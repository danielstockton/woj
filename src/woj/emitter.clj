(ns woj.emitter
  (:require [woj.util :refer [munge-name str-join]]
            [woj.wasm :as w]
            [woj.optimize :as opt]
            [clojure.string :as string]))

;; ============================================
;; Dynamic vars for emission state
;; ============================================

(def ^:dynamic *functions* [])
(def ^:dynamic *globals-emit* [])
(def ^:dynamic *globals-declared* #{})
(def ^:dynamic *fn-counter* 0)
(def ^:dynamic *loop-counter* 0)
(def ^:dynamic *loop-context* nil)
(def ^:dynamic *keywords* {})  ;; keyword -> id mapping for interning
(def ^:dynamic *internal-fn-names* {})  ;; fn-name -> internal name (for exported fns)
(def ^:dynamic *closure-env-param* nil)  ;; env param name when inside closure function
(def ^:dynamic *capture-indices* nil)  ;; symbol -> index in env array (when inside closure)
(def ^:dynamic *callable-globals* #{})  ;; globals that hold callable values (need invokeN)
(def ^:dynamic *direct-fn-globals* {})  ;; map of name -> arity for direct functions
(def ^:dynamic *fn-refs* #{})  ;; direct function globals used as values (need wrappers)
(def ^:dynamic *closure-funcs* [])  ;; closure function names that need elem declarations
(def ^:dynamic *lifted-fn-inits* [])  ;; init code for hoisted non-capturing fn globals
(def ^:dynamic *builtin-refs* #{})  ;; builtins used as values (need wrapper closures)
(def ^:dynamic *emitted-fn-names* #{})  ;; track emitted function names to prevent duplicates
(def ^:dynamic *strings* {})  ;; string -> id mapping for interning (from analyzer)
(def ^:dynamic *symbols* {})  ;; symbol -> id mapping for interning (from analyzer)
(def ^:dynamic *repl-mode* false)  ;; when true, __repl_eval returns (i32 i32) type tag + value
(def ^:dynamic *host-imports* [])  ;; vec of {:module :name :func-name :arity} for host imports
(def ^:dynamic *host-import-fns* #{})  ;; set of munged function names that are host imports

;; Protocol support
(def ^:dynamic *protocols* {})  ;; protocol-name -> {:methods [...]}
(def ^:dynamic *protocol-methods* {})  ;; method-name -> {:protocol name :arity n}
(def ^:dynamic *protocol-impls* {})  ;; [type-tag method-name] -> impl-closure-name
(def ^:dynamic *protocol-dispatch-tables* {})  ;; method-name -> global array name

;; User-defined types from deftype/defrecord
(def ^:dynamic *user-types* {})

;; Forward declarations
(declare emit emit-str emit-call-node emit-call-dispatch)

;; Tail call optimization
(def ^:dynamic *tail-position* false)  ;; true when emitting code in tail position of a function  ;; type-name -> {:tag N, :fields [...], :kind :deftype/:defrecord}

;; Max type tag for dispatch table size (nil=0 through VectorSeq=18, plus 1 for default)
;; Computed dynamically when user types are present
(def max-type-tag 20)

(defn- compute-dispatch-table-size
  "Compute size of dispatch tables from all known type tags.
   Returns max-tag + 1 to accommodate array indices 0..max-tag."
  []
  (let [user-tags (map :tag (vals *user-types*))
        impl-tags (map first (keys *protocol-impls*))
        all-tags (concat [max-type-tag] user-tags impl-tags)]
    (inc (apply max all-tags))))

;; ============================================
;; Emitter
;; ============================================

(declare emit)

(defn- extract-fn-name
  "Extract function name from a func definition string."
  [fn-def]
  (when-let [m (re-find #"\(func (\$[a-zA-Z0-9_>]+)" fn-def)]
    (second m)))

(defn- add-function!
  "Add a function to *functions*. If a function with the same name already exists,
   replace it (last def wins, matching Clojure semantics).
   Returns true if added."
  [fn-def]
  (let [fn-name (extract-fn-name fn-def)]
    (if (contains? *emitted-fn-names* fn-name)
      (do
        (set! *functions* (conj (into [] (remove #(= (extract-fn-name %) fn-name) *functions*)) fn-def))
        true)
      (do
        (set! *emitted-fn-names* (conj *emitted-fn-names* fn-name))
        (set! *functions* (conj *functions* fn-def))
        true))))

(defn collect-locals
  "Collect local variable declarations from let bindings in an AST.
   Traverses all relevant node types, stopping at :fn boundaries
   since nested functions have their own scope.
   All locals are now anyref for uniform value representation."
  [ast]
  (case (:op ast)
    :let (concat
          (map (fn [b] (str "(local $" (munge-name (:name b)) " anyref)")) (:bindings ast))
          (mapcat (fn [b] (collect-locals (:init b))) (:bindings ast))
          (collect-locals (:body ast)))
    :loop (concat
           (map (fn [b] (str "(local $" (munge-name (:name b)) " anyref)")) (:bindings ast))
           (mapcat (fn [b] (collect-locals (:init b))) (:bindings ast))
           (collect-locals (:body ast)))
    :if (concat (collect-locals (:test ast))
                (collect-locals (:then ast))
                (collect-locals (:else ast)))
    :call (concat (collect-locals (:fn ast))
                  (mapcat collect-locals (:args ast)))
    :protocol-call (mapcat collect-locals (:args ast))
    :recur (mapcat collect-locals (:args ast))
    :do (mapcat collect-locals (:exprs ast))
    :set! (collect-locals (:val ast))
    :throw (collect-locals (:val ast))
    :field-access (collect-locals (:target ast))
    :instance? (collect-locals (:val ast))
    :try (concat
          ;; Declare the catch binding as a local if there's a catch clause
          (when-let [catch-clause (:catch ast)]
            [(str "(local $" (munge-name (:binding catch-clause)) " anyref)")])
          (collect-locals (:body ast))
          (when-let [catch-clause (:catch ast)]
            (collect-locals (:body catch-clause)))
          (when-let [finally-clause (:finally ast)]
            (collect-locals finally-clause)))
    ;; Closures need a temp local for building the environment
    :fn (if (:is-closure ast)
          ["(local $__tmp_env anyref)"]
          [])
    ;; Leaf nodes and scope boundaries
    (:const :local :global :fn-global :builtin :builtin-ref :nil :keyword :string :symbol :float :captured) []
    ;; Default - shouldn't happen but safe fallback
    []))

(defn- filter-locals-against-params
  "Remove local declarations that clash with function parameter names.
   This happens when a loop binding shadows a parameter (e.g. (defn f [r] (loop [r r] ...)))."
  [locals params]
  (let [param-names (set (map (fn [p] (str "$" (munge-name p))) params))]
    (remove (fn [local-decl]
              (when-let [m (re-find #"\(local (\$[a-zA-Z0-9_>]+) " local-decl)]
                (param-names (second m))))
            locals)))

(defn- emit-body-with-recur
  "Emit body code, wrapping in a WAT loop if has-recur is true."
  [body params has-recur]
  (if has-recur
    (let [counter *loop-counter*
          _ (set! *loop-counter* (inc *loop-counter*))
          loop-label (str "$fn_recur" counter)
          body-code (binding [*loop-context* {:loop-label loop-label
                                              :loop-bindings params}
                              *tail-position* false]
                      (emit-str body))]
      (str "(loop " loop-label " (result anyref)\n      " body-code ")"))
    (binding [*tail-position* true]
      (emit-str body))))

(defn- emit-function
  "Emit a WAT function definition. Returns the function name.
   - name: function name (symbol or string, will be munged)
   - params: vector of parameter symbols
   - body: body AST node
   - export-name: if non-nil, export with this name (and unbox return to i32)
   - has-recur: if true, wrap body in loop for tail-position recur"
  [name params body export-name & {:keys [has-recur]}]
  (let [munged (if (string? name) name (munge-name name))
        fn-name (str "$" munged)
        ;; All params are anyref internally
        param-decls (mapv (fn [p] (str "(param $" (munge-name p) " anyref)")) params)]
    (if export-name
      ;; Exported functions: wrap with i32 params/result for wasmtime compatibility
      ;; Create internal function with anyref, wrapper with i32
      (let [internal-name (str fn-name "_internal")]
        ;; Track internal name BEFORE emitting body (enables recursion)
        (set! *internal-fn-names* (assoc *internal-fn-names* munged (subs internal-name 1)))
        (let [locals (filter-locals-against-params (distinct (collect-locals body)) params)
              body-code (emit-body-with-recur body params has-recur)
              internal-fn (str "(func " internal-name " "
                               (str-join " " param-decls) " (result anyref)"
                               (if (seq locals) (str "\n    " (str-join "\n    " locals)) "")
                               "\n    " body-code ")")
              ;; Use a unique wrapper name to avoid collisions with builtins.
              ;; The wrapper is only called from JS via export name, never from WAT code.
              wrapper-name (str "$__export_" munged)
              ;; Wrapper that boxes params and unboxes result
              wrapper-param-decls (mapv (fn [p] (str "(param $" (munge-name p) " i32)")) params)
              box-args (mapv (fn [p] (str "(ref.i31 (local.get $" (munge-name p) "))")) params)
              wrapper-fn (if (and *repl-mode* (= export-name "__repl_eval"))
                           ;; REPL mode: _start that prints result string via WASI
                           (str "(func " wrapper-name " (export \"_start\")\n    "
                                "(call $__repl_print_str (call " internal-name ")))")
                           ;; Normal mode: return i32
                           (str "(func " wrapper-name " (export \"" export-name "\") "
                                (str-join " " wrapper-param-decls) " (result i32)\n    "
                                "(call $unbox_i32 (call " internal-name " " (str-join " " box-args) ")))"))]
          (add-function! internal-fn)
          (add-function! wrapper-fn)
          fn-name))
      ;; Non-exported: just use anyref directly
      (let [locals (filter-locals-against-params (distinct (collect-locals body)) params)
            body-code (emit-body-with-recur body params has-recur)
            fn-def (str "(func " fn-name " "
                        (str-join " " param-decls) " (result anyref)"
                        (if (seq locals) (str "\n    " (str-join "\n    " locals)) "")
                        "\n    " body-code ")")]
        (add-function! fn-def)
        fn-name))))

(defn- emit-closure-function
  "Emit a WAT function for a closure (has env param as first argument).
   Returns the function name.
   - name: function name (will be munged)
   - params: vector of user-visible parameter symbols
   - body: body AST node
   - captures: vector of captured variable symbols
   - has-recur: if true, wrap body in loop for tail-position recur"
  [name params body captures & {:keys [has-recur self-name]}]
  (let [munged (if (string? name) name (munge-name name))
        fn-name (str "$" munged)
        arity (count params)
        ;; env param is first, then user params
        env-decl "(param $__env anyref)"
        param-decls (mapv (fn [p] (str "(param $" (munge-name p) " anyref)")) params)
        ;; Build capture indices map
        capture-map (into {} (map-indexed (fn [i sym] [sym i]) captures))
        ;; Emit body with closure context
        locals (filter-locals-against-params
                (distinct (binding [*capture-indices* capture-map
                                    *closure-env-param* "$__env"]
                            (collect-locals body)))
                params)
        ;; Add self-name local if present (for named fn self-reference)
        self-local (when self-name
                     (str "(local $" (munge-name self-name) " anyref)"))
        all-locals (if self-local (cons self-local locals) locals)
        ;; Generate self-reference initialization code
        self-init (when self-name
                    (str "(local.set $" (munge-name self-name)
                         " (struct.new $Closure" arity
                         " (i32.const 11) (ref.func " fn-name
                         ") (local.get $__env)))\n    "))
        body-code (binding [*capture-indices* capture-map
                            *closure-env-param* "$__env"]
                    (emit-body-with-recur body params has-recur))
        ;; Use ClosureFuncN type
        func-type (str "$ClosureFunc" arity)
        fn-def (str "(func " fn-name " (type " func-type ") "
                    env-decl " " (str-join " " param-decls) " (result anyref)"
                    (if (seq all-locals) (str "\n    " (str-join "\n    " all-locals)) "")
                    "\n    " (or self-init "") body-code ")")]
    (add-function! fn-def)
    ;; Track this closure function for elem declaration
    (set! *closure-funcs* (conj *closure-funcs* fn-name))
    fn-name))

;; Arithmetic builtins that need unbox/rebox
(def arithmetic-builtins #{'+ '- '* '/ 'inc 'dec})

;; Comparison builtins that unbox but return boxed boolean
(def comparison-builtins #{'= 'not= '< '> '<= '>= 'neg? 'pos? 'zero? 'NaN?})

;; Boolean builtins that work on truthiness
(def boolean-builtins #{'not 'and 'or})

;; List builtins that work with anyref
(def list-builtins #{'cons 'first 'rest 'nil? 'cons?})

;; Vector builtins
(def vector-builtins #{'nth 'count 'conj 'vector? 'empty-vector})

;; Map builtins
(def map-builtins #{'get 'contains? 'map? 'empty-hash-map 'assoc-map 'dissoc 'keys 'vals 'make-array-map})

;; Set builtins
(def set-builtins #{'set? 'empty-hash-set 'set-conj 'disj})

;; Seq builtins
(def seq-builtins #{'seq 'seq? 'seqable? 'empty?})

;; Atom builtins
(def atom-builtins #{'atom 'deref 'atom? 'reset! 'swap!})

;; Polymorphic builtins (work on multiple types)
(def polymorphic-builtins #{'assoc})

;; Reduce builtins
(def reduce-builtins #{'reduce 'reduce-kv 'reduced 'reduced?})

;; Lazy sequence builtins
(def lazy-seq-builtins #{'make-lazy-seq 'lazy-seq? 'lazy-seq-realized?})

;; String builtins
(def string-builtins #{'str1 'str-concat 'name 'subs 'string->mem! 'mem->string 'pr-str1 'char 'str-hash})

;; Float operation builtins
(def float-op-builtins #{'to-float 'to-int 'math-floor 'math-ceil 'math-sqrt 'math-abs 'math-round})

;; Exception builtins
(def exception-builtins #{'ex-info 'ex-data 'ex-message 'ex-cause})

;; Bit operation builtins (native WASM i32 ops)
(def bit-builtins #{'bit-and 'bit-or 'bit-xor 'bit-not
                    'bit-shift-left 'bit-shift-right 'unsigned-bit-shift-right 'bit-test})

;; Compare builtin (three-way comparison returning -1/0/1)
(def compare-builtins #{'compare})

;; Array builtins (native WasmGC array ops)
(def array-op-builtins #{'make-array 'aget 'aset 'alength 'aclone 'acopy 'object-array 'array? 'vector-from-array})

;; Transient collection builtins
(def transient-builtins #{'transient 'persistent! 'conj! 'assoc! 'dissoc! 'disj! 'pop!})

;; Metadata builtins
(def metadata-builtins #{'with-meta 'meta})

;; Atom watch/validator builtins
(def atom-watch-builtins #{'add-watch 'remove-watch 'set-validator!})

(defn- collect-conj-chain
  "Iteratively collect elements from a chain of (conj (conj ... base e1) e2).
   Returns [base-ast [e1 e2 ...]] so the emitter can process them without deep recursion."
  [ast]
  (loop [node ast, elements ()]
    (if (and (= (:op node) :call)
             (let [fn-ast (:fn node)]
               (and (= (:op fn-ast) :builtin)
                    (= (:name fn-ast) 'conj))))
      (recur (first (:args node)) (cons (second (:args node)) elements))
      [node (vec elements)])))

;; Helper to unbox anyref to i32 (assumes i31ref)
(defn- emit-unbox [code]
  [:i31.get_s [:ref.cast [:ref :i31] code]])

;; Helper to box i32 to anyref (via i31ref)
(defn- emit-box [code]
  [:ref.i31 code])

;; Helper to emit a boolean result from an i32 expression
;; Returns $Boolean struct (global $__true or $__false)
(defn- emit-bool [i32-code]
  [:if [:result :anyref] i32-code
   [:then [:global.get "$__true"]]
   [:else [:global.get "$__false"]]])

;; Emit raw i32 value from an AST node known to have :num-type :i32
;; This avoids box/unbox overhead for typed integer operations.
;; Defined before emit-comparison-as-i32 which uses it.
(defn- emit-i32-raw [ast]
  (cond
    ;; Integer constant: just the raw i32
    (and (= (:op ast) :const) (= (:type ast) :int))
    [:i32.const (:val ast)]

    ;; Typed arithmetic call: emit the i32 operation directly (no boxing)
    (and (= (:op ast) :call) (= :i32 (:num-type ast)))
    (let [fn-name (get-in ast [:fn :name])
          args (:args ast)]
      (case fn-name
        (+ - * /)
        (let [wasm-op (case fn-name + :i32.add - :i32.sub * :i32.mul / :i32.div_s)
              a (emit-i32-raw (first args))
              b (emit-i32-raw (second args))]
          [wasm-op a b])
        inc [:i32.add (emit-i32-raw (first args)) [:i32.const 1]]
        dec [:i32.sub (emit-i32-raw (first args)) [:i32.const 1]]
        ;; fallback: emit normally and unbox
        (emit-unbox (emit ast))))

    ;; Local with known i32 type: unbox from i31ref
    (and (= (:op ast) :local) (= :i32 (:num-type ast)))
    [:i31.get_s [:ref.cast [:ref :i31] [:local.get (str "$" (munge-name (:name ast)))]]]

    ;; if with i32 result: emit both branches as i32 directly
    (and (= (:op ast) :if) (= :i32 (:num-type ast)))
    [:if [:result :i32] [:call "$truthy" (emit (:test ast))]
     [:then (emit-i32-raw (:then ast))]
     [:else (emit-i32-raw (:else ast))]]

    ;; do with i32 result: emit normally but unbox the final result
    (and (= (:op ast) :do) (= :i32 (:num-type ast)))
    (emit-unbox (emit ast))

    ;; let with i32 result: emit normally but unbox the final result
    (and (= (:op ast) :let) (= :i32 (:num-type ast)))
    (emit-unbox (emit ast))

    ;; Fallback: emit normally and unbox
    :else
    (emit-unbox (emit ast))))

(defn- emit-f64-raw
  "Emit an expression as raw f64, avoiding boxing/unboxing when possible."
  [ast]
  (cond
    ;; Float constant
    (= (:op ast) :float)
    [:f64.const (:val ast)]

    ;; Int constant promoted to f64
    (and (= (:op ast) :const) (= (:type ast) :int))
    [:f64.const (double (:val ast))]

    ;; Typed arithmetic call with f64 result
    (and (= (:op ast) :call) (= :f64 (:num-type ast)))
    (let [fn-name (get-in ast [:fn :name])
          args (:args ast)]
      (case fn-name
        (+ - * /)
        (let [wasm-op (case fn-name + :f64.add - :f64.sub * :f64.mul / :f64.div)]
          [wasm-op (emit-f64-raw (first args)) (emit-f64-raw (second args))])
        inc [:f64.add (emit-f64-raw (first args)) [:f64.const 1.0]]
        dec [:f64.sub (emit-f64-raw (first args)) [:f64.const 1.0]]
        ;; fallback: emit normally and extract f64
        [:struct.get "$Float" "$val" [:ref.cast [:ref "$Float"] (emit ast)]]))

    ;; Local with known f64 type
    (and (= (:op ast) :local) (= :f64 (:num-type ast)))
    [:struct.get "$Float" "$val" [:ref.cast [:ref "$Float"] [:local.get (str "$" (munge-name (:name ast)))]]]

    ;; i32 promoted to f64
    (= :i32 (:num-type ast))
    [:f64.convert_i32_s (emit-i32-raw ast)]

    ;; if with f64 result
    (and (= (:op ast) :if) (= :f64 (:num-type ast)))
    [:if [:result :f64] [:call "$truthy" (emit (:test ast))]
     [:then (emit-f64-raw (:then ast))]
     [:else (emit-f64-raw (:else ast))]]

    ;; do/let with f64 result: emit normally and extract
    (and (#{:do :let} (:op ast)) (= :f64 (:num-type ast)))
    [:struct.get "$Float" "$val" [:ref.cast [:ref "$Float"] (emit ast)]]

    ;; Fallback: emit normally and extract f64
    :else
    [:struct.get "$Float" "$val" [:ref.cast [:ref "$Float"] (emit ast)]]))

(defn- emit-f64-box
  "Box an f64 value into a $Float struct."
  [f64-ir]
  [:struct.new "$Float" [:i32.const 5] f64-ir])

;; Emit a comparison call directly as i32, skipping $Boolean boxing/unboxing
(defn- emit-comparison-as-i32 [ast]
  (let [fn-name (get-in ast [:fn :name])
        args (:args ast)]
    (case fn-name
      ;; = and not= use $eq which already returns i32
      = (if (every? #(= :i32 (:num-type %)) args)
          [:i32.eq (emit-i32-raw (first args)) (emit-i32-raw (second args))]
          [:call "$eq" (emit (first args)) (emit (second args))])
      not= (if (every? #(= :i32 (:num-type %)) args)
             [:i32.ne (emit-i32-raw (first args)) (emit-i32-raw (second args))]
             [:i32.eqz [:call "$eq" (emit (first args)) (emit (second args))]])
      ;; All others return $Boolean - extract the val field directly
      (< > <= >=)
      (cond
        (every? #(= :i32 (:num-type %)) args)
        (let [wasm-op (case fn-name < :i32.lt_s > :i32.gt_s <= :i32.le_s >= :i32.ge_s)]
          [wasm-op (emit-i32-raw (first args)) (emit-i32-raw (second args))])
        (every? #(#{:i32 :f64} (:num-type %)) args)
        (let [wasm-op (case fn-name < :f64.lt > :f64.gt <= :f64.le >= :f64.ge)]
          [wasm-op (emit-f64-raw (first args)) (emit-f64-raw (second args))])
        :else
        (let [a (emit (first args))
              b (emit (second args))
              cmp-fn (str "$cmp_" (case fn-name < "lt" > "gt" <= "le" >= "ge"))]
          [:struct.get "$Boolean" "$val" [:ref.cast [:ref "$Boolean"] [:call cmp-fn a b]]]))
      neg?
      (let [a (first args)]
        (cond
          (= :i32 (:num-type a)) [:i32.lt_s (emit-i32-raw a) [:i32.const 0]]
          (= :f64 (:num-type a)) [:f64.lt (emit-f64-raw a) [:f64.const 0.0]]
          :else [:struct.get "$Boolean" "$val" [:ref.cast [:ref "$Boolean"] [:call "$cmp_lt" (emit a) [:ref.i31 [:i32.const 0]]]]]))
      pos?
      (let [a (first args)]
        (cond
          (= :i32 (:num-type a)) [:i32.gt_s (emit-i32-raw a) [:i32.const 0]]
          (= :f64 (:num-type a)) [:f64.gt (emit-f64-raw a) [:f64.const 0.0]]
          :else [:struct.get "$Boolean" "$val" [:ref.cast [:ref "$Boolean"] [:call "$cmp_gt" (emit a) [:ref.i31 [:i32.const 0]]]]]))
      zero?
      (let [a (first args)]
        (cond
          (= :i32 (:num-type a)) [:i32.eqz (emit-i32-raw a)]
          (= :f64 (:num-type a)) [:f64.eq (emit-f64-raw a) [:f64.const 0.0]]
          :else [:struct.get "$Boolean" "$val" [:ref.cast [:ref "$Boolean"] [:call "$zero_QMARK_" (emit a)]]]))
      NaN?
      [:struct.get "$Boolean" "$val" [:ref.cast [:ref "$Boolean"] [:call "$is_nan" (emit (first args))]]]
      ;; Fallback - shouldn't happen but just in case
      [:call "$truthy" (emit ast)])))

;; Check if an AST node is a call to a comparison builtin
(defn- comparison-call? [ast]
  (and (= (:op ast) :call)
       (= (get-in ast [:fn :op]) :builtin)
       (contains? comparison-builtins (get-in ast [:fn :name]))))

;; Emit code that evaluates to i32 (for conditionals)
;; Optimizes comparison builtins to skip $truthy dispatch
(defn- emit-as-i32 [ast]
  "Emit code and check truthiness for conditionals that need i32"
  (if (comparison-call? ast)
    (emit-comparison-as-i32 ast)
    [:call "$truthy" (emit ast)]))


(defn- emit-call-node
  "Handle all :call AST nodes. Extracted from emit to avoid paren hook issues."
  [{:keys [] :as ast}]
  (let [fn-ast (:fn ast)
        fn-ast-op (:op fn-ast)
        call-args (:args ast)]
    ;; IIFE elimination: ((fn [x y] body) a b) -> (let [x a, y b] body)
    (if (and (= fn-ast-op :fn)
             (not (:is-closure fn-ast))
             (nil? (:arities fn-ast))
             (not (:has-recur fn-ast))
             (= (count (:params fn-ast)) (count call-args)))
      (emit {:op :let
             :bindings (mapv (fn [p a] {:name p :init a}) (:params fn-ast) call-args)
             :body (:body fn-ast)})
      ;; Normal call dispatch
      (let [fn-name (when (#{:builtin :global :fn-global} fn-ast-op) (:name fn-ast))
            tail? *tail-position*
            call-prefix (if tail? "return_call" "call")]
        (binding [*tail-position* false]
          (emit-call-dispatch ast fn-ast fn-ast-op fn-name call-args call-prefix))))))

(defn- emit-call-dispatch
  "Dispatch a non-IIFE call to the appropriate handler."
  [ast fn-ast fn-ast-op fn-name call-args call-prefix]
  (cond
    ;; Arithmetic: use inline ops when types are known, else call runtime
    (contains? arithmetic-builtins fn-name)
    (case (:num-type ast)
      :i32 (emit-box (emit-i32-raw ast))
      :f64 (emit-f64-box (emit-f64-raw ast))
      (case fn-name
        (+ - * /)
        (let [op-name (case fn-name + "$add" - "$sub" * "$mul" / "$div")]
          [:call op-name (emit (first call-args)) (emit (second call-args))])
        inc [:call "$inc" (emit (first call-args))]
        dec [:call "$dec" (emit (first call-args))]))

    ;; Comparisons: compare, return $Boolean
    (contains? comparison-builtins fn-name)
    (case fn-name
      (= not=)
      (let [a (emit (first call-args))
            b (emit (second call-args))]
        (case fn-name
          = (emit-bool [:call "$eq" a b])
          not= (emit-bool [:i32.eqz [:call "$eq" a b]])))
      (< > <= >=)
      (cond
        (every? #(= :i32 (:num-type %)) call-args)
        (let [wasm-op (case fn-name < :i32.lt_s > :i32.gt_s <= :i32.le_s >= :i32.ge_s)]
          (emit-bool [wasm-op (emit-i32-raw (first call-args)) (emit-i32-raw (second call-args))]))
        (every? #(#{:i32 :f64} (:num-type %)) call-args)
        (let [wasm-op (case fn-name < :f64.lt > :f64.gt <= :f64.le >= :f64.ge)]
          (emit-bool [wasm-op (emit-f64-raw (first call-args)) (emit-f64-raw (second call-args))]))
        :else
        (let [cmp-fn (str "$cmp_" (case fn-name < "lt" > "gt" <= "le" >= "ge"))]
          [:call cmp-fn (emit (first call-args)) (emit (second call-args))]))
      neg?
      (let [a (first call-args)]
        (cond
          (= :i32 (:num-type a)) (emit-bool [:i32.lt_s (emit-i32-raw a) [:i32.const 0]])
          (= :f64 (:num-type a)) (emit-bool [:f64.lt (emit-f64-raw a) [:f64.const 0.0]])
          :else [:call "$cmp_lt" (emit a) [:ref.i31 [:i32.const 0]]]))
      pos?
      (let [a (first call-args)]
        (cond
          (= :i32 (:num-type a)) (emit-bool [:i32.gt_s (emit-i32-raw a) [:i32.const 0]])
          (= :f64 (:num-type a)) (emit-bool [:f64.gt (emit-f64-raw a) [:f64.const 0.0]])
          :else [:call "$cmp_gt" (emit a) [:ref.i31 [:i32.const 0]]]))
      zero?
      (let [a (first call-args)]
        (cond
          (= :i32 (:num-type a)) (emit-bool [:i32.eqz (emit-i32-raw a)])
          (= :f64 (:num-type a)) (emit-bool [:f64.eq (emit-f64-raw a) [:f64.const 0.0]])
          :else [:call "$zero_QMARK_" (emit a)]))
      NaN?
      [:call "$is_nan" (emit (first call-args))])

    ;; Boolean ops: use $truthy for polymorphic truthiness
    (contains? boolean-builtins fn-name)
    (case fn-name
      not (emit-bool [:i32.eqz [:call "$truthy" (emit (first call-args))]])
      and
      (let [a (emit (first call-args))
            b (emit (second call-args))]
        [:if [:result :anyref] [:call "$truthy" a]
         [:then b]
         [:else a]])
      or
      (let [a (emit (first call-args))
            b (emit (second call-args))]
        [:if [:result :anyref] [:call "$truthy" a]
         [:then a]
         [:else b]]))

    ;; List operations - work directly with anyref
    (contains? list-builtins fn-name)
    (into [:call (str "$" (munge-name fn-name))] (map emit call-args))

    ;; Vector operations
    (contains? vector-builtins fn-name)
    (let [arg0 (first call-args)
          narrowed (:narrowed-type arg0)]
      (case fn-name
        nth (if (= :vector narrowed)
              [:call "$vector_nth" (emit arg0) (emit-unbox (emit (second call-args)))]
              [:call "$nth_polymorphic" (emit arg0) (emit-unbox (emit (second call-args)))])
        count (case narrowed
                :vector (emit-box [:call "$vector_count" (emit arg0)])
                :string (emit-box [:call "$str_codepoint_count" (emit arg0)])
                :map (emit-box [:struct.get "$HashMap" "$count" [:ref.cast [:ref "$HashMap"] (emit arg0)]])
                :set (emit-box [:struct.get "$HashSet" "$count" [:ref.cast [:ref "$HashSet"] (emit arg0)]])
                (emit-box [:call "$count_internal" (emit arg0)]))
        conj
        (let [[base elements] (collect-conj-chain ast)]
          (reduce (fn [acc elem-ast]
                    [:call "$conj" acc (emit elem-ast)])
                  (emit base)
                  elements))
        vector? [:call "$vector_QMARK_" (emit arg0)]
        empty-vector [:call "$empty_vector"]))

    ;; Polymorphic operations (work on multiple types)
    (contains? polymorphic-builtins fn-name)
    (case fn-name
      assoc [:call "$assoc" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))])

    ;; Reduce operations
    (contains? reduce-builtins fn-name)
    (case fn-name
      reduce
      (if (= (count call-args) 2)
        [:call "$reduce_no_init" (emit (first call-args)) (emit (second call-args))]
        [:call "$reduce" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))])
      reduce-kv [:call "$reduce_kv" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))]
      reduced [:call "$reduced" (emit (first call-args))]
      reduced? [:call "$bool" [:call "$reduced_QMARK_" (emit (first call-args))]])

    ;; Lazy sequence operations
    (contains? lazy-seq-builtins fn-name)
    (case fn-name
      make-lazy-seq [:call "$make_lazy_seq" (emit (first call-args))]
      lazy-seq? [:call "$lazy_seq_QMARK_" (emit (first call-args))]
      lazy-seq-realized? [:call "$lazy_seq_realized_QMARK_" (emit (first call-args))])

    ;; String operations
    (contains? string-builtins fn-name)
    (case fn-name
      str1 [:call "$str1" (emit (first call-args))]
      str-concat [:call "$str_concat" (emit (first call-args)) (emit (second call-args))]
      name [:call "$name_fn" (emit (first call-args))]
      subs [:call "$subs" (emit (first call-args)) (emit-unbox (emit (second call-args))) (emit-unbox (emit (nth call-args 2)))]
      string->mem! (emit-box [:call "$string__GT_mem_BANG_" (emit (first call-args)) (emit-unbox (emit (second call-args)))])
      mem->string [:call "$mem__GT_string" (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))]
      pr-str1 [:call "$pr_str1" (emit (first call-args))]
      char [:call "$char_from_code" (emit-unbox (emit (first call-args)))]
      str-hash (emit-box [:call "$str_hash" (emit (first call-args))]))

    ;; Float operation builtins
    (contains? float-op-builtins fn-name)
    (let [v (emit (first call-args))]
      (case fn-name
        to-float [:struct.new "$Float" [:i32.const 5] [:call "$to_f64" v]]
        to-int [:if [:result :anyref] [:ref.test [:ref :i31] v]
                [:then v]
                [:else [:ref.i31 [:i32.trunc_sat_f64_s [:f64.trunc [:call "$to_f64" v]]]]]]
        math-floor [:struct.new "$Float" [:i32.const 5] [:f64.floor [:call "$to_f64" v]]]
        math-ceil [:struct.new "$Float" [:i32.const 5] [:f64.ceil [:call "$to_f64" v]]]
        math-sqrt [:struct.new "$Float" [:i32.const 5] [:f64.sqrt [:call "$to_f64" v]]]
        math-abs [:struct.new "$Float" [:i32.const 5] [:f64.abs [:call "$to_f64" v]]]
        math-round [:struct.new "$Float" [:i32.const 5] [:f64.nearest [:call "$to_f64" v]]]))

    ;; Exception builtins
    (contains? exception-builtins fn-name)
    (case fn-name
      ex-info [:struct.new "$ExceptionInfo" [:i32.const 100]
               (emit (first call-args)) (emit (second call-args))
               (if (>= (count call-args) 3) (emit (nth call-args 2)) [:ref.null :none])]
      ex-data [:struct.get "$ExceptionInfo" "$data" [:ref.cast [:ref "$ExceptionInfo"] (emit (first call-args))]]
      ex-message [:struct.get "$ExceptionInfo" "$message" [:ref.cast [:ref "$ExceptionInfo"] (emit (first call-args))]]
      ex-cause [:struct.get "$ExceptionInfo" "$cause" [:ref.cast [:ref "$ExceptionInfo"] (emit (first call-args))]])

    ;; String primitives
    (contains? #{'str-index-of 'str-to-lower 'str-to-upper 'str-starts-with 'str-ends-with 'str-trim 'str-replace 'str-split} fn-name)
    (case fn-name
      str-index-of [:call "$str_index_of" (emit (first call-args)) (emit (second call-args))]
      str-to-lower [:call "$str_to_lower" (emit (first call-args))]
      str-to-upper [:call "$str_to_upper" (emit (first call-args))]
      str-starts-with [:call "$str_starts_with" (emit (first call-args)) (emit (second call-args))]
      str-ends-with [:call "$str_ends_with" (emit (first call-args)) (emit (second call-args))]
      str-trim [:call "$str_trim" (emit (first call-args))]
      str-replace [:call "$str_replace" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))]
      str-split [:call "$str_split" (emit (first call-args)) (emit (second call-args))])

    ;; Print operations (WASI fd_write)
    (contains? #{'print! 'pr! 'print-str!} fn-name)
    (case fn-name
      print! [:call "$print_BANG_" (emit (first call-args))]
      pr! [:call "$pr_BANG_" (emit (first call-args))]
      print-str! [:call "$print_str_BANG_" (emit (first call-args))])

    ;; Metadata operations
    (contains? metadata-builtins fn-name)
    (case fn-name
      with-meta [:call "$with_meta_" (emit (first call-args)) (emit (second call-args))]
      meta [:call "$meta_" (emit (first call-args))])

    ;; Atom watch/validator operations
    (contains? atom-watch-builtins fn-name)
    (case fn-name
      add-watch [:call "$add_watch" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))]
      remove-watch [:call "$remove_watch" (emit (first call-args)) (emit (second call-args))]
      set-validator! [:call "$set_validator_BANG_" (emit (first call-args)) (emit (second call-args))])

    ;; Regex
    (= fn-name 're-pattern)
    [:struct.new "$Regex" [:i32.const 98] (emit (first call-args))]

    ;; Bit operations: native WASM i32 instructions
    (contains? bit-builtins fn-name)
    (case fn-name
      bit-and (emit-box [:i32.and (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))])
      bit-or (emit-box [:i32.or (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))])
      bit-xor (emit-box [:i32.xor (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))])
      bit-not (emit-box [:i32.xor (emit-unbox (emit (first call-args))) [:i32.const -1]])
      bit-shift-left (emit-box [:i32.shl (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))])
      bit-shift-right (emit-box [:i32.shr_s (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))])
      unsigned-bit-shift-right (emit-box [:i32.shr_u (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))])
      bit-test [:call "$bool" [:i32.and [:i32.shr_u (emit-unbox (emit (first call-args))) (emit-unbox (emit (second call-args)))] [:i32.const 1]]])

    ;; Compare: three-way comparison returning -1/0/1
    (contains? compare-builtins fn-name)
    [:call "$__compare" (emit (first call-args)) (emit (second call-args))]

    ;; Array operations: native WasmGC array instructions
    (contains? array-op-builtins fn-name)
    (case fn-name
      make-array [:array.new_default "$AnyArray" (emit-unbox (emit (first call-args)))]
      aget [:array.get "$AnyArray" [:ref.cast [:ref "$AnyArray"] (emit (first call-args))] (emit-unbox (emit (second call-args)))]
      aset [:call "$__aset" (emit (first call-args)) (emit-unbox (emit (second call-args))) (emit (nth call-args 2))]
      alength (emit-box [:array.len [:ref.cast [:ref "$AnyArray"] (emit (first call-args))]])
      aclone [:call "$__aclone" (emit (first call-args))]
      acopy [:block [:result :anyref]
             [:array.copy "$AnyArray" "$AnyArray"
              [:ref.cast [:ref "$AnyArray"] (emit (nth call-args 2))] (emit-unbox (emit (nth call-args 3)))
              [:ref.cast [:ref "$AnyArray"] (emit (first call-args))] (emit-unbox (emit (second call-args)))
              (emit-unbox (emit (nth call-args 4)))]
             [:ref.null :none]]
      object-array [:call "$__object_array" (emit (first call-args))]
      array? [:call "$bool" [:ref.test [:ref "$AnyArray"] (emit (first call-args))]]
      vector-from-array [:call "$vector_from_array" (emit (first call-args))])

    ;; Transient collection operations
    (contains? transient-builtins fn-name)
    (case fn-name
      transient    [:call "$transient" (emit (first call-args))]
      persistent!  [:call "$persistent_BANG_" (emit (first call-args))]
      conj!        [:call "$conj_BANG_" (emit (first call-args)) (emit (second call-args))]
      assoc!       [:call "$assoc_BANG_" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))]
      dissoc!      [:call "$dissoc_BANG_" (emit (first call-args)) (emit (second call-args))]
      disj!        [:call "$disj_BANG_" (emit (first call-args)) (emit (second call-args))]
      pop!         [:call "$pop_BANG_" (emit (first call-args))])

    ;; Map operations
    (contains? map-builtins fn-name)
    (case fn-name
      get (if (= (count call-args) 3)
            [:call "$hash_map_get_default" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))]
            [:call "$hash_map_get" (emit (first call-args)) (emit (second call-args))])
      contains? [:call "$contains_QMARK_" (emit (first call-args)) (emit (second call-args))]
      map? [:call "$map_QMARK_" (emit (first call-args))]
      empty-hash-map [:call "$empty_hash_map"]
      assoc-map [:call "$hash_map_assoc" (emit (first call-args)) (emit (second call-args)) (emit (nth call-args 2))]
      make-array-map [:call "$make_array_map" (emit (first call-args)) (emit-unbox (emit (second call-args)))]
      dissoc [:call "$dissoc" (emit (first call-args)) (emit (second call-args))]
      keys [:call "$keys" (emit (first call-args))]
      vals [:call "$vals" (emit (first call-args))])

    ;; Set operations
    (contains? set-builtins fn-name)
    (case fn-name
      set? [:call "$set_QMARK_" (emit (first call-args))]
      empty-hash-set [:call "$empty_hash_set"]
      set-conj [:call "$set_conj" (emit (first call-args)) (emit (second call-args))]
      disj [:call "$disj" (emit (first call-args)) (emit (second call-args))])

    ;; Seq operations
    (contains? seq-builtins fn-name)
    (let [arg0 (first call-args)
          narrowed (:narrowed-type arg0)]
      (case fn-name
        seq [:call "$seq" (emit arg0)]
        seq? [:call "$seq_QMARK_" (emit arg0)]
        seqable? [:call "$seqable_QMARK_" (emit arg0)]
        empty? (case narrowed
                 :vector [:call "$bool" [:i32.eqz [:call "$vector_count" (emit arg0)]]]
                 :map [:call "$bool" [:i32.eqz [:struct.get "$HashMap" "$count" [:ref.cast [:ref "$HashMap"] (emit arg0)]]]]
                 :set [:call "$bool" [:i32.eqz [:struct.get "$HashSet" "$count" [:ref.cast [:ref "$HashSet"] (emit arg0)]]]]
                 [:call "$empty_QMARK_" (emit arg0)])))

    ;; Atom operations
    (contains? atom-builtins fn-name)
    (case fn-name
      atom [:call "$atom" (emit (first call-args))]
      deref [:call "$deref" (emit (first call-args))]
      atom? [:call "$atom_QMARK_" (emit (first call-args))]
      reset! [:call "$reset_BANG_" (emit (first call-args)) (emit (second call-args))]
      swap!
      (let [a (emit (first call-args))
            f (emit (second call-args))
            extra-args (drop 2 call-args)]
        (if (empty? extra-args)
          [:call "$swap_BANG_" a f]
          (into [:call (str "$swap_BANG_" (inc (count extra-args))) a f]
                (map emit extra-args)))))

    ;; User-defined function call (callable global - may hold closure)
    (= fn-ast-op :global)
    (let [munged (munge-name fn-name)
          emitted-args (into [] (map emit call-args))
          arity (count emitted-args)]
      (cond
        ;; Host import: unbox args to i32, box i32 result
        (contains? *host-import-fns* munged)
        (emit-box (into [:call (str "$" munged)] (map emit-unbox emitted-args)))
        ;; Callable global (closure) - use invokeN
        (contains? *callable-globals* fn-name)
        (into [(keyword call-prefix) (str "$invoke" arity) [:global.get (str "$" munged)]] emitted-args)
        ;; Direct function - use internal name if available
        :else
        (let [call-name (get *internal-fn-names* munged munged)]
          (into [(keyword call-prefix) (str "$" call-name)] emitted-args))))

    ;; Direct function global - always a direct call
    (= fn-ast-op :fn-global)
    (let [munged (munge-name fn-name)
          emitted-args (into [] (map emit call-args))
          arg-count (count emitted-args)
          fn-info (or (get *direct-fn-globals* fn-name) (:fn-info fn-ast))
          fixed-arities (or (:arities fn-info) #{})
          variadic? (:variadic? fn-info)
          min-arity (or (:min-arity fn-info) 0)
          is-true-multi-arity (> (count fixed-arities) 1)
          has-variadic-alongside-fixed (and variadic? (seq fixed-arities))
          is-multi-arity (or is-true-multi-arity has-variadic-alongside-fixed)
          has-exact-match (contains? fixed-arities arg-count)
          build-rest-list (fn [rest-args]
                            (if (empty? rest-args)
                              [:ref.null :none]
                              (reduce (fn [acc arg] [:call "$cons" arg acc])
                                      [:ref.null :none]
                                      (reverse rest-args))))]
      (cond
        ;; Multi-arity with exact match
        (and is-multi-arity has-exact-match)
        (into [(keyword call-prefix) (str "$" munged "_arity" arg-count "_internal")] emitted-args)

        ;; Multi-arity with variadic (no exact match)
        (and is-multi-arity variadic? (not has-exact-match))
        (let [variadic-min (if (seq fixed-arities)
                             (apply max (filter #(<= % arg-count) (conj fixed-arities min-arity)))
                             min-arity)
              required-args (take variadic-min emitted-args)
              rest-args (drop variadic-min emitted-args)]
          (into [(keyword call-prefix) (str "$" munged "_variadic_internal")]
                (concat required-args [(build-rest-list rest-args)])))

        ;; Single variadic function
        variadic?
        (let [required-args (take min-arity emitted-args)
              rest-args (drop min-arity emitted-args)
              call-name (get *internal-fn-names* munged munged)]
          (into [(keyword call-prefix) (str "$" call-name)]
                (concat required-args [(build-rest-list rest-args)])))

        ;; Regular single-arity function
        :else
        (let [call-name (get *internal-fn-names* munged munged)]
          (into [(keyword call-prefix) (str "$" call-name)] emitted-args))))

    ;; Builtin not in special categories - legacy call
    (= fn-ast-op :builtin)
    (let [emitted-args (into [] (map emit call-args))
          munged (munge-name fn-name)
          call-name (get *internal-fn-names* munged munged)]
      (into [(keyword call-prefix) (str "$" call-name)] emitted-args))

    ;; Calling a local variable - must be a closure, use invokeN
    (= fn-ast-op :local)
    (let [emitted-args (into [] (map emit call-args))
          arity (count emitted-args)]
      (into [(keyword call-prefix) (str "$invoke" arity) [:local.get (str "$" (munge-name (:name fn-ast)))]]
            emitted-args))

    ;; Calling a captured variable - must be a closure, use invokeN
    (= fn-ast-op :captured)
    (let [emitted-args (into [] (map emit call-args))
          arity (count emitted-args)]
      (into [(keyword call-prefix) (str "$invoke" arity) (emit fn-ast)]
            emitted-args))

    ;; Calling the result of another expression (e.g., ((constantly x)))
    :else
    (let [emitted-args (into [] (map emit call-args))
          arity (count emitted-args)]
      (into [(keyword call-prefix) (str "$invoke" arity) (emit fn-ast)]
            emitted-args))))


(defn emit [{:keys [op] :as ast}]
  (cond
    ;; Constants are now boxed (anyref via i31ref)
    (= op :const)
    (case (:type ast)
      :int (let [v (:val ast)]
             ;; i31ref can only hold 31-bit signed integers (-1073741824 to 1073741823)
             ;; Larger integers must be stored as Float (f64)
             (if (and (>= v -1073741824) (<= v 1073741823))
               (emit-box [:i32.const v])
               [:struct.new "$Float" [:i32.const 5] [:f64.const (double v)]]))
      :bool (if (= (:val ast) 1) [:global.get "$__true"] [:global.get "$__false"])
      :nil [:ref.null :none]
      :keyword (emit-box [:i32.const (:val ast)])
      ;; Fallback for old-style consts without type
      (emit-box [:i32.const (:val ast)]))

    (= op :nil) [:ref.null :none]
    ;; Keywords are struct references with unique IDs
    (= op :keyword) [:struct.new "$Keyword" [:i32.const 2] [:i32.const (:id ast)]]
    ;; Strings are interned globals with unique IDs
    (= op :string) [:global.get (str "$__str_" (:id ast))]
    ;; Symbols are globals (like strings) - initialized with name/namespace
    (= op :symbol) [:global.get (str "$__sym_" (:id ast))]
    ;; Floats are struct references with f64 value
    ;; Handle special values: Infinity, -Infinity, NaN
    (= op :float) (let [v (:val ast)]
                    [:struct.new "$Float" [:i32.const 5]
                     [:f64.const (cond
                                   (Double/isNaN v) ##NaN
                                   (= v Double/POSITIVE_INFINITY) ##Inf
                                   (= v Double/NEGATIVE_INFINITY) ##-Inf
                                   :else v)]])
    (= op :local) [:local.get (str "$" (munge-name (:name ast)))]
    (= op :global) [:global.get (str "$" (munge-name (:name ast)))]
    ;; Direct function used as a value - reference the wrapper closure global
    (= op :fn-global) (do
                        (set! *fn-refs* (conj *fn-refs* (:name ast)))
                        [:global.get (str "$__fn_" (munge-name (:name ast)))])
    ;; Builtin used as a value - reference the wrapper closure global
    (= op :builtin-ref) [:global.get (str "$__builtin_" (munge-name (:name ast)))]

    ;; Captured variables - fetch from environment array
    (= op :captured)
    [:call "$array_get" [:local.get *closure-env-param*] [:i32.const (:index ast)]]

    (= op :call)
    (emit-call-node ast)

    ;; if: unbox test for conditional, branches return anyref
    (= op :if)
    (let [tail? *tail-position*
          test-code (binding [*tail-position* false] (emit-as-i32 (:test ast)))
          then-code (binding [*tail-position* tail?] (emit (:then ast)))
          else-code (binding [*tail-position* tail?] (emit (:else ast)))]
      [:if [:result :anyref] test-code
       [:then then-code]
       [:else else-code]])

    (= op :let)
    (let [tail? *tail-position*
          local-sets (binding [*tail-position* false]
                       (mapv (fn [b]
                               [:local.set (str "$" (munge-name (:name b))) (emit (:init b))])
                             (:bindings ast)))
          body-code (binding [*tail-position* tail?] (emit (:body ast)))]
      (into [:block [:result :anyref]] (conj local-sets body-code)))

    (= op :loop)
    (let [counter *loop-counter*
          _ (set! *loop-counter* (inc *loop-counter*))
          loop-label (str "$loop" counter)
          init-sets (binding [*tail-position* false]
                      (mapv (fn [b]
                              [:local.set (str "$" (munge-name (:name b))) (emit (:init b))])
                            (:bindings ast)))
          binding-names (mapv :name (:bindings ast))
          body-code (binding [*loop-context* {:loop-label loop-label
                                              :loop-bindings binding-names}
                              *tail-position* false]
                      (emit (:body ast)))]
      (into [:block [:result :anyref]]
            (conj init-sets [:loop loop-label [:result :anyref] body-code])))

    (= op :recur)
    (let [ctx *loop-context*
          loop-label (:loop-label ctx)
          binding-names (:loop-bindings ctx)
          value-emissions (mapv emit (:args ast))
          sets-reversed (mapv (fn [name]
                                [:local.set (str "$" (munge-name name))])
                              (reverse binding-names))]
      ;; Emit values then sets as a sibling sequence, ending with br
      (list* (concat value-emissions sets-reversed [[:br loop-label]])))

    (= op :fn)
    (let [arities (:arities ast)
          multi-arity? (and arities (> (count arities) 1))
          ;; Helper to build env-init IR for captured variables
                    build-env-init (fn [captures]
                           (if (empty? captures)
                             [:call "$array_new" [:i32.const 0]]
                             (let [env-size (count captures)
                                   env-sets (map-indexed
                                             (fn [i sym]
                                               (let [value-code (if (and *capture-indices* (contains? *capture-indices* sym))
                                                                  [:call "$array_get" [:local.get *closure-env-param*] [:i32.const (get *capture-indices* sym)]]
                                                                  [:local.get (str "$" (munge-name sym))])]
                                               [:call "$array_set" [:local.get "$__tmp_env"] [:i32.const i] value-code]))
                                             captures)]
                               (into [:block [:result :anyref]
                                      [:local.set "$__tmp_env" [:call "$array_new" [:i32.const env-size]]]]
                                     (conj (vec env-sets) [:local.get "$__tmp_env"])))))]
      (if multi-arity?
        ;; Multi-arity anonymous fn: emit as MultiClosure with dispatch function
        (let [counter *fn-counter*
              _ (set! *fn-counter* (inc *fn-counter*))
              base-name (str "anon_multi" (inc counter))
              captures (or (:captures ast) [])
              arity-fn-names (mapv (fn [arity-info]
                                    (let [suffix (if (:variadic? arity-info)
                                                   "_variadic"
                                                   (str "_arity" (:arity arity-info)))
                                          fn-name (str base-name suffix)
                                          params (if (:variadic? arity-info)
                                                   (conj (:params arity-info) (:rest-param arity-info))
                                                   (:params arity-info))]
                                      {:wasm-name (emit-closure-function fn-name params (:body arity-info) captures
                                                                         :has-recur (:has-recur arity-info))
                                       :arity (:arity arity-info)
                                       :variadic? (:variadic? arity-info)
                                       :param-count (count params)}))
                                  arities)
              ;; Build dispatch function (as string for add-function!)
              fixed-fns (filter (complement :variadic?) arity-fn-names)
              variadic-fn (first (filter :variadic? arity-fn-names))
              dispatch-name (str "$" base-name "_dispatch")
              gen-destructure (fn [n]
                                (if (zero? n)
                                  ["" "" " (local.get $__env)"]
                                  (let [locals (apply str (for [i (range n)]
                                                            (str "(local $a" i " anyref) ")))
                                        destruct (apply str
                                                        (for [i (range n)]
                                                          (str "(local.set $a" i " (call $first (local.get $args)))\n      "
                                                               (when (< i (dec n))
                                                                 (str "(local.set $args (call $rest (local.get $args)))\n      ")))))
                                        refs (str " (local.get $__env)" (apply str (for [i (range n)] (str " (local.get $a" i ")"))))]
                                    [locals destruct refs])))
              gen-variadic-destructure (fn []
                                         (let [n-required (:arity variadic-fn)]
                                           (if (zero? n-required)
                                             ["" "" " (local.get $__env) (local.get $args)"]
                                             (let [locals (apply str (for [i (range n-required)]
                                                                      (str "(local $a" i " anyref) ")))
                                                   destruct (apply str
                                                                   (for [i (range n-required)]
                                                                     (str "(local.set $a" i " (call $first (local.get $args)))\n      "
                                                                          "(local.set $args (call $rest (local.get $args)))\n      ")))
                                                   refs (str " (local.get $__env)"
                                                             (apply str (for [i (range n-required)] (str " (local.get $a" i ")")))
                                                             " (local.get $args)")]
                                               [locals destruct refs]))))
              else-case (if variadic-fn
                          (let [[_ v-destruct v-refs] (gen-variadic-destructure)]
                            (str v-destruct "(call " (:wasm-name variadic-fn) v-refs ")"))
                          "(unreachable)")
              dispatch-body (reduce
                             (fn [else-code fn-info]
                               (let [[_ f-destruct f-refs] (gen-destructure (:arity fn-info))]
                                 (str "(if (result anyref) (i32.eq (local.get $argc) (i32.const " (:arity fn-info) "))\n      (then\n      "
                                      f-destruct
                                      "(call " (:wasm-name fn-info) f-refs "))\n      "
                                      "(else " else-code "))")))
                             else-case
                             (reverse (sort-by :arity fixed-fns)))
              max-args (max (if (seq fixed-fns) (apply max (map :arity fixed-fns)) 0)
                            (if variadic-fn (:arity variadic-fn) 0))
              all-locals (apply str (for [i (range max-args)] (str "(local $a" i " anyref) ")))
              func-def (str "(func " dispatch-name " (type $MultiClosureDispatch) "
                            "(param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)\n    "
                            all-locals "\n    "
                            dispatch-body ")")
              _ (add-function! func-def)
              _ (set! *closure-funcs* (conj *closure-funcs* dispatch-name))]
          [:struct.new "$MultiClosure" [:i32.const 11] (build-env-init captures) [:ref.func dispatch-name]])
        ;; Single-arity fn
        (let [counter *fn-counter*
              _ (set! *fn-counter* (inc *fn-counter*))
              is-closure (:is-closure ast)
              captures (:captures ast)
              params (:params ast)
              arity (count params)
              self-name (:fn-name ast)]
          (if is-closure
            (let [fn-name (emit-closure-function (str "closure" (inc counter)) params (:body ast) captures
                                                 :has-recur (:has-recur ast) :self-name self-name)
                  closure-type (str "$Closure" arity)]
              [:struct.new closure-type [:i32.const 11] [:ref.func fn-name] (build-env-init captures)])
            (let [fn-name (emit-closure-function (str "fn" (inc counter)) params (:body ast) []
                                                 :has-recur (:has-recur ast) :self-name self-name)
                  closure-type (str "$Closure" arity)
                  global-name (str "$__lifted_fn" (inc counter))]
              ;; Hoist non-capturing fn to a global singleton initialized in $start
              (set! *globals-emit* (conj *globals-emit*
                                         (str "(global " global-name " (mut anyref) (ref.null none))")))
              (set! *lifted-fn-inits*
                    (conj *lifted-fn-inits*
                          (str "(global.set " global-name
                               " (struct.new " closure-type
                               " (i32.const 11) (ref.func " fn-name
                               ") (call $array_new (i32.const 0))))")))
              [:global.get global-name])))))

    (= op :do)
    (let [tail? *tail-position*
          exprs (:exprs ast)
          n (count exprs)
          emitted (map-indexed (fn [i e]
                                 (binding [*tail-position* (and tail? (= i (dec n)))]
                                   (emit e)))
                               exprs)
          emitted (remove nil? emitted)
          side-effects (butlast emitted)
          result (or (last emitted) [:ref.null :none])
          ;; Wrap side-effect exprs in (drop ...)
          drops (mapv (fn [e] [:drop e]) side-effects)]
      (into [:block [:result :anyref]] (conj drops result)))

    (= op :set!)
    (let [munged (munge-name (:name ast))]
      [:block [:result :anyref]
       [:global.set (str "$" munged) (emit (:val ast))]
       [:global.get (str "$" munged)]])

    ;; throw: (throw expr) - throws an exception with anyref value
    (= op :throw)
    (list [:throw "$exn" (emit (:val ast))] [:unreachable])

    ;; try/catch/finally
    (= op :try)
    (let [{:keys [body catch finally]} ast
          has-catch (some? catch)
          has-finally (some? finally)
          body-code (binding [*tail-position* false] (emit body))]
      (cond
        has-catch
        (let [binding-name (munge-name (:binding catch))
              catch-code (emit (:body catch))
              finally-code (when has-finally (emit finally))
              result [:block "$__no_exn" [:result :anyref]
                      [:block "$__catch_entry" [:result :anyref]
                       [:try_table [:result :anyref] [:catch "$exn" "$__catch_entry"]
                        body-code]
                       [:br "$__no_exn"]]
                      [:local.set (str "$" binding-name)]
                      catch-code]]
          (if has-finally
            [:block [:result :anyref] result finally-code :drop]
            result))

        has-finally
        (let [finally-code (emit finally)]
          [:block [:result :anyref] body-code finally-code :drop])

        :else body-code))

    (= op :def)
    (let [munged (munge-name (:name ast))
          init (:init ast)]
      (cond
        ;; Host import: register import, no function body emitted
        (= (:op init) :host-import)
        (let [arity (:arity init)
              func-name (str "$" munged)
              param-decls (str-join " " (repeat arity "(param i32)"))
              import-str (str "(import \"" (:module init) "\" \"" (:import-name init)
                              "\" (func " func-name " " param-decls " (result i32)))")]
          (set! *host-imports* (conj *host-imports* import-str))
          (set! *host-import-fns* (conj *host-import-fns* munged))
          nil)

        (= (:op init) :fn)
        (do
          (let [arities (:arities init)]
            (if (and arities (> (count arities) 1))
              (doseq [arity-info arities]
                (let [arity-suffix (if (:variadic? arity-info)
                                     "_variadic"
                                     (str "_arity" (:arity arity-info)))
                      munged-base (munge-name (:name ast))
                      full-name (str munged-base arity-suffix)
                      params (if (:variadic? arity-info)
                               (conj (:params arity-info) (:rest-param arity-info))
                               (:params arity-info))]
                  (emit-function full-name params (:body arity-info) full-name
                                 :has-recur (:has-recur arity-info))))
              (let [arity-info (first arities)
                    params (if (and arity-info (:variadic? arity-info))
                             (conj (:params arity-info) (:rest-param arity-info))
                             (or (:params init) (:params arity-info)))]
                (emit-function (:name ast) params
                               (or (:body init) (:body arity-info))
                               (name (:name ast))
                               :has-recur (or (:has-recur init) (:has-recur arity-info))))))
          nil)

        :else
        (do
          (when-not (contains? *globals-declared* munged)
            (set! *globals-declared* (conj *globals-declared* munged))
            (set! *globals-emit* (conj *globals-emit* (str "(global $" munged " (mut anyref) (ref.null none))"))))
          (let [init-fn-name (str "__init_def_" munged)
                init-body (emit-str init)
                init-locals (distinct (collect-locals init))]
            (set! *functions* (conj *functions*
                               (str "(func $" init-fn-name " (result anyref)"
                                    (when (seq init-locals) (str "\n    " (str-join "\n    " init-locals)))
                                    "\n    " init-body ")")))
            [:block [:result :anyref]
             [:global.set (str "$" munged) [:call (str "$" init-fn-name)]]
             [:ref.null :none]]))))

    ;; Protocol definitions
    (= op :defprotocol)
    (do
      (set! *protocols* (assoc *protocols* (:name ast) {:methods (:methods ast)}))
      (doseq [{:keys [name arity arities]} (:methods ast)]
        (set! *protocol-methods* (assoc *protocol-methods* name
                                        {:protocol (:name ast)
                                         :arity arity
                                         :arities (when arities
                                                    (into {} (map (fn [a] [(:arity a) a]) arities)))})))
      [:ref.null :none])

    ;; extend-type implementations
    (= op :extend-type)
    (let [type-tag (:type-tag ast)
          impls (:impls ast)]
      (doseq [{:keys [method impl params]} impls]
        (let [method-info (get *protocol-methods* method)
              multi-arity? (and method-info (:arities method-info) (> (count (:arities method-info)) 1))
              arity (count params)
              fn-name (if multi-arity?
                        (str "__proto_" (munge-name method) "_arity_" arity "_" type-tag)
                        (str "__proto_" (munge-name method) "_" type-tag))
              impl-key (if multi-arity?
                         [type-tag method arity]
                         [type-tag method])]
          (emit-closure-function fn-name params (:body impl) (or (:captures impl) []))
          (set! *protocol-impls* (assoc *protocol-impls* impl-key fn-name))))
      [:ref.null :none])

    ;; extend-protocol: emit each extend-type
    (= op :extend-protocol)
    (do
      (doseq [et (:extend-types ast)]
        (emit et))
      [:ref.null :none])

    ;; Protocol method calls
    (= op :protocol-call)
    (let [method (:method ast)
          args (:args ast)
          arity (count args)
          munged-method (munge-name method)
          method-info (get *protocol-methods* method)
          multi-arity? (and method-info (:arities method-info) (> (count (:arities method-info)) 1))
          dispatch-fn (if multi-arity?
                        (str "$__dispatch_" munged-method "_arity_" arity)
                        (str "$__dispatch_" munged-method))
          call-prefix (if *tail-position* "return_call" "call")]
      (binding [*tail-position* false]
        (into [(keyword call-prefix) dispatch-fn] (map emit args))))

    ;; satisfies? check
    (= op :satisfies?)
    [:call (str "$__satisfies_" (munge-name (:protocol ast))) (emit (:val ast))]

    ;; deftype — generates struct type, constructor, and protocol impls
    (= op :deftype)
    (let [type-name (:name ast)
          fields (:fields ast)
          tag (:tag ast)
          impls (:impls ast)
          munged (munge-name type-name)]
      (set! *user-types* (assoc *user-types* type-name {:tag tag :fields fields :kind :deftype}))
      (let [constructor-sym (or (:constructor-name ast) (symbol (str "->" (name type-name))))
            constructor-munged (munge-name constructor-sym)
            param-decls (str-join " " (mapv (fn [f] (str "(param $" (munge-name f) " anyref)")) fields))
            field-args (str-join " " (mapv (fn [f] (str "(local.get $" (munge-name f) ")")) fields))]
        (add-function! (str "(func $" constructor-munged "_internal " param-decls " (result anyref)\n"
                            "    (struct.new $" munged " (i32.const " tag ") " field-args "))"))
        (set! *internal-fn-names* (assoc *internal-fn-names* constructor-munged (str constructor-munged "_internal")))
        (add-function! (str "(func $" constructor-munged " " param-decls " (result anyref)\n"
                            "    (call $" constructor-munged "_internal " field-args "))")))
      (doseq [{:keys [method impl params]} impls]
        (let [method-info (get *protocol-methods* method)
              multi-arity? (and method-info (:arities method-info) (> (count (:arities method-info)) 1))
              arity (count params)
              fn-name (if multi-arity?
                        (str "__proto_" (munge-name method) "_arity_" arity "_" tag)
                        (str "__proto_" (munge-name method) "_" tag))
              impl-key (if multi-arity?
                         [tag method arity]
                         [tag method])]
          (emit-closure-function fn-name params (:body impl) (or (:captures impl) []))
          (set! *protocol-impls* (assoc *protocol-impls* impl-key fn-name))))
      [:ref.null :none])

    ;; instance? check
    (= op :instance?)
    (let [type-sym (:type ast)
          val-code (emit (:val ast))
          user-type (get *user-types* type-sym)]
      (if user-type
        [:call "$bool" [:i32.eq [:call "$type_tag" val-code] [:i32.const (:tag user-type)]]]
        (case type-sym
          (Number Integer) [:call "$bool" [:ref.test [:ref :i31] val-code]]
          Keyword [:call "$bool" [:i32.eq [:call "$type_tag" val-code] [:i32.const 2]]]
          String [:call "$bool" [:ref.test [:ref "$String"] val-code]]
          Symbol [:call "$bool" [:i32.eq [:call "$type_tag" val-code] [:i32.const 4]]]
          Float [:call "$bool" [:ref.test [:ref "$Float"] val-code]]
          (Cons List ISeq) [:call "$bool" [:ref.test [:ref "$Cons"] val-code]]
          (Vector PersistentVector) [:call "$bool" [:ref.test [:ref "$Vector"] val-code]]
          (HashMap PersistentHashMap) [:call "$bool" [:i32.or [:i32.eq [:call "$type_tag" val-code] [:i32.const 8]] [:i32.eq [:call "$type_tag" val-code] [:i32.const 19]]]]
          (HashSet PersistentHashSet) [:call "$bool" [:i32.eq [:call "$type_tag" val-code] [:i32.const 9]]]
          Atom [:call "$bool" [:ref.test [:ref "$Atom"] val-code]]
          Boolean [:call "$bool" [:i32.eq [:call "$type_tag" val-code] [:i32.const 14]]]
          [:global.get "$__false"])))

    ;; Field access: (.-field obj)
    (= op :field-access)
    (let [field-name (:field ast)
          target-code (emit (:target ast))
          matching-types (for [[type-name {:keys [tag fields]}] *user-types*
                               :let [field-idx (.indexOf (mapv name fields) field-name)]
                               :when (>= field-idx 0)]
                           {:type-name type-name :tag tag :field-idx field-idx :fields fields})]
      (if (= 1 (count matching-types))
        (let [{:keys [type-name field-idx]} (first matching-types)
              munged-type (munge-name type-name)]
          [:struct.get (str "$" munged-type) (inc field-idx)
           [:ref.cast [:ref (str "$" munged-type)] target-code]])
        (reduce (fn [else-code {:keys [type-name tag field-idx]}]
                  (let [munged-type (munge-name type-name)]
                    [:if [:result :anyref] [:i32.eq [:call "$type_tag" target-code] [:i32.const tag]]
                     [:then [:struct.get (str "$" munged-type) (inc field-idx)
                             [:ref.cast [:ref (str "$" munged-type)] target-code]]]
                     [:else else-code]]))
                [:unreachable]
                (reverse matching-types))))

    :else
    (throw (ex-info (str "Unknown AST op: " op) {:ast ast}))))

(defn emit-str
  "Emit an AST node to a WAT string. Bridge from IR to string world.
   Runs optimization passes on the IR before serializing."
  [ast]
  (let [ir (emit ast)]
    (cond
      (nil? ir) nil
      (string? ir) ir
      :else (w/serialize (opt/optimize ir)))))

;; ============================================
;; Builtin Wrapper Generation
;; ============================================

(defn emit-builtin-wrapper
  "Generate a closure wrapper for a builtin used as a value.
   Returns [global-decl func-def] where:
   - global-decl is the global variable declaration
   - func-def is the closure function definition"
  [builtin-name arity]
  (let [munged (munge-name builtin-name)
        global-name (str "$__builtin_" munged)
        func-name (str "$__builtin_" munged "_fn")
        closure-type (str "$Closure" arity)
        func-type (str "$ClosureFunc" arity)
        ;; Generate param list: $__env plus $arg0, $arg1, etc.
        param-decls (str "(param $__env anyref)"
                         (apply str (for [i (range arity)]
                                      (str " (param $arg" i " anyref)"))))
        ;; Generate the call to the builtin
        arg-refs (for [i (range arity)] (str "(local.get $arg" i ")"))
        ;; Construct the AST for the builtin call and emit it
        call-ast {:op :call
                  :fn {:op :builtin :name builtin-name}
                  :args (vec (for [i (range arity)]
                               {:op :local :name (symbol (str "arg" i))}))}
        call-code (emit-str call-ast)
        ;; Function definition
        func-def (str "(func " func-name " (type " func-type ") " param-decls " (result anyref)\n    " call-code ")")
        ;; Global declaration - initialized in $start
        global-decl (str "(global " global-name " (mut anyref) (ref.null none))")]
    {:global-decl global-decl
     :func-def func-def
     :func-name func-name
     :global-name global-name
     :closure-type closure-type
     :arity arity}))

(defn emit-fn-wrapper
  "Generate a closure wrapper for a user-defined function used as a value.
   Similar to emit-builtin-wrapper but calls a user function instead of builtin."
  [fn-name arity]
  (let [munged (munge-name fn-name)
        global-name (str "$__fn_" munged)
        wrapper-fn-name (str "$__fn_" munged "_wrapper")
        closure-type (str "$Closure" arity)
        func-type (str "$ClosureFunc" arity)
        ;; Generate param list: $__env plus $arg0, $arg1, etc.
        param-decls (str "(param $__env anyref)"
                         (apply str (for [i (range arity)]
                                      (str " (param $arg" i " anyref)"))))
        ;; Generate the call to the user function (use internal name if exported)
        arg-refs (apply str (for [i (range arity)] (str " (local.get $arg" i ")")))
        internal-name (get *internal-fn-names* munged)
        call-target (if internal-name (str "$" internal-name) (str "$" munged))
        call-code (str "(call " call-target arg-refs ")")
        ;; Function definition
        func-def (str "(func " wrapper-fn-name " (type " func-type ") " param-decls " (result anyref)\n    " call-code ")")
        ;; Global declaration - initialized in $start
        global-decl (str "(global " global-name " (mut anyref) (ref.null none))")]
    {:global-decl global-decl
     :func-def func-def
     :func-name wrapper-fn-name
     :global-name global-name
     :closure-type closure-type
     :arity arity}))

(defn emit-multi-arity-fn-wrapper
  "Generate a MultiClosure wrapper for a multi-arity/variadic user-defined function.
   The dispatch function takes (env, argc:i32, args:cons_list) and routes to the
   correct _arityN_internal or _variadic_internal function."
  [fn-name fn-info]
  (let [munged (munge-name fn-name)
        global-name (str "$__fn_" munged)
        dispatch-fn-name (str "$__fn_" munged "_dispatch")
        fixed-arities (sort (or (:arities fn-info) #{}))
        variadic? (:variadic? fn-info)
        variadic-arity (or (:variadic-arity fn-info) (:min-arity fn-info) 0)
        ;; Generate destructuring code for N args from cons list
        ;; Returns [locals-decl destructure-code arg-refs]
        gen-destructure (fn [n]
                          (if (zero? n)
                            ["" "" ""]
                            (let [locals (apply str (for [i (range n)]
                                                      (str "(local $a" i " anyref) ")))
                                  destruct (apply str
                                                  (for [i (range n)]
                                                    (str "(local.set $a" i " (call $first (local.get $args)))\n      "
                                                         (when (< i (dec n))
                                                           (str "(local.set $args (call $rest (local.get $args)))\n      ")))))
                                  refs (apply str (for [i (range n)] (str " (local.get $a" i ")")))]
                              [locals destruct refs])))
        ;; Generate variadic destructure: pull out variadic-arity required args, rest stays as list
        gen-variadic-destructure (fn []
                                   (if (zero? variadic-arity)
                                     ["" "" " (local.get $args)"]
                                     (let [locals (apply str (for [i (range variadic-arity)]
                                                               (str "(local $a" i " anyref) ")))
                                           destruct (apply str
                                                           (for [i (range variadic-arity)]
                                                             (str "(local.set $a" i " (call $first (local.get $args)))\n      "
                                                                  "(local.set $args (call $rest (local.get $args)))\n      ")))
                                           refs (str (apply str (for [i (range variadic-arity)] (str " (local.get $a" i ")")))
                                                     " (local.get $args)")]
                                       [locals destruct refs])))
        ;; Build the dispatch body with nested if/else on argc
        ;; Start from the variadic fallback (or unreachable) and wrap with fixed arity checks
        ;; Check if this fn was emitted with multi-arity naming or single-arity naming
        ;; Multi-arity: $name_arity0_internal, $name_variadic_internal
        ;; Single-arity: $name_internal (even if variadic)
        is-true-multi (get *internal-fn-names* (str munged "_variadic"))
        internal-name-fn (fn [arity-n]
                           (let [suffix (str "_arity" arity-n)
                                 full (str munged suffix "_internal")]
                             (str "$" full)))
        variadic-internal (if is-true-multi
                            (str "$" munged "_variadic_internal")
                            (str "$" (get *internal-fn-names* munged (str munged "_internal"))))
        ;; Build the else case (variadic or unreachable)
        else-case (if variadic?
                    (let [[v-locals v-destruct v-refs] (gen-variadic-destructure)]
                      (str v-destruct
                           "(call " variadic-internal v-refs ")"))
                    "(unreachable)")
        ;; Build nested if/else for fixed arities
        dispatch-body (reduce
                       (fn [else-code arity-n]
                         (let [[f-locals f-destruct f-refs] (gen-destructure arity-n)]
                           (str "(if (result anyref) (i32.eq (local.get $argc) (i32.const " arity-n "))\n      (then\n      "
                                f-destruct
                                "(call " (internal-name-fn arity-n) f-refs "))\n      "
                                "(else " else-code "))")))
                       else-case
                       (reverse fixed-arities))
        ;; Collect all needed locals (max across all arities)
        max-args (max (if (seq fixed-arities) (apply max fixed-arities) 0)
                      (if variadic? variadic-arity 0))
        all-locals (apply str (for [i (range max-args)] (str "(local $a" i " anyref) ")))
        ;; Function definition
        func-def (str "(func " dispatch-fn-name " (type $MultiClosureDispatch) "
                      "(param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)\n    "
                      all-locals "\n    "
                      dispatch-body ")")
        ;; Global declaration
        global-decl (str "(global " global-name " (mut anyref) (ref.null none))")]
    {:global-decl global-decl
     :func-def func-def
     :func-name dispatch-fn-name
     :global-name global-name
     :closure-type "$MultiClosure"
     :is-multi true}))

;; ============================================
;; Protocol Dispatch Generation
;; ============================================

(defn generate-dispatch-function
  "Generate a WAT dispatch function for a protocol method using table-based O(1) dispatch.
   Returns {:func-def :table-global-decl :table-init-code}.
   For multi-arity, method-name includes arity suffix (e.g., bar_arity_2)."
  [method-name arity impls]
  (let [munged (munge-name method-name)
        fn-name (str "$__dispatch_" munged)
        table-global (str "$__dispatch_table_" munged)
        table-size (compute-dispatch-table-size)
        ;; Generate param list: arg0 is 'this', the rest are other args
        param-decls (str-join " " (for [i (range arity)]
                                    (str "(param $arg" i " anyref)")))
        arg-list (str-join " " (for [i (range arity)]
                                 (str "(local.get $arg" i ")")))
        ;; Table init: create array then populate entries with impl closures
        init-create (str "(global.set " table-global
                         " (array.new $AnyArray (ref.null none) (i32.const " table-size ")))")
        init-entries (for [[[type-tag _method] _impl-fn-name] impls]
                       (str "(array.set $AnyArray"
                            " (ref.cast (ref $AnyArray) (global.get " table-global "))"
                            " (i32.const " type-tag ")"
                            " (global.get $__proto_" munged "_" type-tag "_closure))"))]
    {:func-def (str "(func " fn-name " " param-decls " (result anyref)\n"
                    "    (local $tag i32)\n"
                    "    (local $impl anyref)\n"
                    "    (local.set $tag (call $type_tag (local.get $arg0)))\n"
                    "    (if (i32.or (i32.lt_s (local.get $tag) (i32.const 0))\n"
                    "                (i32.ge_s (local.get $tag) (i32.const " table-size ")))\n"
                    "      (then (unreachable)))\n"
                    "    (local.set $impl (array.get $AnyArray\n"
                    "      (ref.cast (ref $AnyArray) (global.get " table-global "))\n"
                    "      (local.get $tag)))\n"
                    "    (if (result anyref) (ref.is_null (local.get $impl))\n"
                    "      (then (unreachable))\n"
                    "      (else (call $invoke" arity " (local.get $impl) " arg-list "))))")
     :table-global-decl (str "(global " table-global " (mut anyref) (ref.null none))")
     :table-init-code (vec (cons init-create init-entries))}))

(defn generate-satisfies-function
  "Generate a WAT function to check if a value satisfies a protocol.
   Returns boxed boolean (i31ref)."
  [protocol-name impls]
  (let [munged (munge-name protocol-name)
        fn-name (str "$__satisfies_" munged)
        ;; Get all type tags that have impls for this protocol
        type-tags (vec (set (map first (keys impls))))
        ;; Build check: is type_tag in the set of impl tags?
        check-code (cond
                     (empty? type-tags)
                     "(i32.const 0)"  ;; No impls -> always false

                     (= 1 (count type-tags))
                     ;; Single tag - just direct comparison
                     (str "(i32.eq (call $type_tag (local.get $val)) (i32.const " (first type-tags) "))")

                     :else
                     ;; Multiple tags - use nested i32.or
                     (let [comparisons (map (fn [tag]
                                              (str "(i32.eq (call $type_tag (local.get $val)) (i32.const " tag "))"))
                                            type-tags)]
                       (reduce (fn [acc cmp]
                                 (str "(i32.or " acc " " cmp ")"))
                               (first comparisons)
                               (rest comparisons))))]
    (str "(func " fn-name " (param $val anyref) (result anyref)\n"
         "    (call $bool " check-code "))")))

(defn generate-protocol-impl-closures
  "Generate globals to hold closures for each protocol impl.
   Returns a list of {:global-decl :init-code} maps.
   Keys can be [type-tag method] or [type-tag method arity] for multi-arity."
  [impls]
  (for [[impl-key impl-fn-name] impls]
    (let [type-tag (nth impl-key 0)
          method (nth impl-key 1)
          explicit-arity (when (= 3 (count impl-key)) (nth impl-key 2))
          method-info (get *protocol-methods* method)
          multi-arity? (and method-info (:arities method-info) (> (count (:arities method-info)) 1))
          munged-method (munge-name method)
          arity (or explicit-arity (:arity method-info) 1)
          global-name (if multi-arity?
                        (str "$__proto_" munged-method "_arity_" arity "_" type-tag "_closure")
                        (str "$__proto_" munged-method "_" type-tag "_closure"))]
      {:global-decl (str "(global " global-name " (mut anyref) (ref.null none))")
       :global-name global-name
       :func-name (str "$" impl-fn-name)
       :closure-type (str "$Closure" arity)
       :init-code (str "(global.set " global-name
                       " (struct.new $Closure" arity
                       " (i32.const 11) (ref.func $" impl-fn-name ")"
                       " (call $array_new (i32.const 0))))")})))

(defn emit-prelude-1 []
  (str "(module"
       "\n  ;; WASI imports for printing
  (import \"wasi_snapshot_preview1\" \"fd_write\" (func $fd_write (param i32 i32 i32 i32) (result i32)))"
       "__HOST_IMPORTS__"
       "\n  (memory (export \"memory\") 16)"
       "
  ;; ==========================================
  ;; WasmGC Type Definitions
  ;; ==========================================
  ;; All struct types extend $Tagged with a $__type_id discriminator field.
  ;; This enables reliable type dispatch via tag reads instead of ref.test,
  ;; which is unreliable due to WasmGC's structural typing.
  ;; Tag assignments: nil=0 i31=1 Keyword=2 String=3 Symbol=4 Float=5
  ;; Cons=6 Vector=7 HashMap=8 HashSet=9 Atom=10 Closure=11 LazySeq=12
  ;; Reduced=13 Boolean=14 TransientVector=15 TransientHashMap=16
  ;; TransientHashSet=17 VectorSeq=18 ArrayMap=19 ExceptionInfo=100 User-types=20+

  ;; Base type for all tagged structs
  (type $Tagged (sub (struct (field $__type_id i32))))

  ;; Cons cell: holds two anyref values (first and rest)
  (type $Cons (sub $Tagged (struct (field $__type_id i32) (field $first (mut anyref)) (field $rest (mut anyref)))))

  ;; Boolean: distinct from integers (true=1, false=0)
  (type $Boolean (sub $Tagged (struct (field $__type_id i32) (field $val i32))))

  ;; Keyword: interned symbol with unique ID
  (type $Keyword (sub $Tagged (struct (field $__type_id i32) (field $id i32))))

  ;; UTF-8 byte array (for strings)
  (type $CharArray (array (mut i8)))

  ;; String: interned ID + UTF-8 byte data
  ;; ID >= 0 for interned literals (O(1) equality), -1 for dynamic strings
  (type $String (sub $Tagged (struct (field $__type_id i32) (field $id i32) (field $data (ref $CharArray)))))

  ;; Symbol: interned symbol with unique ID, name string, and optional namespace
  (type $Symbol (sub $Tagged (struct (field $__type_id i32) (field $id i32) (field $name anyref) (field $ns anyref))))

  ;; Float: 64-bit floating point value
  (type $Float (sub $Tagged (struct (field $__type_id i32) (field $val f64))))

  ;; Array of anyref (mutable)
  (type $AnyArray (array (mut anyref)))

  ;; Persistent Vector (32-way branching trie with tail optimization)
  (type $Vector (sub $Tagged (struct
    (field $__type_id i32)
    (field $count i32)      ;; Total number of elements
    (field $shift i32)      ;; Bit shift for trie navigation (0, 5, 10, 15...)
    (field $root anyref)    ;; Root of the trie (null for small vectors)
    (field $tail anyref)))) ;; Tail array (last 1-32 elements)

  ;; HAMT-backed HashMap
  ;; $array field holds root HAMTNode (or null for empty map)
  (type $HashMap (sub $Tagged (struct
    (field $__type_id i32)
    (field $count i32)      ;; Number of key-value pairs
    (field $array anyref)))) ;; HAMT root node (HAMTNode or null)

  ;; HAMT-backed HashSet
  ;; Uses HashMap internally (key = value = element)
  (type $HashSet (sub $Tagged (struct
    (field $__type_id i32)
    (field $count i32)      ;; Number of elements
    (field $array anyref)))) ;; HAMT root node (shared with HashMap)

  ;; HAMT internal node: bitmap-indexed array of children
  ;; Each child is either a HAMTEntry (leaf) or another HAMTNode (branch)
  ;; $edit: 0 = immutable (shared), non-zero = owned by a transient
  (type $HAMTNode (struct
    (field $edit (mut i32))
    (field $bitmap (mut i32))          ;; 32-bit bitmap: which slots are occupied
    (field $children (mut (ref $AnyArray))))) ;; popcount(bitmap) entries

  ;; HAMT leaf entry: single key-value pair
  ;; $edit: 0 = immutable, non-zero = owned by a transient
  (type $HAMTEntry (struct
    (field $edit (mut i32))
    (field $hash i32)       ;; cached hash of key
    (field $key anyref)
    (field $val (mut anyref))))

  ;; HAMT collision node: multiple entries sharing the same hash
  ;; $edit: 0 = immutable, non-zero = owned by a transient
  (type $HAMTCollision (struct
    (field $edit (mut i32))
    (field $hash i32)       ;; shared hash value
    (field $count (mut i32))      ;; number of entries (mutable for transient in-place add)
    (field $entries (mut (ref $AnyArray))))) ;; [k1, v1, k2, v2, ...]

  ;; Atom: mutable reference with watches and validator
  (type $Atom (sub $Tagged (struct
    (field $__type_id i32)
    (field $val (mut anyref))       ;; Mutable value
    (field $watches (mut anyref))   ;; HashMap of key -> watch-fn (null = none)
    (field $validator (mut anyref))))) ;; Validator fn (null = none)

  ;; Reduced: wrapper for early termination in reduce
  (type $Reduced (sub $Tagged (struct
    (field $__type_id i32)
    (field $val anyref))))

  ;; LazySeq: delayed sequence with memoization
  ;; Has extra $__pad field to remain structurally distinct from Cons
  (type $LazySeq (sub $Tagged (struct
    (field $__type_id i32)
    (field $__pad i32)               ;; Padding for structural distinction from Cons
    (field $thunk (mut anyref))      ;; 0-arity closure (null when realized)
    (field $realized (mut anyref))))) ;; cached result (nil or Cons/seq)

  ;; VectorSeq: lazy view over a vector from a given offset
  ;; Tag = 18. O(1) first/rest without allocating Cons cells.
  (type $VectorSeq (sub $Tagged (struct
    (field $__type_id i32)
    (field $vec anyref)              ;; The underlying Vector
    (field $offset i32))))           ;; Current index into the vector

  ;; ExceptionInfo: structured exception data (like Clojure's ex-info)
  (type $ExceptionInfo (sub $Tagged (struct
    (field $__type_id i32)
    (field $message anyref)          ;; String message
    (field $data anyref)             ;; Map of data
    (field $cause anyref))))         ;; Cause (another exception or nil)

  ;; TransientVector: mutable count + tail, shares trie structure with Vector
  ;; Tag = 15
  (type $TransientVector (sub $Tagged (struct
    (field $__type_id i32)
    (field $count (mut i32))
    (field $shift (mut i32))
    (field $root (mut anyref))
    (field $tail (mut anyref))
    (field $edit (mut i32)))))

  ;; TransientHashMap: mutable count + HAMT root
  ;; Tag = 16
  (type $TransientHashMap (sub $Tagged (struct
    (field $__type_id i32)
    (field $count (mut i32))
    (field $array (mut anyref))
    (field $edit (mut i32)))))

  ;; TransientHashSet: mutable count + HAMT root
  ;; Tag = 17
  (type $TransientHashSet (sub $Tagged (struct
    (field $__type_id i32)
    (field $count (mut i32))
    (field $array (mut anyref))
    (field $edit (mut i32)))))

  ;; Regex: compiled regex pattern (stores pattern string)
  (type $Regex (sub $Tagged (struct
    (field $__type_id i32)
    (field $pattern anyref))))   ;; pattern string

  ;; WithMeta: wrapper for values with metadata
  ;; Tag = 99, structurally unique with two padding fields
  (type $WithMeta (sub $Tagged (struct
    (field $__type_id i32)
    (field $__pad1 i32)
    (field $__pad2 i32)
    (field $inner anyref)
    (field $meta anyref))))

  ;; Exception tag for WASM exception handling
  (tag $exn (param anyref))

  ;; ==========================================
  ;; Closure Types
  ;; ==========================================

  ;; Function types for closures (env as first param)
  (type $ClosureFunc0 (func (param anyref) (result anyref)))
  (type $ClosureFunc1 (func (param anyref anyref) (result anyref)))
  (type $ClosureFunc2 (func (param anyref anyref anyref) (result anyref)))
  (type $ClosureFunc3 (func (param anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc4 (func (param anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc5 (func (param anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc6 (func (param anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc7 (func (param anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc8 (func (param anyref anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc9 (func (param anyref anyref anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc10 (func (param anyref anyref anyref anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))

  ;; Closure structs for each arity (needed because funcref types are distinct)
  (type $Closure0 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc0))
    (field $env anyref))))
  (type $Closure1 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc1))
    (field $env anyref))))
  (type $Closure2 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc2))
    (field $env anyref))))
  (type $Closure3 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc3))
    (field $env anyref))))
  (type $Closure4 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc4))
    (field $env anyref))))
  (type $Closure5 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc5))
    (field $env anyref))))
  (type $Closure6 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc6))
    (field $env anyref))))
  (type $Closure7 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc7))
    (field $env anyref))))
  (type $Closure8 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc8))
    (field $env anyref))))
  (type $Closure9 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc9))
    (field $env anyref))))
  (type $Closure10 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc10))
    (field $env anyref))))

  ;; MultiClosure: dispatch function that routes to the right arity at runtime
  (type $MultiClosureDispatch (func (param anyref i32 anyref) (result anyref)))
  (type $MultiClosure (sub $Tagged (struct (field $__type_id i32) (field $env anyref) (field $dispatch (ref $MultiClosureDispatch)))))

  ;; ==========================================
  ;; List Runtime Functions
  ;; ==========================================

  ;; cons: create a new cons cell
  (func $cons (param $first anyref) (param $rest anyref) (result anyref)
    (struct.new $Cons (i32.const 6) (local.get $first) (local.get $rest)))

  ;; first: get the first element of a collection (polymorphic)
  ;; Works on: Cons, Vector, HashMap (returns first key-value pair as vector), HashSet, LazySeq
  (func $first (param $coll anyref) (result anyref)
    (local $count i32)
    (local $arr anyref)
    (local $vs (ref null $VectorSeq))
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> nil
    (if (ref.is_null (local.get $coll))
      (then (return (ref.null none))))
    ;; LazySeq - realize and recurse
    (block $not_lazy (result anyref)
      (br_on_cast_fail $not_lazy anyref (ref $LazySeq) (local.get $coll))
      (return (call $first (call $lazy_seq_realize (local.get $coll)))))
    (drop)
    ;; VectorSeq - O(1) indexed access
    (block $not_vseq (result anyref)
      (local.set $vs (br_on_cast_fail $not_vseq anyref (ref $VectorSeq) (local.get $coll)))
      (return (call $vector_nth
        (struct.get $VectorSeq $vec (local.get $vs))
        (struct.get $VectorSeq $offset (local.get $vs)))))
    (drop)
    ;; Cons cell
    (block $not_cons (result anyref)
      (return (struct.get $Cons $first
        (br_on_cast_fail $not_cons anyref (ref $Cons) (local.get $coll)))))
    (drop)
    ;; Vector
    (block $not_vec (result anyref)
      (br_on_cast_fail $not_vec anyref (ref $Vector) (local.get $coll))
      (local.set $count (call $vector_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 0))
        (then (return (ref.null none))))
      (return (call $vector_nth (local.get $coll) (i32.const 0))))
    (drop)
    ;; HashMap (tag=8)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
      (then
        (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (return (ref.null none))))
        (return (call $first (call $seq (local.get $coll))))))
    ;; HashSet (tag=9)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then
        (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (return (ref.null none))))
        (return (call $first (call $seq (local.get $coll))))))
    ;; String - return first char as 1-char string
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $coll))
      (if (i32.le_s (call $str_len (local.get $coll)) (i32.const 0))
        (then (return (ref.null none))))
      (return (call $char_at_as_str (local.get $coll) (i32.const 0))))
    (drop)
    ;; Protocol fallback: seq then first
    (if (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
      (then (return (call $first (call $__dispatch__seq (local.get $coll))))))
    (ref.null none))

  ;; rest: get the rest of a collection (polymorphic)
  ;; Works on: Cons, Vector, HashMap, HashSet, LazySeq, VectorSeq
  ;; Returns a seq for non-Cons types
  (func $rest (param $coll anyref) (result anyref)
    (local $count i32)
    (local $i i32)
    (local $arr anyref)
    (local $result anyref)
    (local $vs (ref null $VectorSeq))
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> empty list (nil)
    (if (ref.is_null (local.get $coll))
      (then (return (ref.null none))))
    ;; LazySeq - realize and recurse
    (block $not_lazy (result anyref)
      (br_on_cast_fail $not_lazy anyref (ref $LazySeq) (local.get $coll))
      (return (call $rest (call $lazy_seq_realize (local.get $coll)))))
    (drop)
    ;; VectorSeq - O(1) rest via offset increment
    (block $not_vseq (result anyref)
      (local.set $vs (br_on_cast_fail $not_vseq anyref (ref $VectorSeq) (local.get $coll)))
      (local.set $i (i32.add
        (struct.get $VectorSeq $offset (local.get $vs))
        (i32.const 1)))
      (if (result anyref) (i32.ge_s (local.get $i)
        (call $vector_count (struct.get $VectorSeq $vec (local.get $vs))))
        (then (ref.null none))
        (else (struct.new $VectorSeq (i32.const 18)
          (struct.get $VectorSeq $vec (local.get $vs))
          (local.get $i))))
      (return))
    (drop)
    ;; Cons cell
    (block $not_cons (result anyref)
      (return (struct.get $Cons $rest
        (br_on_cast_fail $not_cons anyref (ref $Cons) (local.get $coll)))))
    (drop)
    ;; Vector - return VectorSeq from index 1
    (block $not_vec (result anyref)
      (br_on_cast_fail $not_vec anyref (ref $Vector) (local.get $coll))
      (local.set $count (call $vector_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 1))
        (then (return (ref.null none))))
      (return (struct.new $VectorSeq (i32.const 18) (local.get $coll) (i32.const 1))))
    (drop)
    ;; HashMap (tag=8)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
      (then
        (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 1))
          (then (return (ref.null none))))
        (return (call $rest (call $seq (local.get $coll))))))
    ;; HashSet (tag=9)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then
        (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 1))
          (then (return (ref.null none))))
        (return (call $rest (call $seq (local.get $coll))))))
    ;; String - return rest as seq of codepoint strings
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $coll))
      (local.set $count (call $str_codepoint_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 1))
        (then (return (ref.null none))))
      ;; Build cons list of codepoint strings from end to start
      (local.set $result (ref.null none))
      (local.set $i (i32.sub (local.get $count) (i32.const 1)))
      (block $done4
        (loop $loop4
          (br_if $done4 (i32.lt_s (local.get $i) (i32.const 1)))
          (local.set $result (call $cons
            (call $char_at_as_str (local.get $coll) (local.get $i))
            (local.get $result)))
          (local.set $i (i32.sub (local.get $i) (i32.const 1)))
          (br $loop4)))
      (return (local.get $result)))
    (drop)
    ;; Protocol fallback: seq then rest
    (if (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
      (then (return (call $rest (call $__dispatch__seq (local.get $coll))))))
    (ref.null none))

  ;; nil?: check if value is nil (null reference) - returns $Boolean
  (func $nil_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $val))
      (then (global.get $__true)) (else (global.get $__false))))

  ;; cons?: check if value is a cons cell - returns $Boolean
  (func $cons_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Cons) (local.get $val))
      (then (global.get $__true)) (else (global.get $__false))))

  ;; ==========================================
  ;; List Helper Functions (for testing)
  ;; ==========================================

  ;; list-length: count elements in a seq (handles cons, lazy-seq tails)
  (func $list_length (export \"list-length\") (param $lst anyref) (result i32)
    (local $count i32)
    (local $current anyref)
    (local.set $current (local.get $lst))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $current)))
        ;; Handle lazy seq tails by realizing them
        (if (ref.test (ref $LazySeq) (local.get $current))
          (then (local.set $current (call $seq (local.get $current)))))
        (br_if $done (ref.is_null (local.get $current)))
        (if (ref.test (ref $Cons) (local.get $current))
          (then
            (local.set $count (i32.add (local.get $count) (i32.const 1)))
            (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
            (br $loop))
          (else
            ;; VectorSeq - add remaining count in O(1)
            (if (ref.test (ref $VectorSeq) (local.get $current))
              (then
                (local.set $count (i32.add (local.get $count)
                  (i32.sub
                    (call $vector_count (struct.get $VectorSeq $vec (ref.cast (ref $VectorSeq) (local.get $current))))
                    (struct.get $VectorSeq $offset (ref.cast (ref $VectorSeq) (local.get $current)))))))
              (else
                ;; Non-cons, non-lazy, non-VectorSeq, non-null - count as 1 and stop
                (local.set $count (i32.add (local.get $count) (i32.const 1)))))))))
    (local.get $count))

  ;; list-sum: sum all integers in a list (assumes i31ref elements, returns i32)
  (func $list_sum (export \"list-sum\") (param $lst anyref) (result i32)
    (local $sum i32)
    (local $current anyref)
    (local.set $current (local.get $lst))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $current)))
        (local.set $sum (i32.add (local.get $sum)
          (i31.get_s (ref.cast (ref i31) (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current)))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $loop)))
    (local.get $sum))

  ;; ==========================================
  ;; Polymorphic Operations
  ;; ==========================================

  ;; truthy: returns 1 if value is truthy, 0 if falsy
  ;; - null (nil) -> 0
  ;; - $Boolean with val=0 (false) -> 0
  ;; - $Boolean with val=1 (true) -> 1
  ;; - anything else -> 1 (integers including 0, keywords, cons cells, strings, etc.)
  (func $truthy (param $val anyref) (result i32)
    ;; Check for null first
    (if (result i32) (ref.is_null (local.get $val))
      (then (i32.const 0))
      (else
        ;; Check if it's a Boolean (tag=14)
        (if (result i32) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
          (then
            ;; It's a Boolean - return the val field (0=false, 1=true)
            (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val))))
          (else
            ;; Not null, not Boolean - everything else is truthy (including 0, keywords, etc.)
            (i32.const 1))))))

  ;; unbox_i32: convert anyref to i32 for export wrappers
  ;; Boolean -> 0/1, i31ref -> integer value, null -> 0, other -> 1
  (func $unbox_i32 (param $val anyref) (result i32)
    (if (ref.is_null (local.get $val))
      (then (return (i32.const 0))))
    ;; Boolean (tag=14)
    (if (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
      (then (return (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val))))))
    ;; i31ref (integer)
    (block $not_i31 (result anyref)
      (return (i31.get_s
        (br_on_cast_fail $not_i31 anyref (ref i31) (local.get $val)))))
    (drop)
    (i32.const 1))

  ;; unbox_f64: convert anyref to f64 for export wrappers
  ;; Float -> f64 value, i31ref -> convert to f64, other -> 0.0
  (func $unbox_f64 (param $val anyref) (result f64)
    (block $not_float (result anyref)
      (return (struct.get $Float $val
        (br_on_cast_fail $not_float anyref (ref $Float) (local.get $val)))))
    (drop)
    (block $not_i31 (result anyref)
      (return (f64.convert_i32_s (i31.get_s
        (br_on_cast_fail $not_i31 anyref (ref i31) (local.get $val))))))
    (drop)
    (f64.const 0))

  ;; is_nan: check if value is a NaN float - returns $Boolean
  ;; NaN is the only value where x != x
  (func $is_nan (param $val anyref) (result anyref)
    (local $fv (ref null $Float))
    (block $not_float (result anyref)
      (local.set $fv (br_on_cast_fail $not_float anyref (ref $Float) (local.get $val)))
      ;; It's a float - check if NaN using (x != x)
      (if (result anyref) (f64.ne
        (struct.get $Float $val (local.get $fv))
        (struct.get $Float $val (local.get $fv)))
        (then (global.get $__true))
        (else (global.get $__false)))
      (return))
    (drop)
    ;; Not a float - not NaN
    (global.get $__false))

  ;; ==========================================
  ;; Array Operations
  ;; ==========================================

  ;; array-new: create a new array of given size, filled with null
  (func $array_new (param $size i32) (result anyref)
    (array.new $AnyArray (ref.null none) (local.get $size)))

  ;; array-get: get element at index
  (func $array_get (param $arr anyref) (param $idx i32) (result anyref)
    (array.get $AnyArray (ref.cast (ref $AnyArray) (local.get $arr)) (local.get $idx)))

  ;; array-set: set element at index (mutates in place)
  (func $array_set (param $arr anyref) (param $idx i32) (param $val anyref)
    (array.set $AnyArray (ref.cast (ref $AnyArray) (local.get $arr)) (local.get $idx) (local.get $val)))

  ;; array-length: get array length
  (func $array_length (param $arr anyref) (result i32)
    (array.len (ref.cast (ref $AnyArray) (local.get $arr))))

  ;; array-copy: create a copy of array with new size (for growing)
  (func $array_copy (param $src anyref) (param $new_size i32) (result anyref)
    (local $dst anyref)
    (local $src_len i32)
    (local $copy_len i32)
    (local.set $src_len (array.len (ref.cast (ref $AnyArray) (local.get $src))))
    (local.set $copy_len (if (result i32) (i32.lt_s (local.get $src_len) (local.get $new_size))
      (then (local.get $src_len))
      (else (local.get $new_size))))
    (local.set $dst (array.new $AnyArray (ref.null none) (local.get $new_size)))
    (array.copy $AnyArray $AnyArray
      (ref.cast (ref $AnyArray) (local.get $dst)) (i32.const 0)
      (ref.cast (ref $AnyArray) (local.get $src)) (i32.const 0)
      (local.get $copy_len))
    (local.get $dst))

  ;; ==========================================
  ;; Polymorphic Hash and Equality
  ;; ==========================================

  ;; hash-int: integer hash (murmur-inspired bit mixing)
  (func $hash_int (param $n i32) (result i32)
    (local $h i32)
    (local.set $h (local.get $n))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))
    (local.set $h (i32.mul (local.get $h) (i32.const 0x85ebca6b)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 13))))
    (local.set $h (i32.mul (local.get $h) (i32.const 0xc2b2ae35)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))
    (local.get $h))

  ;; hash: polymorphic hash function
  ;; - nil -> 0
  ;; - i31ref (integer) -> hash_int
  ;; - Keyword -> keyword id (already unique)
  ;; - String -> string id
  ;; - Symbol -> symbol id
  ;; - Float -> hash of truncated value
  ;; - other -> default hash
  (func $hash (param $val anyref) (result i32)
    ;; null -> 0
    (if (ref.is_null (local.get $val))
      (then (return (i32.const 0))))
    ;; i31ref (integer/boolean)?
    (block $not_i31 (result anyref)
      (return (call $hash_int (i31.get_s
        (br_on_cast_fail $not_i31 anyref (ref i31) (local.get $val))))))
    (drop)
    ;; Keyword (tag=2)
    (if (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
      (then (return (call $hash_int (i32.add
        (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val)))
        (i32.const 0x9e3779b9))))))
    ;; String?
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $val))
      ;; Always use content-based hash for strings
      (return (call $str_hash (local.get $val))))
    (drop)
    ;; Symbol?
    (block $not_sym (result anyref)
      (br_on_cast_fail $not_sym anyref (ref $Symbol) (local.get $val))
      (return (call $sym_hash (local.get $val))))
    (drop)
    ;; Float?
    (block $not_float (result anyref)
      (br_on_cast_fail $not_float anyref (ref $Float) (local.get $val))
      ;; Reinterpret f64 bits via linear memory for proper hashing
      (f64.store (i32.const 0) (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))))
      (return (call $hash_int (i32.xor (i32.load (i32.const 0)) (i32.load (i32.const 4))))))
    (drop)
    ;; Vector (tag=7)
    (if (i32.eq (call $type_tag (local.get $val)) (i32.const 7))
      (then (return (call $hash_vector (local.get $val)))))
    ;; User-defined types
    __USER_TYPE_HASH__)

  ;; hash_vector: ordered hash-combine over vector elements
  ;; Uses Clojure's hash-ordered-coll algorithm: seed=1, h = 31*h + hash(elem)
  (func $hash_vector (param $v anyref) (result i32)
    (local $vec (ref $Vector))
    (local $cnt i32)
    (local $i i32)
    (local $h i32)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $cnt (struct.get $Vector $count (local.get $vec)))
    (local.set $h (i32.const 1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $cnt)))
        (local.set $h (i32.add
          (i32.mul (local.get $h) (i32.const 31))
          (call $hash (call $vector_nth (local.get $v) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $hash_int (local.get $h)))

  ;; eq: polymorphic equality
  ;; - both nil -> true
  ;; - both i31ref -> compare values
  ;; - both Keyword -> compare ids
  ;; - both String -> compare via $str_eq
  ;; - both Float -> compare f64 values
  ;; - different types -> false
  (func $eq (param $a anyref) (param $b anyref) (result i32)
    ;; Unwrap WithMeta on both sides (metadata doesn't affect equality)
    (local.set $a (call $unwrap_meta (local.get $a)))
    (local.set $b (call $unwrap_meta (local.get $b)))
    ;; Both null?
    (if (result i32) (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
      (then (i32.const 1))
      (else
        ;; One null, one not?
        (if (result i32) (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (i32.const 0))
          (else
            ;; Both Boolean?
            (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 14))
                                      (i32.eq (call $type_tag (local.get $b)) (i32.const 14)))
              (then (i32.eq
                      (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $a)))
                      (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $b)))))
              (else
                ;; Both i31ref?
                (if (result i32) (i32.and (ref.test (ref i31) (local.get $a))
                                          (ref.test (ref i31) (local.get $b)))
                  (then (i32.eq (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                (i31.get_s (ref.cast (ref i31) (local.get $b)))))
                  (else
                    ;; Both Keywords?
                    (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 2))
                                              (i32.eq (call $type_tag (local.get $b)) (i32.const 2)))
                      (then (i32.eq
                              (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $a)))
                              (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $b)))))
                      (else
                        ;; Both Symbols? Compare by name string + namespace
                        (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 4))
                                                  (i32.eq (call $type_tag (local.get $b)) (i32.const 4)))
                          (then (call $sym_eq (local.get $a) (local.get $b)))
                          (else
                        ;; Both Strings?
                        (if (result i32) (i32.and (ref.test (ref $String) (local.get $a))
                                                  (ref.test (ref $String) (local.get $b)))
                          (then (call $str_eq (local.get $a) (local.get $b)))
                          (else
                            ;; Both Floats?
                            (if (result i32) (i32.and (ref.test (ref $Float) (local.get $a))
                                                      (ref.test (ref $Float) (local.get $b)))
                              (then (f64.eq
                                (struct.get $Float $val (ref.cast (ref $Float) (local.get $a)))
                                (struct.get $Float $val (ref.cast (ref $Float) (local.get $b)))))
                              (else
                                ;; Both seq-like (Cons, VectorSeq, or LazySeq)?
                                (if (result i32) (i32.and
                                    (i32.or (i32.or (ref.test (ref $Cons) (local.get $a)) (ref.test (ref $VectorSeq) (local.get $a))) (ref.test (ref $LazySeq) (local.get $a)))
                                    (i32.or (i32.or (ref.test (ref $Cons) (local.get $b)) (ref.test (ref $VectorSeq) (local.get $b))) (ref.test (ref $LazySeq) (local.get $b))))
                                  (then (call $seq_eq (local.get $a) (local.get $b)))
                                  (else
                                    ;; Both Vector?
                                    (if (result i32) (i32.and (ref.test (ref $Vector) (local.get $a))
                                                              (ref.test (ref $Vector) (local.get $b)))
                                      (then (call $vector_eq (local.get $a) (local.get $b)))
                                      (else
                                        ;; Both map-like (HashMap or ArrayMap)?
                                        (if (result i32) (i32.and (i32.or (i32.eq (call $type_tag (local.get $a)) (i32.const 8)) (i32.eq (call $type_tag (local.get $a)) (i32.const 19)))
                                                                  (i32.or (i32.eq (call $type_tag (local.get $b)) (i32.const 8)) (i32.eq (call $type_tag (local.get $b)) (i32.const 19))))
                                          (then (call $hashmap_eq (local.get $a) (local.get $b)))
                                          (else
                                            ;; Both HashSet?
                                            (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 9))
                                                                      (i32.eq (call $type_tag (local.get $b)) (i32.const 9)))
                                              (then (call $hashset_eq (local.get $a) (local.get $b)))
                                              (else
                                                __USER_TYPE_EQ__)))))))))))))))))))))))))

  ;; seq_eq: general sequence equality using first/rest (handles Cons, VectorSeq, mixed)
  (func $seq_eq (param $a anyref) (param $b anyref) (result i32)
    (block $neq (result i32)
      (loop $loop (result i32)
        ;; Both nil -> equal
        (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 1))))
        ;; One nil -> not equal
        (if (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 0))))
        ;; Compare first elements
        (br_if $neq (i32.const 0) (i32.eqz (call $eq
          (call $first (local.get $a))
          (call $first (local.get $b)))))
        ;; Advance both
        (local.set $a (call $rest (local.get $a)))
        (local.set $b (call $rest (local.get $b)))
        ;; Normalize: nil means empty
        (if (ref.is_null (local.get $a))
          (then) (else (local.set $a (call $seq (local.get $a)))))
        (if (ref.is_null (local.get $b))
          (then) (else (local.set $b (call $seq (local.get $b)))))
        (br $loop))))

  ;; cons_eq: structural equality for cons lists
  (func $cons_eq (param $a anyref) (param $b anyref) (result i32)
    (local $ca (ref $Cons))
    (local $cb (ref $Cons))
    (block $neq (result i32)
      (loop $loop (result i32)
        ;; Both nil -> equal
        (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 1))))
        ;; One nil -> not equal
        (if (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 0))))
        ;; Both must be Cons
        (if (i32.eqz (i32.and (ref.test (ref $Cons) (local.get $a))
                               (ref.test (ref $Cons) (local.get $b))))
          (then (return (i32.const 0))))
        (local.set $ca (ref.cast (ref $Cons) (local.get $a)))
        (local.set $cb (ref.cast (ref $Cons) (local.get $b)))
        (br_if $neq (i32.const 0) (i32.eqz (call $eq
          (struct.get $Cons $first (local.get $ca))
          (struct.get $Cons $first (local.get $cb)))))
        (local.set $a (struct.get $Cons $rest (local.get $ca)))
        (local.set $b (struct.get $Cons $rest (local.get $cb)))
        (br $loop))))

  ;; vector_eq: structural equality for vectors
  (func $vector_eq (param $a anyref) (param $b anyref) (result i32)
    (local $count i32)
    (local $i i32)
    (local.set $count (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $a))))
    (if (result i32) (i32.ne (local.get $count) (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $b))))
      (then (i32.const 0))
      (else
        (local.set $i (i32.const 0))
        (block $neq (result i32)
          (block $done
            (loop $loop
              (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
              (br_if $neq (i32.const 0) (i32.eqz (call $eq
                (call $vector_nth (local.get $a) (local.get $i))
                (call $vector_nth (local.get $b) (local.get $i)))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $loop)))
          (i32.const 1)))))

  ;; hashmap_eq: structural equality for hash maps (HashMap or ArrayMap)
  (func $hashmap_eq (param $a anyref) (param $b anyref) (result i32)
    (local $entries anyref)
    (local $entry anyref)
    (local $key anyref)
    (local $val_a anyref)
    (local $val_b anyref)
    (if (result i32) (i32.ne
        (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $a)))
        (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $b))))
      (then (i32.const 0))
      (else
        ;; Use seq to iterate entries of A (works for both HashMap and ArrayMap)
        (local.set $entries (call $seq (local.get $a)))
        (block $neq (result i32)
          (block $done
            (loop $loop
              (br_if $done (ref.is_null (local.get $entries)))
              ;; Each entry is a [k v] vector
              (local.set $entry (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $entries))))
              (local.set $key (call $vector_nth (local.get $entry) (i32.const 0)))
              (local.set $val_a (call $vector_nth (local.get $entry) (i32.const 1)))
              (local.set $val_b (call $hash_map_get_sentinel (local.get $b) (local.get $key)))
              (br_if $neq (i32.const 0) (ref.eq (ref.cast eqref (local.get $val_b)) (global.get $__not_found_sentinel)))
              (br_if $neq (i32.const 0) (i32.eqz (call $eq (local.get $val_a) (local.get $val_b))))
              (local.set $entries (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $entries))))
              (br $loop)))
          (i32.const 1)))))

  ;; hashset_eq: structural equality for hash sets (HAMT-backed)
  (func $hashset_eq (param $a anyref) (param $b anyref) (result i32)
    (local $keys anyref)
    (local $elem anyref)
    (if (result i32) (i32.ne
        (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $a)))
        (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $b))))
      (then (i32.const 0))
      (else
        (local.set $keys (call $hamt_keys
          (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $a)))
          (ref.null none)))
        (block $neq (result i32)
          (block $done
            (loop $loop
              (br_if $done (ref.is_null (local.get $keys)))
              (local.set $elem (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $keys))))
              (br_if $neq (i32.const 0) (i32.eqz (call $truthy (call $set_contains_QMARK_ (local.get $b) (local.get $elem)))))
              (local.set $keys (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $keys))))
              (br $loop)))
          (i32.const 1)))))

  ;; popcount: count number of 1 bits (for HAMT bitmap indexing)
  (func $popcount (param $x i32) (result i32)
    (local $count i32)
    (local.set $count (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.eqz (local.get $x)))
        (local.set $count (i32.add (local.get $count) (i32.and (local.get $x) (i32.const 1))))
        (local.set $x (i32.shr_u (local.get $x) (i32.const 1)))
        (br $loop)))
    (local.get $count))

  ;; mask: get 5-bit chunk from hash at given shift level
  (func $mask (param $hash i32) (param $shift i32) (result i32)
    (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))

  ;; bitpos: get bit position for a given mask value
  (func $bitpos (param $mask i32) (result i32)
    (i32.shl (i32.const 1) (local.get $mask)))

  ;; ==========================================
  ;; Persistent Vector Operations
  ;; ==========================================

  ;; empty-vector: create an empty vector
  (func $empty_vector (result anyref)
    (struct.new $Vector (i32.const 7)
      (i32.const 0)       ;; count = 0
      (i32.const 5)       ;; shift = 5 (start at leaf level)
      (ref.null none)     ;; root = null
      (call $array_new (i32.const 0))))  ;; tail = empty array

  ;; vector-from-array: create a vector directly from an AnyArray (for count <= 32)
  (func $vector_from_array (param $arr anyref) (result anyref)
    (struct.new $Vector (i32.const 7)
      (array.len (ref.cast (ref $AnyArray) (local.get $arr)))
      (i32.const 5)
      (ref.null none)
      (local.get $arr)))

  ;; vector-count: get number of elements
  (func $vector_count (param $v anyref) (result i32)
    (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $v))))

  ;; tail-offset: calculate where the tail starts
  (func $tail_offset (param $count i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $count) (i32.const 32))
      (then (i32.const 0))
      (else
        ;; ((count - 1) >>> 5) << 5
        (i32.shl
          (i32.shr_u (i32.sub (local.get $count) (i32.const 1)) (i32.const 5))
          (i32.const 5)))))

  ;; vector-array-for: get the array containing element at index
  (func $vector_array_for (param $v anyref) (param $idx i32) (result anyref)
    (local $vec (ref $Vector))
    (local $count i32)
    (local $shift i32)
    (local $node anyref)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $count (struct.get $Vector $count (local.get $vec)))
    ;; Check if index is in tail
    (if (result anyref) (i32.ge_u (local.get $idx) (call $tail_offset (local.get $count)))
      (then (struct.get $Vector $tail (local.get $vec)))
      (else
        ;; Navigate the trie
        (local.set $node (struct.get $Vector $root (local.get $vec)))
        (local.set $shift (struct.get $Vector $shift (local.get $vec)))
        (block $done (result anyref)
          (loop $loop
            (br_if $done (local.get $node) (i32.le_s (local.get $shift) (i32.const 0)))
            (local.set $node (call $array_get
              (local.get $node)
              (i32.and (i32.shr_u (local.get $idx) (local.get $shift)) (i32.const 31))))
            (local.set $shift (i32.sub (local.get $shift) (i32.const 5)))
            (br $loop))
          (local.get $node)))))

  ;; vector-nth: get element at index
  (func $vector_nth (param $v anyref) (param $idx i32) (result anyref)
    (local $arr anyref)
    (local.set $arr (call $vector_array_for (local.get $v) (local.get $idx)))
    (call $array_get (local.get $arr) (i32.and (local.get $idx) (i32.const 31))))

  ;; new-path: create a path of single-element arrays down to a leaf
  (func $new_path (param $shift i32) (param $node anyref) (result anyref)
    (local $arr anyref)
    (if (result anyref) (i32.eqz (local.get $shift))
      (then (local.get $node))
      (else
        (local.set $arr (call $array_new (i32.const 32)))
        (call $array_set (local.get $arr) (i32.const 0)
          (call $new_path (i32.sub (local.get $shift) (i32.const 5)) (local.get $node)))
        (local.get $arr))))

  ;; push-tail: push a new tail into the trie
  (func $push_tail (param $shift i32) (param $parent anyref) (param $tail anyref) (result anyref)
    (local $sub_idx i32)
    (local $new_arr anyref)
    (local $child anyref)
    (local $parent_arr (ref $AnyArray))
    ;; Calculate index in this level
    (local.set $sub_idx (i32.and
      (i32.shr_u (i32.sub (struct.get $Vector $count (ref.cast (ref $Vector) (global.get $__push_tail_vec))) (i32.const 1))
                 (local.get $shift))
      (i32.const 31)))
    ;; Create new array for this node
    (local.set $new_arr (call $array_new (i32.const 32)))
    ;; Copy from parent if exists
    (if (i32.eqz (ref.is_null (local.get $parent)))
      (then
        (local.set $parent_arr (ref.cast (ref $AnyArray) (local.get $parent)))
        (array.copy $AnyArray $AnyArray
          (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
          (local.get $parent_arr) (i32.const 0)
          (array.len (local.get $parent_arr)))))
    ;; Insert at appropriate position
    (if (i32.eq (local.get $shift) (i32.const 5))
      (then
        ;; Leaf level - insert tail directly
        (call $array_set (local.get $new_arr) (local.get $sub_idx) (local.get $tail)))
      (else
        ;; Internal node - recurse
        (local.set $child (call $array_get (local.get $parent) (local.get $sub_idx)))
        (if (ref.is_null (local.get $child))
          (then
            ;; No child - create new path
            (call $array_set (local.get $new_arr) (local.get $sub_idx)
              (call $new_path (i32.sub (local.get $shift) (i32.const 5)) (local.get $tail))))
          (else
            ;; Has child - recurse into it
            (call $array_set (local.get $new_arr) (local.get $sub_idx)
              (call $push_tail (i32.sub (local.get $shift) (i32.const 5)) (local.get $child) (local.get $tail)))))))
    (local.get $new_arr))

  ;; Global for push_tail recursion (workaround for passing vector context)
  (global $__push_tail_vec (mut anyref) (ref.null none))

  ;; vector-conj: add element to end
  (func $vector_conj (param $v anyref) (param $val anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $count i32)
    (local $shift i32)
    (local $root anyref)
    (local $tail anyref)
    (local $new_tail anyref)
    (local $new_root anyref)
    (local $tail_len i32)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $count (struct.get $Vector $count (local.get $vec)))
    (local.set $shift (struct.get $Vector $shift (local.get $vec)))
    (local.set $root (struct.get $Vector $root (local.get $vec)))
    (local.set $tail (struct.get $Vector $tail (local.get $vec)))
    (local.set $tail_len (call $array_length (local.get $tail)))
    ;; Check if room in tail
    (if (result anyref) (i32.lt_s (local.get $tail_len) (i32.const 32))
      (then
        ;; Room in tail - create new tail with element appended
        (local.set $new_tail (call $array_new (i32.add (local.get $tail_len) (i32.const 1))))
        (if (i32.gt_s (local.get $tail_len) (i32.const 0))
          (then
            (array.copy $AnyArray $AnyArray
              (ref.cast (ref $AnyArray) (local.get $new_tail)) (i32.const 0)
              (ref.cast (ref $AnyArray) (local.get $tail)) (i32.const 0)
              (local.get $tail_len))))
        (call $array_set (local.get $new_tail) (local.get $tail_len) (local.get $val))
        (struct.new $Vector (i32.const 7)
          (i32.add (local.get $count) (i32.const 1))
          (local.get $shift)
          (local.get $root)
          (local.get $new_tail)))
      (else
        ;; Tail is full - push tail into trie, create new tail
        (local.set $new_tail (call $array_new (i32.const 1)))
        (call $array_set (local.get $new_tail) (i32.const 0) (local.get $val))
        ;; Set global for push_tail
        (global.set $__push_tail_vec (local.get $v))
        ;; Check if we need to grow the tree
        (if (result anyref) (i32.gt_u (i32.shr_u (local.get $count) (i32.const 5))
                                       (i32.shl (i32.const 1) (local.get $shift)))
          (then
            ;; Tree overflow - need new root level
            (local.set $new_root (call $array_new (i32.const 32)))
            (call $array_set (local.get $new_root) (i32.const 0) (local.get $root))
            (call $array_set (local.get $new_root) (i32.const 1)
              (call $new_path (local.get $shift) (local.get $tail)))
            (struct.new $Vector (i32.const 7)
              (i32.add (local.get $count) (i32.const 1))
              (i32.add (local.get $shift) (i32.const 5))
              (local.get $new_root)
              (local.get $new_tail)))
          (else
            ;; Push tail into existing tree
            (struct.new $Vector (i32.const 7)
              (i32.add (local.get $count) (i32.const 1))
              (local.get $shift)
              (call $push_tail (local.get $shift) (local.get $root) (local.get $tail))
              (local.get $new_tail)))))))

  ;; do-assoc: helper for assoc in trie
  (func $do_assoc (param $shift i32) (param $node anyref) (param $idx i32) (param $val anyref) (result anyref)
    (local $new_arr anyref)
    (local $sub_idx i32)
    (if (result anyref) (i32.eqz (local.get $shift))
      (then
        ;; Leaf level - clone array and update
        (local.set $new_arr (call $array_copy (local.get $node) (call $array_length (local.get $node))))
        (call $array_set (local.get $new_arr) (i32.and (local.get $idx) (i32.const 31)) (local.get $val))
        (local.get $new_arr))
      (else
        ;; Internal node - recurse
        (local.set $sub_idx (i32.and (i32.shr_u (local.get $idx) (local.get $shift)) (i32.const 31)))
        (local.set $new_arr (call $array_copy (local.get $node) (i32.const 32)))
        (call $array_set (local.get $new_arr) (local.get $sub_idx)
          (call $do_assoc
            (i32.sub (local.get $shift) (i32.const 5))
            (call $array_get (local.get $node) (local.get $sub_idx))
            (local.get $idx)
            (local.get $val)))
        (local.get $new_arr))))

  ;; vector-assoc: update element at index
  (func $vector_assoc (param $v anyref) (param $idx i32) (param $val anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $count i32)
    (local $shift i32)
    (local $tail_off i32)
    (local $new_tail anyref)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $count (struct.get $Vector $count (local.get $vec)))
    (local.set $shift (struct.get $Vector $shift (local.get $vec)))
    (local.set $tail_off (call $tail_offset (local.get $count)))
    ;; Check if index is in tail
    (if (result anyref) (i32.ge_u (local.get $idx) (local.get $tail_off))
      (then
        ;; In tail - clone tail and update
        (local.set $new_tail (call $array_copy
          (struct.get $Vector $tail (local.get $vec))
          (call $array_length (struct.get $Vector $tail (local.get $vec)))))
        (call $array_set (local.get $new_tail)
          (i32.and (local.get $idx) (i32.const 31))
          (local.get $val))
        (struct.new $Vector (i32.const 7)
          (local.get $count)
          (local.get $shift)
          (struct.get $Vector $root (local.get $vec))
          (local.get $new_tail)))
      (else
        ;; In trie - use do_assoc
        (struct.new $Vector (i32.const 7)
          (local.get $count)
          (local.get $shift)
          (call $do_assoc (local.get $shift) (struct.get $Vector $root (local.get $vec)) (local.get $idx) (local.get $val))
          (struct.get $Vector $tail (local.get $vec))))))

  ;; vector?: check if value is a vector
  (func $vector_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Vector) (local.get $val))))
