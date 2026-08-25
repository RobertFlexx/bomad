#!/usr/bin/env nomad
(letfun make_person (name age job) 
  (record 
    (name name)
    (age age)
    (job job)))

(letfun print_person_info (person)
  (do
    (let n (. person name))
    (let a (. person age))
    (let j (. person job))
    (println n " is " a " years old and works as a/an " j)))

(let people
  (list
    (make_person "John Doe" 22 "Electrician")
    (make_person "Jane Doe" 21 "Plumber")
    (make_person "Max Mustermann" 25 "Secretary")
    (make_person "Erika Mustermann" 20 "Developer")))

(foreach print_person_info people)
