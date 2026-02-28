(ns woj.wasm
  "WASM IR representation and WAT serializer.

   WASM instructions are represented as Clojure vectors:
     [:i32.add [:i32.const 1] [:i32.const 2]]

   Serializes to WAT S-expressions:
     (i32.add (i32.const 1) (i32.const 2))

   Node types:
   - Vector [:op & children]  — S-expression
   - String                   — literal WAT text (names, labels)
   - Number                   — numeric literal
   - Keyword                  — bare WAT name (e.g. :anyref → anyref)
   - {:raw s}                 — pre-serialized WAT string (passthrough)
   - seq/list                 — instruction sequence (siblings, no wrapping parens)
   - nil                      — empty (ignored)"
  (:require [clojure.string :as str]))

(defn raw
  "Wrap a pre-serialized WAT string as an IR node."
  [s]
  {:raw (or s "")})

(defn serialize
  "Serialize a WASM IR node to a WAT string."
  [node]
  (cond
    (nil? node)
    ""

    ;; Pre-serialized WAT string — pass through
    (and (map? node) (contains? node :raw))
    (or (:raw node) "")

    ;; Vector = S-expression: (op child1 child2 ...)
    (vector? node)
    (let [parts (into []
                      (keep (fn [child]
                              (let [s (serialize child)]
                                (when-not (str/blank? s) s))))
                      node)]
      (str "(" (str/join " " parts) ")"))

    ;; List/seq = instruction sequence (no wrapping parens)
    (seq? node)
    (str/join "\n      " (map serialize node))

    ;; Keyword = bare WAT name
    (keyword? node)
    (name node)

    ;; String = literal WAT text
    (string? node)
    node

    ;; Number = literal
    (number? node)
    (if (float? node)
      ;; Handle special float values
      (cond
        (Double/isNaN node) "nan"
        (Double/isInfinite node) (if (pos? node) "inf" "-inf")
        :else (str node))
      (str node))

    :else
    (str node)))

;; ============================================
;; Convenience constructors
;; ============================================

(defn box-i32
  "Box i32 to anyref: (ref.i31 expr)"
  [expr]
  [:ref.i31 expr])

(defn unbox-i32
  "Unbox anyref to i32: (i31.get_s (ref.cast (ref i31) expr))"
  [expr]
  [:i31.get_s [:ref.cast [:ref :i31] expr]])

(defn bool-node
  "Wrap i32 condition as boxed boolean:
   (if (result anyref) cond (then $__true) (else $__false))"
  [i32-cond]
  [:if [:result :anyref] i32-cond
   [:then [:global.get "$__true"]]
   [:else [:global.get "$__false"]]])

(defn wat-string
  "Format a string for WAT output (with quotes)."
  [s]
  (str "\"" s "\""))
