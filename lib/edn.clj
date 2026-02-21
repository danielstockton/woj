;; EDN Reader - recursive descent parser for woj
;; Supports: integers, floats, strings, keywords, nil, booleans,
;;           vectors, lists, maps, sets, comments

(declare read-form)

(defn edn-whitespace? [c]
  (or (= c " ") (= c "\n") (= c "\r") (= c "\t") (= c ",")))

(defn edn-digit? [c]
  (or (= c "0") (= c "1") (= c "2") (= c "3") (= c "4")
      (= c "5") (= c "6") (= c "7") (= c "8") (= c "9")))

(defn char->digit [c]
  (cond
    (= c "0") 0
    (= c "1") 1
    (= c "2") 2
    (= c "3") 3
    (= c "4") 4
    (= c "5") 5
    (= c "6") 6
    (= c "7") 7
    (= c "8") 8
    (= c "9") 9
    :else -1))

(defn edn-skip-ws [s pos]
  (let [len (count s)]
    (loop [i pos]
      (if (< i len)
        (let [c (nth s i)]
          (if (edn-whitespace? c)
            (recur (+ i 1))
            (if (= c ";")
              ;; Skip comment to end of line
              (recur (loop [j (+ i 1)]
                       (if (< j len)
                         (if (= (nth s j) "\n")
                           (+ j 1)
                           (recur (+ j 1)))
                         j)))
              i)))
        i))))

(defn edn-read-number [s pos]
  (let [len (count s)
        neg (= (nth s pos) "-")
        start (if neg (+ pos 1) pos)
        int-result (loop [i start acc 0]
                     (if (< i len)
                       (let [d (char->digit (nth s i))]
                         (if (>= d 0)
                           (recur (+ i 1) (+ (* acc 10) d))
                           [acc i]))
                       [acc i]))
        int-val (nth int-result 0)
        after-int (nth int-result 1)]
    (if (and (< after-int len) (= (nth s after-int) "."))
      ;; Float
      (let [frac-result (loop [j (+ after-int 1) frac 0.0 scale 0.1]
                          (if (< j len)
                            (let [d (char->digit (nth s j))]
                              (if (>= d 0)
                                (recur (+ j 1)
                                       (+ frac (* (double d) scale))
                                       (* scale 0.1))
                                [frac j]))
                            [frac j]))
            frac-val (nth frac-result 0)
            end-pos (nth frac-result 1)
            float-val (+ (double int-val) frac-val)]
        [(if neg (- 0.0 float-val) float-val) end-pos])
      ;; Integer
      [(if neg (- 0 int-val) int-val) after-int])))

(defn edn-read-string-literal [s pos]
  ;; pos points at opening "
  (let [len (count s)]
    (loop [i (+ pos 1) acc ""]
      (if (< i len)
        (let [c (nth s i)]
          (if (= c "\"")
            [acc (+ i 1)]
            (if (= c "\\")
              (let [nc (nth s (+ i 1))
                    escaped (cond
                              (= nc "\"") "\""
                              (= nc "\\") "\\"
                              (= nc "n") "\n"
                              (= nc "t") "\t"
                              :else nc)]
                (recur (+ i 2) (str acc escaped)))
              (recur (+ i 1) (str acc c)))))
        [acc i]))))

(defn edn-symbol-char? [c]
  (not (or (edn-whitespace? c)
           (= c "(") (= c ")") (= c "[") (= c "]")
           (= c "{") (= c "}") (= c "\"") (= c ";"))))

(defn edn-read-token [s pos]
  (let [len (count s)]
    (loop [i pos]
      (if (and (< i len) (edn-symbol-char? (nth s i)))
        (recur (+ i 1))
        [(subs s pos i) i]))))

(defn edn-read-keyword [s pos]
  ;; pos points at :
  (let [result (edn-read-token s (+ pos 1))]
    [(keyword (nth result 0)) (nth result 1)]))

(defn edn-read-symbol [s pos]
  (let [result (edn-read-token s pos)
        sym-str (nth result 0)
        end-pos (nth result 1)]
    (cond
      (= sym-str "nil") [nil end-pos]
      (= sym-str "true") [true end-pos]
      (= sym-str "false") [false end-pos]
      :else [(symbol sym-str) end-pos])))

(defn edn-read-vector [s pos]
  ;; pos points at [
  (let [len (count s)]
    (loop [i (edn-skip-ws s (+ pos 1)) items []]
      (if (< i len)
        (if (= (nth s i) "]")
          [items (+ i 1)]
          (let [result (read-form s i)
                val (nth result 0)
                new-pos (nth result 1)]
            (recur (edn-skip-ws s new-pos) (conj items val))))
        [items i]))))

(defn edn-read-list [s pos]
  ;; pos points at (
  (let [len (count s)
        vec-result (loop [i (edn-skip-ws s (+ pos 1)) items []]
                     (if (< i len)
                       (if (= (nth s i) ")")
                         [items (+ i 1)]
                         (let [r (read-form s i)
                               val (nth r 0)
                               new-pos (nth r 1)]
                           (recur (edn-skip-ws s new-pos) (conj items val))))
                       [items i]))
        items (nth vec-result 0)
        end-pos (nth vec-result 1)
        ;; Convert vector to list by consing from the end
        lst (loop [j (- (count items) 1) acc nil]
              (if (< j 0)
                acc
                (recur (- j 1) (cons (nth items j) acc))))]
    [lst end-pos]))

(defn edn-read-map [s pos]
  ;; pos points at {
  (let [len (count s)]
    (loop [i (edn-skip-ws s (+ pos 1)) m {}]
      (if (< i len)
        (if (= (nth s i) "}")
          [m (+ i 1)]
          (let [kr (read-form s i)
                k (nth kr 0)
                after-k (nth kr 1)
                vr (read-form s (edn-skip-ws s after-k))
                v (nth vr 0)
                after-v (nth vr 1)]
            (recur (edn-skip-ws s after-v) (assoc m k v))))
        [m i]))))

(defn edn-read-set [s pos]
  ;; pos points at #, next is {
  (let [len (count s)]
    (loop [i (edn-skip-ws s (+ pos 2)) result #{}]
      (if (< i len)
        (if (= (nth s i) "}")
          [result (+ i 1)]
          (let [r (read-form s i)
                val (nth r 0)
                new-pos (nth r 1)]
            (recur (edn-skip-ws s new-pos) (conj result val))))
        [result i]))))

(defn read-form [s pos]
  (let [i (edn-skip-ws s pos)
        len (count s)]
    (if (< i len)
      (let [c (nth s i)]
        (cond
          (= c "\"") (edn-read-string-literal s i)
          (= c ":") (edn-read-keyword s i)
          (= c "[") (edn-read-vector s i)
          (= c "(") (edn-read-list s i)
          (= c "{") (edn-read-map s i)
          (= c "#") (if (and (< (+ i 1) len) (= (nth s (+ i 1)) "{"))
                      (edn-read-set s i)
                      [nil (+ i 1)])
          (or (edn-digit? c)
              (and (= c "-") (< (+ i 1) len) (edn-digit? (nth s (+ i 1)))))
          (edn-read-number s i)
          :else (edn-read-symbol s i)))
      [nil i])))

(defn read-string [s]
  (nth (read-form s 0) 0))
