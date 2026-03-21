(ns woj.wat
  "WAT (WebAssembly Text Format) parser and binary assembler.
   Parses WAT S-expression text into a structured module representation,
   then encodes to WASM binary format using woj.binary.

   This replaces the external wasm-tools dependency for WAT→WASM conversion."
  (:require [woj.binary :as bin]
            [clojure.string :as str]))

;; ============================================
;; Tokenizer
;; ============================================

(defn- skip-line-comment [^String s ^long i]
  (let [len (.length s)]
    (loop [i i]
      (if (or (>= i len) (= (.charAt s i) \newline))
        (min (inc i) len)
        (recur (inc i))))))

(defn- skip-block-comment [^String s ^long i]
  (let [len (.length s)]
    (loop [i i depth 1]
      (cond
        (>= i (dec len)) len
        (and (= (.charAt s i) \() (= (.charAt s (inc i)) \;))
        (recur (+ i 2) (inc depth))
        (and (= (.charAt s i) \;) (= (.charAt s (inc i)) \)))
        (if (= depth 1) (+ i 2) (recur (+ i 2) (dec depth)))
        :else (recur (inc i) depth)))))

(defn- read-string-token [^String s ^long i]
  ;; i points at opening quote
  (let [len (.length s)
        sb (StringBuilder.)]
    (loop [i (inc i)]
      (when (>= i len) (throw (ex-info "Unterminated string" {:pos i})))
      (let [c (.charAt s i)]
        (cond
          (= c \") {:token (.toString sb) :type :string :end (inc i)}
          (= c \\)
          (let [next-c (.charAt s (inc i))]
            (case next-c
              \n (do (.append sb \newline) (recur (+ i 2)))
              \t (do (.append sb \tab) (recur (+ i 2)))
              \r (do (.append sb \return) (recur (+ i 2)))
              \\ (do (.append sb \\) (recur (+ i 2)))
              \" (do (.append sb \") (recur (+ i 2)))
              \' (do (.append sb \') (recur (+ i 2)))
              ;; Hex escape: \xx (WAT uses 2-digit hex escapes for raw bytes)
              (let [is-hex? (fn [c] (or (Character/isDigit c)
                                        (<= (int \a) (int (Character/toLowerCase c)) (int \f))))]
                (if (and (< (+ i 2) len)
                         (is-hex? next-c)
                         (is-hex? (.charAt s (+ i 2))))
                  (let [hex-str (.substring s (int (inc i)) (int (+ i 3)))
                        byte-val (Integer/parseInt hex-str 16)]
                    (.append sb (char byte-val))
                    (recur (+ i 3)))
                  ;; Unknown escape — pass through
                  (do (.append sb \\) (.append sb next-c) (recur (+ i 2)))))))
          :else (do (.append sb c) (recur (inc i))))))))

(defn- read-atom-token [^String s ^long i]
  (let [len (.length s)]
    (loop [j i]
      (if (or (>= j len)
              (let [c (.charAt s j)]
                (or (Character/isWhitespace c) (= c \() (= c \)) (= c \;))))
        {:token (.substring s (int i) (int j)) :end j}
        (recur (inc j))))))

(defn tokenize
  "Tokenize WAT source string into a vector of tokens.
   Returns [{:type :lparen|:rparen|:string|:atom, :value str} ...]"
  [^String s]
  (let [len (.length s)
        tokens (transient [])]
    (loop [i 0]
      (if (>= i len)
        (persistent! tokens)
        (let [c (.charAt s i)]
          (cond
            ;; Whitespace
            (Character/isWhitespace c)
            (recur (inc i))

            ;; Line comment
            (and (= c \;) (< (inc i) len) (= (.charAt s (inc i)) \;))
            (recur (skip-line-comment s (+ i 2)))

            ;; Block comment
            (and (= c \() (< (inc i) len) (= (.charAt s (inc i)) \;))
            (recur (skip-block-comment s (+ i 2)))

            ;; Parens
            (= c \()
            (do (conj! tokens {:type :lparen}) (recur (inc i)))
            (= c \))
            (do (conj! tokens {:type :rparen}) (recur (inc i)))

            ;; String
            (= c \")
            (let [{:keys [token end]} (read-string-token s i)]
              (conj! tokens {:type :string :value token})
              (recur (long end)))

            ;; Atom (identifier, number, keyword)
            :else
            (let [{:keys [token end]} (read-atom-token s i)]
              (conj! tokens {:type :atom :value token})
              (recur (long end)))))))))

;; ============================================
;; S-expression parser
;; ============================================

(defn parse-sexpr
  "Parse tokens into nested S-expression lists.
   Returns {:result sexpr, :rest remaining-tokens}"
  [tokens]
  (when (empty? tokens)
    (throw (ex-info "Unexpected end of input" {})))
  (let [tok (first tokens)]
    (case (:type tok)
      :lparen
      (loop [rest-tokens (next tokens)
             items (transient [])]
        (when (empty? rest-tokens)
          (throw (ex-info "Unexpected end of input (unclosed paren)" {})))
        (if (= :rparen (:type (first rest-tokens)))
          {:result (persistent! items) :rest (next rest-tokens)}
          (let [{:keys [result rest]} (parse-sexpr rest-tokens)]
            (recur rest (conj! items result)))))
      :rparen
      (throw (ex-info "Unexpected )" {}))
      ;; Atom or string
      {:result (if (= :string (:type tok))
                 {:string (:value tok)}
                 (:value tok))
       :rest (next tokens)})))

(defn parse-wat
  "Parse WAT source into an S-expression tree."
  [source]
  (:result (parse-sexpr (tokenize source))))

;; ============================================
;; S-expression utilities
;; ============================================

(defn sexpr-head
  "Get the first element (operator) of an S-expression list."
  [sexpr]
  (when (vector? sexpr) (first sexpr)))

(defn string-val [x]
  (when (map? x) (:string x)))

(defn name-ref? [s]
  (and (string? s) (.startsWith ^String s "$")))

;; ============================================
;; Module analysis - First pass: collect names
;; ============================================

(declare parse-type-use parse-val-type resolve-val-type)

(defn- parse-param-result
  "Parse (param ...) and (result ...) forms. Returns {:params [...] :results [...]}."
  [forms]
  (let [params (transient [])
        results (transient [])]
    (doseq [form forms]
      (when (vector? form)
        (case (first form)
          "param" (if (and (> (count form) 2) (name-ref? (second form)))
                   ;; Named param: (param $name type)
                   (conj! params {:name (second form) :type (nth form 2)})
                   ;; Anonymous params: (param type type ...)
                   (doseq [t (rest form)]
                     (conj! params {:type t})))
          "result" (doseq [t (rest form)]
                     (conj! results t))
          nil)))
    {:params (persistent! params) :results (persistent! results)}))

(defn- parse-type-def
  "Parse a type definition form: (type $name (sub? ...))
   Returns {:name str :def parsed-type-def}"
  [form]
  (let [name (when (name-ref? (second form)) (second form))
        body (if name (nth form 2) (second form))]
    {:name name :body body}))

(defn- parse-func-decl
  "Parse a function declaration, extracting name, export, params, results, locals, body."
  [form]
  (let [items (rest form) ;; skip 'func'
        ;; Extract name if present
        [name items] (if (name-ref? (first items))
                       [(first items) (rest items)]
                       [nil items])
        ;; Extract inline exports
        [exports items] (loop [items items exports [] remaining []]
                          (if (empty? items)
                            [exports (seq remaining)]
                            (let [item (first items)]
                              (if (and (vector? item) (= "export" (first item)))
                                (recur (rest items)
                                       (conj exports (string-val (second item)))
                                       remaining)
                                (recur (rest items) exports (conj remaining item))))))
        ;; Extract type use if present
        [type-use items] (if (and (vector? (first items)) (= "type" (first (first items))))
                           [(second (first items)) (rest items)]
                           [nil items])
        ;; Extract params, results, locals, body
        params (transient [])
        results (transient [])
        locals (transient [])
        body (transient [])]
    (doseq [item items]
      (if (vector? item)
        (case (first item)
          "param" (if (and (> (count item) 2) (name-ref? (second item)))
                    (conj! params {:name (second item) :type (nth item 2)})
                    (doseq [t (rest item)]
                      (conj! params {:type t})))
          "result" (doseq [t (rest item)]
                     (conj! results t))
          "local" (if (and (> (count item) 2) (name-ref? (second item)))
                    (conj! locals {:name (second item) :type (nth item 2)})
                    (doseq [t (rest item)]
                      (conj! locals {:type t})))
          (conj! body item))
        (conj! body item)))
    {:name name
     :exports exports
     :type-use type-use
     :params (persistent! params)
     :results (persistent! results)
     :locals (persistent! locals)
     :body (persistent! body)}))

(defn- parse-global-decl
  "Parse a global declaration: (global $name (mut type)? init-expr)
   or (global $name (export ...) (mut type)? init-expr)"
  [form]
  (let [items (rest form)
        [name items] (if (name-ref? (first items))
                       [(first items) (rest items)]
                       [nil items])
        ;; Extract inline exports
        [exports items] (loop [items items exports [] remaining []]
                          (if (empty? items)
                            [exports (seq remaining)]
                            (let [item (first items)]
                              (if (and (vector? item) (= "export" (first item)))
                                (recur (rest items)
                                       (conj exports (string-val (second item)))
                                       remaining)
                                (recur (rest items) exports (conj remaining item))))))
        ;; Type: either (mut type) or just type
        type-form (first items)
        [mutable? val-type] (if (and (vector? type-form) (= "mut" (first type-form)))
                              [true (second type-form)]
                              [false type-form])
        init-expr (rest items)]
    {:name name
     :exports exports
     :mutable? mutable?
     :type val-type
     :init (vec init-expr)}))

(defn- parse-import-decl
  "Parse an import: (import \"module\" \"name\" (func|global|memory|table $name? ...))"
  [form]
  (let [module-name (string-val (nth form 1))
        field-name (string-val (nth form 2))
        desc (nth form 3)
        kind (first desc)]
    {:module module-name
     :field field-name
     :kind kind
     :desc (rest desc)}))

(defn- parse-memory-decl
  "Parse: (memory (export \"memory\") 256) or (memory 256)"
  [form]
  (let [items (rest form)
        [exports items] (loop [items items exports [] remaining []]
                          (if (empty? items)
                            [exports (seq remaining)]
                            (let [item (first items)]
                              (if (and (vector? item) (= "export" (first item)))
                                (recur (rest items)
                                       (conj exports (string-val (second item)))
                                       remaining)
                                (recur (rest items) exports (conj remaining item))))))
        min-pages (when (first items) (Long/parseLong (first items)))
        max-pages (when (second items) (Long/parseLong (second items)))]
    {:exports exports :min min-pages :max max-pages}))

(defn- parse-data-decl
  "Parse: (data $name \"bytes...\") — passive data segment"
  [form]
  (let [items (rest form)
        [name items] (if (name-ref? (first items))
                       [(first items) (rest items)]
                       [nil items])
        ;; Data can be one or more string literals concatenated
        data-str (str/join (map #(if (map? %) (:string %) (str %)) items))]
    {:name name :data data-str}))

(defn- parse-elem-decl
  "Parse: (elem declare func $f1 $f2 ...)"
  [form]
  (let [items (rest form)]
    (if (= "declare" (first items))
      {:kind :declare
       :type (second items) ;; "func"
       :funcs (vec (drop 2 items))}
      {:kind :other :raw form})))

(defn- parse-tag-decl
  "Parse: (tag $name (param type))"
  [form]
  (let [items (rest form)
        [name items] (if (name-ref? (first items))
                       [(first items) (rest items)]
                       [nil items])
        ;; Parse param types
        param-types (mapcat (fn [item]
                              (when (and (vector? item) (= "param" (first item)))
                                (rest item)))
                            items)]
    {:name name :param-types (vec param-types)}))

(defn analyze-module
  "Parse a WAT module S-expression into a structured representation.
   Returns a map with all module components and name→index mappings."
  [module-sexpr]
  (when-not (and (vector? module-sexpr) (= "module" (first module-sexpr)))
    (throw (ex-info "Expected (module ...)" {:got (first module-sexpr)})))
  (let [forms (rest module-sexpr)
        ;; Collect all top-level forms by kind
        imports (transient [])
        types (transient [])
        funcs (transient [])
        globals (transient [])
        memories (transient [])
        datas (transient [])
        elems (transient [])
        exports (transient [])
        tags (transient [])
        start-fn (atom nil)]
    (doseq [form forms]
      (when (vector? form)
        (case (first form)
          "import" (conj! imports (parse-import-decl form))
          "type" (conj! types (parse-type-def form))
          "func" (conj! funcs (parse-func-decl form))
          "global" (conj! globals (parse-global-decl form))
          "memory" (conj! memories (parse-memory-decl form))
          "data" (conj! datas (parse-data-decl form))
          "elem" (conj! elems (parse-elem-decl form))
          "export" (conj! exports form)
          "tag" (conj! tags (parse-tag-decl form))
          "start" (reset! start-fn (second form))
          nil)))

    (let [imports (persistent! imports)
          types (persistent! types)
          funcs (persistent! funcs)
          globals (persistent! globals)
          memories (persistent! memories)
          datas (persistent! datas)
          elems (persistent! elems)
          tags (persistent! tags)

          ;; Build name→index mappings
          ;; Types: in order of declaration
          type-index (into {} (keep-indexed
                               (fn [i t] (when (:name t) [(:name t) i]))
                               types))

          ;; Functions: imports come first, then defined functions
          func-imports (filter #(= "func" (:kind %)) imports)
          import-func-names (keep-indexed
                             (fn [i imp]
                               (let [desc (:desc imp)
                                     name (when (name-ref? (first desc)) (first desc))]
                                 (when name [name i])))
                             func-imports)
          n-func-imports (count func-imports)
          defined-func-names (keep-indexed
                              (fn [i f] (when (:name f) [(:name f) (+ n-func-imports i)]))
                              funcs)
          func-index (into {} (concat import-func-names defined-func-names))

          ;; Globals: in order (no imported globals in woj)
          global-index (into {} (keep-indexed
                                 (fn [i g] (when (:name g) [(:name g) i]))
                                 globals))

          ;; Data segments: in order
          data-index (into {} (keep-indexed
                               (fn [i d] (when (:name d) [(:name d) i]))
                               datas))

          ;; Tags: in order
          tag-index (into {} (keep-indexed
                              (fn [i t] (when (:name t) [(:name t) i]))
                              tags))

          ;; Build field name→index mappings per type
          ;; Parse struct fields from type bodies
          field-indices (into {}
                              (keep
                               (fn [{:keys [name body]}]
                                 (when (and name (vector? body))
                                   (let [struct-form (cond
                                                       ;; (sub $parent (struct ...))
                                                       (= "sub" (first body))
                                                       (let [inner (last body)]
                                                         (when (and (vector? inner)
                                                                    (= "struct" (first inner)))
                                                           inner))
                                                       ;; (struct ...)
                                                       (= "struct" (first body))
                                                       body
                                                       :else nil)]
                                     (when struct-form
                                       (let [fields (rest struct-form)
                                             field-map (into {}
                                                             (keep-indexed
                                                              (fn [i field]
                                                                (when (and (vector? field)
                                                                           (= "field" (first field))
                                                                           (name-ref? (second field)))
                                                                  [(second field) i]))
                                                              fields))]
                                         (when (seq field-map)
                                           [name field-map]))))))
                               types))]

      {:imports imports
       :types types
       :funcs funcs
       :globals globals
       :memories memories
       :datas datas
       :elems elems
       :exports (persistent! exports)
       :tags tags
       :start @start-fn
       ;; Index mappings
       :type-index type-index
       :func-index func-index
       :global-index global-index
       :data-index data-index
       :tag-index tag-index
       :field-indices field-indices
       :n-func-imports n-func-imports})))

;; ============================================
;; Value type resolution
;; ============================================

(defn resolve-heap-type-str
  "Resolve a heap type string to a keyword or index."
  [ht]
  (case ht
    "func" :func
    "extern" :extern
    "any" :any
    "eq" :eq
    "i31" :i31
    "struct" :struct
    "array" :array
    "none" :none
    "nofunc" :nofunc
    "noextern" :noextern
    ;; Should not get here for named types — they should be resolved via type-index
    (throw (ex-info (str "Unknown heap type: " ht) {:ht ht}))))

(defn resolve-val-type
  "Resolve a WAT value type string to a binary val-type descriptor.
   Uses type-index for resolving named types."
  [type-str type-index]
  (cond
    (string? type-str)
    (case type-str
      "i32" :i32
      "i64" :i64
      "f32" :f32
      "f64" :f64
      "anyref" :anyref
      "funcref" :funcref
      "externref" :externref
      "i31ref" :i31ref
      "structref" :structref
      "arrayref" :arrayref
      ;; Packed types (for arrays)
      "i8" :i8
      "i16" :i16
      ;; Named type reference: $name — but as a standalone val type,
      ;; this shouldn't happen. It's usually inside (ref $name).
      (if (name-ref? type-str)
        {:ref-null (or (get type-index type-str)
                       (throw (ex-info (str "Unknown type: " type-str) {:type type-str})))}
        (throw (ex-info (str "Unknown value type: " type-str) {:type type-str}))))

    ;; Vector form: (ref $Type), (ref null $Type), (ref i31), etc.
    (vector? type-str)
    (case (first type-str)
      "ref" (let [args (rest type-str)]
              (if (= "null" (first args))
                ;; (ref null X)
                (let [ht (second args)]
                  (cond
                    (name-ref? ht) {:ref-null (get type-index ht)}
                    :else {:ref-null (resolve-heap-type-str ht)}))
                ;; (ref X)
                (let [ht (first args)]
                  (cond
                    (name-ref? ht) {:ref (get type-index ht)}
                    :else {:ref (resolve-heap-type-str ht)}))))
      "mut" (resolve-val-type (second type-str) type-index)
      (throw (ex-info (str "Unknown compound type: " type-str) {:type type-str})))

    :else (throw (ex-info (str "Cannot resolve type: " (pr-str type-str))
                          {:type type-str}))))

;; ============================================
;; Type definition encoding
;; ============================================

(defn- encode-field-from-wat
  "Encode a WAT field declaration: (field $name (mut type)) or (field $name type) or (field type)"
  [field-form type-index]
  (let [items (rest field-form) ;; skip "field"
        items (if (name-ref? (first items)) (rest items) items) ;; skip name
        type-form (first items)
        [mutable? vt-raw] (if (and (vector? type-form) (= "mut" (first type-form)))
                            [true (second type-form)]
                            [false type-form])
        vt (resolve-val-type vt-raw type-index)]
    (bin/encode-field-type vt mutable?)))

(defn- encode-type-body
  "Encode a type body (struct, array, or func) to binary."
  [body type-index]
  (cond
    ;; struct
    (and (vector? body) (= "struct" (first body)))
    (let [fields (rest body)]
      (bin/concat-bytes
       [bin/ct-struct]
       (bin/encode-unsigned-leb128 (count fields))
       (vec (mapcat #(encode-field-from-wat % type-index) fields))))

    ;; array
    (and (vector? body) (= "array" (first body)))
    (let [elem-form (second body)
          [mutable? vt-raw] (if (and (vector? elem-form) (= "mut" (first elem-form)))
                              [true (second elem-form)]
                              [false elem-form])
          vt (resolve-val-type vt-raw type-index)]
      (bin/concat-bytes [bin/ct-array] (bin/encode-field-type vt mutable?)))

    ;; func
    (and (vector? body) (= "func" (first body)))
    (let [{:keys [params results]} (parse-param-result (rest body))
          param-types (mapv #(resolve-val-type (:type %) type-index) params)
          result-types (mapv #(resolve-val-type % type-index) results)]
      (bin/encode-func-type param-types result-types))

    :else
    (throw (ex-info (str "Unknown type body: " (pr-str body)) {:body body}))))

(defn encode-type-def
  "Encode a complete type definition (possibly with sub/sub_final)."
  [{:keys [body]} type-index]
  (cond
    ;; (sub $parent (struct/array/func ...))
    (and (vector? body) (= "sub" (first body)))
    (let [items (rest body)
          ;; Collect parent references
          [parents items] (loop [items items parents []]
                            (if (name-ref? (first items))
                              (recur (rest items)
                                     (conj parents (get type-index (first items))))
                              [parents items]))
          composite (first items)
          comp-bytes (encode-type-body composite type-index)]
      (bin/concat-bytes [bin/st-sub]
                        (bin/encode-unsigned-leb128 (count parents))
                        (vec (mapcat bin/encode-unsigned-leb128 parents))
                        comp-bytes))

    ;; Direct (struct/array/func ...) — implicitly final
    (vector? body)
    (let [comp-bytes (encode-type-body body type-index)]
      ;; Final types: use sub_final with 0 parents
      (bin/concat-bytes [bin/st-sub-final]
                        (bin/encode-unsigned-leb128 0)
                        comp-bytes))

    :else
    (throw (ex-info (str "Cannot encode type def: " (pr-str body)) {:body body}))))

;; ============================================
;; Instruction encoding - second pass
;; ============================================

(declare encode-instr-sexpr)

(defn- parse-int-literal
  "Parse a WAT integer literal (decimal or hex)."
  [s]
  (let [s (str/replace s "_" "")]
    (cond
      (str/starts-with? s "0x") (Long/parseLong (subs s 2) 16)
      (str/starts-with? s "-0x") (- (Long/parseLong (subs s 3) 16))
      :else (Long/parseLong s))))

(defn- parse-float-literal
  "Parse a WAT float literal."
  [s]
  (let [s (str/replace s "_" "")]
    (case s
      "nan" Double/NaN
      "inf" Double/POSITIVE_INFINITY
      "-inf" Double/NEGATIVE_INFINITY
      (if (or (str/starts-with? s "0x") (str/starts-with? s "-0x"))
        ;; Hex float — Java supports this format
        (Double/parseDouble (str/replace s "0x" "0x"))
        (Double/parseDouble s)))))

(defn resolve-idx
  "Resolve a WAT index (name or number) to a numeric index."
  [s index-map]
  (cond
    (integer? s) s
    (name-ref? s) (or (get index-map s)
                      (throw (ex-info (str "Unresolved reference: " s)
                                      {:ref s :available (take 5 (keys index-map))})))
    (string? s) (parse-int-literal s)
    :else (throw (ex-info (str "Cannot resolve index: " (pr-str s)) {:s s}))))

(defn- resolve-block-type
  "Resolve a block type from WAT forms following block/loop/if.
   Returns [block-type-descriptor remaining-items]."
  [items type-index]
  ;; Look for (result type) or (type $idx)
  (let [first-item (first items)]
    (cond
      ;; (result type)
      (and (vector? first-item) (= "result" (first first-item)))
      (let [result-types (mapv #(resolve-val-type % type-index) (rest first-item))]
        (if (= 1 (count result-types))
          [(first result-types) (rest items)]
          ;; Multi-value — need to find/create a func type
          ;; For now, this should be rare in woj output
          (throw (ex-info "Multi-value block types not yet supported"
                          {:types result-types}))))
      ;; (type $idx)
      (and (vector? first-item) (= "type" (first first-item)))
      [(resolve-idx (second first-item) type-index) (rest items)]
      ;; No block type — void
      :else [nil items])))

(defn encode-instrs
  "Encode a sequence of WAT instruction S-expressions to binary bytes.
   ctx is a map with index maps and label stack."
  [instrs ctx]
  (vec (mapcat #(encode-instr-sexpr % ctx) instrs)))

(defn encode-instr-sexpr
  "Encode a single WAT instruction S-expression to binary bytes."
  [instr ctx]
  (let [{:keys [type-index func-index global-index data-index tag-index
                field-indices local-index label-stack]} ctx]
    (cond
      ;; String atom — bare instruction or reference
      (string? instr)
      (let [op-kw (keyword instr)]
        (if-let [info (get bin/opcodes op-kw)]
          ;; Simple opcode with no immediates (used in flat WAT syntax)
          (do (assert (= :none (:imm info))
                      (str "Bare instruction requires immediates: " instr))
              (:bytes info))
          (throw (ex-info (str "Unknown bare instruction: " instr) {:instr instr}))))

      ;; S-expression instruction
      (vector? instr)
      (let [op (first instr)
            args (rest instr)
            op-kw (keyword op)]

        (case op
          ;; Block structured instructions
          ("block" "loop")
          (let [;; Optional label
                [label args] (if (name-ref? (first args))
                               [(first args) (rest args)]
                               [nil args])
                ;; Block type
                [bt remaining] (resolve-block-type args type-index)
                ;; Push label
                new-stack (vec (cons label label-stack))
                inner-ctx (assoc ctx :label-stack new-stack)
                body-bytes (encode-instrs remaining inner-ctx)]
            (bin/concat-bytes
             (bin/encode-instruction (keyword op) bt)
             body-bytes
             [0x0B])) ;; end

          "if"
          (let [;; Optional label
                [label args] (if (name-ref? (first args))
                               [(first args) (rest args)]
                               [nil args])
                ;; Block type
                [bt remaining] (resolve-block-type args type-index)
                new-stack (vec (cons label label-stack))
                inner-ctx (assoc ctx :label-stack new-stack)
                ;; Find condition, then, else
                ;; WAT folded form: condition is evaluated first (outside if)
                ;; The remaining forms are either:
                ;; 1. (then ...) (else ...) — folded form
                ;; 2. Mixed: some instructions as condition, then (then ...) (else ...)
                then-forms (atom nil)
                else-forms (atom nil)
                cond-forms (transient [])]
            (doseq [form remaining]
              (if (and (vector? form) (= "then" (first form)))
                (reset! then-forms (rest form))
                (if (and (vector? form) (= "else" (first form)))
                  (reset! else-forms (rest form))
                  (conj! cond-forms form))))
            (let [cond-bytes (encode-instrs (persistent! cond-forms) ctx)
                  then-bytes (if @then-forms
                               (encode-instrs @then-forms inner-ctx)
                               [])
                  else-bytes (when @else-forms
                               (encode-instrs @else-forms inner-ctx))]
              (bin/concat-bytes
               cond-bytes
               (bin/encode-instruction :if bt)
               then-bytes
               (when else-bytes
                 (bin/concat-bytes [0x05] else-bytes)) ;; else
               [0x0B]))) ;; end

          "try"
          (let [[label args] (if (name-ref? (first args))
                               [(first args) (rest args)]
                               [nil args])
                [bt remaining] (resolve-block-type args type-index)
                new-stack (vec (cons label label-stack))
                inner-ctx (assoc ctx :label-stack new-stack)
                ;; Parse: (do ...) (catch $tag ...) (catch_all ...)
                do-body (atom nil)
                catches (transient [])]
            (doseq [form remaining]
              (when (vector? form)
                (case (first form)
                  "do" (reset! do-body (rest form))
                  "catch" (conj! catches {:tag (second form)
                                          :body (vec (drop 2 form))})
                  "catch_all" (conj! catches {:tag nil
                                              :body (vec (rest form))})
                  nil)))
            (let [do-bytes (encode-instrs (or @do-body []) inner-ctx)
                  catch-entries (persistent! catches)]
              (bin/concat-bytes
               (bin/encode-instruction :try bt)
               do-bytes
               (vec (mapcat
                     (fn [{:keys [tag body]}]
                       (let [tag-bytes (if tag
                                         (bin/concat-bytes
                                          [0x07] ;; catch
                                          (bin/encode-unsigned-leb128
                                           (resolve-idx tag tag-index)))
                                         [0x19]) ;; catch_all
                             body-bytes (encode-instrs body inner-ctx)]
                         (bin/concat-bytes tag-bytes body-bytes)))
                     catch-entries))
               [0x0B]))) ;; end

          ;; Branch instructions — resolve label
          ("br" "br_if")
          (let [label-ref (first args)
                label-idx (if (name-ref? label-ref)
                            ;; Find label in stack
                            (let [idx (first (keep-indexed
                                              (fn [i l] (when (= l label-ref) i))
                                              label-stack))]
                              (or idx (throw (ex-info (str "Unknown label: " label-ref)
                                                      {:label label-ref}))))
                            (parse-int-literal label-ref))
                ;; In folded WAT, condition comes before br_if
                cond-forms (rest args)
                cond-bytes (encode-instrs cond-forms ctx)]
            (bin/concat-bytes
             cond-bytes
             (bin/encode-instruction (keyword op) label-idx)))

          "br_table"
          (let [;; args are: values... labels... default-label condition
                ;; In folded form: (br_table label1 label2 ... default condition-expr)
                ;; Labels are $names or numbers, last is default
                labels-and-rest (vec args)
                ;; All label refs come first, then possibly an inline expression
                label-refs (filterv #(or (name-ref? %) (and (string? %) (re-matches #"\d+" %)))
                                    labels-and-rest)
                expr-forms (filterv vector? labels-and-rest)
                resolved (mapv #(if (name-ref? %)
                                  (let [idx (first (keep-indexed
                                                    (fn [i l] (when (= l %) i))
                                                    label-stack))]
                                    (or idx (parse-int-literal %)))
                                  (parse-int-literal %))
                               label-refs)
                labels (vec (butlast resolved))
                default (last resolved)
                expr-bytes (encode-instrs expr-forms ctx)]
            (bin/concat-bytes expr-bytes
                              (bin/encode-instruction :br_table labels default)))

          ;; Call instructions
          ("call" "return_call")
          (let [func-ref (first args)
                func-idx (resolve-idx func-ref func-index)
                ;; Folded form: operands come after function name
                operand-forms (rest args)
                operand-bytes (encode-instrs operand-forms ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op) func-idx)))

          ("call_ref" "return_call_ref")
          (let [type-ref (first args)
                type-idx (resolve-idx type-ref type-index)
                operand-forms (rest args)
                operand-bytes (encode-instrs operand-forms ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op) type-idx)))

          ;; Variable access
          ("local.get" "local.set" "local.tee")
          (let [var-ref (first args)
                var-idx (resolve-idx var-ref local-index)
                operand-forms (rest args)
                operand-bytes (encode-instrs operand-forms ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op) var-idx)))

          ("global.get" "global.set")
          (let [var-ref (first args)
                var-idx (resolve-idx var-ref global-index)
                operand-forms (rest args)
                operand-bytes (encode-instrs operand-forms ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op) var-idx)))

          ;; Constants
          "i32.const"
          (let [v (parse-int-literal (first args))
                ;; WAT allows unsigned i32 values; wrap to signed for LEB128
                v (if (> v Integer/MAX_VALUE)
                    (unchecked-int v)
                    v)]
            (bin/encode-instruction :i32.const v))

          "i64.const"
          (let [v (parse-int-literal (first args))]
            (bin/encode-instruction :i64.const v))

          "f64.const"
          (let [v (parse-float-literal (first args))]
            (bin/encode-instruction :f64.const v))

          "f32.const"
          (let [v (parse-float-literal (first args))]
            (bin/encode-instruction :f32.const v))

          ;; Memory instructions
          ("i32.load" "i64.load" "f64.load" "i32.load8_s" "i32.load8_u"
           "i32.load16_s" "i32.load16_u" "i32.store" "i32.store8"
           "i32.store16" "i64.store" "f64.store")
          (let [;; Parse memarg: offset=N align=N
                [memarg-opts operands] (loop [args args offset 0 align nil remaining []]
                                         (if (empty? args)
                                           [{:offset offset :align (or align 0)} (seq remaining)]
                                           (let [a (first args)]
                                             (cond
                                               (and (string? a) (str/starts-with? a "offset="))
                                               (recur (rest args) (parse-int-literal (subs a 7)) align remaining)
                                               (and (string? a) (str/starts-with? a "align="))
                                               (recur (rest args) offset (parse-int-literal (subs a 6)) remaining)
                                               :else
                                               (recur (rest args) offset align (conj remaining a))))))
                align-log2 (case (long (:align memarg-opts))
                             0 0, 1 0, 2 1, 4 2, 8 3
                             ;; Default based on instruction
                             0)
                operand-bytes (encode-instrs operands ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op)
                                                      align-log2
                                                      (:offset memarg-opts))))

          ("memory.size" "memory.grow")
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op))))

          ;; GC struct instructions
          "struct.new"
          (let [type-ref (first args)
                type-idx (resolve-idx type-ref type-index)
                operand-bytes (encode-instrs (rest args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction :struct.new type-idx)))

          "struct.new_default"
          (let [type-idx (resolve-idx (first args) type-index)]
            (bin/encode-instruction :struct.new_default type-idx))

          ("struct.get" "struct.get_s" "struct.get_u")
          (let [type-ref (first args)
                type-idx (resolve-idx type-ref type-index)
                field-ref (second args)
                field-idx (if (name-ref? field-ref)
                            (let [fields (get field-indices type-ref)]
                              (or (get fields field-ref)
                                  (throw (ex-info (str "Unknown field " field-ref " on " type-ref)
                                                  {:type type-ref :field field-ref}))))
                            (parse-int-literal field-ref))
                operand-bytes (encode-instrs (drop 2 args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op) type-idx field-idx)))

          "struct.set"
          (let [type-ref (first args)
                type-idx (resolve-idx type-ref type-index)
                field-ref (second args)
                field-idx (if (name-ref? field-ref)
                            (get (get field-indices type-ref) field-ref)
                            (parse-int-literal field-ref))
                operand-bytes (encode-instrs (drop 2 args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction :struct.set type-idx field-idx)))

          ;; GC array instructions
          ("array.new" "array.new_default" "array.get" "array.get_s" "array.get_u"
           "array.set" "array.fill")
          (let [type-idx (resolve-idx (first args) type-index)
                operand-bytes (encode-instrs (rest args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op) type-idx)))

          "array.new_fixed"
          (let [type-idx (resolve-idx (first args) type-index)
                n (parse-int-literal (second args))
                operand-bytes (encode-instrs (drop 2 args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction :array.new_fixed type-idx n)))

          "array.new_data"
          (let [type-idx (resolve-idx (first args) type-index)
                data-idx (resolve-idx (second args) data-index)
                operand-bytes (encode-instrs (drop 2 args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction :array.new_data type-idx data-idx)))

          "array.new_elem"
          (let [type-idx (resolve-idx (first args) type-index)]
            ;; elem index is second arg
            (let [elem-idx (parse-int-literal (second args))
                  operand-bytes (encode-instrs (drop 2 args) ctx)]
              (bin/concat-bytes operand-bytes
                                (bin/encode-instruction :array.new_elem type-idx elem-idx))))

          "array.copy"
          (let [type-idx1 (resolve-idx (first args) type-index)
                type-idx2 (resolve-idx (second args) type-index)
                operand-bytes (encode-instrs (drop 2 args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction :array.copy type-idx1 type-idx2)))

          "array.len"
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes (bin/encode-instruction :array.len)))

          ;; Reference instructions
          "ref.null"
          (let [ht (first args)
                heap-type (if (name-ref? ht)
                            (resolve-idx ht type-index)
                            (resolve-heap-type-str ht))]
            (bin/encode-instruction :ref.null heap-type))

          "ref.is_null"
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes (bin/encode-instruction :ref.is_null)))

          "ref.func"
          (let [func-idx (resolve-idx (first args) func-index)]
            (bin/encode-instruction :ref.func func-idx))

          "ref.i31"
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes (bin/encode-instruction :ref.i31)))

          "i31.get_s"
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes (bin/encode-instruction :i31.get_s)))

          "i31.get_u"
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes (bin/encode-instruction :i31.get_u)))

          "ref.eq"
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes (bin/encode-instruction :ref.eq)))

          "ref.as_non_null"
          (let [operand-bytes (encode-instrs args ctx)]
            (bin/concat-bytes operand-bytes (bin/encode-instruction :ref.as_non_null)))

          ;; ref.test / ref.cast
          ("ref.test" "ref.cast")
          (let [;; arg is (ref $Type), (ref null $Type), or shorthand like "anyref", "eqref"
                ref-form (first args)
                ;; Parse nullable + heap type
                [nullable? heap-type operands]
                (cond
                  ;; String shorthand: "anyref", "eqref", "i31ref", etc.
                  (string? ref-form)
                  (let [rt (case ref-form
                             "anyref" {:nullable? true :ht :any}
                             "funcref" {:nullable? true :ht :func}
                             "externref" {:nullable? true :ht :extern}
                             "eqref" {:nullable? true :ht :eq}
                             "i31ref" {:nullable? false :ht :i31}
                             "structref" {:nullable? true :ht :struct}
                             "arrayref" {:nullable? true :ht :array}
                             (if (name-ref? ref-form)
                               {:nullable? false :ht (resolve-idx ref-form type-index)}
                               (throw (ex-info (str "Unknown ref type in " op ": " ref-form) {:form ref-form}))))]
                    [(:nullable? rt) (:ht rt) (rest args)])
                  ;; Vector form: (ref $T) or (ref null $T)
                  (vector? ref-form)
                  (let [null? (= "null" (second ref-form))
                        ht-raw (if null? (nth ref-form 2) (second ref-form))
                        ht (if (name-ref? ht-raw) (resolve-idx ht-raw type-index) (resolve-heap-type-str ht-raw))]
                    [null? ht (rest args)])
                  :else (throw (ex-info (str "Bad ref type in " op ": " (pr-str ref-form)) {:form ref-form})))
                operand-bytes (encode-instrs operands ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op) nullable? heap-type)))

          ;; br_on_cast / br_on_cast_fail
          ("br_on_cast" "br_on_cast_fail")
          (let [label-ref (first args)
                label-idx (if (name-ref? label-ref)
                            (first (keep-indexed
                                    (fn [i l] (when (= l label-ref) i))
                                    label-stack))
                            (parse-int-literal label-ref))
                rt1-form (second args)
                rt2-form (nth args 2)
                ;; Parse ref type: can be "anyref", (ref $T), (ref null $T), etc.
                parse-rt (fn [form]
                           (cond
                             ;; String shorthand: "anyref", "funcref", etc.
                             (string? form)
                             (case form
                               "anyref" {:nullable? true :ht :any}
                               "funcref" {:nullable? true :ht :func}
                               "externref" {:nullable? true :ht :extern}
                               "eqref" {:nullable? true :ht :eq}
                               "i31ref" {:nullable? false :ht :i31}
                               "structref" {:nullable? true :ht :struct}
                               "arrayref" {:nullable? true :ht :array}
                               (if (name-ref? form)
                                 {:nullable? false :ht (resolve-idx form type-index)}
                                 (throw (ex-info (str "Unknown ref type: " form) {:form form}))))
                             ;; (ref $T) or (ref null $T)
                             (vector? form)
                             (let [null? (= "null" (second form))
                                   ht-raw (if null? (nth form 2) (second form))
                                   ht (if (name-ref? ht-raw)
                                        (resolve-idx ht-raw type-index)
                                        (resolve-heap-type-str ht-raw))]
                               {:nullable? null? :ht ht})
                             :else (throw (ex-info (str "Bad ref type: " (pr-str form)) {:form form}))))
                rt1 (parse-rt rt1-form)
                rt2 (parse-rt rt2-form)
                flags (bit-or (if (:nullable? rt1) 0x01 0x00)
                              (if (:nullable? rt2) 0x02 0x00))
                operand-bytes (encode-instrs (drop 3 args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction (keyword op)
                                                      flags label-idx (:ht rt1) (:ht rt2))))

          ;; throw
          "throw"
          (let [tag-idx (resolve-idx (first args) tag-index)
                operand-bytes (encode-instrs (rest args) ctx)]
            (bin/concat-bytes operand-bytes
                              (bin/encode-instruction :throw tag-idx)))

          ;; All simple no-immediate instructions (i32.add, f64.mul, etc.)
          (if-let [info (get bin/opcodes op-kw)]
            (if (= :none (:imm info))
              (let [operand-bytes (encode-instrs args ctx)]
                (bin/concat-bytes operand-bytes (:bytes info)))
              (throw (ex-info (str "Instruction requires explicit handling: " op)
                              {:op op :imm (:imm info)})))
            (throw (ex-info (str "Unknown instruction: " op) {:op op})))))

      :else
      (throw (ex-info (str "Cannot encode instruction: " (pr-str instr)) {:instr instr})))))

;; ============================================
;; Data segment encoding
;; ============================================

(defn- wat-string-to-bytes
  "Convert a pre-decoded WAT string to raw bytes.
   The tokenizer already decoded hex escapes, so each char maps to one byte."
  [^String s]
  (let [n (.length s)
        result (transient [])]
    (loop [i 0]
      (if (>= i n)
        (persistent! result)
        (do (conj! result (int (.charAt s i)))
            (recur (inc i)))))))

;; ============================================
;; Full module binary encoding
;; ============================================

(defn- encode-init-expr
  "Encode an initializer expression (for globals) to binary."
  [init-forms ctx]
  (let [instr-bytes (encode-instrs init-forms ctx)]
    (bin/concat-bytes instr-bytes [0x0B]))) ;; end

(defn- build-func-type-from-import
  "Build a function type from an import descriptor."
  [desc type-index]
  (let [items (if (name-ref? (first desc)) (rest desc) desc)
        {:keys [params results]} (parse-param-result items)]
    {:params (mapv #(resolve-val-type (:type %) type-index) params)
     :results (mapv #(resolve-val-type % type-index) results)}))

(defn- build-func-type-from-func
  "Build a function type from a function declaration."
  [func type-index]
  {:params (mapv #(resolve-val-type (:type %) type-index) (:params func))
   :results (mapv #(resolve-val-type % type-index) (:results func))})

(defn- find-or-add-func-type!
  "Find an existing function type index or add a new one.
   Returns [type-index updated-extra-types]."
  [func-type existing-types extra-types-atom]
  ;; Search in existing types for a matching func type
  ;; For simplicity, we add all function types we need and deduplicate
  (let [all-types (concat existing-types @extra-types-atom)
        match (first (keep-indexed
                      (fn [i t]
                        (when (= (:func-sig t) func-type) i))
                      all-types))]
    (if match
      match
      (let [idx (count all-types)]
        (swap! extra-types-atom conj {:func-sig func-type})
        idx))))

(defn encode-module-from-wat
  "Encode a complete WASM module from parsed WAT analysis.
   Takes the result of analyze-module and produces binary bytes."
  [analysis]
  (let [{:keys [imports types funcs globals memories datas elems tags start
                type-index func-index global-index data-index tag-index
                field-indices n-func-imports]} analysis

        ;; ---- Type section ----
        ;; First encode declared types, then we may add implicit func types
        type-bytes (mapv #(encode-type-def % type-index) types)

        ;; Build a signature cache for existing func types in the type section
        existing-func-sigs
        (into {} (keep-indexed
                  (fn [i t]
                    (let [body (:body t)
                          fb (cond
                               (and (vector? body) (= "func" (first body))) body
                               (and (vector? body) (#{"sub" "sub_final"} (first body)))
                               (let [inner (last body)]
                                 (when (and (vector? inner) (= "func" (first inner))) inner))
                               :else nil)]
                      (when fb
                        (let [{:keys [params results]} (parse-param-result (rest fb))
                              pt (mapv #(resolve-val-type (:type %) type-index) params)
                              rt (mapv #(resolve-val-type % type-index) results)]
                          [{:params pt :results rt} i]))))
                  types))

        ;; Track extra types we need to create for imports/functions
        extra-types (atom [])

        find-or-create-func-type
        (fn [sig]
          (or (get existing-func-sigs sig)
              ;; Check extra types
              (first (keep-indexed
                      (fn [i et]
                        (when (= (:sig et) sig) (+ (count types) i)))
                      @extra-types))
              ;; Create new type
              (let [idx (+ (count types) (count @extra-types))]
                (swap! extra-types conj {:sig sig})
                idx)))

        func-imports (filter #(= "func" (:kind %)) imports)
        import-func-type-indices
        (mapv (fn [imp]
                (let [desc (:desc imp)
                      desc (if (name-ref? (first desc)) (rest desc) desc)]
                  (if-let [type-form (first (filter #(and (vector? %) (= "type" (first %))) desc))]
                    (resolve-idx (second type-form) type-index)
                    (find-or-create-func-type (build-func-type-from-import desc type-index)))))
              func-imports)

        ;; Defined function type indices
        defined-func-type-indices
        (mapv (fn [f]
                (if (:type-use f)
                  (resolve-idx (:type-use f) type-index)
                  (find-or-create-func-type (build-func-type-from-func f type-index))))
              funcs)

        ;; ---- Import section ----
        import-bytes (mapv (fn [imp]
                             (let [{:keys [module field kind desc]} imp]
                               (case kind
                                 "func" (let [desc-rest (if (name-ref? (first desc)) (rest desc) desc)
                                              ;; Find the type index for this import
                                              idx (nth import-func-type-indices
                                                       (.indexOf ^java.util.List func-imports imp))]
                                          (bin/encode-import module field
                                                             (bin/encode-func-import-desc idx)))
                                 "memory" (bin/encode-import module field
                                                              (bin/concat-bytes [bin/kind-memory]
                                                                                (bin/encode-memory 0)))
                                 "global" (throw (ex-info "Global imports not implemented" {:imp imp}))
                                 "table" (throw (ex-info "Table imports not implemented" {:imp imp})))))
                           imports)

        ;; ---- Function section ----
        func-section-entries (vec defined-func-type-indices)

        ;; ---- Memory section ----
        memory-bytes (mapv (fn [mem]
                             (if (:max mem)
                               (bin/encode-memory (:min mem) (:max mem))
                               (bin/encode-memory (:min mem))))
                           memories)

        ;; ---- Tag section ----
        ;; Tags reference a func type for their parameter signature
        tag-bytes (mapv (fn [t]
                          (let [param-types (mapv #(resolve-val-type % type-index)
                                                  (:param-types t))
                                type-idx (find-or-create-func-type
                                          {:params param-types :results []})]
                            (bin/encode-tag type-idx)))
                        tags)

        ;; ---- Global section ----
        ;; Build the instruction encoding context
        base-ctx {:type-index type-index
                  :func-index func-index
                  :global-index global-index
                  :data-index data-index
                  :tag-index tag-index
                  :field-indices field-indices
                  :local-index {}
                  :label-stack []}

        global-bytes (mapv (fn [g]
                             (let [vt (resolve-val-type (:type g) type-index)
                                   init-bytes (encode-init-expr (:init g) base-ctx)]
                               (bin/concat-bytes (bin/encode-val-type vt)
                                                 [(if (:mutable? g) 0x01 0x00)]
                                                 init-bytes)))
                           globals)

        ;; ---- Export section ----
        ;; Collect all exports: inline (from func/global/memory) + standalone
        all-exports (transient [])
        _ (doseq [mem memories]
            (doseq [name (:exports mem)]
              (conj! all-exports (bin/encode-export name bin/kind-memory 0))))
        _ (doseq [[i f] (map-indexed vector funcs)]
            (doseq [name (:exports f)]
              (conj! all-exports (bin/encode-export name bin/kind-func (+ n-func-imports i)))))
        _ (doseq [[i g] (map-indexed vector globals)]
            (doseq [name (:exports g)]
              (conj! all-exports (bin/encode-export name bin/kind-global i))))
        ;; Standalone exports
        _ (doseq [exp (:exports analysis)]
            (when (and (vector? exp) (= "export" (first exp)))
              (let [name (string-val (second exp))
                    desc (nth exp 2)
                    kind (first desc)
                    idx (resolve-idx (second desc)
                                     (case kind
                                       "func" func-index
                                       "global" global-index
                                       "memory" {}
                                       "table" {}))]
                (conj! all-exports
                       (bin/encode-export name
                                          (case kind
                                            "func" bin/kind-func
                                            "global" bin/kind-global
                                            "memory" bin/kind-memory
                                            "table" bin/kind-table)
                                          idx)))))
        export-bytes (persistent! all-exports)

        ;; ---- Start section ----
        start-idx (when start
                    (resolve-idx start func-index))

        ;; ---- Element section ----
        elem-bytes (mapv (fn [e]
                           (case (:kind e)
                             :declare
                             ;; Declarative element segment: flag=0x03 + elemkind=0x00 + count + raw func indices
                             (let [func-refs (mapv #(resolve-idx % func-index) (:funcs e))]
                               (bin/concat-bytes
                                [0x03] ;; declarative
                                [0x00] ;; elemkind: funcref
                                (bin/encode-unsigned-leb128 (count func-refs))
                                (vec (mapcat bin/encode-unsigned-leb128 func-refs))))
                             ;; Other elem kinds — passthrough (shouldn't occur in woj)
                             []))
                         elems)

        ;; ---- Data section ----
        data-bytes (mapv (fn [d]
                           (let [raw-bytes (wat-string-to-bytes (:data d))]
                             ;; Passive data segment
                             (bin/concat-bytes [0x01] ;; passive
                                               (bin/encode-unsigned-leb128 (count raw-bytes))
                                               raw-bytes)))
                         datas)

        ;; ---- Code section ----
        code-bytes (mapv (fn [f]
                           (let [;; Build local index for this function
                                 param-locals (map-indexed
                                               (fn [i p] (when (:name p) [(:name p) i]))
                                               (:params f))
                                 n-params (count (:params f))
                                 extra-locals (map-indexed
                                               (fn [i l] (when (:name l) [(:name l) (+ n-params i)]))
                                               (:locals f))
                                 local-index (into {} (concat (keep identity param-locals)
                                                              (keep identity extra-locals)))
                                 func-ctx (assoc base-ctx :local-index local-index)
                                 ;; Encode locals
                                 local-types (mapv #(resolve-val-type (:type %) type-index)
                                                   (:locals f))
                                 ;; Encode body
                                 body-bytes (encode-instrs (:body f) func-ctx)]
                             (bin/encode-code-entry local-types body-bytes)))
                         funcs)]

    ;; ---- Append extra func types for imports/functions ----
    (let [all-type-bytes (into type-bytes
                               (map (fn [{:keys [sig]}]
                                      (bin/encode-func-type (:params sig) (:results sig)))
                                    @extra-types))]

    ;; ---- Assemble module ----
    (bin/encode-module {:types all-type-bytes
                        :imports import-bytes
                        :functions func-section-entries
                        :memories memory-bytes
                        :tags tag-bytes
                        :globals global-bytes
                        :exports export-bytes
                        :start start-idx
                        :elements elem-bytes
                        :data data-bytes
                        :code code-bytes}))))

;; ============================================
;; Top-level API
;; ============================================

(defn wat->wasm
  "Convert WAT text to WASM binary bytes.
   Returns a vector of unsigned byte values (0-255)."
  [wat-source]
  (let [parsed (parse-wat wat-source)
        analysis (analyze-module parsed)]
    (encode-module-from-wat analysis)))

(defn wat->wasm-bytes
  "Convert WAT text to a Java byte array."
  [wat-source]
  (bin/bytes-out (wat->wasm wat-source)))
