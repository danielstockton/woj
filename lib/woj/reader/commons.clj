;; Reader commons for woj - port of cljs.tools.reader.impl.commons
;; Number parsing, symbol parsing, and common reader helpers

(ns woj.reader.commons
  (:require [woj.reader.types :as t]
            [woj.reader.utils :as u]))

(defn number-literal? [reader initch]
  (or (u/numeric? initch)
      (and (or (= initch "+") (= initch "-"))
           (u/numeric? (t/peek-char reader)))))

(defn read-past [pred rdr]
  (loop [ch (t/read-char rdr)]
    (if (pred ch)
      (recur (t/read-char rdr))
      ch)))

(defn skip-line [reader]
  (loop []
    (when-not (u/newline? (t/read-char reader))
      (recur)))
  reader)

(defn- match-int
  "Parse an integer string with optional sign and various base prefixes.
   Returns the parsed integer or nil."
  [s]
  (let [len (count s)]
    (when (> len 0)
      (let [sign-ch (nth s 0)
            negate (= sign-ch "-")
            start (if (or negate (= sign-ch "+")) 1 0)]
        (when (< start len)
          (cond
            ;; Bare "0"
            (and (= (- len start) 1) (= (nth s start) "0"))
            0

            ;; Hex: 0x or 0X
            (and (>= (- len start) 2)
                 (= (nth s start) "0")
                 (let [c1 (nth s (+ start 1))]
                   (or (= c1 "x") (= c1 "X"))))
            (let [result (parse-int (subs s (+ start 2)) 16)]
              (when (and result (or (>= result 0) (and negate (= result -1073741824))))
                (if negate (- 0 result) result)))

            ;; Octal: leading 0 followed by digits
            (and (> (- len start) 1)
                 (= (nth s start) "0")
                 (u/numeric? (nth s (+ start 1))))
            (let [result (parse-int (subs s (+ start 1)) 8)]
              (when (and result (or (>= result 0) (and negate (= result -1073741824))))
                (if negate (- 0 result) result)))

            ;; Radix: NrDIGITS
            (let [r-idx (loop [i start]
                          (if (< i len)
                            (let [c (nth s i)]
                              (if (or (= c "r") (= c "R"))
                                i
                                (recur (+ i 1))))
                            -1))]
              (> r-idx start))
            (let [r-idx (loop [i start]
                          (if (< i len)
                            (let [c (nth s i)]
                              (if (or (= c "r") (= c "R"))
                                i
                                (recur (+ i 1))))
                            -1))
                  radix (parse-int (subs s start r-idx))
                  digits (subs s (+ r-idx 1))]
              (when (and radix (> (count digits) 0))
                (let [result (parse-int digits radix)]
                  (when (and result (or (>= result 0) (and negate (= result -1073741824))))
                    (if negate (- 0 result) result)))))

            ;; Plain decimal
            :else
            (let [result (parse-int (subs s start) 10)]
              (when (and result (or (>= result 0) (and negate (= result -1073741824))))
                (if negate (- 0 result) result)))))))))

(defn- match-float
  "Parse a float string. Returns the parsed float or nil."
  [s]
  (parse-float s))

(defn- match-ratio
  "Parse a ratio string like '1/2' or '-22/7'. Returns a float or nil.
   WasmGC has no ratio type, so ratios are computed as float division."
  [s]
  (let [len (count s)
        slash-idx (loop [i 0]
                    (if (< i len)
                      (if (= (nth s i) "/")
                        i
                        (recur (+ i 1)))
                      -1))]
    (when (and (> slash-idx 0) (< slash-idx (- len 1)))
      (let [num-part (subs s 0 slash-idx)
            den-part (subs s (+ slash-idx 1))
            num-val (match-int num-part)
            den-val (match-int den-part)]
        (when (and num-val den-val (not (zero? den-val)))
          (/ (double num-val) (double den-val)))))))

(defn match-number
  "Try to parse s as a number (int or float). Returns the number or nil.
   Handles BigInt (N suffix), BigDecimal (M suffix), and ratios (a/b).
   N/M are stripped (WasmGC has no arbitrary-precision types).
   Ratios are computed as float division."
  [s]
  (let [len (count s)]
    (if (and (> len 1)
             (let [last-ch (nth s (- len 1))]
               (or (= last-ch "N") (= last-ch "M"))))
      ;; Strip N/M suffix and re-parse
      (let [stripped (subs s 0 (- len 1))
            last-ch (nth s (- len 1))]
        (if (= last-ch "N")
          (match-int stripped)
          ;; M suffix: try float first, then int (e.g. "42M" is valid BigDecimal)
          (let [result (match-float stripped)]
            (if result result (match-int stripped)))))
      ;; Normal number parsing: try int, then ratio, then float
      (let [result (match-int s)]
        (if result
          result
          (let [ratio (match-ratio s)]
            (if ratio
              ratio
              (match-float s))))))))

(defn parse-symbol
  "Parse a symbol string into [namespace name] or nil if invalid."
  [token]
  (when (and (not (= token ""))
             (not (= (nth token (- (count token) 1)) ":"))
             (not (and (>= (count token) 2)
                       (= (nth token 0) ":")
                       (= (nth token 1) ":"))))
    (let [ns-idx (loop [i 0]
                   (if (< i (count token))
                     (if (= (nth token i) "/")
                       i
                       (recur (+ i 1)))
                     -1))]
      (if (> ns-idx 0)
        (let [ns-part (subs token 0 ns-idx)
              sym-part (subs token (+ ns-idx 1))]
          (when (and (> (count sym-part) 0)
                     (not (u/numeric? (nth sym-part 0)))
                     (not (= (nth ns-part (- (count ns-part) 1)) ":"))
                     (or (= sym-part "/")
                         (< 0 1))) ;; no nested slashes check simplified
            [ns-part sym-part]))
        ;; No namespace
        (when (or (= token "/")
                  (= ns-idx -1))
          [nil token])))))

(defn read-comment [rdr & _]
  (skip-line rdr)
  :woj.reader/skip)
