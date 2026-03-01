;; Clojure reader for woj - port of cljs.tools.reader
;; Reads Clojure source code from strings into data structures

(ns woj.reader
  (:require [woj.reader.types :as t]
            [woj.reader.utils :as u]
            [woj.reader.commons :as c]
            [clojure.string :as str]))

;; ==========================================
;; Forward declarations and sentinels
;; ==========================================

(declare read* macros dispatch-macros read-tagged)

(def ^:dynamic *data-readers* {})
(def ^:dynamic *default-data-reader-fn* nil)
(def ^:dynamic *suppress-read* false)
(def ^:dynamic *read-delim* false)
(def ^:dynamic *alias-map* nil)

;; Sentinel values - unique keywords that can't appear in source
(def READ-EOF :woj.reader/eof)
(def READ-FINISHED :woj.reader/finished)
(def READ-SKIP :woj.reader/skip)

;; ==========================================
;; Helpers
;; ==========================================

(defn- reader-error [rdr & msgs]
  (let [msg (apply str msgs)
        loc (when (t/indexing-reader? rdr)
              (str " [line " (t/get-line-number rdr) ", col " (t/get-column-number rdr) "]"))]
    (throw (ex-info (str "Reader error: " msg loc)
                    {:type :reader-exception
                     :line (when (t/indexing-reader? rdr) (t/get-line-number rdr))
                     :column (when (t/indexing-reader? rdr) (t/get-column-number rdr))}))))

(defn- macro-terminating? [ch]
  (or (= ch "\"") (= ch ";") (= ch "@") (= ch "^")
      (= ch "`") (= ch "~") (= ch "(") (= ch ")")
      (= ch "[") (= ch "]") (= ch "{") (= ch "}")
      (= ch "\\")))

(defn- read-token [rdr kind initch]
  (if (nil? initch)
    (reader-error rdr "EOF while reading " kind)
    (loop [sb initch]
      (let [ch (t/read-char rdr)]
        (if (or (u/whitespace? ch) (macro-terminating? ch) (nil? ch))
          (do
            (when ch (t/unread rdr ch))
            sb)
          (recur (str sb ch)))))))

;; ==========================================
;; Dispatch
;; ==========================================

(defn- read-dispatch [rdr _ opts pending-forms]
  (let [ch (t/read-char rdr)]
    (if (nil? ch)
      (reader-error rdr "EOF while reading dispatch macro")
      (let [dm (dispatch-macros ch)]
        (if dm
          (dm rdr ch opts pending-forms)
          ;; Try tagged literal
          (do (t/unread rdr ch)
              (read-tagged rdr ch opts pending-forms)))))))

(defn- read-unmatched-delimiter [rdr ch opts pending-forms]
  (reader-error rdr "Unmatched delimiter: " ch))

;; ==========================================
;; Collection readers
;; ==========================================

(defn- starting-line-col-info [rdr]
  (when (t/indexing-reader? rdr)
    [(t/get-line-number rdr) (- (t/get-column-number rdr) 1)]))

(defn- ending-line-col-info [rdr]
  (when (t/indexing-reader? rdr)
    [(t/get-line-number rdr) (t/get-column-number rdr)]))

(defn- read-delimited [kind delim rdr opts pending-forms]
  (binding [*read-delim* true]
    (let [start-info (starting-line-col-info rdr)]
      (loop [a []]
        (let [form (read* rdr false READ-EOF delim opts pending-forms)]
          (if (= form READ-FINISHED)
            a
            (if (= form READ-EOF)
              (reader-error rdr "EOF while reading " kind
                            (when start-info (str " started at line " (first start-info))))
              (recur (conj a form)))))))))

(defn- read-list [rdr _ opts pending-forms]
  (let [start-info (starting-line-col-info rdr)
        the-list (read-delimited :list ")" rdr opts pending-forms)
        ;; Convert vector to list
        lst (loop [i (- (count the-list) 1) acc nil]
              (if (< i 0)
                acc
                (recur (- i 1) (cons (nth the-list i) acc))))]
    (if (and start-info (seq lst))
      (with-meta (if (nil? lst) (list) lst)
        {:line (first start-info) :column (second start-info)})
      (if (nil? lst) (list) lst))))

