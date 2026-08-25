//// The evaluator. The beam flattens every call in tail position by itself,
//// so plain recursion here already gives the constant stack behaviour the
//// rust port needed an explicit trampoline for. The five core forms (if do
//// switch scoped try) are recognised by their reserved native ids and
//// their own name in head position, so shadowing one of the names simply
//// turns it back into an ordinary call.

import bomad/env.{type ScopeId}
import bomad/err.{type NomadErr}
import bomad/num
import bomad/expr.{type Expr}
import bomad/value.{type Value, BoolV, Lam, Lst, Mac, Nat, Num, Rec, Str, Unit}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result

// these ids are reserved for the core forms and never handed out to
// user registered natives
pub const if_id = 1

pub const do_id = 2

pub const switch_id = 3

pub const scoped_id = 4

pub const try_id = 5

pub fn eval(expression: Expr, scope: ScopeId) -> Result(Value, NomadErr) {
  case expression {
    expr.NumLit(n) -> Ok(Num(n))
    expr.StringLit(s) -> Ok(Str(s))
    expr.BoolLit(b) -> Ok(BoolV(b))
    expr.UnitE -> Ok(Unit)
    expr.Sym(name) -> env.get(scope, name)
    // a fresh identity per closure creation, equality is by id
    expr.LamE(params, body) -> Ok(Lam(fresh_id(), params, body, scope))
    expr.ListE([]) -> Ok(Lst([]))
    expr.ListE([fun_expr, ..arg_exprs]) -> {
      use fun <- result.try(eval(fun_expr, scope))
      apply(fun, fun_expr, arg_exprs, scope)
    }
  }
}

fn apply(
  fun: Value,
  fun_expr: Expr,
  arg_exprs: List(Expr),
  scope: ScopeId,
) -> Result(Value, NomadErr) {
  case fun {
    Lam(_, params, body, captured) ->
      case list.length(params) == list.length(arg_exprs) {
        False ->
          Error(err.eval(
            "Attempted to invoke lambda with wrong amount of params. Expected: "
            <> int.to_string(list.length(params))
            <> " got: "
            <> int.to_string(list.length(arg_exprs)),
          ))
        True -> {
          use bound <- result.try(bind_args(params, arg_exprs, captured, scope))
          // tail position: the beam flattens this recursion for free
          eval(body, bound)
        }
      }

    Mac(_, params, body) ->
      case list.length(params) == list.length(arg_exprs) {
        False ->
          Error(err.eval(
            "Attempted to invoke macro with wrong amount of params. Expected: "
            <> int.to_string(list.length(params))
            <> " got: "
            <> int.to_string(list.length(arg_exprs)),
          ))
        True -> {
          let table = subst_table(params, arg_exprs)
          // the expansion runs in the caller's environment
          eval(expr.ListE(list.map(body, substitute(_, table))), scope)
        }
      }

    Nat(id, impl) ->
      case head_name(fun_expr), is_core(id) {
        // core treatment needs the reserved id under its own name; an
        // alias like (scoped ((d do)) ...) degrades to an ordinary call,
        // which is exactly what the rust port's ptr_eq check does
        Ok(name), True ->
          case name, id {
            "if", _ if id == if_id -> form_if(arg_exprs, scope)
            "do", _ if id == do_id -> form_do(arg_exprs, scope)
            "switch", _ if id == switch_id -> form_switch(arg_exprs, scope)
            "scoped", _ if id == scoped_id -> form_scoped(arg_exprs, scope)
            "try", _ if id == try_id -> form_try(arg_exprs, scope)
            _, _ -> impl(arg_exprs, scope)
          }
        _, _ -> impl(arg_exprs, scope)
      }

    other ->
      Error(err.eval(
        "Attempt to invoke non-function/non-macro: "
        <> expr.display(fun_expr)
        <> " ("
        <> value.display(other)
        <> ")",
      ))
  }
}

fn head_name(fun_expr: Expr) -> Result(String, Nil) {
  case fun_expr {
    expr.Sym(name) -> Ok(name)
    _ -> Error(Nil)
  }
}

fn is_core(id: Int) -> Bool {
  id >= 1 && id <= 5
}

fn arity_msg(name: String, expected: Int, got: Int) -> String {
  "Native function "
  <> name
  <> " was given bad syntax. Perhaps it was given the wrong amount of args? Args expected: "
  <> int.to_string(expected)
  <> ". Got: "
  <> int.to_string(got)
}

pub fn form_if(args: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case args {
    [cond, yes, no] ->
      case eval(cond, scope) {
        Error(e) -> Error(e)
        Ok(BoolV(True)) -> eval(yes, scope)
        Ok(BoolV(False)) -> eval(no, scope)
        Ok(other) ->
          Error(err.eval(
            "Condition of if-construct does not evaluate to a bool: "
            <> value.display(other),
          ))
      }
    _ -> Error(err.eval(arity_msg("if", 3, list.length(args))))
  }
}

pub fn form_do(args: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case list.reverse(args) {
    [] -> Ok(Unit)
    [last, ..earlier_rev] -> {
      use _ <- result.try(eval_seq(list.reverse(earlier_rev), scope))
      eval(last, scope)
    }
  }
}

pub fn eval_seq(forms: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case forms {
    [] -> Ok(Unit)
    [only] -> eval(only, scope)
    [next, ..rest] -> {
      use _ <- result.try(eval(next, scope))
      eval_seq(rest, scope)
    }
  }
}

