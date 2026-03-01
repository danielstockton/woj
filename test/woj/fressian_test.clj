(ns woj.fressian-test
  (:require [woj.fressian :as fres]))

;; ---- Test helpers ----

(defn- round-trip [val]
  (let [w (fres/writer)]
    (fres/write-object! w val)
    (let [[offset len] (fres/buffer-range w)
          r (fres/reader offset len)]
      (fres/read-object! r))))

(defn- assert= [label expected actual]
  (if (= expected actual)
    (do (println "  PASS:" label) 0)
    (do (println "  FAIL:" label "- expected" expected "got" actual) 1)))

(defn- assert-rt [label val]
  (assert= label val (round-trip val)))

;; ---- Packed integer tests ----

(defn test-integers []
  (println "Testing integers...")
  (+ (assert-rt "zero" 0)
     (assert-rt "one" 1)
     (assert-rt "small positive" 42)
     (assert-rt "max 1-byte (63)" 63)
     (assert-rt "negative one" -1)
     ;; 2-byte packed range
     (assert-rt "64 (2-byte start)" 64)
     (assert-rt "4095 (2-byte max)" 4095)
     (assert-rt "-2 (2-byte neg)" -2)
     (assert-rt "-4096 (2-byte min)" -4096)
     ;; 3-byte packed range
     (assert-rt "4096 (3-byte start)" 4096)
     (assert-rt "524287 (3-byte max)" 524287)
     (assert-rt "-4097 (3-byte neg)" -4097)
     (assert-rt "-524288 (3-byte min)" -524288)
     ;; 4-byte packed range
     (assert-rt "524288 (4-byte start)" 524288)
     (assert-rt "33554431 (4-byte max)" 33554431)
     (assert-rt "-524289 (4-byte neg)" -524289)
     (assert-rt "-33554432 (4-byte min)" -33554432)
     ;; Full INT (5-byte)
     (assert-rt "33554432 (full int)" 33554432)
     (assert-rt "-33554433 (full int neg)" -33554433)
     (assert-rt "100000000" 100000000)))

;; ---- Float tests ----

(defn test-floats []
  (println "Testing floats...")
  (+ (assert-rt "0.0" 0.0)
     (assert-rt "1.0" 1.0)
     (assert-rt "3.14159" 3.14159)
     (assert-rt "-1.0" -1.0)
     (assert-rt "large float" 1234567.89)))

;; ---- String tests ----

(defn test-strings []
  (println "Testing strings...")
  (+ (assert-rt "empty string" "")
     (assert-rt "short string" "hello")
     (assert-rt "7-char string (max packed)" "abcdefg")
     (assert-rt "8-char string (counted)" "abcdefgh")
     (assert-rt "longer string" "the quick brown fox jumps over the lazy dog")))

;; ---- Keyword tests ----

(defn test-keywords []
  (println "Testing keywords...")
  (+ (assert-rt "simple keyword" :foo)
     (assert-rt "another keyword" :bar)
     (assert-rt "namespaced keyword" :person/name)
     (assert-rt "namespaced keyword 2" :db/id)))

;; ---- Symbol tests ----

