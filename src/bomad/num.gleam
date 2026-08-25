//// Numbers. Scripts only ever see one numeric type, an f64, but the beam
//// refuses to hold non-finite floats at all: arithmetic that would
//// overflow raises badarith instead of sliding to inf, and nothing can
//// materialise nan. The original language is OCaml where floats are plain
//// IEEE doubles, so scripts can legitimately write 1e308 * 10 and read
//// back infinity. We therefore carry numbers around as an Ext that makes
//// non-finite values explicit and route every operation through total
//// helpers, matching f64 semantics.

import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/string

/// A script-level number. Finite wraps a beam float; the other three stand
/// in for values the vm cannot represent directly.
pub type Ext {
  Finite(Float)
  Inf
  NegInf
  Nan
}

pub fn of(f: Float) -> Ext {
  Finite(f)
}

pub fn of_int(i: Int) -> Ext {
  Finite(int.to_float(i))
}

/// True for 0.0 and -0.0 alike. A `Finite(0.0)` pattern would miss the
/// negative one because erlang pattern matching separates sign bits.
pub fn is_zero(n: Ext) -> Bool {
  case n {
    Finite(f) -> ffi_is_zero(f)
    _ -> False
  }
}

fn is_sign_negative_of(n: Ext) -> Bool {
  case n {
    Inf -> False
    NegInf -> True
    Nan -> False
    Finite(f) -> ffi_is_sign_negative(f)
  }
}

@external(erlang, "bomad_ffi", "num_is_zero")
fn ffi_is_zero(f: Float) -> Bool

@external(erlang, "bomad_ffi", "is_sign_negative")
fn ffi_is_sign_negative(f: Float) -> Bool

/// Builds a zero or infinite result whose magnitude is already settled;
/// the sign comes from xoring the operands' sign bits, which is what IEEE
/// prescribes there.
fn signed_edge(a: Ext, b: Ext, magnitude_infinite: Bool) -> Ext {
  let negative = is_sign_negative_of(a) != is_sign_negative_of(b)
  case magnitude_infinite, negative {
    True, True -> NegInf
    True, False -> Inf
    False, True -> Finite(-1.0 *. 0.0)
    False, False -> Finite(0.0)
  }
}

// ------------------------------------------------------------------ total ops

pub fn add(a: Ext, b: Ext) -> Ext {
  case a, b {
    Nan, _ | _, Nan -> Nan
    // inf + -inf is the one addition with no defined magnitude
    Inf, NegInf | NegInf, Inf -> Nan
    Inf, _ | _, Inf -> Inf
    NegInf, _ | _, NegInf -> NegInf
    Finite(x), Finite(y) -> ffi_add(x, y)
  }
}

pub fn sub(a: Ext, b: Ext) -> Ext {
  // negating a finite float is exact and the -0 corners wash out through
  // addition's own sign rules, so a + (-b) really is ieee a-b
  add(a, negate(b))
}

pub fn negate(a: Ext) -> Ext {
  case a {
    Finite(f) -> Finite(0.0 -. f)
    Inf -> NegInf
    NegInf -> Inf
    Nan -> Nan
  }
}

pub fn mul(a: Ext, b: Ext) -> Ext {
  case is_zero(a) || is_zero(b) {
    True -> zero_mul(a, b)
    False -> mul_nonzero(a, b)
  }
}

fn zero_mul(a: Ext, b: Ext) -> Ext {
  case a, b {
    Nan, _ | _, Nan -> Nan
    // zero times infinity is nan whatever the signs; plain f64 math gives
    // you that for free, here it needs spelling out
    _, Inf | _, NegInf | Inf, _ | NegInf, _ -> Nan
    // zeros times finites multiply out normally, sign bit included
    // (note -0.0 * -1.0 is 0.0, not another negative zero)
    Finite(x), Finite(y) -> ffi_mul(x, y)
  }
}

fn mul_nonzero(a: Ext, b: Ext) -> Ext {
  case a, b {
    Nan, _ | _, Nan -> Nan
    Inf, Inf | NegInf, NegInf -> Inf
    Inf, NegInf | NegInf, Inf -> NegInf
    // inf * finite keeps its magnitude and flips on the finite side's sign
    Inf, _ | _, Inf | NegInf, _ | _, NegInf -> signed_edge(a, b, True)
    Finite(x), Finite(y) -> ffi_mul(x, y)
  }
}

