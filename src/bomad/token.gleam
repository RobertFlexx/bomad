//// Tokenizer. Delimiters, keyword boundaries and the exact error wording
//// all follow the original, including its fondness for "parantheses".

import bomad/num
import gleam/list
import gleam/string

pub type Token {
  LParen
  RParen
  NumTok(num.Ext)
  BoolTok(Bool)
  StrTok(String)
  UnitTok
  SymTok(String)
  Eof
}

pub fn display(token: Token) -> String {
  case token {
    LParen -> "LPAREN"
    RParen -> "RPAREN"
    NumTok(n) ->
      case n {
        num.Nan -> "NUMLIT(nan)"
        num.Finite(f) -> "NUMLIT(" <> fmt_fixed2(f) <> ")"
        // non-finite literals can only come from overflowing hex floats
        num.Inf -> "NUMLIT(inf)"
        num.NegInf -> "NUMLIT(-inf)"
      }
    BoolTok(True) -> "BOOLLIT(true)"
    BoolTok(False) -> "BOOLLIT(false)"
    StrTok(s) -> "STRINGLIT(\"" <> s <> "\")"
    UnitTok -> "UNITLITERAL"
    SymTok(s) -> "SYMBOL('" <> s <> "')"
    Eof -> "EOF"
  }
}

fn is_delim(c: String) -> Bool {
  c == "(" || c == ")" || c == " " || c == "\t" || c == "\n"
}

fn is_ws(c: String) -> Bool {
  c == " " || c == "\t" || c == "\n" || c == "\r"
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

pub fn tokenize(source: String) -> Result(List(Token), String) {
  let chars = string.to_graphemes(source)
  case scan_all(chars, []) {
    Ok(tokens) -> finish(tokens)
    Error(e) -> Error(e)
  }
}

fn scan_all(chars: List(String), acc: List(Token)) -> Result(List(Token), String) {
  case chars {
    [] -> Ok(list.reverse(acc))
    [c, ..rest] ->
      case is_ws(c) {
        True -> scan_all(rest, acc)
        False ->
          case c {
            "#" -> scan_all(skip_line(rest), acc)
            "(" -> scan_all(rest, [LParen, ..acc])
            ")" -> scan_all(rest, [RParen, ..acc])
            "\"" -> scan_string(rest, "", acc)
            "-" ->
              case rest {
                [d, ..] ->
                  case is_digit(d) {
                    True -> scan_number(chars, acc)
                    False -> scan_symbol(chars, acc)
                  }
                [] -> scan_symbol(chars, acc)
              }
            // a leading dot never starts a number, ".5" is a symbol here
            _ ->
              case is_digit(c) {
                True -> scan_number(chars, acc)
                False -> scan_keyword_or_symbol(chars, acc)
              }
          }
      }
  }
}

fn skip_line(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\n", ..rest] -> rest
    [_, ..rest] -> skip_line(rest)
  }
}

fn scan_string(
  chars: List(String),
  out: String,
  acc: List(Token),
) -> Result(List(Token), String) {
  case chars {
    [] -> Error("String literal was never ended (Got \"" <> out <> ")")
    ["\"", ..rest] -> scan_all(rest, [StrTok(out), ..acc])
    ["\\", e, ..rest] ->
      case e {
        "n" -> scan_string(rest, out <> "\n", acc)
        "t" -> scan_string(rest, out <> "\t", acc)
        "r" -> scan_string(rest, out <> "\r", acc)
        "b" -> scan_string(rest, out <> "\u{0008}", acc)
        "\"" -> scan_string(rest, out <> "\"", acc)
        other -> scan_string(rest, out <> "\\" <> other, acc)
      }
    // a lone backslash at the very end of input lands here
    ["\\"] -> scan_string([], out <> "\\", acc)
    [c, ..rest] -> scan_string(rest, out <> c, acc)
  }
}

fn scan_number(chars: List(String), acc: List(Token)) -> Result(List(Token), String) {
  let #(text, rest) = take_until_delim(chars, "")
  case num.parse_nomad_float(text) {
    Ok(n) -> scan_all(rest, [NumTok(n), ..acc])
    Error(Nil) -> Error("Could not parse " <> text <> " to a number")
  }
}

fn scan_symbol(chars: List(String), acc: List(Token)) -> Result(List(Token), String) {
  let #(text, rest) = take_until_delim(chars, "")
  scan_all(rest, [SymTok(text), ..acc])
}

fn take_until_delim(chars: List(String), out: String) -> #(String, List(String)) {
  case chars {
    [c, ..rest] ->
      case is_delim(c) {
        True -> #(out, chars)
        False -> take_until_delim(rest, out <> c)
      }
    [] -> #(out, [])
  }
}

// a keyword only counts when a delimiter follows, otherwise truest would
// come apart into true and st
fn scan_keyword_or_symbol(chars: List(String), acc: List(Token)) -> Result(List(Token), String) {
  case keyword_at(chars) {
    Ok(#(token, rest)) ->
      case boundary_ok(rest) {
        True -> scan_all(rest, [token, ..acc])
        False -> scan_symbol(chars, acc)
      }
    Error(Nil) -> scan_symbol(chars, acc)
  }
}

fn keyword_at(chars: List(String)) -> Result(#(Token, List(String)), Nil) {
  case chars {
    ["t", "r", "u", "e", ..rest] -> Ok(#(BoolTok(True), rest))
    ["f", "a", "l", "s", "e", ..rest] -> Ok(#(BoolTok(False), rest))
    ["u", "n", "i", "t", ..rest] -> Ok(#(UnitTok, rest))
    _ -> Error(Nil)
  }
}

fn boundary_ok(rest: List(String)) -> Bool {
  case rest {
    [] -> True
    [c, ..] -> is_delim(c)
  }
}

fn finish(tokens: List(Token)) -> Result(List(Token), String) {
  let wrapped = list.append([LParen, ..tokens], [RParen, Eof])
  let #(lefts, rights) = count_parens(wrapped, 0, 0)

  case lefts == rights {
    True -> Ok(wrapped)
    False ->
      // the misspelling of parentheses comes straight from the original,
      // scripts see these strings so they stay untouched
      case lefts > rights {
        True ->
          Error("Unbalanced parantheses: one or more unclosed left parantheses")
        False ->
          Error(
            "Unbalanced parantheses: one or more superfluous right parantheses",
          )
      }
  }
}

fn count_parens(tokens: List(Token), l: Int, r: Int) -> #(Int, Int) {
  case tokens {
    [] -> #(l, r)
    [LParen, ..rest] -> count_parens(rest, l + 1, r)
    [RParen, ..rest] -> count_parens(rest, l, r + 1)
    [_, ..rest] -> count_parens(rest, l, r)
  }
}

// token display renders numbers with two decimals, like the original's
// string_of_token does
fn fmt_fixed2(f: Float) -> String {
  ffi_fmt_fixed(f, 2)
}

@external(erlang, "bomad_ffi", "fmt_fixed")
fn ffi_fmt_fixed(f: Float, decimals: Int) -> String
