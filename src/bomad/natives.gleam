//// The builtin functions. Every diagnostic string here is copied from the
//// original interpreter on purpose, scripts assert on them word for word,
//// including the copy-pasted capitalisation quirks.

import bomad/env.{type ScopeId}
import bomad/err.{type NomadErr}
import bomad/eval
import bomad/expr.{type Expr}
import bomad/num
import bomad/value.{type Value, BoolV, Lam, Lst, Mac, Nat, Num, Rec, Str, Unit}
import gleam/int
import gleam/list
import gleam/string

pub type NativeImpl =
  fn(List(Expr), ScopeId) -> Result(Value, NomadErr)

// ---------------------------------------------------------------- registry

pub fn core_natives() -> List(#(String, NativeImpl)) {
  [
    #("throw", throw_impl),
    #("letmac", letmac_impl),
    #("let", let_impl),
    #("letfun", letfun_impl),
    #("mut", mut_impl),
    #("lambda", lambda_impl),
    #("record", record_impl),
    #(".", access_impl),
    #("record_mut", record_mut_impl),
    #("+", add_impl),
    #("-", sub_impl),
    #("*", mul_impl),
    #("/", div_impl),
    #("mod", mod_impl),
    #("=", eq_impl),
    #(">", gt_impl),
    #(">=", ge_impl),
    #("<", lt_impl),
    #("<=", le_impl),
    #("or", or_impl),
    #("and", and_impl),
    #("list", list_impl),
    #("append", append_impl),
    #("car", car_impl),
    #("cdr", cdr_impl),
    #("cons", cons_impl),
    #("sprint", sprint_impl),
    #("print", print_impl),
    #("println", println_impl),
    #("readln", readln_impl),
    #("chars", chars_impl),
    #("lower", lower_impl),
    #("trim", trim_impl),
    #("splitws", splitws_impl),
    #("to_string", to_string_impl),
    #("string_to_num", string_to_num_impl),
    #("isunit", pred_is_unit),
    #("isstr", pred_is_str),
    #("isnum", pred_is_num),
    #("islist", pred_is_list),
    #("isfun", pred_is_fun),
    #("isnative", pred_is_native),
    // says "isnative" in its own error messages, copy paste from the
    // original, kept so diagnostics stay identical
    #("ismac", pred_is_mac),
    #("isbool", pred_is_bool),
    #("isrecord", pred_is_record),
  ]
}


// the five core forms also exist as plain natives so they behave when
// fished out of the env and called indirectly, e.g. ((car (list do)) 1 2).
// registration order puts them in last so shadowing a name degrades it to
// one of these ordinary calls
pub fn core_form_bindings() -> List(#(String, Int, NativeImpl)) {
  [
    #("if", eval.if_id, fn(args, scope) { eval.form_if(args, scope) }),
    #("do", eval.do_id, fn(args, scope) { eval.form_do(args, scope) }),
    #("switch", eval.switch_id, fn(args, scope) { eval.form_switch(args, scope) }),
    #("scoped", eval.scoped_id, fn(args, scope) { eval.form_scoped(args, scope) }),
    #("try", eval.try_id, fn(args, scope) { eval.form_try(args, scope) }),
  ]
}

// ---------------------------------------------------------------- helpers

pub fn arity(name: String, expected: Int, got: Int) -> NomadErr {
  err.eval(
    "Native function "
    <> name
    <> " was given bad syntax. Perhaps it was given the wrong amount of args? Args expected: "
    <> int.to_string(expected)
    <> ". Got: "
    <> int.to_string(got),
  )
}

pub fn type_err(expected: String, e: Expr, got: Value) -> NomadErr {
  err.eval(
    "This expression was expected to evaluate to a "
    <> expected
    <> ", but it didn't: "
    <> expr.display(e)
    <> " ("
    <> value.display(got)
    <> ")",
  )
}

