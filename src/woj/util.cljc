;; woj.util - Shared utilities for the woj compiler

(ns woj.util
  (:require [clojure.string :as str-lib]))

(def ^:private operator-names
  "Mapping of operator symbols to WAT identifiers."
  {"+"  "_PLUS_"
   "-"  "_MINUS_"
   "*"  "_STAR_"
   "/"  "_SLASH_"
   "="  "_EQ_"
   "<"  "_LT_"
   ">"  "_GT_"
   "<=" "_LT__EQ_"
   ">=" "_GT__EQ_"})

(def ^:private char-replacements
  "Character replacements for valid WAT identifiers.
   Uses strings (not chars) because replacements are multi-char."
  [["-" "_"]
   ["?" "_QMARK_"]
   ["!" "_BANG_"]
   ["'" "_PRIME_"]
   ["=" "_EQ_"]
   ["&" "_AMP_"]
   ["." "_DOT_"]
   ["*" "_STAR_"]
   ["#" "_HASH_"]
   ["%" "_PERCENT_"]
   ["@" "_AT_"]
   ["^" "_CARET_"]
   ["~" "_TILDE_"]
   ["`" "_BACKTICK_"]])

(defn- replace-chars
  "Apply character replacements to a string."
  [s]
  (reduce (fn [acc [from to]]
            (str-lib/replace acc from to))
          s
          char-replacements))

(defn munge-name
  "Convert a Clojure symbol to a valid WAT identifier."
  [sym]
  (let [s (name sym)
        result (if-let [op-name (operator-names s)]
                 op-name
                 (replace-chars s))]
    (if (= "" result)
      (str "__empty_" (pr-str sym))
      result)))

(defn str-join
  "Join collection with separator."
  [sep coll]
  #?(:woj
     (let [buf (string-buffer)
           s (seq coll)]
       (if (nil? s)
         ""
         (do (sb-append! buf (str (first s)))
             (loop [remaining (next s)]
               (if (nil? remaining)
                 (sb->string buf)
                 (do (sb-append! buf sep)
                     (sb-append! buf (str (first remaining)))
                     (recur (next remaining))))))))
     :default
     (let [v (into [] coll)]
       (if (empty? v)
         ""
         (loop [result (str (first v))
                remaining (rest v)]
           (if (empty? remaining)
             result
             (recur (str result sep (first remaining))
                    (rest remaining))))))))