"))

(defn emit-prelude-2 []
  "
  ;; ==========================================
  ;; HAMT (Hash Array Mapped Trie) Implementation
  ;; ==========================================
  ;; HashMap and HashSet backed by persistent HAMT.
  ;; O(log32 n) get/assoc/dissoc instead of O(n) linear scan.
  ;; Uses 5-bit chunks of hash at each trie level (max 7 levels).
  ;; Node types: HAMTNode (branch), HAMTEntry (leaf), HAMTCollision (hash clash).

  ;; Global flag: set to 1 by hamt_assoc when a NEW entry is added (not update)
  (global $__hamt_added (mut i32) (i32.const 0))

  ;; ---- HAMT core: get ----
  (func $hamt_get (param $node anyref) (param $key anyref) (param $hash i32) (param $shift i32) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $slot i32) (local $bit i32) (local $idx i32)
    (local $child anyref)
    (local $entry (ref $HAMTEntry))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $cnt i32)
    ;; null -> not found
    (if (ref.is_null (local.get $node)) (then (return (global.get $__not_found_sentinel))))
    ;; HAMTEntry leaf
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
          (then (return (struct.get $HAMTEntry $val (local.get $entry)))))
        (return (global.get $__not_found_sentinel))))
    ;; HAMTNode branch
    (if (result anyref) (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (if (result anyref) (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then (global.get $__not_found_sentinel))
          (else
            (local.set $idx (i32.popcnt (i32.and
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (i32.sub (local.get $bit) (i32.const 1)))))
            (local.set $child (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $idx)))
            (call $hamt_get (local.get $child) (local.get $key) (local.get $hash)
              (i32.add (local.get $shift) (i32.const 5))))))
      (else
    ;; HAMTCollision
    (if (result anyref) (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
        (local.set $i (i32.const 0))
        (block $found (result anyref)
          (block $notfound
            (loop $loop
              (br_if $notfound (i32.ge_s (local.get $i) (local.get $cnt)))
              (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                (then (br $found (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $loop)))
          (global.get $__not_found_sentinel)))
      (else (global.get $__not_found_sentinel))))))

  ;; ---- HAMT core: create node from two entries at different hashes ----
  (func $hamt_two (param $e1 anyref) (param $h1 i32) (param $e2 anyref) (param $h2 i32) (param $shift i32) (result anyref)
    (local $s1 i32) (local $s2 i32)
    (local $bit1 i32) (local $bit2 i32)
    (local $arr anyref) (local $child anyref)
    ;; Exhausted hash bits -> collision
    (if (result anyref) (i32.ge_u (local.get $shift) (i32.const 32))
      (then
        (local.set $arr (call $array_new (i32.const 4)))
        (call $array_set (local.get $arr) (i32.const 0) (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $e1))))
        (call $array_set (local.get $arr) (i32.const 1) (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $e1))))
        (call $array_set (local.get $arr) (i32.const 2) (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $e2))))
        (call $array_set (local.get $arr) (i32.const 3) (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $e2))))
        (struct.new $HAMTCollision (i32.const 0) (local.get $h1) (i32.const 2) (ref.cast (ref $AnyArray) (local.get $arr))))
      (else
        (local.set $s1 (i32.and (i32.shr_u (local.get $h1) (local.get $shift)) (i32.const 31)))
        (local.set $s2 (i32.and (i32.shr_u (local.get $h2) (local.get $shift)) (i32.const 31)))
        (if (result anyref) (i32.eq (local.get $s1) (local.get $s2))
          (then
            ;; Same slot -> recurse deeper
            (local.set $child (call $hamt_two (local.get $e1) (local.get $h1) (local.get $e2) (local.get $h2)
              (i32.add (local.get $shift) (i32.const 5))))
            (local.set $arr (call $array_new (i32.const 1)))
            (call $array_set (local.get $arr) (i32.const 0) (local.get $child))
            (struct.new $HAMTNode (i32.const 0)
              (i32.shl (i32.const 1) (local.get $s1))
              (ref.cast (ref $AnyArray) (local.get $arr))))
          (else
            ;; Different slots -> two-child node
            (local.set $bit1 (i32.shl (i32.const 1) (local.get $s1)))
            (local.set $bit2 (i32.shl (i32.const 1) (local.get $s2)))
            (local.set $arr (call $array_new (i32.const 2)))
            (if (i32.lt_u (local.get $s1) (local.get $s2))
              (then
                (call $array_set (local.get $arr) (i32.const 0) (local.get $e1))
                (call $array_set (local.get $arr) (i32.const 1) (local.get $e2)))
              (else
                (call $array_set (local.get $arr) (i32.const 0) (local.get $e2))
                (call $array_set (local.get $arr) (i32.const 1) (local.get $e1))))
            (struct.new $HAMTNode (i32.const 0)
              (i32.or (local.get $bit1) (local.get $bit2))
              (ref.cast (ref $AnyArray) (local.get $arr))))))))

  ;; ---- HAMT core: assoc ----
  (func $hamt_assoc (param $node anyref) (param $key anyref) (param $val anyref) (param $hash i32) (param $shift i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $i i32) (local $cnt i32) (local $found_idx i32)
    ;; null -> new entry
    (if (ref.is_null (local.get $node))
      (then
        (global.set $__hamt_added (i32.const 1))
        (return (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val)))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (i32.eq (struct.get $HAMTEntry $hash (local.get $entry)) (local.get $hash))
          (then
            (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
              (then
                ;; Same key -> update value
                (return (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val))))
              (else
                ;; Hash collision -> collision node
                (global.set $__hamt_added (i32.const 1))
                (local.set $new_arr (call $array_new (i32.const 4)))
                (call $array_set (local.get $new_arr) (i32.const 0) (struct.get $HAMTEntry $key (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 1) (struct.get $HAMTEntry $val (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 2) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.const 3) (local.get $val))
                (return (struct.new $HAMTCollision (i32.const 0) (local.get $hash) (i32.const 2) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
          (else
            ;; Different hash -> split
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTEntry $hash (local.get $entry))
              (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; HAMTNode
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (local.set $idx (i32.popcnt (i32.and
          (struct.get $HAMTNode $bitmap (local.get $nd))
          (i32.sub (local.get $bit) (i32.const 1)))))
        (if (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then
            ;; Empty slot -> insert new entry
            (global.set $__hamt_added (i32.const 1))
            (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
            (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
            (local.set $new_arr (call $array_new (i32.add (local.get $len) (i32.const 1))))
            ;; Copy elements before idx
            (if (i32.gt_s (local.get $idx) (i32.const 0))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                (local.get $idx))))
            ;; Insert new entry at idx
            (call $array_set (local.get $new_arr) (local.get $idx)
              (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val)))
            ;; Copy elements after idx
            (if (i32.lt_s (local.get $idx) (local.get $len))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.add (local.get $idx) (i32.const 1))
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (local.get $idx)
                (i32.sub (local.get $len) (local.get $idx)))))
            (return (struct.new $HAMTNode (i32.const 0)
              (i32.or (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit))
              (ref.cast (ref $AnyArray) (local.get $new_arr)))))
          (else
            ;; Occupied slot -> recurse
            (local.set $child (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_assoc (local.get $child) (local.get $key) (local.get $val)
              (local.get $hash) (i32.add (local.get $shift) (i32.const 5))))
            (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
            (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
            (local.set $new_arr (call $array_copy (local.get $old_arr) (local.get $len)))
            (call $array_set (local.get $new_arr) (local.get $idx) (local.get $new_child))
            (return (struct.new $HAMTNode (i32.const 0)
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (ref.cast (ref $AnyArray) (local.get $new_arr))))))))
    ;; HAMTCollision
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (if (i32.eq (struct.get $HAMTCollision $hash (local.get $col)) (local.get $hash))
          (then
            ;; Same hash -> update or extend collision
            (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
            (local.set $found_idx (i32.const -1))
            (local.set $i (i32.const 0))
            (block $cfound
              (loop $cloop
                (br_if $cfound (i32.ge_s (local.get $i) (local.get $cnt)))
                (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                  (then (local.set $found_idx (local.get $i)) (br $cfound)))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $cloop)))
            (if (i32.ge_s (local.get $found_idx) (i32.const 0))
              (then
                ;; Update existing
                (local.set $new_arr (call $array_copy (struct.get $HAMTCollision $entries (local.get $col))
                  (i32.mul (local.get $cnt) (i32.const 2))))
                (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $found_idx) (i32.const 2)) (i32.const 1)) (local.get $val))
                (return (struct.new $HAMTCollision (i32.const 0) (local.get $hash) (local.get $cnt) (ref.cast (ref $AnyArray) (local.get $new_arr)))))
              (else
                ;; Add new to collision
                (global.set $__hamt_added (i32.const 1))
                (local.set $new_arr (call $array_new (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (if (i32.gt_s (local.get $cnt) (i32.const 0))
                  (then (array.copy $AnyArray $AnyArray
                    (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                    (ref.cast (ref $AnyArray) (struct.get $HAMTCollision $entries (local.get $col))) (i32.const 0)
                    (i32.mul (local.get $cnt) (i32.const 2)))))
                (call $array_set (local.get $new_arr) (i32.mul (local.get $cnt) (i32.const 2)) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 1)) (local.get $val))
                (return (struct.new $HAMTCollision (i32.const 0) (local.get $hash) (i32.add (local.get $cnt) (i32.const 1)) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
          (else
            ;; Different hash -> wrap collision in node
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTCollision $hash (local.get $col))
              (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; Fallback (shouldn't reach)
    (local.get $node))

  ;; ---- HAMT core: dissoc ----
  (func $hamt_dissoc (param $node anyref) (param $key anyref) (param $hash i32) (param $shift i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $new_bm i32) (local $i i32) (local $j i32) (local $cnt i32)
    ;; null -> unchanged
    (if (ref.is_null (local.get $node)) (then (return (ref.null none))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
          (then (return (ref.null none))))
        (return (local.get $node))))
    ;; HAMTNode
    (if (result anyref) (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (if (result anyref) (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then (local.get $node))  ;; not found
          (else
            (local.set $idx (i32.popcnt (i32.and
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (i32.sub (local.get $bit) (i32.const 1)))))
            (local.set $child (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_dissoc (local.get $child) (local.get $key) (local.get $hash)
              (i32.add (local.get $shift) (i32.const 5))))
            (if (result anyref) (ref.is_null (local.get $new_child))
              (then
                ;; Child removed entirely -> shrink array
                (local.set $new_bm (i32.and (struct.get $HAMTNode $bitmap (local.get $nd))
                  (i32.xor (local.get $bit) (i32.const -1))))
                (if (result anyref) (i32.eqz (local.get $new_bm))
                  (then (ref.null none))  ;; node now empty
                  (else
                    (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
                    (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
                    ;; If only one child remains and it's a HAMTEntry, promote it
                    ;; NOTE: must use nested ifs (not i32.and) for short-circuit evaluation,
                    ;; otherwise array_get(old_arr, 1-idx) is evaluated even when len != 2
                    (block $after_promote (result anyref)
                      (if (i32.eq (local.get $len) (i32.const 2))
                        (then
                          (if (ref.test (ref $HAMTEntry) (call $array_get (local.get $old_arr)
                              (i32.sub (i32.const 1) (local.get $idx))))
                            (then
                              (br $after_promote (call $array_get (local.get $old_arr) (i32.sub (i32.const 1) (local.get $idx))))))))
                      ;; Fall through: shrink array (remove child at idx)
                      (local.set $new_arr (call $array_new (i32.sub (local.get $len) (i32.const 1))))
                      (if (i32.gt_s (local.get $idx) (i32.const 0))
                        (then (array.copy $AnyArray $AnyArray
                          (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                          (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                          (local.get $idx))))
                      (if (i32.lt_s (i32.add (local.get $idx) (i32.const 1)) (local.get $len))
                        (then (array.copy $AnyArray $AnyArray
                          (ref.cast (ref $AnyArray) (local.get $new_arr)) (local.get $idx)
                          (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.add (local.get $idx) (i32.const 1))
                          (i32.sub (i32.sub (local.get $len) (local.get $idx)) (i32.const 1)))))
                      (struct.new $HAMTNode (i32.const 0) (local.get $new_bm) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
              (else
                ;; Child changed -> replace
                (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
                (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
                (local.set $new_arr (call $array_copy (local.get $old_arr) (local.get $len)))
                (call $array_set (local.get $new_arr) (local.get $idx) (local.get $new_child))
                (struct.new $HAMTNode (i32.const 0) (struct.get $HAMTNode $bitmap (local.get $nd))
                  (ref.cast (ref $AnyArray) (local.get $new_arr))))))))
      (else
    ;; HAMTCollision
    (if (result anyref) (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
        ;; Find key in collision entries
        (local.set $i (i32.const -1))
        (local.set $j (i32.const 0))
        (block $cfound
          (loop $cloop
            (br_if $cfound (i32.ge_s (local.get $j) (local.get $cnt)))
            (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2))))
              (then (local.set $i (local.get $j)) (br $cfound)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $cloop)))
        (if (result anyref) (i32.lt_s (local.get $i) (i32.const 0))
          (then (local.get $node))  ;; not found
          (else
            (if (result anyref) (i32.eq (local.get $cnt) (i32.const 2))
              (then
                ;; Down to 1 entry -> promote to HAMTEntry
                (local.set $j (i32.sub (i32.const 1) (local.get $i)))
                (struct.new $HAMTEntry (i32.const 0)
                  (struct.get $HAMTCollision $hash (local.get $col))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2)))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1)))))
              (else
                ;; Remove entry from collision
                (local.set $new_arr (call $array_new (i32.mul (i32.sub (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (local.set $j (i32.const 0))
                (local.set $slot (i32.const 0))
                (block $cdone
                  (loop $ccopy
                    (br_if $cdone (i32.ge_s (local.get $j) (local.get $cnt)))
                    (if (i32.ne (local.get $j) (local.get $i))
                      (then
                        (call $array_set (local.get $new_arr) (i32.mul (local.get $slot) (i32.const 2))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2))))
                        (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $slot) (i32.const 2)) (i32.const 1))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1))))
                        (local.set $slot (i32.add (local.get $slot) (i32.const 1)))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $ccopy)))
                (struct.new $HAMTCollision (i32.const 0)
                  (struct.get $HAMTCollision $hash (local.get $col))
                  (i32.sub (local.get $cnt) (i32.const 1))
                  (ref.cast (ref $AnyArray) (local.get $new_arr))))))))
      (else (local.get $node))))))

  ;; ---- HAMT core: fold for keys ----
  (func $hamt_keys (param $node anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $cons (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node))) (local.get $acc)))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.sub (struct.get $HAMTCollision $count (local.get $col)) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $cons
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2)))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.sub (local.get $len) (i32.const 1)))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $hamt_keys
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: fold for vals ----
  (func $hamt_vals (param $node anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $cons (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node))) (local.get $acc)))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.sub (struct.get $HAMTCollision $count (local.get $col)) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $cons
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.sub (local.get $len) (i32.const 1)))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $hamt_vals
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: reduce-kv (f acc key val) ----
  (func $hamt_reduce (param $node anyref) (param $f anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (call $reduced_QMARK_ (local.get $acc)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $invoke3 (local.get $f) (local.get $acc)
        (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node)))
        (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node)))))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_s (local.get $i) (struct.get $HAMTCollision $count (local.get $col))))
            (br_if $done (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $invoke3 (local.get $f) (local.get $acc)
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2)))
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.const 0))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.ge_s (local.get $i) (local.get $len)))
            (br_if $done2 (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $hamt_reduce
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $f) (local.get $acc)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: fold for map entries as [key val] vectors ----
  (func $hamt_entries (param $node anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $cons
        (call $vector_conj (call $vector_conj (call $empty_vector)
          (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node))))
          (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node))))
        (local.get $acc)))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.sub (struct.get $HAMTCollision $count (local.get $col)) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $cons
              (call $vector_conj (call $vector_conj (call $empty_vector)
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.sub (local.get $len) (i32.const 1)))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $hamt_entries
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: reduce over entries as [k v] vectors: f(acc, [k v]) ----
  (func $hamt_reduce_entries (param $node anyref) (param $f anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (call $reduced_QMARK_ (local.get $acc)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $invoke2 (local.get $f) (local.get $acc)
        (call $vector_conj (call $vector_conj (call $empty_vector)
          (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node))))
          (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node))))))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_s (local.get $i) (struct.get $HAMTCollision $count (local.get $col))))
            (br_if $done (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
              (call $vector_conj (call $vector_conj (call $empty_vector)
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.const 0))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.ge_s (local.get $i) (local.get $len)))
            (br_if $done2 (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $hamt_reduce_entries
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $f) (local.get $acc)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: reduce over keys only: f(acc, key) ----
  (func $hamt_reduce_keys (param $node anyref) (param $f anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (call $reduced_QMARK_ (local.get $acc)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $invoke2 (local.get $f) (local.get $acc)
        (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node)))))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_s (local.get $i) (struct.get $HAMTCollision $count (local.get $col))))
            (br_if $done (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.const 0))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.ge_s (local.get $i) (local.get $len)))
            (br_if $done2 (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $hamt_reduce_keys
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $f) (local.get $acc)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))
")

