//// Conformance tests, ported from the rust implementation's language and
//// runtime suites. Lots of these assert on exact error strings, that's
//// intentional, the original's diagnostics are part of the contract.

import bomad/env
import bomad/err.{type NomadErr, EvalErr, ExitSig, IoErr, TokenizeErr}
import bomad/expr
import bomad/eval
import bomad/interp
import bomad/num
import bomad/value.{type Value, BoolV, Lst, Num, Str, Unit}
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// -------------------------------------------------------------- helpers

fn last(source: String) -> Result(Value, NomadErr) {
  interp.do_string(interp.with_args([]), source)
}

fn ok(source: String) -> Value {
  case last(source) {
    Ok(v) -> v
    Error(e) -> panic as { "`" <> source <> "` failed: " <> err.report(e) }
  }
}

fn eval_err(source: String) -> String {
  case last(source) {
    Error(EvalErr(m)) -> m
    Error(other) ->
      panic as {
        "`" <> source <> "` failed with non-eval error: " <> err.report(other)
      }
    Ok(v) ->
      panic as { "`" <> source <> "` unexpectedly succeeded: " <> value.display(v) }
  }
}

fn tokenize_err(source: String) -> String {
  case last(source) {
    Error(TokenizeErr(m)) -> m
    other -> panic as { "expected tokenizer error, got " <> string.inspect(other) }
  }
}

fn num_of(source: String) -> Float {
  let assert Num(num.Finite(n)) = ok(source)
  n
}

fn str_of(source: String) -> String {
  let assert Str(s) = ok(source)
  s
}

fn bool_of(source: String) -> Bool {
  let assert BoolV(b) = ok(source)
  b
}

fn shown(source: String) -> String {
  value.display(ok(source))
}

// ------------------------------------------------------- language suite

pub fn arithmetic_and_precedence_by_nesting_test() {
  num_of("(+ 1 2)") |> should.equal(3.0)
  num_of("(* 6 7)") |> should.equal(42.0)
  num_of("(+ (* 10 5) (- 1000 250))") |> should.equal(800.0)
}

pub fn negative_numbers_and_floats_test() {
  num_of("-5") |> should.equal(-5.0)
  num_of("(- 0 2.5)") |> should.equal(-2.5)
  num_of("(mod 7.5 2)") |> should.equal(1.5)
}

pub fn string_escapes_test() {
  str_of("(sprint \"a\\nb\\tc\\rd\\\"e\")")
  |> should.equal("a\nb\tc\rd\"e")
}

pub fn comments_are_ignored_test() {
  num_of("# comment\n(+ 1 # inline\n 2)") |> should.equal(3.0)
}

pub fn keywords_do_not_split_words_test() {
  num_of("(let truest 55) truest") |> should.equal(55.0)
  num_of("(let units 9) units") |> should.equal(9.0)
  bool_of("true") |> should.equal(True)
  bool_of("false") |> should.equal(False)
  ok("unit") |> should.equal(Unit)
}

pub fn unbalanced_parens_are_tokenizer_errors_test() {
  tokenize_err("(+ 1 2")
  |> should.equal(
    "Unbalanced parantheses: one or more unclosed left parantheses",
  )
  tokenize_err("+ 1 2)")
  |> should.equal(
    "Unbalanced parantheses: one or more superfluous right parantheses",
  )
}

pub fn multiple_top_level_forms_evaluate_in_order_test() {
  num_of("(let x 10) (let y 20) (+ x y)") |> should.equal(30.0)
}

pub fn empty_input_is_unit_test() {
  ok("") |> should.equal(Unit)
}

pub fn closures_and_currying_test() {
  num_of(
    "(let add (lambda (x) (lambda (y) (+ x y)))) 
     (let add10 (add 10)) (add10 20)",
  )
  |> should.equal(30.0)
}

pub fn recursion_via_letfun_test() {
  num_of(
    "(letfun fact (n) (switch n (0 1) (_ (* n (fact (dec n)))))) (fact 10)",
  )
  |> should.equal(3_628_800.0)
}