pub fn get_number(e: Expr, scope: ScopeId) -> Result(num.Ext, NomadErr) {
  case eval.eval(e, scope) {
    Ok(Num(x)) -> Ok(x)
    Ok(other) -> Error(type_err("number", e, other))
    Error(e) -> Error(e)
  }
}

pub fn get_string(e: Expr, scope: ScopeId) -> Result(String, NomadErr) {
  case eval.eval(e, scope) {
    Ok(Str(s)) -> Ok(s)
    Ok(other) -> Error(type_err("string", e, other))
    Error(e) -> Error(e)
  }
}

pub fn get_bool(e: Expr, scope: ScopeId) -> Result(Bool, NomadErr) {
  case eval.eval(e, scope) {
    Ok(BoolV(b)) -> Ok(b)
    Ok(other) -> Error(type_err("bool", e, other))
    Error(e) -> Error(e)
  }
}

pub fn get_list(e: Expr, scope: ScopeId) -> Result(List(Value), NomadErr) {
  case eval.eval(e, scope) {
    Ok(Lst(l)) -> Ok(l)
    Ok(other) -> Error(type_err("list", e, other))
    Error(e) -> Error(e)
  }
}

pub fn get_record(e: Expr, scope: ScopeId) -> Result(Int, NomadErr) {
  case eval.eval(e, scope) {
    Ok(Rec(id)) -> Ok(id)
    Ok(other) -> Error(type_err("record", e, other))
    Error(e) -> Error(e)
  }
}

// the error text differs only by one capital letter depending on caller,
// which is silly but the original does it, so we get a flag for it
pub fn symbol_params(
  params: List(Expr),
  lowercase_error: Bool,
) -> Result(List(String), NomadErr) {
  case params {
    [] -> Ok([])
    [expr.Sym(s), ..rest] ->
      case symbol_params(rest, lowercase_error) {
        Ok(tail) -> Ok([s, ..tail])
        Error(e) -> Error(e)
      }
    _ ->
      case lowercase_error {
        True -> Error(err.eval("Non-symbol in parameter list"))
        False -> Error(err.eval("Non-Symbol in parameter list"))
      }
  }
}

// quirk: when the argument fails to evaluate the predicate is just false,
// only exit requests bubble up
pub fn predicate(
  params: List(Expr),
  scope: ScopeId,
  name: String,
  check: fn(Value) -> Bool,
) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case eval.eval(e, scope) {
        Ok(v) -> Ok(BoolV(check(v)))
        Error(err.ExitSig(code)) -> Error(err.ExitSig(code))
        Error(_) -> Ok(BoolV(False))
      }
    _ -> Error(arity(name, 1, list.length(params)))
  }
}

// ---------------------------------------------------------------- control

fn throw_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case eval.eval(e, scope) {
        Ok(Str(s)) -> Error(err.EvalErr(s))
        Ok(other) ->
          Error(err.eval("Cannot throw non-string: " <> value.display(other)))
        Error(e) -> Error(e)
      }
    _ -> Error(arity("throw", 1, list.length(params)))
  }
}

fn letmac_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [expr.Sym(name), expr.ListE(mac_params), ..body] ->
      case symbol_params(mac_params, True) {
        Ok(names) ->
          case env.set(scope, name, Mac(fresh_id(), names, body)) {
            Ok(Nil) -> Ok(Unit)
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    _ -> Error(arity("letmac", 3, list.length(params)))
  }
}

fn let_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [expr.Sym(binding_name), binding_expr] ->
      case eval.eval(binding_expr, scope) {
        Ok(v) ->
          case env.set(scope, binding_name, v) {
            Ok(Nil) -> Ok(Unit)
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    _ -> Error(arity("let", 2, list.length(params)))
  }
}

fn letfun_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [expr.Sym(name), expr.ListE(fun_params), body] ->
      case symbol_params(fun_params, False) {
        Ok(param_list) ->
          case env.set(scope, name, Lam(fresh_id(), param_list, body, scope)) {
            Ok(Nil) -> Ok(Unit)
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    _ -> Error(arity("letfun", 3, list.length(params)))
  }
}

