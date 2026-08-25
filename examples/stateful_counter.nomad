#!/usr/bin/env nomad
(letfun make_counter ()
  (do
    (let x 0)
    (letfun incr ()
      (do
        (mut x (+ x 1))
        x))

    (letfun decr ()
      (do
        (mut x (- x 1))
        x))

    (record
      (incr incr) 
      (decr decr))))

(let funs (make_counter))
(let incr (. funs incr))
(let decr (. funs decr))

(letfun input_loop ()
  (do
    (switch (readln "incr or decr? ")
      ("incr" (println "Counter is now at: " (incr)))
      ("decr" (println "Counter is now at: " (decr)))
      (_ (println "Unknown command! Only enter incr or decr!")))

    (input_loop)))

(println "Ctrl + C to exit!")
(input_loop)