(defn- read-vector [rdr _ opts pending-forms]
  (let [start-info (starting-line-col-info rdr)
        the-vec (read-delimited :vector "]" rdr opts pending-forms)]
    (if start-info
      (with-meta the-vec
        {:line (first start-info) :column (second start-info)})
      the-vec)))

(defn- read-map [rdr _ opts pending-forms]
  (let [start-info (starting-line-col-info rdr)
        the-items (read-delimited :map "}" rdr opts pending-forms)]
    (when (odd? (count the-items))
      (reader-error rdr "Map literal must contain an even number of forms"))
    ;; Build map from pairs
    (let [m (loop [i 0 m {}]
              (if (< i (count the-items))
                (recur (+ i 2) (assoc m (nth the-items i) (nth the-items (+ i 1))))
                m))]
      (if start-info
        (with-meta m {:line (first start-info) :column (second start-info)})
        m))))

;; ==========================================
;; Number reader
;; ==========================================

(defn- read-number [rdr initch]
  (loop [sb initch]
    (let [ch (t/read-char rdr)]
      (if (or (u/whitespace? ch) (macros ch) (nil? ch))
        (do
          (when ch (t/unread rdr ch))
          (let [result (c/match-number sb)]
            (if (nil? result)
              (if *suppress-read* 0 (reader-error rdr "Invalid number: " sb))
              result)))
        (recur (str sb ch))))))

;; ==========================================
;; String reader
;; ==========================================

(defn- read-unicode-char-token [token offset length base]
  (let [l (+ offset length)]
    (when (not (= (count token) l))
      (throw (ex-info (str "Invalid unicode literal: " token) {})))
    (loop [i offset uc 0]
      (if (= i l)
        (char-from-codepoint uc)
        (let [d (u/char-code (nth token i) base)]
          (if (= d -1)
            (throw (ex-info (str "Invalid digit in unicode literal: " (nth token i)) {}))
            (recur (+ i 1) (+ d (* uc base)))))))))

(defn- read-unicode-char-reader [rdr initch base length exact?]
  (loop [i 1 uc (u/char-code initch base)]
    (if (= uc -1)
      (reader-error rdr "Invalid unicode digit: " initch)
      (if (not (= i length))
        (let [ch (t/peek-char rdr)]
          (if (or (u/whitespace? ch) (macros ch) (nil? ch))
            (if exact?
              (reader-error rdr "Invalid unicode character length: " i ", expected " length)
              (char-from-codepoint uc))
            (let [d (u/char-code ch base)]
              (t/read-char rdr)
              (if (= d -1)
                (reader-error rdr "Invalid unicode digit: " ch)
                (recur (+ i 1) (+ d (* uc base)))))))
        (char-from-codepoint uc)))))

(defn- escape-char [rdr]
  (let [ch (t/read-char rdr)]
    (case ch
      "t" "\t"
      "r" "\r"
      "n" "\n"
      "\\" "\\"
      "\"" "\""
      "b" "\b"
      "f" "\f"
      "u" (let [ch2 (t/read-char rdr)]
            (if (= -1 (u/char-code ch2 16))
              (reader-error rdr "Invalid unicode escape: \\u" ch2)
              (read-unicode-char-reader rdr ch2 16 4 true)))
      ;; Octal escape
      (if (u/numeric? ch)
        (let [result (read-unicode-char-reader rdr ch 8 3 false)]
          result)
        (reader-error rdr "Unsupported escape character: \\" ch)))))

(defn- read-string* [reader _ opts pending-forms]
  (loop [sb ""
         ch (t/read-char reader)]
    (if (nil? ch)
      (reader-error reader "EOF while reading string")
      (cond
        (= ch "\\") (recur (str sb (escape-char reader)) (t/read-char reader))
        (= ch "\"") sb
        :else (recur (str sb ch) (t/read-char reader))))))

;; ==========================================
;; Character literal reader
;; ==========================================

