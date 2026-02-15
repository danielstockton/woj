# woj - Clojure to WasmGC Compiler

## Project Overview
woj is a Clojure dialect that compiles to WebAssembly GC. The compiler is written in Clojure.

## Current Status
Phase 12 complete - Namespace Require:
- Compiles `def`, `fn`, `let`, `if`, `loop`, `recur` and arithmetic to WAT
- Booleans (`true`, `false`) and `nil` support
- Logical operators: `not`, `and`, `or`
- Proper symbol munging for Clojure identifiers (e.g., `my-func` → `my_func`, `valid?` → `valid_QMARK_`)
- Improved error messages with source location tracking
- **Implicit boxing** - all values are `anyref` internally, integers auto-boxed via i31ref
- **Cons lists** - `cons`, `first`, `rest` using WasmGC structs
- **Persistent vectors** - 32-way branching trie with tail optimization
- **Persistent hash maps** - simple array-based implementation with keyword and integer keys
- **Persistent hash sets** - array-based with O(n) lookup
- **Keywords** - proper keyword type with interned IDs, usable as map keys
- **Closures** - functions can capture variables from enclosing scope, enabling higher-order programming
- **Recursive functions** - `defn` can call itself, enabling `map`, `filter`, `reduce` etc.
- **Threading macros** - `->` and `->>` for functional pipelines
- **Variadic assoc** - `(assoc m :a 1 :b 2 :c 3)` for easy map updates
- **Atoms** - mutable state with `atom`, `deref`/`@`, `swap!`, `reset!`
- **Apply** - `(apply f args)` and `(apply f x y args)` for dynamic function application
- **Sequence abstraction** - `seq`, `first`, `rest` work on vectors, maps, sets, strings, and lazy seqs
- **Type predicates** - extensive type checking: `set?`, `atom?`, `list?`, `keyword?`, `lazy-seq?`, etc.
- **Reduce** - efficient `reduce` and `reduce-kv` with type-specific implementations and early termination via `reduced`
- **Multi-arity functions** - `(defn f ([] 0) ([x] x) ([x y] (+ x y)))`
- **Variadic functions** - `(defn f [x & more] ...)` with rest args packed into lists
- **Protocols** - `defprotocol`, `extend-type`, `extend-protocol`, `satisfies?` for polymorphic dispatch
- **Lazy sequences** - `lazy-seq` macro for deferred computation with memoization
- **Core sequence operations** - lazy `map`, `filter`, `take`, `drop`, `range`, `repeat`, `repeatedly`, `iterate`
- **Strings** - UTF-8 string literals with proper codepoint-aware `count`, `nth`, `subs`, `first`/`rest`/`seq`; `str` concatenation, `name`, polymorphic `=`/`not=`, strings as map keys
- **Exception handling** - `try`/`catch`/`finally`/`throw` using WASM exception handling proposal; `ex-info`, `ex-data`, `ex-message`, `ex-cause`
- **`condp`** - multi-branch conditional with predicate, including `:>>` form
- **`for` comprehension** - list comprehension with multiple bindings, `:let`, `:when`, `:while`
- **`ns` with `:require`** - multi-file compilation with `:as` aliases and `:refer`; transitive dependency loading; `--path` CLI flag for search paths

## Tech Stack
- **Source language**: woj (Clojure subset)
- **Target**: WAT (WebAssembly Text Format)
- **Compiler**: Written in Clojure

## Directory Structure
- `src/woj/` - Compiler source code
- `examples/` - Example .clj programs
- `test/` - Compiler tests

## Usage

### Compile a file
```bash
clj -M:run examples/hello.clj > output.wat

# With namespace search paths (for files using :require)
clj -M:run --path test/clojure-test-suite/test examples/multi_file.clj > output.wat
```

### Run tests
```bash
# Compiler unit tests
clj -M:test

# Clojure compatibility test suite (individual test files)
clj -M:run --path test/clojure-test-suite/test \
  test/clojure-test-suite/test/clojure/core_test/<file>.cljc > /tmp/test.wat && \
  wasmtime -W gc=y -W function-references=y -W exceptions=y --invoke run-tests /tmp/test.wat
# Output: 0 = all tests pass, >0 = failure count
```

