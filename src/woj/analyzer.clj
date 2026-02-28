(ns woj.analyzer
  (:require [clojure.set :as set]
            [clojure.string :as str]
            [clojure.walk :as walk]))

;; ============================================
;; Dynamic vars for analysis state
;; ============================================

(def ^:dynamic *globals* #{})
(def ^:dynamic *env* {})
(def ^:dynamic *loop-bindings* nil)
(def ^:dynamic *ns-asts* [])  ;; Accumulated ASTs from loaded namespaces
(def ^:dynamic *keywords* {})    ;; keyword -> id mapping for interning
(def ^:dynamic *keyword-counter* 0)
(def ^:dynamic *strings* {})     ;; string -> id mapping for interning
(def ^:dynamic *string-counter* 0)
(def ^:dynamic *symbols* {})     ;; symbol -> id mapping for interning (for quoted symbols)
(def ^:dynamic *symbol-counter* 0)
(def ^:dynamic *enclosing-locals* #{})  ;; locals available for capture from enclosing scope
(def ^:dynamic *capture-map* nil)  ;; symbol -> index when inside closure, nil otherwise
(def ^:dynamic *callable-globals* #{})  ;; globals that hold callable values (not direct functions)
(def ^:dynamic *direct-fn-globals* {})  ;; map of name -> arity for direct functions
(def ^:dynamic *fn-refs* #{})  ;; direct function globals referenced as values (need wrappers)
(def ^:dynamic *macros* {})  ;; macro-name -> macro-fn (Clojure functions for compile-time expansion)
(def ^:dynamic *builtin-refs* #{})  ;; builtins used as values (not in call position)
(def ^:dynamic *gensym-counter* (atom 0))  ;; for generating unique symbols in macros

;; ============================================
;; Namespace / require support
;; ============================================

(def ^:dynamic *ns-aliases* {})           ;; "alias" -> "full.ns.name"
(def ^:dynamic *loaded-namespaces* #{})   ;; set of ns name strings already loaded
(def ^:dynamic *loading-namespaces* #{})  ;; for circular dependency detection
(def ^:dynamic *ns-load-fn* nil)          ;; (fn [ns-name-str] source-or-nil)
(def ^:dynamic *ns-read-fn* nil)          ;; (fn [source-str] forms-vec)
(def ^:dynamic *ns-prefix* nil)           ;; when loading a ns, prefix for defs (e.g. "laced_types_counter__")
(def ^:dynamic *ns-prefix-map* {})        ;; ns-name-str -> prefix string

;; ============================================
;; Protocol support
;; ============================================

(def ^:dynamic *protocols* {})  ;; protocol-name -> {:methods [{:name sym :params [...]} ...]}
(def ^:dynamic *protocol-methods* {})  ;; method-name -> {:protocol protocol-name :params [...]}
(def ^:dynamic *protocol-impls* {})  ;; [type method-name] -> impl-ast

;; ============================================
;; User-defined types (deftype/defrecord)
;; ============================================

(def ^:dynamic *user-types* {})      ;; type-name -> {:tag N, :fields [...], :kind :deftype/:defrecord}
(def ^:dynamic *next-type-tag* 20)   ;; built-in tags use 0-19 (0-14 core, 15-17 transient, 18 VectorSeq, 19 ArrayMap)

;; Type names used for extend-type
;; These map from Clojure-style type names to internal type tags
(def type-name->tag
  {'nil 0
   'Number 1
   'Integer 1
   'Boolean 1  ;; i31ref handles both int and bool
   'Keyword 2
   'String 3
   'Symbol 4
   'Float 5
   'Cons 6
   'List 6
   'ISeq 6
   'Vector 7
   'PersistentVector 7
   'HashMap 8
   'PersistentHashMap 8
   'HashSet 9
   'PersistentHashSet 9
   'Atom 10
   'IFn 11
   'Closure 11
   'LazySeq 12
   'Reduced 13
   'TransientVector 15
   'TransientHashMap 16
   'TransientHashSet 17
   'default -1})

;; ============================================
;; Builtin arities (for wrapper generation)
;; ============================================

(def builtin-arities
  "Map of builtin symbols to their arities."
  {'inc 1, 'dec 1, 'not 1, 'neg? 1, 'pos? 1, 'zero? 1, 'NaN? 1,
   'first 1, 'rest 1, 'nil? 1, 'cons? 1, 'count 1, 'vector? 1, 'map? 1,
   ;; Type predicates
   'list? 1, 'keyword? 1, 'keyword 1, 'keyword2 2, 'number? 1, 'integer? 1, 'fn? 1,
   'coll? 1, 'sequential? 1, 'associative? 1, 'counted? 1, 'indexed? 1,
   'true? 1, 'false? 1, 'some? 1,
   'string? 1, 'symbol? 1, 'float? 1, 'symbol 1, 'symbol2 2, 'namespace 1,
   ;; Seq functions
   'seq 1, 'seq? 1, 'seqable? 1, 'empty? 1,
   ;; Set functions
   'set? 1, 'empty-hash-set 0,
   ;; Map extensions
   'keys 1, 'vals 1,
   ;; Atom functions
   'atom 1, 'deref 1, 'atom? 1,
   'reset! 2, 'swap! 2,
   ;; Apply
   'apply 2,
   ;; Reduce functions
   'reduce 3, 'reduce-kv 3, 'reduced 1, 'reduced? 1,
   ;; String operations
   'str1 1, 'str-concat 2, 'name 1, 'subs 3, 'string->mem! 2, 'mem->string 2, 'pr-str1 1, 'char 1,
   ;; Float operations
   'to-float 1, 'to-int 1, 'math-floor 1, 'math-ceil 1, 'math-sqrt 1, 'math-abs 1, 'math-round 1,
   ;; Numeric
   'num 1,
   ;; Reflection stubs
   'type 1,
   '+ 2, '- 2, '* 2, '/ 2, '= 2, 'not= 2, '< 2, '> 2, '<= 2, '>= 2,
   'and 2, 'or 2, 'cons 2, 'nth 2, 'conj 2, 'get 2, 'contains? 2,
   'dissoc 2, 'disj 2, 'set-conj 2,
   'assoc 3, 'assoc-map 3,
   'empty-vector 0, 'empty-hash-map 0, 'make-array-map 2,
   ;; Bit operations
   'bit-and 2, 'bit-or 2, 'bit-xor 2, 'bit-not 1,
   'bit-shift-left 2, 'bit-shift-right 2, 'unsigned-bit-shift-right 2, 'bit-test 2,
   ;; Comparison
   'compare 2,
   ;; Print operations
   'print! 1, 'pr! 1, 'print-str! 1,
   ;; String primitives
   'str-index-of 2, 'str-to-lower 1, 'str-to-upper 1,
   'str-starts-with 2, 'str-ends-with 2, 'str-trim 1,
   'str-replace 3, 'str-split 2,
   ;; Array operations
   'make-array 1, 'aget 2, 'aset 3, 'alength 1, 'aclone 1, 'acopy 5,
   'object-array 1, 'array? 1, 'vector-from-array 1,
   ;; Transient collection operations
   'transient 1, 'persistent! 1,
   'conj! 2, 'assoc! 3, 'dissoc! 2, 'disj! 2, 'pop! 1,
   ;; Metadata
   'with-meta 2, 'meta 1,
   ;; Atom watches and validators
   'add-watch 3, 'remove-watch 2, 'set-validator! 2,
   ;; Regex
   're-pattern 1, 'regex-pattern 1, 'regex? 1})

;; ============================================
;; Gensym support for macros
;; ============================================

(defn woj-gensym
  "Generate a unique symbol for macro hygiene.
   Can be called with optional prefix string."
  ([] (woj-gensym "G__"))
  ([prefix]
   (symbol (str prefix (swap! *gensym-counter* inc)))))

;; ============================================
;; Error handling
;; ============================================

(defn with-source
  "Add source location from form metadata to AST node."
  [ast form]
  (if-let [m (meta form)]
    (cond-> ast
      (:line m) (assoc :line (:line m))
      (:column m) (assoc :column (:column m)))
    ast))

(defn throw-error
  "Throw an error with optional source location."
  ([msg] (throw (ex-info msg {})))
  ([msg form]
   (let [m (meta form)
         loc (cond
               (and (:line m) (:column m))
               (str " at line " (:line m) ", column " (:column m))
               (:line m)
               (str " at line " (:line m))
               :else "")]
     (throw (ex-info (str msg loc) {:form form})))))

;; ============================================
;; Free variable analysis (for closures)
;; ============================================

(defn free-vars
  "Recursively compute free variables in an AST.
   Returns set of symbols that are referenced but not in bound-vars.
   Stops at :fn boundaries since nested functions have their own scope."
  [ast bound-vars]
  (case (:op ast)
    :local
    (let [name (:name ast)]
      (if (contains? bound-vars name)
        #{}
        #{name}))

    :global #{}  ;; Globals are not captured
    :builtin #{}
    :builtin-ref #{}  ;; Builtin used as value
    :const #{}
    :nil #{}
    :keyword #{}
    :captured #{}  ;; Already a captured reference

    :let
    (let [bindings (:bindings ast)
          ;; Collect free vars from binding inits, accumulating bound vars
          [fv new-bound] (reduce (fn [[fv bound] {:keys [name init]}]
                                   [(into fv (free-vars init bound))
                                    (conj bound name)])
                                 [#{} bound-vars]
                                 bindings)]
      (into fv (free-vars (:body ast) new-bound)))

    :loop
    (let [bindings (:bindings ast)
          [fv new-bound] (reduce (fn [[fv bound] {:keys [name init]}]
                                   [(into fv (free-vars init bound))
                                    (conj bound name)])
                                 [#{} bound-vars]
                                 bindings)]
      (into fv (free-vars (:body ast) new-bound)))

    :if
    (into (free-vars (:test ast) bound-vars)
          (into (free-vars (:then ast) bound-vars)
                (free-vars (:else ast) bound-vars)))

    :do
    (reduce (fn [fv expr] (into fv (free-vars expr bound-vars)))
            #{}
            (:exprs ast))

    :call
    (let [fn-fv (free-vars (:fn ast) bound-vars)
          args-fv (reduce (fn [fv arg] (into fv (free-vars arg bound-vars)))
                          #{}
                          (:args ast))]
      (into fn-fv args-fv))

    :recur
    (reduce (fn [fv arg] (into fv (free-vars arg bound-vars)))
            #{}
            (:args ast))

    :set!
    (free-vars (:val ast) bound-vars)

    :def
    (free-vars (:init ast) bound-vars)

    :fn
    ;; For nested functions, their captures are our free vars (if not bound here)
    ;; If the fn has been analyzed and marked as a closure, use its :captures field
    ;; Otherwise compute free vars the normal way
    (if (:is-closure ast)
      ;; Already analyzed - its captures are free vars from our perspective
      (set/difference (set (:captures ast)) bound-vars)
      ;; Not analyzed yet - compute free vars of body relative to just its params
      (let [params (set (:params ast))
            body-fv (free-vars (:body ast) params)]
        (set/difference body-fv bound-vars)))

    :protocol-call
    (reduce (fn [fv arg] (into fv (free-vars arg bound-vars)))
            #{}
            (:args ast))

    :field-access
    (free-vars (:target ast) bound-vars)

    :instance?
    (free-vars (:val ast) bound-vars)

    :try
    (let [body-fv (free-vars (:body ast) bound-vars)
          catch-fv (if-let [catch-clause (:catch ast)]
                     (let [catch-bound (conj bound-vars (:binding catch-clause))]
                       (free-vars (:body catch-clause) catch-bound))
                     #{})
          finally-fv (if-let [finally-clause (:finally ast)]
                       (free-vars finally-clause bound-vars)
                       #{})]
      (into body-fv (into catch-fv finally-fv)))

    :throw
    (free-vars (:val ast) bound-vars)

    ;; Default - shouldn't happen
    #{}))

;; ============================================
;; Analyzer
;; ============================================

(declare analyze)

(defn analyze-const [form]
  (if (and (>= form -1073741824) (<= form 1073741823))
    {:op :const :val form :type :int :num-type :i32}
    {:op :const :val form :type :int}))

(defn analyze-bool [form]
  {:op :const :val (if form 1 0) :type :bool})

(defn analyze-nil []
  {:op :const :val 0 :type :nil})

(defn java-class-symbol?
  "Check if a symbol looks like a Java class reference."
  [sym]
  (let [s (str sym)
        ns-part (namespace sym)
        name-part (name sym)]
    (or
     ;; Fully qualified Java class (has dots)
     (and (string? s) (.contains s "."))
     ;; Simple capitalized name (Object, String, etc.)
     (and (not ns-part)
          (string? s)
          (not (empty? s))
          (Character/isUpperCase (first s)))
     ;; Java static field/method: Classname/FIELD or Classname/method
     (and ns-part
          (not (empty? ns-part))
          (Character/isUpperCase (first ns-part))))))

(defn analyze-symbol [sym]
  ;; Handle macro-only special symbols (return nil outside macros)
  (if (contains? #{'&env '&form} sym)
    {:op :nil}
    ;; Check if this is a captured variable in current closure context
    (if-let [idx (and *capture-map* (get *capture-map* sym))]
      {:op :captured :name sym :index idx}
      (if-let [info (get *env* sym)]
        (cond-> {:op :local :name sym}
          (:num-type info) (assoc :num-type (:num-type info)))
      ;; When in a namespace, try the prefixed version of the symbol first
        (let [ns-sym (when *ns-prefix* (symbol (str *ns-prefix* sym)))]
          (if-let [resolved (or (when (and ns-sym (contains? *globals* ns-sym)) ns-sym)
                                (when (contains? *globals* sym) sym))]
        ;; Distinguish between direct functions and other globals
            (if-let [fn-info (get *direct-fn-globals* resolved)]
              {:op :fn-global :name resolved :fn-info fn-info}  ;; Direct function, needs special handling
              {:op :global :name resolved})    ;; Callable global or other value
        ;; Check if available from enclosing scope (for free-vars analysis)
            (if (contains? *enclosing-locals* sym)
              {:op :local :name sym}  ;; Will be transformed to :captured in second pass
          ;; Check if it's a builtin being used as a value
              (if-let [arity (get builtin-arities sym)]
                (do
                  (set! *builtin-refs* (conj *builtin-refs* sym))
                  {:op :builtin-ref :name sym :arity arity})
            ;; If symbol has a namespace, resolve via alias or prefix map
                (if-let [ns (namespace sym)]
                  (let [;; Try resolving through namespace aliases first
                        full-ns (get *ns-aliases* ns)
                        prefix (when full-ns (get *ns-prefix-map* full-ns))
                        prefixed-sym (when prefix (symbol (str prefix (name sym))))
                        ;; Also try simple name as fallback
                        simple-sym (symbol (name sym))
                        ;; Resolve: prefixed first, then simple
                        resolved-sym (or (when (and prefixed-sym (contains? *globals* prefixed-sym)) prefixed-sym)
                                         (when (contains? *globals* simple-sym) simple-sym))]
                    (if resolved-sym
                      (if-let [fn-info (get *direct-fn-globals* resolved-sym)]
                        {:op :fn-global :name resolved-sym :fn-info fn-info}
                        {:op :global :name resolved-sym})
                      (if-let [arity (get builtin-arities simple-sym)]
                        (do
                          (set! *builtin-refs* (conj *builtin-refs* simple-sym))
                          {:op :builtin-ref :name simple-sym :arity arity})
                    ;; Java class reference or unknown namespace-qualified symbol
                    ;; Return nil stub to allow compilation
                        (if (java-class-symbol? sym)
                          {:op :nil}
                          {:op :nil}))))  ;; Unknown ns-qualified symbol - return nil
              ;; No namespace - check if Java class
                  (if (java-class-symbol? sym)
                    {:op :nil}
                    (throw-error (str "Unknown symbol: " sym) sym)))))))))))

(defn analyze-def [form]
  (when (< (count form) 2)
    (throw-error "def requires a name" form))
  (let [bare-name (second form)
        ;; When loading a namespace, prefix the def name to avoid cross-namespace collisions
        name (if *ns-prefix*
               (symbol (str *ns-prefix* bare-name))
               bare-name)
        ;; Support (def x) without init - defaults to nil
        init (if (> (count form) 2) (nth form 2) nil)]
    ;; Add to globals BEFORE analyzing body (enables recursion)
    (set! *globals* (conj *globals* name))
    ;; Pre-register in *direct-fn-globals* if init is a fn literal,
    ;; so recursive self-references used as values (e.g. (map f ...)) get :fn-global ops
    (when (and (seq? init) (contains? #{'fn 'fn*} (first init)))
      (set! *direct-fn-globals* (assoc *direct-fn-globals* name
                                       {:arities #{} :variadic? true :min-arity 0})))
    (let [init-ast (analyze init)
          is-direct-fn (= :fn (:op init-ast))]
      ;; If init is not a direct fn literal, it's a callable value (could be closure)
      (if is-direct-fn
        ;; Store arity info: {:arities #{1 2 3} :variadic? bool :min-arity n}
        (let [arities (or (:arities init-ast) [{:arity (count (:params init-ast))
                                                :variadic? (:variadic? init-ast)}])
              fixed-arities (set (map :arity (filter (complement :variadic?) arities)))
              variadic? (some :variadic? arities)
              min-arity (if (seq arities)
                          (apply min (map :arity arities))
                          0)
              variadic-arity (when variadic?
                               (:arity (first (filter :variadic? arities))))]
          (set! *direct-fn-globals* (assoc *direct-fn-globals* name
                                           {:arities fixed-arities
                                            :variadic? variadic?
                                            :min-arity min-arity
                                            :variadic-arity variadic-arity})))
        (set! *callable-globals* (conj *callable-globals* name)))
      {:op :def :name name :init init-ast})))

;; ============================================
;; Destructuring support
;; ============================================

(declare expand-map-destructuring)

(defn expand-seq-destructuring
  "Expand sequential destructuring pattern into let bindings.
   Returns a vector of [symbol init-expr] pairs.
   tmp-sym is the symbol bound to the full collection.
   Supports & rest and :as bindings."
  [pattern tmp-sym]
  (loop [elems (seq pattern)
         idx 0
         bindings []]
    (if (empty? elems)
      bindings
      (let [elem (first elems)]
        (cond
          ;; & rest - bind rest of sequence
          (= elem '&)
          (let [rest-sym (second elems)
                remaining (drop 2 elems)
                bindings (if (and rest-sym (symbol? rest-sym) (not= rest-sym '_))
                           (conj bindings [rest-sym (list 'drop idx tmp-sym)])
                           bindings)]
            ;; Check for :as after & rest
            (if (and (seq remaining) (= (first remaining) :as))
              (let [as-sym (second remaining)]
                (conj bindings [as-sym tmp-sym]))
              bindings))

          ;; :as - bind the full collection
          (= elem :as)
          (let [as-sym (second elems)]
            (conj bindings [as-sym tmp-sym]))

          ;; _ - ignore this element
          (= elem '_)
          (recur (next elems) (inc idx) bindings)

          ;; Symbol - simple binding
          (symbol? elem)
          (recur (next elems) (inc idx)
                 (conj bindings [elem (list 'nth tmp-sym idx)]))

          ;; Nested vector - recursive destructuring
          (vector? elem)
          (let [nested-tmp (woj-gensym "vec__")]
            (recur (next elems) (inc idx)
                   (into (conj bindings [nested-tmp (list 'nth tmp-sym idx)])
                         (expand-seq-destructuring elem nested-tmp))))

          ;; Nested map - recursive destructuring
          (map? elem)
          (let [nested-tmp (woj-gensym "map__")]
            (recur (next elems) (inc idx)
                   (into (conj bindings [nested-tmp (list 'nth tmp-sym idx)])
                         (expand-map-destructuring elem nested-tmp))))

          ;; Skip other forms
          :else
          (recur (next elems) (inc idx) bindings))))))

(defn expand-map-destructuring
  "Expand map destructuring pattern into let bindings.
   Returns a vector of [symbol init-expr] pairs.
   Supports :keys, :as, :or, and explicit {sym :key} bindings."
  [pattern tmp-sym]
  (let [keys-vec (:keys pattern)
        as-sym (:as pattern)
        or-map (:or pattern)
        ;; Explicit bindings are entries that aren't special keys
        explicit (dissoc pattern :keys :as :or :strs :syms)
        bindings (vec
                  (concat
                     ;; :keys bindings - {:keys [a b]} -> a (get m :a), b (get m :b)
                   (when keys-vec
                     (for [k keys-vec]
                       (let [sym (if (symbol? k) k (symbol (name k)))
                             kw (keyword (name (if (symbol? k) k (symbol (name k)))))
                             default (when or-map (get or-map sym))]
                         (if default
                           [sym (list 'or (list 'get tmp-sym kw) default)]
                           [sym (list 'get tmp-sym kw)]))))
                     ;; Explicit bindings - {x :x-key} -> x (get m :x-key)
                   (for [[sym key-expr] explicit]
                     (let [default (when or-map (get or-map sym))]
                       (if default
                         [sym (list 'or (list 'get tmp-sym key-expr) default)]
                         [sym (list 'get tmp-sym key-expr)])))
                     ;; :as binding
                   (when as-sym
                     [[as-sym tmp-sym]])))]
    bindings))

(defn expand-destructuring-binding
  "Expand a single binding pair [pattern init] into multiple simple bindings.
   Returns a vector of [symbol init-expr] pairs."
  [pattern init]
  (cond
    ;; Simple symbol - no destructuring needed
    (symbol? pattern)
    [[pattern init]]

    ;; Sequential destructuring
    (vector? pattern)
    (let [tmp-sym (woj-gensym "seq__")]
      (into [[tmp-sym init]]
            (expand-seq-destructuring pattern tmp-sym)))

    ;; Map destructuring
    (map? pattern)
    (let [tmp-sym (woj-gensym "map__")]
      (into [[tmp-sym init]]
            (expand-map-destructuring pattern tmp-sym)))

    :else
    (throw (ex-info (str "Invalid binding pattern: " pattern) {:pattern pattern}))))

(defn expand-destructuring-bindings
  "Expand a bindings vector, handling destructuring.
   Returns a new bindings vector with only simple symbol bindings."
  [bindings]
  (vec (mapcat (fn [[pattern init]]
                 (apply concat (expand-destructuring-binding pattern init)))
               (partition 2 bindings))))

(defn expand-fn-destructuring
  "Expand destructuring in fn parameters.
   Returns [new-params wrapper-bindings] where wrapper-bindings
   should be wrapped in a let around the body."
  [params]
  (loop [ps params
         new-params []
         bindings []]
    (if (empty? ps)
      [new-params bindings]
      (let [p (first ps)]
        (cond
          ;; & rest - keep as-is, rest is always a simple symbol
          (= p '&)
          (recur (nnext ps)
                 (conj new-params '& (second ps))
                 bindings)

          ;; Simple symbol - no destructuring needed
          (symbol? p)
          (recur (next ps) (conj new-params p) bindings)

          ;; Vector - sequential destructuring
          (vector? p)
          (let [tmp-sym (woj-gensym "p__")
                expanded (expand-seq-destructuring p tmp-sym)]
            (recur (next ps)
                   (conj new-params tmp-sym)
                   (into bindings expanded)))

          ;; Map - map destructuring
          (map? p)
          (let [tmp-sym (woj-gensym "p__")
                expanded (expand-map-destructuring p tmp-sym)]
            (recur (next ps)
                   (conj new-params tmp-sym)
                   (into bindings expanded)))

          :else
          (throw (ex-info (str "Invalid fn parameter: " p) {:param p})))))))

(defn- ast-has-recur?
  "Check if an AST contains :recur nodes at the current fn level (not inside nested fns)."
  [ast]
  (when (map? ast)
    (case (:op ast)
      :recur true
      ;; Don't descend into nested fn/fn-expr/loop - recur there targets those forms
      (:fn :fn-expr :loop) false
      ;; Check all children
      (some ast-has-recur?
            (concat
             (when (:test ast) [(:test ast)])
             (when (:then ast) [(:then ast)])
             (when (:else ast) [(:else ast)])
             (when (:body ast) [(:body ast)])
             (:args ast)
             (:exprs ast)
             (map :init (:bindings ast)))))))

(defn- parse-variadic-params
  "Parse params vector, handling & rest syntax.
   Returns {:params [...] :rest-param sym-or-nil :variadic? bool}"
  [params]
  (let [params-vec (vec params)
        amp-idx (.indexOf params-vec '&)]
    (if (neg? amp-idx)
      {:params params-vec :rest-param nil :variadic? false}
      {:params (vec (take amp-idx params-vec))
       :rest-param (get params-vec (inc amp-idx))
       :variadic? true})))

(defn- analyze-single-arity
  "Analyze a single arity of a function.
   Returns {:arity n :params [...] :body ast :rest-param sym-or-nil :variadic? bool :captures [...] :is-closure bool}"
  [raw-params body-forms fn-name old-env old-enclosing old-capture-map]
  ;; Expand destructuring in parameters
  (let [[params destructure-bindings] (expand-fn-destructuring raw-params)
        ;; Parse variadic params
        {:keys [params rest-param variadic?]} (parse-variadic-params params)
        ;; Build actual params list (required params + rest-param if variadic)
        all-params (if variadic?
                     (conj params rest-param)
                     params)
        ;; If we have destructuring, wrap body in let
        body-forms (if (seq destructure-bindings)
                     (list (list* 'let (vec (apply concat destructure-bindings)) body-forms))
                     body-forms)
        ;; Handle pre/post conditions: {:pre [...] :post [...]} as first body form
        body-forms (let [first-form (first body-forms)]
                     (if (and (map? first-form)
                              (or (contains? first-form :pre) (contains? first-form :post)))
                       (let [pre-conds (:pre first-form)
                             post-conds (:post first-form)
                             real-body (rest body-forms)
                             ;; Pre-conditions: (when-not cond (throw (ex-info "Assert failed: ..." {})))
                             pre-checks (when (seq pre-conds)
                                          (map (fn [c]
                                                 (list 'when-not c
                                                       (list 'throw (list 'ex-info
                                                                          (str "Assert failed: " (pr-str c))
                                                                          {}))))
                                               pre-conds))
                             ;; Post-conditions: wrap body in let, check % against conditions
                             body-with-post (if (seq post-conds)
                                             (let [result-sym (woj-gensym "result__")]
                                               (list (list* 'let [result-sym (cons 'do real-body)]
                                                            (concat
                                                             (map (fn [c]
                                                                    ;; Replace % with result-sym in post-condition
                                                                    (clojure.walk/postwalk
                                                                     (fn [x] (if (= x '%) result-sym x))
                                                                     (list 'when-not c
                                                                           (list 'throw (list 'ex-info
                                                                                              (str "Assert failed: " (pr-str c))
                                                                                              {})))))
                                                                  post-conds)
                                                             (list result-sym)))))
                                             real-body)]
                         (if (seq pre-checks)
                           (concat pre-checks body-with-post)
                           body-with-post))
                       body-forms))
        ;; Add params to env, and fn-name if present (for self-reference)
        param-env (cond-> (into {} (map (fn [p] [p {:kind :local}]) all-params))
                    fn-name (assoc fn-name {:kind :local}))
        ;; Current env's locals become enclosing locals for nested fn
        current-locals (set (keys (filter (fn [[_ v]] (= (:kind v) :local)) *env*)))
        ;; Include this fn's params (and fn-name if any) in enclosing locals for nested functions
        params-set (cond-> (set all-params)
                     fn-name (conj fn-name))
        loop-bound? (thread-bound? #'*loop-bindings*)
        old-loop-bindings (when loop-bound? *loop-bindings*)]
    (set! *env* (merge *env* param-env))
    (set! *enclosing-locals* (into (into *enclosing-locals* current-locals) params-set))
    ;; Set loop-bindings to fn params so recur works at fn tail position
    (when loop-bound? (set! *loop-bindings* (vec all-params)))
    ;; First pass: analyze body without capture map to find free vars
    (set! *capture-map* nil)
    (let [body-ast-pass1 (if (= 1 (count body-forms))
                           (analyze (first body-forms))
                           {:op :do :exprs (into [] (map analyze body-forms))})
          ;; Compute free variables in body (excluding params and fn-name for self-reference)
          fv-exclude (cond-> (set all-params)
                       fn-name (conj fn-name))
          fv (free-vars body-ast-pass1 fv-exclude)
          ;; Filter to only locals available for capture (not globals)
          captures (vec (sort (filter #(contains? *enclosing-locals* %) fv)))
          is-closure (seq captures)]
      (if is-closure
        ;; Second pass: re-analyze with capture map to generate :captured nodes
        (let [capture-indices (into {} (map-indexed (fn [i sym] [sym i]) captures))]
          (set! *env* (merge old-env param-env))  ;; Reset env for re-analysis
          (set! *capture-map* capture-indices)
          (when loop-bound? (set! *loop-bindings* (vec all-params)))  ;; Re-set for second pass
          (let [body-ast (if (= 1 (count body-forms))
                           (analyze (first body-forms))
                           {:op :do :exprs (into [] (map analyze body-forms))})]
            (set! *env* old-env)
            (set! *enclosing-locals* old-enclosing)
            (set! *capture-map* old-capture-map)
            (when loop-bound? (set! *loop-bindings* old-loop-bindings))
            {:arity (count params)
             :params params
             :rest-param rest-param
             :variadic? variadic?
             :body body-ast
             :captures captures
             :is-closure true
             :has-recur (boolean (ast-has-recur? body-ast))}))
        ;; Not a closure, use first pass result
        (do
          (set! *env* old-env)
          (set! *enclosing-locals* old-enclosing)
          (set! *capture-map* old-capture-map)
          (when loop-bound? (set! *loop-bindings* old-loop-bindings))
          {:arity (count params)
           :params params
           :rest-param rest-param
           :variadic? variadic?
           :body body-ast-pass1
           :captures []
           :is-closure false
           :has-recur (boolean (ast-has-recur? body-ast-pass1))})))))

(defn- is-multi-arity-fn?
  "Check if form is multi-arity: (fn ([x] ...) ([x y] ...))"
  [form has-name]
  (let [body-start (if has-name 2 1)
        first-body (nth form body-start nil)]
    (and (seq? first-body)
         (vector? (first first-body)))))

(defn analyze-fn [form]
  ;; Handle (fn [params] body), (fn name [params] body),
  ;; (fn ([x] ...) ([x y] ...)), (fn name ([x] ...) ([x y] ...))
  (let [has-name (symbol? (second form))
        fn-name (when has-name (second form))
        old-env *env*
        old-enclosing *enclosing-locals*
        old-capture-map *capture-map*]
    (if (is-multi-arity-fn? form has-name)
      ;; Multi-arity function
      (let [arity-forms (drop (if has-name 2 1) form)
            arities (mapv (fn [arity-form]
                            (let [raw-params (first arity-form)
                                  body-forms (rest arity-form)]
                              (analyze-single-arity raw-params body-forms fn-name
                                                    old-env old-enclosing old-capture-map)))
                          arity-forms)
            ;; Collect all captures across arities
            all-captures (vec (sort (distinct (mapcat :captures arities))))
            is-closure (seq all-captures)
            ;; Check for variadic arity
            variadic-arity (first (filter :variadic? arities))
            fixed-arities (filter (complement :variadic?) arities)]
        {:op :fn
         :fn-name fn-name
         :arities arities
         :captures all-captures
         :is-closure is-closure
         :variadic-arity variadic-arity
         :fixed-arities (vec fixed-arities)
         :max-arity (apply max (map :arity arities))
         :min-arity (apply min (map :arity arities))})
      ;; Single-arity function (legacy format)
      (let [raw-params (if has-name (nth form 2) (second form))
            body-forms (drop (if has-name 3 2) form)
            arity-info (analyze-single-arity raw-params body-forms fn-name
                                             old-env old-enclosing old-capture-map)]
        ;; For backward compatibility, emit the old single-arity format
        ;; but include :arities for uniformity
        {:op :fn
         :fn-name fn-name
         :params (:params arity-info)
         :rest-param (:rest-param arity-info)
         :variadic? (:variadic? arity-info)
         :body (:body arity-info)
         :captures (:captures arity-info)
         :is-closure (:is-closure arity-info)
         :has-recur (:has-recur arity-info)
         ;; Also include arities for future compatibility
         :arities [arity-info]}))))

(defn analyze-let [form]
  (when (< (count form) 2)
    (throw-error "let requires a binding vector" form))
  (when-not (vector? (second form))
    (throw-error (str "let requires a vector for its bindings, got " (type (second form))) form))
  (when (odd? (count (second form)))
    (throw-error "let requires an even number of forms in binding vector" form))
  (let [raw-bindings (second form)
        body-forms (drop 2 form)
        ;; Expand destructuring in bindings
        bindings (expand-destructuring-bindings raw-bindings)
        old-env *env*]
    (loop [pairs (partition 2 bindings)
           analyzed-bindings []]
      (if (empty? pairs)
        (let [body-ast (if (= 1 (count body-forms))
                         (analyze (first body-forms))
                         {:op :do :exprs (into [] (map analyze body-forms))})
              result {:op :let
                      :bindings analyzed-bindings
                      :body body-ast}]
          (set! *env* old-env)
          result)
        (let [pair (first pairs)
              name (first pair)
              init (second pair)
              init-ast (analyze init)]
          (set! *env* (assoc *env* name (cond-> {:kind :local}
                                                 (:num-type init-ast) (assoc :num-type (:num-type init-ast)))))
          (recur (rest pairs)
                 (conj analyzed-bindings {:name name :init init-ast})))))))

(defn analyze-if [form]
  (when (< (count form) 3)
    (throw-error (str "if requires at least 2 arguments (test and then), got " (dec (count form))) form))
  (when (> (count form) 4)
    (throw-error (str "if takes at most 3 arguments (test, then, else), got " (dec (count form))) form))
  (let [test (nth form 1)
        then (nth form 2)
        else (if (> (count form) 3) (nth form 3) 0)]
    {:op :if
     :test (analyze test)
     :then (analyze then)
     :else (analyze else)}))

(defn analyze-loop [form]
  (when (< (count form) 2)
    (throw-error "loop requires a binding vector" form))
  (when-not (vector? (second form))
    (throw-error (str "loop requires a vector for its bindings, got " (type (second form))) form))
  (when (odd? (count (second form)))
    (throw-error "loop requires an even number of forms in binding vector" form))
  (let [raw-bindings (second form)
        body-forms (drop 2 form)
        pairs (partition 2 raw-bindings)
        ;; Check if any binding uses destructuring
        has-destructuring (some (fn [[pattern _]] (or (vector? pattern) (map? pattern))) pairs)]
    (if has-destructuring
      ;; Expand destructuring: replace complex patterns with temp symbols,
      ;; and wrap body in a let that re-destructures on each iteration.
      ;; (loop [[x & xs] coll, acc 0] body...)
      ;; => (loop [tmp coll, acc 0] (let [[x & xs] tmp] body...))
      (let [new-bindings (vec (mapcat
                                (fn [[pattern init]]
                                  (if (symbol? pattern)
                                    [pattern init]
                                    (let [tmp (woj-gensym "loop__")]
                                      [tmp init])))
                                pairs))
            destr-bindings (vec (mapcat
                                 (fn [[pattern _init]]
                                   (if (symbol? pattern)
                                     []
                                     (let [;; Find the corresponding tmp symbol
                                           idx (.indexOf (mapv first (partition 2 raw-bindings)) pattern)
                                           tmp (nth (take-nth 2 new-bindings) idx)]
                                       [pattern tmp])))
                                 pairs))
            new-body (if (seq destr-bindings)
                       (list (list* 'let destr-bindings body-forms))
                       body-forms)]
        (analyze (list* 'loop new-bindings new-body)))
      ;; No destructuring — original fast path
      (let [old-env *env*
            old-loop-bindings *loop-bindings*]
        (loop [ps pairs
               analyzed-bindings []
               binding-names []]
          (if (empty? ps)
            (do
              (set! *loop-bindings* binding-names)
              (let [body-ast (if (= 1 (count body-forms))
                               (analyze (first body-forms))
                               {:op :do :exprs (into [] (map analyze body-forms))})
                    result {:op :loop
                            :bindings analyzed-bindings
                            :body body-ast}]
                (set! *env* old-env)
                (set! *loop-bindings* old-loop-bindings)
                result))
            (let [pair (first ps)
                  name (first pair)
                  init (second pair)
                  init-ast (analyze init)]
              (set! *env* (assoc *env* name (cond-> {:kind :local}
                                                     (:num-type init-ast) (assoc :num-type (:num-type init-ast)))))
              (recur (rest ps)
                     (conj analyzed-bindings {:name name :init init-ast})
                     (conj binding-names name)))))))))

(defn analyze-recur [form]
  (when-not *loop-bindings*
    (throw-error "recur outside of loop" form))
  (let [args (rest form)]
    (when-not (= (count args) (count *loop-bindings*))
      (throw-error (str "recur arity mismatch: expected " (count *loop-bindings*)
                        " args, got " (count args)) form))
    (with-source
      {:op :recur
       :args (into [] (map analyze args))
       :bindings *loop-bindings*}
      form)))

(defn analyze-do [form]
  (let [raw-exprs (vec (rest form))
        n (count raw-exprs)
        ;; Filter nils from reader conditionals in leading positions,
        ;; but always preserve the last expression (explicit nil return)
        exprs (if (= 0 n)
                []
                (let [leading (remove nil? (butlast raw-exprs))
                      last-expr (nth raw-exprs (dec n))]
                  (concat leading [last-expr])))]
    (if (empty? exprs)
      {:op :const :val 0 :type :nil}
      {:op :do :exprs (into [] (map analyze exprs))})))

(defn analyze-when [form]
  (let [test (nth form 1)
        body-forms (drop 2 form)]
    (if (empty? body-forms)
      ;; (when test) with no body: evaluate test, return nil
      {:op :do :exprs [(analyze test) {:op :const :val 0 :type :nil}]}
      (let [body-ast (if (= 1 (count body-forms))
                       (analyze (first body-forms))
                       {:op :do :exprs (into [] (map analyze body-forms))})]
        {:op :if
         :test (analyze test)
         :then body-ast
         :else {:op :const :val 0 :type :nil}}))))

(defn analyze-when-not [form]
  (let [test (nth form 1)
        body-forms (drop 2 form)]
    (if (empty? body-forms)
      ;; (when-not test) with no body: evaluate test, return nil
      {:op :do :exprs [(analyze test) {:op :const :val 0 :type :nil}]}
      (let [body-ast (if (= 1 (count body-forms))
                       (analyze (first body-forms))
                       {:op :do :exprs (into [] (map analyze body-forms))})]
        {:op :if
         :test (analyze test)
         :then {:op :const :val 0 :type :nil}
         :else body-ast}))))

(defn analyze-set! [form]
  (when (not= (count form) 3)
    (throw-error (str "set! requires exactly 2 arguments (target and value), got " (dec (count form))) form))
  (let [target (nth form 1)
        val-form (nth form 2)]
    (when-not (symbol? target)
      (throw-error "set! target must be a symbol" form))
    (when-not (contains? *globals* target)
      (throw-error (str "set! target must be a global: " target) form))
    {:op :set! :name target :val (analyze val-form)}))

(defn analyze-defn [form]
  (let [name (second form)
        ;; Skip optional docstring
        has-docstring (string? (nth form 2 nil))
        params (if has-docstring (nth form 3) (nth form 2))
        body (drop (if has-docstring 4 3) form)]
    (analyze (list 'def name (cons 'fn (cons params body))))))

;; ============================================
;; clojure.test support
;; ============================================

(defn nest-additions
  "Convert a list of forms into nested binary additions: [a b c] -> (+ (+ a b) c)"
  [forms]
  (if (= 1 (count forms))
    (first forms)
    (reduce (fn [acc form] (list '+ acc form))
            (first forms)
            (rest forms))))

(defn analyze-is
  "Analyze (is expr) - returns 0 if expr is truthy, 1 if falsy.
   This allows test results to be summed: 0 = all pass, >0 = failure count."
  [form]
  (let [expr (second form)]
    {:op :if
     :test (analyze expr)
     :then {:op :const :val 0 :type :int}
     :else {:op :const :val 1 :type :int}}))

(defn analyze-testing
  "Analyze (testing desc body...) - ignores desc string, sums body results."
  [form]
  (let [body-forms (remove nil? (drop 2 form))]  ; Skip 'testing and description, filter nils
    (if (empty? body-forms)
      {:op :const :val 0 :type :int}
      ;; Use nested additions to sum all body results
      (analyze (nest-additions (vec body-forms))))))

(defn expand-are
  "Expand (are [bindings] expr val1 val2 ...) into summed is forms.
   Example: (are [x y] (= x y) 1 1 2 2)
   Expands to: (+ (is (= 1 1)) (is (= 2 2)))
   Uses textual substitution like Clojure's do-template."
  [form]
  (let [bindings (nth form 1)       ; [x y]
        expr (nth form 2)           ; (= x y)
        values (drop 3 form)        ; 1 1 2 2 ...
        arity (count bindings)
        groups (partition arity values)]
    (if (empty? groups)
      0  ; No values = pass
      (let [is-forms (map
                      (fn [vals]
                         ;; Create substitution map: binding -> value (textual substitution)
                        (let [subst-map (zipmap bindings vals)
                               ;; Substitute in expression
                              subst-expr (walk/postwalk
                                          (fn [x]
                                            (if (and (symbol? x) (contains? subst-map x))
                                              (get subst-map x)
                                              x))
                                          expr)]
                          (list 'is subst-expr)))
                      groups)]
        (nest-additions (vec is-forms))))))

(defn analyze-are [form]
  "Analyze (are ...) by expanding and analyzing."
  (analyze (expand-are form)))

;; ============================================
;; Namespace require implementation
;; ============================================

(def ^:private builtin-namespaces
  "Namespaces that are built-in and should not be loaded from files."
  #{"clojure.core" "clojure.test"})

(defn- parse-require-spec
  "Parse a single require spec into a map.
   Handles: bare symbol, [ns.name :as alias :refer [syms]]
   Ignores :refer-macros (resolved by reader conditionals before we see it)."
  [spec]
  (cond
    (symbol? spec)
    {:ns-name (str spec)}

    (vector? spec)
    (let [ns-sym (first spec)
          opts (rest spec)]
      (loop [opts opts
             result {:ns-name (str ns-sym)}]
        (if (empty? opts)
          result
          (let [k (first opts)]
            (cond
              (= k :as)
              (recur (drop 2 opts)
                     (assoc result :as (str (second opts))))

              (= k :refer)
              (recur (drop 2 opts)
                     (assoc result :refer (second opts)))

              ;; Skip :refer-macros and its value (CLJS compat)
              (= k :refer-macros)
              (recur (drop 2 opts) result)

              ;; Skip unknown options
              :else
              (recur (rest opts) result))))))

    :else nil))

(defn- ns-name->prefix
  "Convert a namespace name to a WAT-safe prefix.
   e.g., \"laced.types.counter\" -> \"laced_types_counter__\""
  [ns-name-str]
  (str (-> ns-name-str
           (str/replace "." "_")
           (str/replace "-" "_"))
       "__"))

(defn- load-namespace!
  "Load a namespace's source file and analyze its forms.
   Skips built-in namespaces and already-loaded namespaces.
   Detects circular dependencies."
  [ns-name-str]
  (when-not (contains? builtin-namespaces ns-name-str)
    (when-not (contains? *loaded-namespaces* ns-name-str)
      (when (contains? *loading-namespaces* ns-name-str)
        (throw (ex-info (str "Circular namespace dependency: " ns-name-str)
                        {:ns ns-name-str})))
      (when *ns-load-fn*
        (when-let [source (*ns-load-fn* ns-name-str)]
          (set! *loading-namespaces* (conj *loading-namespaces* ns-name-str))
          (let [prefix (ns-name->prefix ns-name-str)
                forms (*ns-read-fn* source)]
            ;; Store the prefix for this namespace so aliased calls can use it
            (set! *ns-prefix-map* (assoc *ns-prefix-map* ns-name-str prefix))
            (binding [*ns-prefix* prefix]
              (doseq [form forms]
                (let [ast (analyze form)]
                  (set! *ns-asts* (conj *ns-asts* ast))))))
          (set! *loading-namespaces* (disj *loading-namespaces* ns-name-str))
          (set! *loaded-namespaces* (conj *loaded-namespaces* ns-name-str)))))))

(defn analyze-ns
  "Analyze (ns name & clauses).
   Parses :require clauses, loads dependencies, and registers aliases.
   Returns nil AST (ns produces no runtime code)."
  [form]
  (let [clauses (drop 2 form)]  ;; skip 'ns and name
    (doseq [clause clauses]
      (when (and (seq? clause) (= :require (first clause)))
        (doseq [spec (rest clause)]
          (when-let [parsed (parse-require-spec spec)]
            (load-namespace! (:ns-name parsed))
            (when-let [alias (:as parsed)]
              (set! *ns-aliases* (assoc *ns-aliases* alias (:ns-name parsed)))))))))
  {:op :const :val 0 :type :nil})

(defn analyze-throw
  "Analyze (throw expr) - throws an exception with value expr."
  [form]
  {:op :throw :val (analyze (second form))})

(defn analyze-try
  "Analyze (try body... (catch ExType e handler...) (finally cleanup...))
   Compiles to WASM exception handling with try_table/throw."
  [form]
  (let [clauses (rest form)
        ;; Split into body, catch, and finally
        body-forms (take-while #(not (and (seq? %) (contains? #{'catch 'finally} (first %)))) clauses)
        catch-finally (drop-while #(not (and (seq? %) (contains? #{'catch 'finally} (first %)))) clauses)
        catch-clause (first (filter #(and (seq? %) (= 'catch (first %))) catch-finally))
        finally-clause (first (filter #(and (seq? %) (= 'finally (first %))) catch-finally))
        ;; Parse catch: (catch ExType e body...) or (catch :default e body...)
        ;; Also handles elided exception type from reader conditionals: (catch e body...)
        catch-ast (when catch-clause
                    (let [;; Detect if exception type was elided by reader conditional:
                          ;; Normal: (catch Type binding body...) — (nth 2) is a symbol
                          ;; Elided: (catch binding body...) — (nth 2) is a list/form
                          type-elided? (and (>= (count catch-clause) 3)
                                           (not (symbol? (nth catch-clause 2))))
                          ex-type (if type-elided? :default (nth catch-clause 1))
                          binding (if type-elided? (nth catch-clause 1) (nth catch-clause 2))
                          catch-body (drop (if type-elided? 2 3) catch-clause)
                          old-env *env*
                          _ (set! *env* (assoc *env* binding {:kind :local}))
                          body-ast (if (= (count catch-body) 1)
                                     (analyze (first catch-body))
                                     {:op :do :exprs (mapv analyze catch-body)})
                          _ (set! *env* old-env)]
                      {:type (if (= ex-type :default) :default (symbol (name ex-type)))
                       :binding binding
                       :body body-ast}))
        ;; Parse finally: (finally body...)
        finally-ast (when finally-clause
                      (let [finally-body (rest finally-clause)]
                        (if (= (count finally-body) 1)
                          (analyze (first finally-body))
                          {:op :do :exprs (mapv analyze finally-body)})))
        ;; Analyze body
        body-ast (if (= (count body-forms) 1)
                   (analyze (first body-forms))
                   {:op :do :exprs (mapv analyze body-forms)})]
    {:op :try
     :body body-ast
     :catch catch-ast
     :finally finally-ast}))

(defn analyze-deftest
  "Analyze (deftest name body...) - creates a function returning sum of test results.
   Returns 0 if all tests pass, >0 = number of failures."
  [form]
  (let [name (second form)
        body-forms (remove nil? (drop 2 form))]  ; filter nils from reader conditionals
    (if (empty? body-forms)
      ;; Empty test = pass
      (analyze (list 'defn name [] 0))
      ;; Wrap body in nested binary additions to sum all results
      (let [summed-body (nest-additions (vec body-forms))]
        (analyze (list 'defn name [] summed-body))))))

(defn analyze-defmacro [form]
  "Define a macro. The macro body is evaluated as Clojure code at compile time.
   Macros receive unevaluated forms and return transformed code.
   Macros have access to gensym for generating unique symbols."
  (let [name (second form)
        params (nth form 2)
        body (drop 3 form)
        ;; Create and eval a Clojure function for the macro
        ;; We wrap the body to provide gensym, &env, &form as local bindings
        ;; &env and &form are nil since we don't have Clojure's macro environment
        gensym-fn woj-gensym
        macro-fn (eval `(fn ~params
                          (let [~'gensym ~gensym-fn
                                ~'&env nil
                                ~'&form nil]
                            ~@body)))]
    (set! *macros* (assoc *macros* name macro-fn))
    ;; defmacro produces no runtime code
    {:op :const :val 0 :type :nil}))

(defn woj-macroexpand-1 [form]
  "If form is a macro call, expand it once. Otherwise return form unchanged."
  (if (and (seq? form) (symbol? (first form)))
    (if-let [macro-fn (get *macros* (first form))]
      (apply macro-fn (rest form))
      form)
    form))

(defn analyze-cond [form]
  (let [clauses (partition 2 (rest form))]
    (if (empty? clauses)
      {:op :const :val 0 :type :nil}
      (reduce (fn [else-ast [test expr]]
                {:op :if
                 :test (if (= test :else)
                         ;; :else is always truthy - use a boxed 1
                         {:op :const :val 1 :type :bool}
                         (analyze test))
                 :then (analyze expr)
                 :else else-ast})
              {:op :const :val 0 :type :nil}
              (reverse clauses)))))

(defn expand-thread-first
  "Expand (-> x (f a) (g b)) into (g (f x a) b).
   Each form can be a list (insert as first arg) or symbol (wrap in list)."
  [form]
  (let [forms (rest form)]
    (if (< (count forms) 2)
      ;; (-> x) just returns x
      (first forms)
      (let [init (first forms)
            steps (rest forms)]
        (reduce (fn [acc step]
                  (if (seq? step)
                    ;; (f a b) + x => (f x a b)
                    (cons (first step) (cons acc (rest step)))
                    ;; f + x => (f x)
                    (list step acc)))
                init
                steps)))))

(defn analyze-thread-first [form]
  "Analyze -> by expanding it and then analyzing the result."
  (analyze (expand-thread-first form)))

(defn expand-thread-last
  "Expand (->> x (f a) (g b)) into (g b (f a x)).
   Each form can be a list (insert as last arg) or symbol (wrap in list)."
  [form]
  (let [forms (rest form)]
    (if (< (count forms) 2)
      (first forms)
      (let [init (first forms)
            steps (rest forms)]
        (reduce (fn [acc step]
                  (if (seq? step)
                    ;; (f a b) + x => (f a b x)
                    (concat step (list acc))
                    ;; f + x => (f x)
                    (list step acc)))
                init
                steps)))))

(defn analyze-thread-last [form]
  "Analyze ->> by expanding it and then analyzing the result."
  (analyze (expand-thread-last form)))

(defn analyze-list [form]
  "Analyze (list a b c) into nested cons calls: (cons a (cons b (cons c nil)))"
  (let [elements (rest form)]
    (if (empty? elements)
      {:op :nil}
      (reduce (fn [rest-ast elem]
                {:op :call
                 :fn {:op :builtin :name 'cons}
                 :args [(analyze elem) rest-ast]})
              {:op :nil}
              (reverse elements)))))

(defn analyze-vector-elements [elements]
  "Analyze vector elements into repeated conj calls"
  (if (empty? elements)
    {:op :call :fn {:op :builtin :name 'empty-vector} :args []}
    (reduce (fn [vec-ast elem]
              {:op :call
               :fn {:op :builtin :name 'conj}
               :args [vec-ast (analyze elem)]})
            {:op :call :fn {:op :builtin :name 'empty-vector} :args []}
            elements)))

(defn analyze-vector-literal [form]
  "Analyze (vector a b c) into repeated conj calls"
  (analyze-vector-elements (rest form)))

(defn analyze-vector-syntax [form]
  "Analyze [a b c] vector syntax into repeated conj calls"
  (analyze-vector-elements (seq form)))

(defn analyze-set-syntax [form]
  "Analyze #{a b c} set syntax into repeated set-conj calls"
  (let [elements (seq form)]
    (if (empty? elements)
      {:op :call :fn {:op :builtin :name 'empty-hash-set} :args []}
      (reduce (fn [set-ast elem]
                {:op :call
                 :fn {:op :builtin :name 'set-conj}
                 :args [set-ast (analyze elem)]})
              {:op :call :fn {:op :builtin :name 'empty-hash-set} :args []}
              elements))))

(defn analyze-hash-map-literal [form]
  "Analyze (hash-map k1 v1 k2 v2) into repeated assoc calls"
  (let [pairs (partition 2 (rest form))]
    (if (empty? pairs)
      {:op :call :fn {:op :builtin :name 'empty-hash-map} :args []}
      (reduce (fn [map-ast [k v]]
                {:op :call
                 :fn {:op :builtin :name 'assoc-map}
                 :args [map-ast (analyze k) (analyze v)]})
              {:op :call :fn {:op :builtin :name 'empty-hash-map} :args []}
              pairs))))

;; ============================================
;; Protocol Analysis
;; ============================================

(defn analyze-defprotocol
  "Analyze (defprotocol ProtocolName (method1 [this arg]) (method2 [this]))
   Registers the protocol and its methods.
   Supports multi-arity methods: (method [this] [this x] [this x y])"
  [form]
  (let [protocol-name (second form)
        method-sigs (remove string? (drop 2 form))
        methods (mapv (fn [sig]
                        (let [method-name (first sig)
                              ;; Collect all param vectors (skip docstrings)
                              param-vecs (filter vector? (rest sig))
                              arities (mapv (fn [params]
                                              {:params params
                                               :arity (count params)})
                                            param-vecs)]
                          {:name method-name
                           :arities arities
                           ;; For backward compat, expose first arity as :params/:arity
                           :params (:params (first arities))
                           :arity (:arity (first arities))}))
                      method-sigs)]
    ;; Register the protocol
    (set! *protocols* (assoc *protocols* protocol-name {:methods methods}))
    ;; Register each method as a protocol method
    (doseq [{:keys [name arities]} methods]
      (set! *protocol-methods* (assoc *protocol-methods* name
                                      {:protocol protocol-name
                                       :arities (into {} (map (fn [a] [(:arity a) a]) arities))
                                       ;; For backward compat
                                       :params (:params (first arities))
                                       :arity (:arity (first arities))})))
    ;; defprotocol produces no runtime code - methods are generated later
    {:op :defprotocol
     :name protocol-name
     :methods methods}))

(defn analyze-deftype
  "Analyze (deftype Name [field1 field2 ...] Protocol1 (method1 [this] body) ...)
   Allocates a type tag, registers the type, registers ->Name constructor,
   and processes inline protocol implementations."
  [form]
  (let [name-sym (second form)
        fields (nth form 2)
        _ (when-not (vector? fields)
            (throw-error "deftype fields must be a vector" form))
        ;; Allocate type tag
        tag *next-type-tag*
        _ (set! *next-type-tag* (inc *next-type-tag*))
        ;; Register the type
        type-info {:tag tag :fields fields :kind :deftype}
        _ (set! *user-types* (assoc *user-types* name-sym type-info))
        ;; Register ->Name constructor as a direct function
        constructor-name (symbol (str "->" name-sym))
        prefixed-constructor (if *ns-prefix* (symbol (str *ns-prefix* constructor-name)) constructor-name)
        _ (set! *globals* (conj *globals* prefixed-constructor))
        _ (set! *direct-fn-globals* (assoc *direct-fn-globals* prefixed-constructor (count fields)))
        ;; Parse inline protocol impls (same format as extend-type body)
        rest-forms (drop 3 form)
        impls (loop [forms rest-forms
                     current-protocol nil
                     impls []]
                (if (empty? forms)
                  impls
                  (let [f (first forms)]
                    (if (symbol? f)
                      ;; Protocol name
                      (recur (rest forms) f impls)
                      ;; Method impl: (method-name [params] body...)
                      (let [method-name (first f)
                            params (second f)
                            body-forms (drop 2 f)
                            method-info (get *protocol-methods* method-name)
                            _ (when-not method-info
                                (throw-error (str "Unknown protocol method in deftype: " method-name) form))
                            ;; Bind deftype fields as locals in the method body.
                            ;; In Clojure, (deftype Foo [x y] Proto (meth [this] x))
                            ;; makes x and y available as locals. We desugar to:
                            ;; (fn [this] (let [x (.-x this) y (.-y this)] x))
                            ;; When _ is used as this-param, replace with a gensym.
                            raw-this (first params)
                            this-param (if (= raw-this '_) (gensym "this__") raw-this)
                            actual-params (if (= raw-this '_)
                                            (vec (cons this-param (rest params)))
                                            params)
                            field-bindings (when (seq fields)
                                             (vec (mapcat (fn [field]
                                                            [field (list (symbol (str ".-" field)) this-param)])
                                                          fields)))
                            wrapped-body (if (seq field-bindings)
                                           (list (list* 'let field-bindings body-forms))
                                           body-forms)
                            impl-ast (analyze (list* 'fn actual-params wrapped-body))]
                        (recur (rest forms)
                               current-protocol
                               (conj impls {:type name-sym
                                            :type-tag tag
                                            :protocol current-protocol
                                            :method method-name
                                            :params actual-params
                                            :impl impl-ast})))))))]
    ;; Register protocol impls
    (doseq [{:keys [type-tag method impl]} impls]
      (set! *protocol-impls* (assoc *protocol-impls* [type-tag method] impl)))
    {:op :deftype
     :name name-sym
     :constructor-name prefixed-constructor
     :fields fields
     :tag tag
     :impls impls}))

(defn analyze-defrecord
  "Analyze (defrecord Name [field1 field2 ...] Protocol1 (method1 [this] body) ...)
   Same as deftype but auto-generates ILookup -lookup impl for keyword field access,
   and IAssociative -assoc impl so that (assoc record :key val) works."
  [form]
  ;; First, rewrite as deftype and analyze it
  (let [name-sym (second form)
        fields (nth form 2)
        ;; Build the ILookup -lookup method: (cond (= key :f1) (.-f1 this) ... :else nil)
        this-sym (gensym "this__")
        key-sym (gensym "key__")
        cond-clauses (mapcat (fn [field]
                               [(list '= key-sym (keyword field))
                                (list (symbol (str ".-" field)) this-sym)])
                             fields)
        cond-form (concat ['cond] cond-clauses [:else nil])
        lookup-method (list '-lookup (vector this-sym key-sym) (apply list cond-form))
        ;; Build the IAssociative -assoc method:
        ;; Convert record to a hash-map of its fields, then assoc the new k/v
        assoc-this (gensym "this__")
        assoc-key (gensym "key__")
        assoc-val (gensym "val__")
        map-form (apply list 'hash-map
                        (mapcat (fn [field]
                                  [(keyword field)
                                   (list (symbol (str ".-" field)) assoc-this)])
                                fields))
        assoc-body (list 'assoc map-form assoc-key assoc-val)
        assoc-method (list '-assoc (vector assoc-this assoc-key assoc-val) assoc-body)
        ;; Splice ILookup + IAssociative into the inline impls
        rest-forms (drop 3 form)
        augmented-forms (concat rest-forms
                                ['ILookup lookup-method]
                                ['IAssociative assoc-method])
        deftype-form (concat ['deftype name-sym fields] augmented-forms)
        result (analyze-deftype deftype-form)]
    ;; Update the type kind to :defrecord
    (set! *user-types* (assoc *user-types* name-sym
                              (assoc (get *user-types* name-sym) :kind :defrecord)))
    result))

(defn analyze-extend-type
  "Analyze (extend-type Type Protocol1 (method1 [this] body) ...)
   Registers implementations for the given type."
  [form]
  (let [type-name (second form)
        type-tag (or (get type-name->tag type-name)
                     (when-let [ut (get *user-types* type-name)] (:tag ut)))
        _ (when-not type-tag
            (throw-error (str "Unknown type in extend-type: " type-name) form))
        ;; Rest is protocol + methods pairs
        rest-forms (drop 2 form)
        impls (loop [forms rest-forms
                     current-protocol nil
                     impls []]
                (if (empty? forms)
                  impls
                  (let [f (first forms)]
                    (if (symbol? f)
                      ;; This is a protocol name
                      (recur (rest forms) f impls)
                      ;; This is a method impl: (method-name [params] body...)
                      ;; or multi-arity: (method-name ([params1] body1...) ([params2] body2...))
                      (let [method-name (first f)
                            ;; Verify this method belongs to current protocol
                            method-info (get *protocol-methods* method-name)
                            _ (when-not method-info
                                (throw-error (str "Unknown protocol method: " method-name) form))
                            ;; Detect multi-arity: second form is a list (not a vector)
                            multi-arity? (and (seq? (second f)) (vector? (first (second f))))
                            arity-forms (if multi-arity?
                                          ;; Each remaining form is ([params] body...)
                                          (rest f)
                                          ;; Single arity: ([params] body...)
                                          (list (rest f)))
                            new-impls (mapv (fn [arity-form]
                                             (let [params (first arity-form)
                                                   body-forms (rest arity-form)
                                                   impl-ast (analyze (list* 'fn params body-forms))]
                                               {:type type-name
                                                :type-tag type-tag
                                                :protocol current-protocol
                                                :method method-name
                                                :params params
                                                :impl impl-ast}))
                                           arity-forms)]
                        (recur (rest forms)
                               current-protocol
                               (into impls new-impls)))))))]
    ;; Register implementations
    (doseq [{:keys [type-tag method impl params]} impls]
      (let [method-info (get *protocol-methods* method)
            multi-arity? (and method-info (:arities method-info)
                              (> (count (:arities method-info)) 1))
            impl-key (if multi-arity?
                       [type-tag method (count params)]
                       [type-tag method])]
        (set! *protocol-impls* (assoc *protocol-impls* impl-key impl))))
    {:op :extend-type
     :type type-name
     :type-tag type-tag
     :impls impls}))

(defn analyze-extend-protocol
  "Analyze (extend-protocol Protocol Type1 (method1 [this] body) ... Type2 ...)
   Sugar for multiple extend-type calls."
  [form]
  (let [protocol-name (second form)
        rest-forms (drop 2 form)
        ;; Group into type + methods chunks
        chunks (loop [forms rest-forms
                      chunks []]
                 (if (empty? forms)
                   chunks
                   (let [type-name (first forms)
                         ;; Collect methods until next symbol (type name) or end
                         methods (take-while (complement symbol?) (rest forms))
                         remaining (drop (inc (count methods)) forms)]
                     (recur remaining
                            (conj chunks {:type type-name :methods methods})))))
        ;; Convert to extend-type forms and analyze each
        extend-type-asts (mapv (fn [{:keys [type methods]}]
                                 (analyze (list* 'extend-type type protocol-name methods)))
                               chunks)]
    {:op :extend-protocol
     :protocol protocol-name
     :extend-types extend-type-asts}))

(defn analyze-satisfies?
  "Analyze (satisfies? Protocol val) - checks if val's type implements Protocol."
  [form]
  (let [protocol-name (second form)
        val-form (nth form 2)
        protocol-info (get *protocols* protocol-name)]
    (when-not protocol-info
      (throw-error (str "Unknown protocol: " protocol-name) form))
    {:op :satisfies?
     :protocol protocol-name
     :val (analyze val-form)}))

(defn analyze-protocol-call
  "Analyze a call to a protocol method.
   Returns an AST node for protocol dispatch.
   For multi-arity methods, validates against known arities."
  [method-name args form]
  (let [method-info (get *protocol-methods* method-name)]
    (when-not method-info
      (throw-error (str "Unknown protocol method: " method-name) form))
    (let [call-arity (count args)
          arities (:arities method-info)]
      (if arities
        ;; Multi-arity aware: check if this arity is valid
        (when-not (contains? arities call-arity)
          (throw-error (str "Protocol method " method-name " has no arity for "
                            call-arity " args (valid: " (sort (keys arities)) ")") form))
        ;; Legacy single-arity: exact match
        (when (not= call-arity (:arity method-info))
          (throw-error (str "Protocol method " method-name " expects " (:arity method-info)
                            " args, got " call-arity) form))))
    {:op :protocol-call
     :method method-name
     :protocol (:protocol method-info)
     :args (mapv analyze args)}))

(def builtins
  "Set of builtin function symbols."
  #{'+ '- '* '/ '= 'not= '< '> '<= '>= 'not 'and 'or 'inc 'dec 'neg? 'pos? 'zero? 'NaN?
    ;; List operations
    'cons 'first 'rest 'nil? 'cons?
    ;; Vector operations
    'vector 'vec 'nth 'count 'conj 'assoc 'vector? 'empty-vector
    ;; Map operations
    'hash-map 'get 'contains? 'map? 'empty-hash-map 'assoc-map
    'dissoc 'keys 'vals
    ;; Set operations
    'hash-set 'set? 'empty-hash-set 'set-conj 'disj
    ;; Atom operations
    'atom 'deref 'reset! 'swap! 'atom?
    ;; Apply
    'apply
    ;; Reduce operations
    'reduce 'reduce-kv 'reduced 'reduced?
    ;; Lazy sequence operations
    'make-lazy-seq 'lazy-seq? 'lazy-seq-realized?
    ;; String operations
    'str1 'str-concat 'name 'subs 'string->mem! 'mem->string 'pr-str1 'char
    ;; Float operations
    'to-float 'to-int 'math-floor 'math-ceil 'math-sqrt 'math-abs 'math-round
    ;; Exception operations
    'ex-info 'ex-data 'ex-message 'ex-cause
    ;; Type predicates
    'list? 'keyword? 'keyword 'keyword2 'number? 'integer? 'fn?
    'coll? 'sequential? 'associative? 'counted? 'indexed?
    'true? 'false? 'some?
    'string? 'symbol? 'float? 'symbol 'symbol2 'namespace
    ;; Seq operations
    'seq 'seq? 'seqable? 'empty?
    ;; Numeric operations
    'num
    ;; Reflection stubs (return nil)
    'type
    ;; Print operations (WASI fd_write)
    'print! 'pr! 'print-str!
    ;; String primitives for clojure.string
    'str-index-of 'str-to-lower 'str-to-upper
    'str-starts-with 'str-ends-with 'str-trim
    'str-replace 'str-split
    ;; Metadata operations
    'with-meta 'meta
    ;; Atom watches and validators
    'add-watch 'remove-watch 'set-validator!
    ;; Regex
    're-pattern 'regex-pattern 'regex?})

(defn expand-variadic-assoc
  "Expand (assoc m k1 v1 k2 v2 ...) into nested assoc calls."
  [form]
  (let [args (rest form)
        m (first args)
        kvs (rest args)]
    (if (<= (count kvs) 2)
      ;; Simple case: (assoc m k v) - no expansion needed
      form
      ;; Variadic case: expand to nested calls
      (reduce (fn [acc [k v]]
                (list 'assoc acc k v))
              m
              (partition 2 kvs)))))

(def ^:private i32-propagating-ops
  "Arithmetic ops where i32 inputs produce i32 outputs."
  #{'+ '- '* '/ 'inc 'dec})

(defn- annotate-num-type
  "If a call AST represents an arithmetic op where all args are :num-type :i32,
   annotate the result with :num-type :i32."
  [call-ast]
  (let [fn-name (when (= :builtin (get-in call-ast [:fn :op]))
                  (get-in call-ast [:fn :name]))]
    (if (and fn-name
             (contains? i32-propagating-ops fn-name)
             (every? #(= :i32 (:num-type %)) (:args call-ast)))
      (assoc call-ast :num-type :i32)
      call-ast)))

(def ^:private variadic-arithmetic
  "Arithmetic ops that fold left over 2+ args, with identity values for 0-arity."
  {'+ 0, '- nil, '* 1, '/ nil})

(defn- expand-variadic-arithmetic
  "Expand (op a b c ...) into nested binary calls: (op (op a b) c) ...
   Also handles 0-arity (identity) and 1-arity (special) cases."
  [form]
  (let [op (first form)
        args (rest form)
        n (count args)]
    (cond
      ;; 0-arity: (+) => 0, (*) => 1, (-) and (/) are errors in Clojure but we can let them through
      (zero? n)
      (if-let [identity-val (get variadic-arithmetic op)]
        identity-val
        (throw-error (str "Wrong number of args (0) passed to: " op) form))
      ;; 1-arity: (+ x) => x, (* x) => x, (- x) => (- 0 x), (/ x) => (/ 1 x)
      (= n 1)
      (case op
        (+ *) (first args)
        - (list '- 0 (first args))
        / (list '/ 1 (first args)))
      ;; 2-arity: no expansion needed
      (= n 2) form
      ;; 3+ arity: fold left into nested binary calls
      :else (reduce (fn [acc arg] (list op acc arg)) args))))

(defn analyze-call [form]
  (let [fn-expr (first form)
        args (rest form)]
    (cond
      ;; Handle conj with 0, 1, or 3+ args
      (and (= fn-expr 'conj) (not= (count args) 2))
      (cond
        (= (count args) 0) (analyze '(empty-vector))
        (= (count args) 1) (analyze (first args))
        :else (analyze (reduce (fn [acc x] (list 'conj acc x)) args)))

      ;; Handle variadic assoc expansion
      (and (= fn-expr 'assoc) (> (count args) 3))
      (analyze (expand-variadic-assoc form))

      ;; Handle multi-arg apply: (apply f x y args) → (apply f (cons x (cons y (seq args))))
      (and (= fn-expr 'apply) (> (count args) 2))
      (let [f (first args)
            middle (butlast (rest args))
            last-coll (last args)
            ;; Wrap last arg in seq to ensure pure cons list after consing
            wrapped (reduce (fn [coll arg] (list 'cons arg coll))
                            (list 'seq last-coll)
                            (reverse middle))]
        (analyze (list 'apply f wrapped)))

      ;; Handle 2-arg symbol: (symbol ns name) → calls symbol2
      (and (= fn-expr 'symbol) (= (count args) 2))
      {:op :call :fn {:op :builtin :name 'symbol2} :args (into [] (map analyze args))}

      ;; Handle 2-arg keyword: (keyword ns name) → calls keyword2
      (and (= fn-expr 'keyword) (= (count args) 2))
      {:op :call :fn {:op :builtin :name 'keyword2} :args (into [] (map analyze args))}

      ;; Handle and/or with 0 args: (and) → true, (or) → nil
      (and (contains? #{'and 'or} fn-expr) (= (count args) 0))
      (analyze (if (= fn-expr 'and) true nil))

      ;; Handle and/or with 1 arg: (or x) → x, (and x) → x
      (and (contains? #{'and 'or} fn-expr) (= (count args) 1))
      (analyze (first args))

      ;; Handle variadic boolean expansion: (and a b c) → (and (and a b) c)
      (and (contains? #{'and 'or} fn-expr) (> (count args) 2))
      (analyze (reduce (fn [acc arg] (list fn-expr acc arg)) args))

      ;; Handle comparison with 1 arg: (> x) → true, (< x) → true, etc. (Clojure behavior)
      (and (contains? #{'< '> '<= '>= '= 'not=} fn-expr) (= (count args) 1))
      (analyze true)

      ;; Handle variadic comparison expansion: (< a b c) → (let [G1 b] (and (< a G1) (< G1 c)))
      ;; Uses gensyms so intermediate values are only evaluated once.
      (and (contains? #{'< '> '<= '>= '= 'not=} fn-expr) (> (count args) 2))
      (let [arg-list (vec args)
            ;; Generate gensyms for all intermediate args (not first or last)
            syms (into [nil] (map (fn [_] (woj-gensym "cmp__")) (rest (butlast arg-list))))
            ;; Build pairwise comparisons
            pairs (map (fn [i]
                         (let [left (if (zero? i) (nth arg-list i) (nth syms i))
                               right-idx (inc i)
                               right (if (< right-idx (dec (count arg-list)))
                                       (nth syms right-idx)
                                       (nth arg-list right-idx))]
                           (list fn-expr left right)))
                       (range (dec (count arg-list))))
            ;; Combine with and
            combined (reduce (fn [acc pair] (list 'and acc pair)) pairs)
            ;; Wrap in let to bind gensyms to intermediate values
            bindings (vec (mapcat (fn [i]
                                   [(nth syms i) (nth arg-list i)])
                                 (range 1 (dec (count arg-list)))))]
        (if (seq bindings)
          (analyze (list 'let bindings combined))
          (analyze combined)))

      ;; Handle 2-arg subs: (subs s start) → (subs s start (count s))
      (and (= fn-expr 'subs) (= (count args) 2))
      (let [s-sym (woj-gensym "subs__")]
        (analyze (list 'let [s-sym (first args)]
                       (list 'subs s-sym (second args) (list 'count s-sym)))))

      ;; Handle 3-arg nth: (nth coll idx default) → bounds-checked with default
      (and (= fn-expr 'nth) (= (count args) 3))
      (let [c-sym (woj-gensym "nth_c__")
            i-sym (woj-gensym "nth_i__")]
        (analyze (list 'let [c-sym (first args)
                             i-sym (second args)]
                       (list 'if (list 'and (list '>= i-sym 0)
                                       (list '< i-sym (list 'count c-sym)))
                             (list 'nth c-sym i-sym)
                             (nth args 2)))))

      ;; Handle variadic arithmetic expansion
      (and (contains? variadic-arithmetic fn-expr) (not= (count args) 2))
      (analyze (expand-variadic-arithmetic form))

      ;; Keyword in function position: (:key m) → (get m :key), (:key m default) → (get m :key default)
      (keyword? fn-expr)
      (cond
        (= (count args) 1) (analyze (list 'get (first args) fn-expr))
        (= (count args) 2) (analyze (list 'get (first args) fn-expr (second args)))
        :else (throw-error (str "Keywords as functions take 1 or 2 arguments, got " (count args)) form))

      ;; Check if this is a protocol method call
      (and (symbol? fn-expr) (contains? *protocol-methods* fn-expr))
      (analyze-protocol-call fn-expr args form)

      ;; Error for calling non-function literals
      (or (number? fn-expr) (string? fn-expr) (nil? fn-expr) (true? fn-expr) (false? fn-expr))
      (throw-error (str "Cannot call " (pr-str fn-expr) " as a function") form)

      ;; Regular call
      :else
      (let [fn-ast (cond
                     (contains? builtins fn-expr)
                     {:op :builtin :name fn-expr}
                     (symbol? fn-expr)
                     (analyze-symbol fn-expr)
                     :else (analyze fn-expr))
            call-arity (count args)]
        ;; Compile-time arity check for known functions
        (when (= :fn-global (:op fn-ast))
          (let [{:keys [arities variadic? min-arity variadic-arity]} (:fn-info fn-ast)]
            (when (and (some? arities) (not (empty? arities)) (not variadic?))
              ;; Fixed-arity only: call arity must be in the set
              (when-not (contains? arities call-arity)
                (throw-error (str "Wrong number of args (" call-arity ") passed to " fn-expr) form)))
            (when variadic?
              ;; Variadic: call arity must be >= (variadic-arity - 1) or in fixed arities
              (let [var-min (if variadic-arity (dec variadic-arity) 0)]
                (when-not (or (contains? arities call-arity)
                              (>= call-arity var-min))
                  (throw-error (str "Wrong number of args (" call-arity ") passed to " fn-expr) form))))))
        (annotate-num-type
          {:op :call :fn fn-ast :args (into [] (map analyze args))})))))

(defn analyze-keyword [kw]
  "Analyze a keyword, interning it and assigning a unique ID."
  (if-let [id (get *keywords* kw)]
    {:op :keyword :name kw :id id}
    (let [id *keyword-counter*]
      (set! *keyword-counter* (inc *keyword-counter*))
      (set! *keywords* (assoc *keywords* kw id))
      {:op :keyword :name kw :id id})))

(defn analyze-string [s]
  "Analyze a string, interning it and assigning a unique ID."
  (if-let [id (get *strings* s)]
    {:op :string :val s :id id}
    (let [id *string-counter*]
      (set! *string-counter* (inc *string-counter*))
      (set! *strings* (assoc *strings* s id))
      {:op :string :val s :id id})))

(defn analyze-char [c]
  "Analyze a character literal - convert to single-character string.
   This makes char literals consistent with (first \"hello\") which returns a string."
  (analyze-string (str c)))

(defn analyze-float [f]
  "Analyze a float literal."
  {:op :float :val f})

(defn analyze-ratio [r]
  "Analyze a ratio literal - convert to float for now (woj doesn't support ratios)."
  {:op :float :val (double r)})

(defn analyze-bigint [n]
  "Analyze a BigInt literal - treat as regular integer if small enough, else float."
  (let [v (long n)]
    (if (and (>= v Integer/MIN_VALUE) (<= v Integer/MAX_VALUE))
      {:op :const :val (int v) :type :int}
      {:op :float :val (double n)})))

(defn analyze-bigdec [n]
  "Analyze a BigDecimal literal - convert to float."
  {:op :float :val (double n)})

(defn analyze-quoted-symbol [sym]
  "Analyze a quoted symbol, interning it and assigning a unique ID."
  (if-let [id (get *symbols* sym)]
    {:op :symbol :name sym :id id}
    (let [id *symbol-counter*]
      (set! *symbol-counter* (inc *symbol-counter*))
      (set! *symbols* (assoc *symbols* sym id))
      {:op :symbol :name sym :id id})))

(defn analyze-quote [form]
  "Analyze (quote x) - handles symbols, lists, and other literals."
  (let [quoted (second form)]
    (cond
      ;; Quoted symbol -> symbol struct
      (symbol? quoted) (analyze-quoted-symbol quoted)
      ;; Quoted empty list -> nil
      (and (seq? quoted) (empty? quoted)) {:op :nil}
      ;; Quoted list -> expand to nested cons calls (like analyze-list)
      (seq? quoted) (let [element-asts (mapv #(analyze-quote (list 'quote %)) quoted)]
                      (reduce (fn [rest-ast elem-ast]
                                {:op :call
                                 :fn {:op :builtin :name 'cons}
                                 :args [elem-ast rest-ast]})
                              {:op :nil}
                              (reverse element-asts)))
      ;; Quoted vector -> build using empty-vector and conj
      (vector? quoted) (let [quoted-elements (map #(list 'quote %) quoted)
                             element-asts (mapv analyze quoted-elements)]
                         (if (empty? element-asts)
                           {:op :call :fn {:op :builtin :name 'empty-vector} :args []}
                           (reduce (fn [vec-ast elem-ast]
                                     {:op :call
                                      :fn {:op :builtin :name 'conj}
                                      :args [vec-ast elem-ast]})
                                   {:op :call :fn {:op :builtin :name 'empty-vector} :args []}
                                   element-asts)))
      ;; Quoted keyword -> keyword
      (keyword? quoted) (analyze-keyword quoted)
      ;; Quoted literal (number, string, etc) -> just analyze it
      :else (analyze quoted))))

(defn analyze-map-literal [form]
  "Analyze {:a 1 :b 2} into repeated assoc calls on empty-hash-map"
  (if (empty? form)
    {:op :call :fn {:op :builtin :name 'empty-hash-map} :args []}
    (reduce (fn [map-ast [k v]]
              {:op :call
               :fn {:op :builtin :name 'assoc-map}
               :args [map-ast (analyze k) (analyze v)]})
            {:op :call :fn {:op :builtin :name 'empty-hash-map} :args []}
            form)))

;; True special forms that must be in the compiler
(def special-forms
  #{'def 'fn 'let 'if 'loop 'recur 'do 'set! 'defmacro})

(defn analyze [form]
  (let [ast (cond
              (integer? form) (analyze-const form)
              (ratio? form) (analyze-ratio form)
              (instance? clojure.lang.BigInt form) (analyze-bigint form)
              (decimal? form) (analyze-bigdec form)
              (float? form) (analyze-float form)
              (instance? java.util.regex.Pattern form) (analyze (list 're-pattern (.pattern ^java.util.regex.Pattern form)))
              (instance? java.util.UUID form) {:op :const :val 0 :type :nil}  ;; UUID stub
              (= form true) (analyze-bool true)
              (= form false) (analyze-bool false)
              (nil? form) (analyze-nil)
              (string? form) (analyze-string form)
              (char? form) (analyze-char form)
              (keyword? form) (analyze-keyword form)
              (symbol? form) (analyze-symbol form)
              (map? form) (analyze-map-literal form)
              (vector? form) (analyze-vector-syntax form)
              (set? form) (analyze-set-syntax form)
              (seq? form)
              (if (empty? form)
                {:op :nil}  ;; () evaluates to nil (woj has no distinct empty-list value)
                (let [op (first form)]
                  (cond
                  ;; True special forms (cannot be overridden by macros)
                  (= op 'def) (analyze-def form)
                  (= op 'defmacro) (analyze-defmacro form)
                  (= op 'quote) (analyze-quote form)
                  (= op 'fn) (analyze-fn form)
                  (= op 'fn*) (analyze-fn form)  ;; #() reader macro expands to fn*
                  (= op 'let) (analyze-let form)
                  (= op 'if) (analyze-if form)
                  (= op 'loop) (analyze-loop form)
                  (= op 'recur) (analyze-recur form)
                  (= op 'do) (analyze-do form)
                  (= op 'set!) (analyze-set! form)

                  ;; Forward declarations
                  (= op 'declare)
                  (do (doseq [sym (rest form)]
                        (let [prefixed (if *ns-prefix* (symbol (str *ns-prefix* sym)) sym)]
                          (set! *globals* (conj *globals* prefixed))
                          ;; Pre-register as fn-global so forward references used as values
                          ;; or in calls get correct :fn-global ops (updated by actual defn later)
                          (set! *direct-fn-globals* (assoc *direct-fn-globals* prefixed
                                                           {:arities #{} :variadic? true :min-arity 0}))))
                      {:op :nil})

                  ;; Exception handling
                  (= op 'throw) (analyze-throw form)
                  (= op 'try) (analyze-try form)

                  ;; Protocol forms (special forms, cannot be overridden by macros)
                  (= op 'defprotocol) (analyze-defprotocol form)
                  (= op 'deftype) (analyze-deftype form)
                  (= op 'defrecord) (analyze-defrecord form)
                  (= op 'extend-type) (analyze-extend-type form)
                  (= op 'extend-protocol) (analyze-extend-protocol form)
                  (= op 'satisfies?) (analyze-satisfies? form)
                  (= op 'instance?) (if (< (count form) 3)
                                      ;; Reader conditional may have eliminated the type arg
                                      {:op :const :val 0 :type :bool}
                                      (let [type-sym (second form)
                                            val-form (nth form 2)]
                                        {:op :instance?
                                         :type type-sym
                                         :val (analyze val-form)}))

                  ;; reify: (reify Protocol1 (method1 [this arg] body) ...)
                  ;; Expands to anonymous deftype with captured locals as fields
                  (= op 'reify)
                  (let [rest-forms (rest form)
                        ;; Separate method forms from protocol name symbols
                        method-forms (filter seq? rest-forms)
                        ;; Collect all method parameter names (exclude from captures)
                        all-method-params (set (mapcat second method-forms))
                        ;; Collect symbols from method bodies only
                        body-syms (->> method-forms
                                       (mapcat #(drop 2 %))
                                       (tree-seq coll? seq)
                                       (filter symbol?)
                                       set)
                        ;; Captures = body syms that are locals in env, not method params
                        captures (vec (sort (filter (fn [s]
                                                      (and (not (contains? all-method-params s))
                                                           (let [info (get *env* s)]
                                                             (and info (= :local (:kind info))))))
                                                    body-syms)))
                        reify-name (symbol (str "__Reify_" *next-type-tag*))
                        deftype-form (list* 'deftype reify-name (vec captures) rest-forms)
                        constructor-call (list* (symbol (str "->" reify-name)) captures)
                        expanded (list 'do deftype-form constructor-call)]
                    (analyze expanded))

                  ;; User-defined macros (can shadow built-in macro-like forms)
                  ;; Also check for namespace-qualified symbols
                  (and (symbol? op)
                       (or (contains? *macros* op)
                           (and (namespace op) (contains? *macros* (symbol (name op))))))
                  (let [macro-name (if (contains? *macros* op) op (symbol (name op)))
                        expanded (apply (get *macros* macro-name) (rest form))]
                    (analyze expanded))

                  ;; Built-in macro-like forms (used if no user macro defined)
                  (= op 'defn) (analyze-defn form)
                  (= op 'defn-) (analyze (cons 'defn (rest form)))
                  (= op 'cond) (analyze-cond form)
                  (= op 'when) (analyze-when form)
                  (= op 'when-not) (analyze-when-not form)
                  (= op '->) (analyze-thread-first form)
                  (= op '->>) (analyze-thread-last form)
                  (= op 'list) (analyze-list form)
                  (= op 'vector) (analyze-vector-literal form)
                  (= op 'hash-map) (analyze-hash-map-literal form)

                  ;; clojure.test support (also handle namespace-qualified like t/deftest)
                  (or (= op 'deftest) (and (symbol? op) (= (name op) "deftest")))
                  (analyze-deftest form)
                  (or (= op 'is) (and (symbol? op) (= (name op) "is")))
                  (analyze-is form)
                  (or (= op 'are) (and (symbol? op) (= (name op) "are")))
                  (analyze-are form)
                  (or (= op 'testing) (and (symbol? op) (= (name op) "testing")))
                  (analyze-testing form)
                  (= op 'ns) (analyze-ns form)

                  ;; defmulti: (defmulti name dispatch-fn)
                  ;; Expands to: (do (def name__methods (atom {}))
                  ;;                 (def name__hierarchy (atom (make-hierarchy)))
                  ;;                 (def name__prefer (atom {}))
                  ;;                 (defn name [a] ... dispatch with isa? ...))
                  (= op 'defmulti)
                  (let [mm-name (second form)
                        dispatch-expr (nth form 2)
                        methods-name (symbol (str mm-name "__methods"))
                        hierarchy-name (symbol (str mm-name "__hierarchy"))
                        prefer-name (symbol (str mm-name "__prefer"))
                        ;; Generate dispatch call
                        ;; For keywords, inline as (get a :key)
                        ;; For functions, call directly
                        dispatch-call (if (keyword? dispatch-expr)
                                        (list 'get 'a dispatch-expr)
                                        (list dispatch-expr 'a))
                        expanded (list 'do
                                   (list 'def methods-name (list 'atom {}))
                                   (list 'def hierarchy-name (list 'atom (list 'make-hierarchy)))
                                   (list 'def prefer-name (list 'atom {}))
                                   (list 'defn mm-name ['a]
                                     (list 'let ['dv dispatch-call
                                                 'methods (list 'deref methods-name)
                                                 'f (list 'get 'methods 'dv)]
                                       (list 'if (list 'nil? 'f)
                                         ;; No exact match - try isa? hierarchy lookup
                                         (list 'let ['found (list 'mm-find-isa
                                                                  'methods 'dv
                                                                  (list 'deref hierarchy-name)
                                                                  (list 'deref prefer-name))]
                                           (list 'if (list 'nil? 'found)
                                             (list 'let ['df (list 'get 'methods :default)]
                                               (list 'if (list 'nil? 'df) nil (list 'df 'a)))
                                             (list 'found 'a)))
                                         (list 'f 'a)))))]
                    (analyze expanded))

                  ;; defmethod: (defmethod name dispatch-val [args] body)
                  ;; Expands to: (swap! name__methods assoc dispatch-val (fn [args] body))
                  (= op 'defmethod)
                  (let [mm-name (second form)
                        dispatch-val (nth form 2)
                        fn-tail (drop 3 form)
                        methods-name (symbol (str mm-name "__methods"))
                        expanded `(swap! ~methods-name assoc ~dispatch-val (fn ~@fn-tail))]
                    (analyze expanded))

                  ;; prefer-method: (prefer-method mm-name dispatch-val-x dispatch-val-y)
                  ;; Stores preference: when both x and y match, prefer x
                  (= op 'prefer-method)
                  (let [mm-name (second form)
                        x (nth form 2)
                        y (nth form 3)
                        prefer-name (symbol (str mm-name "__prefer"))
                        expanded (list 'swap! prefer-name
                                       (list 'fn ['m]
                                         (list 'assoc 'm x
                                               (list 'set-conj (list 'get 'm x (list 'hash-set)) y))))]
                    (analyze expanded))

                  ;; letfn: (letfn [(f [x] body-f) (g [x] body-g)] body)
                  ;; Expands to let with atoms and trampolines for mutual recursion:
                  ;; (let [f__letfn (atom nil) g__letfn (atom nil)
                  ;;       f (fn [x] ((deref f__letfn) x))
                  ;;       g (fn [x] ((deref g__letfn) x))]
                  ;;   (reset! f__letfn (fn f [x] body-f))
                  ;;   (reset! g__letfn (fn g [x] body-g))
                  ;;   body)
                  (= op 'letfn)
                  (let [fn-specs (second form)
                        body-forms (drop 2 form)
                        ;; Parse each fn spec: (name [params] body...)
                        parsed (mapv (fn [spec]
                                       (let [fname (first spec)
                                             params (second spec)
                                             body (drop 2 spec)]
                                         {:name fname
                                          :params params
                                          :body body
                                          :atom-name (symbol (str fname "__letfn"))}))
                                     fn-specs)
                        ;; Build let bindings: atoms first, then trampolines
                        atom-bindings (mapcat (fn [p]
                                               [(:atom-name p) (list 'atom nil)])
                                             parsed)
                        trampoline-bindings (mapcat (fn [p]
                                                      (let [params (:params p)
                                                            call-args (cons (list 'deref (:atom-name p)) params)]
                                                        [(:name p) (list 'fn params (apply list call-args))]))
                                                    parsed)
                        all-bindings (vec (concat atom-bindings trampoline-bindings))
                        ;; Build reset! forms for real implementations
                        resets (map (fn [p]
                                      (list 'reset! (:atom-name p)
                                            (concat (list 'fn (:name p) (:params p)) (:body p))))
                                    parsed)
                        ;; Build the full expansion
                        expanded (list 'let all-bindings
                                       (apply list 'do (concat resets body-forms)))]
                    (analyze expanded))

                  ;; thrown? - always returns false for now (TODO: implement with try/catch)
                  (or (= op 'thrown?) (and (symbol? op) (= (name op) "thrown?")))
                  {:op :const :val 0 :type :bool}

                  ;; @ reader macro produces clojure.core/deref - convert to our deref
                  (= op 'clojure.core/deref) (analyze (cons 'deref (rest form)))

                  ;; Handle clojure.core qualified names
                  (and (symbol? op) (= (namespace op) "clojure.core"))
                  (analyze (cons (symbol (name op)) (rest form)))

                  ;; Handle clojure.test qualified names (t/is, t/deftest, etc.)
                  (and (symbol? op)
                       (namespace op)
                       (#{"deftest" "is" "are" "testing" "thrown?"} (name op)))
                  (analyze (cons (symbol (name op)) (rest form)))

                  ;; Handle namespace-aliased calls (e.g., ct/insert -> laced_causal_tree__insert)
                  (and (symbol? op) (namespace op) (contains? *ns-aliases* (namespace op)))
                  (let [bare-name (symbol (name op))
                        ;; Protocol methods are dispatched globally, don't prefix them
                        qualified-name (if (contains? *protocol-methods* bare-name)
                                         bare-name
                                         (let [full-ns (get *ns-aliases* (namespace op))
                                               prefix (get *ns-prefix-map* full-ns)]
                                           (if prefix
                                             (symbol (str prefix (name op)))
                                             bare-name)))]
                    (analyze (cons qualified-name (rest form))))

                  ;; Handle full namespace names of loaded namespaces
                  (and (symbol? op) (namespace op) (contains? *loaded-namespaces* (namespace op)))
                  (let [bare-name (symbol (name op))
                        qualified-name (if (contains? *protocol-methods* bare-name)
                                         bare-name
                                         (let [prefix (get *ns-prefix-map* (namespace op))]
                                           (if prefix
                                             (symbol (str prefix (name op)))
                                             bare-name)))]
                    (analyze (cons qualified-name (rest form))))

                  ;; Math builtins: (Math/floor x) -> (math-floor x)
                  (and (symbol? op) (= (namespace op) "Math"))
                  (let [math-builtin (symbol (str "math-" (name op)))]
                    (if (contains? builtins math-builtin)
                      (analyze (cons math-builtin (rest form)))
                      {:op :nil}))

                  ;; Field access: (.-field obj) or (.field obj)
                  (and (symbol? op)
                       (let [n (name op)]
                         (and (> (count n) 2)
                              (.startsWith n ".-"))))
                  (let [field-name (subs (name op) 2)
                        target (analyze (second form))]
                    {:op :field-access :field field-name :target target})

                  ;; Constructor syntax: (TypeName. args...) → (->TypeName args...)
                  (and (symbol? op)
                       (let [n (name op)]
                         (and (> (count n) 1)
                              (.endsWith n ".")
                              (Character/isUpperCase (first n)))))
                  (let [type-name (symbol (subs (name op) 0 (dec (count (name op)))))
                        ctor (symbol (str "->" type-name))]
                    (analyze (cons ctor (rest form))))

                  :else (analyze-call form))))
              :else (throw-error (str "Unsupported form: " form) form))]
    (with-source ast form)))

(defn analyze-forms [forms]
  ;; Reset gensym counter for each compilation
  (reset! *gensym-counter* 0)
  (binding [*globals* #{}
            *env* {}
            *keywords* {}
            *keyword-counter* 0
            *strings* {}
            *string-counter* 0
            *symbols* {}
            *symbol-counter* 0
            *loop-bindings* nil
            *enclosing-locals* #{}
            *capture-map* nil
            *callable-globals* #{}
            *direct-fn-globals* {}
            *fn-refs* #{}
            *macros* {}
            *builtin-refs* #{}
            *protocols* {}
            *protocol-methods* {}
            *protocol-impls* {}
            *user-types* {}
            *next-type-tag* 19
            *ns-aliases* {}
            *loaded-namespaces* #{}
            *loading-namespaces* #{}
            *ns-asts* []
            *ns-load-fn* *ns-load-fn*
            *ns-read-fn* *ns-read-fn*
            *ns-prefix* nil
            *ns-prefix-map* {}]
    (let [result (into [] (map analyze forms))]
      {:ast (into *ns-asts* result)
       :keywords *keywords*
       :strings *strings*
       :symbols *symbols*
       :callable-globals *callable-globals*
       :direct-fn-globals *direct-fn-globals*
       :builtin-refs *builtin-refs*
       :protocols *protocols*
       :protocol-methods *protocol-methods*
       :protocol-impls *protocol-impls*
       :user-types *user-types*})))