pub fn div(a: Ext, b: Ext) -> Ext {
  div_by(a, b, is_zero(b))
}

fn div_by(a: Ext, b: Ext, b_zero: Bool) -> Ext {
  case a, b, b_zero {
    Nan, _, _ | _, Nan, _ -> Nan
    Inf, Inf, _ | NegInf, NegInf, _ | Inf, NegInf, _ | NegInf, Inf, _ -> Nan
    // zero denominator always yields infinity, signed by both sides. the
    // language's / rejects those before we ever get here, this just keeps
    // the helper total like raw f64 division would be
    _, _, True -> signed_edge(a, b, True)
    // infinite numerator over finite value takes the quotient sign
    Inf, _, _ | NegInf, _, _ -> signed_edge(a, b, True)
    // finite over infinity collapses to a signed zero
    _, Inf, _ | _, NegInf, _ -> signed_edge(a, b, False)
    Finite(x), Finite(y), _ -> ffi_div(x, y)
  }
}

/// IEEE remainder, what `%` does on f64. The language's `/` errors on a
/// zero divisor long before reaching here; mod is allowed to produce nan.
pub fn fmod(a: Ext, b: Ext) -> Ext {
  case a, b, is_zero(b) {
    Nan, _, _ | _, Nan, _ -> Nan
    // remainder of an infinite dividend is undefined
    Inf, _, _ | NegInf, _, _ -> Nan
    // finite mod anything infinite is itself
    _, Inf, _ | _, NegInf, _ -> a
    // the ffi catch maps a mod-zero trap to nan already, but -0.0 slips
    // past a Finite(0.0) pattern so test it explicitly
    _, _, True -> Nan
    Finite(x), Finite(y), _ -> ffi_fmod(x, y)
  }
}

/// power of two used by the hex-float parser. saturates to inf/0 instead
/// of trapping, like rust's powi does.
fn power_of_two(exp: Int) -> Ext {
  ffi_pow2(exp)
}

// ------------------------------------------------------------------ comparisons

/// total order over finite values plus infinities. Error means unordered,
/// which happens exactly when either side is nan, mirroring how every f64
/// comparison involving nan is false.
pub fn cmp(a: Ext, b: Ext) -> Result(order.Order, Nil) {
  case a, b {
    Nan, _ | _, Nan -> Error(Nil)
    Inf, Inf | NegInf, NegInf -> Ok(order.Eq)
    Inf, _ | _, NegInf -> Ok(order.Gt)
    NegInf, _ | _, Inf -> Ok(order.Lt)
    Finite(x), Finite(y) -> Ok(float.compare(x, y))
  }
}

pub fn eq(a: Ext, b: Ext) -> Bool {
  cmp(a, b) == Ok(order.Eq)
}

pub fn lt(a: Ext, b: Ext) -> Bool {
  cmp(a, b) == Ok(order.Lt)
}

pub fn gt(a: Ext, b: Ext) -> Bool {
  cmp(a, b) == Ok(order.Gt)
}

pub fn le(a: Ext, b: Ext) -> Bool {
  case cmp(a, b) {
    Ok(order.Lt) | Ok(order.Eq) -> True
    _ -> False
  }
}

pub fn ge(a: Ext, b: Ext) -> Bool {
  case cmp(a, b) {
    Ok(order.Gt) | Ok(order.Eq) -> True
    _ -> False
  }
}

// ------------------------------------------------------------------ conversions

/// truncation toward zero with `as i64` saturation rules: nan goes to 0,
/// infinities and oversized finites clamp to the i64 bounds.
pub fn to_i64_saturating(a: Ext) -> Int {
  case a {
    Nan -> 0
    Inf -> 9_223_372_036_854_775_807
    NegInf -> -9_223_372_036_854_775_808
    Finite(f) ->
      case f >=. 9_223_372_036_854_775_808.0 {
        True -> 9_223_372_036_854_775_807
        False ->
          case f <=. -9_223_372_036_854_775_808.0 {
            True -> -9_223_372_036_854_775_808
            False -> float.truncate(f)
          }
      }
  }
}

