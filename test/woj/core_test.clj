(ns woj.core-test
  "Tests for the woj compiler."
  (:require [woj.analyzer :as analyzer]
            [woj.emitter :as emitter]
            [woj.main :as main]
            [woj.util :as util]))

;; Helper for string containment
(defn str-contains? [s substr]
  (.contains s substr))

;; ============================================
;; Util tests
;; ============================================

(defn test-munge-name []
  (println "Testing munge-name...")
  ;; Operators
  (assert (= (util/munge-name '+) "_PLUS_"))
  (assert (= (util/munge-name '-) "_MINUS_"))
  (assert (= (util/munge-name '<=) "_LT__EQ_"))
  (println "  PASS: operator munging")
  ;; Character replacements
  (assert (= (util/munge-name 'my-func) "my_func"))
  (assert (= (util/munge-name 'valid?) "valid_QMARK_"))
  (assert (= (util/munge-name 'reset!) "reset_BANG_"))
  (assert (= (util/munge-name 'x') "x_PRIME_"))
  (assert (= (util/munge-name 'my-long-name?) "my_long_name_QMARK_"))
  (println "  PASS: character replacements"))

;; ============================================
;; Analyzer tests
;; ============================================

(defn test-analyze-const []
  (println "Testing analyze-const...")
  (let [result (binding [analyzer/*globals* #{}
                         analyzer/*env* {}]
                 (analyzer/analyze 42))]
    (assert (= (:op result) :const))
    (assert (= (:val result) 42))
    (assert (= (:type result) :int))
    (println "  PASS: integer constant")))

(defn test-analyze-def []
  (println "Testing analyze-def...")
  (let [result (binding [analyzer/*globals* #{}
                         analyzer/*env* {}
                         analyzer/*callable-globals* #{}]
                 (analyzer/analyze '(def x 42)))]
    (assert (= (:op result) :def))
    (assert (= (:name result) 'x))
    (assert (= (:op (:init result)) :const))
    (println "  PASS: def with constant")))

(defn test-analyze-fn []
  (println "Testing analyze-fn...")
  (let [result (binding [analyzer/*globals* #{}
                         analyzer/*env* {}
                         analyzer/*enclosing-locals* #{}
                         analyzer/*capture-map* nil]
                 (analyzer/analyze '(fn [x] x)))]
    (assert (= (:op result) :fn))
    (assert (= (:params result) '[x]))
    (assert (= (:op (:body result)) :local))
    (println "  PASS: identity function")))

(defn test-analyze-let []
  (println "Testing analyze-let...")
  (let [result (binding [analyzer/*globals* #{}
                         analyzer/*env* {}
                         analyzer/*enclosing-locals* #{}
                         analyzer/*capture-map* nil]
                 (analyzer/analyze '(let [x 1] x)))]
    (assert (= (:op result) :let))
    (assert (= (count (:bindings result)) 1))
    (assert (= (:op (:body result)) :local))
    (println "  PASS: simple let")))

(defn test-analyze-if []
  (println "Testing analyze-if...")
  (let [result (binding [analyzer/*globals* #{'a}
                         analyzer/*env* {}]
                 (analyzer/analyze '(if a 1 2)))]
    (assert (= (:op result) :if))
    (assert (= (:op (:test result)) :global))
    (assert (= (:op (:then result)) :const))
    (assert (= (:op (:else result)) :const))
    (println "  PASS: if expression")))

(defn test-analyze-call []
  (println "Testing analyze-call...")
  (let [env {'x {:kind :local} 'y {:kind :local}}
        result (binding [analyzer/*globals* #{}
                         analyzer/*env* env]
                 (analyzer/analyze '(+ x y)))]
    (assert (= (:op result) :call))
    (assert (= (:op (:fn result)) :builtin))
    (assert (= (count (:args result)) 2))
    (println "  PASS: builtin call")))

;; ============================================
;; Emitter tests
;; ============================================

(defn test-emit-const []
  (println "Testing emit-const...")
  (binding [emitter/*functions* []
            emitter/*globals-emit* []
            emitter/*fn-counter* 0
            emitter/*loop-counter* 0
            emitter/*closure-env-param* nil
            emitter/*capture-indices* nil
            emitter/*emitted-fn-names* #{}]
    (let [ast {:op :const :val 42 :type :int}
          result (emitter/emit ast)]
      ;; Constants are now boxed (ref.i31 wrapping i32.const)
      (assert (str-contains? result "i32.const"))
      (assert (str-contains? result "42"))
      (assert (str-contains? result "ref.i31"))
      (println "  PASS: emit boxed constant"))))

(defn test-emit-call []
  (println "Testing emit-call...")
  (binding [emitter/*functions* []
            emitter/*globals-emit* []
            emitter/*fn-counter* 0
            emitter/*loop-counter* 0
            emitter/*closure-env-param* nil
            emitter/*capture-indices* nil
            emitter/*emitted-fn-names* #{}]
    (let [ast {:op :call
               :fn {:op :builtin :name '+}
               :args [{:op :const :val 1 :type :int}
                      {:op :const :val 2 :type :int}]}
          result (emitter/emit ast)]
      ;; + now generates a call to polymorphic $add
      (assert (str-contains? result "call $add"))
      (println "  PASS: emit arithmetic with polymorphic add"))))

;; ============================================
;; Integration tests
;; ============================================

(defn test-compile-simple []
  (println "Testing compile-simple...")
  (let [source "(def x 42)"
        result (main/compile-string source)]
    (assert (str-contains? result "module"))
    (assert (str-contains? result "global"))
    (println "  PASS: compile simple def")))

(defn test-compile-fn []
  (println "Testing compile-fn...")
  (let [source "(def double (fn [x] (+ x x)))"
        result (main/compile-string source)]
    (assert (str-contains? result "module"))
    (assert (str-contains? result "func $double"))
    ;; + now generates inline i32.add, not a call
    (assert (str-contains? result "i32.add"))
    (println "  PASS: compile function def")))

(defn test-compile-let []
  (println "Testing compile-let...")
  (let [source "(def foo (fn [a] (let [b (+ a 1)] b)))"
        result (main/compile-string source)]
    (assert (str-contains? result "local.set"))
    (assert (str-contains? result "local.get"))
    (println "  PASS: compile let")))

(defn test-compile-hyphenated-name []
  (println "Testing compile-hyphenated-name...")
  (let [source "(def my-func (fn [x] x))"
        result (main/compile-string source)]
    (assert (str-contains? result "func $my_func"))
    (println "  PASS: hyphenated name compiles to underscore")))

(defn test-compile-predicate-name []
  (println "Testing compile-predicate-name...")
  (let [source "(def valid? (fn [x] x))"
        result (main/compile-string source)]
    (assert (str-contains? result "func $valid_QMARK_"))
    (println "  PASS: predicate name compiles with _QMARK_")))

(defn test-compile-nested-let-in-if []
  (println "Testing compile-nested-let-in-if...")
  (let [source "(def foo (fn [x] (if x (let [y 1] y) (let [z 2] z))))"
        result (main/compile-string source)]
    ;; Should have both y and z as locals
    (assert (str-contains? result "local $y"))
    (assert (str-contains? result "local $z"))
    (println "  PASS: nested let in if branches")))

(defn test-analyze-booleans []
  (println "Testing analyze-booleans...")
  (let [true-result (binding [analyzer/*globals* #{}
                              analyzer/*env* {}]
                      (analyzer/analyze true))
        false-result (binding [analyzer/*globals* #{}
                               analyzer/*env* {}]
                       (analyzer/analyze false))]
    (assert (= (:op true-result) :const))
    (assert (= (:val true-result) 1))
    (assert (= (:type true-result) :bool))
    (assert (= (:val false-result) 0))
    (println "  PASS: true/false analysis")))

(defn test-compile-not []
  (println "Testing compile-not...")
  (let [source "(def invert (fn [x] (not x)))"
        result (main/compile-string source)]
    ;; not now generates inline i32.eqz with boxing
    (assert (str-contains? result "i32.eqz"))
    (println "  PASS: not compiles correctly")))

(defn test-analyze-loop []
  (println "Testing analyze-loop...")
  (let [result (binding [analyzer/*globals* #{}
                         analyzer/*env* {}
                         analyzer/*loop-bindings* nil
                         analyzer/*enclosing-locals* #{}
                         analyzer/*capture-map* nil]
                 (analyzer/analyze '(loop [x 0] x)))]
    (assert (= (:op result) :loop))
    (assert (= (count (:bindings result)) 1))
    (assert (= (:name (first (:bindings result))) 'x))
    (println "  PASS: loop analysis")))

(defn test-compile-loop []
  (println "Testing compile-loop...")
  (let [source "(def count-to (fn [n] (loop [x 0] (if (< x n) (recur (+ x 1)) x))))"
        result (main/compile-string source)]
    (assert (str-contains? result "loop $loop"))
    (assert (str-contains? result "br $loop"))
    (println "  PASS: loop/recur compiles")))

(defn test-compile-defn []
  (println "Testing compile-defn...")
  (let [source "(defn double [x] (+ x x))"
        result (main/compile-string source)]
    (assert (str-contains? result "func $double"))
    ;; + now generates inline i32.add
    (assert (str-contains? result "i32.add"))
    (println "  PASS: defn compiles")))

(defn test-compile-cond []
  (println "Testing compile-cond...")
  (let [source "(defn classify [x] (cond (< x 0) -1 (> x 0) 1 :else 0))"
        result (main/compile-string source)]
    (assert (str-contains? result "func $classify"))
    ;; if now returns anyref
    (assert (str-contains? result "if (result anyref)"))
    (println "  PASS: cond compiles")))

(defn test-compile-inc-dec []
  (println "Testing compile-inc-dec...")
  (let [source "(defn bump [x] (inc (dec x)))"
        result (main/compile-string source)]
    ;; inc/dec now generate inline arithmetic with boxing
    (assert (str-contains? result "i32.add"))
    (assert (str-contains? result "i32.sub"))
    (println "  PASS: inc/dec compile")))

(defn test-compile-predicates []
  (println "Testing compile-predicates...")
  (let [source "(defn sign [x] (cond (neg? x) -1 (pos? x) 1 (zero? x) 0 :else 0))"
        result (main/compile-string source)]
    ;; Predicates now generate inline comparisons with boxing
    (assert (str-contains? result "i32.lt_s"))  ;; neg?
    (assert (str-contains? result "i32.gt_s"))  ;; pos?
    (assert (str-contains? result "i32.eqz"))   ;; zero?
    (println "  PASS: predicates compile")))

(defn test-compile-not-eq []
  (println "Testing compile-not-eq...")
  (let [source "(defn diff? [a b] (not= a b))"
        result (main/compile-string source)]
    ;; not= now generates inline i32.ne with boxing
    (assert (str-contains? result "i32.ne"))
    (println "  PASS: not= compiles")))

(defn test-error-unknown-symbol []
  (println "Testing error-unknown-symbol...")
  (try
    (binding [analyzer/*globals* #{}
              analyzer/*env* {}
              analyzer/*loop-bindings* nil
              analyzer/*enclosing-locals* #{}
              analyzer/*capture-map* nil]
      (analyzer/analyze 'undefined-var))
    (assert false "Should have thrown")
    (catch Exception e
      (assert (str-contains? (.getMessage e) "Unknown symbol: undefined-var"))
      (println "  PASS: unknown symbol error message"))))

(defn test-analyze-defn []
  (println "Testing analyze-defn...")
  (let [result (binding [analyzer/*globals* #{}
                         analyzer/*env* {}
                         analyzer/*enclosing-locals* #{}
                         analyzer/*capture-map* nil
                         analyzer/*callable-globals* #{}
                         analyzer/*direct-fn-globals* {}]
                 (analyzer/analyze '(defn foo [x] x)))]
    (assert (= (:op result) :def))
    (assert (= (:name result) 'foo))
    (assert (= (:op (:init result)) :fn))
    (assert (= (:params (:init result)) '[x]))
    (println "  PASS: defn analysis")))

(defn test-analyze-keyword []
  (println "Testing analyze-keyword...")
  (let [result (binding [analyzer/*globals* #{}
                         analyzer/*env* {}
                         analyzer/*keywords* {}
                         analyzer/*keyword-counter* 0
                         analyzer/*enclosing-locals* #{}
                         analyzer/*capture-map* nil]
                 (analyzer/analyze :foo))]
    (assert (= (:op result) :keyword))
    (assert (= (:name result) :foo))
    (assert (= (:id result) 0))
    (println "  PASS: keyword analysis")))

(defn test-analyze-cond []
  (println "Testing analyze-cond...")
  (let [result (binding [analyzer/*globals* #{'x}
                         analyzer/*env* {}
                         analyzer/*keywords* {}
                         analyzer/*keyword-counter* 0
                         analyzer/*enclosing-locals* #{}
                         analyzer/*capture-map* nil]
                 (analyzer/analyze '(cond (= x 1) 10 (= x 2) 20 :else 30)))]
    (assert (= (:op result) :if))
    ;; First clause test
    (assert (= (:op (:test result)) :call))
    ;; Then branch
    (assert (= (:val (:then result)) 10))
    ;; Else is nested if
    (assert (= (:op (:else result)) :if))
    (println "  PASS: cond analysis")))

(defn test-analyze-closure []
  (println "Testing analyze-closure...")
  ;; Test that closures are detected correctly
  (let [result (analyzer/analyze-forms '[(defn make-adder [x] (fn [y] (+ x y)))])
        defn-ast (first (:ast result))
        outer-fn (:init defn-ast)
        inner-fn (:body outer-fn)]
    (assert (= (:op defn-ast) :def))
    (assert (= (:op outer-fn) :fn))
    (assert (= (:op inner-fn) :fn))
    (assert (:is-closure inner-fn) "Inner fn should be a closure")
    (assert (= (:captures inner-fn) '[x]) "Inner fn should capture x")
    (println "  PASS: closure detection")))

(defn test-analyze-nested-closure []
  (println "Testing analyze-nested-closure...")
  ;; Test nested closures capture correctly
  (let [result (analyzer/analyze-forms '[(defn curry [x] (fn [y] (fn [z] (+ x (+ y z)))))])
        defn-ast (first (:ast result))
        outer-fn (:init defn-ast)
        middle-fn (:body outer-fn)
        inner-fn (:body middle-fn)]
    (assert (:is-closure middle-fn) "Middle fn should be a closure")
    (assert (= (:captures middle-fn) '[x]) "Middle fn should capture x")
    (assert (:is-closure inner-fn) "Inner fn should be a closure")
    (assert (= (:captures inner-fn) '[x y]) "Inner fn should capture x and y")
    (println "  PASS: nested closure detection")))

(defn test-analyze-recursive-fn []
  (println "Testing analyze-recursive-fn...")
  ;; Test that recursive function can reference itself
  (let [result (analyzer/analyze-forms '[(defn factorial [n]
                                           (if (<= n 1)
                                             1
                                             (* n (factorial (- n 1)))))])
        defn-ast (first (:ast result))]
    (assert (= (:op defn-ast) :def))
    (assert (= (:name defn-ast) 'factorial))
    (assert (= (:op (:init defn-ast)) :fn))
    (println "  PASS: recursive function analysis")))

(defn test-compile-closure []
  (println "Testing compile-closure...")
  (let [source "(defn make-adder [x] (fn [y] (+ x y)))"
        result (main/compile-string source)]
    (assert (str-contains? result "Closure") "Should have Closure types")
    (assert (str-contains? result "$ClosureFunc1") "Should have ClosureFunc1 type")
    (assert (str-contains? result "invoke1") "Should have invoke1")
    (println "  PASS: closure compiles")))

(defn test-compile-recursive-fn []
  (println "Testing compile-recursive-fn...")
  (let [source "(defn factorial [n] (if (<= n 1) 1 (* n (factorial (- n 1)))))"
        result (main/compile-string source)]
    (assert (str-contains? result "func $factorial"))
    (assert (str-contains? result "call $factorial") "Should have recursive call")
    (println "  PASS: recursive function compiles")))

(defn test-analyze-thread-first []
  (println "Testing analyze-thread-first...")
  ;; (-> x (f a)) should become (f x a)
  (let [expanded (analyzer/expand-thread-first '(-> 1 (+ 2)))]
    (assert (= expanded '(+ 1 2)) "Should thread as first arg"))
  ;; (-> x f) should become (f x)
  (let [expanded (analyzer/expand-thread-first '(-> 1 inc))]
    (assert (= expanded '(inc 1)) "Should wrap bare symbol"))
  ;; (-> x (f a) (g b)) should become (g (f x a) b)
  (let [expanded (analyzer/expand-thread-first '(-> 1 (+ 2) (* 3)))]
    (assert (= expanded '(* (+ 1 2) 3)) "Should chain threading"))
  (println "  PASS: thread-first expansion"))

(defn test-analyze-thread-last []
  (println "Testing analyze-thread-last...")
  ;; (->> x (f a)) should become (f a x)
  (let [expanded (analyzer/expand-thread-last '(->> 1 (+ 2)))]
    (assert (= expanded '(+ 2 1)) "Should thread as last arg"))
  ;; (->> x (f a) (g b)) should become (g b (f a x))
  (let [expanded (analyzer/expand-thread-last '(->> 1 (cons nil) (cons nil)))]
    (assert (= expanded '(cons nil (cons nil 1))) "Should chain threading"))
  (println "  PASS: thread-last expansion"))

(defn test-analyze-variadic-assoc []
  (println "Testing analyze-variadic-assoc...")
  ;; (assoc m :a 1 :b 2) should expand to nested assocs
  (let [expanded (analyzer/expand-variadic-assoc '(assoc m :a 1 :b 2))]
    (assert (= expanded '(assoc (assoc m :a 1) :b 2)) "Should expand to nested assocs"))
  ;; Simple assoc should not be expanded
  (let [expanded (analyzer/expand-variadic-assoc '(assoc m :a 1))]
    (assert (= expanded '(assoc m :a 1)) "Simple assoc should not expand"))
  (println "  PASS: variadic assoc expansion"))

(defn test-compile-thread-first []
  (println "Testing compile-thread-first...")
  (let [source "(defn add-mul [x] (-> x (+ 1) (* 2)))"
        result (main/compile-string source)]
    (assert (str-contains? result "func $add_mul"))
    (assert (str-contains? result "i32.add"))
    (assert (str-contains? result "i32.mul"))
    (println "  PASS: thread-first compiles")))

(defn test-compile-variadic-assoc []
  (println "Testing compile-variadic-assoc...")
  (let [source "(defn multi-assoc [m] (assoc m :a 1 :b 2))"
        result (main/compile-string source)]
    (assert (str-contains? result "func $multi_assoc"))
    ;; Should have two hash_map_assoc calls (nested)
    (assert (str-contains? result "hash_map_assoc"))
    (println "  PASS: variadic assoc compiles")))

;; ============================================
;; Test runner
;; ============================================

(defn run-all-tests []
  (println "")
  (println "=== woj compiler tests ===")
  (println "")

  (println "--- Util tests ---")
  (test-munge-name)
  (println "")

  (println "--- Analyzer tests ---")
  (test-analyze-const)
  (test-analyze-def)
  (test-analyze-fn)
  (test-analyze-let)
  (test-analyze-if)
  (test-analyze-call)
  (test-analyze-booleans)
  (test-analyze-loop)
  (test-analyze-defn)
  (test-analyze-keyword)
  (test-analyze-cond)
  (test-analyze-closure)
  (test-analyze-nested-closure)
  (test-analyze-recursive-fn)
  (test-analyze-thread-first)
  (test-analyze-thread-last)
  (test-analyze-variadic-assoc)
  (test-error-unknown-symbol)
  (println "")

  (println "--- Emitter tests ---")
  (test-emit-const)
  (test-emit-call)
  (println "")

  (println "--- Integration tests ---")
  (test-compile-simple)
  (test-compile-fn)
  (test-compile-let)
  (test-compile-hyphenated-name)
  (test-compile-predicate-name)
  (test-compile-nested-let-in-if)
  (test-compile-not)
  (test-compile-loop)
  (test-compile-defn)
  (test-compile-cond)
  (test-compile-inc-dec)
  (test-compile-predicates)
  (test-compile-not-eq)
  (test-compile-closure)
  (test-compile-recursive-fn)
  (test-compile-thread-first)
  (test-compile-variadic-assoc)
  (println "")

  (println "=== All tests passed! ==="))

(defn -main [& args]
  (run-all-tests))
