#!/usr/bin/env nomad
(letfun loop (files)
  (if (isunit (cdr files))
    unit
    (try
      (println (read_file (car files)))
      (do
        (println "Couldn't read " (car files))
        (exit 1)))))

(if (= (len args) 1)
  (do
    (println "Usage: cat <files...>")
    (exit 1))

  (loop (cdr args)))