fn mut_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [expr.Sym(binding_name), binding_value] ->
      case eval.eval(binding_value, scope) {
        Ok(v) ->
          case env.mutate(scope, binding_name, v) {
            Ok(Nil) -> Ok(Unit)
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    _ -> Error(arity("mut", 2, list.length(params)))
  }
}

fn lambda_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [expr.ListE(fun_params), body] ->
      case symbol_params(fun_params, False) {
        Ok(param_list) -> Ok(Lam(fresh_id(), param_list, body, scope))
        Error(e) -> Error(e)
      }
    _ -> Error(arity("lambda", 2, list.length(params)))
  }
}

// --------------------------------------------------------------- records

fn record_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  install_fields(fresh_rec(), params, scope)
}

fn install_fields(
  rec_id: Int,
  fields: List(Expr),
  scope: ScopeId,
) -> Result(Value, NomadErr) {
  case fields {
    [] -> Ok(Rec(rec_id))
    [expr.ListE([expr.Sym(field_name), field_expr]), ..rest] ->
      case eval.eval(field_expr, scope) {
        Ok(v) -> {
          rec_add(rec_id, field_name, v)
          install_fields(rec_id, rest, scope)
        }
        Error(e) -> Error(e)
      }
    _ -> Error(err.eval("Record field has bad syntax"))
  }
}

fn access_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [record_expr, expr.Sym(field_name)] ->
      case eval.eval(record_expr, scope) {
        Ok(Rec(rec_id)) ->
          case rec_get(rec_id, field_name) {
            Ok(v) -> Ok(v)
            Error(Nil) ->
              Error(err.eval(
                "Attempt to access non-existant field of record: " <> field_name,
              ))
          }
        Ok(other) ->
          Error(err.eval(
            "Attempt to access field of non-record expression: "
            <> value.display(other),
          ))
        Error(e) -> Error(e)
      }
    _ -> Error(arity(".", 2, list.length(params)))
  }
}

fn record_mut_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [record_expr, expr.Sym(field_name), new_expr] ->
      case eval.eval(record_expr, scope) {
        Ok(Rec(rec_id)) -> {
          // existence gets checked BEFORE the new value evaluates, order matters
          case rec_get(rec_id, field_name) {
            Error(Nil) ->
              Error(err.eval(
                "Cannot mutate non-existant field: " <> field_name,
              ))
            Ok(_) ->
              case eval.eval(new_expr, scope) {
                Ok(v) -> {
                  rec_replace(rec_id, field_name, v)
                  Ok(Unit)
                }
                Error(e) -> Error(e)
              }
          }
        }
        Ok(other) ->
          Error(err.eval(
            "Attempt to mutate field of non-record expression: "
            <> value.display(other),
          ))
        Error(e) -> Error(e)
      }
    _ -> Error(arity("record_mut", 3, list.length(params)))
  }
}

// ------------------------------------------------------------------ math

fn add_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [lhs, rhs] ->
      case eval.eval(lhs, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case eval.eval(rhs, scope) {
            Error(e) -> Error(e)
            Ok(y) ->
              case x, y {
                Num(a), Num(b) -> Ok(Num(num.add(a, b)))
                Str(a), Str(b) -> Ok(Str(a <> b))
                _, _ ->
                  Error(err.eval(
                    "Cannot add these expressions: "
                    <> value.display(x)
                    <> " and "
                    <> value.display(y),
                  ))
              }
          }
      }
    _ -> Error(arity("+", 2, list.length(params)))
  }
}

fn sub_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [lhs, rhs] ->
      case get_number(lhs, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case get_number(rhs, scope) {
            Error(e) -> Error(e)
            Ok(y) -> Ok(Num(num.sub(x, y)))
          }
      }
    _ -> Error(arity("-", 2, list.length(params)))
  }
}

