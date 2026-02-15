;; Conway's Game of Life — rendered entirely in woj
;; JS is just a ~40-line framebuffer bridge
;;
;; Compile: clj -M:run examples/life.clj > examples/life.wat
;; Convert: wasm-tools parse examples/life.wat -o examples/life.wasm
;; Serve:   cd examples && python -m http.server 8000
;; Open:    http://localhost:8000/life.html

;; ── Grid Constants ──────────────────────────────

(def grid-w 80)
(def grid-h 60)
(def total-cells 4800)

;; ── Colors (packed RGB: r*65536 + g*256 + b) ───

(def color-bg 856343) ;; #0d1117

;; ── State ───────────────────────────────────────

(def state (atom nil))

;; ── RNG ─────────────────────────────────────────

(def rng (atom 42))

(defn next-random []
  (let [s @rng
        nv (+ (* s 1103) 12345)
        nv (loop [v nv]
             (cond
               (>= v 65536) (recur (- v 65536))
               (< v 0) (recur (+ v 65536))
               :else v))]
    (reset! rng (if (= nv 0) 1 nv))
    nv))

;; ── Grid Helpers ────────────────────────────────

(defn cell-index [x y] (+ (* y grid-w) x))

(defn cell-x [i] (- i (* (/ i grid-w) grid-w)))

(defn cell-y [i] (/ i grid-w))

(defn in-bounds? [x y]
  (and (>= x 0) (< x grid-w)
       (>= y 0) (< y grid-h)))

(defn make-empty-grid []
  (loop [i 0 grid []]
    (if (>= i total-cells)
      grid
      (recur (inc i) (conj grid 0)))))

(defn make-random-grid []
  (loop [i 0 grid []]
    (if (>= i total-cells)
      grid
      (recur (inc i) (conj grid (if (> (next-random) 45000) 1 0))))))

;; ── Cell Access ─────────────────────────────────

(defn grid-get [grid x y]
  (if (in-bounds? x y)
    (nth grid (cell-index x y))
    0))

(defn cell-alive? [v] (> v 0))

;; ── Core Rules ──────────────────────────────────

(defn count-neighbors [grid x y]
  (let [xm (dec x) xp (inc x)
        ym (dec y) yp (inc y)
        n 0
        n (if (cell-alive? (grid-get grid xm ym)) (inc n) n)
        n (if (cell-alive? (grid-get grid x  ym)) (inc n) n)
        n (if (cell-alive? (grid-get grid xp ym)) (inc n) n)
        n (if (cell-alive? (grid-get grid xm y )) (inc n) n)
        n (if (cell-alive? (grid-get grid xp y )) (inc n) n)
        n (if (cell-alive? (grid-get grid xm yp)) (inc n) n)
        n (if (cell-alive? (grid-get grid x  yp)) (inc n) n)
        n (if (cell-alive? (grid-get grid xp yp)) (inc n) n)]
    n))

(defn next-cell [grid i]
  (let [x (cell-x i)
        y (cell-y i)
        nbrs (count-neighbors grid x y)
        current (nth grid i)
        is-alive (cell-alive? current)]
    (cond
      (and is-alive (or (= nbrs 2) (= nbrs 3)))
      (if (< current 60) (inc current) 60)
      (and (not is-alive) (= nbrs 3))
      1
      :else 0)))

(defn next-generation [grid]
  (loop [i 0 new-grid []]
    (if (>= i total-cells)
      new-grid
      (recur (inc i) (conj new-grid (next-cell grid i))))))

;; ── Color Engine ────────────────────────────────

(defn clamp [v lo hi]
  (cond (< v lo) lo (> v hi) hi :else v))

(defn pack-rgb [r g b]
  (+ (* (clamp r 0 255) 65536)
     (* (clamp g 0 255) 256)
     (clamp b 0 255)))

(defn age->color [age]
  (cond
    (= age 1)   (pack-rgb 100 255 100)
    (<= age 3)  (pack-rgb 40 230 140)
    (<= age 6)  (pack-rgb 0 200 200)
    (<= age 12) (pack-rgb 0 150 255)
    (<= age 25) (pack-rgb 80 100 255)
    (<= age 40) (pack-rgb 130 70 230)
    :else        (pack-rgb 90 50 160)))

;; ── Patterns ────────────────────────────────────

(defn place-cells [grid cells ox oy]
  (loop [remaining (seq cells) g grid]
    (if (nil? remaining)
      g
      (let [cell (first remaining)
            cx (+ ox (nth cell 0))
            cy (+ oy (nth cell 1))]
        (recur (rest remaining)
               (if (in-bounds? cx cy)
                 (assoc g (cell-index cx cy) 1)
                 g))))))

(def glider [[1 0] [2 1] [0 2] [1 2] [2 2]])

(def rpentomino [[1 0] [2 0] [0 1] [1 1] [1 2]])

(def lwss [[1 0] [4 0] [0 1] [0 2] [4 2] [0 3] [1 3] [2 3] [3 3]])

