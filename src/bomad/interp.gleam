//// Interpreter assembly: a root scope, the native registries, the core
//// form bindings, then the stdlib. Registration order matters, first
//// binding of a name wins.

import bomad/env
import bomad/err.{type NomadErr}
import bomad/eval
import bomad/natives
import bomad/natives_os
import bomad/parser
import bomad/stdlib
import bomad/value.{type Value}
import gleam/list

pub type Interp {
  Interp(global: env.ScopeId)
}

/// A fresh interpreter with no script arguments.
pub fn new() -> Interp {
  with_args([])
}

/// The interpreter's root scope, for direct environment access from hosts.
pub fn global_env(interp: Interp) -> env.ScopeId {
  interp.global
}

/// Teach the interpreter a new native function. Natives receive
/// unevaluated expressions plus the calling scope, so hosts can define
/// special forms; ordinary functions just evaluate their arguments first.
pub fn register_native(
  interp: Interp,
  name: String,
  impl: value.NativeImpl,
) -> Result(Nil, NomadErr) {
  env.set(interp.global, name, value.Nat(fresh_id(), impl))
}

pub fn with_args(args: List(String)) -> Interp {
  init_store()
  let global = env.new(env.no_parent)

  let _ = env.set(global, "args", value.Lst(list.map(args, value.Str)))

  list.append(natives.core_natives(), natives_os.os_natives())
  |> list.each(fn(pair) {
    let #(name, impl) = pair
    let _ = env.set(global, name, value.Nat(fresh_id(), impl))
  })

  // must be the registry's own ids, not fresh ones, or the evaluator
  // wouldn't recognise these as core forms
  list.each(natives.core_form_bindings(), fn(triple) {
    let #(name, id, impl) = triple
    let _ = env.set(global, name, value.Nat(id, impl))
  })

  load_stdlib(global)
  Interp(global)
}

pub fn do_string(interp: Interp, source: String) -> Result(Value, NomadErr) {
  case parser.parse_program(source) {
    Ok(forms) -> eval.eval_seq(forms, interp.global)
    Error(e) -> Error(e)
  }
}

pub fn do_file(interp: Interp, path: String) -> Result(Nil, NomadErr) {
  case read_source(path) {
    Error(reason) -> Error(err.IoErr(reason))
    Ok(source) ->
      case parser.parse_program(source) {
        Error(e) -> Error(e)
        Ok(forms) ->
          case eval.eval_seq(forms, interp.global) {
            Ok(_) -> Ok(Nil)
            Error(e) -> Error(e)
          }
      }
  }
}

fn load_stdlib(scope: env.ScopeId) -> Nil {
  list.each(stdlib.stdlib_src, fn(source) {
    let assert Ok(forms) = parser.parse_program(source)
    let assert Ok(_) = eval.eval_seq(forms, scope)
  })
}

@external(erlang, "bomad_ffi", "init_store")
fn init_store() -> Nil

@external(erlang, "bomad_ffi", "fresh_id")
fn fresh_id() -> Int

@external(erlang, "bomad_ffi", "read_file")
fn read_source(path: String) -> Result(String, String)