// ------------------------------------------------------------------ formatting

pub fn format(n: Ext) -> String {
  case n {
    Nan -> "nan"
    Inf -> "inf"
    NegInf -> "-inf"
    Finite(f) -> format_finite(f)
  }
}

// whole numbers print without decimals, but only while they still fit an
// i64; past that we fall back to two decimals like the original does
fn format_finite(f: Float) -> String {
  let whole =
    f -. int.to_float(float.truncate(f)) == 0.0
    && f <. 9_223_372_036_854_775_808.0
    && f >. -9_223_372_036_854_775_808.0

  case whole {
    True -> int_string(float.truncate(f))
    False -> fixed2(f)
  }
}

@external(erlang, "bomad_ffi", "fmt_fixed")
fn fmt_fixed_raw(f: Float, decimals: Int) -> String

fn fixed2(f: Float) -> String {
  fmt_fixed_raw(f, 2)
}

@external(erlang, "erlang", "integer_to_binary")
fn int_string(i: Int) -> String

// ------------------------------------------------------------------ parsing

/// accepts everything f64 parsing takes (decimal shapes including "5." and
/// ".5", the inf/nan spellings, underscores) plus the hex-float form
/// 0x1p-3 that the original language allows.
pub fn parse_nomad_float(text: String) -> Result(Ext, Nil) {
  let s = string.replace(text, "_", "")
  case parse_decimal(s) {
    Ok(n) -> Ok(n)
    Error(Nil) -> parse_spelling(s)
  }
}

fn parse_decimal(s: String) -> Result(Ext, Nil) {
  case s {
    "" -> Error(Nil)
    _ ->
      case float.parse(s) {
        Ok(n) -> Ok(Finite(n))
        Error(Nil) ->
          case int.parse(s) {
            Ok(i) -> Ok(Finite(int.to_float(i)))
            Error(Nil) ->
              case pad_bare_dot(s) {
                Ok(padded) ->
                  case float.parse(padded) {
                    Ok(n) -> Ok(Finite(n))
                    Error(Nil) -> parse_hex(s)
                  }
                Error(Nil) -> parse_hex(s)
              }
          }
      }
  }
}

