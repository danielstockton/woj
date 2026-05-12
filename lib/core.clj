;; woj core library
;; Macros and functions that form the standard library
;; Macros are Clojure code executed at compile time
;; Functions are woj code compiled to WASM

;; ============================================
;; Macro compatibility (define before any macros)
;; ============================================

;; &env and &form are normally only available inside defmacro
;; Define them as nil for compatibility with test files that reference them
(def &env nil)
(def &form nil)

;; ============================================
;; Portability (for clojure-test-suite)
;; ============================================

;; when-var-exists: In woj, always runs the body.
;; This means tests for unimplemented features will fail,
;; serving as a todo list of what needs to be implemented.
(defmacro when-var-exists [var-sym & body]
  `(do ~@body))

;; ============================================
;; Macros (Clojure, compile-time)
;; ============================================

(defmacro defn [name & fdecl]
  (let [fdecl (if (string? (first fdecl)) (rest fdecl) fdecl)
        params (first fdecl)
        body (rest fdecl)]
    `(~'def ~name (~'fn ~params ~@body))))

(defmacro when [test & body]
  `(~'if ~test (~'do ~@body) nil))

(defmacro when-not [test & body]
  `(~'if ~test nil (~'do ~@body)))

(defmacro if-not [test then & [else]]
  `(~'if ~test ~else ~then))

(defmacro if-let [[binding test] then & [else]]
  (let [temp (gensym "temp__")]
    `(~'let [~temp ~test]
            (~'if ~temp
                  (~'let [~binding ~temp] ~then)
                  ~else))))

(defmacro when-let [[binding test] & body]
  (let [temp (gensym "temp__")]
    `(~'let [~temp ~test]
            (~'when ~temp
                    (~'let [~binding ~temp] ~@body)))))

(defmacro when-first [[binding coll] & body]
  (let [s (gensym "s__")]
    `(~'let [~s (~'seq ~coll)]
            (~'when ~s
                    (~'let [~binding (~'first ~s)]
                           ~@body)))))

