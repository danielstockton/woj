;; examples/hello.clj
;; A simple woj program demonstrating basic features.

;; Define a function that doubles its argument
(def double (fn [x] (+ x x)))

;; Define a function that computes the square of a number
(def square (fn [x] (* x x)))

;; Use the double function
(def result (double 21))
;; result = 42
