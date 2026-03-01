;; woj Bootstrap Entry Point
;; This is the compiler's main module when compiled to WASM.
;; Uses woj.reader (instead of tools.reader) and WASI I/O (instead of java.io).

(ns bootstrap.main
  (:require [woj.analyzer :as analyzer]
            [woj.emitter :as emitter]
            [woj.reader :as reader]
            [woj.util :as util]
            [clojure.string :as str]
            [clojure.set :as set]
            [woj.io :as io]))

;; ============================================
;; Reader
;; ============================================

(defn read-all
  "Read all forms from a string using woj.reader.
   Supports reader conditionals with :woj as the feature flag."
  [s]
  (reader/read-all {:read-cond :allow :features #{:woj :default}} s))

;; ============================================
;; Core Library (Prelude)
;; ============================================

(def core-lib-path "lib/core.clj")
(def edn-lib-path "lib/edn.clj")
(def regex-lib-path "lib/regex.clj")

(defn- load-lib-file
  "Load a library source file. Returns the source string or nil if not found."
  [path]
  (io/slurp path))

(defn load-core-lib []
  (load-lib-file core-lib-path))

(defn load-edn-lib []
  (load-lib-file edn-lib-path))

(defn load-regex-lib []
  (load-lib-file regex-lib-path))

;; ============================================
;; Namespace file resolution
;; ============================================

(defn- ns-name->paths
  "Convert a namespace name to candidate file paths."
  [ns-name-str]
  (let [path-part (-> ns-name-str
                      (str/replace "." "/")
                      (str/replace "-" "_"))]
    [(str path-part ".cljc") (str path-part ".clj")]))

(defn- resolve-ns-file
  "Search for a namespace file across search paths. Returns path string or nil."
  [ns-name-str search-paths]
  (let [candidates (ns-name->paths ns-name-str)]
    (first
      (for [dir search-paths
            candidate candidates
            :let [path (str dir "/" candidate)
                  contents (io/slurp path)]
            :when contents]
        path))))

(defn- make-ns-load-fn
  "Create a function that loads namespace source given search paths."
  [search-paths]
  (fn [ns-name-str]
    (when-let [path (resolve-ns-file ns-name-str search-paths)]
      (io/slurp path))))

;; ============================================
;; Tree-shaking
;; ============================================

(defn- collect-refs
  "Walk an AST node and collect all referenced global def names.
   Returns a set of symbols."
  [ast]
  (when-not ast (throw (ex-info "nil ast in collect-refs" {})))
  (case (:op ast)
    (:const :nil :keyword :string :symbol :float :local :captured) #{}
    :builtin-ref #{(:name ast)}
    :fn-global #{(:name ast)}
    :global #{(:name ast)}
    :set! (conj (collect-refs (:val ast)) (:name ast))
    :call (into (collect-refs (:fn ast)) (mapcat collect-refs (:args ast)))
    :builtin (into #{(:name ast)} (mapcat collect-refs (:args ast)))
    :protocol-call (into #{} (mapcat collect-refs (:args ast)))
    :fn (let [arities (:arities ast)]
          (if (and arities (seq arities))
            (into #{} (mapcat #(collect-refs (:body %)) arities))
            (if (:body ast) (collect-refs (:body ast)) #{})))
    :let (into (collect-refs (:body ast))
               (mapcat #(collect-refs (:init %)) (:bindings ast)))
    :loop (into (collect-refs (:body ast))
                (mapcat #(collect-refs (:init %)) (:bindings ast)))
    :do (into #{} (mapcat collect-refs (:exprs ast)))
    :if (into (collect-refs (:test ast))
              (into (collect-refs (:then ast))
                    (if (:else ast) (collect-refs (:else ast)) #{})))
    :recur (into #{} (mapcat collect-refs (:args ast)))
    :throw (collect-refs (:val ast))
    :try (into (collect-refs (:body ast))
               (concat
                (when-let [c (:catch ast)] (collect-refs (:body c)))
                (when-let [f (:finally ast)] (collect-refs f))))
    :def (collect-refs (:init ast))
    :defprotocol #{}
    :extend-type (into #{} (mapcat #(collect-refs (:impl %)) (:impls ast)))
    :extend-protocol (into #{} (mapcat collect-refs (:extend-types ast)))
    :deftype (into #{} (mapcat #(collect-refs (:impl %)) (:impls ast)))
    :field-access (collect-refs (:target ast))
    :instance? (collect-refs (:val ast))
    #{}))

(defn- tree-shake
  "Remove unreachable core/lib definitions from the AST.
   Returns a filtered AST vector.

   Parameters:
   - ast: the full AST vector from analyze-forms
   - ns-ast-count: number of AST entries from :require'd namespaces (at front)
   - core-count: number of AST entries from core.clj + edn.clj + regex.clj"
  [ast ns-ast-count core-count]
  (let [ns-asts (subvec ast 0 ns-ast-count)
        core-asts (subvec ast ns-ast-count (+ ns-ast-count core-count))
        user-asts (subvec ast (+ ns-ast-count core-count))
        core-def-names (into #{} (keep (fn [a] (when (= :def (:op a)) (:name a))) core-asts))
        core-def-refs (into {} (keep (fn [a] (when (= :def (:op a)) [(:name a) (collect-refs (:init a))])) core-asts))
        user-refs (into #{} (mapcat collect-refs user-asts))
        ns-refs (into #{} (mapcat collect-refs ns-asts))
        non-def-core-refs (into #{} (mapcat collect-refs (remove #(= :def (:op %)) core-asts)))
        initial-roots (set/union user-refs ns-refs non-def-core-refs)
        reachable (loop [queue (vec (set/intersection initial-roots core-def-names))
                         visited #{}]
                    (if (empty? queue)
                      visited
                      (let [current (first queue)
                            rest-q (subvec queue 1)]
                        (if (visited current)
                          (recur rest-q visited)
                          (let [deps (get core-def-refs current #{})
                                new-deps (set/intersection (set/difference deps visited) core-def-names)]
                            (recur (into rest-q new-deps) (conj visited current)))))))
        kept-core (filterv (fn [a] (or (not= :def (:op a)) (contains? reachable (:name a)))) core-asts)
        shaken-count (- (count core-asts) (count kept-core))]
    (when (pos? shaken-count)
      (io/eprintln (str "[tree-shaker] Removed " shaken-count " unused core definitions"
                        " (kept " (count (filter #(= :def (:op %)) kept-core)) " of "
                        (count (filter #(= :def (:op %)) core-asts)) ")")))
    (into [] (concat ns-asts kept-core user-asts))))

;; ============================================
;; Pre-generated prelude support
;; ============================================

(def prelude-base-path "bootstrap/prejoined/prelude-base.wat")

(defn- fill-prelude
  "Fill dynamic placeholders in the pre-generated prelude base.
   The base contains markers like __USER_TYPE_DEFS__ that need to be
   replaced with compile-time values (user types, host imports, etc.)."
  [base]
  (let [host-import-section (if (seq emitter/*host-imports*)
                              (str "\n  ;; Host imports\n  " (str-join "\n  " emitter/*host-imports*))
                              "")]
    (-> base
        (emitter/str-replace-once "__USER_TYPE_DEFS__" (emitter/emit-user-type-defs))
        (emitter/str-replace-once "__HOST_IMPORTS__" host-import-section)
        (emitter/str-replace-once "__USER_TYPE_TAGS__"
                                  (if (empty? emitter/*user-types*) "(i32.const -1)" (emitter/emit-user-type-tag-branches)))
        (emitter/str-replace-once "__USER_TYPE_EQ__" (emitter/emit-user-type-eq-code))
        (emitter/str-replace-once "__USER_TYPE_HASH__" (emitter/emit-user-type-hash-code))
        (emitter/str-replace-once "__USER_COUNTED__" (emitter/emit-user-predicate-checks (symbol "-count")))
        (emitter/str-replace-once "__USER_MAP__" (emitter/emit-user-predicate-checks (symbol "-assoc"))))))

;; ============================================
;; Batch-aware compilation
;; ============================================

(defn- prepare-core
  "Load and read core library sources. Returns {:core-forms [...] :prelude-base str}.
   Called once per batch — the expensive part (~7s in WASM)."
  []
  (let [t0 (now-ms)
        prelude-base (io/slurp prelude-base-path)
        t0b (now-ms)
        _ (io/eprintln (str "[timing] load prelude base: " (- t0b t0) "ms"
                            (if prelude-base (str " (" (count prelude-base) " chars)") " (NOT FOUND)")))
        core-source (str (or (load-core-lib) "") "\n"
                         (or (load-edn-lib) "") "\n"
                         (or (load-regex-lib) "") "\n")
        t1 (now-ms)
        _ (io/eprintln (str "[timing] load core: " (- t1 t0b) "ms"))
        core-forms (read-all core-source)
        t2 (now-ms)
        _ (io/eprintln (str "[timing] read core: " (- t2 t1) "ms (" (count core-forms) " forms)"))]
    {:core-forms core-forms
     :prelude-base prelude-base
     :load-time-ms (- t2 t0)}))

(def core-analyzer-state-path "bootstrap/prejoined/core-analyzer-state.edn")
(def core-macros-path "bootstrap/prejoined/core-macros.clj")
(def core-head-count-path "bootstrap/prejoined/core-head-count.txt")
(def core-start-header-path "bootstrap/prejoined/core-start-header.wat")
(def core-start-body-path "bootstrap/prejoined/core-start-body.wat")

(defn- load-core-head-chunks
  "Load pre-joined core head WAT chunks."
  []
  (let [count-str (io/slurp core-head-count-path)]
    (when count-str
      (let [n (parse-int (str/trim count-str))]
        (loop [i 0 chunks []]
          (if (>= i n)
            chunks
            (let [chunk (io/slurp (str "bootstrap/prejoined/core-head-" i ".wat"))]
              (recur (inc i) (conj chunks chunk)))))))))

(defn- prepare-core-fast
  "Load pre-analyzed core state + re-analyze only macro definitions.
   Also loads pre-joined core WAT for stream-module assembly.
   Returns map or nil if pre-analyzed files not found.
   ~1s total vs ~7s for prepare-core."
  []
  (let [t0 (now-ms)
        state-edn (io/slurp core-analyzer-state-path)
        macro-source (io/slurp core-macros-path)
        start-header (io/slurp core-start-header-path)
        start-body (io/slurp core-start-body-path)]
    (when (and state-edn macro-source start-header start-body)
      (let [t1 (now-ms)
            head-chunks (load-core-head-chunks)
            _ (when-not head-chunks
                (io/eprintln "[fast] WARNING: could not load core head chunks"))
            t1b (now-ms)
            _ (io/eprintln (str "[timing] load pre-analyzed + prejoined files: " (- t1b t0) "ms"))
            ;; Parse the EDN state (use read-all since woj.edn isn't available at this stage)
            base-state (first (read-all state-edn))
            t2 (now-ms)
            _ (io/eprintln (str "[timing] parse analyzer state EDN: " (- t2 t1b) "ms"))
            ;; Read and analyze just macro forms to get live macro functions
            macro-forms (read-all macro-source)
            t3 (now-ms)
            _ (io/eprintln (str "[timing] read macro forms: " (- t3 t2) "ms (" (count macro-forms) " macros)"))
            ;; Analyze macros in context of the base state to produce live fn objects
            macro-result (analyzer/analyze-forms-continuing macro-forms base-state)
            t4 (now-ms)
            _ (io/eprintln (str "[timing] analyze macros: " (- t4 t3) "ms"))
            ;; Merge: base state + live macro functions from analysis
            full-state (assoc base-state :macros (:macros macro-result))
            ;; Build internal-fn-names map from direct-fn-globals:
            ;; Every core fn "foo_bar" maps to "foo_bar_internal"
            core-ifn (reduce (fn [acc [sym _info]] (let [munged (util/munge-name sym)] (assoc acc munged (str munged "_internal")))) {} (or (:direct-fn-globals full-state) {}))]
        (io/eprintln (str "[timing] prepare-core-fast total: " (- t4 t0) "ms"))
        (io/eprintln (str "[timing] built internal-fn-names: " (count core-ifn) " entries"))
        {:analyzer-state full-state
         :core-head-chunks head-chunks
         :core-start-header start-header
         :core-start-body start-body
         :core-string-count (or (:string-count base-state) 0)
         :core-keyword-count (or (:keyword-count base-state) 0)
         :core-symbol-count (count (or (:symbols base-state) {}))
         :core-internal-fn-names core-ifn
         :core-builtin-refs (or (:builtin-refs-emit base-state) (:builtin-refs base-state) #{})
         :core-fn-refs (or (:fn-refs-emit base-state) (:fn-refs base-state) #{})
         :core-fn-counter (or (:fn-counter base-state) 0)}))))

(defn- compile-one-fast
  "Compile user source using pre-analyzed core state via analyze-forms-continuing.
   Uses stream-module with pre-joined core WAT — core functions are already assembled.
   Skips re-analyzing 439 core forms — only analyzes user code (~20ms vs ~200ms).
   No tree-shaking (all core defs are in the pre-joined WAT)."
  [source {:keys [analyzer-state core-head-chunks core-start-header core-start-body search-paths]}]
  (let [t0 (now-ms)
        user-forms (read-all source)
        t1 (now-ms)
        _ (io/eprintln (str "[timing] read user: " (- t1 t0) "ms (" (count user-forms) " forms)"))
        analysis-result (binding [analyzer/*ns-load-fn* (when (seq search-paths) (make-ns-load-fn search-paths))
                                  analyzer/*ns-read-fn* (when (seq search-paths) read-all)]
                          (analyzer/analyze-forms-continuing user-forms analyzer-state))
        t2 (now-ms)
        _ (io/eprintln (str "[timing] analyze (continuing): " (- t2 t1) "ms"))
        ast (:ast analysis-result)
        keywords (:keywords analysis-result)
        strings (:strings analysis-result)
        callable-globals (:callable-globals analysis-result)
        direct-fn-globals (:direct-fn-globals analysis-result)
        builtin-refs (:builtin-refs analysis-result)
        symbols (:symbols analysis-result)
        user-types (:user-types analysis-result)]
    (binding [emitter/*keywords* keywords
              emitter/*strings* strings
              emitter/*symbols* (or symbols {})
              emitter/*callable-globals* callable-globals
              emitter/*direct-fn-globals* direct-fn-globals
              emitter/*fn-refs* #{}
              emitter/*builtin-refs* builtin-refs
              emitter/*repl-mode* false
              emitter/*user-types* (or user-types {})
              emitter/*fn-counter* 0
              emitter/*loop-counter* 0
              emitter/*loop-context* nil
              emitter/*internal-fn-names* {}
              emitter/*closure-env-param* nil
              emitter/*capture-indices* nil
              emitter/*functions* []
              emitter/*globals-emit* []
              emitter/*globals-declared* #{}
              emitter/*closure-funcs* []
              emitter/*emitted-fn-names* #{"$float_QMARK_"}
              emitter/*host-imports* []
              emitter/*host-import-fns* #{}
              emitter/*protocols* {}
              emitter/*protocol-methods* {}
              emitter/*protocol-impls* {}
              emitter/*lifted-fn-inits* []]
      (let [{:keys [init-code]} (emitter/emit-forms ast)
            t3 (now-ms)
            _ (io/eprintln (str "[timing] emit-forms: " (- t3 t2) "ms"))]
        ;; Use stream-module: pre-joined core WAT + user WAT spliced in
        (emitter/stream-module ast init-code
                               {:core-head-chunks core-head-chunks
                                :core-start-header core-start-header
                                :core-start-body core-start-body})
        (let [t4 (now-ms)]
          (io/eprintln (str "[timing] stream-module: " (- t4 t3) "ms"))
          (io/eprintln (str "[timing] compile-one-fast total: " (- t4 t0) "ms")))))))

(defn- compile-one
  "Compile a single file's source to WAT string.
   Takes pre-loaded core state to avoid redundant I/O and reading.

   Options:
   - :core-forms     - pre-read core forms vector (from prepare-core)
   - :prelude-base   - pre-loaded prelude WAT template
   - :search-paths   - namespace search paths
   - :tree-shake?    - whether to tree-shake (default true)
   - :return-string? - if true, returns WAT string instead of printing (for batch)"
  [source {:keys [core-forms prelude-base search-paths tree-shake? return-string?]
           :or {core-forms [] prelude-base nil search-paths [] tree-shake? true return-string? false}}]
  (let [t0 (now-ms)
        user-forms (read-all source)
        t1 (now-ms)
        _ (io/eprintln (str "[timing] read user: " (- t1 t0) "ms (" (count user-forms) " forms)"))
        core-form-count (count core-forms)
        include-core? (pos? core-form-count)
        all-forms (into core-forms user-forms)
        analysis-result (binding [analyzer/*ns-load-fn* (when (seq search-paths) (make-ns-load-fn search-paths))
                                  analyzer/*ns-read-fn* (when (seq search-paths) read-all)]
                          (analyzer/analyze-forms all-forms))
        t2 (now-ms)
        _ (io/eprintln (str "[timing] analyze: " (- t2 t1) "ms"))
        ast (:ast analysis-result)
        ns-ast-count (- (count ast) (count all-forms))
        ast (if (and include-core? tree-shake?)
              (tree-shake ast ns-ast-count core-form-count)
              ast)
        t3 (now-ms)
        _ (when (and include-core? tree-shake?)
            (io/eprintln (str "[timing] tree-shake: " (- t3 t2) "ms")))
        keywords (:keywords analysis-result)
        strings (:strings analysis-result)
        callable-globals (:callable-globals analysis-result)
        direct-fn-globals (:direct-fn-globals analysis-result)
        builtin-refs (:builtin-refs analysis-result)
        symbols (:symbols analysis-result)
        user-types (:user-types analysis-result)]
    (binding [emitter/*keywords* keywords
              emitter/*strings* strings
              emitter/*symbols* (or symbols {})
              emitter/*callable-globals* callable-globals
              emitter/*direct-fn-globals* direct-fn-globals
              emitter/*fn-refs* #{}
              emitter/*builtin-refs* builtin-refs
              emitter/*repl-mode* false
              emitter/*user-types* (or user-types {})
              emitter/*fn-counter* 0
              emitter/*loop-counter* 0
              emitter/*loop-context* nil
              emitter/*internal-fn-names* {}
              emitter/*closure-env-param* nil
              emitter/*capture-indices* nil
              emitter/*functions* []
              emitter/*globals-emit* []
              emitter/*globals-declared* #{}
              emitter/*closure-funcs* []
              emitter/*emitted-fn-names* #{"$float_QMARK_"}
              emitter/*host-imports* []
              emitter/*host-import-fns* #{}
              emitter/*protocols* {}
              emitter/*protocol-methods* {}
              emitter/*protocol-impls* {}
              emitter/*lifted-fn-inits* []]
      (let [{:keys [init-code]} (emitter/emit-forms ast)
            t4 (now-ms)
            _ (io/eprintln (str "[timing] emit-forms: " (- t4 t3) "ms"))
            filled-prelude (when prelude-base (fill-prelude prelude-base))
            t5 (now-ms)
            _ (when prelude-base (io/eprintln (str "[timing] fill prelude: " (- t5 t4) "ms")))
            wat (emitter/assemble-module ast init-code
                                         (if filled-prelude {:prelude filled-prelude} {}))
            t6 (now-ms)]
        (io/eprintln (str "[timing] assemble: " (- t6 t5) "ms"))
        (io/eprintln (str "[timing] compile-one total: " (- t6 t0) "ms"))
        (if return-string? wat (do (print-str! wat) nil))))))

;; ============================================
;; Single-file compilation (backwards compat)
;; ============================================

(defn compile-string
  "Compile woj source to WAT. Analyzes core+user together, tree-shakes, then emits."
  ([source] (compile-string source true))
  ([source include-core?] (compile-string source include-core? []))
  ([source include-core? search-paths]
   (let [core (when include-core? (prepare-core))
         core-forms (if core (:core-forms core) [])
         prelude-base (if core (:prelude-base core) (io/slurp prelude-base-path))]
     (compile-one source {:core-forms core-forms
                          :prelude-base prelude-base
                          :search-paths search-paths}))))

(defn compile-file
  "Compile a woj source file to WAT."
  ([filename] (compile-file filename []))
  ([filename search-paths]
   (let [source (io/slurp filename)
         all-paths (distinct (remove nil? (concat ["lib" "."] search-paths)))]
     (when-not source
       (throw (ex-info (str "Cannot read file: " filename) {})))
     (compile-string source true all-paths))))

;; ============================================
;; Batch compilation
;; ============================================

(defn- set-emitter-vars!
  "Set all emitter dynamic vars for a compilation. Uses set! instead of binding
   to avoid the deeply-nested try/catch save/restore machinery that causes
   wasm trap: cast failure after multiple iterations."
  [analysis-result]
  (let [keywords (:keywords analysis-result)
        strings (:strings analysis-result)
        callable-globals (:callable-globals analysis-result)
        direct-fn-globals (:direct-fn-globals analysis-result)
        builtin-refs (:builtin-refs analysis-result)
        symbols (:symbols analysis-result)
        user-types (:user-types analysis-result)]
    (set! emitter/*keywords* keywords)
    (set! emitter/*strings* strings)
    (set! emitter/*symbols* (or symbols {}))
    (set! emitter/*callable-globals* callable-globals)
    (set! emitter/*direct-fn-globals* direct-fn-globals)
    (set! emitter/*fn-refs* #{})
    (set! emitter/*builtin-refs* builtin-refs)
    (set! emitter/*repl-mode* false)
    (set! emitter/*user-types* (or user-types {}))
    (set! emitter/*fn-counter* 0)
    (set! emitter/*loop-counter* 0)
    (set! emitter/*loop-context* nil)
    (set! emitter/*internal-fn-names* {})
    (set! emitter/*closure-env-param* nil)
    (set! emitter/*capture-indices* nil)
    (set! emitter/*functions* [])
    (set! emitter/*globals-emit* [])
    (set! emitter/*globals-declared* #{})
    (set! emitter/*closure-funcs* [])
    (set! emitter/*emitted-fn-names* #{"$float_QMARK_"})
    (set! emitter/*host-imports* [])
    (set! emitter/*host-import-fns* #{})
    (set! emitter/*protocols* {})
    (set! emitter/*protocol-methods* {})
    (set! emitter/*protocol-impls* {})
    (set! emitter/*lifted-fn-inits* [])))

(defn- compile-one-batch
  "Compile a single file within a batch context. Returns the filled prelude for caching."
  [source filename all-paths core-forms prelude-base cached-prelude]
  (let [user-forms (read-all source)
        all-forms (into core-forms user-forms)
        _ (set! analyzer/*ns-load-fn* (when (seq all-paths) (make-ns-load-fn all-paths)))
        _ (set! analyzer/*ns-read-fn* (when (seq all-paths) read-all))
        analysis-result (analyzer/analyze-forms all-forms)
        _ (set-emitter-vars! analysis-result)
        ast (:ast analysis-result)
        {:keys [init-code]} (emitter/emit-forms ast)
        filled-prelude (or cached-prelude
                           (when prelude-base (fill-prelude prelude-base)))
        wat (emitter/assemble-module ast init-code
                                     (if filled-prelude {:prelude filled-prelude} {}))]
    (print-str! wat)
    filled-prelude))

(defn- emit-user-string-additions
  "Generate WAT for user-added strings (IDs >= core-string-count).
   Returns {:globals [...] :data-segment str :init-fns [...] :init-code [...]}."
  [core-string-count]
  (let [all-entries (sort-by val emitter/*strings*)
        user-entries (filter (fn [entry] (>= (val entry) core-string-count)) all-entries)]
    (when (seq user-entries)
      (let [globals (for [[_ id] user-entries]
                      (str "(global $__str_" id " (mut anyref) (ref.null none))"))
            data-info (reduce (fn [acc [s id]]
                                (let [bytes (emitter/string->utf8-bytes s)
                                      offset (:offset acc)]
                                  (-> acc
                                      (update :bytes (fn [b] (into (or b []) bytes)))
                                      (assoc-in [:entries id] {:offset offset :length (count bytes)})
                                      (assoc :offset (+ offset (count bytes))))))
                              {:bytes [] :entries {} :offset 0}
                              user-entries)
            data-segment (when (seq (:bytes data-info))
                           (str "(data $__user_str_data \""
                                (emitter/bytes->hex-escape (:bytes data-info))
                                "\")"))
            init-fns (for [[_ id] user-entries]
                       (let [{:keys [offset length]} (get-in data-info [:entries id])]
                         (str "(func $__init_str_" id " (result anyref)\n"
                              "    (struct.new $String (i32.const 3) (i32.const " id ")\n"
                              "      (array.new_data $CharArray $__user_str_data (i32.const " offset ") (i32.const " length "))))")))
            init-code (for [[_ id] user-entries]
                        (str "(global.set $__str_" id " (call $__init_str_" id "))"))]
        {:globals globals :data-segment data-segment :init-fns init-fns :init-code init-code}))))

(defn- emit-user-keyword-additions
  "Generate WAT for user-added keywords (IDs >= core-keyword-count).
   Returns {:init-fns [...] :init-code [...] :data-segment str}."
  [core-keyword-count]
  (let [all-entries (sort-by val emitter/*keywords*)
        user-entries (filter (fn [entry] (>= (val entry) core-keyword-count)) all-entries)
        total-kw-count (count all-entries)]
    (when (seq user-entries)
      (let [data-info (reduce (fn [acc [kw id]]
                                (let [kw-name (if (namespace kw)
                                                (str (namespace kw) "/" (name kw))
                                                (name kw))
                                      bytes (emitter/string->utf8-bytes kw-name)
                                      offset (:offset acc)]
                                  (-> acc
                                      (update :bytes (fn [b] (into (or b []) bytes)))
                                      (assoc-in [:entries id] {:offset offset :length (count bytes)})
                                      (assoc :offset (+ offset (count bytes))))))
                              {:bytes [] :entries {} :offset 0}
                              user-entries)
            data-segment (when (seq (:bytes data-info))
                           (str "(data $__user_kw_data \""
                                (emitter/bytes->hex-escape (:bytes data-info))
                                "\")"))
            init-fns (for [[_ id] user-entries]
                       (let [{:keys [offset length]} (get-in data-info [:entries id])]
                         (str "(func $__init_kw_name_" id " (result anyref)\n"
                              "    (struct.new $String (i32.const 3) (i32.const " -1 ")\n"
                              "      (array.new_data $CharArray $__user_kw_data (i32.const " offset ") (i32.const " length "))))")))
            ;; Grow kw_names array: copy existing entries to bigger array, add new entries
            init-code (concat
                       [(str "(global.set $__kw_names (call $array_copy (global.get $__kw_names) (i32.const " total-kw-count ")))")
                        (str "(global.set $__kw_next_id (i32.const " total-kw-count "))")]
                       (for [[_ id] user-entries]
                         (str "(call $array_set (global.get $__kw_names) (i32.const " id ") (call $__init_kw_name_" id "))")))]
        {:init-fns init-fns :init-code init-code :data-segment data-segment}))))

(defn- emit-user-symbol-additions
  "Generate WAT for user-added symbols (IDs >= core-symbol-count).
   Returns {:globals [...] :data-segment str :init-fns [...] :init-code [...]}."
  [core-symbol-count]
  (let [all-entries (sort-by val emitter/*symbols*)
        user-entries (filter (fn [entry] (>= (val entry) core-symbol-count)) all-entries)]
    (when (seq user-entries)
      (let [globals (for [[_ id] user-entries]
                      (str "(global $__sym_" id " (mut anyref) (ref.null none))"))
            data-info (reduce (fn [acc [sym id]]
                                (let [sym-name (name sym)
                                      sym-ns (namespace sym)
                                      name-bytes (emitter/string->utf8-bytes sym-name)
                                      name-offset (:offset acc)
                                      acc (-> acc
                                              (update :bytes (fn [b] (into (or b []) name-bytes)))
                                              (assoc-in [:entries id :name-offset] name-offset)
                                              (assoc-in [:entries id :name-length] (count name-bytes))
                                              (assoc :offset (+ name-offset (count name-bytes))))]
                                  (if sym-ns
                                    (let [ns-bytes (emitter/string->utf8-bytes sym-ns)
                                          ns-offset (:offset acc)]
                                      (-> acc
                                          (update :bytes (fn [b] (into (or b []) ns-bytes)))
                                          (assoc-in [:entries id :ns-offset] ns-offset)
                                          (assoc-in [:entries id :ns-length] (count ns-bytes))
                                          (assoc :offset (+ ns-offset (count ns-bytes)))))
                                    acc)))
                              {:bytes [] :entries {} :offset 0}
                              user-entries)
            data-segment (when (seq (:bytes data-info))
                           (str "(data $__user_sym_data \""
                                (emitter/bytes->hex-escape (:bytes data-info))
                                "\")"))
            init-fns (for [[_ id] user-entries]
                       (let [{:keys [name-offset name-length ns-offset ns-length]} (get-in data-info [:entries id])
                             has-ns (some? ns-offset)]
                         (str "(func $__init_sym_" id " (result anyref)\n"
                              "    (struct.new $Symbol (i32.const 4) (i32.const " id ")\n"
                              "      (struct.new $String (i32.const 3) (i32.const -1)\n"
                              "        (array.new_data $CharArray $__user_sym_data (i32.const " name-offset ") (i32.const " name-length ")))\n"
                              "      " (if has-ns
                                         (str "(struct.new $String (i32.const 3) (i32.const -1)\n"
                                              "        (array.new_data $CharArray $__user_sym_data (i32.const " ns-offset ") (i32.const " ns-length ")))")
                                         "(ref.null none)")
                              "))")))
            init-code (for [[_ id] user-entries]
                        (str "(global.set $__sym_" id " (call $__init_sym_" id "))"))]
        {:globals globals :data-segment data-segment :init-fns init-fns :init-code init-code}))))

(defn- compile-one-batch-fast
  "Compile a single file using pre-analyzed core state. No tree-shaking needed
   since core WAT is pre-joined. Uses set! instead of binding.
   Generates user-specific WAT additions (globals, strings, keywords, symbols)
   and splices them into the pre-joined core via stream-module."
  [source filename all-paths fast-core]
  (let [user-forms (read-all source)
        _ (set! analyzer/*ns-load-fn* (when (seq all-paths) (make-ns-load-fn all-paths)))
        _ (set! analyzer/*ns-read-fn* (when (seq all-paths) read-all))
        analysis-result (analyzer/analyze-forms-continuing user-forms (:analyzer-state fast-core))
        _ (set-emitter-vars! analysis-result)
        ;; Restore emitter state from core to avoid naming collisions
        _ (set! emitter/*internal-fn-names* (:core-internal-fn-names fast-core))
        _ (set! emitter/*fn-counter* (:core-fn-counter fast-core))
        ast (:ast analysis-result)
        {:keys [init-code]} (emitter/emit-forms ast)
        ;; Generate user-specific WAT additions
        core-str-count (:core-string-count fast-core)
        core-kw-count (:core-keyword-count fast-core)
        core-sym-count (:core-symbol-count fast-core)
        str-adds (emit-user-string-additions core-str-count)
        kw-adds (emit-user-keyword-additions core-kw-count)
        sym-adds (emit-user-symbol-additions core-sym-count)
        ;; Filter out core builtin/fn refs — their wrappers are already in pre-joined WAT
        _ (set! emitter/*builtin-refs* (reduce disj emitter/*builtin-refs* (:core-builtin-refs fast-core)))
        _ (set! emitter/*fn-refs* (reduce disj emitter/*fn-refs* (:core-fn-refs fast-core)))
        extras (emitter/generate-user-extras)]
    (emitter/stream-module ast init-code
                           {:core-head-chunks (:core-head-chunks fast-core)
                            :core-start-header (:core-start-header fast-core)
                            :core-start-body (:core-start-body fast-core)
                            :user-globals emitter/*globals-emit*
                            :user-data-segments (filter some? [(:data-segment str-adds) (:data-segment kw-adds) (:data-segment sym-adds)])
                            :user-extra-fns (concat (:init-fns str-adds) (:init-fns kw-adds) (:init-fns sym-adds) (:functions extras))
                            :user-extra-init (concat (:init-code str-adds) (:init-code kw-adds) (:init-code sym-adds) (:init-code extras))
                            :user-extra-globals (concat (:globals str-adds) (:globals sym-adds) (:globals extras))
                            :user-extra-elem-funcs (:elem-funcs extras)})))

(defn- nth-batch-filename
  "Extract the Nth batch filename from fresh WASI args.
   Args format: [program '--' '--batch' '--path' dir ... file1 file2 ...]
   Skips '--', '--batch', and '--path <dir>' pairs to find file args."
  [args n]
  (let [argc (count args)]
    (loop [i 1  ;; skip program name
           file-idx 0]
      (if (>= i argc)
        nil
        (let [arg (nth args i)]
          (cond
            (= arg "--") (recur (inc i) file-idx)
            (= arg "--batch") (recur (inc i) file-idx)
            (= arg "--path") (recur (+ i 2) file-idx)
            (= file-idx n) arg
            :else (recur (inc i) (inc file-idx))))))))

(defn- compile-batch
  "Compile multiple files in a single invocation, reusing core forms and prelude.
   Outputs each file's WAT delimited by ===FILE:name=== and ===END=== markers.
   Tries fast path (pre-analyzed core) first, falls back to slow path."
  [filenames search-paths]
  (let [total (count filenames)  ;; Compute BEFORE heavy allocation corrupts the vector
        all-paths (distinct (remove nil? (concat ["lib" "."] search-paths)))
        t0 (now-ms)
        fast-core (prepare-core-fast)
        use-fast? (some? fast-core)
        slow-core (when-not use-fast? (prepare-core))
        t1 (now-ms)
        _ (io/eprintln (str "[batch] Prepared core in " (- t1 t0) "ms"
                            (if use-fast? " (fast path)" " (slow path)")
                            ", compiling " (count filenames) " files"))
        ;; Slow-path state (only used if fast path unavailable)
        core-forms (when slow-core (:core-forms slow-core))
        prelude-base (when slow-core (:prelude-base slow-core))]
    ;; Workaround for wasmtime GC bug: compilation triggers GC that corrupts
    ;; anyref values in data structures. Re-read CLI args each iteration to get
    ;; fresh filename strings, and slurp the file immediately before compiling.
    (loop [n 0
           cached-prelude nil]
        (if (< n total)
          ;; Re-derive filename from fresh CLI args read to avoid GC-corrupted refs
          (let [fresh-args (io/args)
                filename (nth-batch-filename fresh-args n)
                _ (io/eprintln (str "[batch] Compiling " (inc n) "/" total ": " filename))
                source (io/slurp filename)]
            (print-str! (str "===FILE:" filename "===\n"))
            (let [new-cached (if source
                               (try
                                 (if use-fast?
                                   (do (compile-one-batch-fast source filename all-paths fast-core)
                                       cached-prelude)
                                   (compile-one-batch source filename all-paths
                                                      core-forms prelude-base cached-prelude))
                                 (catch e
                                   (io/eprintln (str "[batch] ERROR compiling " filename ": " (ex-message e)))
                                   cached-prelude))
                               (do (io/eprintln (str "[batch] Cannot read file: " filename))
                                   cached-prelude))]
              (print-str! "\n===END===\n")
              (recur (inc n) new-cached)))
          nil))))

;; ============================================
;; Main entry point
;; ============================================

(defn- parse-args
  "Parse CLI arguments using index-based access to avoid VectorSeq bug in WASM.
   Returns {:paths [...] :input-files [...] :batch? bool}."
  [args]
  (let [argc (count args)]
    (loop [i 0
           paths []
           batch? false
           files []]
      (if (>= i argc)
        {:paths paths :input-files files :batch? batch?
         :input-file (first files)}
        (let [arg (nth args i)]
          (cond
            (= arg "--path")
            (if (< (inc i) argc)
              (recur (+ i 2) (conj paths (nth args (inc i))) batch? files)
              (throw (ex-info "--path requires an argument" {})))

            (= arg "--batch")
            (recur (inc i) paths true files)

            (= arg "--")
            (recur (inc i) paths batch? files)

            :else
            (recur (inc i) paths batch? (conj files arg))))))))

(defn- parse-wasi-args
  "Parse WASI command-line arguments. First arg is the program name."
  []
  (let [args (io/args)]
    (if (< (count args) 2)
      (do (io/eprintln "Usage: woj-compiler [--batch] [--path <dir>]... <file>...")
          nil)
      ;; Skip program name (index 0), pass remaining args as vector slice
      (let [argc (count args)
            remaining (loop [i 1 acc []]
                        (if (>= i argc) acc (recur (inc i) (conj acc (nth args i)))))]
        (parse-args remaining)))))

;; Top-level entry point — runs during $start
(try
  (when-let [parsed (parse-wasi-args)]
    (let [paths (:paths parsed)]
      (if (:batch? parsed)
        (compile-batch (:input-files parsed) paths)
        (when-let [filename (:input-file parsed)]
          (compile-file filename paths)))))
  (catch e
    (io/eprintln (str "Error: " (ex-message e)))
    (when (ex-data e)
      (io/eprintln (str "Data: " (pr-str (ex-data e)))))))