### Full Pipeline (with WasmGC)
```bash
# 1. Compile .clj to .wat
clj -M:run examples/hello.clj > output.wat

# 2. Run with wasmtime (GC and function-references enabled)
wasmtime -W gc=y -W function-references=y -W exceptions=y --invoke <function> output.wat <args>

# Examples:
clj -M:run examples/hello.clj > output.wat && wasmtime -W gc=y -W function-references=y -W exceptions=y --invoke double output.wat 21
# Output: 42

# Vector example:
clj -M:run examples/vectors.clj > output.wat && wasmtime -W gc=y -W function-references=y -W exceptions=y --invoke test-count output.wat
# Output: 3

# Map example:
clj -M:run examples/maps.clj > output.wat && wasmtime -W gc=y -W function-references=y -W exceptions=y --invoke test-get-a output.wat
# Output: 100

# Closure example:
clj -M:run examples/closures.clj > output.wat && wasmtime -W gc=y -W function-references=y -W exceptions=y --invoke test-basic output.wat
# Output: 15
```

Note: wasmtime can parse WAT directly with full WasmGC support. The `-W function-references=y` flag is required for closures, and `-W exceptions=y` is required for try/catch/throw. The older wat2wasm (wabt) has limited GC support.

**For browser deployment**, use `wasm-tools` to convert WAT to WASM:
```bash
# Install once: cargo install wasm-tools
wasm-tools parse file.wat -o file.wasm
```