(defn- read-char* [rdr _ opts pending-forms]
  (let [ch (t/read-char rdr)]
    (if (nil? ch)
      (reader-error rdr "EOF while reading character")
      (let [token (if (or (macro-terminating? ch) (u/whitespace? ch))
                    ch
                    (read-token rdr :character ch))]
        (cond
          (= (count token) 1) token

          (= token "newline") "\n"
          (= token "space") " "
          (= token "tab") "\t"
          (= token "backspace") "\b"
          (= token "formfeed") "\f"
          (= token "return") "\r"

          (= (nth token 0) "u")
          (read-unicode-char-token token 1 4 16)

          (= (nth token 0) "o")
          (let [len (- (count token) 1)]
            (if (> len 3)
              (reader-error rdr "Invalid octal character length: " token)
              (read-unicode-char-token token 1 len 8)))

          :else
          (reader-error rdr "Unsupported character: \\" token))))))

;; ==========================================
;; Symbol and keyword readers
;; ==========================================

(defn- read-symbol [rdr initch]
  (let [start-info (starting-line-col-info rdr)
        token (read-token rdr :symbol initch)]
    (case token
      "nil" nil
      "true" true
      "false" false
      "/" (quote /)
      ;; Regular symbol
      (let [parsed (c/parse-symbol token)]
        (if parsed
          (let [sym (symbol (first parsed) (second parsed))]
            (if start-info
              (with-meta sym {:line (first start-info) :column (second start-info)})
              sym))
          (reader-error rdr "Invalid symbol: " token))))))

(defn- resolve-alias [sym]
  (when *alias-map*
    (get *alias-map* sym)))

(defn- read-keyword [reader initch opts pending-forms]
  (let [ch (t/read-char reader)]
    (if (u/whitespace? ch)
      (reader-error reader "Single colon is not a valid keyword")
      (let [token (read-token reader :keyword ch)
            parsed (c/parse-symbol token)]
        (if parsed
          (let [ns-part (first parsed)
                name-part (second parsed)]
            (if (= (nth token 0) ":")
              ;; ::keyword (auto-resolved namespace)
              (if ns-part
                ;; ::alias/name
                (let [resolved (resolve-alias (symbol (subs ns-part 1)))]
                  (if resolved
                    (keyword (str resolved) name-part)
                    (reader-error reader "Invalid keyword: ::" token)))
                ;; ::name — use current ns (not available in woj bootstrap, use nil)
                (keyword nil (subs name-part 1)))
              ;; :ns/name or :name
              (keyword ns-part name-part)))
          (reader-error reader "Invalid keyword: :" token))))))

;; ==========================================
;; Regex reader
;; ==========================================

(defn- read-regex [rdr _ opts pending-forms]
  (loop [sb ""]
    (let [ch (t/read-char rdr)]
      (cond
        (= ch "\"") (re-pattern sb)
        (nil? ch) (reader-error rdr "EOF while reading regex")
        (= ch "\\") (let [ch2 (t/read-char rdr)]
                       (if (nil? ch2)
                         (reader-error rdr "EOF while reading regex")
                         (recur (str sb ch ch2))))
        :else (recur (str sb ch))))))

;; ==========================================
;; Wrapping readers (quote, deref, var)
;; ==========================================

(defn- wrapping-reader [sym]
  (fn [rdr _ opts pending-forms]
    (list sym (read* rdr true nil nil opts pending-forms))))

;; ==========================================
;; Metadata reader
;; ==========================================

(defn- read-meta [rdr _ opts pending-forms]
  (let [start-info (starting-line-col-info rdr)
        m (u/desugar-meta (read* rdr true nil nil opts pending-forms))]
    (when-not (map? m)
      (reader-error rdr "Metadata must be a map, keyword, symbol, or string"))
    (let [o (read* rdr true nil nil opts pending-forms)]
      (if (seq? o)
        (let [m2 (if start-info
                   (assoc m :line (first start-info) :column (second start-info))
                   m)]
          (with-meta o (merge (meta o) m2)))
        (with-meta o (merge (meta o) m))))))

;; ==========================================
;; Set reader
;; ==========================================

(defn- read-set [rdr _ opts pending-forms]
  (let [coll (read-delimited :set "}" rdr opts pending-forms)]
    (set coll)))

