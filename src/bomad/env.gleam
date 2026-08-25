//// Environment scopes. A scope is just an id into the ffi store plus its
//// parent's id, so a closure can hold onto a scope while later bindings
//// keep appearing in it, exactly like the mutable hash tables of the
//// original.

import bomad/err.{type NomadErr}
import bomad/value.{type Value}
import gleam/list
import gleam/string

pub type ScopeId =
  Int

pub const no_parent = -1

pub fn new(parent: ScopeId) -> ScopeId {
  ffi_scope_new(parent)
}

pub fn get(scope: ScopeId, key: String) -> Result(Value, NomadErr) {
  case ffi_scope_get(scope, key) {
    Ok(v) -> Ok(v)
    Error(Nil) -> Error(err.eval("No such variable: " <> key))
  }
}

pub fn set(scope: ScopeId, key: String, value: Value) -> Result(Nil, NomadErr) {
  case ffi_scope_set(scope, key, value) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) ->
      Error(err.eval("Cannot bind " <> key <> ": Already exists in this scope"))
  }
}

pub fn mutate(scope: ScopeId, key: String, value: Value) -> Result(Nil, NomadErr) {
  case ffi_scope_mutate(scope, key, value) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) ->
      Error(err.eval("Cannot mutate non-existant binding: " <> key))
  }
}

// sorted so print_env output is deterministic; the original walks a
// hashtable in whatever order it feels like
pub fn locals_sorted(scope: ScopeId) -> List(#(String, Value)) {
  list.sort(ffi_scope_locals(scope), fn(a, b) { string.compare(a.0, b.0) })
}

@external(erlang, "bomad_ffi", "scope_new")
fn ffi_scope_new(parent: ScopeId) -> ScopeId

@external(erlang, "bomad_ffi", "scope_get")
fn ffi_scope_get(scope: ScopeId, key: String) -> Result(Value, Nil)

@external(erlang, "bomad_ffi", "scope_set")
fn ffi_scope_set(scope: ScopeId, key: String, value: Value) -> Result(Nil, Nil)

@external(erlang, "bomad_ffi", "scope_mutate")
fn ffi_scope_mutate(scope: ScopeId, key: String, value: Value) -> Result(Nil, Nil)

@external(erlang, "bomad_ffi", "scope_locals")
fn ffi_scope_locals(scope: ScopeId) -> List(#(String, Value))
