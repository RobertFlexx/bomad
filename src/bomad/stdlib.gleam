//// The nomad-side standard library, loaded verbatim at startup.
//// Kept in sync with the original's stdlib.ml / stdlib.rs, don't
//// "improve" these, scripts depend on them.

pub const stdlib_src: List(String) = [
  "(letfun not (a) (if a false true))",
  "(letfun inc (i) (+ i 1))",
  "(letfun dec (i) (- i 1))",
  "(letmac unless (cond yes no) if (not cond) yes no)",
  "(letmac when (cond body) if cond body unit)",
  "(letmac != (lhs rhs) not (= lhs rhs))",
  "\n    (letfun typeof (expr)\n      (switch true\n        ((isstr expr) \"string\")\n        ((isnum expr) \"number\")\n        ((isbool expr) \"bool\")\n        ((islist expr) \"list\")\n        ((isrecord expr) \"record\")\n        ((isfun expr) \"function\")\n        ((isnative expr) \"native\")\n        ((isunit expr) \"unit\")\n        ((ismac expr) \"macro\")\n        (_ \"unknown\")))\n    ",
  "\n    (letfun foldl (f acc l)\n      (do\n        (letfun aux (a h t)\n          (if (isunit t)\n            a\n            (aux (f a h) (car t) (cdr t))))\n\n      (aux acc (car l) (cdr l))))\n    ",
  "\n    (letfun begins_with (l1 l2)\n      (if (< (len l1) (len l2))\n        false\n        (do\n          (letfun aux (l1h l1t l2h l2t)\n            (if (isunit l2t)\n              true\n              (if (= l1h l2h)\n                (aux (car l1t) (cdr l1t) (car l2t) (cdr l2t))\n                false)))\n\n          (aux (car l1) (cdr l1) (car l2) (cdr l2)))))\n    ",
  "(letfun ends_with (l1 l2) (begins_with (rev l1) (rev l2)))",
  "(letfun has_prefix (s1 s2) (begins_with (chars s1) (chars s2)))",
  "(letfun has_suffix (s1 s2) (ends_with (chars s1) (chars s2)))",
  "\n    (letfun list_init (n f)\n      (do\n        (letfun aux (acc i)\n          (if (< i 0)\n            acc\n            (aux (cons (f i) acc) (dec i))))\n\n        (aux () (dec n))))\n    ",
  "\n    (letfun map (f l)\n      (do\n        (letfun aux (acc h t)\n          (if (isunit t)\n            (rev acc)\n            (aux (cons (f h) acc) (car t) (cdr t))))\n\n        (aux () (car l) (cdr l))))\n    ",
  "\n    (letfun mapi (f l)\n      (do\n        (letfun aux (acc h t i)\n          (if (isunit t)\n            (rev acc)\n            (aux (cons (f h i) acc) (car t) (cdr t) (inc i))))\n\n        (aux () (car l) (cdr l) 0)))\n    ",
  "\n    (letfun filter (f l)\n      (do\n        (letfun aux (acc h t)\n          (if (isunit t)\n            (rev acc)\n            (if (f h)\n              (aux (cons h acc) (car t) (cdr t))\n              (aux acc (car t) (cdr t)))))\n\n        (aux () (car l) (cdr l))))\n    ",
  "\n    (letfun rev (l)\n      (do\n        (letfun aux (acc h t)\n          (if (isunit t)\n            acc\n            (aux (cons h acc) (car t) (cdr t))))\n\n        (aux () (car l) (cdr l))))\n    ",
  "\n    (letfun len (l)\n      (do\n        (letfun aux (acc h t)\n          (if (isunit t)\n            acc\n            (aux (inc acc) (car t) (cdr t))))\n\n        (aux 0 (car l) (cdr l))))\n    ",
  "(letfun strlen (s) (len (chars s)))",
  "\n    (letfun foreach (f l)\n      (do\n        (letfun aux (h t)\n          (do\n            (if (isunit t)\n            unit\n            (do\n              (f h)\n              (aux (car t) (cdr t))))))\n\n        (aux (car l) (cdr l))))\n    ",
  "\n    (letfun foreachi (f l)\n      (do\n        (letfun aux (h t i)\n          (do\n            (if (isunit t)\n              unit\n              (do\n                (f h i)\n                (aux (car t) (cdr t) (inc i))))))\n\n        (aux (car l) (cdr l) 0)))\n    ",
  "\n    (letfun nth (l idx)\n      (do\n        (letfun aux (h t i)\n          (if (isunit t)\n            (throw \"List has no such index\")\n            (if (= i 0)\n              h\n              (aux (car t) (cdr t) (dec i)))))\n\n        (aux (car l) (cdr l) idx)))\n    ",
  "\n    (letfun nth_unit (l idx)\n      (do\n        (letfun aux (h t i)\n          (if (isunit t)\n            unit\n            (if (= i 0)\n              h\n              (aux (car t) (cdr t) (dec i)))))\n\n        (aux (car l) (cdr l) idx)))\n    ",
  "\n    (letfun range (start end list)\n      (do\n        (letfun aux (acc h t i)\n          (if (isunit t)\n            (rev acc)\n            (if (and (>= i start) (<= i end))\n              (aux (cons h acc) (car t) (cdr t) (inc i))\n              (aux acc (car t) (cdr t) (inc i)))))\n\n        (aux () (car list) (cdr list) 0)))\n    ",
]