(defn emit-prelude-2a []
  "
  ;; ==========================================
  ;; Persistent HashMap Operations (HAMT-backed)
  ;; ==========================================

  (func $empty_hash_map (result anyref)
    ;; Returns an ArrayMap (tag 19) — promotes to HAMT HashMap at 9+ entries
    (struct.new $HashMap (i32.const 19) (i32.const 0) (ref.null none)))

  (func $hash_map_count (param $m anyref) (result i32)
    (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))))

  (func $hash_map_get (param $m anyref) (param $key anyref) (result anyref)
    (local $result anyref)
    (local $root anyref)
    (local $tag i32)
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        (local.set $tag (call $type_tag (local.get $m)))
        ;; ArrayMap (tag 19) — flat array linear scan
        (if (result anyref) (i32.eq (local.get $tag) (i32.const 19))
          (then (call $array_map_get
            (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m)))
            (local.get $key)
            (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m)))))
          (else
        (if (result anyref) (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 16)))
          (then
            ;; HashMap or TransientHashMap - use HAMT lookup
            (if (i32.eq (local.get $tag) (i32.const 16))
              (then (local.set $root (struct.get $TransientHashMap $array (ref.cast (ref $TransientHashMap) (local.get $m)))))
              (else (local.set $root (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))))))
            (local.set $result (call $hamt_get (local.get $root)
              (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
            (if (result anyref) (ref.eq (ref.cast eqref (local.get $result)) (global.get $__not_found_sentinel))
              (then (ref.null none))
              (else (local.get $result))))
          (else
            ;; Protocol fallback for user types implementing ILookup
            (if (result anyref) (call $truthy (call $__satisfies_ILookup (local.get $m)))
              (then (call $__dispatch__lookup (local.get $m) (local.get $key)))
              (else (ref.null none))))))))))

  (func $hash_map_assoc (param $m anyref) (param $key anyref) (param $val anyref) (result anyref)
    ;; Dispatch: ArrayMap (tag 19) uses flat array, HashMap (tag 8) uses HAMT
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    ;; nil -> create 1-entry ArrayMap
    (if (ref.is_null (local.get $m))
      (then (return (call $array_map_assoc
        (ref.cast (ref $HashMap) (call $empty_hash_map))
        (local.get $key) (local.get $val)))))
    ;; ArrayMap (tag 19)
    (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
      (then (return (call $array_map_assoc (ref.cast (ref $HashMap) (local.get $m)) (local.get $key) (local.get $val)))))
    ;; HAMT HashMap (tag 8)
    (call $hash_map_assoc_hamt (local.get $m) (local.get $key) (local.get $val)))

  ;; hash_map_assoc_hamt: assoc on HAMT-backed HashMap only (tag 8)
  (func $hash_map_assoc_hamt (param $m anyref) (param $key anyref) (param $val anyref) (result anyref)
    (local $map (ref $HashMap))
    (local $root anyref) (local $new_root anyref)
    (local $h i32)
    (if (ref.is_null (local.get $m))
      (then
        (local.set $h (call $hash (local.get $key)))
        (return (struct.new $HashMap (i32.const 8) (i32.const 1)
          (struct.new $HAMTEntry (i32.const 0) (local.get $h) (local.get $key) (local.get $val))))))
    (local.set $map (ref.cast (ref $HashMap) (local.get $m)))
    (local.set $root (struct.get $HashMap $array (local.get $map)))
    (local.set $h (call $hash (local.get $key)))
    (global.set $__hamt_added (i32.const 0))
    (local.set $new_root (call $hamt_assoc (local.get $root) (local.get $key) (local.get $val) (local.get $h) (i32.const 0)))
    (struct.new $HashMap (i32.const 8)
      (i32.add (struct.get $HashMap $count (local.get $map)) (global.get $__hamt_added))
      (local.get $new_root)))

  (func $hash_map_get_sentinel (param $m anyref) (param $key anyref) (result anyref)
    (local $root anyref)
    (local $tag i32)
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    (if (result anyref) (ref.is_null (local.get $m))
      (then (global.get $__not_found_sentinel))
      (else
        (local.set $tag (call $type_tag (local.get $m)))
        ;; ArrayMap (tag 19) — flat array linear scan
        (if (result anyref) (i32.eq (local.get $tag) (i32.const 19))
          (then (call $array_map_get_sentinel
            (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m)))
            (local.get $key)
            (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m)))))
          (else
        ;; Get root: HashMap or TransientHashMap
        (if (i32.eq (local.get $tag) (i32.const 16))
          (then (local.set $root (struct.get $TransientHashMap $array (ref.cast (ref $TransientHashMap) (local.get $m)))))
          (else (local.set $root (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))))))
        (call $hamt_get (local.get $root)
          (local.get $key) (call $hash (local.get $key)) (i32.const 0)))))))

  (func $hash_map_get_default (param $m anyref) (param $key anyref) (param $default anyref) (result anyref)
    (local $result anyref)
    (local.set $result (call $hash_map_get_sentinel (local.get $m) (local.get $key)))
    (if (result anyref) (ref.eq (ref.cast eqref (local.get $result)) (global.get $__not_found_sentinel))
      (then (local.get $default))
      (else (local.get $result))))

  (func $hash_map_contains_QMARK_ (param $m anyref) (param $key anyref) (result anyref)
    (if (result anyref) (ref.eq (ref.cast eqref (call $hash_map_get_sentinel (local.get $m) (local.get $key))) (global.get $__not_found_sentinel))
      (then (global.get $__false))
      (else (global.get $__true))))

  (func $map_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.eq (call $type_tag (local.get $val)) (i32.const 8))
                                (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
                        __USER_MAP__)))

  (func $keys (param $m anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        ;; ArrayMap — convert to HashMap first
        (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
          (then (return (call $keys (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $m)))))))
        (if (result anyref) (i32.le_s (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))) (i32.const 0))
          (then (ref.null none))
          (else (call $hamt_keys (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))) (ref.null none)))))))

  (func $vals (param $m anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        ;; ArrayMap — convert to HashMap first
        (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
          (then (return (call $vals (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $m)))))))
        (if (result anyref) (i32.le_s (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))) (i32.const 0))
          (then (ref.null none))
          (else (call $hamt_vals (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))) (ref.null none)))))))

  ;; ==========================================
  ;; Persistent HashSet Operations (HAMT-backed)
  ;; ==========================================

  (func $empty_hash_set (result anyref)
    (struct.new $HashSet (i32.const 9) (i32.const 0) (ref.null none)))

  (func $set_conj (param $s anyref) (param $elem anyref) (result anyref)
    (local $set (ref $HashSet))
    (local $root anyref) (local $new_root anyref)
    (local $h i32)
    (if (ref.is_null (local.get $s))
      (then
        (local.set $h (call $hash (local.get $elem)))
        (return (struct.new $HashSet (i32.const 9) (i32.const 1)
          (struct.new $HAMTEntry (i32.const 0) (local.get $h) (local.get $elem) (local.get $elem))))))
    (local.set $set (ref.cast (ref $HashSet) (local.get $s)))
    (local.set $root (struct.get $HashSet $array (local.get $set)))
    (local.set $h (call $hash (local.get $elem)))
    (global.set $__hamt_added (i32.const 0))
    (local.set $new_root (call $hamt_assoc (local.get $root) (local.get $elem) (local.get $elem) (local.get $h) (i32.const 0)))
    (if (result anyref) (i32.eqz (global.get $__hamt_added))
      (then (local.get $s))  ;; already present, return unchanged
      (else (struct.new $HashSet (i32.const 9)
        (i32.add (struct.get $HashSet $count (local.get $set)) (i32.const 1))
        (local.get $new_root)))))

  (func $disj (param $s anyref) (param $elem anyref) (result anyref)
    (local $set (ref $HashSet))
    (local $root anyref) (local $new_root anyref) (local $h i32)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (ref.null none))
      (else
        (local.set $set (ref.cast (ref $HashSet) (local.get $s)))
        (local.set $root (struct.get $HashSet $array (local.get $set)))
        (local.set $h (call $hash (local.get $elem)))
        ;; Check if element exists first
        (if (result anyref) (ref.eq (ref.cast eqref (call $hamt_get (local.get $root) (local.get $elem) (local.get $h) (i32.const 0))) (global.get $__not_found_sentinel))
          (then (local.get $s))  ;; not found, return unchanged
          (else
            (local.set $new_root (call $hamt_dissoc (local.get $root) (local.get $elem) (local.get $h) (i32.const 0)))
            (struct.new $HashSet (i32.const 9)
              (i32.sub (struct.get $HashSet $count (local.get $set)) (i32.const 1))
              (local.get $new_root)))))))

  (func $set_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 9))))

  (func $set_contains_QMARK_ (param $s anyref) (param $elem anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (global.get $__false))
      (else
        (if (result anyref) (ref.eq (ref.cast eqref
            (call $hamt_get (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $s)))
              (local.get $elem) (call $hash (local.get $elem)) (i32.const 0)))
            (global.get $__not_found_sentinel))
          (then (global.get $__false))
          (else (global.get $__true))))))

  ;; ==========================================
  ;; Sequence Operations
  ;; ==========================================

  ;; seq: returns nil if empty, otherwise returns a seq representation
  ;; For lists (cons cells): return the list itself
  ;; For vectors: return a cons-based sequence
  ;; For maps: return key-value pairs as cons list
  ;; For sets: return elements as cons list
  ;; For lazy seqs: realize and recurse
  (func $seq (param $coll anyref) (result anyref)
    (local $i i32)
    (local $count i32)
    (local $arr anyref)
    (local $result anyref)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> nil
    (if (ref.is_null (local.get $coll))
      (then (return (ref.null none))))
    ;; LazySeq - realize and recurse
    (block $not_lazy (result anyref)
      (br_on_cast_fail $not_lazy anyref (ref $LazySeq) (local.get $coll))
      (return (call $seq (call $lazy_seq_realize (local.get $coll)))))
    (drop)
    ;; Cons cell - return as-is
    (block $not_cons (result anyref)
      (br_on_cast_fail $not_cons anyref (ref $Cons) (local.get $coll))
      (return (local.get $coll)))
    (drop)
    ;; VectorSeq - return as-is (already a seq)
    (block $not_vseq (result anyref)
      (br_on_cast_fail $not_vseq anyref (ref $VectorSeq) (local.get $coll))
      (return (local.get $coll)))
    (drop)
    ;; Vector - return VectorSeq (lazy O(1) view)
    (block $not_vec (result anyref)
      (br_on_cast_fail $not_vec anyref (ref $Vector) (local.get $coll))
      (local.set $count (call $vector_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 0))
        (then (return (ref.null none))))
      (return (struct.new $VectorSeq (i32.const 18) (local.get $coll) (i32.const 0))))
    (drop)
    ;; HashMap/ArrayMap (tag=8/19)
    (if (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
                (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
      (then
        (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (return (ref.null none))))
        ;; ArrayMap (tag 19) — produce seq from flat array
        (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
          (then (return (call $array_map_seq (ref.cast (ref $HashMap) (local.get $coll))))))
        ;; HAMT HashMap (tag 8)
        (return (call $hamt_entries
          (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll)))
          (ref.null none)))))
    ;; HashSet (tag=9)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then
        (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (return (ref.null none))))
        (return (call $hamt_keys
          (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll)))
          (ref.null none)))))
    ;; String - convert to cons list of codepoint strings
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $coll))
      (local.set $count (call $str_codepoint_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 0))
        (then (return (ref.null none))))
      (local.set $result (ref.null none))
      (local.set $i (i32.sub (local.get $count) (i32.const 1)))
      (block $done3
        (loop $loop3
          (br_if $done3 (i32.lt_s (local.get $i) (i32.const 0)))
          (local.set $result (call $cons
            (call $char_at_as_str (local.get $coll) (local.get $i))
            (local.get $result)))
          (local.set $i (i32.sub (local.get $i) (i32.const 1)))
          (br $loop3)))
      (return (local.get $result)))
    (drop)
    ;; Protocol fallback for user types implementing ISeqable
    (if (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
      (then (return (call $__dispatch__seq (local.get $coll)))))
    (ref.null none))

    ;; seq?: check if value is a seq (cons cell), lazy seq, or VectorSeq
  (func $seq_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $LazySeq) (local.get $val)))
      (ref.test (ref $VectorSeq) (local.get $val)))))

  ;; seqable?: check if value can be converted to a seq
  (func $seqable_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or
      (ref.is_null (local.get $val))
      (ref.test (ref $Cons) (local.get $val)))
      (ref.test (ref $Vector) (local.get $val)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 9)))
      (ref.test (ref $LazySeq) (local.get $val)))
      (ref.test (ref $String) (local.get $val)))
      (ref.test (ref $VectorSeq) (local.get $val)))
      (call $truthy (call $__satisfies_ISeqable (local.get $val))))))

  ;; empty?: check if collection is empty
  (func $empty_QMARK_ (param $coll anyref) (result anyref)
    (call $bool
      (if (result i32) (ref.is_null (local.get $coll))
        (then (i32.const 1))
        (else
          (if (result i32) (ref.test (ref $Cons) (local.get $coll))
            (then (i32.const 0))  ;; cons cells are never empty
            (else
              (if (result i32) (ref.test (ref $VectorSeq) (local.get $coll))
                (then (i32.const 0))  ;; VectorSeqs are never empty (only created from non-empty vectors)
                (else
              (if (result i32) (ref.test (ref $Vector) (local.get $coll))
                (then (i32.eqz (call $vector_count (local.get $coll))))
                (else
                  (if (result i32) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
                    (then (i32.eqz (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll)))))
                    (else
                      (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
                        (then (i32.eqz (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll)))))
                        (else
                          (if (result i32) (ref.test (ref $String) (local.get $coll))
                            (then (i32.eqz (call $str_len (local.get $coll))))
                            (else
                              ;; LazySeq? Realize it and check if nil
                              (if (result i32) (ref.test (ref $LazySeq) (local.get $coll))
                                (then (ref.is_null (call $seq (local.get $coll))))
                                (else
                                  ;; Protocol fallback: empty if ISeqable returns nil seq
                                  (if (result i32) (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
                                    (then (ref.is_null (call $__dispatch__seq (local.get $coll))))
                                    (else (i32.const 1)))))))))))))))))))))

  ;; dissoc: remove key from hash map
  (func $dissoc (param $m anyref) (param $key anyref) (result anyref)
    (local $h i32)
    (local $root anyref)
    (local $count i32)
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        ;; ArrayMap — convert to HashMap first, then dissoc
        (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
          (then (return (call $dissoc (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $m))) (local.get $key)))))
        ;; Check if key exists using sentinel
        (if (result anyref) (ref.eq
            (ref.cast eqref (call $hash_map_get_sentinel (local.get $m) (local.get $key)))
            (global.get $__not_found_sentinel))
          (then (local.get $m))  ;; Key not found - return unchanged
          (else
            (local.set $root (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))))
            (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))))
            (local.set $h (call $hash (local.get $key)))
            (struct.new $HashMap (i32.const 8)
              (i32.sub (local.get $count) (i32.const 1))
              (call $hamt_dissoc (local.get $root) (local.get $key) (local.get $h) (i32.const 0))))))))


  ;; ==========================================
  ;; ArrayMap (PersistentArrayMap) — flat array for small maps (≤8 entries)
  ;; Uses $HashMap struct with type_id=19 and $array holding flat [k0,v0,k1,v1,...]
  ;; Promotes to HAMT HashMap (tag 8) when exceeding 8 entries.
  ;; ==========================================

  ;; empty_hash_map_hamt: create an empty HAMT-backed HashMap (tag 8)
  (func $empty_hash_map_hamt (result anyref)
    (struct.new $HashMap (i32.const 8) (i32.const 0) (ref.null none)))

  ;; array_map_get: linear scan of flat [k,v,k,v,...] array for key
  (func $array_map_get (param $arr anyref) (param $key anyref) (param $count i32) (result anyref)
    (local $i i32)
    (local $len i32)
    (local $typed_arr (ref $AnyArray))
    (if (ref.is_null (local.get $arr))
      (then (return (ref.null none))))
    (local.set $typed_arr (ref.cast (ref $AnyArray) (local.get $arr)))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (call $eq (array.get $AnyArray (local.get $typed_arr) (local.get $i)) (local.get $key))
          (then (return (array.get $AnyArray (local.get $typed_arr) (i32.add (local.get $i) (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (ref.null none))

  ;; array_map_get_sentinel: like array_map_get but returns sentinel instead of nil for not-found
  (func $array_map_get_sentinel (param $arr anyref) (param $key anyref) (param $count i32) (result anyref)
    (local $i i32)
    (local $len i32)
    (local $typed_arr (ref $AnyArray))
    (if (ref.is_null (local.get $arr))
      (then (return (global.get $__not_found_sentinel))))
    (local.set $typed_arr (ref.cast (ref $AnyArray) (local.get $arr)))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (call $eq (array.get $AnyArray (local.get $typed_arr) (local.get $i)) (local.get $key))
          (then (return (array.get $AnyArray (local.get $typed_arr) (i32.add (local.get $i) (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (global.get $__not_found_sentinel))

  ;; array_map_assoc: assoc on ArrayMap — copy+replace or copy+extend, promote to HashMap at 9+
  (func $array_map_assoc (param $m (ref $HashMap)) (param $key anyref) (param $val anyref) (result anyref)
    (local $arr anyref) (local $typed_arr (ref $AnyArray))
    (local $count i32) (local $len i32) (local $i i32)
    (local $new_arr (ref $AnyArray)) (local $new_len i32)
    (local.set $arr (struct.get $HashMap $array (local.get $m)))
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    ;; Empty ArrayMap: create 1-entry ArrayMap
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then
        (local.set $new_arr (array.new $AnyArray (ref.null none) (i32.const 2)))
        (array.set $AnyArray (local.get $new_arr) (i32.const 0) (local.get $key))
        (array.set $AnyArray (local.get $new_arr) (i32.const 1) (local.get $val))
        (return (struct.new $HashMap (i32.const 19) (i32.const 1) (local.get $new_arr)))))
    (local.set $typed_arr (ref.cast (ref $AnyArray) (local.get $arr)))
    ;; Check if key already exists (linear scan)
    (local.set $i (i32.const 0))
    (block $not_found
      (loop $scan
        (br_if $not_found (i32.ge_s (local.get $i) (local.get $len)))
        (if (call $eq (array.get $AnyArray (local.get $typed_arr) (local.get $i)) (local.get $key))
          (then
            ;; Key found at $i — copy array and replace value at $i+1
            (local.set $new_arr (array.new $AnyArray (ref.null none) (local.get $len)))
            (array.copy $AnyArray $AnyArray (local.get $new_arr) (i32.const 0) (local.get $typed_arr) (i32.const 0) (local.get $len))
            (array.set $AnyArray (local.get $new_arr) (i32.add (local.get $i) (i32.const 1)) (local.get $val))
            (return (struct.new $HashMap (i32.const 19) (local.get $count) (local.get $new_arr)))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $scan)))
    ;; Key not found — promote to HashMap if count >= 8
    (if (i32.ge_s (local.get $count) (i32.const 8))
      (then (return (call $hash_map_assoc_hamt (call $array_map_to_hash_map (local.get $m)) (local.get $key) (local.get $val)))))
    ;; Extend: copy array + append k,v
    (local.set $new_len (i32.add (local.get $len) (i32.const 2)))
    (local.set $new_arr (array.new $AnyArray (ref.null none) (local.get $new_len)))
    (array.copy $AnyArray $AnyArray (local.get $new_arr) (i32.const 0) (local.get $typed_arr) (i32.const 0) (local.get $len))
    (array.set $AnyArray (local.get $new_arr) (local.get $len) (local.get $key))
    (array.set $AnyArray (local.get $new_arr) (i32.add (local.get $len) (i32.const 1)) (local.get $val))
    (struct.new $HashMap (i32.const 19) (i32.add (local.get $count) (i32.const 1)) (local.get $new_arr)))

  ;; array_map_to_hash_map: convert ArrayMap to HAMT HashMap (tag 8)
  (func $array_map_to_hash_map (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $result anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (call $empty_hash_map_hamt))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $result (call $empty_hash_map_hamt))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $result (call $hash_map_assoc_hamt (local.get $result)
          (array.get $AnyArray (local.get $arr) (local.get $i))
          (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $result))

  ;; array_map_seq: produce Cons list of [k,v] vectors from flat array
  (func $array_map_seq (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $result anyref) (local $entry anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (ref.null none))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $result (ref.null none))
    ;; Build cons list from back to front (so seq is in insertion order)
    (local.set $i (i32.sub (local.get $len) (i32.const 2)))
    (block $done
      (loop $loop
        (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
        ;; Create [k v] vector via conj (2-element vector)
        (local.set $entry (call $vector_conj (call $vector_conj (call $empty_vector)
          (array.get $AnyArray (local.get $arr) (local.get $i)))
          (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1)))))
        (local.set $result (call $cons (local.get $entry) (local.get $result)))
        (local.set $i (i32.sub (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $result))

  ;; array_map_reduce_kv: reduce over ArrayMap key-value pairs
  (func $array_map_reduce_kv (param $f anyref) (param $init anyref) (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $acc anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (local.get $init))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $acc (call $invoke3 (local.get $f) (local.get $acc)
          (array.get $AnyArray (local.get $arr) (local.get $i))
          (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1)))))
        ;; Check for reduced
        (if (ref.test (ref $Reduced) (local.get $acc))
          (then (return (local.get $acc))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $acc))

  ;; array_map_reduce_entries: reduce over ArrayMap entries as [k,v] vectors (for reduce on maps)
  (func $array_map_reduce_entries (param $f anyref) (param $init anyref) (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $acc anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (local.get $init))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (call $vector_conj (call $vector_conj (call $empty_vector)
            (array.get $AnyArray (local.get $arr) (local.get $i)))
            (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1))))))
        (if (ref.test (ref $Reduced) (local.get $acc))
          (then (return (local.get $acc))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $acc))

")

(defn emit-prelude-transient []
  "
  ;; ==========================================
  ;; Transient Collections
  ;; ==========================================

  ;; Global monotonic edit counter — each transient call increments this
  (global $__edit_counter (mut i32) (i32.const 1))

  ;; ---- HAMT transient helpers: ensure node ownership ----

  ;; If node.edit == edit, return node (owned); else clone with new edit
  (func $hamt_node_ensure_editable (param $node (ref $HAMTNode)) (param $edit i32) (result (ref $HAMTNode))
    (if (result (ref $HAMTNode)) (i32.eq (struct.get $HAMTNode $edit (local.get $node)) (local.get $edit))
      (then (local.get $node))
      (else
        (struct.new $HAMTNode (local.get $edit)
          (struct.get $HAMTNode $bitmap (local.get $node))
          (ref.cast (ref $AnyArray) (call $array_copy
            (struct.get $HAMTNode $children (local.get $node))
            (array.len (struct.get $HAMTNode $children (local.get $node)))))))))

  (func $hamt_entry_ensure_editable (param $entry (ref $HAMTEntry)) (param $edit i32) (result (ref $HAMTEntry))
    (if (result (ref $HAMTEntry)) (i32.eq (struct.get $HAMTEntry $edit (local.get $entry)) (local.get $edit))
      (then (local.get $entry))
      (else
        (struct.new $HAMTEntry (local.get $edit)
          (struct.get $HAMTEntry $hash (local.get $entry))
          (struct.get $HAMTEntry $key (local.get $entry))
          (struct.get $HAMTEntry $val (local.get $entry))))))

  (func $hamt_collision_ensure_editable (param $col (ref $HAMTCollision)) (param $edit i32) (result (ref $HAMTCollision))
    (if (result (ref $HAMTCollision)) (i32.eq (struct.get $HAMTCollision $edit (local.get $col)) (local.get $edit))
      (then (local.get $col))
      (else
        (struct.new $HAMTCollision (local.get $edit)
          (struct.get $HAMTCollision $hash (local.get $col))
          (struct.get $HAMTCollision $count (local.get $col))
          (ref.cast (ref $AnyArray) (call $array_copy
            (struct.get $HAMTCollision $entries (local.get $col))
            (array.len (struct.get $HAMTCollision $entries (local.get $col)))))))))

  ;; ---- hamt_assoc_transient: in-place HAMT mutation ----
  (func $hamt_assoc_transient (param $node anyref) (param $key anyref) (param $val anyref) (param $hash i32) (param $shift i32) (param $edit i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $i i32) (local $cnt i32) (local $found_idx i32)
    (local $editable_nd (ref $HAMTNode))
    (local $editable_entry (ref $HAMTEntry))
    (local $editable_col (ref $HAMTCollision))
    ;; null -> new entry (with transient edit)
    (if (ref.is_null (local.get $node))
      (then
        (global.set $__hamt_added (i32.const 1))
        (return (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val)))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (i32.eq (struct.get $HAMTEntry $hash (local.get $entry)) (local.get $hash))
          (then
            (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
              (then
                ;; Same key -> update value in place if owned
                (local.set $editable_entry (call $hamt_entry_ensure_editable (local.get $entry) (local.get $edit)))
                (struct.set $HAMTEntry $val (local.get $editable_entry) (local.get $val))
                (return (local.get $editable_entry)))
              (else
                ;; Hash collision -> collision node
                (global.set $__hamt_added (i32.const 1))
                (local.set $new_arr (call $array_new (i32.const 4)))
                (call $array_set (local.get $new_arr) (i32.const 0) (struct.get $HAMTEntry $key (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 1) (struct.get $HAMTEntry $val (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 2) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.const 3) (local.get $val))
                (return (struct.new $HAMTCollision (local.get $edit) (local.get $hash) (i32.const 2) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
          (else
            ;; Different hash -> split via hamt_two (immutable, will be cloned on next access)
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTEntry $hash (local.get $entry))
              (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; HAMTNode
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (local.set $idx (i32.popcnt (i32.and
          (struct.get $HAMTNode $bitmap (local.get $nd))
          (i32.sub (local.get $bit) (i32.const 1)))))
        (if (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then
            ;; Empty slot -> insert new entry, ensure editable
            (global.set $__hamt_added (i32.const 1))
            (local.set $editable_nd (call $hamt_node_ensure_editable (local.get $nd) (local.get $edit)))
            (local.set $old_arr (struct.get $HAMTNode $children (local.get $editable_nd)))
            (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
            (local.set $new_arr (call $array_new (i32.add (local.get $len) (i32.const 1))))
            ;; Copy elements before idx
            (if (i32.gt_s (local.get $idx) (i32.const 0))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                (local.get $idx))))
            ;; Insert new entry at idx
            (call $array_set (local.get $new_arr) (local.get $idx)
              (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val)))
            ;; Copy elements after idx
            (if (i32.lt_s (local.get $idx) (local.get $len))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.add (local.get $idx) (i32.const 1))
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (local.get $idx)
                (i32.sub (local.get $len) (local.get $idx)))))
            ;; Mutate the editable node in place
            (struct.set $HAMTNode $bitmap (local.get $editable_nd)
              (i32.or (struct.get $HAMTNode $bitmap (local.get $editable_nd)) (local.get $bit)))
            (struct.set $HAMTNode $children (local.get $editable_nd)
              (ref.cast (ref $AnyArray) (local.get $new_arr)))
            (return (local.get $editable_nd)))
          (else
            ;; Occupied slot -> recurse
            (local.set $editable_nd (call $hamt_node_ensure_editable (local.get $nd) (local.get $edit)))
            (local.set $child (array.get $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_assoc_transient (local.get $child) (local.get $key) (local.get $val)
              (local.get $hash) (i32.add (local.get $shift) (i32.const 5)) (local.get $edit)))
            ;; Update child in place
            (array.set $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx) (local.get $new_child))
            (return (local.get $editable_nd))))))
    ;; HAMTCollision
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (if (i32.eq (struct.get $HAMTCollision $hash (local.get $col)) (local.get $hash))
          (then
            ;; Same hash -> update or extend collision in place
            (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
            (local.set $found_idx (i32.const -1))
            (local.set $i (i32.const 0))
            (block $cfound
              (loop $cloop
                (br_if $cfound (i32.ge_s (local.get $i) (local.get $cnt)))
                (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                  (then (local.set $found_idx (local.get $i)) (br $cfound)))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $cloop)))
            (if (i32.ge_s (local.get $found_idx) (i32.const 0))
              (then
                ;; Update existing — ensure editable and mutate
                (local.set $editable_col (call $hamt_collision_ensure_editable (local.get $col) (local.get $edit)))
                (call $array_set (struct.get $HAMTCollision $entries (local.get $editable_col))
                  (i32.add (i32.mul (local.get $found_idx) (i32.const 2)) (i32.const 1)) (local.get $val))
                (return (local.get $editable_col)))
              (else
                ;; Add new to collision
                (global.set $__hamt_added (i32.const 1))
                (local.set $editable_col (call $hamt_collision_ensure_editable (local.get $col) (local.get $edit)))
                (local.set $new_arr (call $array_new (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (if (i32.gt_s (local.get $cnt) (i32.const 0))
                  (then (array.copy $AnyArray $AnyArray
                    (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                    (struct.get $HAMTCollision $entries (local.get $editable_col)) (i32.const 0)
                    (i32.mul (local.get $cnt) (i32.const 2)))))
                (call $array_set (local.get $new_arr) (i32.mul (local.get $cnt) (i32.const 2)) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 1)) (local.get $val))
                (struct.set $HAMTCollision $count (local.get $editable_col) (i32.add (local.get $cnt) (i32.const 1)))
                (struct.set $HAMTCollision $entries (local.get $editable_col) (ref.cast (ref $AnyArray) (local.get $new_arr)))
                (return (local.get $editable_col)))))
          (else
            ;; Different hash -> wrap collision in node
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTCollision $hash (local.get $col))
              (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; Fallback
    (local.get $node))

  ;; ---- hamt_dissoc_transient: in-place HAMT removal ----
  (func $hamt_dissoc_transient (param $node anyref) (param $key anyref) (param $hash i32) (param $shift i32) (param $edit i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $new_bm i32) (local $i i32) (local $j i32) (local $cnt i32)
    (local $editable_nd (ref $HAMTNode))
    (local $editable_col (ref $HAMTCollision))
    ;; null -> unchanged
    (if (ref.is_null (local.get $node)) (then (return (ref.null none))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
          (then (return (ref.null none))))
        (return (local.get $node))))
    ;; HAMTNode
    (if (result anyref) (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (if (result anyref) (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then (local.get $node))  ;; not found
          (else
            (local.set $idx (i32.popcnt (i32.and
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (i32.sub (local.get $bit) (i32.const 1)))))
            (local.set $editable_nd (call $hamt_node_ensure_editable (local.get $nd) (local.get $edit)))
            (local.set $child (array.get $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_dissoc_transient (local.get $child) (local.get $key) (local.get $hash)
              (i32.add (local.get $shift) (i32.const 5)) (local.get $edit)))
            (if (result anyref) (ref.is_null (local.get $new_child))
              (then
                ;; Child removed entirely -> shrink array
                (local.set $new_bm (i32.and (struct.get $HAMTNode $bitmap (local.get $editable_nd))
                  (i32.xor (local.get $bit) (i32.const -1))))
                (if (result anyref) (i32.eqz (local.get $new_bm))
                  (then (ref.null none))  ;; node now empty
                  (else
                    (local.set $old_arr (struct.get $HAMTNode $children (local.get $editable_nd)))
                    (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
                    ;; If only one child remains and it's a HAMTEntry, promote it
                    (if (result anyref) (i32.and (i32.eq (local.get $len) (i32.const 2))
                        (ref.test (ref $HAMTEntry) (array.get $AnyArray (ref.cast (ref $AnyArray) (local.get $old_arr))
                          (i32.sub (i32.const 1) (local.get $idx)))))
                      (then (array.get $AnyArray (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.sub (i32.const 1) (local.get $idx))))
                      (else
                        (local.set $new_arr (call $array_new (i32.sub (local.get $len) (i32.const 1))))
                        (if (i32.gt_s (local.get $idx) (i32.const 0))
                          (then (array.copy $AnyArray $AnyArray
                            (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                            (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                            (local.get $idx))))
                        (if (i32.lt_s (i32.add (local.get $idx) (i32.const 1)) (local.get $len))
                          (then (array.copy $AnyArray $AnyArray
                            (ref.cast (ref $AnyArray) (local.get $new_arr)) (local.get $idx)
                            (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.add (local.get $idx) (i32.const 1))
                            (i32.sub (i32.sub (local.get $len) (local.get $idx)) (i32.const 1)))))
                        (struct.set $HAMTNode $bitmap (local.get $editable_nd) (local.get $new_bm))
                        (struct.set $HAMTNode $children (local.get $editable_nd) (ref.cast (ref $AnyArray) (local.get $new_arr)))
                        (local.get $editable_nd))))))
              (else
                ;; Child changed -> replace in place
                (array.set $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx) (local.get $new_child))
                (local.get $editable_nd))))))
      (else
    ;; HAMTCollision
    (if (result anyref) (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
        ;; Find key in collision entries
        (local.set $i (i32.const -1))
        (local.set $j (i32.const 0))
        (block $cfound
          (loop $cloop
            (br_if $cfound (i32.ge_s (local.get $j) (local.get $cnt)))
            (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2))))
              (then (local.set $i (local.get $j)) (br $cfound)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $cloop)))
        (if (result anyref) (i32.lt_s (local.get $i) (i32.const 0))
          (then (local.get $node))  ;; not found
          (else
            (if (result anyref) (i32.eq (local.get $cnt) (i32.const 2))
              (then
                ;; Down to 1 entry -> promote to HAMTEntry
                (local.set $j (i32.sub (i32.const 1) (local.get $i)))
                (struct.new $HAMTEntry (i32.const 0)
                  (struct.get $HAMTCollision $hash (local.get $col))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2)))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1)))))
              (else
                ;; Remove entry from collision in place
                (local.set $editable_col (call $hamt_collision_ensure_editable (local.get $col) (local.get $edit)))
                (local.set $new_arr (call $array_new (i32.mul (i32.sub (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (local.set $j (i32.const 0))
                (local.set $slot (i32.const 0))
                (block $cdone
                  (loop $ccopy
                    (br_if $cdone (i32.ge_s (local.get $j) (local.get $cnt)))
                    (if (i32.ne (local.get $j) (local.get $i))
                      (then
                        (call $array_set (local.get $new_arr) (i32.mul (local.get $slot) (i32.const 2))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $editable_col)) (i32.mul (local.get $j) (i32.const 2))))
                        (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $slot) (i32.const 2)) (i32.const 1))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $editable_col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1))))
                        (local.set $slot (i32.add (local.get $slot) (i32.const 1)))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $ccopy)))
                (struct.set $HAMTCollision $count (local.get $editable_col) (i32.sub (local.get $cnt) (i32.const 1)))
                (struct.set $HAMTCollision $entries (local.get $editable_col) (ref.cast (ref $AnyArray) (local.get $new_arr)))
                (local.get $editable_col))))))
      (else (local.get $node))))))

  ;; ---- transient: create transient from persistent collection ----
  (func $transient (param $coll anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $map (ref $HashMap))
    (local $set (ref $HashSet))
    (local $edit i32)
    (local $tail anyref) (local $new_tail anyref) (local $tail_len i32)
    ;; Increment edit counter
    (local.set $edit (i32.add (global.get $__edit_counter) (i32.const 1)))
    (global.set $__edit_counter (local.get $edit))
    ;; Vector -> TransientVector
    (if (ref.test (ref $Vector) (local.get $coll))
      (then
        (local.set $vec (ref.cast (ref $Vector) (local.get $coll)))
        (local.set $tail (struct.get $Vector $tail (local.get $vec)))
        (local.set $tail_len (call $array_length (local.get $tail)))
        ;; Clone tail (mutable part during appends) — always size 32 for O(1) conj!
        (local.set $new_tail (call $array_new (i32.const 32)))
        (if (i32.gt_s (local.get $tail_len) (i32.const 0))
          (then (array.copy $AnyArray $AnyArray
            (ref.cast (ref $AnyArray) (local.get $new_tail)) (i32.const 0)
            (ref.cast (ref $AnyArray) (local.get $tail)) (i32.const 0)
            (local.get $tail_len))))
        (return (struct.new $TransientVector (i32.const 15)
          (struct.get $Vector $count (local.get $vec))
          (struct.get $Vector $shift (local.get $vec))
          (struct.get $Vector $root (local.get $vec))
          (local.get $new_tail)
          (local.get $edit)))))
    ;; ArrayMap -> convert to HashMap first, then make transient
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
      (then (return (call $transient (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $coll)))))))
    ;; HashMap -> TransientHashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
      (then
        (local.set $map (ref.cast (ref $HashMap) (local.get $coll)))
        (return (struct.new $TransientHashMap (i32.const 16)
          (struct.get $HashMap $count (local.get $map))
          (struct.get $HashMap $array (local.get $map))
          (local.get $edit)))))
    ;; HashSet -> TransientHashSet
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then
        (local.set $set (ref.cast (ref $HashSet) (local.get $coll)))
        (return (struct.new $TransientHashSet (i32.const 17)
          (struct.get $HashSet $count (local.get $set))
          (struct.get $HashSet $array (local.get $set))
          (local.get $edit)))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- persistent!: convert transient back to persistent ----
  (func $persistent_BANG_ (param $coll anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $tm (ref $TransientHashMap))
    (local $ts (ref $TransientHashSet))
    (local $tail anyref) (local $tail_len i32) (local $trimmed anyref)
    ;; TransientVector -> Vector
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        ;; Check edit is live
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; Invalidate transient
        (struct.set $TransientVector $edit (local.get $tv) (i32.const 0))
        ;; Trim tail to actual size
        (local.set $tail_len (i32.sub (struct.get $TransientVector $count (local.get $tv))
          (call $tail_offset (struct.get $TransientVector $count (local.get $tv)))))
        (local.set $trimmed (call $array_new (local.get $tail_len)))
        (if (i32.gt_s (local.get $tail_len) (i32.const 0))
          (then (array.copy $AnyArray $AnyArray
            (ref.cast (ref $AnyArray) (local.get $trimmed)) (i32.const 0)
            (ref.cast (ref $AnyArray) (struct.get $TransientVector $tail (local.get $tv))) (i32.const 0)
            (local.get $tail_len))))
        (return (struct.new $Vector (i32.const 7)
          (struct.get $TransientVector $count (local.get $tv))
          (struct.get $TransientVector $shift (local.get $tv))
          (struct.get $TransientVector $root (local.get $tv))
          (local.get $trimmed)))))
    ;; TransientHashMap -> HashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (struct.set $TransientHashMap $edit (local.get $tm) (i32.const 0))
        (return (struct.new $HashMap (i32.const 8)
          (struct.get $TransientHashMap $count (local.get $tm))
          (struct.get $TransientHashMap $array (local.get $tm))))))
    ;; TransientHashSet -> HashSet
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
      (then
        (local.set $ts (ref.cast (ref $TransientHashSet) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashSet $edit (local.get $ts)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (struct.set $TransientHashSet $edit (local.get $ts) (i32.const 0))
        (return (struct.new $HashSet (i32.const 9)
          (struct.get $TransientHashSet $count (local.get $ts))
          (struct.get $TransientHashSet $array (local.get $ts))))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- conj!: add to transient collection ----
  (func $conj_BANG_ (param $coll anyref) (param $val anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $tm (ref $TransientHashMap))
    (local $ts (ref $TransientHashSet))
    (local $count i32) (local $tail_len i32)
    (local $tail anyref) (local $new_tail anyref)
    (local $new_root anyref) (local $h i32)
    ;; TransientVector
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $count (struct.get $TransientVector $count (local.get $tv)))
        (local.set $tail_len (i32.sub (local.get $count) (call $tail_offset (local.get $count))))
        ;; Room in tail?
        (if (i32.lt_s (local.get $tail_len) (i32.const 32))
          (then
            ;; Mutate tail in place
            (call $array_set (struct.get $TransientVector $tail (local.get $tv))
              (local.get $tail_len) (local.get $val))
            (struct.set $TransientVector $count (local.get $tv) (i32.add (local.get $count) (i32.const 1)))
            (return (local.get $tv)))
          (else
            ;; Tail full -> push tail into trie
            (local.set $tail (struct.get $TransientVector $tail (local.get $tv)))
            ;; Create trimmed copy of current tail for the trie
            (local.set $new_tail (call $array_copy (local.get $tail) (i32.const 32)))
            ;; Set global for push_tail (it reads the vector for count)
            ;; We need a temporary Vector for push_tail
            (global.set $__push_tail_vec (struct.new $Vector (i32.const 7)
              (local.get $count)
              (struct.get $TransientVector $shift (local.get $tv))
              (struct.get $TransientVector $root (local.get $tv))
              (local.get $new_tail)))
            ;; Check if tree needs to grow
            (if (i32.gt_u (i32.shr_u (local.get $count) (i32.const 5))
                           (i32.shl (i32.const 1) (struct.get $TransientVector $shift (local.get $tv))))
              (then
                ;; Tree overflow - need new root level
                (local.set $new_root (call $array_new (i32.const 32)))
                (call $array_set (local.get $new_root) (i32.const 0) (struct.get $TransientVector $root (local.get $tv)))
                (call $array_set (local.get $new_root) (i32.const 1)
                  (call $new_path (struct.get $TransientVector $shift (local.get $tv)) (local.get $new_tail)))
                (struct.set $TransientVector $shift (local.get $tv)
                  (i32.add (struct.get $TransientVector $shift (local.get $tv)) (i32.const 5)))
                (struct.set $TransientVector $root (local.get $tv) (local.get $new_root)))
              (else
                ;; Push tail into existing tree
                (struct.set $TransientVector $root (local.get $tv)
                  (call $push_tail (struct.get $TransientVector $shift (local.get $tv))
                    (struct.get $TransientVector $root (local.get $tv)) (local.get $new_tail)))))
            ;; Create new tail with single element
            (local.set $new_tail (call $array_new (i32.const 32)))
            (call $array_set (local.get $new_tail) (i32.const 0) (local.get $val))
            (struct.set $TransientVector $tail (local.get $tv) (local.get $new_tail))
            (struct.set $TransientVector $count (local.get $tv) (i32.add (local.get $count) (i32.const 1)))
            (return (local.get $tv))))))
    ;; TransientHashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; val is a 2-element vector [k v]
        (global.set $__hamt_added (i32.const 0))
        (local.set $new_root (call $hamt_assoc_transient
          (struct.get $TransientHashMap $array (local.get $tm))
          (call $vector_nth (local.get $val) (i32.const 0))
          (call $vector_nth (local.get $val) (i32.const 1))
          (call $hash (call $vector_nth (local.get $val) (i32.const 0)))
          (i32.const 0)
          (struct.get $TransientHashMap $edit (local.get $tm))))
        (struct.set $TransientHashMap $array (local.get $tm) (local.get $new_root))
        (struct.set $TransientHashMap $count (local.get $tm)
          (i32.add (struct.get $TransientHashMap $count (local.get $tm)) (global.get $__hamt_added)))
        (return (local.get $tm))))
    ;; TransientHashSet
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
      (then
        (local.set $ts (ref.cast (ref $TransientHashSet) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashSet $edit (local.get $ts)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (global.set $__hamt_added (i32.const 0))
        (local.set $h (call $hash (local.get $val)))
        (local.set $new_root (call $hamt_assoc_transient
          (struct.get $TransientHashSet $array (local.get $ts))
          (local.get $val) (local.get $val) (local.get $h) (i32.const 0)
          (struct.get $TransientHashSet $edit (local.get $ts))))
        (struct.set $TransientHashSet $array (local.get $ts) (local.get $new_root))
        (struct.set $TransientHashSet $count (local.get $ts)
          (i32.add (struct.get $TransientHashSet $count (local.get $ts)) (global.get $__hamt_added)))
        (return (local.get $ts))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- assoc!: assoc on transient ----
  (func $assoc_BANG_ (param $coll anyref) (param $key anyref) (param $val anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $tm (ref $TransientHashMap))
    (local $idx i32) (local $count i32)
    (local $tail_off i32) (local $new_root anyref)
    ;; TransientVector
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $idx (i31.get_s (ref.cast (ref i31) (local.get $key))))
        (local.set $count (struct.get $TransientVector $count (local.get $tv)))
        ;; idx == count -> same as conj!
        (if (i32.eq (local.get $idx) (local.get $count))
          (then (return (call $conj_BANG_ (local.get $coll) (local.get $val)))))
        (local.set $tail_off (call $tail_offset (local.get $count)))
        (if (i32.ge_u (local.get $idx) (local.get $tail_off))
          (then
            ;; In tail -> mutate in place
            (call $array_set (struct.get $TransientVector $tail (local.get $tv))
              (i32.and (local.get $idx) (i32.const 31)) (local.get $val))
            (return (local.get $tv)))
          (else
            ;; In trie -> path-copying (reuse persistent do_assoc)
            (struct.set $TransientVector $root (local.get $tv)
              (call $do_assoc (struct.get $TransientVector $shift (local.get $tv))
                (struct.get $TransientVector $root (local.get $tv)) (local.get $idx) (local.get $val)))
            (return (local.get $tv))))))
    ;; TransientHashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (global.set $__hamt_added (i32.const 0))
        (local.set $new_root (call $hamt_assoc_transient
          (struct.get $TransientHashMap $array (local.get $tm))
          (local.get $key) (local.get $val)
          (call $hash (local.get $key)) (i32.const 0)
          (struct.get $TransientHashMap $edit (local.get $tm))))
        (struct.set $TransientHashMap $array (local.get $tm) (local.get $new_root))
        (struct.set $TransientHashMap $count (local.get $tm)
          (i32.add (struct.get $TransientHashMap $count (local.get $tm)) (global.get $__hamt_added)))
        (return (local.get $tm))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- dissoc!: remove from transient hash map ----
  (func $dissoc_BANG_ (param $coll anyref) (param $key anyref) (result anyref)
    (local $tm (ref $TransientHashMap))
    (local $new_root anyref) (local $h i32)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; Check if key exists
        (if (ref.eq
            (ref.cast eqref (call $hamt_get
              (struct.get $TransientHashMap $array (local.get $tm))
              (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
            (global.get $__not_found_sentinel))
          (then (return (local.get $coll))))
        (local.set $h (call $hash (local.get $key)))
        (local.set $new_root (call $hamt_dissoc_transient
          (struct.get $TransientHashMap $array (local.get $tm))
          (local.get $key) (local.get $h) (i32.const 0)
          (struct.get $TransientHashMap $edit (local.get $tm))))
        (struct.set $TransientHashMap $array (local.get $tm) (local.get $new_root))
        (struct.set $TransientHashMap $count (local.get $tm)
          (i32.sub (struct.get $TransientHashMap $count (local.get $tm)) (i32.const 1)))
        (return (local.get $coll))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- disj!: remove from transient hash set ----
  (func $disj_BANG_ (param $coll anyref) (param $elem anyref) (result anyref)
    (local $ts (ref $TransientHashSet))
    (local $new_root anyref) (local $h i32)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
      (then
        (local.set $ts (ref.cast (ref $TransientHashSet) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashSet $edit (local.get $ts)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; Check if element exists
        (if (ref.eq
            (ref.cast eqref (call $hamt_get
              (struct.get $TransientHashSet $array (local.get $ts))
              (local.get $elem) (call $hash (local.get $elem)) (i32.const 0)))
            (global.get $__not_found_sentinel))
          (then (return (local.get $coll))))
        (local.set $h (call $hash (local.get $elem)))
        (local.set $new_root (call $hamt_dissoc_transient
          (struct.get $TransientHashSet $array (local.get $ts))
          (local.get $elem) (local.get $h) (i32.const 0)
          (struct.get $TransientHashSet $edit (local.get $ts))))
        (struct.set $TransientHashSet $array (local.get $ts) (local.get $new_root))
        (struct.set $TransientHashSet $count (local.get $ts)
          (i32.sub (struct.get $TransientHashSet $count (local.get $ts)) (i32.const 1)))
        (return (local.get $coll))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- pop!: remove last element from transient vector ----
  ;; Strategy: if tail has >1 element, just decrement count. Otherwise,
  ;; persist, pop via persistent vector, then re-transient.
  (func $pop_BANG_ (param $coll anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $count i32) (local $tail_len i32)
    (local $new_count i32)
    (local $new_tail anyref) (local $new_tail_buf anyref)
    (local $new_tail_len i32)
    (local $vec anyref)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $count (struct.get $TransientVector $count (local.get $tv)))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $new_count (i32.sub (local.get $count) (i32.const 1)))
        (local.set $tail_len (i32.sub (local.get $count) (call $tail_offset (local.get $count))))
        (if (i32.gt_s (local.get $tail_len) (i32.const 1))
          (then
            ;; Tail has >1 element -> just decrement count
            (struct.set $TransientVector $count (local.get $tv) (local.get $new_count))
            (return (local.get $tv)))
          (else
            ;; Tail has 1 element -> need to pull new tail from trie
            (if (i32.le_s (local.get $new_count) (i32.const 0))
              (then
                ;; Going to empty
                (struct.set $TransientVector $count (local.get $tv) (i32.const 0))
                (struct.set $TransientVector $shift (local.get $tv) (i32.const 5))
                (struct.set $TransientVector $root (local.get $tv) (ref.null none))
                (struct.set $TransientVector $tail (local.get $tv) (call $array_new (i32.const 32)))
                (return (local.get $tv)))
              (else
                ;; Find the leaf array for the new last element
                (local.set $vec (struct.new $Vector (i32.const 7)
                  (local.get $count)
                  (struct.get $TransientVector $shift (local.get $tv))
                  (struct.get $TransientVector $root (local.get $tv))
                  (struct.get $TransientVector $tail (local.get $tv))))
                (local.set $new_tail (call $vector_array_for (local.get $vec)
                  (i32.sub (local.get $new_count) (i32.const 1))))
                ;; Copy into a 32-sized buffer
                (local.set $new_tail_len (call $array_length (local.get $new_tail)))
                (local.set $new_tail_buf (call $array_new (i32.const 32)))
                (if (i32.gt_s (local.get $new_tail_len) (i32.const 0))
                  (then (array.copy $AnyArray $AnyArray
                    (ref.cast (ref $AnyArray) (local.get $new_tail_buf)) (i32.const 0)
                    (ref.cast (ref $AnyArray) (local.get $new_tail)) (i32.const 0)
                    (local.get $new_tail_len))))
                (struct.set $TransientVector $count (local.get $tv) (local.get $new_count))
                (struct.set $TransientVector $tail (local.get $tv) (local.get $new_tail_buf))
                ;; Note: trie entries beyond count are unreachable (safe to leave stale)
                (return (local.get $tv)))))) ;; close return, else-B, if-B, else-A
    )) ;; close if-A, then-outer; leave if-outer open for fallthrough
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))
")

(defn emit-prelude-2b []
  "
  ;; make_array_map: create ArrayMap directly from AnyArray of [k,v,k,v,...] pairs.
  ;; No duplicate-key checking — caller guarantees uniqueness. count = number of k/v pairs.
  (func $make_array_map (param $arr anyref) (param $count i32) (result anyref)
    (struct.new $HashMap (i32.const 19) (local.get $count) (local.get $arr)))

  ;; ==========================================
  ;; Atom Operations
  ;; ==========================================

  ;; atom: create an atom with initial value
  (func $atom (param $val anyref) (result anyref)
    (struct.new $Atom (i32.const 10) (local.get $val) (ref.null none) (ref.null none)))

  ;; deref: get value from atom
  (func $deref (param $a anyref) (result anyref)
    (struct.get $Atom $val (ref.cast (ref $Atom) (local.get $a))))

  ;; fire_watches: call each watch fn with (key atom old new)
  (func $fire_watches (param $watches anyref) (param $atom anyref) (param $old anyref) (param $new anyref)
    (local $s anyref)
    (local $entry anyref)
    (if (ref.is_null (local.get $watches)) (then (return)))
    (local.set $s (call $seq (local.get $watches)))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $s)))
        (local.set $entry (call $first (local.get $s)))
        ;; entry is a vector [key fn]
        (drop (call $invoke4
          (call $vector_nth (local.get $entry) (i32.const 1))
          (call $vector_nth (local.get $entry) (i32.const 0))
          (local.get $atom)
          (local.get $old)
          (local.get $new)))
        (local.set $s (call $rest (local.get $s)))
        (br $loop))))

  ;; atom_validate: check validator, throw if invalid
  (func $atom_validate (param $validator anyref) (param $val anyref)
    (if (ref.is_null (local.get $validator)) (then (return)))
    (if (i32.eqz (call $truthy (call $invoke1 (local.get $validator) (local.get $val))))
      (then (throw $exn (ref.null none)))))

  ;; reset!: set atom value, returns new value (with validator/watches)
  (func $reset_BANG_ (param $a anyref) (param $val anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $old anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    ;; Validate
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $val))
    ;; Save old, set new
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (struct.set $Atom $val (local.get $atom) (local.get $val))
    ;; Fire watches
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $val))
    (local.get $val))

  ;; swap!: apply function to atom value (with validator/watches)
  (func $swap_BANG_ (param $a anyref) (param $f anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $old anyref)
    (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke1 (local.get $f) (local.get $old)))
    ;; Validate
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    ;; Set new
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    ;; Fire watches
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  ;; add_watch: add a watch function to an atom
  (func $add_watch (param $a anyref) (param $key anyref) (param $f anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $watches anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $watches (struct.get $Atom $watches (local.get $atom)))
    (if (ref.is_null (local.get $watches))
      (then (local.set $watches (call $hash_map_assoc (call $empty_hash_map) (local.get $key) (local.get $f))))
      (else (local.set $watches (call $hash_map_assoc (local.get $watches) (local.get $key) (local.get $f)))))
    (struct.set $Atom $watches (local.get $atom) (local.get $watches))
    (local.get $a))

  ;; remove_watch: remove a watch function from an atom
  (func $remove_watch (param $a anyref) (param $key anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $watches anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $watches (struct.get $Atom $watches (local.get $atom)))
    (if (i32.eqz (ref.is_null (local.get $watches)))
      (then (struct.set $Atom $watches (local.get $atom) (call $dissoc (local.get $watches) (local.get $key)))))
    (local.get $a))

  ;; set_validator!: set validator function on atom
  (func $set_validator_BANG_ (param $a anyref) (param $f anyref) (result anyref)
    (local $atom (ref $Atom))
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    ;; Validate current value with new validator
    (call $atom_validate (local.get $f) (struct.get $Atom $val (local.get $atom)))
    (struct.set $Atom $validator (local.get $atom) (local.get $f))
    (ref.null none))

  ;; atom?: check if value is an atom
  (func $atom_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Atom) (local.get $val))))

  ;; ==========================================
  ;; Apply
  ;; ==========================================

  ;; count_internal: get count of any collection as i32 (for apply dispatch)
  (func $count_internal (param $coll anyref) (result i32)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    (if (result i32) (ref.is_null (local.get $coll))
      (then (i32.const 0))
      (else (if (result i32) (ref.test (ref $Vector) (local.get $coll))
        (then (call $vector_count (local.get $coll)))
        (else (if (result i32) (ref.test (ref $VectorSeq) (local.get $coll))
          (then (i32.sub
            (call $vector_count (struct.get $VectorSeq $vec (ref.cast (ref $VectorSeq) (local.get $coll))))
            (struct.get $VectorSeq $offset (ref.cast (ref $VectorSeq) (local.get $coll)))))
          (else (if (result i32) (ref.test (ref $Cons) (local.get $coll))
          (then (call $list_length (local.get $coll)))
          (else (if (result i32) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
            (then (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
            (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
              (then (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
              (else (if (result i32) (ref.test (ref $String) (local.get $coll))
                (then (call $str_codepoint_count (local.get $coll)))
                (else (if (result i32) (ref.test (ref $LazySeq) (local.get $coll))
                  (then (call $count_internal (call $lazy_seq_realize (local.get $coll))))
                  (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
                    (then (struct.get $TransientVector $count (ref.cast (ref $TransientVector) (local.get $coll))))
                    (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
                      (then (struct.get $TransientHashMap $count (ref.cast (ref $TransientHashMap) (local.get $coll))))
                      (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
                        (then (struct.get $TransientHashSet $count (ref.cast (ref $TransientHashSet) (local.get $coll))))
                        (else
                          ;; Protocol fallback for ICounted
                          (if (result i32) (call $truthy (call $__satisfies_ICounted (local.get $coll)))
                            (then (i31.get_s (ref.cast (ref i31) (call $__dispatch__count (local.get $coll)))))
                            (else (i32.const 0))))
                      ))
                    ))
                  ))
                ))
              ))
            ))
          ))
        ))
      ))
    )))
  )

  ;; apply_0-8: helper functions for apply with specific arities
  (func $apply_0 (param $f anyref) (result anyref)
    (call $invoke0 (local.get $f)))

  (func $apply_1 (param $f anyref) (param $s anyref) (result anyref)
    (call $invoke1 (local.get $f) (call $first (local.get $s))))

  (func $apply_2 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke2 (local.get $f) (local.get $a0) (call $first (local.get $s))))

  (func $apply_3 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke3 (local.get $f) (local.get $a0) (local.get $a1) (call $first (local.get $s))))

  (func $apply_4 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke4 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (call $first (local.get $s))))

  (func $apply_5 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke5 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (call $first (local.get $s))))

  (func $apply_6 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref) (local $a4 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a4 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke6 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (call $first (local.get $s))))

  (func $apply_7 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref) (local $a4 anyref) (local $a5 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a4 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a5 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke7 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $a5) (call $first (local.get $s))))

  (func $apply_8 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref) (local $a4 anyref) (local $a5 anyref) (local $a6 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a4 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a5 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a6 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke8 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $a5) (local.get $a6) (call $first (local.get $s))))

  ;; apply: call function with args from collection (supports up to 8 args)
  (func $apply (param $f anyref) (param $args anyref) (result anyref)
    (local $s anyref)
    (local $n i32)
    (local.set $s (call $seq (local.get $args)))
    (local.set $n (call $count_internal (local.get $s)))
    (if (result anyref) (i32.eq (local.get $n) (i32.const 0))
      (then (call $apply_0 (local.get $f)))
      (else (if (result anyref) (i32.eq (local.get $n) (i32.const 1))
        (then (call $apply_1 (local.get $f) (local.get $s)))
        (else (if (result anyref) (i32.eq (local.get $n) (i32.const 2))
          (then (call $apply_2 (local.get $f) (local.get $s)))
          (else (if (result anyref) (i32.eq (local.get $n) (i32.const 3))
            (then (call $apply_3 (local.get $f) (local.get $s)))
            (else (if (result anyref) (i32.eq (local.get $n) (i32.const 4))
              (then (call $apply_4 (local.get $f) (local.get $s)))
              (else (if (result anyref) (i32.eq (local.get $n) (i32.const 5))
                (then (call $apply_5 (local.get $f) (local.get $s)))
                (else (if (result anyref) (i32.eq (local.get $n) (i32.const 6))
                  (then (call $apply_6 (local.get $f) (local.get $s)))
                  (else (if (result anyref) (i32.eq (local.get $n) (i32.const 7))
                    (then (call $apply_7 (local.get $f) (local.get $s)))
                    (else (if (result anyref) (i32.eq (local.get $n) (i32.const 8))
                      (then (call $apply_8 (local.get $f) (local.get $s)))
                      (else (unreachable))
                    ))
                  ))
                ))
              ))
            ))
          ))
        ))
      ))
    )
  )

  ;; string?: check if value is a string
  (func $string_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $String) (local.get $val))))

  ;; symbol?: check if value is a symbol
  (func $symbol_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 4))))

  ;; float?: check if value is a float
  (func $float_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Float) (local.get $val))))

  ;; regex?: check if value is a compiled regex pattern
  (func $regex_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Regex) (local.get $val))))

  ;; regex-pattern: extract pattern string from a Regex struct
  (func $regex_pattern (param $val anyref) (result anyref)
    (struct.get $Regex $pattern (ref.cast (ref $Regex) (local.get $val))))

  ;; integer?: check if value is an integer (i31ref)
  (func $integer_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.and
      (i32.eqz (ref.is_null (local.get $val)))
      (ref.test (ref i31) (local.get $val)))))

  ;; number?: check if value is any number type (integer or float)
  (func $number_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $val))
      (then (global.get $__false))
      (else
        (call $bool (i32.or
          (ref.test (ref i31) (local.get $val))
          (ref.test (ref $Float) (local.get $val)))))))

  ;; true?: check if value is boolean true ($Boolean with val=1)
  (func $true_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
      (then (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
        (then (global.get $__true))
        (else (global.get $__false))))
      (else (global.get $__false))))

  ;; false?: check if value is boolean false ($Boolean with val=0)
  (func $false_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
      (then (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
        (then (global.get $__false))
        (else (global.get $__true))))
      (else (global.get $__false))))

  ;; some?: check if value is not nil
  (func $some_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eqz (ref.is_null (local.get $val)))))

  ;; list?: check if value is a cons cell
  (func $list_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Cons) (local.get $val))))

  ;; keyword?: check if value is a keyword
  (func $keyword_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 2))))

  ;; fn?: check if value is a function (any closure type, all share tag 11)
  (func $fn_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 11))))

  ;; coll?: check if value is a collection (vector, map, set, list, or VectorSeq)
  (func $coll_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.or (i32.or (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $Vector) (local.get $val)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 9)))
      (ref.test (ref $VectorSeq) (local.get $val)))))

  ;; sequential?: check if value is sequential (vector, list, or VectorSeq)
  (func $sequential_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $Vector) (local.get $val)))
      (ref.test (ref $VectorSeq) (local.get $val)))))

  ;; associative?: check if value is associative (vector or map)
  (func $associative_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or
      (ref.test (ref $Vector) (local.get $val))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))))

  ;; counted?: check if value supports O(1) count (vector, map, set)
  (func $counted_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.or (i32.or
      (ref.test (ref $Vector) (local.get $val))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 9)))
      __USER_COUNTED__)))

  ;; indexed?: check if value supports indexed access (vector)
  (func $indexed_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Vector) (local.get $val))))

  ;; num: coerce to number (identity for woj - returns value unchanged)
  (func $num (param $val anyref) (result anyref)
    (local.get $val))

  ;; type: get type of value (stub - returns nil in woj)
  (func $type (param $val anyref) (result anyref)
    (ref.null none))

  ;; ==========================================
  ;; Polymorphic Operations
  ;; ==========================================

  ;; assoc: polymorphic assoc for vectors and hash-maps
  ;; For vectors, key must be an integer index
  ;; For hash-maps, key can be any value
  (func $assoc (param $coll anyref) (param $key anyref) (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
      (then
        ;; Vector - unbox key to get index
        (call $vector_assoc (local.get $coll)
          (i31.get_s (ref.cast (ref i31) (local.get $key)))
          (local.get $val)))
      (else
        (if (result anyref) (i32.or (i32.or (ref.is_null (local.get $coll)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
          (then
            ;; nil, HashMap, or ArrayMap
            (call $hash_map_assoc (local.get $coll) (local.get $key) (local.get $val)))
          (else
            ;; Protocol fallback for IAssociative
            (if (result anyref) (call $truthy (call $__satisfies_IAssociative (local.get $coll)))
              (then (call $__dispatch__assoc (local.get $coll) (local.get $key) (local.get $val)))
              (else (call $hash_map_assoc (local.get $coll) (local.get $key) (local.get $val)))))))))

  ;; ==========================================
  ;; Closure Runtime Functions
  ;; ==========================================

  ;; closure?: check if value is any closure type (all share tag 11)
  (func $closure_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 11))))

  ;; invoke0: invoke a 0-arity closure
  (func $invoke0 (param $closure anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 0)
        (ref.null none)
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc0
      (struct.get $Closure0 $env (ref.cast (ref $Closure0) (local.get $closure)))
      (struct.get $Closure0 $func (ref.cast (ref $Closure0) (local.get $closure)))))

  ;; invoke1: invoke a 1-arity closure (or keyword/map/set-as-function)
  (func $invoke1 (param $closure anyref) (param $arg0 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    (local $tag i32)
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    (local.set $tag (call $type_tag (local.get $closure)))
    ;; Keyword as function (tag=2)
    (if (i32.eq (local.get $tag) (i32.const 2))
      (then (return (call $hash_map_get (local.get $arg0) (local.get $closure)))))
    ;; HashMap/ArrayMap as function (tags 8, 19) — (the-map key)
    (if (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 19)))
      (then (return (call $hash_map_get (local.get $closure) (local.get $arg0)))))
    ;; HashSet as function (tag 9) — returns element if present, else nil
    (if (i32.eq (local.get $tag) (i32.const 9))
      (then (return (if (result anyref) (call $truthy (call $set_contains_QMARK_ (local.get $closure) (local.get $arg0)))
        (then (local.get $arg0))
        (else (ref.null none))))))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 1)
        (call $cons (local.get $arg0) (ref.null none))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc1
      (struct.get $Closure1 $env (ref.cast (ref $Closure1) (local.get $closure)))
      (local.get $arg0)
      (struct.get $Closure1 $func (ref.cast (ref $Closure1) (local.get $closure)))))

  ;; invoke2: invoke a 2-arity closure (or map-as-function with default)
  (func $invoke2 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    (local $tag i32)
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    (local.set $tag (call $type_tag (local.get $closure)))
    ;; Keyword as function with default (tag=2) — (:kw map default)
    (if (i32.eq (local.get $tag) (i32.const 2))
      (then (return (call $hash_map_get_default (local.get $arg0) (local.get $closure) (local.get $arg1)))))
    ;; HashMap/ArrayMap as function with default (tags 8, 19) — (the-map key default)
    (if (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 19)))
      (then (return (call $hash_map_get_default (local.get $closure) (local.get $arg0) (local.get $arg1)))))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 2)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (ref.null none)))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc2
      (struct.get $Closure2 $env (ref.cast (ref $Closure2) (local.get $closure)))
      (local.get $arg0)
      (local.get $arg1)
      (struct.get $Closure2 $func (ref.cast (ref $Closure2) (local.get $closure)))))

  ;; invoke3: invoke a 3-arity closure
  (func $invoke3 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 3)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (ref.null none))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc3
      (struct.get $Closure3 $env (ref.cast (ref $Closure3) (local.get $closure)))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (struct.get $Closure3 $func (ref.cast (ref $Closure3) (local.get $closure)))))

  ;; invoke4: invoke a 4-arity closure
  (func $invoke4 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 4)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (ref.null none)))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc4
      (struct.get $Closure4 $env (ref.cast (ref $Closure4) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
      (struct.get $Closure4 $func (ref.cast (ref $Closure4) (local.get $closure)))))

  ;; invoke5: invoke a 5-arity closure
  (func $invoke5 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 5)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (ref.null none))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc5
      (struct.get $Closure5 $env (ref.cast (ref $Closure5) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
      (struct.get $Closure5 $func (ref.cast (ref $Closure5) (local.get $closure)))))

  ;; invoke6: invoke a 6-arity closure
  (func $invoke6 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 6)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (ref.null none)))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc6
      (struct.get $Closure6 $env (ref.cast (ref $Closure6) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
      (struct.get $Closure6 $func (ref.cast (ref $Closure6) (local.get $closure)))))

  ;; invoke7: invoke a 7-arity closure
  (func $invoke7 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 7)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (ref.null none))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc7
      (struct.get $Closure7 $env (ref.cast (ref $Closure7) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
      (struct.get $Closure7 $func (ref.cast (ref $Closure7) (local.get $closure)))))

  ;; invoke8: invoke a 8-arity closure
  (func $invoke8 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 8)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (call $cons (local.get $arg7) (ref.null none)))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc8
      (struct.get $Closure8 $env (ref.cast (ref $Closure8) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
          (local.get $arg7)
      (struct.get $Closure8 $func (ref.cast (ref $Closure8) (local.get $closure)))))

  ;; invoke9: invoke a 9-arity closure
  (func $invoke9 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (param $arg8 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 9)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (call $cons (local.get $arg7) (call $cons (local.get $arg8) (ref.null none))))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc9
      (struct.get $Closure9 $env (ref.cast (ref $Closure9) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
          (local.get $arg7)
          (local.get $arg8)
      (struct.get $Closure9 $func (ref.cast (ref $Closure9) (local.get $closure)))))

  ;; invoke10: invoke a 10-arity closure
  (func $invoke10 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (param $arg8 anyref) (param $arg9 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 10)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (call $cons (local.get $arg7) (call $cons (local.get $arg8) (call $cons (local.get $arg9) (ref.null none)))))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc10
      (struct.get $Closure10 $env (ref.cast (ref $Closure10) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
          (local.get $arg7)
          (local.get $arg8)
          (local.get $arg9)
      (struct.get $Closure10 $func (ref.cast (ref $Closure10) (local.get $closure)))))

  ;; ==========================================
  ;; IReduce Protocol Implementations
  ;; ==========================================

  ;; reduced?: check if value is a Reduced wrapper
  (func $reduced_QMARK_ (param $val anyref) (result i32)
    (ref.test (ref $Reduced) (local.get $val)))

  ;; reduced: wrap value for early termination
  (func $reduced (param $val anyref) (result anyref)
    (struct.new $Reduced (i32.const 13) (local.get $val)))

  ;; deref-reduced: unwrap Reduced value (or return as-is if not Reduced)
  (func $deref_reduced (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Reduced) (local.get $val))
      (then (struct.get $Reduced $val (ref.cast (ref $Reduced) (local.get $val))))
      (else (local.get $val))))

  ;; cons-reduce: reduce over cons list (handles LazySeq in rest position)
  (func $cons_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $curr anyref)
    (local $next anyref)
    (local.set $acc (local.get $init))
    (local.set $curr (local.get $coll))
    (block $done
      (loop $loop
        ;; Check if done (null or reduced)
        (br_if $done (ref.is_null (local.get $curr)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        ;; If curr is a LazySeq, realize it first
        (if (ref.test (ref $LazySeq) (local.get $curr))
          (then (local.set $curr (call $lazy_seq_realize (local.get $curr)))))
        ;; If after realization curr is still null, we're done
        (br_if $done (ref.is_null (local.get $curr)))
        ;; If curr became a VectorSeq, delegate to vectorseq_reduce
        (if (ref.test (ref $VectorSeq) (local.get $curr))
          (then
            (local.set $acc (call $vectorseq_reduce (local.get $curr) (local.get $f) (local.get $acc)))
            (br $done)))
        ;; Apply f: acc = f(acc, first(curr))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $curr)))))
        ;; Advance: curr = rest(curr)
        (local.set $next (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $curr))))
        ;; If next is a LazySeq, realize it
        (if (ref.test (ref $LazySeq) (local.get $next))
          (then (local.set $next (call $lazy_seq_realize (local.get $next)))))
        (local.set $curr (local.get $next))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; vector-reduce: reduce over vector (efficient indexed access)
  (func $vector_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $i i32)
    (local $count i32)
    (local $v (ref $Vector))
    (local.set $v (ref.cast (ref $Vector) (local.get $coll)))
    (local.set $count (struct.get $Vector $count (local.get $v)))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        ;; Apply f: acc = f(acc, nth(v, i))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (call $vector_nth (local.get $coll) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; hashmap-reduce: reduce over map entries as [k v] vectors (HAMT-backed)
  (func $hashmap_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    ;; ArrayMap (tag 19): iterate flat [k,v,...] array producing [k,v] vectors
    (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
      (then
        (call $deref_reduced
          (call $array_map_reduce_entries
            (local.get $f) (local.get $init) (ref.cast (ref $HashMap) (local.get $coll)))))
      (else
        (call $deref_reduced
          (call $hamt_reduce_entries
            (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll)))
            (local.get $f) (local.get $init))))))

  ;; hashset-reduce: reduce over set elements (HAMT-backed)
  (func $hashset_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (call $deref_reduced
      (call $hamt_reduce_keys
        (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll)))
        (local.get $f) (local.get $init))))

  ;; vectorseq-reduce: reduce over VectorSeq (efficient indexed access from offset)
  (func $vectorseq_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $i i32)
    (local $count i32)
    (local $vs (ref $VectorSeq))
    (local $vec anyref)
    (local.set $vs (ref.cast (ref $VectorSeq) (local.get $coll)))
    (local.set $vec (struct.get $VectorSeq $vec (local.get $vs)))
    (local.set $i (struct.get $VectorSeq $offset (local.get $vs)))
    (local.set $count (call $vector_count (local.get $vec)))
    (local.set $acc (local.get $init))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (call $vector_nth (local.get $vec) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; Polymorphic reduce dispatcher
  (func $reduce (param $f anyref) (param $init anyref) (param $coll anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (local.get $init))
      (else
        ;; LazySeq - realize and recurse
        (if (result anyref) (ref.test (ref $LazySeq) (local.get $coll))
          (then (call $reduce (local.get $f) (local.get $init) (call $lazy_seq_realize (local.get $coll))))
          (else
            (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
              (then (call $vector_reduce (local.get $coll) (local.get $f) (local.get $init)))
              (else
                (if (result anyref) (ref.test (ref $VectorSeq) (local.get $coll))
                  (then (call $vectorseq_reduce (local.get $coll) (local.get $f) (local.get $init)))
                  (else
                (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
                  (then (call $cons_reduce (local.get $coll) (local.get $f) (local.get $init)))
                  (else
                    (if (result anyref) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
                      (then (call $hashmap_reduce (local.get $coll) (local.get $f) (local.get $init)))
                      (else
                        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
                          (then (call $hashset_reduce (local.get $coll) (local.get $f) (local.get $init)))
                          (else
                            ;; Protocol fallback for IReduce
                            (if (result anyref) (call $truthy (call $__satisfies_IReduce (local.get $coll)))
                              (then (call $__dispatch__reduce_init (local.get $coll) (local.get $f) (local.get $init)))
                              (else (local.get $init))))))))))))))))))

  ;; reduce without initial value: (reduce f coll)
  ;; Uses first element as init, reduces rest. Empty coll calls (f).
  (func $reduce_no_init (param $f anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    ;; Get seq of collection
    (local.set $s (call $seq (local.get $coll)))
    ;; Empty collection: call f with no args (Clojure semantics)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (call $invoke0 (local.get $f)))
      (else
        ;; Use first as init, reduce rest
        (call $reduce (local.get $f)
          (call $first (local.get $s))
          (call $rest (local.get $s))))))

  ;; reduce-kv: reduce with separate key and value arguments (for maps) (HAMT-backed)
  (func $reduce_kv (param $f anyref) (param $init anyref) (param $coll anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (local.get $init))
      (else
        ;; ArrayMap (tag 19) — iterate flat array
        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
          (then
            (call $deref_reduced
              (call $array_map_reduce_kv (local.get $f) (local.get $init)
                (ref.cast (ref $HashMap) (local.get $coll)))))
          (else
        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
          (then
            (call $deref_reduced
              (call $hamt_reduce
                (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll)))
                (local.get $f) (local.get $init))))
          (else (local.get $init))))))))

  ;; ==========================================
  ;; Lazy Sequence Operations
  ;; ==========================================

  ;; make-lazy-seq: create a lazy sequence from a thunk (0-arity closure)
  (func $make_lazy_seq (param $thunk anyref) (result anyref)
    (struct.new $LazySeq
      (i32.const 12)        ;; type tag (12 = LazySeq)
      (i32.const 0)         ;; __pad (structural padding)
      (local.get $thunk)    ;; thunk - the 0-arity closure
      (ref.null none)))     ;; realized - initially null (not realized)

  ;; lazy-seq?: check if value is a lazy sequence
  (func $lazy_seq_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $LazySeq) (local.get $val))))

  ;; lazy-seq-realized?: check if lazy seq has been realized (thunk is null)
  (func $lazy_seq_realized_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $LazySeq) (local.get $val))
      (then (call $bool (ref.is_null (struct.get $LazySeq $thunk
              (ref.cast (ref $LazySeq) (local.get $val))))))
      (else (call $bool (i32.const 0)))))

  ;; lazy-seq-realize: force evaluation of lazy sequence, return realized value
  ;; If already realized, return cached value
  ;; If not realized, call thunk and cache result
  (func $lazy_seq_realize (param $ls anyref) (result anyref)
    (local $lazy (ref $LazySeq))
    (local $thunk anyref)
    (local $result anyref)
    (local.set $lazy (ref.cast (ref $LazySeq) (local.get $ls)))
    (local.set $thunk (struct.get $LazySeq $thunk (local.get $lazy)))
    ;; If thunk is null, already realized - return cached value
    (if (result anyref) (ref.is_null (local.get $thunk))
      (then (struct.get $LazySeq $realized (local.get $lazy)))
      (else
        ;; Not realized - call thunk and cache result
        (local.set $result (call $invoke0 (local.get $thunk)))
        ;; If result is another LazySeq, recursively realize it
        (if (ref.test (ref $LazySeq) (local.get $result))
          (then (local.set $result (call $lazy_seq_realize (local.get $result)))))
        ;; Cache the result
        (struct.set $LazySeq $realized (local.get $lazy) (local.get $result))
        ;; Clear thunk to mark as realized (and allow GC of closure)
        (struct.set $LazySeq $thunk (local.get $lazy) (ref.null none))
        (local.get $result))))

  ;; ==========================================
  ;; Type Tag for Protocol Dispatch
  ;; ==========================================

  ;; Type tag constants:
  ;; nil = 0, i31 (int) = 1, Keyword = 2, String = 3, Symbol = 4, Float = 5
  ;; Cons = 6, Vector = 7, HashMap = 8, HashSet = 9, Atom = 10
  ;; Closure0-10 = 11 (all closures share tag), LazySeq = 12, Reduced = 13, Boolean = 14
  ;; TransientVector = 15, TransientHashMap = 16, TransientHashSet = 17
  ;; VectorSeq = 18, ExceptionInfo = 100, User-types = 19+

  ;; type_tag: returns numeric type tag for dispatch
  ;; All struct types extend $Tagged with $__type_id as first field,
  ;; so we just cast to $Tagged and read the tag directly.
  ;; WithMeta (tag=99) is transparent: returns the inner value's tag.
  (func $type_tag (param $val anyref) (result i32)
    (local $tag i32)
    (if (ref.is_null (local.get $val))
      (then (return (i32.const 0))))
    (if (ref.test (ref i31) (local.get $val))
      (then (return (i32.const 1))))
    (block $not_tagged (result anyref)
      (local.set $tag (struct.get $Tagged $__type_id
        (br_on_cast_fail $not_tagged anyref (ref $Tagged) (local.get $val))))
      (if (i32.eq (local.get $tag) (i32.const 99))
        (then (return (call $type_tag (struct.get $WithMeta $inner (ref.cast (ref $WithMeta) (local.get $val)))))))
      (return (local.get $tag)))
    (drop)
    (i32.const -1))

  ;; unwrap_meta: strip WithMeta wrapper if present, returning inner value
  (func $unwrap_meta (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Tagged) (local.get $val))
      (then (if (result anyref)
        (i32.eq (struct.get $Tagged $__type_id (ref.cast (ref $Tagged) (local.get $val))) (i32.const 99))
        (then (struct.get $WithMeta $inner (ref.cast (ref $WithMeta) (local.get $val))))
        (else (local.get $val))))
      (else (local.get $val))))

  ;; with_meta: wrap a value with metadata
  (func $with_meta_ (param $val anyref) (param $meta anyref) (result anyref)
    ;; If val already has meta, unwrap first
    (local $inner anyref)
    (local.set $inner (call $unwrap_meta (local.get $val)))
    ;; If meta is nil, return unwrapped value (no metadata)
    (if (result anyref) (ref.is_null (local.get $meta))
      (then (local.get $inner))
      (else (struct.new $WithMeta (i32.const 99) (i32.const 0) (i32.const 0) (local.get $inner) (local.get $meta)))))

  ;; meta_: extract metadata from a value (nil if none)
  ;; Uses tag check (tag=99) to avoid structural typing conflict
  (func $meta_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Tagged) (local.get $val))
      (then (if (result anyref)
        (i32.eq (struct.get $Tagged $__type_id (ref.cast (ref $Tagged) (local.get $val))) (i32.const 99))
        (then (struct.get $WithMeta $meta (ref.cast (ref $WithMeta) (local.get $val))))
        (else (ref.null none))))
      (else (ref.null none))))")

