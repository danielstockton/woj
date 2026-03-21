(ns woj.binary
  "WASM binary encoder. Converts WAT text or IR vectors to WASM binary format.

   Approach: Parse the WAT output from the existing emitter into a structured
   representation, then encode to binary. This avoids duplicating the complex
   module assembly logic in emitter.cljc.

   Byte sequences are represented as Clojure vectors of integers (0-255).
   Convert to byte arrays with `bytes-out` for final output."
  (:require [clojure.string :as str]))

;; ============================================
;; Byte output helpers
;; ============================================

(defn byte-vec
  "Ensure a value is a byte vector. Passes through vectors, wraps scalars."
  [x]
  (if (vector? x) x [x]))

(defn concat-bytes
  "Concatenate multiple byte vectors into one."
  [& vecs]
  (into [] (mapcat byte-vec) (remove nil? vecs)))

#?(:clj
   (defn bytes-out
     "Convert a vector of unsigned byte values (0-255) to a Java byte array."
     [v]
     (let [ba (byte-array (count v))]
       (dotimes [i (count v)]
         (aset ba i (unchecked-byte (nth v i))))
       ba)))

;; ============================================
;; LEB128 encoding
;; ============================================

(defn encode-unsigned-leb128
  "Encode a non-negative integer as unsigned LEB128 bytes."
  [value]
  (assert (>= value 0) (str "unsigned LEB128 requires non-negative value, got: " value))
  (if (zero? value)
    [0]
    (loop [v value
           result []]
      (if (zero? v)
        result
        (let [byte-val (bit-and v 0x7F)
              v' (unsigned-bit-shift-right v 7)
              byte-val (if (pos? v')
                         (bit-or byte-val 0x80)
                         byte-val)]
          (recur v' (conj result byte-val)))))))

(defn encode-signed-leb128
  "Encode an integer as signed LEB128 bytes."
  [value]
  (loop [v (long value)
         result []]
    (let [byte-val (bit-and v 0x7F)
          v' (bit-shift-right v 7) ;; arithmetic shift
          ;; Check if we're done: sign bit of byte matches remaining bits
          done? (or (and (zero? v') (zero? (bit-and byte-val 0x40)))
                    (and (= v' -1) (not (zero? (bit-and byte-val 0x40)))))]
      (if done?
        (conj result byte-val)
        (recur v' (conj result (bit-or byte-val 0x80)))))))

;; ============================================
;; Basic value encoding
;; ============================================

#?(:clj
   (defn encode-f64
     "Encode a double as 8 bytes IEEE 754 little-endian."
     [value]
     (let [buf (java.nio.ByteBuffer/allocate 8)]
       (.order buf java.nio.ByteOrder/LITTLE_ENDIAN)
       (.putDouble buf (double value))
       (vec (map #(bit-and % 0xFF) (.array buf))))))

(defn encode-f32
  "Encode a float as 4 bytes IEEE 754 little-endian."
  [value]
  #?(:clj
     (let [buf (java.nio.ByteBuffer/allocate 4)]
       (.order buf java.nio.ByteOrder/LITTLE_ENDIAN)
       (.putFloat buf (float value))
       (vec (map #(bit-and % 0xFF) (.array buf))))))

(defn encode-vec
  "Encode a WASM vec: length (unsigned LEB128) followed by elements."
  [elements]
  (concat-bytes (encode-unsigned-leb128 (count elements))
                (vec (apply concat elements))))

(defn encode-byte-vec
  "Encode a byte vector: length prefix + raw bytes."
  [bytes]
  (concat-bytes (encode-unsigned-leb128 (count bytes)) bytes))

(defn encode-name
  "Encode a UTF-8 name: byte length + UTF-8 bytes."
  [s]
  (let [utf8 #?(:clj (vec (map #(bit-and % 0xFF) (.getBytes ^String s "UTF-8")))
                :default (vec (map #(bit-and % 0xFF) (.getBytes s "UTF-8"))))]
    (concat-bytes (encode-unsigned-leb128 (count utf8)) utf8)))

(defn encode-section
  "Encode a WASM section: section-id byte + size-prefixed content."
  [section-id content-bytes]
  (concat-bytes [section-id]
                (encode-unsigned-leb128 (count content-bytes))
                content-bytes))

;; ============================================
;; WASM value types
;; ============================================

;; Numeric types
(def ^:const vt-i32 0x7F)
(def ^:const vt-i64 0x7E)
(def ^:const vt-f32 0x7D)
(def ^:const vt-f64 0x7C)
;; Packed storage types (for arrays/struct fields only)
(def ^:const pt-i8 0x78)
(def ^:const pt-i16 0x77)

;; Reference type constructors
(def ^:const rt-ref 0x64)      ;; non-nullable: (ref ht)
(def ^:const rt-ref-null 0x63) ;; nullable: (ref null ht)

;; Abstract heap types (encoded as single bytes in heap type position)
(def ^:const ht-func 0x70)
(def ^:const ht-extern 0x6F)
(def ^:const ht-any 0x6E)
(def ^:const ht-eq 0x6D)
(def ^:const ht-i31 0x6C)
(def ^:const ht-struct 0x6B)
(def ^:const ht-array 0x6A)
(def ^:const ht-exn 0x69)
(def ^:const ht-none 0x71)
(def ^:const ht-noextern 0x72)
(def ^:const ht-nofunc 0x73)

;; Common reference types
(def anyref [rt-ref-null ht-any])     ;; (ref null any) = anyref
(def funcref [ht-func])               ;; funcref shorthand
(def externref [ht-extern])           ;; externref shorthand
(def i31ref [rt-ref ht-i31])          ;; (ref i31) — non-nullable
(def nullref [rt-ref-null ht-none])   ;; (ref null none) — null only

(defn encode-heap-type
  "Encode a heap type. Abstract types are single bytes, concrete types are LEB128 indices."
  [ht]
  (cond
    (integer? ht) (encode-signed-leb128 ht) ;; type index
    (keyword? ht) (case ht
                    :func [ht-func]
                    :extern [ht-extern]
                    :any [ht-any]
                    :eq [ht-eq]
                    :i31 [ht-i31]
                    :struct [ht-struct]
                    :array [ht-array]
                    :exn [ht-exn]
                    :none [ht-none]
                    :nofunc [ht-nofunc]
                    :noextern [ht-noextern]
                    (throw (ex-info (str "Unknown heap type: " ht) {:ht ht})))
    :else (throw (ex-info (str "Invalid heap type: " ht) {:ht ht}))))

(defn encode-ref-type
  "Encode a reference type: nullable? + heap-type."
  [nullable? heap-type]
  (concat-bytes [(if nullable? rt-ref-null rt-ref)]
                (encode-heap-type heap-type)))

(defn encode-val-type
  "Encode a value type. Can be a numeric type keyword or a ref type descriptor."
  [vt]
  (cond
    (keyword? vt)
    (case vt
      :i32 [vt-i32]
      :i64 [vt-i64]
      :f32 [vt-f32]
      :f64 [vt-f64]
      :funcref [ht-func]
      :externref [ht-extern]
      :anyref anyref
      :i31ref i31ref
      ;; Abstract ref types (nullable by default as per WAT convention)
      :structref [rt-ref-null ht-struct]
      :arrayref [rt-ref-null ht-array]
      :i8 [pt-i8]
      :i16 [pt-i16]
      (throw (ex-info (str "Unknown val type keyword: " vt) {:vt vt})))

    ;; {:ref idx} or {:ref-null idx} for concrete types
    (map? vt)
    (cond
      (:ref vt) (encode-ref-type false (:ref vt))
      (:ref-null vt) (encode-ref-type true (:ref-null vt))
      :else (throw (ex-info (str "Unknown val type map: " vt) {:vt vt})))

    ;; Vector [nullable? heap-type] for explicit ref types
    (vector? vt)
    (let [[nullable? ht] vt]
      (encode-ref-type nullable? ht))

    :else (throw (ex-info (str "Unknown val type: " vt) {:vt vt}))))

;; ============================================
;; Type section encoding (WasmGC)
;; ============================================

;; Composite type tags
(def ^:const ct-func 0x60)
(def ^:const ct-struct 0x5F)
(def ^:const ct-array 0x5E)

;; Sub type tags
(def ^:const st-sub 0x50)       ;; open subtype
(def ^:const st-sub-final 0x4F) ;; final subtype

;; Rec group tag
(def ^:const rec-group 0x4E)

(defn encode-field-type
  "Encode a struct field type: val-type + mutability (0=const, 1=mut)."
  [val-type mutable?]
  (concat-bytes (encode-val-type val-type)
                [(if mutable? 0x01 0x00)]))

(defn encode-struct-type
  "Encode a struct type: 0x5F + field-count + fields."
  [fields]
  (concat-bytes [ct-struct]
                (encode-unsigned-leb128 (count fields))
                (vec (mapcat (fn [{:keys [type mutable?] :or {mutable? false}}]
                               (encode-field-type type mutable?))
                             fields))))

(defn encode-array-type
  "Encode an array type: 0x5E + element field-type."
  [{:keys [type mutable?] :or {mutable? false}}]
  (concat-bytes [ct-array]
                (encode-field-type type mutable?)))

(defn encode-func-type
  "Encode a function type: 0x60 + param-vec + result-vec."
  [params results]
  (concat-bytes [ct-func]
                (encode-unsigned-leb128 (count params))
                (vec (mapcat encode-val-type params))
                (encode-unsigned-leb128 (count results))
                (vec (mapcat encode-val-type results))))

(defn encode-sub-type
  "Encode a sub type declaration.
   composite is {:struct fields}, {:array element}, or {:func params results}.
   parents is a vec of type indices (empty for no supertype)."
  ([composite] (encode-sub-type composite [] false))
  ([composite parents] (encode-sub-type composite parents false))
  ([composite parents final?]
   (let [comp-bytes (cond
                      (:struct composite)
                      (encode-struct-type (:struct composite))
                      (:array composite)
                      (encode-array-type (:array composite))
                      (:func composite)
                      (let [{:keys [params results]} (:func composite)]
                        (encode-func-type params results))
                      :else
                      (throw (ex-info "Unknown composite type" {:composite composite})))]
     (if (and (empty? parents) (not final?))
       ;; No parents, not final — can omit sub wrapper for non-GC types
       ;; But for GC types we usually need the sub wrapper
       comp-bytes
       (concat-bytes [(if final? st-sub-final st-sub)]
                     (encode-unsigned-leb128 (count parents))
                     (vec (mapcat encode-unsigned-leb128 parents))
                     comp-bytes)))))

(defn encode-rec-group
  "Encode a rec group: 0x4E + count + sub-types."
  [sub-type-bytes]
  (concat-bytes [rec-group]
                (encode-unsigned-leb128 (count sub-type-bytes))
                (vec (apply concat sub-type-bytes))))

;; ============================================
;; Instruction opcodes
;; ============================================

;; Each entry: opcode keyword -> [byte(s), immediate-format]
;; Immediate formats:
;;   :none          - no immediates
;;   :u32           - one unsigned LEB128 (index)
;;   :s32           - one signed LEB128 (i32.const)
;;   :s64           - one signed LEB128 (i64.const)
;;   :f64           - 8 bytes IEEE 754
;;   :f32           - 4 bytes IEEE 754
;;   :block         - block type immediate
;;   :memarg        - align + offset (two unsigned LEB128)
;;   :br-table      - vec of labels + default label
;;   :call-indirect - type-idx + table-idx
;;   :gc-type       - GC prefix + one type index
;;   :gc-type-field - GC prefix + type index + field index
;;   :gc-type-data  - GC prefix + type index + data index
;;   :gc-type-n     - GC prefix + type index + count
;;   :gc-type-type  - GC prefix + two type indices
;;   :gc-none       - GC prefix, no more immediates
;;   :gc-cast       - GC prefix + ref.test/ref.cast with heap type
;;   :gc-br-cast    - GC prefix + br_on_cast flags + label + ht1 + ht2
;;   :ref-null      - heap type
;;   :ref-func      - func index
;;   :memory        - 0x00 byte (memory index)
;;   :tag           - tag index (for throw/catch)
;;   :select-t      - select with types

(def opcodes
  {;; Control flow
   :unreachable    {:bytes [0x00] :imm :none}
   :nop            {:bytes [0x01] :imm :none}
   :block          {:bytes [0x02] :imm :block}
   :loop           {:bytes [0x03] :imm :block}
   :if             {:bytes [0x04] :imm :block}
   :else           {:bytes [0x05] :imm :none}
   :end            {:bytes [0x0B] :imm :none}
   :br             {:bytes [0x0C] :imm :u32}
   :br_if          {:bytes [0x0D] :imm :u32}
   :br_table       {:bytes [0x0E] :imm :br-table}
   :return         {:bytes [0x0F] :imm :none}
   :call           {:bytes [0x10] :imm :u32}
   :call_indirect  {:bytes [0x11] :imm :call-indirect}
   :return_call    {:bytes [0x12] :imm :u32}
   :call_ref       {:bytes [0x14] :imm :u32}    ;; typed function references
   :return_call_ref {:bytes [0x15] :imm :u32}   ;; typed function references + tail call

   ;; Exception handling (phase 3 legacy)
   :try            {:bytes [0x06] :imm :block}
   :catch          {:bytes [0x07] :imm :tag}
   :catch_all      {:bytes [0x19] :imm :none}
   :throw          {:bytes [0x08] :imm :tag}

   ;; Parametric
   :drop           {:bytes [0x1A] :imm :none}
   :select         {:bytes [0x1B] :imm :none}

   ;; Variable
   :local.get      {:bytes [0x20] :imm :u32}
   :local.set      {:bytes [0x21] :imm :u32}
   :local.tee      {:bytes [0x22] :imm :u32}
   :global.get     {:bytes [0x23] :imm :u32}
   :global.set     {:bytes [0x24] :imm :u32}

   ;; Memory
   :i32.load       {:bytes [0x28] :imm :memarg}
   :i64.load       {:bytes [0x29] :imm :memarg}
   :i32.load8_s    {:bytes [0x2C] :imm :memarg}
   :i32.load8_u    {:bytes [0x2D] :imm :memarg}
   :i32.load16_s   {:bytes [0x2E] :imm :memarg}
   :i32.load16_u   {:bytes [0x2F] :imm :memarg}
   :i32.store      {:bytes [0x36] :imm :memarg}
   :i32.store8     {:bytes [0x3A] :imm :memarg}
   :i32.store16    {:bytes [0x3B] :imm :memarg}
   :i64.store      {:bytes [0x37] :imm :memarg}
   :f64.load       {:bytes [0x2B] :imm :memarg}
   :f64.store      {:bytes [0x39] :imm :memarg}
   :memory.size    {:bytes [0x3F] :imm :memory}
   :memory.grow    {:bytes [0x40] :imm :memory}

   ;; Constants
   :i32.const      {:bytes [0x41] :imm :s32}
   :i64.const      {:bytes [0x42] :imm :s64}
   :f32.const      {:bytes [0x43] :imm :f32}
   :f64.const      {:bytes [0x44] :imm :f64}

   ;; i32 comparison
   :i32.eqz        {:bytes [0x45] :imm :none}
   :i32.eq         {:bytes [0x46] :imm :none}
   :i32.ne         {:bytes [0x47] :imm :none}
   :i32.lt_s       {:bytes [0x48] :imm :none}
   :i32.lt_u       {:bytes [0x49] :imm :none}
   :i32.gt_s       {:bytes [0x4A] :imm :none}
   :i32.gt_u       {:bytes [0x4B] :imm :none}
   :i32.le_s       {:bytes [0x4C] :imm :none}
   :i32.le_u       {:bytes [0x4D] :imm :none}
   :i32.ge_s       {:bytes [0x4E] :imm :none}
   :i32.ge_u       {:bytes [0x4F] :imm :none}

   ;; i64 comparison
   :i64.eqz        {:bytes [0x50] :imm :none}
   :i64.eq         {:bytes [0x51] :imm :none}
   :i64.ne         {:bytes [0x52] :imm :none}
   :i64.lt_s       {:bytes [0x53] :imm :none}
   :i64.gt_s       {:bytes [0x55] :imm :none}
   :i64.le_s       {:bytes [0x57] :imm :none}
   :i64.ge_s       {:bytes [0x59] :imm :none}

   ;; f64 comparison
   :f64.eq         {:bytes [0x61] :imm :none}
   :f64.ne         {:bytes [0x62] :imm :none}
   :f64.lt         {:bytes [0x63] :imm :none}
   :f64.gt         {:bytes [0x64] :imm :none}
   :f64.le         {:bytes [0x65] :imm :none}
   :f64.ge         {:bytes [0x66] :imm :none}

   ;; i32 arithmetic
   :i32.add        {:bytes [0x6A] :imm :none}
   :i32.sub        {:bytes [0x6B] :imm :none}
   :i32.mul        {:bytes [0x6C] :imm :none}
   :i32.div_s      {:bytes [0x6D] :imm :none}
   :i32.div_u      {:bytes [0x6E] :imm :none}
   :i32.rem_s      {:bytes [0x6F] :imm :none}
   :i32.rem_u      {:bytes [0x70] :imm :none}
   :i32.and        {:bytes [0x71] :imm :none}
   :i32.or         {:bytes [0x72] :imm :none}
   :i32.xor        {:bytes [0x73] :imm :none}
   :i32.shl        {:bytes [0x74] :imm :none}
   :i32.shr_s      {:bytes [0x75] :imm :none}
   :i32.shr_u      {:bytes [0x76] :imm :none}
   :i32.rotl       {:bytes [0x77] :imm :none}
   :i32.rotr       {:bytes [0x78] :imm :none}
   :i32.clz        {:bytes [0x67] :imm :none}
   :i32.ctz        {:bytes [0x68] :imm :none}
   :i32.popcnt     {:bytes [0x69] :imm :none}

   ;; i64 arithmetic
   :i64.add        {:bytes [0x7C] :imm :none}
   :i64.sub        {:bytes [0x7D] :imm :none}
   :i64.mul        {:bytes [0x7E] :imm :none}
   :i64.div_s      {:bytes [0x7F] :imm :none}
   :i64.div_u      {:bytes [0x80] :imm :none}
   :i64.rem_s      {:bytes [0x81] :imm :none}
   :i64.rem_u      {:bytes [0x82] :imm :none}
   :i64.and        {:bytes [0x83] :imm :none}
   :i64.or         {:bytes [0x84] :imm :none}
   :i64.xor        {:bytes [0x85] :imm :none}
   :i64.shl        {:bytes [0x86] :imm :none}
   :i64.shr_s      {:bytes [0x87] :imm :none}
   :i64.shr_u      {:bytes [0x88] :imm :none}

   ;; f64 arithmetic
   :f64.abs        {:bytes [0x99] :imm :none}
   :f64.neg        {:bytes [0x9A] :imm :none}
   :f64.ceil       {:bytes [0x9B] :imm :none}
   :f64.floor      {:bytes [0x9C] :imm :none}
   :f64.trunc      {:bytes [0x9D] :imm :none}
   :f64.nearest    {:bytes [0x9E] :imm :none}
   :f64.sqrt       {:bytes [0x9F] :imm :none}
   :f64.add        {:bytes [0xA0] :imm :none}
   :f64.sub        {:bytes [0xA1] :imm :none}
   :f64.mul        {:bytes [0xA2] :imm :none}
   :f64.div        {:bytes [0xA3] :imm :none}

   ;; Conversions
   :i32.wrap_i64        {:bytes [0xA7] :imm :none}
   :i32.trunc_f64_s     {:bytes [0xAA] :imm :none}
   :i32.trunc_f64_u     {:bytes [0xAB] :imm :none}
   :i64.extend_i32_s    {:bytes [0xAC] :imm :none}
   :i64.extend_i32_u    {:bytes [0xAD] :imm :none}
   :f64.convert_i32_s   {:bytes [0xB7] :imm :none}
   :f64.convert_i32_u   {:bytes [0xB8] :imm :none}
   :f64.convert_i64_s   {:bytes [0xB9] :imm :none}
   :f64.promote_f32     {:bytes [0xBB] :imm :none}
   :i64.reinterpret_f64 {:bytes [0xBD] :imm :none}
   :f64.reinterpret_i64 {:bytes [0xBF] :imm :none}

   ;; Saturating truncation (0xFC prefix)
   :i32.trunc_sat_f64_s {:bytes [0xFC 0x02] :imm :none}
   :i32.trunc_sat_f64_u {:bytes [0xFC 0x03] :imm :none}

   ;; Reference types
   :ref.null        {:bytes [0xD0] :imm :ref-null}
   :ref.is_null     {:bytes [0xD1] :imm :none}
   :ref.func        {:bytes [0xD2] :imm :ref-func}
   :ref.eq          {:bytes [0xD3] :imm :none}
   :ref.as_non_null {:bytes [0xD4] :imm :none}

   ;; GC instructions (0xFB prefix)
   :struct.new         {:bytes [0xFB 0x00] :imm :gc-type}
   :struct.new_default {:bytes [0xFB 0x01] :imm :gc-type}
   :struct.get         {:bytes [0xFB 0x02] :imm :gc-type-field}
   :struct.get_s       {:bytes [0xFB 0x03] :imm :gc-type-field}
   :struct.get_u       {:bytes [0xFB 0x04] :imm :gc-type-field}
   :struct.set         {:bytes [0xFB 0x05] :imm :gc-type-field}
   :array.new          {:bytes [0xFB 0x06] :imm :gc-type}
   :array.new_default  {:bytes [0xFB 0x07] :imm :gc-type}
   :array.new_fixed    {:bytes [0xFB 0x08] :imm :gc-type-n}
   :array.new_data     {:bytes [0xFB 0x09] :imm :gc-type-data}
   :array.new_elem     {:bytes [0xFB 0x0A] :imm :gc-type-data}
   :array.get          {:bytes [0xFB 0x0B] :imm :gc-type}
   :array.get_s        {:bytes [0xFB 0x0C] :imm :gc-type}
   :array.get_u        {:bytes [0xFB 0x0D] :imm :gc-type}
   :array.set          {:bytes [0xFB 0x0E] :imm :gc-type}
   :array.len          {:bytes [0xFB 0x0F] :imm :none}
   :array.fill         {:bytes [0xFB 0x10] :imm :gc-type}
   :array.copy         {:bytes [0xFB 0x11] :imm :gc-type-type}

   ;; GC ref.test / ref.cast — need special handling for nullable variants
   :ref.test          {:bytes [0xFB 0x14] :imm :gc-cast}
   :ref.cast          {:bytes [0xFB 0x16] :imm :gc-cast}

   ;; GC br_on_cast
   :br_on_cast        {:bytes [0xFB 0x18] :imm :gc-br-cast}
   :br_on_cast_fail   {:bytes [0xFB 0x19] :imm :gc-br-cast}

   ;; i31 operations
   :ref.i31           {:bytes [0xFB 0x1C] :imm :none}
   :i31.get_s         {:bytes [0xFB 0x1D] :imm :none}
   :i31.get_u         {:bytes [0xFB 0x1E] :imm :none}})

;; ============================================
;; Instruction encoding
;; ============================================

(defn encode-block-type
  "Encode a block type for block/loop/if/try.
   nil -> void (0x40)
   :i32, :f64 etc -> value type byte
   :anyref -> ref null any (2 bytes)
   integer -> type index as s33"
  [bt]
  (cond
    (nil? bt) [0x40]
    (integer? bt) (encode-signed-leb128 bt) ;; func type index
    (keyword? bt) (encode-val-type bt)
    (map? bt) (encode-val-type bt)
    (vector? bt) (encode-val-type bt)
    :else (throw (ex-info (str "Unknown block type: " bt) {:bt bt}))))

(defn encode-instruction
  "Encode a single instruction with its immediates.
   Returns a byte vector.

   Arguments:
   - op: keyword like :i32.add, :call, :struct.new
   - immediates: vector of immediate values (meaning depends on instruction)

   For index-based instructions, immediates are unsigned integers.
   For const instructions, the immediate is the constant value.
   For block instructions, the immediate is the block type."
  [op & immediates]
  (let [info (get opcodes op)]
    (when-not info
      (throw (ex-info (str "Unknown opcode: " op) {:op op})))
    (let [{:keys [bytes imm]} info
          result (vec bytes)]
      (case imm
        :none result

        :u32 (concat-bytes result (encode-unsigned-leb128 (first immediates)))
        :s32 (concat-bytes result (encode-signed-leb128 (first immediates)))
        :s64 (concat-bytes result (encode-signed-leb128 (first immediates)))
        :f64 (concat-bytes result (encode-f64 (first immediates)))
        :f32 (concat-bytes result (encode-f32 (first immediates)))

        :block (concat-bytes result (encode-block-type (first immediates)))

        :memarg (let [[align offset] immediates]
                  (concat-bytes result
                                (encode-unsigned-leb128 (or align 0))
                                (encode-unsigned-leb128 (or offset 0))))

        :memory (conj result 0x00) ;; memory index is always 0

        :tag (concat-bytes result (encode-unsigned-leb128 (first immediates)))

        :ref-null (concat-bytes result (encode-heap-type (first immediates)))
        :ref-func (concat-bytes result (encode-unsigned-leb128 (first immediates)))

        :br-table (let [labels (first immediates)
                        default (second immediates)]
                    (concat-bytes result
                                  (encode-unsigned-leb128 (count labels))
                                  (vec (mapcat encode-unsigned-leb128 labels))
                                  (encode-unsigned-leb128 default)))

        :call-indirect (let [[type-idx table-idx] immediates]
                         (concat-bytes result
                                       (encode-unsigned-leb128 type-idx)
                                       (encode-unsigned-leb128 (or table-idx 0))))

        ;; GC instructions with type index
        :gc-type (concat-bytes result (encode-unsigned-leb128 (first immediates)))

        ;; GC instructions with type index + field index
        :gc-type-field (let [[type-idx field-idx] immediates]
                         (concat-bytes result
                                       (encode-unsigned-leb128 type-idx)
                                       (encode-unsigned-leb128 field-idx)))

        ;; GC instructions with type index + data/elem index
        :gc-type-data (let [[type-idx data-idx] immediates]
                        (concat-bytes result
                                      (encode-unsigned-leb128 type-idx)
                                      (encode-unsigned-leb128 data-idx)))

        ;; GC instructions with type index + count
        :gc-type-n (let [[type-idx n] immediates]
                     (concat-bytes result
                                   (encode-unsigned-leb128 type-idx)
                                   (encode-unsigned-leb128 n)))

        ;; GC instructions with two type indices
        :gc-type-type (let [[type-idx1 type-idx2] immediates]
                        (concat-bytes result
                                      (encode-unsigned-leb128 type-idx1)
                                      (encode-unsigned-leb128 type-idx2)))

        ;; ref.test / ref.cast with heap type
        ;; immediates: [nullable? heap-type]
        :gc-cast (let [[nullable? heap-type] immediates
                       ;; Adjust opcode for nullable variant (+1)
                       adjusted (if nullable?
                                  (update result (dec (count result)) inc)
                                  result)]
                   (concat-bytes adjusted (encode-heap-type heap-type)))

        ;; br_on_cast: flags + label + ht1 + ht2
        ;; immediates: [flags label-idx heap-type1 heap-type2]
        :gc-br-cast (let [[flags label ht1 ht2] immediates]
                      (concat-bytes result
                                    [flags]
                                    (encode-unsigned-leb128 label)
                                    (encode-heap-type ht1)
                                    (encode-heap-type ht2)))

        :select-t (let [types (first immediates)]
                    (concat-bytes [0x1C]  ;; select with types
                                  (encode-unsigned-leb128 (count types))
                                  (vec (mapcat encode-val-type types))))

        (throw (ex-info (str "Unhandled immediate format: " imm) {:op op :imm imm}))))))

;; ============================================
;; Module section encoders
;; ============================================

;; Section IDs
(def ^:const section-custom   0)
(def ^:const section-type     1)
(def ^:const section-import   2)
(def ^:const section-function 3)
(def ^:const section-table    4)
(def ^:const section-memory   5)
(def ^:const section-global   6)
(def ^:const section-export   7)
(def ^:const section-start    8)
(def ^:const section-element  9)
(def ^:const section-code     10)
(def ^:const section-data     11)
(def ^:const section-data-count 12)
(def ^:const section-tag      13)

;; Import/export kinds
(def ^:const kind-func   0x00)
(def ^:const kind-table  0x01)
(def ^:const kind-memory 0x02)
(def ^:const kind-global 0x03)
(def ^:const kind-tag    0x04)

(defn encode-import
  "Encode an import entry: module-name + field-name + import-desc."
  [module-name field-name desc-bytes]
  (concat-bytes (encode-name module-name)
                (encode-name field-name)
                desc-bytes))

(defn encode-func-import-desc
  "Encode a function import descriptor: 0x00 + type-index."
  [type-idx]
  (concat-bytes [kind-func] (encode-unsigned-leb128 type-idx)))

(defn encode-export
  "Encode an export entry: name + kind + index."
  [export-name kind idx]
  (concat-bytes (encode-name export-name)
                [kind]
                (encode-unsigned-leb128 idx)))

(defn encode-global
  "Encode a global: type + mutability + init-expr."
  [val-type mutable? init-expr-bytes]
  (concat-bytes (encode-val-type val-type)
                [(if mutable? 0x01 0x00)]
                init-expr-bytes
                [0x0B])) ;; end

(defn encode-memory
  "Encode a memory type: limits (flags + min [+ max])."
  ([min-pages]
   (concat-bytes [0x00] (encode-unsigned-leb128 min-pages)))
  ([min-pages max-pages]
   (concat-bytes [0x01]
                 (encode-unsigned-leb128 min-pages)
                 (encode-unsigned-leb128 max-pages))))

(defn encode-table
  "Encode a table type: ref-type + limits."
  [ref-type min-size & [max-size]]
  (concat-bytes (encode-val-type ref-type)
                (if max-size
                  (concat-bytes [0x01]
                                (encode-unsigned-leb128 min-size)
                                (encode-unsigned-leb128 max-size))
                  (concat-bytes [0x00]
                                (encode-unsigned-leb128 min-size)))))

(defn encode-data-segment
  "Encode an active data segment: memory-idx + offset-expr + byte-data."
  ([byte-data]
   ;; Passive data segment
   (concat-bytes [0x01]
                 (encode-unsigned-leb128 (count byte-data))
                 byte-data))
  ([memory-idx offset byte-data]
   ;; Active data segment
   (concat-bytes [0x00] ;; active, memory 0
                 (encode-instruction :i32.const offset)
                 [0x0B] ;; end
                 (encode-unsigned-leb128 (count byte-data))
                 byte-data)))

(defn encode-locals
  "Encode function locals as compressed runs: vec of [count type] pairs."
  [local-types]
  (if (empty? local-types)
    (encode-unsigned-leb128 0)
    ;; Compress runs of same type
    (let [runs (reduce (fn [acc t]
                         (if (and (seq acc) (= (:type (peek acc)) t))
                           (update acc (dec (count acc)) update :count inc)
                           (conj acc {:type t :count 1})))
                       []
                       local-types)]
      (concat-bytes
       (encode-unsigned-leb128 (count runs))
       (vec (mapcat (fn [{:keys [count type]}]
                      (concat-bytes (encode-unsigned-leb128 count)
                                    (encode-val-type type)))
                    runs))))))

(defn encode-code-entry
  "Encode a function code entry: size-prefixed (locals + body)."
  [local-types body-bytes]
  (let [locals (encode-locals local-types)
        func-body (concat-bytes locals body-bytes [0x0B]) ;; end
        ]
    (concat-bytes (encode-unsigned-leb128 (count func-body))
                  func-body)))

(defn encode-tag
  "Encode a tag: attribute (0x00) + type-index."
  [type-idx]
  (concat-bytes [0x00] (encode-unsigned-leb128 type-idx)))

;; ============================================
;; Module header
;; ============================================

(def wasm-magic [0x00 0x61 0x73 0x6D]) ;; \0asm
(def wasm-version [0x01 0x00 0x00 0x00]) ;; version 1

(defn encode-module-header []
  (concat-bytes wasm-magic wasm-version))

;; ============================================
;; Complete module encoding
;; ============================================

(defn encode-module
  "Encode a complete WASM module from section data.

   sections is a map with optional keys:
     :types     - vec of type definition byte vectors (already encoded sub/rec types)
     :imports   - vec of import byte vectors
     :functions - vec of type indices (one per function)
     :tables    - vec of table type byte vectors
     :memories  - vec of memory type byte vectors
     :globals   - vec of global byte vectors
     :exports   - vec of export byte vectors
     :start     - function index (integer) or nil
     :elements  - vec of element segment byte vectors
     :code      - vec of code entry byte vectors
     :data      - vec of data segment byte vectors
     :tags      - vec of tag byte vectors"
  [sections]
  (let [make-section (fn [id entries]
                       (when (seq entries)
                         (encode-section id
                                         (concat-bytes
                                          (encode-unsigned-leb128 (count entries))
                                          (vec (apply concat entries))))))
        ;; Data count section goes before code section
        data-count-section (when (seq (:data sections))
                             (encode-section section-data-count
                                             (encode-unsigned-leb128 (count (:data sections)))))
        ;; Start section is just a function index, not vec-prefixed
        start-section (when-let [idx (:start sections)]
                        (encode-section section-start
                                        (encode-unsigned-leb128 idx)))]
    (apply concat-bytes
           (encode-module-header)
           (remove nil?
                   [(make-section section-type (:types sections))
                    (make-section section-import (:imports sections))
                    (make-section section-function
                                 (map encode-unsigned-leb128 (:functions sections)))
                    (make-section section-table (:tables sections))
                    (make-section section-memory (:memories sections))
                    (when (seq (:tags sections))
                      (make-section section-tag (:tags sections)))
                    (make-section section-global (:globals sections))
                    (make-section section-export (:exports sections))
                    start-section
                    (make-section section-element (:elements sections))
                    data-count-section
                    (make-section section-code (:code sections))
                    (make-section section-data (:data sections))]))))

;; ============================================
;; High-level helpers for common patterns
;; ============================================

(defn simple-func-type
  "Create a simple function type (no GC, just value types).
   Returns encoded bytes for use in :types section."
  [param-types result-types]
  (encode-func-type param-types result-types))

(defn simple-module
  "Build a minimal WASM module with exported functions.
   For testing purposes.

   funcs is a vec of maps:
     {:name \"export-name\"
      :params [:i32 :i32]
      :results [:i32]
      :locals [:i32]        ;; additional locals beyond params
      :body [bytes...]}     ;; instruction bytes"
  [funcs]
  (let [;; Build type section - one type per unique signature
        sigs (mapv (fn [f] [(:params f) (:results f)]) funcs)
        unique-sigs (vec (distinct sigs))
        sig->idx (into {} (map-indexed (fn [i s] [s i]) unique-sigs))
        types (mapv (fn [[params results]] (simple-func-type params results))
                    unique-sigs)

        ;; Function section - type index for each function
        func-type-indices (mapv (fn [f] (sig->idx [(:params f) (:results f)])) funcs)

        ;; Export section
        exports (mapv (fn [f i] (encode-export (:name f) kind-func i))
                      funcs (range))

        ;; Code section
        code (mapv (fn [f]
                     (encode-code-entry (or (:locals f) [])
                                        (vec (:body f))))
                   funcs)]
    (encode-module {:types types
                    :functions func-type-indices
                    :exports exports
                    :code code})))