pub fn form_switch(args: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case args {
    [] -> Error(err.eval(arity_msg("switch", 2, 0)))
    [scrutinee, ..cases] -> {
      use target <- result.try(eval(scrutinee, scope))
      find_arm(cases, target, scope)
    }
  }
}

fn find_arm(
  cases: List(Expr),
  target: Value,
  scope: ScopeId,
) -> Result(Value, NomadErr) {
  case cases {
    [] -> Ok(Unit)
    [arm, ..rest] ->
      case arm {
        expr.ListE([matcher, on_match]) ->
          case matcher {
            expr.Sym("_") -> eval(on_match, scope)
            _ ->
              case eval(matcher, scope) {
                Error(e) -> Error(e)
                Ok(matched) ->
                  case values_equal(matched, target) {
                    True -> eval(on_match, scope)
                    False -> find_arm(rest, target, scope)
                  }
              }
          }
        // not a two element list, same complaint either way
        _ -> Error(err.eval("Malformed switch-arm syntax"))
      }
  }
}

pub fn form_scoped(args: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case args {
    [expr.ListE(binding_pairs), body] -> {
      let child = env.new(scope)
      // each binding evaluates against the outer scope and lands in the
      // child right away, interleaved, like the original does it
      use _ <- result.try(bind_pairs(binding_pairs, scope, child))
      eval(body, child)
    }
    _ -> Error(err.eval(arity_msg("scoped", 2, list.length(args))))
  }
}

fn bind_pairs(
  pairs: List(Expr),
  outer: ScopeId,
  child: ScopeId,
) -> Result(Nil, NomadErr) {
  case pairs {
    [] -> Ok(Nil)
    [pair, ..rest] ->
      case pair {
        expr.ListE([expr.Sym(name), binding_expr]) ->
          case eval(binding_expr, outer) {
            Ok(v) ->
              case env.set(child, name, v) {
                Ok(Nil) -> bind_pairs(rest, outer, child)
                Error(e) -> Error(e)
              }
            Error(e) -> Error(e)
          }
        _ ->
          Error(err.eval(
            "Bad Syntax! The binding list is in the wrong form! (Expected '(name value)')",
          ))
      }
  }
}

pub fn form_try(args: List(Expr), scope: ScopeId) -> Result(Value, NomadErr) {
  case args {
    [may_fail, on_fail] ->
      case eval(may_fail, scope) {
        Ok(v) -> Ok(v)
        // only evaluation errors are recoverable; exit requests (and any
        // foreign error a host native might raise) propagate untouched
        Error(err.EvalErr(_)) -> eval(on_fail, scope)
        Error(e) -> Error(e)
      }
    _ -> Error(err.eval(arity_msg("try", 2, list.length(args))))
  }
}

fn bind_args(
  params: List(String),
  arg_exprs: List(Expr),
  captured: ScopeId,
  caller: ScopeId,
) -> Result(ScopeId, NomadErr) {
  let fresh = env.new(captured)
  case bind_loop(fresh, params, arg_exprs, caller) {
    Ok(Nil) -> Ok(fresh)
    Error(e) -> Error(e)
  }
}

// interleaved like the original: evaluate one argument, install it,
// move on. a duplicate param name fails halfway through, side effects
// included
fn bind_loop(
  fresh: ScopeId,
  params: List(String),
  arg_exprs: List(Expr),
  caller: ScopeId,
) -> Result(Nil, NomadErr) {
  case params, arg_exprs {
    [], [] -> Ok(Nil)
    [name, ..prest], [arg_expr, ..arest] ->
      case eval(arg_expr, caller) {
        Ok(v) ->
          case env.set(fresh, name, v) {
            Ok(Nil) -> bind_loop(fresh, prest, arest, caller)
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    // lengths were verified before we got here
    _, _ -> Ok(Nil)
  }
}

fn subst_table(
  params: List(String),
  arg_exprs: List(Expr),
) -> Dict(String, Expr) {
  list.zip(params, arg_exprs)
  |> list.fold(dict.new(), fn(acc, pair) {
    let #(name, expr_) = pair
    dict.insert(acc, name, expr_)
  })
}

fn substitute(item: Expr, table: Dict(String, Expr)) -> Expr {
  case item {
    expr.Sym(name) ->
      case dict.get(table, name) {
        Ok(replacement) -> replacement
        Error(Nil) -> item
      }
    expr.ListE(items) -> expr.ListE(list.map(items, substitute(_, table)))
    other -> other
  }
}

// structural for data, identity for anything callable or record shaped.
// every lambda/letfun evaluation mints a fresh closure, so two separately
// created ones never compare equal, only the same value passed around
pub fn values_equal(a: Value, b: Value) -> Bool {
  case a, b {
    Num(x), Num(y) -> num.eq(x, y)
    Str(x), Str(y) -> x == y
    BoolV(x), BoolV(y) -> x == y
    Unit, Unit -> True
    Lst(xs), Lst(ys) -> lists_equal(xs, ys)
    Lam(x, _, _, _), Lam(y, _, _, _) -> x == y
    Mac(x, _, _), Mac(y, _, _) -> x == y
    Nat(x, _), Nat(y, _) -> x == y
    Rec(x), Rec(y) -> x == y
    _, _ -> False
  }
}

fn lists_equal(xs: List(Value), ys: List(Value)) -> Bool {
  case xs, ys {
    [], [] -> True
    [x, ..xrest], [y, ..yrest] -> values_equal(x, y) && lists_equal(xrest, yrest)
    _, _ -> False
  }
}

@external(erlang, "bomad_ffi", "fresh_id")
fn fresh_id() -> Int
