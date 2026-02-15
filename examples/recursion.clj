;; Recursive function examples

(defn factorial [n]
  (if (<= n 1)
    1
    (* n (factorial (- n 1)))))

(defn test-factorial []
  (factorial 5))  ;; => 120

;; Sum of a list using recursion
(defn sum-list [lst]
  (if (nil? lst)
    0
    (+ (first lst) (sum-list (rest lst)))))

(defn test-sum []
  (sum-list (list 1 2 3 4 5)))  ;; => 15

;; Length of a list
(defn length [lst]
  (if (nil? lst)
    0
    (+ 1 (length (rest lst)))))

(defn test-length []
  (length (list 1 2 3 4)))  ;; => 4