// the float grammar allows "5.", ".5" and even "5.e2"; erlang wants a
// digit on both sides of the dot. pads only when the text is decimal
// shaped, anything else stays untouched for the hex fallback
fn pad_bare_dot(s: String) -> Result(String, Nil) {
  let #(sign, body) = case string.starts_with(s, "-") {
    True -> #("-", string.drop_start(s, 1))
    False ->
      case string.starts_with(s, "+") {
        True -> #("+", string.drop_start(s, 1))
        False -> #("", s)
      }
  }
  let #(mantissa, exponent) = case string.split_once(body, "e") {
    Ok(#(m, e)) ->
      case string.contains(e, "e") {
        True -> #(body, "")
        False -> #(m, "e" <> e)
      }
    Error(Nil) ->
      case string.split_once(body, "E") {
        Ok(#(m, e)) ->
          case string.contains(e, "E") {
            True -> #(body, "")
            False -> #(m, "E" <> e)
          }
        Error(Nil) -> #(body, "")
      }
  }
  case string.split(mantissa, ".") {
    [whole, frac] ->
      case digits_only(whole) && digits_only(frac) {
        True -> {
          let w = case whole {
            "" -> "0"
            _ -> whole
          }
          let f = case frac {
            "" -> "0"
            _ -> frac
          }
          case mantissa == "" {
            True -> Error(Nil)
            False -> Ok(sign <> w <> "." <> f <> exponent)
          }
        }
        False -> Error(Nil)
      }
    // no dot at all: "1e18" style, erlang still refuses these without .0
    [whole] ->
      case whole != "" && digits_only(whole) {
        True -> Ok(sign <> whole <> ".0" <> exponent)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn digits_only(s: String) -> Bool {
  s
  |> string.to_graphemes
  |> list.all(is_digit_g)
}

fn is_digit_g(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn parse_spelling(s: String) -> Result(Ext, Nil) {
  case string.lowercase(s) {
    "nan" | "+nan" | "-nan" -> Ok(Nan)
    "inf" | "+inf" | "infinity" | "+infinity" -> Ok(Inf)
    "-inf" | "-infinity" -> Ok(NegInf)
    _ -> Error(Nil)
  }
}

fn parse_hex(s: String) -> Result(Ext, Nil) {
  let #(negative, body) = case string.starts_with(s, "-") {
    True -> #(True, string.drop_start(s, 1))
    False ->
      case string.starts_with(s, "+") {
        True -> #(False, string.drop_start(s, 1))
        False -> #(False, s)
      }
  }

  let prefix_ok =
    string.starts_with(body, "0x") || string.starts_with(body, "0X")

  case prefix_ok {
    False -> Error(Nil)
    True -> {
      let rest = string.drop_start(body, 2)
      case split_p_exp(rest) {
        Ok(#(mantissa_s, exp)) ->
          case hex_mantissa(mantissa_s) {
            Ok(value) -> {
              let n = mul(Finite(value), power_of_two(exp))
              case negative {
                True -> Ok(negate(n))
                False -> Ok(n)
              }
            }
            Error(Nil) -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn split_p_exp(rest: String) -> Result(#(String, Int), Nil) {
  let lower = string.split_once(rest, "p")
  let upper = string.split_once(rest, "P")
  case lower, upper {
    Ok(#(m, e)), _ -> parse_exp(m, e)
    _, Ok(#(m, e)) -> parse_exp(m, e)
    _, _ -> Ok(#(rest, 0))
  }
}

fn parse_exp(m: String, e: String) -> Result(#(String, Int), Nil) {
  case int.parse(e) {
    Ok(i) -> Ok(#(m, i))
    Error(Nil) -> Error(Nil)
  }
}

fn hex_mantissa(m: String) -> Result(Float, Nil) {
  case string.split_once(m, ".") {
    Ok(#(int_part, frac_part)) ->
      case int_part == "" && frac_part == "" {
        True -> Error(Nil)
        False ->
          case hex_digits(string.to_graphemes(int_part), 0.0) {
            Ok(whole) ->
              hex_frac(string.to_graphemes(frac_part), whole, 1.0 /. 16.0)
            Error(Nil) -> Error(Nil)
          }
      }
    Error(Nil) -> hex_digits(string.to_graphemes(m), 0.0)
  }
}

fn hex_digits(chars: List(String), acc: Float) -> Result(Float, Nil) {
  case chars {
    [] -> Ok(acc)
    [c, ..rest] ->
      case hex_digit_value(c) {
        Ok(d) -> hex_digits(rest, acc *. 16.0 +. int.to_float(d))
        Error(Nil) -> Error(Nil)
      }
  }
}

fn hex_frac(chars: List(String), acc: Float, scale: Float) -> Result(Float, Nil) {
  case chars {
    [] -> Ok(acc)
    [c, ..rest] ->
      case hex_digit_value(c) {
        Ok(d) -> hex_frac(rest, acc +. int.to_float(d) *. scale, scale /. 16.0)
        Error(Nil) -> Error(Nil)
      }
  }
}

fn hex_digit_value(c: String) -> Result(Int, Nil) {
  case c {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    "a" | "A" -> Ok(10)
    "b" | "B" -> Ok(11)
    "c" | "C" -> Ok(12)
    "d" | "D" -> Ok(13)
    "e" | "E" -> Ok(14)
    "f" | "F" -> Ok(15)
    _ -> Error(Nil)
  }
}

// ------------------------------------------------------------------ ffi

// these run only on finite operands. a badarith trap is always a genuine
// magnitude overflow, so translating it by sign is exact: no rounding
// ambiguity once the operation refused to complete.

@external(erlang, "bomad_ffi", "num_add")
fn ffi_add(x: Float, y: Float) -> Ext

@external(erlang, "bomad_ffi", "num_mul")
fn ffi_mul(x: Float, y: Float) -> Ext

@external(erlang, "bomad_ffi", "num_div")
fn ffi_div(x: Float, y: Float) -> Ext

@external(erlang, "bomad_ffi", "num_fmod")
fn ffi_fmod(x: Float, y: Float) -> Ext

@external(erlang, "bomad_ffi", "num_pow2")
fn ffi_pow2(exp: Int) -> Ext