## Supported Language Features
- `def` - global definitions
- `defn` - function definition shorthand
- `set!` - global mutation (returns the new value)
- `fn` - functions with closure support, multi-arity, and variadic (`& rest`) params
- `let` - local bindings
- `do` - sequence expressions, returns last value
- `if` - conditionals (automatically unboxes test value)
- `cond` - multi-branch conditional
- `condp` - predicate-based multi-branch conditional (supports `:>>` form)
- `case` - value-based dispatch (expands to `cond`)
- `when` - single-branch conditional (returns nil if false)
- `when-not` - negated single-branch conditional
- `loop`/`recur` - tail recursion (works in both `loop` and `fn`/`defn` tail position)
- `try`/`catch`/`finally` - exception handling using WASM exceptions proposal
- `throw` - throw exceptions (any value or `ex-info`)
- `->` - thread-first macro
- `->>` - thread-last macro
- `some->`, `some->>`, `cond->`, `cond->>`, `as->` - advanced threading macros
- `for` - list comprehension with multiple bindings, `:let`, `:when`, `:while`
- `ns` - namespace declaration with `:require`, `:as` aliases, `:refer`; loads dependencies from search paths
- Arithmetic: `+`, `-`, `*`, `/`, `inc`, `dec`
- Comparison: `=`, `not=`, `<`, `>`, `<=`, `>=`
- Logical: `not`, `and`, `or`
- Predicates: `neg?`, `pos?`, `zero?`, `nil?`, `cons?`, `vector?`, `map?`, `set?`, `atom?`, `list?`, `keyword?`, `number?`, `integer?`, `fn?`, `coll?`, `sequential?`, `associative?`, `counted?`, `indexed?`, `true?`, `false?`, `some?`, `seq?`, `seqable?`, `empty?`, `lazy-seq?`, `string?`
- Integer literals (auto-boxed)
- Booleans: `true`, `false` (auto-boxed)
- `nil` (compiles to `ref.null`)
- Keywords: `:foo` (proper struct type with interned ID)
- **Strings**: `"hello"` literal syntax, `str` for concatenation/conversion, `pr-str` for EDN output, `count`, `nth`, `subs`, `name`, `symbol`, `namespace`
- **Floats**: `3.14` literal syntax, polymorphic arithmetic with ints, `float?`, `double`, `Math/floor`, `Math/ceil`, `Math/sqrt`, `Math/abs`, `Math/round`
- **Lists**: `list`, `cons`, `first`, `rest` (WasmGC structs)
- **Vectors**: `vector`, `[1 2 3]` literal syntax, `nth`, `count`, `conj` (32-way trie)
- **Maps**: `hash-map`, `get`, `contains?`, `dissoc`, `keys`, `vals`, `merge`, `get-in`, `assoc-in`, `update-in`, literal syntax `{:a 1 :b 2}` (array-based persistent map)
- **Sets**: `hash-set`, `set-conj`, `disj`, `set`, `union`, `intersection`, `difference`
- **Polymorphic**: `assoc` works on both vectors and maps (variadic: `(assoc m :a 1 :b 2)`), `contains?` works on maps and sets
- **Atoms**: `atom`, `deref`/`@`, `swap!`, `reset!`, `swap-vals!`, `reset-vals!`, `add-watch`, `remove-watch`, `set-validator!`
- **Apply**: `apply` for dynamic function application, multi-arg `(apply f x y args)`
- **Reduce**: `reduce`, `reduce-kv` (efficient type-specific implementations), `reduced`, `reduced?` for early termination
- **Sequence operations**: `seq`, `first`, `rest`, `next`, `reverse`, `concat`, `take-while`, `drop-while`, `split-at`, `split-with`, `interpose`, `interleave`, `some`, `every?`, `not-every?`, `not-any?`, `keep`, `map-indexed`, `keep-indexed`, `distinct`, `partition`, `partition-all`, `mapcat`, `remove`
- **Higher-order functions**: `identity`, `constantly`, `comp`, `partial`, `complement`, `juxt`
- **Control flow macros**: `if-not`, `if-let`, `when-let`, `when-first`, `if-some`, `when-some`, `dotimes`, `while`
- **clojure.test**: `deftest`, `is`, `are`, `testing` (returns 0 for pass, failure count otherwise)
- **Protocols**: `defprotocol`, `extend-type`, `extend-protocol`, `satisfies?` for type-based polymorphic dispatch
- **User types**: `deftype` with fields and inline protocol implementations, `instance?`, field access via `.-field`
- **Exception handling**: `try`/`catch`/`finally`, `throw`, `ex-info`, `ex-data`, `ex-message`, `ex-cause`
- **Lazy sequences**: `lazy-seq` macro for deferred computation with memoization
- **Core sequence operations**: lazy `map`, `filter`, `take`, `drop`, `range`, `repeat`, `repeatedly`, `iterate`; eager `mapv`, `filterv`, `into`, `vec`
- **Transducers**: `transduce`, `sequence`, `eduction`, `into` with xf; 1-arity transducer-returning forms of `map`, `filter`, `take`, `drop`, `take-while`, `drop-while`, `keep`, `mapcat`, `remove`, `distinct`, `dedupe`, `partition-all`, `interpose`; completion protocol via metadata
- **Metadata**: `meta`, `with-meta`, `vary-meta` on collections
- **Regex**: `#""` literal syntax, `re-find`, `re-matches`, `re-seq`, `re-pattern`, `regex?`; pure-woj NFA engine supporting literals, `.`, `*`, `+`, `?`, `\d`, `\w`, `\s`, `[charset]`, `^$`, `|`, `()`
- **letfn**: mutually recursive local functions via atom+trampoline pattern
- **reify**: anonymous protocol implementations (expands to anonymous deftype)

## Code Style
- Use Clojure idioms
- Multimethods for AST dispatch (emit)
- Keep functions pure where possible

## Known Limitations
- wabt 1.0.39 doesn't support WasmGC (use wasmtime directly with `-W gc=y -W function-references=y -W exceptions=y`)
- Source locations in errors require metadata from reader (not available with standard read-string)
- Hash maps use simple O(n) array-based lookup (works but not optimal for large maps)
- Max 10-arity closures (can add more types if needed)
- Captured values are copied at closure creation (immutable capture)
- `deftype` supports inline protocol implementations; `defrecord` is stubbed as map constructor

## Value Representation

