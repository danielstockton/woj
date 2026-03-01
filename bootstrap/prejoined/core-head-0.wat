(module
  ;; WASI imports for I/O
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_close" (func $fd_close (param i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_seek" (func $fd_seek (param i32 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open" (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_filestat_get" (func $fd_filestat_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_get" (func $args_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "clock_time_get" (func $clock_time_get (param i32 i64 i32) (result i32)))
  (memory (export "memory") 256)
  ;; ==========================================
  ;; WasmGC Type Definitions
  ;; ==========================================
  ;; All struct types extend $Tagged with a $__type_id discriminator field.
  ;; This enables reliable type dispatch via tag reads instead of ref.test,
  ;; which is unreliable due to WasmGC's structural typing.
  ;; Tag assignments: nil=0 i31=1 Keyword=2 String=3 Symbol=4 Float=5
  ;; Cons=6 Vector=7 HashMap=8 HashSet=9 Atom=10 Closure=11 LazySeq=12
  ;; Reduced=13 Boolean=14 TransientVector=15 TransientHashMap=16
  ;; TransientHashSet=17 VectorSeq=18 ArrayMap=19 ExceptionInfo=100 User-types=20+

  ;; Base type for all tagged structs
  (type $Tagged (sub (struct (field $__type_id i32))))

  ;; Cons cell: holds two anyref values (first and rest)
  (type $Cons (sub $Tagged (struct (field $__type_id i32) (field $first (mut anyref)) (field $rest (mut anyref)))))

  ;; Boolean: distinct from integers (true=1, false=0)
  (type $Boolean (sub $Tagged (struct (field $__type_id i32) (field $val i32))))

  ;; Keyword: interned symbol with unique ID
  (type $Keyword (sub $Tagged (struct (field $__type_id i32) (field $id i32))))

  ;; UTF-8 byte array (for strings)
  (type $CharArray (array (mut i8)))

  ;; String: interned ID + UTF-8 byte data
  ;; ID >= 0 for interned literals (O(1) equality), -1 for dynamic strings
  (type $String (sub $Tagged (struct (field $__type_id i32) (field $id i32) (field $data (ref $CharArray)))))

  ;; Symbol: interned symbol with unique ID, name string, and optional namespace
  (type $Symbol (sub $Tagged (struct (field $__type_id i32) (field $id i32) (field $name anyref) (field $ns anyref))))

  ;; Float: 64-bit floating point value
  (type $Float (sub $Tagged (struct (field $__type_id i32) (field $val f64))))

  ;; Array of anyref (mutable)
  (type $AnyArray (array (mut anyref)))

  ;; Persistent Vector (32-way branching trie with tail optimization)
  (type $Vector (sub $Tagged (struct
    (field $__type_id i32)
    (field $count i32)      ;; Total number of elements
    (field $shift i32)      ;; Bit shift for trie navigation (0, 5, 10, 15...)
    (field $root anyref)    ;; Root of the trie (null for small vectors)
    (field $tail anyref)))) ;; Tail array (last 1-32 elements)

  ;; HAMT-backed HashMap
  ;; $array field holds root HAMTNode (or null for empty map)
  (type $HashMap (sub $Tagged (struct
    (field $__type_id i32)
    (field $count i32)      ;; Number of key-value pairs
    (field $array anyref)))) ;; HAMT root node (HAMTNode or null)

  ;; HAMT-backed HashSet
  ;; Uses HashMap internally (key = value = element)
  (type $HashSet (sub $Tagged (struct
    (field $__type_id i32)
    (field $count i32)      ;; Number of elements
    (field $array anyref)))) ;; HAMT root node (shared with HashMap)

  ;; HAMT internal node: bitmap-indexed array of children
  ;; Each child is either a HAMTEntry (leaf) or another HAMTNode (branch)
  ;; $edit: 0 = immutable (shared), non-zero = owned by a transient
  (type $HAMTNode (struct
    (field $edit (mut i32))
    (field $bitmap (mut i32))          ;; 32-bit bitmap: which slots are occupied
    (field $children (mut (ref $AnyArray))))) ;; popcount(bitmap) entries

  ;; HAMT leaf entry: single key-value pair
  ;; $edit: 0 = immutable, non-zero = owned by a transient
  (type $HAMTEntry (struct
    (field $edit (mut i32))
    (field $hash i32)       ;; cached hash of key
    (field $key anyref)
    (field $val (mut anyref))))

  ;; HAMT collision node: multiple entries sharing the same hash
  ;; $edit: 0 = immutable, non-zero = owned by a transient
  (type $HAMTCollision (struct
    (field $edit (mut i32))
    (field $hash i32)       ;; shared hash value
    (field $count (mut i32))      ;; number of entries (mutable for transient in-place add)
    (field $entries (mut (ref $AnyArray))))) ;; [k1, v1, k2, v2, ...]

  ;; Atom: mutable reference with watches and validator
  (type $Atom (sub $Tagged (struct
    (field $__type_id i32)
    (field $val (mut anyref))       ;; Mutable value
    (field $watches (mut anyref))   ;; HashMap of key -> watch-fn (null = none)
    (field $validator (mut anyref))))) ;; Validator fn (null = none)

  ;; Reduced: wrapper for early termination in reduce
  (type $Reduced (sub $Tagged (struct
    (field $__type_id i32)
    (field $val anyref))))

  ;; LazySeq: delayed sequence with memoization
  ;; Has extra $__pad field to remain structurally distinct from Cons
  (type $LazySeq (sub $Tagged (struct
    (field $__type_id i32)
    (field $__pad i32)               ;; Padding for structural distinction from Cons
    (field $thunk (mut anyref))      ;; 0-arity closure (null when realized)
    (field $realized (mut anyref))))) ;; cached result (nil or Cons/seq)

  ;; VectorSeq: lazy view over a vector from a given offset
  ;; Tag = 18. O(1) first/rest without allocating Cons cells.
  (type $VectorSeq (sub $Tagged (struct
    (field $__type_id i32)
    (field $vec anyref)              ;; The underlying Vector
    (field $offset i32))))           ;; Current index into the vector

  ;; ExceptionInfo: structured exception data (like Clojure's ex-info)
  (type $ExceptionInfo (sub $Tagged (struct
    (field $__type_id i32)
    (field $message anyref)          ;; String message
    (field $data anyref)             ;; Map of data
    (field $cause anyref))))         ;; Cause (another exception or nil)

  ;; TransientVector: mutable count + tail, shares trie structure with Vector
  ;; Tag = 15
  (type $TransientVector (sub $Tagged (struct
    (field $__type_id i32)
    (field $count (mut i32))
    (field $shift (mut i32))
    (field $root (mut anyref))
    (field $tail (mut anyref))
    (field $edit (mut i32)))))

  ;; TransientHashMap: mutable count + HAMT root
  ;; Tag = 16
  (type $TransientHashMap (sub $Tagged (struct
    (field $__type_id i32)
    (field $count (mut i32))
    (field $array (mut anyref))
    (field $edit (mut i32)))))

  ;; TransientHashSet: mutable count + HAMT root
  ;; Tag = 17
  (type $TransientHashSet (sub $Tagged (struct
    (field $__type_id i32)
    (field $count (mut i32))
    (field $array (mut anyref))
    (field $edit (mut i32)))))

  ;; Regex: compiled regex pattern (stores pattern string)
  (type $Regex (sub $Tagged (struct
    (field $__type_id i32)
    (field $pattern anyref))))   ;; pattern string

  ;; StringBuffer: mutable growable byte buffer for O(N) string building
  ;; Not a Tagged struct — internal-only, not exposed as a woj value type
  (type $StringBuffer (struct
    (field $data (mut (ref $CharArray)))
    (field $len (mut i32))))

  ;; WithMeta: wrapper for values with metadata
  ;; Tag = 99, structurally unique with two padding fields
  (type $WithMeta (sub $Tagged (struct
    (field $__type_id i32)
    (field $__pad1 i32)
    (field $__pad2 i32)
    (field $inner anyref)
    (field $meta anyref))))

  ;; Exception tag for WASM exception handling
  (tag $exn (param anyref))

  ;; ==========================================
  ;; Closure Types
  ;; ==========================================

  ;; Function types for closures (env as first param)
  (type $ClosureFunc0 (func (param anyref) (result anyref)))
  (type $ClosureFunc1 (func (param anyref anyref) (result anyref)))
  (type $ClosureFunc2 (func (param anyref anyref anyref) (result anyref)))
  (type $ClosureFunc3 (func (param anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc4 (func (param anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc5 (func (param anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc6 (func (param anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc7 (func (param anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc8 (func (param anyref anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc9 (func (param anyref anyref anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))
  (type $ClosureFunc10 (func (param anyref anyref anyref anyref anyref anyref anyref anyref anyref anyref anyref) (result anyref)))

  ;; Closure structs for each arity (needed because funcref types are distinct)
  (type $Closure0 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc0))
    (field $env anyref))))
  (type $Closure1 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc1))
    (field $env anyref))))
  (type $Closure2 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc2))
    (field $env anyref))))
  (type $Closure3 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc3))
    (field $env anyref))))
  (type $Closure4 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc4))
    (field $env anyref))))
  (type $Closure5 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc5))
    (field $env anyref))))
  (type $Closure6 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc6))
    (field $env anyref))))
  (type $Closure7 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc7))
    (field $env anyref))))
  (type $Closure8 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc8))
    (field $env anyref))))
  (type $Closure9 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc9))
    (field $env anyref))))
  (type $Closure10 (sub $Tagged (struct
    (field $__type_id i32)
    (field $func (ref $ClosureFunc10))
    (field $env anyref))))

  ;; MultiClosure: dispatch function that routes to the right arity at runtime
  (type $MultiClosureDispatch (func (param anyref i32 anyref) (result anyref)))
  (type $MultiClosure (sub $Tagged (struct (field $__type_id i32) (field $env anyref) (field $dispatch (ref $MultiClosureDispatch)))))

  ;; ==========================================
  ;; List Runtime Functions
  ;; ==========================================

  ;; cons: create a new cons cell
  (func $cons (param $first anyref) (param $rest anyref) (result anyref)
    (struct.new $Cons (i32.const 6) (local.get $first) (local.get $rest)))

  ;; first: get the first element of a collection (polymorphic)
  ;; Works on: Cons, Vector, HashMap (returns first key-value pair as vector), HashSet, LazySeq
  (func $first (param $coll anyref) (result anyref)
    (local $count i32)
    (local $arr anyref)
    (local $vs (ref null $VectorSeq))
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> nil
    (if (ref.is_null (local.get $coll))
      (then (return (ref.null none))))
    ;; LazySeq - realize and recurse
    (block $not_lazy (result anyref)
      (br_on_cast_fail $not_lazy anyref (ref $LazySeq) (local.get $coll))
      (return (call $first (call $lazy_seq_realize (local.get $coll)))))
    (drop)
    ;; VectorSeq - O(1) indexed access
    (block $not_vseq (result anyref)
      (local.set $vs (br_on_cast_fail $not_vseq anyref (ref $VectorSeq) (local.get $coll)))
      (return (call $vector_nth
        (struct.get $VectorSeq $vec (local.get $vs))
        (struct.get $VectorSeq $offset (local.get $vs)))))
    (drop)
    ;; Cons cell
    (block $not_cons (result anyref)
      (return (struct.get $Cons $first
        (br_on_cast_fail $not_cons anyref (ref $Cons) (local.get $coll)))))
    (drop)
    ;; Vector
    (block $not_vec (result anyref)
      (br_on_cast_fail $not_vec anyref (ref $Vector) (local.get $coll))
      (local.set $count (call $vector_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 0))
        (then (return (ref.null none))))
      (return (call $vector_nth (local.get $coll) (i32.const 0))))
    (drop)
    ;; HashMap (tag=8) or ArrayMap (tag=19)
    (if (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
                (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
      (then (return (call $first (call $seq (local.get $coll))))))
    ;; HashSet (tag=9)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then (return (call $first (call $seq (local.get $coll))))))
    ;; String - return first char as 1-char string
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $coll))
      (if (i32.le_s (call $str_len (local.get $coll)) (i32.const 0))
        (then (return (ref.null none))))
      (return (call $char_at_as_str (local.get $coll) (i32.const 0))))
    (drop)
    ;; Protocol fallback: seq then first
    (if (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
      (then (return (call $first (call $__dispatch__seq (local.get $coll))))))
    (ref.null none))

  ;; rest: get the rest of a collection (polymorphic)
  ;; Works on: Cons, Vector, HashMap, HashSet, LazySeq, VectorSeq
  ;; Returns a seq for non-Cons types
  (func $rest (param $coll anyref) (result anyref)
    (local $count i32)
    (local $i i32)
    (local $arr anyref)
    (local $result anyref)
    (local $vs (ref null $VectorSeq))
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> empty list (nil)
    (if (ref.is_null (local.get $coll))
      (then (return (ref.null none))))
    ;; LazySeq - realize and recurse
    (block $not_lazy (result anyref)
      (br_on_cast_fail $not_lazy anyref (ref $LazySeq) (local.get $coll))
      (return (call $rest (call $lazy_seq_realize (local.get $coll)))))
    (drop)
    ;; VectorSeq - O(1) rest via offset increment
    (block $not_vseq (result anyref)
      (local.set $vs (br_on_cast_fail $not_vseq anyref (ref $VectorSeq) (local.get $coll)))
      (local.set $i (i32.add
        (struct.get $VectorSeq $offset (local.get $vs))
        (i32.const 1)))
      (if (result anyref) (i32.ge_s (local.get $i)
        (call $vector_count (struct.get $VectorSeq $vec (local.get $vs))))
        (then (ref.null none))
        (else (struct.new $VectorSeq (i32.const 18)
          (struct.get $VectorSeq $vec (local.get $vs))
          (local.get $i))))
      (return))
    (drop)
    ;; Cons cell
    (block $not_cons (result anyref)
      (return (struct.get $Cons $rest
        (br_on_cast_fail $not_cons anyref (ref $Cons) (local.get $coll)))))
    (drop)
    ;; Vector - return VectorSeq from index 1
    (block $not_vec (result anyref)
      (br_on_cast_fail $not_vec anyref (ref $Vector) (local.get $coll))
      (local.set $count (call $vector_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 1))
        (then (return (ref.null none))))
      (return (struct.new $VectorSeq (i32.const 18) (local.get $coll) (i32.const 1))))
    (drop)
    ;; HashMap (tag=8) or ArrayMap (tag=19)
    (if (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
                (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
      (then (return (call $rest (call $seq (local.get $coll))))))
    ;; HashSet (tag=9)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then (return (call $rest (call $seq (local.get $coll))))))
    ;; String - return rest as seq of codepoint strings
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $coll))
      (local.set $count (call $str_codepoint_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 1))
        (then (return (ref.null none))))
      ;; Build cons list of codepoint strings from end to start
      (local.set $result (ref.null none))
      (local.set $i (i32.sub (local.get $count) (i32.const 1)))
      (block $done4
        (loop $loop4
          (br_if $done4 (i32.lt_s (local.get $i) (i32.const 1)))
          (local.set $result (call $cons
            (call $char_at_as_str (local.get $coll) (local.get $i))
            (local.get $result)))
          (local.set $i (i32.sub (local.get $i) (i32.const 1)))
          (br $loop4)))
      (return (local.get $result)))
    (drop)
    ;; Protocol fallback: seq then rest
    (if (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
      (then (return (call $rest (call $__dispatch__seq (local.get $coll))))))
    (ref.null none))

  ;; nil?: check if value is nil (null reference) - returns $Boolean
  (func $nil_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $val))
      (then (global.get $__true)) (else (global.get $__false))))

  ;; cons?: check if value is a cons cell - returns $Boolean
  (func $cons_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Cons) (local.get $val))
      (then (global.get $__true)) (else (global.get $__false))))

  ;; ==========================================
  ;; List Helper Functions (for testing)
  ;; ==========================================

  ;; list-length: count elements in a seq (handles cons, lazy-seq tails)
  (func $list_length (export "list-length") (param $lst anyref) (result i32)
    (local $count i32)
    (local $current anyref)
    (local.set $current (local.get $lst))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $current)))
        ;; Handle lazy seq tails by realizing them
        (if (ref.test (ref $LazySeq) (local.get $current))
          (then (local.set $current (call $seq (local.get $current)))))
        (br_if $done (ref.is_null (local.get $current)))
        (if (ref.test (ref $Cons) (local.get $current))
          (then
            (local.set $count (i32.add (local.get $count) (i32.const 1)))
            (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
            (br $loop))
          (else
            ;; VectorSeq - add remaining count in O(1)
            (if (ref.test (ref $VectorSeq) (local.get $current))
              (then
                (local.set $count (i32.add (local.get $count)
                  (i32.sub
                    (call $vector_count (struct.get $VectorSeq $vec (ref.cast (ref $VectorSeq) (local.get $current))))
                    (struct.get $VectorSeq $offset (ref.cast (ref $VectorSeq) (local.get $current)))))))
              (else
                ;; Non-cons, non-lazy, non-VectorSeq, non-null - count as 1 and stop
                (local.set $count (i32.add (local.get $count) (i32.const 1)))))))))
    (local.get $count))

  ;; list-sum: sum all integers in a list (assumes i31ref elements, returns i32)
  (func $list_sum (export "list-sum") (param $lst anyref) (result i32)
    (local $sum i32)
    (local $current anyref)
    (local.set $current (local.get $lst))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $current)))
        (local.set $sum (i32.add (local.get $sum)
          (i31.get_s (ref.cast (ref i31) (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current)))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $loop)))
    (local.get $sum))

  ;; ==========================================
  ;; Polymorphic Operations
  ;; ==========================================

  ;; truthy: returns 1 if value is truthy, 0 if falsy
  ;; - null (nil) -> 0
  ;; - $Boolean with val=0 (false) -> 0
  ;; - $Boolean with val=1 (true) -> 1
  ;; - anything else -> 1 (integers including 0, keywords, cons cells, strings, etc.)
  (func $truthy (param $val anyref) (result i32)
    ;; Check for null first
    (if (result i32) (ref.is_null (local.get $val))
      (then (i32.const 0))
      (else
        ;; Check if it's a Boolean (tag=14)
        (if (result i32) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
          (then
            ;; It's a Boolean - return the val field (0=false, 1=true)
            (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val))))
          (else
            ;; Not null, not Boolean - everything else is truthy (including 0, keywords, etc.)
            (i32.const 1))))))

  ;; unbox_i32: convert anyref to i32 for export wrappers
  ;; Boolean -> 0/1, i31ref -> integer value, null -> 0, other -> 1
  (func $unbox_i32 (param $val anyref) (result i32)
    (if (ref.is_null (local.get $val))
      (then (return (i32.const 0))))
    ;; Boolean (tag=14)
    (if (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
      (then (return (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val))))))
    ;; i31ref (integer)
    (block $not_i31 (result anyref)
      (return (i31.get_s
        (br_on_cast_fail $not_i31 anyref (ref i31) (local.get $val)))))
    (drop)
    (i32.const 1))

  ;; unbox_f64: convert anyref to f64 for export wrappers
  ;; Float -> f64 value, i31ref -> convert to f64, other -> 0.0
  (func $unbox_f64 (param $val anyref) (result f64)
    (block $not_float (result anyref)
      (return (struct.get $Float $val
        (br_on_cast_fail $not_float anyref (ref $Float) (local.get $val)))))
    (drop)
    (block $not_i31 (result anyref)
      (return (f64.convert_i32_s (i31.get_s
        (br_on_cast_fail $not_i31 anyref (ref i31) (local.get $val))))))
    (drop)
    (f64.const 0))

  ;; is_nan: check if value is a NaN float - returns $Boolean
  ;; NaN is the only value where x != x
  (func $is_nan (param $val anyref) (result anyref)
    (local $fv (ref null $Float))
    (block $not_float (result anyref)
      (local.set $fv (br_on_cast_fail $not_float anyref (ref $Float) (local.get $val)))
      ;; It's a float - check if NaN using (x != x)
      (if (result anyref) (f64.ne
        (struct.get $Float $val (local.get $fv))
        (struct.get $Float $val (local.get $fv)))
        (then (global.get $__true))
        (else (global.get $__false)))
      (return))
    (drop)
    ;; Not a float - not NaN
    (global.get $__false))

  ;; ==========================================
  ;; Array Operations
  ;; ==========================================

  ;; array-new: create a new array of given size, filled with null
  (func $array_new (param $size i32) (result anyref)
    (array.new $AnyArray (ref.null none) (local.get $size)))

  ;; array-get: get element at index
  (func $array_get (param $arr anyref) (param $idx i32) (result anyref)
    (array.get $AnyArray (ref.cast (ref $AnyArray) (local.get $arr)) (local.get $idx)))

  ;; array-set: set element at index (mutates in place)
  (func $array_set (param $arr anyref) (param $idx i32) (param $val anyref)
    (array.set $AnyArray (ref.cast (ref $AnyArray) (local.get $arr)) (local.get $idx) (local.get $val)))

  ;; array-length: get array length
  (func $array_length (param $arr anyref) (result i32)
    (array.len (ref.cast (ref $AnyArray) (local.get $arr))))

  ;; array-copy: create a copy of array with new size (for growing)
  (func $array_copy (param $src anyref) (param $new_size i32) (result anyref)
    (local $dst anyref)
    (local $src_len i32)
    (local $copy_len i32)
    (local.set $src_len (array.len (ref.cast (ref $AnyArray) (local.get $src))))
    (local.set $copy_len (if (result i32) (i32.lt_s (local.get $src_len) (local.get $new_size))
      (then (local.get $src_len))
      (else (local.get $new_size))))
    (local.set $dst (array.new $AnyArray (ref.null none) (local.get $new_size)))
    (array.copy $AnyArray $AnyArray
      (ref.cast (ref $AnyArray) (local.get $dst)) (i32.const 0)
      (ref.cast (ref $AnyArray) (local.get $src)) (i32.const 0)
      (local.get $copy_len))
    (local.get $dst))

  ;; ==========================================
  ;; Polymorphic Hash and Equality
  ;; ==========================================

  ;; hash-int: integer hash (murmur-inspired bit mixing)
  (func $hash_int (param $n i32) (result i32)
    (local $h i32)
    (local.set $h (local.get $n))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))
    (local.set $h (i32.mul (local.get $h) (i32.const 0x85ebca6b)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 13))))
    (local.set $h (i32.mul (local.get $h) (i32.const 0xc2b2ae35)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))
    (local.get $h))

  ;; hash: polymorphic hash function
  ;; - nil -> 0
  ;; - i31ref (integer) -> hash_int
  ;; - Keyword -> keyword id (already unique)
  ;; - String -> string id
  ;; - Symbol -> symbol id
  ;; - Float -> hash of truncated value
  ;; - other -> default hash
  (func $hash (param $val anyref) (result i32)
    ;; null -> 0
    (if (ref.is_null (local.get $val))
      (then (return (i32.const 0))))
    ;; i31ref (integer/boolean)?
    (block $not_i31 (result anyref)
      (return (call $hash_int (i31.get_s
        (br_on_cast_fail $not_i31 anyref (ref i31) (local.get $val))))))
    (drop)
    ;; Keyword (tag=2)
    (if (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
      (then (return (call $hash_int (i32.add
        (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val)))
        (i32.const 0x9e3779b9))))))
    ;; String?
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $val))
      ;; Always use content-based hash for strings
      (return (call $str_hash (local.get $val))))
    (drop)
    ;; Symbol?
    (block $not_sym (result anyref)
      (br_on_cast_fail $not_sym anyref (ref $Symbol) (local.get $val))
      (return (call $sym_hash (local.get $val))))
    (drop)
    ;; Float?
    (block $not_float (result anyref)
      (br_on_cast_fail $not_float anyref (ref $Float) (local.get $val))
      ;; Reinterpret f64 bits via linear memory for proper hashing
      (f64.store (i32.const 0) (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))))
      (return (call $hash_int (i32.xor (i32.load (i32.const 0)) (i32.load (i32.const 4))))))
    (drop)
    ;; Vector (tag=7)
    (if (i32.eq (call $type_tag (local.get $val)) (i32.const 7))
      (then (return (call $hash_vector (local.get $val)))))
    ;; User-defined types
    (if (result i32) (i32.eq (call $type_tag (local.get $val)) (i32.const 20)) (then (i32.add (i32.mul (i32.const 31) (i32.add (i32.mul (i32.const 31) (i32.const 20)) (call $hash (struct.get $SortedMap $comparator (ref.cast (ref $SortedMap) (local.get $val)))))) (call $hash (struct.get $SortedMap $entries (ref.cast (ref $SortedMap) (local.get $val)))))) (else (if (result i32) (i32.eq (call $type_tag (local.get $val)) (i32.const 21)) (then (i32.add (i32.mul (i32.const 31) (i32.add (i32.mul (i32.const 31) (i32.const 21)) (call $hash (struct.get $SortedSet $comparator (ref.cast (ref $SortedSet) (local.get $val)))))) (call $hash (struct.get $SortedSet $elements (ref.cast (ref $SortedSet) (local.get $val)))))) (else (i32.const 31))))))

  ;; hash_vector: ordered hash-combine over vector elements
  ;; Uses Clojure's hash-ordered-coll algorithm: seed=1, h = 31*h + hash(elem)
  (func $hash_vector (param $v anyref) (result i32)
    (local $vec (ref $Vector))
    (local $cnt i32)
    (local $i i32)
    (local $h i32)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $cnt (struct.get $Vector $count (local.get $vec)))
    (local.set $h (i32.const 1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $cnt)))
        (local.set $h (i32.add
          (i32.mul (local.get $h) (i32.const 31))
          (call $hash (call $vector_nth (local.get $v) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $hash_int (local.get $h)))

  ;; eq: polymorphic equality
  ;; - both nil -> true
  ;; - both i31ref -> compare values
  ;; - both Keyword -> compare ids
  ;; - both String -> compare via $str_eq
  ;; - both Float -> compare f64 values
  ;; - different types -> false
  (func $eq (param $a anyref) (param $b anyref) (result i32)
    ;; Unwrap WithMeta on both sides (metadata doesn't affect equality)
    (local.set $a (call $unwrap_meta (local.get $a)))
    (local.set $b (call $unwrap_meta (local.get $b)))
    ;; Both null?
    (if (result i32) (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
      (then (i32.const 1))
      (else
        ;; One null, one not?
        (if (result i32) (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (i32.const 0))
          (else
            ;; Both Boolean?
            (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 14))
                                      (i32.eq (call $type_tag (local.get $b)) (i32.const 14)))
              (then (i32.eq
                      (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $a)))
                      (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $b)))))
              (else
                ;; Both i31ref?
                (if (result i32) (i32.and (ref.test (ref i31) (local.get $a))
                                          (ref.test (ref i31) (local.get $b)))
                  (then (i32.eq (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                (i31.get_s (ref.cast (ref i31) (local.get $b)))))
                  (else
                    ;; Both Keywords?
                    (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 2))
                                              (i32.eq (call $type_tag (local.get $b)) (i32.const 2)))
                      (then (i32.eq
                              (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $a)))
                              (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $b)))))
                      (else
                        ;; Both Symbols? Compare by name string + namespace
                        (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 4))
                                                  (i32.eq (call $type_tag (local.get $b)) (i32.const 4)))
                          (then (call $sym_eq (local.get $a) (local.get $b)))
                          (else
                        ;; Both Strings?
                        (if (result i32) (i32.and (ref.test (ref $String) (local.get $a))
                                                  (ref.test (ref $String) (local.get $b)))
                          (then (call $str_eq (local.get $a) (local.get $b)))
                          (else
                            ;; Both Floats?
                            (if (result i32) (i32.and (ref.test (ref $Float) (local.get $a))
                                                      (ref.test (ref $Float) (local.get $b)))
                              (then (f64.eq
                                (struct.get $Float $val (ref.cast (ref $Float) (local.get $a)))
                                (struct.get $Float $val (ref.cast (ref $Float) (local.get $b)))))
                              (else
                                ;; Both seq-like (Cons, VectorSeq, or LazySeq)?
                                (if (result i32) (i32.and
                                    (i32.or (i32.or (ref.test (ref $Cons) (local.get $a)) (ref.test (ref $VectorSeq) (local.get $a))) (ref.test (ref $LazySeq) (local.get $a)))
                                    (i32.or (i32.or (ref.test (ref $Cons) (local.get $b)) (ref.test (ref $VectorSeq) (local.get $b))) (ref.test (ref $LazySeq) (local.get $b))))
                                  (then (call $seq_eq (local.get $a) (local.get $b)))
                                  (else
                                    ;; Both Vector?
                                    (if (result i32) (i32.and (ref.test (ref $Vector) (local.get $a))
                                                              (ref.test (ref $Vector) (local.get $b)))
                                      (then (call $vector_eq (local.get $a) (local.get $b)))
                                      (else
                                        ;; Both map-like (HashMap or ArrayMap)?
                                        (if (result i32) (i32.and (i32.or (i32.eq (call $type_tag (local.get $a)) (i32.const 8)) (i32.eq (call $type_tag (local.get $a)) (i32.const 19)))
                                                                  (i32.or (i32.eq (call $type_tag (local.get $b)) (i32.const 8)) (i32.eq (call $type_tag (local.get $b)) (i32.const 19))))
                                          (then (call $hashmap_eq (local.get $a) (local.get $b)))
                                          (else
                                            ;; Both HashSet?
                                            (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 9))
                                                                      (i32.eq (call $type_tag (local.get $b)) (i32.const 9)))
                                              (then (call $hashset_eq (local.get $a) (local.get $b)))
                                              (else
                                                (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 20)) (i32.eq (call $type_tag (local.get $b)) (i32.const 20))) (then (i32.and (call $eq (struct.get $SortedMap $comparator (ref.cast (ref $SortedMap) (local.get $a))) (struct.get $SortedMap $comparator (ref.cast (ref $SortedMap) (local.get $b)))) (call $eq (struct.get $SortedMap $entries (ref.cast (ref $SortedMap) (local.get $a))) (struct.get $SortedMap $entries (ref.cast (ref $SortedMap) (local.get $b)))))) (else (if (result i32) (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 21)) (i32.eq (call $type_tag (local.get $b)) (i32.const 21))) (then (i32.and (call $eq (struct.get $SortedSet $comparator (ref.cast (ref $SortedSet) (local.get $a))) (struct.get $SortedSet $comparator (ref.cast (ref $SortedSet) (local.get $b)))) (call $eq (struct.get $SortedSet $elements (ref.cast (ref $SortedSet) (local.get $a))) (struct.get $SortedSet $elements (ref.cast (ref $SortedSet) (local.get $b)))))) (else (i32.const 0))))))))))))))))))))))))))))))

  ;; seq_eq: general sequence equality using first/rest (handles Cons, VectorSeq, mixed)
  (func $seq_eq (param $a anyref) (param $b anyref) (result i32)
    (block $neq (result i32)
      (loop $loop (result i32)
        ;; Both nil -> equal
        (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 1))))
        ;; One nil -> not equal
        (if (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 0))))
        ;; Compare first elements
        (br_if $neq (i32.const 0) (i32.eqz (call $eq
          (call $first (local.get $a))
          (call $first (local.get $b)))))
        ;; Advance both
        (local.set $a (call $rest (local.get $a)))
        (local.set $b (call $rest (local.get $b)))
        ;; Normalize: nil means empty
        (if (ref.is_null (local.get $a))
          (then) (else (local.set $a (call $seq (local.get $a)))))
        (if (ref.is_null (local.get $b))
          (then) (else (local.set $b (call $seq (local.get $b)))))
        (br $loop))))

  ;; cons_eq: structural equality for cons lists
  (func $cons_eq (param $a anyref) (param $b anyref) (result i32)
    (local $ca (ref $Cons))
    (local $cb (ref $Cons))
    (block $neq (result i32)
      (loop $loop (result i32)
        ;; Both nil -> equal
        (if (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 1))))
        ;; One nil -> not equal
        (if (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (return (i32.const 0))))
        ;; Both must be Cons
        (if (i32.eqz (i32.and (ref.test (ref $Cons) (local.get $a))
                               (ref.test (ref $Cons) (local.get $b))))
          (then (return (i32.const 0))))
        (local.set $ca (ref.cast (ref $Cons) (local.get $a)))
        (local.set $cb (ref.cast (ref $Cons) (local.get $b)))
        (br_if $neq (i32.const 0) (i32.eqz (call $eq
          (struct.get $Cons $first (local.get $ca))
          (struct.get $Cons $first (local.get $cb)))))
        (local.set $a (struct.get $Cons $rest (local.get $ca)))
        (local.set $b (struct.get $Cons $rest (local.get $cb)))
        (br $loop))))

  ;; vector_eq: structural equality for vectors
  (func $vector_eq (param $a anyref) (param $b anyref) (result i32)
    (local $count i32)
    (local $i i32)
    (local.set $count (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $a))))
    (if (result i32) (i32.ne (local.get $count) (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $b))))
      (then (i32.const 0))
      (else
        (local.set $i (i32.const 0))
        (block $neq (result i32)
          (block $done
            (loop $loop
              (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
              (br_if $neq (i32.const 0) (i32.eqz (call $eq
                (call $vector_nth (local.get $a) (local.get $i))
                (call $vector_nth (local.get $b) (local.get $i)))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $loop)))
          (i32.const 1)))))

  ;; hashmap_eq: structural equality for hash maps (HashMap or ArrayMap)
  (func $hashmap_eq (param $a anyref) (param $b anyref) (result i32)
    (local $entries anyref)
    (local $entry anyref)
    (local $key anyref)
    (local $val_a anyref)
    (local $val_b anyref)
    (if (result i32) (i32.ne
        (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $a)))
        (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $b))))
      (then (i32.const 0))
      (else
        ;; Use seq to iterate entries of A (works for both HashMap and ArrayMap)
        (local.set $entries (call $seq (local.get $a)))
        (block $neq (result i32)
          (block $done
            (loop $loop
              (br_if $done (ref.is_null (local.get $entries)))
              ;; Each entry is a [k v] vector
              (local.set $entry (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $entries))))
              (local.set $key (call $vector_nth (local.get $entry) (i32.const 0)))
              (local.set $val_a (call $vector_nth (local.get $entry) (i32.const 1)))
              (local.set $val_b (call $hash_map_get_sentinel (local.get $b) (local.get $key)))
              (br_if $neq (i32.const 0) (ref.eq (ref.cast eqref (local.get $val_b)) (global.get $__not_found_sentinel)))
              (br_if $neq (i32.const 0) (i32.eqz (call $eq (local.get $val_a) (local.get $val_b))))
              (local.set $entries (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $entries))))
              (br $loop)))
          (i32.const 1)))))

  ;; hashset_eq: structural equality for hash sets (HAMT-backed)
  (func $hashset_eq (param $a anyref) (param $b anyref) (result i32)
    (local $keys anyref)
    (local $elem anyref)
    (if (result i32) (i32.ne
        (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $a)))
        (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $b))))
      (then (i32.const 0))
      (else
        (local.set $keys (call $hamt_keys
          (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $a)))
          (ref.null none)))
        (block $neq (result i32)
          (block $done
            (loop $loop
              (br_if $done (ref.is_null (local.get $keys)))
              (local.set $elem (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $keys))))
              (br_if $neq (i32.const 0) (i32.eqz (call $truthy (call $set_contains_QMARK_ (local.get $b) (local.get $elem)))))
              (local.set $keys (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $keys))))
              (br $loop)))
          (i32.const 1)))))

  ;; popcount: count number of 1 bits (for HAMT bitmap indexing)
  (func $popcount (param $x i32) (result i32)
    (local $count i32)
    (local.set $count (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.eqz (local.get $x)))
        (local.set $count (i32.add (local.get $count) (i32.and (local.get $x) (i32.const 1))))
        (local.set $x (i32.shr_u (local.get $x) (i32.const 1)))
        (br $loop)))
    (local.get $count))

  ;; mask: get 5-bit chunk from hash at given shift level
  (func $mask (param $hash i32) (param $shift i32) (result i32)
    (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))

  ;; bitpos: get bit position for a given mask value
  (func $bitpos (param $mask i32) (result i32)
    (i32.shl (i32.const 1) (local.get $mask)))

  ;; ==========================================
  ;; Persistent Vector Operations
  ;; ==========================================

  ;; empty-vector: create an empty vector
  (func $empty_vector (result anyref)
    (struct.new $Vector (i32.const 7)
      (i32.const 0)       ;; count = 0
      (i32.const 5)       ;; shift = 5 (start at leaf level)
      (ref.null none)     ;; root = null
      (call $array_new (i32.const 0))))  ;; tail = empty array

  ;; vector-from-array: create a vector directly from an AnyArray (for count <= 32)
  (func $vector_from_array (param $arr anyref) (result anyref)
    (struct.new $Vector (i32.const 7)
      (array.len (ref.cast (ref $AnyArray) (local.get $arr)))
      (i32.const 5)
      (ref.null none)
      (local.get $arr)))

  ;; vector-count: get number of elements
  (func $vector_count (param $v anyref) (result i32)
    (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $v))))

  ;; tail-offset: calculate where the tail starts
  (func $tail_offset (param $count i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $count) (i32.const 32))
      (then (i32.const 0))
      (else
        ;; ((count - 1) >>> 5) << 5
        (i32.shl
          (i32.shr_u (i32.sub (local.get $count) (i32.const 1)) (i32.const 5))
          (i32.const 5)))))

  ;; vector-array-for: get the array containing element at index
  (func $vector_array_for (param $v anyref) (param $idx i32) (result anyref)
    (local $vec (ref $Vector))
    (local $count i32)
    (local $shift i32)
    (local $node anyref)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $count (struct.get $Vector $count (local.get $vec)))
    ;; Check if index is in tail
    (if (result anyref) (i32.ge_u (local.get $idx) (call $tail_offset (local.get $count)))
      (then (struct.get $Vector $tail (local.get $vec)))
      (else
        ;; Navigate the trie
        (local.set $node (struct.get $Vector $root (local.get $vec)))
        (local.set $shift (struct.get $Vector $shift (local.get $vec)))
        (block $done (result anyref)
          (loop $loop
            (br_if $done (local.get $node) (i32.le_s (local.get $shift) (i32.const 0)))
            (local.set $node (call $array_get
              (local.get $node)
              (i32.and (i32.shr_u (local.get $idx) (local.get $shift)) (i32.const 31))))
            (local.set $shift (i32.sub (local.get $shift) (i32.const 5)))
            (br $loop))
          (local.get $node)))))

  ;; vector-nth: get element at index
  (func $vector_nth (param $v anyref) (param $idx i32) (result anyref)
    (local $arr anyref)
    (local.set $arr (call $vector_array_for (local.get $v) (local.get $idx)))
    (call $array_get (local.get $arr) (i32.and (local.get $idx) (i32.const 31))))

  ;; new-path: create a path of single-element arrays down to a leaf
  (func $new_path (param $shift i32) (param $node anyref) (result anyref)
    (local $arr anyref)
    (if (result anyref) (i32.eqz (local.get $shift))
      (then (local.get $node))
      (else
        (local.set $arr (call $array_new (i32.const 32)))
        (call $array_set (local.get $arr) (i32.const 0)
          (call $new_path (i32.sub (local.get $shift) (i32.const 5)) (local.get $node)))
        (local.get $arr))))

  ;; push-tail: push a new tail into the trie
  (func $push_tail (param $shift i32) (param $parent anyref) (param $tail anyref) (result anyref)
    (local $sub_idx i32)
    (local $new_arr anyref)
    (local $child anyref)
    (local $parent_arr (ref $AnyArray))
    ;; Calculate index in this level
    (local.set $sub_idx (i32.and
      (i32.shr_u (i32.sub (struct.get $Vector $count (ref.cast (ref $Vector) (global.get $__push_tail_vec))) (i32.const 1))
                 (local.get $shift))
      (i32.const 31)))
    ;; Create new array for this node
    (local.set $new_arr (call $array_new (i32.const 32)))
    ;; Copy from parent if exists
    (if (i32.eqz (ref.is_null (local.get $parent)))
      (then
        (local.set $parent_arr (ref.cast (ref $AnyArray) (local.get $parent)))
        (array.copy $AnyArray $AnyArray
          (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
          (local.get $parent_arr) (i32.const 0)
          (array.len (local.get $parent_arr)))))
    ;; Insert at appropriate position
    (if (i32.eq (local.get $shift) (i32.const 5))
      (then
        ;; Leaf level - insert tail directly
        (call $array_set (local.get $new_arr) (local.get $sub_idx) (local.get $tail)))
      (else
        ;; Internal node - recurse
        (local.set $child (call $array_get (local.get $parent) (local.get $sub_idx)))
        (if (ref.is_null (local.get $child))
          (then
            ;; No child - create new path
            (call $array_set (local.get $new_arr) (local.get $sub_idx)
              (call $new_path (i32.sub (local.get $shift) (i32.const 5)) (local.get $tail))))
          (else
            ;; Has child - recurse into it
            (call $array_set (local.get $new_arr) (local.get $sub_idx)
              (call $push_tail (i32.sub (local.get $shift) (i32.const 5)) (local.get $child) (local.get $tail)))))))
    (local.get $new_arr))

  ;; Global for push_tail recursion (workaround for passing vector context)
  (global $__push_tail_vec (mut anyref) (ref.null none))

  ;; vector-conj: add element to end
  (func $vector_conj (param $v anyref) (param $val anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $count i32)
    (local $shift i32)
    (local $root anyref)
    (local $tail anyref)
    (local $new_tail anyref)
    (local $new_root anyref)
    (local $tail_len i32)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $count (struct.get $Vector $count (local.get $vec)))
    (local.set $shift (struct.get $Vector $shift (local.get $vec)))
    (local.set $root (struct.get $Vector $root (local.get $vec)))
    (local.set $tail (struct.get $Vector $tail (local.get $vec)))
    (local.set $tail_len (call $array_length (local.get $tail)))
    ;; Check if room in tail
    (if (result anyref) (i32.lt_s (local.get $tail_len) (i32.const 32))
      (then
        ;; Room in tail - create new tail with element appended
        (local.set $new_tail (call $array_new (i32.add (local.get $tail_len) (i32.const 1))))
        (if (i32.gt_s (local.get $tail_len) (i32.const 0))
          (then
            (array.copy $AnyArray $AnyArray
              (ref.cast (ref $AnyArray) (local.get $new_tail)) (i32.const 0)
              (ref.cast (ref $AnyArray) (local.get $tail)) (i32.const 0)
              (local.get $tail_len))))
        (call $array_set (local.get $new_tail) (local.get $tail_len) (local.get $val))
        (struct.new $Vector (i32.const 7)
          (i32.add (local.get $count) (i32.const 1))
          (local.get $shift)
          (local.get $root)
          (local.get $new_tail)))
      (else
        ;; Tail is full - push tail into trie, create new tail
        (local.set $new_tail (call $array_new (i32.const 1)))
        (call $array_set (local.get $new_tail) (i32.const 0) (local.get $val))
        ;; Set global for push_tail
        (global.set $__push_tail_vec (local.get $v))
        ;; Check if we need to grow the tree
        (if (result anyref) (i32.gt_u (i32.shr_u (local.get $count) (i32.const 5))
                                       (i32.shl (i32.const 1) (local.get $shift)))
          (then
            ;; Tree overflow - need new root level
            (local.set $new_root (call $array_new (i32.const 32)))
            (call $array_set (local.get $new_root) (i32.const 0) (local.get $root))
            (call $array_set (local.get $new_root) (i32.const 1)
              (call $new_path (local.get $shift) (local.get $tail)))
            (struct.new $Vector (i32.const 7)
              (i32.add (local.get $count) (i32.const 1))
              (i32.add (local.get $shift) (i32.const 5))
              (local.get $new_root)
              (local.get $new_tail)))
          (else
            ;; Push tail into existing tree
            (struct.new $Vector (i32.const 7)
              (i32.add (local.get $count) (i32.const 1))
              (local.get $shift)
              (call $push_tail (local.get $shift) (local.get $root) (local.get $tail))
              (local.get $new_tail)))))))

  ;; do-assoc: helper for assoc in trie
  (func $do_assoc (param $shift i32) (param $node anyref) (param $idx i32) (param $val anyref) (result anyref)
    (local $new_arr anyref)
    (local $sub_idx i32)
    (if (result anyref) (i32.eqz (local.get $shift))
      (then
        ;; Leaf level - clone array and update
        (local.set $new_arr (call $array_copy (local.get $node) (call $array_length (local.get $node))))
        (call $array_set (local.get $new_arr) (i32.and (local.get $idx) (i32.const 31)) (local.get $val))
        (local.get $new_arr))
      (else
        ;; Internal node - recurse
        (local.set $sub_idx (i32.and (i32.shr_u (local.get $idx) (local.get $shift)) (i32.const 31)))
        (local.set $new_arr (call $array_copy (local.get $node) (i32.const 32)))
        (call $array_set (local.get $new_arr) (local.get $sub_idx)
          (call $do_assoc
            (i32.sub (local.get $shift) (i32.const 5))
            (call $array_get (local.get $node) (local.get $sub_idx))
            (local.get $idx)
            (local.get $val)))
        (local.get $new_arr))))

  ;; vector-assoc: update element at index
  (func $vector_assoc (param $v anyref) (param $idx i32) (param $val anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $count i32)
    (local $shift i32)
    (local $tail_off i32)
    (local $new_tail anyref)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $count (struct.get $Vector $count (local.get $vec)))
    (local.set $shift (struct.get $Vector $shift (local.get $vec)))
    (local.set $tail_off (call $tail_offset (local.get $count)))
    ;; Check if index is in tail
    (if (result anyref) (i32.ge_u (local.get $idx) (local.get $tail_off))
      (then
        ;; In tail - clone tail and update
        (local.set $new_tail (call $array_copy
          (struct.get $Vector $tail (local.get $vec))
          (call $array_length (struct.get $Vector $tail (local.get $vec)))))
        (call $array_set (local.get $new_tail)
          (i32.and (local.get $idx) (i32.const 31))
          (local.get $val))
        (struct.new $Vector (i32.const 7)
          (local.get $count)
          (local.get $shift)
          (struct.get $Vector $root (local.get $vec))
          (local.get $new_tail)))
      (else
        ;; In trie - use do_assoc
        (struct.new $Vector (i32.const 7)
          (local.get $count)
          (local.get $shift)
          (call $do_assoc (local.get $shift) (struct.get $Vector $root (local.get $vec)) (local.get $idx) (local.get $val))
          (struct.get $Vector $tail (local.get $vec))))))

  ;; vector?: check if value is a vector
  (func $vector_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Vector) (local.get $val))))


  ;; User-defined types
  (type $SortedMap (sub $Tagged (struct (field $__type_id i32) (field $comparator anyref) (field $entries anyref))))
  (type $SortedSet (sub $Tagged (struct (field $__type_id i32) (field $comparator anyref) (field $elements anyref))))
  ;; ==========================================
  ;; HAMT (Hash Array Mapped Trie) Implementation
  ;; ==========================================
  ;; HashMap and HashSet backed by persistent HAMT.
  ;; O(log32 n) get/assoc/dissoc instead of O(n) linear scan.
  ;; Uses 5-bit chunks of hash at each trie level (max 7 levels).
  ;; Node types: HAMTNode (branch), HAMTEntry (leaf), HAMTCollision (hash clash).

  ;; Global flag: set to 1 by hamt_assoc when a NEW entry is added (not update)
  (global $__hamt_added (mut i32) (i32.const 0))

  ;; ---- HAMT core: get ----
  (func $hamt_get (param $node anyref) (param $key anyref) (param $hash i32) (param $shift i32) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $slot i32) (local $bit i32) (local $idx i32)
    (local $child anyref)
    (local $entry (ref $HAMTEntry))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $cnt i32)
    ;; null -> not found
    (if (ref.is_null (local.get $node)) (then (return (global.get $__not_found_sentinel))))
    ;; HAMTEntry leaf
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
          (then (return (struct.get $HAMTEntry $val (local.get $entry)))))
        (return (global.get $__not_found_sentinel))))
    ;; HAMTNode branch
    (if (result anyref) (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (if (result anyref) (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then (global.get $__not_found_sentinel))
          (else
            (local.set $idx (i32.popcnt (i32.and
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (i32.sub (local.get $bit) (i32.const 1)))))
            (local.set $child (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $idx)))
            (call $hamt_get (local.get $child) (local.get $key) (local.get $hash)
              (i32.add (local.get $shift) (i32.const 5))))))
      (else
    ;; HAMTCollision
    (if (result anyref) (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
        (local.set $i (i32.const 0))
        (block $found (result anyref)
          (block $notfound
            (loop $loop
              (br_if $notfound (i32.ge_s (local.get $i) (local.get $cnt)))
              (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                (then (br $found (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $loop)))
          (global.get $__not_found_sentinel)))
      (else (global.get $__not_found_sentinel))))))

  ;; ---- HAMT core: create node from two entries at different hashes ----
  (func $hamt_two (param $e1 anyref) (param $h1 i32) (param $e2 anyref) (param $h2 i32) (param $shift i32) (result anyref)
    (local $s1 i32) (local $s2 i32)
    (local $bit1 i32) (local $bit2 i32)
    (local $arr anyref) (local $child anyref)
    ;; Exhausted hash bits -> collision
    (if (result anyref) (i32.ge_u (local.get $shift) (i32.const 32))
      (then
        (local.set $arr (call $array_new (i32.const 4)))
        (call $array_set (local.get $arr) (i32.const 0) (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $e1))))
        (call $array_set (local.get $arr) (i32.const 1) (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $e1))))
        (call $array_set (local.get $arr) (i32.const 2) (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $e2))))
        (call $array_set (local.get $arr) (i32.const 3) (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $e2))))
        (struct.new $HAMTCollision (i32.const 0) (local.get $h1) (i32.const 2) (ref.cast (ref $AnyArray) (local.get $arr))))
      (else
        (local.set $s1 (i32.and (i32.shr_u (local.get $h1) (local.get $shift)) (i32.const 31)))
        (local.set $s2 (i32.and (i32.shr_u (local.get $h2) (local.get $shift)) (i32.const 31)))
        (if (result anyref) (i32.eq (local.get $s1) (local.get $s2))
          (then
            ;; Same slot -> recurse deeper
            (local.set $child (call $hamt_two (local.get $e1) (local.get $h1) (local.get $e2) (local.get $h2)
              (i32.add (local.get $shift) (i32.const 5))))
            (local.set $arr (call $array_new (i32.const 1)))
            (call $array_set (local.get $arr) (i32.const 0) (local.get $child))
            (struct.new $HAMTNode (i32.const 0)
              (i32.shl (i32.const 1) (local.get $s1))
              (ref.cast (ref $AnyArray) (local.get $arr))))
          (else
            ;; Different slots -> two-child node
            (local.set $bit1 (i32.shl (i32.const 1) (local.get $s1)))
            (local.set $bit2 (i32.shl (i32.const 1) (local.get $s2)))
            (local.set $arr (call $array_new (i32.const 2)))
            (if (i32.lt_u (local.get $s1) (local.get $s2))
              (then
                (call $array_set (local.get $arr) (i32.const 0) (local.get $e1))
                (call $array_set (local.get $arr) (i32.const 1) (local.get $e2)))
              (else
                (call $array_set (local.get $arr) (i32.const 0) (local.get $e2))
                (call $array_set (local.get $arr) (i32.const 1) (local.get $e1))))
            (struct.new $HAMTNode (i32.const 0)
              (i32.or (local.get $bit1) (local.get $bit2))
              (ref.cast (ref $AnyArray) (local.get $arr))))))))

  ;; ---- HAMT core: assoc ----
  (func $hamt_assoc (param $node anyref) (param $key anyref) (param $val anyref) (param $hash i32) (param $shift i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $i i32) (local $cnt i32) (local $found_idx i32)
    ;; null -> new entry
    (if (ref.is_null (local.get $node))
      (then
        (global.set $__hamt_added (i32.const 1))
        (return (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val)))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (i32.eq (struct.get $HAMTEntry $hash (local.get $entry)) (local.get $hash))
          (then
            (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
              (then
                ;; Same key -> update value
                (return (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val))))
              (else
                ;; Hash collision -> collision node
                (global.set $__hamt_added (i32.const 1))
                (local.set $new_arr (call $array_new (i32.const 4)))
                (call $array_set (local.get $new_arr) (i32.const 0) (struct.get $HAMTEntry $key (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 1) (struct.get $HAMTEntry $val (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 2) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.const 3) (local.get $val))
                (return (struct.new $HAMTCollision (i32.const 0) (local.get $hash) (i32.const 2) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
          (else
            ;; Different hash -> split
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTEntry $hash (local.get $entry))
              (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; HAMTNode
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (local.set $idx (i32.popcnt (i32.and
          (struct.get $HAMTNode $bitmap (local.get $nd))
          (i32.sub (local.get $bit) (i32.const 1)))))
        (if (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then
            ;; Empty slot -> insert new entry
            (global.set $__hamt_added (i32.const 1))
            (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
            (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
            (local.set $new_arr (call $array_new (i32.add (local.get $len) (i32.const 1))))
            ;; Copy elements before idx
            (if (i32.gt_s (local.get $idx) (i32.const 0))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                (local.get $idx))))
            ;; Insert new entry at idx
            (call $array_set (local.get $new_arr) (local.get $idx)
              (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val)))
            ;; Copy elements after idx
            (if (i32.lt_s (local.get $idx) (local.get $len))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.add (local.get $idx) (i32.const 1))
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (local.get $idx)
                (i32.sub (local.get $len) (local.get $idx)))))
            (return (struct.new $HAMTNode (i32.const 0)
              (i32.or (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit))
              (ref.cast (ref $AnyArray) (local.get $new_arr)))))
          (else
            ;; Occupied slot -> recurse
            (local.set $child (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_assoc (local.get $child) (local.get $key) (local.get $val)
              (local.get $hash) (i32.add (local.get $shift) (i32.const 5))))
            (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
            (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
            (local.set $new_arr (call $array_copy (local.get $old_arr) (local.get $len)))
            (call $array_set (local.get $new_arr) (local.get $idx) (local.get $new_child))
            (return (struct.new $HAMTNode (i32.const 0)
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (ref.cast (ref $AnyArray) (local.get $new_arr))))))))
    ;; HAMTCollision
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (if (i32.eq (struct.get $HAMTCollision $hash (local.get $col)) (local.get $hash))
          (then
            ;; Same hash -> update or extend collision
            (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
            (local.set $found_idx (i32.const -1))
            (local.set $i (i32.const 0))
            (block $cfound
              (loop $cloop
                (br_if $cfound (i32.ge_s (local.get $i) (local.get $cnt)))
                (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                  (then (local.set $found_idx (local.get $i)) (br $cfound)))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $cloop)))
            (if (i32.ge_s (local.get $found_idx) (i32.const 0))
              (then
                ;; Update existing
                (local.set $new_arr (call $array_copy (struct.get $HAMTCollision $entries (local.get $col))
                  (i32.mul (local.get $cnt) (i32.const 2))))
                (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $found_idx) (i32.const 2)) (i32.const 1)) (local.get $val))
                (return (struct.new $HAMTCollision (i32.const 0) (local.get $hash) (local.get $cnt) (ref.cast (ref $AnyArray) (local.get $new_arr)))))
              (else
                ;; Add new to collision
                (global.set $__hamt_added (i32.const 1))
                (local.set $new_arr (call $array_new (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (if (i32.gt_s (local.get $cnt) (i32.const 0))
                  (then (array.copy $AnyArray $AnyArray
                    (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                    (ref.cast (ref $AnyArray) (struct.get $HAMTCollision $entries (local.get $col))) (i32.const 0)
                    (i32.mul (local.get $cnt) (i32.const 2)))))
                (call $array_set (local.get $new_arr) (i32.mul (local.get $cnt) (i32.const 2)) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 1)) (local.get $val))
                (return (struct.new $HAMTCollision (i32.const 0) (local.get $hash) (i32.add (local.get $cnt) (i32.const 1)) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
          (else
            ;; Different hash -> wrap collision in node
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTCollision $hash (local.get $col))
              (struct.new $HAMTEntry (i32.const 0) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; Fallback (shouldn't reach)
    (local.get $node))

  ;; ---- HAMT core: dissoc ----
  (func $hamt_dissoc (param $node anyref) (param $key anyref) (param $hash i32) (param $shift i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $new_bm i32) (local $i i32) (local $j i32) (local $cnt i32)
    ;; null -> unchanged
    (if (ref.is_null (local.get $node)) (then (return (ref.null none))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
          (then (return (ref.null none))))
        (return (local.get $node))))
    ;; HAMTNode
    (if (result anyref) (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (if (result anyref) (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then (local.get $node))  ;; not found
          (else
            (local.set $idx (i32.popcnt (i32.and
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (i32.sub (local.get $bit) (i32.const 1)))))
            (local.set $child (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_dissoc (local.get $child) (local.get $key) (local.get $hash)
              (i32.add (local.get $shift) (i32.const 5))))
            (if (result anyref) (ref.is_null (local.get $new_child))
              (then
                ;; Child removed entirely -> shrink array
                (local.set $new_bm (i32.and (struct.get $HAMTNode $bitmap (local.get $nd))
                  (i32.xor (local.get $bit) (i32.const -1))))
                (if (result anyref) (i32.eqz (local.get $new_bm))
                  (then (ref.null none))  ;; node now empty
                  (else
                    (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
                    (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
                    ;; If only one child remains and it's a HAMTEntry, promote it
                    ;; NOTE: must use nested ifs (not i32.and) for short-circuit evaluation,
                    ;; otherwise array_get(old_arr, 1-idx) is evaluated even when len != 2
                    (block $after_promote (result anyref)
                      (if (i32.eq (local.get $len) (i32.const 2))
                        (then
                          (if (ref.test (ref $HAMTEntry) (call $array_get (local.get $old_arr)
                              (i32.sub (i32.const 1) (local.get $idx))))
                            (then
                              (br $after_promote (call $array_get (local.get $old_arr) (i32.sub (i32.const 1) (local.get $idx))))))))
                      ;; Fall through: shrink array (remove child at idx)
                      (local.set $new_arr (call $array_new (i32.sub (local.get $len) (i32.const 1))))
                      (if (i32.gt_s (local.get $idx) (i32.const 0))
                        (then (array.copy $AnyArray $AnyArray
                          (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                          (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                          (local.get $idx))))
                      (if (i32.lt_s (i32.add (local.get $idx) (i32.const 1)) (local.get $len))
                        (then (array.copy $AnyArray $AnyArray
                          (ref.cast (ref $AnyArray) (local.get $new_arr)) (local.get $idx)
                          (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.add (local.get $idx) (i32.const 1))
                          (i32.sub (i32.sub (local.get $len) (local.get $idx)) (i32.const 1)))))
                      (struct.new $HAMTNode (i32.const 0) (local.get $new_bm) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
              (else
                ;; Child changed -> replace
                (local.set $old_arr (struct.get $HAMTNode $children (local.get $nd)))
                (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
                (local.set $new_arr (call $array_copy (local.get $old_arr) (local.get $len)))
                (call $array_set (local.get $new_arr) (local.get $idx) (local.get $new_child))
                (struct.new $HAMTNode (i32.const 0) (struct.get $HAMTNode $bitmap (local.get $nd))
                  (ref.cast (ref $AnyArray) (local.get $new_arr))))))))
      (else
    ;; HAMTCollision
    (if (result anyref) (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
        ;; Find key in collision entries
        (local.set $i (i32.const -1))
        (local.set $j (i32.const 0))
        (block $cfound
          (loop $cloop
            (br_if $cfound (i32.ge_s (local.get $j) (local.get $cnt)))
            (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2))))
              (then (local.set $i (local.get $j)) (br $cfound)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $cloop)))
        (if (result anyref) (i32.lt_s (local.get $i) (i32.const 0))
          (then (local.get $node))  ;; not found
          (else
            (if (result anyref) (i32.eq (local.get $cnt) (i32.const 2))
              (then
                ;; Down to 1 entry -> promote to HAMTEntry
                (local.set $j (i32.sub (i32.const 1) (local.get $i)))
                (struct.new $HAMTEntry (i32.const 0)
                  (struct.get $HAMTCollision $hash (local.get $col))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2)))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1)))))
              (else
                ;; Remove entry from collision
                (local.set $new_arr (call $array_new (i32.mul (i32.sub (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (local.set $j (i32.const 0))
                (local.set $slot (i32.const 0))
                (block $cdone
                  (loop $ccopy
                    (br_if $cdone (i32.ge_s (local.get $j) (local.get $cnt)))
                    (if (i32.ne (local.get $j) (local.get $i))
                      (then
                        (call $array_set (local.get $new_arr) (i32.mul (local.get $slot) (i32.const 2))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2))))
                        (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $slot) (i32.const 2)) (i32.const 1))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1))))
                        (local.set $slot (i32.add (local.get $slot) (i32.const 1)))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $ccopy)))
                (struct.new $HAMTCollision (i32.const 0)
                  (struct.get $HAMTCollision $hash (local.get $col))
                  (i32.sub (local.get $cnt) (i32.const 1))
                  (ref.cast (ref $AnyArray) (local.get $new_arr))))))))
      (else (local.get $node))))))

  ;; ---- HAMT core: fold for keys ----
  (func $hamt_keys (param $node anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $cons (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node))) (local.get $acc)))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.sub (struct.get $HAMTCollision $count (local.get $col)) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $cons
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2)))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.sub (local.get $len) (i32.const 1)))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $hamt_keys
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: fold for vals ----
  (func $hamt_vals (param $node anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $cons (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node))) (local.get $acc)))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.sub (struct.get $HAMTCollision $count (local.get $col)) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $cons
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.sub (local.get $len) (i32.const 1)))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $hamt_vals
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: reduce-kv (f acc key val) ----
  (func $hamt_reduce (param $node anyref) (param $f anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (call $reduced_QMARK_ (local.get $acc)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $invoke3 (local.get $f) (local.get $acc)
        (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node)))
        (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node)))))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_s (local.get $i) (struct.get $HAMTCollision $count (local.get $col))))
            (br_if $done (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $invoke3 (local.get $f) (local.get $acc)
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2)))
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.const 0))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.ge_s (local.get $i) (local.get $len)))
            (br_if $done2 (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $hamt_reduce
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $f) (local.get $acc)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: fold for map entries as [key val] vectors ----
  (func $hamt_entries (param $node anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $cons
        (call $vector_conj (call $vector_conj (call $empty_vector)
          (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node))))
          (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node))))
        (local.get $acc)))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.sub (struct.get $HAMTCollision $count (local.get $col)) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $cons
              (call $vector_conj (call $vector_conj (call $empty_vector)
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.sub (local.get $len) (i32.const 1)))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $acc (call $hamt_entries
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $acc)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: reduce over entries as [k v] vectors: f(acc, [k v]) ----
  (func $hamt_reduce_entries (param $node anyref) (param $f anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (call $reduced_QMARK_ (local.get $acc)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $invoke2 (local.get $f) (local.get $acc)
        (call $vector_conj (call $vector_conj (call $empty_vector)
          (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node))))
          (struct.get $HAMTEntry $val (ref.cast (ref $HAMTEntry) (local.get $node))))))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_s (local.get $i) (struct.get $HAMTCollision $count (local.get $col))))
            (br_if $done (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
              (call $vector_conj (call $vector_conj (call $empty_vector)
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.const 0))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.ge_s (local.get $i) (local.get $len)))
            (br_if $done2 (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $hamt_reduce_entries
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $f) (local.get $acc)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ---- HAMT core: reduce over keys only: f(acc, key) ----
  (func $hamt_reduce_keys (param $node anyref) (param $f anyref) (param $acc anyref) (result anyref)
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $i i32) (local $len i32)
    (if (ref.is_null (local.get $node)) (then (return (local.get $acc))))
    (if (call $reduced_QMARK_ (local.get $acc)) (then (return (local.get $acc))))
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then (return (call $invoke2 (local.get $f) (local.get $acc)
        (struct.get $HAMTEntry $key (ref.cast (ref $HAMTEntry) (local.get $node)))))))
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_s (local.get $i) (struct.get $HAMTCollision $count (local.get $col))))
            (br_if $done (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
              (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (return (local.get $acc))))
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $len (array.len (struct.get $HAMTNode $children (local.get $nd))))
        (local.set $i (i32.const 0))
        (block $done2
          (loop $loop2
            (br_if $done2 (i32.ge_s (local.get $i) (local.get $len)))
            (br_if $done2 (call $reduced_QMARK_ (local.get $acc)))
            (local.set $acc (call $hamt_reduce_keys
              (call $array_get (struct.get $HAMTNode $children (local.get $nd)) (local.get $i))
              (local.get $f) (local.get $acc)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop2)))
        (return (local.get $acc))))
    (local.get $acc))

  ;; ==========================================
  ;; Persistent HashMap Operations (HAMT-backed)
  ;; ==========================================

  (func $empty_hash_map (result anyref)
    ;; Returns an ArrayMap (tag 19) — promotes to HAMT HashMap at 9+ entries
    (struct.new $HashMap (i32.const 19) (i32.const 0) (ref.null none)))

  (func $hash_map_count (param $m anyref) (result i32)
    (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))))

  (func $hash_map_get (param $m anyref) (param $key anyref) (result anyref)
    (local $result anyref)
    (local $root anyref)
    (local $tag i32)
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        (local.set $tag (call $type_tag (local.get $m)))
        ;; ArrayMap (tag 19) — flat array linear scan
        (if (result anyref) (i32.eq (local.get $tag) (i32.const 19))
          (then (call $array_map_get
            (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m)))
            (local.get $key)
            (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m)))))
          (else
        (if (result anyref) (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 16)))
          (then
            ;; HashMap or TransientHashMap - use HAMT lookup
            (if (i32.eq (local.get $tag) (i32.const 16))
              (then (local.set $root (struct.get $TransientHashMap $array (ref.cast (ref $TransientHashMap) (local.get $m)))))
              (else (local.set $root (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))))))
            (local.set $result (call $hamt_get (local.get $root)
              (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
            (if (result anyref) (ref.eq (ref.cast eqref (local.get $result)) (global.get $__not_found_sentinel))
              (then (ref.null none))
              (else (local.get $result))))
          (else
            ;; Protocol fallback for user types implementing ILookup
            (if (result anyref) (call $truthy (call $__satisfies_ILookup (local.get $m)))
              (then (call $__dispatch__lookup (local.get $m) (local.get $key)))
              (else (ref.null none))))))))))

  (func $hash_map_assoc (param $m anyref) (param $key anyref) (param $val anyref) (result anyref)
    ;; Dispatch: ArrayMap (tag 19) uses flat array, HashMap (tag 8) uses HAMT
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    ;; nil -> create 1-entry ArrayMap
    (if (ref.is_null (local.get $m))
      (then (return (call $array_map_assoc
        (ref.cast (ref $HashMap) (call $empty_hash_map))
        (local.get $key) (local.get $val)))))
    ;; ArrayMap (tag 19)
    (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
      (then (return (call $array_map_assoc (ref.cast (ref $HashMap) (local.get $m)) (local.get $key) (local.get $val)))))
    ;; HAMT HashMap (tag 8)
    (call $hash_map_assoc_hamt (local.get $m) (local.get $key) (local.get $val)))

  ;; hash_map_assoc_hamt: assoc on HAMT-backed HashMap only (tag 8)
  (func $hash_map_assoc_hamt (param $m anyref) (param $key anyref) (param $val anyref) (result anyref)
    (local $map (ref $HashMap))
    (local $root anyref) (local $new_root anyref)
    (local $h i32)
    (if (ref.is_null (local.get $m))
      (then
        (local.set $h (call $hash (local.get $key)))
        (return (struct.new $HashMap (i32.const 8) (i32.const 1)
          (struct.new $HAMTEntry (i32.const 0) (local.get $h) (local.get $key) (local.get $val))))))
    (local.set $map (ref.cast (ref $HashMap) (local.get $m)))
    (local.set $root (struct.get $HashMap $array (local.get $map)))
    (local.set $h (call $hash (local.get $key)))
    (global.set $__hamt_added (i32.const 0))
    (local.set $new_root (call $hamt_assoc (local.get $root) (local.get $key) (local.get $val) (local.get $h) (i32.const 0)))
    (struct.new $HashMap (i32.const 8)
      (i32.add (struct.get $HashMap $count (local.get $map)) (global.get $__hamt_added))
      (local.get $new_root)))

  (func $hash_map_get_sentinel (param $m anyref) (param $key anyref) (result anyref)
    (local $root anyref)
    (local $tag i32)
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    (if (result anyref) (ref.is_null (local.get $m))
      (then (global.get $__not_found_sentinel))
      (else
        (local.set $tag (call $type_tag (local.get $m)))
        ;; ArrayMap (tag 19) — flat array linear scan
        (if (result anyref) (i32.eq (local.get $tag) (i32.const 19))
          (then (call $array_map_get_sentinel
            (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m)))
            (local.get $key)
            (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m)))))
          (else
        ;; Get root: HashMap or TransientHashMap
        (if (i32.eq (local.get $tag) (i32.const 16))
          (then (local.set $root (struct.get $TransientHashMap $array (ref.cast (ref $TransientHashMap) (local.get $m)))))
          (else (local.set $root (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))))))
        (call $hamt_get (local.get $root)
          (local.get $key) (call $hash (local.get $key)) (i32.const 0)))))))

  (func $hash_map_get_default (param $m anyref) (param $key anyref) (param $default anyref) (result anyref)
    (local $result anyref)
    (local.set $result (call $hash_map_get_sentinel (local.get $m) (local.get $key)))
    (if (result anyref) (ref.eq (ref.cast eqref (local.get $result)) (global.get $__not_found_sentinel))
      (then (local.get $default))
      (else (local.get $result))))

  (func $hash_map_contains_QMARK_ (param $m anyref) (param $key anyref) (result anyref)
    (if (result anyref) (ref.eq (ref.cast eqref (call $hash_map_get_sentinel (local.get $m) (local.get $key))) (global.get $__not_found_sentinel))
      (then (global.get $__false))
      (else (global.get $__true))))

  (func $map_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.eq (call $type_tag (local.get $val)) (i32.const 8))
                                (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
                        (i32.eq (call $type_tag (local.get $val)) (i32.const 20)))))

  (func $keys (param $m anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        ;; ArrayMap — convert to HashMap first
        (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
          (then (return (call $keys (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $m)))))))
        (if (result anyref) (i32.le_s (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))) (i32.const 0))
          (then (ref.null none))
          (else (call $hamt_keys (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))) (ref.null none)))))))

  (func $vals (param $m anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        ;; ArrayMap — convert to HashMap first
        (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
          (then (return (call $vals (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $m)))))))
        (if (result anyref) (i32.le_s (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))) (i32.const 0))
          (then (ref.null none))
          (else (call $hamt_vals (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))) (ref.null none)))))))

  ;; ==========================================
  ;; Persistent HashSet Operations (HAMT-backed)
  ;; ==========================================

  (func $empty_hash_set (result anyref)
    (struct.new $HashSet (i32.const 9) (i32.const 0) (ref.null none)))

  (func $set_conj (param $s anyref) (param $elem anyref) (result anyref)
    (local $set (ref $HashSet))
    (local $root anyref) (local $new_root anyref)
    (local $h i32)
    (if (ref.is_null (local.get $s))
      (then
        (local.set $h (call $hash (local.get $elem)))
        (return (struct.new $HashSet (i32.const 9) (i32.const 1)
          (struct.new $HAMTEntry (i32.const 0) (local.get $h) (local.get $elem) (local.get $elem))))))
    (local.set $set (ref.cast (ref $HashSet) (local.get $s)))
    (local.set $root (struct.get $HashSet $array (local.get $set)))
    (local.set $h (call $hash (local.get $elem)))
    (global.set $__hamt_added (i32.const 0))
    (local.set $new_root (call $hamt_assoc (local.get $root) (local.get $elem) (local.get $elem) (local.get $h) (i32.const 0)))
    (if (result anyref) (i32.eqz (global.get $__hamt_added))
      (then (local.get $s))  ;; already present, return unchanged
      (else (struct.new $HashSet (i32.const 9)
        (i32.add (struct.get $HashSet $count (local.get $set)) (i32.const 1))
        (local.get $new_root)))))

  (func $disj (param $s anyref) (param $elem anyref) (result anyref)
    (local $set (ref $HashSet))
    (local $root anyref) (local $new_root anyref) (local $h i32)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (ref.null none))
      (else
        (local.set $set (ref.cast (ref $HashSet) (local.get $s)))
        (local.set $root (struct.get $HashSet $array (local.get $set)))
        (local.set $h (call $hash (local.get $elem)))
        ;; Check if element exists first
        (if (result anyref) (ref.eq (ref.cast eqref (call $hamt_get (local.get $root) (local.get $elem) (local.get $h) (i32.const 0))) (global.get $__not_found_sentinel))
          (then (local.get $s))  ;; not found, return unchanged
          (else
            (local.set $new_root (call $hamt_dissoc (local.get $root) (local.get $elem) (local.get $h) (i32.const 0)))
            (struct.new $HashSet (i32.const 9)
              (i32.sub (struct.get $HashSet $count (local.get $set)) (i32.const 1))
              (local.get $new_root)))))))

  (func $set_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 9))))

  (func $set_contains_QMARK_ (param $s anyref) (param $elem anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (global.get $__false))
      (else
        (if (result anyref) (ref.eq (ref.cast eqref
            (call $hamt_get (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $s)))
              (local.get $elem) (call $hash (local.get $elem)) (i32.const 0)))
            (global.get $__not_found_sentinel))
          (then (global.get $__false))
          (else (global.get $__true))))))

  ;; ==========================================
  ;; Sequence Operations
  ;; ==========================================

  ;; seq: returns nil if empty, otherwise returns a seq representation
  ;; For lists (cons cells): return the list itself
  ;; For vectors: return a cons-based sequence
  ;; For maps: return key-value pairs as cons list
  ;; For sets: return elements as cons list
  ;; For lazy seqs: realize and recurse
  (func $seq (param $coll anyref) (result anyref)
    (local $i i32)
    (local $count i32)
    (local $arr anyref)
    (local $result anyref)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> nil
    (if (ref.is_null (local.get $coll))
      (then (return (ref.null none))))
    ;; LazySeq - realize and recurse
    (block $not_lazy (result anyref)
      (br_on_cast_fail $not_lazy anyref (ref $LazySeq) (local.get $coll))
      (return (call $seq (call $lazy_seq_realize (local.get $coll)))))
    (drop)
    ;; Cons cell - return as-is
    (block $not_cons (result anyref)
      (br_on_cast_fail $not_cons anyref (ref $Cons) (local.get $coll))
      (return (local.get $coll)))
    (drop)
    ;; VectorSeq - return as-is (already a seq)
    (block $not_vseq (result anyref)
      (br_on_cast_fail $not_vseq anyref (ref $VectorSeq) (local.get $coll))
      (return (local.get $coll)))
    (drop)
    ;; Vector - return VectorSeq (lazy O(1) view)
    (block $not_vec (result anyref)
      (br_on_cast_fail $not_vec anyref (ref $Vector) (local.get $coll))
      (local.set $count (call $vector_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 0))
        (then (return (ref.null none))))
      (return (struct.new $VectorSeq (i32.const 18) (local.get $coll) (i32.const 0))))
    (drop)
    ;; HashMap/ArrayMap (tag=8/19)
    (if (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
                (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
      (then
        (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (return (ref.null none))))
        ;; ArrayMap (tag 19) — produce seq from flat array
        (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
          (then (return (call $array_map_seq (ref.cast (ref $HashMap) (local.get $coll))))))
        ;; HAMT HashMap (tag 8)
        (return (call $hamt_entries
          (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll)))
          (ref.null none)))))
    ;; HashSet (tag=9)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then
        (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (return (ref.null none))))
        (return (call $hamt_keys
          (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll)))
          (ref.null none)))))
    ;; String - convert to cons list of codepoint strings
    (block $not_str (result anyref)
      (br_on_cast_fail $not_str anyref (ref $String) (local.get $coll))
      (local.set $count (call $str_codepoint_count (local.get $coll)))
      (if (i32.le_s (local.get $count) (i32.const 0))
        (then (return (ref.null none))))
      (local.set $result (ref.null none))
      (local.set $i (i32.sub (local.get $count) (i32.const 1)))
      (block $done3
        (loop $loop3
          (br_if $done3 (i32.lt_s (local.get $i) (i32.const 0)))
          (local.set $result (call $cons
            (call $char_at_as_str (local.get $coll) (local.get $i))
            (local.get $result)))
          (local.set $i (i32.sub (local.get $i) (i32.const 1)))
          (br $loop3)))
      (return (local.get $result)))
    (drop)
    ;; Protocol fallback for user types implementing ISeqable
    (if (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
      (then (return (call $__dispatch__seq (local.get $coll)))))
    (ref.null none))

    ;; seq?: check if value is a seq (cons cell), lazy seq, or VectorSeq
  (func $seq_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $LazySeq) (local.get $val)))
      (ref.test (ref $VectorSeq) (local.get $val)))))

  ;; seqable?: check if value can be converted to a seq
  (func $seqable_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or
      (ref.is_null (local.get $val))
      (ref.test (ref $Cons) (local.get $val)))
      (ref.test (ref $Vector) (local.get $val)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 9)))
      (ref.test (ref $LazySeq) (local.get $val)))
      (ref.test (ref $String) (local.get $val)))
      (ref.test (ref $VectorSeq) (local.get $val)))
      (call $truthy (call $__satisfies_ISeqable (local.get $val))))))

  ;; empty?: check if collection is empty
  (func $empty_QMARK_ (param $coll anyref) (result anyref)
    (call $bool
      (if (result i32) (ref.is_null (local.get $coll))
        (then (i32.const 1))
        (else
          (if (result i32) (ref.test (ref $Cons) (local.get $coll))
            (then (i32.const 0))  ;; cons cells are never empty
            (else
              (if (result i32) (ref.test (ref $VectorSeq) (local.get $coll))
                (then (i32.const 0))  ;; VectorSeqs are never empty (only created from non-empty vectors)
                (else
              (if (result i32) (ref.test (ref $Vector) (local.get $coll))
                (then (i32.eqz (call $vector_count (local.get $coll))))
                (else
                  (if (result i32) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
                    (then (i32.eqz (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll)))))
                    (else
                      (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
                        (then (i32.eqz (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll)))))
                        (else
                          (if (result i32) (ref.test (ref $String) (local.get $coll))
                            (then (i32.eqz (call $str_len (local.get $coll))))
                            (else
                              ;; LazySeq? Realize it and check if nil
                              (if (result i32) (ref.test (ref $LazySeq) (local.get $coll))
                                (then (ref.is_null (call $seq (local.get $coll))))
                                (else
                                  ;; Protocol fallback: empty if ISeqable returns nil seq
                                  (if (result i32) (call $truthy (call $__satisfies_ISeqable (local.get $coll)))
                                    (then (ref.is_null (call $__dispatch__seq (local.get $coll))))
                                    (else (i32.const 1)))))))))))))))))))))

  ;; dissoc: remove key from hash map
  (func $dissoc (param $m anyref) (param $key anyref) (result anyref)
    (local $h i32)
    (local $root anyref)
    (local $count i32)
    ;; Unwrap WithMeta
    (local.set $m (call $unwrap_meta (local.get $m)))
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        ;; ArrayMap — convert to HashMap first, then dissoc
        (if (i32.eq (call $type_tag (local.get $m)) (i32.const 19))
          (then (return (call $dissoc (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $m))) (local.get $key)))))
        ;; Check if key exists using sentinel
        (if (result anyref) (ref.eq
            (ref.cast eqref (call $hash_map_get_sentinel (local.get $m) (local.get $key)))
            (global.get $__not_found_sentinel))
          (then (local.get $m))  ;; Key not found - return unchanged
          (else
            (local.set $root (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $m))))
            (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))))
            (local.set $h (call $hash (local.get $key)))
            (struct.new $HashMap (i32.const 8)
              (i32.sub (local.get $count) (i32.const 1))
              (call $hamt_dissoc (local.get $root) (local.get $key) (local.get $h) (i32.const 0))))))))


  ;; ==========================================
  ;; ArrayMap (PersistentArrayMap) — flat array for small maps (≤8 entries)
  ;; Uses $HashMap struct with type_id=19 and $array holding flat [k0,v0,k1,v1,...]
  ;; Promotes to HAMT HashMap (tag 8) when exceeding 8 entries.
  ;; ==========================================

  ;; empty_hash_map_hamt: create an empty HAMT-backed HashMap (tag 8)
  (func $empty_hash_map_hamt (result anyref)
    (struct.new $HashMap (i32.const 8) (i32.const 0) (ref.null none)))

  ;; array_map_get: linear scan of flat [k,v,k,v,...] array for key
  (func $array_map_get (param $arr anyref) (param $key anyref) (param $count i32) (result anyref)
    (local $i i32)
    (local $len i32)
    (local $typed_arr (ref $AnyArray))
    (if (ref.is_null (local.get $arr))
      (then (return (ref.null none))))
    (local.set $typed_arr (ref.cast (ref $AnyArray) (local.get $arr)))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (call $eq (array.get $AnyArray (local.get $typed_arr) (local.get $i)) (local.get $key))
          (then (return (array.get $AnyArray (local.get $typed_arr) (i32.add (local.get $i) (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (ref.null none))

  ;; array_map_get_sentinel: like array_map_get but returns sentinel instead of nil for not-found
  (func $array_map_get_sentinel (param $arr anyref) (param $key anyref) (param $count i32) (result anyref)
    (local $i i32)
    (local $len i32)
    (local $typed_arr (ref $AnyArray))
    (if (ref.is_null (local.get $arr))
      (then (return (global.get $__not_found_sentinel))))
    (local.set $typed_arr (ref.cast (ref $AnyArray) (local.get $arr)))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (call $eq (array.get $AnyArray (local.get $typed_arr) (local.get $i)) (local.get $key))
          (then (return (array.get $AnyArray (local.get $typed_arr) (i32.add (local.get $i) (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (global.get $__not_found_sentinel))

  ;; array_map_assoc: assoc on ArrayMap — copy+replace or copy+extend, promote to HashMap at 9+
  (func $array_map_assoc (param $m (ref $HashMap)) (param $key anyref) (param $val anyref) (result anyref)
    (local $arr anyref) (local $typed_arr (ref $AnyArray))
    (local $count i32) (local $len i32) (local $i i32)
    (local $new_arr (ref $AnyArray)) (local $new_len i32)
    (local.set $arr (struct.get $HashMap $array (local.get $m)))
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    ;; Empty ArrayMap: create 1-entry ArrayMap
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then
        (local.set $new_arr (array.new $AnyArray (ref.null none) (i32.const 2)))
        (array.set $AnyArray (local.get $new_arr) (i32.const 0) (local.get $key))
        (array.set $AnyArray (local.get $new_arr) (i32.const 1) (local.get $val))
        (return (struct.new $HashMap (i32.const 19) (i32.const 1) (local.get $new_arr)))))
    (local.set $typed_arr (ref.cast (ref $AnyArray) (local.get $arr)))
    ;; Check if key already exists (linear scan)
    (local.set $i (i32.const 0))
    (block $not_found
      (loop $scan
        (br_if $not_found (i32.ge_s (local.get $i) (local.get $len)))
        (if (call $eq (array.get $AnyArray (local.get $typed_arr) (local.get $i)) (local.get $key))
          (then
            ;; Key found at $i — copy array and replace value at $i+1
            (local.set $new_arr (array.new $AnyArray (ref.null none) (local.get $len)))
            (array.copy $AnyArray $AnyArray (local.get $new_arr) (i32.const 0) (local.get $typed_arr) (i32.const 0) (local.get $len))
            (array.set $AnyArray (local.get $new_arr) (i32.add (local.get $i) (i32.const 1)) (local.get $val))
            (return (struct.new $HashMap (i32.const 19) (local.get $count) (local.get $new_arr)))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $scan)))
    ;; Key not found — promote to HashMap if count >= 8
    (if (i32.ge_s (local.get $count) (i32.const 8))
      (then (return (call $hash_map_assoc_hamt (call $array_map_to_hash_map (local.get $m)) (local.get $key) (local.get $val)))))
    ;; Extend: copy array + append k,v
    (local.set $new_len (i32.add (local.get $len) (i32.const 2)))
    (local.set $new_arr (array.new $AnyArray (ref.null none) (local.get $new_len)))
    (array.copy $AnyArray $AnyArray (local.get $new_arr) (i32.const 0) (local.get $typed_arr) (i32.const 0) (local.get $len))
    (array.set $AnyArray (local.get $new_arr) (local.get $len) (local.get $key))
    (array.set $AnyArray (local.get $new_arr) (i32.add (local.get $len) (i32.const 1)) (local.get $val))
    (struct.new $HashMap (i32.const 19) (i32.add (local.get $count) (i32.const 1)) (local.get $new_arr)))

  ;; array_map_to_hash_map: convert ArrayMap to HAMT HashMap (tag 8)
  (func $array_map_to_hash_map (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $result anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (call $empty_hash_map_hamt))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $result (call $empty_hash_map_hamt))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $result (call $hash_map_assoc_hamt (local.get $result)
          (array.get $AnyArray (local.get $arr) (local.get $i))
          (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $result))

  ;; array_map_seq: produce Cons list of [k,v] vectors from flat array
  (func $array_map_seq (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $result anyref) (local $entry anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (ref.null none))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $result (ref.null none))
    ;; Build cons list from back to front (so seq is in insertion order)
    (local.set $i (i32.sub (local.get $len) (i32.const 2)))
    (block $done
      (loop $loop
        (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
        ;; Create [k v] vector via conj (2-element vector)
        (local.set $entry (call $vector_conj (call $vector_conj (call $empty_vector)
          (array.get $AnyArray (local.get $arr) (local.get $i)))
          (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1)))))
        (local.set $result (call $cons (local.get $entry) (local.get $result)))
        (local.set $i (i32.sub (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $result))

  ;; array_map_reduce_kv: reduce over ArrayMap key-value pairs
  (func $array_map_reduce_kv (param $f anyref) (param $init anyref) (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $acc anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (local.get $init))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $acc (call $invoke3 (local.get $f) (local.get $acc)
          (array.get $AnyArray (local.get $arr) (local.get $i))
          (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1)))))
        ;; Check for reduced
        (if (ref.test (ref $Reduced) (local.get $acc))
          (then (return (local.get $acc))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $acc))

  ;; array_map_reduce_entries: reduce over ArrayMap entries as [k,v] vectors (for reduce on maps)
  (func $array_map_reduce_entries (param $f anyref) (param $init anyref) (param $m (ref $HashMap)) (result anyref)
    (local $arr (ref $AnyArray)) (local $count i32) (local $len i32)
    (local $i i32) (local $acc anyref)
    (local.set $count (struct.get $HashMap $count (local.get $m)))
    (if (i32.le_s (local.get $count) (i32.const 0))
      (then (return (local.get $init))))
    (local.set $arr (ref.cast (ref $AnyArray) (struct.get $HashMap $array (local.get $m))))
    (local.set $len (i32.shl (local.get $count) (i32.const 1)))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (call $vector_conj (call $vector_conj (call $empty_vector)
            (array.get $AnyArray (local.get $arr) (local.get $i)))
            (array.get $AnyArray (local.get $arr) (i32.add (local.get $i) (i32.const 1))))))
        (if (ref.test (ref $Reduced) (local.get $acc))
          (then (return (local.get $acc))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (local.get $acc))


  ;; ==========================================
  ;; PRNG (xorshift32)
  ;; ==========================================
  (global $__prng_state (mut i32) (i32.const 2463534242))

  (func $rand_float (result f64)
    (local $s i32)
    (local.set $s (global.get $__prng_state))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (global.set $__prng_state (local.get $s))
    ;; Convert to [0, 1): unsigned i32 / 4294967296.0
    (f64.div (f64.convert_i32_u (local.get $s)) (f64.const 4294967296.0)))

  ;; ==========================================
  ;; Transient Collections
  ;; ==========================================

  ;; Global monotonic edit counter — each transient call increments this
  (global $__edit_counter (mut i32) (i32.const 1))

  ;; ---- HAMT transient helpers: ensure node ownership ----

  ;; If node.edit == edit, return node (owned); else clone with new edit
  (func $hamt_node_ensure_editable (param $node (ref $HAMTNode)) (param $edit i32) (result (ref $HAMTNode))
    (if (result (ref $HAMTNode)) (i32.eq (struct.get $HAMTNode $edit (local.get $node)) (local.get $edit))
      (then (local.get $node))
      (else
        (struct.new $HAMTNode (local.get $edit)
          (struct.get $HAMTNode $bitmap (local.get $node))
          (ref.cast (ref $AnyArray) (call $array_copy
            (struct.get $HAMTNode $children (local.get $node))
            (array.len (struct.get $HAMTNode $children (local.get $node)))))))))

  (func $hamt_entry_ensure_editable (param $entry (ref $HAMTEntry)) (param $edit i32) (result (ref $HAMTEntry))
    (if (result (ref $HAMTEntry)) (i32.eq (struct.get $HAMTEntry $edit (local.get $entry)) (local.get $edit))
      (then (local.get $entry))
      (else
        (struct.new $HAMTEntry (local.get $edit)
          (struct.get $HAMTEntry $hash (local.get $entry))
          (struct.get $HAMTEntry $key (local.get $entry))
          (struct.get $HAMTEntry $val (local.get $entry))))))

  (func $hamt_collision_ensure_editable (param $col (ref $HAMTCollision)) (param $edit i32) (result (ref $HAMTCollision))
    (if (result (ref $HAMTCollision)) (i32.eq (struct.get $HAMTCollision $edit (local.get $col)) (local.get $edit))
      (then (local.get $col))
      (else
        (struct.new $HAMTCollision (local.get $edit)
          (struct.get $HAMTCollision $hash (local.get $col))
          (struct.get $HAMTCollision $count (local.get $col))
          (ref.cast (ref $AnyArray) (call $array_copy
            (struct.get $HAMTCollision $entries (local.get $col))
            (array.len (struct.get $HAMTCollision $entries (local.get $col)))))))))

  ;; ---- hamt_assoc_transient: in-place HAMT mutation ----
  (func $hamt_assoc_transient (param $node anyref) (param $key anyref) (param $val anyref) (param $hash i32) (param $shift i32) (param $edit i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $i i32) (local $cnt i32) (local $found_idx i32)
    (local $editable_nd (ref $HAMTNode))
    (local $editable_entry (ref $HAMTEntry))
    (local $editable_col (ref $HAMTCollision))
    ;; null -> new entry (with transient edit)
    (if (ref.is_null (local.get $node))
      (then
        (global.set $__hamt_added (i32.const 1))
        (return (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val)))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (i32.eq (struct.get $HAMTEntry $hash (local.get $entry)) (local.get $hash))
          (then
            (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
              (then
                ;; Same key -> update value in place if owned
                (local.set $editable_entry (call $hamt_entry_ensure_editable (local.get $entry) (local.get $edit)))
                (struct.set $HAMTEntry $val (local.get $editable_entry) (local.get $val))
                (return (local.get $editable_entry)))
              (else
                ;; Hash collision -> collision node
                (global.set $__hamt_added (i32.const 1))
                (local.set $new_arr (call $array_new (i32.const 4)))
                (call $array_set (local.get $new_arr) (i32.const 0) (struct.get $HAMTEntry $key (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 1) (struct.get $HAMTEntry $val (local.get $entry)))
                (call $array_set (local.get $new_arr) (i32.const 2) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.const 3) (local.get $val))
                (return (struct.new $HAMTCollision (local.get $edit) (local.get $hash) (i32.const 2) (ref.cast (ref $AnyArray) (local.get $new_arr)))))))
          (else
            ;; Different hash -> split via hamt_two (immutable, will be cloned on next access)
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTEntry $hash (local.get $entry))
              (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; HAMTNode
    (if (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (local.set $idx (i32.popcnt (i32.and
          (struct.get $HAMTNode $bitmap (local.get $nd))
          (i32.sub (local.get $bit) (i32.const 1)))))
        (if (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then
            ;; Empty slot -> insert new entry, ensure editable
            (global.set $__hamt_added (i32.const 1))
            (local.set $editable_nd (call $hamt_node_ensure_editable (local.get $nd) (local.get $edit)))
            (local.set $old_arr (struct.get $HAMTNode $children (local.get $editable_nd)))
            (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
            (local.set $new_arr (call $array_new (i32.add (local.get $len) (i32.const 1))))
            ;; Copy elements before idx
            (if (i32.gt_s (local.get $idx) (i32.const 0))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                (local.get $idx))))
            ;; Insert new entry at idx
            (call $array_set (local.get $new_arr) (local.get $idx)
              (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val)))
            ;; Copy elements after idx
            (if (i32.lt_s (local.get $idx) (local.get $len))
              (then (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.add (local.get $idx) (i32.const 1))
                (ref.cast (ref $AnyArray) (local.get $old_arr)) (local.get $idx)
                (i32.sub (local.get $len) (local.get $idx)))))
            ;; Mutate the editable node in place
            (struct.set $HAMTNode $bitmap (local.get $editable_nd)
              (i32.or (struct.get $HAMTNode $bitmap (local.get $editable_nd)) (local.get $bit)))
            (struct.set $HAMTNode $children (local.get $editable_nd)
              (ref.cast (ref $AnyArray) (local.get $new_arr)))
            (return (local.get $editable_nd)))
          (else
            ;; Occupied slot -> recurse
            (local.set $editable_nd (call $hamt_node_ensure_editable (local.get $nd) (local.get $edit)))
            (local.set $child (array.get $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_assoc_transient (local.get $child) (local.get $key) (local.get $val)
              (local.get $hash) (i32.add (local.get $shift) (i32.const 5)) (local.get $edit)))
            ;; Update child in place
            (array.set $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx) (local.get $new_child))
            (return (local.get $editable_nd))))))
    ;; HAMTCollision
    (if (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (if (i32.eq (struct.get $HAMTCollision $hash (local.get $col)) (local.get $hash))
          (then
            ;; Same hash -> update or extend collision in place
            (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
            (local.set $found_idx (i32.const -1))
            (local.set $i (i32.const 0))
            (block $cfound
              (loop $cloop
                (br_if $cfound (i32.ge_s (local.get $i) (local.get $cnt)))
                (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $i) (i32.const 2))))
                  (then (local.set $found_idx (local.get $i)) (br $cfound)))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $cloop)))
            (if (i32.ge_s (local.get $found_idx) (i32.const 0))
              (then
                ;; Update existing — ensure editable and mutate
                (local.set $editable_col (call $hamt_collision_ensure_editable (local.get $col) (local.get $edit)))
                (call $array_set (struct.get $HAMTCollision $entries (local.get $editable_col))
                  (i32.add (i32.mul (local.get $found_idx) (i32.const 2)) (i32.const 1)) (local.get $val))
                (return (local.get $editable_col)))
              (else
                ;; Add new to collision
                (global.set $__hamt_added (i32.const 1))
                (local.set $editable_col (call $hamt_collision_ensure_editable (local.get $col) (local.get $edit)))
                (local.set $new_arr (call $array_new (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (if (i32.gt_s (local.get $cnt) (i32.const 0))
                  (then (array.copy $AnyArray $AnyArray
                    (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                    (struct.get $HAMTCollision $entries (local.get $editable_col)) (i32.const 0)
                    (i32.mul (local.get $cnt) (i32.const 2)))))
                (call $array_set (local.get $new_arr) (i32.mul (local.get $cnt) (i32.const 2)) (local.get $key))
                (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 1)) (local.get $val))
                (struct.set $HAMTCollision $count (local.get $editable_col) (i32.add (local.get $cnt) (i32.const 1)))
                (struct.set $HAMTCollision $entries (local.get $editable_col) (ref.cast (ref $AnyArray) (local.get $new_arr)))
                (return (local.get $editable_col)))))
          (else
            ;; Different hash -> wrap collision in node
            (global.set $__hamt_added (i32.const 1))
            (return (call $hamt_two
              (local.get $node)
              (struct.get $HAMTCollision $hash (local.get $col))
              (struct.new $HAMTEntry (local.get $edit) (local.get $hash) (local.get $key) (local.get $val))
              (local.get $hash)
              (local.get $shift)))))))
    ;; Fallback
    (local.get $node))

  ;; ---- hamt_dissoc_transient: in-place HAMT removal ----
  (func $hamt_dissoc_transient (param $node anyref) (param $key anyref) (param $hash i32) (param $shift i32) (param $edit i32) (result anyref)
    (local $entry (ref $HAMTEntry))
    (local $nd (ref $HAMTNode))
    (local $col (ref $HAMTCollision))
    (local $slot i32) (local $bit i32) (local $idx i32) (local $len i32)
    (local $child anyref) (local $new_child anyref)
    (local $new_arr anyref) (local $old_arr anyref)
    (local $new_bm i32) (local $i i32) (local $j i32) (local $cnt i32)
    (local $editable_nd (ref $HAMTNode))
    (local $editable_col (ref $HAMTCollision))
    ;; null -> unchanged
    (if (ref.is_null (local.get $node)) (then (return (ref.null none))))
    ;; HAMTEntry
    (if (ref.test (ref $HAMTEntry) (local.get $node))
      (then
        (local.set $entry (ref.cast (ref $HAMTEntry) (local.get $node)))
        (if (call $eq (local.get $key) (struct.get $HAMTEntry $key (local.get $entry)))
          (then (return (ref.null none))))
        (return (local.get $node))))
    ;; HAMTNode
    (if (result anyref) (ref.test (ref $HAMTNode) (local.get $node))
      (then
        (local.set $nd (ref.cast (ref $HAMTNode) (local.get $node)))
        (local.set $slot (i32.and (i32.shr_u (local.get $hash) (local.get $shift)) (i32.const 31)))
        (local.set $bit (i32.shl (i32.const 1) (local.get $slot)))
        (if (result anyref) (i32.eqz (i32.and (struct.get $HAMTNode $bitmap (local.get $nd)) (local.get $bit)))
          (then (local.get $node))  ;; not found
          (else
            (local.set $idx (i32.popcnt (i32.and
              (struct.get $HAMTNode $bitmap (local.get $nd))
              (i32.sub (local.get $bit) (i32.const 1)))))
            (local.set $editable_nd (call $hamt_node_ensure_editable (local.get $nd) (local.get $edit)))
            (local.set $child (array.get $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx)))
            (local.set $new_child (call $hamt_dissoc_transient (local.get $child) (local.get $key) (local.get $hash)
              (i32.add (local.get $shift) (i32.const 5)) (local.get $edit)))
            (if (result anyref) (ref.is_null (local.get $new_child))
              (then
                ;; Child removed entirely -> shrink array
                (local.set $new_bm (i32.and (struct.get $HAMTNode $bitmap (local.get $editable_nd))
                  (i32.xor (local.get $bit) (i32.const -1))))
                (if (result anyref) (i32.eqz (local.get $new_bm))
                  (then (ref.null none))  ;; node now empty
                  (else
                    (local.set $old_arr (struct.get $HAMTNode $children (local.get $editable_nd)))
                    (local.set $len (array.len (ref.cast (ref $AnyArray) (local.get $old_arr))))
                    ;; If only one child remains and it's a HAMTEntry, promote it
                    (if (result anyref) (i32.and (i32.eq (local.get $len) (i32.const 2))
                        (ref.test (ref $HAMTEntry) (array.get $AnyArray (ref.cast (ref $AnyArray) (local.get $old_arr))
                          (i32.sub (i32.const 1) (local.get $idx)))))
                      (then (array.get $AnyArray (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.sub (i32.const 1) (local.get $idx))))
                      (else
                        (local.set $new_arr (call $array_new (i32.sub (local.get $len) (i32.const 1))))
                        (if (i32.gt_s (local.get $idx) (i32.const 0))
                          (then (array.copy $AnyArray $AnyArray
                            (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                            (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.const 0)
                            (local.get $idx))))
                        (if (i32.lt_s (i32.add (local.get $idx) (i32.const 1)) (local.get $len))
                          (then (array.copy $AnyArray $AnyArray
                            (ref.cast (ref $AnyArray) (local.get $new_arr)) (local.get $idx)
                            (ref.cast (ref $AnyArray) (local.get $old_arr)) (i32.add (local.get $idx) (i32.const 1))
                            (i32.sub (i32.sub (local.get $len) (local.get $idx)) (i32.const 1)))))
                        (struct.set $HAMTNode $bitmap (local.get $editable_nd) (local.get $new_bm))
                        (struct.set $HAMTNode $children (local.get $editable_nd) (ref.cast (ref $AnyArray) (local.get $new_arr)))
                        (local.get $editable_nd))))))
              (else
                ;; Child changed -> replace in place
                (array.set $AnyArray (struct.get $HAMTNode $children (local.get $editable_nd)) (local.get $idx) (local.get $new_child))
                (local.get $editable_nd))))))
      (else
    ;; HAMTCollision
    (if (result anyref) (ref.test (ref $HAMTCollision) (local.get $node))
      (then
        (local.set $col (ref.cast (ref $HAMTCollision) (local.get $node)))
        (local.set $cnt (struct.get $HAMTCollision $count (local.get $col)))
        ;; Find key in collision entries
        (local.set $i (i32.const -1))
        (local.set $j (i32.const 0))
        (block $cfound
          (loop $cloop
            (br_if $cfound (i32.ge_s (local.get $j) (local.get $cnt)))
            (if (call $eq (local.get $key) (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2))))
              (then (local.set $i (local.get $j)) (br $cfound)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $cloop)))
        (if (result anyref) (i32.lt_s (local.get $i) (i32.const 0))
          (then (local.get $node))  ;; not found
          (else
            (if (result anyref) (i32.eq (local.get $cnt) (i32.const 2))
              (then
                ;; Down to 1 entry -> promote to HAMTEntry
                (local.set $j (i32.sub (i32.const 1) (local.get $i)))
                (struct.new $HAMTEntry (i32.const 0)
                  (struct.get $HAMTCollision $hash (local.get $col))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.mul (local.get $j) (i32.const 2)))
                  (call $array_get (struct.get $HAMTCollision $entries (local.get $col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1)))))
              (else
                ;; Remove entry from collision in place
                (local.set $editable_col (call $hamt_collision_ensure_editable (local.get $col) (local.get $edit)))
                (local.set $new_arr (call $array_new (i32.mul (i32.sub (local.get $cnt) (i32.const 1)) (i32.const 2))))
                (local.set $j (i32.const 0))
                (local.set $slot (i32.const 0))
                (block $cdone
                  (loop $ccopy
                    (br_if $cdone (i32.ge_s (local.get $j) (local.get $cnt)))
                    (if (i32.ne (local.get $j) (local.get $i))
                      (then
                        (call $array_set (local.get $new_arr) (i32.mul (local.get $slot) (i32.const 2))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $editable_col)) (i32.mul (local.get $j) (i32.const 2))))
                        (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $slot) (i32.const 2)) (i32.const 1))
                          (call $array_get (struct.get $HAMTCollision $entries (local.get $editable_col)) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1))))
                        (local.set $slot (i32.add (local.get $slot) (i32.const 1)))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $ccopy)))
                (struct.set $HAMTCollision $count (local.get $editable_col) (i32.sub (local.get $cnt) (i32.const 1)))
                (struct.set $HAMTCollision $entries (local.get $editable_col) (ref.cast (ref $AnyArray) (local.get $new_arr)))
                (local.get $editable_col))))))
      (else (local.get $node))))))

  ;; ---- transient: create transient from persistent collection ----
  (func $transient (param $coll anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $map (ref $HashMap))
    (local $set (ref $HashSet))
    (local $edit i32)
    (local $tail anyref) (local $new_tail anyref) (local $tail_len i32)
    ;; Increment edit counter
    (local.set $edit (i32.add (global.get $__edit_counter) (i32.const 1)))
    (global.set $__edit_counter (local.get $edit))
    ;; Vector -> TransientVector
    (if (ref.test (ref $Vector) (local.get $coll))
      (then
        (local.set $vec (ref.cast (ref $Vector) (local.get $coll)))
        (local.set $tail (struct.get $Vector $tail (local.get $vec)))
        (local.set $tail_len (call $array_length (local.get $tail)))
        ;; Clone tail (mutable part during appends) — always size 32 for O(1) conj!
        (local.set $new_tail (call $array_new (i32.const 32)))
        (if (i32.gt_s (local.get $tail_len) (i32.const 0))
          (then (array.copy $AnyArray $AnyArray
            (ref.cast (ref $AnyArray) (local.get $new_tail)) (i32.const 0)
            (ref.cast (ref $AnyArray) (local.get $tail)) (i32.const 0)
            (local.get $tail_len))))
        (return (struct.new $TransientVector (i32.const 15)
          (struct.get $Vector $count (local.get $vec))
          (struct.get $Vector $shift (local.get $vec))
          (struct.get $Vector $root (local.get $vec))
          (local.get $new_tail)
          (local.get $edit)))))
    ;; ArrayMap -> convert to HashMap first, then make transient
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
      (then (return (call $transient (call $array_map_to_hash_map (ref.cast (ref $HashMap) (local.get $coll)))))))
    ;; HashMap -> TransientHashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
      (then
        (local.set $map (ref.cast (ref $HashMap) (local.get $coll)))
        (return (struct.new $TransientHashMap (i32.const 16)
          (struct.get $HashMap $count (local.get $map))
          (struct.get $HashMap $array (local.get $map))
          (local.get $edit)))))
    ;; HashSet -> TransientHashSet
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
      (then
        (local.set $set (ref.cast (ref $HashSet) (local.get $coll)))
        (return (struct.new $TransientHashSet (i32.const 17)
          (struct.get $HashSet $count (local.get $set))
          (struct.get $HashSet $array (local.get $set))
          (local.get $edit)))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- persistent!: convert transient back to persistent ----
  (func $persistent_BANG_ (param $coll anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $tm (ref $TransientHashMap))
    (local $ts (ref $TransientHashSet))
    (local $tail anyref) (local $tail_len i32) (local $trimmed anyref)
    ;; TransientVector -> Vector
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        ;; Check edit is live
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; Invalidate transient
        (struct.set $TransientVector $edit (local.get $tv) (i32.const 0))
        ;; Trim tail to actual size
        (local.set $tail_len (i32.sub (struct.get $TransientVector $count (local.get $tv))
          (call $tail_offset (struct.get $TransientVector $count (local.get $tv)))))
        (local.set $trimmed (call $array_new (local.get $tail_len)))
        (if (i32.gt_s (local.get $tail_len) (i32.const 0))
          (then (array.copy $AnyArray $AnyArray
            (ref.cast (ref $AnyArray) (local.get $trimmed)) (i32.const 0)
            (ref.cast (ref $AnyArray) (struct.get $TransientVector $tail (local.get $tv))) (i32.const 0)
            (local.get $tail_len))))
        (return (struct.new $Vector (i32.const 7)
          (struct.get $TransientVector $count (local.get $tv))
          (struct.get $TransientVector $shift (local.get $tv))
          (struct.get $TransientVector $root (local.get $tv))
          (local.get $trimmed)))))
    ;; TransientHashMap -> HashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (struct.set $TransientHashMap $edit (local.get $tm) (i32.const 0))
        (return (struct.new $HashMap (i32.const 8)
          (struct.get $TransientHashMap $count (local.get $tm))
          (struct.get $TransientHashMap $array (local.get $tm))))))
    ;; TransientHashSet -> HashSet
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
      (then
        (local.set $ts (ref.cast (ref $TransientHashSet) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashSet $edit (local.get $ts)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (struct.set $TransientHashSet $edit (local.get $ts) (i32.const 0))
        (return (struct.new $HashSet (i32.const 9)
          (struct.get $TransientHashSet $count (local.get $ts))
          (struct.get $TransientHashSet $array (local.get $ts))))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- conj!: add to transient collection ----
  (func $conj_BANG_ (param $coll anyref) (param $val anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $tm (ref $TransientHashMap))
    (local $ts (ref $TransientHashSet))
    (local $count i32) (local $tail_len i32)
    (local $tail anyref) (local $new_tail anyref)
    (local $new_root anyref) (local $h i32)
    ;; TransientVector
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $count (struct.get $TransientVector $count (local.get $tv)))
        (local.set $tail_len (i32.sub (local.get $count) (call $tail_offset (local.get $count))))
        ;; Room in tail?
        (if (i32.lt_s (local.get $tail_len) (i32.const 32))
          (then
            ;; Mutate tail in place
            (call $array_set (struct.get $TransientVector $tail (local.get $tv))
              (local.get $tail_len) (local.get $val))
            (struct.set $TransientVector $count (local.get $tv) (i32.add (local.get $count) (i32.const 1)))
            (return (local.get $tv)))
          (else
            ;; Tail full -> push tail into trie
            (local.set $tail (struct.get $TransientVector $tail (local.get $tv)))
            ;; Create trimmed copy of current tail for the trie
            (local.set $new_tail (call $array_copy (local.get $tail) (i32.const 32)))
            ;; Set global for push_tail (it reads the vector for count)
            ;; We need a temporary Vector for push_tail
            (global.set $__push_tail_vec (struct.new $Vector (i32.const 7)
              (local.get $count)
              (struct.get $TransientVector $shift (local.get $tv))
              (struct.get $TransientVector $root (local.get $tv))
              (local.get $new_tail)))
            ;; Check if tree needs to grow
            (if (i32.gt_u (i32.shr_u (local.get $count) (i32.const 5))
                           (i32.shl (i32.const 1) (struct.get $TransientVector $shift (local.get $tv))))
              (then
                ;; Tree overflow - need new root level
                (local.set $new_root (call $array_new (i32.const 32)))
                (call $array_set (local.get $new_root) (i32.const 0) (struct.get $TransientVector $root (local.get $tv)))
                (call $array_set (local.get $new_root) (i32.const 1)
                  (call $new_path (struct.get $TransientVector $shift (local.get $tv)) (local.get $new_tail)))
                (struct.set $TransientVector $shift (local.get $tv)
                  (i32.add (struct.get $TransientVector $shift (local.get $tv)) (i32.const 5)))
                (struct.set $TransientVector $root (local.get $tv) (local.get $new_root)))
              (else
                ;; Push tail into existing tree
                (struct.set $TransientVector $root (local.get $tv)
                  (call $push_tail (struct.get $TransientVector $shift (local.get $tv))
                    (struct.get $TransientVector $root (local.get $tv)) (local.get $new_tail)))))
            ;; Create new tail with single element
            (local.set $new_tail (call $array_new (i32.const 32)))
            (call $array_set (local.get $new_tail) (i32.const 0) (local.get $val))
            (struct.set $TransientVector $tail (local.get $tv) (local.get $new_tail))
            (struct.set $TransientVector $count (local.get $tv) (i32.add (local.get $count) (i32.const 1)))
            (return (local.get $tv))))))
    ;; TransientHashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; val is a 2-element vector [k v]
        (global.set $__hamt_added (i32.const 0))
        (local.set $new_root (call $hamt_assoc_transient
          (struct.get $TransientHashMap $array (local.get $tm))
          (call $vector_nth (local.get $val) (i32.const 0))
          (call $vector_nth (local.get $val) (i32.const 1))
          (call $hash (call $vector_nth (local.get $val) (i32.const 0)))
          (i32.const 0)
          (struct.get $TransientHashMap $edit (local.get $tm))))
        (struct.set $TransientHashMap $array (local.get $tm) (local.get $new_root))
        (struct.set $TransientHashMap $count (local.get $tm)
          (i32.add (struct.get $TransientHashMap $count (local.get $tm)) (global.get $__hamt_added)))
        (return (local.get $tm))))
    ;; TransientHashSet
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
      (then
        (local.set $ts (ref.cast (ref $TransientHashSet) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashSet $edit (local.get $ts)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (global.set $__hamt_added (i32.const 0))
        (local.set $h (call $hash (local.get $val)))
        (local.set $new_root (call $hamt_assoc_transient
          (struct.get $TransientHashSet $array (local.get $ts))
          (local.get $val) (local.get $val) (local.get $h) (i32.const 0)
          (struct.get $TransientHashSet $edit (local.get $ts))))
        (struct.set $TransientHashSet $array (local.get $ts) (local.get $new_root))
        (struct.set $TransientHashSet $count (local.get $ts)
          (i32.add (struct.get $TransientHashSet $count (local.get $ts)) (global.get $__hamt_added)))
        (return (local.get $ts))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- assoc!: assoc on transient ----
  (func $assoc_BANG_ (param $coll anyref) (param $key anyref) (param $val anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $tm (ref $TransientHashMap))
    (local $idx i32) (local $count i32)
    (local $tail_off i32) (local $new_root anyref)
    ;; TransientVector
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $idx (i31.get_s (ref.cast (ref i31) (local.get $key))))
        (local.set $count (struct.get $TransientVector $count (local.get $tv)))
        ;; idx == count -> same as conj!
        (if (i32.eq (local.get $idx) (local.get $count))
          (then (return (call $conj_BANG_ (local.get $coll) (local.get $val)))))
        (local.set $tail_off (call $tail_offset (local.get $count)))
        (if (i32.ge_u (local.get $idx) (local.get $tail_off))
          (then
            ;; In tail -> mutate in place
            (call $array_set (struct.get $TransientVector $tail (local.get $tv))
              (i32.and (local.get $idx) (i32.const 31)) (local.get $val))
            (return (local.get $tv)))
          (else
            ;; In trie -> path-copying (reuse persistent do_assoc)
            (struct.set $TransientVector $root (local.get $tv)
              (call $do_assoc (struct.get $TransientVector $shift (local.get $tv))
                (struct.get $TransientVector $root (local.get $tv)) (local.get $idx) (local.get $val)))
            (return (local.get $tv))))))
    ;; TransientHashMap
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (global.set $__hamt_added (i32.const 0))
        (local.set $new_root (call $hamt_assoc_transient
          (struct.get $TransientHashMap $array (local.get $tm))
          (local.get $key) (local.get $val)
          (call $hash (local.get $key)) (i32.const 0)
          (struct.get $TransientHashMap $edit (local.get $tm))))
        (struct.set $TransientHashMap $array (local.get $tm) (local.get $new_root))
        (struct.set $TransientHashMap $count (local.get $tm)
          (i32.add (struct.get $TransientHashMap $count (local.get $tm)) (global.get $__hamt_added)))
        (return (local.get $tm))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- dissoc!: remove from transient hash map ----
  (func $dissoc_BANG_ (param $coll anyref) (param $key anyref) (result anyref)
    (local $tm (ref $TransientHashMap))
    (local $new_root anyref) (local $h i32)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
      (then
        (local.set $tm (ref.cast (ref $TransientHashMap) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashMap $edit (local.get $tm)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; Check if key exists
        (if (ref.eq
            (ref.cast eqref (call $hamt_get
              (struct.get $TransientHashMap $array (local.get $tm))
              (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
            (global.get $__not_found_sentinel))
          (then (return (local.get $coll))))
        (local.set $h (call $hash (local.get $key)))
        (local.set $new_root (call $hamt_dissoc_transient
          (struct.get $TransientHashMap $array (local.get $tm))
          (local.get $key) (local.get $h) (i32.const 0)
          (struct.get $TransientHashMap $edit (local.get $tm))))
        (struct.set $TransientHashMap $array (local.get $tm) (local.get $new_root))
        (struct.set $TransientHashMap $count (local.get $tm)
          (i32.sub (struct.get $TransientHashMap $count (local.get $tm)) (i32.const 1)))
        (return (local.get $coll))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- disj!: remove from transient hash set ----
  (func $disj_BANG_ (param $coll anyref) (param $elem anyref) (result anyref)
    (local $ts (ref $TransientHashSet))
    (local $new_root anyref) (local $h i32)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
      (then
        (local.set $ts (ref.cast (ref $TransientHashSet) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientHashSet $edit (local.get $ts)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        ;; Check if element exists
        (if (ref.eq
            (ref.cast eqref (call $hamt_get
              (struct.get $TransientHashSet $array (local.get $ts))
              (local.get $elem) (call $hash (local.get $elem)) (i32.const 0)))
            (global.get $__not_found_sentinel))
          (then (return (local.get $coll))))
        (local.set $h (call $hash (local.get $elem)))
        (local.set $new_root (call $hamt_dissoc_transient
          (struct.get $TransientHashSet $array (local.get $ts))
          (local.get $elem) (local.get $h) (i32.const 0)
          (struct.get $TransientHashSet $edit (local.get $ts))))
        (struct.set $TransientHashSet $array (local.get $ts) (local.get $new_root))
        (struct.set $TransientHashSet $count (local.get $ts)
          (i32.sub (struct.get $TransientHashSet $count (local.get $ts)) (i32.const 1)))
        (return (local.get $coll))))
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; ---- pop!: remove last element from transient vector ----
  ;; Strategy: if tail has >1 element, just decrement count. Otherwise,
  ;; persist, pop via persistent vector, then re-transient.
  (func $pop_BANG_ (param $coll anyref) (result anyref)
    (local $tv (ref $TransientVector))
    (local $count i32) (local $tail_len i32)
    (local $new_count i32)
    (local $new_tail anyref) (local $new_tail_buf anyref)
    (local $new_tail_len i32)
    (local $vec anyref)
    (if (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
      (then
        (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
        (if (i32.eqz (struct.get $TransientVector $edit (local.get $tv)))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $count (struct.get $TransientVector $count (local.get $tv)))
        (if (i32.le_s (local.get $count) (i32.const 0))
          (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none))) (unreachable)))
        (local.set $new_count (i32.sub (local.get $count) (i32.const 1)))
        (local.set $tail_len (i32.sub (local.get $count) (call $tail_offset (local.get $count))))
        (if (i32.gt_s (local.get $tail_len) (i32.const 1))
          (then
            ;; Tail has >1 element -> just decrement count
            (struct.set $TransientVector $count (local.get $tv) (local.get $new_count))
            (return (local.get $tv)))
          (else
            ;; Tail has 1 element -> need to pull new tail from trie
            (if (i32.le_s (local.get $new_count) (i32.const 0))
              (then
                ;; Going to empty
                (struct.set $TransientVector $count (local.get $tv) (i32.const 0))
                (struct.set $TransientVector $shift (local.get $tv) (i32.const 5))
                (struct.set $TransientVector $root (local.get $tv) (ref.null none))
                (struct.set $TransientVector $tail (local.get $tv) (call $array_new (i32.const 32)))
                (return (local.get $tv)))
              (else
                ;; Find the leaf array for the new last element
                (local.set $vec (struct.new $Vector (i32.const 7)
                  (local.get $count)
                  (struct.get $TransientVector $shift (local.get $tv))
                  (struct.get $TransientVector $root (local.get $tv))
                  (struct.get $TransientVector $tail (local.get $tv))))
                (local.set $new_tail (call $vector_array_for (local.get $vec)
                  (i32.sub (local.get $new_count) (i32.const 1))))
                ;; Copy into a 32-sized buffer
                (local.set $new_tail_len (call $array_length (local.get $new_tail)))
                (local.set $new_tail_buf (call $array_new (i32.const 32)))
                (if (i32.gt_s (local.get $new_tail_len) (i32.const 0))
                  (then (array.copy $AnyArray $AnyArray
                    (ref.cast (ref $AnyArray) (local.get $new_tail_buf)) (i32.const 0)
                    (ref.cast (ref $AnyArray) (local.get $new_tail)) (i32.const 0)
                    (local.get $new_tail_len))))
                (struct.set $TransientVector $count (local.get $tv) (local.get $new_count))
                (struct.set $TransientVector $tail (local.get $tv) (local.get $new_tail_buf))
                ;; Note: trie entries beyond count are unreachable (safe to leave stale)
                (return (local.get $tv)))))) ;; close return, else-B, if-B, else-A
    )) ;; close if-A, then-outer; leave if-outer open for fallthrough
    ;; Unsupported type
    (throw $exn (struct.new $ExceptionInfo (i32.const 100) (ref.null none) (ref.null none) (ref.null none)))
    (unreachable))

  ;; make_array_map: create ArrayMap directly from AnyArray of [k,v,k,v,...] pairs.
  ;; No duplicate-key checking — caller guarantees uniqueness. count = number of k/v pairs.
  (func $make_array_map (param $arr anyref) (param $count i32) (result anyref)
    (struct.new $HashMap (i32.const 19) (local.get $count) (local.get $arr)))

  ;; ==========================================
  ;; Atom Operations
  ;; ==========================================

  ;; atom: create an atom with initial value
  (func $atom (param $val anyref) (result anyref)
    (struct.new $Atom (i32.const 10) (local.get $val) (ref.null none) (ref.null none)))

  ;; deref: get value from atom
  (func $deref (param $a anyref) (result anyref)
    (struct.get $Atom $val (ref.cast (ref $Atom) (local.get $a))))

  ;; fire_watches: call each watch fn with (key atom old new)
  (func $fire_watches (param $watches anyref) (param $atom anyref) (param $old anyref) (param $new anyref)
    (local $s anyref)
    (local $entry anyref)
    (if (ref.is_null (local.get $watches)) (then (return)))
    (local.set $s (call $seq (local.get $watches)))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $s)))
        (local.set $entry (call $first (local.get $s)))
        ;; entry is a vector [key fn]
        (drop (call $invoke4
          (call $vector_nth (local.get $entry) (i32.const 1))
          (call $vector_nth (local.get $entry) (i32.const 0))
          (local.get $atom)
          (local.get $old)
          (local.get $new)))
        (local.set $s (call $rest (local.get $s)))
        (br $loop))))

  ;; atom_validate: check validator, throw if invalid
  (func $atom_validate (param $validator anyref) (param $val anyref)
    (if (ref.is_null (local.get $validator)) (then (return)))
    (if (i32.eqz (call $truthy (call $invoke1 (local.get $validator) (local.get $val))))
      (then (throw $exn (ref.null none)))))

  ;; reset!: set atom value, returns new value (with validator/watches)
  (func $reset_BANG_ (param $a anyref) (param $val anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $old anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    ;; Validate
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $val))
    ;; Save old, set new
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (struct.set $Atom $val (local.get $atom) (local.get $val))
    ;; Fire watches
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $val))
    (local.get $val))

  ;; swap!: apply function to atom value (with validator/watches)
  (func $swap_BANG_ (param $a anyref) (param $f anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $old anyref)
    (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke1 (local.get $f) (local.get $old)))
    ;; Validate
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    ;; Set new
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    ;; Fire watches
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  ;; add_watch: add a watch function to an atom
  (func $add_watch (param $a anyref) (param $key anyref) (param $f anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $watches anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $watches (struct.get $Atom $watches (local.get $atom)))
    (if (ref.is_null (local.get $watches))
      (then (local.set $watches (call $hash_map_assoc (call $empty_hash_map) (local.get $key) (local.get $f))))
      (else (local.set $watches (call $hash_map_assoc (local.get $watches) (local.get $key) (local.get $f)))))
    (struct.set $Atom $watches (local.get $atom) (local.get $watches))
    (local.get $a))

  ;; remove_watch: remove a watch function from an atom
  (func $remove_watch (param $a anyref) (param $key anyref) (result anyref)
    (local $atom (ref $Atom))
    (local $watches anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $watches (struct.get $Atom $watches (local.get $atom)))
    (if (i32.eqz (ref.is_null (local.get $watches)))
      (then (struct.set $Atom $watches (local.get $atom) (call $dissoc (local.get $watches) (local.get $key)))))
    (local.get $a))

  ;; set_validator!: set validator function on atom
  (func $set_validator_BANG_ (param $a anyref) (param $f anyref) (result anyref)
    (local $atom (ref $Atom))
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    ;; Validate current value with new validator
    (call $atom_validate (local.get $f) (struct.get $Atom $val (local.get $atom)))
    (struct.set $Atom $validator (local.get $atom) (local.get $f))
    (ref.null none))

  ;; atom?: check if value is an atom
  (func $atom_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Atom) (local.get $val))))

  ;; ==========================================
  ;; Apply
  ;; ==========================================

  ;; count_internal: get count of any collection as i32 (for apply dispatch)
  (func $count_internal (param $coll anyref) (result i32)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    (if (result i32) (ref.is_null (local.get $coll))
      (then (i32.const 0))
      (else (if (result i32) (ref.test (ref $Vector) (local.get $coll))
        (then (call $vector_count (local.get $coll)))
        (else (if (result i32) (ref.test (ref $VectorSeq) (local.get $coll))
          (then (i32.sub
            (call $vector_count (struct.get $VectorSeq $vec (ref.cast (ref $VectorSeq) (local.get $coll))))
            (struct.get $VectorSeq $offset (ref.cast (ref $VectorSeq) (local.get $coll)))))
          (else (if (result i32) (ref.test (ref $Cons) (local.get $coll))
          (then (call $list_length (local.get $coll)))
          (else (if (result i32) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
            (then (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
            (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
              (then (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
              (else (if (result i32) (ref.test (ref $String) (local.get $coll))
                (then (call $str_codepoint_count (local.get $coll)))
                (else (if (result i32) (ref.test (ref $LazySeq) (local.get $coll))
                  (then (call $count_internal (call $lazy_seq_realize (local.get $coll))))
                  (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
                    (then (struct.get $TransientVector $count (ref.cast (ref $TransientVector) (local.get $coll))))
                    (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 16))
                      (then (struct.get $TransientHashMap $count (ref.cast (ref $TransientHashMap) (local.get $coll))))
                      (else (if (result i32) (i32.eq (call $type_tag (local.get $coll)) (i32.const 17))
                        (then (struct.get $TransientHashSet $count (ref.cast (ref $TransientHashSet) (local.get $coll))))
                        (else
                          ;; Protocol fallback for ICounted
                          (if (result i32) (call $truthy (call $__satisfies_ICounted (local.get $coll)))
                            (then (i31.get_s (ref.cast (ref i31) (call $__dispatch__count (local.get $coll)))))
                            (else (i32.const 0))))
                      ))
                    ))
                  ))
                ))
              ))
            ))
          ))
        ))
      ))
    )))
  )

  ;; apply_0-8: helper functions for apply with specific arities
  (func $apply_0 (param $f anyref) (result anyref)
    (call $invoke0 (local.get $f)))

  (func $apply_1 (param $f anyref) (param $s anyref) (result anyref)
    (call $invoke1 (local.get $f) (call $first (local.get $s))))

  (func $apply_2 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke2 (local.get $f) (local.get $a0) (call $first (local.get $s))))

  (func $apply_3 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke3 (local.get $f) (local.get $a0) (local.get $a1) (call $first (local.get $s))))

  (func $apply_4 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke4 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (call $first (local.get $s))))

  (func $apply_5 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke5 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (call $first (local.get $s))))

  (func $apply_6 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref) (local $a4 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a4 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke6 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (call $first (local.get $s))))

  (func $apply_7 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref) (local $a4 anyref) (local $a5 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a4 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a5 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke7 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $a5) (call $first (local.get $s))))

  (func $apply_8 (param $f anyref) (param $s anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) (local $a3 anyref) (local $a4 anyref) (local $a5 anyref) (local $a6 anyref)
    (local.set $a0 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a1 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a2 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a3 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a4 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a5 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (local.set $a6 (call $first (local.get $s)))
    (local.set $s (call $rest (local.get $s)))
    (call $invoke8 (local.get $f) (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $a5) (local.get $a6) (call $first (local.get $s))))

  ;; apply: call function with args from collection (supports up to 8 args)
  ;; apply_multi_fallback: for 9+ args, directly call MultiClosure dispatch with the seq
  (func $apply_multi_fallback (param $f anyref) (param $s anyref) (param $n i32) (result anyref)
    (local $mc (ref null $MultiClosure))
    (local $unwrapped anyref)
    (local.set $unwrapped (call $unwrap_meta (local.get $f)))
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $unwrapped)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (local.get $n)
        (local.get $s)
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    (unreachable))

  (func $apply (param $f anyref) (param $args anyref) (result anyref)
    (local $s anyref)
    (local $n i32)
    (local.set $s (call $seq (local.get $args)))
    (local.set $n (call $count_internal (local.get $s)))
    (if (result anyref) (i32.eq (local.get $n) (i32.const 0))
      (then (call $apply_0 (local.get $f)))
      (else (if (result anyref) (i32.eq (local.get $n) (i32.const 1))
        (then (call $apply_1 (local.get $f) (local.get $s)))
        (else (if (result anyref) (i32.eq (local.get $n) (i32.const 2))
          (then (call $apply_2 (local.get $f) (local.get $s)))
          (else (if (result anyref) (i32.eq (local.get $n) (i32.const 3))
            (then (call $apply_3 (local.get $f) (local.get $s)))
            (else (if (result anyref) (i32.eq (local.get $n) (i32.const 4))
              (then (call $apply_4 (local.get $f) (local.get $s)))
              (else (if (result anyref) (i32.eq (local.get $n) (i32.const 5))
                (then (call $apply_5 (local.get $f) (local.get $s)))
                (else (if (result anyref) (i32.eq (local.get $n) (i32.const 6))
                  (then (call $apply_6 (local.get $f) (local.get $s)))
                  (else (if (result anyref) (i32.eq (local.get $n) (i32.const 7))
                    (then (call $apply_7 (local.get $f) (local.get $s)))
                    (else (if (result anyref) (i32.eq (local.get $n) (i32.const 8))
                      (then (call $apply_8 (local.get $f) (local.get $s)))
                      (else (call $apply_multi_fallback (local.get $f) (local.get $s) (local.get $n)))
                    ))
                  ))
                ))
              ))
            ))
          ))
        ))
      ))
    )
  )

  ;; string?: check if value is a string
  (func $string_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $String) (local.get $val))))

  ;; symbol?: check if value is a symbol (sees through WithMeta wrappers)
  (func $symbol_QMARK_ (param $val anyref) (result anyref)
    ;; Unwrap WithMeta transparently
    (if (ref.test (ref $WithMeta) (local.get $val))
      (then (local.set $val (struct.get $WithMeta $inner (ref.cast (ref $WithMeta) (local.get $val))))))
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 4))))

  ;; float?: check if value is a float
  (func $float_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Float) (local.get $val))))

  ;; regex?: check if value is a compiled regex pattern
  (func $regex_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Regex) (local.get $val))))

  ;; regex-pattern: extract pattern string from a Regex struct
  (func $regex_pattern (param $val anyref) (result anyref)
    (struct.get $Regex $pattern (ref.cast (ref $Regex) (local.get $val))))

  ;; integer?: check if value is an integer (i31ref)
  (func $integer_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.and
      (i32.eqz (ref.is_null (local.get $val)))
      (ref.test (ref i31) (local.get $val)))))

  ;; number?: check if value is any number type (integer or float)
  (func $number_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $val))
      (then (global.get $__false))
      (else
        (call $bool (i32.or
          (ref.test (ref i31) (local.get $val))
          (ref.test (ref $Float) (local.get $val)))))))

  ;; true?: check if value is boolean true ($Boolean with val=1)
  (func $true_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
      (then (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
        (then (global.get $__true))
        (else (global.get $__false))))
      (else (global.get $__false))))

  ;; false?: check if value is boolean false ($Boolean with val=0)
  (func $false_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
      (then (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
        (then (global.get $__false))
        (else (global.get $__true))))
      (else (global.get $__false))))

  ;; some?: check if value is not nil
  (func $some_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eqz (ref.is_null (local.get $val)))))

  ;; list?: check if value is a cons cell
  (func $list_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Cons) (local.get $val))))

  ;; keyword?: check if value is a keyword
  (func $keyword_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 2))))

  ;; fn?: check if value is a function (any closure type, all share tag 11)
  (func $fn_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 11))))

  ;; coll?: check if value is a collection (vector, map, set, list, or VectorSeq)
  (func $coll_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.or (i32.or (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $Vector) (local.get $val)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 9)))
      (ref.test (ref $VectorSeq) (local.get $val)))))

  ;; sequential?: check if value is sequential (vector, list, or VectorSeq)
  (func $sequential_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $Vector) (local.get $val)))
      (ref.test (ref $VectorSeq) (local.get $val)))))

  ;; associative?: check if value is associative (vector or map)
  (func $associative_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or
      (ref.test (ref $Vector) (local.get $val))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))))

  ;; counted?: check if value supports O(1) count (vector, map, set)
  (func $counted_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.or (i32.or (i32.or (i32.or
      (ref.test (ref $Vector) (local.get $val))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 8)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
      (i32.eq (call $type_tag (local.get $val)) (i32.const 9)))
      (i32.or (i32.eq (call $type_tag (local.get $val)) (i32.const 21)) (i32.eq (call $type_tag (local.get $val)) (i32.const 20))))))

  ;; indexed?: check if value supports indexed access (vector)
  (func $indexed_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $Vector) (local.get $val))))

  ;; num: coerce to number (identity for woj - returns value unchanged)
  (func $num (param $val anyref) (result anyref)
    (local.get $val))

  ;; type: get type of value (stub - returns nil in woj)
  (func $type (param $val anyref) (result anyref)
    (ref.null none))

  ;; ==========================================
  ;; Polymorphic Operations
  ;; ==========================================

  ;; assoc: polymorphic assoc for vectors and hash-maps
  ;; For vectors, key must be an integer index
  ;; For hash-maps, key can be any value
  (func $assoc (param $coll anyref) (param $key anyref) (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
      (then
        ;; Vector - unbox key to get index
        (call $vector_assoc (local.get $coll)
          (i31.get_s (ref.cast (ref i31) (local.get $key)))
          (local.get $val)))
      (else
        (if (result anyref) (i32.or (i32.or (ref.is_null (local.get $coll)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
          (then
            ;; nil, HashMap, or ArrayMap
            (call $hash_map_assoc (local.get $coll) (local.get $key) (local.get $val)))
          (else
            ;; Protocol fallback for IAssociative
            (if (result anyref) (call $truthy (call $__satisfies_IAssociative (local.get $coll)))
              (then (call $__dispatch__assoc (local.get $coll) (local.get $key) (local.get $val)))
              (else (call $hash_map_assoc (local.get $coll) (local.get $key) (local.get $val)))))))))

  ;; ==========================================
  ;; Closure Runtime Functions
  ;; ==========================================

  ;; closure?: check if value is any closure type (all share tag 11)
  (func $closure_QMARK_ (param $val anyref) (result anyref)
    (call $bool (i32.eq (call $type_tag (local.get $val)) (i32.const 11))))

  ;; invoke0: invoke a 0-arity closure
  (func $invoke0 (param $closure anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 0)
        (ref.null none)
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc0
      (struct.get $Closure0 $env (ref.cast (ref $Closure0) (local.get $closure)))
      (struct.get $Closure0 $func (ref.cast (ref $Closure0) (local.get $closure)))))

  ;; invoke1: invoke a 1-arity closure (or keyword/map/set-as-function)
  (func $invoke1 (param $closure anyref) (param $arg0 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    (local $tag i32)
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    (local.set $tag (call $type_tag (local.get $closure)))
    ;; Keyword as function (tag=2)
    (if (i32.eq (local.get $tag) (i32.const 2))
      (then (return (call $hash_map_get (local.get $arg0) (local.get $closure)))))
    ;; HashMap/ArrayMap as function (tags 8, 19) — (the-map key)
    (if (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 19)))
      (then (return (call $hash_map_get (local.get $closure) (local.get $arg0)))))
    ;; HashSet as function (tag 9) — returns element if present, else nil
    (if (i32.eq (local.get $tag) (i32.const 9))
      (then (return (if (result anyref) (call $truthy (call $set_contains_QMARK_ (local.get $closure) (local.get $arg0)))
        (then (local.get $arg0))
        (else (ref.null none))))))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 1)
        (call $cons (local.get $arg0) (ref.null none))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc1
      (struct.get $Closure1 $env (ref.cast (ref $Closure1) (local.get $closure)))
      (local.get $arg0)
      (struct.get $Closure1 $func (ref.cast (ref $Closure1) (local.get $closure)))))

  ;; invoke2: invoke a 2-arity closure (or map-as-function with default)
  (func $invoke2 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    (local $tag i32)
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    (local.set $tag (call $type_tag (local.get $closure)))
    ;; Keyword as function with default (tag=2) — (:kw map default)
    (if (i32.eq (local.get $tag) (i32.const 2))
      (then (return (call $hash_map_get_default (local.get $arg0) (local.get $closure) (local.get $arg1)))))
    ;; HashMap/ArrayMap as function with default (tags 8, 19) — (the-map key default)
    (if (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 19)))
      (then (return (call $hash_map_get_default (local.get $closure) (local.get $arg0) (local.get $arg1)))))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 2)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (ref.null none)))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc2
      (struct.get $Closure2 $env (ref.cast (ref $Closure2) (local.get $closure)))
      (local.get $arg0)
      (local.get $arg1)
      (struct.get $Closure2 $func (ref.cast (ref $Closure2) (local.get $closure)))))

  ;; invoke3: invoke a 3-arity closure
  (func $invoke3 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Unwrap WithMeta if present
    (local.set $closure (call $unwrap_meta (local.get $closure)))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 3)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (ref.null none))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc3
      (struct.get $Closure3 $env (ref.cast (ref $Closure3) (local.get $closure)))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (struct.get $Closure3 $func (ref.cast (ref $Closure3) (local.get $closure)))))

  ;; invoke4: invoke a 4-arity closure
  (func $invoke4 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 4)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (ref.null none)))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc4
      (struct.get $Closure4 $env (ref.cast (ref $Closure4) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
      (struct.get $Closure4 $func (ref.cast (ref $Closure4) (local.get $closure)))))

  ;; invoke5: invoke a 5-arity closure
  (func $invoke5 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 5)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (ref.null none))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc5
      (struct.get $Closure5 $env (ref.cast (ref $Closure5) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
      (struct.get $Closure5 $func (ref.cast (ref $Closure5) (local.get $closure)))))

  ;; invoke6: invoke a 6-arity closure
  (func $invoke6 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 6)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (ref.null none)))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc6
      (struct.get $Closure6 $env (ref.cast (ref $Closure6) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
      (struct.get $Closure6 $func (ref.cast (ref $Closure6) (local.get $closure)))))

  ;; invoke7: invoke a 7-arity closure
  (func $invoke7 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 7)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (ref.null none))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc7
      (struct.get $Closure7 $env (ref.cast (ref $Closure7) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
      (struct.get $Closure7 $func (ref.cast (ref $Closure7) (local.get $closure)))))

  ;; invoke8: invoke a 8-arity closure
  (func $invoke8 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 8)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (call $cons (local.get $arg7) (ref.null none)))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc8
      (struct.get $Closure8 $env (ref.cast (ref $Closure8) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
          (local.get $arg7)
      (struct.get $Closure8 $func (ref.cast (ref $Closure8) (local.get $closure)))))

  ;; invoke9: invoke a 9-arity closure
  (func $invoke9 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (param $arg8 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 9)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (call $cons (local.get $arg7) (call $cons (local.get $arg8) (ref.null none))))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc9
      (struct.get $Closure9 $env (ref.cast (ref $Closure9) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
          (local.get $arg7)
          (local.get $arg8)
      (struct.get $Closure9 $func (ref.cast (ref $Closure9) (local.get $closure)))))

  ;; invoke10: invoke a 10-arity closure
  (func $invoke10 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (param $arg8 anyref) (param $arg9 anyref) (result anyref)
    (local $mc (ref null $MultiClosure))
    ;; Check MultiClosure
    (block $not_multi (result anyref)
      (local.set $mc (br_on_cast_fail $not_multi anyref (ref $MultiClosure) (local.get $closure)))
      (return (call_ref $MultiClosureDispatch
        (struct.get $MultiClosure $env (local.get $mc))
        (i32.const 10)
        (call $cons (local.get $arg0) (call $cons (local.get $arg1) (call $cons (local.get $arg2) (call $cons (local.get $arg3) (call $cons (local.get $arg4) (call $cons (local.get $arg5) (call $cons (local.get $arg6) (call $cons (local.get $arg7) (call $cons (local.get $arg8) (call $cons (local.get $arg9) (ref.null none)))))))))))
        (struct.get $MultiClosure $dispatch (local.get $mc)))))
    (drop)
    ;; Regular closure
    (call_ref $ClosureFunc10
      (struct.get $Closure10 $env (ref.cast (ref $Closure10) (local.get $closure)))
      (local.get $arg0)
          (local.get $arg1)
          (local.get $arg2)
          (local.get $arg3)
          (local.get $arg4)
          (local.get $arg5)
          (local.get $arg6)
          (local.get $arg7)
          (local.get $arg8)
          (local.get $arg9)
      (struct.get $Closure10 $func (ref.cast (ref $Closure10) (local.get $closure)))))

  ;; ==========================================
  ;; IReduce Protocol Implementations
  ;; ==========================================

  ;; reduced?: check if value is a Reduced wrapper
  (func $reduced_QMARK_ (param $val anyref) (result i32)
    (ref.test (ref $Reduced) (local.get $val)))

  ;; reduced: wrap value for early termination
  (func $reduced (param $val anyref) (result anyref)
    (struct.new $Reduced (i32.const 13) (local.get $val)))

  ;; deref-reduced: unwrap Reduced value (or return as-is if not Reduced)
  (func $deref_reduced (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Reduced) (local.get $val))
      (then (struct.get $Reduced $val (ref.cast (ref $Reduced) (local.get $val))))
      (else (local.get $val))))

  ;; cons-reduce: reduce over cons list (handles LazySeq in rest position)
  (func $cons_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $curr anyref)
    (local $next anyref)
    (local.set $acc (local.get $init))
    (local.set $curr (local.get $coll))
    (block $done
      (loop $loop
        ;; Check if done (null or reduced)
        (br_if $done (ref.is_null (local.get $curr)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        ;; If curr is a LazySeq, realize it first
        (if (ref.test (ref $LazySeq) (local.get $curr))
          (then (local.set $curr (call $lazy_seq_realize (local.get $curr)))))
        ;; If after realization curr is still null, we're done
        (br_if $done (ref.is_null (local.get $curr)))
        ;; If curr became a VectorSeq, delegate to vectorseq_reduce
        (if (ref.test (ref $VectorSeq) (local.get $curr))
          (then
            (local.set $acc (call $vectorseq_reduce (local.get $curr) (local.get $f) (local.get $acc)))
            (br $done)))
        ;; Apply f: acc = f(acc, first(curr))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $curr)))))
        ;; Advance: curr = rest(curr)
        (local.set $next (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $curr))))
        ;; If next is a LazySeq, realize it
        (if (ref.test (ref $LazySeq) (local.get $next))
          (then (local.set $next (call $lazy_seq_realize (local.get $next)))))
        (local.set $curr (local.get $next))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; vector-reduce: reduce over vector (efficient indexed access)
  (func $vector_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $i i32)
    (local $count i32)
    (local $v (ref $Vector))
    (local.set $v (ref.cast (ref $Vector) (local.get $coll)))
    (local.set $count (struct.get $Vector $count (local.get $v)))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        ;; Apply f: acc = f(acc, nth(v, i))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (call $vector_nth (local.get $coll) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; hashmap-reduce: reduce over map entries as [k v] vectors (HAMT-backed)
  (func $hashmap_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    ;; ArrayMap (tag 19): iterate flat [k,v,...] array producing [k,v] vectors
    (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
      (then
        (call $deref_reduced
          (call $array_map_reduce_entries
            (local.get $f) (local.get $init) (ref.cast (ref $HashMap) (local.get $coll)))))
      (else
        (call $deref_reduced
          (call $hamt_reduce_entries
            (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll)))
            (local.get $f) (local.get $init))))))

  ;; hashset-reduce: reduce over set elements (HAMT-backed)
  (func $hashset_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (call $deref_reduced
      (call $hamt_reduce_keys
        (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll)))
        (local.get $f) (local.get $init))))

  ;; vectorseq-reduce: reduce over VectorSeq (efficient indexed access from offset)
  (func $vectorseq_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $i i32)
    (local $count i32)
    (local $vs (ref $VectorSeq))
    (local $vec anyref)
    (local.set $vs (ref.cast (ref $VectorSeq) (local.get $coll)))
    (local.set $vec (struct.get $VectorSeq $vec (local.get $vs)))
    (local.set $i (struct.get $VectorSeq $offset (local.get $vs)))
    (local.set $count (call $vector_count (local.get $vec)))
    (local.set $acc (local.get $init))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (call $vector_nth (local.get $vec) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; Polymorphic reduce dispatcher
  (func $reduce (param $f anyref) (param $init anyref) (param $coll anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (local.get $init))
      (else
        ;; LazySeq - realize and recurse
        (if (result anyref) (ref.test (ref $LazySeq) (local.get $coll))
          (then (call $reduce (local.get $f) (local.get $init) (call $lazy_seq_realize (local.get $coll))))
          (else
            (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
              (then (call $vector_reduce (local.get $coll) (local.get $f) (local.get $init)))
              (else
                (if (result anyref) (ref.test (ref $VectorSeq) (local.get $coll))
                  (then (call $vectorseq_reduce (local.get $coll) (local.get $f) (local.get $init)))
                  (else
                (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
                  (then (call $cons_reduce (local.get $coll) (local.get $f) (local.get $init)))
                  (else
                    (if (result anyref) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
                      (then (call $hashmap_reduce (local.get $coll) (local.get $f) (local.get $init)))
                      (else
                        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
                          (then (call $hashset_reduce (local.get $coll) (local.get $f) (local.get $init)))
                          (else
                            ;; Protocol fallback for IReduce
                            (if (result anyref) (call $truthy (call $__satisfies_IReduce (local.get $coll)))
                              (then (call $__dispatch__reduce_init (local.get $coll) (local.get $f) (local.get $init)))
                              (else (local.get $init))))))))))))))))))

  ;; reduce without initial value: (reduce f coll)
  ;; Uses first element as init, reduces rest. Empty coll calls (f).
  (func $reduce_no_init (param $f anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    ;; Get seq of collection
    (local.set $s (call $seq (local.get $coll)))
    ;; Empty collection: call f with no args (Clojure semantics)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (call $invoke0 (local.get $f)))
      (else
        ;; Use first as init, reduce rest
        (call $reduce (local.get $f)
          (call $first (local.get $s))
          (call $rest (local.get $s))))))

  ;; reduce-kv: reduce with separate key and value arguments (for maps) (HAMT-backed)
  (func $reduce_kv (param $f anyref) (param $init anyref) (param $coll anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (local.get $init))
      (else
        ;; ArrayMap (tag 19) — iterate flat array
        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19))
          (then
            (call $deref_reduced
              (call $array_map_reduce_kv (local.get $f) (local.get $init)
                (ref.cast (ref $HashMap) (local.get $coll)))))
          (else
        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 8))
          (then
            (call $deref_reduced
              (call $hamt_reduce
                (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll)))
                (local.get $f) (local.get $init))))
          (else (local.get $init))))))))

  ;; ==========================================
  ;; Lazy Sequence Operations
  ;; ==========================================

  ;; make-lazy-seq: create a lazy sequence from a thunk (0-arity closure)
  (func $make_lazy_seq (param $thunk anyref) (result anyref)
    (struct.new $LazySeq
      (i32.const 12)        ;; type tag (12 = LazySeq)
      (i32.const 0)         ;; __pad (structural padding)
      (local.get $thunk)    ;; thunk - the 0-arity closure
      (ref.null none)))     ;; realized - initially null (not realized)

  ;; lazy-seq?: check if value is a lazy sequence
  (func $lazy_seq_QMARK_ (param $val anyref) (result anyref)
    (call $bool (ref.test (ref $LazySeq) (local.get $val))))

  ;; lazy-seq-realized?: check if lazy seq has been realized (thunk is null)
  (func $lazy_seq_realized_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $LazySeq) (local.get $val))
      (then (call $bool (ref.is_null (struct.get $LazySeq $thunk
              (ref.cast (ref $LazySeq) (local.get $val))))))
      (else (call $bool (i32.const 0)))))

  ;; lazy-seq-realize: force evaluation of lazy sequence, return realized value
  ;; If already realized, return cached value
  ;; If not realized, call thunk and cache result
  (func $lazy_seq_realize (param $ls anyref) (result anyref)
    (local $lazy (ref $LazySeq))
    (local $thunk anyref)
    (local $result anyref)
    (local.set $lazy (ref.cast (ref $LazySeq) (local.get $ls)))
    (local.set $thunk (struct.get $LazySeq $thunk (local.get $lazy)))
    ;; If thunk is null, already realized - return cached value
    (if (result anyref) (ref.is_null (local.get $thunk))
      (then (struct.get $LazySeq $realized (local.get $lazy)))
      (else
        ;; Not realized - call thunk and cache result
        (local.set $result (call $invoke0 (local.get $thunk)))
        ;; If result is another LazySeq, recursively realize it
        (if (ref.test (ref $LazySeq) (local.get $result))
          (then (local.set $result (call $lazy_seq_realize (local.get $result)))))
        ;; Cache the result
        (struct.set $LazySeq $realized (local.get $lazy) (local.get $result))
        ;; Clear thunk to mark as realized (and allow GC of closure)
        (struct.set $LazySeq $thunk (local.get $lazy) (ref.null none))
        (local.get $result))))

  ;; ==========================================
  ;; Type Tag for Protocol Dispatch
  ;; ==========================================

  ;; Type tag constants:
  ;; nil = 0, i31 (int) = 1, Keyword = 2, String = 3, Symbol = 4, Float = 5
  ;; Cons = 6, Vector = 7, HashMap = 8, HashSet = 9, Atom = 10
  ;; Closure0-10 = 11 (all closures share tag), LazySeq = 12, Reduced = 13, Boolean = 14
  ;; TransientVector = 15, TransientHashMap = 16, TransientHashSet = 17
  ;; VectorSeq = 18, ExceptionInfo = 100, User-types = 19+

  ;; type_tag: returns numeric type tag for dispatch
  ;; All struct types extend $Tagged with $__type_id as first field,
  ;; so we just cast to $Tagged and read the tag directly.
  ;; WithMeta (tag=99) is transparent: returns the inner value's tag.
  (func $type_tag (param $val anyref) (result i32)
    (local $tag i32)
    (if (ref.is_null (local.get $val))
      (then (return (i32.const 0))))
    (if (ref.test (ref i31) (local.get $val))
      (then (return (i32.const 1))))
    (block $not_tagged (result anyref)
      (local.set $tag (struct.get $Tagged $__type_id
        (br_on_cast_fail $not_tagged anyref (ref $Tagged) (local.get $val))))
      (if (i32.eq (local.get $tag) (i32.const 99))
        (then (return (call $type_tag (struct.get $WithMeta $inner (ref.cast (ref $WithMeta) (local.get $val)))))))
      (return (local.get $tag)))
    (drop)
    (i32.const -1))

  ;; unwrap_meta: strip WithMeta wrapper if present, returning inner value
  (func $unwrap_meta (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Tagged) (local.get $val))
      (then (if (result anyref)
        (i32.eq (struct.get $Tagged $__type_id (ref.cast (ref $Tagged) (local.get $val))) (i32.const 99))
        (then (struct.get $WithMeta $inner (ref.cast (ref $WithMeta) (local.get $val))))
        (else (local.get $val))))
      (else (local.get $val))))

  ;; with_meta: wrap a value with metadata
  (func $with_meta_ (param $val anyref) (param $meta anyref) (result anyref)
    ;; If val already has meta, unwrap first
    (local $inner anyref)
    (local.set $inner (call $unwrap_meta (local.get $val)))
    ;; If meta is nil, return unwrapped value (no metadata)
    (if (result anyref) (ref.is_null (local.get $meta))
      (then (local.get $inner))
      (else (struct.new $WithMeta (i32.const 99) (i32.const 0) (i32.const 0) (local.get $inner) (local.get $meta)))))

  ;; meta_: extract metadata from a value (nil if none)
  ;; Uses tag check (tag=99) to avoid structural typing conflict
  (func $meta_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Tagged) (local.get $val))
      (then (if (result anyref)
        (i32.eq (struct.get $Tagged $__type_id (ref.cast (ref $Tagged) (local.get $val))) (i32.const 99))
        (then (struct.get $WithMeta $meta (ref.cast (ref $WithMeta) (local.get $val))))
        (else (ref.null none))))
      (else (ref.null none))))
  ;; ==========================================
  ;; String Operations
  ;; ==========================================

  ;; str_byte_len: get length of string in bytes
  (func $str_len (param $s anyref) (result i32)
    (array.len (struct.get $String $data (ref.cast (ref $String) (local.get $s)))))

  ;; utf8_cp_len: given first byte of UTF-8 sequence, return codepoint byte length (1-4)
  (func $utf8_cp_len (param $byte i32) (result i32)
    (if (result i32) (i32.le_u (local.get $byte) (i32.const 0x7F))
      (then (i32.const 1))
      (else (if (result i32) (i32.le_u (local.get $byte) (i32.const 0xDF))
        (then (i32.const 2))
        (else (if (result i32) (i32.le_u (local.get $byte) (i32.const 0xEF))
          (then (i32.const 3))
          (else (i32.const 4))))))))

  ;; str_codepoint_count: count UTF-8 codepoints in a string
  (func $str_codepoint_count (param $s anyref) (result i32)
    (local $data (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $count i32)
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $count (i32.add (local.get $count) (i32.const 1)))
        (local.set $i (i32.add (local.get $i)
          (call $utf8_cp_len (array.get_u $CharArray (local.get $data) (local.get $i)))))
        (br $loop)))
    (local.get $count))

  ;; utf8_byte_offset: find byte offset of Nth codepoint in a CharArray
  (func $utf8_byte_offset (param $data (ref $CharArray)) (param $n i32) (result i32)
    (local $i i32)
    (local $cp i32)
    (local $len i32)
    (local.set $len (array.len (local.get $data)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $cp) (local.get $n)))
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $i (i32.add (local.get $i)
          (call $utf8_cp_len (array.get_u $CharArray (local.get $data) (local.get $i)))))
        (local.set $cp (i32.add (local.get $cp) (i32.const 1)))
        (br $loop)))
    (local.get $i))

  ;; str_eq: compare two strings for equality
  ;; Fast path: if both have same non-negative ID, they're equal
  ;; Slow path: byte-by-byte comparison
  (func $str_eq (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $String))
    (local $sb (ref $String))
    (local $da (ref $CharArray))
    (local $db (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local.set $sa (ref.cast (ref $String) (local.get $a)))
    (local.set $sb (ref.cast (ref $String) (local.get $b)))
    ;; Fast path: same ID and both >= 0 (interned)
    (if (result i32) (i32.and
        (i32.ge_s (struct.get $String $id (local.get $sa)) (i32.const 0))
        (i32.eq (struct.get $String $id (local.get $sa))
                (struct.get $String $id (local.get $sb))))
      (then (i32.const 1))
      (else
        ;; Slow path: compare bytes
        (local.set $da (struct.get $String $data (local.get $sa)))
        (local.set $db (struct.get $String $data (local.get $sb)))
        (local.set $len (array.len (local.get $da)))
        ;; Different lengths -> not equal
        (if (result i32) (i32.ne (local.get $len) (array.len (local.get $db)))
          (then (i32.const 0))
          (else
            ;; Compare byte by byte
            (local.set $i (i32.const 0))
            (block $neq (result i32)
              (block $done
                (loop $loop
                  (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
                  (br_if $neq (i32.const 0) (i32.ne
                    (array.get_u $CharArray (local.get $da) (local.get $i))
                    (array.get_u $CharArray (local.get $db) (local.get $i))))
                  (local.set $i (i32.add (local.get $i) (i32.const 1)))
                  (br $loop)))
              (i32.const 1)))))))

  ;; str_concat: concatenate two strings, returns new string with ID=-1
  (func $str_concat (param $a anyref) (param $b anyref) (result anyref)
    (local $sa (ref $String))
    (local $sb (ref $String))
    (local $da (ref $CharArray))
    (local $db (ref $CharArray))
    (local $la i32)
    (local $lb i32)
    (local $new_data (ref $CharArray))
    (local.set $sa (ref.cast (ref $String) (local.get $a)))
    (local.set $sb (ref.cast (ref $String) (local.get $b)))
    (local.set $da (struct.get $String $data (local.get $sa)))
    (local.set $db (struct.get $String $data (local.get $sb)))
    (local.set $la (array.len (local.get $da)))
    (local.set $lb (array.len (local.get $db)))
    (local.set $new_data (array.new $CharArray (i32.const 0) (i32.add (local.get $la) (local.get $lb))))
    (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $da) (i32.const 0) (local.get $la))
    (array.copy $CharArray $CharArray (local.get $new_data) (local.get $la) (local.get $db) (i32.const 0) (local.get $lb))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; int_to_str: convert i32 to decimal string
  (func $int_to_str (param $n i32) (result anyref)
    (local $abs i32)
    (local $neg i32)
    (local $buf (ref $CharArray))
    (local $pos i32)
    (local $digit i32)
    (local $result (ref $CharArray))
    (local $len i32)
    (local $i i32)
    ;; Handle zero
    (if (result anyref) (i32.eqz (local.get $n))
      (then
        (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 1)))
        (array.set $CharArray (local.get $buf) (i32.const 0) (i32.const 48))  ;; '0'
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $buf)))
      (else
        ;; Handle negative
        (local.set $neg (i32.lt_s (local.get $n) (i32.const 0)))
        (local.set $abs (if (result i32) (local.get $neg)
          (then (i32.sub (i32.const 0) (local.get $n)))
          (else (local.get $n))))
        ;; Write digits in reverse into buffer (max 11 digits for i32)
        (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 12)))
        (local.set $pos (i32.const 11))
        (block $done
          (loop $loop
            (br_if $done (i32.eqz (local.get $abs)))
            (local.set $digit (i32.rem_u (local.get $abs) (i32.const 10)))
            (array.set $CharArray (local.get $buf) (local.get $pos)
              (i32.add (i32.const 48) (local.get $digit)))  ;; '0' + digit
            (local.set $abs (i32.div_u (local.get $abs) (i32.const 10)))
            (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
            (br $loop)))
        ;; Add minus sign if negative
        (if (local.get $neg)
          (then
            (array.set $CharArray (local.get $buf) (local.get $pos) (i32.const 45))  ;; '-'
            (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))))
        ;; Copy to correctly-sized array
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (local.set $len (i32.sub (i32.const 12) (local.get $pos)))
        (local.set $result (array.new $CharArray (i32.const 0) (local.get $len)))
        (array.copy $CharArray $CharArray (local.get $result) (i32.const 0) (local.get $buf) (local.get $pos) (local.get $len))
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $result)))))

  ;; str1: convert any single value to string
  ;; nil -> "", int -> decimal, string -> itself, keyword -> ":name"
  (func $str1 (param $val anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $val (call $unwrap_meta (local.get $val)))
    ;; nil -> empty string
    (if (result anyref) (ref.is_null (local.get $val))
      (then (call $make_empty_str))
      (else
        ;; String -> itself
        (if (result anyref) (ref.test (ref $String) (local.get $val))
          (then (local.get $val))
          (else
            ;; i31ref (integer/boolean) -> decimal string
            (if (result anyref) (ref.test (ref i31) (local.get $val))
              (then (call $int_to_str (i31.get_s (ref.cast (ref i31) (local.get $val)))))
              (else
                ;; Keyword -> :name
                (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
                  (then (call $keyword_to_str (local.get $val)))
                  (else
                    ;; Boolean -> true/false string
                    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
                      (then
                        (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
                          (then (call $str1_true))
                          (else (call $str1_false))))
                      (else
                        ;; Float -> decimal string
                        (if (result anyref) (ref.test (ref $Float) (local.get $val))
                          (then (call $float_to_str
                            (struct.get $Float $val (ref.cast (ref $Float) (local.get $val)))))
                          (else
                            ;; Symbol -> ns/name or just name
                            (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
                              (then (call $symbol_to_str (local.get $val)))
                              (else
                                ;; Other -> empty string
                                (call $make_empty_str))))))))))))))))

  ;; make_empty_str: create an empty string
  (func $make_empty_str (result anyref)
    (struct.new $String (i32.const 3) (i32.const -1) (array.new $CharArray (i32.const 0) (i32.const 0))))

  ;; make_str_slash: create a slash string for namespaced keyword construction
  (func $make_str_slash (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 47))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; str1_true: return the string true
  (func $str1_true (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 4)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 116))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 114))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 117))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 101))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; str1_false: return the string false
  (func $str1_false (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 5)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 102))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 97))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 108))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 115))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 101))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; keyword_to_str: convert keyword to ":name" string
  (func $keyword_to_str (param $kw anyref) (result anyref)
    (local $id i32)
    (local $name anyref)
    (local $colon (ref $CharArray))
    (local $colon_str anyref)
    (local.set $id (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $kw))))
    ;; Look up name (handles both compile-time and runtime keywords)
    (local.set $name (call $kw_name_lookup (local.get $id)))
    ;; Prepend ":"
    (local.set $colon (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $colon) (i32.const 0) (i32.const 58))  ;; ':'
    (local.set $colon_str (struct.new $String (i32.const 3) (i32.const -1) (local.get $colon)))
    (call $str_concat (local.get $colon_str) (local.get $name)))

  ;; kw_name_lookup: look up keyword name by ID, checking runtime list
  (func $kw_name_lookup (param $id i32) (result anyref)
    (local $current anyref)
    ;; Check compile-time table first
    (if (i32.and
          (i32.eqz (ref.is_null (global.get $__kw_names)))
          (i32.lt_s (local.get $id) (call $array_length (global.get $__kw_names))))
      (then (return (call $array_get (global.get $__kw_names) (local.get $id)))))
    ;; Search runtime keyword list
    (local.set $current (global.get $__kw_runtime_list))
    (block $done
      (loop $search
        (br_if $done (ref.is_null (local.get $current)))
        (if (i32.eq (local.get $id)
              (struct.get $Keyword $id (ref.cast (ref $Keyword)
                (struct.get $Cons $rest (ref.cast (ref $Cons)
                  (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))))
          (then (return
            (struct.get $Cons $first (ref.cast (ref $Cons)
              (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $search)))
    (call $make_empty_str))

  ;; strip_ns: given a string like foo/bar, return bar. If no slash, return as-is.
  (func $strip_ns (param $s anyref) (result anyref)
    (local $src (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $slash_pos i32)
    (local $new_len i32)
    (local $dst (ref $CharArray))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $src)))
    (local.set $slash_pos (i32.const -1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (i32.eq (array.get_u $CharArray (local.get $src) (local.get $i)) (i32.const 47))  ;; '/'
          (then (local.set $slash_pos (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (if (result anyref) (i32.lt_s (local.get $slash_pos) (i32.const 0))
      (then (local.get $s))
      (else
        (local.set $new_len (i32.sub (local.get $len) (i32.add (local.get $slash_pos) (i32.const 1))))
        (if (result anyref) (i32.le_s (local.get $new_len) (i32.const 0))
          (then (call $make_empty_str))
          (else
            (local.set $dst (array.new $CharArray (i32.const 0) (local.get $new_len)))
            (array.copy $CharArray $CharArray (local.get $dst) (i32.const 0) (local.get $src)
              (i32.add (local.get $slash_pos) (i32.const 1)) (local.get $new_len))
            (struct.new $String (i32.const 3) (i32.const -1) (local.get $dst)))))))

  ;; name_fn: get bare name from keyword (without namespace) or symbol
  (func $name_fn (param $val anyref) (result anyref)
    ;; Unwrap WithMeta transparently (e.g., ^:const on def symbols)
    ;; Note: can't use $type_tag here — it already sees through WithMeta and never returns 99
    (if (ref.test (ref $WithMeta) (local.get $val))
      (then (local.set $val (struct.get $WithMeta $inner (ref.cast (ref $WithMeta) (local.get $val))))))
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
      (then
        (call $strip_ns (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val))))))
      (else
        ;; Symbol -> read name from struct
        (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
          (then
            (struct.get $Symbol $name (ref.cast (ref $Symbol) (local.get $val))))
          (else
            ;; String -> return itself
            (if (result anyref) (ref.test (ref $String) (local.get $val))
              (then (local.get $val))
              (else (call $make_empty_str))))))))

  ;; subs: get substring from start (inclusive) to end (exclusive) in codepoints
  (func $subs (param $s anyref) (param $start i32) (param $end i32) (result anyref)
    (local $src (ref $CharArray))
    (local $byte_start i32)
    (local $byte_end i32)
    (local $byte_len i32)
    (local $new_data (ref $CharArray))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $byte_start (call $utf8_byte_offset (local.get $src) (local.get $start)))
    (local.set $byte_end (call $utf8_byte_offset (local.get $src) (local.get $end)))
    (local.set $byte_len (i32.sub (local.get $byte_end) (local.get $byte_start)))
    (if (result anyref) (i32.le_s (local.get $byte_len) (i32.const 0))
      (then (call $make_empty_str))
      (else
        (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $byte_len)))
        (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $src) (local.get $byte_start) (local.get $byte_len))
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))))

  ;; char_from_code: create a single-character string from a char code (i32)
  (func $char_from_code (param $code i32) (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $data) (i32.const 0) (local.get $code))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; char_from_codepoint: create a single-character string from a Unicode codepoint (i32)
  ;; Properly encodes as UTF-8 (1-4 bytes)
  (func $char_from_codepoint (param $cp i32) (result anyref)
    (local $data (ref $CharArray))
    (if (result anyref) (i32.le_u (local.get $cp) (i32.const 0x7F))
      (then
        ;; 1-byte ASCII
        (local.set $data (array.new $CharArray (i32.const 0) (i32.const 1)))
        (array.set $CharArray (local.get $data) (i32.const 0) (local.get $cp))
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))
      (else
        (if (result anyref) (i32.le_u (local.get $cp) (i32.const 0x7FF))
          (then
            ;; 2-byte: 110xxxxx 10xxxxxx
            (local.set $data (array.new $CharArray (i32.const 0) (i32.const 2)))
            (array.set $CharArray (local.get $data) (i32.const 0)
              (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6))))
            (array.set $CharArray (local.get $data) (i32.const 1)
              (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
            (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))
          (else
            (if (result anyref) (i32.le_u (local.get $cp) (i32.const 0xFFFF))
              (then
                ;; 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
                (local.set $data (array.new $CharArray (i32.const 0) (i32.const 3)))
                (array.set $CharArray (local.get $data) (i32.const 0)
                  (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12))))
                (array.set $CharArray (local.get $data) (i32.const 1)
                  (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
                (array.set $CharArray (local.get $data) (i32.const 2)
                  (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
                (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))
              (else
                ;; 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                (local.set $data (array.new $CharArray (i32.const 0) (i32.const 4)))
                (array.set $CharArray (local.get $data) (i32.const 0)
                  (i32.or (i32.const 0xF0) (i32.shr_u (local.get $cp) (i32.const 18))))
                (array.set $CharArray (local.get $data) (i32.const 1)
                  (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0x3F))))
                (array.set $CharArray (local.get $data) (i32.const 2)
                  (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
                (array.set $CharArray (local.get $data) (i32.const 3)
                  (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
                (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))))))))

  ;; codepoint_at: extract the Unicode codepoint (as i32) at codepoint index i from a string
  (func $codepoint_at (param $s anyref) (param $idx i32) (result i32)
    (local $data (ref $CharArray))
    (local $offset i32)
    (local $b0 i32)
    (local $cp_len i32)
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $offset (call $utf8_byte_offset (local.get $data) (local.get $idx)))
    (local.set $b0 (array.get_u $CharArray (local.get $data) (local.get $offset)))
    (local.set $cp_len (call $utf8_cp_len (local.get $b0)))
    (if (result i32) (i32.eq (local.get $cp_len) (i32.const 1))
      (then (local.get $b0))
      (else
        (if (result i32) (i32.eq (local.get $cp_len) (i32.const 2))
          (then
            ;; 110xxxxx 10xxxxxx
            (i32.or
              (i32.shl (i32.and (local.get $b0) (i32.const 0x1F)) (i32.const 6))
              (i32.and (array.get_u $CharArray (local.get $data) (i32.add (local.get $offset) (i32.const 1))) (i32.const 0x3F))))
          (else
            (if (result i32) (i32.eq (local.get $cp_len) (i32.const 3))
              (then
                ;; 1110xxxx 10xxxxxx 10xxxxxx
                (i32.or
                  (i32.or
                    (i32.shl (i32.and (local.get $b0) (i32.const 0x0F)) (i32.const 12))
                    (i32.shl (i32.and (array.get_u $CharArray (local.get $data) (i32.add (local.get $offset) (i32.const 1))) (i32.const 0x3F)) (i32.const 6)))
                  (i32.and (array.get_u $CharArray (local.get $data) (i32.add (local.get $offset) (i32.const 2))) (i32.const 0x3F))))
              (else
                ;; 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                (i32.or
                  (i32.or
                    (i32.shl (i32.and (local.get $b0) (i32.const 0x07)) (i32.const 18))
                    (i32.shl (i32.and (array.get_u $CharArray (local.get $data) (i32.add (local.get $offset) (i32.const 1))) (i32.const 0x3F)) (i32.const 12)))
                  (i32.or
                    (i32.shl (i32.and (array.get_u $CharArray (local.get $data) (i32.add (local.get $offset) (i32.const 2))) (i32.const 0x3F)) (i32.const 6))
                    (i32.and (array.get_u $CharArray (local.get $data) (i32.add (local.get $offset) (i32.const 3))) (i32.const 0x3F)))))))))))

  ;; str_hash: FNV-1a hash of string bytes
  (func $str_hash (param $s anyref) (result i32)
    (local $data (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $h i32)
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (local.set $h (i32.const 0x811c9dc5))  ;; FNV offset basis
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $h (i32.xor (local.get $h)
          (array.get_u $CharArray (local.get $data) (local.get $i))))
        (local.set $h (i32.mul (local.get $h) (i32.const 0x01000193)))  ;; FNV prime
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $h))
  ;; str_index_of: find first occurrence of substring, return byte offset or -1
  ;; Both params are String refs. Returns i31ref (index or -1)
  (func $str_index_of (param $haystack anyref) (param $needle anyref) (result anyref)
    (local $hdata (ref $CharArray))
    (local $ndata (ref $CharArray))
    (local $hlen i32) (local $nlen i32)
    (local $i i32) (local $j i32) (local $match i32)
    ;; Count codepoints to find position, not byte offset
    (local $cp_count i32)
    (if (ref.is_null (local.get $haystack)) (then (return (ref.i31 (i32.const -1)))))
    (if (ref.is_null (local.get $needle)) (then (return (ref.i31 (i32.const -1)))))
    (local.set $hdata (struct.get $String $data (ref.cast (ref $String) (local.get $haystack))))
    (local.set $ndata (struct.get $String $data (ref.cast (ref $String) (local.get $needle))))
    (local.set $hlen (array.len (local.get $hdata)))
    (local.set $nlen (array.len (local.get $ndata)))
    (if (i32.eqz (local.get $nlen)) (then (return (ref.i31 (i32.const 0)))))
    (if (i32.gt_s (local.get $nlen) (local.get $hlen)) (then (return (ref.i31 (i32.const -1)))))
    (local.set $i (i32.const 0))
    (local.set $cp_count (i32.const 0))
    (block $done
      (loop $outer
        (br_if $done (i32.gt_s (i32.add (local.get $i) (local.get $nlen)) (local.get $hlen)))
        ;; Check if needle matches at position i
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $no_match
          (loop $inner
            (br_if $no_match (i32.ge_s (local.get $j) (local.get $nlen)))
            (if (i32.ne (array.get_u $CharArray (local.get $hdata) (i32.add (local.get $i) (local.get $j)))
                        (array.get_u $CharArray (local.get $ndata) (local.get $j)))
              (then (local.set $match (i32.const 0)) (br $no_match)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $inner)))
        (if (local.get $match) (then (return (ref.i31 (local.get $cp_count)))))
        ;; Advance i by one codepoint
        (local.set $i (i32.add (local.get $i) (call $utf8_cp_len (array.get_u $CharArray (local.get $hdata) (local.get $i)))))
        (local.set $cp_count (i32.add (local.get $cp_count) (i32.const 1)))
        (br $outer)))
    (ref.i31 (i32.const -1)))

  ;; str_to_lower: convert ASCII chars to lowercase
  (func $str_to_lower (param $s anyref) (result anyref)
    (local $data (ref $CharArray))
    (local $len i32) (local $i i32) (local $b i32)
    (local $new_data (ref $CharArray))
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $len)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $b (array.get_u $CharArray (local.get $data) (local.get $i)))
        (if (i32.and (i32.ge_u (local.get $b) (i32.const 65)) (i32.le_u (local.get $b) (i32.const 90)))
          (then (local.set $b (i32.add (local.get $b) (i32.const 32)))))
        (array.set $CharArray (local.get $new_data) (local.get $i) (local.get $b))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; str_to_upper: convert ASCII chars to uppercase
  (func $str_to_upper (param $s anyref) (result anyref)
    (local $data (ref $CharArray))
    (local $len i32) (local $i i32) (local $b i32)
    (local $new_data (ref $CharArray))
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $len)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $b (array.get_u $CharArray (local.get $data) (local.get $i)))
        (if (i32.and (i32.ge_u (local.get $b) (i32.const 97)) (i32.le_u (local.get $b) (i32.const 122)))
          (then (local.set $b (i32.sub (local.get $b) (i32.const 32)))))
        (array.set $CharArray (local.get $new_data) (local.get $i) (local.get $b))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; str_starts_with: check if string starts with prefix (returns i31ref bool)
  (func $str_starts_with (param $s anyref) (param $prefix anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $pdata (ref $CharArray))
    (local $slen i32) (local $plen i32) (local $i i32)
    (if (ref.is_null (local.get $s)) (then (return (global.get $__false))))
    (if (ref.is_null (local.get $prefix)) (then (return (global.get $__true))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $pdata (struct.get $String $data (ref.cast (ref $String) (local.get $prefix))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $plen (array.len (local.get $pdata)))
    (if (i32.gt_s (local.get $plen) (local.get $slen)) (then (return (global.get $__false))))
    (local.set $i (i32.const 0))
    (block $no
      (loop $loop
        (br_if $no (i32.ge_s (local.get $i) (local.get $plen)))
        (if (i32.ne (array.get_u $CharArray (local.get $sdata) (local.get $i))
                    (array.get_u $CharArray (local.get $pdata) (local.get $i)))
          (then (return (global.get $__false))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (global.get $__true))

  ;; str_ends_with: check if string ends with suffix (returns i31ref bool)
  (func $str_ends_with (param $s anyref) (param $suffix anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $xdata (ref $CharArray))
    (local $slen i32) (local $xlen i32) (local $i i32) (local $offset i32)
    (if (ref.is_null (local.get $s)) (then (return (global.get $__false))))
    (if (ref.is_null (local.get $suffix)) (then (return (global.get $__true))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $xdata (struct.get $String $data (ref.cast (ref $String) (local.get $suffix))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $xlen (array.len (local.get $xdata)))
    (if (i32.gt_s (local.get $xlen) (local.get $slen)) (then (return (global.get $__false))))
    (local.set $offset (i32.sub (local.get $slen) (local.get $xlen)))
    (local.set $i (i32.const 0))
    (block $no
      (loop $loop
        (br_if $no (i32.ge_s (local.get $i) (local.get $xlen)))
        (if (i32.ne (array.get_u $CharArray (local.get $sdata) (i32.add (local.get $offset) (local.get $i)))
                    (array.get_u $CharArray (local.get $xdata) (local.get $i)))
          (then (return (global.get $__false))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (global.get $__true))

  ;; str_trim: remove leading/trailing ASCII whitespace
  (func $str_trim (param $s anyref) (result anyref)
    (local $data (ref $CharArray))
    (local $len i32) (local $start i32) (local $end i32) (local $new_len i32)
    (local $new_data (ref $CharArray))
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $data)))
    (if (i32.eqz (local.get $len)) (then (return (local.get $s))))
    ;; Find start (skip whitespace)
    (local.set $start (i32.const 0))
    (block $s_done
      (loop $s_loop
        (br_if $s_done (i32.ge_s (local.get $start) (local.get $len)))
        (br_if $s_done (i32.gt_u (array.get_u $CharArray (local.get $data) (local.get $start)) (i32.const 32)))
        (local.set $start (i32.add (local.get $start) (i32.const 1)))
        (br $s_loop)))
    ;; Find end (skip trailing whitespace)
    (local.set $end (local.get $len))
    (block $e_done
      (loop $e_loop
        (br_if $e_done (i32.le_s (local.get $end) (local.get $start)))
        (br_if $e_done (i32.gt_u (array.get_u $CharArray (local.get $data) (i32.sub (local.get $end) (i32.const 1))) (i32.const 32)))
        (local.set $end (i32.sub (local.get $end) (i32.const 1)))
        (br $e_loop)))
    (local.set $new_len (i32.sub (local.get $end) (local.get $start)))
    (if (i32.eqz (local.get $new_len)) (then (return (struct.new $String (i32.const 3) (i32.const -1) (array.new $CharArray (i32.const 0) (i32.const 0))))))
    (if (i32.and (i32.eqz (local.get $start)) (i32.eq (local.get $end) (local.get $len)))
      (then (return (local.get $s))))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $new_len)))
    (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $data) (local.get $start) (local.get $new_len))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; str_replace: replace all occurrences of target with replacement
  (func $str_replace (param $s anyref) (param $target anyref) (param $replacement anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $tdata (ref $CharArray)) (local $rdata (ref $CharArray))
    (local $slen i32) (local $tlen i32) (local $rlen i32)
    (local $i i32) (local $j i32) (local $match i32)
    (local $result_len i32) (local $result_cap i32)
    (local $result (ref $CharArray)) (local $ri i32)
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $tdata (struct.get $String $data (ref.cast (ref $String) (local.get $target))))
    (local.set $rdata (struct.get $String $data (ref.cast (ref $String) (local.get $replacement))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $tlen (array.len (local.get $tdata)))
    (local.set $rlen (array.len (local.get $rdata)))
    (if (i32.eqz (local.get $tlen)) (then (return (local.get $s))))
    ;; Allocate result buffer (worst case: every char is replaced)
    (local.set $result_cap (i32.mul (local.get $slen) (i32.add (local.get $rlen) (i32.const 1))))
    (if (i32.lt_s (local.get $result_cap) (i32.add (local.get $slen) (i32.const 1)))
      (then (local.set $result_cap (i32.add (local.get $slen) (i32.const 1)))))
    (local.set $result (array.new $CharArray (i32.const 0) (local.get $result_cap)))
    (local.set $i (i32.const 0))
    (local.set $ri (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $slen)))
        ;; Check for match at position i
        (local.set $match (i32.const 1))
        (if (i32.le_s (i32.add (local.get $i) (local.get $tlen)) (local.get $slen))
          (then
            (local.set $j (i32.const 0))
            (block $no_match
              (loop $cmp
                (br_if $no_match (i32.ge_s (local.get $j) (local.get $tlen)))
                (if (i32.ne (array.get_u $CharArray (local.get $sdata) (i32.add (local.get $i) (local.get $j)))
                            (array.get_u $CharArray (local.get $tdata) (local.get $j)))
                  (then (local.set $match (i32.const 0)) (br $no_match)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $cmp))))
          (else (local.set $match (i32.const 0))))
        (if (local.get $match)
          (then
            ;; Copy replacement
            (local.set $j (i32.const 0))
            (block $rd
              (loop $rl
                (br_if $rd (i32.ge_s (local.get $j) (local.get $rlen)))
                (array.set $CharArray (local.get $result) (local.get $ri) (array.get_u $CharArray (local.get $rdata) (local.get $j)))
                (local.set $ri (i32.add (local.get $ri) (i32.const 1)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $rl)))
            (local.set $i (i32.add (local.get $i) (local.get $tlen))))
          (else
            ;; Copy original byte
            (array.set $CharArray (local.get $result) (local.get $ri) (array.get_u $CharArray (local.get $sdata) (local.get $i)))
            (local.set $ri (i32.add (local.get $ri) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $loop)))
    ;; Trim result to actual length
    (local.set $result_len (local.get $ri))
    (local.set $sdata (array.new $CharArray (i32.const 0) (local.get $result_len)))
    (array.copy $CharArray $CharArray (local.get $sdata) (i32.const 0) (local.get $result) (i32.const 0) (local.get $result_len))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $sdata)))

  ;; str_split: split string by single-char separator, return a Cons list of strings
  (func $str_split (param $s anyref) (param $sep anyref) (result anyref)
    (local $sdata (ref $CharArray)) (local $sepdata (ref $CharArray))
    (local $slen i32) (local $seplen i32)
    (local $i i32) (local $start i32) (local $j i32) (local $match i32)
    (local $result anyref) (local $part (ref $CharArray)) (local $part_len i32)
    (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
    (local.set $sdata (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $sepdata (struct.get $String $data (ref.cast (ref $String) (local.get $sep))))
    (local.set $slen (array.len (local.get $sdata)))
    (local.set $seplen (array.len (local.get $sepdata)))
    (if (i32.eqz (local.get $seplen)) (then (return (struct.new $Cons (i32.const 6) (local.get $s) (ref.null none)))))
    (local.set $result (ref.null none))
    (local.set $i (local.get $slen))
    (local.set $start (local.get $slen))
    ;; Scan backwards to build list in forward order
    (block $done
      (loop $loop
        ;; Check if we can match separator at position i-seplen
        (if (i32.ge_s (local.get $i) (local.get $seplen))
          (then
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (local.set $match (i32.const 1))
            (if (i32.ge_s (i32.sub (local.get $start) (local.get $i)) (local.get $seplen))
              (then
                ;; Check for separator match at position i
                (local.set $j (i32.const 0))
                (block $no_match
                  (loop $cmp
                    (br_if $no_match (i32.ge_s (local.get $j) (local.get $seplen)))
                    (if (i32.ne (array.get_u $CharArray (local.get $sdata) (i32.add (local.get $i) (local.get $j)))
                                (array.get_u $CharArray (local.get $sepdata) (local.get $j)))
                      (then (local.set $match (i32.const 0)) (br $no_match)))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $cmp)))
                (if (local.get $match)
                  (then
                    ;; Extract substring from i+seplen to start
                    (local.set $part_len (i32.sub (local.get $start) (i32.add (local.get $i) (local.get $seplen))))
                    (local.set $part (array.new $CharArray (i32.const 0) (local.get $part_len)))
                    (if (i32.gt_s (local.get $part_len) (i32.const 0))
                      (then (array.copy $CharArray $CharArray (local.get $part) (i32.const 0) (local.get $sdata)
                        (i32.add (local.get $i) (local.get $seplen)) (local.get $part_len))))
                    (local.set $result (struct.new $Cons (i32.const 6)
                      (struct.new $String (i32.const 3) (i32.const -1) (local.get $part))
                      (local.get $result)))
                    (local.set $start (local.get $i)))))
              (else (nop))))
          (else
            ;; Add first segment
            (local.set $part_len (local.get $start))
            (local.set $part (array.new $CharArray (i32.const 0) (local.get $part_len)))
            (if (i32.gt_s (local.get $part_len) (i32.const 0))
              (then (array.copy $CharArray $CharArray (local.get $part) (i32.const 0) (local.get $sdata) (i32.const 0) (local.get $part_len))))
            (local.set $result (struct.new $Cons (i32.const 6)
              (struct.new $String (i32.const 3) (i32.const -1) (local.get $part))
              (local.get $result)))
            (return (local.get $result))))
        (br $loop)))
    (local.get $result))

  ;; string->mem!: copy String's UTF-8 bytes to linear memory at offset, return byte count
  (func $string__GT_mem_BANG_ (param $str anyref) (param $offset i32) (result i32)
    (local $chars (ref null $CharArray))
    (local $len i32)
    (local $i i32)
    (if (ref.is_null (local.get $str)) (then (return (i32.const 0))))
    (if (i32.eqz (ref.test (ref $String) (local.get $str))) (then (return (i32.const 0))))
    (local.set $chars (struct.get $String $data (ref.cast (ref $String) (local.get $str))))
    (local.set $len (array.len (local.get $chars)))
    (if (i32.eqz (local.get $len)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $offset) (local.get $i))
                    (array.get_u $CharArray (local.get $chars) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $len))

  ;; mem->string: read len bytes from linear memory at offset, return String
  (func $mem__GT_string (param $offset i32) (param $len i32) (result anyref)
    (local $chars (ref $CharArray))
    (local $i i32)
    (if (i32.le_s (local.get $len) (i32.const 0))
      (then (return (struct.new $String (i32.const 3) (i32.const -1)
                      (array.new $CharArray (i32.const 0) (i32.const 0))))))
    (local.set $chars (array.new $CharArray (i32.const 0) (local.get $len)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (array.set $CharArray (local.get $chars) (local.get $i)
          (i32.load8_u (i32.add (local.get $offset) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $chars)))

  ;; char_at_as_str: return codepoint at codepoint index as string
  (func $char_at_as_str (param $s anyref) (param $idx i32) (result anyref)
    (local $data (ref $CharArray))
    (local $offset i32)
    (local $cp_len i32)
    (local $new_data (ref $CharArray))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $offset (call $utf8_byte_offset (local.get $data) (local.get $idx)))
    (local.set $cp_len (call $utf8_cp_len (array.get_u $CharArray (local.get $data) (local.get $offset))))
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $cp_len)))
    (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $data) (local.get $offset) (local.get $cp_len))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $new_data)))

  ;; nth_polymorphic: get element at index from vector, transient vector, string, or cons
  (func $nth_polymorphic (param $coll anyref) (param $idx i32) (result anyref)
    (local $tv (ref $TransientVector))
    (local $cur anyref)
    (local $i i32)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
      (then (call $vector_nth (local.get $coll) (local.get $idx)))
      (else
        (if (result anyref) (ref.test (ref $VectorSeq) (local.get $coll))
          (then (call $vector_nth
            (struct.get $VectorSeq $vec (ref.cast (ref $VectorSeq) (local.get $coll)))
            (i32.add (struct.get $VectorSeq $offset (ref.cast (ref $VectorSeq) (local.get $coll)))
                     (local.get $idx))))
          (else
        (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 15))
          (then
            ;; TransientVector — build temp Vector for array_for lookup
            (local.set $tv (ref.cast (ref $TransientVector) (local.get $coll)))
            (call $vector_nth
              (struct.new $Vector (i32.const 7)
                (struct.get $TransientVector $count (local.get $tv))
                (struct.get $TransientVector $shift (local.get $tv))
                (struct.get $TransientVector $root (local.get $tv))
                (struct.get $TransientVector $tail (local.get $tv)))
              (local.get $idx)))
          (else
            (if (result anyref) (ref.test (ref $String) (local.get $coll))
              (then (call $char_at_as_str (local.get $coll) (local.get $idx)))
              (else
                ;; Cons (list) — walk the chain idx times
                (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
                  (then
                    (local.set $cur (local.get $coll))
                    (local.set $i (local.get $idx))
                    (block $found
                      (loop $walk
                        (br_if $found (i32.or (ref.is_null (local.get $cur)) (i32.eqz (ref.test (ref $Cons) (local.get $cur)))))
                        (if (i32.eqz (local.get $i))
                          (then
                            (local.set $cur (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $cur))))
                            (br $found)))
                        (local.set $cur (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $cur))))
                        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                        (br $walk)))
                    (local.get $cur))
                  (else
                    ;; LazySeq or other seq — walk using first/rest
                    (if (result anyref) (ref.test (ref $LazySeq) (local.get $coll))
                      (then
                        (local.set $cur (local.get $coll))
                        (local.set $i (local.get $idx))
                        (block $done2
                          (loop $walk2
                            (br_if $done2 (ref.is_null (call $seq (local.get $cur))))
                            (if (i32.eqz (local.get $i))
                              (then
                                (local.set $cur (call $first (local.get $cur)))
                                (br $done2)))
                            (local.set $cur (call $rest (local.get $cur)))
                            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                            (br $walk2)))
                        (local.get $cur))
                      (else (ref.null none))))))))))))))

  ;; Keyword name table global (initialized in $start)
  (global $__kw_names (mut anyref) (ref.null none))
  ;; Runtime keyword creation support
  (global $__kw_next_id (mut i32) (i32.const 0))
  (global $__kw_runtime_list (mut anyref) (ref.null none))
  ;; Symbol helpers
  ;; sym_eq: compare two symbols by name + namespace
  (func $sym_eq (param $a anyref) (param $b anyref) (result i32)
    (local $sa (ref $Symbol)) (local $sb (ref $Symbol))
    (local.set $sa (ref.cast (ref $Symbol) (local.get $a)))
    (local.set $sb (ref.cast (ref $Symbol) (local.get $b)))
    ;; Fast path: same ID and both >= 0
    (if (i32.and (i32.ge_s (struct.get $Symbol $id (local.get $sa)) (i32.const 0))
                 (i32.eq (struct.get $Symbol $id (local.get $sa))
                         (struct.get $Symbol $id (local.get $sb))))
      (then (return (i32.const 1))))
    ;; Compare name strings
    (if (i32.eqz (call $str_eq (struct.get $Symbol $name (local.get $sa))
                                (struct.get $Symbol $name (local.get $sb))))
      (then (return (i32.const 0))))
    ;; Names match - compare namespaces
    (if (i32.and (ref.is_null (struct.get $Symbol $ns (local.get $sa)))
                 (ref.is_null (struct.get $Symbol $ns (local.get $sb))))
      (then (return (i32.const 1))))
    (if (i32.or (ref.is_null (struct.get $Symbol $ns (local.get $sa)))
                (ref.is_null (struct.get $Symbol $ns (local.get $sb))))
      (then (return (i32.const 0))))
    (call $str_eq (struct.get $Symbol $ns (local.get $sa))
                   (struct.get $Symbol $ns (local.get $sb))))

  ;; sym_hash: hash a symbol by name content (+ namespace)
  (func $sym_hash (param $val anyref) (result i32)
    (local $s (ref $Symbol))
    (local $h i32)
    (local.set $s (ref.cast (ref $Symbol) (local.get $val)))
    (local.set $h (call $str_hash (struct.get $Symbol $name (local.get $s))))
    ;; Mix in namespace hash if present
    (if (i32.eqz (ref.is_null (struct.get $Symbol $ns (local.get $s))))
      (then
        (local.set $h (i32.add (i32.mul (local.get $h) (i32.const 31))
                                (call $str_hash (struct.get $Symbol $ns (local.get $s)))))))
    (call $hash_int (i32.add (local.get $h) (i32.const 0xcc9e2d51))))

  ;; symbol_to_str: convert symbol to string (ns/name or just name)
  (func $symbol_to_str (param $val anyref) (result anyref)
    (local $s (ref $Symbol))
    (local $slash (ref $CharArray))
    (local $slash_str anyref)
    (local.set $s (ref.cast (ref $Symbol) (local.get $val)))
    (if (result anyref) (ref.is_null (struct.get $Symbol $ns (local.get $s)))
      (then (struct.get $Symbol $name (local.get $s)))
      (else
        ;; Create ns/name string
        (local.set $slash (array.new $CharArray (i32.const 0) (i32.const 1)))
        (array.set $CharArray (local.get $slash) (i32.const 0) (i32.const 47))  ;; '/'
        (local.set $slash_str (struct.new $String (i32.const 3) (i32.const -1) (local.get $slash)))
        (call $str_concat (call $str_concat (struct.get $Symbol $ns (local.get $s)) (local.get $slash_str))
                          (struct.get $Symbol $name (local.get $s))))))

  ;; extract_ns: given a string like foo/bar, return foo. If no slash, return null.
  (func $extract_ns (param $s anyref) (result anyref)
    (local $src (ref $CharArray))
    (local $len i32)
    (local $i i32)
    (local $slash_pos i32)
    (local $dst (ref $CharArray))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (array.len (local.get $src)))
    (local.set $slash_pos (i32.const -1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        (if (i32.eq (array.get_u $CharArray (local.get $src) (local.get $i)) (i32.const 47))  ;; '/'
          (then (local.set $slash_pos (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (if (result anyref) (i32.lt_s (local.get $slash_pos) (i32.const 0))
      (then (ref.null none))
      (else
        (if (result anyref) (i32.le_s (local.get $slash_pos) (i32.const 0))
          (then (call $make_empty_str))
          (else
            (local.set $dst (array.new $CharArray (i32.const 0) (local.get $slash_pos)))
            (array.copy $CharArray $CharArray (local.get $dst) (i32.const 0) (local.get $src)
              (i32.const 0) (local.get $slash_pos))
            (struct.new $String (i32.const 3) (i32.const -1) (local.get $dst)))))))

  ;; namespace: get namespace of keyword or symbol
  (func $namespace (param $val anyref) (result anyref)
    ;; Symbol -> return ns field (may be null)
    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
      (then (struct.get $Symbol $ns (ref.cast (ref $Symbol) (local.get $val))))
      (else
        ;; Keyword -> extract namespace from full name
        (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
          (then (call $extract_ns (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val))))))
          (else (ref.null none))))))

  ;; symbol: construct a symbol from a string, keyword, or symbol (1-arg)
  (func $symbol (param $arg anyref) (result anyref)
    (local $name_str anyref)
    (local $slash_idx i32)
    ;; nil -> throw
    (if (ref.is_null (local.get $arg))
      (then (throw $exn (call $str1 (call $make_empty_str)))))
    ;; Already a symbol -> return as-is
    (if (i32.eq (call $type_tag (local.get $arg)) (i32.const 4))
      (then (return (local.get $arg))))
    ;; Keyword -> create symbol with same name
    (if (i32.eq (call $type_tag (local.get $arg)) (i32.const 2))
      (then
        (local.set $name_str (call $name_fn (local.get $arg)))
        (return (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name_str) (ref.null none)))))
    ;; String -> check for ns/name format
    (local.set $name_str (call $str1 (local.get $arg)))
    (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name_str) (ref.null none)))

  ;; symbol2: construct a namespaced symbol from two strings (2-arg)
  (func $symbol2 (param $ns anyref) (param $name anyref) (result anyref)
    ;; If ns is nil, create symbol with just name (no namespace)
    (if (result anyref) (ref.is_null (local.get $ns))
      (then (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name) (ref.null none)))
      (else (struct.new $Symbol (i32.const 4) (i32.const -1) (local.get $name) (local.get $ns)))))

  ;; keyword_from_string: create/lookup keyword from string name
  (func $keyword (param $name anyref) (result anyref)
    (local $i i32)
    (local $count i32)
    (local $current anyref)
    ;; If already a keyword, return as-is
    (if (i32.eq (call $type_tag (local.get $name)) (i32.const 2))
      (then (return (local.get $name))))
    ;; Search compile-time keyword table
    (if (i32.eqz (ref.is_null (global.get $__kw_names)))
      (then
        (local.set $count (call $array_length (global.get $__kw_names)))
        (local.set $i (i32.const 0))
        (block $found_ct
          (loop $search_ct
            (br_if $found_ct (i32.ge_s (local.get $i) (local.get $count)))
            (if (call $str_eq (local.get $name) (call $array_get (global.get $__kw_names) (local.get $i)))
              (then (return (struct.new $Keyword (i32.const 2) (local.get $i)))))

            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $search_ct)))))
    ;; Search runtime keyword list (cons pairs: (cons (cons name-str keyword) rest))
    (local.set $current (global.get $__kw_runtime_list))
    (block $found_rt
      (loop $search_rt
        (br_if $found_rt (ref.is_null (local.get $current)))
        (if (call $str_eq (local.get $name)
              (struct.get $Cons $first (ref.cast (ref $Cons)
                (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))
          (then (return
            (struct.get $Cons $rest (ref.cast (ref $Cons)
              (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $search_rt)))
    ;; Not found - create new keyword
    (local.set $current (struct.new $Keyword (i32.const 2) (global.get $__kw_next_id)))
    (global.set $__kw_next_id (i32.add (global.get $__kw_next_id) (i32.const 1)))
    ;; Add to runtime list: (cons (cons name keyword) existing-list)
    (global.set $__kw_runtime_list
      (call $cons (call $cons (local.get $name) (local.get $current))
                  (global.get $__kw_runtime_list)))
    (local.get $current))

  ;; keyword2: construct a namespaced keyword from ns and name strings
  ;; Concatenates ns + slash + name, then interns as keyword
  (func $keyword2 (param $ns anyref) (param $name anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $ns))
      (then (call $keyword (local.get $name)))
      (else (call $keyword (call $str_concat (call $str_concat (local.get $ns) (call $make_str_slash)) (local.get $name))))))

  ;; Boolean constants (singleton instances)
  (global $__true (ref $Boolean) (struct.new $Boolean (i32.const 14) (i32.const 1)))
  (global $__false (ref $Boolean) (struct.new $Boolean (i32.const 14) (i32.const 0)))

  ;; bool: convert i32 to $Boolean (0 -> $__false, non-zero -> $__true)
  (func $bool (param $v i32) (result anyref)
    (if (result anyref) (local.get $v)
      (then (global.get $__true))
      (else (global.get $__false))))

  ;; Sentinel for hash_map_get_sentinel (distinguishes nil value from key-not-found)
  (global $__not_found_sentinel (ref $Keyword) (struct.new $Keyword (i32.const 2) (i32.const -999)))

  ;; ==========================================
  ;; Polymorphic contains? (maps + sets)
  ;; ==========================================
  (func $contains_QMARK_ (param $coll anyref) (param $key anyref) (result anyref)
    (local $tag i32) (local $root anyref)
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (global.get $__false))
      (else
        (local.set $tag (call $type_tag (local.get $coll)))
        (if (result anyref) (i32.or (i32.eq (local.get $tag) (i32.const 8)) (i32.eq (local.get $tag) (i32.const 19)))
          (then (call $hash_map_contains_QMARK_ (local.get $coll) (local.get $key)))
          (else
            (if (result anyref) (i32.eq (local.get $tag) (i32.const 9))
              (then (call $set_contains_QMARK_ (local.get $coll) (local.get $key)))
              (else
                ;; Vector - check if index is in bounds (key must be i31 integer)
                (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
                  (then
                    (if (result anyref) (ref.test (ref i31) (local.get $key))
                      (then
                        (if (result anyref) (i32.and
                            (i32.ge_s (i31.get_s (ref.cast (ref i31) (local.get $key))) (i32.const 0))
                            (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $key)))
                                      (struct.get $Vector $count (ref.cast (ref $Vector) (local.get $coll)))))
                          (then (global.get $__true))
                          (else (global.get $__false))))
                      (else (global.get $__false))))
                  (else
                    ;; TransientHashMap
                    (if (result anyref) (i32.eq (local.get $tag) (i32.const 16))
                      (then
                        (local.set $root (struct.get $TransientHashMap $array (ref.cast (ref $TransientHashMap) (local.get $coll))))
                        (if (result anyref) (ref.eq (ref.cast eqref
                            (call $hamt_get (local.get $root) (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
                            (global.get $__not_found_sentinel))
                          (then (global.get $__false))
                          (else (global.get $__true))))
                      (else
                        ;; TransientHashSet
                        (if (result anyref) (i32.eq (local.get $tag) (i32.const 17))
                          (then
                            (local.set $root (struct.get $TransientHashSet $array (ref.cast (ref $TransientHashSet) (local.get $coll))))
                            (if (result anyref) (ref.eq (ref.cast eqref
                                (call $hamt_get (local.get $root) (local.get $key) (call $hash (local.get $key)) (i32.const 0)))
                                (global.get $__not_found_sentinel))
                              (then (global.get $__false))
                              (else (global.get $__true))))
                          (else
                            ;; Protocol fallback: user types implementing ILookup (defrecord etc.)
                            (if (result anyref) (call $truthy (call $__satisfies_ILookup (local.get $coll)))
                              (then
                                (if (result anyref) (ref.eq (ref.cast eqref
                                    (call $hash_map_get_default (local.get $coll) (local.get $key) (global.get $__not_found_sentinel)))
                                    (global.get $__not_found_sentinel))
                                  (then (global.get $__false))
                                  (else (global.get $__true))))
                              (else (global.get $__false))))))))))))))))

  ;; ==========================================
  ;; Polymorphic conj (vectors, lists, sets, maps, nil)
  ;; ==========================================
  (func $conj (param $coll anyref) (param $val anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $coll (call $unwrap_meta (local.get $coll)))
    ;; nil -> create a list
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (call $cons (local.get $val) (ref.null none)))
      (else
        ;; Vector -> append
        (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
          (then (call $vector_conj (local.get $coll) (local.get $val)))
          (else
            ;; Cons (list) -> prepend
            (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
              (then (call $cons (local.get $val) (local.get $coll)))
              (else
                ;; VectorSeq -> prepend (like a seq/list)
                (if (result anyref) (ref.test (ref $VectorSeq) (local.get $coll))
                  (then (call $cons (local.get $val) (local.get $coll)))
                  (else
                ;; HashSet -> add element
                (if (result anyref) (i32.eq (call $type_tag (local.get $coll)) (i32.const 9))
                  (then (call $set_conj (local.get $coll) (local.get $val)))
                  (else
                    ;; HashMap/ArrayMap -> assoc key-value pair (val must be a 2-element vector [k v])
                    (if (result anyref) (i32.or (i32.eq (call $type_tag (local.get $coll)) (i32.const 8)) (i32.eq (call $type_tag (local.get $coll)) (i32.const 19)))
                      (then (call $hash_map_assoc (local.get $coll)
                        (call $vector_nth (local.get $val) (i32.const 0))
                        (call $vector_nth (local.get $val) (i32.const 1))))
                      (else
                        ;; Protocol fallback for ICollection
                        (if (result anyref) (call $truthy (call $__satisfies_ICollection (local.get $coll)))
                          (then (call $__dispatch__conj (local.get $coll) (local.get $val)))
                          (else (call $vector_conj (local.get $coll) (local.get $val)))))))))))))))))

  ;; ==========================================
  ;; Polymorphic comparison (int + float)
  ;; ==========================================

  ;; Helper to extract numeric value as f64
  (func $to_f64 (param $val anyref) (result f64)
    (if (result f64) (ref.test (ref i31) (local.get $val))
      (then (f64.convert_i32_s (i31.get_s (ref.cast (ref i31) (local.get $val)))))
      (else
        (if (result f64) (ref.test (ref $Float) (local.get $val))
          (then (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))))
          (else (f64.const 0))))))

  (func $cmp_lt (param $a anyref) (param $b anyref) (result anyref)
    ;; Both i31ref -> fast path
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.lt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  (func $cmp_gt (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.gt_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.gt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  (func $cmp_le (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.le_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.le (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  (func $cmp_ge (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (if (result anyref) (i32.ge_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                           (i31.get_s (ref.cast (ref i31) (local.get $b))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else (if (result anyref) (f64.ge (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (global.get $__true)) (else (global.get $__false))))))

  ;; zero?: polymorphic (works on int and float)
  (func $zero_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $val))
      (then (if (result anyref) (i32.eqz (i31.get_s (ref.cast (ref i31) (local.get $val))))
        (then (global.get $__true)) (else (global.get $__false))))
      (else
        (if (result anyref) (ref.test (ref $Float) (local.get $val))
          (then (if (result anyref) (f64.eq (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))) (f64.const 0))
            (then (global.get $__true)) (else (global.get $__false))))
          (else (global.get $__false))))))

  ;; ==========================================
  ;; Three-way compare (returns -1, 0, or 1 as i31ref)
  ;; Flat style to avoid deep nesting
  ;; ==========================================
  (func $__compare (param $a anyref) (param $b anyref) (result anyref)
    (local $result i32)
    (local $ia i32) (local $ib i32)
    (local.set $result (i32.const 0))
    (block $done
      ;; nil cases
      (if (ref.is_null (local.get $a))
        (then
          (if (ref.is_null (local.get $b))
            (then (br $done))
            (else (local.set $result (i32.const -1)) (br $done)))))
      (if (ref.is_null (local.get $b))
        (then (local.set $result (i32.const 1)) (br $done)))
      ;; Both i31ref (integers)
      (if (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
        (then
          (local.set $ia (i31.get_s (ref.cast (ref i31) (local.get $a))))
          (local.set $ib (i31.get_s (ref.cast (ref i31) (local.get $b))))
          (if (i32.lt_s (local.get $ia) (local.get $ib))
            (then (local.set $result (i32.const -1)))
            (else (if (i32.gt_s (local.get $ia) (local.get $ib))
              (then (local.set $result (i32.const 1))))))
          (br $done)))
      ;; Keywords: compare by name string (lexicographic, like Clojure)
      (if (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 2)) (i32.eq (call $type_tag (local.get $b)) (i32.const 2)))
        (then
          (local.set $result (i31.get_s (ref.cast (ref i31) (call $__compare_strings
            (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $a))))
            (call $kw_name_lookup (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $b))))))))
          (br $done)))
      ;; Strings: byte-by-byte comparison
      (if (i32.and (ref.test (ref $String) (local.get $a)) (ref.test (ref $String) (local.get $b)))
        (then
          (local.set $result (i31.get_s (ref.cast (ref i31) (call $__compare_strings (local.get $a) (local.get $b)))))
          (br $done)))
      ;; Symbols: compare by name string (lexicographic)
      (if (i32.and (i32.eq (call $type_tag (local.get $a)) (i32.const 4)) (i32.eq (call $type_tag (local.get $b)) (i32.const 4)))
        (then
          (local.set $result (i31.get_s (ref.cast (ref i31) (call $__compare_strings
            (struct.get $Symbol $name (ref.cast (ref $Symbol) (local.get $a)))
            (struct.get $Symbol $name (ref.cast (ref $Symbol) (local.get $b)))))))
          (br $done)))
      ;; Float/mixed numeric: compare as f64
      (if (f64.lt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
        (then (local.set $result (i32.const -1)))
        (else (if (f64.gt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))
          (then (local.set $result (i32.const 1)))))))
    (ref.i31 (local.get $result)))

  ;; String comparison helper
  (func $__compare_strings (param $a anyref) (param $b anyref) (result anyref)
    (local $data_a (ref $CharArray))
    (local $data_b (ref $CharArray))
    (local $len_a i32) (local $len_b i32) (local $min_len i32)
    (local $i i32) (local $ca i32) (local $cb i32)
    (local $result i32)
    (local.set $data_a (struct.get $String $data (ref.cast (ref $String) (local.get $a))))
    (local.set $data_b (struct.get $String $data (ref.cast (ref $String) (local.get $b))))
    (local.set $len_a (array.len (local.get $data_a)))
    (local.set $len_b (array.len (local.get $data_b)))
    (local.set $min_len (if (result i32) (i32.lt_s (local.get $len_a) (local.get $len_b))
      (then (local.get $len_a)) (else (local.get $len_b))))
    (local.set $i (i32.const 0))
    (local.set $result (i32.const 0))
    (block $done
      (loop $cmp
        (br_if $done (i32.ge_s (local.get $i) (local.get $min_len)))
        (local.set $ca (array.get_s $CharArray (local.get $data_a) (local.get $i)))
        (local.set $cb (array.get_s $CharArray (local.get $data_b) (local.get $i)))
        (if (i32.lt_s (local.get $ca) (local.get $cb))
          (then (local.set $result (i32.const -1)) (br $done)))
        (if (i32.gt_s (local.get $ca) (local.get $cb))
          (then (local.set $result (i32.const 1)) (br $done)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cmp))
      ;; All bytes equal up to min_len, compare lengths
      (if (i32.lt_s (local.get $len_a) (local.get $len_b))
        (then (local.set $result (i32.const -1)))
        (else (if (i32.gt_s (local.get $len_a) (local.get $len_b))
          (then (local.set $result (i32.const 1)))))))
    (ref.i31 (local.get $result)))

  ;; ==========================================
  ;; Array helpers (WasmGC $AnyArray interop)
  ;; ==========================================

  ;; aset: sets array element and returns the value
  (func $__aset (param $arr anyref) (param $i i32) (param $v anyref) (result anyref)
    (array.set $AnyArray (ref.cast (ref $AnyArray) (local.get $arr)) (local.get $i) (local.get $v))
    (local.get $v))

  ;; aclone: create a copy of an array
  (func $__aclone (param $arr anyref) (result anyref)
    (local $src (ref $AnyArray))
    (local $len i32)
    (local $dst (ref $AnyArray))
    (local.set $src (ref.cast (ref $AnyArray) (local.get $arr)))
    (local.set $len (array.len (local.get $src)))
    (local.set $dst (array.new_default $AnyArray (local.get $len)))
    (array.copy $AnyArray $AnyArray (local.get $dst) (i32.const 0) (local.get $src) (i32.const 0) (local.get $len))
    (local.get $dst))

  ;; object_array: convert a seq/vector to a WasmGC array
  (func $__object_array (param $coll anyref) (result anyref)
    (local $len i32)
    (local $arr (ref $AnyArray))
    (local $i i32)
    (local $s anyref)
    ;; Get count
    (local.set $len (call $count_internal (local.get $coll)))
    (local.set $arr (array.new_default $AnyArray (local.get $len)))
    ;; Iterate via seq
    (local.set $s (call $seq (local.get $coll)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $fill
        (br_if $done (ref.is_null (local.get $s)))
        (array.set $AnyArray (local.get $arr) (local.get $i) (call $first (local.get $s)))
        (local.set $s (call $rest (local.get $s)))
        (local.set $s (call $seq (local.get $s)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $fill)))
    (local.get $arr))

  ;; ==========================================
  ;; Mixed arithmetic (int + float)
  ;; ==========================================
  (func $add (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a)))
                               (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.add (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  (func $sub (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $a)))
                               (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.sub (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  (func $mul (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $a)))
                               (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.mul (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  (func $div (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
      (then (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $a)))
                                  (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (else (struct.new $Float (i32.const 5) (f64.div (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))))

  ;; inc/dec: polymorphic
  (func $inc (param $a anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $a))
      (then (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a))) (i32.const 1))))
      (else (struct.new $Float (i32.const 5) (f64.add (call $to_f64 (local.get $a)) (f64.const 1))))))

  (func $dec (param $a anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $a))
      (then (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $a))) (i32.const 1))))
      (else (struct.new $Float (i32.const 5) (f64.sub (call $to_f64 (local.get $a)) (f64.const 1))))))

  ;; ==========================================
  ;; Variadic swap! (swap! a f x y ...)
  ;; ==========================================
  (func $swap_BANG_2 (param $a anyref) (param $f anyref) (param $x anyref) (result anyref)
    (local $atom (ref $Atom)) (local $old anyref) (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke2 (local.get $f) (local.get $old) (local.get $x)))
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  (func $swap_BANG_3 (param $a anyref) (param $f anyref) (param $x anyref) (param $y anyref) (result anyref)
    (local $atom (ref $Atom)) (local $old anyref) (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke3 (local.get $f) (local.get $old) (local.get $x) (local.get $y)))
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  (func $swap_BANG_4 (param $a anyref) (param $f anyref) (param $x anyref) (param $y anyref) (param $z anyref) (result anyref)
    (local $atom (ref $Atom)) (local $old anyref) (local $new anyref)
    (local.set $atom (ref.cast (ref $Atom) (local.get $a)))
    (local.set $old (struct.get $Atom $val (local.get $atom)))
    (local.set $new (call $invoke4 (local.get $f) (local.get $old) (local.get $x) (local.get $y) (local.get $z)))
    (call $atom_validate (struct.get $Atom $validator (local.get $atom)) (local.get $new))
    (struct.set $Atom $val (local.get $atom) (local.get $new))
    (call $fire_watches (struct.get $Atom $watches (local.get $atom)) (local.get $a) (local.get $old) (local.get $new))
    (local.get $new))

  ;; ==========================================
  ;; Float to string (proper decimal conversion)
  ;; ==========================================
  ;; Helper: return special float strings by index (0=NaN, 1=##Inf, 2=##-Inf)
  ;; Uses linear memory scratch space to build short strings
  (func $float_special_str (param $which i32) (result anyref)
    ;; Write bytes to linear memory at offset 0, then use $mem__GT_string
    (if (result anyref) (i32.eqz (local.get $which))
      (then
        (i32.store8 (i32.const 0) (i32.const 78))
        (i32.store8 (i32.const 1) (i32.const 97))
        (i32.store8 (i32.const 2) (i32.const 78))
        (call $mem__GT_string (i32.const 0) (i32.const 3)))
      (else (if (result anyref) (i32.eq (local.get $which) (i32.const 1))
        (then
          (i32.store8 (i32.const 0) (i32.const 35))
          (i32.store8 (i32.const 1) (i32.const 35))
          (i32.store8 (i32.const 2) (i32.const 73))
          (i32.store8 (i32.const 3) (i32.const 110))
          (i32.store8 (i32.const 4) (i32.const 102))
          (call $mem__GT_string (i32.const 0) (i32.const 5)))
        (else
          (i32.store8 (i32.const 0) (i32.const 35))
          (i32.store8 (i32.const 1) (i32.const 35))
          (i32.store8 (i32.const 2) (i32.const 45))
          (i32.store8 (i32.const 3) (i32.const 73))
          (i32.store8 (i32.const 4) (i32.const 110))
          (i32.store8 (i32.const 5) (i32.const 102))
          (call $mem__GT_string (i32.const 0) (i32.const 6)))))))

  (func $float_to_str (param $f f64) (result anyref)
    (local $neg i32)
    (local $abs f64)
    (local $exp i32)
    (local $mantissa f64)
    (local $int_part i32)
    (local $frac f64)
    (local $int_str anyref)
    (local $digit i32)
    (local $buf (ref $CharArray))
    (local $pos i32)
    (local $i i32)
    (local $result (ref $CharArray))
    ;; Handle special values: NaN, Infinity, -Infinity
    (if (f64.ne (local.get $f) (local.get $f))
      (then (return (call $float_special_str (i32.const 0)))))
    (if (f64.eq (local.get $f) (f64.const inf))
      (then (return (call $float_special_str (i32.const 1)))))
    (if (f64.eq (local.get $f) (f64.const -inf))
      (then (return (call $float_special_str (i32.const 2)))))
    ;; Handle 0.0 and -0.0
    (if (f64.eq (local.get $f) (f64.const 0))
      (then (return (call $make_literal_str_2 (i32.const 48) (i32.const 46) (i32.const 48))))) ;; "0.0"
    ;; Handle negative
    (local.set $neg (f64.lt (local.get $f) (f64.const 0)))
    (local.set $abs (if (result f64) (local.get $neg)
      (then (f64.neg (local.get $f)))
      (else (local.get $f))))
    ;; Check if we need scientific notation: abs >= 2^31 (i32 overflow) or abs < 1e-3
    (if (i32.or (f64.ge (local.get $abs) (f64.const 2147483648.0))
                (f64.lt (local.get $abs) (f64.const 0.001)))
      (then (return (call $float_to_str_sci (local.get $f)))))
    ;; Normal decimal path: abs fits in reasonable range
    ;; Get integer part using f64.floor (not i32.trunc to avoid overflow)
    (local.set $frac (local.get $abs))
    (local.set $int_part (i32.trunc_sat_f64_s (f64.floor (local.get $abs))))
    (local.set $frac (f64.sub (local.get $abs) (f64.convert_i32_s (local.get $int_part))))
    ;; Convert integer part (with sign)
    (local.set $int_str (call $int_to_str (if (result i32) (local.get $neg)
      (then (i32.sub (i32.const 0) (local.get $int_part)))
      (else (local.get $int_part)))))
    ;; Format fractional part: up to 6 digits, strip trailing zeros (keep 1)
    (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 7))) ;; dot + 6 digits
    (array.set $CharArray (local.get $buf) (i32.const 0) (i32.const 46)) ;; '.'
    (local.set $pos (i32.const 1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (i32.const 6)))
        (local.set $frac (f64.mul (local.get $frac) (f64.const 10)))
        (local.set $digit (i32.trunc_sat_f64_s (local.get $frac)))
        (local.set $frac (f64.sub (local.get $frac) (f64.convert_i32_s (local.get $digit))))
        (array.set $CharArray (local.get $buf) (local.get $pos) (i32.add (i32.const 48) (local.get $digit)))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Strip trailing zeros (keep at least dot + 1 digit = pos >= 2)
    (block $strip_done
      (loop $strip
        (br_if $strip_done (i32.le_s (local.get $pos) (i32.const 2)))
        (br_if $strip_done (i32.ne (array.get_u $CharArray (local.get $buf) (i32.sub (local.get $pos) (i32.const 1))) (i32.const 48)))
        (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
        (br $strip)))
    ;; Copy to right-sized array
    (local.set $result (array.new $CharArray (i32.const 0) (local.get $pos)))
    (array.copy $CharArray $CharArray (local.get $result) (i32.const 0) (local.get $buf) (i32.const 0) (local.get $pos))
    (call $str_concat (local.get $int_str)
      (struct.new $String (i32.const 3) (i32.const -1) (local.get $result))))

  ;; Helper: make a 3-char string from 3 byte values
  (func $make_literal_str_2 (param $a i32) (param $b i32) (param $c i32) (result anyref)
    (local $buf (ref $CharArray))
    (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 3)))
    (array.set $CharArray (local.get $buf) (i32.const 0) (local.get $a))
    (array.set $CharArray (local.get $buf) (i32.const 1) (local.get $b))
    (array.set $CharArray (local.get $buf) (i32.const 2) (local.get $c))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $buf)))

  ;; Scientific notation: e.g. 1.7976931348623157E308 or 4.9E-324
  (func $float_to_str_sci (param $f f64) (result anyref)
    (local $neg i32)
    (local $abs f64)
    (local $exp i32)
    (local $mantissa f64)
    (local $digit i32)
    (local $buf (ref $CharArray))
    (local $pos i32)
    (local $i i32)
    (local $result (ref $CharArray))
    (local $sign_str anyref)
    (local $mant_str anyref)
    (local $exp_str anyref)
    ;; Handle negative
    (local.set $neg (f64.lt (local.get $f) (f64.const 0)))
    (local.set $abs (if (result f64) (local.get $neg)
      (then (f64.neg (local.get $f)))
      (else (local.get $f))))
    ;; Compute exponent: repeatedly divide/multiply by 10 to normalize to [1, 10)
    (local.set $exp (i32.const 0))
    (local.set $mantissa (local.get $abs))
    ;; If >= 10, divide by 10 and increment exp
    (if (f64.ge (local.get $mantissa) (f64.const 10))
      (then
        (block $big_done
          (loop $big_loop
            (br_if $big_done (f64.lt (local.get $mantissa) (f64.const 10)))
            (local.set $mantissa (f64.div (local.get $mantissa) (f64.const 10)))
            (local.set $exp (i32.add (local.get $exp) (i32.const 1)))
            (br $big_loop)))))
    ;; If < 1, multiply by 10 and decrement exp
    (if (f64.lt (local.get $mantissa) (f64.const 1))
      (then
        (block $small_done
          (loop $small_loop
            (br_if $small_done (f64.ge (local.get $mantissa) (f64.const 1)))
            (local.set $mantissa (f64.mul (local.get $mantissa) (f64.const 10)))
            (local.set $exp (i32.sub (local.get $exp) (i32.const 1)))
            (br $small_loop)))))
    ;; Now mantissa is in [1, 10), exp is the exponent
    ;; Format mantissa with up to 16 significant digits
    (local.set $digit (i32.trunc_sat_f64_s (local.get $mantissa)))
    (local.set $mantissa (f64.sub (local.get $mantissa) (f64.convert_i32_s (local.get $digit))))
    ;; Build: digit . fraction
    (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 18))) ;; digit + dot + 16 frac digits
    (array.set $CharArray (local.get $buf) (i32.const 0) (i32.add (i32.const 48) (local.get $digit)))
    (array.set $CharArray (local.get $buf) (i32.const 1) (i32.const 46)) ;; '.'
    (local.set $pos (i32.const 2))
    (local.set $i (i32.const 0))
    (block $frac_done
      (loop $frac_loop
        (br_if $frac_done (i32.ge_s (local.get $i) (i32.const 16)))
        (local.set $mantissa (f64.mul (local.get $mantissa) (f64.const 10)))
        (local.set $digit (i32.trunc_sat_f64_s (local.get $mantissa)))
        ;; Clamp digit to 0-9
        (if (i32.gt_s (local.get $digit) (i32.const 9))
          (then (local.set $digit (i32.const 9))))
        (if (i32.lt_s (local.get $digit) (i32.const 0))
          (then (local.set $digit (i32.const 0))))
        (local.set $mantissa (f64.sub (local.get $mantissa) (f64.convert_i32_s (local.get $digit))))
        (array.set $CharArray (local.get $buf) (local.get $pos) (i32.add (i32.const 48) (local.get $digit)))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $frac_loop)))
    ;; Strip trailing zeros (keep at least 1 after dot)
    (block $strip_done
      (loop $strip
        (br_if $strip_done (i32.le_s (local.get $pos) (i32.const 3)))
        (br_if $strip_done (i32.ne (array.get_u $CharArray (local.get $buf) (i32.sub (local.get $pos) (i32.const 1))) (i32.const 48)))
        (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
        (br $strip)))
    ;; Build mantissa string
    (local.set $result (array.new $CharArray (i32.const 0) (local.get $pos)))
    (array.copy $CharArray $CharArray (local.get $result) (i32.const 0) (local.get $buf) (i32.const 0) (local.get $pos))
    (local.set $mant_str (struct.new $String (i32.const 3) (i32.const -1) (local.get $result)))
    ;; Build sign prefix
    (local.set $sign_str (if (result anyref) (local.get $neg)
      (then (call $make_literal_str_1 (i32.const 45))) ;; "-"
      (else (call $make_empty_str))))
    ;; Build exponent string: "E" + exp
    (local.set $exp_str (call $str_concat
      (call $make_literal_str_1 (i32.const 69)) ;; "E"
      (call $int_to_str (local.get $exp))))
    ;; Concat: sign + mantissa + "E" + exp
    (call $str_concat (call $str_concat (local.get $sign_str) (local.get $mant_str))
      (local.get $exp_str)))

  ;; Helper: make a 1-char string
  (func $make_literal_str_1 (param $ch i32) (result anyref)
    (local $buf (ref $CharArray))
    (local.set $buf (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $buf) (i32.const 0) (local.get $ch))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $buf)))
  ;; ==========================================
  ;; Linear Memory Helpers (big-endian I/O, FNV-1a hash)
  ;; ==========================================

  ;; mem_write_i32_be: write 32-bit integer in big-endian byte order
  (func $mem_write_i32_be (param $offset i32) (param $val i32)
    (i32.store8 (local.get $offset)
      (i32.shr_u (local.get $val) (i32.const 24)))
    (i32.store8 (i32.add (local.get $offset) (i32.const 1))
      (i32.and (i32.shr_u (local.get $val) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.add (local.get $offset) (i32.const 2))
      (i32.and (i32.shr_u (local.get $val) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.add (local.get $offset) (i32.const 3))
      (i32.and (local.get $val) (i32.const 0xFF))))

  ;; mem_read_i32_be: read 32-bit integer in big-endian byte order
  (func $mem_read_i32_be (param $offset i32) (result i32)
    (i32.or
      (i32.or
        (i32.shl (i32.load8_u (local.get $offset)) (i32.const 24))
        (i32.shl (i32.load8_u (i32.add (local.get $offset) (i32.const 1))) (i32.const 16)))
      (i32.or
        (i32.shl (i32.load8_u (i32.add (local.get $offset) (i32.const 2))) (i32.const 8))
        (i32.load8_u (i32.add (local.get $offset) (i32.const 3))))))

  ;; mem_write_f64_be: write f64 in big-endian byte order
  ;; Uses scratch space at offset 16 for byte-swap
  (func $mem_write_f64_be (param $offset i32) (param $val f64)
    (local $i i32)
    ;; Store f64 natively (little-endian on most platforms) at scratch offset 16
    (f64.store (i32.const 16) (local.get $val))
    ;; Copy 8 bytes in reverse order to target offset
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (i32.const 8)))
        (i32.store8 (i32.add (local.get $offset) (local.get $i))
          (i32.load8_u (i32.add (i32.const 16) (i32.sub (i32.const 7) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop))))

  ;; mem_read_f64_be: read f64 from big-endian byte order
  ;; Uses scratch space at offset 16 for byte-swap
  (func $mem_read_f64_be (param $offset i32) (result f64)
    (local $i i32)
    ;; Copy 8 bytes in reverse order from source to scratch offset 16
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (i32.const 8)))
        (i32.store8 (i32.add (i32.const 16) (local.get $i))
          (i32.load8_u (i32.add (local.get $offset) (i32.sub (i32.const 7) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Load f64 from scratch (now in native byte order)
    (f64.load (i32.const 16)))

  ;; mem_hash: FNV-1a hash over linear memory range [offset, offset+length)
  (func $mem_hash (param $offset i32) (param $length i32) (result i32)
    (local $h i32)
    (local $i i32)
    (local $end i32)
    (local.set $h (i32.const 0x811c9dc5))
    (local.set $end (i32.add (local.get $offset) (local.get $length)))
    (local.set $i (local.get $offset))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $end)))
        (local.set $h (i32.xor (local.get $h) (i32.load8_u (local.get $i))))
        (local.set $h (i32.mul (local.get $h) (i32.const 0x01000193)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $h))
  ;; ==========================================
  ;; StringBuffer: mutable growable byte buffer
  ;; ==========================================

  ;; string_buffer: create a new StringBuffer with initial capacity
  (func $string_buffer (result anyref)
    (struct.new $StringBuffer
      (array.new $CharArray (i32.const 0) (i32.const 256))
      (i32.const 0)))

  ;; sb_ensure_capacity: grow buffer if needed (internal helper)
  (func $sb_ensure_capacity (param $sb (ref $StringBuffer)) (param $needed i32)
    (local $data (ref $CharArray))
    (local $cap i32)
    (local $new_cap i32)
    (local $new_data (ref $CharArray))
    (local.set $data (struct.get $StringBuffer $data (local.get $sb)))
    (local.set $cap (array.len (local.get $data)))
    (if (i32.le_s (local.get $needed) (local.get $cap)) (then (return)))
    ;; Double until big enough
    (local.set $new_cap (local.get $cap))
    (block $done
      (loop $grow
        (local.set $new_cap (i32.shl (local.get $new_cap) (i32.const 1)))
        (br_if $done (i32.ge_s (local.get $new_cap) (local.get $needed)))
        (br $grow)))
    ;; Allocate and bulk copy with array.copy
    (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $new_cap)))
    (array.copy $CharArray $CharArray
      (local.get $new_data) (i32.const 0)
      (local.get $data) (i32.const 0)
      (struct.get $StringBuffer $len (local.get $sb)))
    (struct.set $StringBuffer $data (local.get $sb) (local.get $new_data)))

  ;; sb_append!: append a String's bytes to the buffer
  (func $sb_append_BANG_ (param $sb anyref) (param $s anyref) (result anyref)
    (local $sb_ref (ref $StringBuffer))
    (local $src (ref $CharArray))
    (local $src_len i32)
    (local $len i32)
    (local $new_len i32)
    (if (ref.is_null (local.get $s)) (then (return (local.get $sb))))
    (if (i32.eqz (ref.test (ref $String) (local.get $s))) (then (return (local.get $sb))))
    (local.set $sb_ref (ref.cast (ref $StringBuffer) (local.get $sb)))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $src_len (array.len (local.get $src)))
    (if (i32.eqz (local.get $src_len)) (then (return (local.get $sb))))
    (local.set $len (struct.get $StringBuffer $len (local.get $sb_ref)))
    (local.set $new_len (i32.add (local.get $len) (local.get $src_len)))
    (call $sb_ensure_capacity (local.get $sb_ref) (local.get $new_len))
    ;; Bulk copy with array.copy
    (array.copy $CharArray $CharArray
      (struct.get $StringBuffer $data (local.get $sb_ref)) (local.get $len)
      (local.get $src) (i32.const 0)
      (local.get $src_len))
    (struct.set $StringBuffer $len (local.get $sb_ref) (local.get $new_len))
    (local.get $sb))

  ;; sb_append_char!: append a single byte to the buffer
  (func $sb_append_char_BANG_ (param $sb anyref) (param $ch i32) (result anyref)
    (local $sb_ref (ref $StringBuffer))
    (local $len i32)
    (local.set $sb_ref (ref.cast (ref $StringBuffer) (local.get $sb)))
    (local.set $len (struct.get $StringBuffer $len (local.get $sb_ref)))
    (call $sb_ensure_capacity (local.get $sb_ref) (i32.add (local.get $len) (i32.const 1)))
    (array.set $CharArray (struct.get $StringBuffer $data (local.get $sb_ref))
      (local.get $len) (local.get $ch))
    (struct.set $StringBuffer $len (local.get $sb_ref) (i32.add (local.get $len) (i32.const 1)))
    (local.get $sb))

  ;; sb->string: convert buffer contents to a String
  (func $sb__GT_string (param $sb anyref) (result anyref)
    (local $sb_ref (ref $StringBuffer))
    (local $len i32)
    (local $result (ref $CharArray))
    (local.set $sb_ref (ref.cast (ref $StringBuffer) (local.get $sb)))
    (local.set $len (struct.get $StringBuffer $len (local.get $sb_ref)))
    (if (result anyref) (i32.eqz (local.get $len))
      (then (struct.new $String (i32.const 3) (i32.const -1) (array.new $CharArray (i32.const 0) (i32.const 0))))
      (else
        (local.set $result (array.new $CharArray (i32.const 0) (local.get $len)))
        (array.copy $CharArray $CharArray
          (local.get $result) (i32.const 0)
          (struct.get $StringBuffer $data (local.get $sb_ref)) (i32.const 0)
          (local.get $len))
        (struct.new $String (i32.const 3) (i32.const -1) (local.get $result)))))
  ;; ==========================================
  ;; pr-str1: EDN-safe printing of a single value
  ;; Unlike str1, this quotes strings, prints nil as the word nil,
  ;; and recursively prints collections.
  ;; ==========================================

  ;; pr_str1: convert any value to its EDN string representation
  (func $pr_str1 (param $val anyref) (result anyref)
    ;; Unwrap WithMeta
    (local.set $val (call $unwrap_meta (local.get $val)))
    ;; nil -> nil literal string
    (if (result anyref) (ref.is_null (local.get $val))
      (then (call $pr_str_literal_nil))
      (else
        ;; String -> quoted with escapes
        (if (result anyref) (ref.test (ref $String) (local.get $val))
          (then (call $pr_str_string (local.get $val)))
          (else
            ;; i31ref (integer) -> decimal string (same as str1)
            (if (result anyref) (ref.test (ref i31) (local.get $val))
              (then (call $int_to_str (i31.get_s (ref.cast (ref i31) (local.get $val)))))
              (else
                ;; Keyword -> :name (same as str1)
                (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 2))
                  (then (call $keyword_to_str (local.get $val)))
                  (else
                    ;; Boolean -> true/false (same as str1)
                    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 14))
                      (then
                        (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (local.get $val)))
                          (then (call $str1_true))
                          (else (call $str1_false))))
                      (else
                        ;; Float -> decimal string (same as str1)
                        (if (result anyref) (ref.test (ref $Float) (local.get $val))
                          (then (call $float_to_str
                            (struct.get $Float $val (ref.cast (ref $Float) (local.get $val)))))
                          (else
                            ;; Vector -> [elem1 elem2 ...]
                            (if (result anyref) (ref.test (ref $Vector) (local.get $val))
                              (then (call $pr_str_vector (local.get $val)))
                              (else
                                ;; HashMap/ArrayMap -> {:k1 v1, :k2 v2}
                                (if (result anyref) (i32.or (i32.eq (call $type_tag (local.get $val)) (i32.const 8)) (i32.eq (call $type_tag (local.get $val)) (i32.const 19)))
                                  (then (call $pr_str_map (local.get $val)))
                                  (else
                                    ;; HashSet -> #{elem1 elem2}
                                    (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 9))
                                      (then (call $pr_str_set (local.get $val)))
                                      (else
                                        ;; Cons (list) -> (elem1 elem2 ...)
                                        (if (result anyref) (ref.test (ref $Cons) (local.get $val))
                                          (then (call $pr_str_list (local.get $val)))
                                          (else
                                            ;; Symbol -> ns/name or just name
                                            (if (result anyref) (i32.eq (call $type_tag (local.get $val)) (i32.const 4))
                                              (then (call $symbol_to_str (local.get $val)))
                                              (else
                                                ;; LazySeq -> realize and print as list
                                                (if (result anyref) (ref.test (ref $LazySeq) (local.get $val))
                                                  (then (call $pr_str_list (call $seq (local.get $val))))
                                                  (else
                                                    ;; VectorSeq -> print as list
                                                    (if (result anyref) (ref.test (ref $VectorSeq) (local.get $val))
                                                      (then (call $pr_str_vectorseq (local.get $val)))
                                                      (else
                                                        ;; Unknown -> nil placeholder
                                                        (call $pr_str_literal_nil))))))))))))))))))))))))))))

  ;; pr_str_literal_nil: return the 3-char string nil
  (func $pr_str_literal_nil (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 3)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 110))  ;; 'n'
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 105))  ;; 'i'
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 108))  ;; 'l'
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; pr_str_string: quote a string with escape sequences
  ;; hello -> backslash-quoted hello, handles backslash, quote, newline, tab
  (func $pr_str_string (param $s anyref) (result anyref)
    (local $src (ref $CharArray))
    (local $src_len i32)
    (local $i i32)
    (local $ch i32)
    (local $extra i32)
    (local $dst (ref $CharArray))
    (local $dst_len i32)
    (local $j i32)
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $src_len (array.len (local.get $src)))
    ;; First pass: count extra chars needed for escaping
    (local.set $extra (i32.const 0))
    (local.set $i (i32.const 0))
    (block $count_done
      (loop $count_loop
        (br_if $count_done (i32.ge_s (local.get $i) (local.get $src_len)))
        (local.set $ch (array.get_u $CharArray (local.get $src) (local.get $i)))
        ;; Count extra char for escapable chars (backslash, quote, newline, tab)
        (if (i32.or (i32.or (i32.eq (local.get $ch) (i32.const 92))   ;; backslash
                            (i32.eq (local.get $ch) (i32.const 34)))  ;; quote
                    (i32.or (i32.eq (local.get $ch) (i32.const 10))   ;; newline
                            (i32.eq (local.get $ch) (i32.const 9))))  ;; tab
          (then (local.set $extra (i32.add (local.get $extra) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $count_loop)))
    ;; Allocate: src_len + extra + 2 (for surrounding quotes)
    (local.set $dst_len (i32.add (i32.add (local.get $src_len) (local.get $extra)) (i32.const 2)))
    (local.set $dst (array.new $CharArray (i32.const 0) (local.get $dst_len)))
    ;; Opening quote
    (array.set $CharArray (local.get $dst) (i32.const 0) (i32.const 34))
    ;; Second pass: copy with escaping
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 1))
    (block $copy_done
      (loop $copy_loop
        (br_if $copy_done (i32.ge_s (local.get $i) (local.get $src_len)))
        (local.set $ch (array.get_u $CharArray (local.get $src) (local.get $i)))
        ;; Check for special chars
        (if (i32.eq (local.get $ch) (i32.const 92))  ;; backslash
          (then
            (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
            (local.set $j (i32.add (local.get $j) (i32.const 1))))
          (else (if (i32.eq (local.get $ch) (i32.const 34))  ;; quote
            (then
              (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
              (local.set $j (i32.add (local.get $j) (i32.const 1)))
              (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 34))
              (local.set $j (i32.add (local.get $j) (i32.const 1))))
            (else (if (i32.eq (local.get $ch) (i32.const 10))  ;; newline
              (then
                (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 110))  ;; 'n'
                (local.set $j (i32.add (local.get $j) (i32.const 1))))
              (else (if (i32.eq (local.get $ch) (i32.const 9))  ;; tab
                (then
                  (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 92))
                  (local.set $j (i32.add (local.get $j) (i32.const 1)))
                  (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 116))  ;; 't'
                  (local.set $j (i32.add (local.get $j) (i32.const 1))))
                (else
                  ;; Regular char
                  (array.set $CharArray (local.get $dst) (local.get $j) (local.get $ch))
                  (local.set $j (i32.add (local.get $j) (i32.const 1)))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $copy_loop)))
    ;; Closing quote
    (array.set $CharArray (local.get $dst) (local.get $j) (i32.const 34))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $dst)))

  ;; pr_str_vector: format vector as [elem1 elem2 ...]
  (func $pr_str_vector (param $v anyref) (result anyref)
    (local $vec (ref $Vector))
    (local $cnt i32)
    (local $i i32)
    (local $result anyref)
    (local.set $vec (ref.cast (ref $Vector) (local.get $v)))
    (local.set $cnt (struct.get $Vector $count (local.get $vec)))
    ;; Start with open bracket
    (local.set $result (call $pr_str_char (i32.const 91)))  ;; '['
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $cnt)))
        ;; Add space separator (not before first)
        (if (i32.gt_s (local.get $i) (i32.const 0))
          (then (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $v) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Close with bracket
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 93))))

  ;; pr_str_list: format cons list as (elem1 elem2 ...)
  (func $pr_str_list (param $lst anyref) (result anyref)
    (local $result anyref)
    (local $current anyref)
    (local $first i32)
    (local.set $result (call $pr_str_char (i32.const 40)))  ;; '('
    (local.set $current (local.get $lst))
    (local.set $first (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $current)))
        (br_if $done (i32.eqz (ref.test (ref $Cons) (local.get $current))))
        ;; Add space separator (not before first)
        (if (local.get $first)
          (then (local.set $first (i32.const 0)))
          (else (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $current))))))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $loop)))
    ;; Close with paren
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 41))))

  ;; pr_str_vectorseq: format VectorSeq as (elem1 elem2 ...)
  (func $pr_str_vectorseq (param $vs anyref) (result anyref)
    (local $result anyref)
    (local $vseq (ref $VectorSeq))
    (local $vec anyref)
    (local $i i32)
    (local $count i32)
    (local.set $vseq (ref.cast (ref $VectorSeq) (local.get $vs)))
    (local.set $vec (struct.get $VectorSeq $vec (local.get $vseq)))
    (local.set $i (struct.get $VectorSeq $offset (local.get $vseq)))
    (local.set $count (call $vector_count (local.get $vec)))
    (local.set $result (call $pr_str_char (i32.const 40)))  ;; '('
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        ;; Add space separator (not before first)
        (if (i32.gt_s (local.get $i) (struct.get $VectorSeq $offset (local.get $vseq)))
          (then (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $vec) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Close with paren
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 41))))

  ;; pr_str_map: format map as {:k1 v1, :k2 v2}
  (func $pr_str_map (param $m anyref) (result anyref)
    (local $result anyref)
    (local $entries anyref)
    (local $entry anyref)
    (local $first i32)
    (local.set $result (call $pr_str_char (i32.const 123)))  ;; '{'
    ;; seq on map gives cons list of [k v] vectors
    (local.set $entries (call $seq (local.get $m)))
    (local.set $first (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $entries)))
        (br_if $done (i32.eqz (ref.test (ref $Cons) (local.get $entries))))
        ;; Add comma-space separator (not before first)
        (if (local.get $first)
          (then (local.set $first (i32.const 0)))
          (else (local.set $result (call $str_concat (local.get $result)
            (call $pr_str_2char (i32.const 44) (i32.const 32))))))  ;; comma-space
        ;; Each entry is a [k v] vector
        (local.set $entry (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $entries))))
        ;; key
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $entry) (i32.const 0)))))
        ;; space
        (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))
        ;; value
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (call $vector_nth (local.get $entry) (i32.const 1)))))
        (local.set $entries (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $entries))))
        (br $loop)))
    ;; Close with brace
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 125))))

  ;; pr_str_set: format set as #{elem1 elem2}
  (func $pr_str_set (param $s anyref) (result anyref)
    (local $result anyref)
    (local $entries anyref)
    (local $first i32)
    ;; Start with hash-brace
    (local.set $result (call $pr_str_2char (i32.const 35) (i32.const 123)))  ;; hash-brace
    ;; seq on set gives cons list of elements
    (local.set $entries (call $seq (local.get $s)))
    (local.set $first (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $entries)))
        (br_if $done (i32.eqz (ref.test (ref $Cons) (local.get $entries))))
        ;; Add space separator (not before first)
        (if (local.get $first)
          (then (local.set $first (i32.const 0)))
          (else (local.set $result (call $str_concat (local.get $result) (call $pr_str_char (i32.const 32))))))
        ;; Add pr-str of element
        (local.set $result (call $str_concat (local.get $result)
          (call $pr_str1 (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $entries))))))
        (local.set $entries (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $entries))))
        (br $loop)))
    ;; Close with brace
    (call $str_concat (local.get $result) (call $pr_str_char (i32.const 125))))

  ;; pr_str_char: make single-char string from ASCII code
  (func $pr_str_char (param $ch i32) (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $data) (i32.const 0) (local.get $ch))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))

  ;; pr_str_2char: make 2-char string from two ASCII codes
  (func $pr_str_2char (param $c1 i32) (param $c2 i32) (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 2)))
    (array.set $CharArray (local.get $data) (i32.const 0) (local.get $c1))
    (array.set $CharArray (local.get $data) (i32.const 1) (local.get $c2))
    (struct.new $String (i32.const 3) (i32.const -1) (local.get $data)))


  ;; Globals
  (global $_AMP_env (mut anyref) (ref.null none))
  (global $_AMP_form (mut anyref) (ref.null none))
  (global $__lifted_fn26 (mut anyref) (ref.null none))
  (global $__lifted_fn27 (mut anyref) (ref.null none))
  (global $__lifted_fn38 (mut anyref) (ref.null none))
  (global $__lifted_fn42 (mut anyref) (ref.null none))
  (global $global_hierarchy (mut anyref) (ref.null none))
  (global $__lifted_fn69 (mut anyref) (ref.null none))
  (global $__lifted_fn81 (mut anyref) (ref.null none))
  (global $__lifted_fn89 (mut anyref) (ref.null none))
  (global $__lifted_fn90 (mut anyref) (ref.null none))
  (global $__lifted_fn91 (mut anyref) (ref.null none))
  (global $__lifted_fn92 (mut anyref) (ref.null none))
  (global $max_int (mut anyref) (ref.null none))
  (global $min_int (mut anyref) (ref.null none))
  (global $all_ones_int (mut anyref) (ref.null none))
  (global $max_double (mut anyref) (ref.null none))
  (global $min_double (mut anyref) (ref.null none))
  (global $_AMP_ (mut anyref) (ref.null none))
  (global $case_STAR_ (mut anyref) (ref.null none))
  (global $new (mut anyref) (ref.null none))
  (global $_DOT_ (mut anyref) (ref.null none))
  (global $catch (mut anyref) (ref.null none))
  (global $deftype_STAR_ (mut anyref) (ref.null none))
  (global $finally (mut anyref) (ref.null none))
  (global $fn_STAR_ (mut anyref) (ref.null none))
  (global $let_STAR_ (mut anyref) (ref.null none))
  (global $letfn_STAR_ (mut anyref) (ref.null none))
  (global $loop_STAR_ (mut anyref) (ref.null none))
  (global $throw (mut anyref) (ref.null none))
  (global $try (mut anyref) (ref.null none))
  (global $var (mut anyref) (ref.null none))
  (global $_STAR_assert_STAR_ (mut anyref) (ref.null none))
  (global $full_width_checker_pos (mut anyref) (ref.null none))
  (global $full_width_checker_neg (mut anyref) (ref.null none))
  (global $Object (mut anyref) (ref.null none))
  (global $String (mut anyref) (ref.null none))
  (global $clojure_DOT_lang_DOT_BigInt (mut anyref) (ref.null none))
  (global $clojure_DOT_lang_DOT_MapEntry (mut anyref) (ref.null none))
  (global $create (mut anyref) (ref.null none))
  (global $clojure_DOT_lang_DOT_IPending (mut anyref) (ref.null none))
  (global $clojure_DOT_lang_DOT_IReduce (mut anyref) (ref.null none))
  (global $UP (mut anyref) (ref.null none))
  (global $HALF_UP (mut anyref) (ref.null none))
  (global $CEILING (mut anyref) (ref.null none))
  (global $FLOOR (mut anyref) (ref.null none))
  (global $__lifted_fn105 (mut anyref) (ref.null none))
  (global $__lifted_fn107 (mut anyref) (ref.null none))
  (global $__lifted_fn108 (mut anyref) (ref.null none))
  (global $__builtin_bit_shift_left (mut anyref) (ref.null none))
  (global $__builtin_dec (mut anyref) (ref.null none))
  (global $__builtin_bit_xor (mut anyref) (ref.null none))
  (global $__builtin_conj_BANG_ (mut anyref) (ref.null none))
  (global $__builtin_conj (mut anyref) (ref.null none))
  (global $__builtin_assoc_BANG_ (mut anyref) (ref.null none))
  (global $__builtin_persistent_BANG_ (mut anyref) (ref.null none))
  (global $__builtin_bit_and (mut anyref) (ref.null none))
  (global $__builtin_bit_or (mut anyref) (ref.null none))
  (global $__builtin_bit_not (mut anyref) (ref.null none))
  (global $__builtin_assoc (mut anyref) (ref.null none))
  (global $__builtin_transient (mut anyref) (ref.null none))
  (global $__builtin_compare (mut anyref) (ref.null none))
  (global $__fn_comp (mut anyref) (ref.null none))
  (global $__fn__STAR_ (mut anyref) (ref.null none))
  (global $__fn_min (mut anyref) (ref.null none))
  (global $__fn_identity (mut anyref) (ref.null none))
  (global $__fn_sorted_set_conj (mut anyref) (ref.null none))
  (global $__fn_concat (mut anyref) (ref.null none))
  (global $__fn__MINUS_ (mut anyref) (ref.null none))
  (global $__fn_list_STAR_ (mut anyref) (ref.null none))
  (global $__fn_merge (mut anyref) (ref.null none))
  (global $__fn__PLUS_ (mut anyref) (ref.null none))
  (global $__fn_max (mut anyref) (ref.null none))
  (global $__proto__assoc_8_closure (mut anyref) (ref.null none))
  (global $__proto__count_7_closure (mut anyref) (ref.null none))
  (global $__proto__lookup_0_closure (mut anyref) (ref.null none))
  (global $__proto__lookup_20_closure (mut anyref) (ref.null none))
  (global $__proto__seq_9_closure (mut anyref) (ref.null none))
  (global $__proto__reduce_init_8_closure (mut anyref) (ref.null none))
  (global $__proto__seq_20_closure (mut anyref) (ref.null none))
  (global $__proto__seq_12_closure (mut anyref) (ref.null none))
  (global $__proto__reduce_init_0_closure (mut anyref) (ref.null none))
  (global $__proto__seq_0_closure (mut anyref) (ref.null none))
  (global $__proto__conj_20_closure (mut anyref) (ref.null none))
  (global $__proto__count_3_closure (mut anyref) (ref.null none))
  (global $__proto__count_9_closure (mut anyref) (ref.null none))
  (global $__proto__seq_6_closure (mut anyref) (ref.null none))
  (global $__proto__conj_9_closure (mut anyref) (ref.null none))
  (global $__proto__count_21_closure (mut anyref) (ref.null none))
  (global $__proto__seq_8_closure (mut anyref) (ref.null none))
  (global $__proto__conj_8_closure (mut anyref) (ref.null none))
  (global $__proto__count_12_closure (mut anyref) (ref.null none))
  (global $__proto__reduce_init_6_closure (mut anyref) (ref.null none))
  (global $__proto__count_0_closure (mut anyref) (ref.null none))
  (global $__proto__conj_21_closure (mut anyref) (ref.null none))
  (global $__proto__assoc_20_closure (mut anyref) (ref.null none))
  (global $__proto__seq_3_closure (mut anyref) (ref.null none))
  (global $__proto__conj_6_closure (mut anyref) (ref.null none))
  (global $__proto__reduce_init_9_closure (mut anyref) (ref.null none))
  (global $__proto__count_20_closure (mut anyref) (ref.null none))
  (global $__proto__reduce_init_7_closure (mut anyref) (ref.null none))
  (global $__proto__seq_7_closure (mut anyref) (ref.null none))
  (global $__proto__lookup_7_closure (mut anyref) (ref.null none))
  (global $__proto__count_6_closure (mut anyref) (ref.null none))
  (global $__proto__count_8_closure (mut anyref) (ref.null none))
  (global $__proto__seq_21_closure (mut anyref) (ref.null none))
  (global $__proto__assoc_7_closure (mut anyref) (ref.null none))
  (global $__proto__conj_0_closure (mut anyref) (ref.null none))
  (global $__proto__lookup_8_closure (mut anyref) (ref.null none))
  (global $__proto__reduce_init_12_closure (mut anyref) (ref.null none))
  (global $__proto__conj_7_closure (mut anyref) (ref.null none))
  (global $__dispatch_table__seq (mut anyref) (ref.null none))
  (global $__dispatch_table__count (mut anyref) (ref.null none))
  (global $__dispatch_table__conj (mut anyref) (ref.null none))
  (global $__dispatch_table__lookup (mut anyref) (ref.null none))
  (global $__dispatch_table__assoc (mut anyref) (ref.null none))
  (global $__dispatch_table__reduce_init (mut anyref) (ref.null none))
  (global $__str_0 (mut anyref) (ref.null none))
  (global $__str_1 (mut anyref) (ref.null none))
  (global $__str_2 (mut anyref) (ref.null none))
  (global $__str_3 (mut anyref) (ref.null none))
  (global $__str_4 (mut anyref) (ref.null none))
  (global $__str_5 (mut anyref) (ref.null none))
  (global $__str_6 (mut anyref) (ref.null none))
  (global $__str_7 (mut anyref) (ref.null none))
  (global $__str_8 (mut anyref) (ref.null none))
  (global $__str_9 (mut anyref) (ref.null none))
  (global $__str_10 (mut anyref) (ref.null none))
  (global $__str_11 (mut anyref) (ref.null none))
  (global $__str_12 (mut anyref) (ref.null none))
  (global $__str_13 (mut anyref) (ref.null none))
  (global $__str_14 (mut anyref) (ref.null none))
  (global $__str_15 (mut anyref) (ref.null none))
  (global $__str_16 (mut anyref) (ref.null none))
  (global $__str_17 (mut anyref) (ref.null none))
  (global $__str_18 (mut anyref) (ref.null none))
  (global $__str_19 (mut anyref) (ref.null none))
  (global $__str_20 (mut anyref) (ref.null none))
  (global $__str_21 (mut anyref) (ref.null none))
  (global $__str_22 (mut anyref) (ref.null none))
  (global $__str_23 (mut anyref) (ref.null none))
  (global $__str_24 (mut anyref) (ref.null none))
  (global $__str_25 (mut anyref) (ref.null none))
  (global $__str_26 (mut anyref) (ref.null none))
  (global $__str_27 (mut anyref) (ref.null none))
  (global $__str_28 (mut anyref) (ref.null none))
  (global $__str_29 (mut anyref) (ref.null none))
  (global $__str_30 (mut anyref) (ref.null none))
  (global $__str_31 (mut anyref) (ref.null none))
  (global $__str_32 (mut anyref) (ref.null none))
  (global $__str_33 (mut anyref) (ref.null none))
  (global $__str_34 (mut anyref) (ref.null none))
  (global $__str_35 (mut anyref) (ref.null none))
  (global $__str_36 (mut anyref) (ref.null none))
  (global $__str_37 (mut anyref) (ref.null none))
  (global $__str_38 (mut anyref) (ref.null none))
  (global $__str_39 (mut anyref) (ref.null none))
  (global $__str_40 (mut anyref) (ref.null none))
  (global $__str_41 (mut anyref) (ref.null none))
  (global $__str_42 (mut anyref) (ref.null none))
  (global $__str_43 (mut anyref) (ref.null none))
  (global $__str_44 (mut anyref) (ref.null none))
  (global $__str_45 (mut anyref) (ref.null none))
  (global $__str_46 (mut anyref) (ref.null none))
  (global $__str_47 (mut anyref) (ref.null none))
  (global $__str_48 (mut anyref) (ref.null none))
  (global $__str_49 (mut anyref) (ref.null none))
  (global $__str_50 (mut anyref) (ref.null none))
  (global $__str_51 (mut anyref) (ref.null none))
  (global $__str_52 (mut anyref) (ref.null none))
  (global $__str_53 (mut anyref) (ref.null none))
  (global $__str_54 (mut anyref) (ref.null none))
  (global $__str_55 (mut anyref) (ref.null none))
  (global $__str_56 (mut anyref) (ref.null none))
  (global $__str_57 (mut anyref) (ref.null none))
  (global $__str_58 (mut anyref) (ref.null none))
  (global $__sym_0 (mut anyref) (ref.null none))
  (global $__sym_1 (mut anyref) (ref.null none))
  (global $__sym_2 (mut anyref) (ref.null none))
  (global $__sym_3 (mut anyref) (ref.null none))
  (global $__sym_4 (mut anyref) (ref.null none))
  (global $__sym_5 (mut anyref) (ref.null none))
  (global $__sym_6 (mut anyref) (ref.null none))
  (global $__sym_7 (mut anyref) (ref.null none))
  (global $__sym_8 (mut anyref) (ref.null none))
  (global $__sym_9 (mut anyref) (ref.null none))
  (global $__sym_10 (mut anyref) (ref.null none))
  (global $__sym_11 (mut anyref) (ref.null none))
  (global $__sym_12 (mut anyref) (ref.null none))
  (global $__sym_13 (mut anyref) (ref.null none))

  ;; Data segments for constant byte arrays
  (data $__str_data "\43\61\6e\6e\6f\74\20\64\65\72\69\76\65\20\74\61\67\20\66\72\6f\6d\20\69\74\73\65\6c\66\43\79\63\6c\69\63\20\64\65\72\69\76\61\74\69\6f\6e\0a\20\2d\2b\30\78\58\65\45\2e\0d\09\2c\31\32\33\34\35\36\37\38\39\3b\22\5c\6e\74\28\29\5b\5d\7b\7d\6e\69\6c\74\72\75\65\66\61\6c\73\65\3a\23\61\7a\41\5a\5f\5e\64\44\77\57\73\53\24\2a\3f\7c\52\65\74\75\72\6e\73\20\5b\73\74\61\72\74\20\65\6e\64\5d\20\6f\66\20\74\68\65\20\66\69\72\73\74\20\6d\61\74\63\68\2c\20\6f\72\20\6e\69\6c\20\69\66\20\6e\6f\20\6d\61\74\63\68\2e\52\65\74\75\72\6e\73\20\5b\73\74\61\72\74\20\65\6e\64\5d\20\6f\66\20\74\68\65\20\66\69\72\73\74\20\6d\61\74\63\68\20\69\6e\20\73\2c\20\6f\72\20\6e\69\6c\2e")
  (data $__kw_data "\78\66\2f\63\6f\6d\70\6c\65\74\65\70\61\72\65\6e\74\73\61\6e\63\65\73\74\6f\72\73\64\65\73\63\65\6e\64\61\6e\74\73\74\61\67\70\61\72\65\6e\74\64\65\66\61\75\6c\74\77\6f\6a\2f\73\65\6e\74\69\6e\65\6c\77\6f\6a\2f\6e\6f\74\2d\66\6f\75\6e\64\72\61\6e\67\65\63\68\61\72\6c\69\74\63\6c\61\73\73\2d\62\75\69\6c\74\69\6e\64\69\67\69\74\6e\6f\6e\2d\64\69\67\69\74\77\6f\72\64\6e\6f\6e\2d\77\6f\72\64\73\70\61\63\65\6e\6f\6e\2d\73\70\61\63\65\64\6f\74\61\6e\63\68\6f\72\73\74\61\72\74\65\6e\64\63\6c\61\73\73\73\74\61\72\70\6c\75\73\6f\70\74\73\65\71\61\6c\74\67\72\6f\75\70")
  (data $__sym_data "\26\63\61\73\65\2a\6e\65\77\2e\63\61\74\63\68\64\65\66\74\79\70\65\2a\66\69\6e\61\6c\6c\79\66\6e\2a\6c\65\74\2a\6c\65\74\66\6e\2a\6c\6f\6f\70\2a\74\68\72\6f\77\74\72\79\76\61\72")

  ;; Closure function declarations
  (elem declare func $__proto__seq_0 $__proto__seq_6 $__proto__seq_7 $__proto__seq_8 $__proto__seq_9 $__proto__seq_3 $__proto__seq_12 $__proto__count_0 $__proto__count_6 $__proto__count_7 $__proto__count_8 $__proto__count_9 $__proto__count_3 $__proto__count_12 $__proto__conj_0 $__proto__conj_6 $__proto__conj_7 $__proto__conj_8 $__proto__conj_9 $__proto__lookup_0 $__proto__lookup_8 $__proto__lookup_7 $__proto__assoc_8 $__proto__assoc_7 $__proto__reduce_init_0 $__proto__reduce_init_6 $__proto__reduce_init_7 $__proto__reduce_init_8 $__proto__reduce_init_9 $__proto__reduce_init_12 $closure1 $closure3 $closure2 $closure4 $closure5 $closure6 $closure8 $closure7 $closure9 $closure11 $closure10 $closure13 $closure12 $closure14 $closure15 $closure16 $closure17 $closure19 $closure18 $closure21 $closure20 $closure23 $closure22 $closure25 $closure24 $fn26 $closure29 $closure28 $fn27 $closure30 $closure32 $closure34 $closure33 $closure31 $closure36 $closure35 $closure37 $fn38 $closure39 $closure40 $closure41 $fn42 $closure43 $closure44 $closure45 $closure46 $closure47 $anon_multi48_arity0 $anon_multi48_arity1 $anon_multi48_arity2 $anon_multi48_arity3 $anon_multi48_dispatch $closure49 $anon_multi50_arity0 $anon_multi50_arity1 $anon_multi50_arity2 $anon_multi50_arity3 $anon_multi50_dispatch $anon_multi51_arity0 $anon_multi51_arity1 $anon_multi51_arity2 $anon_multi51_dispatch $anon_multi52_arity0 $anon_multi52_arity1 $anon_multi52_dispatch $anon_multi53_arity1 $anon_multi53_arity2 $anon_multi53_dispatch $anon_multi54_arity1 $anon_multi54_arity2 $anon_multi54_dispatch $anon_multi55_arity1 $anon_multi55_arity2 $anon_multi55_dispatch $anon_multi56_arity1 $anon_multi56_arity2 $anon_multi56_dispatch $closure57 $closure58 $closure59 $closure60 $closure61 $closure62 $closure63 $closure64 $closure65 $closure66 $closure67 $closure68 $closure70 $fn69 $closure71 $closure72 $closure73 $closure74 $anon_multi76_arity0 $anon_multi76_arity1 $anon_multi76_arity2 $anon_multi76_dispatch $closure75 $closure77 $closure78 $closure79 $closure80 $fn81 $anon_multi82_arity1 $anon_multi82_arity2 $anon_multi82_arity3 $anon_multi82_dispatch $anon_multi83_arity1 $anon_multi83_arity2 $anon_multi83_arity3 $anon_multi83_dispatch $anon_multi84_arity1 $anon_multi84_arity2 $anon_multi84_arity3 $anon_multi84_dispatch $anon_multi85_arity1 $anon_multi85_arity2 $anon_multi85_arity3 $anon_multi85_dispatch $anon_multi86_arity1 $anon_multi86_arity2 $anon_multi86_arity3 $anon_multi86_dispatch $anon_multi87_arity1 $anon_multi87_arity2 $anon_multi87_arity3 $anon_multi87_dispatch $anon_multi88_arity1 $anon_multi88_arity2 $anon_multi88_arity3 $anon_multi88_dispatch $fn89 $fn90 $fn91 $fn92 $anon_multi93_arity1 $anon_multi93_arity2 $anon_multi93_arity3 $anon_multi93_dispatch $anon_multi94_arity2 $anon_multi94_arity3 $anon_multi94_dispatch $anon_multi95_arity3 $anon_multi95_arity4 $anon_multi95_dispatch $closure96 $closure97 $__proto__seq_20 $__proto__count_20 $__proto__lookup_20 $__proto__assoc_20 $__proto__conj_20 $__proto__seq_21 $__proto__count_21 $__proto__conj_21 $closure98 $closure99 $closure100 $closure101 $closure102 $fn105 $closure104 $closure103 $fn107 $closure106 $fn108 $closure109 $closure110 $__proto__seq_0 $__proto__seq_6 $__proto__seq_7 $__proto__seq_8 $__proto__seq_9 $__proto__seq_3 $__proto__seq_12 $__proto__count_0 $__proto__count_6 $__proto__count_7 $__proto__count_8 $__proto__count_9 $__proto__count_3 $__proto__count_12 $__proto__conj_0 $__proto__conj_6 $__proto__conj_7 $__proto__conj_8 $__proto__conj_9 $__proto__lookup_0 $__proto__lookup_8 $__proto__lookup_7 $__proto__assoc_8 $__proto__assoc_7 $__proto__reduce_init_0 $__proto__reduce_init_6 $__proto__reduce_init_7 $__proto__reduce_init_8 $__proto__reduce_init_9 $__proto__reduce_init_12 $closure1 $closure3 $closure2 $closure4 $closure5 $closure6 $closure8 $closure7 $closure9 $closure11 $closure10 $closure13 $closure12 $closure14 $closure15 $closure16 $closure17 $closure19 $closure18 $closure21 $closure20 $closure23 $closure22 $closure25 $closure24 $fn26 $closure29 $closure28 $fn27 $closure30 $closure32 $closure34 $closure33 $closure31 $closure36 $closure35 $closure37 $fn38 $closure39 $closure40 $closure41 $fn42 $closure43 $closure44 $closure45 $closure46 $closure47 $anon_multi48_arity0 $anon_multi48_arity1 $anon_multi48_arity2 $anon_multi48_arity3 $anon_multi48_dispatch $closure49 $anon_multi50_arity0 $anon_multi50_arity1 $anon_multi50_arity2 $anon_multi50_arity3 $anon_multi50_dispatch $anon_multi51_arity0 $anon_multi51_arity1 $anon_multi51_arity2 $anon_multi51_dispatch $anon_multi52_arity0 $anon_multi52_arity1 $anon_multi52_dispatch $anon_multi53_arity1 $anon_multi53_arity2 $anon_multi53_dispatch $anon_multi54_arity1 $anon_multi54_arity2 $anon_multi54_dispatch $anon_multi55_arity1 $anon_multi55_arity2 $anon_multi55_dispatch $anon_multi56_arity1 $anon_multi56_arity2 $anon_multi56_dispatch $closure57 $closure58 $closure59 $closure60 $closure61 $closure62 $closure63 $closure64 $closure65 $closure66 $closure67 $closure68 $closure70 $fn69 $closure71 $closure72 $closure73 $closure74 $anon_multi76_arity0 $anon_multi76_arity1 $anon_multi76_arity2 $anon_multi76_dispatch $closure75 $closure77 $closure78 $closure79 $closure80 $fn81 $anon_multi82_arity1 $anon_multi82_arity2 $anon_multi82_arity3 $anon_multi82_dispatch $anon_multi83_arity1 $anon_multi83_arity2 $anon_multi83_arity3 $anon_multi83_dispatch $anon_multi84_arity1 $anon_multi84_arity2 $anon_multi84_arity3 $anon_multi84_dispatch $anon_multi85_arity1 $anon_multi85_arity2 $anon_multi85_arity3 $anon_multi85_dispatch $anon_multi86_arity1 $anon_multi86_arity2 $anon_multi86_arity3 $anon_multi86_dispatch $anon_multi87_arity1 $anon_multi87_arity2 $anon_multi87_arity3 $anon_multi87_dispatch $anon_multi88_arity1 $anon_multi88_arity2 $anon_multi88_arity3 $anon_multi88_dispatch $fn89 $fn90 $fn91 $fn92 $anon_multi93_arity1 $anon_multi93_arity2 $anon_multi93_arity3 $anon_multi93_dispatch $anon_multi94_arity2 $anon_multi94_arity3 $anon_multi94_dispatch $anon_multi95_arity3 $anon_multi95_arity4 $anon_multi95_dispatch $closure96 $closure97 $__proto__seq_20 $__proto__count_20 $__proto__lookup_20 $__proto__assoc_20 $__proto__conj_20 $__proto__seq_21 $__proto__count_21 $__proto__conj_21 $closure98 $closure99 $closure100 $closure101 $closure102 $fn105 $closure104 $closure103 $fn107 $closure106 $fn108 $closure109 $closure110 $__builtin_bit_shift_left_fn $__builtin_dec_fn $__builtin_bit_xor_fn $__builtin_conj_BANG__fn $__builtin_conj_fn $__builtin_assoc_BANG__fn $__builtin_persistent_BANG__fn $__builtin_bit_and_fn $__builtin_bit_or_fn $__builtin_bit_not_fn $__builtin_assoc_fn $__builtin_transient_fn $__builtin_compare_fn $__fn_comp_dispatch $__fn__STAR__dispatch $__fn_min_dispatch $__fn_identity_wrapper $__fn_sorted_set_conj_wrapper $__fn_concat_dispatch $__fn__MINUS__dispatch $__fn_list_STAR__dispatch $__fn_merge_dispatch $__fn__PLUS__dispatch $__fn_max_dispatch $__proto__assoc_8 $__proto__count_7 $__proto__lookup_0 $__proto__lookup_20 $__proto__seq_9 $__proto__reduce_init_8 $__proto__seq_20 $__proto__seq_12 $__proto__reduce_init_0 $__proto__seq_0 $__proto__conj_20 $__proto__count_3 $__proto__count_9 $__proto__seq_6 $__proto__conj_9 $__proto__count_21 $__proto__seq_8 $__proto__conj_8 $__proto__count_12 $__proto__reduce_init_6 $__proto__count_0 $__proto__conj_21 $__proto__assoc_20 $__proto__seq_3 $__proto__conj_6 $__proto__reduce_init_9 $__proto__count_20 $__proto__reduce_init_7 $__proto__seq_7 $__proto__lookup_7 $__proto__count_6 $__proto__count_8 $__proto__seq_21 $__proto__assoc_7 $__proto__conj_0 $__proto__lookup_8 $__proto__reduce_init_12 $__proto__conj_7)

  ;; User functions
  (func $__init_def__AMP_env (result anyref)
    (ref.null none))

  (func $__init_def__AMP_form (result anyref)
    (ref.null none))

  (func $__proto__seq_0 (type $ClosureFunc1) (param $__env anyref) (param $_ anyref) (result anyref)
    (ref.null none))

  (func $__proto__seq_6 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $__proto__seq_7 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (call $seq (local.get $coll)))

  (func $__proto__seq_8 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (call $seq (local.get $coll)))

  (func $__proto__seq_9 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (call $seq (local.get $coll)))

  (func $__proto__seq_3 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (call $seq (local.get $coll)))

  (func $__proto__seq_12 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (call $seq (local.get $coll)))

  (func $__proto__count_0 (type $ClosureFunc1) (param $__env anyref) (param $_ anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $__proto__count_6 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (ref.i31 (call $count_internal (local.get $coll))))

  (func $__proto__count_7 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (ref.i31 (call $count_internal (local.get $coll))))

  (func $__proto__count_8 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (ref.i31 (call $count_internal (local.get $coll))))

  (func $__proto__count_9 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (ref.i31 (call $count_internal (local.get $coll))))

  (func $__proto__count_3 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (ref.i31 (call $count_internal (local.get $coll))))

  (func $__proto__count_12 (type $ClosureFunc1) (param $__env anyref) (param $coll anyref) (result anyref)
    (ref.i31 (call $count_internal (local.get $coll))))

  (func $__proto__conj_0 (type $ClosureFunc2) (param $__env anyref) (param $_ anyref) (param $val anyref) (result anyref)
    (call $cons (local.get $val) (ref.null none)))

  (func $__proto__conj_6 (type $ClosureFunc2) (param $__env anyref) (param $coll anyref) (param $val anyref) (result anyref)
    (call $cons (local.get $val) (local.get $coll)))

  (func $__proto__conj_7 (type $ClosureFunc2) (param $__env anyref) (param $coll anyref) (param $val anyref) (result anyref)
    (call $conj (local.get $coll) (local.get $val)))

  (func $__proto__conj_8 (type $ClosureFunc2) (param $__env anyref) (param $coll anyref) (param $val anyref) (result anyref)
    (call $conj (local.get $coll) (local.get $val)))

  (func $__proto__conj_9 (type $ClosureFunc2) (param $__env anyref) (param $coll anyref) (param $val anyref) (result anyref)
    (call $conj (local.get $coll) (local.get $val)))

  (func $__proto__lookup_0 (type $ClosureFunc2) (param $__env anyref) (param $_ anyref) (param $key anyref) (result anyref)
    (ref.null none))

  (func $__proto__lookup_8 (type $ClosureFunc2) (param $__env anyref) (param $coll anyref) (param $key anyref) (result anyref)
    (call $hash_map_get (local.get $coll) (local.get $key)))

  (func $__proto__lookup_7 (type $ClosureFunc2) (param $__env anyref) (param $coll anyref) (param $key anyref) (result anyref)
    (call $nth_polymorphic (local.get $coll) (i31.get_s (ref.cast (ref i31) (local.get $key)))))

  (func $__proto__assoc_8 (type $ClosureFunc3) (param $__env anyref) (param $coll anyref) (param $key anyref) (param $val anyref) (result anyref)
    (call $assoc (local.get $coll) (local.get $key) (local.get $val)))

  (func $__proto__assoc_7 (type $ClosureFunc3) (param $__env anyref) (param $coll anyref) (param $key anyref) (param $val anyref) (result anyref)
    (call $assoc (local.get $coll) (local.get $key) (local.get $val)))

  (func $__proto__reduce_init_0 (type $ClosureFunc3) (param $__env anyref) (param $_ anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local.get $init))

  (func $__proto__reduce_init_6 (type $ClosureFunc3) (param $__env anyref) (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (call $reduce (local.get $f) (local.get $init) (local.get $coll)))

  (func $__proto__reduce_init_7 (type $ClosureFunc3) (param $__env anyref) (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (call $reduce (local.get $f) (local.get $init) (local.get $coll)))

  (func $__proto__reduce_init_8 (type $ClosureFunc3) (param $__env anyref) (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (call $reduce (local.get $f) (local.get $init) (local.get $coll)))

  (func $__proto__reduce_init_9 (type $ClosureFunc3) (param $__env anyref) (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (call $reduce (local.get $f) (local.get $init) (local.get $coll)))

  (func $__proto__reduce_init_12 (type $ClosureFunc3) (param $__env anyref) (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (call $reduce (local.get $f) (local.get $init) (local.get $coll)))

  (func $identity_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export_identity (export "identity") (param $x i32) (result i32)
    (call $unbox_i32 (call $identity_internal (ref.i31 (local.get $x)))))

  (func $second_internal (param $coll anyref) (result anyref)
    (call $first (call $rest (local.get $coll))))

  (func $__export_second (export "second") (param $coll i32) (result i32)
    (call $unbox_i32 (call $second_internal (ref.i31 (local.get $coll)))))

  (func $ffirst_internal (param $coll anyref) (result anyref)
    (call $first (call $first (local.get $coll))))

  (func $__export_ffirst (export "ffirst") (param $coll i32) (result i32)
    (call $unbox_i32 (call $ffirst_internal (ref.i31 (local.get $coll)))))

  (func $closure1 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $temp__2 anyref)
    (local $s anyref)
    (block (result anyref) (local.set $temp__2 (call $seq (call $array_get (local.get $__env) (i32.const 0)))) (if (result anyref) (call $truthy (local.get $temp__2)) (then (block (result anyref) (local.set $s (local.get $temp__2)) (call $cons (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (call $first (local.get $s))) (call $map_seq_internal (call $array_get (local.get $__env) (i32.const 1)) (call $rest (local.get $s)))))) (else (ref.null none)))))

  (func $map_seq_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure1) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $f)) (local.get $__tmp_env)))))

  (func $__export_map_seq (export "map-seq") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $map_seq_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $closure3 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $input))))

  (func $closure2 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure2 (i32.const 11) (ref.func $closure3) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env))))

  (func $map_arity1_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure2) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env))))

  (func $__export_map_arity1 (export "map_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $map_arity1_internal (ref.i31 (local.get $f)))))

  (func $map_arity2_internal (param $f anyref) (param $coll anyref) (result anyref)
    (return_call $map_seq_internal (local.get $f) (local.get $coll)))

  (func $__export_map_arity2 (export "map_arity2") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $map_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $closure4 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $s1 anyref)
    (local $s2 anyref)
    (block (result anyref) (local.set $s1 (call $seq (call $array_get (local.get $__env) (i32.const 0)))) (local.set $s2 (call $seq (call $array_get (local.get $__env) (i32.const 1)))) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (local.get $s1)) (then (local.get $s2)) (else (local.get $s1)))) (then (call $cons (call $invoke2 (call $array_get (local.get $__env) (i32.const 2)) (call $first (local.get $s1)) (call $first (local.get $s2))) (call $map_arity3_internal (call $array_get (local.get $__env) (i32.const 2)) (call $rest (local.get $s1)) (call $rest (local.get $s2))))) (else (ref.null none)))))

  (func $map_arity3_internal (param $f anyref) (param $c1 anyref) (param $c2 anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure4) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $c1)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $c2)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $f)) (local.get $__tmp_env)))))

  (func $__export_map_arity3 (export "map_arity3") (param $f i32) (param $c1 i32) (param $c2 i32) (result i32)
    (call $unbox_i32 (call $map_arity3_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $c1)) (ref.i31 (local.get $c2)))))

  (func $closure5 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $s1 anyref)
    (local $s2 anyref)
    (local $s3 anyref)
    (block (result anyref) (local.set $s1 (call $seq (call $array_get (local.get $__env) (i32.const 0)))) (local.set $s2 (call $seq (call $array_get (local.get $__env) (i32.const 1)))) (local.set $s3 (call $seq (call $array_get (local.get $__env) (i32.const 2)))) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (local.get $s1)) (then (local.get $s2)) (else (local.get $s1)))) (then (local.get $s3)) (else (if (result anyref) (call $truthy (local.get $s1)) (then (local.get $s2)) (else (local.get $s1)))))) (then (call $cons (call $invoke3 (call $array_get (local.get $__env) (i32.const 3)) (call $first (local.get $s1)) (call $first (local.get $s2)) (call $first (local.get $s3))) (call $map_arity4_internal (call $array_get (local.get $__env) (i32.const 3)) (call $rest (local.get $s1)) (call $rest (local.get $s2)) (call $rest (local.get $s3))))) (else (ref.null none)))))

  (func $map_arity4_internal (param $f anyref) (param $c1 anyref) (param $c2 anyref) (param $c3 anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure5) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 4))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $c1)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $c2)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $c3)) (call $array_set (local.get $__tmp_env) (i32.const 3) (local.get $f)) (local.get $__tmp_env)))))

  (func $__export_map_arity4 (export "map_arity4") (param $f i32) (param $c1 i32) (param $c2 i32) (param $c3 i32) (result i32)
    (call $unbox_i32 (call $map_arity4_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $c1)) (ref.i31 (local.get $c2)) (ref.i31 (local.get $c3)))))

  (func $closure6 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $temp__4 anyref)
    (local $s anyref)
    (local $x anyref)
    (block (result anyref) (local.set $temp__4 (call $seq (call $array_get (local.get $__env) (i32.const 0)))) (if (result anyref) (call $truthy (local.get $temp__4)) (then (block (result anyref) (local.set $s (local.get $temp__4)) (block (result anyref) (local.set $x (call $first (local.get $s))) (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))) (then (call $cons (local.get $x) (call $filter_seq_internal (call $array_get (local.get $__env) (i32.const 1)) (call $rest (local.get $s))))) (else (return_call $filter_seq_internal (call $array_get (local.get $__env) (i32.const 1)) (call $rest (local.get $s)))))))) (else (ref.null none)))))

  (func $filter_seq_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure6) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $pred)) (local.get $__tmp_env)))))

  (func $__export_filter_seq (export "filter-seq") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $filter_seq_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $closure8 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $input))) (then (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (local.get $input))) (else (local.get $result))))

  (func $closure7 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure2 (i32.const 11) (ref.func $closure8) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env))))

  (func $filter_arity1_internal (param $pred anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure7) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $pred)) (local.get $__tmp_env))))

  (func $__export_filter_arity1 (export "filter_arity1") (param $pred i32) (result i32)
    (call $unbox_i32 (call $filter_arity1_internal (ref.i31 (local.get $pred)))))

  (func $filter_arity2_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (return_call $filter_seq_internal (local.get $pred) (local.get $coll)))

  (func $__export_filter_arity2 (export "filter_arity2") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $filter_arity2_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $closure9 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $temp__6 anyref)
    (local $s anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (call $array_get (local.get $__env) (i32.const 1)) (ref.i31 (i32.const 0))))) (then (block (result anyref) (local.set $temp__6 (call $seq (call $array_get (local.get $__env) (i32.const 0)))) (if (result anyref) (call $truthy (local.get $temp__6)) (then (block (result anyref) (local.set $s (local.get $temp__6)) (call $cons (call $first (local.get $s)) (call $take_seq_internal (call $dec (call $array_get (local.get $__env) (i32.const 1))) (call $rest (local.get $s)))))) (else (ref.null none))))) (else (ref.null none))))

  (func $take_seq_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure9) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $n)) (local.get $__tmp_env)))))

  (func $__export_take_seq (export "take-seq") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $take_seq_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $closure11 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (call $deref (call $array_get (local.get $__env) (i32.const 0))) (ref.i31 (i32.const 0))))) (then (block (result anyref) (drop (call $swap_BANG_ (call $array_get (local.get $__env) (i32.const 0)) (global.get $__builtin_dec))) (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (local.get $input)))) (else (local.get $result))))

  (func $closure10 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $remaining anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $remaining (call $atom (call $array_get (local.get $__env) (i32.const 0)))) (struct.new $Closure2 (i32.const 11) (ref.func $closure11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $remaining)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env)))))

  (func $take_arity1_internal (param $n anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure10) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $n)) (local.get $__tmp_env))))

  (func $__export_take_arity1 (export "take_arity1") (param $n i32) (result i32)
    (call $unbox_i32 (call $take_arity1_internal (ref.i31 (local.get $n)))))

  (func $take_arity2_internal (param $n anyref) (param $coll anyref) (result anyref)
    (return_call $take_seq_internal (local.get $n) (local.get $coll)))

  (func $__export_take_arity2 (export "take_arity2") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $take_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $closure13 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (call $deref (call $array_get (local.get $__env) (i32.const 0))) (ref.i31 (i32.const 0))))) (then (block (result anyref) (drop (call $swap_BANG_ (call $array_get (local.get $__env) (i32.const 0)) (global.get $__builtin_dec))) (local.get $result))) (else (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (local.get $input)))))

  (func $closure12 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $remaining anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $remaining (call $atom (call $array_get (local.get $__env) (i32.const 0)))) (struct.new $Closure2 (i32.const 11) (ref.func $closure13) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $remaining)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env)))))

  (func $drop_arity1_internal (param $n anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure12) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $n)) (local.get $__tmp_env))))

  (func $__export_drop_arity1 (export "drop_arity1") (param $n i32) (result i32)
    (call $unbox_i32 (call $drop_arity1_internal (ref.i31 (local.get $n)))))

  (func $drop_arity2_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $remaining anyref)
    (local $curr anyref)
    (block (result anyref) (local.set $remaining (local.get $n)) (local.set $curr (local.get $coll)) (loop $loop0 (result anyref) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $cmp_le (local.get $remaining) (ref.i31 (i32.const 0)))) (then (call $cmp_le (local.get $remaining) (ref.i31 (i32.const 0)))) (else (call $nil_QMARK_ (call $seq (local.get $curr)))))) (then (local.get $curr)) (else (call $dec (local.get $remaining))
      (call $rest (local.get $curr))
      (local.set $curr)
      (local.set $remaining)
      (br $loop0))))))

  (func $__export_drop_arity2 (export "drop_arity2") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $drop_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $nth_list_internal (param $coll anyref) (param $n anyref) (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $zero_QMARK_ (local.get $n)))) (then (call $first (local.get $coll))) (else (return_call $nth_list_internal (call $rest (local.get $coll)) (call $dec (local.get $n))))))

  (func $__export_nth_list (export "nth-list") (param $coll i32) (param $n i32) (result i32)
    (call $unbox_i32 (call $nth_list_internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $n)))))

  (func $length_internal (param $coll anyref) (result anyref)
    (if (result anyref) (call $truthy (call $seq (local.get $coll))) (then (call $inc (call $length_internal (call $rest (local.get $coll))))) (else (ref.i31 (i32.const 0)))))

  (func $__export_length (export "length") (param $coll i32) (result i32)
    (call $unbox_i32 (call $length_internal (ref.i31 (local.get $coll)))))

  (func $concat_list_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (call $truthy (call $seq (local.get $a))) (then (call $cons (call $first (local.get $a)) (call $concat_list_internal (call $rest (local.get $a)) (local.get $b)))) (else (local.get $b))))

  (func $__export_concat_list (export "concat-list") (param $a i32) (param $b i32) (result i32)
    (call $unbox_i32 (call $concat_list_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b)))))

  (func $last_internal (param $coll anyref) (result anyref)
    (if (result anyref) (call $truthy (call $seq (call $rest (local.get $coll)))) (then (return_call $last_internal (call $rest (local.get $coll)))) (else (call $first (local.get $coll)))))

  (func $__export_last (export "last") (param $coll i32) (result i32)
    (call $unbox_i32 (call $last_internal (ref.i31 (local.get $coll)))))

  (func $butlast_internal (param $coll anyref) (result anyref)
    (if (result anyref) (call $truthy (call $seq (call $rest (local.get $coll)))) (then (call $cons (call $first (local.get $coll)) (call $butlast_internal (call $rest (local.get $coll))))) (else (ref.null none))))

  (func $__export_butlast (export "butlast") (param $coll i32) (result i32)
    (call $unbox_i32 (call $butlast_internal (ref.i31 (local.get $coll)))))

  (func $even_QMARK__internal (param $n anyref) (result anyref)
    (call $zero_QMARK_ (call $sub (local.get $n) (call $mul (ref.i31 (i32.const 2)) (call $div (local.get $n) (ref.i31 (i32.const 2)))))))

  (func $__export_even_QMARK_ (export "even?") (param $n i32) (result i32)
    (call $unbox_i32 (call $even_QMARK__internal (ref.i31 (local.get $n)))))

  (func $odd_QMARK__internal (param $n anyref) (result anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $even_QMARK__internal (local.get $n)))) (then (global.get $__true)) (else (global.get $__false))))

  (func $__export_odd_QMARK_ (export "odd?") (param $n i32) (result i32)
    (call $unbox_i32 (call $odd_QMARK__internal (ref.i31 (local.get $n)))))

  (func $closure14 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $array_get (local.get $__env) (i32.const 0)) (call $range_infinite_internal (call $inc (call $array_get (local.get $__env) (i32.const 0))))))

  (func $range_infinite_internal (param $start anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure14) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $start)) (local.get $__tmp_env)))))

  (func $__export_range_infinite (export "range-infinite") (param $start i32) (result i32)
    (call $unbox_i32 (call $range_infinite_internal (ref.i31 (local.get $start)))))

  (func $closure15 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (call $array_get (local.get $__env) (i32.const 2)) (ref.i31 (i32.const 0))))) (then (call $cmp_lt (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0)))) (else (call $cmp_gt (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0)))))) (then (call $cons (call $array_get (local.get $__env) (i32.const 1)) (call $range_step_internal (call $add (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 2))) (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 2))))) (else (ref.null none))))

  (func $range_step_internal (param $start anyref) (param $end anyref) (param $step anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure15) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $end)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $start)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $step)) (local.get $__tmp_env)))))

  (func $__export_range_step (export "range-step") (param $start i32) (param $end i32) (param $step i32) (result i32)
    (call $unbox_i32 (call $range_step_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)) (ref.i31 (local.get $step)))))

  (func $range_from_arity1_internal (param $start anyref) (result anyref)
    (return_call $range_infinite_internal (local.get $start)))

  (func $__export_range_from_arity1 (export "range_from_arity1") (param $start i32) (result i32)
    (call $unbox_i32 (call $range_from_arity1_internal (ref.i31 (local.get $start)))))

  (func $range_from_arity2_internal (param $start anyref) (param $end anyref) (result anyref)
    (return_call $range_step_internal (local.get $start) (local.get $end) (ref.i31 (i32.const 1))))

  (func $__export_range_from_arity2 (export "range_from_arity2") (param $start i32) (param $end i32) (result i32)
    (call $unbox_i32 (call $range_from_arity2_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)))))

  (func $range_from_arity3_internal (param $start anyref) (param $end anyref) (param $step anyref) (result anyref)
    (return_call $range_step_internal (local.get $start) (local.get $end) (local.get $step)))

  (func $__export_range_from_arity3 (export "range_from_arity3") (param $start i32) (param $end i32) (param $step i32) (result i32)
    (call $unbox_i32 (call $range_from_arity3_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)) (ref.i31 (local.get $step)))))

  (func $reverse_internal (param $coll anyref) (result anyref)
    (local $acc anyref)
    (local $curr anyref)
    (block (result anyref) (local.set $acc (ref.null none)) (local.set $curr (call $seq (local.get $coll))) (loop $loop1 (result anyref) (if (result anyref) (call $truthy (local.get $curr)) (then (call $cons (call $first (local.get $curr)) (local.get $acc))
      (call $seq (call $rest (local.get $curr)))
      (local.set $curr)
      (local.set $acc)
      (br $loop1)) (else (local.get $acc))))))

  (func $__export_reverse (export "reverse") (param $coll i32) (result i32)
    (call $unbox_i32 (call $reverse_internal (ref.i31 (local.get $coll)))))

  (func $concat_arity0_internal  (result anyref)
    (ref.null none))

  (func $__export_concat_arity0 (export "concat_arity0")  (result i32)
    (call $unbox_i32 (call $concat_arity0_internal )))

  (func $closure16 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $seq (call $array_get (local.get $__env) (i32.const 0))))

  (func $concat_arity1_internal (param $a anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure16) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $a)) (local.get $__tmp_env)))))

  (func $__export_concat_arity1 (export "concat_arity1") (param $a i32) (result i32)
    (call $unbox_i32 (call $concat_arity1_internal (ref.i31 (local.get $a)))))

  (func $closure17 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (call $array_get (local.get $__env) (i32.const 0)))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (call $seq (call $array_get (local.get $__env) (i32.const 1)))) (else (call $cons (call $first (local.get $s)) (call $concat_arity2_internal (call $rest (local.get $s)) (call $array_get (local.get $__env) (i32.const 1))))))))

  (func $concat_arity2_internal (param $a anyref) (param $b anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure17) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $a)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $b)) (local.get $__tmp_env)))))

  (func $__export_concat_arity2 (export "concat_arity2") (param $a i32) (param $b i32) (result i32)
    (call $unbox_i32 (call $concat_arity2_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b)))))

  (func $concat_variadic_internal (param $a anyref) (param $b anyref) (param $more anyref) (result anyref)
    (return_call $concat_arity2_internal (local.get $a) (call $concat_arity2_internal (local.get $b) (call $reduce_no_init (global.get $__fn_concat) (local.get $more)))))

  (func $__export_concat_variadic (export "concat_variadic") (param $a i32) (param $b i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $concat_variadic_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b)) (ref.i31 (local.get $more)))))

  (func $take_while_seq_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (if (result anyref) (call $truthy (call $invoke1 (local.get $pred) (call $first (local.get $s)))) (then (call $cons (call $first (local.get $s)) (call $take_while_seq_internal (local.get $pred) (call $rest (local.get $s))))) (else (ref.null none)))))))

  (func $__export_take_while_seq (export "take-while-seq") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $take_while_seq_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $closure19 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $input))) (then (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (local.get $input))) (else (call $reduced (local.get $result)))))

  (func $closure18 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure2 (i32.const 11) (ref.func $closure19) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env))))

  (func $take_while_arity1_internal (param $pred anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure18) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $pred)) (local.get $__tmp_env))))

  (func $__export_take_while_arity1 (export "take_while_arity1") (param $pred i32) (result i32)
    (call $unbox_i32 (call $take_while_arity1_internal (ref.i31 (local.get $pred)))))

  (func $take_while_arity2_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (return_call $take_while_seq_internal (local.get $pred) (local.get $coll)))

  (func $__export_take_while_arity2 (export "take_while_arity2") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $take_while_arity2_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $drop_while_seq_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (if (result anyref) (call $truthy (call $invoke1 (local.get $pred) (call $first (local.get $s)))) (then (return_call $drop_while_seq_internal (local.get $pred) (call $rest (local.get $s)))) (else (local.get $s)))))))

  (func $__export_drop_while_seq (export "drop-while-seq") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $drop_while_seq_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $closure21 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $deref (call $array_get (local.get $__env) (i32.const 0)))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $input))) (else (call $deref (call $array_get (local.get $__env) (i32.const 0)))))) (then (local.get $result)) (else (block (result anyref) (drop (call $reset_BANG_ (call $array_get (local.get $__env) (i32.const 0)) (global.get $__false))) (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 2)) (local.get $result) (local.get $input))))))

  (func $closure20 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $dropping anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $dropping (call $atom (global.get $__true))) (struct.new $Closure2 (i32.const 11) (ref.func $closure21) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $dropping)) (call $array_set (local.get $__tmp_env) (i32.const 1) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $rf)) (local.get $__tmp_env)))))

  (func $drop_while_arity1_internal (param $pred anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure20) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $pred)) (local.get $__tmp_env))))

  (func $__export_drop_while_arity1 (export "drop_while_arity1") (param $pred i32) (result i32)
    (call $unbox_i32 (call $drop_while_arity1_internal (ref.i31 (local.get $pred)))))

  (func $drop_while_arity2_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (return_call $drop_while_seq_internal (local.get $pred) (local.get $coll)))

  (func $__export_drop_while_arity2 (export "drop_while_arity2") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $drop_while_arity2_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $split_at_internal (param $n anyref) (param $coll anyref) (result anyref)
    (call $cons (call $take_arity2_internal (local.get $n) (local.get $coll)) (call $cons (call $drop_arity2_internal (local.get $n) (local.get $coll)) (ref.null none))))

  (func $__export_split_at (export "split-at") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $split_at_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $split_with_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (call $cons (call $take_while_arity2_internal (local.get $pred) (local.get $coll)) (call $cons (call $drop_while_arity2_internal (local.get $pred) (local.get $coll)) (ref.null none))))

  (func $__export_split_with (export "split-with") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $split_with_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $interpose_seq_internal (param $sep anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (if (result anyref) (call $truthy (call $seq (call $rest (local.get $s)))) (then (call $cons (call $first (local.get $s)) (call $cons (local.get $sep) (call $interpose_seq_internal (local.get $sep) (call $rest (local.get $s)))))) (else (call $cons (call $first (local.get $s)) (ref.null none))))))))

  (func $__export_interpose_seq (export "interpose-seq") (param $sep i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $interpose_seq_internal (ref.i31 (local.get $sep)) (ref.i31 (local.get $coll)))))

  (func $closure23 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (if (result anyref) (call $truthy (call $deref (call $array_get (local.get $__env) (i32.const 2)))) (then (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (local.get $result) (call $array_get (local.get $__env) (i32.const 1))) (local.get $input))) (else (block (result anyref) (drop (call $reset_BANG_ (call $array_get (local.get $__env) (i32.const 2)) (global.get $__true))) (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (local.get $result) (local.get $input))))))

  (func $closure22 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $started anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $started (call $atom (global.get $__false))) (struct.new $Closure2 (i32.const 11) (ref.func $closure23) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $rf)) (call $array_set (local.get $__tmp_env) (i32.const 1) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $started)) (local.get $__tmp_env)))))

  (func $interpose_arity1_internal (param $sep anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure22) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $sep)) (local.get $__tmp_env))))

  (func $__export_interpose_arity1 (export "interpose_arity1") (param $sep i32) (result i32)
    (call $unbox_i32 (call $interpose_arity1_internal (ref.i31 (local.get $sep)))))

  (func $interpose_arity2_internal (param $sep anyref) (param $coll anyref) (result anyref)
    (return_call $interpose_seq_internal (local.get $sep) (local.get $coll)))

  (func $__export_interpose_arity2 (export "interpose_arity2") (param $sep i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $interpose_arity2_internal (ref.i31 (local.get $sep)) (ref.i31 (local.get $coll)))))

  (func $interleave_internal (param $c1 anyref) (param $c2 anyref) (result anyref)
    (local $s1 anyref)
    (local $s2 anyref)
    (block (result anyref) (local.set $s1 (call $seq (local.get $c1))) (local.set $s2 (call $seq (local.get $c2))) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s1))) (then (call $nil_QMARK_ (local.get $s1))) (else (call $nil_QMARK_ (local.get $s2))))) (then (ref.null none)) (else (call $cons (call $first (local.get $s1)) (call $cons (call $first (local.get $s2)) (call $interleave_internal (call $rest (local.get $s1)) (call $rest (local.get $s2)))))))))

  (func $__export_interleave (export "interleave") (param $c1 i32) (param $c2 i32) (result i32)
    (call $unbox_i32 (call $interleave_internal (ref.i31 (local.get $c1)) (ref.i31 (local.get $c2)))))

  (func $some_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    (local $result anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (block (result anyref) (local.set $result (call $invoke1 (local.get $pred) (call $first (local.get $s)))) (if (result anyref) (call $truthy (local.get $result)) (then (local.get $result)) (else (return_call $some_internal (local.get $pred) (call $rest (local.get $s))))))))))

  (func $__export_some (export "some") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $some_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $every_QMARK__internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (global.get $__true)) (else (if (result anyref) (call $truthy (call $invoke1 (local.get $pred) (call $first (local.get $s)))) (then (return_call $every_QMARK__internal (local.get $pred) (call $rest (local.get $s)))) (else (global.get $__false)))))))

  (func $__export_every_QMARK_ (export "every?") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $every_QMARK__internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $not_every_QMARK__internal (param $pred anyref) (param $coll anyref) (result anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $every_QMARK__internal (local.get $pred) (local.get $coll)))) (then (global.get $__true)) (else (global.get $__false))))

  (func $__export_not_every_QMARK_ (export "not-every?") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $not_every_QMARK__internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $not_any_QMARK__internal (param $pred anyref) (param $coll anyref) (result anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $some_internal (local.get $pred) (local.get $coll)))) (then (global.get $__true)) (else (global.get $__false))))

  (func $__export_not_any_QMARK_ (export "not-any?") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $not_any_QMARK__internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $closure25 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (local $v anyref)
    (block (result anyref) (local.set $v (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $input))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $v))) (then (local.get $result)) (else (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (local.get $v))))))

  (func $closure24 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure2 (i32.const 11) (ref.func $closure25) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env))))

  (func $keep_arity1_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure24) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env))))

  (func $__export_keep_arity1 (export "keep_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $keep_arity1_internal (ref.i31 (local.get $f)))))

  (func $fn26 (type $ClosureFunc2) (param $__env anyref) (param $f anyref) (param $coll anyref) (result anyref)
    (local $keep_seq anyref)
    (local $s anyref)
    (local $result anyref)
    (local.set $keep_seq (struct.new $Closure2 (i32.const 11) (ref.func $fn26) (local.get $__env)))
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (block (result anyref) (local.set $result (call $invoke1 (local.get $f) (call $first (local.get $s)))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $result))) (then (return_call $invoke2 (local.get $keep_seq) (local.get $f) (call $rest (local.get $s)))) (else (call $cons (local.get $result) (call $invoke2 (local.get $keep_seq) (local.get $f) (call $rest (local.get $s)))))))))))

  (func $keep_arity2_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $keep_seq anyref)
    (block (result anyref) (local.set $keep_seq (global.get $__lifted_fn26)) (return_call $invoke2 (local.get $keep_seq) (local.get $f) (local.get $coll))))

  (func $__export_keep_arity2 (export "keep_arity2") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $keep_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $map_indexed_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $idx anyref)
    (local $curr anyref)
    (local $acc anyref)
    (block (result anyref) (local.set $idx (ref.i31 (i32.const 0))) (local.set $curr (call $seq (local.get $coll))) (local.set $acc (ref.null none)) (loop $loop2 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $curr))) (then (call $reverse_internal (local.get $acc))) (else (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
      (call $seq (call $rest (local.get $curr)))
      (call $cons (call $invoke2 (local.get $f) (local.get $idx) (call $first (local.get $curr))) (local.get $acc))
      (local.set $acc)
      (local.set $curr)
      (local.set $idx)
      (br $loop2))))))

  (func $__export_map_indexed (export "map-indexed") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $map_indexed_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $keep_indexed_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $idx anyref)
    (local $curr anyref)
    (local $acc anyref)
    (local $result anyref)
    (block (result anyref) (local.set $idx (ref.i31 (i32.const 0))) (local.set $curr (call $seq (local.get $coll))) (local.set $acc (ref.null none)) (loop $loop3 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $curr))) (then (call $reverse_internal (local.get $acc))) (else (block (result anyref) (local.set $result (call $invoke2 (local.get $f) (local.get $idx) (call $first (local.get $curr)))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $result))) (then (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
      (call $seq (call $rest (local.get $curr)))
      (local.get $acc)
      (local.set $acc)
      (local.set $curr)
      (local.set $idx)
      (br $loop3)) (else (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
      (call $seq (call $rest (local.get $curr)))
      (call $cons (local.get $result) (local.get $acc))
      (local.set $acc)
      (local.set $curr)
      (local.set $idx)
      (br $loop3)))))))))

  (func $__export_keep_indexed (export "keep-indexed") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $keep_indexed_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $closure29 (type $ClosureFunc1) (param $__env anyref) (param $s anyref) (result anyref)
    (call $set_conj (local.get $s) (call $array_get (local.get $__env) (i32.const 0))))

  (func $closure28 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (local $__tmp_env anyref)
    (if (result anyref) (call $truthy (call $contains_QMARK_ (call $deref (call $array_get (local.get $__env) (i32.const 1))) (local.get $input))) (then (local.get $result)) (else (block (result anyref) (drop (call $swap_BANG_ (call $array_get (local.get $__env) (i32.const 1)) (struct.new $Closure1 (i32.const 11) (ref.func $closure29) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $input)) (local.get $__tmp_env))))) (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (local.get $result) (local.get $input))))))

  (func $fn27 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $seen anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $seen (call $atom (call $empty_hash_set))) (struct.new $Closure2 (i32.const 11) (ref.func $closure28) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $rf)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $seen)) (local.get $__tmp_env)))))

  (func $distinct_arity0_internal  (result anyref)
    (global.get $__lifted_fn27))

  (func $__export_distinct_arity0 (export "distinct_arity0")  (result i32)
    (call $unbox_i32 (call $distinct_arity0_internal )))

  (func $closure30 (type $ClosureFunc1) (param $__env anyref) (param $y anyref) (result anyref)
    (if (result anyref) (call $eq (call $array_get (local.get $__env) (i32.const 0)) (local.get $y)) (then (global.get $__true)) (else (global.get $__false))))

  (func $distinct_arity1_internal (param $coll anyref) (result anyref)
    (local $seen anyref)
    (local $curr anyref)
    (local $acc anyref)
    (local $x anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $seen (ref.null none)) (local.set $curr (call $seq (local.get $coll))) (local.set $acc (ref.null none)) (loop $loop4 (result anyref) (if (result anyref) (call $truthy (local.get $curr)) (then (block (result anyref) (local.set $x (call $first (local.get $curr))) (if (result anyref) (call $truthy (call $some_internal (struct.new $Closure1 (i32.const 11) (ref.func $closure30) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $x)) (local.get $__tmp_env))) (local.get $seen))) (then (local.get $seen)
      (call $seq (call $rest (local.get $curr)))
      (local.get $acc)
      (local.set $acc)
      (local.set $curr)
      (local.set $seen)
      (br $loop4)) (else (call $cons (local.get $x) (local.get $seen))
      (call $seq (call $rest (local.get $curr)))
      (call $cons (local.get $x) (local.get $acc))
      (local.set $acc)
      (local.set $curr)
      (local.set $seen)
      (br $loop4))))) (else (call $reverse_internal (local.get $acc)))))))

  (func $__export_distinct_arity1 (export "distinct_arity1") (param $coll i32) (result i32)
    (call $unbox_i32 (call $distinct_arity1_internal (ref.i31 (local.get $coll)))))

  (func $partition_seq_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    (local $chunk anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (block (result anyref) (local.set $chunk (call $take_arity2_internal (local.get $n) (local.get $s))) (if (result anyref) (call $eq (ref.i31 (call $count_internal (local.get $chunk))) (local.get $n)) (then (call $cons (local.get $chunk) (call $partition_seq_internal (local.get $n) (call $drop_arity2_internal (local.get $n) (local.get $s))))) (else (ref.null none))))))))

  (func $__export_partition_seq (export "partition-seq") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $partition_seq_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $partition_internal (param $n anyref) (param $coll anyref) (result anyref)
    (return_call $partition_seq_internal (local.get $n) (local.get $coll)))

  (func $__export_partition (export "partition") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $partition_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $xf_complete_internal (param $xf anyref) (param $result anyref) (result anyref)
    (local $m anyref)
    (local $completer anyref)
    (block (result anyref) (local.set $m (call $meta_ (local.get $xf))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $m))) (then (local.get $result)) (else (block (result anyref) (local.set $completer (call $hash_map_get (local.get $m) (struct.new $Keyword (i32.const 2) (i32.const 0)))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $completer))) (then (local.get $result)) (else (return_call $invoke1 (local.get $completer) (local.get $result)))))))))

  (func $__export_xf_complete (export "xf-complete") (param $xf i32) (param $result i32) (result i32)
    (call $unbox_i32 (call $xf_complete_internal (ref.i31 (local.get $xf)) (ref.i31 (local.get $result)))))

  (func $partition_all_seq_internal (param $n anyref) (param $coll anyref) (result anyref)
    (if (result anyref) (call $truthy (call $nil_QMARK_ (call $seq (local.get $coll)))) (then (ref.null none)) (else (call $cons (call $take_arity2_internal (local.get $n) (local.get $coll)) (call $partition_all_seq_internal (local.get $n) (call $drop_arity2_internal (local.get $n) (local.get $coll)))))))

  (func $__export_partition_all_seq (export "partition-all-seq") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $partition_all_seq_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $closure32 (type $ClosureFunc1) (param $__env anyref) (param $result anyref) (result anyref)
    (local $b anyref)
    (block (result anyref) (local.set $b (call $deref (call $array_get (local.get $__env) (i32.const 0)))) (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (ref.i31 (call $count_internal (local.get $b))) (ref.i31 (i32.const 0))))) (then (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (local.get $b))) (else (local.get $result)))))

  (func $closure34 (type $ClosureFunc1) (param $__env anyref) (param $v anyref) (result anyref)
    (call $conj (local.get $v) (call $array_get (local.get $__env) (i32.const 0))))

  (func $closure33 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (local $b anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $b (call $swap_BANG_ (call $array_get (local.get $__env) (i32.const 0)) (struct.new $Closure1 (i32.const 11) (ref.func $closure34) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $input)) (local.get $__tmp_env))))) (if (result anyref) (call $eq (ref.i31 (call $count_internal (local.get $b))) (call $array_get (local.get $__env) (i32.const 1))) (then (block (result anyref) (drop (call $reset_BANG_ (call $array_get (local.get $__env) (i32.const 0)) (call $empty_vector))) (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 2)) (local.get $result) (local.get $b)))) (else (local.get $result)))))

  (func $closure31 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $buf anyref)
    (local $complete anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $buf (call $atom (call $empty_vector))) (local.set $complete (struct.new $Closure1 (i32.const 11) (ref.func $closure32) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $buf)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env)))) (call $with_meta_ (struct.new $Closure2 (i32.const 11) (ref.func $closure33) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $buf)) (call $array_set (local.get $__tmp_env) (i32.const 1) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $rf)) (local.get $__tmp_env))) (call $hash_map_assoc (call $empty_hash_map) (struct.new $Keyword (i32.const 2) (i32.const 0)) (local.get $complete)))))

  (func $partition_all_arity1_internal (param $n anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure31) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $n)) (local.get $__tmp_env))))

  (func $__export_partition_all_arity1 (export "partition_all_arity1") (param $n i32) (result i32)
    (call $unbox_i32 (call $partition_all_arity1_internal (ref.i31 (local.get $n)))))

  (func $partition_all_arity2_internal (param $n anyref) (param $coll anyref) (result anyref)
    (return_call $partition_all_seq_internal (local.get $n) (local.get $coll)))

  (func $__export_partition_all_arity2 (export "partition_all_arity2") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $partition_all_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $flatten_one_internal (param $coll anyref) (result anyref)
    (local $s anyref)
    (local $x anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (block (result anyref) (local.set $x (call $first (local.get $s))) (if (result anyref) (call $truthy (call $cons_QMARK_ (local.get $x))) (then (return_call $concat_arity2_internal (local.get $x) (call $flatten_one_internal (call $rest (local.get $s))))) (else (call $cons (local.get $x) (call $flatten_one_internal (call $rest (local.get $s)))))))))))

  (func $__export_flatten_one (export "flatten-one") (param $coll i32) (result i32)
    (call $unbox_i32 (call $flatten_one_internal (ref.i31 (local.get $coll)))))

  (func $mapcat_seq_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (ref.null none)) (else (return_call $concat_arity2_internal (call $invoke1 (local.get $f) (call $first (local.get $s))) (call $mapcat_seq_internal (local.get $f) (call $rest (local.get $s))))))))

  (func $__export_mapcat_seq (export "mapcat-seq") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $mapcat_seq_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $closure36 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (call $reduce (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $input))))

  (func $closure35 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure2 (i32.const 11) (ref.func $closure36) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env))))

  (func $mapcat_arity1_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure35) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env))))

  (func $__export_mapcat_arity1 (export "mapcat_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $mapcat_arity1_internal (ref.i31 (local.get $f)))))

  (func $mapcat_arity2_internal (param $f anyref) (param $coll anyref) (result anyref)
    (return_call $mapcat_seq_internal (local.get $f) (local.get $coll)))

  (func $__export_mapcat_arity2 (export "mapcat_arity2") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $mapcat_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $closure37 (type $ClosureFunc1) (param $__env anyref) (param $p__7 anyref) (result anyref)
    (local $a anyref)
    (local $b anyref)
    (block (result anyref) (local.set $a (call $nth_polymorphic (local.get $p__7) (i32.const 0))) (local.set $b (call $nth_polymorphic (local.get $p__7) (i32.const 1))) (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (local.get $a) (local.get $b))))

  (func $fn38 (type $ClosureFunc2) (param $__env anyref) (param $a anyref) (param $b anyref) (result anyref)
    (call $conj (call $conj (call $empty_vector) (local.get $a)) (local.get $b)))

  (func $mapcat_arity3_internal (param $f anyref) (param $c1 anyref) (param $c2 anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $mapcat_seq_internal (struct.new $Closure1 (i32.const 11) (ref.func $closure37) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env))) (call $map_arity3_internal (global.get $__lifted_fn38) (local.get $c1) (local.get $c2))))

  (func $__export_mapcat_arity3 (export "mapcat_arity3") (param $f i32) (param $c1 i32) (param $c2 i32) (result i32)
    (call $unbox_i32 (call $mapcat_arity3_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $c1)) (ref.i31 (local.get $c2)))))

  (func $closure39 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (call $reduce (call $array_get (local.get $__env) (i32.const 0)) (local.get $result) (local.get $input)))

  (func $cat_internal (param $rf anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure2 (i32.const 11) (ref.func $closure39) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $rf)) (local.get $__tmp_env))))

  (func $__export_cat (export "cat") (param $rf i32) (result i32)
    (call $unbox_i32 (call $cat_internal (ref.i31 (local.get $rf)))))

  (func $closure40 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))) (then (global.get $__true)) (else (global.get $__false))))

  (func $remove_arity1_internal (param $pred anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $filter_arity1_internal (struct.new $Closure1 (i32.const 11) (ref.func $closure40) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $pred)) (local.get $__tmp_env)))))

  (func $__export_remove_arity1 (export "remove_arity1") (param $pred i32) (result i32)
    (call $unbox_i32 (call $remove_arity1_internal (ref.i31 (local.get $pred)))))

  (func $closure41 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))) (then (global.get $__true)) (else (global.get $__false))))

  (func $remove_arity2_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $filter_arity2_internal (struct.new $Closure1 (i32.const 11) (ref.func $closure41) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $pred)) (local.get $__tmp_env))) (local.get $coll)))

  (func $__export_remove_arity2 (export "remove_arity2") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $remove_arity2_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $next_internal (param $coll anyref) (result anyref)
    (call $seq (call $rest (local.get $coll))))

  (func $__export_next (export "next") (param $coll i32) (result i32)
    (call $unbox_i32 (call $next_internal (ref.i31 (local.get $coll)))))

  (func $nthnext_internal (param $coll anyref) (param $n anyref) (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $zero_QMARK_ (local.get $n)))) (then (local.get $coll)) (else (return_call $nthnext_internal (call $rest (local.get $coll)) (call $dec (local.get $n))))))

  (func $__export_nthnext (export "nthnext") (param $coll i32) (param $n i32) (result i32)
    (call $unbox_i32 (call $nthnext_internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $n)))))

  (func $nthrest_internal (param $coll anyref) (param $n anyref) (result anyref)
    (return_call $nthnext_internal (local.get $coll) (local.get $n)))

  (func $__export_nthrest (export "nthrest") (param $coll i32) (param $n i32) (result i32)
    (call $unbox_i32 (call $nthrest_internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $n)))))

  (func $merge_arity0_internal  (result anyref)
    (ref.null none))

  (func $__export_merge_arity0 (export "merge_arity0")  (result i32)
    (call $unbox_i32 (call $merge_arity0_internal )))

  (func $merge_arity1_internal (param $m anyref) (result anyref)
    (local.get $m))

  (func $__export_merge_arity1 (export "merge_arity1") (param $m i32) (result i32)
    (call $unbox_i32 (call $merge_arity1_internal (ref.i31 (local.get $m)))))

  (func $fn42 (type $ClosureFunc3) (param $__env anyref) (param $r anyref) (param $k anyref) (param $v anyref) (result anyref)
    (return_call $invoke3 (global.get $__builtin_assoc_BANG_) (local.get $r) (local.get $k) (local.get $v)))

  (func $merge_arity2_internal (param $m1 anyref) (param $m2 anyref) (result anyref)
    (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $m2))) (then (local.get $m1)) (else (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $m1))) (then (local.get $m2)) (else (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce_kv (global.get $__lifted_fn42) (call $invoke1 (global.get $__builtin_transient) (local.get $m1)) (local.get $m2))))))))

  (func $__export_merge_arity2 (export "merge_arity2") (param $m1 i32) (param $m2 i32) (result i32)
    (call $unbox_i32 (call $merge_arity2_internal (ref.i31 (local.get $m1)) (ref.i31 (local.get $m2)))))

  (func $merge_variadic_internal (param $m1 anyref) (param $m2 anyref) (param $more anyref) (result anyref)
    (call $reduce (global.get $__fn_merge) (call $merge_arity2_internal (local.get $m1) (local.get $m2)) (local.get $more)))

  (func $__export_merge_variadic (export "merge_variadic") (param $m1 i32) (param $m2 i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $merge_variadic_internal (ref.i31 (local.get $m1)) (ref.i31 (local.get $m2)) (ref.i31 (local.get $more)))))

  (func $closure43 (type $ClosureFunc3) (param $__env anyref) (param $m anyref) (param $k anyref) (param $v anyref) (result anyref)
    (if (result anyref) (call $truthy (call $contains_QMARK_ (local.get $m) (local.get $k))) (then (call $assoc (local.get $m) (local.get $k) (call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (call $hash_map_get (local.get $m) (local.get $k)) (local.get $v)))) (else (call $assoc (local.get $m) (local.get $k) (local.get $v)))))

  (func $merge_with_internal (param $f anyref) (param $m1 anyref) (param $m2 anyref) (result anyref)
    (local $__tmp_env anyref)
    (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $m2))) (then (local.get $m1)) (else (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $m1))) (then (local.get $m2)) (else (call $reduce_kv (struct.new $Closure3 (i32.const 11) (ref.func $closure43) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env))) (local.get $m1) (local.get $m2)))))))

  (func $__export_merge_with (export "merge-with") (param $f i32) (param $m1 i32) (param $m2 i32) (result i32)
    (call $unbox_i32 (call $merge_with_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $m1)) (ref.i31 (local.get $m2)))))

  (func $find_internal (param $m anyref) (param $k anyref) (result anyref)
    (if (result anyref) (call $truthy (call $contains_QMARK_ (local.get $m) (local.get $k))) (then (call $conj (call $conj (call $empty_vector) (local.get $k)) (call $hash_map_get (local.get $m) (local.get $k)))) (else (ref.null none))))

  (func $__export_find (export "find") (param $m i32) (param $k i32) (result i32)
    (call $unbox_i32 (call $find_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $k)))))

  (func $closure44 (type $ClosureFunc2) (param $__env anyref) (param $r anyref) (param $k anyref) (result anyref)
    (if (result anyref) (call $truthy (call $contains_QMARK_ (call $array_get (local.get $__env) (i32.const 0)) (local.get $k))) (then (return_call $invoke3 (global.get $__builtin_assoc_BANG_) (local.get $r) (local.get $k) (call $hash_map_get (call $array_get (local.get $__env) (i32.const 0)) (local.get $k)))) (else (local.get $r))))

  (func $select_keys_internal (param $m anyref) (param $ks anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure44) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $m)) (local.get $__tmp_env))) (call $invoke1 (global.get $__builtin_transient) (call $empty_hash_map)) (local.get $ks))))

  (func $__export_select_keys (export "select-keys") (param $m i32) (param $ks i32) (result i32)
    (call $unbox_i32 (call $select_keys_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks)))))

  (func $get_in_arity2_internal (param $m anyref) (param $ks anyref) (result anyref)
    (return_call $get_in_arity3_internal (local.get $m) (local.get $ks) (ref.null none)))

  (func $__export_get_in_arity2 (export "get_in_arity2") (param $m i32) (param $ks i32) (result i32)
    (call $unbox_i32 (call $get_in_arity2_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks)))))

  (func $get_in_arity3_internal (param $m anyref) (param $ks anyref) (param $not_found anyref) (result anyref)
    (local $s anyref)
    (local $remaining anyref)
    (local $k anyref)
    (local $nxt anyref)
    (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $ks))) (then (local.get $m)) (else (block (result anyref) (local.set $s (call $seq (local.get $ks))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (local.get $m)) (else (block (result anyref) (local.set $m (local.get $m)) (local.set $remaining (local.get $s)) (loop $loop5 (result anyref) (block (result anyref) (local.set $k (call $first (local.get $remaining))) (local.set $nxt (call $seq (call $rest (local.get $remaining)))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $nxt))) (then (call $hash_map_get_default (local.get $m) (local.get $k) (local.get $not_found))) (else (call $hash_map_get (local.get $m) (local.get $k))
      (local.get $nxt)
      (local.set $remaining)
      (local.set $m)
      (br $loop5))))))))))))

  (func $__export_get_in_arity3 (export "get_in_arity3") (param $m i32) (param $ks i32) (param $not_found i32) (result i32)
    (call $unbox_i32 (call $get_in_arity3_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks)) (ref.i31 (local.get $not_found)))))

  (func $assoc_in_internal (param $m anyref) (param $ks anyref) (param $v anyref) (result anyref)
    (if (result anyref) (call $truthy (call $seq (call $rest (local.get $ks)))) (then (call $assoc (local.get $m) (call $first (local.get $ks)) (call $assoc_in_internal (call $hash_map_get (local.get $m) (call $first (local.get $ks))) (call $seq (call $rest (local.get $ks))) (local.get $v)))) (else (call $assoc (local.get $m) (call $first (local.get $ks)) (local.get $v)))))

  (func $__export_assoc_in (export "assoc-in") (param $m i32) (param $ks i32) (param $v i32) (result i32)
    (call $unbox_i32 (call $assoc_in_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks)) (ref.i31 (local.get $v)))))

  (func $update_internal (param $m anyref) (param $k anyref) (param $f anyref) (result anyref)
    (call $assoc (local.get $m) (local.get $k) (call $invoke1 (local.get $f) (call $hash_map_get (local.get $m) (local.get $k)))))

  (func $__export_update (export "update") (param $m i32) (param $k i32) (param $f i32) (result i32)
    (call $unbox_i32 (call $update_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $k)) (ref.i31 (local.get $f)))))

  (func $update_in_internal (param $m anyref) (param $ks anyref) (param $f anyref) (result anyref)
    (local $upd_m__8 anyref)
    (local $upd_k__9 anyref)
    (if (result anyref) (call $truthy (call $seq (call $rest (local.get $ks)))) (then (call $assoc (local.get $m) (call $first (local.get $ks)) (call $update_in_internal (call $hash_map_get (local.get $m) (call $first (local.get $ks))) (call $seq (call $rest (local.get $ks))) (local.get $f)))) (else (block (result anyref) (local.set $upd_m__8 (local.get $m)) (local.set $upd_k__9 (call $first (local.get $ks))) (call $assoc (local.get $upd_m__8) (local.get $upd_k__9) (call $invoke1 (local.get $f) (call $hash_map_get (local.get $upd_m__8) (local.get $upd_k__9))))))))

  (func $__export_update_in (export "update-in") (param $m i32) (param $ks i32) (param $f i32) (result i32)
    (call $unbox_i32 (call $update_in_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks)) (ref.i31 (local.get $f)))))

  (func $set_internal (param $coll anyref) (result anyref)
    (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (global.get $__builtin_conj_BANG_) (call $invoke1 (global.get $__builtin_transient) (call $empty_hash_set)) (call $seq (local.get $coll)))))

  (func $__export_set (export "set") (param $coll i32) (result i32)
    (call $unbox_i32 (call $set_internal (ref.i31 (local.get $coll)))))

  (func $union_internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (global.get $__builtin_conj_BANG_) (call $invoke1 (global.get $__builtin_transient) (local.get $s1)) (call $seq (local.get $s2)))))

  (func $__export_union (export "union") (param $s1 i32) (param $s2 i32) (result i32)
    (call $unbox_i32 (call $union_internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2)))))

  (func $closure45 (type $ClosureFunc2) (param $__env anyref) (param $r anyref) (param $elem anyref) (result anyref)
    (if (result anyref) (call $truthy (call $contains_QMARK_ (call $array_get (local.get $__env) (i32.const 0)) (local.get $elem))) (then (return_call $invoke2 (global.get $__builtin_conj_BANG_) (local.get $r) (local.get $elem))) (else (local.get $r))))

  (func $intersection_internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure45) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $s2)) (local.get $__tmp_env))) (call $invoke1 (global.get $__builtin_transient) (call $empty_hash_set)) (call $seq (local.get $s1)))))

  (func $__export_intersection (export "intersection") (param $s1 i32) (param $s2 i32) (result i32)
    (call $unbox_i32 (call $intersection_internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2)))))

  (func $closure46 (type $ClosureFunc2) (param $__env anyref) (param $r anyref) (param $elem anyref) (result anyref)
    (if (result anyref) (call $truthy (call $contains_QMARK_ (call $array_get (local.get $__env) (i32.const 0)) (local.get $elem))) (then (local.get $r)) (else (return_call $invoke2 (global.get $__builtin_conj_BANG_) (local.get $r) (local.get $elem)))))

  (func $difference_internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure46) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $s2)) (local.get $__tmp_env))) (call $invoke1 (global.get $__builtin_transient) (call $empty_hash_set)) (call $seq (local.get $s1)))))

  (func $__export_difference (export "difference") (param $s1 i32) (param $s2 i32) (result i32)
    (call $unbox_i32 (call $difference_internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2)))))

  (func $closure47 (type $ClosureFunc1) (param $__env anyref) (param $elem anyref) (result anyref)
    (call $contains_QMARK_ (call $array_get (local.get $__env) (i32.const 0)) (local.get $elem)))

  (func $subset_QMARK__internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $every_QMARK__internal (struct.new $Closure1 (i32.const 11) (ref.func $closure47) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $s2)) (local.get $__tmp_env))) (call $seq (local.get $s1))))

  (func $__export_subset_QMARK_ (export "subset?") (param $s1 i32) (param $s2 i32) (result i32)
    (call $unbox_i32 (call $subset_QMARK__internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2)))))

  (func $superset_QMARK__internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (return_call $subset_QMARK__internal (local.get $s2) (local.get $s1)))

  (func $__export_superset_QMARK_ (export "superset?") (param $s1 i32) (param $s2 i32) (result i32)
    (call $unbox_i32 (call $superset_QMARK__internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2)))))

  (func $swap_vals_BANG__internal (param $a anyref) (param $f anyref) (result anyref)
    (local $old anyref)
    (local $new anyref)
    (block (result anyref) (local.set $old (call $deref (local.get $a))) (local.set $new (call $invoke1 (local.get $f) (local.get $old))) (block (result anyref) (drop (call $reset_BANG_ (local.get $a) (local.get $new))) (call $conj (call $conj (call $empty_vector) (local.get $old)) (local.get $new)))))

  (func $__export_swap_vals_BANG_ (export "swap-vals!") (param $a i32) (param $f i32) (result i32)
    (call $unbox_i32 (call $swap_vals_BANG__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $f)))))

  (func $reset_vals_BANG__internal (param $a anyref) (param $newval anyref) (result anyref)
    (local $old anyref)
    (block (result anyref) (local.set $old (call $deref (local.get $a))) (block (result anyref) (drop (call $reset_BANG_ (local.get $a) (local.get $newval))) (call $conj (call $conj (call $empty_vector) (local.get $old)) (local.get $newval)))))

  (func $__export_reset_vals_BANG_ (export "reset-vals!") (param $a i32) (param $newval i32) (result i32)
    (call $unbox_i32 (call $reset_vals_BANG__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $newval)))))

  (func $anon_multi48_arity0 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $array_get (local.get $__env) (i32.const 0)))

  (func $anon_multi48_arity1 (type $ClosureFunc1) (param $__env anyref) (param $a anyref) (result anyref)
    (call $array_get (local.get $__env) (i32.const 0)))

  (func $anon_multi48_arity2 (type $ClosureFunc2) (param $__env anyref) (param $a anyref) (param $b anyref) (result anyref)
    (call $array_get (local.get $__env) (i32.const 0)))

  (func $anon_multi48_arity3 (type $ClosureFunc3) (param $__env anyref) (param $a anyref) (param $b anyref) (param $c anyref) (result anyref)
    (call $array_get (local.get $__env) (i32.const 0)))

  (func $anon_multi48_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 0))
      (then
      (call $anon_multi48_arity0 (local.get $__env)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi48_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi48_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 3))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a2 (call $first (local.get $args)))
      (call $anon_multi48_arity3 (local.get $__env) (local.get $a0) (local.get $a1) (local.get $a2)))
      (else (unreachable))))))))))

  (func $constantly_internal (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $x)) (local.get $__tmp_env)) (ref.func $anon_multi48_dispatch)))

  (func $__export_constantly (export "constantly") (param $x i32) (result i32)
    (call $unbox_i32 (call $constantly_internal (ref.i31 (local.get $x)))))

  (func $comp_arity0_internal  (result anyref)
    (global.get $__fn_identity))

  (func $__export_comp_arity0 (export "comp_arity0")  (result i32)
    (call $unbox_i32 (call $comp_arity0_internal )))

  (func $comp_arity1_internal (param $f anyref) (result anyref)
    (local.get $f))

  (func $__export_comp_arity1 (export "comp_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $comp_arity1_internal (ref.i31 (local.get $f)))))

  (func $closure49 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (return_call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))

  (func $comp_arity2_internal (param $f anyref) (param $g anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure49) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g)) (local.get $__tmp_env))))

  (func $__export_comp_arity2 (export "comp_arity2") (param $f i32) (param $g i32) (result i32)
    (call $unbox_i32 (call $comp_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g)))))

  (func $comp_variadic_internal (param $f anyref) (param $g anyref) (param $more anyref) (result anyref)
    (call $reduce_no_init (global.get $__fn_comp) (call $cons (local.get $f) (call $cons (local.get $g) (local.get $more)))))

  (func $__export_comp_variadic (export "comp_variadic") (param $f i32) (param $g i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $comp_variadic_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g)) (ref.i31 (local.get $more)))))

  (func $partial_arity1_internal (param $f anyref) (result anyref)
    (local.get $f))

  (func $__export_partial_arity1 (export "partial_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $partial_arity1_internal (ref.i31 (local.get $f)))))

  (func $anon_multi50_arity0 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (return_call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0))))

  (func $anon_multi50_arity1 (type $ClosureFunc1) (param $__env anyref) (param $b anyref) (result anyref)
    (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0)) (local.get $b)))

  (func $anon_multi50_arity2 (type $ClosureFunc2) (param $__env anyref) (param $b anyref) (param $c anyref) (result anyref)
    (return_call $invoke3 (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0)) (local.get $b) (local.get $c)))

  (func $anon_multi50_arity3 (type $ClosureFunc3) (param $__env anyref) (param $b anyref) (param $c anyref) (param $d anyref) (result anyref)
    (return_call $invoke4 (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0)) (local.get $b) (local.get $c) (local.get $d)))

  (func $anon_multi50_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 0))
      (then
      (call $anon_multi50_arity0 (local.get $__env)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi50_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi50_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 3))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a2 (call $first (local.get $args)))
      (call $anon_multi50_arity3 (local.get $__env) (local.get $a0) (local.get $a1) (local.get $a2)))
      (else (unreachable))))))))))

  (func $partial_arity2_internal (param $f anyref) (param $a anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $a)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $f)) (local.get $__tmp_env)) (ref.func $anon_multi50_dispatch)))

  (func $__export_partial_arity2 (export "partial_arity2") (param $f i32) (param $a i32) (result i32)
    (call $unbox_i32 (call $partial_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $a)))))

  (func $anon_multi51_arity0 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 2)) (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1))))

  (func $anon_multi51_arity1 (type $ClosureFunc1) (param $__env anyref) (param $c anyref) (result anyref)
    (return_call $invoke3 (call $array_get (local.get $__env) (i32.const 2)) (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1)) (local.get $c)))

  (func $anon_multi51_arity2 (type $ClosureFunc2) (param $__env anyref) (param $c anyref) (param $d anyref) (result anyref)
    (return_call $invoke4 (call $array_get (local.get $__env) (i32.const 2)) (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1)) (local.get $c) (local.get $d)))

  (func $anon_multi51_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 0))
      (then
      (call $anon_multi51_arity0 (local.get $__env)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi51_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi51_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (unreachable))))))))

  (func $partial_arity3_internal (param $f anyref) (param $a anyref) (param $b anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $a)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $b)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $f)) (local.get $__tmp_env)) (ref.func $anon_multi51_dispatch)))

  (func $__export_partial_arity3 (export "partial_arity3") (param $f i32) (param $a i32) (param $b i32) (result i32)
    (call $unbox_i32 (call $partial_arity3_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $a)) (ref.i31 (local.get $b)))))

  (func $anon_multi52_arity0 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (return_call $invoke3 (call $array_get (local.get $__env) (i32.const 3)) (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 2))))

  (func $anon_multi52_arity1 (type $ClosureFunc1) (param $__env anyref) (param $d anyref) (result anyref)
    (return_call $invoke4 (call $array_get (local.get $__env) (i32.const 3)) (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 2)) (local.get $d)))

  (func $anon_multi52_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 0))
      (then
      (call $anon_multi52_arity0 (local.get $__env)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi52_arity1 (local.get $__env) (local.get $a0)))
      (else (unreachable))))))

  (func $partial_arity4_internal (param $f anyref) (param $a anyref) (param $b anyref) (param $c anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 4))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $a)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $b)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $c)) (call $array_set (local.get $__tmp_env) (i32.const 3) (local.get $f)) (local.get $__tmp_env)) (ref.func $anon_multi52_dispatch)))

  (func $__export_partial_arity4 (export "partial_arity4") (param $f i32) (param $a i32) (param $b i32) (param $c i32) (result i32)
    (call $unbox_i32 (call $partial_arity4_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $a)) (ref.i31 (local.get $b)) (ref.i31 (local.get $c)))))

  (func $anon_multi53_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))) (then (global.get $__true)) (else (global.get $__false))))

  (func $anon_multi53_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x) (local.get $y)))) (then (global.get $__true)) (else (global.get $__false))))

  (func $anon_multi53_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi53_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi53_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (unreachable))))))

  (func $complement_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env)) (ref.func $anon_multi53_dispatch)))

  (func $__export_complement (export "complement") (param $f i32) (result i32)
    (call $unbox_i32 (call $complement_internal (ref.i31 (local.get $f)))))

  (func $anon_multi54_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (call $conj (call $empty_vector) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))))

  (func $anon_multi54_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (call $conj (call $conj (call $empty_vector) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))

  (func $anon_multi54_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi54_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi54_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (unreachable))))))

  (func $juxt_arity1_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env)) (ref.func $anon_multi54_dispatch)))

  (func $__export_juxt_arity1 (export "juxt_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $juxt_arity1_internal (ref.i31 (local.get $f)))))

  (func $anon_multi55_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (call $conj (call $conj (call $empty_vector) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))

  (func $anon_multi55_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (call $conj (call $conj (call $empty_vector) (call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x) (local.get $y))) (call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x) (local.get $y))))

  (func $anon_multi55_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi55_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi55_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (unreachable))))))

  (func $juxt_arity2_internal (param $f anyref) (param $g anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g)) (local.get $__tmp_env)) (ref.func $anon_multi55_dispatch)))

  (func $__export_juxt_arity2 (export "juxt_arity2") (param $f i32) (param $g i32) (result i32)
    (call $unbox_i32 (call $juxt_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g)))))

  (func $anon_multi56_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (call $conj (call $conj (call $conj (call $empty_vector) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))) (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))

  (func $anon_multi56_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (call $conj (call $conj (call $conj (call $empty_vector) (call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x) (local.get $y))) (call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x) (local.get $y))) (call $invoke2 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x) (local.get $y))))

  (func $anon_multi56_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi56_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi56_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (unreachable))))))

  (func $juxt_arity3_internal (param $f anyref) (param $g anyref) (param $h anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $h)) (local.get $__tmp_env)) (ref.func $anon_multi56_dispatch)))

  (func $__export_juxt_arity3 (export "juxt_arity3") (param $f i32) (param $g i32) (param $h i32) (result i32)
    (call $unbox_i32 (call $juxt_arity3_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g)) (ref.i31 (local.get $h)))))

  (func $range_arity0_internal  (result anyref)
    (return_call $range_from_arity1_internal (ref.i31 (i32.const 0))))

  (func $__export_range_arity0 (export "range_arity0")  (result i32)
    (call $unbox_i32 (call $range_arity0_internal )))

  (func $range_arity1_internal (param $end anyref) (result anyref)
    (return_call $range_from_arity3_internal (ref.i31 (i32.const 0)) (local.get $end) (ref.i31 (i32.const 1))))

  (func $__export_range_arity1 (export "range_arity1") (param $end i32) (result i32)
    (call $unbox_i32 (call $range_arity1_internal (ref.i31 (local.get $end)))))

  (func $range_arity2_internal (param $start anyref) (param $end anyref) (result anyref)
    (return_call $range_from_arity3_internal (local.get $start) (local.get $end) (ref.i31 (i32.const 1))))

  (func $__export_range_arity2 (export "range_arity2") (param $start i32) (param $end i32) (result i32)
    (call $unbox_i32 (call $range_arity2_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)))))

  (func $range_arity3_internal (param $start anyref) (param $end anyref) (param $step anyref) (result anyref)
    (return_call $range_from_arity3_internal (local.get $start) (local.get $end) (local.get $step)))

  (func $__export_range_arity3 (export "range_arity3") (param $start i32) (param $end i32) (param $step i32) (result i32)
    (call $unbox_i32 (call $range_arity3_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)) (ref.i31 (local.get $step)))))

  (func $closure57 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $array_get (local.get $__env) (i32.const 0)) (call $repeat_infinite_internal (call $array_get (local.get $__env) (i32.const 0)))))

  (func $repeat_infinite_internal (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure57) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $x)) (local.get $__tmp_env)))))

  (func $__export_repeat_infinite (export "repeat-infinite") (param $x i32) (result i32)
    (call $unbox_i32 (call $repeat_infinite_internal (ref.i31 (local.get $x)))))

  (func $closure58 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (call $array_get (local.get $__env) (i32.const 0)) (ref.i31 (i32.const 0))))) (then (call $cons (call $array_get (local.get $__env) (i32.const 1)) (call $repeat_n_internal (call $dec (call $array_get (local.get $__env) (i32.const 0))) (call $array_get (local.get $__env) (i32.const 1))))) (else (ref.null none))))

  (func $repeat_n_internal (param $n anyref) (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure58) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $n)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $x)) (local.get $__tmp_env)))))

  (func $__export_repeat_n (export "repeat-n") (param $n i32) (param $x i32) (result i32)
    (call $unbox_i32 (call $repeat_n_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $x)))))

  (func $repeat_arity1_internal (param $x anyref) (result anyref)
    (return_call $repeat_infinite_internal (local.get $x)))

  (func $__export_repeat_arity1 (export "repeat_arity1") (param $x i32) (result i32)
    (call $unbox_i32 (call $repeat_arity1_internal (ref.i31 (local.get $x)))))

  (func $repeat_arity2_internal (param $n anyref) (param $x anyref) (result anyref)
    (return_call $repeat_n_internal (local.get $n) (local.get $x)))

  (func $__export_repeat_arity2 (export "repeat_arity2") (param $n i32) (param $x i32) (result i32)
    (call $unbox_i32 (call $repeat_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $x)))))

  (func $closure59 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $invoke0 (call $array_get (local.get $__env) (i32.const 0))) (call $repeatedly_infinite_internal (call $array_get (local.get $__env) (i32.const 0)))))

  (func $repeatedly_infinite_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure59) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env)))))

  (func $__export_repeatedly_infinite (export "repeatedly-infinite") (param $f i32) (result i32)
    (call $unbox_i32 (call $repeatedly_infinite_internal (ref.i31 (local.get $f)))))

  (func $closure60 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (call $array_get (local.get $__env) (i32.const 1)) (ref.i31 (i32.const 0))))) (then (call $cons (call $invoke0 (call $array_get (local.get $__env) (i32.const 0))) (call $repeatedly_n_internal (call $dec (call $array_get (local.get $__env) (i32.const 1))) (call $array_get (local.get $__env) (i32.const 0))))) (else (ref.null none))))

  (func $repeatedly_n_internal (param $n anyref) (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure60) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $n)) (local.get $__tmp_env)))))

  (func $__export_repeatedly_n (export "repeatedly-n") (param $n i32) (param $f i32) (result i32)
    (call $unbox_i32 (call $repeatedly_n_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $f)))))

  (func $repeatedly_arity1_internal (param $f anyref) (result anyref)
    (return_call $repeatedly_infinite_internal (local.get $f)))

  (func $__export_repeatedly_arity1 (export "repeatedly_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $repeatedly_arity1_internal (ref.i31 (local.get $f)))))

  (func $repeatedly_arity2_internal (param $n anyref) (param $f anyref) (result anyref)
    (return_call $repeatedly_n_internal (local.get $n) (local.get $f)))

  (func $__export_repeatedly_arity2 (export "repeatedly_arity2") (param $n i32) (param $f i32) (result i32)
    (call $unbox_i32 (call $repeatedly_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $f)))))

  (func $closure61 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $array_get (local.get $__env) (i32.const 1)) (call $iterate_internal (call $array_get (local.get $__env) (i32.const 0)) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1))))))

  (func $iterate_internal (param $f anyref) (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure61) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $x)) (local.get $__tmp_env)))))

  (func $__export_iterate (export "iterate") (param $f i32) (param $x i32) (result i32)
    (call $unbox_i32 (call $iterate_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $x)))))

  (func $into_arity2_internal (param $to anyref) (param $from anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $vector_QMARK_ (local.get $to))) (then (call $vector_QMARK_ (local.get $to))) (else (call $map_QMARK_ (local.get $to))))) (then (if (result anyref) (call $truthy (call $vector_QMARK_ (local.get $to))) (then (call $vector_QMARK_ (local.get $to))) (else (call $map_QMARK_ (local.get $to))))) (else (call $set_QMARK_ (local.get $to))))) (then (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (global.get $__builtin_conj_BANG_) (call $invoke1 (global.get $__builtin_transient) (local.get $to)) (call $seq (local.get $from))))) (else (block (result anyref) (local.set $result (local.get $to)) (local.set $remaining (call $seq (local.get $from))) (loop $loop6 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $remaining))) (then (local.get $result)) (else (call $conj (local.get $result) (call $first (local.get $remaining)))
      (call $seq (call $rest (local.get $remaining)))
      (local.set $remaining)
      (local.set $result)
      (br $loop6))))))))

  (func $__export_into_arity2 (export "into_arity2") (param $to i32) (param $from i32) (result i32)
    (call $unbox_i32 (call $into_arity2_internal (ref.i31 (local.get $to)) (ref.i31 (local.get $from)))))

  (func $into_arity3_internal (param $to anyref) (param $xform anyref) (param $from anyref) (result anyref)
    (local $xf anyref)
    (local $result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $vector_QMARK_ (local.get $to))) (then (call $vector_QMARK_ (local.get $to))) (else (call $map_QMARK_ (local.get $to))))) (then (if (result anyref) (call $truthy (call $vector_QMARK_ (local.get $to))) (then (call $vector_QMARK_ (local.get $to))) (else (call $map_QMARK_ (local.get $to))))) (else (call $set_QMARK_ (local.get $to))))) (then (block (result anyref) (local.set $xf (call $invoke1 (local.get $xform) (global.get $__builtin_conj_BANG_))) (local.set $result (call $reduce (local.get $xf) (call $invoke1 (global.get $__builtin_transient) (local.get $to)) (call $seq (local.get $from)))) (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $xf_complete_internal (local.get $xf) (local.get $result))))) (else (block (result anyref) (local.set $xf (call $invoke1 (local.get $xform) (global.get $__builtin_conj))) (local.set $result (call $reduce (local.get $xf) (local.get $to) (call $seq (local.get $from)))) (return_call $xf_complete_internal (local.get $xf) (local.get $result))))))

  (func $__export_into_arity3 (export "into_arity3") (param $to i32) (param $xform i32) (param $from i32) (result i32)
    (call $unbox_i32 (call $into_arity3_internal (ref.i31 (local.get $to)) (ref.i31 (local.get $xform)) (ref.i31 (local.get $from)))))

  (func $zipmap_internal (param $keys anyref) (param $vals anyref) (result anyref)
    (local $result anyref)
    (local $ks anyref)
    (local $vs anyref)
    (block (result anyref) (local.set $result (call $invoke1 (global.get $__builtin_transient) (call $empty_hash_map))) (local.set $ks (call $seq (local.get $keys))) (local.set $vs (call $seq (local.get $vals))) (loop $loop7 (result anyref) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $ks))) (then (call $nil_QMARK_ (local.get $ks))) (else (call $nil_QMARK_ (local.get $vs))))) (then (call $invoke1 (global.get $__builtin_persistent_BANG_) (local.get $result))) (else (call $invoke3 (global.get $__builtin_assoc_BANG_) (local.get $result) (call $first (local.get $ks)) (call $first (local.get $vs)))
      (call $seq (call $rest (local.get $ks)))
      (call $seq (call $rest (local.get $vs)))
      (local.set $vs)
      (local.set $ks)
      (local.set $result)
      (br $loop7))))))

  (func $__export_zipmap (export "zipmap") (param $keys i32) (param $vals i32) (result i32)
    (call $unbox_i32 (call $zipmap_internal (ref.i31 (local.get $keys)) (ref.i31 (local.get $vals)))))

  (func $doall_internal (param $coll anyref) (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (loop $loop8 (result anyref) (if (result anyref) (call $truthy (local.get $s)) (then (call $seq (call $rest (local.get $s)))
      (local.set $s)
      (br $loop8)) (else (local.get $coll))))))

  (func $__export_doall (export "doall") (param $coll i32) (result i32)
    (call $unbox_i32 (call $doall_internal (ref.i31 (local.get $coll)))))

  (func $dorun_internal (param $coll anyref) (result anyref)
    (local $s anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (loop $loop9 (result anyref) (if (result anyref) (call $truthy (local.get $s)) (then (call $seq (call $rest (local.get $s)))
      (local.set $s)
      (br $loop9)) (else (ref.null none))))))

  (func $__export_dorun (export "dorun") (param $coll i32) (result i32)
    (call $unbox_i32 (call $dorun_internal (ref.i31 (local.get $coll)))))

  (func $vary_meta_internal (param $obj anyref) (param $f anyref) (result anyref)
    (call $with_meta_ (local.get $obj) (call $invoke1 (local.get $f) (call $meta_ (local.get $obj)))))

  (func $__export_vary_meta (export "vary-meta") (param $obj i32) (param $f i32) (result i32)
    (call $unbox_i32 (call $vary_meta_internal (ref.i31 (local.get $obj)) (ref.i31 (local.get $f)))))

  (func $volatile_BANG__internal (param $x anyref) (result anyref)
    (call $atom (local.get $x)))

  (func $__export_volatile_BANG_ (export "volatile!") (param $x i32) (result i32)
    (call $unbox_i32 (call $volatile_BANG__internal (ref.i31 (local.get $x)))))

  (func $vreset_BANG__internal (param $v anyref) (param $newval anyref) (result anyref)
    (call $reset_BANG_ (local.get $v) (local.get $newval)))

  (func $__export_vreset_BANG_ (export "vreset!") (param $v i32) (param $newval i32) (result i32)
    (call $unbox_i32 (call $vreset_BANG__internal (ref.i31 (local.get $v)) (ref.i31 (local.get $newval)))))

  (func $vswap_BANG__arity2_internal (param $v anyref) (param $f anyref) (result anyref)
    (call $swap_BANG_ (local.get $v) (local.get $f)))

  (func $__export_vswap_BANG__arity2 (export "vswap_BANG__arity2") (param $v i32) (param $f i32) (result i32)
    (call $unbox_i32 (call $vswap_BANG__arity2_internal (ref.i31 (local.get $v)) (ref.i31 (local.get $f)))))

  (func $vswap_BANG__arity3_internal (param $v anyref) (param $f anyref) (param $x anyref) (result anyref)
    (call $reset_BANG_ (local.get $v) (call $invoke2 (local.get $f) (call $deref (local.get $v)) (local.get $x))))

  (func $__export_vswap_BANG__arity3 (export "vswap_BANG__arity3") (param $v i32) (param $f i32) (param $x i32) (result i32)
    (call $unbox_i32 (call $vswap_BANG__arity3_internal (ref.i31 (local.get $v)) (ref.i31 (local.get $f)) (ref.i31 (local.get $x)))))

  (func $vswap_BANG__arity4_internal (param $v anyref) (param $f anyref) (param $x anyref) (param $y anyref) (result anyref)
    (call $reset_BANG_ (local.get $v) (call $invoke3 (local.get $f) (call $deref (local.get $v)) (local.get $x) (local.get $y))))

  (func $__export_vswap_BANG__arity4 (export "vswap_BANG__arity4") (param $v i32) (param $f i32) (param $x i32) (param $y i32) (result i32)
    (call $unbox_i32 (call $vswap_BANG__arity4_internal (ref.i31 (local.get $v)) (ref.i31 (local.get $f)) (ref.i31 (local.get $x)) (ref.i31 (local.get $y)))))

  (func $any_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__true))

  (func $__export_any_QMARK_ (export "any?") (param $x i32) (result i32)
    (call $unbox_i32 (call $any_QMARK__internal (ref.i31 (local.get $x)))))

  (func $rem_internal (param $n anyref) (param $d anyref) (result anyref)
    (local $q anyref)
    (block (result anyref) (local.set $q (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $integer_QMARK_ (local.get $n))) (then (call $integer_QMARK_ (local.get $d))) (else (call $integer_QMARK_ (local.get $n))))) (then (call $div (local.get $n) (local.get $d))) (else (if (result anyref) (ref.test (ref i31) (call $div (local.get $n) (local.get $d))) (then (call $div (local.get $n) (local.get $d))) (else (ref.i31 (i32.trunc_sat_f64_s (f64.trunc (call $to_f64 (call $div (local.get $n) (local.get $d))))))))))) (call $sub (local.get $n) (call $mul (local.get $q) (local.get $d)))))

  (func $__export_rem (export "rem") (param $n i32) (param $d i32) (result i32)
    (call $unbox_i32 (call $rem_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $d)))))

  (func $mod_internal (param $n anyref) (param $d anyref) (result anyref)
    (local $r anyref)
    (block (result anyref) (local.set $r (call $rem_internal (local.get $n) (local.get $d))) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $zero_QMARK_ (local.get $r))) (then (call $zero_QMARK_ (local.get $r))) (else (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (local.get $d) (ref.i31 (i32.const 0))))) (then (call $cmp_gt (local.get $r) (ref.i31 (i32.const 0)))) (else (call $cmp_lt (local.get $r) (ref.i31 (i32.const 0)))))))) (then (local.get $r)) (else (call $add (local.get $r) (local.get $d))))))

  (func $__export_mod (export "mod") (param $n i32) (param $d i32) (result i32)
    (call $unbox_i32 (call $mod_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $d)))))

  (func $abs_internal (param $n anyref) (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_lt (local.get $n) (ref.i31 (i32.const 0))))) (then (call $sub (ref.i31 (i32.const 0)) (local.get $n))) (else (local.get $n))))

  (func $__export_abs (export "abs") (param $n i32) (result i32)
    (call $unbox_i32 (call $abs_internal (ref.i31 (local.get $n)))))

  (func $min_arity1_internal (param $a anyref) (result anyref)
    (local.get $a))

  (func $__export_min_arity1 (export "min_arity1") (param $a i32) (result i32)
    (call $unbox_i32 (call $min_arity1_internal (ref.i31 (local.get $a)))))

  (func $min_arity2_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_lt (local.get $a) (local.get $b)))) (then (local.get $a)) (else (local.get $b))))

  (func $__export_min_arity2 (export "min_arity2") (param $a i32) (param $b i32) (result i32)
    (call $unbox_i32 (call $min_arity2_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b)))))

  (func $min_variadic_internal (param $a anyref) (param $b anyref) (param $more anyref) (result anyref)
    (call $reduce (global.get $__fn_min) (call $min_arity2_internal (local.get $a) (local.get $b)) (local.get $more)))

  (func $__export_min_variadic (export "min_variadic") (param $a i32) (param $b i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $min_variadic_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b)) (ref.i31 (local.get $more)))))

  (func $max_arity1_internal (param $a anyref) (result anyref)
    (local.get $a))

  (func $__export_max_arity1 (export "max_arity1") (param $a i32) (result i32)
    (call $unbox_i32 (call $max_arity1_internal (ref.i31 (local.get $a)))))

  (func $max_arity2_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_gt (local.get $a) (local.get $b)))) (then (local.get $a)) (else (local.get $b))))

  (func $__export_max_arity2 (export "max_arity2") (param $a i32) (param $b i32) (result i32)
    (call $unbox_i32 (call $max_arity2_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b)))))

  (func $max_variadic_internal (param $a anyref) (param $b anyref) (param $more anyref) (result anyref)
    (call $reduce (global.get $__fn_max) (call $max_arity2_internal (local.get $a) (local.get $b)) (local.get $more)))

  (func $__export_max_variadic (export "max_variadic") (param $a i32) (param $b i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $max_variadic_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b)) (ref.i31 (local.get $more)))))

  (func $_PLUS__arity0_internal  (result anyref)
    (ref.i31 (i32.const 0)))

  (func $__export__PLUS__arity0 (export "_PLUS__arity0")  (result i32)
    (call $unbox_i32 (call $_PLUS__arity0_internal )))

  (func $_PLUS__arity1_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export__PLUS__arity1 (export "_PLUS__arity1") (param $x i32) (result i32)
    (call $unbox_i32 (call $_PLUS__arity1_internal (ref.i31 (local.get $x)))))

  (func $_PLUS__arity2_internal (param $x anyref) (param $y anyref) (result anyref)
    (call $add (local.get $x) (local.get $y)))

  (func $__export__PLUS__arity2 (export "_PLUS__arity2") (param $x i32) (param $y i32) (result i32)
    (call $unbox_i32 (call $_PLUS__arity2_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $y)))))

  (func $_PLUS__variadic_internal (param $x anyref) (param $y anyref) (param $more anyref) (result anyref)
    (call $reduce (global.get $__fn__PLUS_) (call $add (local.get $x) (local.get $y)) (local.get $more)))

  (func $__export__PLUS__variadic (export "_PLUS__variadic") (param $x i32) (param $y i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $_PLUS__variadic_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $y)) (ref.i31 (local.get $more)))))

  (func $_MINUS__arity1_internal (param $x anyref) (result anyref)
    (call $sub (ref.i31 (i32.const 0)) (local.get $x)))

  (func $__export__MINUS__arity1 (export "_MINUS__arity1") (param $x i32) (result i32)
    (call $unbox_i32 (call $_MINUS__arity1_internal (ref.i31 (local.get $x)))))

  (func $_MINUS__arity2_internal (param $x anyref) (param $y anyref) (result anyref)
    (call $sub (local.get $x) (local.get $y)))

  (func $__export__MINUS__arity2 (export "_MINUS__arity2") (param $x i32) (param $y i32) (result i32)
    (call $unbox_i32 (call $_MINUS__arity2_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $y)))))

  (func $_MINUS__variadic_internal (param $x anyref) (param $y anyref) (param $more anyref) (result anyref)
    (call $reduce (global.get $__fn__MINUS_) (call $sub (local.get $x) (local.get $y)) (local.get $more)))

  (func $__export__MINUS__variadic (export "_MINUS__variadic") (param $x i32) (param $y i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $_MINUS__variadic_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $y)) (ref.i31 (local.get $more)))))

  (func $_STAR__arity0_internal  (result anyref)
    (ref.i31 (i32.const 1)))

  (func $__export__STAR__arity0 (export "_STAR__arity0")  (result i32)
    (call $unbox_i32 (call $_STAR__arity0_internal )))

  (func $_STAR__arity1_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export__STAR__arity1 (export "_STAR__arity1") (param $x i32) (result i32)
    (call $unbox_i32 (call $_STAR__arity1_internal (ref.i31 (local.get $x)))))

  (func $_STAR__arity2_internal (param $x anyref) (param $y anyref) (result anyref)
    (call $mul (local.get $x) (local.get $y)))

  (func $__export__STAR__arity2 (export "_STAR__arity2") (param $x i32) (param $y i32) (result i32)
    (call $unbox_i32 (call $_STAR__arity2_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $y)))))

  (func $_STAR__variadic_internal (param $x anyref) (param $y anyref) (param $more anyref) (result anyref)
    (call $reduce (global.get $__fn__STAR_) (call $mul (local.get $x) (local.get $y)) (local.get $more)))

  (func $__export__STAR__variadic (export "_STAR__variadic") (param $x i32) (param $y i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $_STAR__variadic_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $y)) (ref.i31 (local.get $more)))))

  (func $sort_with_cmp_internal (param $cmp anyref) (param $coll anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (local $acc anyref)
    (local $left anyref)
    (local $x anyref)
    (block (result anyref) (local.set $result (ref.null none)) (local.set $remaining (call $seq (local.get $coll))) (loop $loop10 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $remaining))) (then (local.get $result)) (else (block (result anyref) (local.set $acc (ref.null none)) (local.set $left (local.get $result)) (local.set $x (call $first (local.get $remaining))) (loop $loop11 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $left))) (then (call $reverse_internal (call $cons (local.get $x) (local.get $acc)))) (else (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_lt (call $invoke2 (local.get $cmp) (local.get $x) (call $first (local.get $left))) (ref.i31 (i32.const 0))))) (then (call $concat_arity2_internal (call $reverse_internal (call $cons (local.get $x) (local.get $acc))) (local.get $left))) (else (call $cons (call $first (local.get $left)) (local.get $acc))
      (call $rest (local.get $left))
      (local.get $x)
      (local.set $x)
      (local.set $left)
      (local.set $acc)
      (br $loop11)))))))
      (call $seq (call $rest (local.get $remaining)))
      (local.set $remaining)
      (local.set $result)
      (br $loop10))))))

  (func $__export_sort_with_cmp (export "sort-with-cmp") (param $cmp i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $sort_with_cmp_internal (ref.i31 (local.get $cmp)) (ref.i31 (local.get $coll)))))

  (func $sort_arity1_internal (param $coll anyref) (result anyref)
    (return_call $sort_with_cmp_internal (global.get $__builtin_compare) (local.get $coll)))

  (func $__export_sort_arity1 (export "sort_arity1") (param $coll i32) (result i32)
    (call $unbox_i32 (call $sort_arity1_internal (ref.i31 (local.get $coll)))))

  (func $sort_arity2_internal (param $cmp anyref) (param $coll anyref) (result anyref)
    (return_call $sort_with_cmp_internal (local.get $cmp) (local.get $coll)))

  (func $__export_sort_arity2 (export "sort_arity2") (param $cmp i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $sort_arity2_internal (ref.i31 (local.get $cmp)) (ref.i31 (local.get $coll)))))

  (func $int_QMARK__internal (param $x anyref) (result anyref)
    (return_call $integer_QMARK_ (local.get $x)))

  (func $__export_int_QMARK_ (export "int?") (param $x i32) (result i32)
    (call $unbox_i32 (call $int_QMARK__internal (ref.i31 (local.get $x)))))

  (func $double_QMARK__internal (param $x anyref) (result anyref)
    (return_call $float_QMARK_ (local.get $x)))

  (func $__export_double_QMARK_ (export "double?") (param $x i32) (result i32)
    (call $unbox_i32 (call $double_QMARK__internal (ref.i31 (local.get $x)))))

  (func $boolean_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $true_QMARK_ (local.get $x))) (then (call $true_QMARK_ (local.get $x))) (else (call $false_QMARK_ (local.get $x)))))

  (func $__export_boolean_QMARK_ (export "boolean?") (param $x i32) (result i32)
    (call $unbox_i32 (call $boolean_QMARK__internal (ref.i31 (local.get $x)))))

  (func $ratio_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__false))

  (func $__export_ratio_QMARK_ (export "ratio?") (param $x i32) (result i32)
    (call $unbox_i32 (call $ratio_QMARK__internal (ref.i31 (local.get $x)))))

  (func $rational_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $integer_QMARK_ (local.get $x))) (then (call $integer_QMARK_ (local.get $x))) (else (call $ratio_QMARK__internal (local.get $x)))))

  (func $__export_rational_QMARK_ (export "rational?") (param $x i32) (result i32)
    (call $unbox_i32 (call $rational_QMARK__internal (ref.i31 (local.get $x)))))

  (func $big_int_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__false))

  (func $__export_big_int_QMARK_ (export "big-int?") (param $x i32) (result i32)
    (call $unbox_i32 (call $big_int_QMARK__internal (ref.i31 (local.get $x)))))

  (func $char_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__false))

  (func $__export_char_QMARK_ (export "char?") (param $x i32) (result i32)
    (call $unbox_i32 (call $char_QMARK__internal (ref.i31 (local.get $x)))))

  (func $val_internal (param $entry anyref) (result anyref)
    (call $first (call $rest (local.get $entry))))

  (func $__export_val (export "val") (param $entry i32) (result i32)
    (call $unbox_i32 (call $val_internal (ref.i31 (local.get $entry)))))

  (func $key_internal (param $entry anyref) (result anyref)
    (call $first (local.get $entry)))

  (func $__export_key (export "key") (param $entry i32) (result i32)
    (call $unbox_i32 (call $key_internal (ref.i31 (local.get $entry)))))

  (func $make_hierarchy_internal  (result anyref)
    (call $hash_map_assoc (call $hash_map_assoc (call $hash_map_assoc (call $empty_hash_map) (struct.new $Keyword (i32.const 2) (i32.const 1)) (call $empty_hash_map)) (struct.new $Keyword (i32.const 2) (i32.const 2)) (call $empty_hash_map)) (struct.new $Keyword (i32.const 2) (i32.const 3)) (call $empty_hash_map)))

  (func $__export_make_hierarchy (export "make-hierarchy")  (result i32)
    (call $unbox_i32 (call $make_hierarchy_internal )))

  (func $__init_def_global_hierarchy (result anyref)
    (call $atom (call $make_hierarchy_internal)))

  (func $closure62 (type $ClosureFunc2) (param $__env anyref) (param $am anyref) (param $desc anyref) (result anyref)
    (local $desc_anc anyref)
    (block (result anyref) (local.set $desc_anc (call $hash_map_get_default (local.get $am) (local.get $desc) (call $empty_hash_set))) (call $assoc (local.get $am) (local.get $desc) (call $union_internal (local.get $desc_anc) (call $array_get (local.get $__env) (i32.const 0))))))

  (func $closure63 (type $ClosureFunc2) (param $__env anyref) (param $dm anyref) (param $anc anyref) (result anyref)
    (local $anc_desc anyref)
    (block (result anyref) (local.set $anc_desc (call $hash_map_get_default (local.get $dm) (local.get $anc) (call $empty_hash_set))) (call $assoc (local.get $dm) (local.get $anc) (call $union_internal (local.get $anc_desc) (call $array_get (local.get $__env) (i32.const 0))))))

  (func $hierarchy_derive_internal (param $h anyref) (param $tag anyref) (param $parent anyref) (result anyref)
    (local $cur_parents anyref)
    (local $cur_ancestors anyref)
    (local $_ anyref)
    (local $parent_ancestors anyref)
    (local $new_ancestors anyref)
    (local $new_parents_map anyref)
    (local $tag_descendants anyref)
    (local $new_ancestors_map anyref)
    (local $new_parent_set anyref)
    (local $new_descendants_map anyref)
    (local $__tmp_env anyref)
    (if (result anyref) (call $eq (local.get $tag) (local.get $parent)) (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (global.get $__str_0) (call $hash_map_assoc (call $empty_hash_map) (struct.new $Keyword (i32.const 2) (i32.const 4)) (local.get $tag)) (ref.null none)))
      (unreachable)) (else (block (result anyref) (local.set $cur_parents (call $hash_map_get_default (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 1))) (local.get $tag) (call $empty_hash_set))) (local.set $cur_ancestors (call $hash_map_get_default (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 2))) (local.get $tag) (call $empty_hash_set))) (if (result anyref) (call $truthy (call $contains_QMARK_ (local.get $cur_parents) (local.get $parent))) (then (local.get $h)) (else (block (result anyref) (local.set $_ (if (result anyref) (call $truthy (call $contains_QMARK_ (call $hash_map_get_default (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 2))) (local.get $parent) (call $empty_hash_set)) (local.get $tag))) (then (throw $exn (struct.new $ExceptionInfo (i32.const 100) (global.get $__str_1) (call $hash_map_assoc (call $hash_map_assoc (call $empty_hash_map) (struct.new $Keyword (i32.const 2) (i32.const 4)) (local.get $tag)) (struct.new $Keyword (i32.const 2) (i32.const 5)) (local.get $parent)) (ref.null none)))
      (unreachable)) (else (ref.null none)))) (local.set $parent_ancestors (call $hash_map_get_default (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 2))) (local.get $parent) (call $empty_hash_set))) (local.set $new_ancestors (call $set_conj (call $union_internal (local.get $cur_ancestors) (local.get $parent_ancestors)) (local.get $parent))) (local.set $new_parents_map (call $assoc (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 1))) (local.get $tag) (call $set_conj (local.get $cur_parents) (local.get $parent)))) (local.set $tag_descendants (call $set_conj (call $hash_map_get_default (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 3))) (local.get $tag) (call $empty_hash_set)) (local.get $tag))) (local.set $new_ancestors_map (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure62) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $new_ancestors)) (local.get $__tmp_env))) (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 2))) (local.get $tag_descendants))) (local.set $new_parent_set (call $set_conj (local.get $parent_ancestors) (local.get $parent))) (local.set $new_descendants_map (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure63) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $tag_descendants)) (local.get $__tmp_env))) (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 3))) (local.get $new_parent_set))) (call $hash_map_assoc (call $hash_map_assoc (call $hash_map_assoc (call $empty_hash_map) (struct.new $Keyword (i32.const 2) (i32.const 1)) (local.get $new_parents_map)) (struct.new $Keyword (i32.const 2) (i32.const 2)) (local.get $new_ancestors_map)) (struct.new $Keyword (i32.const 2) (i32.const 3)) (local.get $new_descendants_map)))))))))

  (func $__export_hierarchy_derive (export "hierarchy-derive") (param $h i32) (param $tag i32) (param $parent i32) (result i32)
    (call $unbox_i32 (call $hierarchy_derive_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)) (ref.i31 (local.get $parent)))))

  (func $closure64 (type $ClosureFunc1) (param $__env anyref) (param $h anyref) (result anyref)
    (return_call $hierarchy_derive_internal (local.get $h) (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0))))

  (func $derive_arity2_internal (param $tag anyref) (param $parent anyref) (result anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (drop (call $swap_BANG_ (global.get $global_hierarchy) (struct.new $Closure1 (i32.const 11) (ref.func $closure64) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $parent)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $tag)) (local.get $__tmp_env))))) (ref.null none)))

  (func $__export_derive_arity2 (export "derive_arity2") (param $tag i32) (param $parent i32) (result i32)
    (call $unbox_i32 (call $derive_arity2_internal (ref.i31 (local.get $tag)) (ref.i31 (local.get $parent)))))

  (func $derive_arity3_internal (param $h anyref) (param $tag anyref) (param $parent anyref) (result anyref)
    (return_call $hierarchy_derive_internal (local.get $h) (local.get $tag) (local.get $parent)))

  (func $__export_derive_arity3 (export "derive_arity3") (param $h i32) (param $tag i32) (param $parent i32) (result i32)
    (call $unbox_i32 (call $derive_arity3_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)) (ref.i31 (local.get $parent)))))

  (func $parents_arity1_internal (param $tag anyref) (result anyref)
    (return_call $parents_arity2_internal (call $deref (global.get $global_hierarchy)) (local.get $tag)))

  (func $__export_parents_arity1 (export "parents_arity1") (param $tag i32) (result i32)
    (call $unbox_i32 (call $parents_arity1_internal (ref.i31 (local.get $tag)))))

  (func $parents_arity2_internal (param $h anyref) (param $tag anyref) (result anyref)
    (local $p anyref)
    (block (result anyref) (local.set $p (call $hash_map_get (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 1))) (local.get $tag))) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $p))) (then (call $nil_QMARK_ (local.get $p))) (else (call $empty_QMARK_ (local.get $p))))) (then (ref.null none)) (else (local.get $p)))))

  (func $__export_parents_arity2 (export "parents_arity2") (param $h i32) (param $tag i32) (result i32)
    (call $unbox_i32 (call $parents_arity2_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)))))

  (func $ancestors_arity1_internal (param $tag anyref) (result anyref)
    (return_call $ancestors_arity2_internal (call $deref (global.get $global_hierarchy)) (local.get $tag)))

  (func $__export_ancestors_arity1 (export "ancestors_arity1") (param $tag i32) (result i32)
    (call $unbox_i32 (call $ancestors_arity1_internal (ref.i31 (local.get $tag)))))

  (func $ancestors_arity2_internal (param $h anyref) (param $tag anyref) (result anyref)
    (local $a anyref)
    (block (result anyref) (local.set $a (call $hash_map_get (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 2))) (local.get $tag))) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $a))) (then (call $nil_QMARK_ (local.get $a))) (else (call $empty_QMARK_ (local.get $a))))) (then (ref.null none)) (else (local.get $a)))))

  (func $__export_ancestors_arity2 (export "ancestors_arity2") (param $h i32) (param $tag i32) (result i32)
    (call $unbox_i32 (call $ancestors_arity2_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)))))

  (func $descendants_arity1_internal (param $tag anyref) (result anyref)
    (return_call $descendants_arity2_internal (call $deref (global.get $global_hierarchy)) (local.get $tag)))

  (func $__export_descendants_arity1 (export "descendants_arity1") (param $tag i32) (result i32)
    (call $unbox_i32 (call $descendants_arity1_internal (ref.i31 (local.get $tag)))))

  (func $descendants_arity2_internal (param $h anyref) (param $tag anyref) (result anyref)
    (local $d anyref)
    (block (result anyref) (local.set $d (call $hash_map_get (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 3))) (local.get $tag))) (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $d))) (then (call $nil_QMARK_ (local.get $d))) (else (call $empty_QMARK_ (local.get $d))))) (then (ref.null none)) (else (local.get $d)))))

  (func $__export_descendants_arity2 (export "descendants_arity2") (param $h i32) (param $tag i32) (result i32)
    (call $unbox_i32 (call $descendants_arity2_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)))))

  (func $isa_QMARK__arity2_internal (param $child anyref) (param $parent anyref) (result anyref)
    (return_call $isa_QMARK__arity3_internal (call $deref (global.get $global_hierarchy)) (local.get $child) (local.get $parent)))

  (func $__export_isa_QMARK__arity2 (export "isa_QMARK__arity2") (param $child i32) (param $parent i32) (result i32)
    (call $unbox_i32 (call $isa_QMARK__arity2_internal (ref.i31 (local.get $child)) (ref.i31 (local.get $parent)))))

  (func $isa_QMARK__arity3_internal (param $h anyref) (param $child anyref) (param $parent anyref) (result anyref)
    (if (result anyref) (call $eq (local.get $child) (local.get $parent)) (then (if (result anyref) (call $eq (local.get $child) (local.get $parent)) (then (global.get $__true)) (else (global.get $__false)))) (else (call $contains_QMARK_ (call $hash_map_get_default (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 2))) (local.get $child) (call $empty_hash_set)) (local.get $parent)))))

  (func $__export_isa_QMARK__arity3 (export "isa_QMARK__arity3") (param $h i32) (param $child i32) (param $parent i32) (result i32)
    (call $unbox_i32 (call $isa_QMARK__arity3_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $child)) (ref.i31 (local.get $parent)))))

  (func $closure65 (type $ClosureFunc2) (param $__env anyref) (param $h3 anyref) (param $p anyref) (result anyref)
    (return_call $hierarchy_derive_internal (local.get $h3) (call $array_get (local.get $__env) (i32.const 0)) (local.get $p)))

  (func $underive_add_parents_internal (param $all_parents anyref) (param $h2 anyref) (param $tk anyref) (result anyref)
    (local $ps anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $ps (call $hash_map_get (local.get $all_parents) (local.get $tk))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $ps))) (then (local.get $h2)) (else (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure65) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $tk)) (local.get $__tmp_env))) (local.get $h2) (local.get $ps))))))

  (func $__export_underive_add_parents (export "underive-add-parents") (param $all_parents i32) (param $h2 i32) (param $tk i32) (result i32)
    (call $unbox_i32 (call $underive_add_parents_internal (ref.i31 (local.get $all_parents)) (ref.i31 (local.get $h2)) (ref.i31 (local.get $tk)))))

  (func $closure66 (type $ClosureFunc1) (param $__env anyref) (param $h anyref) (result anyref)
    (return_call $underive_arity3_internal (local.get $h) (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 0))))

  (func $underive_arity2_internal (param $tag anyref) (param $parent anyref) (result anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (drop (call $swap_BANG_ (global.get $global_hierarchy) (struct.new $Closure1 (i32.const 11) (ref.func $closure66) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $parent)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $tag)) (local.get $__tmp_env))))) (ref.null none)))

  (func $__export_underive_arity2 (export "underive_arity2") (param $tag i32) (param $parent i32) (result i32)
    (call $unbox_i32 (call $underive_arity2_internal (ref.i31 (local.get $tag)) (ref.i31 (local.get $parent)))))

  (func $closure67 (type $ClosureFunc2) (param $__env anyref) (param $h2 anyref) (param $tk anyref) (result anyref)
    (return_call $underive_add_parents_internal (call $array_get (local.get $__env) (i32.const 0)) (local.get $h2) (local.get $tk)))

  (func $underive_arity3_internal (param $h anyref) (param $tag anyref) (param $parent anyref) (result anyref)
    (local $cur_parents anyref)
    (local $new_parents anyref)
    (local $all_parents anyref)
    (local $base anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $cur_parents (call $hash_map_get_default (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 1))) (local.get $tag) (call $empty_hash_set))) (local.set $new_parents (call $disj (local.get $cur_parents) (local.get $parent))) (local.set $all_parents (call $assoc (call $hash_map_get (local.get $h) (struct.new $Keyword (i32.const 2) (i32.const 1))) (local.get $tag) (local.get $new_parents))) (local.set $base (call $make_hierarchy_internal)) (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure67) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $all_parents)) (local.get $__tmp_env))) (local.get $base) (call $keys (local.get $all_parents)))))

  (func $__export_underive_arity3 (export "underive_arity3") (param $h i32) (param $tag i32) (param $parent i32) (result i32)
    (call $unbox_i32 (call $underive_arity3_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)) (ref.i31 (local.get $parent)))))

  (func $mm_is_preferred_internal (param $prefer anyref) (param $x anyref) (param $y anyref) (result anyref)
    (local $prefs anyref)
    (block (result anyref) (local.set $prefs (call $hash_map_get (local.get $prefer) (local.get $x))) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $prefs))) (then (global.get $__false)) (else (call $contains_QMARK_ (local.get $prefs) (local.get $y))))))

  (func $__export_mm_is_preferred (export "mm-is-preferred") (param $prefer i32) (param $x i32) (param $y i32) (result i32)
    (call $unbox_i32 (call $mm_is_preferred_internal (ref.i31 (local.get $prefer)) (ref.i31 (local.get $x)) (ref.i31 (local.get $y)))))

  (func $mm_find_isa_internal (param $methods anyref) (param $dv anyref) (param $h anyref) (param $prefer anyref) (result anyref)
    (local $ks anyref)
    (local $remaining anyref)
    (local $best anyref)
    (local $best_key anyref)
    (local $k anyref)
    (block (result anyref) (local.set $ks (call $keys (local.get $methods))) (block (result anyref) (local.set $remaining (call $seq (local.get $ks))) (local.set $best (ref.null none)) (local.set $best_key (ref.null none)) (loop $loop12 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $remaining))) (then (local.get $best)) (else (block (result anyref) (local.set $k (call $first (local.get $remaining))) (if (result anyref) (call $truthy (if (result anyref) (i32.eqz (call $eq (local.get $k) (struct.new $Keyword (i32.const 2) (i32.const 6)))) (then (call $isa_QMARK__arity3_internal (local.get $h) (local.get $dv) (local.get $k))) (else (if (result anyref) (i32.eqz (call $eq (local.get $k) (struct.new $Keyword (i32.const 2) (i32.const 6)))) (then (global.get $__true)) (else (global.get $__false)))))) (then (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $best))) (then (call $seq (call $rest (local.get $remaining)))
      (call $hash_map_get (local.get $methods) (local.get $k))
      (local.get $k)
      (local.set $best_key)
      (local.set $best)
      (local.set $remaining)
      (br $loop12)) (else (if (result anyref) (call $truthy (call $mm_is_preferred_internal (local.get $prefer) (local.get $k) (local.get $best_key))) (then (call $seq (call $rest (local.get $remaining)))
      (call $hash_map_get (local.get $methods) (local.get $k))
      (local.get $k)
      (local.set $best_key)
      (local.set $best)
      (local.set $remaining)
      (br $loop12)) (else (if (result anyref) (call $truthy (call $mm_is_preferred_internal (local.get $prefer) (local.get $best_key) (local.get $k))) (then (call $seq (call $rest (local.get $remaining)))
      (local.get $best)
      (local.get $best_key)
      (local.set $best_key)
      (local.set $best)
      (local.set $remaining)
      (br $loop12)) (else (if (result anyref) (call $truthy (call $isa_QMARK__arity3_internal (local.get $h) (local.get $k) (local.get $best_key))) (then (call $seq (call $rest (local.get $remaining)))
      (call $hash_map_get (local.get $methods) (local.get $k))
      (local.get $k)
      (local.set $best_key)
      (local.set $best)
      (local.set $remaining)
      (br $loop12)) (else (if (result anyref) (call $truthy (call $isa_QMARK__arity3_internal (local.get $h) (local.get $best_key) (local.get $k))) (then (call $seq (call $rest (local.get $remaining)))
      (local.get $best)
      (local.get $best_key)
      (local.set $best_key)
      (local.set $best)
      (local.set $remaining)
      (br $loop12)) (else (call $seq (call $rest (local.get $remaining)))
      (local.get $best)
      (local.get $best_key)
      (local.set $best_key)
      (local.set $best)
      (local.set $remaining)
      (br $loop12)))))))))))) (else (call $seq (call $rest (local.get $remaining)))
      (local.get $best)
      (local.get $best_key)
      (local.set $best_key)
      (local.set $best)
      (local.set $remaining)
      (br $loop12))))))))))

  (func $__export_mm_find_isa (export "mm-find-isa") (param $methods i32) (param $dv i32) (param $h i32) (param $prefer i32) (result i32)
    (call $unbox_i32 (call $mm_find_isa_internal (ref.i31 (local.get $methods)) (ref.i31 (local.get $dv)) (ref.i31 (local.get $h)) (ref.i31 (local.get $prefer)))))

  (func $take_last_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $len anyref)
    (block (result anyref) (local.set $len (ref.i31 (call $count_internal (call $seq (local.get $coll))))) (return_call $drop_arity2_internal (call $max_arity2_internal (ref.i31 (i32.const 0)) (call $sub (local.get $len) (local.get $n))) (local.get $coll))))

  (func $__export_take_last (export "take-last") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $take_last_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $drop_last_arity1_internal (param $coll anyref) (result anyref)
    (return_call $drop_last_arity2_internal (ref.i31 (i32.const 1)) (local.get $coll)))

  (func $__export_drop_last_arity1 (export "drop_last_arity1") (param $coll i32) (result i32)
    (call $unbox_i32 (call $drop_last_arity1_internal (ref.i31 (local.get $coll)))))

  (func $drop_last_arity2_internal (param $n anyref) (param $coll anyref) (result anyref)
    (return_call $take_arity2_internal (call $max_arity2_internal (ref.i31 (i32.const 0)) (call $sub (ref.i31 (call $count_internal (call $seq (local.get $coll)))) (local.get $n))) (local.get $coll)))

  (func $__export_drop_last_arity2 (export "drop_last_arity2") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $drop_last_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $shuffle_internal (param $coll anyref) (result anyref)
    (local $n anyref)
    (local $i anyref)
    (local $v anyref)
    (local $j anyref)
    (local $vi anyref)
    (local $vj anyref)
    (block (result anyref) (local.set $n (ref.i31 (call $count_internal (local.get $coll)))) (block (result anyref) (local.set $i (call $dec (local.get $n))) (local.set $v (call $vec_internal (local.get $coll))) (loop $loop13 (result anyref) (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_le (local.get $i) (ref.i31 (i32.const 0))))) (then (local.get $v)) (else (block (result anyref) (local.set $j (if (result anyref) (ref.test (ref i31) (call $mul (struct.new $Float (i32.const 5) (call $rand_float)) (struct.new $Float (i32.const 5) (call $to_f64 (call $inc (local.get $i)))))) (then (call $mul (struct.new $Float (i32.const 5) (call $rand_float)) (struct.new $Float (i32.const 5) (call $to_f64 (call $inc (local.get $i)))))) (else (ref.i31 (i32.trunc_sat_f64_s (f64.trunc (call $to_f64 (call $mul (struct.new $Float (i32.const 5) (call $rand_float)) (struct.new $Float (i32.const 5) (call $to_f64 (call $inc (local.get $i)))))))))))) (local.set $vi (call $nth_polymorphic (local.get $v) (i31.get_s (ref.cast (ref i31) (local.get $i))))) (local.set $vj (call $nth_polymorphic (local.get $v) (i31.get_s (ref.cast (ref i31) (local.get $j))))) (call $dec (local.get $i))
      (call $assoc (call $assoc (local.get $v) (local.get $i) (local.get $vj)) (local.get $j) (local.get $vi))
      (local.set $v)
      (local.set $i)
      (br $loop13))))))))

  (func $__export_shuffle (export "shuffle") (param $coll i32) (result i32)
    (call $unbox_i32 (call $shuffle_internal (ref.i31 (local.get $coll)))))

  (func $closure68 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $x anyref)
    (if (result anyref) (i32.eqz (call $truthy (call $nil_QMARK_ (call $seq (call $array_get (local.get $__env) (i32.const 0)))))) (then (block (result anyref) (local.set $x (call $first (call $array_get (local.get $__env) (i32.const 0)))) (if (result anyref) (call $truthy (call $seqable_QMARK_ (local.get $x))) (then (return_call $concat_arity2_internal (call $flatten_internal (local.get $x)) (call $flatten_internal (call $rest (call $array_get (local.get $__env) (i32.const 0)))))) (else (call $cons (local.get $x) (call $flatten_internal (call $rest (call $array_get (local.get $__env) (i32.const 0))))))))) (else (ref.null none))))

  (func $flatten_internal (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure68) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll)) (local.get $__tmp_env)))))

  (func $__export_flatten (export "flatten") (param $coll i32) (result i32)
    (call $unbox_i32 (call $flatten_internal (ref.i31 (local.get $coll)))))

  (func $closure70 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (if (result anyref) (call $eq (local.get $input) (call $deref (call $array_get (local.get $__env) (i32.const 0)))) (then (local.get $result)) (else (block (result anyref) (drop (call $reset_BANG_ (call $array_get (local.get $__env) (i32.const 0)) (local.get $input))) (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 1)) (local.get $result) (local.get $input))))))

  (func $fn69 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $prev anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $prev (call $atom (struct.new $Keyword (i32.const 2) (i32.const 7)))) (struct.new $Closure2 (i32.const 11) (ref.func $closure70) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $prev)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $rf)) (local.get $__tmp_env)))))

  (func $dedupe_arity0_internal  (result anyref)
    (global.get $__lifted_fn69))

  (func $__export_dedupe_arity0 (export "dedupe_arity0")  (result i32)
    (call $unbox_i32 (call $dedupe_arity0_internal )))

  (func $dedupe_arity1_internal (param $coll anyref) (result anyref)
    (local $result anyref)
    (local $prev anyref)
    (local $s anyref)
    (local $x anyref)
    (block (result anyref) (local.set $result (ref.null none)) (local.set $prev (struct.new $Keyword (i32.const 2) (i32.const 7))) (local.set $s (call $seq (local.get $coll))) (loop $loop14 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (call $reverse_internal (local.get $result))) (else (block (result anyref) (local.set $x (call $first (local.get $s))) (if (result anyref) (call $eq (local.get $x) (local.get $prev)) (then (local.get $result)
      (local.get $prev)
      (call $seq (call $rest (local.get $s)))
      (local.set $s)
      (local.set $prev)
      (local.set $result)
      (br $loop14)) (else (call $cons (local.get $x) (local.get $result))
      (local.get $x)
      (call $seq (call $rest (local.get $s)))
      (local.set $s)
      (local.set $prev)
      (local.set $result)
      (br $loop14)))))))))

  (func $__export_dedupe_arity1 (export "dedupe_arity1") (param $coll i32) (result i32)
    (call $unbox_i32 (call $dedupe_arity1_internal (ref.i31 (local.get $coll)))))

  (func $closure71 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (local $cached anyref)
    (local $result anyref)
    (block (result anyref) (local.set $cached (call $hash_map_get_default (call $deref (call $array_get (local.get $__env) (i32.const 0))) (local.get $x) (struct.new $Keyword (i32.const 2) (i32.const 8)))) (if (result anyref) (call $eq (local.get $cached) (struct.new $Keyword (i32.const 2) (i32.const 8))) (then (block (result anyref) (local.set $result (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))) (block (result anyref) (drop (call $swap_BANG_3 (call $array_get (local.get $__env) (i32.const 0)) (global.get $__builtin_assoc) (local.get $x) (local.get $result))) (local.get $result)))) (else (local.get $cached)))))

  (func $memoize_internal (param $f anyref) (result anyref)
    (local $cache anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $cache (call $atom (call $empty_hash_map))) (struct.new $Closure1 (i32.const 11) (ref.func $closure71) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $cache)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $f)) (local.get $__tmp_env)))))

  (func $__export_memoize (export "memoize") (param $f i32) (result i32)
    (call $unbox_i32 (call $memoize_internal (ref.i31 (local.get $f)))))

  (func $trampoline_run_internal (param $f anyref) (result anyref)
    (local $result anyref)
    (block (result anyref) (local.set $result (call $invoke0 (local.get $f))) (loop $loop15 (result anyref) (if (result anyref) (call $truthy (call $fn_QMARK_ (local.get $result))) (then (call $invoke0 (local.get $result))
      (local.set $result)
      (br $loop15)) (else (local.get $result))))))

  (func $__export_trampoline_run (export "trampoline-run") (param $f i32) (result i32)
    (call $unbox_i32 (call $trampoline_run_internal (ref.i31 (local.get $f)))))

  (func $trampoline_arity1_internal (param $f anyref) (result anyref)
    (return_call $trampoline_run_internal (local.get $f)))

  (func $__export_trampoline_arity1 (export "trampoline_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $trampoline_arity1_internal (ref.i31 (local.get $f)))))

  (func $closure72 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (return_call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1))))

  (func $trampoline_arity2_internal (param $f anyref) (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $trampoline_run_internal (struct.new $Closure0 (i32.const 11) (ref.func $closure72) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $x)) (local.get $__tmp_env)))))

  (func $__export_trampoline_arity2 (export "trampoline_arity2") (param $f i32) (param $x i32) (result i32)
    (call $unbox_i32 (call $trampoline_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $x)))))

  (func $closure73 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1)) (call $array_get (local.get $__env) (i32.const 2))))

  (func $trampoline_arity3_internal (param $f anyref) (param $x anyref) (param $y anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $trampoline_run_internal (struct.new $Closure0 (i32.const 11) (ref.func $closure73) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $x)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $y)) (local.get $__tmp_env)))))

  (func $__export_trampoline_arity3 (export "trampoline_arity3") (param $f i32) (param $x i32) (param $y i32) (result i32)
    (call $unbox_i32 (call $trampoline_arity3_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $x)) (ref.i31 (local.get $y)))))

  (func $vec_internal (param $coll anyref) (result anyref)
    (if (result anyref) (call $truthy (call $vector_QMARK_ (local.get $coll))) (then (local.get $coll)) (else (return_call $into_arity2_internal (call $empty_vector) (local.get $coll)))))

  (func $__export_vec (export "vec") (param $coll i32) (result i32)
    (call $unbox_i32 (call $vec_internal (ref.i31 (local.get $coll)))))

  (func $mapv_arity2_internal (param $f anyref) (param $coll anyref) (result anyref)
    (return_call $into_arity2_internal (call $empty_vector) (call $map_arity2_internal (local.get $f) (local.get $coll))))

  (func $__export_mapv_arity2 (export "mapv_arity2") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $mapv_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $mapv_arity3_internal (param $f anyref) (param $c1 anyref) (param $c2 anyref) (result anyref)
    (return_call $into_arity2_internal (call $empty_vector) (call $map_arity3_internal (local.get $f) (local.get $c1) (local.get $c2))))

  (func $__export_mapv_arity3 (export "mapv_arity3") (param $f i32) (param $c1 i32) (param $c2 i32) (result i32)
    (call $unbox_i32 (call $mapv_arity3_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $c1)) (ref.i31 (local.get $c2)))))

  (func $mapv_arity4_internal (param $f anyref) (param $c1 anyref) (param $c2 anyref) (param $c3 anyref) (result anyref)
    (return_call $into_arity2_internal (call $empty_vector) (call $map_arity4_internal (local.get $f) (local.get $c1) (local.get $c2) (local.get $c3))))

  (func $__export_mapv_arity4 (export "mapv_arity4") (param $f i32) (param $c1 i32) (param $c2 i32) (param $c3 i32) (result i32)
    (call $unbox_i32 (call $mapv_arity4_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $c1)) (ref.i31 (local.get $c2)) (ref.i31 (local.get $c3)))))

  (func $filterv_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (return_call $into_arity2_internal (call $empty_vector) (call $filter_arity2_internal (local.get $pred) (local.get $coll))))

  (func $__export_filterv (export "filterv") (param $pred i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $filterv_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll)))))

  (func $subvec_arity2_internal (param $v anyref) (param $start anyref) (result anyref)
    (return_call $subvec_arity3_internal (local.get $v) (local.get $start) (ref.i31 (call $count_internal (local.get $v)))))

  (func $__export_subvec_arity2 (export "subvec_arity2") (param $v i32) (param $start i32) (result i32)
    (call $unbox_i32 (call $subvec_arity2_internal (ref.i31 (local.get $v)) (ref.i31 (local.get $start)))))

  (func $subvec_arity3_internal (param $v anyref) (param $start anyref) (param $end anyref) (result anyref)
    (local $result anyref)
    (local $i anyref)
    (block (result anyref) (local.set $result (call $empty_vector)) (local.set $i (local.get $start)) (loop $loop16 (result anyref) (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $cmp_ge (local.get $i) (local.get $end)))) (then (local.get $result)) (else (call $conj (local.get $result) (call $nth_polymorphic (local.get $v) (i31.get_s (ref.cast (ref i31) (local.get $i)))))
      (call $inc (local.get $i))
      (local.set $i)
      (local.set $result)
      (br $loop16))))))

  (func $__export_subvec_arity3 (export "subvec_arity3") (param $v i32) (param $start i32) (param $end i32) (result i32)
    (call $unbox_i32 (call $subvec_arity3_internal (ref.i31 (local.get $v)) (ref.i31 (local.get $start)) (ref.i31 (local.get $end)))))

  (func $closure74 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (return_call $concat_arity2_internal (call $array_get (local.get $__env) (i32.const 0)) (call $cycle_internal (call $array_get (local.get $__env) (i32.const 0)))))

  (func $cycle_internal (param $coll anyref) (result anyref)
    (local $s anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $s (call $seq (local.get $coll))) (if (result anyref) (i32.eqz (call $truthy (call $nil_QMARK_ (local.get $s)))) (then (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure74) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $s)) (local.get $__tmp_env))))) (else (ref.null none)))))

  (func $__export_cycle (export "cycle") (param $coll i32) (result i32)
    (call $unbox_i32 (call $cycle_internal (ref.i31 (local.get $coll)))))

  (func $get_validator_internal (param $ref anyref) (result anyref)
    (ref.null none))

  (func $__export_get_validator (export "get-validator") (param $ref i32) (result i32)
    (call $unbox_i32 (call $get_validator_internal (ref.i31 (local.get $ref)))))

  (func $boolean_internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (local.get $x)) (then (global.get $__true)) (else (global.get $__false))))

  (func $__export_boolean (export "boolean") (param $x i32) (result i32)
    (call $unbox_i32 (call $boolean_internal (ref.i31 (local.get $x)))))

  (func $not_empty_internal (param $coll anyref) (result anyref)
    (if (result anyref) (call $truthy (call $empty_QMARK_ (local.get $coll))) (then (ref.null none)) (else (local.get $coll))))

  (func $__export_not_empty (export "not-empty") (param $coll i32) (result i32)
    (call $unbox_i32 (call $not_empty_internal (ref.i31 (local.get $coll)))))

  (func $empty_internal (param $coll anyref) (result anyref)
    (if (result anyref) (call $truthy (call $vector_QMARK_ (local.get $coll))) (then (call $empty_vector)) (else (if (result anyref) (call $truthy (call $map_QMARK_ (local.get $coll))) (then (call $empty_hash_map)) (else (if (result anyref) (call $truthy (call $set_QMARK_ (local.get $coll))) (then (call $empty_hash_set)) (else (ref.null none))))))))

  (func $__export_empty (export "empty") (param $coll i32) (result i32)
    (call $unbox_i32 (call $empty_internal (ref.i31 (local.get $coll)))))

  (func $str1_or_pr_internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $coll_QMARK_ (local.get $x))) (then (call $coll_QMARK_ (local.get $x))) (else (call $seq_QMARK_ (local.get $x))))) (then (if (result anyref) (call $truthy (call $coll_QMARK_ (local.get $x))) (then (call $coll_QMARK_ (local.get $x))) (else (call $seq_QMARK_ (local.get $x))))) (else (call $lazy_seq_QMARK_ (local.get $x))))) (then (call $pr_str1 (local.get $x))) (else (call $str1 (local.get $x)))))

  (func $__export_str1_or_pr (export "str1-or-pr") (param $x i32) (result i32)
    (call $unbox_i32 (call $str1_or_pr_internal (ref.i31 (local.get $x)))))

  (func $str_arity0_internal  (result anyref)
    (global.get $__str_2))

  (func $__export_str_arity0 (export "str_arity0")  (result i32)
    (call $unbox_i32 (call $str_arity0_internal )))

  (func $str_arity1_internal (param $x anyref) (result anyref)
    (return_call $str1_or_pr_internal (local.get $x)))

  (func $__export_str_arity1 (export "str_arity1") (param $x i32) (result i32)
    (call $unbox_i32 (call $str_arity1_internal (ref.i31 (local.get $x)))))

  (func $str_variadic_internal (param $x anyref) (param $more anyref) (result anyref)
    (local $buf anyref)
    (local $s anyref)
    (block (result anyref) (local.set $buf (call $string_buffer)) (block (result anyref) (drop (call $sb_append_BANG_ (local.get $buf) (call $str1_or_pr_internal (local.get $x)))) (block (result anyref) (local.set $s (call $seq (local.get $more))) (loop $loop17 (result anyref) (if (result anyref) (call $truthy (call $nil_QMARK_ (local.get $s))) (then (call $sb__GT_string (local.get $buf))) (else (block (result anyref) (drop (call $sb_append_BANG_ (local.get $buf) (call $str1_or_pr_internal (call $first (local.get $s))))) (call $seq (call $rest (local.get $s)))
      (local.set $s)
      (br $loop17)))))))))

  (func $__export_str_variadic (export "str_variadic") (param $x i32) (param $more i32) (result i32)
    (call $unbox_i32 (call $str_variadic_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $more)))))

  (func $simple_keyword_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $keyword_QMARK_ (local.get $x))) (then (call $nil_QMARK_ (call $namespace (local.get $x)))) (else (call $keyword_QMARK_ (local.get $x)))))

  (func $__export_simple_keyword_QMARK_ (export "simple-keyword?") (param $x i32) (result i32)
    (call $unbox_i32 (call $simple_keyword_QMARK__internal (ref.i31 (local.get $x)))))

  (func $simple_symbol_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $symbol_QMARK_ (local.get $x))) (then (call $nil_QMARK_ (call $namespace (local.get $x)))) (else (call $symbol_QMARK_ (local.get $x)))))

  (func $__export_simple_symbol_QMARK_ (export "simple-symbol?") (param $x i32) (result i32)
    (call $unbox_i32 (call $simple_symbol_QMARK__internal (ref.i31 (local.get $x)))))

  (func $simple_ident_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $simple_keyword_QMARK__internal (local.get $x))) (then (call $simple_keyword_QMARK__internal (local.get $x))) (else (call $simple_symbol_QMARK__internal (local.get $x)))))

  (func $__export_simple_ident_QMARK_ (export "simple-ident?") (param $x i32) (result i32)
    (call $unbox_i32 (call $simple_ident_QMARK__internal (ref.i31 (local.get $x)))))

  (func $qualified_keyword_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $keyword_QMARK_ (local.get $x))) (then (call $some_QMARK_ (call $namespace (local.get $x)))) (else (call $keyword_QMARK_ (local.get $x)))))

  (func $__export_qualified_keyword_QMARK_ (export "qualified-keyword?") (param $x i32) (result i32)
    (call $unbox_i32 (call $qualified_keyword_QMARK__internal (ref.i31 (local.get $x)))))

  (func $qualified_symbol_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $symbol_QMARK_ (local.get $x))) (then (call $some_QMARK_ (call $namespace (local.get $x)))) (else (call $symbol_QMARK_ (local.get $x)))))

  (func $__export_qualified_symbol_QMARK_ (export "qualified-symbol?") (param $x i32) (result i32)
    (call $unbox_i32 (call $qualified_symbol_QMARK__internal (ref.i31 (local.get $x)))))

  (func $qualified_ident_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $qualified_keyword_QMARK__internal (local.get $x))) (then (call $qualified_keyword_QMARK__internal (local.get $x))) (else (call $qualified_symbol_QMARK__internal (local.get $x)))))

  (func $__export_qualified_ident_QMARK_ (export "qualified-ident?") (param $x i32) (result i32)
    (call $unbox_i32 (call $qualified_ident_QMARK__internal (ref.i31 (local.get $x)))))

  (func $ident_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $keyword_QMARK_ (local.get $x))) (then (call $keyword_QMARK_ (local.get $x))) (else (call $symbol_QMARK_ (local.get $x)))))

  (func $__export_ident_QMARK_ (export "ident?") (param $x i32) (result i32)
    (call $unbox_i32 (call $ident_QMARK__internal (ref.i31 (local.get $x)))))

  (func $special_symbol_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__false))

  (func $__export_special_symbol_QMARK_ (export "special-symbol?") (param $x i32) (result i32)
    (call $unbox_i32 (call $special_symbol_QMARK__internal (ref.i31 (local.get $x)))))

  (func $ex_info_internal (param $msg anyref) (param $data anyref) (result anyref)
    (ref.null none))

  (func $__export_ex_info (export "ex-info") (param $msg i32) (param $data i32) (result i32)
    (call $unbox_i32 (call $ex_info_internal (ref.i31 (local.get $msg)) (ref.i31 (local.get $data)))))

  (func $ex_message_internal (param $e anyref) (result anyref)
    (ref.null none))

  (func $__export_ex_message (export "ex-message") (param $e i32) (result i32)
    (call $unbox_i32 (call $ex_message_internal (ref.i31 (local.get $e)))))

  (func $ex_data_internal (param $e anyref) (result anyref)
    (ref.null none))

  (func $__export_ex_data (export "ex-data") (param $e i32) (result i32)
    (call $unbox_i32 (call $ex_data_internal (ref.i31 (local.get $e)))))

  (func $to_array_internal (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $__export_to_array (export "to-array") (param $coll i32) (result i32)
    (call $unbox_i32 (call $to_array_internal (ref.i31 (local.get $coll)))))

  (func $reversible_QMARK__internal (param $coll anyref) (result anyref)
    (global.get $__false))

  (func $__export_reversible_QMARK_ (export "reversible?") (param $coll i32) (result i32)
    (call $unbox_i32 (call $reversible_QMARK__internal (ref.i31 (local.get $coll)))))

  (func $rseq_internal (param $coll anyref) (result anyref)
    (return_call $reverse_internal (call $seq (local.get $coll))))

  (func $__export_rseq (export "rseq") (param $coll i32) (result i32)
    (call $unbox_i32 (call $rseq_internal (ref.i31 (local.get $coll)))))

  (func $anon_multi76_arity0 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (return_call $invoke0 (call $array_get (local.get $__env) (i32.const 0))))

  (func $anon_multi76_arity1 (type $ClosureFunc1) (param $__env anyref) (param $result anyref) (result anyref)
    (return_call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $result)))

  (func $anon_multi76_arity2 (type $ClosureFunc2) (param $__env anyref) (param $result anyref) (param $input anyref) (result anyref)
    (local $i anyref)
    (block (result anyref) (local.set $i (call $deref (call $array_get (local.get $__env) (i32.const 0)))) (block (result anyref) (drop (call $reset_BANG_ (call $array_get (local.get $__env) (i32.const 0)) (call $inc (local.get $i)))) (if (result anyref) (struct.get $Boolean $val (ref.cast (ref $Boolean) (call $zero_QMARK_ (call $rem_internal (local.get $i) (call $array_get (local.get $__env) (i32.const 1)))))) (then (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 2)) (local.get $result) (local.get $input))) (else (local.get $result))))))

  (func $anon_multi76_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 0))
      (then
      (call $anon_multi76_arity0 (local.get $__env)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi76_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi76_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (unreachable))))))))

  (func $closure75 (type $ClosureFunc1) (param $__env anyref) (param $rf anyref) (result anyref)
    (local $ia anyref)
    (local $__tmp_env anyref)
    (block (result anyref) (local.set $ia (call $atom (ref.i31 (i32.const 1)))) (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $ia)) (call $array_set (local.get $__tmp_env) (i32.const 1) (call $array_get (local.get $__env) (i32.const 0))) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $rf)) (local.get $__tmp_env)) (ref.func $anon_multi76_dispatch))))

  (func $take_nth_arity1_internal (param $n anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (i32.const 11) (ref.func $closure75) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $n)) (local.get $__tmp_env))))

  (func $__export_take_nth_arity1 (export "take_nth_arity1") (param $n i32) (result i32)
    (call $unbox_i32 (call $take_nth_arity1_internal (ref.i31 (local.get $n)))))

  (func $closure77 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $temp__11 anyref)
    (local $s anyref)
    (block (result anyref) (local.set $temp__11 (call $seq (call $array_get (local.get $__env) (i32.const 0)))) (if (result anyref) (call $truthy (local.get $temp__11)) (then (block (result anyref) (local.set $s (local.get $temp__11)) (call $cons (call $first (local.get $s)) (call $take_nth_arity2_internal (call $array_get (local.get $__env) (i32.const 1)) (call $drop_arity2_internal (call $array_get (local.get $__env) (i32.const 1)) (local.get $s)))))) (else (ref.null none)))))

  (func $take_nth_arity2_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (i32.const 11) (ref.func $closure77) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $n)) (local.get $__tmp_env)))))

  (func $__export_take_nth_arity2 (export "take_nth_arity2") (param $n i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $take_nth_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll)))))

  (func $closure78 (type $ClosureFunc2) (param $__env anyref) (param $a anyref) (param $b anyref) (result anyref)
    (return_call $invoke2 (global.get $__builtin_compare) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $a)) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $b))))

  (func $sort_by_arity2_internal (param $keyfn anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $sort_with_cmp_internal (struct.new $Closure2 (i32.const 11) (ref.func $closure78) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $keyfn)) (local.get $__tmp_env))) (local.get $coll)))

  (func $__export_sort_by_arity2 (export "sort_by_arity2") (param $keyfn i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $sort_by_arity2_internal (ref.i31 (local.get $keyfn)) (ref.i31 (local.get $coll)))))

  (func $closure79 (type $ClosureFunc2) (param $__env anyref) (param $a anyref) (param $b anyref) (result anyref)
    (return_call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $a)) (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $b))))

  (func $sort_by_arity3_internal (param $keyfn anyref) (param $cmp anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $sort_with_cmp_internal (struct.new $Closure2 (i32.const 11) (ref.func $closure79) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $cmp)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $keyfn)) (local.get $__tmp_env))) (local.get $coll)))

  (func $__export_sort_by_arity3 (export "sort_by_arity3") (param $keyfn i32) (param $cmp i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $sort_by_arity3_internal (ref.i31 (local.get $keyfn)) (ref.i31 (local.get $cmp)) (ref.i31 (local.get $coll)))))

  (func $closure80 (type $ClosureFunc2) (param $__env anyref) (param $m anyref) (param $x anyref) (result anyref)
    (local $k anyref)
    (block (result anyref) (local.set $k (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (return_call $invoke3 (global.get $__builtin_assoc_BANG_) (local.get $m) (local.get $k) (call $conj (call $hash_map_get_default (local.get $m) (local.get $k) (call $empty_vector)) (local.get $x)))))

  (func $group_by_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (struct.new $Closure2 (i32.const 11) (ref.func $closure80) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env))) (call $invoke1 (global.get $__builtin_transient) (call $empty_hash_map)) (local.get $coll))))

  (func $__export_group_by (export "group-by") (param $f i32) (param $coll i32) (result i32)
    (call $unbox_i32 (call $group_by_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll)))))

  (func $fn81 (type $ClosureFunc2) (param $__env anyref) (param $m anyref) (param $x anyref) (result anyref)
    (return_call $invoke3 (global.get $__builtin_assoc_BANG_) (local.get $m) (local.get $x) (call $inc (call $hash_map_get_default (local.get $m) (local.get $x) (ref.i31 (i32.const 0))))))

  (func $frequencies_internal (param $coll anyref) (result anyref)
    (return_call $invoke1 (global.get $__builtin_persistent_BANG_) (call $reduce (global.get $__lifted_fn81) (call $invoke1 (global.get $__builtin_transient) (call $empty_hash_map)) (local.get $coll))))

  (func $__export_frequencies (export "frequencies") (param $coll i32) (result i32)
    (call $unbox_i32 (call $frequencies_internal (ref.i31 (local.get $coll)))))

  (func $realized_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $lazy_seq_QMARK_ (local.get $x))) (then (call $lazy_seq_realized_QMARK_ (local.get $x))) (else (global.get $__true))))

  (func $__export_realized_QMARK_ (export "realized?") (param $x i32) (result i32)
    (call $unbox_i32 (call $realized_QMARK__internal (ref.i31 (local.get $x)))))

  (func $numerator_internal (param $r anyref) (result anyref)
    (local.get $r))

  (func $__export_numerator (export "numerator") (param $r i32) (result i32)
    (call $unbox_i32 (call $numerator_internal (ref.i31 (local.get $r)))))

  (func $denominator_internal (param $r anyref) (result anyref)
    (ref.i31 (i32.const 1)))

  (func $__export_denominator (export "denominator") (param $r i32) (result i32)
    (call $unbox_i32 (call $denominator_internal (ref.i31 (local.get $r)))))

  (func $rationalize_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export_rationalize (export "rationalize") (param $x i32) (result i32)
    (call $unbox_i32 (call $rationalize_internal (ref.i31 (local.get $x)))))

  (func $byte_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export_byte (export "byte") (param $x i32) (result i32)
    (call $unbox_i32 (call $byte_internal (ref.i31 (local.get $x)))))

  (func $short_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export_short (export "short") (param $x i32) (result i32)
    (call $unbox_i32 (call $short_internal (ref.i31 (local.get $x)))))

  (func $int_internal (param $x anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $x)) (then (local.get $x)) (else (ref.i31 (i32.trunc_sat_f64_s (f64.trunc (call $to_f64 (local.get $x))))))))

  (func $__export_int (export "int") (param $x i32) (result i32)
    (call $unbox_i32 (call $int_internal (ref.i31 (local.get $x)))))

  (func $long_internal (param $x anyref) (result anyref)
    (if (result anyref) (ref.test (ref i31) (local.get $x)) (then (local.get $x)) (else (ref.i31 (i32.trunc_sat_f64_s (f64.trunc (call $to_f64 (local.get $x))))))))

  (func $__export_long (export "long") (param $x i32) (result i32)
    (call $unbox_i32 (call $long_internal (ref.i31 (local.get $x)))))

  (func $float_internal (param $x anyref) (result anyref)
    (struct.new $Float (i32.const 5) (call $to_f64 (local.get $x))))

  (func $__export_float (export "float") (param $x i32) (result i32)
    (call $unbox_i32 (call $float_internal (ref.i31 (local.get $x)))))

  (func $double_internal (param $x anyref) (result anyref)
    (struct.new $Float (i32.const 5) (call $to_f64 (local.get $x))))

  (func $__export_double (export "double") (param $x i32) (result i32)
    (call $unbox_i32 (call $double_internal (ref.i31 (local.get $x)))))

  (func $bigint_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export_bigint (export "bigint") (param $x i32) (result i32)
    (call $unbox_i32 (call $bigint_internal (ref.i31 (local.get $x)))))

  (func $bigdec_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $__export_bigdec (export "bigdec") (param $x i32) (result i32)
    (call $unbox_i32 (call $bigdec_internal (ref.i31 (local.get $x)))))

  (func $decimal_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__false))

  (func $__export_decimal_QMARK_ (export "decimal?") (param $x i32) (result i32)
    (call $unbox_i32 (call $decimal_QMARK__internal (ref.i31 (local.get $x)))))

  (func $uuid_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__false))

  (func $__export_uuid_QMARK_ (export "uuid?") (param $x i32) (result i32)
    (call $unbox_i32 (call $uuid_QMARK__internal (ref.i31 (local.get $x)))))

  (func $var_QMARK__internal (param $x anyref) (result anyref)
    (global.get $__false))

  (func $__export_var_QMARK_ (export "var?") (param $x i32) (result i32)
    (call $unbox_i32 (call $var_QMARK__internal (ref.i31 (local.get $x)))))

  (func $anon_multi82_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (return_call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))

  (func $anon_multi82_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y)))))

  (func $anon_multi82_arity3 (type $ClosureFunc3) (param $__env anyref) (param $x anyref) (param $y anyref) (param $z anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z)))))

  (func $anon_multi82_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi82_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi82_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 3))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a2 (call $first (local.get $args)))
      (call $anon_multi82_arity3 (local.get $__env) (local.get $a0) (local.get $a1) (local.get $a2)))
      (else (unreachable))))))))

  (func $some_fn_arity1_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 1))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (local.get $__tmp_env)) (ref.func $anon_multi82_dispatch)))

  (func $__export_some_fn_arity1 (export "some_fn_arity1") (param $f i32) (result i32)
    (call $unbox_i32 (call $some_fn_arity1_internal (ref.i31 (local.get $f)))))

  (func $anon_multi83_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x)))))

  (func $anon_multi83_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y)))))

  (func $anon_multi83_arity3 (type $ClosureFunc3) (param $__env anyref) (param $x anyref) (param $y anyref) (param $z anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z)))))

  (func $anon_multi83_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi83_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi83_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 3))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a2 (call $first (local.get $args)))
      (call $anon_multi83_arity3 (local.get $__env) (local.get $a0) (local.get $a1) (local.get $a2)))
      (else (unreachable))))))))

  (func $some_fn_arity2_internal (param $f anyref) (param $g anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 2))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g)) (local.get $__tmp_env)) (ref.func $anon_multi83_dispatch)))

  (func $__export_some_fn_arity2 (export "some_fn_arity2") (param $f i32) (param $g i32) (result i32)
    (call $unbox_i32 (call $some_fn_arity2_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g)))))

  (func $anon_multi84_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x)))))

  (func $anon_multi84_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y)))))

  (func $anon_multi84_arity3 (type $ClosureFunc3) (param $__env anyref) (param $x anyref) (param $y anyref) (param $z anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $z)))))

  (func $anon_multi84_dispatch (type $MultiClosureDispatch) (param $__env anyref) (param $argc i32) (param $args anyref) (result anyref)
    (local $a0 anyref) (local $a1 anyref) (local $a2 anyref) 
    (if (result anyref) (i32.eq (local.get $argc) (i32.const 1))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (call $anon_multi84_arity1 (local.get $__env) (local.get $a0)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 2))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (call $anon_multi84_arity2 (local.get $__env) (local.get $a0) (local.get $a1)))
      (else (if (result anyref) (i32.eq (local.get $argc) (i32.const 3))
      (then
      (local.set $a0 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a1 (call $first (local.get $args)))
      (local.set $args (call $rest (local.get $args)))
      (local.set $a2 (call $first (local.get $args)))
      (call $anon_multi84_arity3 (local.get $__env) (local.get $a0) (local.get $a1) (local.get $a2)))
      (else (unreachable))))))))

  (func $some_fn_arity3_internal (param $f anyref) (param $g anyref) (param $h anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $MultiClosure (i32.const 11) (block (result anyref) (local.set $__tmp_env (call $array_new (i32.const 3))) (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f)) (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g)) (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $h)) (local.get $__tmp_env)) (ref.func $anon_multi84_dispatch)))

  (func $__export_some_fn_arity3 (export "some_fn_arity3") (param $f i32) (param $g i32) (param $h i32) (result i32)
    (call $unbox_i32 (call $some_fn_arity3_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g)) (ref.i31 (local.get $h)))))

  (func $anon_multi85_arity1 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 3)) (local.get $x)))))

  (func $anon_multi85_arity2 (type $ClosureFunc2) (param $__env anyref) (param $x anyref) (param $y anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 3)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 3)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 3)) (local.get $y)))))

  (func $anon_multi85_arity3 (type $ClosureFunc3) (param $__env anyref) (param $x anyref) (param $y anyref) (param $z anyref) (result anyref)
    (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 3)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 3)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 3)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $y))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $z))))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 2)) (local.get $x))))) (then (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))) (then (if (result anyref) (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (then (call $