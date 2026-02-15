;; Vector Sum - tests vector iteration and access
(defn build-vector [n]
  (loop [i 0 v (vector)]
    (if (>= i n)
      v
      (recur (inc i) (conj v i)))))

(defn sum-vector [v]
  (let [n (count v)]
    (loop [i 0 acc 0]
      (if (>= i n)
        acc
        (recur (inc i) (+ acc (nth v i)))))))

;; Run 1000 iterations internally to amortize startup overhead
;; Build vector once, then sum it 1000 times
(defn bench-vector-sum []
  (let [v (build-vector 1000)]
    (loop [i 0 result 0]
      (if (>= i 1000)
        result
        (recur (inc i) (sum-vector v))))))
