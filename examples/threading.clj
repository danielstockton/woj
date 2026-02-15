;; Threading macro and variadic assoc examples

;; Test -> threading macro
(defn test-thread-first []
  (-> 1
      (+ 2)      ;; 3
      (* 3)))    ;; 9

;; Test with hash-maps
(defn test-thread-map []
  (let [m (hash-map :a 1)]
    (-> m
        (assoc :b 2)
        (assoc :c 3)
        (get :c))))  ;; => 3

;; Test variadic assoc
(defn test-variadic-assoc []
  (let [m (hash-map :a 1)]
    (get (assoc m :b 2 :c 3 :d 4) :d)))  ;; => 4

;; Test ->> threading macro
(defn test-thread-last []
  (->> (list 1 2 3)
       (cons 0)      ;; (0 1 2 3)
       first))       ;; => 0