fn mul_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [lhs, rhs] ->
      case eval.eval(lhs, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case eval.eval(rhs, scope) {
            Error(e) -> Error(e)
            Ok(y) ->
              case x, y {
                Num(a), Num(b) -> Ok(Num(num.mul(a, b)))
                Num(a), Str(s) -> Ok(Str(mul_string(s, a)))
                Str(s), Num(a) -> Ok(Str(mul_string(s, a)))
                _, _ ->
                  Error(err.eval(
                    "Cannot multiply these expressions: "
                    <> value.display(x)
                    <> " and "
                    <> value.display(y),
                  ))
              }
          }
      }
    _ -> Error(arity("*", 2, list.length(params)))
  }
}

fn div_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [lhs, rhs] ->
      case get_number(lhs, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case get_number(rhs, scope) {
            Error(e) -> Error(e)
            Ok(y) ->
              // a Finite(0.0) pattern would miss -0.0 on the beam, and
              // (* -1 0) really does produce one
              case num.is_zero(y) {
                True -> Error(err.eval("Attempt to divide by 0"))
                False -> Ok(Num(num.div(x, y)))
              }
          }
      }
    _ -> Error(arity("/", 2, list.length(params)))
  }
}

fn mod_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [lhs, rhs] ->
      case get_number(lhs, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case get_number(rhs, scope) {
            Error(e) -> Error(e)
            Ok(y) -> Ok(Num(num.fmod(x, y)))
          }
      }
    _ -> Error(arity("mod", 2, list.length(params)))
  }
}

// ------------------------------------------------------------ comparison

fn eq_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [a, b] ->
      case eval.eval(a, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case eval.eval(b, scope) {
            Error(e) -> Error(e)
            Ok(y) -> Ok(BoolV(eval.values_equal(x, y)))
          }
      }
    _ -> Error(arity("=", 2, list.length(params)))
  }
}

fn num_compare(
  params: List(Expr),
  scope: ScopeId,
  name: String,
  ok: fn(num.Ext, num.Ext) -> Bool,
) -> Result(Value, NomadErr) {
  case params {
    [a, b] ->
      case get_number(a, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case get_number(b, scope) {
            Error(e) -> Error(e)
            Ok(y) -> Ok(BoolV(ok(x, y)))
          }
      }
    _ -> Error(arity(name, 2, list.length(params)))
  }
}

fn gt_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  num_compare(params, scope, ">", num.gt)
}

fn ge_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  num_compare(params, scope, ">=", num.ge)
}

fn lt_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  num_compare(params, scope, "<", num.lt)
}

fn le_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  num_compare(params, scope, "<=", num.le)
}

// short circuiting on the left operand, the right side never runs when
// the answer is already decided
fn or_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [a, b] ->
      case get_bool(a, scope) {
        Error(e) -> Error(e)
        Ok(True) -> Ok(BoolV(True))
        Ok(False) ->
          case get_bool(b, scope) {
            Error(e) -> Error(e)
            Ok(y) -> Ok(BoolV(y))
          }
      }
    _ -> Error(arity("or", 2, list.length(params)))
  }
}

fn and_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [a, b] ->
      case get_bool(a, scope) {
        Error(e) -> Error(e)
        Ok(False) -> Ok(BoolV(False))
        Ok(True) ->
          case get_bool(b, scope) {
            Error(e) -> Error(e)
            Ok(y) -> Ok(BoolV(y))
          }
      }
    _ -> Error(arity("and", 2, list.length(params)))
  }
}

// ----------------------------------------------------------------- lists

fn list_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  collect_values(params, scope, [])
}

fn collect_values(
  exprs: List(Expr),
  scope: ScopeId,
  acc: List(Value),
) -> Result(Value, NomadErr) {
  case exprs {
    [] -> Ok(Lst(list.reverse(acc)))
    [e, ..rest] ->
      case eval.eval(e, scope) {
        Ok(v) -> collect_values(rest, scope, [v, ..acc])
        Error(e) -> Error(e)
      }
  }
}