(defn emit-prelude-3 []
  "
  ;; ==========================================
  ;; String Operations
  ;; ==========================================

  ;; str_byte_len: get length of string in bytes
  (func $str_len (param $s anyref) (result i32)
    (array.len (struct.get $String $data (ref.cast (ref $String) (local.get $s)))))

  ;; utf8_cp_len: given first byte of UTF-8 sequence, return codepoint byte length (1-4)
  (func $utf8_cp_len (param $byte i32) (result i32)
    (if (result i32) (i32.le_u (local.get $byte) (i32.const 0x7F))
      (then (i32.const 1))
      (else (if (result i32) (i32.le_u (local.get $byte) (i32.const 0xDF))
        (then (i32.const 2))
        (else (if (result i32) (i32.le_u (local.get $byte) (i32.const 0xEF))
          (then (i32.const 3))
          (else (i32.const 4))))))))

  ;; str_codepoint_count: count UTF-8 codepoints in a string
  (func $str_codepoint_count (param $s anyref) (result i32)
    (local $data (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $count i32)
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $count (i32.add (local.get $count) (i32.const 1)))
        (local.set $i (i32.add (local.get $i)
          (call $utf8_cp_len (array.get_u $CharArray (local.get $data) (local.get $i)))))
        (br $loop)))
    (local.get $count))

  ;; utf8_byte_offset: find byte offset of Nth codepoint in a CharArray
  (func $utf8_byte_offset (param $data (ref $CharArray)) (param $n i32) (result i32)
    (local $i i32)
    (local $cp i32)
    (local $len i32)
    (local.set $len (array.len (local.get $data)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $cp) (local.get $n)))
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $i (i32.add (local.get $i)
          (call $utf8_cp_len (array.get_u $CharArray (local.get $data) (local.get $i)))))
        (local.set $cp (i32.add (local.get $cp) (i32.const 1)))
        (br $loop)))
    (local.get $i))

  ;; str_eq: compare two strings for equality
  ;; Fast path: if both have same non-negative ID, they're equal
  ;; Slow path: byte-by-byte comparison
  (func $str_eq (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $String))
    (local $sb (ref $String))
    (local $da (ref $CharArray))
    (local $db (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local.set $sa (ref.cast (ref $String) (local.get $a)))
    (local.set $sb (ref.cast (ref $String) (local.get $b)))
    ;; Fast path: same ID and both >= 0 (interned)
    (if (result i32) (i32.and
        (i32.ge_s (struct.get $String $id (local.get $sa)) (i32.const 0))
        (i32.eq (struct.get $String $id (local.get $sa))
                (struct.get $String $id (local.get $sb))))
      (then (i32.const 1))
      (else
        ;; Slow path: compare bytes
        (local.set $da (struct.get $String $data (local.get $sa)))
        (local.set $db (struct.get $String $data (local.get $sb)))
        (local.set $len (array.len (local.get $da)))
        ;; Different lengths -> not equal
        (if (result i32) (i32.ne (local.get $len) (array.len (local.get $db)))
          (then (i32.const 0))
          (else
            ;; Compare byte by byte
            (local.set $i (i32.const 0))
            (block $neq (result i32)
              (block $done
                (loop $loop
                  (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
                  (br_if $neq (i32.const 0) (i32.ne
                    (array.get_u $CharArray (local.get $da) (local.get $i))
                    (array.get_u $CharArray (local.get $db) (local.get $i))))
                  (local.set $i (i32.add (local.get $i) (i32.const 1)))
                  (br $loop)))
              (i32.const 1)))))))

  ;; str_concat: concatenate two strings, returns new string with ID=-1
  (func $str_concat (param $a anyref) (param $b anyref) (result anyref)
    (local $sa (ref $String))
    (local $sb (ref $String))
    (local $da (ref $CharArray))
    (local $db (ref $CharArray))
    (local $la i32)
    (local $lb i32)
    (local $new_data (ref $CharArray))
    (local.set $sa (ref.cast (ref $String) (local.get $a)))
    (local.set $sb (ref.cast (ref $String) (local.get $b)))
    (local.set $da (struct.get $String $data (local.get $sa)))
    (local.set $db (struct.get $String $data (local.get $sb)))
    (local.set $la (array.len (local.get $da)))
    (local.set $lb (array.len (local.get $db)))
    (local.set $new_data (array.new $CharArray (i32.const 0) (i32.add (local.get $la) (local.get $lb))))
    (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $da) (i32.const 0) (local.get $la))
    (array.copy $CharArray $CharArray (local.get $new_data) (local.get $la) (local.get $db) (i32.const 0) (local.get $lb))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; int_to_str: convert i32 to decimal string
  (func $int_to_str (param $n i32) (result anyref)
    (local $abs i32)
    (local $neg i32)
    (local $buf (ref $CharArray))
    (local $pos i32)
    (local $digit i32)
    (local $result (ref $CharArray))
    (local $len i32)
    (local $i i32)
    ;; Handle zero
    (if (result anyref) (i32.eqz (local.get $n))
      (then
        (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 1)))
        (array.set $CharArray (local.get $buf) (i32.const 0) (i32.const 48))  ;; '0'
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $buf)))
      (else
        ;; Handle negative
        (local.set $neg (i32.lt_s (local.get $n) (i32.const 0)))
        (local.set $abs (if (result i32) (local.get $neg)
          (then (i32.sub (i32.const 0) (local.get $n)))
          (else (local.get $n))))
        ;; Write digits in reverse into buffer (max 11 digits for i32)
        (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 12)))
        (local.set $pos (i32.const 11))
        (block $done
          (loop $loop
            (br_if $done (i32.eqz (local.get $abs)))
            (local.set $digit (i32.rem_u (local.get $abs) (i32.const 10)))
            (array.set $CharArray (local.get $buf) (local.get $pos)
              (i32.add (i32.const 48) (local.get $digit)))  ;; '0' + digit
            (local.set $abs (i32.div_u (local.get $abs) (i32.const 10)))
            (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
            (br $loop)))
        ;; Add minus sign if negative
        (if (local.get $neg)
          (then
            (array.set $CharArray (local.get $buf) (local.get $pos) (i32.const 45))  ;; '-'
            (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))))
        ;; Copy to correctly-sized array
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (local.set $len (i32.sub (i32.const 12) (local.get $pos)))
        (local.set $result (array.new $CharArray (i32.const 0) (local.get $len)))
        (array.copy $CharArray $CharArray (local.get $result) (i32.const 0) (local.get $buf) (local.get $pos) (local.get $len))
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $result)))))

  ;; str1: convert any single value to string
  ;; nil -> \"\", int -> decimal, string -> itself, keyword -> \":name\"
  (func $str1 (param $val anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $val (call $unwrap_meta (local.get $val)))
    ;; nil -> empty string
    (if (result anyref) (ref.is_null (local.get $val))
      (then (call $make_empty_str))
      (else
        ;; String -> itself
        (if (result anyref) (ref.test (ref $String) (local.get $val))
          (then (local.get $val))
          (else
            ;; i31ref (integer/boolean) -> decimal string
            (if (result anyref) (ref.test (ref i31) (local.get $val))
              (then (call $int_to_str (i31.get_s (ref.cast (ref i31) (local.get $val)))))
              (else
                ;; Keyword -> :name
                (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
                  (then (call $keyword_to_str (local.get $val)))
                  (else
                    ;; Boolean -> true/false string
                    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
                      (then
                        (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
                          (then (call $str1_true))
                          (else (call $str1_false))))
                      (else
                        ;; Float -> decimal string
                        (if (result anyref) (ref.test (ref $Float) (local.get $val))
                          (then (call $float_to_str
                            (struct.get $Float $val (ref.cast (ref $Float) (local.get $val)))))
                          (else
                            ;; Symbol -> ns/name or just name
                            (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
                              (then (call $symbol_to_str (local.get $val)))
                              (else
                                ;; Other -> empty string
                                (call $make_empty_str))))))))))))))))

  ;; make_empty_str: create an empty string
  (func $make_empty_str (result anyref)
    (struct.new $String (i32.const 3) (i32.const -1) (array.new $CharArray (i32.const 0) (i32.const 0))))

  ;; str1_true: return the string true
  (func $str1_true (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 4)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 116))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 114))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 117))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 101))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; str1_false: return the string false
  (func $str1_false (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 5)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 102))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 97))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 108))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 115))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 101))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; keyword_to_str: convert keyword to \":name\" string
  (func $keyword_to_str (param $kw anyref) (result anyref)
    (local $id i32)
    (local $name anyref)
    (local $colon (ref $CharArray))
    (local $colon_str anyref)
    (local.set $id (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $kw))))
    ;; Look up name (handles both compile-time and runtime keywords)
    (local.set $name (call $kw_name_lookup (local.get $id)))
    ;; Prepend \":\"
    (local.set $colon (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $colon) (i32.const 0) (i32.const 58))  ;; ':'
    (local.set $colon_str (struct.new $String (i32.const 3) (i32.const -1) (local.get $colon)))
    (call $str_concat (local.get $colon_str) (local.get $name)))

  ;; kw_name_lookup: look up keyword name by ID, checking runtime list
  (func $kw_name_lookup (param $id i32) (result anyref)
    (local $current anyref)
    ;; Check compile-time table first
    (if (i32.and
          (i32.eqz (ref.is_null (global.get $__kw_names)))
          (i32.lt_s (local.get $id) (call $array_length (global.get $__kw_names))))
      (then (return (call $array_get (global.get $__kw_names) (local.get $id)))))
    ;; Search runtime keyword list
    (local.set $current (global.get $__kw_runtime_list))
    (block $done
      (loop $search
        (br_if $done (ref.is_null (local.get $current)))
        (if (i32.eq (local.get $id)
              (struct.get $Keyword $id (ref.cast (ref $Keyword)
                (struct.get $Cons $rest (ref.cast (ref $Cons)
                  (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))))
          (then (return
            (struct.get $Cons $first (ref.cast (ref $Cons)
              (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $search)))
    (call $make_empty_str))

  ;; strip_ns: given a string like foo/bar, return bar. If no slash, return as-is.
  (func $strip_ns (param $s anyref) (result anyref)
    (local $src (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $slash_pos i32)
    (local $new_len i32)
    (local $dst (ref $CharArray))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $src)))
    (local.set $slash_pos (i32.const -1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (i32.eq (array.get_u $CharArray (local.get $src) (local.get $i)) (i32.const 47))  ;; '/'
          (then (local.set $slash_pos (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (if (result anyref) (i32.lt_s (local.get $slash_pos) (i32.const 0))
      (then (local.get $s))
      (else
        (local.set $new_len (i32.sub (local.get $len) (i32.add (local.get $slash_pos) (i32.const 1))))
        (if (result anyref) (i32.le_s (local.get $new_len) (i32.const 0))
          (then (call $make_empty_str))
          (else
            (local.set $dst (array.new $CharArray (i32.const 0) (local.get $new_len)))
            (array.copy $CharArray $CharArray (local.get $dst) (i32.const 0) (local.get $src)
              (i32.add (local.get $slash_pos) (i32.const 1)) (local.get $new_len))
            (struct.new $String (i32.const 3) (i32.const -1) (local.get $dst)))))))

  ;; name_fn: get bare name from keyword (without namespace) or symbol
  (func $name_fn (param $val anyref) (result anyref)
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
      (then
        (call $strip_ns (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val))))))
      (else
        ;; Symbol -> read name from struct
        (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
          (then
            (struct.get $Symbol $name (ref.cast (ref $Symbol) (local.get $val))))
          (else
            ;; String -> return itself
            (if (result anyref) (ref.test (ref $String) (local.get $val))
              (then (local.get $val))
              (else (call $make_empty_str))))))))

  ;; subs: get substring from start (inclusive) to end (exclusive) in codepoints
  (func $subs (param $s anyref) (param $start i32) (param $end i32) (result anyref)
    (local $src (ref $CharArray))
    (local $byte_start i32)
    (local $byte_end i32)
    (local $byte_len i32)
    (local $new_data (ref $CharArray))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $byte_start (call $utf8_byte_offset (local.get $src) (local.get $start)))
    (local.set $byte_end (call $utf8_byte_offset (local.get $src) (local.get $end)))
    (local.set $byte_len (i32.sub (local.get $byte_end) (local.get $byte_start)))
    (if (result anyref) (i32.le_s (local.get $byte_len) (i32.const 0))
      (then (call $make_empty_str))
      (else
        (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $byte_len)))
        (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $src) (local.get $byte_start) (local.get $byte_len))
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))))

  ;; char_from_code: create a single-character string from a char code (i32)
  (func $char_from_code (param $code i32) (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $data) (i32.const 0) (local.get $code))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; str_hash: FNV-1a hash of string bytes
  (func $str_hash (param $s anyref) (result i32)
    (local $data (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $h i32)
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (local.set $h (i32.const 0x811c9dc5))  ;; FNV offset basis
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $h (i32.xor (local.get $h)
          (array.get_u $CharArray (local.get $data) (local.get $i))))
        (local.set $h (i32.mul (local.get $h) (i32.const 0x01000193)))  ;; FNV prime
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $h))")

