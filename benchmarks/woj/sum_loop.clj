;; Sum Loop - tests tail recursion optimization
;; Using 10000 to stay within i31ref range (max ~1 billion)
(defn sum-to [n]
  (loop [i 1 acc 0]
    (if (> i n)
      acc
      (recur (inc i) (+ acc i)))))

;; Run 10000 iterations internally to amortize startup overhead
(defn bench-sum-loop []
  (loop [i 0 result 0]
    (if (>= i 10000)
      result
      (recur (inc i) (sum-to 10000)))))