fn append_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [a, b] ->
      case get_list(a, scope) {
        Error(e) -> Error(e)
        Ok(x) ->
          case get_list(b, scope) {
            Error(e) -> Error(e)
            Ok(y) -> Ok(Lst(list.append(x, y)))
          }
      }
    _ -> Error(arity("append", 2, list.length(params)))
  }
}

fn car_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_list(e, scope) {
        Error(e) -> Error(e)
        Ok(l) ->
          case l {
            [head, ..] -> Ok(head)
            [] -> Ok(Unit)
          }
      }
    _ -> Error(arity("car", 1, list.length(params)))
  }
}

fn cdr_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_list(e, scope) {
        Error(e) -> Error(e)
        Ok(l) ->
          case l {
            [_, ..tail] -> Ok(Lst(tail))
            [] -> Ok(Unit)
          }
      }
    _ -> Error(arity("cdr", 1, list.length(params)))
  }
}

// note the order: the list argument evaluates first, like in the original
fn cons_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e, l] ->
      case get_list(l, scope) {
        Error(e) -> Error(e)
        Ok(tail) ->
          case eval.eval(e, scope) {
            Ok(head) -> Ok(Lst([head, ..tail]))
            Error(e) -> Error(e)
          }
      }
    _ -> Error(arity("cons", 2, list.length(params)))
  }
}

// --------------------------------------------------------------- printing

fn sprint_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  concat_displayed(params, scope, "")
}

fn println_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case concat_displayed(params, scope, "") {
    Ok(Str(out)) -> {
      put_line(out)
      Ok(Unit)
    }
    Ok(_) -> Ok(Unit)
    Error(e) -> Error(e)
  }
}

fn print_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case concat_displayed(params, scope, "") {
    Ok(Str(out)) -> {
      put_str(out)
      Ok(Unit)
    }
    Ok(_) -> Ok(Unit)
    Error(e) -> Error(e)
  }
}

fn concat_displayed(
  exprs: List(Expr),
  scope: ScopeId,
  acc: String,
) -> Result(Value, NomadErr) {
  case exprs {
    [] -> Ok(Str(acc))
    [e, ..rest] ->
      case eval.eval(e, scope) {
        Ok(v) -> concat_displayed(rest, scope, acc <> value.display(v))
        Error(e) -> Error(e)
      }
  }
}

fn readln_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [prompt] ->
      case get_string(prompt, scope) {
        Error(e) -> Error(e)
        Ok(p) -> {
          put_str(p)
          case stdin_line() {
            Ok(line) -> Ok(Str(strip_line_breaks(line)))
            Error(Nil) -> Error(err.eval("readln: reached end of input"))
          }
        }
      }
    _ -> Error(arity("readln", 1, list.length(params)))
  }
}

// trims trailing newlines only, repeatedly
fn strip_line_breaks(line: String) -> String {
  case string.ends_with(line, "\n") || string.ends_with(line, "\r") {
    True -> strip_line_breaks(string.drop_end(line, 1))
    False -> line
  }
}

// ---------------------------------------------------------------- strings

fn chars_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(s) -> Ok(Lst(chars_of(s)))
      }
    _ -> Error(arity("chars", 1, list.length(params)))
  }
}

// one string per unicode scalar value
fn chars_of(s: String) -> List(Value) {
  s
  |> string.to_utf_codepoints
  |> list.map(fn(cp) { Str(string.from_utf_codepoints([cp])) })
}

fn lower_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        // ascii only, like the original
        Ok(s) -> Ok(Str(lower_ascii(s)))
        Error(e) -> Error(e)
      }
    _ -> Error(arity("lower", 1, list.length(params)))
  }
}

fn trim_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case eval.eval(e, scope) {
        Ok(Str(s)) -> Ok(Str(trim_ocaml(s)))
        Ok(other) ->
          Error(err.eval(
            "Cannot apply trim-operation on non-string expression: "
            <> value.display(other),
          ))
        Error(e) -> Error(e)
      }
    _ -> Error(arity("trim", 1, list.length(params)))
  }
}

