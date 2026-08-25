#!/usr/bin/env nomad
(letfun print_list (l)
  (do
    (letfun aux (h t i)
      (if (isunit t)
        unit
        (do
          (println i ": " h)
          (aux (car t) (cdr t) (+ i 1)))))
        
    (aux (car l) (cdr l) 0)))

(let my_list (list 1 2 3 4 5 6 7 8 9 10))
(print_list my_list)
