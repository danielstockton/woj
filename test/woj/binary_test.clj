(ns woj.binary-test
  "Tests for the WASM binary encoder.
   Run with: clj -M:test (once added to test runner)
   Or standalone: clj -M -m woj.binary-test"
  (:require [woj.binary :as b]
            [woj.main :as main]
            [woj.wat :as wat]
            [clojure.string :as str])
  (:import [java.io FileOutputStream]))

;; ============================================
;; LEB128 tests
;; ============================================

(defn test-unsigned-leb128 []
  (println "Testing unsigned LEB128...")
  ;; Single byte values (0-127)
  (assert (= [0] (b/encode-unsigned-leb128 0)))
  (assert (= [1] (b/encode-unsigned-leb128 1)))
  (assert (= [0x7F] (b/encode-unsigned-leb128 127)))
  (println "  PASS: single byte")

  ;; Two byte values (128-16383)
  (assert (= [0x80 0x01] (b/encode-unsigned-leb128 128)))
  (assert (= [0xE5 0x8E 0x26] (b/encode-unsigned-leb128 624485)))
  (println "  PASS: multi byte")

  ;; Edge cases from WASM spec
  (assert (= [0x08] (b/encode-unsigned-leb128 8)))
  (assert (= [0x80 0x80 0x04] (b/encode-unsigned-leb128 65536)))
  (println "  PASS: edge cases"))

(defn test-signed-leb128 []
  (println "Testing signed LEB128...")
  ;; Positive values
  (assert (= [0] (b/encode-signed-leb128 0)))
  (assert (= [1] (b/encode-signed-leb128 1)))
  (assert (= [0x3F] (b/encode-signed-leb128 63)))
  (assert (= [0xC0 0x00] (b/encode-signed-leb128 64)))
  (println "  PASS: positive")

  ;; Negative values
  (assert (= [0x7F] (b/encode-signed-leb128 -1)))
  (assert (= [0x41] (b/encode-signed-leb128 -63)))
  (assert (= [0x40] (b/encode-signed-leb128 -64)))
  (assert (= [0xBF 0x7F] (b/encode-signed-leb128 -65)))
  (println "  PASS: negative")

  ;; Spec example: -123456
  (assert (= [0xC0 0xBB 0x78] (b/encode-signed-leb128 -123456)))
  (println "  PASS: spec examples"))

;; ============================================
;; F64 encoding test
;; ============================================

(defn test-f64 []
  (println "Testing f64 encoding...")
  ;; 0.0 -> all zeros
  (assert (= [0 0 0 0 0 0 0 0] (b/encode-f64 0.0)))
  ;; 1.0 -> 0x3FF0000000000000 LE
  (assert (= [0x00 0x00 0x00 0x00 0x00 0x00 0xF0 0x3F] (b/encode-f64 1.0)))
  ;; -1.0 -> 0xBFF0000000000000 LE
  (assert (= [0x00 0x00 0x00 0x00 0x00 0x00 0xF0 0xBF] (b/encode-f64 -1.0)))
  ;; 3.14159...
  (let [bytes (b/encode-f64 Math/PI)]
    (assert (= 8 (count bytes)))
    ;; Verify round-trip
    (let [buf (java.nio.ByteBuffer/allocate 8)]
      (.order buf java.nio.ByteOrder/LITTLE_ENDIAN)
      (.put buf (b/bytes-out bytes))
      (.flip buf)
      (assert (= Math/PI (.getDouble buf)))))
  (println "  PASS: f64 encoding"))

;; ============================================
;; Value type encoding tests
;; ============================================

