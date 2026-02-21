;; ============================================
;; Minimal regex engine for woj
;; Supports: literals, . * + ? \d \w \s \D \W \S
;;           [charset] [^charset] ^ $ | ()
;; ============================================

;; --- Character class helpers ---

(defn- re-digit? [c]
  (and (>= (compare c "0") 0) (<= (compare c "9") 0)))

(defn- re-word-char? [c]
  (or (and (>= (compare c "a") 0) (<= (compare c "z") 0))
      (and (>= (compare c "A") 0) (<= (compare c "Z") 0))
      (and (>= (compare c "0") 0) (<= (compare c "9") 0))
      (= c "_")))

(defn- re-space? [c]
  (or (= c " ") (= c "\t") (= c "\n") (= c "\r")))

;; --- Pattern parser ---
;; Converts a regex string into an AST represented as vectors:
;; [:lit "a"] [:dot] [:star x] [:plus x] [:opt x]
;; [:class true/false chars] [:anchor :start/:end]
;; [:group exprs...] [:alt a b] [:seq parts...]

(defn- re-parse-charset [pat pos]
  (let [len (count pat)
        negated (and (< pos len) (= (nth pat pos) "^"))
        start (if negated (inc pos) pos)]
    (loop [i start specs []]
      (if (>= i len)
        [negated specs i]
        (let [c (nth pat i)]
          (if (= c "]")
            [negated specs (inc i)]
            (if (and (< (+ i 2) len) (= (nth pat (inc i)) "-"))
              (recur (+ i 3) (conj specs [:range c (nth pat (+ i 2))]))
              (recur (inc i) (conj specs [:char c])))))))))

(defn- re-parse-escape [pat pos]
  (if (>= pos (count pat))
    [[:lit "\\"] pos]
    (let [c (nth pat pos)]
      (case c
        "d" [[:class-builtin :digit] (inc pos)]
        "D" [[:class-builtin :non-digit] (inc pos)]
        "w" [[:class-builtin :word] (inc pos)]
        "W" [[:class-builtin :non-word] (inc pos)]
        "s" [[:class-builtin :space] (inc pos)]
        "S" [[:class-builtin :non-space] (inc pos)]
        [[:lit c] (inc pos)]))))

(declare re-parse-group)

(defn- re-parse-atom [pat pos]
  (let [c (nth pat pos)]
    (case c
      "." [[:dot] (inc pos)]
      "^" [[:anchor :start] (inc pos)]
      "$" [[:anchor :end] (inc pos)]
      "\\" (re-parse-escape pat (inc pos))
      "[" (let [[neg specs new-pos] (re-parse-charset pat (inc pos))]
            [[:class neg specs] new-pos])
      "(" (let [[group new-pos] (re-parse-group pat (inc pos))]
            [group new-pos])
      [[:lit c] (inc pos)])))

(defn- re-parse-quantified [pat pos]
  (let [[atom new-pos] (re-parse-atom pat pos)]
    (if (>= new-pos (count pat))
      [atom new-pos]
      (let [q (nth pat new-pos)]
        (case q
          "*" [[:star atom] (inc new-pos)]
          "+" [[:plus atom] (inc new-pos)]
          "?" [[:opt atom] (inc new-pos)]
          [atom new-pos])))))

(defn- re-parse-seq [pat pos stop-chars]
  (loop [i pos parts []]
    (if (or (>= i (count pat)) (contains? stop-chars (nth pat i)))
      [parts i]
      (let [[part new-pos] (re-parse-quantified pat i)]
        (recur new-pos (conj parts part))))))

