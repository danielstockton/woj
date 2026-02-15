Run the woj compiler test suite.

Steps:
1. Run the compiler unit tests: `clj -M:test`
2. Show the test output
3. Run a quick smoke test through the full pipeline (compile to WAT, run with wasmtime):
   ```
   echo '(defn test-smoke [] (+ 20 22))' > /tmp/smoke.clj
   clj -M:run /tmp/smoke.clj > /tmp/smoke.wat
   wasmtime -W gc=y -W function-references=y --invoke test-smoke /tmp/smoke.wat
   ```
   Expected output: 42
4. Run the Clojure compatibility test suite files that are expected to pass. For each file:
   ```
   clj -M:run test/clojure-test-suite/test/clojure/core_test/<file>.cljc > /tmp/test.wat 2>&1
   wasmtime -W gc=y -W function-references=y --invoke run-all-tests /tmp/test.wat
   ```
   Output: 0 = all tests pass, >0 = failure count
   If compilation fails, note the error and continue.

   Key test files to run (in order):
   - eq.cljc (equality)
   - nil_qmark.cljc (nil?)
   - true_qmark.cljc (true?)
   - false_qmark.cljc (false?)
   - not.cljc (not)
   - and.cljc (and)
   - or.cljc (or)
   - cons.cljc (cons)
   - first.cljc (first)
   - rest.cljc (rest)
   - count.cljc (count)
   - conj.cljc (conj)
   - nth.cljc (nth)
   - assoc.cljc (assoc)
   - dissoc.cljc (dissoc)
   - get.cljc (get)
   - contains_qmark.cljc (contains?)
   - keys.cljc (keys)
   - vals.cljc (vals)
   - atom.cljc (atom)
   - reduce.cljc (reduce)
   - empty_qmark.cljc (empty?)

5. Report summary: how many unit tests passed, how many clojure test suite files passed/failed/errored
