#!/usr/bin/env nomad
(letfun lowtrim (s) 
  (trim (lower s)))

(letfun input_loop (correct_answer prompt)
  (if (= (lowtrim correct_answer) (lowtrim (readln prompt)))
    (println "Correct!")
    (do 
      (println "False!\nTry again!")
      (input_loop correct_answer prompt))))

(input_loop "Berlin" "What is the capital of Germany? ")
(input_loop "21" "What's 9 + 10? ")
(input_loop "OCaml" "What language is Nomad-LISP written in? ")
(println "All questions answered correctly!")
