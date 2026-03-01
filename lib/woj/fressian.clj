(ns woj.fressian)

;; ============================================
;; Fressian Binary Codec for woj
;; Wire-compatible byte codes from Datomic/fressian
;; Uses WASM linear memory as the byte buffer
;; ============================================

;; ---- Byte code constants (from Codes.java) ----

;; Packed integers: 1-byte range wraps around 0xFF
(def INT_PACKED_2_START 0x40)
(def INT_PACKED_2_ZERO  0x50)
(def INT_PACKED_2_END   0x60)
(def INT_PACKED_3_START 0x60)
(def INT_PACKED_3_ZERO  0x68)
(def INT_PACKED_3_END   0x70)
(def INT_PACKED_4_START 0x70)
(def INT_PACKED_4_ZERO  0x72)
(def INT_PACKED_4_END   0x74)

;; Priority cache (32 packed slots)
(def PRIORITY_CACHE_PACKED_START 0x80)
(def PRIORITY_CACHE_PACKED_END   0xA0)

;; Rich types
(def MAP  0xC0)
(def SET  0xC1)
(def SYM  0xC9)
(def KEY  0xCA)

;; Cache operations
(def GET_PRIORITY_CACHE 0xCC)
(def PUT_PRIORITY_CACHE 0xCD)

;; Strings
(def STRING_PACKED_LENGTH_START 0xDA)
(def STRING                    0xE3)

;; Lists (used for vectors/seqs)
(def LIST_PACKED_LENGTH_START 0xE4)
(def LIST                    0xEC)
(def BEGIN_CLOSED_LIST       0xED)

;; Primitives & control
(def TRUE             0xF5)
(def FALSE            0xF6)
(def NULL             0xF7)
(def INT              0xF8)
(def DOUBLE           0xFA)
(def DOUBLE_0         0xFB)
(def DOUBLE_1         0xFC)
(def END_COLLECTION   0xFD)
(def RESET_CACHES     0xFE)

;; ---- Buffer offset ----
;; Well above WASI iovec (0-11), f64 scratch (16-23), HostStore buffers (0-N, 1024-M)
(def BUFFER-OFFSET 65536)

;; ---- Writer ----

(defn writer
  "Create a writer positioned at BUFFER-OFFSET."
  []
  {:pos (atom BUFFER-OFFSET)
   :cache (atom {})
   :cache-idx (atom 0)})

(defn- w-pos [w] @(:pos w))

(defn- w-write-byte! [w b]
  (let [p @(:pos w)]
    (mem-write-byte! p (bit-and b 0xFF))
    (reset! (:pos w) (+ p 1))))

(defn- w-write-raw-i16! [w val]
  (let [p @(:pos w)]
    (mem-write-byte! p (bit-and (bit-shift-right val 8) 0xFF))
    (mem-write-byte! (+ p 1) (bit-and val 0xFF))
    (reset! (:pos w) (+ p 2))))

(defn- w-write-raw-i24! [w val]
  (let [p @(:pos w)]
    (mem-write-byte! p (bit-and (bit-shift-right val 16) 0xFF))
    (mem-write-byte! (+ p 1) (bit-and (bit-shift-right val 8) 0xFF))
    (mem-write-byte! (+ p 2) (bit-and val 0xFF))
    (reset! (:pos w) (+ p 3))))

(defn- w-write-raw-i32! [w val]
  (let [p @(:pos w)]
    (mem-write-i32-be! p val)
    (reset! (:pos w) (+ p 4))))

(defn- w-write-raw-f64! [w val]
  (let [p @(:pos w)]
    (mem-write-f64-be! p val)
    (reset! (:pos w) (+ p 8))))

;; ---- Write packed integer ----
;; Fressian packs integers using variable-length encoding:
;; - 1 byte: -1 to 63 (codes 0xFF..0x3F, wrapping unsigned)
;; - 2 bytes: -4096 to 4095
;; - 3 bytes: -524288 to 524287
;; - 4 bytes: full i32 range (via INT_PACKED_4 or INT code)

