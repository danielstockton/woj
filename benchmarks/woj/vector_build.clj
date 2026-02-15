;; Vector Build - tests persistent data structure creation
(defn build-vector [n]
  (loop [i 0 v (vector)]
    (if (>= i n)
      v
      (recur (inc i) (conj v i)))))

;; Run 1000 iterations internally to amortize startup overhead
(defn bench-vector-build []
  (loop [i 0 result 0]
    (if (>= i 1000)
      result
      (recur (inc i) (count (build-vector 1000))))))
