#!/usr/bin/env nomad
(letfun count (start end)
  (if (< end start)
    (println "done!")
    (do 
      (println start) 
      (count (+ start 1) end))))

(let start 0)
(let end 10)
(count start end)
