;; woj - Clojure to WasmGC Compiler
;;
;; This is a wrapper for backward compatibility.
;; Use: clj -M:run <input.clj>
;;
;; Note: Currently generates i32-only WAT due to limited WasmGC tooling support.

(ns woj.compiler
  (:require [woj.main :as main]))

(apply main/-main *command-line-args*)
