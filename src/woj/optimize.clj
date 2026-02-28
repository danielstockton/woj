(ns woj.optimize
  "WASM IR optimization passes.

   Operates on the IR representation from woj.wasm (vectors, seqs, etc.).
   Each pass is a function (node -> node) applied bottom-up.

   Key optimizations:
   1. Boolean-in-if: (call $truthy (if (result anyref) C (then $__true) (else $__false))) → C
   2. Box/unbox elimination: (i31.get_s (ref.cast (ref i31) (ref.i31 E))) → E
   3. Constant folding: (i32.add (i32.const 1) (i32.const 2)) → (i32.const 3)
   4. Dead drop elimination: (drop PURE) → removed
   5. Block simplification: flatten nested blocks, unwrap single-result blocks")

;; ============================================
;; Tree walker
;; ============================================

(defn walk-ir
  "Bottom-up tree walk. Applies f to each node after walking children.
   Handles all IR node types: vectors, seqs, strings, keywords, numbers, nil, {:raw s}."
  [f node]
  (cond
    (nil? node) (f nil)

    ;; Pre-serialized — opaque, don't walk
    (and (map? node) (contains? node :raw))
    (f node)

    ;; Vector S-expression — walk children, then apply f
    (vector? node)
    (f (mapv (partial walk-ir f) node))

    ;; Seq/list — walk children, then apply f
    (seq? node)
    (f (map (partial walk-ir f) node))

    ;; Leaf nodes — just apply f
    :else
    (f node)))

;; ============================================
;; Pattern matchers
;; ============================================

(defn- vec-op?
  "Check if node is a vector with the given op keyword."
  [node op]
  (and (vector? node) (>= (count node) 1) (= (first node) op)))

(defn- truthy-call?
  "Is this [:call \"$truthy\" X]?"
  [node]
  (and (vec-op? node :call) (= (count node) 3) (= (nth node 1) "$truthy")))

(defn- bool-if?
  "Is this [:if [:result :anyref] COND [:then [:global.get \"$__true\"]] [:else [:global.get \"$__false\"]]]?"
  [node]
  (and (vec-op? node :if)
       (= (count node) 5)
       (= (nth node 1) [:result :anyref])
       (= (nth node 3) [:then [:global.get "$__true"]])
       (= (nth node 4) [:else [:global.get "$__false"]])))

(defn- box?
  "Is this [:ref.i31 X]?"
  [node]
  (and (vec-op? node :ref.i31) (= (count node) 2)))

(defn- unbox?
  "Is this [:i31.get_s [:ref.cast [:ref :i31] X]]?"
  [node]
  (and (vec-op? node :i31.get_s)
       (= (count node) 2)
       (let [inner (nth node 1)]
         (and (vec-op? inner :ref.cast)
              (= (count inner) 3)
              (= (nth inner 1) [:ref :i31])))))

(defn- i32-const?
  "Is this [:i32.const N]?"
  [node]
  (and (vec-op? node :i32.const) (= (count node) 2) (number? (nth node 1))))

;; ============================================
;; Optimization passes
;; ============================================

(defn opt-bool-in-if
  "Eliminate (call $truthy (if (result anyref) C (then $__true) (else $__false))) → C.
   This is the most common pattern — every `if` test wraps its condition."
  [node]
  (if (and (truthy-call? node) (bool-if? (nth node 2)))
    ;; The condition C inside the bool-if is already an i32
    (nth (nth node 2) 2)
    node))

(defn opt-box-unbox
  "Eliminate (i31.get_s (ref.cast (ref i31) (ref.i31 E))) → E.
   Consecutive box-then-unbox cancels out."
  [node]
  (if (and (unbox? node)
           (let [cast-arg (nth (nth node 1) 2)]
             (box? cast-arg)))
    ;; Extract E from (ref.i31 E) inside the cast
    (nth (nth (nth node 1) 2) 1)
    node))

(defn opt-unbox-box
  "Eliminate (ref.i31 (i31.get_s (ref.cast (ref i31) E))) → E.
   Consecutive unbox-then-box cancels out."
  [node]
  (if (and (box? node) (unbox? (nth node 1)))
    ;; Extract E from the ref.cast
    (nth (nth (nth node 1) 1) 2)
    node))

(defn- i32-binop [op a b]
  (case op
    :i32.add (+ a b)
    :i32.sub (- a b)
    :i32.mul (* a b)
    nil))

(defn opt-constant-fold
  "Fold (i32.add (i32.const A) (i32.const B)) → (i32.const (+ A B)).
   Handles add, sub, mul."
  [node]
  (if (and (vector? node) (= (count node) 3)
           (#{:i32.add :i32.sub :i32.mul} (first node))
           (i32-const? (nth node 1))
           (i32-const? (nth node 2)))
    (let [result (i32-binop (first node) (nth (nth node 1) 1) (nth (nth node 2) 1))]
      (if result
        [:i32.const result]
        node))
    node))

(defn- pure-expr?
  "Is this a side-effect-free expression safe to eliminate?"
  [node]
  (or (nil? node)
      (string? node)
      (number? node)
      (keyword? node)
      (and (vector? node)
           (#{:i32.const :f64.const :local.get :global.get
              :ref.null :ref.i31 :i31.get_s :ref.cast} (first node)))))

(defn opt-dead-drop
  "Eliminate (drop PURE) where the expression has no side effects."
  [node]
  (if (and (vec-op? node :drop) (= (count node) 2) (pure-expr? (nth node 1)))
    nil
    node))

(defn opt-block-simplify
  "Simplify blocks:
   - (block (result anyref) EXPR) → EXPR (single-expression block)
   - Flatten nested blocks with same result type."
  [node]
  (if (and (vec-op? node :block)
           (>= (count node) 3)
           (= (nth node 1) [:result :anyref]))
    (let [body (subvec node 2)]
      ;; Single expression in block — unwrap
      (if (= (count body) 1)
        (first body)
        node))
    node))

;; ============================================
;; Combined optimizer
;; ============================================

(defn- apply-passes
  "Apply all optimization passes to a single node."
  [node]
  (-> node
      opt-bool-in-if
      opt-box-unbox
      opt-unbox-box
      opt-constant-fold
      opt-dead-drop
      opt-block-simplify))

(defn optimize
  "Run all optimization passes bottom-up over an IR tree."
  [ir]
  (walk-ir apply-passes ir))
