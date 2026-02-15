;; examples/closures.clj
;; Demonstrates closure support in woj

;; Basic closure - function factory
(defn make-adder [x]
  (fn [y] (+ x y)))

(def add5 (make-adder 5))
(def add10 (make-adder 10))

;; Test basic closure
(defn test-basic []
  (add5 10))  ;; => 15

;; Multiple captures
(defn make-linear [m b]
  (fn [x] (+ (* m x) b)))

(def line1 (make-linear 2 3))  ;; y = 2x + 3

(defn test-linear []
  (line1 5))  ;; => 2*5 + 3 = 13

;; Nested closures (currying)
(defn curry-add [x]
  (fn [y]
    (fn [z] (+ x (+ y z)))))

(def add-step1 (curry-add 10))
(def add-step2 (add-step1 20))

(defn test-curry []
  (add-step2 5))  ;; => 10 + 20 + 5 = 35

;; Closure passed to another function
(defn apply-twice [f x]
  (f (f x)))

(defn test-apply-twice []
  (apply-twice (make-adder 3) 10))  ;; (10+3)+3 = 16

;; Closure that creates another closure
(defn make-counter-factory [start]
  (fn [step]
    (fn [n] (+ start (+ (* step n) 0)))))

(def counter-from-10 (make-counter-factory 10))
(def count-by-5 (counter-from-10 5))

(defn test-counter []
  (count-by-5 3))  ;; 10 + 5*3 = 25
