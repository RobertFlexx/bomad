#!/usr/bin/env nomad
(let add 
  (lambda (x)
    (lambda (y)
      (+ x y))))

(let add10 (add 10))
(let x (add10 20))
(println "x = " x)
(if (= x 30)
  (println "All good! Closures work as expected.")
  (println "Uh oh, Closures do not work as expected!"))