(defn emit-prelude-3b []
  "
  ;; str_index_of: find first occurrence of substring, return byte offset or -1
  ;; Both params are String refs. Returns i31ref (index or -1)
  (func $str_index_of (param $haystack anyref) (param $needle anyref) (result anyref)
    (local $hdata (ref $CharArray))
    (local $ndata (ref $CharArray))
    (local $hlen i32) (local $nlen i32)
    (local $i i32) (local $j i32) (local $match i32)
    ;; Count codepoints to find position, not byte offset
    (local $cp_count i32)
    (if (ref.is_null (local.get $haystack)) (then (return (ref.i31 (i32.const -1)))))
    (if (ref.is_null (local.get $needle)) (then (return (ref.i31 (i32.const -1)))))
    (local.set $hdata (struct.get $String $data (ref.cast (ref $String) (local.get $haystack))))
    (local.set $ndata (struct.get $String $data (ref.cast (ref $String) (local.get $needle))))
    (local.set $hlen (array.len (local.get $hdata)))
    (local.set $nlen (array.len (local.get $ndata)))
    (if (i32.eqz (local.get $nlen)) (then (return (ref.i31 (i32.const 0)))))
    (if (i32.gt_s (local.get $nlen) (local.get $hlen)) (then (return (ref.i31 (i32.const -1)))))
    (local.set $i (i32.const 0))
    (local.set $cp_count (i32.const 0))
    (block $done
      (loop $outer
        (br_if $done (i32.gt_s (i32.add (local.get $i) (local.get $nlen)) (local.get $hlen)))
        ;; Check if needle matches at position i
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $no_match
          (loop $inner
            (br_if $no_match (i32.ge_s (local.get $j) (local.get $nlen)))
            (if (i32.ne (array.get_u $CharArray (local.get $hdata) (i32.add (local.get $i) (local.get $j)))
                        (array.get_u $CharArray (local.get $ndata) (local.get $j)))
              (then (local.set $match (i32.const 0)) (br $no_match)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $inner)))
        (if (local.get $match) (then (return (ref.i31 (local.get $cp_count)))))
        ;; Advance i by one codepoint
        (local.set $i (i32.add (local.get $i) (call $utf8_cp_len (array.get_u $CharArray (local.get $hdata) (local.get $i)))))
        (local.set $cp_count (i32.add (local.get $cp_count) (i32.const 1)))
        (br $outer)))
    (ref.i31 (i32.const -1)))

  ;; str_to_lower: convert ASCII chars to lowercase
  (func $str_to_lower (param $s anyref) (result anyref)
    (local $data (ref $CharArray))
    (local $len i32) (local $i i32) (local $b i32)
    (local $new_data (ref $CharArray))
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $len)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $b (array.get_u $CharArray (local.get $data) (local.get $i)))
        (if (i32.and (i32.ge_u (local.get $b) (i32.const 65)) (i32.le_u (local.get $b) (i32.const 90)))
          (then (local.set $b (i32.add (local.get $b) (i32.const 32)))))
        (array.set $CharArray (local.get $new_data) (local.get $i) (local.get $b))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; str_to_upper: convert ASCII chars to uppercase
  (func $str_to_upper (param $s anyref) (result anyref)
    (local $data (ref $CharArray))
    (local $len i32) (local $i i32) (local $b i32)
    (local $new_data (ref $CharArray))
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $len)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $b (array.get_u $CharArray (local.get $data) (local.get $i)))
        (if (i32.and (i32.ge_u (local.get $b) (i32.const 97)) (i32.le_u (local.get $b) (i32.const 122)))
          (then (local.set $b (i32.sub (local.get $b) (i32.const 32)))))
        (array.set $CharArray (local.get $new_data) (local.get $i) (local.get $b))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; str_starts_with: check if string starts with prefix (returns i31ref bool)
  (func $str_starts_with (param $s anyref) (param $prefix anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $pdata (ref $CharArray))
    (local $slen i32) (local $plen i32) (local $i i32)
    (if (ref.is_null (local.get $s)) (then (return (global.get $__false))))
    (if (ref.is_null (local.get $prefix)) (then (return (global.get $__true))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $pdata (struct.get $String $data (ref.cast (ref $String) (local.get $prefix))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $plen (array.len (local.get $pdata)))
    (if (i32.gt_s (local.get $plen) (local.get $slen)) (then (return (global.get $__false))))
    (local.set $i (i32.const 0))
    (block $no
      (loop $loop
        (br_if $no (i32.ge_s (local.get $i) (local.get $plen)))
        (if (i32.ne (array.get_u $CharArray (local.get $sdata) (local.get $i))
                    (array.get_u $CharArray (local.get $pdata) (local.get $i)))
          (then (return (global.get $__false))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (global.get $__true))

  ;; str_ends_with: check if string ends with suffix (returns i31ref bool)
  (func $str_ends_with (param $s anyref) (param $suffix anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $xdata (ref $CharArray))
    (local $slen i32) (local $xlen i32) (local $i i32) (local $offset i32)
    (if (ref.is_null (local.get $s)) (then (return (global.get $__false))))
    (if (ref.is_null (local.get $suffix)) (then (return (global.get $__true))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $xdata (struct.get $String $data (ref.cast (ref $String) (local.get $suffix))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $xlen (array.len (local.get $xdata)))
    (if (i32.gt_s (local.get $xlen) (local.get $slen)) (then (return (global.get $__false))))
    (local.set $offset (i32.sub (local.get $slen) (local.get $xlen)))
    (local.set $i (i32.const 0))
    (block $no
      (loop $loop
        (br_if $no (i32.ge_s (local.get $i) (local.get $xlen)))
        (if (i32.ne (array.get_u $CharArray (local.get $sdata) (i32.add (local.get $offset) (local.get $i)))
                    (array.get_u $CharArray (local.get $xdata) (local.get $i)))
          (then (return (global.get $__false))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (global.get $__true))

  ;; str_trim: remove leading/trailing ASCII whitespace
  (func $str_trim (param $s anyref) (result anyref)
    (local $data (ref $CharArray))
    (local $len i32) (local $start i32) (local $end i32) (local $new_len i32)
    (local $new_data (ref $CharArray))
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (if (i32.eqz (local.get $len)) (then (return (local.get $s))))
    ;; Find start (skip whitespace)
    (local.set $start (i32.const 0))
    (block $s_done
      (loop $s_loop
        (br_if $s_done (i32.ge_s (local.get $start) (local.get $len)))
        (br_if $s_done (i32.gt_u (array.get_u $CharArray (local.get $data) (local.get $start)) (i32.const 32)))
        (local.set $start (i32.add (local.get $start) (i32.const 1)))
        (br $s_loop)))
    ;; Find end (skip trailing whitespace)
    (local.set $end (local.get $len))
    (block $e_done
      (loop $e_loop
        (br_if $e_done (i32.le_s (local.get $end) (local.get $start)))
        (br_if $e_done (i32.gt_u (array.get_u $CharArray (local.get $data) (i32.sub (local.get $end) (i32.const 1))) (i32.const 32)))
        (local.set $end (i32.sub (local.get $end) (i32.const 1)))
        (br $e_loop)))
    (local.set $new_len (i32.sub (local.get $end) (local.get $start)))
    (if (i32.eqz (local.get $new_len)) (then (return (struct.new $String (i32.const 3) (i32.const -1) (array.new $CharArray (i32.const 0) (i32.const 0))))))
    (if (i32.and (i32.eqz (local.get $start)) (i32.eq (local.get $end) (local.get $len)))
      (then (return (local.get $s))))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $new_len)))
    (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $data) (local.get $start) (local.get $new_len))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; str_replace: replace all occurrences of target with replacement
  (func $str_replace (param $s anyref) (param $target anyref) (param $replacement anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $tdata (ref $CharArray)) (local $rdata (ref $CharArray))
    (local $slen i32) (local $tlen i32) (local $rlen i32)
    (local $i i32) (local $j i32) (local $match i32)
    (local $result_len i32) (local $result_cap i32)
    (local $result (ref $CharArray)) (local $ri i32)
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $tdata (struct.get $String $data (ref.cast (ref $String) (local.get $target))))
    (local.set $rdata (struct.get $String $data (ref.cast (ref $String) (local.get $replacement))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $tlen (array.len (local.get $tdata)))
    (local.set $rlen (array.len (local.get $rdata)))
    (if (i32.eqz (local.get $tlen)) (then (return (local.get $s))))
    ;; Allocate result buffer (worst case: every char is replaced)
    (local.set $result_cap (i32.mul (local.get $slen) (i32.add (local.get $rlen) (i32.const 1))))
    (if (i32.lt_s (local.get $result_cap) (i32.add (local.get $slen) (i32.const 1)))
      (then (local.set $result_cap (i32.add (local.get $slen) (i32.const 1)))))
    (local.set $result (array.new $CharArray (i32.const 0) (local.get $result_cap)))
    (local.set $i (i32.const 0))
    (local.set $ri (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $slen)))
        ;; Check for match at position i
        (local.set $match (i32.const 1))
        (if (i32.le_s (i32.add (local.get $i) (local.get $tlen)) (local.get $slen))
          (then
            (local.set $j (i32.const 0))
            (block $no_match
              (loop $cmp
                (br_if $no_match (i32.ge_s (local.get $j) (local.get $tlen)))
                (if (i32.ne (array.get_u $CharArray (local.get $sdata) (i32.add (local.get $i) (local.get $j)))
                            (array.get_u $CharArray (local.get $tdata) (local.get $j)))
                  (then (local.set $match (i32.const 0)) (br $no_match)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $cmp))))
          (else (local.set $match (i32.const 0))))
        (if (local.get $match)
          (then
            ;; Copy replacement
            (local.set $j (i32.const 0))
            (block $rd
              (loop $rl
                (br_if $rd (i32.ge_s (local.get $j) (local.get $rlen)))
                (array.set $CharArray (local.get $result) (local.get $ri) (array.get_u $CharArray (local.get $rdata) (local.get $j)))
                (local.set $ri (i32.add (local.get $ri) (i32.const 1)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $rl)))
            (local.set $i (i32.add (local.get $i) (local.get $tlen))))
          (else
            ;; Copy original byte
            (array.set $CharArray (local.get $result) (local.get $ri) (array.get_u $CharArray (local.get $sdata) (local.get $i)))
            (local.set $ri (i32.add (local.get $ri) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $loop)))
    ;; Trim result to actual length
    (local.set $result_len (local.get $ri))
    (local.set $sdata (array.new $CharArray (i32.const 0) (local.get $result_len)))
    (array.copy $CharArray $CharArray (local.get $sdata) (i32.const 0) (local.get $result) (i32.const 0) (local.get $result_len))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $sdata)))

  ;; str_split: split string by single-char separator, return a Cons list of strings
  (func $str_split (param $s anyref) (param $sep anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $sepdata (ref $CharArray))
    (local $slen i32) (local $seplen i32)
    (local $i i32) (local $start i32) (local $j i32) (local $match i32)
    (local $result anyref) (local $part (ref $CharArray)) (local $part_len i32)
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $sepdata (struct.get $String $data (ref.cast (ref $String) (local.get $sep))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $seplen (array.len (local.get $sepdata)))
    (if (i32.eqz (local.get $seplen)) (then (return (struct.new $Cons (i32.const 6) (local.get $s) (ref.null none)))))
    (local.set $result (ref.null none))
    (local.set $i (local.get $slen))
    (local.set $start (local.get $slen))
    ;; Scan backwards to build list in forward order
    (block $done
      (loop $loop
        ;; Check if we can match separator at position i-seplen
        (if (i32.ge_s (local.get $i) (local.get $seplen))
          (then
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (local.set $match (i32.const 1))
            (if (i32.ge_s (i32.sub (local.get $start) (local.get $i)) (local.get $seplen))
              (then
                ;; Check for separator match at position i
                (local.set $j (i32.const 0))
                (block $no_match
                  (loop $cmp
                    (br_if $no_match (i32.ge_s (local.get $j) (local.get $seplen)))
                    (if (i32.ne (array.get_u $CharArray (local.get $sdata) (i32.add (local.get $i) (local.get $j)))
                                (array.get_u $CharArray (local.get $sepdata) (local.get $j)))
                      (then (local.set $match (i32.const 0)) (br $no_match)))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $cmp)))
                (if (local.get $match)
                  (then
                    ;; Extract substring from i+seplen to start
                    (local.set $part_len (i32.sub (local.get $start) (i32.add (local.get $i) (local.get $seplen))))
                    (local.set $part (array.new $CharArray (i32.const 0) (local.get $part_len)))
                    (if (i32.gt_s (local.get $part_len) (i32.const 0))
                      (then (array.copy $CharArray $CharArray (local.get $part) (i32.const 0) (local.get $sdata)
                        (i32.add (local.get $i) (local.get $seplen)) (local.get $part_len))))
                    (local.set $result (struct.new $Cons (i32.const 6)
                      (struct.new $String (i32.const 3) (i32.const -1) (local.get $part))
                      (local.get $result)))
                    (local.set $start (local.get $i)))))
              (else (nop))))
          (else
            ;; Add first segment
            (local.set $part_len (local.get $start))
            (local.set $part (array.new $CharArray (i32.const 0) (local.get $part_len)))
            (if (i32.gt_s (local.get $part_len) (i32.const 0))
              (then (array.copy $CharArray $CharArray (local.get $part) (i32.const 0) (local.get $sdata) (i32.const 0) (local.get $part_len))))
            (local.set $result (struct.new $Cons (i32.const 6)
              (struct.new $String (i32.const 3) (i32.const -1) (local.get $part))
              (local.get $result)))
            (return (local.get $result))))
        (br $loop)))
    (local.get $result))

  ;; string->mem!: copy String's UTF-8 bytes to linear memory at offset, return byte count
  (func $string__GT_mem_BANG_ (param $str anyref) (param $offset i32) (result i32)
    (local $chars (ref null $CharArray))
    (local $len i32)
    (local $i i32)
    (if (ref.is_null (local.get $str)) (then (return (i32.const 0))))
    (if (i32.eqz (ref.test (ref $String) (local.get $str))) (then (return (i32.const 0))))
    (local.set $chars (struct.get $String $data (ref.cast (ref $String) (local.get $str))))
    (local.set $len (array.len (local.get $chars)))
    (if (i32.eqz (local.get $len)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $offset) (local.get $i))
                    (array.get_u $CharArray (local.get $chars) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $len))

  ;; mem->string: read len bytes from linear memory at offset, return String
  (func $mem__GT_string (param $offset i32) (param $len i32) (result anyref)
    (local $chars (ref $CharArray))
    (local $i i32)
    (if (i32.le_s (local.get $len) (i32.const 0))
      (then (return (struct.new $String (i32.const 3) (i32.const -1)
                      (array.new $CharArray (i32.const 0) (i32.const 0))))))
    (local.set $chars (array.new $CharArray (i32.const 0) (local.get $len)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (array.set $CharArray (local.get $chars) (local.get $i)
          (i32.load8_u (i32.add (local.get $offset) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $chars)))

  ;; char_at_as_str: return codepoint at codepoint index as string
  (func $char_at_as_str (param $s anyref) (param $idx i32) (result anyref)
    (local $data (ref $CharArray))
    (local $offset i32)
    (local $cp_len i32)
    (local $new_data (ref $CharArray))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $offset (call $utf8_byte_offset (local.get $data) (local.get $idx)))
    (local.set $cp_len (call $utf8_cp_len (array.get_u $CharArray (local.get $data) (local.get $offset))))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $cp_len)))
    (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $data) (local.get $offset) (local.get $cp_len))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; nth_polymorphic: get element at index from vector, transient vector, string, or cons
  (func $nth_polymorphic (param $coll anyref) (param $idx i32) (result anyref)
    (local $tv (ref $TransientVector))
    (local $cur anyref)
    (local $i i32)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
      (then (call $vector_nth (local.get $coll) (local.get $idx)))
      (else
        (if (result anyref) (ref.test (ref $VectorSeq) (local.get $coll))
          (then (call $vector_nth
            (struct.get $VectorSeq $vec (ref.cast (ref $VectorSeq) (local.get $coll)))
            (i32.add (struct.get $VectorSeq $offset (ref.cast (ref $VectorSeq) (local.get $coll)))
                     (local.get $idx))))
          (else
        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
          (then
            ;; TransientVector — build temp Vector for array_for lookup
            (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
            (call $vector_nth
              (struct.new $Vector (i32.const 7)
                (struct.get $TransientVector $count (local.get $tv))
                (struct.get $TransientVector $shift (local.get $tv))
                (struct.get $TransientVector $root (local.get $tv))
                (struct.get $TransientVector $tail (local.get $tv)))
              (local.get $idx)))
          (else
            (if (result anyref) (ref.test (ref $String) (local.get $coll))
              (then (call $char_at_as_str (local.get $coll) (local.get $idx)))
              (else
                ;; Cons (list) — walk the chain idx times
                (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
                  (then
                    (local.set $cur (local.get $coll))
                    (local.set $i (local.get $idx))
                    (block $found
                      (loop $walk
                        (br_if $found (i32.or (ref.is_null (local.get $cur)) (i32.eqz (ref.test (ref $Cons) (local.get $cur)))))
                        (if (i32.eqz (local.get $i))
                          (then
                            (local.set $cur (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $cur))))
                            (br $found)))
                        (local.set $cur (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $cur))))
                        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                        (br $walk)))
                    (local.get $cur))
                  (else
                    ;; LazySeq or other seq — walk using first/rest
                    (if (result anyref) (ref.test (ref $LazySeq) (local.get $coll))
                      (then
                        (local.set $cur (local.get $coll))
                        (local.set $i (local.get $idx))
                        (block $done2
                          (loop $walk2
                            (br_if $done2 (ref.is_null (call $seq (local.get $cur))))
                            (if (i32.eqz (local.get $i))
                              (then
                                (local.set $cur (call $first (local.get $cur)))
                                (br $done2)))
                            (local.set $cur (call $rest (local.get $cur)))
                            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                            (br $walk2)))
                        (local.get $cur))
                      (else (ref.null none))))))))))))))

  ;; Keyword name table global (initialized in $start)
  (global $__kw_names (mut anyref) (ref.null none))
  ;; Runtime keyword creation support
  (global $__kw_next_id (mut i32) (i32.const 0))
  (global $__kw_runtime_list (mut anyref) (ref.null none))
  ;; Symbol helpers
  ;; sym_eq: compare two symbols by name + namespace
  (func $sym_eq (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $Symbol)) (local $sb (ref $Symbol))
    (local.set $sa (ref.cast (ref $Symbol) (local.get $a)))
    (local.set $sb (ref.cast (ref $Symbol) (local.get $b)))
    ;; Fast path: same ID and both >= 0
    (if (i32.and (i32.ge_s (struct.get $Symbol $id (local.get $sa)) (i32.const 0))
                 (i32.eq (struct.get $Symbol $id (local.get $sa))
                         (struct.get $Symbol $id (local.get $sb))))
      (then (return (i32.const 1))))
    ;; Compare name strings
    (if (i32.eqz (call $str_eq (struct.get $Symbol $name (local.get $sa))
                                (struct.get $Symbol $name (local.get $sb))))
      (then (return (i32.const 0))))
    ;; Names match - compare namespaces
    (if (i32.and (ref.is_null (struct.get $Symbol $ns (local.get $sa)))
                 (ref.is_null (struct.get $Symbol $ns (local.get $sb))))
      (then (return (i32.const 1))))
    (if (i32.or (ref.is_null (struct.get $Symbol $ns (local.get $sa)))
                (ref.is_null (struct.get $Symbol $ns (local.get $sb))))
      (then (return (i32.const 0))))
    (call $str_eq (struct.get $Symbol $ns (local.get $sa))
                   (struct.get $Symbol $ns (local.get $sb))))

  ;; sym_hash: hash a symbol by name content (+ namespace)
  (func $sym_hash (param $val anyref) (result i32)
    (local $s (ref $Symbol))
    (local $h i32)
    (local.set $s (ref.cast (ref $Symbol) (local.get $val)))
    (local.set $h (call $str_hash (struct.get $Symbol $name (local.get $s))))
    ;; Mix in namespace hash if present
    (if (i32.eqz (ref.is_null (struct.get $Symbol $ns (local.get $s))))
      (then
        (local.set $h (i32.add (i32.mul (local.get $h) (i32.const 31))
                                (call $str_hash (struct.get $Symbol $ns (local.get $s)))))))
    (call $hash_int (i32.add (local.get $h) (i32.const 0xcc9e2d51))))

  ;; symbol_to_str: convert symbol to string (ns/name or just name)
  (func $symbol_to_str (param $val anyref) (result anyref)
    (local $s (ref $Symbol))
    (local $slash (ref $CharArray))
    (local $slash_str anyref)
    (local.set $s (ref.cast (ref $Symbol) (local.get $val)))
    (if (result anyref) (ref.is_null (struct.get $Symbol $ns (local.get $s)))
      (then (struct.get $Symbol $name (local.get $s)))
      (else
        ;; Create ns/name string
        (local.set $slash (array.new $CharArray (i32.const 0) (i32.const 1)))
        (array.set $CharArray (local.get $slash) (i32.const 0) (i32.const 47))  ;; '/'
        (local.set $slash_str (struct.new $String (i32.const 3) (i32.const -1) (local.get $slash)))
        (call $str_concat (call $str_concat (struct.get $Symbol $ns (local.get $s)) (local.get $slash_str))
                          (struct.get $Symbol $name (local.get $s))))))

  ;; extract_ns: given a string like foo/bar, return foo. If no slash, return null.
  (func $extract_ns (param $s anyref) (result anyref)
    (local $src (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $slash_pos i32)
    (local $dst (ref $CharArray))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $src)))
    (local.set $slash_pos (i32.const -1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (i32.eq (array.get_u $CharArray (local.get $src) (local.get $i)) (i32.const 47))  ;; '/'
          (then (local.set $slash_pos (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (if (result anyref) (i32.lt_s (local.get $slash_pos) (i32.const 0))
      (then (ref.null none))
      (else
        (if (result anyref) (i32.le_s (local.get $slash_pos) (i32.const 0))
          (then (call $make_empty_str))
          (else
            (local.set $dst (array.new $CharArray (i32.const 0) (local.get $slash_pos)))
            (array.copy $CharArray $CharArray (local.get $dst) (i32.const 0) (local.get $src)
              (i32.const 0) (local.get $slash_pos))
            (struct.new $String (i32.const 3) (i32.const -1) (local.get $dst)))))))

  ;; namespace: get namespace of keyword or symbol
  (func $namespace (param $val anyref) (result anyref)
    ;; Symbol -> return ns field (may be null)
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
      (then (struct.get $Symbol $ns (ref.cast (ref $Symbol) (local.get $val))))
      (else
        ;; Keyword -> extract namespace from full name
        (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
          (then (call $extract_ns (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val))))))
          (else (ref.null none))))))

  ;; symbol: construct a symbol from a string, keyword, or symbol (1-arg)
  (func $symbol (param $arg anyref) (result anyref)
    (local $name_str anyref)
    (local $slash_idx i32)
    ;; nil -> throw
    (if (ref.is_null (local.get $arg))
      (then (throw $exn (call $str1 (call $make_empty_str)))))
    ;; Already a symbol -> return as-is
    (if (i32.eq (call $type_tag (local.get $arg)) (i32.const 4))
      (then (return (local.get $arg))))
    ;; Keyword -> create symbol with same name
    (if (i32.eq (call $type_tag (local.get $arg)) (i32.const 2))
      (then
        (local.set $name_str (call $name_fn (local.get $arg)))
        (return (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name_str) (ref.null none)))))
    ;; String -> check for ns/name format
    (local.set $name_str (call $str1 (local.get $arg)))
    (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name_str) (ref.null none)))

  ;; symbol2: construct a namespaced symbol from two strings (2-arg)
  (func $symbol2 (param $ns anyref) (param $name anyref) (result anyref)
    ;; If ns is nil, create symbol with just name (no namespace)
    (if (result anyref) (ref.is_null (local.get $ns))
      (then (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name) (ref.null none)))
      (else (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name) (local.get $ns)))))

  ;; keyword_from_string: create/lookup keyword from string name
  (func $keyword (param $name anyref) (result anyref)
    (local $i i32)
    (local $count i32)
    (local $current anyref)
    ;; If already a keyword, return as-is
    (if (i32.eq (call $type_tag (local.get $name)) (i32.const 2))
      (then (return (local.get $name))))
    ;; Search compile-time keyword table
    (if (i32.eqz (ref.is_null (global.get $__kw_names)))
      (then
        (local.set $count (call $array_length (global.get $__kw_names)))
        (local.set $i (i32.const 0))
        (block $found_ct
          (loop $search_ct
            (br_if $found_ct (i32.ge_s (local.get $i) (local.get $count)))
            (if (call $str_eq (local.get $name) (call $array_get (global.get $__kw_names) (local.get $i)))
              (then (return (struct.new $Keyword (i32.const 2) (local.get $i)))))

            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $search_ct)))))
    ;; Search runtime keyword list (cons pairs: (cons (cons name-str keyword) rest))
    (local.set $current (global.get $__kw_runtime_list))
    (block $found_rt
      (loop $search_rt
        (br_if $found_rt (ref.is_null (local.get $current)))
        (if (call $str_eq (local.get $name)
              (struct.get $Cons $first (ref.cast (ref $Cons)
                (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))
          (then (return
            (struct.get $Cons $rest (ref.cast (ref $Cons)
              (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $search_rt)))
    ;; Not found - create new keyword
    (local.set $current (struct.new $Keyword (i32.const 2) (global.get $__kw_next_id)))
    (global.set $__kw_next_id (i32.add (global.get $__kw_next_id) (i32.const 1)))
    ;; Add to runtime list: (cons (cons name keyword) existing-list)
    (global.set $__kw_runtime_list
      (call $cons (call $cons (local.get $name) (local.get $current))
                  (global.get $__kw_runtime_list)))
    (local.get $current))

  ;; keyword2: construct a namespaced keyword from two strings (2-arg)
  ;; Stub: ignores namespace, creates keyword from name only
  (func $keyword2 (param $ns anyref) (param $name anyref) (result anyref)
    ;; If ns is nil, just use name
    (if (result anyref) (ref.is_null (local.get $ns))
      (then (call $keyword (local.get $name)))
      (else (call $keyword (local.get $name)))))

  ;; Boolean constants (singleton instances)
  (global $__true (ref $Boolean) (struct.new $Boolean (i32.const 14) (i32.const 1)))
  (global $__false (ref $Boolean) (struct.new $Boolean (i32.const 14) (i32.const 0)))

  ;; bool: convert i32 to $Boolean (0 -> $__false, non-zero -> $__true)
  (func $bool (param $v i32) (result anyref)
    (if (result anyref) (local.get $v)
      (then (global.get $__true))
      (else (global.get $__false))))

  ;; Sentinel for hash_map_get_sentinel (distinguishes nil value from key-not-found)
  (global $__not_found_sentinel (ref $Keyword) (struct.new $Keyword (i32.const 2) (i32.const -999)))

  ;; ==========================================
  ;; Polymorphic contains? (maps + sets)
  ;; ==========================================
  (func $contains_QMARK_ (param $coll anyref) (param $key anyref) (result anyref)
    (local $tag i32) (local $root anyref)
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (global.get $__false))
      (else
        (local.set $tag (call $type_tag (local.get $coll)))
        (if (result anyref) (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 19)))
          (then (call $hash_map_contains_QMARK_ (local.get $coll) (local.get $key)))
          (else
            (if (result anyref) (i32.eq (local.get $tag) (i32.const 9))
              (then (call $set_contains_QMARK_ (local.get $coll) (local.get $key)))
              (else
                ;; Vector - check if index is in bounds (key must be i31 integer)
                (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
                  (then
                    (if (result anyref) (ref.test (ref i31) (local.get $key))
                      (then
                        (if (result anyref) (i32.and
                            (i32.ge_s (i31.get_s (ref.cast (ref i31) (local.get $key))) (i32.const 0))
                            (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $key)))
                                      (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $coll)))))
                          (then (global.get $__true))
                          (else (global.get $__false))))
                      (else (global.get $__false))))
                  (else
                    ;; TransientHashMap
                    (if (result anyref) (i32.eq (local.get $tag) (i32.const 16))
                      (then
                        (local.set $root (struct.get $TransientHashMap $array (ref.cast (ref $TransientHashMap) (local.get $coll))))
                        (if (result anyref) (ref.eq (ref.cast eqref
                            (call $hamt_get (local.get $root) (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
                            (global.get $__not_found_sentinel))
                          (then (global.get $__false))
                          (else (global.get $__true))))
                      (else
                        ;; TransientHashSet
                        (if (result anyref) (i32.eq (local.get $tag) (i32.const 17))
                          (then
                            (local.set $root (struct.get $TransientHashSet $array (ref.cast (ref $TransientHashSet) (local.get $coll))))
                            (if (result anyref) (ref.eq (ref.cast eqref
                                (call $hamt_get (local.get $root) (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
                                (global.get $__not_found_sentinel))
                              (then (global.get $__false))
                              (else (global.get $__true))))
                          (else
                            ;; Protocol fallback: user types implementing ILookup (defrecord etc.)
                            (if (result anyref) (call $truthy (call $__satisfies_ILookup (local.get $coll)))
                              (then
                                (if (result anyref) (ref.eq (ref.cast eqref
                                    (call $hash_map_get_default (local.get $coll) (local.get $key) (global.get $__not_found_sentinel)))
                                    (global.get $__not_found_sentinel))
                                  (then (global.get $__false))
                                  (else (global.get $__true))))
                              (else (global.get $__false))))))))))))))))

  ;; ==========================================
  ;; Polymorphic conj (vectors, lists, sets, maps, nil)
  ;; ==========================================
  (func $conj (param $coll anyref) (param $val anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> create a list
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (call $cons (local.get $val) (ref.null none)))
      (else
        ;; Vector -> append
        (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
          (then (call $vector_conj (local.get $coll) (local.get $val)))
          (else
            ;; Cons (list) -> prepend
            (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
              (then (call $cons (local.get $val) (local.get $coll)))
              (else
                ;; VectorSeq -> prepend (like a seq/list)
                (if (result anyref) (ref.test (ref $VectorSeq) (local.get $coll))
                  (then (call $cons (local.get $val) (local.get $coll)))
                  (else
                ;; HashSet -> add element
                (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
                  (then (call $set_conj (local.get $coll) (local.get $val)))
                  (else
                    ;; HashMap/ArrayMap -> assoc key-value pair (val must be a 2-element vector [k v])
                    (if (result anyref) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
                      (then (call $hash_map_assoc (local.get $coll)
                        (call $vector_nth (local.get $val) (i32.const 0))
                        (call $vector_nth (local.get $val) (i32.const 1))))
                      (else
                        ;; Protocol fallback for ICollection
                        (if (result anyref) (call $truthy (call $__satisfies_ICollection (local.get $coll)))
                          (then (call $__dispatch__conj (local.get $coll) (local.get $val)))
                          (else (call $vector_conj (local.get $coll) (local.get $val)))))))))))))))))

  ;; ==========================================
  ;; Polymorphic comparison (int + float)
  ;; ==========================================

  ;; Helper to extract numeric value as f64
  (func $to_f64 (param $val anyref) (result f64)
    (if (result f64) (ref.test (ref i31) (local.get $val))
      (then (f64.convert_i32_s (i31.get_s (ref.cast (ref i31) (local.get $val)))))
      (else
        (if (result f64) (ref.test (ref $Float) (local.get $val))
          (then (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))))
          (else (f64.const 0))))))

  (func $cmp_lt (param $a anyref) (param $b anyref) (result anyref)
    ;; Both i31ref -> fast path
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.lt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  (func $cmp_gt (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.gt_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.gt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  (func $cmp_le (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.le_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.le (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  (func $cmp_ge (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.ge_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.ge (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  ;; zero?: polymorphic (works on int and float)
  (func $zero_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $val))
      (then (if (result anyref) (i32.eqz (i31.get_s (ref.cast (ref i31) (local.get $val))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else
        (if (result anyref) (ref.test (ref $Float) (local.get $val))
          (then (if (result anyref) (f64.eq (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))) (f64.const 0))
            (then (global.get $__true)) (else (global.get $__false))))
          (else (global.get $__false))))))

  ;; ==========================================
  ;; Three-way compare (returns -1, 0, or 1 as i31ref)
  ;; Flat style to avoid deep nesting
  ;; ==========================================
  (func $__compare (param $a anyref) (param $b anyref) (result anyref)
    (local $result i32)
    (local $ia i32) (local $ib i32)
    (local.set $result (i32.const 0))
    (block $done
      ;; nil cases
      (if (ref.is_null (local.get $a))
        (then
          (if (ref.is_null (local.get $b))
            (then (br $done))
            (else (local.set $result (i32.const -1)) (br $done)))))
      (if (ref.is_null (local.get $b))
        (then (local.set $result (i32.const 1)) (br $done)))
      ;; Both i31ref (integers)
      (if (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
        (then
          (local.set $ia (i31.get_s (ref.cast (ref i31) (local.get $a))))
          (local.set $ib (i31.get_s (ref.cast (ref i31) (local.get $b))))
          (if (i32.lt_s (local.get $ia) (local.get $ib))
            (then (local.set $result (i32.const -1)))
            (else (if (i32.gt_s (local.get $ia) (local.get $ib))
              (then (local.set $result (i32.const 1))))))
          (br $done)))
      ;; Keywords: compare by name string (lexicographic, like Clojure)
      (if (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 2)) (i32.eq (call $type_tag (local.get $b)) (i32.const 2)))
        (then
          (local.set $result (i31.get_s (ref.cast (ref i31) (call $__compare_strings
            (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $a))))
            (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $b))))))))
          (br $done)))
      ;; Strings: byte-by-byte comparison
      (if (i32.and (ref.test (ref $String) (local.get $a)) (ref.test (ref $String) (local.get $b)))
        (then
          (local.set $result (i31.get_s (ref.cast (ref i31) (call $__compare_strings (local.get $a) (local.get $b)))))
          (br $done)))
      ;; Symbols: compare by name string (lexicographic)
      (if (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 4)) (i32.eq (call $type_tag (local.get $b)) (i32.const 4)))
        (then
          (local.set $result (i31.get_s (ref.cast (ref i31) (call $__compare_strings
            (struct.get $Symbol $name (ref.cast (ref $Symbol) (local.get $a)))
            (struct.get $Symbol $name (ref.cast (ref $Symbol) (local.get $b)))))))
          (br $done)))
      ;; Float/mixed numeric: compare as f64
      (if (f64.lt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (local.set $result (i32.const -1)))
        (else (if (f64.gt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
          (then (local.set $result (i32.const 1)))))))
    (ref.i31 (local.get $result)))

  ;; String comparison helper
  (func $__compare_strings (param $a anyref) (param $b anyref) (result anyref)
    (local $data_a (ref $CharArray))
    (local $data_b (ref $CharArray))
    (local $len_a i32) (local $len_b i32) (local $min_len i32)
    (local $i i32) (local $ca i32) (local $cb i32)
    (local $result i32)
    (local.set $data_a (struct.get $String $data (ref.cast (ref $String) (local.get $a))))
    (local.set $data_b (struct.get $String $data (ref.cast (ref $String) (local.get $b))))
    (local.set $len_a (array.len (local.get $data_a)))
    (local.set $len_b (array.len (local.get $data_b)))
    (local.set $min_len (if (result i32) (i32.lt_s (local.get $len_a) (local.get $len_b))
      (then (local.get $len_a)) (else (local.get $len_b))))
    (local.set $i (i32.const 0))
    (local.set $result (i32.const 0))
    (block $done
      (loop $cmp
        (br_if $done (i32.ge_s (local.get $i) (local.get $min_len)))
        (local.set $ca (array.get_s $CharArray (local.get $data_a) (local.get $i)))
        (local.set $cb (array.get_s $CharArray (local.get $data_b) (local.get $i)))
        (if (i32.lt_s (local.get $ca) (local.get $cb))
          (then (local.set $result (i32.const -1)) (br $done)))
        (if (i32.gt_s (local.get $ca) (local.get $cb))
          (then (local.set $result (i32.const 1)) (br $done)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cmp))
      ;; All bytes equal up to min_len, compare lengths
      (if (i32.lt_s (local.get $len_a) (local.get $len_b))
        (then (local.set $result (i32.const -1)))
        (else (if (i32.gt_s (local.get $len_a) (local.get $len_b))
          (then (local.set $result (i32.const 1)))))))
    (ref.i31 (local.get $result)))

  ;; ==========================================
  ;; Array helpers (WasmGC $AnyArray interop)
  ;; ==========================================

  ;; aset: sets array element and returns the value
  (func $__aset (param $arr anyref) (param $i i32) (param $v anyref) (result anyref)
    (array.set $AnyArray (ref.cast (ref $AnyArray) (local.get $arr)) (local.get $i) (local.get $v))
    (local.get $v))

  ;; aclone: create a copy of an array
  (func $__aclone (param $arr anyref) (result anyref)
    (local $src (ref $AnyArray))
    (local $len i32)
    (local $dst (ref $AnyArray))
    (local.set $src (ref.cast (ref $AnyArray) (local.get $arr)))
    (local.set $len (array.len (local.get $src)))
    (local.set $dst (array.new_default $AnyArray (local.get $len)))
    (array.copy $AnyArray $AnyArray (local.get $dst) (i32.const 0) (local.get $src) (i32.const 0) (local.get $len))
    (local.get $dst))

  ;; object_array: convert a seq/vector to a WasmGC array
  (func $__object_array (param $coll anyref) (result anyref)
    (local $len i32)
    (local $arr (ref $AnyArray))
    (local $i i32)
    (local $s anyref)
    ;; Get count
    (local.set $len (call $count_internal (local.get $coll)))
    (local.set $arr (array.new_default $AnyArray (local.get $len)))
    ;; Iterate via seq
    (local.set $s (call $seq (local.get $coll)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $fill
        (br_if $done (ref.is_null (local.get $s)))
        (array.set $AnyArray (local.get $arr) (local.get $i) (call $first (local.get $s)))
        (local.set $s (call $rest (local.get $s)))
        (local.set $s (call $seq (local.get $s)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $fill)))
    (local.get $arr))

  ;; ==========================================
  ;; Mixed arithmetic (int + float)
  ;; ==========================================
  (func $add (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a)))
                               (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.add (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  (func $sub (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $a)))
                               (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.sub (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  (func $mul (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $a)))
                               (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.mul (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  (func $div (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                  (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.div (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  ;; inc/dec: polymorphic
  (func $inc (param $a anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $a))
      (then (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a))) (i32.const 1))))
      (else (struct.new $Float (i32.const 5) (f64.add (call $to_f64 (local.get $a)) (f64.const 1))))))

  (func $dec (param $a anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $a))
      (then (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $a))) (i32.const 1))))
      (else (struct.new $Float (i32.const 5) (f64.sub (call $to_f64 (local.get $a)) (f64.const 1))))))

  ;; ==========================================
  ;; Variadic swap! (swap! a f x y ...)
  ;; ==========================================
  (func $swap_BANG_2 (param $a anyref) (param $f anyref) (param $x anyref) (result anyref)
    (local $atom (ref $Atom)) (local $old anyref) (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke2 (local.get $f) (local.get $old) (local.get $x)))
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  (func $swap_BANG_3 (param $a anyref) (param $f anyref) (param $x anyref) (param $y anyref) (result anyref)
    (local $atom (ref $Atom)) (local $old anyref) (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke3 (local.get $f) (local.get $old) (local.get $x) (local.get $y)))
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  (func $swap_BANG_4 (param $a anyref) (param $f anyref) (param $x anyref) (param $y anyref) (param $z anyref) (result anyref)
    (local $atom (ref $Atom)) (local $old anyref) (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke4 (local.get $f) (local.get $old) (local.get $x) (local.get $y) (local.get $z)))
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  ;; ==========================================
  ;; Float to string (proper decimal conversion)
  ;; ==========================================
  (func $float_to_str (param $f f64) (result anyref)
    (local $int_part i32)
    (local $frac f64)
    (local $neg i32)
    (local $abs f64)
    (local $int_str anyref)
    (local $dot_str anyref)
    (local $frac_str anyref)
    (local $digit i32)
    (local $buf (ref $CharArray))
    (local $pos i32)
    (local $i i32)
    ;; Handle negative
    (local.set $neg (f64.lt (local.get $f) (f64.const 0)))
    (local.set $abs (if (result f64) (local.get $neg)
      (then (f64.neg (local.get $f)))
      (else (local.get $f))))
    ;; Get integer part
    (local.set $int_part (i32.trunc_f64_s (local.get $abs)))
    ;; Get fractional part
    (local.set $frac (f64.sub (local.get $abs) (f64.convert_i32_s (local.get $int_part))))
    ;; Convert integer part (with sign)
    (local.set $int_str (call $int_to_str (if (result i32) (local.get $neg)
      (then (i32.sub (i32.const 0) (local.get $int_part)))
      (else (local.get $int_part)))))
    ;; Build decimal digits (up to 6 digits, strip trailing zeros)
    (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 6)))
    (local.set $pos (i32.const 0))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (i32.const 6)))
        (local.set $frac (f64.mul (local.get $frac) (f64.const 10)))
        (local.set $digit (i32.trunc_f64_s (local.get $frac)))
        (local.set $frac (f64.sub (local.get $frac) (f64.convert_i32_s (local.get $digit))))
        (array.set $CharArray (local.get $buf) (local.get $i) (i32.add (i32.const 48) (local.get $digit)))
        (local.set $pos (i32.add (local.get $i) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Strip trailing zeros (but keep at least 1 digit)
    (block $strip_done
      (loop $strip
        (br_if $strip_done (i32.le_s (local.get $pos) (i32.const 1)))
        (br_if $strip_done (i32.ne (array.get_u $CharArray (local.get $buf) (i32.sub (local.get $pos) (i32.const 1))) (i32.const 48)))
        (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
        (br $strip)))
    ;; Build dot + frac string
    (local.set $dot_str (struct.new $String (i32.const 3) (i32.const -1)
      (block (result (ref $CharArray))
        (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 1)))
        (array.set $CharArray (local.get $buf) (i32.const 0) (i32.const 46))
        (local.get $buf))))
    (local.set $frac_str (struct.new $String (i32.const 3) (i32.const -1)
      (block (result (ref $CharArray))
        (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 6)))
        (local.set $i (i32.const 0))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.ge_s (local.get $i) (local.get $pos)))
            ;; Recalculate the digits
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop2)))
        (local.get $buf))))
    ;; Simpler approach: just concat int_str + dot + digits
    (call $str_concat (call $str_concat (local.get $int_str) (local.get $dot_str))
      (call $int_to_str_frac (local.get $f))))

  ;; Helper: format fractional part of float
  (func $int_to_str_frac (param $f f64) (result anyref)
    (local $abs f64)
    (local $int_part i32)
    (local $frac f64)
    (local $buf (ref $CharArray))
    (local $pos i32)
    (local $digit i32)
    (local $result (ref $CharArray))
    (local $i i32)
    (local.set $abs (if (result f64) (f64.lt (local.get $f) (f64.const 0))
      (then (f64.neg (local.get $f)))
      (else (local.get $f))))
    (local.set $int_part (i32.trunc_f64_s (local.get $abs)))
    (local.set $frac (f64.sub (local.get $abs) (f64.convert_i32_s (local.get $int_part))))
    ;; Generate up to 6 fractional digits
    (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 6)))
    (local.set $pos (i32.const 0))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (i32.const 6)))
        (local.set $frac (f64.mul (local.get $frac) (f64.const 10)))
        (local.set $digit (i32.trunc_f64_s (local.get $frac)))
        (local.set $frac (f64.sub (local.get $frac) (f64.convert_i32_s (local.get $digit))))
        (array.set $CharArray (local.get $buf) (local.get $i) (i32.add (i32.const 48) (local.get $digit)))
        (local.set $pos (i32.add (local.get $i) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Strip trailing zeros (keep at least 1)
    (block $strip_done
      (loop $strip
        (br_if $strip_done (i32.le_s (local.get $pos) (i32.const 1)))
        (br_if $strip_done (i32.ne (array.get_u $CharArray (local.get $buf) (i32.sub (local.get $pos) (i32.const 1))) (i32.const 48)))
        (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
        (br $strip)))
    ;; Copy to right-sized array
    (local.set $result (array.new $CharArray (i32.const 0) (local.get $pos)))
    (array.copy $CharArray $CharArray (local.get $result) (i32.const 0) (local.get $buf) (i32.const 0) (local.get $pos))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $result)))")