(defn- re-parse-alt [pat pos]
  (let [[first-parts new-pos] (re-parse-seq pat pos #{"|" ")"})]
    (loop [i new-pos alts [(if (= (count first-parts) 1) (first first-parts) (into [:seq] first-parts))]]
      (if (or (>= i (count pat)) (not= (nth pat i) "|"))
        [(if (= (count alts) 1) (first alts) (into [:alt] alts)) i]
        (let [[parts next-pos] (re-parse-seq pat (inc i) #{"|" ")"})]
          (recur next-pos (conj alts (if (= (count parts) 1) (first parts) (into [:seq] parts)))))))))

(defn- re-parse-group [pat pos]
  (let [[expr new-pos] (re-parse-alt pat pos)]
    (if (and (< new-pos (count pat)) (= (nth pat new-pos) ")"))
      [[:group expr] (inc new-pos)]
      [[:group expr] new-pos])))

(defn- re-parse [pattern-str]
  (let [[ast _] (re-parse-alt pattern-str 0)]
    ast))

;; --- Matcher ---
;; NFA-style backtracking matcher

(defn- re-match-class-spec [c spec]
  (case (first spec)
    :char (= c (second spec))
    :range (and (>= (compare c (second spec)) 0)
                (<= (compare c (nth spec 2)) 0))
    false))

(defn- re-match-class [c neg specs]
  (let [any-match (some (fn [spec] (re-match-class-spec c spec)) specs)]
    (if neg (not any-match) (true? any-match))))

(defn- re-match-builtin-class [c class-type]
  (case class-type
    :digit (re-digit? c)
    :non-digit (not (re-digit? c))
    :word (re-word-char? c)
    :non-word (not (re-word-char? c))
    :space (re-space? c)
    :non-space (not (re-space? c))
    false))

(defn- re-match-one [node s pos len]
  (if (>= pos len)
    nil
    (let [c (nth s pos)]
      (case (first node)
        :lit (when (= c (second node)) (inc pos))
        :dot (inc pos)
        :class (when (re-match-class c (second node) (nth node 2)) (inc pos))
        :class-builtin (when (re-match-builtin-class c (second node)) (inc pos))
        nil))))

(defn- re-match-node [node s pos len]
  (case (first node)
    :lit (let [r (re-match-one node s pos len)]
           (if r [r] []))
    :dot (let [r (re-match-one node s pos len)]
           (if r [r] []))
    :class (let [r (re-match-one node s pos len)]
             (if r [r] []))
    :class-builtin (let [r (re-match-one node s pos len)]
                     (if r [r] []))
    :anchor (case (second node)
              :start (if (= pos 0) [pos] [])
              :end (if (= pos len) [pos] [])
              [])
    :star
    (let [inner (second node)]
      (loop [positions [pos] seen #{pos}]
        (let [new-positions
              (reduce (fn [acc p]
                        (let [r (re-match-one inner s p len)]
                          (if (and r (not (contains? seen r)))
                            (conj acc r)
                            acc)))
                      [] positions)]
          (if (empty? new-positions)
            (vec seen)
            (recur new-positions (into seen new-positions))))))
    :plus
    (let [inner (second node)]
      (loop [positions []
             current [pos]
             seen #{}]
        (let [new-positions
              (reduce (fn [acc p]
                        (let [r (re-match-one inner s p len)]
                          (if (and r (not (contains? seen r)))
                            (conj acc r)
                            acc)))
                      [] current)]
          (if (empty? new-positions)
            positions
            (recur (into positions new-positions)
                   new-positions
                   (into seen new-positions))))))
    :opt
    (let [inner (second node)
          r (re-match-one inner s pos len)]
      (if r [pos r] [pos]))
    :seq
    (let [parts (rest node)]
      (reduce (fn [positions part]
                (if (empty? positions)
                  []
                  (vec (reduce (fn [acc p]
                                 (let [rs (re-match-node part s p len)]
                                   (reduce (fn [a r] (if (contains? a r) a (conj a r)))
                                           acc rs)))
                               #{} positions))))
              [pos] parts))
    :alt
    (let [alternatives (rest node)]
      (vec (reduce (fn [acc alt]
                     (let [rs (re-match-node alt s pos len)]
                       (reduce (fn [a r] (if (contains? a r) a (conj a r)))
                               acc rs)))
                   #{} alternatives)))
    :group
    (re-match-node (second node) s pos len)
    []))

(defn- re-try-match-at [ast s pos len]
  (let [end-positions (re-match-node ast s pos len)]
    (if (empty? end-positions)
      nil
      (reduce (fn [a b] (if (> a b) a b)) end-positions))))

;; --- Internal API (called by public re-find / re-matches / re-seq) ---

(defn- re-find-str [pattern-str s]
  (let [ast (re-parse pattern-str)
        len (count s)]
    (loop [pos 0]
      (if (> pos len)
        nil
        (let [end (re-try-match-at ast s pos len)]
          (if end
            (subs s pos end)
            (recur (inc pos))))))))

(defn- re-matches-str [pattern-str s]
  (let [ast (re-parse pattern-str)
        len (count s)
        end-positions (re-match-node ast s 0 len)]
    (if (some (fn [p] (= p len)) end-positions)
      s
      nil)))

(defn- re-seq-helper [ast s pos len]
  (lazy-seq
    (loop [p pos]
      (if (> p len)
        nil
        (let [end (re-try-match-at ast s p len)]
          (if end
            (let [matched (subs s p end)
                  next-pos (if (= end p) (inc p) end)]
              (cons matched (re-seq-helper ast s next-pos len)))
            (recur (inc p))))))))

(defn- re-seq-str [pattern-str s]
  (let [ast (re-parse pattern-str)
        len (count s)]
    (re-seq-helper ast s 0 len)))

;; --- Internal: find match with position info ---

(defn- re-find-index-str [pattern-str s]
  "Returns [start end] of the first match, or nil if no match."
  (let [ast (re-parse pattern-str)
        len (count s)]
    (loop [pos 0]
      (if (> pos len)
        nil
        (let [end (re-try-match-at ast s pos len)]
          (if end
            [pos end]
            (recur (inc pos))))))))

;; --- Public API ---

(defn re-find [re s]
  (re-find-str (regex-pattern re) s))

(defn re-matches [re s]
  (re-matches-str (regex-pattern re) s))

(defn re-seq [re s]
  (re-seq-str (regex-pattern re) s))

(defn re-find-index [re s]
  "Returns [start end] of the first match in s, or nil."
  (re-find-index-str (regex-pattern re) s))
