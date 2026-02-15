(module
  ;; ==========================================
  ;; WasmGC Type Definitions
  ;; ==========================================

  ;; Cons cell: holds two anyref values (first and rest)
  (type $Cons (struct (field $first (mut anyref)) (field $rest (mut anyref))))

  ;; Keyword: interned symbol with unique ID
  (type $Keyword (struct (field $id i32)))

  ;; UTF-8 byte array (for strings)
  (type $CharArray (array (mut i8)))

  ;; String: interned ID + UTF-8 byte data
  ;; ID >= 0 for interned literals (O(1) equality), -1 for dynamic strings
  (type $String (struct (field $id i32) (field $data (ref $CharArray))))

  ;; Symbol: interned symbol (for quoted symbols) with unique ID
  (type $Symbol (struct (field $id i32)))

  ;; Float: 64-bit floating point value
  (type $Float (struct (field $val f64)))

  ;; Array of anyref (mutable)
  (type $AnyArray (array (mut anyref)))

  ;; Persistent Vector (32-way branching trie with tail optimization)
  (type $Vector (struct
    (field $count i32)      ;; Total number of elements
    (field $shift i32)      ;; Bit shift for trie navigation (0, 5, 10, 15...)
    (field $root anyref)    ;; Root of the trie (null for small vectors)
    (field $tail anyref)))  ;; Tail array (last 1-32 elements)

  ;; Simple Array-based HashMap (O(n) lookup but correct)
  ;; Stores key-value pairs in flat array: [k1, v1, k2, v2, ...]
  (type $HashMap (struct
    (field $count i32)      ;; Number of key-value pairs
    (field $array anyref))) ;; Array of [key, value, key, value, ...]

  ;; Simple Array-based HashSet (O(n) lookup)
  ;; Stores elements in flat array: [e1, e2, e3, ...]
  (type $HashSet (struct
    (field $count i32)      ;; Number of elements
    (field $array anyref))) ;; Array of elements

  ;; Atom: mutable reference
  (type $Atom (struct
    (field $val (mut anyref)))) ;; Mutable value

  ;; Reduced: wrapper for early termination in reduce
  (type $Reduced (struct
    (field $val anyref)))

  ;; LazySeq: delayed sequence with memoization
  ;; Note: Has 3 fields to distinguish from Cons (which has 2 fields) - WasmGC uses structural typing
  (type $LazySeq (struct
    (field $tag i32)                 ;; Type tag (always 12 for LazySeq) - for structural distinction
    (field $thunk (mut anyref))      ;; 0-arity closure (null when realized)
    (field $realized (mut anyref)))) ;; cached result (nil or Cons/seq)

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
  (type $Closure0 (struct
    (field $func (ref $ClosureFunc0))
    (field $env anyref)))
  (type $Closure1 (struct
    (field $func (ref $ClosureFunc1))
    (field $env anyref)))
  (type $Closure2 (struct
    (field $func (ref $ClosureFunc2))
    (field $env anyref)))
  (type $Closure3 (struct
    (field $func (ref $ClosureFunc3))
    (field $env anyref)))
  (type $Closure4 (struct
    (field $func (ref $ClosureFunc4))
    (field $env anyref)))
  (type $Closure5 (struct
    (field $func (ref $ClosureFunc5))
    (field $env anyref)))
  (type $Closure6 (struct
    (field $func (ref $ClosureFunc6))
    (field $env anyref)))
  (type $Closure7 (struct
    (field $func (ref $ClosureFunc7))
    (field $env anyref)))
  (type $Closure8 (struct
    (field $func (ref $ClosureFunc8))
    (field $env anyref)))
  (type $Closure9 (struct
    (field $func (ref $ClosureFunc9))
    (field $env anyref)))
  (type $Closure10 (struct
    (field $func (ref $ClosureFunc10))
    (field $env anyref)))

  ;; ==========================================
  ;; List Runtime Functions
  ;; ==========================================

  ;; cons: create a new cons cell
  (func $cons (param $first anyref) (param $rest anyref) (result anyref)
    (struct.new $Cons (local.get $first) (local.get $rest)))

  ;; first: get the first element of a collection (polymorphic)
  ;; Works on: Cons, Vector, HashMap (returns first key-value pair as vector), HashSet, LazySeq
  (func $first (param $coll anyref) (result anyref)
    (local $count i32)
    (local $arr anyref)
    ;; nil -> nil
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (ref.null none))
      (else
        ;; LazySeq - realize and recurse
        (if (result anyref) (ref.test (ref $LazySeq) (local.get $coll))
          (then (call $first (call $lazy_seq_realize (local.get $coll))))
          (else
            ;; Cons cell
            (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
          (then (struct.get $Cons $first (ref.cast (ref $Cons) (local.get $coll))))
          (else
            ;; Vector
            (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
              (then
                (local.set $count (call $vector_count (local.get $coll)))
                (if (result anyref) (i32.le_s (local.get $count) (i32.const 0))
                  (then (ref.null none))
                  (else (call $vector_nth (local.get $coll) (i32.const 0)))))
              (else
                ;; HashMap - return first key
                (if (result anyref) (ref.test (ref $HashMap) (local.get $coll))
                  (then
                    (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
                    (if (result anyref) (i32.le_s (local.get $count) (i32.const 0))
                      (then (ref.null none))
                      (else
                        (local.set $arr (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll))))
                        ;; Return [key value] as a 2-element vector
                        (call $vector_conj
                          (call $vector_conj
                            (call $empty_vector)
                            (call $array_get (local.get $arr) (i32.const 0)))
                          (call $array_get (local.get $arr) (i32.const 1))))))
                  (else
                    ;; HashSet
                    (if (result anyref) (ref.test (ref $HashSet) (local.get $coll))
                      (then
                        (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
                        (if (result anyref) (i32.le_s (local.get $count) (i32.const 0))
                          (then (ref.null none))
                          (else
                            (local.set $arr (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll))))
                            (call $array_get (local.get $arr) (i32.const 0)))))
                      (else
                        ;; String - return first char as 1-char string
                        (if (result anyref) (ref.test (ref $String) (local.get $coll))
                          (then
                            (if (result anyref) (i32.le_s (call $str_len (local.get $coll)) (i32.const 0))
                              (then (ref.null none))
                              (else (call $char_at_as_str (local.get $coll) (i32.const 0)))))
                          (else
                            ;; Other - return nil
                            (ref.null none))))))))))))))))

  ;; rest: get the rest of a collection (polymorphic)
  ;; Works on: Cons, Vector, HashMap, HashSet, LazySeq
  ;; Returns a seq (cons list) for non-Cons types
  (func $rest (param $coll anyref) (result anyref)
    (local $count i32)
    (local $i i32)
    (local $arr anyref)
    (local $result anyref)
    ;; nil -> empty list (nil)
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (ref.null none))
      (else
        ;; LazySeq - realize and recurse
        (if (result anyref) (ref.test (ref $LazySeq) (local.get $coll))
          (then (call $rest (call $lazy_seq_realize (local.get $coll))))
          (else
            ;; Cons cell
            (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
          (then (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $coll))))
          (else
            ;; Vector - return rest as cons list
            (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
              (then
                (local.set $count (call $vector_count (local.get $coll)))
                (if (result anyref) (i32.le_s (local.get $count) (i32.const 1))
                  (then (ref.null none))
                  (else
                    ;; Build cons list from index 1 to end
                    (local.set $result (ref.null none))
                    (local.set $i (i32.sub (local.get $count) (i32.const 1)))
                    (block $done
                      (loop $loop
                        (br_if $done (i32.lt_s (local.get $i) (i32.const 1)))
                        (local.set $result (call $cons
                          (call $vector_nth (local.get $coll) (local.get $i))
                          (local.get $result)))
                        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                        (br $loop)))
                    (local.get $result))))
              (else
                ;; HashMap - return rest of keys as cons list
                (if (result anyref) (ref.test (ref $HashMap) (local.get $coll))
                  (then
                    (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
                    (if (result anyref) (i32.le_s (local.get $count) (i32.const 1))
                      (then (ref.null none))
                      (else
                        (local.set $arr (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll))))
                        (local.set $result (ref.null none))
                        ;; Start from last pair, build cons list of [k v] vectors
                        (local.set $i (i32.sub (local.get $count) (i32.const 1)))
                        (block $done2
                          (loop $loop2
                            (br_if $done2 (i32.lt_s (local.get $i) (i32.const 1)))
                            (local.set $result (call $cons
                              (call $vector_conj
                                (call $vector_conj
                                  (call $empty_vector)
                                  (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2))))
                                (call $array_get (local.get $arr) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))
                              (local.get $result)))
                            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                            (br $loop2)))
                        (local.get $result))))
                  (else
                    ;; HashSet - return rest as cons list
                    (if (result anyref) (ref.test (ref $HashSet) (local.get $coll))
                      (then
                        (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
                        (if (result anyref) (i32.le_s (local.get $count) (i32.const 1))
                          (then (ref.null none))
                          (else
                            (local.set $arr (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll))))
                            (local.set $result (ref.null none))
                            (local.set $i (i32.sub (local.get $count) (i32.const 1)))
                            (block $done3
                              (loop $loop3
                                (br_if $done3 (i32.lt_s (local.get $i) (i32.const 1)))
                                (local.set $result (call $cons
                                  (call $array_get (local.get $arr) (local.get $i))
                                  (local.get $result)))
                                (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                                (br $loop3)))
                            (local.get $result))))
                      (else
                        ;; String - return rest as seq of 1-char strings
                        (if (result anyref) (ref.test (ref $String) (local.get $coll))
                          (then
                            (local.set $count (call $str_len (local.get $coll)))
                            (if (result anyref) (i32.le_s (local.get $count) (i32.const 1))
                              (then (ref.null none))
                              (else
                                ;; Build cons list of single-char strings from end to start
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
                                (local.get $result))))
                          (else
                            ;; Other - return nil
                            (ref.null none))))))))))))))))

  ;; nil?: check if value is nil (null reference) - returns boxed boolean
  (func $nil_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.is_null (local.get $val))))

  ;; cons?: check if value is a cons cell - returns boxed boolean
  (func $cons_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Cons) (local.get $val))))

  ;; ==========================================
  ;; List Helper Functions (for testing)
  ;; ==========================================

  ;; list-length: count elements in a list (returns i32 for export)
  (func $list_length (export "list-length") (param $lst anyref) (result i32)
    (local $count i32)
    (local $current anyref)
    (local.set $current (local.get $lst))
    (block $done
      (loop $loop
        (br_if $done (ref.is_null (local.get $current)))
        (local.set $count (i32.add (local.get $count) (i32.const 1)))
        (local.set $current (struct.get $Cons $rest (ref.cast (ref $Cons) (local.get $current))))
        (br $loop)))
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
  ;; - i31ref 0 (false) -> 0
  ;; - anything else -> 1 (including keywords, cons cells, non-zero i31ref)
  (func $truthy (param $val anyref) (result i32)
    ;; Check for null first
    (if (result i32) (ref.is_null (local.get $val))
      (then (i32.const 0))
      (else
        ;; Check if it's an i31ref
        (if (result i32) (ref.test (ref i31) (local.get $val))
          (then
            ;; It's an i31ref - return the value (0 is falsy, non-zero is truthy)
            (i31.get_s (ref.cast (ref i31) (local.get $val))))
          (else
            ;; Not null, not i31ref - it's some object (keyword, cons, etc) - truthy
            (i32.const 1))))))

  ;; is_nan: check if value is a NaN float - returns boxed boolean
  ;; NaN is the only value where x != x
  (func $is_nan (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Float) (local.get $val))
      (then
        ;; It's a float - check if NaN using (x != x)
        (ref.i31 (f64.ne
          (struct.get $Float $val (ref.cast (ref $Float) (local.get $val)))
          (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))))))
      (else
        ;; Not a float - not NaN
        (ref.i31 (i32.const 0)))))

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
    (if (result i32) (ref.is_null (local.get $val))
      (then (i32.const 0))
      (else
        ;; i31ref (integer/boolean)?
        (if (result i32) (ref.test (ref i31) (local.get $val))
          (then (call $hash_int (i31.get_s (ref.cast (ref i31) (local.get $val)))))
          (else
            ;; Keyword?
            (if (result i32) (ref.test (ref $Keyword) (local.get $val))
              (then
                ;; Use keyword id with some mixing
                (call $hash_int (i32.add
                  (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val)))
                  (i32.const 0x9e3779b9))))
              (else
                ;; String?
                (if (result i32) (ref.test (ref $String) (local.get $val))
                  (then
                    ;; If ID >= 0 (interned), use ID-based hash; else use $str_hash
                    (if (result i32) (i32.ge_s (struct.get $String $id (ref.cast (ref $String) (local.get $val))) (i32.const 0))
                      (then (call $hash_int (i32.add
                        (struct.get $String $id (ref.cast (ref $String) (local.get $val)))
                        (i32.const 0x1b873593))))
                      (else (call $str_hash (local.get $val)))))
                  (else
                    ;; Symbol?
                    (if (result i32) (ref.test (ref $Symbol) (local.get $val))
                      (then
                        (call $hash_int (i32.add
                          (struct.get $Symbol $id (ref.cast (ref $Symbol) (local.get $val)))
                          (i32.const 0xcc9e2d51))))
                      (else
                        ;; Float?
                        (if (result i32) (ref.test (ref $Float) (local.get $val))
                          (then
                            (call $hash_int (i32.trunc_f64_s
                              (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))))))
                          (else
                            ;; Other object - use default
                            (i32.const 31))))))))))))))

  ;; eq: polymorphic equality
  ;; - both nil -> true
  ;; - both i31ref -> compare values
  ;; - both Keyword -> compare ids
  ;; - both String -> compare via $str_eq
  ;; - both Float -> compare f64 values
  ;; - different types -> false
  (func $eq (param $a anyref) (param $b anyref) (result i32)
    ;; Both null?
    (if (result i32) (i32.and (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
      (then (i32.const 1))
      (else
        ;; One null, one not?
        (if (result i32) (i32.or (ref.is_null (local.get $a)) (ref.is_null (local.get $b)))
          (then (i32.const 0))
          (else
            ;; Both i31ref?
            (if (result i32) (i32.and (ref.test (ref i31) (local.get $a))
                                      (ref.test (ref i31) (local.get $b)))
              (then (i32.eq (i31.get_s (ref.cast (ref i31) (local.get $a)))
                            (i31.get_s (ref.cast (ref i31) (local.get $b)))))
              (else
                ;; Both Keywords?
                (if (result i32) (i32.and (ref.test (ref $Keyword) (local.get $a))
                                          (ref.test (ref $Keyword) (local.get $b)))
                  (then (i32.eq
                          (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $a)))
                          (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $b)))))
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
                            ;; Different types or unsupported - not equal
                            (i32.const 0))))))))))))))

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
    (struct.new $Vector
      (i32.const 0)       ;; count = 0
      (i32.const 5)       ;; shift = 5 (start at leaf level)
      (ref.null none)     ;; root = null
      (call $array_new (i32.const 0))))  ;; tail = empty array

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
        (struct.new $Vector
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
            (struct.new $Vector
              (i32.add (local.get $count) (i32.const 1))
              (i32.add (local.get $shift) (i32.const 5))
              (local.get $new_root)
              (local.get $new_tail)))
          (else
            ;; Push tail into existing tree
            (struct.new $Vector
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
        (struct.new $Vector
          (local.get $count)
          (local.get $shift)
          (struct.get $Vector $root (local.get $vec))
          (local.get $new_tail)))
      (else
        ;; In trie - use do_assoc
        (struct.new $Vector
          (local.get $count)
          (local.get $shift)
          (call $do_assoc (local.get $shift) (struct.get $Vector $root (local.get $vec)) (local.get $idx) (local.get $val))
          (struct.get $Vector $tail (local.get $vec))))))

  ;; vector?: check if value is a vector
  (func $vector_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Vector) (local.get $val))))

  ;; ==========================================
  ;; Persistent HashMap Operations (Simple Array-based)
  ;; ==========================================

  ;; empty-hash-map: create an empty hash map
  (func $empty_hash_map (result anyref)
    (struct.new $HashMap
      (i32.const 0)       ;; count = 0
      (call $array_new (i32.const 0))))  ;; empty array

  ;; hash-map-count: get number of key-value pairs
  (func $hash_map_count (param $m anyref) (result i32)
    (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $m))))

  ;; hash-map-get: lookup key in hash map (linear search)
  (func $hash_map_get (param $m anyref) (param $key anyref) (result anyref)
    (local $map (ref $HashMap))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (local.set $map (ref.cast (ref $HashMap) (local.get $m)))
    (local.set $arr (struct.get $HashMap $array (local.get $map)))
    (local.set $count (struct.get $HashMap $count (local.get $map)))
    (local.set $i (i32.const 0))
    (block $found (result anyref)
      (block $notfound
        (loop $loop
          (br_if $notfound (i32.ge_s (local.get $i) (local.get $count)))
          (if (call $eq (local.get $key) (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2))))
            (then (br $found (call $array_get (local.get $arr) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop)))
      (ref.null none)))

  ;; hash-map-assoc: insert or update key-value pair
  (func $hash_map_assoc (param $m anyref) (param $key anyref) (param $val anyref) (result anyref)
    (local $map (ref $HashMap))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (local $found_idx i32)
    (local $new_arr anyref)
    (local.set $map (ref.cast (ref $HashMap) (local.get $m)))
    (local.set $arr (struct.get $HashMap $array (local.get $map)))
    (local.set $count (struct.get $HashMap $count (local.get $map)))
    ;; Search for existing key
    (local.set $found_idx (i32.const -1))
    (local.set $i (i32.const 0))
    (block $found
      (loop $loop
        (br_if $found (i32.ge_s (local.get $i) (local.get $count)))
        (if (call $eq (local.get $key) (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2))))
          (then
            (local.set $found_idx (local.get $i))
            (br $found)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (if (result anyref) (i32.ge_s (local.get $found_idx) (i32.const 0))
      (then
        ;; Key exists - update value (copy array with new value)
        (local.set $new_arr (call $array_copy (local.get $arr) (i32.mul (local.get $count) (i32.const 2))))
        (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $found_idx) (i32.const 2)) (i32.const 1)) (local.get $val))
        (struct.new $HashMap (local.get $count) (local.get $new_arr)))
      (else
        ;; Key doesn't exist - add new entry
        (local.set $new_arr (call $array_new (i32.mul (i32.add (local.get $count) (i32.const 1)) (i32.const 2))))
        ;; Copy existing entries
        (if (i32.gt_s (local.get $count) (i32.const 0))
          (then
            (array.copy $AnyArray $AnyArray
              (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
              (ref.cast (ref $AnyArray) (local.get $arr)) (i32.const 0)
              (i32.mul (local.get $count) (i32.const 2)))))
        ;; Add new entry
        (call $array_set (local.get $new_arr) (i32.mul (local.get $count) (i32.const 2)) (local.get $key))
        (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $count) (i32.const 2)) (i32.const 1)) (local.get $val))
        (struct.new $HashMap (i32.add (local.get $count) (i32.const 1)) (local.get $new_arr)))))

  ;; hash-map-contains?: check if key exists
  (func $hash_map_contains_QMARK_ (param $m anyref) (param $key anyref) (result anyref)
    (ref.i31 (i32.eqz (ref.is_null (call $hash_map_get (local.get $m) (local.get $key))))))

  ;; map?: check if value is a hash map
  (func $map_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $HashMap) (local.get $val))))

  ;; keys: return list of all keys in hash map
  (func $keys (param $m anyref) (result anyref)
    (local $map (ref $HashMap))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (local $result anyref)
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        (local.set $map (ref.cast (ref $HashMap) (local.get $m)))
        (local.set $arr (struct.get $HashMap $array (local.get $map)))
        (local.set $count (struct.get $HashMap $count (local.get $map)))
        (local.set $result (ref.null none))
        (local.set $i (i32.sub (local.get $count) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $result (call $cons
              (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2)))
              (local.get $result)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (local.get $result))))

  ;; vals: return list of all values in hash map
  (func $vals (param $m anyref) (result anyref)
    (local $map (ref $HashMap))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (local $result anyref)
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        (local.set $map (ref.cast (ref $HashMap) (local.get $m)))
        (local.set $arr (struct.get $HashMap $array (local.get $map)))
        (local.set $count (struct.get $HashMap $count (local.get $map)))
        (local.set $result (ref.null none))
        (local.set $i (i32.sub (local.get $count) (i32.const 1)))
        (block $done
          (loop $loop
            (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
            (local.set $result (call $cons
              (call $array_get (local.get $arr) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))
              (local.get $result)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br $loop)))
        (local.get $result))))

  ;; ==========================================
  ;; Persistent HashSet Operations (Simple Array-based)
  ;; ==========================================

  ;; empty-hash-set: create an empty hash set
  (func $empty_hash_set (result anyref)
    (struct.new $HashSet
      (i32.const 0)       ;; count = 0
      (call $array_new (i32.const 0))))  ;; empty array

  ;; set-conj: add element to set (if not already present)
  (func $set_conj (param $s anyref) (param $elem anyref) (result anyref)
    (local $set (ref $HashSet))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (local $new_arr anyref)
    (if (result anyref) (ref.is_null (local.get $s))
      (then
        ;; nil -> create new set with element
        (local.set $new_arr (call $array_new (i32.const 1)))
        (call $array_set (local.get $new_arr) (i32.const 0) (local.get $elem))
        (struct.new $HashSet (i32.const 1) (local.get $new_arr)))
      (else
        (local.set $set (ref.cast (ref $HashSet) (local.get $s)))
        (local.set $arr (struct.get $HashSet $array (local.get $set)))
        (local.set $count (struct.get $HashSet $count (local.get $set)))
        ;; Check if element already exists
        (local.set $i (i32.const 0))
        (block $found (result anyref)
          (block $notfound
            (loop $loop
              (br_if $notfound (i32.ge_s (local.get $i) (local.get $count)))
              (if (call $eq (local.get $elem) (call $array_get (local.get $arr) (local.get $i)))
                (then (br $found (local.get $s))))  ;; Already exists, return unchanged
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $loop)))
          ;; Not found - add element
          (local.set $new_arr (call $array_new (i32.add (local.get $count) (i32.const 1))))
          (if (i32.gt_s (local.get $count) (i32.const 0))
            (then
              (array.copy $AnyArray $AnyArray
                (ref.cast (ref $AnyArray) (local.get $new_arr)) (i32.const 0)
                (ref.cast (ref $AnyArray) (local.get $arr)) (i32.const 0)
                (local.get $count))))
          (call $array_set (local.get $new_arr) (local.get $count) (local.get $elem))
          (struct.new $HashSet (i32.add (local.get $count) (i32.const 1)) (local.get $new_arr))))))

  ;; disj: remove element from set
  (func $disj (param $s anyref) (param $elem anyref) (result anyref)
    (local $set (ref $HashSet))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (local $j i32)
    (local $new_arr anyref)
    (local $found_idx i32)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (ref.null none))
      (else
        (local.set $set (ref.cast (ref $HashSet) (local.get $s)))
        (local.set $arr (struct.get $HashSet $array (local.get $set)))
        (local.set $count (struct.get $HashSet $count (local.get $set)))
        (local.set $found_idx (i32.const -1))
        ;; Find element
        (local.set $i (i32.const 0))
        (block $found
          (loop $loop
            (br_if $found (i32.ge_s (local.get $i) (local.get $count)))
            (if (call $eq (local.get $elem) (call $array_get (local.get $arr) (local.get $i)))
              (then
                (local.set $found_idx (local.get $i))
                (br $found)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (if (result anyref) (i32.ge_s (local.get $found_idx) (i32.const 0))
          (then
            ;; Element found - create new set without it
            (local.set $new_arr (call $array_new (i32.sub (local.get $count) (i32.const 1))))
            (local.set $j (i32.const 0))
            (local.set $i (i32.const 0))
            (block $done
              (loop $copy
                (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
                (if (i32.ne (local.get $i) (local.get $found_idx))
                  (then
                    (call $array_set (local.get $new_arr) (local.get $j) (call $array_get (local.get $arr) (local.get $i)))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $copy)))
            (struct.new $HashSet (i32.sub (local.get $count) (i32.const 1)) (local.get $new_arr)))
          (else
            ;; Element not found - return unchanged
            (local.get $s))))))

  ;; set?: check if value is a hash set
  (func $set_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $HashSet) (local.get $val))))

  ;; set-contains?: check if element exists in set
  (func $set_contains_QMARK_ (param $s anyref) (param $elem anyref) (result anyref)
    (local $set (ref $HashSet))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (if (result anyref) (ref.is_null (local.get $s))
      (then (ref.i31 (i32.const 0)))
      (else
        (local.set $set (ref.cast (ref $HashSet) (local.get $s)))
        (local.set $arr (struct.get $HashSet $array (local.get $set)))
        (local.set $count (struct.get $HashSet $count (local.get $set)))
        (local.set $i (i32.const 0))
        (block $found (result anyref)
          (block $notfound
            (loop $loop
              (br_if $notfound (i32.ge_s (local.get $i) (local.get $count)))
              (if (call $eq (local.get $elem) (call $array_get (local.get $arr) (local.get $i)))
                (then (br $found (ref.i31 (i32.const 1)))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $loop)))
          (ref.i31 (i32.const 0))))))

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
    ;; nil -> nil
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (ref.null none))
      (else
        ;; LazySeq - realize and recurse
        (if (result anyref) (ref.test (ref $LazySeq) (local.get $coll))
          (then (call $seq (call $lazy_seq_realize (local.get $coll))))
          (else
            ;; Cons cell - return as-is if non-empty, nil if empty
            (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
          (then (local.get $coll))
          (else
            ;; Vector - convert to cons list
            (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
              (then
                (local.set $count (call $vector_count (local.get $coll)))
                (if (result anyref) (i32.le_s (local.get $count) (i32.const 0))
                  (then (ref.null none))
                  (else
                    (local.set $result (ref.null none))
                    (local.set $i (i32.sub (local.get $count) (i32.const 1)))
                    (block $done
                      (loop $loop
                        (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
                        (local.set $result (call $cons
                          (call $vector_nth (local.get $coll) (local.get $i))
                          (local.get $result)))
                        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                        (br $loop)))
                    (local.get $result))))
              (else
                ;; HashMap - return keys call
                (if (result anyref) (ref.test (ref $HashMap) (local.get $coll))
                  (then
                    (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
                    (if (result anyref) (i32.le_s (local.get $count) (i32.const 0))
                      (then (ref.null none))
                      (else (call $keys (local.get $coll)))))
                  (else
                    ;; HashSet - convert to cons list
                    (if (result anyref) (ref.test (ref $HashSet) (local.get $coll))
                      (then
                        (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
                        (if (result anyref) (i32.le_s (local.get $count) (i32.const 0))
                          (then (ref.null none))
                          (else
                            (local.set $arr (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll))))
                            (local.set $result (ref.null none))
                            (local.set $i (i32.sub (local.get $count) (i32.const 1)))
                            (block $done2
                              (loop $loop2
                                (br_if $done2 (i32.lt_s (local.get $i) (i32.const 0)))
                                (local.set $result (call $cons
                                  (call $array_get (local.get $arr) (local.get $i))
                                  (local.get $result)))
                                (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                                (br $loop2)))
                            (local.get $result))))
                      (else
                        ;; String - convert to cons list of 1-char strings
                        (if (result anyref) (ref.test (ref $String) (local.get $coll))
                          (then
                            (local.set $count (call $str_len (local.get $coll)))
                            (if (result anyref) (i32.le_s (local.get $count) (i32.const 0))
                              (then (ref.null none))
                              (else
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
                                (local.get $result))))
                          (else
                            ;; Other - return nil
                            (ref.null none))))))))))))))))

  ;; seq?: check if value is a seq (cons cell) or lazy seq
  (func $seq_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $LazySeq) (local.get $val)))))

  ;; seqable?: check if value can be converted to a seq
  (func $seqable_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or
      (ref.is_null (local.get $val))
      (ref.test (ref $Cons) (local.get $val)))
      (ref.test (ref $Vector) (local.get $val)))
      (ref.test (ref $HashMap) (local.get $val)))
      (ref.test (ref $HashSet) (local.get $val)))
      (ref.test (ref $LazySeq) (local.get $val)))
      (ref.test (ref $String) (local.get $val)))))

  ;; empty?: check if collection is empty
  (func $empty_QMARK_ (param $coll anyref) (result anyref)
    (ref.i31
      (if (result i32) (ref.is_null (local.get $coll))
        (then (i32.const 1))
        (else
          (if (result i32) (ref.test (ref $Cons) (local.get $coll))
            (then (i32.const 0))  ;; cons cells are never empty
            (else
              (if (result i32) (ref.test (ref $Vector) (local.get $coll))
                (then (i32.eqz (call $vector_count (local.get $coll))))
                (else
                  (if (result i32) (ref.test (ref $HashMap) (local.get $coll))
                    (then (i32.eqz (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll)))))
                    (else
                      (if (result i32) (ref.test (ref $HashSet) (local.get $coll))
                        (then (i32.eqz (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll)))))
                        (else
                          (if (result i32) (ref.test (ref $String) (local.get $coll))
                            (then (i32.eqz (call $str_len (local.get $coll))))
                            (else (i32.const 1)))))))))))))))

  ;; dissoc: remove key from hash map
  (func $dissoc (param $m anyref) (param $key anyref) (result anyref)
    (local $map (ref $HashMap))
    (local $arr anyref)
    (local $count i32)
    (local $i i32)
    (local $j i32)
    (local $new_arr anyref)
    (local $found_idx i32)
    (if (result anyref) (ref.is_null (local.get $m))
      (then (ref.null none))
      (else
        (local.set $map (ref.cast (ref $HashMap) (local.get $m)))
        (local.set $arr (struct.get $HashMap $array (local.get $map)))
        (local.set $count (struct.get $HashMap $count (local.get $map)))
        (local.set $found_idx (i32.const -1))
        ;; Find key
        (local.set $i (i32.const 0))
        (block $found
          (loop $loop
            (br_if $found (i32.ge_s (local.get $i) (local.get $count)))
            (if (call $eq (local.get $key) (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2))))
              (then
                (local.set $found_idx (local.get $i))
                (br $found)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (if (result anyref) (i32.ge_s (local.get $found_idx) (i32.const 0))
          (then
            ;; Key found - create new map without it
            (local.set $new_arr (call $array_new (i32.mul (i32.sub (local.get $count) (i32.const 1)) (i32.const 2))))
            (local.set $j (i32.const 0))
            (local.set $i (i32.const 0))
            (block $done
              (loop $copy
                (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
                (if (i32.ne (local.get $i) (local.get $found_idx))
                  (then
                    (call $array_set (local.get $new_arr) (i32.mul (local.get $j) (i32.const 2))
                      (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2))))
                    (call $array_set (local.get $new_arr) (i32.add (i32.mul (local.get $j) (i32.const 2)) (i32.const 1))
                      (call $array_get (local.get $arr) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $copy)))
            (struct.new $HashMap (i32.sub (local.get $count) (i32.const 1)) (local.get $new_arr)))
          (else
            ;; Key not found - return unchanged
            (local.get $m))))))

  ;; ==========================================
  ;; Atom Operations
  ;; ==========================================

  ;; atom: create an atom with initial value
  (func $atom (param $val anyref) (result anyref)
    (struct.new $Atom (local.get $val)))

  ;; deref: get value from atom
  (func $deref (param $a anyref) (result anyref)
    (struct.get $Atom $val (ref.cast (ref $Atom) (local.get $a))))

  ;; reset!: set atom value, returns new value
  (func $reset_BANG_ (param $a anyref) (param $val anyref) (result anyref)
    (struct.set $Atom $val (ref.cast (ref $Atom) (local.get $a)) (local.get $val))
    (local.get $val))

  ;; swap!: apply function to atom value (function must be a closure)
  ;; Note: This is a simplified implementation that doesn't support arbitrary arities
  (func $swap_BANG_ (param $a anyref) (param $f anyref) (result anyref)
    (local $old anyref)
    (local $new anyref)
    (local.set $old (struct.get $Atom $val (ref.cast (ref $Atom) (local.get $a))))
    (local.set $new (call $invoke1 (local.get $f) (local.get $old)))
    (struct.set $Atom $val (ref.cast (ref $Atom) (local.get $a)) (local.get $new))
    (local.get $new))

  ;; atom?: check if value is an atom
  (func $atom_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Atom) (local.get $val))))

  ;; ==========================================
  ;; Apply
  ;; ==========================================

  ;; count_internal: get count of any collection as i32 (for apply dispatch)
  (func $count_internal (param $coll anyref) (result i32)
    (if (result i32) (ref.is_null (local.get $coll))
      (then (i32.const 0))
      (else (if (result i32) (ref.test (ref $Vector) (local.get $coll))
        (then (call $vector_count (local.get $coll)))
        (else (if (result i32) (ref.test (ref $Cons) (local.get $coll))
          (then (call $list_length (local.get $coll)))
          (else (if (result i32) (ref.test (ref $HashMap) (local.get $coll))
            (then (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
            (else (if (result i32) (ref.test (ref $HashSet) (local.get $coll))
              (then (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
              (else (if (result i32) (ref.test (ref $String) (local.get $coll))
                (then (call $str_len (local.get $coll)))
                (else (if (result i32) (ref.test (ref $LazySeq) (local.get $coll))
                  (then (call $count_internal (call $lazy_seq_realize (local.get $coll))))
                  (else (i32.const 0))
                ))
              ))
            ))
          ))
        ))
      ))
    )
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
  (func $apply (param $f anyref) (param $args anyref) (result anyref)
    (local $s anyref)
    (local $n i32)
    (local.set $s (call $seq (local.get $args)))
    (local.set $n (call $count_internal (local.get $args)))
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
                    (else (call $apply_8 (local.get $f) (local.get $s)))
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
    (ref.i31 (ref.test (ref $String) (local.get $val))))

  ;; symbol?: check if value is a symbol
  (func $symbol_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Symbol) (local.get $val))))

  ;; float?: check if value is a float
  (func $float_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Float) (local.get $val))))

  ;; integer?: check if value is an integer (i31ref)
  (func $integer_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.and
      (i32.eqz (ref.is_null (local.get $val)))
      (ref.test (ref i31) (local.get $val)))))

  ;; number?: check if value is any number type (integer or float)
  (func $number_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $val))
      (then (ref.i31 (i32.const 0)))
      (else
        (ref.i31 (i32.or
          (ref.test (ref i31) (local.get $val))
          (ref.test (ref $Float) (local.get $val)))))))

  ;; true?: check if value is boolean true (i31ref with value 1)
  (func $true_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $val))
      (then (ref.i31 (i32.const 0)))
      (else
        (if (result anyref) (ref.test (ref i31) (local.get $val))
          (then (ref.i31 (i32.eq (i31.get_s (ref.cast (ref i31) (local.get $val))) (i32.const 1))))
          (else (ref.i31 (i32.const 0)))))))

  ;; false?: check if value is boolean false (i31ref with value 0 or nil)
  (func $false_QMARK_ (param $val anyref) (result anyref)
    (if (result anyref) (ref.is_null (local.get $val))
      (then (ref.i31 (i32.const 0)))  ;; nil is not false?, it's nil
      (else
        (if (result anyref) (ref.test (ref i31) (local.get $val))
          (then (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (local.get $val))))))
          (else (ref.i31 (i32.const 0)))))))

  ;; some?: check if value is not nil
  (func $some_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.eqz (ref.is_null (local.get $val)))))

  ;; list?: check if value is a cons cell
  (func $list_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Cons) (local.get $val))))

  ;; keyword?: check if value is a keyword
  (func $keyword_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Keyword) (local.get $val))))

  ;; fn?: check if value is a function (any closure type)
  (func $fn_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or
      (ref.test (ref $Closure0) (local.get $val))
      (ref.test (ref $Closure1) (local.get $val)))
      (ref.test (ref $Closure2) (local.get $val)))
      (ref.test (ref $Closure3) (local.get $val)))
      (ref.test (ref $Closure4) (local.get $val)))
      (ref.test (ref $Closure5) (local.get $val)))
      (ref.test (ref $Closure6) (local.get $val)))
      (ref.test (ref $Closure7) (local.get $val)))
      (ref.test (ref $Closure8) (local.get $val)))
      (ref.test (ref $Closure9) (local.get $val)))
      (ref.test (ref $Closure10) (local.get $val)))))

  ;; coll?: check if value is a collection (vector, map, set, or list)
  (func $coll_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or (i32.or (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $Vector) (local.get $val)))
      (ref.test (ref $HashMap) (local.get $val)))
      (ref.test (ref $HashSet) (local.get $val)))))

  ;; sequential?: check if value is sequential (vector or list)
  (func $sequential_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or
      (ref.test (ref $Cons) (local.get $val))
      (ref.test (ref $Vector) (local.get $val)))))

  ;; associative?: check if value is associative (vector or map)
  (func $associative_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or
      (ref.test (ref $Vector) (local.get $val))
      (ref.test (ref $HashMap) (local.get $val)))))

  ;; counted?: check if value supports O(1) count (vector, map, set)
  (func $counted_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or (i32.or
      (ref.test (ref $Vector) (local.get $val))
      (ref.test (ref $HashMap) (local.get $val)))
      (ref.test (ref $HashSet) (local.get $val)))))

  ;; indexed?: check if value supports indexed access (vector)
  (func $indexed_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $Vector) (local.get $val))))

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
        ;; Assume hash-map
        (call $hash_map_assoc (local.get $coll) (local.get $key) (local.get $val)))))

  ;; ==========================================
  ;; Closure Runtime Functions
  ;; ==========================================

  ;; closure?: check if value is any closure type
  (func $closure_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or
      (ref.test (ref $Closure0) (local.get $val))
      (ref.test (ref $Closure1) (local.get $val)))
      (ref.test (ref $Closure2) (local.get $val)))
      (ref.test (ref $Closure3) (local.get $val)))
      (ref.test (ref $Closure4) (local.get $val)))
      (ref.test (ref $Closure5) (local.get $val)))
      (ref.test (ref $Closure6) (local.get $val)))
      (ref.test (ref $Closure7) (local.get $val)))
      (ref.test (ref $Closure8) (local.get $val)))))

  ;; invoke0: invoke a 0-arity closure
  (func $invoke0 (param $closure anyref) (result anyref)
    (local $c (ref $Closure0))
    (local.set $c (ref.cast (ref $Closure0) (local.get $closure)))
    (call_ref $ClosureFunc0
      (struct.get $Closure0 $env (local.get $c))
      (struct.get $Closure0 $func (local.get $c))))

  ;; invoke1: invoke a 1-arity closure
  (func $invoke1 (param $closure anyref) (param $arg0 anyref) (result anyref)
    (local $c (ref $Closure1))
    (local.set $c (ref.cast (ref $Closure1) (local.get $closure)))
    (call_ref $ClosureFunc1
      (struct.get $Closure1 $env (local.get $c))
      (local.get $arg0)
      (struct.get $Closure1 $func (local.get $c))))

  ;; invoke2: invoke a 2-arity closure
  (func $invoke2 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (result anyref)
    (local $c (ref $Closure2))
    (local.set $c (ref.cast (ref $Closure2) (local.get $closure)))
    (call_ref $ClosureFunc2
      (struct.get $Closure2 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (struct.get $Closure2 $func (local.get $c))))

  ;; invoke3: invoke a 3-arity closure
  (func $invoke3 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (result anyref)
    (local $c (ref $Closure3))
    (local.set $c (ref.cast (ref $Closure3) (local.get $closure)))
    (call_ref $ClosureFunc3
      (struct.get $Closure3 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (struct.get $Closure3 $func (local.get $c))))

  ;; invoke4: invoke a 4-arity closure
  (func $invoke4 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (result anyref)
    (local $c (ref $Closure4))
    (local.set $c (ref.cast (ref $Closure4) (local.get $closure)))
    (call_ref $ClosureFunc4
      (struct.get $Closure4 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (local.get $arg3)
      (struct.get $Closure4 $func (local.get $c))))

  ;; invoke5: invoke a 5-arity closure
  (func $invoke5 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (result anyref)
    (local $c (ref $Closure5))
    (local.set $c (ref.cast (ref $Closure5) (local.get $closure)))
    (call_ref $ClosureFunc5
      (struct.get $Closure5 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (local.get $arg3)
      (local.get $arg4)
      (struct.get $Closure5 $func (local.get $c))))

  ;; invoke6: invoke a 6-arity closure
  (func $invoke6 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (result anyref)
    (local $c (ref $Closure6))
    (local.set $c (ref.cast (ref $Closure6) (local.get $closure)))
    (call_ref $ClosureFunc6
      (struct.get $Closure6 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (local.get $arg3)
      (local.get $arg4)
      (local.get $arg5)
      (struct.get $Closure6 $func (local.get $c))))

  ;; invoke7: invoke a 7-arity closure
  (func $invoke7 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (result anyref)
    (local $c (ref $Closure7))
    (local.set $c (ref.cast (ref $Closure7) (local.get $closure)))
    (call_ref $ClosureFunc7
      (struct.get $Closure7 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (local.get $arg3)
      (local.get $arg4)
      (local.get $arg5)
      (local.get $arg6)
      (struct.get $Closure7 $func (local.get $c))))

  ;; invoke8: invoke a 8-arity closure
  (func $invoke8 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (result anyref)
    (local $c (ref $Closure8))
    (local.set $c (ref.cast (ref $Closure8) (local.get $closure)))
    (call_ref $ClosureFunc8
      (struct.get $Closure8 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (local.get $arg3)
      (local.get $arg4)
      (local.get $arg5)
      (local.get $arg6)
      (local.get $arg7)
      (struct.get $Closure8 $func (local.get $c))))

  ;; invoke9: invoke a 9-arity closure
  (func $invoke9 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (param $arg8 anyref) (result anyref)
    (local $c (ref $Closure9))
    (local.set $c (ref.cast (ref $Closure9) (local.get $closure)))
    (call_ref $ClosureFunc9
      (struct.get $Closure9 $env (local.get $c))
      (local.get $arg0)
      (local.get $arg1)
      (local.get $arg2)
      (local.get $arg3)
      (local.get $arg4)
      (local.get $arg5)
      (local.get $arg6)
      (local.get $arg7)
      (local.get $arg8)
      (struct.get $Closure9 $func (local.get $c))))

  ;; invoke10: invoke a 10-arity closure
  (func $invoke10 (param $closure anyref) (param $arg0 anyref) (param $arg1 anyref) (param $arg2 anyref) (param $arg3 anyref) (param $arg4 anyref) (param $arg5 anyref) (param $arg6 anyref) (param $arg7 anyref) (param $arg8 anyref) (param $arg9 anyref) (result anyref)
    (local $c (ref $Closure10))
    (local.set $c (ref.cast (ref $Closure10) (local.get $closure)))
    (call_ref $ClosureFunc10
      (struct.get $Closure10 $env (local.get $c))
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
      (struct.get $Closure10 $func (local.get $c))))

  ;; ==========================================
  ;; IReduce Protocol Implementations
  ;; ==========================================

  ;; reduced?: check if value is a Reduced wrapper
  (func $reduced_QMARK_ (param $val anyref) (result i32)
    (ref.test (ref $Reduced) (local.get $val)))

  ;; reduced: wrap value for early termination
  (func $reduced (param $val anyref) (result anyref)
    (struct.new $Reduced (local.get $val)))

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

  ;; hashmap-reduce: reduce over map entries as [k v] vectors
  (func $hashmap_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $i i32)
    (local $count i32)
    (local $arr anyref)
    (local $entry anyref)
    (local.set $arr (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll))))
    (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        ;; Build [k v] entry vector
        (local.set $entry (call $vector_conj
          (call $vector_conj (call $empty_vector)
            (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2))))
          (call $array_get (local.get $arr) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))))
        ;; Apply f: acc = f(acc, entry)
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc) (local.get $entry)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; hashset-reduce: reduce over set elements
  (func $hashset_reduce (param $coll anyref) (param $f anyref) (param $init anyref) (result anyref)
    (local $acc anyref)
    (local $i i32)
    (local $count i32)
    (local $arr anyref)
    (local.set $arr (struct.get $HashSet $array (ref.cast (ref $HashSet) (local.get $coll))))
    (local.set $count (struct.get $HashSet $count (ref.cast (ref $HashSet) (local.get $coll))))
    (local.set $acc (local.get $init))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        (br_if $done (call $reduced_QMARK_ (local.get $acc)))
        (local.set $acc (call $invoke2 (local.get $f) (local.get $acc)
          (call $array_get (local.get $arr) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (call $deref_reduced (local.get $acc)))

  ;; Polymorphic reduce dispatcher
  (func $reduce (param $f anyref) (param $init anyref) (param $coll anyref) (result anyref)
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
                (if (result anyref) (ref.test (ref $Cons) (local.get $coll))
                  (then (call $cons_reduce (local.get $coll) (local.get $f) (local.get $init)))
                  (else
                    (if (result anyref) (ref.test (ref $HashMap) (local.get $coll))
                      (then (call $hashmap_reduce (local.get $coll) (local.get $f) (local.get $init)))
                      (else
                        (if (result anyref) (ref.test (ref $HashSet) (local.get $coll))
                          (then (call $hashset_reduce (local.get $coll) (local.get $f) (local.get $init)))
                          (else (local.get $init))))))))))))))

  ;; reduce-kv: reduce with separate key and value arguments (for maps)
  (func $reduce_kv (param $f anyref) (param $init anyref) (param $coll anyref) (result anyref)
    (local $acc anyref)
    (local $i i32)
    (local $count i32)
    (local $arr anyref)
    (if (result anyref) (ref.is_null (local.get $coll))
      (then (local.get $init))
      (else
        (if (result anyref) (ref.test (ref $HashMap) (local.get $coll))
          (then
            (local.set $arr (struct.get $HashMap $array (ref.cast (ref $HashMap) (local.get $coll))))
            (local.set $count (struct.get $HashMap $count (ref.cast (ref $HashMap) (local.get $coll))))
            (local.set $acc (local.get $init))
            (local.set $i (i32.const 0))
            (block $done
              (loop $loop
                (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
                (br_if $done (call $reduced_QMARK_ (local.get $acc)))
                ;; Apply f: acc = f(acc, key, val)
                (local.set $acc (call $invoke3 (local.get $f) (local.get $acc)
                  (call $array_get (local.get $arr) (i32.mul (local.get $i) (i32.const 2)))
                  (call $array_get (local.get $arr) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $loop)))
            (call $deref_reduced (local.get $acc)))
          (else (local.get $init))))))

  ;; ==========================================
  ;; Lazy Sequence Operations
  ;; ==========================================

  ;; make-lazy-seq: create a lazy sequence from a thunk (0-arity closure)
  (func $make_lazy_seq (param $thunk anyref) (result anyref)
    (struct.new $LazySeq
      (i32.const 12)        ;; type tag (12 = LazySeq)
      (local.get $thunk)    ;; thunk - the 0-arity closure
      (ref.null none)))     ;; realized - initially null (not realized)

  ;; lazy-seq?: check if value is a lazy sequence
  (func $lazy_seq_QMARK_ (param $val anyref) (result anyref)
    (ref.i31 (ref.test (ref $LazySeq) (local.get $val))))

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
  ;; nil = 0, i31 (int/bool) = 1, Keyword = 2, String = 3, Symbol = 4, Float = 5
  ;; Cons = 6, Vector = 7, HashMap = 8, HashSet = 9, Atom = 10
  ;; Closure0-10 = 11 (all closures share tag), LazySeq = 12 (future), Reduced = 13

  ;; type_tag: returns numeric type tag for dispatch using br_table pattern
  (func $type_tag (param $val anyref) (result i32)
    (if (result i32) (ref.is_null (local.get $val))
      (then (i32.const 0))
      (else (if (result i32) (ref.test (ref i31) (local.get $val))
        (then (i32.const 1))
        (else (if (result i32) (ref.test (ref $Keyword) (local.get $val))
          (then (i32.const 2))
          (else (if (result i32) (ref.test (ref $String) (local.get $val))
            (then (i32.const 3))
            (else (if (result i32) (ref.test (ref $Symbol) (local.get $val))
              (then (i32.const 4))
              (else (if (result i32) (ref.test (ref $Float) (local.get $val))
                (then (i32.const 5))
                (else (if (result i32) (ref.test (ref $Cons) (local.get $val))
                  (then (i32.const 6))
                  (else (if (result i32) (ref.test (ref $Vector) (local.get $val))
                    (then (i32.const 7))
                    (else (if (result i32) (ref.test (ref $HashMap) (local.get $val))
                      (then (i32.const 8))
                      (else (if (result i32) (ref.test (ref $HashSet) (local.get $val))
                        (then (i32.const 9))
                        (else (if (result i32) (ref.test (ref $Atom) (local.get $val))
                          (then (i32.const 10))
                          (else (if (result i32) (ref.test (ref $LazySeq) (local.get $val))
                            (then (i32.const 12))
                            (else (if (result i32) (ref.test (ref $Reduced) (local.get $val))
                              (then (i32.const 13))
                              (else (if (result i32) (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or (i32.or
                              (ref.test (ref $Closure0) (local.get $val))
                              (ref.test (ref $Closure1) (local.get $val)))
                              (ref.test (ref $Closure2) (local.get $val)))
                              (ref.test (ref $Closure3) (local.get $val)))
                              (ref.test (ref $Closure4) (local.get $val)))
                              (ref.test (ref $Closure5) (local.get $val)))
                              (ref.test (ref $Closure6) (local.get $val)))
                              (ref.test (ref $Closure7) (local.get $val)))
                              (ref.test (ref $Closure8) (local.get $val)))
                              (ref.test (ref $Closure9) (local.get $val)))
                              (ref.test (ref $Closure10) (local.get $val)))
                                (then (i32.const 11))
                                (else (i32.const -1))))))))))))))))))))))))))))))
  ;; ==========================================
  ;; String Operations
  ;; ==========================================

  ;; str_len: get length of string in bytes
  (func $str_len (param $s anyref) (result i32)
    (array.len (struct.get $String $data (ref.cast (ref $String) (local.get $s)))))

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
    (struct.new $String (i32.const -1) (local.get $new_data)))

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
        (struct.new $String (i32.const -1) (local.get $buf)))
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
        (struct.new $String (i32.const -1) (local.get $result)))))

  ;; str1: convert any single value to string
  ;; nil -> "", int -> decimal, string -> itself, keyword -> ":name"
  (func $str1 (param $val anyref) (result anyref)
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
                (if (result anyref) (ref.test (ref $Keyword) (local.get $val))
                  (then (call $keyword_to_str (local.get $val)))
                  (else
                    ;; Float -> approximate string (just integer part for now)
                    (if (result anyref) (ref.test (ref $Float) (local.get $val))
                      (then (call $int_to_str (i32.trunc_f64_s
                        (struct.get $Float $val (ref.cast (ref $Float) (local.get $val))))))
                      (else
                        ;; Other -> empty string
                        (call $make_empty_str))))))))))))

  ;; make_empty_str: create an empty string
  (func $make_empty_str (result anyref)
    (struct.new $String (i32.const -1) (array.new $CharArray (i32.const 0) (i32.const 0))))

  ;; keyword_to_str: convert keyword to ":name" string
  ;; Uses keyword name table (initialized in $start)
  (func $keyword_to_str (param $kw anyref) (result anyref)
    (local $id i32)
    (local $name anyref)
    (local $colon (ref $CharArray))
    (local $colon_str anyref)
    (local.set $id (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $kw))))
    ;; Look up name from keyword name table
    (local.set $name (call $array_get (global.get $__kw_names) (local.get $id)))
    ;; Prepend ":"
    (local.set $colon (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $colon) (i32.const 0) (i32.const 58))  ;; ':'
    (local.set $colon_str (struct.new $String (i32.const -1) (local.get $colon)))
    (call $str_concat (local.get $colon_str) (local.get $name)))

  ;; name_fn: get bare name from keyword (without colon)
  (func $name_fn (param $val anyref) (result anyref)
    (if (result anyref) (ref.test (ref $Keyword) (local.get $val))
      (then
        (call $array_get (global.get $__kw_names)
          (struct.get $Keyword $id (ref.cast (ref $Keyword) (local.get $val)))))
      (else
        ;; String -> return itself
        (if (result anyref) (ref.test (ref $String) (local.get $val))
          (then (local.get $val))
          (else (call $make_empty_str))))))

  ;; subs: get substring from start (inclusive) to end (exclusive)
  (func $subs (param $s anyref) (param $start i32) (param $end i32) (result anyref)
    (local $src (ref $CharArray))
    (local $len i32)
    (local $new_data (ref $CharArray))
    (local.set $src (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $len (i32.sub (local.get $end) (local.get $start)))
    (if (result anyref) (i32.le_s (local.get $len) (i32.const 0))
      (then (call $make_empty_str))
      (else
        (local.set $new_data (array.new $CharArray (i32.const 0) (local.get $len)))
        (array.copy $CharArray $CharArray (local.get $new_data) (i32.const 0) (local.get $src) (local.get $start) (local.get $len))
        (struct.new $String (i32.const -1) (local.get $new_data)))))

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

  ;; char_at_as_str: return single-char string at index
  (func $char_at_as_str (param $s anyref) (param $idx i32) (result anyref)
    (local $data (ref $CharArray))
    (local $new_data (ref $CharArray))
    (local.set $data (struct.get $String $data (ref.cast (ref $String) (local.get $s))))
    (local.set $new_data (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $new_data) (i32.const 0)
      (array.get_u $CharArray (local.get $data) (local.get $idx)))
    (struct.new $String (i32.const -1) (local.get $new_data)))

  ;; nth_polymorphic: get element at index from vector or string
  (func $nth_polymorphic (param $coll anyref) (param $idx i32) (result anyref)
    (if (result anyref) (ref.test (ref $Vector) (local.get $coll))
      (then (call $vector_nth (local.get $coll) (local.get $idx)))
      (else
        (if (result anyref) (ref.test (ref $String) (local.get $coll))
          (then (call $char_at_as_str (local.get $coll) (local.get $idx)))
          (else (ref.null none))))))

  ;; Keyword name table global (initialized in $start)
  (global $__kw_names (mut anyref) (ref.null none))


  ;; Globals
  (global $_AMP_env (mut anyref) (ref.null none))
  (global $_AMP_form (mut anyref) (ref.null none))
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
  (global $__builtin__STAR_ (mut anyref) (ref.null none))
  (global $__proto_area_7_closure (mut anyref) (ref.null none))
  (global $__proto_perimeter_7_closure (mut anyref) (ref.null none))
  (global $__str_0 (mut anyref) (ref.null none))
  (global $__str_1 (mut anyref) (ref.null none))
  (global $__str_2 (mut anyref) (ref.null none))
  (global $__str_3 (mut anyref) (ref.null none))
  (global $__str_4 (mut anyref) (ref.null none))
  (global $__str_5 (mut anyref) (ref.null none))
  (global $__str_6 (mut anyref) (ref.null none))
  (global $__str_7 (mut anyref) (ref.null none))

  ;; Closure function declarations
  (elem declare func $closure1 $closure2 $closure3 $closure4 $closure5 $closure6 $closure7 $closure8 $closure9 $closure10 $closure11 $closure12 $closure13 $closure14 $closure15 $closure16 $closure17 $closure18 $closure19 $fn20 $closure21 $closure22 $closure23 $__proto_area_7 $__proto_perimeter_7 $closure24 $fn25 $fn26 $fn27 $fn28 $__builtin__STAR__fn $__proto_area_7 $__proto_perimeter_7)

  ;; User functions
  (func $identity_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $identity (export "identity") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $identity_internal (ref.i31 (local.get $x))))))

  (func $second_internal (param $coll anyref) (result anyref)
    (call $first (call $rest (local.get $coll))))

  (func $second (export "second") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $second_internal (ref.i31 (local.get $coll))))))

  (func $ffirst_internal (param $coll anyref) (result anyref)
    (call $first (call $first (local.get $coll))))

  (func $ffirst (export "ffirst") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ffirst_internal (ref.i31 (local.get $coll))))))

  (func $closure1 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $temp__2 anyref)
    (local $s anyref)
    (block (result anyref)
      (local.set $temp__2 (call $seq (call $array_get (local.get $__env) (i32.const 0))))
      (if (result anyref)
      (call $truthy (local.get $temp__2))
      (then (block (result anyref)
      (block (result anyref)
      (local.set $s (local.get $temp__2))
      (call $cons (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (call $first (local.get $s))) (call $map_internal (call $array_get (local.get $__env) (i32.const 1)) (call $rest (local.get $s)))))))
      (else (ref.null none)))))

  (func $map_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure1) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $f))
        (local.get $__tmp_env)))))

  (func $map (export "map") (param $f i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $map_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll))))))

  (func $closure2 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $temp__4 anyref)
    (local $s anyref)
    (local $x anyref)
    (block (result anyref)
      (local.set $temp__4 (call $seq (call $array_get (local.get $__env) (i32.const 0))))
      (if (result anyref)
      (call $truthy (local.get $temp__4))
      (then (block (result anyref)
      (block (result anyref)
      (local.set $s (local.get $temp__4))
      (block (result anyref)
      (local.set $x (call $first (local.get $s)))
      (if (result anyref)
      (call $truthy (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x)))
      (then (call $cons (local.get $x) (call $filter_internal (call $array_get (local.get $__env) (i32.const 1)) (call $rest (local.get $s)))))
      (else (call $filter_internal (call $array_get (local.get $__env) (i32.const 1)) (call $rest (local.get $s)))))))))
      (else (ref.null none)))))

  (func $filter_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure2) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $pred))
        (local.get $__tmp_env)))))

  (func $filter (export "filter") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $filter_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $closure3 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (local $temp__6 anyref)
    (local $s anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))) (i32.const 0))))
      (then (block (result anyref)
      (block (result anyref)
      (local.set $temp__6 (call $seq (call $array_get (local.get $__env) (i32.const 0))))
      (if (result anyref)
      (call $truthy (local.get $temp__6))
      (then (block (result anyref)
      (block (result anyref)
      (local.set $s (local.get $temp__6))
      (call $cons (call $first (local.get $s)) (call $take_internal (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))) (i32.const 1))) (call $rest (local.get $s)))))))
      (else (ref.null none))))))
      (else (ref.null none))))

  (func $take_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure3) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $coll))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $n))
        (local.get $__tmp_env)))))

  (func $take (export "take") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $take_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $drop_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $remaining anyref)
    (local $curr anyref)
    (block (result anyref)
      (local.set $remaining (local.get $n))
      (local.set $curr (local.get $coll))
      (loop $loop0 (result anyref)
        (if (result anyref)
      (call $truthy (if (result anyref) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.le_s (i31.get_s (ref.cast (ref i31) (local.get $remaining))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0))))))))
        (then (ref.i31 (i32.le_s (i31.get_s (ref.cast (ref i31) (local.get $remaining))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0)))))))
        (else (call $nil_QMARK_ (call $seq (local.get $curr))))))
      (then (local.get $curr))
      (else (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $remaining))) (i32.const 1)))
        (call $rest (local.get $curr))
        (local.set $curr)
        (local.set $remaining)
        (br $loop0))))))

  (func $drop (export "drop") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $drop_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $nth_list_internal (param $coll anyref) (param $n anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (local.get $n))))))
      (then (call $first (local.get $coll)))
      (else (call $nth_list_internal (call $rest (local.get $coll)) (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1)))))))

  (func $nth_list (export "nth-list") (param $coll i32) (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $nth_list_internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $n))))))

  (func $length_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.i31 (i32.const 0)))
      (else (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (call $length_internal (call $rest (local.get $coll))))) (i32.const 1))))))

  (func $length (export "length") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $length_internal (ref.i31 (local.get $coll))))))

  (func $concat_list_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $a)))
      (then (local.get $b))
      (else (call $cons (call $first (local.get $a)) (call $concat_list_internal (call $rest (local.get $a)) (local.get $b))))))

  (func $concat_list (export "concat-list") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $concat_list_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $last_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (call $rest (local.get $coll))))
      (then (call $first (local.get $coll)))
      (else (call $last_internal (call $rest (local.get $coll))))))

  (func $last (export "last") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $last_internal (ref.i31 (local.get $coll))))))

  (func $butlast_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (call $rest (local.get $coll))))
      (then (ref.null none))
      (else (call $cons (call $first (local.get $coll)) (call $butlast_internal (call $rest (local.get $coll)))))))

  (func $butlast (export "butlast") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $butlast_internal (ref.i31 (local.get $coll))))))

  (func $even_QMARK__internal (param $n anyref) (result anyref)
    (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 2)))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 2)))))))))))))))))))

  (func $even_QMARK_ (export "even?") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $even_QMARK__internal (ref.i31 (local.get $n))))))

  (func $odd_QMARK__internal (param $n anyref) (result anyref)
    (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (call $even_QMARK__internal (local.get $n)))))))

  (func $odd_QMARK_ (export "odd?") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $odd_QMARK__internal (ref.i31 (local.get $n))))))

  (func $closure4 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $array_get (local.get $__env) (i32.const 0)) (call $range_infinite_internal (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 0)))) (i32.const 1))))))

  (func $range_infinite_internal (param $start anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure4) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $start))
        (local.get $__tmp_env)))))

  (func $range_infinite (export "range-infinite") (param $start i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_infinite_internal (ref.i31 (local.get $start))))))

  (func $closure5 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (if (result anyref)
      (call $truthy (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 2)))) (i32.const 0))))
      (then (ref.i31 (i32.lt_s (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))) (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 0)))))))
      (else (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))) (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 0)))))))))
      (then (block (result anyref)
      (call $cons (call $array_get (local.get $__env) (i32.const 1)) (call $range_step_internal (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))) (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 2)))))) (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 2))))))
      (else (ref.null none))))

  (func $range_step_internal (param $start anyref) (param $end anyref) (param $step anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure5) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 3)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $end))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $start))
        (call $array_set (local.get $__tmp_env) (i32.const 2) (local.get $step))
        (local.get $__tmp_env)))))

  (func $range_step (export "range-step") (param $start i32) (param $end i32) (param $step i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_step_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)) (ref.i31 (local.get $step))))))

  (func $range_from_arity1_internal (param $start anyref) (result anyref)
    (call $range_infinite_internal (local.get $start)))

  (func $range_from_arity1 (export "range-from_arity1") (param $start i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_from_arity1_internal (ref.i31 (local.get $start))))))

  (func $range_from_arity2_internal (param $start anyref) (param $end anyref) (result anyref)
    (call $range_step_internal (local.get $start) (local.get $end) (ref.i31 (i32.const 1))))

  (func $range_from_arity2 (export "range-from_arity2") (param $start i32) (param $end i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_from_arity2_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end))))))

  (func $range_from_arity3_internal (param $start anyref) (param $end anyref) (param $step anyref) (result anyref)
    (call $range_step_internal (local.get $start) (local.get $end) (local.get $step)))

  (func $range_from_arity3 (export "range-from_arity3") (param $start i32) (param $end i32) (param $step i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_from_arity3_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)) (ref.i31 (local.get $step))))))

  (func $reverse_internal (param $coll anyref) (result anyref)
    (local $acc anyref)
    (local $curr anyref)
    (block (result anyref)
      (local.set $acc (ref.null none))
      (local.set $curr (local.get $coll))
      (loop $loop1 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $curr)))
      (then (local.get $acc))
      (else (call $cons (call $first (local.get $curr)) (local.get $acc))
        (call $rest (local.get $curr))
        (local.set $curr)
        (local.set $acc)
        (br $loop1))))))

  (func $reverse (export "reverse") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $reverse_internal (ref.i31 (local.get $coll))))))

  (func $concat_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $a)))
      (then (local.get $b))
      (else (call $cons (call $first (local.get $a)) (call $concat_internal (call $rest (local.get $a)) (local.get $b))))))

  (func $concat (export "concat") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $concat_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $take_while_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (if (result anyref)
      (call $truthy (call $invoke1 (local.get $pred) (call $first (local.get $coll))))
      (then (call $cons (call $first (local.get $coll)) (call $take_while_internal (local.get $pred) (call $rest (local.get $coll)))))
      (else (ref.null none))))))

  (func $take_while (export "take-while") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $take_while_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $drop_while_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (if (result anyref)
      (call $truthy (call $invoke1 (local.get $pred) (call $first (local.get $coll))))
      (then (call $drop_while_internal (local.get $pred) (call $rest (local.get $coll))))
      (else (local.get $coll))))))

  (func $drop_while (export "drop-while") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $drop_while_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $split_at_internal (param $n anyref) (param $coll anyref) (result anyref)
    (call $cons (call $take_internal (local.get $n) (local.get $coll)) (call $cons (call $drop_internal (local.get $n) (local.get $coll)) (ref.null none))))

  (func $split_at (export "split-at") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $split_at_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $split_with_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (call $cons (call $take_while_internal (local.get $pred) (local.get $coll)) (call $cons (call $drop_while_internal (local.get $pred) (local.get $coll)) (ref.null none))))

  (func $split_with (export "split-with") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $split_with_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $interpose_internal (param $sep anyref) (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (if (result anyref)
      (call $truthy (call $nil_QMARK_ (call $rest (local.get $coll))))
      (then (call $cons (call $first (local.get $coll)) (ref.null none)))
      (else (call $cons (call $first (local.get $coll)) (call $cons (local.get $sep) (call $interpose_internal (local.get $sep) (call $rest (local.get $coll))))))))))

  (func $interpose (export "interpose") (param $sep i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $interpose_internal (ref.i31 (local.get $sep)) (ref.i31 (local.get $coll))))))

  (func $interleave_internal (param $c1 anyref) (param $c2 anyref) (result anyref)
    (if (result anyref)
      (call $truthy (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $nil_QMARK_ (local.get $c1))))
        (then (call $nil_QMARK_ (local.get $c1)))
        (else (call $nil_QMARK_ (local.get $c2)))))
      (then (ref.null none))
      (else (call $cons (call $first (local.get $c1)) (call $cons (call $first (local.get $c2)) (call $interleave_internal (call $rest (local.get $c1)) (call $rest (local.get $c2))))))))

  (func $interleave (export "interleave") (param $c1 i32) (param $c2 i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $interleave_internal (ref.i31 (local.get $c1)) (ref.i31 (local.get $c2))))))

  (func $some_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (block (result anyref)
      (local.set $result (call $invoke1 (local.get $pred) (call $first (local.get $coll))))
      (if (result anyref)
      (call $truthy (local.get $result))
      (then (local.get $result))
      (else (call $some_internal (local.get $pred) (call $rest (local.get $coll)))))))))

  (func $some (export "some") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $some_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $every_QMARK__internal (param $pred anyref) (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.i31 (i32.const 1)))
      (else (if (result anyref)
      (call $truthy (call $invoke1 (local.get $pred) (call $first (local.get $coll))))
      (then (call $every_QMARK__internal (local.get $pred) (call $rest (local.get $coll))))
      (else (ref.i31 (i32.const 0)))))))

  (func $every_QMARK_ (export "every?") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $every_QMARK__internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $not_every_QMARK__internal (param $pred anyref) (param $coll anyref) (result anyref)
    (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (call $every_QMARK__internal (local.get $pred) (local.get $coll)))))))

  (func $not_every_QMARK_ (export "not-every?") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $not_every_QMARK__internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $not_any_QMARK__internal (param $pred anyref) (param $coll anyref) (result anyref)
    (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (call $some_internal (local.get $pred) (local.get $coll)))))))

  (func $not_any_QMARK_ (export "not-any?") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $not_any_QMARK__internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $keep_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (block (result anyref)
      (local.set $result (call $invoke1 (local.get $f) (call $first (local.get $coll))))
      (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $result)))
      (then (call $keep_internal (local.get $f) (call $rest (local.get $coll))))
      (else (call $cons (local.get $result) (call $keep_internal (local.get $f) (call $rest (local.get $coll))))))))))

  (func $keep (export "keep") (param $f i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $keep_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll))))))

  (func $map_indexed_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $idx anyref)
    (local $curr anyref)
    (local $acc anyref)
    (block (result anyref)
      (local.set $idx (ref.i31 (i32.const 0)))
      (local.set $curr (local.get $coll))
      (local.set $acc (ref.null none))
      (loop $loop2 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $curr)))
      (then (call $reverse_internal (local.get $acc)))
      (else (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
        (call $rest (local.get $curr))
        (call $cons (call $invoke2 (local.get $f) (local.get $idx) (call $first (local.get $curr))) (local.get $acc))
        (local.set $acc)
        (local.set $curr)
        (local.set $idx)
        (br $loop2))))))

  (func $map_indexed (export "map-indexed") (param $f i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $map_indexed_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll))))))

  (func $keep_indexed_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $idx anyref)
    (local $curr anyref)
    (local $acc anyref)
    (local $result anyref)
    (block (result anyref)
      (local.set $idx (ref.i31 (i32.const 0)))
      (local.set $curr (local.get $coll))
      (local.set $acc (ref.null none))
      (loop $loop3 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $curr)))
      (then (call $reverse_internal (local.get $acc)))
      (else (block (result anyref)
      (local.set $result (call $invoke2 (local.get $f) (local.get $idx) (call $first (local.get $curr))))
      (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $result)))
      (then (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
        (call $rest (local.get $curr))
        (local.get $acc)
        (local.set $acc)
        (local.set $curr)
        (local.set $idx)
        (br $loop3))
      (else (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
        (call $rest (local.get $curr))
        (call $cons (local.get $result) (local.get $acc))
        (local.set $acc)
        (local.set $curr)
        (local.set $idx)
        (br $loop3)))))))))

  (func $keep_indexed (export "keep-indexed") (param $f i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $keep_indexed_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll))))))

  (func $closure6 (type $ClosureFunc1) (param $__env anyref) (param $y anyref) (result anyref)
    (ref.i31 (call $eq (call $array_get (local.get $__env) (i32.const 0)) (local.get $y))))

  (func $distinct_internal (param $coll anyref) (result anyref)
    (local $seen anyref)
    (local $curr anyref)
    (local $acc anyref)
    (local $x anyref)
    (local $__tmp_env anyref)
    (block (result anyref)
      (local.set $seen (ref.null none))
      (local.set $curr (local.get $coll))
      (local.set $acc (ref.null none))
      (loop $loop4 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $curr)))
      (then (call $reverse_internal (local.get $acc)))
      (else (block (result anyref)
      (local.set $x (call $first (local.get $curr)))
      (if (result anyref)
      (call $truthy (call $some_internal (struct.new $Closure1 (ref.func $closure6) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $x))
        (local.get $__tmp_env))) (local.get $seen)))
      (then (local.get $seen)
        (call $rest (local.get $curr))
        (local.get $acc)
        (local.set $acc)
        (local.set $curr)
        (local.set $seen)
        (br $loop4))
      (else (call $cons (local.get $x) (local.get $seen))
        (call $rest (local.get $curr))
        (call $cons (local.get $x) (local.get $acc))
        (local.set $acc)
        (local.set $curr)
        (local.set $seen)
        (br $loop4)))))))))

  (func $distinct (export "distinct") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $distinct_internal (ref.i31 (local.get $coll))))))

  (func $partition_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $chunk anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (block (result anyref)
      (local.set $chunk (call $take_internal (local.get $n) (local.get $coll)))
      (if (result anyref)
      (call $truthy (ref.i31 (call $eq (call $length_internal (local.get $chunk)) (local.get $n))))
      (then (call $cons (local.get $chunk) (call $partition_internal (local.get $n) (call $drop_internal (local.get $n) (local.get $coll)))))
      (else (ref.null none)))))))

  (func $partition (export "partition") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $partition_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $partition_all_internal (param $n anyref) (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (call $cons (call $take_internal (local.get $n) (local.get $coll)) (call $partition_all_internal (local.get $n) (call $drop_internal (local.get $n) (local.get $coll)))))))

  (func $partition_all (export "partition-all") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $partition_all_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $flatten_one_internal (param $coll anyref) (result anyref)
    (local $x anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (block (result anyref)
      (local.set $x (call $first (local.get $coll)))
      (if (result anyref)
      (call $truthy (call $cons_QMARK_ (local.get $x)))
      (then (call $concat_internal (local.get $x) (call $flatten_one_internal (call $rest (local.get $coll)))))
      (else (call $cons (local.get $x) (call $flatten_one_internal (call $rest (local.get $coll))))))))))

  (func $flatten_one (export "flatten-one") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $flatten_one_internal (ref.i31 (local.get $coll))))))

  (func $mapcat_internal (param $f anyref) (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (call $concat_internal (call $invoke1 (local.get $f) (call $first (local.get $coll))) (call $mapcat_internal (local.get $f) (call $rest (local.get $coll)))))))

  (func $mapcat (export "mapcat") (param $f i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $mapcat_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll))))))

  (func $closure7 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))))))

  (func $remove_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $filter_internal (struct.new $Closure1 (ref.func $closure7) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $pred))
        (local.get $__tmp_env))) (local.get $coll)))

  (func $remove (export "remove") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $remove_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $next_internal (param $coll anyref) (result anyref)
    (local $r anyref)
    (block (result anyref)
      (local.set $r (call $rest (local.get $coll)))
      (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $r)))
      (then (ref.null none))
      (else (if (result anyref)
      (call $truthy (call $cons_QMARK_ (local.get $r)))
      (then (local.get $r))
      (else (ref.null none)))))))

  (func $next (export "next") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $next_internal (ref.i31 (local.get $coll))))))

  (func $nthnext_internal (param $coll anyref) (param $n anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (local.get $n))))))
      (then (local.get $coll))
      (else (call $nthnext_internal (call $rest (local.get $coll)) (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1)))))))

  (func $nthnext (export "nthnext") (param $coll i32) (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $nthnext_internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $n))))))

  (func $nthrest_internal (param $coll anyref) (param $n anyref) (result anyref)
    (call $nthnext_internal (local.get $coll) (local.get $n)))

  (func $nthrest (export "nthrest") (param $coll i32) (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $nthrest_internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $n))))))

  (func $repeatedly_n_internal (param $n anyref) (param $f anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (local.get $n))))))
      (then (ref.null none))
      (else (call $cons (call $invoke0 (local.get $f) ) (call $repeatedly_n_internal (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1))) (local.get $f))))))

  (func $repeatedly_n (export "repeatedly-n") (param $n i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeatedly_n_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $f))))))

  (func $merge_internal (param $m1 anyref) (param $m2 anyref) (result anyref)
    (local $ks anyref)
    (local $result anyref)
    (local $remaining anyref)
    (local $k anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $m2)))
      (then (local.get $m1))
      (else (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $m1)))
      (then (local.get $m2))
      (else (block (result anyref)
      (local.set $ks (call $keys (local.get $m2)))
      (block (result anyref)
      (local.set $result (local.get $m1))
      (local.set $remaining (local.get $ks))
      (loop $loop5 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (block (result anyref)
      (local.set $k (call $first (local.get $remaining)))
      (call $assoc (local.get $result) (local.get $k) (call $hash_map_get (local.get $m2) (local.get $k)))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop5))))))))))))

  (func $merge (export "merge") (param $m1 i32) (param $m2 i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $merge_internal (ref.i31 (local.get $m1)) (ref.i31 (local.get $m2))))))

  (func $find_internal (param $m anyref) (param $k anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $hash_map_contains_QMARK_ (local.get $m) (local.get $k)))
      (then (call $vector_conj (call $vector_conj (call $empty_vector) (local.get $k)) (call $hash_map_get (local.get $m) (local.get $k))))
      (else (ref.null none))))

  (func $find (export "find") (param $m i32) (param $k i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $find_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $k))))))

  (func $select_keys_internal (param $m anyref) (param $ks anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (local $k anyref)
    (block (result anyref)
      (local.set $result (call $empty_hash_map))
      (local.set $remaining (local.get $ks))
      (loop $loop6 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (block (result anyref)
      (local.set $k (call $first (local.get $remaining)))
      (if (result anyref)
      (call $truthy (call $hash_map_contains_QMARK_ (local.get $m) (local.get $k)))
      (then (call $assoc (local.get $result) (local.get $k) (call $hash_map_get (local.get $m) (local.get $k)))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop6))
      (else (local.get $result)
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop6)))))))))

  (func $select_keys (export "select-keys") (param $m i32) (param $ks i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $select_keys_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks))))))

  (func $get_in_internal (param $m anyref) (param $ks anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $ks)))
      (then (local.get $m))
      (else (call $get_in_internal (call $hash_map_get (local.get $m) (call $first (local.get $ks))) (call $rest (local.get $ks))))))

  (func $get_in (export "get-in") (param $m i32) (param $ks i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $get_in_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks))))))

  (func $assoc_in_internal (param $m anyref) (param $ks anyref) (param $v anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (call $rest (local.get $ks))))
      (then (call $assoc (local.get $m) (call $first (local.get $ks)) (local.get $v)))
      (else (call $assoc (local.get $m) (call $first (local.get $ks)) (call $assoc_in_internal (call $hash_map_get (local.get $m) (call $first (local.get $ks))) (call $rest (local.get $ks)) (local.get $v))))))

  (func $assoc_in (export "assoc-in") (param $m i32) (param $ks i32) (param $v i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $assoc_in_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks)) (ref.i31 (local.get $v))))))

  (func $update_internal (param $m anyref) (param $k anyref) (param $f anyref) (result anyref)
    (call $assoc (local.get $m) (local.get $k) (call $invoke1 (local.get $f) (call $hash_map_get (local.get $m) (local.get $k)))))

  (func $update (export "update") (param $m i32) (param $k i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $update_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $k)) (ref.i31 (local.get $f))))))

  (func $update_in_internal (param $m anyref) (param $ks anyref) (param $f anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (call $rest (local.get $ks))))
      (then (call $update_internal (local.get $m) (call $first (local.get $ks)) (local.get $f)))
      (else (call $assoc (local.get $m) (call $first (local.get $ks)) (call $update_in_internal (call $hash_map_get (local.get $m) (call $first (local.get $ks))) (call $rest (local.get $ks)) (local.get $f))))))

  (func $update_in (export "update-in") (param $m i32) (param $ks i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $update_in_internal (ref.i31 (local.get $m)) (ref.i31 (local.get $ks)) (ref.i31 (local.get $f))))))

  (func $set_internal (param $coll anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (block (result anyref)
      (local.set $result (call $empty_hash_set))
      (local.set $remaining (local.get $coll))
      (loop $loop7 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (call $set_conj (local.get $result) (call $first (local.get $remaining)))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop7))))))

  (func $set (export "set") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $set_internal (ref.i31 (local.get $coll))))))

  (func $union_internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (block (result anyref)
      (local.set $result (local.get $s1))
      (local.set $remaining (call $seq (local.get $s2)))
      (loop $loop8 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (call $set_conj (local.get $result) (call $first (local.get $remaining)))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop8))))))

  (func $union (export "union") (param $s1 i32) (param $s2 i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $union_internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2))))))

  (func $intersection_internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (local $elem anyref)
    (block (result anyref)
      (local.set $result (call $empty_hash_set))
      (local.set $remaining (call $seq (local.get $s1)))
      (loop $loop9 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (block (result anyref)
      (local.set $elem (call $first (local.get $remaining)))
      (if (result anyref)
      (call $truthy (call $hash_map_contains_QMARK_ (local.get $s2) (local.get $elem)))
      (then (call $set_conj (local.get $result) (local.get $elem))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop9))
      (else (local.get $result)
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop9)))))))))

  (func $intersection (export "intersection") (param $s1 i32) (param $s2 i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $intersection_internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2))))))

  (func $difference_internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (local $elem anyref)
    (block (result anyref)
      (local.set $result (call $empty_hash_set))
      (local.set $remaining (call $seq (local.get $s1)))
      (loop $loop10 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (block (result anyref)
      (local.set $elem (call $first (local.get $remaining)))
      (if (result anyref)
      (call $truthy (call $hash_map_contains_QMARK_ (local.get $s2) (local.get $elem)))
      (then (local.get $result)
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop10))
      (else (call $set_conj (local.get $result) (local.get $elem))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop10)))))))))

  (func $difference (export "difference") (param $s1 i32) (param $s2 i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $difference_internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2))))))

  (func $closure8 (type $ClosureFunc1) (param $__env anyref) (param $elem anyref) (result anyref)
    (call $hash_map_contains_QMARK_ (call $array_get (local.get $__env) (i32.const 0)) (local.get $elem)))

  (func $subset_QMARK__internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $every_QMARK__internal (struct.new $Closure1 (ref.func $closure8) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $s2))
        (local.get $__tmp_env))) (call $seq (local.get $s1))))

  (func $subset_QMARK_ (export "subset?") (param $s1 i32) (param $s2 i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $subset_QMARK__internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2))))))

  (func $superset_QMARK__internal (param $s1 anyref) (param $s2 anyref) (result anyref)
    (call $subset_QMARK__internal (local.get $s2) (local.get $s1)))

  (func $superset_QMARK_ (export "superset?") (param $s1 i32) (param $s2 i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $superset_QMARK__internal (ref.i31 (local.get $s1)) (ref.i31 (local.get $s2))))))

  (func $swap_vals_BANG__internal (param $a anyref) (param $f anyref) (result anyref)
    (local $old anyref)
    (local $new anyref)
    (block (result anyref)
      (local.set $old (call $deref (local.get $a)))
      (local.set $new (call $invoke1 (local.get $f) (local.get $old)))
      (block (result anyref)
      (call $reset_BANG_ (local.get $a) (local.get $new))
      drop
      (call $vector_conj (call $vector_conj (call $empty_vector) (local.get $old)) (local.get $new)))))

  (func $swap_vals_BANG_ (export "swap-vals!") (param $a i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $swap_vals_BANG__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $f))))))

  (func $reset_vals_BANG__internal (param $a anyref) (param $newval anyref) (result anyref)
    (local $old anyref)
    (block (result anyref)
      (local.set $old (call $deref (local.get $a)))
      (block (result anyref)
      (call $reset_BANG_ (local.get $a) (local.get $newval))
      drop
      (call $vector_conj (call $vector_conj (call $empty_vector) (local.get $old)) (local.get $newval)))))

  (func $reset_vals_BANG_ (export "reset-vals!") (param $a i32) (param $newval i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $reset_vals_BANG__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $newval))))))

  (func $closure9 (type $ClosureFunc1) (param $__env anyref) (param $_ anyref) (result anyref)
    (call $array_get (local.get $__env) (i32.const 0)))

  (func $constantly_internal (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure9) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $x))
        (local.get $__tmp_env))))

  (func $constantly (export "constantly") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $constantly_internal (ref.i31 (local.get $x))))))

  (func $closure10 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))

  (func $comp_internal (param $f anyref) (param $g anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure10) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g))
        (local.get $__tmp_env))))

  (func $comp (export "comp") (param $f i32) (param $g i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $comp_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g))))))

  (func $closure11 (type $ClosureFunc1) (param $__env anyref) (param $y anyref) (result anyref)
    (call $invoke2 (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1)) (local.get $y)))

  (func $partial_internal (param $f anyref) (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure11) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $x))
        (local.get $__tmp_env))))

  (func $partial (export "partial") (param $f i32) (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $partial_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $x))))))

  (func $closure12 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (ref.i31 (i32.eqz (i31.get_s (ref.cast (ref i31) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))))))

  (func $complement_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure12) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (local.get $__tmp_env))))

  (func $complement (export "complement") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $complement_internal (ref.i31 (local.get $f))))))

  (func $closure13 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (call $vector_conj (call $vector_conj (call $empty_vector) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))) (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x))))

  (func $juxt_internal (param $f anyref) (param $g anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure13) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g))
        (local.get $__tmp_env))))

  (func $juxt (export "juxt") (param $f i32) (param $g i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $juxt_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g))))))

  (func $range_arity0_internal  (result anyref)
    (call $range_from_arity1_internal (ref.i31 (i32.const 0))))

  (func $range_arity0 (export "range_arity0")  (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_arity0_internal ))))

  (func $range_arity1_internal (param $end anyref) (result anyref)
    (call $range_from_arity3_internal (ref.i31 (i32.const 0)) (local.get $end) (ref.i31 (i32.const 1))))

  (func $range_arity1 (export "range_arity1") (param $end i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_arity1_internal (ref.i31 (local.get $end))))))

  (func $range_arity2_internal (param $start anyref) (param $end anyref) (result anyref)
    (call $range_from_arity3_internal (local.get $start) (local.get $end) (ref.i31 (i32.const 1))))

  (func $range_arity2 (export "range_arity2") (param $start i32) (param $end i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_arity2_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end))))))

  (func $range_arity3_internal (param $start anyref) (param $end anyref) (param $step anyref) (result anyref)
    (call $range_from_arity3_internal (local.get $start) (local.get $end) (local.get $step)))

  (func $range_arity3 (export "range_arity3") (param $start i32) (param $end i32) (param $step i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $range_arity3_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $end)) (ref.i31 (local.get $step))))))

  (func $closure14 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $array_get (local.get $__env) (i32.const 0)) (call $repeat_infinite_internal (call $array_get (local.get $__env) (i32.const 0)))))

  (func $repeat_infinite_internal (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure14) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $x))
        (local.get $__tmp_env)))))

  (func $repeat_infinite (export "repeat-infinite") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeat_infinite_internal (ref.i31 (local.get $x))))))

  (func $closure15 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 0)))) (i32.const 0))))
      (then (block (result anyref)
      (call $cons (call $array_get (local.get $__env) (i32.const 1)) (call $repeat_n_internal (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 0)))) (i32.const 1))) (call $array_get (local.get $__env) (i32.const 1))))))
      (else (ref.null none))))

  (func $repeat_n_internal (param $n anyref) (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure15) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $n))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $x))
        (local.get $__tmp_env)))))

  (func $repeat_n (export "repeat-n") (param $n i32) (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeat_n_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $x))))))

  (func $repeat_arity1_internal (param $x anyref) (result anyref)
    (call $repeat_infinite_internal (local.get $x)))

  (func $repeat_arity1 (export "repeat_arity1") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeat_arity1_internal (ref.i31 (local.get $x))))))

  (func $repeat_arity2_internal (param $n anyref) (param $x anyref) (result anyref)
    (call $repeat_n_internal (local.get $n) (local.get $x)))

  (func $repeat_arity2 (export "repeat_arity2") (param $n i32) (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeat_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $x))))))

  (func $closure16 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $invoke0 (call $array_get (local.get $__env) (i32.const 0)) ) (call $repeatedly_infinite_internal (call $array_get (local.get $__env) (i32.const 0)))))

  (func $repeatedly_infinite_internal (param $f anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure16) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (local.get $__tmp_env)))))

  (func $repeatedly_infinite (export "repeatedly-infinite") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeatedly_infinite_internal (ref.i31 (local.get $f))))))

  (func $closure17 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))) (i32.const 0))))
      (then (block (result anyref)
      (call $cons (call $invoke0 (call $array_get (local.get $__env) (i32.const 0)) ) (call $repeatedly_n_internal (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))) (i32.const 1))) (call $array_get (local.get $__env) (i32.const 0))))))
      (else (ref.null none))))

  (func $repeatedly_arity1_internal (param $f anyref) (result anyref)
    (call $repeatedly_infinite_internal (local.get $f)))

  (func $repeatedly_arity1 (export "repeatedly_arity1") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeatedly_arity1_internal (ref.i31 (local.get $f))))))

  (func $repeatedly_arity2_internal (param $n anyref) (param $f anyref) (result anyref)
    (call $repeatedly_n_internal (local.get $n) (local.get $f)))

  (func $repeatedly_arity2 (export "repeatedly_arity2") (param $n i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeatedly_arity2_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $f))))))

  (func $closure18 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $array_get (local.get $__env) (i32.const 1)) (call $iterate_internal (call $array_get (local.get $__env) (i32.const 0)) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (call $array_get (local.get $__env) (i32.const 1))))))

  (func $iterate_internal (param $f anyref) (param $x anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure18) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $x))
        (local.get $__tmp_env)))))

  (func $iterate (export "iterate") (param $f i32) (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $iterate_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $x))))))

  (func $into_internal (param $to anyref) (param $from anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (block (result anyref)
      (local.set $result (local.get $to))
      (local.set $remaining (call $seq (local.get $from)))
      (loop $loop11 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (call $vector_conj (local.get $result) (call $first (local.get $remaining)))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop11))))))

  (func $into (export "into") (param $to i32) (param $from i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $into_internal (ref.i31 (local.get $to)) (ref.i31 (local.get $from))))))

  (func $zipmap_internal (param $keys anyref) (param $vals anyref) (result anyref)
    (local $result anyref)
    (local $ks anyref)
    (local $vs anyref)
    (block (result anyref)
      (local.set $result (call $empty_hash_map))
      (local.set $ks (local.get $keys))
      (local.set $vs (local.get $vals))
      (loop $loop12 (result anyref)
        (if (result anyref)
      (call $truthy (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $nil_QMARK_ (local.get $ks))))
        (then (call $nil_QMARK_ (local.get $ks)))
        (else (call $nil_QMARK_ (local.get $vs)))))
      (then (local.get $result))
      (else (call $assoc (local.get $result) (call $first (local.get $ks)) (call $first (local.get $vs)))
        (call $rest (local.get $ks))
        (call $rest (local.get $vs))
        (local.set $vs)
        (local.set $ks)
        (local.set $result)
        (br $loop12))))))

  (func $zipmap (export "zipmap") (param $keys i32) (param $vals i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $zipmap_internal (ref.i31 (local.get $keys)) (ref.i31 (local.get $vals))))))

  (func $doall_internal (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $doall (export "doall") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $doall_internal (ref.i31 (local.get $coll))))))

  (func $meta_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $meta (export "meta") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $meta_internal (ref.i31 (local.get $x))))))

  (func $with_meta_internal (param $x anyref) (param $m anyref) (result anyref)
    (local.get $x))

  (func $with_meta (export "with-meta") (param $x i32) (param $m i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $with_meta_internal (ref.i31 (local.get $x)) (ref.i31 (local.get $m))))))

  (func $vary_meta_internal (param $obj anyref) (param $f anyref) (result anyref)
    (local.get $obj))

  (func $vary_meta (export "vary-meta") (param $obj i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $vary_meta_internal (ref.i31 (local.get $obj)) (ref.i31 (local.get $f))))))

  (func $volatile_BANG__internal (param $x anyref) (result anyref)
    (call $atom (local.get $x)))

  (func $volatile_BANG_ (export "volatile!") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $volatile_BANG__internal (ref.i31 (local.get $x))))))

  (func $vreset_BANG__internal (param $v anyref) (param $newval anyref) (result anyref)
    (call $reset_BANG_ (local.get $v) (local.get $newval)))

  (func $vreset_BANG_ (export "vreset!") (param $v i32) (param $newval i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $vreset_BANG__internal (ref.i31 (local.get $v)) (ref.i31 (local.get $newval))))))

  (func $vswap_BANG__internal (param $v anyref) (param $f anyref) (result anyref)
    (call $swap_BANG_ (local.get $v) (local.get $f)))

  (func $vswap_BANG_ (export "vswap!") (param $v i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $vswap_BANG__internal (ref.i31 (local.get $v)) (ref.i31 (local.get $f))))))

  (func $sorted_QMARK__internal (param $coll anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $sorted_QMARK_ (export "sorted?") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $sorted_QMARK__internal (ref.i31 (local.get $coll))))))

  (func $any_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 1)))

  (func $any_QMARK_ (export "any?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $any_QMARK__internal (ref.i31 (local.get $x))))))

  (func $mod_internal (param $n anyref) (param $d anyref) (result anyref)
    (local $r anyref)
    (block (result anyref)
      (local.set $r (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $d))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (local.get $d))))))))))))))
      (if (result anyref)
      (call $truthy (ref.i31 (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $r))) (i32.const 0))))
      (then (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $r))) (i31.get_s (ref.cast (ref i31) (local.get $d))))))
      (else (local.get $r)))))

  (func $mod (export "mod") (param $n i32) (param $d i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $mod_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $d))))))

  (func $rem_internal (param $n anyref) (param $d anyref) (result anyref)
    (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $d))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (local.get $d))))))))))))))

  (func $rem (export "rem") (param $n i32) (param $d i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $rem_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $d))))))

  (func $abs_internal (param $n anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 0))))
      (then (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0)))) (i31.get_s (ref.cast (ref i31) (local.get $n))))))
      (else (local.get $n))))

  (func $abs (export "abs") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $abs_internal (ref.i31 (local.get $n))))))

  (func $min_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (then (local.get $a))
      (else (local.get $b))))

  (func $min (export "min") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $min_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $max_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (then (local.get $a))
      (else (local.get $b))))

  (func $max (export "max") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $max_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $sort_internal (param $coll anyref) (result anyref)
    (local $result anyref)
    (local $remaining anyref)
    (local $acc anyref)
    (local $left anyref)
    (local $x anyref)
    (block (result anyref)
      (local.set $result (ref.null none))
      (local.set $remaining (call $seq (local.get $coll)))
      (loop $loop13 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $remaining)))
      (then (local.get $result))
      (else (block (result anyref)
      (local.set $acc (ref.null none))
      (local.set $left (local.get $result))
      (local.set $x (call $first (local.get $remaining)))
      (loop $loop14 (result anyref)
        (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $left)))
      (then (call $reverse_internal (call $cons (local.get $x) (local.get $acc))))
      (else (if (result anyref)
      (call $truthy (ref.i31 (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $x))) (i31.get_s (ref.cast (ref i31) (call $first (local.get $left)))))))
      (then (call $concat_internal (call $reverse_internal (call $cons (local.get $x) (local.get $acc))) (local.get $left)))
      (else (call $cons (call $first (local.get $left)) (local.get $acc))
        (call $rest (local.get $left))
        (local.get $x)
        (local.set $x)
        (local.set $left)
        (local.set $acc)
        (br $loop14)))))))
        (call $rest (local.get $remaining))
        (local.set $remaining)
        (local.set $result)
        (br $loop13))))))

  (func $sort (export "sort") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $sort_internal (ref.i31 (local.get $coll))))))

  (func $int_QMARK__internal (param $x anyref) (result anyref)
    (call $integer_QMARK_ (local.get $x)))

  (func $int_QMARK_ (export "int?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $int_QMARK__internal (ref.i31 (local.get $x))))))

  (func $double_QMARK__internal (param $x anyref) (result anyref)
    (call $float_QMARK_ (local.get $x)))

  (func $double_QMARK_ (export "double?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $double_QMARK__internal (ref.i31 (local.get $x))))))

  (func $boolean_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $true_QMARK_ (local.get $x))))
        (then (call $true_QMARK_ (local.get $x)))
        (else (call $false_QMARK_ (local.get $x)))))

  (func $boolean_QMARK_ (export "boolean?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $boolean_QMARK__internal (ref.i31 (local.get $x))))))

  (func $ratio_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $ratio_QMARK_ (export "ratio?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ratio_QMARK__internal (ref.i31 (local.get $x))))))

  (func $rational_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $integer_QMARK_ (local.get $x))))
        (then (call $integer_QMARK_ (local.get $x)))
        (else (call $ratio_QMARK__internal (local.get $x)))))

  (func $rational_QMARK_ (export "rational?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $rational_QMARK__internal (ref.i31 (local.get $x))))))

  (func $big_int_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $big_int_QMARK_ (export "big-int?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $big_int_QMARK__internal (ref.i31 (local.get $x))))))

  (func $char_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $char_QMARK_ (export "char?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $char_QMARK__internal (ref.i31 (local.get $x))))))

  (func $val_internal (param $entry anyref) (result anyref)
    (call $second_internal (local.get $entry)))

  (func $val (export "val") (param $entry i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $val_internal (ref.i31 (local.get $entry))))))

  (func $key_internal (param $entry anyref) (result anyref)
    (call $first (local.get $entry)))

  (func $key (export "key") (param $entry i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $key_internal (ref.i31 (local.get $entry))))))

  (func $derive_internal (param $h anyref) (param $tag anyref) (param $parent anyref) (result anyref)
    (local.get $h))

  (func $derive (export "derive") (param $h i32) (param $tag i32) (param $parent i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $derive_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)) (ref.i31 (local.get $parent))))))

  (func $underive_internal (param $h anyref) (param $tag anyref) (param $parent anyref) (result anyref)
    (local.get $h))

  (func $underive (export "underive") (param $h i32) (param $tag i32) (param $parent i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $underive_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag)) (ref.i31 (local.get $parent))))))

  (func $ancestors_internal (param $h anyref) (param $tag anyref) (result anyref)
    (ref.null none))

  (func $ancestors (export "ancestors") (param $h i32) (param $tag i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ancestors_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag))))))

  (func $descendants_internal (param $h anyref) (param $tag anyref) (result anyref)
    (ref.null none))

  (func $descendants (export "descendants") (param $h i32) (param $tag i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $descendants_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag))))))

  (func $parents_internal (param $h anyref) (param $tag anyref) (result anyref)
    (ref.null none))

  (func $parents (export "parents") (param $h i32) (param $tag i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $parents_internal (ref.i31 (local.get $h)) (ref.i31 (local.get $tag))))))

  (func $isa_QMARK__internal (param $h anyref) (param $child anyref) (param $parent anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $isa_QMARK_ (export "isa?") (param $h i32) (param $child i32) (param $parent i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $isa_QMARK__internal (ref.i31 (local.get $h)) (ref.i31 (local.get $child)) (ref.i31 (local.get $parent))))))

  (func $make_hierarchy_internal  (result anyref)
    (call $empty_hash_map))

  (func $make_hierarchy (export "make-hierarchy")  (result i32)
    (i31.get_s (ref.cast (ref i31) (call $make_hierarchy_internal ))))

  (func $take_last_internal (param $n anyref) (param $coll anyref) (result anyref)
    (local $len anyref)
    (block (result anyref)
      (local.set $len (ref.i31 (call $count_internal (call $seq (local.get $coll)))))
      (call $drop_internal (call $max_internal (ref.i31 (i32.const 0)) (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $len))) (i31.get_s (ref.cast (ref i31) (local.get $n)))))) (local.get $coll))))

  (func $take_last (export "take-last") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $take_last_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $drop_last_internal (param $n anyref) (param $coll anyref) (result anyref)
    (call $take_internal (call $max_internal (ref.i31 (i32.const 0)) (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (ref.i31 (call $count_internal (call $seq (local.get $coll)))))) (i31.get_s (ref.cast (ref i31) (local.get $n)))))) (local.get $coll)))

  (func $drop_last (export "drop-last") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $drop_last_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $drop_last_1_internal (param $coll anyref) (result anyref)
    (call $drop_last_internal (ref.i31 (i32.const 1)) (local.get $coll)))

  (func $drop_last_1 (export "drop-last-1") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $drop_last_1_internal (ref.i31 (local.get $coll))))))

  (func $shuffle_internal (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $shuffle (export "shuffle") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $shuffle_internal (ref.i31 (local.get $coll))))))

  (func $vec_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $vector_QMARK_ (local.get $coll)))
      (then (local.get $coll))
      (else (call $into_internal (call $empty_vector) (local.get $coll)))))

  (func $vec (export "vec") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $vec_internal (ref.i31 (local.get $coll))))))

  (func $mapv_internal (param $f anyref) (param $coll anyref) (result anyref)
    (call $into_internal (call $empty_vector) (call $map_internal (local.get $f) (local.get $coll))))

  (func $mapv (export "mapv") (param $f i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $mapv_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll))))))

  (func $filterv_internal (param $pred anyref) (param $coll anyref) (result anyref)
    (call $into_internal (call $empty_vector) (call $filter_internal (local.get $pred) (local.get $coll))))

  (func $filterv (export "filterv") (param $pred i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $filterv_internal (ref.i31 (local.get $pred)) (ref.i31 (local.get $coll))))))

  (func $subvec_internal (param $v anyref) (param $start anyref) (param $end anyref) (result anyref)
    (local $result anyref)
    (local $i anyref)
    (block (result anyref)
      (local.set $result (call $empty_vector))
      (local.set $i (local.get $start))
      (loop $loop15 (result anyref)
        (if (result anyref)
      (call $truthy (ref.i31 (i32.ge_s (i31.get_s (ref.cast (ref i31) (local.get $i))) (i31.get_s (ref.cast (ref i31) (local.get $end))))))
      (then (local.get $result))
      (else (call $vector_conj (local.get $result) (call $nth_polymorphic (local.get $v) (i31.get_s (ref.cast (ref i31) (local.get $i)))))
        (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $i))) (i32.const 1)))
        (local.set $i)
        (local.set $result)
        (br $loop15))))))

  (func $subvec (export "subvec") (param $v i32) (param $start i32) (param $end i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $subvec_internal (ref.i31 (local.get $v)) (ref.i31 (local.get $start)) (ref.i31 (local.get $end))))))

  (func $cycle_internal (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $cycle (export "cycle") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $cycle_internal (ref.i31 (local.get $coll))))))

  (func $add_watch_internal (param $ref anyref) (param $key anyref) (param $f anyref) (result anyref)
    (local.get $ref))

  (func $add_watch (export "add-watch") (param $ref i32) (param $key i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $add_watch_internal (ref.i31 (local.get $ref)) (ref.i31 (local.get $key)) (ref.i31 (local.get $f))))))

  (func $remove_watch_internal (param $ref anyref) (param $key anyref) (result anyref)
    (local.get $ref))

  (func $remove_watch (export "remove-watch") (param $ref i32) (param $key i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $remove_watch_internal (ref.i31 (local.get $ref)) (ref.i31 (local.get $key))))))

  (func $get_validator_internal (param $ref anyref) (result anyref)
    (ref.null none))

  (func $get_validator (export "get-validator") (param $ref i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $get_validator_internal (ref.i31 (local.get $ref))))))

  (func $set_validator_BANG__internal (param $ref anyref) (param $f anyref) (result anyref)
    (ref.null none))

  (func $set_validator_BANG_ (export "set-validator!") (param $ref i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $set_validator_BANG__internal (ref.i31 (local.get $ref)) (ref.i31 (local.get $f))))))

  (func $assoc_BANG__internal (param $coll anyref) (param $k anyref) (param $v anyref) (result anyref)
    (call $assoc (local.get $coll) (local.get $k) (local.get $v)))

  (func $assoc_BANG_ (export "assoc!") (param $coll i32) (param $k i32) (param $v i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $assoc_BANG__internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $k)) (ref.i31 (local.get $v))))))

  (func $conj_BANG__internal (param $coll anyref) (param $v anyref) (result anyref)
    (call $vector_conj (local.get $coll) (local.get $v)))

  (func $conj_BANG_ (export "conj!") (param $coll i32) (param $v i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $conj_BANG__internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $v))))))

  (func $disj_BANG__internal (param $coll anyref) (param $v anyref) (result anyref)
    (call $disj (local.get $coll) (local.get $v)))

  (func $disj_BANG_ (export "disj!") (param $coll i32) (param $v i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $disj_BANG__internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $v))))))

  (func $dissoc_BANG__internal (param $coll anyref) (param $k anyref) (result anyref)
    (call $dissoc (local.get $coll) (local.get $k)))

  (func $dissoc_BANG_ (export "dissoc!") (param $coll i32) (param $k i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $dissoc_BANG__internal (ref.i31 (local.get $coll)) (ref.i31 (local.get $k))))))

  (func $transient_internal (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $transient (export "transient") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $transient_internal (ref.i31 (local.get $coll))))))

  (func $persistent_BANG__internal (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $persistent_BANG_ (export "persistent!") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $persistent_BANG__internal (ref.i31 (local.get $coll))))))

  (func $boolean_internal (param $x anyref) (result anyref)
    (if (result anyref)
      (call $truthy (local.get $x))
      (then (ref.i31 (i32.const 1)))
      (else (ref.i31 (i32.const 0)))))

  (func $boolean (export "boolean") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $boolean_internal (ref.i31 (local.get $x))))))

  (func $not_empty_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $empty_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (local.get $coll))))

  (func $not_empty (export "not-empty") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $not_empty_internal (ref.i31 (local.get $coll))))))

  (func $empty_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $vector_QMARK_ (local.get $coll)))
      (then (call $empty_vector))
      (else (if (result anyref)
      (call $truthy (call $map_QMARK_ (local.get $coll)))
      (then (call $empty_hash_map))
      (else (if (result anyref)
      (call $truthy (call $set_QMARK_ (local.get $coll)))
      (then (call $empty_hash_set))
      (else (ref.null none))))))))

  (func $empty (export "empty") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $empty_internal (ref.i31 (local.get $coll))))))

  (func $symbol_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $symbol (export "symbol") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $symbol_internal (ref.i31 (local.get $x))))))

  (func $namespace_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $namespace (export "namespace") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $namespace_internal (ref.i31 (local.get $x))))))

  (func $simple_ident_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $simple_ident_QMARK_ (export "simple-ident?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $simple_ident_QMARK__internal (ref.i31 (local.get $x))))))

  (func $simple_keyword_QMARK__internal (param $x anyref) (result anyref)
    (call $keyword_QMARK_ (local.get $x)))

  (func $simple_keyword_QMARK_ (export "simple-keyword?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $simple_keyword_QMARK__internal (ref.i31 (local.get $x))))))

  (func $simple_symbol_QMARK__internal (param $x anyref) (result anyref)
    (call $symbol_QMARK_ (local.get $x)))

  (func $simple_symbol_QMARK_ (export "simple-symbol?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $simple_symbol_QMARK__internal (ref.i31 (local.get $x))))))

  (func $qualified_ident_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $qualified_ident_QMARK_ (export "qualified-ident?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $qualified_ident_QMARK__internal (ref.i31 (local.get $x))))))

  (func $qualified_keyword_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $qualified_keyword_QMARK_ (export "qualified-keyword?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $qualified_keyword_QMARK__internal (ref.i31 (local.get $x))))))

  (func $qualified_symbol_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $qualified_symbol_QMARK_ (export "qualified-symbol?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $qualified_symbol_QMARK__internal (ref.i31 (local.get $x))))))

  (func $ident_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $keyword_QMARK_ (local.get $x))))
        (then (call $keyword_QMARK_ (local.get $x)))
        (else (call $symbol_QMARK_ (local.get $x)))))

  (func $ident_QMARK_ (export "ident?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ident_QMARK__internal (ref.i31 (local.get $x))))))

  (func $special_symbol_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $special_symbol_QMARK_ (export "special-symbol?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $special_symbol_QMARK__internal (ref.i31 (local.get $x))))))

  (func $ex_info_internal (param $msg anyref) (param $data anyref) (result anyref)
    (ref.null none))

  (func $ex_info (export "ex-info") (param $msg i32) (param $data i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ex_info_internal (ref.i31 (local.get $msg)) (ref.i31 (local.get $data))))))

  (func $ex_message_internal (param $e anyref) (result anyref)
    (ref.null none))

  (func $ex_message (export "ex-message") (param $e i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ex_message_internal (ref.i31 (local.get $e))))))

  (func $ex_data_internal (param $e anyref) (result anyref)
    (ref.null none))

  (func $ex_data (export "ex-data") (param $e i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ex_data_internal (ref.i31 (local.get $e))))))

  (func $to_array_internal (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $to_array (export "to-array") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $to_array_internal (ref.i31 (local.get $coll))))))

  (func $reversible_QMARK__internal (param $coll anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $reversible_QMARK_ (export "reversible?") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $reversible_QMARK__internal (ref.i31 (local.get $coll))))))

  (func $rseq_internal (param $coll anyref) (result anyref)
    (call $reverse_internal (call $seq (local.get $coll))))

  (func $rseq (export "rseq") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $rseq_internal (ref.i31 (local.get $coll))))))

  (func $take_nth_internal (param $n anyref) (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll)))
      (then (ref.null none))
      (else (call $cons (call $first (local.get $coll)) (call $take_nth_internal (local.get $n) (call $drop_internal (local.get $n) (local.get $coll)))))))

  (func $take_nth (export "take-nth") (param $n i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $take_nth_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $coll))))))

  (func $compare_internal (param $a anyref) (param $b anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (then (ref.i31 (i32.const -1)))
      (else (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
      (then (ref.i31 (i32.const 1)))
      (else (ref.i31 (i32.const 0)))))))

  (func $compare (export "compare") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $compare_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $sort_by_internal (param $keyfn anyref) (param $coll anyref) (result anyref)
    (call $sort_internal (local.get $coll)))

  (func $sort_by (export "sort-by") (param $keyfn i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $sort_by_internal (ref.i31 (local.get $keyfn)) (ref.i31 (local.get $coll))))))

  (func $closure19 (type $ClosureFunc2) (param $__env anyref) (param $m anyref) (param $x anyref) (result anyref)
    (local $k anyref)
    (block (result anyref)
      (local.set $k (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))
      (call $assoc (local.get $m) (local.get $k) (call $vector_conj (call $hash_map_get (local.get $m) (local.get $k)) (local.get $x)))))

  (func $group_by_internal (param $f anyref) (param $coll anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $reduce (struct.new $Closure2 (ref.func $closure19) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 1)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (local.get $__tmp_env))) (call $empty_hash_map) (local.get $coll)))

  (func $group_by (export "group-by") (param $f i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $group_by_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $coll))))))

  (func $fn20 (type $ClosureFunc2) (param $__env anyref) (param $m anyref) (param $x anyref) (result anyref)
    (call $assoc (local.get $m) (local.get $x) (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (call $hash_map_get (local.get $m) (local.get $x)))) (i32.const 1)))))

  (func $frequencies_internal (param $coll anyref) (result anyref)
    (call $reduce (struct.new $Closure2 (ref.func $fn20) (call $array_new (i32.const 0))) (call $empty_hash_map) (local.get $coll)))

  (func $frequencies (export "frequencies") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $frequencies_internal (ref.i31 (local.get $coll))))))

  (func $realized_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 1)))

  (func $realized_QMARK_ (export "realized?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $realized_QMARK__internal (ref.i31 (local.get $x))))))

  (func $numerator_internal (param $r anyref) (result anyref)
    (local.get $r))

  (func $numerator (export "numerator") (param $r i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $numerator_internal (ref.i31 (local.get $r))))))

  (func $denominator_internal (param $r anyref) (result anyref)
    (ref.i31 (i32.const 1)))

  (func $denominator (export "denominator") (param $r i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $denominator_internal (ref.i31 (local.get $r))))))

  (func $rationalize_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $rationalize (export "rationalize") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $rationalize_internal (ref.i31 (local.get $x))))))

  (func $byte_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $byte (export "byte") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $byte_internal (ref.i31 (local.get $x))))))

  (func $short_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $short (export "short") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $short_internal (ref.i31 (local.get $x))))))

  (func $int_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $int (export "int") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $int_internal (ref.i31 (local.get $x))))))

  (func $long_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $long (export "long") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $long_internal (ref.i31 (local.get $x))))))

  (func $float_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $float (export "float") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $float_internal (ref.i31 (local.get $x))))))

  (func $double_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $double (export "double") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $double_internal (ref.i31 (local.get $x))))))

  (func $char_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $char (export "char") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $char_internal (ref.i31 (local.get $x))))))

  (func $bigint_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $bigint (export "bigint") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bigint_internal (ref.i31 (local.get $x))))))

  (func $bigdec_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $bigdec (export "bigdec") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bigdec_internal (ref.i31 (local.get $x))))))

  (func $decimal_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $decimal_QMARK_ (export "decimal?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $decimal_QMARK__internal (ref.i31 (local.get $x))))))

  (func $uuid_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $uuid_QMARK_ (export "uuid?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $uuid_QMARK__internal (ref.i31 (local.get $x))))))

  (func $var_QMARK__internal (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $var_QMARK_ (export "var?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $var_QMARK__internal (ref.i31 (local.get $x))))))

  (func $closure21 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))))
        (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x)))
        (else (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x)))))

  (func $some_fn_internal (param $f anyref) (param $g anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure21) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g))
        (local.get $__tmp_env))))

  (func $some_fn (export "some-fn") (param $f i32) (param $g i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $some_fn_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g))))))

  (func $closure22 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $invoke1 (call $array_get (local.get $__env) (i32.const 0)) (local.get $x))))
        (then (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (local.get $x)))
        (else (ref.i31 (i32.const 0)))))

  (func $every_pred_internal (param $f anyref) (param $g anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure22) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $f))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $g))
        (local.get $__tmp_env))))

  (func $every_pred (export "every-pred") (param $f i32) (param $g i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $every_pred_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $g))))))

  (func $promise_internal  (result anyref)
    (call $atom (ref.null none)))

  (func $promise (export "promise")  (result i32)
    (i31.get_s (ref.cast (ref i31) (call $promise_internal ))))

  (func $deliver_internal (param $p anyref) (param $val anyref) (result anyref)
    (call $reset_BANG_ (local.get $p) (local.get $val)))

  (func $deliver (export "deliver") (param $p i32) (param $val i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $deliver_internal (ref.i31 (local.get $p)) (ref.i31 (local.get $val))))))

  (func $ensure_reduced_internal (param $x anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (call $reduced_QMARK_ (local.get $x))))
      (then (local.get $x))
      (else (call $reduced (local.get $x)))))

  (func $ensure_reduced (export "ensure-reduced") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ensure_reduced_internal (ref.i31 (local.get $x))))))

  (func $unreduced_internal (param $x anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (call $reduced_QMARK_ (local.get $x))))
      (then (local.get $x))
      (else (local.get $x))))

  (func $unreduced (export "unreduced") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $unreduced_internal (ref.i31 (local.get $x))))))

  (func $bit_and_internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))) (i31.get_s (ref.cast (ref i31) (call $max_internal (call $max_internal (local.get $a) (local.get $b)) (ref.i31 (i32.const 1))))))))

  (func $bit_and (export "bit-and") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_and_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_or_internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))

  (func $bit_or (export "bit-or") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_or_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_xor_internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))

  (func $bit_xor (export "bit-xor") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_xor_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_not_internal (param $a anyref) (result anyref)
    (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const -1)))) (i31.get_s (ref.cast (ref i31) (local.get $a))))))

  (func $bit_not (export "bit-not") (param $a i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_not_internal (ref.i31 (local.get $a))))))

  (func $bit_shift_left_internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (call $reduce (global.get $__builtin__STAR_) (ref.i31 (i32.const 1)) (call $repeat_arity2_internal (local.get $b) (ref.i31 (i32.const 2)))))))))

  (func $bit_shift_left (export "bit-shift-left") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_shift_left_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_shift_right_internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (call $reduce (global.get $__builtin__STAR_) (ref.i31 (i32.const 1)) (call $repeat_arity2_internal (local.get $b) (ref.i31 (i32.const 2)))))))))

  (func $bit_shift_right (export "bit-shift-right") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_shift_right_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $unsigned_bit_shift_right_internal (param $a anyref) (param $b anyref) (result anyref)
    (call $bit_shift_right_internal (local.get $a) (local.get $b)))

  (func $unsigned_bit_shift_right (export "unsigned-bit-shift-right") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $unsigned_bit_shift_right_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_and_not_internal (param $a anyref) (param $b anyref) (result anyref)
    (local.get $a))

  (func $bit_and_not (export "bit-and-not") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_and_not_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_clear_internal (param $a anyref) (param $b anyref) (result anyref)
    (local.get $a))

  (func $bit_clear (export "bit-clear") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_clear_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_flip_internal (param $a anyref) (param $b anyref) (result anyref)
    (local.get $a))

  (func $bit_flip (export "bit-flip") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_flip_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_set_internal (param $a anyref) (param $b anyref) (result anyref)
    (local.get $a))

  (func $bit_set (export "bit-set") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_set_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $bit_test_internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $bit_test (export "bit-test") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bit_test_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $run_tests_internal  (result anyref)
    (ref.i31 (i32.const 0)))

  (func $run_tests (export "run-tests")  (result i32)
    (i31.get_s (ref.cast (ref i31) (call $run_tests_internal ))))

  (func $print_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $print (export "print") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $print_internal (ref.i31 (local.get $x))))))

  (func $println_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $println (export "println") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $println_internal (ref.i31 (local.get $x))))))

  (func $pr_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $pr (export "pr") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $pr_internal (ref.i31 (local.get $x))))))

  (func $prn_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $prn (export "prn") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $prn_internal (ref.i31 (local.get $x))))))

  (func $print_str_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $print_str (export "print-str") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $print_str_internal (ref.i31 (local.get $x))))))

  (func $println_str_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $println_str (export "println-str") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $println_str_internal (ref.i31 (local.get $x))))))

  (func $pr_str_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $pr_str (export "pr-str") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $pr_str_internal (ref.i31 (local.get $x))))))

  (func $prn_str_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $prn_str (export "prn-str") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $prn_str_internal (ref.i31 (local.get $x))))))

  (func $aclone_internal (param $arr anyref) (result anyref)
    (local.get $arr))

  (func $aclone (export "aclone") (param $arr i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $aclone_internal (ref.i31 (local.get $arr))))))

  (func $tap>_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $add_tap_internal (param $f anyref) (result anyref)
    (ref.null none))

  (func $add_tap (export "add-tap") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $add_tap_internal (ref.i31 (local.get $f))))))

  (func $remove_tap_internal (param $f anyref) (result anyref)
    (ref.null none))

  (func $remove_tap (export "remove-tap") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $remove_tap_internal (ref.i31 (local.get $f))))))

  (func $ifn_QMARK__internal (param $x anyref) (result anyref)
    (call $fn_QMARK_ (local.get $x)))

  (func $ifn_QMARK_ (export "ifn?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ifn_QMARK__internal (ref.i31 (local.get $x))))))

  (func $instance_QMARK__internal (param $c anyref) (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $instance_QMARK_ (export "instance?") (param $c i32) (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $instance_QMARK__internal (ref.i31 (local.get $c)) (ref.i31 (local.get $x))))))

  (func $throw_internal (param $e anyref) (result anyref)
    (ref.null none))

  (func $throw (export "throw") (param $e i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $throw_internal (ref.i31 (local.get $e))))))

  (func $peek_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $vector_QMARK_ (local.get $coll)))
      (then (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (ref.i31 (call $count_internal (local.get $coll))))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0)))))))
      (then (call $nth_polymorphic (local.get $coll) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (ref.i31 (call $count_internal (local.get $coll))))) (i32.const 1)))))))
      (else (ref.null none))))
      (else (if (result anyref)
      (call $truthy (call $cons_QMARK_ (local.get $coll)))
      (then (call $first (local.get $coll)))
      (else (ref.null none))))))

  (func $peek (export "peek") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $peek_internal (ref.i31 (local.get $coll))))))

  (func $pop_internal (param $coll anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $vector_QMARK_ (local.get $coll)))
      (then (if (result anyref)
      (call $truthy (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (ref.i31 (call $count_internal (local.get $coll))))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0)))))))
      (then (call $subvec_internal (local.get $coll) (ref.i31 (i32.const 0)) (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (ref.i31 (call $count_internal (local.get $coll))))) (i32.const 1)))))
      (else (call $empty_vector))))
      (else (if (result anyref)
      (call $truthy (call $cons_QMARK_ (local.get $coll)))
      (then (call $rest (local.get $coll)))
      (else (ref.null none))))))

  (func $pop (export "pop") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $pop_internal (ref.i31 (local.get $coll))))))

  (func $pop_BANG__internal (param $coll anyref) (result anyref)
    (call $pop_internal (local.get $coll)))

  (func $pop_BANG_ (export "pop!") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $pop_BANG__internal (ref.i31 (local.get $coll))))))

  (func $quot_internal (param $n anyref) (param $d anyref) (result anyref)
    (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (local.get $d))))))

  (func $quot (export "quot") (param $n i32) (param $d i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $quot_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $d))))))

  (func $repeatedly_internal (param $n anyref) (param $f anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (i32.le_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0)))))))
      (then (ref.null none))
      (else (call $cons (call $invoke0 (local.get $f) ) (call $repeatedly_arity2_internal (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1))) (local.get $f))))))

  (func $repeatedly (export "repeatedly") (param $n i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $repeatedly_internal (ref.i31 (local.get $n)) (ref.i31 (local.get $f))))))

  (func $parse_boolean_internal (param $s anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $parse_boolean (export "parse-boolean") (param $s i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $parse_boolean_internal (ref.i31 (local.get $s))))))

  (func $parse_double_internal (param $s anyref) (result anyref)
    (struct.new $Float (f64.const 0.0)))

  (func $parse_double (export "parse-double") (param $s i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $parse_double_internal (ref.i31 (local.get $s))))))

  (func $parse_long_internal (param $s anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $parse_long (export "parse-long") (param $s i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $parse_long_internal (ref.i31 (local.get $s))))))

  (func $parse_uuid_internal (param $s anyref) (result anyref)
    (ref.null none))

  (func $parse_uuid (export "parse-uuid") (param $s i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $parse_uuid_internal (ref.i31 (local.get $s))))))

  (func $rand_int_internal (param $n anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $rand_int (export "rand-int") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $rand_int_internal (ref.i31 (local.get $n))))))

  (func $pos_int_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $integer_QMARK_ (local.get $x))))
        (then (ref.i31 (i32.gt_s (i31.get_s (ref.cast (ref i31) (local.get $x))) (i32.const 0))))
        (else (ref.i31 (i32.const 0)))))

  (func $pos_int_QMARK_ (export "pos-int?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $pos_int_QMARK__internal (ref.i31 (local.get $x))))))

  (func $neg_int_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $integer_QMARK_ (local.get $x))))
        (then (ref.i31 (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $x))) (i32.const 0))))
        (else (ref.i31 (i32.const 0)))))

  (func $neg_int_QMARK_ (export "neg-int?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $neg_int_QMARK__internal (ref.i31 (local.get $x))))))

  (func $nat_int_QMARK__internal (param $x anyref) (result anyref)
    (if (result anyref) (i31.get_s (ref.cast (ref i31) (call $integer_QMARK_ (local.get $x))))
        (then (ref.i31 (i32.ge_s (i31.get_s (ref.cast (ref i31) (local.get $x))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0)))))))
        (else (ref.i31 (i32.const 0)))))

  (func $nat_int_QMARK_ (export "nat-int?") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $nat_int_QMARK__internal (ref.i31 (local.get $x))))))

  (func $transduce_internal (param $xform anyref) (param $f anyref) (param $init anyref) (param $coll anyref) (result anyref)
    (call $reduce (local.get $f) (local.get $init) (local.get $coll)))

  (func $transduce (export "transduce") (param $xform i32) (param $f i32) (param $init i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $transduce_internal (ref.i31 (local.get $xform)) (ref.i31 (local.get $f)) (ref.i31 (local.get $init)) (ref.i31 (local.get $coll))))))

  (func $int_array_internal (param $n anyref) (result anyref)
    (call $empty_vector))

  (func $int_array (export "int-array") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $int_array_internal (ref.i31 (local.get $n))))))

  (func $object_array_internal (param $n anyref) (result anyref)
    (call $empty_vector))

  (func $object_array (export "object-array") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $object_array_internal (ref.i31 (local.get $n))))))

  (func $aset_internal (param $arr anyref) (param $idx anyref) (param $val anyref) (result anyref)
    (ref.null none))

  (func $aset (export "aset") (param $arr i32) (param $idx i32) (param $val i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $aset_internal (ref.i31 (local.get $arr)) (ref.i31 (local.get $idx)) (ref.i31 (local.get $val))))))

  (func $aget_internal (param $arr anyref) (param $idx anyref) (result anyref)
    (ref.null none))

  (func $aget (export "aget") (param $arr i32) (param $idx i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $aget_internal (ref.i31 (local.get $arr)) (ref.i31 (local.get $idx))))))

  (func $nnext_internal (param $coll anyref) (result anyref)
    (call $next_internal (call $next_internal (local.get $coll))))

  (func $nnext (export "nnext") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $nnext_internal (ref.i31 (local.get $coll))))))

  (func $nfirst_internal (param $coll anyref) (result anyref)
    (call $first (call $first (local.get $coll))))

  (func $nfirst (export "nfirst") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $nfirst_internal (ref.i31 (local.get $coll))))))

  (func $keyword_fn_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $keyword_fn (export "keyword-fn") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $keyword_fn_internal (ref.i31 (local.get $x))))))

  (func $intern_internal (param $ns anyref) (param $name anyref) (result anyref)
    (ref.null none))

  (func $intern (export "intern") (param $ns i32) (param $name i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $intern_internal (ref.i31 (local.get $ns)) (ref.i31 (local.get $name))))))

  (func $inc_PRIME__internal (param $n anyref) (result anyref)
    (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1))))

  (func $inc_PRIME_ (export "inc'") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $inc_PRIME__internal (ref.i31 (local.get $n))))))

  (func $dec_PRIME__internal (param $n anyref) (result anyref)
    (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1))))

  (func $dec_PRIME_ (export "dec'") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $dec_PRIME__internal (ref.i31 (local.get $n))))))

  (func $identical_QMARK__internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (call $eq (local.get $a) (local.get $b))))

  (func $identical_QMARK_ (export "identical?") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $identical_QMARK__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $format_internal (param $fmt anyref) (param $args anyref) (result anyref)
    (ref.null none))

  (func $format (export "format") (param $fmt i32) (param $args i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $format_internal (ref.i31 (local.get $fmt)) (ref.i31 (local.get $args))))))

  (func $closure23 (type $ClosureFunc1) (param $__env anyref) (param $x anyref) (result anyref)
    (call $invoke1 (call $array_get (local.get $__env) (i32.const 1)) (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $x)))
      (then (call $array_get (local.get $__env) (i32.const 0)))
      (else (local.get $x)))))

  (func $fnil_internal (param $f anyref) (param $default anyref) (result anyref)
    (local $__tmp_env anyref)
    (struct.new $Closure1 (ref.func $closure23) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $default))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $f))
        (local.get $__tmp_env))))

  (func $fnil (export "fnil") (param $f i32) (param $default i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $fnil_internal (ref.i31 (local.get $f)) (ref.i31 (local.get $default))))))

  (func $random_sample_internal (param $prob anyref) (param $coll anyref) (result anyref)
    (local.get $coll))

  (func $random_sample (export "random-sample") (param $prob i32) (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $random_sample_internal (ref.i31 (local.get $prob)) (ref.i31 (local.get $coll))))))

  (func $rand_nth_internal (param $coll anyref) (result anyref)
    (call $first (local.get $coll)))

  (func $rand_nth (export "rand-nth") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $rand_nth_internal (ref.i31 (local.get $coll))))))

  (func $alter_var_root_internal (param $v anyref) (param $f anyref) (result anyref)
    (ref.null none))

  (func $alter_var_root (export "alter-var-root") (param $v i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $alter_var_root_internal (ref.i31 (local.get $v)) (ref.i31 (local.get $f))))))

  (func $var_get_internal (param $v anyref) (result anyref)
    (ref.null none))

  (func $var_get (export "var-get") (param $v i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $var_get_internal (ref.i31 (local.get $v))))))

  (func $long_array_internal (param $n anyref) (result anyref)
    (call $empty_vector))

  (func $long_array (export "long-array") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $long_array_internal (ref.i31 (local.get $n))))))

  (func $fnext_internal (param $coll anyref) (result anyref)
    (call $first (call $next_internal (local.get $coll))))

  (func $fnext (export "fnext") (param $coll i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $fnext_internal (ref.i31 (local.get $coll))))))

  (func $force_internal (param $x anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $fn_QMARK_ (local.get $x)))
      (then (call $invoke0 (local.get $x) ))
      (else (local.get $x))))

  (func $force (export "force") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $force_internal (ref.i31 (local.get $x))))))

  (func $alength_internal (param $arr anyref) (result anyref)
    (ref.i31 (call $count_internal (local.get $arr))))

  (func $alength (export "alength") (param $arr i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $alength_internal (ref.i31 (local.get $arr))))))

  (func $ref_internal (param $x anyref) (result anyref)
    (call $atom (local.get $x)))

  (func $ref (export "ref") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ref_internal (ref.i31 (local.get $x))))))

  (func $dosync_internal (param $body anyref) (result anyref)
    (ref.null none))

  (func $dosync (export "dosync") (param $body i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $dosync_internal (ref.i31 (local.get $body))))))

  (func $ref_set_internal (param $r anyref) (param $v anyref) (result anyref)
    (call $reset_BANG_ (local.get $r) (local.get $v)))

  (func $ref_set (export "ref-set") (param $r i32) (param $v i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $ref_set_internal (ref.i31 (local.get $r)) (ref.i31 (local.get $v))))))

  (func $alter_internal (param $r anyref) (param $f anyref) (result anyref)
    (call $swap_BANG_ (local.get $r) (local.get $f)))

  (func $alter (export "alter") (param $r i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $alter_internal (ref.i31 (local.get $r)) (ref.i31 (local.get $f))))))

  (func $commute_internal (param $r anyref) (param $f anyref) (result anyref)
    (call $swap_BANG_ (local.get $r) (local.get $f)))

  (func $commute (export "commute") (param $r i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $commute_internal (ref.i31 (local.get $r)) (ref.i31 (local.get $f))))))

  (func $sleep_internal (param $ms anyref) (result anyref)
    (ref.null none))

  (func $sleep (export "sleep") (param $ms i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $sleep_internal (ref.i31 (local.get $ms))))))

  (func $double_array_internal (param $n anyref) (result anyref)
    (call $empty_vector))

  (func $double_array (export "double-array") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $double_array_internal (ref.i31 (local.get $n))))))

  (func $create_ns_internal (param $sym anyref) (result anyref)
    (ref.null none))

  (func $create_ns (export "create-ns") (param $sym i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $create_ns_internal (ref.i31 (local.get $sym))))))

  (func $+_PRIME__internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))

  (func $_STAR__PRIME__internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))

  (func $_STAR__PRIME_ (export "*'") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $_STAR__PRIME__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $__PRIME__internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))

  (func $__PRIME_ (export "-'") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $__PRIME__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $agent_internal (param $state anyref) (result anyref)
    (call $atom (local.get $state)))

  (func $agent (export "agent") (param $state i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $agent_internal (ref.i31 (local.get $state))))))

  (func $send_internal (param $a anyref) (param $f anyref) (result anyref)
    (call $swap_BANG_ (local.get $a) (local.get $f)))

  (func $send (export "send") (param $a i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $send_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $f))))))

  (func $send_off_internal (param $a anyref) (param $f anyref) (result anyref)
    (call $swap_BANG_ (local.get $a) (local.get $f)))

  (func $send_off (export "send-off") (param $a i32) (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $send_off_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $f))))))

  (func $await_internal (param $a anyref) (result anyref)
    (ref.null none))

  (func $await (export "await") (param $a i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $await_internal (ref.i31 (local.get $a))))))

  (func $future_cancel_internal (param $f anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $future_cancel (export "future-cancel") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $future_cancel_internal (ref.i31 (local.get $f))))))

  (func $future_done_QMARK__internal (param $f anyref) (result anyref)
    (ref.i31 (i32.const 1)))

  (func $future_done_QMARK_ (export "future-done?") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $future_done_QMARK__internal (ref.i31 (local.get $f))))))

  (func $future_cancelled_QMARK__internal (param $f anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $future_cancelled_QMARK_ (export "future-cancelled?") (param $f i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $future_cancelled_QMARK__internal (ref.i31 (local.get $f))))))

  (func $float_array_internal (param $n anyref) (result anyref)
    (call $empty_vector))

  (func $float_array (export "float-array") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $float_array_internal (ref.i31 (local.get $n))))))

  (func $agent_error_internal (param $a anyref) (result anyref)
    (ref.null none))

  (func $agent_error (export "agent-error") (param $a i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $agent_error_internal (ref.i31 (local.get $a))))))

  (func $rand_internal  (result anyref)
    (struct.new $Float (f64.const 0.5)))

  (func $rand (export "rand")  (result i32)
    (i31.get_s (ref.cast (ref i31) (call $rand_internal ))))

  (func $random_uuid_internal  (result anyref)
    (ref.null none))

  (func $random_uuid (export "random-uuid")  (result i32)
    (i31.get_s (ref.cast (ref i31) (call $random_uuid_internal ))))

  (func $restart_agent_internal (param $a anyref) (param $options anyref) (result anyref)
    (local.get $a))

  (func $restart_agent (export "restart-agent") (param $a i32) (param $options i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $restart_agent_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $options))))))

  (func $list_internal (param $x anyref) (result anyref)
    (call $cons (local.get $x) (ref.null none)))

  (func $list (export "list") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $list_internal (ref.i31 (local.get $x))))))

  (func $keyword_internal (param $x anyref) (result anyref)
    (local.get $x))

  (func $keyword (export "keyword") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $keyword_internal (ref.i31 (local.get $x))))))

  (func $split_internal (param $s anyref) (param $re anyref) (result anyref)
    (ref.null none))

  (func $split (export "split") (param $s i32) (param $re i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $split_internal (ref.i31 (local.get $s)) (ref.i31 (local.get $re))))))

  (func $into_array_internal (param $type_or_coll anyref) (param $coll_or_nil anyref) (result anyref)
    (if (result anyref)
      (call $truthy (call $nil_QMARK_ (local.get $coll_or_nil)))
      (then (local.get $type_or_coll))
      (else (local.get $coll_or_nil))))

  (func $into_array (export "into-array") (param $type_or_coll i32) (param $coll_or_nil i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $into_array_internal (ref.i31 (local.get $type_or_coll)) (ref.i31 (local.get $coll_or_nil))))))

  (func $make_array_internal (param $type anyref) (param $size anyref) (result anyref)
    (call $empty_vector))

  (func $make_array (export "make-array") (param $type i32) (param $size i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $make_array_internal (ref.i31 (local.get $type)) (ref.i31 (local.get $size))))))

  (func $class_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $class (export "class") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $class_internal (ref.i31 (local.get $x))))))

  (func $bases_internal (param $x anyref) (result anyref)
    (ref.null none))

  (func $bases (export "bases") (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $bases_internal (ref.i31 (local.get $x))))))

  (func $satisfies_QMARK__internal (param $protocol anyref) (param $x anyref) (result anyref)
    (ref.i31 (i32.const 0)))

  (func $satisfies_QMARK_ (export "satisfies?") (param $protocol i32) (param $x i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $satisfies_QMARK__internal (ref.i31 (local.get $protocol)) (ref.i31 (local.get $x))))))

  (func $_EQ__EQ__internal (param $a anyref) (param $b anyref) (result anyref)
    (ref.i31 (call $eq (local.get $a) (local.get $b))))

  (func $_EQ__EQ_ (export "==") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $_EQ__EQ__internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $__proto_area_7 (type $ClosureFunc1) (param $__env anyref) (param $s anyref) (result anyref)
    (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (call $nth_polymorphic (local.get $s) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0))))))) (i31.get_s (ref.cast (ref i31) (call $nth_polymorphic (local.get $s) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 1))))))))))

  (func $__proto_perimeter_7 (type $ClosureFunc1) (param $__env anyref) (param $s anyref) (result anyref)
    (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 2)))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (call $nth_polymorphic (local.get $s) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 0))))))) (i31.get_s (ref.cast (ref i31) (call $nth_polymorphic (local.get $s) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 1))))))))))))))

  (func $closure24 (type $ClosureFunc0) (param $__env anyref)  (result anyref)
    (call $cons (call $array_get (local.get $__env) (i32.const 0)) (call $fibs_from_internal (call $array_get (local.get $__env) (i32.const 1)) (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 0)))) (i31.get_s (ref.cast (ref i31) (call $array_get (local.get $__env) (i32.const 1)))))))))

  (func $fibs_from_internal (param $a anyref) (param $b anyref) (result anyref)
    (local $__tmp_env anyref)
    (call $make_lazy_seq (struct.new $Closure0 (ref.func $closure24) (block (result anyref)
        (local.set $__tmp_env (call $array_new (i32.const 2)))
        (call $array_set (local.get $__tmp_env) (i32.const 0) (local.get $a))
        (call $array_set (local.get $__tmp_env) (i32.const 1) (local.get $b))
        (local.get $__tmp_env)))))

  (func $fibs_from (export "fibs-from") (param $a i32) (param $b i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $fibs_from_internal (ref.i31 (local.get $a)) (ref.i31 (local.get $b))))))

  (func $fibs_internal  (result anyref)
    (call $fibs_from_internal (ref.i31 (i32.const 0)) (ref.i31 (i32.const 1))))

  (func $fibs (export "fibs")  (result i32)
    (i31.get_s (ref.cast (ref i31) (call $fibs_internal ))))

  (func $collatz_next_internal (param $n anyref) (result anyref)
    (if (result anyref)
      (call $truthy (ref.i31 (call $eq (local.get $n) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 2)))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 2)))))))))))))
      (then (ref.i31 (i32.div_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 2)))))))
      (else (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 1)))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 3)))) (i31.get_s (ref.cast (ref i31) (local.get $n))))))))))))

  (func $collatz_next (export "collatz-next") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $collatz_next_internal (ref.i31 (local.get $n))))))

  (func $greet_internal (param $s anyref) (result anyref)
    (call $str_concat (call $str_concat (call $str1 (global.get $__str_0)) (call $str1 (local.get $s))) (call $str1 (global.get $__str_1))))

  (func $greet (export "greet") (param $s i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $greet_internal (ref.i31 (local.get $s))))))

  (func $fib_at_internal (param $i anyref) (result anyref)
    (call $first (call $drop_internal (local.get $i) (call $fibs_internal ))))

  (func $fib_at (export "fib-at") (param $i i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $fib_at_internal (ref.i31 (local.get $i))))))

  (func $fn25 (type $ClosureFunc2) (param $__env anyref) (param $a anyref) (param $x anyref) (result anyref)
    (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $x))))))

  (func $fib_sum_internal (param $n anyref) (result anyref)
    (call $reduce (struct.new $Closure2 (ref.func $fn25) (call $array_new (i32.const 0))) (ref.i31 (i32.const 0)) (call $take_internal (local.get $n) (call $fibs_internal ))))

  (func $fib_sum (export "fib-sum") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $fib_sum_internal (ref.i31 (local.get $n))))))

  (func $fn26 (type $ClosureFunc2) (param $__env anyref) (param $a anyref) (param $x anyref) (result anyref)
    (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $x))) (i31.get_s (ref.cast (ref i31) (local.get $x))))))))))

  (func $sum_squares_internal (param $n anyref) (result anyref)
    (call $reduce (struct.new $Closure2 (ref.func $fn26) (call $array_new (i32.const 0))) (ref.i31 (i32.const 0)) (call $take_internal (local.get $n) (call $drop_internal (ref.i31 (i32.const 1)) (call $range_arity0_internal )))))

  (func $sum_squares (export "sum-squares") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $sum_squares_internal (ref.i31 (local.get $n))))))

  (func $get_area_internal (param $w anyref) (param $h anyref) (result anyref)
    (call $__dispatch_area (call $vector_conj (call $vector_conj (call $empty_vector) (local.get $w)) (local.get $h))))

  (func $get_area (export "get-area") (param $w i32) (param $h i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $get_area_internal (ref.i31 (local.get $w)) (ref.i31 (local.get $h))))))

  (func $get_perimeter_internal (param $w anyref) (param $h anyref) (result anyref)
    (call $__dispatch_perimeter (call $vector_conj (call $vector_conj (call $empty_vector) (local.get $w)) (local.get $h))))

  (func $get_perimeter (export "get-perimeter") (param $w i32) (param $h i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $get_perimeter_internal (ref.i31 (local.get $w)) (ref.i31 (local.get $h))))))

  (func $collatz_len_internal (param $start anyref) (result anyref)
    (local $n anyref)
    (local $steps anyref)
    (block (result anyref)
      (local.set $n (local.get $start))
      (local.set $steps (ref.i31 (i32.const 0)))
      (loop $loop16 (result anyref)
        (if (result anyref)
      (call $truthy (ref.i31 (i32.le_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 1)))))))
      (then (local.get $steps))
      (else (call $collatz_next_internal (local.get $n))
        (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $steps))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 1))))))
        (local.set $steps)
        (local.set $n)
        (br $loop16))))))

  (func $collatz_len (export "collatz-len") (param $start i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $collatz_len_internal (ref.i31 (local.get $start))))))

  (func $collatz_at_internal (param $start anyref) (param $i anyref) (result anyref)
    (local $n anyref)
    (local $step anyref)
    (block (result anyref)
      (local.set $n (local.get $start))
      (local.set $step (ref.i31 (i32.const 0)))
      (loop $loop17 (result anyref)
        (if (result anyref)
      (call $truthy (ref.i31 (call $eq (local.get $step) (local.get $i))))
      (then (local.get $n))
      (else (if (result anyref)
      (call $truthy (ref.i31 (i32.le_s (i31.get_s (ref.cast (ref i31) (local.get $n))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 1)))))))
      (then (ref.i31 (i32.const 1)))
      (else (call $collatz_next_internal (local.get $n))
        (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $step))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 1))))))
        (local.set $step)
        (local.set $n)
        (br $loop17))))))))

  (func $collatz_at (export "collatz-at") (param $start i32) (param $i i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $collatz_at_internal (ref.i31 (local.get $start)) (ref.i31 (local.get $i))))))

  (func $fn27 (type $ClosureFunc2) (param $__env anyref) (param $acc anyref) (param $person anyref) (result anyref)
    (local $map__7 anyref)
    (local $age anyref)
    (block (result anyref)
      (local.set $map__7 (local.get $person))
      (local.set $age (call $hash_map_get (local.get $map__7) (struct.new $Keyword (i32.const 0))))
      (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (local.get $acc))) (i31.get_s (ref.cast (ref i31) (local.get $age)))))))

  (func $fn28 (type $ClosureFunc1) (param $__env anyref) (param $i anyref) (result anyref)
    (call $hash_map_assoc (call $hash_map_assoc (call $empty_hash_map) (struct.new $Keyword (i32.const 1)) (global.get $__str_2)) (struct.new $Keyword (i32.const 0)) (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 25)))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $i))) (i31.get_s (ref.cast (ref i31) (ref.i31 (i32.const 5))))))))))))

  (func $team_total_internal (param $n anyref) (result anyref)
    (call $reduce (struct.new $Closure2 (ref.func $fn27) (call $array_new (i32.const 0))) (ref.i31 (i32.const 0)) (call $map_internal (struct.new $Closure1 (ref.func $fn28) (call $array_new (i32.const 0))) (call $take_internal (local.get $n) (call $range_arity0_internal )))))

  (func $team_total (export "team-total") (param $n i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $team_total_internal (ref.i31 (local.get $n))))))

  (func $greeting_len_internal (param $id anyref) (result anyref)
    (ref.i31 (call $count_internal (call $greet_internal (if (result anyref)
      (call $truthy (ref.i31 (call $eq (local.get $id) (ref.i31 (i32.const 0)))))
      (then (global.get $__str_3))
      (else (if (result anyref)
      (call $truthy (ref.i31 (call $eq (local.get $id) (ref.i31 (i32.const 1)))))
      (then (global.get $__str_4))
      (else (if (result anyref)
      (call $truthy (ref.i31 (call $eq (local.get $id) (ref.i31 (i32.const 2)))))
      (then (global.get $__str_5))
      (else (if (result anyref)
      (call $truthy (ref.i31 (call $eq (local.get $id) (ref.i31 (i32.const 3)))))
      (then (global.get $__str_6))
      (else (global.get $__str_7)))))))))))))

  (func $greeting_len (export "greeting-len") (param $id i32) (result i32)
    (i31.get_s (ref.cast (ref i31) (call $greeting_len_internal (ref.i31 (local.get $id))))))

  (func $__builtin__STAR__fn (type $ClosureFunc2) (param $__env anyref) (param $arg0 anyref) (param $arg1 anyref) (result anyref)
    (ref.i31 (i32.mul (i31.get_s (ref.cast (ref i31) (local.get $arg0))) (i31.get_s (ref.cast (ref i31) (local.get $arg1))))))

  (func $__dispatch_area (param $arg0 anyref) (result anyref)
    (if (result anyref) (i32.eq (call $type_tag (local.get $arg0)) (i32.const 7))
          (then (call $invoke1 (global.get $__proto_area_7_closure) (local.get $arg0)))
          (else (unreachable))))

  (func $__dispatch_perimeter (param $arg0 anyref) (result anyref)
    (if (result anyref) (i32.eq (call $type_tag (local.get $arg0)) (i32.const 7))
          (then (call $invoke1 (global.get $__proto_perimeter_7_closure) (local.get $arg0)))
          (else (unreachable))))

  (func $__satisfies_IArea (param $val anyref) (result anyref)
    (ref.i31 (i32.eq (call $type_tag (local.get $val)) (i32.const 7))))

  (func $__satisfies_IPerimeter (param $val anyref) (result anyref)
    (ref.i31 (i32.eq (call $type_tag (local.get $val)) (i32.const 7))))

  (func $__init_str_0 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 7)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 72))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 101))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 108))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 108))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 111))
    (array.set $CharArray (local.get $data) (i32.const 5) (i32.const 44))
    (array.set $CharArray (local.get $data) (i32.const 6) (i32.const 32))
    (struct.new $String (i32.const 0) (local.get $data)))

  (func $__init_str_1 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 1)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 33))
    (struct.new $String (i32.const 1) (local.get $data)))

  (func $__init_str_2 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 6)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 109))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 101))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 109))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 98))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 101))
    (array.set $CharArray (local.get $data) (i32.const 5) (i32.const 114))
    (struct.new $String (i32.const 2) (local.get $data)))

  (func $__init_str_3 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 5)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 87))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 111))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 114))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 108))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 100))
    (struct.new $String (i32.const 3) (local.get $data)))

  (func $__init_str_4 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 3)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 119))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 111))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 106))
    (struct.new $String (i32.const 4) (local.get $data)))

  (func $__init_str_5 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 11)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 87))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 101))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 98))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 65))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 115))
    (array.set $CharArray (local.get $data) (i32.const 5) (i32.const 115))
    (array.set $CharArray (local.get $data) (i32.const 6) (i32.const 101))
    (array.set $CharArray (local.get $data) (i32.const 7) (i32.const 109))
    (array.set $CharArray (local.get $data) (i32.const 8) (i32.const 98))
    (array.set $CharArray (local.get $data) (i32.const 9) (i32.const 108))
    (array.set $CharArray (local.get $data) (i32.const 10) (i32.const 121))
    (struct.new $String (i32.const 5) (local.get $data)))

  (func $__init_str_6 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 7)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 67))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 108))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 111))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 106))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 117))
    (array.set $CharArray (local.get $data) (i32.const 5) (i32.const 114))
    (array.set $CharArray (local.get $data) (i32.const 6) (i32.const 101))
    (struct.new $String (i32.const 6) (local.get $data)))

  (func $__init_str_7 (result anyref)
    (local $data (ref $CharArray))
    (local.set $data (array.new $CharArray (i32.const 0) (i32.const 6)))
    (array.set $CharArray (local.get $data) (i32.const 0) (i32.const 70))
    (array.set $CharArray (local.get $data) (i32.const 1) (i32.const 114))
    (array.set $CharArray (local.get $data) (i32.const 2) (i32.const 105))
    (array.set $CharArray (local.get $data) (i32.const 3) (i32.const 101))
    (array.set $CharArray (local.get $data) (i32.const 4) (i32.const 110))
    (array.set $CharArray (local.get $data) (i32.const 5) (i32.const 100))
    (struct.new $String (i32.const 7) (local.get $data)))

  ;; Initialization
  (func $start
    (global.set $__builtin__STAR_ (struct.new $Closure2 (ref.func $__builtin__STAR__fn) (call $array_new (i32.const 0))))
    (global.set $__proto_area_7_closure (struct.new $Closure1 (ref.func $__proto_area_7) (call $array_new (i32.const 0))))
    (global.set $__proto_perimeter_7_closure (struct.new $Closure1 (ref.func $__proto_perimeter_7) (call $array_new (i32.const 0))))
    (global.set $__str_0 (call $__init_str_0))
    (global.set $__str_1 (call $__init_str_1))
    (global.set $__str_2 (call $__init_str_2))
    (global.set $__str_3 (call $__init_str_3))
    (global.set $__str_4 (call $__init_str_4))
    (global.set $__str_5 (call $__init_str_5))
    (global.set $__str_6 (call $__init_str_6))
    (global.set $__str_7 (call $__init_str_7))
    (block (result anyref) (global.set $_AMP_env (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $_AMP_form (ref.null none)) (ref.null none))
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (block (result anyref) (global.set $max_int (struct.new $Float (f64.const 2.147483647E9))) (ref.null none))
    drop
    (block (result anyref) (global.set $min_int (struct.new $Float (f64.const -2.147483648E9))) (ref.null none))
    drop
    (block (result anyref) (global.set $all_ones_int (ref.i31 (i32.const -1))) (ref.null none))
    drop
    (block (result anyref) (global.set $max_double (struct.new $Float (f64.const 1.7976931348623157E308))) (ref.null none))
    drop
    (block (result anyref) (global.set $min_double (struct.new $Float (f64.const 4.9E-324))) (ref.null none))
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (block (result anyref) (global.set $_AMP_ (struct.new $Symbol (i32.const 0))) (ref.null none))
    drop
    (block (result anyref) (global.set $case_STAR_ (struct.new $Symbol (i32.const 1))) (ref.null none))
    drop
    (block (result anyref) (global.set $new (struct.new $Symbol (i32.const 2))) (ref.null none))
    drop
    (block (result anyref) (global.set $_DOT_ (struct.new $Symbol (i32.const 3))) (ref.null none))
    drop
    (block (result anyref) (global.set $catch (struct.new $Symbol (i32.const 4))) (ref.null none))
    drop
    (block (result anyref) (global.set $deftype_STAR_ (struct.new $Symbol (i32.const 5))) (ref.null none))
    drop
    (block (result anyref) (global.set $finally (struct.new $Symbol (i32.const 6))) (ref.null none))
    drop
    (block (result anyref) (global.set $fn_STAR_ (struct.new $Symbol (i32.const 7))) (ref.null none))
    drop
    (block (result anyref) (global.set $let_STAR_ (struct.new $Symbol (i32.const 8))) (ref.null none))
    drop
    (block (result anyref) (global.set $letfn_STAR_ (struct.new $Symbol (i32.const 9))) (ref.null none))
    drop
    (block (result anyref) (global.set $loop_STAR_ (struct.new $Symbol (i32.const 10))) (ref.null none))
    drop
    (block (result anyref) (global.set $throw (struct.new $Symbol (i32.const 11))) (ref.null none))
    drop
    (block (result anyref) (global.set $try (struct.new $Symbol (i32.const 12))) (ref.null none))
    drop
    (block (result anyref) (global.set $var (struct.new $Symbol (i32.const 13))) (ref.null none))
    drop
    (block (result anyref) (global.set $_STAR_assert_STAR_ (ref.i31 (i32.const 1))) (ref.null none))
    drop
    (block (result anyref) (global.set $full_width_checker_pos (ref.null none)) (ref.null none))
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (block (result anyref) (global.set $full_width_checker_neg (ref.null none)) (ref.null none))
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (block (result anyref) (global.set $Object (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $String (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $clojure_DOT_lang_DOT_BigInt (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $clojure_DOT_lang_DOT_MapEntry (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $create (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $clojure_DOT_lang_DOT_IPending (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $clojure_DOT_lang_DOT_IReduce (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $UP (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $HALF_UP (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $CEILING (ref.null none)) (ref.null none))
    drop
    (block (result anyref) (global.set $FLOOR (ref.null none)) (ref.null none))
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop
    (ref.null none)
    drop)
  (start $start)
)
