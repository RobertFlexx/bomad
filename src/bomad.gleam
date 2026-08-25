//// CLI entrypoint. Same surface as the other implementations: --help, -e
//// for inline evaluation, a file path to run a script, no args for the
//// REPL.

import bomad/err
import bomad/interp.{type Interp}
import bomad/value

const help = " \\\\
  \\\\
 //\\\\
//  \\\\

The Magnificent Nomad-LISP Interpretation System

Omit all arguments to enter REPL Mode.
Use the -e | --eval flag to evaluate an expression which is passed as an argument.
\tExample: nomad -e '(+ 1 2)' # => 3

You can also pass a file to be run as a script.
\tExample: nomad my_script.nomad
For More information, visit:
https://github.com/Moritisimor/nomad-lisp"

pub fn main() -> Nil {
  case plain_args() {
    ["--help"] | ["-h"] -> {
      out_line(help)
      halt(0)
    }
    ["-e", code] | ["--eval", code] -> eval_mode(code, plain_args())
    [] | ["--repl"] | ["-r"] -> repl()
    [file, ..] -> file_mode(file, plain_args())
  }
}

fn eval_mode(code: String, argv: List(String)) -> Nil {
  let interpreter = interp.with_args(argv)
  case interp.do_string(interpreter, code) {
    Ok(value) -> {
      out_line(value.display(value))
      halt(0)
    }
    Error(err.ExitSig(code)) -> halt(code)
    Error(e) -> {
      out_line(err.report(e))
      halt(1)
    }
  }
}

fn file_mode(file: String, argv: List(String)) -> Nil {
  let interpreter = interp.with_args(argv)
  case interp.do_file(interpreter, file) {
    Ok(Nil) -> halt(0)
    Error(err.ExitSig(code)) -> halt(code)
    Error(e) -> {
      out_line(err.report(e))
      halt(1)
    }
  }
}

fn repl() -> Nil {
  let interpreter = interp.with_args(plain_args())
  repl_loop(interpreter)
}

fn repl_loop(interpreter: Interp) -> Nil {
  case repl_line() {
    Error(Nil) -> halt(0)
    Ok(line) -> {
      // one line goes through the parser at a time, so an incomplete form
      // is just a parse error, its closing parens never arrive. the rust
      // repl behaves the same way
      case interp.do_string(interpreter, line) {
        Ok(value) ->
          out_line("Evaluates to: " <> value.display(value))
        Error(err.ExitSig(code)) -> halt(code)
        Error(e) -> out_line(err.report(e))
      }
      repl_loop(interpreter)
    }
  }
}

fn out_line(text: String) -> Nil {
  put_line(text)
}

@external(erlang, "bomad_ffi", "put_line")
fn put_line(text: String) -> Nil

@external(erlang, "bomad_ffi", "repl_line")
fn repl_line() -> Result(String, Nil)

@external(erlang, "bomad_ffi", "halt_now")
fn halt(code: Int) -> Nil

@external(erlang, "bomad_ffi", "plain_args")
fn plain_args() -> List(String)