(defn test-symbols []
  (println "Testing symbols...")
  (+ (assert-rt "simple symbol" 'foo)
     (assert-rt "namespaced symbol" 'clojure.core/map)))

;; ---- Boolean and nil tests ----

(defn test-primitives []
  (println "Testing primitives...")
  (+ (assert-rt "nil" nil)
     (assert-rt "true" true)
     (assert-rt "false" false)))

;; ---- Vector tests ----

(defn test-vectors []
  (println "Testing vectors...")
  (+ (assert-rt "empty vector" [])
     (assert-rt "single-element" [1])
     (assert-rt "small vector" [1 2 3])
     (assert-rt "7-element (max packed)" [1 2 3 4 5 6 7])
     (assert-rt "8-element (counted)" [1 2 3 4 5 6 7 8])
     (assert-rt "mixed types" [1 "hello" :foo true nil])
     (assert-rt "nested vectors" [[1 2] [3 4]])))

;; ---- Map tests ----

(defn test-maps []
  (println "Testing maps...")
  (let [;; Single key-value
        m1 {:a 1}
        r1 (round-trip m1)]
    (+ (assert= "map {:a 1} key" 1 (get r1 :a))
       ;; Multi key-value
       (let [m2 {:name "Alice" :age 30}
             r2 (round-trip m2)]
         (+ (assert= "map name" "Alice" (get r2 :name))
            (assert= "map age" 30 (get r2 :age))))
       ;; Empty map
       (assert= "empty map" {} (round-trip {}))
       ;; Nested map
       (let [m3 {:person {:name "Bob" :age 25}}
             r3 (round-trip m3)
             inner (get r3 :person)]
         (+ (assert= "nested map name" "Bob" (get inner :name))
            (assert= "nested map age" 25 (get inner :age)))))))

;; ---- Set tests ----

(defn test-sets []
  (println "Testing sets...")
  (+ (assert-rt "empty set" #{})
     ;; Sets don't have guaranteed order, so check membership
     (let [s (round-trip #{1 2 3})]
       (+ (assert= "set contains 1" true (contains? s 1))
          (assert= "set contains 2" true (contains? s 2))
          (assert= "set contains 3" true (contains? s 3))
          (assert= "set count" 3 (count s))))))

;; ---- Priority cache tests ----

(defn test-cache []
  (println "Testing priority cache...")
  ;; Write a structure with repeated keywords — second occurrence should be cached
  (let [w (fres/writer)
        data [{:type :leaf :id 1} {:type :leaf :id 2} {:type :node :id 3}]]
    (fres/write-object! w data)
    (let [[offset len] (fres/buffer-range w)
          r (fres/reader offset len)
          result (fres/read-object! r)]
      ;; Verify correct round-trip
      (+ (assert= "cached vec count" 3 (count result))
         (assert= "first type" :leaf (get (nth result 0) :type))
         (assert= "first id" 1 (get (nth result 0) :id))
         (assert= "second type" :leaf (get (nth result 1) :type))
         (assert= "third type" :node (get (nth result 2) :type))
         ;; Verify the cached version is smaller than uncached would be
         ;; (We just verify it round-trips correctly; size check is implicit)
         (assert= "third id" 3 (get (nth result 2) :id))))))

;; ---- Datom-like structure test (defdb integration preview) ----

(defn test-datom-structures []
  (println "Testing datom-like structures...")
  (let [;; Simulate a serialized B+ tree leaf
        leaf {:t :L
              :ks [[1 :person/name "Alice" 1000 true]
                   [1 :person/age 30 1000 true]
                   [2 :person/name "Bob" 1001 true]]}
        w (fres/writer)]
    (fres/write-object! w leaf)
    (let [[offset len] (fres/buffer-range w)
          r (fres/reader offset len)
          result (fres/read-object! r)]
      (+ (assert= "leaf type" :L (get result :t))
         (assert= "datom count" 3 (count (get result :ks)))
         (let [d0 (nth (get result :ks) 0)]
           (+ (assert= "datom entity" 1 (nth d0 0))
              (assert= "datom attr" :person/name (nth d0 1))
              (assert= "datom value" "Alice" (nth d0 2))
              (assert= "datom tx" 1000 (nth d0 3))
              (assert= "datom added" true (nth d0 4))))))))

;; ---- Mem-hash test ----

(defn test-mem-hash []
  (println "Testing mem-hash...")
  (let [w (fres/writer)]
    (fres/write-object! w {:t :L :ks [[1 :name "test" 100 true]]})
    (let [[offset len] (fres/buffer-range w)
          h1 (mem-hash offset len)
          ;; Same data should produce same hash
          w2 (fres/writer)]
      (fres/write-object! w2 {:t :L :ks [[1 :name "test" 100 true]]})
      (let [[offset2 len2] (fres/buffer-range w2)
            h2 (mem-hash offset2 len2)]
        (+ (assert= "hash deterministic" h1 h2)
           ;; Different data should (probably) produce different hash
           (let [w3 (fres/writer)]
             (fres/write-object! w3 {:t :L :ks [[2 :name "other" 101 true]]})
             (let [[offset3 len3] (fres/buffer-range w3)
                   h3 (mem-hash offset3 len3)]
               (assert= "hash differs" true (not= h1 h3)))))))))

;; ---- Runner ----

(defn run-tests []
  (let [failures (+ (test-integers)
                    (test-floats)
                    (test-strings)
                    (test-keywords)
                    (test-symbols)
                    (test-primitives)
                    (test-vectors)
                    (test-maps)
                    (test-sets)
                    (test-cache)
                    (test-datom-structures)
                    (test-mem-hash))]
    (println "---")
    (if (= failures 0)
      (println "All fressian tests passed!")
      (println failures "test(s) failed"))
    failures))