All values are represented as `anyref` internally:
- **Integers** → `i31ref` via `ref.i31` (31-bit signed integers)
- **Booleans** → `i31ref` (1 for true, 0 for false)
- **nil** → `ref.null none`
- **Keywords** → `(ref $Keyword)` struct with interned ID
- **Symbols** → `(ref $Symbol)` struct with interned ID, name string, and optional namespace (tag=4)
- **Cons cells** → `(ref $Cons)` struct
- **Vectors** → `(ref $Vector)` struct with trie
- **HashMaps** → `(ref $HashMap)` struct with array (tag=0)
- **HashSets** → `(ref $HashSet)` struct with array (tag=1)
- **Atoms** → `(ref $Atom)` struct with mutable value field
- **Strings** → `(ref $String)` struct with interned ID and `(ref $CharArray)` UTF-8 byte data
- **Floats** → `(ref $Float)` struct with f64 value (tag=5)
- **Closures** → `(ref $ClosureN)` struct with func ref and environment array
- **LazySeq** → `(ref $LazySeq)` struct with thunk and realized value
- **Reduced** → `(ref $Reduced)` wrapper for early termination in reduce
- **ExceptionInfo** → `(ref $ExceptionInfo)` struct with message, data, and cause fields
- **Regex** → `(ref $Regex)` struct with pattern string (tag=98)
- **WithMeta** → `(ref $WithMeta)` transparent wrapper with inner value + metadata (tag=99)

Exported functions automatically unbox return values to `i32` for wasmtime compatibility.

## clojure.core Compatibility

The `test/clojure/` directory contains tests imported from the official Clojure test suite (with Java interop removed). This shows what woj implements vs what's missing.

### Implemented ✓

**Special Forms & Macros:**
`def`, `defn`, `fn`, `let`, `do`, `if`, `cond`, `condp`, `case`, `when`, `when-not`, `if-not`, `if-let`, `when-let`, `when-first`, `if-some`, `when-some`, `loop`, `recur`, `->`, `->>`, `some->`, `some->>`, `cond->`, `cond->>`, `as->`, `for`, `dotimes`, `while`, `lazy-seq`, `letfn`, `try`/`catch`/`finally`/`throw`, `ns` (with `:require`/`:as`/`:refer`)

**Data Structure Literals:**
`[]` vectors, `{}` maps, `()` lists, `"string"` strings, `:keyword` keywords, `true`/`false`/`nil`

**Arithmetic:** `+`, `-`, `*`, `/`, `inc`, `dec`

**Comparison:** `=`, `not=`, `<`, `>`, `<=`, `>=`

**Logical:** `not`, `and`, `or`

**List Operations:** `list`, `cons`, `first`, `rest`, `next`

**Vector Operations:** `vector`, `nth`, `count`, `conj`, `assoc`

**Map Operations:** `hash-map`, `get`, `contains?`, `assoc`, `dissoc`, `keys`, `vals`, `merge`, `get-in`, `assoc-in`, `update-in`

**Set Operations:** `hash-set`, `set-conj`, `disj`, `set`, `union`, `intersection`, `difference`

**Sorted Collections:** `sorted-map`, `sorted-set`, `sorted-map-by`, `sorted-set-by`, `sorted?`, `subseq`, `rsubseq`; protocol-based dispatch for `seq`, `count`, `get`, `assoc`, `conj`

**Sequence Operations:** `seq`, `first`, `rest`, `next`, `reverse`, `concat`, `take-while`, `drop-while`, `split-at`, `split-with`, `interpose`, `interleave`, `some`, `every?`, `not-every?`, `not-any?`, `keep`, `map-indexed`, `keep-indexed`, `distinct`, `partition`, `partition-all`, `mapcat`, `remove`, `map`, `filter`, `take`, `drop`, `range`, `repeat`, `repeatedly`, `iterate`, `mapv`, `filterv`, `into`, `vec`, `last`, `butlast`, `zipmap`, `doall`, `dorun`

**Transducers:** `transduce`, `sequence`, `eduction`, `into` (3-arity with xf), `cat`; 1-arity transducer-returning: `map`, `filter`, `take`, `drop`, `take-while`, `drop-while`, `keep`, `mapcat`, `remove`, `distinct`, `dedupe`, `partition-all`, `interpose`

**Atoms:** `atom`, `deref`/`@`, `swap!`, `reset!`, `swap-vals!`, `reset-vals!`, `add-watch`, `remove-watch`, `set-validator!`

**Higher-Order Functions:** `apply`, `identity`, `constantly`, `comp`, `partial`, `complement`, `juxt`, `reduce`, `reduce-kv`

**String Operations:** `str`, `count`, `nth`, `subs`, `name`, `keyword`, `symbol`, `namespace`