(defn write-int! [w n]
  (cond
    ;; 1-byte packed: -1 to 63
    (and (>= n -1) (<= n 63))
    (w-write-byte! w (bit-and n 0xFF))

    ;; 2-byte packed: -4096 to 4095
    (and (>= n -4096) (<= n 4095))
    (let [code (+ INT_PACKED_2_ZERO (bit-shift-right n 8))
          low  (bit-and n 0xFF)]
      (w-write-byte! w code)
      (w-write-byte! w low))

    ;; 3-byte packed: -524288 to 524287
    (and (>= n -524288) (<= n 524287))
    (let [code (+ INT_PACKED_3_ZERO (bit-shift-right n 16))
          mid  (bit-and (bit-shift-right n 8) 0xFF)
          low  (bit-and n 0xFF)]
      (w-write-byte! w code)
      (w-write-byte! w mid)
      (w-write-byte! w low))

    ;; 4-byte packed: -33554432 to 33554431
    (and (>= n -33554432) (<= n 33554431))
    (let [code (+ INT_PACKED_4_ZERO (bit-shift-right n 24))
          b1   (bit-and (bit-shift-right n 16) 0xFF)
          b2   (bit-and (bit-shift-right n 8) 0xFF)
          b3   (bit-and n 0xFF)]
      (w-write-byte! w code)
      (w-write-byte! w b1)
      (w-write-byte! w b2)
      (w-write-byte! w b3))

    ;; Full i32 via INT code
    :else
    (do
      (w-write-byte! w INT)
      (w-write-raw-i32! w n))))

;; ---- Write count (always non-negative, used for lengths) ----
(defn- write-count! [w n]
  (write-int! w n))

;; ---- Write string ----

(defn write-string! [w s]
  ;; Strategy: write bytes to a scratch area to measure, then emit header + bytes.
  ;; Scratch area is 32KB before our buffer at offset 32768.
  (let [scratch 32768
        byte-len (string->mem! s scratch)]
    (if (<= byte-len 7)
      ;; Packed length string (0-7 bytes): 1-byte header
      (do
        (w-write-byte! w (+ STRING_PACKED_LENGTH_START byte-len))
        (let [dst @(:pos w)]
          (loop [i 0]
            (when (< i byte-len)
              (mem-write-byte! (+ dst i) (mem-read-byte (+ scratch i)))
              (recur (+ i 1))))
          (reset! (:pos w) (+ dst byte-len))))
      ;; Full STRING code + count + bytes
      (do
        (w-write-byte! w STRING)
        (write-count! w byte-len)
        (let [dst @(:pos w)]
          (loop [i 0]
            (when (< i byte-len)
              (mem-write-byte! (+ dst i) (mem-read-byte (+ scratch i)))
              (recur (+ i 1))))
          (reset! (:pos w) (+ dst byte-len)))))))

;; ---- Write keyword ----

(defn- write-keyword-raw! [w kw]
  (let [ns-part (namespace kw)
        nm-part (name kw)]
    (w-write-byte! w KEY)
    (if ns-part
      (do
        (write-string! w ns-part)
        (write-string! w nm-part))
      (do
        (w-write-byte! w NULL)
        (write-string! w nm-part)))))

;; ---- Write symbol ----

(defn- write-symbol-raw! [w sym]
  (let [ns-part (namespace sym)
        nm-part (name sym)]
    (w-write-byte! w SYM)
    (if ns-part
      (do
        (write-string! w ns-part)
        (write-string! w nm-part))
      (do
        (w-write-byte! w NULL)
        (write-string! w nm-part)))))

;; ---- Priority cache ----

(defn- cache-lookup [w val]
  (get @(:cache w) val))

(defn- cache-put! [w val]
  (let [idx @(:cache-idx w)]
    (swap! (:cache w) assoc val idx)
    (swap! (:cache-idx w) inc)
    idx))

(defn- write-cached! [w val write-fn]
  (if-let [idx (cache-lookup w val)]
    ;; Cache hit - emit reference
    (if (< idx 32)
      (w-write-byte! w (+ PRIORITY_CACHE_PACKED_START idx))
      (do
        (w-write-byte! w GET_PRIORITY_CACHE)
        (write-int! w idx)))
    ;; Cache miss - emit PUT_PRIORITY_CACHE then the value
    (do
      (w-write-byte! w PUT_PRIORITY_CACHE)
      (cache-put! w val)
      (write-fn w val))))

;; ---- Write vector/list ----

(defn- write-list-header! [w cnt]
  (if (<= cnt 7)
    (w-write-byte! w (+ LIST_PACKED_LENGTH_START cnt))
    (do
      (w-write-byte! w LIST)
      (write-count! w cnt))))

;; ---- Top-level write dispatch ----

(declare write-object!)

