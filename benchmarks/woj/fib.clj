;; Fibonacci - tests function call overhead and recursion
(defn fib [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2)))))

;; Run 100 iterations internally to amortize startup overhead
(defn bench-fib []
  (loop [i 0 result 0]
    (if (>= i 100)
      result
      (recur (inc i) (fib 30)))))
