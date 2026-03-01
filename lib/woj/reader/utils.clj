;; Reader utilities for woj - port of cljs.tools.reader.impl.utils

(ns woj.reader.utils
  (:require [clojure.string :as str]))

(defn whitespace? [ch]
  (when ch
    (or (= ch " ") (= ch "\t") (= ch "\n") (= ch "\r")
        (= ch ",") (= ch "\f"))))

(defn numeric? [ch]
  (when ch
    (let [cp (codepoint-at ch 0)]
      (and (>= cp 48) (<= cp 57)))))

(defn newline? [ch]
  (or (= ch "\n") (nil? ch)))

(defn desugar-meta [f]
  (cond
    (keyword? f) {f true}
    (symbol? f) {:tag f}
    (string? f) {:tag f}
    (vector? f) {:param-tags f}
    :else f))

(def ^:dynamic *last-id* (atom 0))

(defn next-id []
  (swap! *last-id* + 1))

(defn char-code
  "Parse character ch as digit in given base. Returns -1 if invalid."
  [ch base]
  (let [cp (codepoint-at ch 0)
        v (cond
            (and (>= cp 48) (<= cp 57)) (- cp 48)   ;; 0-9
            (and (>= cp 65) (<= cp 90)) (+ 10 (- cp 65)) ;; A-Z
            (and (>= cp 97) (<= cp 122)) (+ 10 (- cp 97)) ;; a-z
            :else -1)]
    (if (and (>= v 0) (< v base)) v -1)))

(defn namespace-keys [ns-str keys]
  (map (fn [k]
         (if (or (symbol? k) (keyword? k))
           (let [k-ns (namespace k)
                 k-name (name k)
                 make-key (if (symbol? k) symbol keyword)]
             (cond
               (nil? k-ns) (make-key ns-str k-name)
               (= "_" k-ns) (make-key k-name)
               :else k))
           k))
       keys))

(defn upper-case-char? [ch]
  (let [cp (codepoint-at ch 0)]
    (and (>= cp 65) (<= cp 90))))

(defn lower-case-char? [ch]
  (let [cp (codepoint-at ch 0)]
    (and (>= cp 97) (<= cp 122))))

(defn alpha? [ch]
  (or (upper-case-char? ch) (lower-case-char? ch)))
