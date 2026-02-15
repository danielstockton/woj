;; Example: Persistent Vectors in woj
;; 32-way branching trie with tail optimization

;; Create a simple vector
(def v (vector 10 20 30))

;; Get element count (should be 3)
(defn test-count []
  (count v))

;; Get element at index (should be 20)
(defn test-nth []
  (nth v 1))

;; Get first element (should be 10)
(defn test-first []
  (nth v 0))

;; Get last element (should be 30)
(defn test-last []
  (nth v 2))

;; Conj adds to end - new vector has 4 elements
(defn test-conj []
  (count (conj v 40)))

;; Assoc updates at index - should return 99
(defn test-assoc []
  (nth (assoc v 1 99) 1))

;; Check vector? predicate (should be 1/true)
(defn test-vector? []
  (vector? v))

;; Empty vector has count 0
(defn test-empty []
  (count (vector)))

;; Build larger vector with loop
(defn build-large []
  (loop [vec (vector)
         i 0]
    (if (< i 100)
      (recur (conj vec i) (+ i 1))
      (count vec))))

;; Sum elements using loop
(defn sum-vec []
  (loop [i 0
         sum 0]
    (if (< i (count v))
      (recur (+ i 1) (+ sum (nth v i)))
      sum)))
