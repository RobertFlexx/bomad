-module(bomad_ffi).

-export([init_store/0, fresh_id/0, scope_new/1, scope_get/2, scope_set/3,
          scope_mutate/3, scope_locals/1, scope_parent/1,
          rec_new/0, rec_get/2, rec_add/3, rec_replace/3,
          exec_status/1, stdin_line/0, repl_line/0, put_s/1, put_line/1,
          halt_now/1, plain_args/0,
          fmt_fixed/2, make_nan/0, make_inf/0, is_nan/1, is_finite/1,
          mod_float/2,
          num_add/2, num_mul/2, num_div/2, num_fmod/2, num_pow2/1, lower_ascii/1, trim_ocaml/1,
          num_is_zero/1, is_sign_negative/1,
          read_file/1, write_file/2, remove_file/1, list_dir/1,
          make_dir/1, remove_dir/1, set_cwd/1, get_cwd/0, getenv/1]).

%% every mutable thing the language promises lives behind integer ids:
%% environment scopes and records. reference semantics fall out of that.
%% the process dictionary backs the store because the language has no
%% concurrency primitives at all, so everything runs inside one process,
%% and pd reads cost a fraction of ets round trips. the interpreter is
%% evaluated synchronously wherever it was started, which keeps this sound

init_store() ->
    %% ids must never be reused: a second interpreter in the same process
    %% would otherwise collide with bindings left over by the first one
    case get(counter) of
        undefined -> put(counter, 100);
        _ -> ok
    end,
    ok.

fresh_id() ->
    case get(counter) of
        undefined -> init_store();
        _ -> ok
    end,
    C = get(counter),
    put(counter, C + 1),
    C.

scope_new(Parent) ->
    Id = fresh_id(),
    put({scope, Id}, Parent),
    put({locals, Id}, []),
    Id.

scope_get(Id, Key) ->
    walk_get(Id, Key).

walk_get(-1, _Key) -> {error, nil};
walk_get(Id, Key) ->
    case get({b, Id, Key}) of
        undefined -> walk_get(get({scope, Id}), Key);
        Value -> {ok, Value}
    end.

scope_set(Id, Key, Value) ->
    case get({b, Id, Key}) of
        undefined ->
            put({b, Id, Key}, Value),
            put({locals, Id}, [Key | get({locals, Id})]),
            {ok, nil};
        _Found ->
            {error, nil}
    end.

scope_mutate(Id, Key, Value) ->
    case find_owner(Id, Key) of
        -1 ->
            {error, nil};
        Owner ->
            put({b, Owner, Key}, Value),
            {ok, nil}
    end.

find_owner(-1, _Key) -> -1;
find_owner(Id, Key) ->
    case get({b, Id, Key}) of
        undefined -> find_owner(get({scope, Id}), Key);
        _Found -> Id
    end.

scope_locals(Id) ->
    Keys = get({locals, Id}),
    [{K, get({b, Id, K})} || K <- Keys].

scope_parent(Id) ->
    case get({scope, Id}) of
        undefined -> -1;
        Parent -> Parent
    end.

rec_new() ->
    Id = fresh_id(),
    put({rec, Id}, maps:new()),
    Id.

rec_get(Id, Field) ->
    case get({rec, Id}) of
        undefined ->
            {error, nil};
        Map ->
            case maps:find(Field, Map) of
                {ok, V} -> {ok, V};
                error -> {error, nil}
            end
    end.

rec_add(Id, Field, Value) ->
    case get({rec, Id}) of
        undefined ->
            {error, nil};
        Map ->
            put({rec, Id}, maps:put(Field, Value, Map)),
            {ok, nil}
    end.

rec_replace(Id, Field, Value) ->
    case get({rec, Id}) of
        undefined ->
            {error, nil};
        Map ->
            case maps:is_key(Field, Map) of
                true ->
                    put({rec, Id}, maps:put(Field, Value, Map)),
                    {ok, nil};
                false ->
                    {error, nil}
            end
    end.

%% the beam hands us a decoded status (code, or 128+signal for kills),
%% not the raw unix wait word ocaml sees. translate back as best we can:
%% below 128 means a normal exit, at or above means a signal death.
%% children exiting with codes >= 128 are therefore indistinguishable
%% from signals, a documented limit of the platform
exec_status(Cmd) ->
    try open_port({spawn_executable, "/bin/sh"}, [exit_status, {args, ["-c", Cmd]}]) of
        Port ->
            Status = receive
                {Port, {exit_status, S}} -> S;
                _Other -> 127
            after 300000 ->
                127
            end,
            catch port_close(Port),
            to_wait_word(Status)
    catch
        _:_ -> 127
    end.

to_wait_word(S) when S >= 0, S < 128 -> S * 256;
to_wait_word(S) when S >= 128, S < 256 -> S - 128;
to_wait_word(_) -> 127.

stdin_line() ->
    case io:get_line("") of
        eof -> {error, nil};
        Line -> {ok, Line}
    end.

repl_line() ->
    case io:get_line("Nomad λ ") of
        eof -> {error, nil};
        Line -> {ok, Line}
    end.

put_s(Text) ->
    try io:put_chars(Text) of
        _ -> nil
    catch
        _:_ -> nil
    end.

put_line(Text) ->
    put_s([Text, $\n]).

halt_now(Code) ->
    erlang:halt(Code).

plain_args() ->
    %% init hands us charlists, the gleam side expects utf8 binaries
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

fmt_fixed(Float, Decimals) ->
    float_to_binary(Float, [{decimals, Decimals}]).

%% the beam constant-folds float equality, so nan detection has to go
%% through a runtime call where erlang's own inequality still sees it
is_nan(F) -> F =/= F.