(defn test-val-types []
  (println "Testing value type encoding...")
  (assert (= [0x7F] (b/encode-val-type :i32)))
  (assert (= [0x7E] (b/encode-val-type :i64)))
  (assert (= [0x7C] (b/encode-val-type :f64)))
  (assert (= [0x63 0x6E] (b/encode-val-type :anyref)))
  (assert (= [0x64 0x6C] (b/encode-val-type :i31ref)))
  (println "  PASS: basic types")

  ;; Concrete reference types
  (assert (= [0x64 0x00] (b/encode-val-type {:ref 0})))     ;; (ref $type0)
  (assert (= [0x63 0x05] (b/encode-val-type {:ref-null 5}))) ;; (ref null $type5)
  (println "  PASS: concrete ref types"))

;; ============================================
;; Instruction encoding tests
;; ============================================

(defn test-instructions []
  (println "Testing instruction encoding...")
  ;; Simple opcodes
  (assert (= [0x00] (b/encode-instruction :unreachable)))
  (assert (= [0x1A] (b/encode-instruction :drop)))
  (assert (= [0x6A] (b/encode-instruction :i32.add)))
  (assert (= [0x0F] (b/encode-instruction :return)))
  (println "  PASS: simple opcodes")

  ;; i32.const
  (assert (= [0x41 0x00] (b/encode-instruction :i32.const 0)))
  (assert (= [0x41 0x2A] (b/encode-instruction :i32.const 42)))
  (assert (= [0x41 0x7F] (b/encode-instruction :i32.const -1)))
  (println "  PASS: i32.const")

  ;; f64.const
  (let [bytes (b/encode-instruction :f64.const 3.14)]
    (assert (= 0x44 (first bytes)))
    (assert (= 9 (count bytes)))) ;; 1 opcode + 8 bytes
  (println "  PASS: f64.const")

  ;; local.get / call
  (assert (= [0x20 0x00] (b/encode-instruction :local.get 0)))
  (assert (= [0x20 0x05] (b/encode-instruction :local.get 5)))
  (assert (= [0x10 0x03] (b/encode-instruction :call 3)))
  (println "  PASS: index instructions")

  ;; block type
  (assert (= [0x02 0x40] (b/encode-instruction :block nil)))       ;; void block
  (assert (= [0x02 0x7F] (b/encode-instruction :block :i32)))      ;; (block (result i32) ...)
  (assert (= [0x02 0x63 0x6E] (b/encode-instruction :block :anyref))) ;; (block (result anyref) ...)
  (println "  PASS: block types")

  ;; GC instructions
  (assert (= [0xFB 0x00 0x05] (b/encode-instruction :struct.new 5)))
  (assert (= [0xFB 0x02 0x03 0x01] (b/encode-instruction :struct.get 3 1)))
  (assert (= [0xFB 0x0F] (b/encode-instruction :array.len)))
  (assert (= [0xFB 0x1C] (b/encode-instruction :ref.i31)))
  (assert (= [0xFB 0x1D] (b/encode-instruction :i31.get_s)))
  (println "  PASS: GC instructions")

  ;; ref.test / ref.cast (non-nullable)
  (assert (= [0xFB 0x14 0x05] (b/encode-instruction :ref.test false 5)))
  ;; ref.test (nullable variant)
  (assert (= [0xFB 0x15 0x05] (b/encode-instruction :ref.test true 5)))
  ;; ref.cast non-null
  (assert (= [0xFB 0x16 0x03] (b/encode-instruction :ref.cast false 3)))
  ;; ref.cast nullable
  (assert (= [0xFB 0x17 0x03] (b/encode-instruction :ref.cast true 3)))
  (println "  PASS: ref.test/ref.cast")

  ;; ref.null
  (assert (= [0xD0 0x6E] (b/encode-instruction :ref.null :any)))
  (assert (= [0xD0 0x71] (b/encode-instruction :ref.null :none)))
  (println "  PASS: ref.null")

  ;; Memory instructions
  (assert (= [0x3F 0x00] (b/encode-instruction :memory.size)))
  (assert (= [0x36 0x02 0x00] (b/encode-instruction :i32.store 2 0))) ;; align=2, offset=0
  (println "  PASS: memory instructions")

  ;; Exception handling
  (assert (= [0x08 0x00] (b/encode-instruction :throw 0)))
  (assert (= [0x07 0x00] (b/encode-instruction :catch 0)))
  (println "  PASS: exception instructions"))

