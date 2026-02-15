;; woj.util - Shared utilities for the woj compiler

(ns woj.util)

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
            (clojure.string/replace acc from to))
          s
          char-replacements))

(defn munge-name
  "Convert a Clojure symbol to a valid WAT identifier."
  [sym]
  (let [s (name sym)]
    (if-let [op-name (operator-names s)]
      op-name
      (replace-chars s))))

(defn str-join
  "Join collection with separator."
  [sep coll]
  (let [v (into [] coll)]
    (if (empty? v)
      ""
      (loop [result (str (first v))
             remaining (rest v)]
        (if (empty? remaining)
          result
          (recur (str result sep (first remaining))
                 (rest remaining)))))))