;; ==========================================
;; Discard reader
;; ==========================================

(defn- read-discard [rdr _ opts pending-forms]
  (read* rdr true nil nil opts pending-forms)
  READ-SKIP)

;; ==========================================
;; Symbolic value reader (##NaN, ##Inf, ##-Inf)
;; ==========================================

(defn- read-symbolic-value [rdr _ opts pending-forms]
  (let [sym (read* rdr true nil nil opts pending-forms)]
    (case (name sym)
      "NaN" ##NaN
      "-Inf" ##-Inf
      "Inf" ##Inf
      (reader-error rdr "Invalid symbolic value: ##" sym))))

;; ==========================================
;; Reader conditionals (#?(:woj ... :default ...))
;; ==========================================

(def ^:private RESERVED-FEATURES #{:else :none})

(defn- has-feature? [rdr feature opts]
  (if (keyword? feature)
    (or (= :default feature)
        (contains? (get opts :features) feature))
    (reader-error rdr "Feature should be a keyword: " feature)))

(defn- read-suppress [rdr opts pending-forms]
  (binding [*suppress-read* true]
    (read* rdr false READ-EOF ")" opts pending-forms)))

(def ^:private NO-MATCH :woj.reader/no-match)

(defn- match-feature [rdr opts pending-forms]
  (let [feature (read* rdr false READ-EOF ")" opts pending-forms)]
    (if (= feature READ-EOF)
      (reader-error rdr "EOF while reading reader conditional")
      (if (= feature READ-FINISHED)
        READ-FINISHED
        (do
          (when (contains? RESERVED-FEATURES feature)
            (reader-error rdr "Feature name " feature " is reserved"))
          (if (has-feature? rdr feature opts)
            ;; Feature matched, read the form
            (let [form (read* rdr false READ-EOF ")" opts pending-forms)]
              (when (= form READ-EOF)
                (reader-error rdr "EOF while reading reader conditional"))
              form)
            ;; Not matched, skip the form
            (do (read-suppress rdr opts pending-forms)
                NO-MATCH)))))))

(defn- read-cond-delimited [rdr splicing opts pending-forms]
  (let [result (loop [matched NO-MATCH finished nil]
                 (cond
                   (= matched NO-MATCH)
                   (let [m (match-feature rdr opts pending-forms)]
                     (if (= m READ-FINISHED)
                       READ-FINISHED
                       (recur m nil)))

                   (not (= finished READ-FINISHED))
                   (recur matched (read-suppress rdr opts pending-forms))

                   :else matched))]
    (if (= result READ-FINISHED)
      READ-SKIP
      (if splicing
        (if (sequential? result)
          ;; Splice into pending-forms
          (do
            (doseq [form (reverse result)]
              (swap! pending-forms (fn [pf] (into [form] pf))))
            READ-SKIP)
          (reader-error rdr "Spliced form in read-cond-splicing must be sequential"))
        result))))

(defn- read-cond [rdr _ opts pending-forms]
  (when-not (and opts (contains? #{:allow :preserve} (:read-cond opts)))
    (throw (ex-info "Conditional read not allowed" {:type :runtime-exception})))
  (let [ch (t/read-char rdr)]
    (if (nil? ch)
      (reader-error rdr "EOF while reading reader conditional")
      (let [splicing (= ch "@")
            ch (if splicing (t/read-char rdr) ch)]
        (when (and splicing (not *read-delim*))
          (reader-error rdr "cond-splice not in list"))
        (let [ch2 (if (u/whitespace? ch)
                    (c/read-past u/whitespace? rdr)
                    ch)]
          (if (not (= ch2 "("))
            (throw (ex-info "read-cond body must be a list" {:type :runtime-exception}))
            (binding [*suppress-read* (or *suppress-read* (= :preserve (:read-cond opts)))]
              (if *suppress-read*
                ;; In preserve mode, just read and wrap
                (let [form (read-list rdr ch2 opts pending-forms)]
                  {:splicing? splicing :form form})
                (read-cond-delimited rdr splicing opts pending-forms)))))))))

;; ==========================================
;; Anonymous function reader #(...)
;; ==========================================

(def ^:dynamic *arg-env* nil)

(defn- garg [n]
  (symbol (str (if (= n -1) "rest" (str "p" n))
               "__" (u/next-id) "#")))

(defn- register-arg [n]
  (if *arg-env*
    (let [existing (get @*arg-env* n)]
      (if existing
        existing
        (let [g (garg n)]
          (swap! *arg-env* assoc n g)
          g)))
    (throw (ex-info "Arg literal not in #()" {:type :illegal-state}))))

(defn- read-fn [rdr _ opts pending-forms]
  (when *arg-env*
    (throw (ex-info "Nested #()s are not allowed" {:type :illegal-state})))
  (binding [*arg-env* (atom (sorted-map))]
    (t/unread rdr "(")
    (let [form (read* rdr true nil nil opts pending-forms)
          rargs (seq (reverse (seq @*arg-env*)))
          args (if rargs
                 (let [higharg (first (first rargs))]
                   (let [args (loop [i 1 a []]
                                (if (> i higharg)
                                  a
                                  (recur (+ i 1)
                                         (conj a (or (get @*arg-env* i) (garg i))))))
                         args (if (get @*arg-env* -1)
                                (conj args (quote &) (get @*arg-env* -1))
                                args)]
                     args))
                 [])]
      (list (quote fn*) args form))))

(defn- read-arg [rdr pct opts pending-forms]
  (if (nil? *arg-env*)
    (read-symbol rdr pct)
    (let [ch (t/peek-char rdr)]
      (cond
        (or (u/whitespace? ch) (macro-terminating? ch) (nil? ch))
        (register-arg 1)

        (= ch "&")
        (do (t/read-char rdr)
            (register-arg -1))

        :else
        (let [n (read* rdr true nil nil opts pending-forms)]
          (if (integer? n)
            (register-arg n)
            (throw (ex-info "Arg literal must be %, %& or %integer"
                            {:type :illegal-state}))))))))

;; ==========================================
;; Syntax quote reader
;; ==========================================

(def ^:dynamic *gensym-env* nil)

(defn- read-unquote [rdr _ opts pending-forms]
  (let [ch (t/peek-char rdr)]
    (if (= ch "@")
      (do (t/read-char rdr)
          (list (quote clojure.core/unquote-splicing)
                (read* rdr true nil nil opts pending-forms)))
      (list (quote clojure.core/unquote)
            (read* rdr true nil nil opts pending-forms)))))

(declare syntax-quote*)

(defn- unquote-splicing? [form]
  (and (seq? form) (= (first form) (quote clojure.core/unquote-splicing))))

(defn- unquote? [form]
  (and (seq? form) (= (first form) (quote clojure.core/unquote))))

(defn- expand-list [s]
  (loop [s (seq s) r []]
    (if s
      (let [item (first s)]
        (recur (next s)
               (conj r (cond
                         (unquote? item) (list (quote clojure.core/list) (second item))
                         (unquote-splicing? item) (second item)
                         :else (list (quote clojure.core/list) (syntax-quote* item))))))
      (seq r))))

(defn- flatten-map [form]
  (loop [s (seq form) kv []]
    (if s
      (let [e (first s)]
        (recur (next s) (conj (conj kv (first e)) (second e))))
      (seq kv))))

(defn- register-gensym [sym]
  (when-not *gensym-env*
    (throw (ex-info "Gensym literal not in syntax-quote" {:type :illegal-state})))
  (let [existing (get @*gensym-env* sym)]
    (if existing
      existing
      (let [gs (symbol (str (subs (name sym) 0 (- (count (name sym)) 1))
                            "__" (u/next-id) "__auto__"))]
        (swap! *gensym-env* assoc sym gs)
        gs))))

(defn- special-symbol? [sym]
  (contains? #{(quote def) (quote fn) (quote fn*) (quote let) (quote if) (quote do)
               (quote loop) (quote recur) (quote set!) (quote quote) (quote try)
               (quote catch) (quote finally) (quote throw) (quote new) (quote .)}
             sym))

;; Resolve a symbol in syntax-quote context.
;; In bootstrap mode, symbols pass through as-is.
(def ^:dynamic resolve-symbol (fn [s] s))

(defn- syntax-quote-coll [type-fn coll]
  (let [res (list (quote clojure.core/sequence)
                  (cons (quote clojure.core/concat)
                        (expand-list coll)))]
    (if type-fn
      (list (quote clojure.core/apply) type-fn res)
      res)))

(defn- add-meta [form ret]
  (let [m (meta form)]
    (if (and m
             (seq (dissoc (dissoc (dissoc (dissoc (dissoc (dissoc m :line) :column) :end-line) :end-column) :file) :source)))
      (list (quote clojure.core/with-meta) ret (syntax-quote* m))
      ret)))

(defn- syntax-quote* [form]
  (let [result
        (cond
          (and (symbol? form) (special-symbol? form))
          (list (quote quote) form)

          (symbol? form)
          (list (quote quote)
                (if (and (not (namespace form))
                         (str/ends-with? (name form) "#"))
                  (register-gensym form)
                  (resolve-symbol form)))

          (unquote? form) (second form)
          (unquote-splicing? form)
          (throw (ex-info "unquote-splice not in list" {:type :illegal-state}))

          (coll? form)
          (cond
            (map? form) (syntax-quote-coll (quote clojure.core/hash-map) (flatten-map form))
            (vector? form) (list (quote clojure.core/vec) (syntax-quote-coll nil form))
            (set? form) (syntax-quote-coll (quote clojure.core/hash-set) form)
            (or (seq? form) (list? form))
            (if (seq form)
              (syntax-quote-coll nil form)
              (quote (clojure.core/list)))
            :else (throw (ex-info "Unknown collection type" {:type :unsupported-operation})))

          (or (keyword? form) (number? form) (string? form)
              (nil? form) (true? form) (false? form))
          form

          :else (list (quote quote) form))]
    (add-meta form result)))

(defn- read-syntax-quote [rdr _ opts pending-forms]
  (binding [*gensym-env* (atom {})]
    (syntax-quote* (read* rdr true nil nil opts pending-forms))))

;; ==========================================
;; Tagged literal reader
;; ==========================================

(declare read-tagged)

(defn- read-tagged [rdr _ opts pending-forms]
  (let [tag (read* rdr true nil nil opts pending-forms)]
    (when-not (symbol? tag)
      (reader-error rdr "Reader tag must be a symbol"))
    (if *suppress-read*
      {:tag tag :form (read* rdr true nil nil opts pending-forms)}
      (let [f (or (get *data-readers* tag)
                  (when *default-data-reader-fn*
                    *default-data-reader-fn*))]
        (if f
          (f (read* rdr true nil nil opts pending-forms))
          (reader-error rdr "Unknown reader tag: " tag))))))

;; ==========================================
;; Namespaced map reader #:ns{...}
;; ==========================================

(defn- read-namespaced-map [rdr _ opts pending-forms]
  (let [token (read-token rdr :namespaced-map (t/read-char rdr))
        ns-str (cond
                 (= (nth token 0) ":")
                 ;; ::alias or :: — auto-resolve
                 (when (> (count token) 1)
                   (let [alias-sym (symbol (subs token 1))]
                     (when-let [resolved (resolve-alias alias-sym)]
                       (str resolved))))
                 :else
                 ;; :ns — literal namespace
                 (let [parsed (c/parse-symbol token)]
                   (when parsed (second parsed))))]
    (when-not ns-str
      (reader-error rdr "Invalid namespaced map: #:" token))
    (let [ch (c/read-past u/whitespace? rdr)]
      (if (= ch "{")
        (let [items (read-delimited :namespaced-map "}" rdr opts pending-forms)]
          (when (odd? (count items))
            (reader-error rdr "Namespaced map must contain even number of forms"))
          (let [ks (u/namespace-keys ns-str
                     (loop [i 0 ks []]
                       (if (< i (count items))
                         (recur (+ i 2) (conj ks (nth items i)))
                         ks)))
                vs (loop [i 1 vs []]
                     (if (< i (count items))
                       (recur (+ i 2) (conj vs (nth items i)))
                       vs))]
            (zipmap ks vs)))
        (reader-error rdr "Namespaced map must specify a map: #:" token)))))

;; ==========================================
;; Macro and dispatch macro tables
;; ==========================================

(defn- macros [ch]
  (case ch
    "\"" read-string*
    ":" read-keyword
    ";" c/read-comment
    "'" (wrapping-reader (quote quote))
    "@" (wrapping-reader (quote clojure.core/deref))
    "^" read-meta
    "`" read-syntax-quote
    "~" read-unquote
    "(" read-list
    ")" read-unmatched-delimiter
    "[" read-vector
    "]" read-unmatched-delimiter
    "{" read-map
    "}" read-unmatched-delimiter
    "\\" read-char*
    "%" read-arg
    "#" read-dispatch
    nil))

(defn- dispatch-macros [ch]
  (case ch
    "^" read-meta
    "'" (wrapping-reader (quote var))
    "(" read-fn
    "{" read-set
    "<" (fn [rdr & _] (reader-error rdr "Unreadable form"))
    "=" (fn [rdr & _] (reader-error rdr "read-eval not supported"))
    "\"" read-regex
    "!" c/read-comment
    "_" read-discard
    "?" read-cond
    ":" read-namespaced-map
    "#" read-symbolic-value
    nil))

;; ==========================================
;; Core read function
;; ==========================================

(defn- read*-internal [reader eof-error? sentinel return-on opts pending-forms]
  (loop []
    ;; Check pending forms first
    (let [pf @pending-forms]
      (if (> (count pf) 0)
        (let [form (first pf)]
          (reset! pending-forms (vec (rest pf)))
          form)
        (let [ch (t/read-char reader)]
          (cond
            (u/whitespace? ch) (recur)
            (nil? ch) (if eof-error?
                        (reader-error reader "EOF")
                        sentinel)
            (= ch return-on) READ-FINISHED
            (c/number-literal? reader ch) (read-number reader ch)
            :else
            (let [f (macros ch)]
              (if f
                (let [res (f reader ch opts pending-forms)]
                  (if (= res READ-SKIP)
                    (recur)
                    res))
                (read-symbol reader ch)))))))))

(defn- read*
  ([reader eof-error? sentinel opts pending-forms]
   (read* reader eof-error? sentinel nil opts pending-forms))
  ([reader eof-error? sentinel return-on opts pending-forms]
   (try
     (read*-internal reader eof-error? sentinel return-on opts pending-forms)
     (catch e
       (if (and (map? (ex-data e))
                (= :reader-exception (:type (ex-data e))))
         (throw e)
         (throw (ex-info (str "Reader error: " (ex-message e))
                         (merge {:type :reader-exception}
                                (when (t/indexing-reader? reader)
                                  {:line (t/get-line-number reader)
                                   :column (t/get-column-number reader)})
                                (ex-data e))
                         e)))))))

;; ==========================================
;; Public API
;; ==========================================

(defn read
  "Read a single form from reader."
  ([reader]
   (read reader true nil))
  ([opts reader]
   (if (map? opts)
     (let [eof (get opts :eof :eofthrow)]
       (read* reader (= eof :eofthrow) eof nil opts (atom [])))
     ;; Legacy 3-arg compat: (read reader eof-error? sentinel)
     (read* opts reader nil nil {} (atom []))))
  ([reader eof-error? sentinel]
   (read* reader eof-error? sentinel nil {} (atom []))))

(defn read-string
  "Read one form from string s. Returns nil when s is nil or empty."
  ([s]
   (read-string {} s))
  ([opts s]
   (when (and s (not (= s "")))
     (read opts (t/string-push-back-reader s)))))

(defn read-all
  "Read all forms from string s. Returns a vector of forms."
  ([s] (read-all {} s))
  ([opts s]
   (when (and s (not (= s "")))
     (let [rdr (t/string-push-back-reader s)
           sentinel :woj.reader/eof-sentinel]
       (loop [forms []]
         (let [form (read (assoc opts :eof sentinel) rdr)]
           (if (= form sentinel)
             forms
             (recur (conj forms form)))))))))