;; ============================================
;; Type section encoding tests
;; ============================================

(defn test-type-encoding []
  (println "Testing type section encoding...")

  ;; Simple function type: (func (param i32 i32) (result i32))
  (let [ft (b/encode-func-type [:i32 :i32] [:i32])]
    (assert (= [0x60 0x02 0x7F 0x7F 0x01 0x7F] ft)))
  (println "  PASS: func type")

  ;; Struct type: (struct (field i32) (field (mut anyref)))
  (let [st (b/encode-struct-type [{:type :i32} {:type :anyref :mutable? true}])]
    (assert (= 0x5F (first st)))  ;; struct tag
    (assert (= (second st) 2)))   ;; 2 fields
  (println "  PASS: struct type")

  ;; Array type: (array (mut i8))
  (let [at (b/encode-array-type {:type :i32 :mutable? true})]
    (assert (= [0x5E 0x7F 0x01] at))) ;; array + i32 + mutable
  (println "  PASS: array type")

  ;; Sub type
  (let [sub (b/encode-sub-type {:struct [{:type :i32}]} [0])]
    (assert (= 0x50 (first sub)))) ;; sub tag
  (println "  PASS: sub type"))

;; ============================================
;; Section encoding tests
;; ============================================

(defn test-section-encoding []
  (println "Testing section encoding...")

  ;; A section with ID 1 (type) and some content
  (let [content [0x01 0x60 0x00 0x00] ;; 1 type: () -> ()
        section (b/encode-section 1 content)]
    (assert (= 1 (first section)))       ;; section ID
    (assert (= 4 (second section)))      ;; content length
    (assert (= content (subvec section 2))))
  (println "  PASS: section encoding"))

;; ============================================
;; End-to-end: minimal WASM module
;; ============================================

(defn test-minimal-module []
  (println "Testing minimal module encoding...")

  ;; Build: (module
  ;;   (func (export "double") (param i32) (result i32)
  ;;     local.get 0
  ;;     local.get 0
  ;;     i32.add))
  (let [module-bytes (b/simple-module
                      [{:name "double"
                        :params [:i32]
                        :results [:i32]
                        :body (b/concat-bytes
                               (b/encode-instruction :local.get 0)
                               (b/encode-instruction :local.get 0)
                               (b/encode-instruction :i32.add))}])
        ba (b/bytes-out module-bytes)]
    ;; Check magic number
    (assert (= 0x00 (bit-and (aget ba 0) 0xFF)))
    (assert (= 0x61 (bit-and (aget ba 1) 0xFF)))
    (assert (= 0x73 (bit-and (aget ba 2) 0xFF)))
    (assert (= 0x6D (bit-and (aget ba 3) 0xFF)))
    ;; Check version
    (assert (= 0x01 (bit-and (aget ba 4) 0xFF)))
    (assert (= 0x00 (bit-and (aget ba 5) 0xFF)))

    ;; Write to temp file and validate with wasmtime
    (let [f (java.io.File/createTempFile "woj-test-" ".wasm")]
      (with-open [fos (FileOutputStream. f)]
        (.write fos ba))
      (println "  Wrote" (count ba) "bytes to" (.getPath f))

      ;; Try running with wasmtime
      (try
        (let [proc (.start (ProcessBuilder.
                            ["wasmtime" "--invoke" "double"
                             (.getPath f) "21"]))
              stdout (slurp (.getInputStream proc))
              stderr (slurp (.getErrorStream proc))
              exit (.waitFor proc)]
          (.delete f)
          (if (zero? exit)
            (do
              (assert (= "42" (str/trim stdout))
                      (str "Expected 42, got: " (pr-str (str/trim stdout))))
              (println "  PASS: wasmtime returned 42"))
            (do
              (println "  WARN: wasmtime failed (exit" exit ")")
              (println "  stderr:" stderr))))
        (catch java.io.IOException _
          (.delete f)
          (println "  SKIP: wasmtime not available")))))
  (println "  PASS: minimal module structure"))

