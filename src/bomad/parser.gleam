//// Recursive descent parser. The tokenizer wraps the whole program in one
//// outer list expression, so parse_program just unpacks that root list.

import bomad/err.{type NomadErr}
import bomad/expr.{type Expr, BoolLit, ListE, NumLit, StringLit, Sym, UnitE}
import bomad/token.{
  type Token, BoolTok, Eof, LParen, NumTok, RParen, StrTok, SymTok, UnitTok,
}
import gleam/list

pub fn parse_program(source: String) -> Result(List(Expr), NomadErr) {
  case parse_one(source) {
    Ok(ListE(forms)) -> Ok(forms)
    Ok(_) -> Error(err.ParseErr("Root Expression is not a list"))
    Error(e) -> Error(e)
  }
}

pub fn parse_one(source: String) -> Result(Expr, NomadErr) {
  case token.tokenize(source) {
    Error(e) -> Error(err.TokenizeErr(e))
    Ok(tokens) ->
      case run(tokens) {
        Ok(expr) -> Ok(expr)
        Error(e) -> Error(err.ParseErr(e))
      }
  }
}

fn run(tokens: List(Token)) -> Result(Expr, String) {
  case parse_expr(Parser(tokens: tokens, pos: 0)) {
    Ok(#(expr, _)) -> Ok(expr)
    Error(e) -> Error(e)
  }
}

type Parser {
  Parser(tokens: List(Token), pos: Int)
}

fn peek(state: Parser) -> Result(Token, Nil) {
  case list.drop(state.tokens, state.pos) {
    [t, ..] -> Ok(t)
    [] -> Error(Nil)
  }
}

fn bump(state: Parser) -> #(Result(Token, Nil), Parser) {
  case peek(state) {
    Ok(t) -> #(Ok(t), Parser(..state, pos: state.pos + 1))
    Error(Nil) -> #(Error(Nil), state)
  }
}

fn parse_expr(state: Parser) -> Result(#(Expr, Parser), String) {
  let #(got, state) = bump(state)
  case got {
    Error(Nil) -> Error("Cannot parse EOF")
    Ok(NumTok(n)) -> Ok(#(NumLit(n), state))
    Ok(SymTok(s)) -> Ok(#(Sym(s), state))
    Ok(StrTok(s)) -> Ok(#(StringLit(s), state))
    Ok(BoolTok(b)) -> Ok(#(BoolLit(b), state))
    Ok(UnitTok) -> Ok(#(UnitE, state))
    Ok(LParen) -> parse_list(state)
    Ok(other) -> Error("Unexpected token: " <> token.display(other))
  }
}

fn parse_list(state: Parser) -> Result(#(Expr, Parser), String) {
  parse_list_loop(state, [])
}

fn parse_list_loop(
  state: Parser,
  acc: List(Expr),
) -> Result(#(Expr, Parser), String) {
  case peek(state) {
    Error(Nil) -> Error("Unexpected EOF")
    Ok(Eof) -> Error("Unexpected EOF")
    Ok(RParen) -> {
      let #(_, state) = bump(state)
      Ok(#(ListE(list.reverse(acc)), state))
    }
    Ok(_) ->
      case parse_expr(state) {
        Ok(#(item, next)) -> parse_list_loop(next, [item, ..acc])
        Error(e) -> Error(e)
      }
  }
}
