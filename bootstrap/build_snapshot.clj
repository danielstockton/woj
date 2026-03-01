(ns bootstrap.build-snapshot
  "JVM script that analyzes+emits core libraries and captures all compiler state
   into a snapshot data structure. The snapshot is written as a .clj file that can
   be loaded by the bootstrap compiler, avoiding re-compilation of core at runtime."
  (:require [woj.analyzer :as analyzer]
            [woj.emitter :as emitter]
            [woj.main :as main]
            [clojure.string :as str]))

(defn- load-core-forms
  "Load and read all core library forms."
  []
  (let [core-source (str (or (main/load-core-lib) "") "\n"
                         (or (main/load-edn-lib) "") "\n"
                         (or (main/load-regex-lib) "") "\n")]
    (main/read-all core-source)))

(defn- capture-snapshot
  "Analyze and emit core libraries, capturing all compiler state."
  [core-forms]
  (let [_ (binding [*err* *err*]
            (.println *err* (str "[snapshot] Read " (count core-forms) " core forms")))

        ;; Analyze core forms
        analysis-result (analyzer/analyze-forms core-forms)
        ast (:ast analysis-result)
        _ (binding [*err* *err*]
            (.println *err* (str "[snapshot] Analyzed " (count ast) " ASTs")))

        ;; Set up emitter bindings and emit
        keywords (:keywords analysis-result)
        strings (:strings analysis-result)
        callable-globals (:callable-globals analysis-result)
        direct-fn-globals (:direct-fn-globals analysis-result)
        builtin-refs (:builtin-refs analysis-result)
        symbols (:symbols analysis-result)
        user-types (:user-types analysis-result)]

    ;; Emit core ASTs with proper bindings, then capture emitter state
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
              emitter/*emitted-fn-names* #{"$float_QMARK_"}
              emitter/*strings* strings
              emitter/*symbols* (or symbols {})
              emitter/*repl-mode* false
              emitter/*user-types* (or user-types {})
              emitter/*host-imports* []
              emitter/*host-import-fns* #{}
              emitter/*protocols* {}
              emitter/*protocol-methods* {}
              emitter/*protocol-impls* {}
              emitter/*lifted-fn-inits* []]

      (let [{:keys [init-code]} (emitter/emit-forms ast)
            ;; Collect locals from core top-level code
            start-locals (distinct (mapcat emitter/collect-locals ast))]

        (binding [*err* *err*]
          (.println *err* (str "[snapshot] Emitted " (count emitter/*functions*) " functions, "
                               (count init-code) " init code entries")))

        ;; Build the snapshot map
        {;; Analyzer continuation state
         :keywords (:keywords analysis-result)
         :keyword-count (:keyword-count analysis-result)
         :strings (:strings analysis-result)
         :string-count (:string-count analysis-result)
         :symbols (:symbols analysis-result)
         :symbol-count (:symbol-count analysis-result)
         :callable-globals (:callable-globals analysis-result)
         :direct-fn-globals (:direct-fn-globals analysis-result)
         :fn-refs (:fn-refs analysis-result)
         :builtin-refs (:builtin-refs analysis-result)
         :macros (:macros analysis-result)
         :globals (:globals analysis-result)
         :protocols (:protocols analysis-result)
         :protocol-methods (:protocol-methods analysis-result)
         :protocol-impls (:protocol-impls analysis-result)
         :user-types (:user-types analysis-result)
         :next-type-tag (:next-type-tag analysis-result)
         :dynamic-globals (:dynamic-globals analysis-result)

         ;; Emitter continuation state
         :fn-counter emitter/*fn-counter*
         :closure-funcs emitter/*closure-funcs*
         :lifted-fn-inits emitter/*lifted-fn-inits*
         :fn-refs-emit emitter/*fn-refs*
         :builtin-refs-emit emitter/*builtin-refs*
         :emitted-fn-names emitter/*emitted-fn-names*
         :internal-fn-names emitter/*internal-fn-names*
         :protocol-dispatch-tables emitter/*protocol-dispatch-tables*

         ;; Emitter protocol state
         :emitter-protocols emitter/*protocols*
         :emitter-protocol-methods emitter/*protocol-methods*
         :emitter-protocol-impls emitter/*protocol-impls*

         ;; Pre-compiled WAT fragments (vecs for assemble-module fallback)
         :core-functions emitter/*functions*
         :core-globals emitter/*globals-emit*
         :core-init-code (vec init-code)
         :core-start-locals (vec start-locals)

}))))

(defn- serialize-macros
  "Convert macro fns to their source forms for serialization.
   Macros are Clojure functions that can't be directly serialized.
   We'll store them as nil and rely on re-analyzing macro defs from core."
  [macros]
  ;; Macros are fn objects - not directly serializable.
  ;; The snapshot consumer will need to re-analyze macro definitions.
  ;; For now, store the macro NAMES so we know which globals are macros.
  (into {} (map (fn [[k _]] [k :macro]) macros)))

(defn- serialize-snapshot
  "Convert a snapshot to a pr-str serializable form.
   Functions (macros) are replaced with markers since they can't be serialized."
  [snapshot]
  (-> snapshot
      (update :macros serialize-macros)
      ;; direct-fn-globals values may contain fn objects for multi-arity dispatch
      ;; These are plain data maps, should be serializable as-is
      ))

(defn- write-snapshot-file
  "Write the snapshot as a Clojure namespace file.
   Uses read-string to avoid symbol resolution issues."
  [snapshot]
  (let [serializable (serialize-snapshot snapshot)]
    (println "(ns bootstrap.snapshot-data)")
    (println)
    (println ";; AUTO-GENERATED by bootstrap/build_snapshot.clj")
    (println ";; Do not edit manually.")
    (println)
    (println "(def snapshot (clojure.edn/read-string")
    (println (pr-str (pr-str serializable)))
    (println "))")
    (println)))

(defn- split-string-to-chunks
  "Split a string into chunks of at most max-size bytes."
  [s max-size]
  (if (<= (count s) max-size)
    [s]
    (loop [remaining s
           result []]
      (if (empty? remaining)
        result
        (let [chunk-size (min (count remaining) max-size)]
          (recur (subs remaining chunk-size)
                 (conj result (subs remaining 0 chunk-size))))))))

(defn- write-prejoined-files
  "Run assemble-module for core-only (no user code) and split the resulting WAT
   into sections. The start function body is separated so user init can be appended.

   Produces:
     core-head-N.wat  - everything before the start function (prelude, globals, data, elem, functions)
     core-head-count.txt - number of head chunks
     core-start-header.wat - start function opening + locals
     core-start-body.wat   - start function init code (without closing paren)

   stream-module prints: head chunks, user functions, start header, start body, user init, close."
  [snapshot]
  (let [dir "bootstrap/prejoined"]
    (.mkdirs (java.io.File. dir))
    ;; Generate the full core WAT via assemble-module with empty user code
    ;; Must restore emitter bindings since assemble-module reads dynamic vars
    (let [core-wat (binding [emitter/*builtin-refs* (:builtin-refs-emit snapshot)
                             emitter/*fn-refs* (or (:fn-refs-emit snapshot) #{})
                             emitter/*direct-fn-globals* (:direct-fn-globals snapshot)
                             emitter/*internal-fn-names* (or (:internal-fn-names snapshot) {})
                             emitter/*emitted-fn-names* (or (:emitted-fn-names snapshot) #{})
                             emitter/*fn-counter* (or (:fn-counter snapshot) 0)
                             emitter/*loop-counter* 0
                             emitter/*lifted-fn-inits* (or (:lifted-fn-inits snapshot) [])
                             emitter/*protocol-impls* (or (:emitter-protocol-impls snapshot) {})
                             emitter/*protocol-methods* (or (:emitter-protocol-methods snapshot) {})
                             emitter/*protocols* (or (:emitter-protocols snapshot) {})
                             emitter/*keywords* (:keywords snapshot)
                             emitter/*strings* (:strings snapshot)
                             emitter/*symbols* (or (:symbols snapshot) {})
                             emitter/*user-types* (or (:user-types snapshot) {})
                             emitter/*functions* []
                             emitter/*globals-emit* []
                             emitter/*globals-declared* #{}
                             emitter/*closure-funcs* (or (:closure-funcs snapshot) [])
                             emitter/*host-imports* []
                             emitter/*host-import-fns* #{}]
                    (emitter/assemble-module [] [] {:core-functions (:core-functions snapshot)
                                                    :core-globals (:core-globals snapshot)
                                                    :core-init-code (:core-init-code snapshot)
                                                    :core-start-locals (:core-start-locals snapshot)
                                                    :core-elem-funcs (:closure-funcs snapshot)}))
          ;; Split at the start function marker
          start-marker "\n\n  ;; Initialization\n  (func $start"
          start-idx (str/index-of core-wat start-marker)
          _ (when-not start-idx
              (throw (ex-info "Could not find start function marker in core WAT" {})))
          ;; Head: everything before the start function (prelude + globals + data + elem + functions)
          head (subs core-wat 0 start-idx)
          ;; Start function section (includes "(func $start" through "(start $start)\n)")
          start-section (subs core-wat start-idx)
          ;; Split start function into header (func decl + locals) and body (init code)
          ;; The start function looks like: (func $start\n    (local ...)\n    ...init-code...)\n  (start $start)\n)
          ;; Find the end of locals (first line that doesn't start with "(local")
          start-lines (str/split-lines start-section)
          ;; First line is "" (from the leading \n\n), second is "  ;; Initialization"
          ;; Third is "  (func $start" possibly with locals on subsequent lines
          ;; Find where init code begins (after locals)
          func-start-idx (str/index-of start-section "(func $start")
          after-func-decl (subs start-section func-start-idx)
          ;; Split at first newline after locals
          local-end (loop [pos (str/index-of after-func-decl "\n")]
                      (let [next-line-start (inc pos)
                            next-line (subs after-func-decl next-line-start
                                            (or (str/index-of after-func-decl "\n" next-line-start)
                                                (count after-func-decl)))]
                        (if (str/starts-with? (str/trim next-line) "(local")
                          (recur (str/index-of after-func-decl "\n" next-line-start))
                          next-line-start)))
          start-header (str "\n\n  ;; Initialization\n  " (subs after-func-decl 0 local-end))
          ;; Body is everything from local-end to before the closing ")\n  (start $start)\n)"
          body-and-close (subs after-func-decl local-end)
          ;; Remove the closing ")\n  (start $start)\n)"
          close-marker ")\n  (start $start)\n)"
          close-idx (str/last-index-of body-and-close close-marker)
          start-body (if close-idx
                       (subs body-and-close 0 close-idx)
                       body-and-close)]

      (binding [*err* *err*]
        (.println *err* (str "[snapshot] Core WAT: " (count core-wat) " chars")))

      ;; Write head chunks (everything before start function)
      (let [chunks (split-string-to-chunks head 900000)
            n (count chunks)]
        (binding [*err* *err*]
          (.println *err* (str "[snapshot] Head: " (count head) " chars, " n " chunks")))
        (doseq [i (range n)]
          (spit (str dir "/core-head-" i ".wat") (nth chunks i)))
        (spit (str dir "/core-head-count.txt") (str n)))

      ;; Write start function parts
      (spit (str dir "/core-start-header.wat") start-header)
      (spit (str dir "/core-start-body.wat") start-body))

    (binding [*err* *err*]
      (.println *err* (str "[snapshot] Wrote pre-joined files to " dir "/")))))

(defn- write-prelude-base
  "Generate the static prelude base with a __USER_TYPE_DEFS__ placeholder.
   This is the ~300KB of WAT that never changes between compilations.
   At WASM compile time, the bootstrap compiler loads this file and fills
   the placeholder + other dynamic substitutions, avoiding re-evaluation
   of 10 emit-prelude-N string-literal functions."
  []
  (let [dir "bootstrap/prejoined"
        base (str (emitter/emit-prelude-1)
                  "__USER_TYPE_DEFS__"
                  (emitter/emit-prelude-2) (emitter/emit-prelude-2a)
                  (emitter/emit-prelude-transient) (emitter/emit-prelude-2b)
                  (emitter/emit-prelude-3) (emitter/emit-prelude-3b)
                  (emitter/emit-prelude-3d) (emitter/emit-prelude-sb)
                  (emitter/emit-prelude-3c))]
    (.mkdirs (java.io.File. dir))
    (spit (str dir "/prelude-base.wat") base)
    (binding [*err* *err*]
      (.println *err* (str "[snapshot] Wrote prelude-base.wat (" (count base) " chars)")))))

(defn- write-core-analyzer-state
  "Serialize the analyzer state (minus macros) to EDN.
   This is everything analyze-forms-continuing needs to resume from."
  [analysis-result]
  (let [dir "bootstrap/prejoined"
        state (-> (select-keys analysis-result
                    [:keywords :keyword-count :strings :string-count
                     :symbols :symbol-count :globals :callable-globals
                     :direct-fn-globals :fn-refs :builtin-refs
                     :protocols :protocol-methods :protocol-impls
                     :user-types :next-type-tag :dynamic-globals])
                  (assoc :fn-refs-emit (or (:fn-refs-emit analysis-result) #{})
                         :builtin-refs-emit (or (:builtin-refs-emit analysis-result) #{})
                         :fn-counter (or (:fn-counter analysis-result) 0)
                         :loop-counter (or (:loop-counter analysis-result) 0)
                         :closure-funcs (or (:closure-funcs analysis-result) [])
                         :lifted-fn-inits (or (:lifted-fn-inits analysis-result) [])))]
    (.mkdirs (java.io.File. dir))
    (spit (str dir "/core-analyzer-state.edn") (pr-str state))
    (binding [*err* *err*]
      (.println *err* (str "[snapshot] Wrote core-analyzer-state.edn ("
                           (count (pr-str state)) " chars)")))))

(defn- write-core-macros
  "Extract defmacro forms from core source and write to a separate file.
   These are the only forms that need re-analysis at runtime (since macros
   are functions that can't be serialized to EDN)."
  [core-forms]
  (let [dir "bootstrap/prejoined"
        macro-forms (filterv (fn [form]
                               (and (seq? form)
                                    (contains? #{'defmacro 'defmacro-} (first form))))
                             core-forms)]
    (.mkdirs (java.io.File. dir))
    (spit (str dir "/core-macros.clj")
          (str ";; AUTO-GENERATED by bootstrap/build_snapshot.clj\n"
               ";; Contains only defmacro forms from core.clj for fast re-analysis.\n\n"
               (clojure.string/join "\n\n" (map pr-str macro-forms))
               "\n"))
    (binding [*err* *err*]
      (.println *err* (str "[snapshot] Wrote core-macros.clj (" (count macro-forms) " macros)")))))

(defn -main [& args]
  (let [core-forms (load-core-forms)
        snapshot (capture-snapshot core-forms)]
    (write-snapshot-file snapshot)
    (write-prejoined-files snapshot)
    (write-prelude-base)
    ;; Phase 2: pre-analyzed core state for batch mode
    (write-core-analyzer-state snapshot)
    (write-core-macros core-forms)))