(defn emit-prelude-3c []
  "
  ;; ==========================================
  ;; pr-str1: EDN-safe printing of a single value
  ;; Unlike str1, this quotes strings, prints nil as the word nil,
  ;; and recursively prints collections.
  ;; ==========================================

  ;; pr_str1: convert any value to its EDN string representation
  (func $pr_str1 (param $val anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $val (call $unwrap_meta (local.get $val)))
    ;; nil -> nil literal string
    (if (result anyref) (ref.is_null (local.get $val))
      (then (call $pr_str_literal_nil))
      (else
        ;; String -> quoted with escapes
        (if (result anyref) (ref.test (ref $String) (local.get $val))
          (then (call $pr_str_string (local.get $val)))
          (else
            ;; i31ref (integer) -> decimal string (same as str1)
            (if (result anyref) (ref.test (ref i31) (local.get $val))
              (then (call $int_to_str (i31.get_s (ref.cast (ref i31) (local.get $val)))))
              (else
                ;; Keyword -> :name (same as str1)
                (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
                  (then (call $keyword_to_str (local.get $val)))
                  (else
                    ;; Boolean -> true/false (same as str1)
                    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
                      (then
                        (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
                          (then (call $str1_true))
                          (else (call $str1_false))))
                      (else
                        ;; Float -> decimal string (same as str1)
                        (if (result anyref) (ref.test (ref $Float) (local.get $val))
                          (then (call $float_to_str
                            (struct.get $Float $val (ref.cast (ref $Float) (local.get $val)))))
                          (else
                            ;; Vector -> [elem1 elem2 ...]
                            (if (result anyref) (ref.test (ref $Vector) (local.get $val))
                              (then (call $pr_str_vector (local.get $val)))
                              (else
                                ;; HashMap/ArrayMap -> {:k1 v1, :k2 v2}
                                (if (result anyref) (i32.or (i32.eq (call $type_tag (local.get $val)) (i32.const 8)) (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
                                  (then (call $pr_str_map (local.get $val)))
                                  (else
                                    ;; HashSet -> #{elem1 elem2}
                                    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 9))
                                      (then (call $pr_str_set (local.get $val)))
                                      (else
                                        ;; Cons (list) -> (elem1 elem2 ...)
                                        (if (result anyref) (ref.test (ref $Cons) (local.get $val))
                                          (then (call $pr_str_list (local.get $val)))
                                          (else
                                            ;; Symbol -> ns/name or just name
                                            (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
                                              (then (call $symbol_to_str (local.get $val)))
                                              (else
                                                ;; LazySeq -> realize and print as list
                                                (if (result anyref) (ref.test (ref $LazySeq) (local.get $val))
                                                  (then (call $pr_str_list (call $seq (local.get $val))))
                                                  (else
                                                    ;; VectorSeq -> print as list
                                                    (if (result anyref) (ref.test (ref $VectorSeq) (local.get $val))
                                                      (then (call $pr_str_vectorseq (local.get $val)))
                                                      (else
                                                        ;; Unknown -> nil placeholder
                                                        (call $pr_str_literal_nil))))))))))))))))))))))))))))

  ;; pr_str_literal_nil: return the 3-char string nil
  (func $pr_str_literal_nil (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 3)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 110))  ;; 'n'
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 105))  ;; 'i'
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 108))  ;; 'l'
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; pr_str_string: quote a string with escape sequences
  ;; hello -> backslash-quoted hello, handles backslash, quote, newline, tab
  (func $pr_str_string (param $s anyref) (result anyref)
    (local $src (ref $CharArray))
    (local $src_len i32)
    (local $i i32)
    (local $ch i32)
    (local $extra i32)
    (local $dst (ref $CharArray))
    (local $dst_len i32)
    (local $j i32)
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $src_len (array.len (local.get $src)))
    ;; First pass: count extra chars needed for escaping
    (local.set $extra (i32.const 0))
    (local.set $i (i32.const 0))
    (block $count_done
      (loop $count_loop
        (br_if $count_done (i32.ge_s (local.get $i) (local.get $src_len)))
        (local.set $ch (array.get_u $CharArray (local.get $src) (local.get $i)))
        ;; Count extra char for escapable chars (backslash, quote, newline, tab)
        (if (i32.or (i32.or (i32.eq (local.get $ch) (i32.const 92))   ;; backslash
                            (i32.eq (local.get $ch) (i32.const 34)))  ;; quote
                    (i32.or (i32.eq (local.get $ch) (i32.const 10))   ;; newline
                            (i32.eq (local.get $ch) (i32.const 9))))  ;; tab
          (then (local.set $extra (i32.add (local.get $extra) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $count_loop)))
    ;; Allocate: src_len + extra + 2 (for surrounding quotes)
    (local.set $dst_len (i32.add (i32.add (local.get $src_len) (local.get $extra)) (i32.const 2)))
    (local.set $dst (array.new $CharArray (i32.const 0) (local.get $dst_len)))
    ;; Opening quote
    (array.set $CharArray (local.get $dst) (i32.const 0) (i32.const 34))
    ;; Second pass: copy with escaping
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 1))
    (block $copy_done
      (loop $copy_loop
        (br_if $copy_done (i32.ge_s (local.get $i) (local.get $src_len)))
        (local.set $ch (array.get_u $CharArray (local.get $src) (local.get $i)))
        ;; Check for special chars
        (if (i32.eq (local.get $ch) (i32.const 92))  ;; backslash
          (then
            (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
            (local.set $j (i32.add (local.get $j) (i32.const 1))))
          (else (if (i32.eq (local.get $ch) (i32.const 34))  ;; quote
            (then
              (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
              (local.set $j (i32.add (local.get $j) (i32.const 1)))
              (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 34))
              (local.set $j (i32.add (local.get $j) (i32.const 1))))
            (else (if (i32.eq (local.get $ch) (i32.const 10))  ;; newline
              (then
                (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 110))  ;; 'n'
                (local.set $j (i32.add (local.get $j) (i32.const 1))))
              (else (if (i32.eq (local.get $ch) (i32.const 9))  ;; tab
                (then
                  (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
                  (local.set $j (i32.add (local.get $j) (i32.const 1)))
                  (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 116))  ;; 't'
                  (local.set $j (i32.add (local.get $j) (i32.const 1))))
                (else
                  ;; Regular char
                  (array.set $CharArray (local.get $dst) (local.get $j) (local.get $ch))
                  (local.set $j (i32.add (local.get $j) (i32.const 1)))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $copy_loop)))
    ;; Closing quote
    (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 34))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $dst)))

  ;; pr_str_vector: format vector as [elem1 elem2 ...]
  (func $pr_str_vector (param $v anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $cnt i32)
    (local $i i32)
    (local $result anyref)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $cnt (struct.get $Vector $count (local.get $vec)))
    ;; Start with open bracket
    (local.set $result (call $pr_str_char (i32.const 91)))  ;; '['
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $cnt)))
        ;; Add space separator (not before first)
        (if (i32.gt_s (local.get $i) (i32.const 0))
          (then (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $v) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Close with bracket
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 93))))

  ;; pr_str_list: format cons list as (elem1 elem2 ...)
  (func $pr_str_list (param $lst anyref) (result anyref)
    (local $result anyref)
    (local $current anyref)
    (local $first i32)
    (local.set $result (call $pr_str_char (i32.const 40)))  ;; '('
    (local.set $current (local.get $lst))
    (local.set $first (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $current)))
        (br_if $done (i32.eqz (ref.test (ref $Cons) (local.get $current))))
        ;; Add space separator (not before first)
        (if (local.get $first)
          (then (local.set $first (i32.const 0)))
          (else (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $loop)))
    ;; Close with paren
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 41))))

  ;; pr_str_vectorseq: format VectorSeq as (elem1 elem2 ...)
  (func $pr_str_vectorseq (param $vs anyref) (result anyref)
    (local $result anyref)
    (local $vseq (ref $VectorSeq))
    (local $vec anyref)
    (local $i i32)
    (local $count i32)
    (local.set $vseq (ref.cast (ref $VectorSeq) (local.get $vs)))
    (local.set $vec (struct.get $VectorSeq $vec (local.get $vseq)))
    (local.set $i (struct.get $VectorSeq $offset (local.get $vseq)))
    (local.set $count (call $vector_count (local.get $vec)))
    (local.set $result (call $pr_str_char (i32.const 40)))  ;; '('
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        ;; Add space separator (not before first)
        (if (i32.gt_s (local.get $i) (struct.get $VectorSeq $offset (local.get $vseq)))
          (then (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $vec) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Close with paren
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 41))))

  ;; pr_str_map: format map as {:k1 v1, :k2 v2}
  (func $pr_str_map (param $m anyref) (result anyref)
    (local $result anyref)
    (local $entries anyref)
    (local $entry anyref)
    (local $first i32)
    (local.set $result (call $pr_str_char (i32.const 123)))  ;; '{'
    ;; seq on map gives cons list of [k v] vectors
    (local.set $entries (call $seq (local.get $m)))
    (local.set $first (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $entries)))
        (br_if $done (i32.eqz (ref.test (ref $Cons) (local.get $entries))))
        ;; Add comma-space separator (not before first)
        (if (local.get $first)
          (then (local.set $first (i32.const 0)))
          (else (local.set $result (call $str_concat (local.get $result)
            (call $pr_str_2char (i32.const 44) (i32.const 32))))))  ;; comma-space
        ;; Each entry is a [k v] vector
        (local.set $entry (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $entries))))
        ;; key
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $entry) (i32.const 0)))))
        ;; space
        (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))
        ;; value
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $entry) (i32.const 1)))))
        (local.set $entries (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $entries))))
        (br $loop)))
    ;; Close with brace
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 125))))

  ;; pr_str_set: format set as #{elem1 elem2}
  (func $pr_str_set (param $s anyref) (result anyref)
    (local $result anyref)
    (local $entries anyref)
    (local $first i32)
    ;; Start with hash-brace
    (local.set $result (call $pr_str_2char (i32.const 35) (i32.const 123)))  ;; hash-brace
    ;; seq on set gives cons list of elements
    (local.set $entries (call $seq (local.get $s)))
    (local.set $first (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $entries)))
        (br_if $done (i32.eqz (ref.test (ref $Cons) (local.get $entries))))
        ;; Add space separator (not before first)
        (if (local.get $first)
          (then (local.set $first (i32.const 0)))
          (else (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $entries))))))
        (local.set $entries (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $entries))))
        (br $loop)))
    ;; Close with brace
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 125))))

  ;; pr_str_char: make single-char string from ASCII code
  (func $pr_str_char (param $ch i32) (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $data) (i32.const 0) (local.get $ch))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; pr_str_2char: make 2-char string from two ASCII codes
  (func $pr_str_2char (param $c1 i32) (param $c2 i32) (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 2)))
    (array.set $CharArray (local.get $data) (i32.const 0) (local.get $c1))
    (array.set $CharArray (local.get $data) (i32.const 1) (local.get $c2))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))