**Predicates:** `nil?`, `cons?`, `vector?`, `map?`, `set?`, `atom?`, `list?`, `keyword?`, `number?`, `integer?`, `float?`, `fn?`, `coll?`, `sequential?`, `associative?`, `counted?`, `indexed?`, `true?`, `false?`, `some?`, `seq?`, `seqable?`, `empty?`, `zero?`, `pos?`, `neg?`, `satisfies?`, `lazy-seq?`, `string?`, `symbol?`, `even?`, `odd?`, `regex?`

**Exception Handling:** `try`/`catch`/`finally`, `throw`, `ex-info`, `ex-data`, `ex-message`, `ex-cause`

**Protocols:** `defprotocol`, `extend-type`, `extend-protocol`, `deftype` (with inline protocol implementations), `reify`

**Metadata:** `meta`, `with-meta`, `vary-meta`

**Regex:** `#""` literal, `re-find`, `re-matches`, `re-seq`, `re-pattern`

### Not Yet Implemented ✗

**Control Flow:**
`doseq` (multiple bindings only partially supported)

**Sequence Operations:**
`sort`, `empty`, `not-empty`, `frequencies`, `group-by`, `flatten`, `lazy-cat`, `subvec`

**Other:**
`eval`, chars, ratios, `clojure.core.reducers`

## Known Bugs (discovered via defdb)

### Fixed
- **Character literals compiled to integers** — `\?` produced `i31ref(63)` instead of string `"?"`. Since `(first "?name")` returns a string, comparisons like `(= (first s) \?)` always failed. Fixed: `analyze-char` now delegates to `analyze-string`.
- **`empty?` on LazySeq always returned true** — `$empty_QMARK_` had no LazySeq branch, fell through to default `(i32.const 1)`. Fixed: added LazySeq branch that calls `$seq` to check.
- **Symbol equality** — `$eq` had no Symbol comparison branch, so symbol-keyed map lookups failed. Fixed: added Symbol branch comparing interned IDs.
- **`name` on symbols returned nil** — No symbol-to-name mapping existed at runtime. Fixed: added `$__sym_names` global array populated during module init.

### Previously Not Fixed (now fixed)
- **`get` with 3 args ignores default value** — Fixed: added `$hash_map_get_default` with 3-arg support.
- **`apply` on lazy sequences** — Fixed: `$apply` now recomputes arity from `$seq`-converted args.
- **`concat` with empty initial vectors** — Fixed: `concat` now uses `(seq a)` instead of `(nil? a)`.
- **String hash inconsistency** — `$hash` used interned string IDs, causing HAMT lookup failures for dynamically-created strings (e.g., `nth` on a string). Fixed: always use content-based hashing for strings.
- **`throw` missing `(unreachable)` in emitter** — `throw` is a diverging instruction in WASM but the emitter didn't emit `(unreachable)` after it. In typed blocks (e.g., `if` with `(result anyref)`), this caused "type mismatch: expected anyref but nothing on stack" validation errors. Fixed: `emit` for `:throw` now appends `(unreachable)`.

## Future Work

### Tier 1 - Blocking for real programs
- [x] `for` comprehension with `:let`/`:when`/`:while`/multiple bindings
- [x] `condp` macro
- [x] `try`/`catch`/`throw` + `ex-info`/`ex-data`/`ex-message`/`ex-cause` (WASM exception handling proposal)
- [x] Working `ns` with `:require`/`:as`/`:refer` (multi-file compilation)