(def pulsar
  [[2 0] [3 0] [4 0] [8 0] [9 0] [10 0]
   [0 2] [5 2] [7 2] [12 2]
   [0 3] [5 3] [7 3] [12 3]
   [0 4] [5 4] [7 4] [12 4]
   [2 5] [3 5] [4 5] [8 5] [9 5] [10 5]
   [2 7] [3 7] [4 7] [8 7] [9 7] [10 7]
   [0 8] [5 8] [7 8] [12 8]
   [0 9] [5 9] [7 9] [12 9]
   [0 10] [5 10] [7 10] [12 10]
   [2 12] [3 12] [4 12] [8 12] [9 12] [10 12]])

(def glider-gun
  [[24 0]
   [22 1] [24 1]
   [12 2] [13 2] [20 2] [21 2] [34 2] [35 2]
   [11 3] [15 3] [20 3] [21 3] [34 3] [35 3]
   [0 4] [1 4] [10 4] [16 4] [20 4] [21 4]
   [0 5] [1 5] [10 5] [14 5] [16 5] [17 5] [22 5] [24 5]
   [10 6] [16 6] [24 6]
   [11 7] [15 7]
   [12 8] [13 8]])

;; ── Public API ──────────────────────────────────

(defn get-width [] grid-w)
(defn get-height [] grid-h)

(defn init []
  (reset! state {:grid (make-empty-grid)
                 :paused true
                 :generation 0})
  0)

(defn load-demo []
  (swap! state (fn [s]
    (let [g (make-empty-grid)
          g (place-cells g glider-gun 1 2)
          g (place-cells g pulsar 55 23)
          g (place-cells g rpentomino 60 8)
          g (place-cells g lwss 25 50)
          g (place-cells g glider 38 5)
          g (place-cells g glider 44 8)
          g (place-cells g glider 50 5)]
      (assoc s :grid g :generation 0))))
  0)

(defn get-pixel [i]
  (let [age (nth (get @state :grid) i)]
    (if (= age 0)
      color-bg
      (age->color age))))

(defn tick []
  (when-not (get @state :paused)
    (swap! state (fn [s]
      (-> s
          (assoc :grid (next-generation (get s :grid)))
          (assoc :generation (inc (get s :generation)))))))
  0)

(defn step []
  (swap! state (fn [s]
    (-> s
        (assoc :grid (next-generation (get s :grid)))
        (assoc :generation (inc (get s :generation))))))
  0)

(defn toggle-pause []
  (swap! state (fn [s]
    (assoc s :paused (not (get s :paused)))))
  0)

(defn is-paused []
  (if (get @state :paused) 1 0))

(defn get-generation []
  (get @state :generation))

(defn get-population []
  (reduce (fn [acc cell] (if (cell-alive? cell) (inc acc) acc))
          0
          (get @state :grid)))

;; ── Cell Manipulation ───────────────────────────

(defn is-alive-at [x y]
  (if (and (in-bounds? x y)
           (cell-alive? (nth (get @state :grid) (cell-index x y))))
    1 0))

(defn set-alive [x y]
  (when (in-bounds? x y)
    (swap! state (fn [s]
      (assoc s :grid (assoc (get s :grid) (cell-index x y) 1)))))
  0)

(defn set-dead [x y]
  (when (in-bounds? x y)
    (swap! state (fn [s]
      (assoc s :grid (assoc (get s :grid) (cell-index x y) 0)))))
  0)

(defn clear-grid []
  (swap! state (fn [s]
    (assoc s :grid (make-empty-grid) :generation 0)))
  0)

(defn randomize []
  (swap! state (fn [s]
    (assoc s :grid (make-random-grid) :generation 0)))
  0)

(defn seed-rng [seed]
  (reset! rng (if (= seed 0) 1 seed))
  0)

;; ── Pattern Placement ───────────────────────────

(defn add-glider []
  (swap! state (fn [s]
    (assoc s :grid (place-cells (get s :grid) glider
                                (- (/ grid-w 2) 1)
                                (- (/ grid-h 2) 1)))))
  0)

(defn add-pulsar []
  (swap! state (fn [s]
    (assoc s :grid (place-cells (get s :grid) pulsar
                                (- (/ grid-w 2) 6)
                                (- (/ grid-h 2) 6)))))
  0)

(defn add-gun []
  (swap! state (fn [s]
    (assoc s :grid (place-cells (get s :grid) glider-gun
                                2 (- (/ grid-h 2) 4)))))
  0)

(defn add-rpentomino []
  (swap! state (fn [s]
    (assoc s :grid (place-cells (get s :grid) rpentomino
                                (/ grid-w 2) (/ grid-h 2)))))
  0)

;; ── Test (for wasmtime) ─────────────────────────

(defn test-life []
  (seed-rng 42)
  (init)
  (set-alive 5 5)
  (set-alive 6 5)
  (set-alive 7 5)
  (step)
  ;; Blinker should rotate vertical
  (if (and (= (is-alive-at 6 4) 1)
           (= (is-alive-at 6 5) 1)
           (= (is-alive-at 6 6) 1)
           (= (is-alive-at 5 5) 0)
           (= (is-alive-at 7 5) 0))
    0
    1))