(defn write-object! [w val]
  (cond
    (nil? val)
    (w-write-byte! w NULL)

    (= val true)
    (w-write-byte! w TRUE)

    (= val false)
    (w-write-byte! w FALSE)

    (integer? val)
    (write-int! w val)

    (float? val)
    (cond
      (= val 0.0) (w-write-byte! w DOUBLE_0)
      (= val 1.0) (w-write-byte! w DOUBLE_1)
      :else (do
              (w-write-byte! w DOUBLE)
              (w-write-raw-f64! w val)))

    (string? val)
    (write-string! w val)

    (keyword? val)
    (write-cached! w val write-keyword-raw!)

    (symbol? val)
    (write-symbol-raw! w val)

    (vector? val)
    (let [cnt (count val)]
      (write-list-header! w cnt)
      (loop [i 0]
        (when (< i cnt)
          (write-object! w (nth val i))
          (recur (+ i 1)))))

    (map? val)
    (let [ks (keys val)
          cnt (count ks)]
      (w-write-byte! w MAP)
      (write-count! w cnt)
      (loop [ks ks]
        (when (seq ks)
          (let [k (first ks)]
            (write-object! w k)
            (write-object! w (get val k))
            (recur (rest ks))))))

    (set? val)
    (let [items (seq val)
          cnt (count val)]
      (w-write-byte! w SET)
      (write-count! w cnt)
      (loop [items items]
        (when (seq items)
          (write-object! w (first items))
          (recur (rest items)))))

    ;; Fallback: seq/list -> closed list
    (seq? val)
    (do
      (w-write-byte! w BEGIN_CLOSED_LIST)
      (loop [s val]
        (when (seq s)
          (write-object! w (first s))
          (recur (rest s))))
      (w-write-byte! w END_COLLECTION))

    :else
    (throw (str "fressian: cannot write value of unknown type"))))

;; ---- Buffer range ----

(defn buffer-range
  "Returns [offset length] of the data written by writer w."
  [w]
  [BUFFER-OFFSET (- @(:pos w) BUFFER-OFFSET)])

;; ---- Reader ----

(defn reader
  "Create a reader over a linear memory region."
  [offset len]
  {:pos (atom offset)
   :end (+ offset len)
   :cache (atom [])})

(defn- r-pos [r] @(:pos r))

(defn- r-read-byte! [r]
  (let [p @(:pos r)
        b (mem-read-byte p)]
    (reset! (:pos r) (+ p 1))
    b))

(defn- r-read-raw-i16! [r]
  (let [p @(:pos r)
        hi (mem-read-byte p)
        lo (mem-read-byte (+ p 1))]
    (reset! (:pos r) (+ p 2))
    (bit-or (bit-shift-left hi 8) lo)))

(defn- r-read-raw-i24! [r]
  (let [p @(:pos r)
        b0 (mem-read-byte p)
        b1 (mem-read-byte (+ p 1))
        b2 (mem-read-byte (+ p 2))]
    (reset! (:pos r) (+ p 3))
    (bit-or (bit-or (bit-shift-left b0 16) (bit-shift-left b1 8)) b2)))

(defn- r-read-raw-i32! [r]
  (let [p @(:pos r)
        val (mem-read-i32-be p)]
    (reset! (:pos r) (+ p 4))
    val))

(defn- r-read-raw-f64! [r]
  (let [p @(:pos r)
        val (mem-read-f64-be p)]
    (reset! (:pos r) (+ p 8))
    val))

;; ---- Read string bytes from linear memory ----

(defn- r-read-string-bytes! [r len]
  (let [p @(:pos r)
        s (mem->string p len)]
    (reset! (:pos r) (+ p len))
    s))

;; ---- Read integer from code ----
;; Decode packed integer given the first byte (code).

(defn- read-int-by-code [r code]
  (cond
    ;; 1-byte packed: 0x00-0x3F = values 0-63
    (<= code 0x3F)
    code

    ;; 1-byte packed: 0xFF = -1 (wraps around)
    (= code 0xFF)
    -1

    ;; 2-byte packed: code in [0x40, 0x60), zero at 0x50
    (and (>= code INT_PACKED_2_START) (< code INT_PACKED_2_END))
    (let [b1 (r-read-byte! r)]
      (+ (bit-shift-left (- code INT_PACKED_2_ZERO) 8) b1))

    ;; 3-byte packed: code in [0x60, 0x70), zero at 0x68
    (and (>= code INT_PACKED_3_START) (< code INT_PACKED_3_END))
    (let [hi (r-read-byte! r)
          lo (r-read-byte! r)]
      (+ (bit-shift-left (- code INT_PACKED_3_ZERO) 16)
         (bit-shift-left hi 8)
         lo))

    ;; Full INT: 4-byte i32
    (= code INT)
    (r-read-raw-i32! r)

    :else
    (throw (str "fressian: unexpected int code " code))))

;; ---- Read object ----

(declare read-object!)

(defn- cache-add! [r val]
  (swap! (:cache r) conj val)
  val)

