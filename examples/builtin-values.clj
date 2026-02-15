;; Test builtins as first-class values

;; Test 1: map with inc
(defn test-map-inc []
  (first (map inc (list 1 2 3))))  ;; Should return 2

;; Test 2: reduce with +
(defn test-reduce-plus []
  (reduce + 0 (list 1 2 3)))  ;; Should return 6

;; Test 3: filter with pos?
(defn test-filter-pos []
  (first (filter pos? (list -1 0 5 -3 2))))  ;; Should return 5

;; Test 4: map with dec
(defn test-map-dec []
  (first (map dec (list 10 20 30))))  ;; Should return 9

;; Test 5: reduce with *
(defn test-reduce-times []
  (reduce * 1 (list 2 3 4)))  ;; Should return 24
