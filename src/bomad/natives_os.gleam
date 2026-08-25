//// Process and filesystem level builtins. Same deal as the core natives:
//// exact diagnostics, same result shapes, including the wait-status style
//// exit codes that exec reports.

import bomad/env.{type ScopeId}
import bomad/err.{type NomadErr}
import bomad/num
import gleam/float
import bomad/eval
import bomad/expr.{type Expr}
import bomad/natives.{type NativeImpl, arity, get_number, get_string}
import bomad/parser
import bomad/value.{type Value, Num, Str, Unit}
import gleam/int
import gleam/list
import gleam/string

pub fn os_natives() -> List(#(String, NativeImpl)) {
  [
    #("exec", exec_impl),
    #("exit", exit_impl),
    #("bye", bye_impl),
    #("print_env", print_env_impl),
    #("include", include_impl),
    #("read_file", read_file_impl),
    #("write_file", write_file_impl),
    #("remove_file", remove_file_impl),
    #("read_dir", read_dir_impl),
    #("mkdir", mkdir_impl),
    #("remove_dir", remove_dir_impl),
    #("chdir", chdir_impl),
    #("cwd", cwd_impl),
    #("get_env", get_env_impl),
    // arity messages say "get_env" even here, original quirk, kept
    #("get_env_unit", get_env_unit_impl),
  ]
}

fn exec_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(cmd) -> Ok(Num(num.Finite(int.to_float(exec_status(cmd)))))
      }
    _ -> Error(arity("exec", 1, list.length(params)))
  }
}

// exit statuses use the shell encoding: code * 256 for a normal exit,
// raw signal number for a signal death, 127 for a missing shell. the ffi
// translates the beam's decoded status back into that, see
// bomad_ffi:exec_status/1
@external(erlang, "bomad_ffi", "exec_status")
fn exec_status(cmd: String) -> Int

fn exit_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_number(e, scope) {
        Error(e) -> Error(e)
        Ok(code) -> Error(err.ExitSig(float_to_i32_code(code)))
      }
    _ -> Error(arity("exit", 1, list.length(params)))
  }
}

fn bye_impl(_params: List(Expr), _scope: ScopeId) -> Result(Value, NomadErr) {
  Error(err.ExitSig(0))
}

// nan clamps to zero, infinities and anything past i32 range saturate,
// everything else truncates toward zero
fn float_to_i32_code(x: num.Ext) -> Int {
  case x {
    num.Nan -> 0
    num.Inf -> 2_147_483_647
    num.NegInf -> -2_147_483_648
    num.Finite(f) ->
      case f >=. 2_147_483_647.0 {
        True -> 2_147_483_647
        False ->
          case f <=. -2_147_483_648.0 {
            True -> -2_147_483_648
            False -> float.truncate(f)
          }
      }
  }
}

fn print_env_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [] -> {
      print_scopes(scope, 0)
      Ok(Unit)
    }
    _ -> Error(arity("print_env", 0, list.length(params)))
  }
}

fn print_scopes(current: ScopeId, idx: Int) -> Nil {
  case current == env.no_parent {
    True -> Nil
    False -> {
      natives_put_line("Scope " <> int.to_string(idx) <> ":")
      env.locals_sorted(current)
      |> list.each(fn(entry) {
        let #(k, v) = entry
        natives_put_line("\t" <> k <> ": " <> value.display(v))
      })
      print_scopes(parent_of(current), idx + 1)
    }
  }
}

@external(erlang, "bomad_ffi", "scope_parent")
fn parent_of(scope: ScopeId) -> ScopeId

@external(erlang, "bomad_ffi", "put_line")
fn natives_put_line(text: String) -> Nil

fn include_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [expr.Sym(path)] ->
      case read_file(path) {
        Error(reason) ->
          Error(err.eval(
            "Error while including '" <> path <> "': " <> reason,
          ))
        Ok(content) ->
          case parser.parse_program(content) {
            Error(e) -> Error(e)
            Ok(forms) ->
              case eval.eval_seq(forms, scope) {
                Error(e) -> Error(e)
                Ok(_) -> Ok(Unit)
              }
          }
      }
    _ -> Error(arity("include", 1, list.length(params)))
  }
}

