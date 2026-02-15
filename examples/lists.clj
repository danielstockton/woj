;; Example: Cons lists in woj
;; Uses WasmGC structs for persistent list data structure
;; With implicit boxing - no manual box-int needed!

;; Create a simple list of integers (auto-boxed)
(def my-list (list 10 20 12))

;; Function that returns the sum of a list (should be 42)
(defn sum-my-list []
  (+ (first my-list)
     (+ (first (rest my-list))
        (first (rest (rest my-list))))))

;; Function that returns the length of a list (should be 3)
(defn len-my-list []
  (if (nil? my-list)
    0
    (if (nil? (rest my-list))
      1
      (if (nil? (rest (rest my-list)))
        2
        3))))

;; Get first element (should be 10)
(defn get-first []
  (first my-list))

;; Check if list is nil (should be 0/false)
(defn is-nil []
  (nil? my-list))

;; Check if list is a cons (should be 1/true)
(defn is-cons []
  (cons? my-list))

;; Build a list manually with cons (sum should be 6)
(defn manual-list []
  (let [lst (cons 1 (cons 2 (cons 3 nil)))]
    (+ (first lst)
       (+ (first (rest lst))
          (first (rest (rest lst)))))))
