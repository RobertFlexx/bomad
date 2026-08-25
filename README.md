# bomad

A robust, embeddable **Gleam** implementation of
[nomad-lisp](https://github.com/Moritisimor/nomad-lisp), a small, dynamically
typed Lisp dialect originally written in OCaml.

bomad behaves like the original interpreter: same syntax, same standard
library, same diagnostics. while exposing a first class embedding API for
Gleam and Erlang hosts. It tracks the Rust port
([romad](https://github.com/RobertFlexx/romad)) fix for fix.

also see [gomad](https://github.com/Moritisimor/gomad) for the native Go implementation, and embedding API for Go

## Building

```bash
gleam build
gleam run                      # starts the REPL
```

## Usage

Identical to the original `nomad` binary:

```bash
gleam run                      # REPL mode
gleam run -- -e '(+ 1 2)'      # evaluate an expression  => 3
gleam run -- my_script.nomad   # run a script
```

`gleam export erlang-shipment` produces a standalone binary that takes the
exact same arguments as the original `nomad` executable.

Try it:

```lisp
(+ (* 10 5) (- 1000 250))

(letfun fib (n)
  (switch n
    (0 0)
    (1 1)
    (_ (+ (fib (dec n)) (fib (- n 2))))))

(println (fib 20))
```

See the upstream documentation under `docs/` in the nomad-lisp repo and
sample programs in `examples/` (carried over from nomad-lisp).

## Embedding

Add `bomad` to your `gleam.toml`, then:

```gleam
import bomad/env
import bomad/err
import bomad/eval
import bomad/interp
import bomad/num
import bomad/parser
import bomad/value

pub fn main() {
  // A fresh interpreter ships with all natives + the stdlib preloaded.
  let interpreter = interp.new()

  // Evaluate source code; get the last value back.
  let assert Ok(value.Lst(squares)) =
    interp.do_string(interpreter, "(map (lambda (x) (* x x)) (list 1 2 3))")

  // Script arguments are bound to the `args` list variable.
  let scripted = interp.with_args(["my_app", "--flag"])

  // Extend the language from the host. Natives receive unevaluated
  // expressions + the calling scope, so special forms are possible;
  // ordinary functions just evaluate their arguments first.
  let assert Ok(_) =
    interp.register_native(scripted, "square", fn(args, scope) {
      case args {
        [x] ->
          case eval.eval(x, scope) {
            Ok(value.Num(n)) -> Ok(value.Num(num.mul(n, n)))
            _ -> Error(err.eval("square wants a number")),
          }
        _ -> Error(err.eval("square wants 1 arg")),
      }
    })

  // Direct environment access, single-expression evaluation, files:
  let assert Ok(_) =
    env.set(interp.global_env(scripted), "answer", value.Num(num.of(42.0)))
  let assert Ok(answer) = parser.parse_one("answer")
  let assert Ok(value.Num(num.Finite(42.0))) =
    eval.eval(answer, interp.global_env(scripted))
  let assert Ok(_) = interp.do_file(interpreter, "examples/map.nomad")

  Nil
}
```

### Error handling for hosts

* All failures surface as a `NomadErr` (`ParseErr`, `TokenizeErr`,
  `EvalErr`, `IoErr`). The evaluator never crashes on bad scripts.
* `(exit n)` / `(bye)` return a recoverable `ExitSig(n)` signal so embedded
  runtimes can shut down cleanly. The CLI maps this to a real process exit,
  preserving original behaviour.

### Working with values

Lists are persistent singly-linked structures with O(1) `car`/`cdr`/`cons`
(structural sharing, like OCaml's lists). Hosts iterate without copying:

```gleam
let assert Ok(v) =
  interp.do_string(interp.new(), "(map (lambda (x) (* x x)) (list 1 2 3))")
let assert value.Lst(items) = v
// items holds three shared cells; no copying happened
```

## Architecture notes

* **Persistent lists**: values are immutable singly-linked cells with
  structural sharing, so cloning a value is a pointer copy and recursion
  depth no longer multiplies memory.
* **Environments** are chained scopes holding shared values; lookups walk
  parents exactly like the original. Mutable scopes live behind integer ids
  backed by the Erlang process dictionary, which is sound because the
  language has no concurrency primitives and everything runs synchronously
  in the caller's process.
* **Natives** receive unevaluated expressions plus the calling scope, so
  hosts can define special forms (`if`, `switch`, ...).
* **Tail calls stay flat** (`eval.gleam`): the beam does last-call
  optimisation by itself, so self-recursive functions in tail position run
  in constant stack space, matching OCaml 5 whose compiler/runtime does the
  same. The five core forms (`if`, `do`, `switch`, `scoped`, `try`) keep
  their bodies in tail position and are recognised by native identity, so
  rebinding e.g. `if` transparently restores ordinary native semantics.
* **Non-finite numbers**: the beam refuses to hold inf/nan floats at all,
  arithmetic that would overflow raises instead of sliding to infinity.
  bomad carries numbers in an extension type that makes non-finite values
  explicit and routes every operation through total helpers, so scripts can
  write `1e308 * 10` and read back `inf`, down to signed zeros:
  `(* -0.0 inf)` is `nan` and `/` rejects `-0.0` divisors.
* **`try` uses a handler stack**: entering a `try` pushes its handler
  continuation and evaluation proceeds into the body; recoverable errors
  surface at the step that produced them and resume at the innermost
  handler. Exit requests stay uncatchable and propagate to the host.
* Evaluation runs on the caller's process; there is no small default
  stack to grow, so deeply non-tail recursive scripts are limited only by
  beam heap, not a fixed stack size.

## Bug fixes relative to nomad-lisp

Behaviour is identical for valid programs; the following defects were fixed,
the same list the Rust port addresses:

| # | Original behaviour | bomad |
|---|--------------------|-------|
| 1 | `isrecord` tested for bools, so records reported `"unknown"` type | records recognised correctly |
| 2 | Tokenizer split words containing `true`/`false`/`unit` (`truest` -> `true` `st`) | keyword boundaries enforced |
| 3 | `>=` / `<=` used OCaml polymorphic compare on raw values | proper numeric comparison |
| 4 | Numbers/symbols hitting EOF without a delimiter were errors (scripts needed trailing whitespace) | EOF is an implicit terminator |
| 5 | `(= unit unit)` returned `false` (equality fall-through) | units compare equal |
| 6 | `(exit n)` / `(bye)` killed the whole process, even inside `try` | controlled exit signal, uncatchable by `try` |
| 7 | `readln` crashed with an uncaught exception on EOF | EOF raises a catchable evaluation error |
| 8 | `chars` iterated bytes, mangling UTF-8 | Unicode characters |
| 9 | Inconsistent arity-error names (`isnative` reported by `ismac`, ...) | kept byte-identical for diagnostic compatibility |
| 10 | `read_dir` order was arbitrary | deterministic, sorted |
| 11 | `do_string` kept evaluating top-level forms after an error, silently discarding it, and only returned the last form's result | evaluation stops at the first error |
| 12 | CRLF scripts leaked `\r` into symbols (`println\r`) | `\r` treated as whitespace |

## Layout

```
src/
├── bomad.gleam          CLI (repl / -e / script / help)
├── bomad/err.gleam      NomadErr types (Parse/Tokenize/Eval/Io/Exit)
├── bomad/expr.gleam     AST + display (error-message compatible)
├── bomad/token.gleam    tokenizer
├── bomad/parser.gleam   recursive-descent parser
├── bomad/num.gleam      total f64 semantics over the beam's finite-only floats
├── bomad/value.gleam    runtime values + lexical environments
├── bomad/env.gleam      environment ids and lookups
├── bomad/eval.gleam     evaluator: TCO trampoline, closures, macros
├── bomad/natives*.gleam builtin functions (core + system/fs)
├── bomad/stdlib.gleam   embedded nomad standard library sources
└── bomad/interp.gleam   embedding API (Interp)
src/bomad_ffi.erl       thin erlang shims: id store, exec, float helpers
test/                   language + runtime conformance tests
examples/               nomad-lisp example programs
```

## Testing

```bash
gleam test
```

The suite covers tokenizer/parser edge cases, closures & macros, records,
the full standard library, number formatting, exit signalling and the
embedding API, mirroring the other implementations' tests plus a few
beam-specific regression tests for signed zeros and aliased core forms.

MIT licensed, same as nomad-lisp.
