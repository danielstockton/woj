;; woj Playground - Interactive feature demos
;; Compile: clj -M:run examples/showcase.clj > examples/showcase.wat
;; Convert: wasm-tools parse examples/showcase.wat -o examples/showcase.wasm
;; Open:    examples/showcase.html in browser

(ns woj.showcase)

;; ── Protocols ──────────────────────────────────────

(defprotocol IArea
  (area [shape]))

(defprotocol IPerimeter
  (perimeter [shape]))

(extend-type Vector
  IArea
  (area [s] (* (nth s 0) (nth s 1)))
  IPerimeter
  (perimeter [s] (* 2 (+ (nth s 0) (nth s 1)))))

;; ── Lazy Fibonacci ─────────────────────────────────

(defn fibs-from [a b]
  (lazy-seq (cons a (fibs-from b (+ a b)))))

(defn fibs [] (fibs-from 0 1))

;; ── Collatz ────────────────────────────────────────

(defn collatz-next [n]
  (if (= n (* 2 (/ n 2)))
    (/ n 2)
    (+ 1 (* 3 n))))

;; ── String Operations ──────────────────────────────

(defn greet [s]
  (str "Hello, " s "!"))

;; ════════════════════════════════════════════════════
;; Interactive exports
;; ════════════════════════════════════════════════════

;; 1. Fibonacci: value at position i
(defn fib-at [i]
  (first (drop i (fibs))))

;; 1. Fibonacci: sum of first n values
(defn fib-sum [n]
  (reduce (fn [a x] (+ a x)) 0 (take n (fibs))))

;; 2. Pipeline: sum of first n squares via ->>
(defn sum-squares [n]
  (->> (range)
       (drop 1)
       (take n)
       (reduce (fn [a x] (+ a (* x x))) 0)))

;; 3. Protocol: area of [w h] rectangle
(defn get-area [w h]
  (area [w h]))

;; 3. Protocol: perimeter of [w h] rectangle
(defn get-perimeter [w h]
  (perimeter [w h]))

;; 4. Collatz: steps to reach 1
(defn collatz-len [start]
  (loop [n start steps 0]
    (if (<= n 1)
      steps
      (recur (collatz-next n) (+ steps 1)))))

;; 4. Collatz: value at step i of trajectory
(defn collatz-at [start i]
  (loop [n start step 0]
    (if (= step i)
      n
      (if (<= n 1)
        1
        (recur (collatz-next n) (+ step 1))))))

;; 5. Destructuring: total age of n team members
(defn team-total [n]
  (reduce (fn [acc person]
            (let [{:keys [age]} person]
              (+ acc age)))
          0
          (map (fn [i] {:name "member" :age (+ 25 (* i 5))})
               (take n (range)))))

;; 6. Strings: greeting length for preset name
(defn greeting-len [id]
  (count (greet (cond
                  (= id 0) "World"
                  (= id 1) "woj"
                  (= id 2) "WebAssembly"
                  (= id 3) "Clojure"
                  :else "Friend"))))