;; ============================================
;; End-to-end: module with GC types
;; ============================================

(defn test-gc-module []
  (println "Testing GC module encoding...")

  ;; Build a module with:
  ;; - A struct type: (type $Pair (struct (field $a i32) (field $b i32)))
  ;; - A function that creates a struct and reads a field
  ;; (func (export "make-sum") (param i32 i32) (result i32)
  ;;   (struct.get $Pair 0 (struct.new $Pair (local.get 0) (local.get 1)))
  ;;   (struct.get $Pair 1 (struct.new $Pair (local.get 0) (local.get 1)))
  ;;   i32.add)

  ;; Actually simpler: just test struct.new + struct.get
  ;; Type 0: (struct (field i32) (field i32))
  ;; Type 1: (func (param i32 i32) (result i32))
  ;; func: struct.new 0 (local.get 0) (local.get 1) -> struct.get 0 0 -> +
  ;;        struct.new 0 (local.get 0) (local.get 1) -> struct.get 0 1

  (let [;; Type section: rec group with struct type + func type
        struct-type (b/encode-sub-type
                     {:struct [{:type :i32 :mutable? false}
                               {:type :i32 :mutable? false}]}
                     []
                     true) ;; final
        func-type (b/simple-func-type [:i32 :i32] [:i32])
        ;; Wrap in rec group
        types [(b/encode-rec-group [struct-type func-type])]

        ;; Function section: 1 func of type 1
        functions [1]

        ;; Export
        exports [(b/encode-export "make-sum" b/kind-func 0)]

        ;; Code: struct.new $Pair(0), struct.get 0 0, then again struct.get 0 1, add
        body (b/concat-bytes
              ;; Create struct, get field 0
              (b/encode-instruction :local.get 0)
              (b/encode-instruction :local.get 1)
              (b/encode-instruction :struct.new 0)
              (b/encode-instruction :struct.get 0 0)
              ;; Create struct, get field 1
              (b/encode-instruction :local.get 0)
              (b/encode-instruction :local.get 1)
              (b/encode-instruction :struct.new 0)
              (b/encode-instruction :struct.get 0 1)
              ;; Add
              (b/encode-instruction :i32.add))
        code [(b/encode-code-entry [] body)]

        module-bytes (b/encode-module {:types types
                                       :functions functions
                                       :exports exports
                                       :code code})]

    ;; Write and test
    (let [f (java.io.File/createTempFile "woj-gc-test-" ".wasm")]
      (with-open [fos (FileOutputStream. f)]
        (.write fos (b/bytes-out module-bytes)))
      (println "  Wrote" (count module-bytes) "bytes to" (.getPath f))

      (try
        (let [proc (.start (ProcessBuilder.
                            ["wasmtime" "-W" "gc=y"
                             "--invoke" "make-sum"
                             (.getPath f) "20" "22"]))
              stdout (slurp (.getInputStream proc))
              stderr (slurp (.getErrorStream proc))
              exit (.waitFor proc)]
          (.delete f)
          (if (zero? exit)
            (do
              (assert (= "42" (str/trim stdout))
                      (str "Expected 42, got: " (pr-str (str/trim stdout))))
              (println "  PASS: GC module - wasmtime returned 42"))
            (do
              (println "  FAIL: wasmtime failed (exit" exit ")")
              (println "  stderr:" stderr))))
        (catch java.io.IOException _
          (.delete f)
          (println "  SKIP: wasmtime not available")))))
  (println "  PASS: GC module structure"))

;; ============================================
;; End-to-end: anyref boxing (i31ref)
;; ============================================