fn read_file_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(path) ->
          case read_file(path) {
            Ok(content) -> Ok(Str(content))
            Error(reason) ->
              Error(err.eval(
                "Error while reading '" <> path <> "': " <> reason,
              ))
          }
      }
    _ -> Error(arity("read_file", 1, list.length(params)))
  }
}

fn write_file_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [path_expr, content_expr] ->
      case get_string(path_expr, scope) {
        Error(e) -> Error(e)
        Ok(path) ->
          case get_string(content_expr, scope) {
            Error(e) -> Error(e)
            Ok(content) ->
              case write_file(path, content) {
                Ok(Nil) -> Ok(Unit)
                Error(reason) ->
                  Error(err.eval(
                    "Couldn't write to '" <> path <> "': " <> reason,
                  ))
              }
          }
      }
    _ -> Error(arity("write_file", 2, list.length(params)))
  }
}

fn remove_file_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(path) ->
          case remove_file(path) {
            Ok(Nil) -> Ok(Unit)
            Error(reason) ->
              Error(err.eval(
                "Couldn't remove file '" <> path <> "': " <> reason,
              ))
          }
      }
    _ -> Error(arity("remove_file", 1, list.length(params)))
  }
}

fn read_dir_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(path) ->
          case list_dir(path) {
            Ok(names) ->
              Ok(value.Lst(
                names
                |> sort_strings
                |> list.map(Str),
              ))
            Error(reason) ->
              Error(err.eval(
                "Couldn't read directory '" <> path <> "': " <> reason,
              ))
          }
      }
    _ -> Error(arity("read_dir", 1, list.length(params)))
  }
}

fn sort_strings(names: List(String)) -> List(String) {
  list.sort(names, string.compare)
}

fn mkdir_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(path) ->
          case make_dir(path) {
            Ok(Nil) -> Ok(Unit)
            Error(reason) ->
              Error(err.eval(
                "Couldn't create directory '" <> path <> "': " <> reason,
              ))
          }
      }
    _ -> Error(arity("mkdir", 1, list.length(params)))
  }
}

fn remove_dir_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(path) ->
          case remove_dir(path) {
            Ok(Nil) -> Ok(Unit)
            Error(reason) ->
              Error(err.eval(
                "Couldn't remove directory: '" <> path <> "': " <> reason,
              ))
          }
      }
    _ -> Error(arity("remove_dir", 1, list.length(params)))
  }
}

fn chdir_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(path) ->
          case set_cwd(path) {
            Ok(Nil) -> Ok(Unit)
            Error(reason) ->
              Error(err.eval(
                "Error while changing working directory to '"
                <> path
                <> "': "
                <> reason,
              ))
          }
      }
    _ -> Error(arity("chdir", 1, list.length(params)))
  }
}

fn cwd_impl(params: List(Expr), _scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [] ->
      case get_cwd() {
        Ok(path) -> Ok(Str(path))
        Error(reason) ->
          Error(err.eval(
            "Could not determine working directory: " <> reason,
          ))
      }
    _ -> Error(arity("cwd", 0, list.length(params)))
  }
}

fn get_env_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(var) ->
          case getenv(var) {
            Ok(v) -> Ok(Str(v))
            Error(Nil) ->
              Error(err.eval(
                "Environment variable '" <> var <> "' not found",
              ))
          }
      }
    _ -> Error(arity("get_env", 1, list.length(params)))
  }
}

fn get_env_unit_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(var) ->
          case getenv(var) {
            Ok(v) -> Ok(Str(v))
            Error(Nil) -> Ok(Unit)
          }
      }
    _ -> Error(arity("get_env", 1, list.length(params)))
  }
}

// ------------------------------------------------------------------- ffi

@external(erlang, "bomad_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "bomad_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "bomad_ffi", "remove_file")
fn remove_file(path: String) -> Result(Nil, String)

@external(erlang, "bomad_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)

@external(erlang, "bomad_ffi", "make_dir")
fn make_dir(path: String) -> Result(Nil, String)

@external(erlang, "bomad_ffi", "remove_dir")
fn remove_dir(path: String) -> Result(Nil, String)

@external(erlang, "bomad_ffi", "set_cwd")
fn set_cwd(path: String) -> Result(Nil, String)

@external(erlang, "bomad_ffi", "get_cwd")
fn get_cwd() -> Result(String, String)

@external(erlang, "bomad_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