(defmacro if-some [[binding test] then & [else]]
  (let [temp (gensym "temp__")]
    `(~'let [~temp ~test]
            (~'if (~'some? ~temp)
                  (~'let [~binding ~temp] ~then)
                  ~else))))

(defmacro when-some [[binding test] & body]
  (let [temp (gensym "temp__")]
    `(~'let [~temp ~test]
            (~'when (~'some? ~temp)
                    (~'let [~binding ~temp] ~@body)))))

;; dotimes: execute body n times with binding bound to 0..(n-1)
(defmacro dotimes [[binding n] & body]
  (let [limit (gensym "limit__")]
    `(~'let [~limit ~n]
            (~'loop [~binding 0]
                    (~'when (~'< ~binding ~limit)
                            ~@body
                            (~'recur (~'inc ~binding)))))))

;; while: execute body while test is truthy, returns nil
(defmacro while [test & body]
  `(~'loop []
           (~'when ~test
                   ~@body
                   (~'recur))))

(defmacro cond [& clauses]
  (when (seq clauses)
    (let [test (first clauses)
          expr (second clauses)
          rest-clauses (drop 2 clauses)]
      (if (= test :else)
        expr
        `(~'if ~test ~expr (~'cond ~@rest-clauses))))))

(defmacro -> [x & forms]
  (if (empty? forms)
    x
    (let [form (first forms)
          rest-forms (rest forms)
          threaded (if (seq? form)
                     (cons (first form) (cons x (rest form)))
                     (list form x))]
      `(~'-> ~threaded ~@rest-forms))))

(defmacro ->> [x & forms]
  (if (empty? forms)
    x
    (let [form (first forms)
          rest-forms (rest forms)
          threaded (if (seq? form)
                     (concat form (list x))
                     (list form x))]
      `(~'->> ~threaded ~@rest-forms))))

;; some->: thread-first with nil short-circuiting
(defmacro some-> [expr & forms]
  (let [temp (gensym "some__")]
    (if (empty? forms)
      expr
      `(~'let [~temp ~expr]
              (~'if (~'nil? ~temp)
                    nil
                    (~'some-> (~'-> ~temp ~(first forms)) ~@(rest forms)))))))

;; some->>: thread-last with nil short-circuiting
(defmacro some->> [expr & forms]
  (let [temp (gensym "some__")]
    (if (empty? forms)
      expr
      `(~'let [~temp ~expr]
              (~'if (~'nil? ~temp)
                    nil
                    (~'some->> (~'->> ~temp ~(first forms)) ~@(rest forms)))))))

;; as->: thread with named binding
(defmacro as-> [expr name & forms]
  (if (empty? forms)
    expr
    `(~'let [~name ~expr]
            (~'as-> ~(first forms) ~name ~@(rest forms)))))

;; cond->: thread-first with conditional steps
(defmacro cond-> [expr & clauses]
  (let [temp (gensym "cond__")]
    (if (empty? clauses)
      expr
      (let [[test form & rest-clauses] clauses]
        `(~'let [~temp ~expr]
                (~'cond-> (~'if ~test (~'-> ~temp ~form) ~temp) ~@rest-clauses))))))

;; cond->>: thread-last with conditional steps
(defmacro cond->> [expr & clauses]
  (let [temp (gensym "cond__")]
    (if (empty? clauses)
      expr
      (let [[test form & rest-clauses] clauses]
        `(~'let [~temp ~expr]
                (~'cond->> (~'if ~test (~'->> ~temp ~form) ~temp) ~@rest-clauses))))))

(defmacro list [& elements]
  (if (empty? elements)
    nil
    `(~'cons ~(first elements) (~'list ~@(rest elements)))))

(defmacro vector [& elements]
  (reduce (fn [acc elem] `(~'conj ~acc ~elem))
          '(empty-vector)
          elements))

(defmacro hash-map [& kvs]
  (reduce (fn [acc [k v]] `(~'assoc-map ~acc ~k ~v))
          '(empty-hash-map)
          (partition 2 kvs)))

(defmacro hash-set [& elements]
  (reduce (fn [acc elem] `(~'set-conj ~acc ~elem))
          '(empty-hash-set)
          elements))

;; Note: variadic assoc is handled by the analyzer's expand-variadic-assoc
;; The 'assoc' builtin is polymorphic (works on vectors and maps)

;; ============================================
;; Lazy Sequence Macro (must be before functions that use it)
;; ============================================

;; lazy-seq: create a lazy sequence from a body
;; The body is wrapped in a thunk that gets called when the sequence is realized
(defmacro lazy-seq [& body]
  `(~'make-lazy-seq (~'fn [] ~@body)))

;; ============================================
;; Core Collection Protocols
;; ============================================
;; These protocols enable user-defined types (via deftype) to participate
;; in core operations like seq, count, conj, get, assoc, and reduce.
;; Built-in types are extended here so (satisfies? ISeqable [1 2 3]) works.
;; The WAT fast path handles built-in types directly; these impls are
;; only invoked for user types via protocol dispatch.

(defprotocol ISeqable (-seq [coll]))
(defprotocol ICounted (-count [coll]))
(defprotocol ICollection (-conj [coll val]))
(defprotocol ILookup (-lookup [coll key]))
(defprotocol IAssociative (-assoc [coll key val]))
(defprotocol IReduce (-reduce-init [coll f init]))

(extend-protocol ISeqable
  nil (-seq [_] nil)
  Cons (-seq [coll] coll)
  Vector (-seq [coll] (seq coll))
  HashMap (-seq [coll] (seq coll))
  HashSet (-seq [coll] (seq coll))
  String (-seq [coll] (seq coll))
  LazySeq (-seq [coll] (seq coll)))

(extend-protocol ICounted
  nil (-count [_] 0)
  Cons (-count [coll] (count coll))
  Vector (-count [coll] (count coll))
  HashMap (-count [coll] (count coll))
  HashSet (-count [coll] (count coll))
  String (-count [coll] (count coll))
  LazySeq (-count [coll] (count coll)))

(extend-protocol ICollection
  nil (-conj [_ val] (cons val nil))
  Cons (-conj [coll val] (cons val coll))
  Vector (-conj [coll val] (conj coll val))
  HashMap (-conj [coll val] (conj coll val))
  HashSet (-conj [coll val] (conj coll val)))

(extend-protocol ILookup
  nil (-lookup [_ key] nil)
  HashMap (-lookup [coll key] (get coll key))
  Vector (-lookup [coll key] (nth coll key)))

(extend-protocol IAssociative
  HashMap (-assoc [coll key val] (assoc coll key val))
  Vector (-assoc [coll key val] (assoc coll key val)))

(extend-protocol IReduce
  nil (-reduce-init [_ f init] init)
  Cons (-reduce-init [coll f init] (reduce f init coll))
  Vector (-reduce-init [coll f init] (reduce f init coll))
  HashMap (-reduce-init [coll f init] (reduce f init coll))
  HashSet (-reduce-init [coll f init] (reduce f init coll))
  LazySeq (-reduce-init [coll f init] (reduce f init coll)))

;; ============================================
;; Functions (woj, compiled to WASM)
;; ============================================

;; Identity
(defn identity [x] x)

;; List operations
(defn second [coll]
  (first (rest coll)))

(defn ffirst [coll]
  (first (first coll)))

;; Higher-order functions that take user-provided functions
;; These work when the user passes closures or named functions
;; Now implemented using lazy-seq for deferred evaluation

(defn map-seq [f coll]
  (lazy-seq
   (when-let [s (seq coll)]
     (cons (f (first s)) (map-seq f (rest s))))))

(defn map
  ([f] (fn [rf] (fn [result input] (rf result (f input)))))
  ([f coll] (map-seq f coll))
  ([f c1 c2] (lazy-seq (let [s1 (seq c1) s2 (seq c2)] (when (and s1 s2) (cons (f (first s1) (first s2)) (map f (rest s1) (rest s2)))))))
  ([f c1 c2 c3] (lazy-seq (let [s1 (seq c1) s2 (seq c2) s3 (seq c3)] (when (and s1 s2 s3) (cons (f (first s1) (first s2) (first s3)) (map f (rest s1) (rest s2) (rest s3))))))))

(defn filter-seq [pred coll]
  (lazy-seq
   (when-let [s (seq coll)]
     (let [x (first s)]
       (if (pred x)
         (cons x (filter-seq pred (rest s)))
         (filter-seq pred (rest s)))))))

(defn filter
  ([pred] (fn [rf] (fn [result input] (if (pred input) (rf result input) result))))
  ([pred coll] (filter-seq pred coll)))

;; reduce is now a builtin with efficient type-specific implementations
;; (defn reduce [f init coll] ...) - removed, using builtin

;; Sequence slicing functions (lazy where applicable)
(defn take-seq [n coll]
  (lazy-seq
   (when (pos? n)
     (when-let [s (seq coll)]
       (cons (first s) (take-seq (dec n) (rest s)))))))

(defn take
  ([n] (fn [rf]
         (let [remaining (atom n)]
           (fn [result input]
             (if (pos? (deref remaining))
               (do (swap! remaining dec)
                   (rf result input))
               result)))))
  ([n coll] (take-seq n coll)))

(defn drop
  ([n] (fn [rf]
         (let [remaining (atom n)]
           (fn [result input]
             (if (pos? (deref remaining))
               (do (swap! remaining dec) result)
               (rf result input))))))
  ([n coll]
   (loop [remaining n curr coll]
     (if (or (<= remaining 0) (nil? (seq curr)))
       curr
       (recur (dec remaining) (rest curr))))))

(defn nth-list [coll n]
  (if (zero? n)
    (first coll)
    (nth-list (rest coll) (dec n))))

(defn concat-list [a b]
  (if (seq a)
    (cons (first a) (concat-list (rest a) b))
    b))

(defn last [coll]
  (if (seq (rest coll))
    (last (rest coll))
    (first coll)))

(defn butlast [coll]
  (if (seq (rest coll))
    (cons (first coll) (butlast (rest coll)))
    nil))

;; Predicates
(defn even? [n]
  (zero? (- n (* 2 (/ n 2)))))

(defn odd? [n]
  (not (even? n)))

;; Range (lazy version with step support)
;; Helper for infinite range
(defn range-infinite [start]
  (lazy-seq (cons start (range-infinite (inc start)))))

;; Helper for finite range with step
(defn range-step [start end step]
  (lazy-seq
   (when (if (pos? step) (< start end) (> start end))
     (cons start (range-step (+ start step) end step)))))

;; range-from: main entry point
(defn range-from
  ([start]
   (range-infinite start))
  ([start end]
   (range-step start end 1))
  ([start end step]
   (range-step start end step)))

;; ============================================
;; Additional Sequence Operations (Phase 2.2)
;; ============================================

;; reverse: reverse a list
(defn reverse [coll]
  (loop [acc nil curr (seq coll)]
    (if curr
      (recur (cons (first curr) acc) (seq (rest curr)))
      acc)))

;; concat: concatenate multiple sequences
(defn concat
  ([] nil)
  ([a] (lazy-seq (seq a)))
  ([a b]
   (lazy-seq
     (let [s (seq a)]
       (if (nil? s)
         (seq b)
         (cons (first s) (concat (rest s) b))))))
  ([a b & more]
   (concat a (concat b (reduce concat more)))))

;; take-while: take elements while predicate is true
(defn take-while-seq [pred coll]
  (let [s (seq coll)]
    (if (nil? s)
      nil
      (if (pred (first s))
        (cons (first s) (take-while-seq pred (rest s)))
        nil))))

(defn take-while
  ([pred] (fn [rf]
            (fn [result input]
              (if (pred input)
                (rf result input)
                (reduced result)))))
  ([pred coll] (take-while-seq pred coll)))

;; drop-while: drop elements while predicate is true
(defn drop-while-seq [pred coll]
  (let [s (seq coll)]
    (if (nil? s)
      nil
      (if (pred (first s))
        (drop-while-seq pred (rest s))
        s))))

(defn drop-while
  ([pred] (fn [rf]
            (let [dropping (atom true)]
              (fn [result input]
                (if (and (deref dropping) (pred input))
                  result
                  (do (reset! dropping false)
                      (rf result input)))))))
  ([pred coll] (drop-while-seq pred coll)))

;; split-at: split collection at index n
(defn split-at [n coll]
  (list (take n coll) (drop n coll)))

;; split-with: split collection where predicate becomes false
(defn split-with [pred coll]
  (list (take-while pred coll) (drop-while pred coll)))

;; interpose: insert separator between elements
(defn interpose-seq [sep coll]
  (let [s (seq coll)]
    (if (nil? s)
      nil
      (if (seq (rest s))
        (cons (first s) (cons sep (interpose-seq sep (rest s))))
        (list (first s))))))

(defn interpose
  ([sep] (fn [rf]
           (let [started (atom false)]
             (fn [result input]
               (if (deref started)
                 (rf (rf result sep) input)
                 (do (reset! started true)
                     (rf result input)))))))
  ([sep coll] (interpose-seq sep coll)))

;; interleave: interleave two sequences
(defn interleave [c1 c2]
  (let [s1 (seq c1) s2 (seq c2)]
    (if (or (nil? s1) (nil? s2))
      nil
      (cons (first s1) (cons (first s2) (interleave (rest s1) (rest s2)))))))

;; some: returns first truthy value of (pred x) for x in coll
(defn some [pred coll]
  (let [s (seq coll)]
    (if (nil? s)
      nil
      (let [result (pred (first s))]
        (if result
          result
          (some pred (rest s)))))))

;; every?: returns true if (pred x) is truthy for all x in coll
(defn every? [pred coll]
  (let [s (seq coll)]
    (if (nil? s)
      true
      (if (pred (first s))
        (every? pred (rest s))
        false))))

;; not-every?: returns true if (pred x) is falsy for some x in coll
(defn not-every? [pred coll]
  (not (every? pred coll)))

;; not-any?: returns true if (pred x) is falsy for all x in coll
(defn not-any? [pred coll]
  (not (some pred coll)))

;; keep: returns non-nil results of (f x) for x in coll
(defn keep
  ([f] (fn [rf]
         (fn [result input]
           (let [v (f input)]
             (if (nil? v) result (rf result v))))))
  ([f coll]
   (let [keep-seq (fn keep-seq [f coll]
                    (let [s (seq coll)]
                      (if (nil? s)
                        nil
                        (let [result (f (first s))]
                          (if (nil? result)
                            (keep-seq f (rest s))
                            (cons result (keep-seq f (rest s))))))))]
     (keep-seq f coll))))

;; map-indexed: like map but f takes index and element
(defn map-indexed [f coll]
  (loop [idx 0 curr (seq coll) acc nil]
    (if (nil? curr)
      (reverse acc)
      (recur (inc idx) (next curr) (cons (f idx (first curr)) acc)))))

;; keep-indexed: like keep but f takes index and element
(defn keep-indexed [f coll]
  (loop [idx 0 curr (seq coll) acc nil]
    (if (nil? curr)
      (reverse acc)
      (let [result (f idx (first curr))]
        (if (nil? result)
          (recur (inc idx) (next curr) acc)
          (recur (inc idx) (next curr) (cons result acc)))))))

;; distinct: remove duplicates (O(n^2) simple version)
(defn distinct
  ([] (fn [rf]
        (let [seen (atom #{})]
          (fn [result input]
            (if (contains? (deref seen) input)
              result
              (do (swap! seen (fn [s] (set-conj s input)))
                  (rf result input)))))))
  ([coll]
   (loop [seen nil curr (seq coll) acc nil]
     (if curr
       (let [x (first curr)]
         (if (some (fn [y] (= x y)) seen)
          (recur seen (next curr) acc)
          (recur (cons x seen) (next curr) (cons x acc))))
       (reverse acc)))))

;; partition: partition collection into groups of n
(defn partition-seq [n coll]
  (let [s (seq coll)]
    (if (nil? s)
      nil
      (let [chunk (take n s)]
        (if (= (count chunk) n)
          (cons chunk (partition-seq n (drop n s)))
          nil)))))

(defn partition [n coll]
  (partition-seq n coll))

;; partition-all: like partition but includes incomplete final chunk
;; xf-complete: call completion on a transducer-wrapped reducing function
;; Uses metadata to find the completion function
(defn xf-complete [xf result]
  (let [m (meta xf)]
    (if (nil? m)
      result
      (let [completer (get m :xf/complete)]
        (if (nil? completer)
          result
          (completer result))))))

(defn partition-all-seq [n coll]
  (if (nil? (seq coll))
    nil
    (cons (take n coll) (partition-all-seq n (drop n coll)))))


(defn partition-all
  ([n] (fn [rf]
         (let [buf (atom [])
               complete (fn [result]
                          (let [b (deref buf)]
                            (if (> (count b) 0)
                              (rf result b)
                              result)))]
           (with-meta
             (fn [result input]
               (let [b (swap! buf (fn [v] (conj v input)))]
                 (if (= (count b) n)
                   (do (reset! buf [])
                       (rf result b))
                   result)))
             {:xf/complete complete}))))
  ([n coll] (partition-all-seq n coll)))

;; flatten: flatten nested lists (simple version for one level)
(defn flatten-one [coll]
  (let [s (seq coll)]
    (if (nil? s)
      nil
      (let [x (first s)]
        (if (cons? x)
          (concat x (flatten-one (rest s)))
          (cons x (flatten-one (rest s))))))))

;; mapcat: map then concat results
(defn mapcat-seq [f coll]
  (let [s (seq coll)]
    (if (nil? s)
      nil
      (concat (f (first s)) (mapcat-seq f (rest s))))))

(defn mapcat
  ([f] (fn [rf]
         (fn [result input]
           (reduce rf result (f input)))))
  ([f coll] (mapcat-seq f coll))
  ([f c1 c2] (mapcat-seq (fn [[a b]] (f a b)) (map (fn [a b] [a b]) c1 c2))))

;; cat: transducer that concatenates nested collections into the reduction
(defn cat [rf]
  (fn [result input]
    (reduce rf result input)))

;; remove: opposite of filter
(defn remove
  ([pred] (filter (fn [x] (not (pred x)))))
  ([pred coll] (filter (fn [x] (not (pred x))) coll)))

;; next: like rest but returns nil instead of empty list
(defn next [coll]
  (seq (rest coll)))

;; nthnext: drop n elements and return the rest
(defn nthnext [coll n]
  (if (zero? n)
    coll
    (nthnext (rest coll) (dec n))))

;; nthrest: like nthnext (alias)
(defn nthrest [coll n]
  (nthnext coll n))

;; ============================================
;; Map Operations (Phase 3)
;; ============================================

;; merge: merge maps (later maps override earlier)
(defn merge
  ([] nil)
  ([m] m)
  ([m1 m2]
   (if (nil? m2)
     m1
     (if (nil? m1)
       m2
       (persistent!
        (reduce-kv (fn [r k v] (assoc! r k v))
                   (transient m1)
                   m2)))))
  ([m1 m2 & more]
   (reduce merge (merge m1 m2) more)))

;; merge-with: merge maps using f to combine values for duplicate keys
(defn merge-with [f m1 m2]
  (if (nil? m2)
    m1
    (if (nil? m1)
      m2
      (reduce-kv (fn [m k v]
                   (if (contains? m k)
                     (assoc m k (f (get m k) v))
                     (assoc m k v)))
                 m1 m2))))

;; find: returns [key value] pair if key exists, nil otherwise
(defn find [m k]
  (if (contains? m k)
    [k (get m k)]
    nil))

;; select-keys: returns a map with only the specified keys
(defn select-keys [m ks]
  (persistent!
   (reduce (fn [r k] (if (contains? m k) (assoc! r k (get m k)) r))
           (transient {})
           ks)))

;; get-in: get nested value
(defn get-in
  ([m ks] (get-in m ks nil))
  ([m ks not-found]
   (if (nil? ks)
     m
     (let [s (seq ks)]
       (if (nil? s)
         m
         (loop [m m remaining s]
           (let [k (first remaining)
                 nxt (next remaining)]
             (if (nil? nxt)
               ;; Last key: use 3-arg get with not-found
               (get m k not-found)
               ;; Intermediate key: get and continue
               (recur (get m k) nxt)))))))))

;; assoc-in: assoc at nested path
(defn assoc-in [m ks v]
  (if (next ks)
    (assoc m (first ks) (assoc-in (get m (first ks)) (next ks) v))
    (assoc m (first ks) v)))

;; update: apply function to value at key
(defn update [m k f]
  (assoc m k (f (get m k))))

;; update-in: apply function to nested value
(defn update-in [m ks f]
  (if (next ks)
    (assoc m (first ks) (update-in (get m (first ks)) (next ks) f))
    (update m (first ks) f)))

;; ============================================
;; Set Operations (Phase 3)
;; ============================================

;; set: convert collection to set
(defn set [coll]
  (persistent!
   (reduce conj! (transient (hash-set)) (seq coll))))

;; union: union of two sets
(defn union [s1 s2]
  (persistent!
   (reduce conj! (transient s1) (seq s2))))

;; intersection: intersection of two sets
(defn intersection [s1 s2]
  (persistent!
   (reduce (fn [r elem] (if (contains? s2 elem) (conj! r elem) r))
           (transient (hash-set))
           (seq s1))))

;; difference: elements in s1 but not in s2
(defn difference [s1 s2]
  (persistent!
   (reduce (fn [r elem] (if (contains? s2 elem) r (conj! r elem)))
           (transient (hash-set))
           (seq s1))))

;; subset?: is s1 a subset of s2?
(defn subset? [s1 s2]
  (every? (fn [elem] (contains? s2 elem)) (seq s1)))

;; superset?: is s1 a superset of s2?
(defn superset? [s1 s2]
  (subset? s2 s1))

;; ============================================
;; Atom Operations (Phase 4)
;; ============================================

;; swap-vals!: swap atom value, return [old new]
;; Note: In single-threaded WASM, this is safe
(defn swap-vals! [a f]
  (let [old (deref a)
        new (f old)]
    (reset! a new)
    (vector old new)))

;; reset-vals!: reset atom value, return [old new]
(defn reset-vals! [a newval]
  (let [old (deref a)]
    (reset! a newval)
    (vector old newval)))

;; ============================================
;; Higher-Order Functions (Phase 5)
;; ============================================

;; identity is defined earlier in the file

;; constantly: returns a function that always returns the same value
;; Note: currently returns 1-arity fn, ignores any arguments
(defn constantly [x]
  (fn
    ([] x)
    ([a] x)
    ([a b] x)
    ([a b c] x)))

;; comp: compose functions (right to left)
(defn comp
  ([] identity)
  ([f] f)
  ([f g] (fn [x] (f (g x))))
  ([f g & more]
   (reduce comp (cons f (cons g more)))))

;; partial: partially apply a function
;; Returns a multi-arity closure that captures the partial args.
(defn partial
  ([f] f)
  ([f a] (fn
           ([] (f a))
           ([b] (f a b))
           ([b c] (f a b c))
           ([b c d] (f a b c d))))
  ([f a b] (fn
             ([] (f a b))
             ([c] (f a b c))
             ([c d] (f a b c d))))
  ([f a b c] (fn
               ([] (f a b c))
               ([d] (f a b c d)))))

;; complement: returns a function that negates the result
(defn complement [f]
  (fn
    ([x] (not (f x)))
    ([x y] (not (f x y)))))

;; juxt: returns a function that returns a vector of results
(defn juxt
  ([f] (fn
         ([x] [(f x)])
         ([x y] [(f x) (f y)])))
  ([f g] (fn
           ([x] [(f x) (g x)])
           ([x y] [(f x y) (g x y)])))
  ([f g h] (fn
             ([x] [(f x) (g x) (h x)])
             ([x y] [(f x y) (g x y) (h x y)]))))

;; ============================================
;; Additional Functions for clojure-test-suite
;; ============================================

;; range: lazy sequence of numbers
;; (range) - infinite sequence starting from 0
;; (range end) - 0 to end-1
;; (range start end) - start to end-1
;; (range start end step) - start to end-1 by step
(defn range
  ([] (range-from 0))
  ([end] (range-from 0 end 1))
  ([start end] (range-from start end 1))
  ([start end step] (range-from start end step)))

;; repeat: create a lazy sequence of repeated values
;; Helper for infinite repeat
(defn repeat-infinite [x]
  (lazy-seq (cons x (repeat-infinite x))))

;; Helper for finite repeat
(defn repeat-n [n x]
  (lazy-seq
   (when (pos? n)
     (cons x (repeat-n (dec n) x)))))

;; repeat: main entry point
;; (repeat x) - infinite sequence of x
;; (repeat n x) - sequence of n x's
(defn repeat
  ([x] (repeat-infinite x))
  ([n x] (repeat-n n x)))

;; repeatedly: create a lazy sequence by calling f repeatedly
;; Helper for infinite repeatedly
(defn repeatedly-infinite [f]
  (lazy-seq (cons (f) (repeatedly-infinite f))))

;; Helper for finite repeatedly
(defn repeatedly-n [n f]
  (lazy-seq
   (when (pos? n)
     (cons (f) (repeatedly-n (dec n) f)))))

;; repeatedly: main entry point
;; (repeatedly f) - infinite sequence
;; (repeatedly n f) - sequence of n calls
(defn repeatedly
  ([f] (repeatedly-infinite f))
  ([n f] (repeatedly-n n f)))

;; iterate: create a lazy sequence of f applied repeatedly
;; (iterate f x) - x, (f x), (f (f x)), ...
(defn iterate [f x]
  (lazy-seq (cons x (iterate f (f x)))))

;; into: pour collection into another collection (uses transients for performance)
(defn into
  ([to from]
   (if (or (vector? to) (map? to) (set? to))
     (persistent!
      (reduce conj! (transient to) (seq from)))
     (loop [result to remaining (seq from)]
       (if (nil? remaining)
         result
         (recur (conj result (first remaining)) (next remaining))))))
  ([to xform from]
   (if (or (vector? to) (map? to) (set? to))
     (let [xf (xform conj!)
           result (reduce xf (transient to) (seq from))]
       (persistent! (xf-complete xf result)))
     (let [xf (xform conj)
           result (reduce xf to (seq from))]
       (xf-complete xf result)))))

;; zipmap: create a map from keys and values sequences
(defn zipmap [keys vals]
  (loop [result (transient {}) ks (seq keys) vs (seq vals)]
    (if (or (nil? ks) (nil? vs))
      (persistent! result)
      (recur (assoc! result (first ks) (first vs))
             (next ks)
             (next vs)))))

;; doall: force realization of lazy sequences, returns the collection
(defn doall [coll]
  (loop [s (seq coll)]
    (if s
      (recur (next s))
      coll)))

;; dorun: force realization of lazy sequences, returns nil
(defn dorun [coll]
  (loop [s (seq coll)]
    (if s
      (recur (next s))
      nil)))

;; meta/with-meta: stubs (woj doesn't have metadata yet)
;; meta and with-meta are builtins

;; vary-meta: apply f to the metadata of obj
(defn vary-meta [obj f]
  (with-meta obj (f (meta obj))))

;; volatile!: stub using atoms (same semantics for single-threaded wasm)
(defn volatile! [x] (atom x))
(defn vreset! [v newval] (reset! v newval))
(defn vswap!
  ([v f] (swap! v f))
  ([v f x] (reset! v (f @v x)))
  ([v f x y] (reset! v (f @v x y))))

;; sorted?: stub (always false since we don't have sorted collections)
(defn sorted? [coll] false)

;; any?: check if anything is passed (always true for any value)
(defn any? [x] true)

;; rem: remainder (truncated division toward zero)
(defn rem [n d]
  (let [q (if (and (integer? n) (integer? d))
            (/ n d)
            (to-int (/ n d)))]
    (- n (* q d))))

;; mod: modulus (floored division)
(defn mod [n d]
  (let [r (rem n d)]
    (if (or (zero? r) (if (pos? d) (pos? r) (neg? r)))
      r
      (+ r d))))

;; abs: absolute value
(defn abs [n]
  (if (neg? n) (- 0 n) n))

;; min/max: variadic
(defn min
  ([a] a)
  ([a b] (if (< a b) a b))
  ([a b & more] (reduce min (min a b) more)))
(defn max
  ([a] a)
  ([a b] (if (> a b) a b))
  ([a b & more] (reduce max (max a b) more)))

;; Variadic arithmetic: these shadow the 2-arity builtins when used as values
;; Direct calls like (+ 1 2) still use the fast builtin path via the analyzer
;; But (apply + [1 2 3]) or (reduce + coll) use these multi-arity definitions
(defn +
  ([] 0)
  ([x] x)
  ([x y] (+ x y))
  ([x y & more] (reduce + (+ x y) more)))
(defn -
  ([x] (- 0 x))
  ([x y] (- x y))
  ([x y & more] (reduce - (- x y) more)))
(defn *
  ([] 1)
  ([x] x)
  ([x y] (* x y))
  ([x y & more] (reduce * (* x y) more)))

;; sort: insertion sort with optional comparator
(defn sort-with-cmp [cmp coll]
  (loop [result nil remaining (seq coll)]
    (if (nil? remaining)
      result
      (recur
       (loop [acc nil left result x (first remaining)]
         (if (nil? left)
           (reverse (cons x acc))
           (if (neg? (cmp x (first left)))
             (concat (reverse (cons x acc)) left)
             (recur (cons (first left) acc) (rest left) x))))
       (next remaining)))))

(defn sort
  ([coll] (sort-with-cmp compare coll))
  ([cmp coll] (sort-with-cmp cmp coll)))

;; int?: check if integer (same as integer? for now)
(defn int? [x] (integer? x))

;; double?: check if float
(defn double? [x] (float? x))

;; boolean?: check if boolean
(defn boolean? [x]
  (or (true? x) (false? x)))

;; ratio?: stub (woj converts ratios to floats)
(defn ratio? [x] false)

;; rational?: stub
(defn rational? [x] (or (integer? x) (ratio? x)))

;; big-int?: stub (woj doesn't have BigInt)
(defn big-int? [x] false)

;; char?: check if character (characters are integers in woj)
;; Stub for now - returns false
(defn char? [x] false)

;; array-map: same as hash-map (woj doesn't differentiate)
(defmacro array-map [& kvs]
  `(hash-map ~@kvs))


;; comment: evaluates to nil
(defmacro comment [& body] nil)

;; val: get value from map entry (pair)
(defn val [entry] (second entry))

;; key: get key from map entry (pair)
(defn key [entry] (first entry))

;; Hierarchy system: derive/underive/ancestors/descendants/parents/isa?
;; A hierarchy is a map with :parents, :ancestors, :descendants keys.
;; Each maps a tag to a set of related tags.

(defn make-hierarchy []
  {:parents {} :ancestors {} :descendants {}})

;; Global hierarchy for 2-arg derive/isa?/etc.
(def global-hierarchy (atom (make-hierarchy)))

(defn- hierarchy-derive [h tag parent]
  (if (= tag parent)
    (throw (ex-info "Cannot derive tag from itself" {:tag tag}))
    (let [cur-parents (get (get h :parents) tag #{})
          cur-ancestors (get (get h :ancestors) tag #{})]
      ;; If already derived, return unchanged
      (if (contains? cur-parents parent)
        h
        (let [;; Check for cycle: parent is descendant of tag
              _ (if (contains? (get (get h :ancestors) parent #{}) tag)
                  (throw (ex-info "Cyclic derivation" {:tag tag :parent parent}))
                  nil)
              ;; Compute new ancestors for tag: parent + parent's ancestors
              parent-ancestors (get (get h :ancestors) parent #{})
              new-ancestors (set-conj (union cur-ancestors parent-ancestors) parent)
              ;; Update parents
              new-parents-map (assoc (get h :parents) tag (set-conj cur-parents parent))
              ;; Update ancestors for tag and all its descendants
              tag-descendants (set-conj (get (get h :descendants) tag #{}) tag)
              ;; For each descendant of tag (including tag itself), add new ancestors
              new-ancestors-map (reduce
                                  (fn [am desc]
                                    (let [desc-anc (get am desc #{})]
                                      (assoc am desc (union desc-anc new-ancestors))))
                                  (get h :ancestors)
                                  tag-descendants)
              ;; Update descendants: parent and all parent's ancestors gain tag and tag's descendants
              new-parent-set (set-conj parent-ancestors parent)
              new-descendants-map (reduce
                                    (fn [dm anc]
                                      (let [anc-desc (get dm anc #{})]
                                        (assoc dm anc (union anc-desc tag-descendants))))
                                    (get h :descendants)
                                    new-parent-set)]
          {:parents new-parents-map
           :ancestors new-ancestors-map
           :descendants new-descendants-map})))))

(defn derive
  ([tag parent]
   (swap! global-hierarchy (fn [h] (hierarchy-derive h tag parent)))
   nil)
  ([h tag parent]
   (hierarchy-derive h tag parent)))

(defn parents
  ([tag] (parents (deref global-hierarchy) tag))
  ([h tag]
   (let [p (get (get h :parents) tag)]
     (if (or (nil? p) (empty? p)) nil p))))

(defn ancestors
  ([tag] (ancestors (deref global-hierarchy) tag))
  ([h tag]
   (let [a (get (get h :ancestors) tag)]
     (if (or (nil? a) (empty? a)) nil a))))

(defn descendants
  ([tag] (descendants (deref global-hierarchy) tag))
  ([h tag]
   (let [d (get (get h :descendants) tag)]
     (if (or (nil? d) (empty? d)) nil d))))

(defn isa?
  ([child parent]
   (isa? (deref global-hierarchy) child parent))
  ([h child parent]
   (or (= child parent)
       (contains? (get (get h :ancestors) child #{}) parent))))

(defn- underive-add-parents [all-parents h2 tk]
  (let [ps (get all-parents tk)]
    (if (nil? ps)
      h2
      (reduce (fn [h3 p]
                (hierarchy-derive h3 tk p))
              h2 ps))))

(defn underive
  ([tag parent]
   (swap! global-hierarchy (fn [h] (underive h tag parent)))
   nil)
  ([h tag parent]
   (let [cur-parents (get (get h :parents) tag #{})
         new-parents (disj cur-parents parent)
         all-parents (assoc (get h :parents) tag new-parents)
         base (make-hierarchy)]
     (reduce (fn [h2 tk] (underive-add-parents all-parents h2 tk))
             base (keys all-parents)))))

;; mm-find-isa: find the best matching method via isa? hierarchy lookup
;; Returns the method function or nil if no match found
(defn- mm-is-preferred [prefer x y]
  (let [prefs (get prefer x)]
    (if (nil? prefs)
      false
      (contains? prefs y))))

(defn mm-find-isa [methods dv h prefer]
  (let [ks (keys methods)]
    (loop [remaining (seq ks) best nil best-key nil]
      (if (nil? remaining)
        best
        (let [k (first remaining)]
          (if (and (not (= k :default)) (isa? h dv k))
            (if (nil? best)
              (recur (next remaining) (get methods k) k)
              ;; Ambiguity: check preferences
              (if (mm-is-preferred prefer k best-key)
                (recur (next remaining) (get methods k) k)
                (if (mm-is-preferred prefer best-key k)
                  (recur (next remaining) best best-key)
                  ;; Check if one is more specific (k isa? best-key or vice versa)
                  (if (isa? h k best-key)
                    (recur (next remaining) (get methods k) k)
                    (if (isa? h best-key k)
                      (recur (next remaining) best best-key)
                      ;; True ambiguity - just pick one (could throw)
                      (recur (next remaining) best best-key))))))
            (recur (next remaining) best best-key)))))))

;; take-last: take last n items
(defn take-last [n coll]
  (let [len (count (seq coll))]
    (drop (max 0 (- len n)) coll)))

;; drop-last: drop last n items
(defn drop-last
  ([coll] (drop-last 1 coll))
  ([n coll] (take (max 0 (- (count (seq coll)) n)) coll)))

;; shuffle: Fisher-Yates shuffle
(defn shuffle [coll]
  (let [n (count coll)]
    (loop [i (dec n) v (vec coll)]
      (if (<= i 0)
        v
        (let [j (to-int (* (Math/random) (to-float (inc i))))
              vi (nth v i)
              vj (nth v j)]
          (recur (dec i) (assoc (assoc v i vj) j vi)))))))

;; flatten: recursively flatten nested sequences
(defn flatten [coll]
  (lazy-seq
    (when (not (nil? (seq coll)))
      (let [x (first coll)]
        (if (seqable? x)
          (concat (flatten x) (flatten (rest coll)))
          (cons x (flatten (rest coll))))))))

;; dedupe: remove consecutive duplicates (eager)
(defn dedupe
  ([] (fn [rf]
        (let [prev (atom :woj/sentinel)]
          (fn [result input]
            (if (= input (deref prev))
              result
              (do (reset! prev input)
                  (rf result input)))))))
  ([coll]
   (loop [result nil prev :woj/sentinel s (seq coll)]
     (if (nil? s)
       (reverse result)
       (let [x (first s)]
         (if (= x prev)
           (recur result prev (next s))
           (recur (cons x result) x (next s))))))))

;; memoize: cache function results using an atom map
;; Caches single-argument function results
(defn memoize [f]
  (let [cache (atom {})]
    (fn [x]
      (let [cached (get @cache x :woj/not-found)]
        (if (= cached :woj/not-found)
          (let [result (f x)]
            (swap! cache assoc x result)
            result)
          cached)))))

;; trampoline: for mutual recursion without stack overflow
(defn trampoline-run [f]
  (loop [result (f)]
    (if (fn? result)
      (recur (result))
      result)))

(defn trampoline
  ([f] (trampoline-run f))
  ([f x] (trampoline-run (fn [] (f x))))
  ([f x y] (trampoline-run (fn [] (f x y)))))

;; vec: convert to vector
(defn vec [coll]
  (if (vector? coll)
    coll
    (into [] coll)))

;; mapv: eager map returning a vector
(defn mapv
  ([f coll] (into [] (map f coll)))
  ([f c1 c2] (into [] (map f c1 c2)))
  ([f c1 c2 c3] (into [] (map f c1 c2 c3))))

;; filterv: eager filter returning a vector
(defn filterv [pred coll]
  (into [] (filter pred coll)))

;; subvec: get subvector (simple implementation)
(defn subvec
  ([v start] (subvec v start (count v)))
  ([v start end]
   (loop [result [] i start]
     (if (>= i end)
       result
       (recur (conj result (nth v i)) (inc i))))))

;; cycle: infinite lazy repetition of a sequence
(defn cycle [coll]
  (let [s (seq coll)]
    (when (not (nil? s))
      (lazy-seq (concat s (cycle s))))))

;; add-watch/remove-watch/set-validator!: now builtins (Phase 8)

;; get-validator: stub (not yet a builtin)
(defn get-validator [ref] nil)

;; transient collection operations are now builtins:
;; transient, persistent!, conj!, assoc!, dissoc!, disj!, pop!

;; boolean: coerce to boolean
(defn boolean [x]
  (if x true false))

;; not-empty: returns nil if coll is empty, else coll
(defn not-empty [coll]
  (if (empty? coll) nil coll))

;; empty: return empty version of collection
(defn empty [coll]
  (cond
    (vector? coll) []
    (map? coll) {}
    (set? coll) (hash-set)
    :else nil))

;; str: convert values to strings and concatenate
;; Real function so it can be passed to apply, map, etc.
(defn str1-or-pr [x]
  (if (or (coll? x) (seq? x) (lazy-seq? x))
    (pr-str1 x)
    (str1 x)))

(defn str
  ([] "")
  ([x] (str1-or-pr x))
  ([x & more]
   (let [buf (string-buffer)]
     (sb-append! buf (str1-or-pr x))
     (loop [s (seq more)]
       (if (nil? s)
         (sb->string buf)
         (do (sb-append! buf (str1-or-pr (first s)))
             (recur (next s))))))))

;; symbol: create symbol from string/keyword/symbol (builtin)
;; symbol and symbol2 are builtins - no need for function definitions

;; name: get name from keyword/symbol (builtin)
;; Already a builtin - no need for a function definition

;; namespace: get namespace of symbol (builtin)
;; namespace is a builtin - no need for a function definition

;; simple-ident?/simple-keyword?/simple-symbol?
(defn simple-keyword? [x] (and (keyword? x) (nil? (namespace x))))
(defn simple-symbol? [x] (and (symbol? x) (nil? (namespace x))))
(defn simple-ident? [x] (or (simple-keyword? x) (simple-symbol? x)))

;; qualified-ident?/qualified-keyword?/qualified-symbol?
(defn qualified-keyword? [x] (and (keyword? x) (some? (namespace x))))
(defn qualified-symbol? [x] (and (symbol? x) (some? (namespace x))))
(defn qualified-ident? [x] (or (qualified-keyword? x) (qualified-symbol? x)))

;; ident?: check if keyword or symbol
(defn ident? [x] (or (keyword? x) (symbol? x)))

;; special-symbol?: stub
(defn special-symbol? [x] false)

;; ex-info/ex-message/ex-data: exception stubs
(defn ex-info [msg data] nil)
(defn ex-message [e] nil)
(defn ex-data [e] nil)

;; subs: substring (builtin, 3-arity: s start end)
;; For 2-arity, use: (subs s start (count s))

;; to-array: stub
(defn to-array [coll] coll)

;; reversible?: stub
(defn reversible? [coll] false)

;; rseq: reverse sequence (stub using reverse)
(defn rseq [coll] (reverse (seq coll)))

;; take-nth: take every nth item, or return transducer
(defn take-nth
  ([n]
   (fn [rf]
     (let [ia (atom 1)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (let [i (deref ia)]
            (reset! ia (inc i))
            (if (zero? (rem i n))
              (rf result input)
              result)))))))
  ([n coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (cons (first s) (take-nth n (drop n s)))))))

;; compare is now a builtin (native WASM $compare function)

;; sort-by: sort by key function with optional comparator
(defn sort-by
  ([keyfn coll] (sort-with-cmp (fn [a b] (compare (keyfn a) (keyfn b))) coll))
  ([keyfn cmp coll]
   (sort-with-cmp (fn [a b] (cmp (keyfn a) (keyfn b))) coll)))

;; group-by: group elements by function
(defn group-by [f coll]
  (persistent!
   (reduce
    (fn [m x]
      (let [k (f x)]
        (assoc! m k (conj (get m k []) x))))
    (transient {})
    coll)))

;; frequencies: count occurrences
(defn frequencies [coll]
  (persistent!
   (reduce
    (fn [m x]
      (assoc! m x (inc (get m x 0))))
    (transient {})
    coll)))

;; iterate: defined above with lazy-seq

;; realized?: check if lazy-seq or delay has been realized
(defn realized? [x]
  (if (lazy-seq? x)
    (lazy-seq-realized? x)
    true))

;; numerator/denominator: ratio stubs
(defn numerator [r] r)
(defn denominator [r] 1)

;; rationalize: stub
(defn rationalize [x] x)

;; byte/short/int/long/float/double: coercion
(defn byte [x] x)
(defn short [x] x)
(defn int [x] (to-int x))
(defn long [x] (to-int x))
(defn float [x] (to-float x))
(defn double [x] (to-float x))

;; char: builtin - converts integer char code to single-character string

;; bigint/bigdec: stubs
(defn bigint [x] x)
(defn bigdec [x] x)

;; decimal?: stub
(defn decimal? [x] false)

;; uuid?: stub
(defn uuid? [x] false)

;; var?: stub
(defn var? [x] false)

;; some-fn: returns a fn that returns first truthy result
(defn some-fn
  ([f]
   (fn
     ([x] (f x))
     ([x y] (or (f x) (f y)))
     ([x y z] (or (f x) (f y) (f z)))))
  ([f g]
   (fn
     ([x] (or (f x) (g x)))
     ([x y] (or (f x) (f y) (g x) (g y)))
     ([x y z] (or (f x) (f y) (f z) (g x) (g y) (g z)))))
  ([f g h]
   (fn
     ([x] (or (f x) (g x) (h x)))
     ([x y] (or (f x) (f y) (g x) (g y) (h x) (h y)))
     ([x y z] (or (f x) (f y) (f z) (g x) (g y) (g z) (h x) (h y) (h z)))))
  ([f g h i]
   (fn
     ([x] (or (f x) (g x) (h x) (i x)))
     ([x y] (or (f x) (f y) (g x) (g y) (h x) (h y) (i x) (i y)))
     ([x y z] (or (f x) (f y) (f z) (g x) (g y) (g z) (h x) (h y) (h z) (i x) (i y) (i z))))))

;; every-pred: returns a fn that returns true if all preds are truthy
(defn every-pred
  ([f]
   (fn
     ([x] (and (f x) true))
     ([x y] (and (f x) (f y)))
     ([x y z] (and (f x) (f y) (f z)))))
  ([f g]
   (fn
     ([x] (and (f x) (g x)))
     ([x y] (and (f x) (f y) (g x) (g y)))
     ([x y z] (and (f x) (f y) (f z) (g x) (g y) (g z)))))
  ([f g h]
   (fn
     ([x] (and (f x) (g x) (h x)))
     ([x y] (and (f x) (f y) (g x) (g y) (h x) (h y)))
     ([x y z] (and (f x) (f y) (f z) (g x) (g y) (g z) (h x) (h y) (h z))))))

;; promise/deliver: stubs
(defn promise [] (atom nil))
(defn deliver [p val] (reset! p val))

;; reduced/reduced? are now builtins for early termination in reduce
;; ensure-reduced/unreduced: stubs (use builtins for core functionality)
(defn ensure-reduced [x]
  (if (reduced? x) x (reduced x)))
(defn unreduced [x]
  (if (reduced? x)
    ;; Need to unwrap - but the builtin deref_reduced handles this internally
    ;; For now, just return x since reduced values get auto-unwrapped by reduce
    x
    x))

;; bit operations - bit-and, bit-or, bit-xor, bit-not, bit-shift-left,
;; bit-shift-right, unsigned-bit-shift-right, bit-test are now builtins
;; (native WASM i32 instructions)
(defn bit-and-not [a b] (bit-and a (bit-not b)))
(defn bit-clear [a b] (bit-and a (bit-not (bit-shift-left 1 b))))
(defn bit-flip [a b] (bit-xor a (bit-shift-left 1 b)))
(defn bit-set [a b] (bit-or a (bit-shift-left 1 b)))

;; clojure.test stubs
(defn run-tests [] 0)
(defmacro use-fixtures [type & fns] nil)  ;; no-op for woj

;; print functions (no-op in woj for now, except pr-str which is real)
(defn print [x] nil)
(defn println [x] nil)
(defn pr [x] nil)
(defn prn [x] nil)
(defn print-str [x] nil)
(defn println-str
  ([] "\n")
  ([x] (str (pr-str1 x) "\n"))
  ([x & more] (str (reduce (fn [acc v] (str-concat acc (str-concat " " (pr-str1 v)))) (pr-str1 x) more) "\n")))
(defn pr-str
  ([] "")
  ([x] (pr-str1 x))
  ([x & more] (reduce (fn [acc v] (str-concat acc (str-concat " " (pr-str1 v)))) (pr-str1 x) more)))
(defn prn-str
  ([] "\n")
  ([x] (str (pr-str1 x) "\n"))
  ([x & more] (str (reduce (fn [acc v] (str-concat acc (str-concat " " (pr-str1 v)))) (pr-str1 x) more) "\n")))

(defn print-str
  ([] "")
  ([x] (str1 x))
  ([x & more] (reduce (fn [acc v] (str-concat acc (str-concat " " (str1 v)))) (str1 x) more)))

;; Printing to stdout via WASI fd_write
(defn print
  ([] nil)
  ([x] (print! x))
  ([x & more]
   (print! x)
   (loop [s more]
     (when (not (nil? s))
       (print-str! " ")
       (print! (first s))
       (recur (rest s))))))

(defn println
  ([] (print-str! "\n"))
  ([x] (print! x) (print-str! "\n"))
  ([x & more]
   (print! x)
   (loop [s more]
     (when (not (nil? s))
       (print-str! " ")
       (print! (first s))
       (recur (rest s))))
   (print-str! "\n")))

(defn pr
  ([] nil)
  ([x] (pr! x))
  ([x & more]
   (pr! x)
   (loop [s more]
     (when (not (nil? s))
       (print-str! " ")
       (pr! (first s))
       (recur (rest s))))))

(defn prn
  ([] (print-str! "\n"))
  ([x] (pr! x) (print-str! "\n"))
  ([x & more]
   (pr! x)
   (loop [s more]
     (when (not (nil? s))
       (print-str! " ")
       (pr! (first s))
       (recur (rest s))))
   (print-str! "\n")))

;; with-out-str: stub macro
(defmacro with-out-str [& body]
  `(do ~@body nil))

;; with-precision: stub macro
(defmacro with-precision [precision & body]
  `(do ~@body))

;; case: match expr against constant test values
(defmacro case [expr & clauses]
  ;; Test values are compile-time constants (not evaluated)
  (let [pairs (partition 2 clauses)
        default (when (odd? (count clauses)) (last clauses))
        expr-sym (gensym "expr__")]
    `(let [~expr-sym ~expr]
       (cond
         ~@(mapcat (fn [[test result]]
                     ;; Handle multiple test values: (case x (a b c) result)
                     (if (and (seq? test) (not (= (first test) 'quote)))
                       ;; Multiple values - use 'or' of equality tests
                       [`(or ~@(map (fn [t] `(= ~expr-sym '~t)) test)) result]
                       ;; Single value - quote it
                       [`(= ~expr-sym '~test) result]))
                   pairs)
         :else ~default))))

;; condp: match expr using binary predicate
;; (condp pred expr test1 result1 test2 :>> result-fn default)
(defmacro condp [pred expr & clauses]
  (let [expr-sym (gensym "expr__")
        pred-sym (gensym "pred__")]
    (letfn [(process [clauses]
              (cond
                ;; No clauses left and no default - throw would be ideal, return nil for now
                (empty? clauses)
                nil

                ;; Single clause = default expression
                (= (count clauses) 1)
                (first clauses)

                ;; :>> form: (test :>> result-fn rest...)
                (and (>= (count clauses) 3)
                     (= (second clauses) :>>))
                (let [test (first clauses)
                      result-fn (nth clauses 2)
                      rest-clauses (drop 3 clauses)
                      temp (gensym "temp__")]
                  `(~'let [~temp (~pred-sym ~test ~expr-sym)]
                          (~'if ~temp
                                (~result-fn ~temp)
                                ~(process rest-clauses))))

                ;; Normal clause: (test result rest...)
                :else
                (let [test (first clauses)
                      result (second clauses)
                      rest-clauses (drop 2 clauses)]
                  `(~'if (~pred-sym ~test ~expr-sym)
                         ~result
                         ~(process rest-clauses)))))]
      `(~'let [~expr-sym ~expr
               ~pred-sym ~pred]
              ~(process clauses)))))

;; doseq: iterate for side effects (supports multiple bindings, :when, :let, :while)
(defmacro doseq [bindings & body]
  (if (empty? bindings)
    `(do ~@body nil)
    (let [first-elem (first bindings)]
      (cond
        ;; :when filter — skip this iteration if pred is false, but continue loop
        (= first-elem :when)
        (let [pred (second bindings)
              rest-bindings (drop 2 bindings)]
          `(when ~pred
             (doseq ~(vec rest-bindings) ~@body)))

        ;; :let introduces locals
        (= first-elem :let)
        (let [let-bindings (second bindings)
              rest-bindings (drop 2 bindings)]
          `(let ~let-bindings
             (doseq ~(vec rest-bindings) ~@body)))

        ;; :while for early termination — stop the enclosing loop entirely when false
        ;; We set a sentinel that the loop checks before recurring
        (= first-elem :while)
        (let [pred (second bindings)
              rest-bindings (drop 2 bindings)
              done (gensym "done__")]
          `(if ~pred
             (doseq ~(vec rest-bindings) ~@body)
             :doseq-while-stop))

        ;; Regular binding pair
        :else
        (let [binding first-elem
              coll (second bindings)
              rest-bindings (drop 2 bindings)
              remaining (gensym "remaining__")]
          ;; Check if any :while appears in rest-bindings — if so, we need to
          ;; check its result to decide whether to continue recurring
          (if (some #{:while} rest-bindings)
            (let [result (gensym "result__")]
              `(loop [~remaining (seq ~coll)]
                 (when ~remaining
                   (let [~binding (first ~remaining)
                         ~result (doseq ~(vec rest-bindings) ~@body)]
                     (when (not= ~result :doseq-while-stop)
                       (recur (next ~remaining)))))))
            `(loop [~remaining (seq ~coll)]
               (when ~remaining
                 (let [~binding (first ~remaining)]
                   (doseq ~(vec rest-bindings) ~@body)
                   (recur (next ~remaining)))))))))))


;; for: list comprehension (supports multiple bindings, :let, :when, :while)
(defmacro for [bindings body]
  (letfn [(process [bindings]
            (cond
              ;; No more bindings - emit the body wrapped in a list
              (empty? bindings)
              `(~'list ~body)

              ;; :let introduces local bindings
              (= (first bindings) :let)
              (let [let-bindings (second bindings)
                    rest-bindings (drop 2 bindings)]
                `(~'let ~let-bindings ~(process rest-bindings)))

              ;; :when filters
              (= (first bindings) :when)
              (let [pred (second bindings)
                    rest-bindings (drop 2 bindings)]
                `(~'if ~pred ~(process rest-bindings) nil))

              ;; :while stops iteration
              (= (first bindings) :while)
              (let [pred (second bindings)
                    rest-bindings (drop 2 bindings)]
                `(~'if ~pred ~(process rest-bindings) nil))

              ;; Regular binding pair: [x coll]
              :else
              (let [binding (first bindings)
                    coll (second bindings)
                    rest-bindings (drop 2 bindings)]
                `(~'mapcat (~'fn [~binding] ~(process rest-bindings)) ~coll))))]
    (process bindings)))

;; bound-fn/bound-fn*: stubs (no var bindings in woj)
(defmacro bound-fn [& fntail]
  `(fn ~@fntail))

(defmacro bound-fn* [f]
  f)

;; binding: stub (just runs body, no dynamic binding)
(defmacro binding [bindings & body]
  `(do ~@body))

;; defprotocol: stub that defines placeholder methods
;; In woj, protocol methods just become regular functions that throw/return nil
(defmacro defprotocol [name & sigs]
  (let [;; Filter to only method signatures (skip docstrings)
        method-sigs (filter #(and (list? %) (symbol? (first %))) sigs)
        ;; Generate stub functions for each method
        method-defs (for [sig method-sigs
                          :let [method-name (first sig)
                                params (second sig)
                               ;; Create a function that just returns nil
                                arity (count params)]]
                      `(defn ~method-name ~params nil))]
    `(do ~@method-defs)))

;; reify: stub
(defmacro reify [& body]
  nil)

;; aclone/amap/areduce: array stubs
(defn aclone [arr] arr)

;; tap>/add-tap/remove-tap: stub
(defn tap> [x] nil)
(defn add-tap [f] nil)
(defn remove-tap [f] nil)

;; ============================================
;; Test Portability Helpers (r/ and p/ prefixed)
;; ============================================

;; These are used by the clojure-test-suite for cross-dialect testing
;; We provide them in the main namespace since woj doesn't have requires

;; Integer range constants (32-bit for woj/wasm)
(def max-int 2147483647)
(def min-int -2147483648)
(def all-ones-int -1)

;; Float range constants
(def max-double 1.7976931348623157E308)
(def min-double 4.9E-324)

;; ifn?: check if callable (stub - checks fn?)
(defn ifn? [x] (fn? x))

;; instance? - will be a special form when deftype is implemented

;; throw: stub (does nothing)
(defn throw [e] nil)

;; peek/pop: collection operations
(defn peek [coll]
  (cond
    (vector? coll) (if (> (count coll) 0) (nth coll (dec (count coll))) nil)
    (cons? coll) (first coll)
    :else nil))

(defn pop [coll]
  (cond
    (vector? coll) (if (> (count coll) 0) (subvec coll 0 (dec (count coll))) [])
    (cons? coll) (rest coll)
    :else nil))

;; pop! is now a builtin

;; quot: truncated integer division (truncates toward zero)
(defn quot [n d]
  (if (and (integer? n) (integer? d))
    (/ n d)
    (int (/ n d))))

;; repeatedly: defined above with lazy-seq

;; parse-* functions: stubs
(defn parse-boolean [s] false)
(defn parse-double [s] 0.0)
(defn parse-long [s] 0)
(defn parse-uuid [s] nil)

(defn rand-int [n] (to-int (* (Math/random) (to-float n))))

;; pos-int?/neg-int?/nat-int?: integer predicates
(defn pos-int? [x] (and (integer? x) (pos? x)))
(defn neg-int? [x] (and (integer? x) (neg? x)))
(defn nat-int? [x] (and (integer? x) (>= x 0)))

;; transduce: apply transducer xform to reducing function f, then reduce over coll
(defn transduce [xform f init coll]
  (let [xf (xform f)
        result (reduce xf init coll)]
    (xf-complete xf result)))

;; sequence: eagerly apply transducer, return seq
(defn sequence
  ([coll] (seq coll))
  ([xform coll]
   (let [xf (xform conj)
         result (reduce xf [] coll)]
     (seq (xf-complete xf result)))))

;; eduction: like sequence but re-evaluates each time (returns reducible)
(defn eduction [xform coll]
  (let [xf (xform conj)
        result (reduce xf [] coll)]
    (seq (xf-complete xf result))))

;; defrecord: stub macro (creates a map constructor)
(defmacro defrecord [name fields & body]
  `(defn ~(symbol (str "->" (clojure.core/name name))) [~@fields]
     (hash-map ~@(mapcat (fn [f] [(keyword (clojure.core/name f)) f]) fields))))


;; Additional stubs for test compatibility

;; Special symbols used in special-symbol? tests
;; These need to be defined so (are [arg] ... &) works
(def & '&)
(def case* 'case*)
(def new 'new)
(def . '.)
(def catch 'catch)
(def deftype* 'deftype*)
(def finally 'finally)
(def fn* 'fn*)
(def let* 'let*)
(def letfn* 'letfn*)
(def loop* 'loop*)
(def throw 'throw)
(def try 'try)
(def var 'var)

;; Dynamic vars used in tests (stubs)
(def *assert* true)

;; full-width-checker-pos: test helper (stub returning nil)
(def full-width-checker-pos nil)

;; int-array/object-array: stubs
(defn int-array [n] [])
(defn object-array [n] [])

;; aset/aget: array operations (stubs)
(defn aset [arr idx val] nil)
(defn aget [arr idx] nil)

;; future: stub (just evaluates body)
(defmacro future [& body]
  `(do ~@body))

;; var: stub
(defmacro var [sym]
  nil)

;; try/catch/finally and throw are now real special forms in the compiler
;; ex-info, ex-data, ex-message, ex-cause are builtins

;; nnext/nfirst: sequence operations
(defn nnext [coll] (next (next coll)))
(defn nfirst [coll] (first (first coll)))

;; keyword function: convert to keyword (stub)
(defn keyword-fn [x] x)  ;; Can't shadow keyword literal

;; intern: stub
(defn intern
  ([ns name] nil)
  ([ns name val] nil))

;; inc'/dec': promoted arithmetic (same as inc/dec in woj)
(defn inc' [n] (inc n))
(defn dec' [n] (dec n))

;; identical?: reference equality (stub - use =)
(defn identical? [a b] (= a b))

;; format: stub
(defn format [fmt & args] nil)

;; fnil: function that replaces nil args with defaults
(defn fnil
  ([f d1]
   (fn
     ([x] (f (if (nil? x) d1 x)))
     ([x y] (f (if (nil? x) d1 x) y))
     ([x y z] (f (if (nil? x) d1 x) y z))))
  ([f d1 d2]
   (fn
     ([x y] (f (if (nil? x) d1 x) (if (nil? y) d2 y)))
     ([x y z] (f (if (nil? x) d1 x) (if (nil? y) d2 y) z))))
  ([f d1 d2 d3]
   (fn
     ([x y z] (f (if (nil? x) d1 x) (if (nil? y) d2 y) (if (nil? z) d3 z)))
     ([x y z w] (f (if (nil? x) d1 x) (if (nil? y) d2 y) (if (nil? z) d3 z) w)))))


;; random-sample/rand-nth
(defn random-sample
  ([prob] (filter (fn [_] (< (Math/random) prob))))
  ([prob coll] (filter (fn [_] (< (Math/random) prob)) coll)))
(defn rand-nth [coll]
  (let [v (vec coll)]
    (nth v (rand-int (count v)))))

;; full-width-checker-neg: test helper
(def full-width-checker-neg nil)

;; defmulti/defmethod: stubs
;; defmulti and defmethod are handled by the analyzer directly
;; (no macro stubs needed)

;; alter-var-root: stub
(defn alter-var-root [v f] nil)

;; var-get: stub
(defn var-get [v] nil)


;; long-array: stub
(defn long-array [n] [])

;; fnext: next of first
(defn fnext [coll] (first (next coll)))

;; delay/force: stubs
;; delay: deferred computation with memoization
;; Returns a function that caches its result on first call
(defmacro delay [& body]
  `(let [result# (atom nil)
         done# (atom false)]
     (fn []
       (when (not @done#)
         (reset! result# (do ~@body))
         (reset! done# true))
       @result#)))

(defn force [x]
  (if (fn? x) (x) x))

;; lazy-cat: lazily concatenate sequences
(defmacro lazy-cat [& colls]
  (if (empty? colls)
    nil
    (if (= (count colls) 1)
      `(lazy-seq ~(first colls))
      `(lazy-seq (concat ~(first colls) (lazy-cat ~@(rest colls)))))))

;; assert: stub (just evaluate expression)
(defmacro assert [expr & msg]
  (let [msg-expr (if (seq msg)
                   (first msg)
                   (str "Assert failed: " (pr-str expr)))]
    `(~'when (~'not ~expr)
       (~'throw (~'ex-info ~msg-expr {})))))

;; doto: evaluate expr, then call forms with expr as first arg, return expr
(defmacro doto [expr & forms]
  (let [g (gensym "doto__")]
    `(~'let [~g ~expr]
       ~@(map (fn [f]
                (if (seq? f)
                  (concat (list (first f) g) (rest f))
                  (list f g)))
              forms)
       ~g)))

;; alength: array length (stub)
(defn alength [arr] (count arr))

;; ref: reference type (stub using atom)
(defn ref [x] (atom x))
(defn dosync [& body] nil)
(defn ref-set [r v] (reset! r v))
(defn alter [r f] (swap! r f))
(defn commute [r f] (swap! r f))

;; sleep: stub (no effect in wasm)
(defn sleep [ms] nil)

;; double-array: stub
(defn double-array [n] [])

;; create-ns: stub
(defn create-ns [sym] nil)

;; +'/*/: promoted arithmetic (same as regular in woj)
(defn +' [a b] (+ a b))
(defn *' [a b] (* a b))
(defn -' [a b] (- a b))

;; agent: stub using atom
(defn agent [state] (atom state))
(defn send [a f] (swap! a f))
(defn send-off [a f] (swap! a f))
(defn await [a] nil)

;; future-cancel/future-done?/future-cancelled?: stubs
(defn future-cancel [f] false)
(defn future-done? [f] true)
(defn future-cancelled? [f] false)

;; float-array: stub
(defn float-array [n] [])

;; Java interop stubs - just return nil/false
;; Note: these won't actually work but allow tests to compile

;; definterface: stub macro (Java interop)
(defmacro definterface [name & body]
  `nil)

;; agent-error: stub
(defn agent-error [a] nil)

(defn rand
  ([] (Math/random))
  ([n] (* (Math/random) (to-float n))))

;; random-uuid: stub
(defn random-uuid [] nil)

;; restart-agent: stub
(defn restart-agent [a options] a)

;; ============================================
;; Java Interop Stubs
;; ============================================
;; These allow tests referencing Java classes to compile

(def Object nil)
(def String nil)
(def clojure.lang.BigInt nil)
(def clojure.lang.MapEntry nil)
(def clojure.lang.MapEntry/create nil)
(def clojure.lang.IPending nil)
(def clojure.lang.IReduce nil)
(def UP nil)
(def HALF_UP nil)
(def CEILING nil)
(def FLOOR nil)

;; list as a function (for passing to higher-order functions)
;; Note: only supports 1-arity since woj doesn't have varargs
(defn list [x] (cons x nil))

;; list*: creates a list with items prepended to a sequence
(defn list*
  ([coll] (seq coll))
  ([a coll] (cons a (seq coll)))
  ([a b & more]
   (cons a (cons b (apply list* more)))))

;; keyword is a builtin that creates/looks up keywords from strings

;; split: string split stub
(defn split [s re] nil)

;; ============================================
;; Additional Java interop stubs
;; ============================================

;; into-array: convert to Java array (returns collection in woj)
;; Note: woj only supports single arity, this takes [type coll] form
(defn into-array [type-or-coll coll-or-nil]
  (if (nil? coll-or-nil) type-or-coll coll-or-nil))

;; make-array: create native array (woj builtin takes 1 arg: size)
(defn make-array [size] [])

;; class stub
(defn class [x] nil)

;; bases stub
(defn bases [x] nil)

;; satisfies? stub
(defn satisfies? [protocol x] false)

;; == : numeric equality (cross-type coercion via f64)
(defn == [a b]
  (if (and (integer? a) (integer? b))
    (= a b)
    (= (to-float a) (to-float b))))

;; ============================================
;; Sorted Collections (Phase 11)
;; ============================================

;; Binary search in a sorted vector of [key value] pairs
;; Returns the index where the key should be inserted
(defn sorted-bsearch [entries k cmp]
  (loop [lo 0 hi (count entries)]
    (if (>= lo hi)
      lo
      (let [mid (/ (+ lo hi) 2)
            mk (first (nth entries mid))
            c (cmp mk k)]
        (if (zero? c)
          mid  ;; exact match
          (if (neg? c)
            (recur (inc mid) hi)
            (recur lo mid)))))))

;; SortedMap type: comparator + sorted vector of [key value] pairs
(deftype SortedMap [comparator entries])

;; Sorted map operations
(defn sorted-map-get [sm k]
  (let [entries (.-entries sm)
        cmp (.-comparator sm)
        idx (sorted-bsearch entries k cmp)]
    (if (and (< idx (count entries))
             (zero? (cmp (first (nth entries idx)) k)))
      (second (nth entries idx))
      nil)))

(defn sorted-map-get-default [sm k default]
  (let [entries (.-entries sm)
        cmp (.-comparator sm)
        idx (sorted-bsearch entries k cmp)]
    (if (and (< idx (count entries))
             (zero? (cmp (first (nth entries idx)) k)))
      (second (nth entries idx))
      default)))

(defn sorted-map-assoc [sm k v]
  (let [entries (.-entries sm)
        cmp (.-comparator sm)
        idx (sorted-bsearch entries k cmp)]
    (if (and (< idx (count entries))
             (zero? (cmp (first (nth entries idx)) k)))
      ;; Replace existing
      (->SortedMap cmp (assoc entries idx [k v]))
      ;; Insert new
      (let [before (vec (take idx entries))
            after (vec (drop idx entries))]
        (->SortedMap cmp (into (conj before [k v]) after))))))

(defn sorted-map-dissoc [sm k]
  (let [entries (.-entries sm)
        cmp (.-comparator sm)
        idx (sorted-bsearch entries k cmp)]
    (if (and (< idx (count entries))
             (zero? (cmp (first (nth entries idx)) k)))
      (let [before (vec (take idx entries))
            after (vec (drop (inc idx) entries))]
        (->SortedMap cmp (into before after)))
      sm)))

(defn sorted-map-contains? [sm k]
  (let [entries (.-entries sm)
        cmp (.-comparator sm)
        idx (sorted-bsearch entries k cmp)]
    (and (< idx (count entries))
         (zero? (cmp (first (nth entries idx)) k)))))

(defn sorted-map-seq [sm]
  (let [entries (.-entries sm)]
    (if (zero? (count entries))
      nil
      (seq entries))))

(defn sorted-map-count [sm]
  (count (.-entries sm)))

;; Extend protocols for SortedMap
(extend-type SortedMap
  ISeqable (-seq [coll] (sorted-map-seq coll))
  ICounted (-count [coll] (sorted-map-count coll))
  ILookup (-lookup [coll key] (sorted-map-get coll key))
  IAssociative (-assoc [coll key val] (sorted-map-assoc coll key val))
  ICollection (-conj [coll val]
    (if (vector? val)
      (sorted-map-assoc coll (first val) (second val))
      coll)))

;; SortedSet type: comparator + sorted vector of elements
(deftype SortedSet [comparator elements])

(defn sorted-set-bsearch [elements k cmp]
  (loop [lo 0 hi (count elements)]
    (if (>= lo hi)
      lo
      (let [mid (/ (+ lo hi) 2)
            mk (nth elements mid)
            c (cmp mk k)]
        (if (zero? c)
          mid
          (if (neg? c)
            (recur (inc mid) hi)
            (recur lo mid)))))))

(defn sorted-set-contains? [ss k]
  (let [elements (.-elements ss)
        cmp (.-comparator ss)
        idx (sorted-set-bsearch elements k cmp)]
    (and (< idx (count elements))
         (zero? (cmp (nth elements idx) k)))))

(defn sorted-set-conj [ss k]
  (let [elements (.-elements ss)
        cmp (.-comparator ss)
        idx (sorted-set-bsearch elements k cmp)]
    (if (and (< idx (count elements))
             (zero? (cmp (nth elements idx) k)))
      ss  ;; already present
      (let [before (vec (take idx elements))
            after (vec (drop idx elements))]
        (->SortedSet cmp (into (conj before k) after))))))

(defn sorted-set-disj [ss k]
  (let [elements (.-elements ss)
        cmp (.-comparator ss)
        idx (sorted-set-bsearch elements k cmp)]
    (if (and (< idx (count elements))
             (zero? (cmp (nth elements idx) k)))
      (let [before (vec (take idx elements))
            after (vec (drop (inc idx) elements))]
        (->SortedSet cmp (into before after)))
      ss)))

(defn sorted-set-seq [ss]
  (let [elements (.-elements ss)]
    (if (zero? (count elements))
      nil
      (seq elements))))

(defn sorted-set-count [ss]
  (count (.-elements ss)))

;; Extend protocols for SortedSet
(extend-type SortedSet
  ISeqable (-seq [coll] (sorted-set-seq coll))
  ICounted (-count [coll] (sorted-set-count coll))
  ICollection (-conj [coll val] (sorted-set-conj coll val)))

;; Constructors
(defn sorted-map-by [cmp & keyvals]
  (loop [sm (->SortedMap cmp [])
         kvs (seq keyvals)]
    (if (nil? kvs)
      sm
      (let [k (first kvs)
            v (second kvs)]
        (recur (sorted-map-assoc sm k v) (next (next kvs)))))))

(defn sorted-map [& keyvals]
  (loop [sm (->SortedMap compare [])
         kvs (seq keyvals)]
    (if (nil? kvs)
      sm
      (let [k (first kvs)
            v (second kvs)]
        (recur (sorted-map-assoc sm k v) (next (next kvs)))))))

(defn sorted-set-by [cmp & vals]
  (reduce sorted-set-conj (->SortedSet cmp []) vals))

(defn sorted-set [& vals]
  (reduce sorted-set-conj (->SortedSet compare []) vals))

;; sorted?: check if value is a sorted collection
(defn sorted? [x]
  (or (instance? SortedMap x)
      (instance? SortedSet x)))

;; subseq/rsubseq: get subsequences of sorted collections
(defn subseq
  ([sc test key]
   (let [s (seq sc)]
     (filter (fn [entry]
               (let [k (if (instance? SortedMap sc) (first entry) entry)]
                 (test k key)))
             s)))
  ([sc start-test start-key end-test end-key]
   (let [s (seq sc)]
     (filter (fn [entry]
               (let [k (if (instance? SortedMap sc) (first entry) entry)]
                 (and (start-test k start-key) (end-test k end-key))))
             s))))

(defn rsubseq
  ([sc test key]
   (reverse (subseq sc test key)))
  ([sc start-test start-key end-test end-key]
   (reverse (subseq sc start-test start-key end-test end-key))))

(defn vec-index-of
  "Returns the index of item in coll, or -1 if not found."
  [coll item]
  (let [n (count coll)]
    (loop [i 0]
      (if (< i n)
        (if (= (nth coll i) item)
          i
          (recur (+ i 1)))
        -1))))

(defn- digit-value
  "Returns the numeric value of a character string for the given radix, or -1 if invalid."
  [c radix]
  (let [cp (codepoint-at c 0)
        v (cond
            (and (>= cp 48) (<= cp 57)) (- cp 48)   ;; 0-9
            (and (>= cp 65) (<= cp 90)) (+ 10 (- cp 65)) ;; A-Z
            (and (>= cp 97) (<= cp 122)) (+ 10 (- cp 97)) ;; a-z
            :else -1)]
    (if (and (>= v 0) (< v radix)) v -1)))

(defn parse-int
  "Parse a string to an integer. With radix, supports any base 2-36.
   Returns nil if the string is not a valid integer."
  ([s] (parse-int s 10))
  ([s radix]
   (let [len (count s)]
     (when (> len 0)
       (let [neg (= (nth s 0) "-")
             start (if neg 1 0)
             start (if (and (< start len) (= (nth s start) "+")) (+ start 1) start)
             ;; Handle 0x, 0X prefix for hex
             has-hex-prefix (if (and (= radix 16) (>= (- len start) 2))
                              (if (= (nth s start) "0")
                                (let [c1 (nth s (+ start 1))]
                                  (or (= c1 "x") (= c1 "X")))
                                false)
                              false)
             start (if has-hex-prefix (+ start 2) start)]
         (when (< start len)
           (loop [i start acc 0]
             (if (< i len)
               (let [d (digit-value (nth s i) radix)]
                 (when (>= d 0)
                   (if (> (* (to-float acc) (to-float radix)) 1073741823.0) nil (recur (+ i 1) (+ (* acc radix) d)))))
               (if neg (- 0 acc) acc)))))))))

(defn- parse-exponent
  "Parse an exponent suffix starting at position j in string s of length len.
   Returns the exponent multiplied into base, or base if no exponent."
  [s len j base neg]
  (if (< j len)
    (let [c (nth s j)]
      (if (or (= c "e") (= c "E"))
        (let [j2 (+ j 1)
              e-neg (if (< j2 len) (= (nth s j2) "-") false)
              e-plus (if (< j2 len) (= (nth s j2) "+") false)
              j3 (if (or e-neg e-plus) (+ j2 1) j2)]
          (loop [k j3 exp 0]
            (if (< k len)
              (let [d (digit-value (nth s k) 10)]
                (when (>= d 0)
                  (recur (+ k 1) (+ (* exp 10) d))))
              (let [exp-val (if e-neg (- 0 exp) exp)
                    abs-exp (if (< exp-val 0) (- 0 exp-val) exp-val)
                    ;; Apply exponent by repeated multiply/divide to avoid overflow
                    ;; (e.g. 10^324 overflows f64, but 4.9 * 10^-324 = 5e-324 is valid)
                    result (loop [p 0 r base]
                             (if (< p abs-exp)
                               (recur (+ p 1) (if (< exp-val 0) (/ r 10.0) (* r 10.0)))
                               r))]
                (if neg (- 0.0 result) result)))))
        (if neg (- 0.0 base) base)))
    (if neg (- 0.0 base) base)))

(defn parse-float
  "Parse a string to a float. Returns nil if the string is not a valid number."
  [s]
  (let [len (count s)]
    (when (> len 0)
      (let [neg (= (nth s 0) "-")
            start (if neg 1 0)
            start (if (and (< start len) (= (nth s start) "+")) (+ start 1) start)]
        (when (< start len)
          ;; Parse integer part
          (loop [i start int-acc 0 has-digit false]
            (if (< i len)
              (let [c (nth s i)]
                (if (or (= c ".") (or (= c "e") (= c "E")))
                  ;; Done with integer part
                  (if (= c ".")
                    ;; Parse fractional part
                    (loop [j (+ i 1) frac 0.0 scale 0.1]
                      (if (< j len)
                        (let [fc (nth s j)]
                          (if (or (= fc "e") (= fc "E"))
                            (parse-exponent s len j (+ (double int-acc) frac) neg)
                            (let [d (digit-value fc 10)]
                              (when (>= d 0)
                                (recur (+ j 1) (+ frac (* (double d) scale)) (* scale 0.1))))))
                        (let [result (+ (double int-acc) frac)]
                          (if neg (- 0.0 result) result))))
                    ;; Exponent on integer
                    (parse-exponent s len i (double int-acc) neg))
                  ;; Still parsing integer digits
                  (let [d (digit-value c 10)]
                    (when (>= d 0)
                      (if (> (* (to-float int-acc) 10.0) 1073741823.0) (recur (+ i 1) (+ (* (to-float int-acc) 10.0) (to-float d)) true) (recur (+ i 1) (+ (* int-acc 10) d) true))))))
              ;; End of string, no dot or exponent — return as float
              (when has-digit
                (if neg (- 0.0 (double int-acc)) (double int-acc))))))))))