### Tier 2 - Expected by Clojure programmers
- [x] `defmulti`/`defmethod` with hierarchy support (`derive`, `isa?`, `make-hierarchy`)
- [x] `deftype` with inline protocol implementations
- [x] `reify` - anonymous protocol implementations (expands to anonymous deftype)
- [x] `meta`/`with-meta`/`vary-meta` - metadata on collections via `$WithMeta` wrapper
- [x] Regex: `#""` literal, `re-find`, `re-seq`, `re-matches`, `re-pattern` (pure-woj NFA engine)
- [x] `clojure.string` library: `split`, `join`, `replace`, `trim`, `lower-case`, `upper-case`, `starts-with?`, `ends-with?`, `includes?`, `blank?`, `reverse`, `index-of`, `capitalize`
- [ ] `sort`/`sort-by`
- [x] `letfn` - mutually recursive local functions (atom+trampoline pattern)
- [x] `pr-str` (EDN output), `read-string` (EDN input via `woj.edn`)
- [x] Printing: `pr`, `prn`, `print`, `println`, `prn-str` (via WASI fd_write)
- [x] `even?`/`odd?` predicates
- [x] `delay`/`force`/`realized?`
- [x] `volatile!`/`vswap!`/`vreset!`
- [x] Atom watches and validators: `add-watch`, `remove-watch`, `set-validator!`
- [x] Symbols as first-class values (full Symbol type, usable as map keys, `symbol` constructor, `namespace`)
- [x] More sequence ops: `cycle`, `take-nth`, `take-last`, `drop-last`, `nthrest`, `nthnext`, `shuffle`, `flatten`, `dedupe`, `frequencies`, `group-by`, `not-empty`, `empty`, `lazy-cat`, `subvec`
- [x] Higher-order utilities: `fnil`, `every-pred`, `some-fn`, `memoize`, `trampoline`
- [x] `clojure.set`: `select`, `project`, `rename`, `rename-keys`, `join`, `map-invert`, `index`
- [x] `clojure.walk`: `walk`, `prewalk`, `postwalk`, `keywordize-keys`, `stringify-keys`
- [x] `clojure.edn`: `read-string` (safe EDN parsing, implemented in `lib/edn.clj`)

### Tier 3 - Performance and completeness
- [ ] HAMT-based hash maps (O(log32 n) instead of O(n) array-based)
- [ ] Transient collections: `transient`/`persistent!`, `assoc!`, `conj!`, `disj!`
- [x] Transducers: `transduce`, `into` with xf, `eduction`, `sequence`; `map`/`filter`/`take`/`drop`/`take-while`/`drop-while`/`keep`/`mapcat`/`remove`/`distinct`/`dedupe`/`partition-all`/`interpose` return transducers when called without collection
- [x] Sorted collections: `sorted-map`, `sorted-set`, `sorted-map-by`, `sorted-set-by` (sorted-vector based with binary search, protocol dispatch for seq/count/get/assoc/conj)
- [x] MapEntry: `key`/`val`/`find`/`select-keys` (map entries are 2-element vectors)
- [ ] Chunked lazy sequences (batch evaluation for performance)
- [ ] `gen-class`/`gen-interface` equivalent for WASM host interop
- [x] Float64 support (IEEE 754 doubles via `$Float` struct, polymorphic arithmetic)
- [ ] Character type (currently char literals compile to single-char strings)
- [ ] BigInt/BigDecimal support

## Files

| File | Description |
|------|-------------|
| `src/woj/main.clj` | Entry point, reader, compile-file/string |
| `src/woj/analyzer.clj` | AST analysis, keyword interning, closure detection |
| `src/woj/emitter.clj` | WAT code generation, WasmGC runtime |
| `src/woj/util.clj` | Symbol munging utilities |
| `test/woj/core_test.clj` | Compiler test suite |
| `test/woj_compat_test.clj` | woj compatibility tests (runs in WASM) |
| `test/clojure/` | Official Clojure tests (Java interop removed) |
| `examples/lists.clj` | Cons list examples |
| `examples/vectors.clj` | Vector examples |
| `examples/maps.clj` | Hash map examples |
| `examples/keywords.clj` | Keyword examples |
| `examples/closures.clj` | Closure examples |
| `examples/recursion.clj` | Recursive function examples |
| `examples/threading.clj` | Threading macros and variadic assoc |
| `test/protocol_test.clj` | Protocol tests (defprotocol, extend-type, satisfies?) |
| `test/lazy_seq_test.clj` | Lazy sequence tests (lazy-seq, lazy-seq?, memoization) |
| `test/seq_ops_test.clj` | Sequence operations tests (map, filter, take, drop, range, etc.) |
| `test/destructuring_test.clj` | Destructuring tests (vector, map, :keys, :as, :or) |
| `test/string_test.clj` | String tests (literals, str, count, nth, subs, name, seq ops) |
| `lib/regex.clj` | Pure-woj regex engine (NFA-style parser + matcher) |
