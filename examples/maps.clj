;; Example: Persistent Hash Maps in woj
;; HAMT (Hash Array Mapped Trie) implementation

;; Create a simple map with keyword keys
(def m (hash-map :a 100 :b 200 :c 300))

;; Get value by key (should be 100)
(defn test-get-a []
  (get m :a))

;; Get value by key (should be 200)
(defn test-get-b []
  (get m :b))

;; Get value by key (should be 300)
(defn test-get-c []
  (get m :c))

;; Get missing key returns nil (0 when unboxed)
(defn test-get-missing []
  (if (nil? (get m :z))
    1  ;; nil -> true
    0))

;; Check contains? (should be 1/true)
(defn test-contains []
  (contains? m :a))

;; Check contains? for missing (should be 0/false)
(defn test-not-contains []
  (contains? m :z))

;; Check map? predicate (should be 1/true)
(defn test-map? []
  (map? m))

;; Assoc adds new key-value pair
(defn test-assoc []
  (get (hash-map :x 42) :x))

;; Assoc updates existing key
(defn test-assoc-update []
  (let [m2 (hash-map :a 1)]
    (get (hash-map :a 1 :a 999) :a)))

;; Map with integer keys
(defn test-int-keys []
  (let [m (hash-map 1 10 2 20 3 30)]
    (+ (get m 1) (+ (get m 2) (get m 3)))))

;; Empty map
(defn test-empty []
  (if (nil? (get (hash-map) :x))
    1
    0))