is_finite(F) when is_float(F) ->
    <<_:1, Exp:11, _:52>> = <<F:64/float>>,
    Exp =/= 16#7FF;
is_finite(_) -> false.

%% nan and inf are not writable as literals on the beam, so they get
%% built here through their bit patterns when a script asks for them
make_nan() ->
    <<F:64/float>> = <<16#7FF8000000000000:64>>,
    F.

make_inf() ->
    <<F:64/float>> = <<16#7FF0000000000000:64>>,
    F.

%% ieee fmod; a zero divisor yields nan instead of an arithmetic crash
mod_float(A, B) ->
    try math:fmod(A, B) catch _:_ -> make_nan() end.

%% ------------------------------------------------------------------
%% total float ops backing bomad/num. the beam raises badarith whenever a
%% result would be non-finite, and such a trap is always a genuine
%% magnitude overflow, so translating it by sign is exact. these only see
%% finite operands; inf/nan are handled gleam side

%% true for 0.0 and -0.0 alike; plain pattern matching would tell the two
%% sign bits apart and miss negative zero
num_is_zero(A) -> A == 0.0.

%% true when the float's sign bit is set, negatives plus negative zero
is_sign_negative(A) when is_float(A) ->
    <<S:1, _/bitstring>> = <<A/float>>,
    S =:= 1.

num_add(A, B) ->
    try A + B of
        R -> {finite, R}
    catch
        _:_ when A > 0 -> inf;
        _:_ -> neg_inf
    end.

num_mul(A, B) ->
    try A * B of
        R -> {finite, R}
    catch
        _:_ when (A >= 0) =:= (B >= 0) -> inf;
        _:_ -> neg_inf
    end.

num_div(A, B) ->
    try A / B of
        R -> {finite, R}
    catch
        _:_ when (A >= 0) =:= (B >= 0) -> inf;
        _:_ -> neg_inf
    end.

%% remainder of two finites cannot overflow; any trap here is a domain
%% error that slipped through, which maps to nan like c's fmod would
num_fmod(A, B) ->
    try math:fmod(A, B) of
        R -> {finite, R}
    catch
        _:_ -> nan
    end.

%% 2^exp for the hex-float parser. saturates instead of trapping:
%% positive overflow to inf, underflow to zero
num_pow2(Exp) ->
    try math:pow(2, Exp) of
        R -> {finite, R}
    catch
        _:_ when Exp > 0 -> inf;
        _:_ -> {finite, 0.0}
    end.

%% ascii only on purpose: the original lowercases with to_ascii_lowercase,
%% unicode letters pass through untouched
lower_ascii(Bin) when is_binary(Bin) ->
    << <<(case C >= $A andalso C =< $Z of
             true -> C + 32;
             false -> C
         end)/utf8>>
      || <<C/utf8>> <= Bin >>;
lower_ascii(Other) -> Other.

%% ocaml's String.trim set: space \t \n \r \v \f, nothing else
trim_ocaml(Bin) ->
    string:trim(Bin, both, " \t\n\r\v\f").

%% ------------------------------------------------------------------
%% filesystem and environment. error strings copy the "(os error N)" shape
%% scripts expect to see, e.g. "No such file or directory (os error 2)",
%% because they land in user visible diagnostics verbatim

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, R} -> {error, posix_msg(R)}
    end.

write_file(Path, Content) ->
    case file:write_file(Path, Content) of
        ok -> {ok, nil};
        {error, R} -> {error, posix_msg(R)}
    end.

remove_file(Path) ->
    case file:delete(Path) of
        ok -> {ok, nil};
        {error, R} -> {error, posix_msg(R)}
    end.

list_dir(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> {ok, Names};
        {error, R} -> {error, posix_msg(R)}
    end.

%% the original forces 0755; file:make_dir uses the process umask which is
%% close enough in practice and needs no setuid dance on the beam
make_dir(Path) ->
    case file:make_dir(Path) of
        ok -> {ok, nil};
        {error, R} -> {error, posix_msg(R)}
    end.

remove_dir(Path) ->
    case file:del_dir(Path) of
        ok -> {ok, nil};
        {error, R} -> {error, posix_msg(R)}
    end.

set_cwd(Path) ->
    case file:set_cwd(Path) of
        ok -> {ok, nil};
        {error, R} -> {error, posix_msg(R)}
    end.

get_cwd() ->
    case file:get_cwd() of
        {ok, Dir} -> {ok, Dir};
        {error, R} -> {error, posix_msg(R)}
    end.

getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Val -> {ok, unicode:characters_to_binary(Val)}
    end.

posix_msg(enoent) -> <<"No such file or directory (os error 2)">>;
posix_msg(eacces) -> <<"Permission denied (os error 13)">>;
posix_msg(eisdir) -> <<"Is a directory (os error 21)">>;
posix_msg(enotdir) -> <<"Not a directory (os error 20)">>;
posix_msg(eexist) -> <<"File exists (os error 17)">>;
posix_msg(enotempty) -> <<"Directory not empty (os error 39)">>;
posix_msg(ebadf) -> <<"Bad file descriptor (os error 9)">>;
posix_msg(enospc) -> <<"No space left on device (os error 28)">>;
posix_msg(erofs) -> <<"Read-only file system (os error 30)">>;
posix_msg(enametoolong) -> <<"File name too long (os error 36)">>;
posix_msg(enoexec) -> <<"Exec format error (os error 8)">>;
posix_msg(Other) when is_atom(Other) ->
    Name = atom_to_binary(Other, utf8),
    <<"Unknown error: ", Name/binary>>;
posix_msg(_) -> <<"Unknown error">>.