")

(defn- emit-user-type-defs []
  "Generate WasmGC struct type definitions for user-defined types.
   All user types extend $Tagged with $__type_id as first field."
  (if (empty? *user-types*)
    ""
    (str "\n\n  ;; User-defined types\n"
         (str-join "\n"
                   (for [[type-name {:keys [fields]}] *user-types*]
                     (let [munged (munge-name type-name)
                           field-decls (str-join " " (mapv (fn [f] (str "(field $" (munge-name f) " anyref)")) fields))]
                       (str "  (type $" munged " (sub $Tagged (struct (field $__type_id i32) " field-decls ")))")))))))

(defn- emit-user-type-tag-branches []
  "Generate type_tag branches for user-defined types.
   Since all types (built-in and user) now extend $Tagged, this is handled
   by the $Tagged cast in type_tag itself. No separate user-type branches needed."
  ;; All types extend $Tagged, so the main type_tag function handles everything
  ;; via (struct.get $Tagged $__type_id (ref.cast (ref $Tagged) val))
  "(i32.const -1)")

(defn- emit-user-type-eq-code []
  "Generate WAT equality-checking code for user-defined types.
   Produces nested if/else checking type tags, then structurally comparing all fields."
  (if (empty? *user-types*)
    "(i32.const 0)"
    (let [type-entries (seq *user-types*)
          gen-eq (fn [[type-name {:keys [tag fields]}]]
                   (let [munged (munge-name type-name)
                         field-eqs (map (fn [f]
                                          (let [mf (munge-name f)]
                                            (str "(call $eq "
                                                 "(struct.get $" munged " $" mf " (ref.cast (ref $" munged ") (local.get $a))) "
                                                 "(struct.get $" munged " $" mf " (ref.cast (ref $" munged ") (local.get $b))))")))
                                        fields)
                         combined (cond
                                    (empty? field-eqs) "(i32.const 1)"
                                    (= 1 (count field-eqs)) (first field-eqs)
                                    :else (reduce (fn [acc eq]
                                                    (str "(i32.and " acc " " eq ")"))
                                                  (first field-eqs)
                                                  (rest field-eqs)))]
                     {:tag tag :eq-expr combined}))]
      (reduce (fn [fallback {:keys [tag eq-expr]}]
                (str "(if (result i32) (i32.and "
                     "(i32.eq (call $type_tag (local.get $a)) (i32.const " tag ")) "
                     "(i32.eq (call $type_tag (local.get $b)) (i32.const " tag "))) "
                     "(then " eq-expr ") "
                     "(else " fallback "))"))
              "(i32.const 0)"
              (reverse (map gen-eq type-entries))))))

