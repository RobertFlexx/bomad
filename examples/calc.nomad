#!/usr/bin/env nomad
(letfun input_loop ()
  (do
    (try
      (let x (string_to_num (readln "Enter x: ")))
    (do
      (println "Could not parse x!")
      (input_loop)))

    (try
      (let y (string_to_num (readln "Enter y: ")))
    (do
      (println "Could not parse y!")
      (input_loop)))

    (let op (readln "Enter operator: "))
    (println
      (switch op
        ("+" (+ x y))
        ("-" (- x y))
        ("*" (* x y))
        ("/" (if (= y 0)
          "Cannot divide by zero!"
          (/ x y)))
          
        (_ "Unknown operator!")))
          
    (input_loop)))

(println "Ctrl + C to exit!")
(input_loop)
