(ns clojure.string)

;; ============================================
;; clojure.string - String manipulation library
;; ============================================

(defn lower-case [s]
  (str-to-lower s))

(defn upper-case [s]
  (str-to-upper s))

(defn trim [s]
  (str-trim s))

(defn trim-newline [s]
  (if (nil? s)
    nil
    (loop [s s]
      (let [len (count s)]
        (if (zero? len)
          s
          (let [last-ch (subs s (dec len) len)]
            (if (or (= last-ch "\n") (= last-ch "\r"))
              (recur (subs s 0 (dec len)))
              s)))))))

(defn triml [s]
  (if (nil? s)
    nil
    (let [len (count s)]
      (loop [i 0]
        (if (>= i len)
          ""
          (let [ch (subs s i (inc i))]
            (if (or (= ch " ") (= ch "\t") (= ch "\n") (= ch "\r"))
              (recur (inc i))
              (subs s i len))))))))

(defn trimr [s]
  (if (nil? s)
    nil
    (let [len (count s)]
      (loop [i len]
        (if (zero? i)
          ""
          (let [ch (subs s (dec i) i)]
            (if (or (= ch " ") (= ch "\t") (= ch "\n") (= ch "\r"))
              (recur (dec i))
              (subs s 0 i))))))))

(defn starts-with? [s substr]
  (str-starts-with s substr))

(defn ends-with? [s substr]
  (str-ends-with s substr))

(defn includes? [s substr]
  (not (neg? (str-index-of s substr))))

(defn index-of
  ([s value]
   (let [i (str-index-of s value)]
     (if (neg? i) nil i)))
  ([s value from-index]
   (if (>= from-index (count s))
     nil
     (let [sub (subs s from-index (count s))
           i (str-index-of sub value)]
       (if (neg? i) nil (+ i from-index))))))

(defn replace [s match replacement]
  (str-replace s match replacement))

(defn replace-first [s match replacement]
  (let [idx (str-index-of s match)]
    (if (neg? idx)
      s
      (let [before (subs s 0 idx)
            after (subs s (+ idx (count match)) (count s))]
        (str before replacement after)))))

(defn split [s re]
  (vec (str-split s re)))

(defn join
  ([coll]
   (reduce (fn [acc x] (str-concat acc (str1 x))) "" coll))
  ([separator coll]
   (let [s (seq coll)]
     (if (nil? s)
       ""
       (reduce (fn [acc x] (str-concat acc (str-concat separator (str1 x)))) (str1 (first s)) (rest s))))))

(defn blank? [s]
  (or (nil? s) (= s "") (= (str-trim s) "")))

(defn capitalize [s]
  (if (or (nil? s) (= s ""))
    s
    (str (str-to-upper (subs s 0 1)) (str-to-lower (subs s 1 (count s))))))

(defn reverse [s]
  (if (nil? s)
    nil
    (let [len (count s)]
      (loop [result "" i (dec len)]
        (if (neg? i)
          result
          (recur (str result (subs s i (inc i))) (dec i)))))))
