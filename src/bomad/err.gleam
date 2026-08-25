//// Error types. The wording of every report line is part of the contract
//// with the original interpreter, right down to the capitalisation.

import gleam/int

pub type NomadErr {
  ParseErr(String)
  TokenizeErr(String)
  EvalErr(String)
  IoErr(String)
  ExitSig(Int)
}

pub fn eval(msg: String) -> NomadErr {
  EvalErr(msg)
}

pub fn report(err: NomadErr) -> String {
  case err {
    ParseErr(e) -> "Error while parsing: " <> e
    TokenizeErr(e) -> "Error while tokenizing: " <> e
    EvalErr(e) -> "Error while evaluating: " <> e
    IoErr(e) -> "Error while reading file: " <> e
    ExitSig(code) ->
      "Error while evaluating: program requested exit with status "
      <> int.to_string(code)
  }
}