fn splitws_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(s) -> {
          let parts =
            s
            |> string.split(" ")
            |> list.filter(fn(p) { trim_ocaml(p) != "" })
          Ok(Lst(list.map(parts, Str)))
        }
      }
    _ -> Error(arity("splitws", 1, list.length(params)))
  }
}

fn to_string_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case eval.eval(e, scope) {
        Ok(v) -> Ok(Str(value.display(v)))
        Error(e) -> Error(e)
      }
    _ -> Error(arity("to_string", 1, list.length(params)))
  }
}

fn string_to_num_impl(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case params {
    [e] ->
      case get_string(e, scope) {
        Error(e) -> Error(e)
        Ok(s) ->
          case num.parse_nomad_float(s) {
            Ok(n) -> Ok(Num(n))
            Error(Nil) ->
              Error(err.eval("Cannot parse this string to a number: " <> s))
          }
      }
    _ -> Error(arity("string_to_num", 1, list.length(params)))
  }
}

// ------------------------------------------------------------- predicates

fn pred_is_unit(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "isunit", is_unit_val)
}

fn is_unit_val(v: Value) -> Bool {
  case v {
    Unit -> True
    _ -> False
  }
}

fn pred_is_str(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "isstring", fn(v) {
    case v {
      Str(_) -> True
      _ -> False
    }
  })
}

fn pred_is_num(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "isnum", fn(v) {
    case v {
      Num(_) -> True
      _ -> False
    }
  })
}

fn pred_is_list(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "islist", fn(v) {
    case v {
      Lst(_) -> True
      _ -> False
    }
  })
}

fn pred_is_fun(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "islambda", fn(v) {
    case v {
      Lam(_, _, _, _) -> True
      _ -> False
    }
  })
}

fn pred_is_native(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "isnative", fn(v) {
    case v {
      Nat(_, _) -> True
      _ -> False
    }
  })
}

fn pred_is_mac(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "isnative", fn(v) {
    case v {
      Mac(_, _, _) -> True
      _ -> False
    }
  })
}

fn pred_is_bool(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "isbool", fn(v) {
    case v {
      BoolV(_) -> True
      _ -> False
    }
  })
}

fn pred_is_record(params: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  predicate(params, scope, "isrecord", fn(v) {
    case v {
      Rec(_) -> True
      _ -> False
    }
  })
}

// ------------------------------------------------------------------- ffi



@external(erlang, "bomad_ffi", "fresh_id")
fn fresh_id() -> Int

@external(erlang, "bomad_ffi", "rec_new")
fn fresh_rec() -> Int

@external(erlang, "bomad_ffi", "rec_get")
fn rec_get(id: Int, field: String) -> Result(Value, Nil)

@external(erlang, "bomad_ffi", "rec_add")
fn rec_add(id: Int, field: String, v: Value) -> Nil

@external(erlang, "bomad_ffi", "rec_replace")
fn rec_replace(id: Int, field: String, v: Value) -> Nil

@external(erlang, "bomad_ffi", "put_s")
fn put_str(text: String) -> Nil

@external(erlang, "bomad_ffi", "put_line")
fn put_line(text: String) -> Nil

@external(erlang, "bomad_ffi", "stdin_line")
fn stdin_line() -> Result(String, Nil)

@external(erlang, "bomad_ffi", "lower_ascii")
fn lower_ascii(text: String) -> String

@external(erlang, "bomad_ffi", "trim_ocaml")
fn trim_ocaml(text: String) -> String

// nan repeats zero times, infinity saturates at a million, everything
// else truncates toward zero then clamps to [0, 1_000_000]
pub fn mul_string(s: String, factor: num.Ext) -> String {
  let n = case factor {
    num.Nan -> 0
    num.Inf | num.NegInf -> 1_000_000
    num.Finite(_) -> num.to_i64_saturating(factor)
  }
  case n < 1 {
    True -> ""
    False -> string.repeat(s, int.clamp(n, 0, 1_000_000))
  }
}