(defn- emit-user-type-hash-code []
  "Generate WAT hashing code for user-defined types.
   For each type, combines tag and field hashes: hash = ((tag*31 + hash(f1))*31 + hash(f2))..."
  (if (empty? *user-types*)
    "(i32.const 31)"
    (let [type-entries (seq *user-types*)
          gen-hash (fn [[type-name {:keys [tag fields]}]]
                     (let [munged (munge-name type-name)
                           hash-expr (reduce
                                      (fn [acc f]
                                        (let [mf (munge-name f)]
                                          (str "(i32.add (i32.mul (i32.const 31) " acc ") "
                                               "(call $hash (struct.get $" munged " $" mf
                                               " (ref.cast (ref $" munged ") (local.get $val)))))")))
                                      (str "(i32.const " tag ")")
                                      fields)]
                       {:tag tag :hash-expr hash-expr}))]
      (reduce (fn [fallback {:keys [tag hash-expr]}]
                (str "(if (result i32) (i32.eq (call $type_tag (local.get $val)) (i32.const " tag ")) "
                     "(then " hash-expr ") "
                     "(else " fallback "))"))
              "(i32.const 31)"
              (reverse (map gen-hash type-entries))))))

(defn- emit-user-predicate-checks
  "Generate i32 check expression for user types that extend a given protocol method.
   Returns an i32 expression, or (i32.const 0) if no user types match.
   Only includes user-defined type tags (>= 20) to avoid false positives with builtins."
  [method-name]
  (let [;; Find user type tags (>= 20) that implement the given method
        user-tags (->> (keys *protocol-impls*)
                       (filter (fn [k] (= (nth k 1) method-name)))
                       (map first)
                       (filter #(>= % 20))
                       distinct
                       vec)]
    (if (empty? user-tags)
      "(i32.const 0)"
      (reduce (fn [acc tag]
                (str "(i32.or " acc " (i32.eq (call $type_tag (local.get $val)) (i32.const " tag ")))"))
              (str "(i32.eq (call $type_tag (local.get $val)) (i32.const " (first user-tags) "))")
              (rest user-tags)))))

(defn emit-prelude []
  (let [host-import-section (if (seq *host-imports*)
                              (str "\n  ;; Host imports\n  " (str-join "\n  " *host-imports*))
                              "")
        base (str (emit-prelude-1) (emit-user-type-defs) (emit-prelude-2) (emit-prelude-2a) (emit-prelude-transient) (emit-prelude-2b) (emit-prelude-3) (emit-prelude-3b) (emit-prelude-3c))]
    ;; Replace all placeholders
    (-> base
        (string/replace "__HOST_IMPORTS__" host-import-section)
        (string/replace "__USER_TYPE_TAGS__"
                        (if (empty? *user-types*) "(i32.const -1)" (emit-user-type-tag-branches)))
        (string/replace "__USER_TYPE_EQ__"
                        (emit-user-type-eq-code))
        (string/replace "__USER_TYPE_HASH__"
                        (emit-user-type-hash-code))
        (string/replace "__USER_COUNTED__"
                        (emit-user-predicate-checks (symbol "-count")))
        (string/replace "__USER_MAP__"
                        (emit-user-predicate-checks (symbol "-assoc"))))))

(defn emit-module [ast-forms]
  (binding [*functions* []
            *globals-emit* []
            *globals-declared* #{}
            *fn-counter* 0
            *loop-counter* 0
            *closure-funcs* []
            *emitted-fn-names* #{"$float_QMARK_"}
            *host-imports* []
            *host-import-fns* #{}
            *protocols* {}
            *protocol-methods* {}
            *protocol-impls* {}
            *lifted-fn-inits* []]
  ;; Pre-scan: populate *internal-fn-names* for all exported functions
  ;; so cross-namespace calls can resolve to _internal names regardless of emit order
    (doseq [form ast-forms]
      (when (= (:op form) :def)
        (let [init-op (:op (:init form))]
          (cond
            ;; Host import: pre-register in *host-import-fns*
            (= init-op :host-import)
            (let [munged (munge-name (:name form))]
              (set! *host-import-fns* (conj *host-import-fns* munged)))

            ;; Normal function
            (= init-op :fn)
            (let [arities (get-in form [:init :arities])
                  fname (:name form)
                  munged (munge-name fname)]
              (if (and arities (> (count arities) 1))
                ;; Multi-arity: register each arity's internal name
                (doseq [arity-info arities]
                  (let [arity-suffix (if (:variadic? arity-info)
                                       "_variadic"
                                       (str "_arity" (:arity arity-info)))
                        full-munged (str munged arity-suffix)]
                    (set! *internal-fn-names* (assoc *internal-fn-names* full-munged (str full-munged "_internal")))))
                ;; Single arity: register standard internal name
                (set! *internal-fn-names* (assoc *internal-fn-names* munged (str munged "_internal")))))))))
    (let [init-code (into [] (filter some? (map emit-str ast-forms)))
        ;; Generate builtin wrappers for any builtins used as values
          builtin-wrappers (when (seq *builtin-refs*)
                             (let [;; Map builtin-arities locally
                                   arities {'inc 1, 'dec 1, 'not 1, 'neg? 1, 'pos? 1, 'zero? 1, 'NaN? 1,
                                            'first 1, 'rest 1, 'nil? 1, 'cons? 1, 'count 1, 'vector? 1, 'map? 1,
                                            'list? 1, 'keyword? 1, 'number? 1, 'integer? 1, 'fn? 1,
                                            'coll? 1, 'sequential? 1, 'associative? 1, 'counted? 1, 'indexed? 1,
                                            'true? 1, 'false? 1, 'some? 1,
                                            'string? 1, 'symbol? 1, 'float? 1, 'symbol 1, 'symbol2 2, 'namespace 1,
                                            'seq 1, 'seq? 1, 'seqable? 1, 'empty? 1,
                                            'set? 1, 'empty-hash-set 0,
                                            'keys 1, 'vals 1,
                                            'atom 1, 'deref 1, 'atom? 1,
                                            'num 1, 'type 1,
                                            '+ 2, '- 2, '* 2, '/ 2, '= 2, 'not= 2, '< 2, '> 2, '<= 2, '>= 2,
                                            'and 2, 'or 2, 'cons 2, 'nth 2, 'conj 2, 'get 2, 'contains? 2,
                                            'reset! 2, 'swap! 2, 'apply 2,
                                            'dissoc 2, 'disj 2, 'set-conj 2,
                                            'assoc 3, 'assoc-map 3,
                                            'reduce 3, 'reduce-kv 3, 'reduced 1, 'reduced? 1,
                                            'make-lazy-seq 1, 'lazy-seq? 1, 'lazy-seq-realized? 1,
                                            'str1 1, 'str-concat 2, 'name 1, 'subs 3, 'string->mem! 2, 'mem->string 2, 'pr-str1 1, 'char 1,
                                            'keyword 1, 'keyword2 2,
                                         ;; Float operations
                                            'to-float 1, 'to-int 1, 'math-floor 1, 'math-ceil 1, 'math-sqrt 1,
                                            'math-abs 1, 'math-round 1,
                                            'empty-vector 0, 'empty-hash-map 0, 'make-array-map 2,
                                         ;; Bit operations
                                            'bit-and 2, 'bit-or 2, 'bit-xor 2, 'bit-not 1,
                                            'bit-shift-left 2, 'bit-shift-right 2,
                                            'unsigned-bit-shift-right 2, 'bit-test 2,
                                         ;; Compare
                                            'compare 2,
                                         ;; Array operations
                                            'make-array 1, 'aget 2, 'aset 3, 'alength 1,
                                            'aclone 1, 'acopy 5, 'object-array 1, 'array? 1,
                                            'vector-from-array 1,
                                         ;; Regex operations
                                            're-pattern 1, 'regex-pattern 1, 'regex? 1,
                                         ;; Hash
                                            'str-hash 1,
                                         ;; Transient operations
                                            'transient 1, 'persistent! 1,
                                            'conj! 2, 'assoc! 3, 'dissoc! 2, 'disj! 2, 'pop! 1}]
                               (for [builtin *builtin-refs*]
                                 (emit-builtin-wrapper builtin (get arities builtin)))))
        ;; Generate wrappers for user-defined functions used as values
          fn-wrappers (when (seq *fn-refs*)
                        (for [fn-name *fn-refs*]
                          (let [fn-info (get *direct-fn-globals* fn-name)
                                is-multi (and (map? fn-info)
                                              (or (> (count (:arities fn-info)) 1)
                                                  (:variadic? fn-info)))]
                            (if is-multi
                              (emit-multi-arity-fn-wrapper fn-name fn-info)
                              (let [arity (if (map? fn-info)
                                            (or (first (:arities fn-info)) (:min-arity fn-info) 0)
                                            (or fn-info 0))]
                                (emit-fn-wrapper fn-name arity))))))
        ;; Generate protocol impl closures
          proto-impl-closures (when (seq *protocol-impls*)
                                (generate-protocol-impl-closures *protocol-impls*))
        ;; Generate dispatch functions for each protocol method
        ;; For multi-arity methods, generate one dispatch per arity
          proto-dispatch-funcs (when (seq *protocol-methods*)
                                 (mapcat
                                  (fn [[method-name {:keys [arity arities]}]]
                                    (if (and arities (> (count arities) 1))
                                      ;; Multi-arity: generate dispatch per arity
                                      (for [[a _] arities
                                            :let [;; Multi-arity impls use [type-tag method arity] key
                                                  method-impls (filter (fn [[[_ m ar] _]]
                                                                        (and (= m method-name) (= ar a)))
                                                                       *protocol-impls*)
                                                  ;; Rekey to [type-tag method] for generate-dispatch-function
                                                  rekeyed (map (fn [[[tt m _a] v]] [[tt m] v]) method-impls)]]
                                        (when (seq rekeyed)
                                          (generate-dispatch-function
                                           (symbol (str (name method-name) "_arity_" a)) a rekeyed)))
                                      ;; Single-arity: original behavior
                                      (let [method-impls (filter (fn [[[_ m & _] _]] (= m method-name)) *protocol-impls*)]
                                        (when (seq method-impls)
                                          [(generate-dispatch-function method-name arity method-impls)]))))
                                  *protocol-methods*))
        ;; Generate satisfies? predicates for each protocol
          proto-satisfies-funcs (when (seq *protocols*)
                                  (for [[proto-name _] *protocols*
                                        :let [;; Get all impls for methods of this protocol
                                              proto-methods (set (map :name (:methods (get *protocols* proto-name))))
                                              proto-impls (filter (fn [entry] (contains? proto-methods (nth (first entry) 1))) *protocol-impls*)]]
                                    (generate-satisfies-function proto-name proto-impls)))
        ;; Generate stubs for core protocol methods/satisfies if not already defined
        ;; These are needed because the WAT prelude references them unconditionally
          core-proto-stubs
          (let [core-methods [[(symbol "-seq") 1 (symbol "ISeqable")]
                              [(symbol "-count") 1 (symbol "ICounted")]
                              [(symbol "-conj") 2 (symbol "ICollection")]
                              [(symbol "-lookup") 2 (symbol "ILookup")]
                              [(symbol "-assoc") 3 (symbol "IAssociative")]
                              [(symbol "-reduce-init") 3 (symbol "IReduce")]]
                dispatch-stubs (for [[method-name arity _] core-methods
                                     :when (not (contains? *protocol-methods* method-name))]
                                 (let [munged (munge-name method-name)
                                       fn-name (str "$__dispatch_" munged)
                                       param-decls (str-join " " (for [i (range arity)]
                                                                   (str "(param $arg" i " anyref)")))]
                                   (str "(func " fn-name " " param-decls " (result anyref)\n"
                                        "    (unreachable))")))
                satisfies-stubs (for [[_ _ proto-name] core-methods
                                      :when (not (contains? *protocols* proto-name))]
                                  (let [munged (munge-name proto-name)
                                        fn-name (str "$__satisfies_" munged)]
                                    (str "(func " fn-name " (param $val anyref) (result anyref)\n"
                                         "    (global.get $__false))")))]
            (concat (distinct dispatch-stubs) (distinct satisfies-stubs)))
          prelude (emit-prelude)
        ;; Add builtin and fn wrapper globals
          builtin-globals (when (seq builtin-wrappers)
                            (map :global-decl builtin-wrappers))
          fn-globals (when (seq fn-wrappers)
                       (map :global-decl fn-wrappers))
          proto-globals (when (seq proto-impl-closures)
                          (map :global-decl proto-impl-closures))
        ;; Generate string constant globals and init code
          string-entries (sort-by val *strings*)  ;; sorted by id
          string-globals (for [[s id] string-entries]
                           (str "(global $__str_" id " (mut anyref) (ref.null none))"))
        ;; Build a single data segment with all string bytes concatenated
          string-data-info (if (seq string-entries)
                             (reduce (fn [acc [s id]]
                                       (let [bytes (.getBytes ^String s "UTF-8")
                                             offset (:offset acc)]
                                         (-> acc
                                             (update :bytes (fn [b] (into (or b []) bytes)))
                                             (assoc-in [:entries id] {:offset offset :length (count bytes)})
                                             (assoc :offset (+ offset (count bytes))))))
                                     {:bytes [] :entries {} :offset 0}
                                     string-entries)
                             {:bytes [] :entries {} :offset 0})
          string-data-segment (when (seq string-entries)
                                (let [all-bytes (:bytes string-data-info)]
                                  (str "(data $__str_data \""
                                       (apply str (map (fn [b] (format "\\%02x" (bit-and b 0xff))) all-bytes))
                                       "\")")))
          string-init-fns (for [[s id] string-entries]
                            (let [{:keys [offset length]} (get-in string-data-info [:entries id])]
                              (str "(func $__init_str_" id " (result anyref)\n"
                                   "    (struct.new $String (i32.const 3) (i32.const " id ")\n"
                                   "      (array.new_data $CharArray $__str_data (i32.const " offset ") (i32.const " length "))))")))
          string-init-code (for [[_ id] string-entries]
                             (str "(global.set $__str_" id " (call $__init_str_" id "))"))
        ;; Generate keyword name table init
        ;; We need the keywords from the analyzer to build name strings
          kw-entries (sort-by val *keywords*)
          kw-count (count kw-entries)
          kw-data-info (if (pos? kw-count)
                         (reduce (fn [acc [kw id]]
                                   (let [kw-name (if (namespace kw)
                                                   (str (namespace kw) "/" (name kw))
                                                   (name kw))
                                         bytes (.getBytes ^String kw-name "UTF-8")
                                         offset (:offset acc)]
                                     (-> acc
                                         (update :bytes (fn [b] (into (or b []) bytes)))
                                         (assoc-in [:entries id] {:offset offset :length (count bytes)})
                                         (assoc :offset (+ offset (count bytes))))))
                                 {:bytes [] :entries {} :offset 0}
                                 kw-entries)
                         {:bytes [] :entries {} :offset 0})
          kw-data-segment (when (pos? kw-count)
                            (let [all-bytes (:bytes kw-data-info)]
                              (str "(data $__kw_data \""
                                   (apply str (map (fn [b] (format "\\%02x" (bit-and b 0xff))) all-bytes))
                                   "\")")))
          kw-name-init-code (when (pos? kw-count)
                              (let [kw-init-lines
                                    (for [[kw id] kw-entries]
                                      (let [{:keys [offset length]} (get-in kw-data-info [:entries id])]
                                        (str "(func $__init_kw_name_" id " (result anyref)\n"
                                             "    (struct.new $String (i32.const 3) (i32.const " -1 ")\n"
                                             "      (array.new_data $CharArray $__kw_data (i32.const " offset ") (i32.const " length "))))")))]
                                {:funcs kw-init-lines
                                 :init-code (concat
                                             [(str "(global.set $__kw_names (call $array_new (i32.const " kw-count ")))")
                                              (str "(global.set $__kw_next_id (i32.const " kw-count "))")]
                                             (for [[_ id] kw-entries]
                                               (str "(call $array_set (global.get $__kw_names) (i32.const " id ") (call $__init_kw_name_" id "))")))}))
        ;; Generate symbol globals and init (like strings)
          sym-entries (sort-by val *symbols*)
          sym-count (count sym-entries)
          sym-globals (for [[_ id] sym-entries]
                        (str "(global $__sym_" id " (mut anyref) (ref.null none))"))
        ;; Build data segment for symbol name/ns strings
          sym-data-info (reduce (fn [acc [sym id]]
                                  (let [sym-name (name sym)
                                        sym-ns (namespace sym)
                                        ;; Store name bytes
                                        name-bytes (.getBytes ^String sym-name "UTF-8")
                                        name-offset (:offset acc)
                                        acc (-> acc
                                                (update :bytes (fn [b] (into (or b []) name-bytes)))
                                                (assoc-in [:entries id :name-offset] name-offset)
                                                (assoc-in [:entries id :name-length] (count name-bytes))
                                                (assoc :offset (+ name-offset (count name-bytes))))]
                                    (if sym-ns
                                      (let [ns-bytes (.getBytes ^String sym-ns "UTF-8")
                                            ns-offset (:offset acc)]
                                        (-> acc
                                            (update :bytes (fn [b] (into (or b []) ns-bytes)))
                                            (assoc-in [:entries id :ns-offset] ns-offset)
                                            (assoc-in [:entries id :ns-length] (count ns-bytes))
                                            (assoc :offset (+ ns-offset (count ns-bytes)))))
                                      acc)))
                                {:bytes [] :entries {} :offset 0}
                                sym-entries)
          sym-data-segment (when (pos? sym-count)
                             (let [all-bytes (:bytes sym-data-info)]
                               (str "(data $__sym_data \""
                                    (apply str (map (fn [b] (format "\\%02x" (bit-and b 0xff))) all-bytes))
                                    "\")")))
          sym-init-code (when (pos? sym-count)
                          (let [sym-init-fns
                                (for [[sym id] sym-entries]
                                  (let [{:keys [name-offset name-length ns-offset ns-length]} (get-in sym-data-info [:entries id])
                                        has-ns (some? ns-offset)]
                                    (str "(func $__init_sym_" id " (result anyref)\n"
                                         "    (struct.new $Symbol (i32.const 4) (i32.const " id ")\n"
                                         "      (struct.new $String (i32.const 3) (i32.const -1)\n"
                                         "        (array.new_data $CharArray $__sym_data (i32.const " name-offset ") (i32.const " name-length ")))\n"
                                         "      " (if has-ns
                                                    (str "(struct.new $String (i32.const 3) (i32.const -1)\n"
                                                         "        (array.new_data $CharArray $__sym_data (i32.const " ns-offset ") (i32.const " ns-length ")))")
                                                    "(ref.null none)")
                                         "))")))]
                            {:funcs sym-init-fns
                             :init-code (for [[_ id] sym-entries]
                                          (str "(global.set $__sym_" id " (call $__init_sym_" id "))"))}))
        ;; Extract dispatch table info from protocol dispatch maps
          proto-dispatch-infos (filter some? proto-dispatch-funcs)
          dispatch-table-globals (when (seq proto-dispatch-infos)
                                   (map :table-global-decl proto-dispatch-infos))
          all-globals (concat *globals-emit* builtin-globals fn-globals proto-globals
                              dispatch-table-globals string-globals sym-globals)
          globals-section (str-join "\n  " all-globals)
        ;; Add builtin and fn wrapper functions
          builtin-funcs (when (seq builtin-wrappers)
                          (map :func-def builtin-wrappers))
          fn-funcs (when (seq fn-wrappers)
                     (map :func-def fn-wrappers))
        ;; Print helper (WASI-based) - always available
          print-fns [(str
                       ";; Print a woj String to stdout via WASI fd_write
  ;; Memory layout: [0..3]=nwritten [4..7]=iov_base [8..11]=iov_len [12..]=data
  (func $__repl_print_str (param $str anyref)
    (local $chars (ref null $CharArray))
    (local $len i32)
    (local $i i32)
    (if (ref.is_null (local.get $str)) (then (return)))
    (if (i32.eqz (ref.test (ref $String) (local.get $str))) (then (return)))
    (local.set $chars (struct.get $String $data (ref.cast (ref $String) (local.get $str))))
    (local.set $len (array.len (local.get $chars)))
    (if (i32.eqz (local.get $len)) (then (return)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (i32.const 12) (local.get $i))
                    (array.get_u $CharArray (local.get $chars) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (i32.store (i32.const 4) (i32.const 12))
    (i32.store (i32.const 8) (local.get $len))
    (drop (call $fd_write (i32.const 1) (i32.const 4) (i32.const 1) (i32.const 0))))")
                     ";; print!: convert any value to string via str1, write to stdout, return nil
  (func $print_BANG_ (param $val anyref) (result anyref)
    (call $__repl_print_str (call $str1 (local.get $val)))
    (ref.null none))
  ;; pr!: convert any value to string via pr-str1 (EDN), write to stdout, return nil
  (func $pr_BANG_ (param $val anyref) (result anyref)
    (call $__repl_print_str (call $pr_str1 (local.get $val)))
    (ref.null none))
  ;; print-str!: write a pre-built String to stdout, return nil
  (func $print_str_BANG_ (param $str anyref) (result anyref)
    (call $__repl_print_str (local.get $str))
    (ref.null none))"]
          all-functions (concat *functions* builtin-funcs fn-funcs
                                (map :func-def proto-dispatch-infos)
                                (filter some? proto-satisfies-funcs)
                                (filter some? core-proto-stubs)
                                string-init-fns
                                (:funcs kw-name-init-code)
                                (:funcs sym-init-code)
                                print-fns)
          functions-section (str-join "\n\n  " all-functions)
        ;; Elem declarations for closure functions (needed for ref.func)
        ;; Include builtin and fn wrapper functions, and protocol impl functions
          builtin-func-names (when (seq builtin-wrappers)
                               (map :func-name builtin-wrappers))
          fn-func-names (when (seq fn-wrappers)
                          (map :func-name fn-wrappers))
          proto-impl-func-names (when (seq proto-impl-closures)
                                  (map :func-name proto-impl-closures))
          all-closure-funcs (concat *closure-funcs* builtin-func-names fn-func-names proto-impl-func-names)
          elem-section (if (seq all-closure-funcs)
                         (str "\n\n  ;; Closure function declarations\n  (elem declare func "
                              (str-join " " all-closure-funcs) ")")
                         "")
        ;; Generate initialization code for builtin wrappers
          builtin-init-code (when (seq builtin-wrappers)
                              (for [{:keys [global-name func-name closure-type]} builtin-wrappers]
                                (str "(global.set " global-name " (struct.new " closure-type " (i32.const 11) (ref.func " func-name ") (call $array_new (i32.const 0))))")))
        ;; Generate initialization code for fn wrappers
          fn-init-code (when (seq fn-wrappers)
                         (for [{:keys [global-name func-name closure-type is-multi]} fn-wrappers]
                           (if is-multi
                           ;; MultiClosure: env first, dispatch second
                             (str "(global.set " global-name " (struct.new " closure-type " (i32.const 11) (call $array_new (i32.const 0)) (ref.func " func-name ")))")
                           ;; Regular ClosureN: func first, env second
                             (str "(global.set " global-name " (struct.new " closure-type " (i32.const 11) (ref.func " func-name ") (call $array_new (i32.const 0))))"))))
        ;; Generate initialization code for protocol impl closures
          proto-init-code (when (seq proto-impl-closures)
                            (map :init-code proto-impl-closures))
        ;; Generate dispatch table init code (must come after proto-init-code since tables reference closures)
          dispatch-table-init-code (when (seq proto-dispatch-infos)
                                     (mapcat :table-init-code proto-dispatch-infos))
        ;; Add drop after each init expression since they return values but $start doesn't
          init-with-drops (map (fn [code] (str code "\n    drop")) init-code)
        ;; Combine builtin init, fn init, proto init, dispatch table init, string init, kw name init (no drops needed) with user init
          all-init (concat
                    builtin-init-code fn-init-code proto-init-code
                    dispatch-table-init-code
                    *lifted-fn-inits*
                    string-init-code
                    (:init-code kw-name-init-code)
                    (:init-code sym-init-code)
                    init-with-drops)
          ;; Collect locals from top-level user code (let bindings, loops, etc.)
          start-locals (distinct (mapcat collect-locals ast-forms))
          start-fn (if (seq all-init)
                     (str "\n\n  ;; Initialization\n  (func $start"
                          (if (seq start-locals) (str "\n    " (str-join "\n    " start-locals)) "")
                          "\n    " (str-join "\n    " all-init) ")\n  (start $start)")
                     "")
        ;; Data segments for string/keyword/symbol byte arrays
          data-segments (let [segs (filter some? [string-data-segment kw-data-segment sym-data-segment])]
                          (when (seq segs)
                            (str "\n\n  ;; Data segments for constant byte arrays\n  "
                                 (str-join "\n  " segs))))]
          
      (str prelude
           (if (seq all-globals) (str "\n\n  ;; Globals\n  " globals-section) "")
           (or data-segments "")
           elem-section
           (if (seq all-functions) (str "\n\n  ;; User functions\n  " functions-section) "")
           start-fn
           "\n)"))))