(defn read-object! [r]
  (let [code (r-read-byte! r)]
    (cond
      ;; Packed 1-byte integers: 0x00-0x3F and 0xFF
      (or (<= code 0x3F) (= code 0xFF))
      (read-int-by-code r code)

      ;; Packed 2-byte integers
      (and (>= code INT_PACKED_2_START) (< code INT_PACKED_2_END))
      (read-int-by-code r code)

      ;; Packed 3-byte integers
      (and (>= code INT_PACKED_3_START) (< code INT_PACKED_3_END))
      (read-int-by-code r code)

      ;; Packed 4-byte integers (0x70-0x74)
      (and (>= code INT_PACKED_4_START) (< code INT_PACKED_4_END))
      ;; 4-byte packed: code in [0x70, 0x74), zero at 0x72
      (let [b1 (r-read-byte! r)
            b2 (r-read-byte! r)
            b3 (r-read-byte! r)
            raw (bit-or (bit-or (bit-shift-left (- code INT_PACKED_4_ZERO) 24)
                                (bit-shift-left b1 16))
                        (bit-or (bit-shift-left b2 8) b3))]
        raw)

      ;; Full INT
      (= code INT)
      (r-read-raw-i32! r)

      ;; Priority cache packed (0x80-0x9F)
      (and (>= code PRIORITY_CACHE_PACKED_START)
           (< code PRIORITY_CACHE_PACKED_END))
      (let [idx (- code PRIORITY_CACHE_PACKED_START)]
        (nth @(:cache r) idx))

      ;; NULL
      (= code NULL)
      nil

      ;; TRUE
      (= code TRUE)
      true

      ;; FALSE
      (= code FALSE)
      false

      ;; DOUBLE_0
      (= code DOUBLE_0)
      0.0

      ;; DOUBLE_1
      (= code DOUBLE_1)
      1.0

      ;; DOUBLE
      (= code DOUBLE)
      (r-read-raw-f64! r)

      ;; Packed strings (length 0-7)
      (and (>= code STRING_PACKED_LENGTH_START)
           (< code (+ STRING_PACKED_LENGTH_START 8)))
      (let [len (- code STRING_PACKED_LENGTH_START)]
        (r-read-string-bytes! r len))

      ;; Full STRING
      (= code STRING)
      (let [len (read-int-by-code r (r-read-byte! r))]
        (r-read-string-bytes! r len))

      ;; Packed lists (length 0-7) -> vectors
      (and (>= code LIST_PACKED_LENGTH_START)
           (< code (+ LIST_PACKED_LENGTH_START 8)))
      (let [cnt (- code LIST_PACKED_LENGTH_START)]
        (loop [i 0 acc []]
          (if (< i cnt)
            (recur (+ i 1) (conj acc (read-object! r)))
            acc)))

      ;; LIST with count -> vector
      (= code LIST)
      (let [cnt (read-int-by-code r (r-read-byte! r))]
        (loop [i 0 acc []]
          (if (< i cnt)
            (recur (+ i 1) (conj acc (read-object! r)))
            acc)))

      ;; BEGIN_CLOSED_LIST -> read until END_COLLECTION
      (= code BEGIN_CLOSED_LIST)
      (loop [acc []]
        (let [peek-code (r-read-byte! r)]
          (if (= peek-code END_COLLECTION)
            (seq acc)
            ;; Push back the byte and read normally
            (do (swap! (:pos r) dec)
                (recur (conj acc (read-object! r)))))))

      ;; MAP
      (= code MAP)
      (let [cnt (read-int-by-code r (r-read-byte! r))]
        (loop [i 0 m {}]
          (if (< i cnt)
            (let [k (read-object! r)
                  v (read-object! r)]
              (recur (+ i 1) (assoc m k v)))
            m)))

      ;; SET
      (= code SET)
      (let [cnt (read-int-by-code r (r-read-byte! r))]
        (loop [i 0 s #{}]
          (if (< i cnt)
            (recur (+ i 1) (conj s (read-object! r)))
            s)))

      ;; KEY (keyword)
      (= code KEY)
      (let [ns-val (read-object! r)
            nm-val (read-object! r)]
        (if (nil? ns-val)
          (keyword nm-val)
          (keyword ns-val nm-val)))

      ;; SYM (symbol)
      (= code SYM)
      (let [ns-val (read-object! r)
            nm-val (read-object! r)]
        (if (nil? ns-val)
          (symbol nm-val)
          (symbol ns-val nm-val)))

      ;; PUT_PRIORITY_CACHE
      (= code PUT_PRIORITY_CACHE)
      (let [val (read-object! r)]
        (cache-add! r val))

      ;; GET_PRIORITY_CACHE (for indices >= 32)
      (= code GET_PRIORITY_CACHE)
      (let [idx (read-int-by-code r (r-read-byte! r))]
        (nth @(:cache r) idx))

      ;; RESET_CACHES
      (= code RESET_CACHES)
      (do
        (reset! (:cache r) [])
        (read-object! r))

      :else
      (throw (str "fressian: unknown code " code)))))