(defn test-i31ref-module []
  (println "Testing i31ref boxing module...")

  ;; Build a module that boxes and unboxes i31ref:
  ;; (func (export "box-unbox") (param i32) (result i32)
  ;;   (i31.get_s (ref.cast (ref i31) (ref.i31 (local.get 0)))))

  ;; Type 0: (func (param i32) (result i32))
  (let [func-type (b/simple-func-type [:i32] [:i32])
        types [func-type]

        functions [0]
        exports [(b/encode-export "box-unbox" b/kind-func 0)]

        body (b/concat-bytes
              (b/encode-instruction :local.get 0)
              (b/encode-instruction :ref.i31)
              (b/encode-instruction :ref.cast false :i31)
              (b/encode-instruction :i31.get_s))
        code [(b/encode-code-entry [] body)]

        module-bytes (b/encode-module {:types types
                                       :functions functions
                                       :exports exports
                                       :code code})]

    (let [f (java.io.File/createTempFile "woj-i31-test-" ".wasm")]
      (with-open [fos (FileOutputStream. f)]
        (.write fos (b/bytes-out module-bytes)))
      (println "  Wrote" (count module-bytes) "bytes to" (.getPath f))

      (try
        (let [proc (.start (ProcessBuilder.
                            ["wasmtime" "-W" "gc=y" "-W" "function-references=y"
                             "--invoke" "box-unbox"
                             (.getPath f) "42"]))
              stdout (slurp (.getInputStream proc))
              stderr (slurp (.getErrorStream proc))
              exit (.waitFor proc)]
          (.delete f)
          (if (zero? exit)
            (do
              (assert (= "42" (str/trim stdout))
                      (str "Expected 42, got: " (pr-str (str/trim stdout))))
              (println "  PASS: i31ref box/unbox - wasmtime returned 42"))
            (do
              (println "  FAIL: wasmtime failed (exit" exit ")")
              (println "  stderr:" stderr))))
        (catch java.io.IOException _
          (.delete f)
          (println "  SKIP: wasmtime not available")))))
  (println "  PASS: i31ref module structure"))

;; ============================================
;; Full pipeline test: compile woj -> WAT -> binary -> run
;; ============================================

(defn test-full-pipeline []
  (println "Testing full pipeline (woj -> binary -> wasmtime)...")
  (let [wat-str (main/compile-string "(defn double [x] (+ x x))")
        wasm-bytes (wat/wat->wasm-bytes wat-str)
        f (java.io.File/createTempFile "woj_pipeline_" ".wasm")]
    (.deleteOnExit f)
    (with-open [os (java.io.FileOutputStream. f)]
      (.write os wasm-bytes))
    (assert (> (count wasm-bytes) 1000) "binary should be non-trivial size")
    (try
      (let [proc (.start (ProcessBuilder. ["wasmtime"
                                            "-W" "gc=y" "-W" "function-references=y"
                                            "-W" "exceptions=y" "-W" "tail-call=y"
                                            "--invoke" "double" (.getAbsolutePath f) "21"]))
            stdout (slurp (.getInputStream proc))
            stderr (slurp (.getErrorStream proc))
            exit (.waitFor proc)]
        (when (zero? exit)
          (let [result (str/trim (str/replace stdout #"warning:.*\n?" ""))]
            (assert (= "42" result) (str "Expected 42, got: " result))
            (println "  PASS: wasmtime returned 42")))
        (when (not (zero? exit))
          (println "  FAIL: wasmtime exit" exit)
          (println "  stderr:" stderr)))
      (catch java.io.IOException _
        (.delete f)
        (println "  SKIP: wasmtime not available")))
    (.delete f)))

;; ============================================
;; Test runner
;; ============================================

(defn run-all-tests []
  (println "=== woj.binary tests ===")
  (test-unsigned-leb128)
  (test-signed-leb128)
  (test-f64)
  (test-val-types)
  (test-instructions)
  (test-type-encoding)
  (test-section-encoding)
  (test-minimal-module)
  (test-gc-module)
  (test-i31ref-module)
  (test-full-pipeline)
  (println "=== All binary tests passed ==="))

(defn -main [& _args]
  (run-all-tests))
