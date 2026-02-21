(ns woj.main
  (:require [woj.analyzer :as analyzer]
            [woj.emitter :as emitter]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.set :as set]
            [clojure.tools.reader :as reader]
            [clojure.tools.reader.reader-types :as reader-types]))

;; ============================================
;; Reader
;; ============================================

(defn read-all
  "Read all forms from a string using tools.reader.
   Supports reader conditionals with :woj as the feature flag."
  [s]
  (let [rdr (reader-types/indexing-push-back-reader s)]
    (binding [reader/*read-eval* false
              reader/*alias-map* {}]
      (loop [forms []]
        (let [form (reader/read {:eof ::eof
                                 :read-cond :allow
                                 :features #{:woj :default}}
                                rdr)]
          (if (= form ::eof)
            forms
            (recur (conj forms form))))))))

;; ============================================
;; Core Library (Prelude)
;; ============================================

(def core-lib-path "lib/core.clj")
(def edn-lib-path "lib/edn.clj")
(def regex-lib-path "lib/regex.clj")

(defn- load-lib-file
  "Load a library source file. Returns the source string or nil if not found."
  [path resource-name]
  (try
    (slurp path)
    (catch java.io.FileNotFoundException _
      (or
        ;; Try relative to woj's own source location
        (try
          (when-let [woj-src (io/resource "woj/main.clj")]
            (let [woj-root (-> (io/file (.toURI woj-src))
                               .getParentFile .getParentFile .getParentFile)
                  f (io/file woj-root path)]
              (when (.exists f)
                (slurp f))))
          (catch Exception _ nil))
        ;; Original classpath fallback
        (when-let [r (io/resource resource-name)]
          (slurp r))))))

(defn load-core-lib
  "Load the core library source. Returns the source string or nil if not found."
  []
  (load-lib-file core-lib-path "core.clj"))

(defn load-edn-lib
  "Load the EDN library source. Returns the source string or nil if not found."
  []
  (load-lib-file edn-lib-path "edn.clj"))

(defn load-regex-lib
  "Load the regex library source. Returns the source string or nil if not found."
  []
  (load-lib-file regex-lib-path "regex.clj"))

;; ============================================
;; Namespace file resolution
;; ============================================

(defn- ns-name->paths
  "Convert a namespace name to candidate file paths.
   e.g., \"clojure.core-test.portability\" -> [\"clojure/core_test/portability.cljc\" \"...clj\"]"
  [ns-name-str]
  (let [path-part (-> ns-name-str
                      (str/replace "." "/")
                      (str/replace "-" "_"))]
    [(str path-part ".cljc") (str path-part ".clj")]))

(defn- resolve-ns-file
  "Search for a namespace file across search paths. Returns the File or nil."
  [ns-name-str search-paths]
  (let [candidates (ns-name->paths ns-name-str)]
    (first
      (for [dir search-paths
            candidate candidates
            :let [f (io/file dir candidate)]
            :when (.exists f)]
        f))))

(defn- make-ns-load-fn
  "Create a function that loads namespace source given search paths."
  [search-paths]
  (fn [ns-name-str]
    (when-let [f (resolve-ns-file ns-name-str search-paths)]
      (slurp f))))

;; ============================================
;; Tree-shaking
;; ============================================

(defn- collect-refs
  "Walk an AST node and collect all referenced global def names.
   Returns a set of symbols."
  [ast]
  (when-not ast (throw (ex-info "nil ast in collect-refs" {})))
  (case (:op ast)
    ;; Leaf nodes - no global references
    (:const :nil :keyword :string :symbol :float :local :captured) #{}
    ;; Builtin-ref: builtin used as a value - track its name like :builtin
    :builtin-ref #{(:name ast)}

    ;; Global references
    :fn-global #{(:name ast)}
    :global #{(:name ast)}

    ;; Mutation targets
    :set! (conj (collect-refs (:val ast)) (:name ast))

    ;; Function calls
    :call (into (collect-refs (:fn ast)) (mapcat collect-refs (:args ast)))
    ;; Builtins: some builtins (vec, vector, etc.) are defined in core.clj, not the WAT prelude.
    ;; Track the name so the corresponding :def is kept if it exists.
    :builtin (into #{(:name ast)} (mapcat collect-refs (:args ast)))

    ;; Protocol calls - args may reference globals
    :protocol-call (into #{} (mapcat collect-refs (:args ast)))

    ;; Function literals - walk into arities/body
    :fn (let [arities (:arities ast)]
          (if (and arities (seq arities))
            (into #{} (mapcat #(collect-refs (:body %)) arities))
            (if (:body ast)
              (collect-refs (:body ast))
              #{})))

    ;; Binding forms
    :let (into (collect-refs (:body ast))
               (mapcat #(collect-refs (:init %)) (:bindings ast)))
    :loop (into (collect-refs (:body ast))
                (mapcat #(collect-refs (:init %)) (:bindings ast)))

    ;; Control flow
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

    ;; Definitions
    :def (collect-refs (:init ast))

    ;; Protocol/type forms - walk into impl bodies
    :defprotocol #{}
    :extend-type (into #{} (mapcat #(collect-refs (:impl %)) (:impls ast)))
    :extend-protocol (into #{} (mapcat collect-refs (:extend-types ast)))
    :deftype (into #{} (mapcat #(collect-refs (:impl %)) (:impls ast)))

    ;; Field access / instance check
    :field-access (collect-refs (:target ast))
    :instance? (collect-refs (:val ast))

    ;; Default - unknown node type, be conservative and return empty
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

        ;; Build dependency map for core defs: name -> set of referenced names
        core-def-names (into #{} (keep (fn [a] (when (= :def (:op a)) (:name a))) core-asts))
        core-def-refs (into {} (keep (fn [a]
                                       (when (= :def (:op a))
                                         [(:name a) (collect-refs (:init a))]))
                                     core-asts))

        ;; Roots: all global refs from user code, ns-asts, and non-def core forms
        user-refs (into #{} (mapcat collect-refs user-asts))
        ns-refs (into #{} (mapcat collect-refs ns-asts))
        ;; Non-def core forms (protocols, extend-type, etc.) are always kept
        non-def-core-refs (into #{} (mapcat collect-refs
                                           (remove #(= :def (:op %)) core-asts)))
        initial-roots (set/union user-refs ns-refs non-def-core-refs)

        ;; Walk reachability from roots through core defs
        reachable (loop [queue (vec (set/intersection initial-roots core-def-names))
                         visited #{}]
                    (if (empty? queue)
                      visited
                      (let [current (first queue)
                            rest-q (subvec queue 1)]
                        (if (visited current)
                          (recur rest-q visited)
                          (let [deps (get core-def-refs current #{})
                                new-deps (set/intersection
                                          (set/difference deps visited)
                                          core-def-names)]
                            (recur (into rest-q new-deps)
                                   (conj visited current)))))))

        ;; Filter core asts: keep non-defs and reachable defs
        kept-core (filterv (fn [a]
                             (or (not= :def (:op a))
                                 (contains? reachable (:name a))))
                           core-asts)
        shaken-count (- (count core-asts) (count kept-core))]
    (binding [*out* *err*]
      (when (pos? shaken-count)
        (println (str "[tree-shaker] Removed " shaken-count " unused core definitions"
                      " (kept " (count (filter #(= :def (:op %)) kept-core)) " of "
                      (count (filter #(= :def (:op %)) core-asts)) ")"))))
    (into [] (concat ns-asts kept-core user-asts))))

;; ============================================
;; Compilation
;; ============================================

(defn- defmacro-form?
  "Check if a form is a defmacro definition (from test files, not core)."
  [form]
  (and (list? form)
       (= (first form) 'defmacro)))

(defn compile-string
  "Compile woj source to WAT. If include-core? is true (default), prepends core library.
   If repl-mode? is true, __repl_eval returns (i32 i32) type tag + value."
  ([source] (compile-string source true))
  ([source include-core?] (compile-string source include-core? false))
  ([source include-core? repl-mode?] (compile-string source include-core? repl-mode? []))
  ([source include-core? repl-mode? search-paths]
   (let [;; Read core/lib forms separately from user forms for tree-shaking
         core-source (if include-core?
                       (str (or (load-core-lib) "") "\n"
                            (or (load-edn-lib) "") "\n"
                            (or (load-regex-lib) "") "\n")
                       "")
         core-forms (if include-core? (read-all core-source) [])
         user-forms (read-all source)
         core-form-count (count core-forms)
         forms (into core-forms user-forms)
         ;; Don't filter defmacro forms - they need to be analyzed to register macros
         analysis-result (binding [analyzer/*ns-load-fn* (when (seq search-paths)
                                                           (make-ns-load-fn search-paths))
                                   analyzer/*ns-read-fn* (when (seq search-paths)
                                                           read-all)]
                           (analyzer/analyze-forms forms))
         ast (:ast analysis-result)
         ;; Tree-shake unused core definitions
         ns-ast-count (- (count ast) (count forms))
         ast (if (and include-core? (pos? core-form-count))
               (tree-shake ast ns-ast-count core-form-count)
               ast)
         keywords (:keywords analysis-result)
         strings (:strings analysis-result)
         callable-globals (:callable-globals analysis-result)
         direct-fn-globals (:direct-fn-globals analysis-result)
         builtin-refs (:builtin-refs analysis-result)
         symbols (:symbols analysis-result)
         user-types (:user-types analysis-result)]
     (binding [emitter/*functions* []
               emitter/*globals-emit* []
               emitter/*globals-declared* #{}
               emitter/*fn-counter* 0
               emitter/*loop-counter* 0
               emitter/*loop-context* nil
               emitter/*keywords* keywords
               emitter/*internal-fn-names* {}
               emitter/*closure-env-param* nil
               emitter/*capture-indices* nil
               emitter/*callable-globals* callable-globals
               emitter/*direct-fn-globals* direct-fn-globals
               emitter/*fn-refs* #{}
               emitter/*closure-funcs* []
               emitter/*builtin-refs* builtin-refs
               emitter/*emitted-fn-names* #{}
               emitter/*strings* strings
               emitter/*symbols* (or symbols {})
               emitter/*repl-mode* repl-mode?
               emitter/*user-types* (or user-types {})]
       (emitter/emit-module ast)))))

(defn- woj-lib-path []
  (try
    (when-let [woj-src (io/resource "woj/main.clj")]
      (let [woj-root (-> (io/file (.toURI woj-src))
                         .getParentFile .getParentFile .getParentFile)]
        (.getPath (io/file woj-root "lib"))))
    (catch Exception _ nil)))

(defn compile-file
  "Compile a woj source file to WAT."
  ([filename] (compile-file filename []))
  ([filename search-paths]
   (let [source (slurp filename)
         ;; Add the file's parent directory and lib/ to search paths
         parent (.getParent (io/file filename))
         lib-path "lib"
         all-paths (distinct (remove nil? (concat [parent lib-path (woj-lib-path)] search-paths)))]
     (compile-string source true false all-paths))))

;; ============================================
;; Main entry point
;; ============================================

(defn- parse-args
  "Parse CLI arguments. Returns {:paths [...] :input-file str}."
  [args]
  (loop [args args
         paths []
         input nil]
    (cond
      (empty? args)
      {:paths paths :input-file input}

      (= (first args) "--path")
      (if (next args)
        (recur (drop 2 args) (conj paths (second args)) input)
        (throw (ex-info "--path requires an argument" {})))

      :else
      ;; First non-flag arg is the input file
      (recur (rest args) paths (or input (first args))))))

(defn -main [& args]
  (if (empty? args)
    (do
      (println "woj - Clojure to WebAssembly compiler")
      (println "")
      (println "Usage: clj -M:run [--path <dir>]... <input.clj>")
      (println "")
      (println "Compiles a woj source file to WAT (WebAssembly Text Format).")
      (println "")
      (println "Options:")
      (println "  --path <dir>  Add directory to namespace search path (repeatable)"))
    (let [{:keys [paths input-file]} (parse-args args)]
      (if input-file
        (println (compile-file input-file paths))
        (binding [*out* *err*]
          (println "Error: no input file specified"))))))
