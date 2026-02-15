# woj

A Clojure dialect that compiles directly to WebAssembly GC.

## Status

Active development - core language features implemented, working toward clojure.core compatibility.

## Features

- **Control flow**: `def`, `defn`, `fn`, `let`, `do`, `if`, `cond`, `when`, `when-not`, `loop`/`recur`, `->`, `->>`
- **Data structures**: Vectors, hash maps, cons lists, keywords
- **Arithmetic**: `+`, `-`, `*`, `/`, `inc`, `dec`
- **Comparison**: `=`, `not=`, `<`, `>`, `<=`, `>=`
- **Logical**: `not`, `and`, `or`
- **Closures**: Functions can capture variables from enclosing scope
- **Recursive functions**: `defn` can call itself
- **Implicit boxing**: All values are `anyref` internally (integers via i31ref)

See [CLAUDE.md](CLAUDE.md) for full compatibility details with clojure.core.

## Requirements

- [Clojure](https://clojure.org/) (compiler is written in Clojure)
- [wasmtime](https://wasmtime.dev/) with GC support (for running wasm)

## Usage

```bash
# Compile .clj to .wat
clj -M:run examples/hello.clj > output.wat

# Run with wasmtime (GC and function-references required)
wasmtime -W gc=y -W function-references=y --invoke double output.wat 21
# Output: 42

# Run tests
clj -M:test
```

## Examples

```clojure
;; Basic arithmetic
(defn double [x] (+ x x))

;; Vectors
(def v [1 2 3])
(nth v 1)  ;; => 2
(conj v 4) ;; => [1 2 3 4]

;; Hash maps
(def m {:a 1 :b 2})
(get m :a)  ;; => 1
(assoc m :c 3 :d 4)  ;; => {:a 1 :b 2 :c 3 :d 4}

;; Closures
(defn make-adder [x]
  (fn [y] (+ x y)))
(def add5 (make-adder 5))
(add5 10)  ;; => 15

;; Recursion
(defn factorial [n]
  (if (<= n 1)
    1
    (* n (factorial (- n 1)))))

;; Threading
(-> x (+ 1) (* 2))  ;; => (* (+ x 1) 2)
```

## Architecture

woj compiles Clojure source directly to WAT (WebAssembly Text Format), using WasmGC features:

- **i31ref** for boxed integers (31-bit)
- **Struct types** for cons cells, vectors, hash maps, closures
- **32-way branching trie** for persistent vectors
- **Array-based** hash maps (O(n) lookup, HAMT planned)

## Test Suite

The `test/clojure/` directory contains tests imported from the official Clojure test suite with Java interop removed. This serves as a specification for clojure.core compatibility.

```bash
# Run compiler tests
clj -M:test

# Test files from official Clojure (for reference)
test/clojure/test_clojure/
  - control.clj      # if, when, cond, loop, case
  - data_structures.clj  # vectors, maps, sets, lists
  - sequences.clj    # map, filter, reduce, etc.
  - numbers.clj      # arithmetic, comparisons
  - logic.clj        # and, or, not
  - ...
```

## License

MIT
