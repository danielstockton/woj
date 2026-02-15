(ns woj.repl
  (:require [woj.main :as main]
            [clojure.java.io :as io]
            [clojure.string :as string])
  (:import [java.io BufferedReader InputStreamReader]))

;; ============================================
;; REPL State
;; ============================================

(defn make-repl-state []
  (atom {:accumulated-forms []}))

(def ^:private repl-state (make-repl-state))

;; ============================================
;; Form Classification
;; ============================================

(def ^:private def-like-ops
  #{'def 'defn 'defmacro 'defprotocol 'extend-type 'extend-protocol})

(defn- def-like? [form]
  (and (seq? form)
       (contains? def-like-ops (first form))))

(defn- def-name [form]
  (when (and (seq? form) (>= (count form) 2))
    (second form)))

;; ============================================
;; Paren Balancing
;; ============================================

(defn- balanced? [s]
  (let [depth (atom 0)
        in-string (atom false)
        escape (atom false)]
    (doseq [c s]
      (cond
        @escape (reset! escape false)
        (= c \\) (when @in-string (reset! escape true))
        (= c \") (swap! in-string not)
        @in-string nil
        (= c \() (swap! depth inc)
        (= c \)) (swap! depth dec)
        (= c \[) (swap! depth inc)
        (= c \]) (swap! depth dec)
        (= c \{) (swap! depth inc)
        (= c \}) (swap! depth dec)))
    (<= @depth 0)))

;; ============================================
;; Wasmtime Execution
;; ============================================

(def ^:private wat-path "/tmp/woj-repl.wat")

(defn- run-wasmtime [wat-source]
  (spit wat-path wat-source)
  (let [proc (.exec (Runtime/getRuntime)
                    (into-array String ["wasmtime" "-W" "gc=y" "-W" "function-references=y"
                                        "-W" "exceptions=y" wat-path]))
        stdout (slurp (.getInputStream proc))
        stderr (slurp (.getErrorStream proc))
        exit (.waitFor proc)]
    {:exit exit :stdout stdout :stderr (string/trim stderr)}))

;; ============================================
;; REPL pr-str prelude (compiled to WASM)
;; ============================================

;; Forward declarations needed so recursive helpers can reference each other.
;; Define helpers first, then __repl-pr-str last (it calls the helpers,
;; and the helpers call it back via the global).
(def ^:private repl-prelude
  "(def __repl-pr-str nil)

(defn __repl-pr-coll [open close s]
  (if (nil? s)
    (str open close)
    (loop [result (str open (__repl-pr-str (first s)))
           remaining (rest s)]
      (if (nil? (seq remaining))
        (str result close)
        (recur (str result \" \" (__repl-pr-str (first remaining)))
               (rest remaining))))))

(defn __repl-pr-map [m]
  (let [ks (keys m)]
    (if (nil? (seq ks))
      \"{}\"
      (loop [result (str \"{\" (__repl-pr-str (first ks)) \" \" (__repl-pr-str (get m (first ks))))
             remaining (rest ks)]
        (if (nil? (seq remaining))
          (str result \"}\")
          (recur (str result \", \" (__repl-pr-str (first remaining)) \" \" (__repl-pr-str (get m (first remaining))))
                 (rest remaining)))))))

(set! __repl-pr-str (fn [x]
  (cond
    (nil? x) \"nil\"
    (integer? x) (str x)
    (string? x) (str \"\\\"\" x \"\\\"\")
    (keyword? x) (str \":\" (name x))
    (float? x) (str x)
    (vector? x) (__repl-pr-coll \"[\" \"]\" (seq x))
    (map? x) (__repl-pr-map x)
    (set? x) (__repl-pr-coll \"#{\" \"}\" (seq x))
    (cons? x) (__repl-pr-coll \"(\" \")\" x)
    (lazy-seq? x) (__repl-pr-coll \"(\" \")\" (seq x))
    (fn? x) \"#<fn>\"
    (atom? x) (str \"#<atom \" (__repl-pr-str (deref x)) \">\")
    :else (str x))))")

;; ============================================
;; Eval
;; ============================================

(defn eval-string
  "Evaluate a string of woj code. Returns {:value string :error string}.
   Uses the given state atom or the default repl-state."
  ([input] (eval-string input repl-state))
  ([input state]
   (try
     (let [forms (main/read-all input)
           defs (filter def-like? forms)
           exprs (remove def-like? forms)
           ;; Build accumulated source
           accumulated (:accumulated-forms @state)
           accumulated-src (string/join "\n" accumulated)
           ;; New defs to add
           new-def-strs (mapv pr-str defs)
           ;; Non-def exprs that aren't the last (for side effects)
           side-effect-exprs (if (seq exprs) (butlast exprs) [])
           side-effect-src (string/join "\n" (map pr-str side-effect-exprs))
           ;; Build the eval wrapper - wrap in __repl-pr-str for display
           eval-body (cond
                       (seq exprs) (str "(__repl-pr-str " (pr-str (last exprs)) ")")
                       (seq defs) "\"\"" ;; defs only - empty string, we show #'name
                       :else "\"nil\"")
           eval-fn (str "(defn __repl_eval [] " eval-body ")")
           ;; Full source: accumulated + pr-str prelude + new defs + side effects + eval fn
           full-source (str accumulated-src "\n"
                            repl-prelude "\n"
                            (string/join "\n" new-def-strs) "\n"
                            side-effect-src "\n"
                            eval-fn)
           wat (main/compile-string full-source true true)
           result (run-wasmtime wat)]
       (if (zero? (:exit result))
         (do
           (when (seq defs)
             (swap! state update :accumulated-forms
                    into new-def-strs))
           (let [display (if (and (seq defs) (empty? exprs))
                           (str "#'" (def-name (last defs)))
                           (:stdout result))]
             {:value display}))
         {:error (if (not (string/blank? (:stderr result)))
                   (:stderr result)
                   (:stdout result))}))
     (catch Exception e
       {:error (str (.getMessage e))}))))

;; ============================================
;; Terminal REPL
;; ============================================

(defn- read-input [reader]
  (print "woj=> ")
  (flush)
  (loop [input ""]
    (if-let [line (.readLine reader)]
      (let [new-input (if (empty? input) line (str input "\n" line))]
        (if (balanced? new-input)
          new-input
          (do
            (print "  ... ")
            (flush)
            (recur new-input))))
      nil)))

(defn start-repl
  "Start an interactive REPL session."
  ([] (start-repl repl-state))
  ([state]
   (println "woj REPL - Clojure to WebAssembly")
   (println "Type :quit to exit, :reset to clear state")
   (println)
   (let [reader (BufferedReader. (InputStreamReader. System/in))]
     (loop []
       (when-let [input (read-input reader)]
         (let [trimmed (string/trim input)]
           (cond
             (empty? trimmed) (recur)
             (= trimmed ":quit") (println "Bye!")
             (= trimmed ":reset") (do (reset! state {:accumulated-forms []})
                                      (println "State cleared.")
                                      (recur))
             :else (let [result (eval-string trimmed state)]
                     (if (:error result)
                       (println (str "Error: " (:error result)))
                       (println (:value result)))
                     (recur)))))))))

(defn -main [& _args]
  (start-repl))