pub fn lambda_arity_must_match_exactly_test() {
  eval_err("((lambda (x) x))")
  |> should.equal(
    "Attempted to invoke lambda with wrong amount of params. Expected: 1 got: 0",
  )
}

pub fn duplicate_params_are_rejected_like_the_original_test() {
  eval_err("((lambda (x x) x) 1 2)")
  |> should.equal("Cannot bind x: Already exists in this scope")
}

pub fn let_rebinding_in_same_scope_fails_mut_works_test() {
  eval_err("(let x 1) (let x 2)")
  |> should.equal("Cannot bind x: Already exists in this scope")
  num_of("(let x 1) (mut x 41) (+ x 1)") |> should.equal(42.0)
  eval_err("(mut nope 1)")
  |> should.equal("Cannot mutate non-existant binding: nope")
}

pub fn macros_expand_in_caller_scope_test() {
  num_of(
    "(letmac my_when (cond body) if cond body unit) 
     (my_when true 7)",
  )
  |> should.equal(7.0)

  let assert Lst(items) = ok("(letmac m (a) list a a a) 
   (m (+ 1 1))")
  items |> list.length |> should.equal(3)
  items
  |> list.each(fn(item) {
    let assert Num(num.Finite(2.0)) = item
    Nil
  })
}

pub fn macro_arity_must_match_test() {
  eval_err("(letmac m (a b) a) (m 1)")
  |> should.equal(
    "Attempted to invoke macro with wrong amount of params. Expected: 2 got: 1",
  )
}

pub fn switch_semantics_test() {
  let src = fn(scrutinee: String) {
    "(switch "
    <> scrutinee
    <> " (1 \"one\") (2 \"two\") (_ \"many\"))"
  }
  src("1") |> str_of |> should.equal("one")
  src("2") |> str_of |> should.equal("two")
  src("99") |> str_of |> should.equal("many")

  ok("(switch 99 (1 \"one\"))") |> should.equal(Unit)
}

pub fn scoped_bindings_do_not_leak_test() {
  num_of("(scoped ((x 10) (y 20)) (+ x y))") |> should.equal(30.0)
  let assert Error(_) = last("(scoped ((x 1)) x) (+ x 1)")
  Nil
}

pub fn do_returns_last_value_test() {
  num_of("(do 1 2 3)") |> should.equal(3.0)
  ok("(do)") |> should.equal(Unit)
}

pub fn if_requires_bool_condition_test() {
  num_of("(if true 1 2)") |> should.equal(1.0)
  eval_err("(if 1 1 2)")
  |> should.equal("Condition of if-construct does not evaluate to a bool: 1")
}

pub fn try_catches_evaluation_errors_only_test() {
  str_of("(try (throw \"boom\") \"caught\")") |> should.equal("caught")
  num_of("(try (/ 1 0) 42)") |> should.equal(42.0)
}

pub fn throw_can_carry_any_message_test() {
  eval_err("(throw \"custom\")") |> should.equal("custom")
}

pub fn unbound_variables_report_nicely_test() {
  eval_err("nope") |> should.equal("No such variable: nope")
}

pub fn invoking_non_functions_errors_with_display_test() {
  eval_err("(1 2)")
  |> should.equal(
    "Attempt to invoke non-function/non-macro: Number(1.000000) (1)",
  )
}

pub fn ocaml_style_number_literals_test() {
  num_of("(+ 0x1A 0)") |> should.equal(26.0)
  num_of("1_000") |> should.equal(1000.0)
  num_of("(- 0xA.8p-2 0)") |> should.equal(2.625)
  num_of("0x.8") |> should.equal(0.5)
}

pub fn rust_shaped_decimals_parse_like_rust_test() {
  num_of("5.") |> should.equal(5.0)
  // string_to_num keeps the full float grammar even though the tokenizer
  // does not: ".5" and "-.5e2" tokenize as symbols
  num_of("(string_to_num \".5\")") |> should.equal(0.5)
  num_of("(string_to_num \"-.5e2\")") |> should.equal(-50.0)
}

// a leading dot never starts a number: the original tokenizes ".5" as a
// symbol and evaluating it fails with its usual no-such-variable report
pub fn leading_dot_is_a_symbol_like_the_original_test() {
  eval_err("(.5)") |> should.equal("No such variable: .5")
  eval_err("(-.5)") |> should.equal("No such variable: -.5")
}

// core forms are recognized only when their reserved id shows up under
// their own name; an alias degrades to an ordinary native call instead of
// panicking
pub fn aliased_core_form_degrades_to_native_call_test() {
  num_of("(scoped ((d do)) (d 1 2))") |> should.equal(2.0)
  // an aliased if still runs, just eagerly like any ordinary native
  num_of("(scoped ((i if)) (i true 1 2))") |> should.equal(1.0)
}

pub fn try_catches_only_eval_errors_test() {
  num_of("(try (/ 1 0) 42)") |> should.equal(42.0)
  // exit requests are not recoverable
  let assert Error(ExitSig(3)) = last("(try (exit 3) 42)")
}

// erlang separates -0.0 from 0.0 in pattern matches while every other
// runtime lumps them together; these pin the expected outcomes
pub fn negative_zero_division_errors_like_rust_test() {
  eval_err("(/ 1 (* -1 0))")
  |> should.equal("Attempt to divide by 0")
}

pub fn zero_times_infinity_is_nan_test() {
  str_of("(to_string (* (* -1 0) (* 1e308 10)))")
  |> should.equal("nan")

  str_of("(to_string (* (* -1 0) (mod 0 0)))")
  |> should.equal("nan")
}

pub fn infinity_arithmetic_carries_sign_test() {
  str_of("(to_string (* (* 1e308 10) -2))") |> should.equal("-inf")
  str_of("(to_string (/ (* 1e308 10) -5))") |> should.equal("-inf")
  str_of("(to_string (* -1 (* 1e308 10)))") |> should.equal("-inf")
  str_of("(to_string (mod 5 (* -1 0)))") |> should.equal("nan")
}

pub fn string_to_num_accepts_ocaml_spellings_test() {
  num_of("(string_to_num \"0x10\")") |> should.equal(16.0)
  num_of("(string_to_num \"1_0\")") |> should.equal(10.0)
  eval_err("(string_to_num \"abc\")")
  |> should.equal("Cannot parse this string to a number: abc")
}

pub fn number_formatting_matches_string_of_rval_test() {
  str_of("(to_string 1e18)")
  |> should.equal("1000000000000000000")

  str_of("(to_string (mod 0 0))") |> should.equal("nan")

  str_of("(to_string (* 1e308 10))") |> should.equal("inf")
}

pub fn cons_evaluates_the_list_argument_first_test() {
  let v = ok(
    "(let r (record (log ()))) 
     (letfun note_head () 
       (do (record_mut r log (append (. r log) (list \"head\"))) 1)) 
     (letfun note_tail () 
       (do (record_mut r log (append (. r log) (list \"tail\"))) ())) 
     (cons (note_head) (note_tail)) 
     (. r log)",
  )
  let assert Lst(items) = v
  let tags =
    list.flat_map(items, fn(item) {
      case item {
        Str(s) -> [s]
        _ -> []
      }
    })
  tags |> should.equal(["tail", "head"])
}

pub fn lower_is_ascii_only_like_lowercase_ascii_test() {
  str_of("(lower \"MiXeD 123\")") |> should.equal("mixed 123")

  str_of("(lower \"ÉÀ\")") |> should.equal("ÉÀ")
}

pub fn trim_only_strips_ascii_whitespace_test() {
  str_of("(trim \" \\tx \")") |> should.equal("x")
  let nbsp = "\u{00a0}"

  num_of("(len (chars (trim \"" <> nbsp <> "\")))")
  |> should.equal(1.0)
  str_of("(trim \" x \")") |> should.equal("x")
}

pub fn predicate_arity_errors_use_the_original_names_test() {
  eval_err("(isstr 1 2)")
  |> should.equal(
    "Native function isstring was given bad syntax. Perhaps it was given the wrong amount of args? Args expected: 1. Got: 2",
  )
  eval_err("(isfun 1 2)")
  |> should.equal(
    "Native function islambda was given bad syntax. Perhaps it was given the wrong amount of args? Args expected: 1. Got: 2",
  )

  eval_err("(ismac 1 2)")
  |> should.equal(
    "Native function isnative was given bad syntax. Perhaps it was given the wrong amount of args? Args expected: 1. Got: 2",
  )
}

pub fn get_env_unit_arity_error_says_get_env_test() {
  eval_err("(get_env_unit 1 2)")
  |> should.equal(
    "Native function get_env was given bad syntax. Perhaps it was given the wrong amount of args? Args expected: 1. Got: 2",
  )
}

pub fn tail_recursive_loops_run_in_constant_stack_test() {
  num_of(
    "(let loop (lambda (n acc) (if (= n 0) acc (loop (- n 1) (+ acc 1)))))
     (loop 1000000 0)",
  )
  |> should.equal(1_000_000.0)
}

pub fn tail_positions_of_all_core_forms_are_flat_test() {
  str_of(
    "(let loop (lambda (n) (switch n (0 \"done\") (_ (loop (- n 1))))))
     (loop 200000)",
  )
  |> should.equal("done")

  str_of(
    "(let loop (lambda (n) (if (= n 0) \"ok\" (scoped ((m (- n 1))) (loop m)))))
     (loop 200000)",
  )
  |> should.equal("ok")

  str_of(
    "(let loop (lambda (n) (if (= n 0) \"done\" (try (throw \"x\") (loop (- n 1))))))
     (loop 200000)",
  )
  |> should.equal("done")
}

pub fn try_bodies_do_not_exhaust_the_stack_test() {
  str_of(
    "(let loop (lambda (n) (if (= n 0) \"ok\" (try (loop (- n 1)) \"e\"))))
     (loop 200000)",
  )
  |> should.equal("ok")
}

pub fn mutual_recursion_through_tail_calls_is_flat_test() {
  bool_of(
    "(let even? (lambda (n) (if (= n 0) true (odd? (- n 1)))))
     (let odd? (lambda (n) (if (= n 0) false (even? (- n 1)))))
     (even? 500001)",
  )
  |> should.equal(False)
}

pub fn rebinding_a_core_form_disables_its_special_treatment_test() {
  // letmac tries to rebind if in the global scope, set rejects it
  let assert Error(EvalErr(_)) = last("(letmac if (a) a) (if 5)")
  Nil
}

pub fn try_catches_errors_from_nested_evaluation_test() {
  str_of("(try (no-such-var-here 1 2 3) \"caught\")")
  |> should.equal("caught")

  str_of("(try (try (car 5) (throw \"from-handler\")) \"outer\")")
  |> should.equal("outer")
}

pub fn indirect_core_form_calls_stay_plain_natives_test() {
  // ((car (list do)) 1 2) reaches the registry's own impl but through a
  // non-symbol head, so it behaves like an ordinary native call
  num_of("((car (list do)) 1 2)") |> should.equal(2.0)
}

pub fn lambdas_compare_by_identity_test() {
  bool_of("(= (lambda (x) x) (lambda (x) x))") |> should.equal(False)
  bool_of(
    "(let f (lambda (x) x))
     (= f f)",
  )
  |> should.equal(True)
}

pub fn unit_literal_in_call_position_is_an_error_test() {
  let assert Error(_) = last("((unit))")
  Nil
}

pub fn lambda_values_display_as_function_test() {
  shown("(lambda (x) x)") |> should.equal("<FUNCTION>")
  shown("print") |> should.equal("<NATIVEFUNCTION>")
  shown("(letmac m () unit) m") |> should.equal("<MACRO>")
}

pub fn closures_capture_by_reference_test() {
  num_of(
    "(let counter 0)
     (let bump (lambda () (do (mut counter (+ counter 1)) counter)))
     (bump) (bump)
     counter",
  )
  |> should.equal(2.0)
}

pub fn stdlib_loads_at_startup_test() {
  bool_of("(not false)") |> should.equal(True)
  num_of("(inc 41)") |> should.equal(42.0)
  num_of("(dec 43)") |> should.equal(42.0)
  str_of("(unless true \"a\" \"b\")") |> should.equal("b")
  str_of("(when true \"yes\")") |> should.equal("yes")
  bool_of("(!= 1 2)") |> should.equal(True)
  str_of("(typeof 1.5)") |> should.equal("number")
  num_of("(foldl + 0 (list 1 2 3 4))") |> should.equal(10.0)
  str_of("(typeof print)") |> should.equal("native")
}

// --------------------------------------------------------- runtime suite

pub fn records_construct_access_mutate_test() {
  num_of("(let p (record (name \"ann\") (age 3))) (. p age)")
  |> should.equal(3.0)
  num_of(
    "(let p (record (x 1))) 
     (record_mut p x 99) 
     (. p x)",
  )
  |> should.equal(99.0)

  case last("(let p (record (x 1))) (. p y)") {
    Error(EvalErr(m)) ->
      m
      |> should.equal("Attempt to access non-existant field of record: y")
    other -> panic as { "wrong result: " <> string.inspect(other) }
  }
  case last("(let p (record (x 1))) (record_mut p y 2)") {
    Error(EvalErr(m)) ->
      m |> should.equal("Cannot mutate non-existant field: y")
    other -> panic as { "wrong result: " <> string.inspect(other) }
  }
}

pub fn records_are_shared_references_test() {
  num_of(
    "(letfun give () (record (n 0))) 
     (let a (give)) (let b a) 
     (record_mut b n 5) 
     (. a n)",
  )
  |> should.equal(5.0)
}

pub fn isrecord_and_typeof_recognise_records_test() {
  bool_of("(isrecord (record (a 1)))") |> should.equal(True)
  str_of("(typeof (record (a 1)))") |> should.equal("record")
  str_of("(typeof 1.5)") |> should.equal("number")
  str_of("(typeof \"s\")") |> should.equal("string")
  str_of("(typeof true)") |> should.equal("bool")
  str_of("(typeof (list))") |> should.equal("list")
  str_of("(typeof unit)") |> should.equal("unit")
  str_of("(typeof print)") |> should.equal("native")
  str_of("(typeof (lambda (x) x))") |> should.equal("function")
  str_of("(do (letmac m () unit) (typeof m))") |> should.equal("macro")
}

pub fn comparison_operators_are_numeric_test() {
  bool_of("(>= 2 2)") |> should.equal(True)
  bool_of("(>= 1 2)") |> should.equal(False)
  bool_of("(<= 1 2)") |> should.equal(True)
  bool_of("(> 3 2)") |> should.equal(True)
  bool_of("(< 3 2)") |> should.equal(False)
}

pub fn equality_rules_match_the_original_with_unit_fixed_test() {
  bool_of("(= 1 1)") |> should.equal(True)
  bool_of("(= \"a\" \"a\")") |> should.equal(True)
  bool_of("(= (list 1 2) (list 1 2))") |> should.equal(True)
  bool_of("(= (list 1 2) (list 2 1))") |> should.equal(False)
  bool_of("(= 1 \"1\")") |> should.equal(False)

  bool_of("(= unit unit)") |> should.equal(True)
}

pub fn list_operations_test() {
  num_of("(len (list 1 2 3))") |> should.equal(3.0)
  shown("(rev (list 1 2 3))") |> should.equal("(3 2 1)")
  shown("(append (list 1) (list 2 3))") |> should.equal("(1 2 3)")
  shown("(cons 0 (list 1 2))") |> should.equal("(0 1 2)")
  num_of("(car (list 1 2))") |> should.equal(1.0)
  shown("(cdr (list 1 2))") |> should.equal("(2)")
  ok("(car (list))") |> should.equal(Unit)
  ok("(cdr (list))") |> should.equal(Unit)
  shown("(map (lambda (x) (* x x)) (list 1 2 3))") |> should.equal("(1 4 9)")
  num_of("(foldl + 0 (list 1 2 3 4))") |> should.equal(10.0)
  shown("(filter (lambda (x) (< x 3)) (list 1 2 3 4))")
  |> should.equal("(1 2)")
  shown("(range 1 3 (list 0 1 2 3 4))") |> should.equal("(1 2 3)")
  num_of("(nth (list 10 20 30) 1)") |> should.equal(20.0)

  case last("(nth (list 10) 5)") {
    Error(EvalErr(m)) -> m |> should.equal("List has no such index")
    other -> panic as { "wrong result: " <> string.inspect(other) }
  }
  ok("(nth_unit (list 10) 5)") |> should.equal(Unit)
  shown("(list_init 3 (lambda (i) (* i i)))") |> should.equal("(0 1 4)")
  shown("(mapi (lambda (x i) i) (list 7 7 7))") |> should.equal("(0 1 2)")
}

pub fn string_operations_test() {
  num_of("(strlen \"héllo\")") |> should.equal(5.0)
  shown("(chars \"abc\")") |> should.equal("(a b c)")
  str_of("(lower \"AbC\")") |> should.equal("abc")
  str_of("(trim \"  hi  \")") |> should.equal("hi")
  shown("(splitws \"a b  c\")") |> should.equal("(a b c)")
  num_of("(string_to_num \"3.5\")") |> should.equal(3.5)

  case last("(string_to_num \"nope\")") {
    Error(EvalErr(m)) ->
      m |> should.equal("Cannot parse this string to a number: nope")
    other -> panic as { "wrong result: " <> string.inspect(other) }
  }
  bool_of("(has_suffix \"file.nomad\" \".nomad\")") |> should.equal(True)
  bool_of("(begins_with (list 1 2) (list 1))") |> should.equal(True)
  str_of("(* \"ab\" 3)") |> should.equal("ababab")
  str_of("(* 2 \"-\")") |> should.equal("--")
}

pub fn logic_operators_short_circuit_evaluation_of_values_test() {
  bool_of("(and true false)") |> should.equal(False)
  bool_of("(or false true)") |> should.equal(True)

  case last("(and 1 true)") {
    Error(EvalErr(m)) ->
      m
      |> should.equal(
        "This expression was expected to evaluate to a bool, but it didn't: Number(1.000000) (1)",
      )
    other -> panic as { "wrong result: " <> string.inspect(other) }
  }

  // short circuit: when the left side decides the answer the right side is
  // never type checked at all
  bool_of("(and false 1)") |> should.equal(False)
  bool_of("(or true 1)") |> should.equal(True)
}

pub fn number_formatting_matches_original_test() {
  str_of("(to_string 42)") |> should.equal("42")
  str_of("(to_string -7)") |> should.equal("-7")
  str_of("(to_string (/ 10 4))") |> should.equal("2.50")
  str_of("(to_string (+ 1 2))") |> should.equal("3")
  str_of("(to_string true)") |> should.equal("true")
  str_of("(to_string \"raw\")") |> should.equal("raw")
  shown("(to_string (list 1 2.5))") |> should.equal("(1 2.50)")
}

pub fn exit_and_bye_return_control_signals_test() {
  case last("(bye)") {
    Error(ExitSig(0)) -> Nil
    other -> panic as { "expected Exit(0), got " <> string.inspect(other) }
  }
  case last("(exit 3)") {
    Error(ExitSig(3)) -> Nil
    other -> panic as { "expected Exit(3), got " <> string.inspect(other) }
  }

  case last("(try (bye) 42)") {
    Error(ExitSig(0)) -> Nil
    other ->
      panic as { "expected Exit(0) to propagate, got " <> string.inspect(other) }
  }
}

pub fn host_functions_can_be_registered_test() {
  let interpreter = interp.with_args([])
  let assert Ok(Nil) =
    env.set(
      interpreter.global,
      "shout",
      value.Nat(
        ffi_fresh(),
        fn(args, scope) { concat_uppercased(args, scope, "") },
      ),
    )

  let assert Ok(Str(s)) =
    interp.do_string(interpreter, "(shout \"hey\" 42)")
  s |> should.equal("HEY42")
}

fn concat_uppercased(
  args: List(expr.Expr),
  scope: env.ScopeId,
  acc: String,
) -> Result(Value, NomadErr) {
  case args {
    [] -> Ok(Str(uppercase_ascii(acc)))
    [arg, ..rest] ->
      case eval.eval(arg, scope) {
        Ok(v) -> concat_uppercased(rest, scope, acc <> value.display(v))
        Error(e) -> Error(e)
      }
  }
}

pub fn args_binding_is_configurable_test() {
  let interpreter = interp.with_args(["script.nomad", "alpha", "beta"])
  let assert Ok(Num(num.Finite(3.0))) = interp.do_string(interpreter, "(len args)")
  let assert Ok(Str("alpha")) =
    interp.do_string(interpreter, "(car (cdr args))")
  Nil
}

pub fn globals_can_be_read_written_from_host_test() {
  let interpreter = interp.with_args([])
  let assert Ok(Nil) = env.set(interpreter.global, "answer", Num(num.Finite(42.0)))
  let assert Ok(Num(num.Finite(42.0))) = interp.do_string(interpreter, "answer")
  Nil
}

pub fn do_file_evaluates_scripts_test() {
  let script = "/tmp/opencode/bomad_test_script.nomad"
  let assert Ok(Nil) = ffi_write(script, "(letfun sq (x) (* x x)) (sq 9)")

  let interpreter = interp.with_args([])
  let assert Ok(Nil) = interp.do_file(interpreter, script)
  let assert Ok(Num(num.Finite(64.0))) = interp.do_string(interpreter, "(sq 8)")

  case interp.do_file(interpreter, "/tmp/opencode/missing.nomad") {
    Error(IoErr(_)) -> Nil
    other -> panic as { "expected Io error, got " <> string.inspect(other) }
  }
}

pub fn parse_errors_carry_original_wording_test() {
  let assert Error(TokenizeErr(_)) = last("(")
  let assert Error(TokenizeErr(m)) = last("(1 2")
  let assert True = string.starts_with(m, "Unbalanced parantheses")
  Nil
}

pub fn exec_surfaces_raw_wait_statuses_test() {
  num_of("(exec \"exit 3\")") |> should.equal(768.0)

  num_of("(exec \"kill -9 $$\")") |> should.equal(9.0)
  let assert Ok(_) = last("(exec \"definitely-not-a-command-xyz\")")
  Nil
}

pub fn exit_error_reports_like_the_original_test() {
  case last("(exit 3)") {
    Error(e) -> err.report(e) |> should.equal(
      "Error while evaluating: program requested exit with status 3",
    )
    other -> panic as { "wrong result: " <> string.inspect(other) }
  }
}

// ------------------------------------------------------------------- ffi

@external(erlang, "bomad_ffi", "fresh_id")
fn ffi_fresh() -> Int

@external(erlang, "bomad_ffi", "write_file")
fn ffi_write(path: String, content: String) -> Result(Nil, String)

// only ascii ever flows through here in tests
@external(erlang, "string", "uppercase")
fn uppercase_ascii(s: String) -> String
