(ns bench
  (:require [criterium.core :as crit]))

;; Fibonacci - tests function call overhead and recursion
(defn fib [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2)))))

;; Sum Loop - tests tail recursion optimization
(defn sum-to [n]
  (loop [i 1 acc 0]
    (if (> i n)
      acc
      (recur (inc i) (+ acc i)))))

;; Vector Build - tests persistent data structure creation
(defn build-vector [n]
  (loop [i 0 v []]
    (if (>= i n)
      v
      (recur (inc i) (conj v i)))))

;; Vector Sum - tests vector iteration and access
(defn sum-vector [v]
  (let [n (count v)]
    (loop [i 0 acc 0]
      (if (>= i n)
        acc
        (recur (inc i) (+ acc (nth v i)))))))

(defn run-benchmarks []
  (println "")
  (println "=== Fibonacci (fib 30) ===")
  (println "Expected result:" (fib 30))
  (crit/quick-bench (fib 30))

  (println "")
  (println "=== Sum Loop (sum 1..10000) ===")
  (println "Expected result:" (sum-to 10000))
  (crit/quick-bench (sum-to 10000))

  (println "")
  (println "=== Vector Build (1000 elements) ===")
  (println "Expected result:" (count (build-vector 1000)))
  (crit/quick-bench (build-vector 1000))

  (println "")
  (println "=== Vector Sum (1000 elements) ===")
  (let [v (build-vector 1000)]
    (println "Expected result:" (sum-vector v))
    (crit/quick-bench (sum-vector v))))

(defn -main [& args]
  (run-benchmarks))
