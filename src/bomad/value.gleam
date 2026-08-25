//// Runtime values. Numbers, strings and lists compare structurally while
//// lambdas, macros, natives and records compare by identity, which is what
//// scripts of the original rely on. Every mutable thing (env scopes,
//// records) lives behind an integer id in the ffi store, so reference
//// semantics survive the beam's immutability.

import bomad/err
import bomad/expr
import bomad/num
import gleam/list
import gleam/string

pub type NativeImpl =
  fn(List(expr.Expr), Int) -> Result(Value, err.NomadErr)

pub type Value {
  Num(num.Ext)
  Str(String)
  BoolV(Bool)
  Unit
  Lst(List(Value))
  Lam(id: Int, params: List(String), body: expr.Expr, captured: Int)
  Mac(id: Int, params: List(String), body: List(expr.Expr))
  Nat(id: Int, impl: NativeImpl)
  Rec(id: Int)
}

pub fn display(value: Value) -> String {
  case value {
    Num(n) -> num.format(n)
    Str(s) -> s
    BoolV(True) -> "true"
    BoolV(False) -> "false"
    Unit -> "<UNIT>"
    Lst(items) -> list_display(items)
    Lam(_, _, _, _) -> "<FUNCTION>"
    Mac(_, _, _) -> "<MACRO>"
    Nat(_, _) -> "<NATIVEFUNCTION>"
    Rec(_) -> "<RECORD>"
  }
}

fn list_display(items: List(Value)) -> String {
  "(" <> string.join(list.map(items, display), " ") <> ")"
}

