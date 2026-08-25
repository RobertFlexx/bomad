//// The AST. Display output leaks into runtime error messages (for example
//// when a condition is not a bool) so the formatting is deliberately kept
//// identical to the ocaml version, quirks included.

import bomad/num

pub type Expr {
  NumLit(num.Ext)
  StringLit(String)
  BoolLit(Bool)
  UnitE
  Sym(String)
  LamE(List(String), Expr)
  ListE(List(Expr))
}

pub fn display(expr: Expr) -> String {
  case expr {
    NumLit(n) -> "Number(" <> fmt6_or_nan(n) <> ")"
    StringLit(s) -> "String(\"" <> s <> "\")"
    BoolLit(True) -> "Bool(true)"
    BoolLit(False) -> "Bool(false)"
    UnitE -> "<UNIT>"
    Sym(s) -> "Symbol('" <> s <> "')"
    LamE(_, _) -> "<LAMBDA>"
    ListE(items) -> "List(" <> join(items) <> ")"
  }
}

fn join(items: List(Expr)) -> String {
  case items {
    [] -> ""
    [first, ..rest] -> display(first) <> pad_join(rest)
  }
}

fn pad_join(items: List(Expr)) -> String {
  case items {
    [] -> ""
    [first, ..rest] -> " " <> display(first) <> pad_join(rest)
  }
}

// a literal can only go non-finite through a hex float that overflows,
// and the original prints those lowercase, quirks included
fn fmt6_or_nan(n: num.Ext) -> String {
  case n {
    num.Nan -> "nan"
    num.Inf -> "inf"
    num.NegInf -> "-inf"
    num.Finite(f) -> fmt_fixed(f, 6)
  }
}

@external(erlang, "bomad_ffi", "fmt_fixed")
fn fmt_fixed(n: Float, decimals: Int) -> String
