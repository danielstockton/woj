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

#?(:woj
   (do
     (defn- serialize-to!
       "Append serialized WAT for node to StringBuffer buf."
       [buf node]
       (cond
         (nil? node) nil

         (and (map? node) (contains? node :raw))
         (let [r (:raw node)]
           (when r (sb-append! buf r)))

         (vector? node)
         (do (sb-append-char! buf 40) ;; (
             (let [first-done (atom false)]
               (loop [i 0]
                 (when (< i (count node))
                   (let [child (nth node i)]
                     (when-not (nil? child)
                       (let [is-str (string? child)
                             skip (and is-str (= child ""))]
                         (when-not skip
                           (when @first-done (sb-append-char! buf 32)) ;; space
                           (if is-str
                             (sb-append! buf child)
                             (serialize-to! buf child))
                           (reset! first-done true)))))
                   (recur (inc i)))))
             (sb-append-char! buf 41)) ;; )

         (string? node) (sb-append! buf node)

         (keyword? node) (sb-append! buf (name node))

         (number? node) (sb-append! buf (if (float? node)
                                          (cond
                                            (not= node node) "nan"
                                            (= node ##Inf) "inf"
                                            (= node ##-Inf) "-inf"
                                            :else (str node))
                                          (str node)))

         (seq? node) (let [first? (atom true)]
                       (loop [s (seq node)]
                         (when s
                           (when-not @first? (sb-append! buf "\n      "))
                           (serialize-to! buf (first s))
                           (reset! first? false)
                           (recur (next s)))))

         :else (sb-append! buf (str node))))

     (defn serialize
       "Serialize a WASM IR node to a WAT string."
       [node]
       (if (nil? node)
         ""
         (let [buf (string-buffer)]
           (serialize-to! buf node)
           (sb->string buf)))))

   :default
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
           #?(:clj (Double/isNaN node) :default (not= node node)) "nan"
           (= node ##Inf) "inf"
           (= node ##-Inf) "-inf"
           :else (str node))
         (str node))

       :else
       (str node))))

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
