;; Snake game in woj
;; Compile: clj -M:run examples/snake.clj > examples/snake.wat
;; Convert: wasm-tools parse examples/snake.wat -o examples/snake.wasm
;; Serve: cd examples && python -m http.server 8000
;; Play: http://localhost:8000/snake.html

;; Grid size
(def grid-width 20)
(def grid-height 15)

;; Directions: 0=up, 1=right, 2=down, 3=left
(def dir-up 0)
(def dir-right 1)
(def dir-down 2)
(def dir-left 3)

;; Game state atom
(def game-state (atom nil))

;; Random seed for food placement
(def rng-state (atom 12345))

;; Simple LCG random number generator
(defn next-random []
  (let [current @rng-state
        ;; LCG parameters that work with 31-bit signed integers
        ;; Keep numbers smaller to avoid overflow
        a 1103
        c 12345
        m 65536
        raw (+ (* current a) c)
        ;; Manual modulo using loop
        next-val (loop [v raw]
                   (cond
                     (>= v m) (recur (- v m))
                     (< v 0) (recur (+ v m))
                     :else v))]
    (reset! rng-state (if (= next-val 0) 1 next-val))
    next-val))

(defn random-in-range [max-val]
  (let [r (next-random)]
    (loop [v r]
      (if (< v max-val)
        v
        (recur (- v max-val))))))

;; Position helpers
(defn make-pos [x y] [x y])
(defn pos-x [pos] (nth pos 0))
(defn pos-y [pos] (nth pos 1))

(defn pos-eq? [p1 p2]
  (and (= (pos-x p1) (pos-x p2))
       (= (pos-y p1) (pos-y p2))))

;; Check if position is in list of positions
(defn pos-in-list? [pos positions]
  (loop [remaining (seq positions)]
    (if (nil? remaining)
      false
      (if (pos-eq? pos (first remaining))
        true
        (recur (rest remaining))))))

;; Direction to delta
(defn dir-dx [dir]
  (cond
    (= dir dir-right) 1
    (= dir dir-left) -1
    :else 0))

(defn dir-dy [dir]
  (cond
    (= dir dir-down) 1
    (= dir dir-up) -1
    :else 0))

;; Check if two directions are opposite
(defn opposite-dir? [d1 d2]
  (or (and (= d1 dir-up) (= d2 dir-down))
      (and (= d1 dir-down) (= d2 dir-up))
      (and (= d1 dir-left) (= d2 dir-right))
      (and (= d1 dir-right) (= d2 dir-left))))

;; Spawn food at random location not on snake
(defn spawn-food [snake]
  (loop [attempts 0]
    (if (> attempts 100)
      (make-pos 0 0)
      (let [x (random-in-range grid-width)
            y (random-in-range grid-height)
            pos (make-pos x y)]
        (if (pos-in-list? pos snake)
          (recur (inc attempts))
          pos)))))

;; Initialize game
(defn init-game []
  (let [initial-snake [(make-pos 10 7) (make-pos 9 7) (make-pos 8 7)]
        initial-food (spawn-food initial-snake)]
    (reset! game-state
            {:snake initial-snake
             :direction dir-right
             :food initial-food
             :score 0
             :game-over false}))
  0)

;; Get snake length
(defn get-snake-length []
  (count (get @game-state :snake)))

;; Get snake segment position
(defn get-snake-x [index]
  (let [snake (get @game-state :snake)]
    (if (< index (count snake))
      (pos-x (nth snake index))
      -1)))

(defn get-snake-y [index]
  (let [snake (get @game-state :snake)]
    (if (< index (count snake))
      (pos-y (nth snake index))
      -1)))

;; Get food position
(defn get-food-x []
  (pos-x (get @game-state :food)))

(defn get-food-y []
  (pos-y (get @game-state :food)))

;; Get score
(defn get-score []
  (get @game-state :score))

;; Check game over
(defn is-game-over []
  (if (get @game-state :game-over) 1 0))

;; Set direction (from keyboard input)
(defn set-direction [new-dir]
  (let [current-dir (get @game-state :direction)]
    (when-not (opposite-dir? current-dir new-dir)
      (swap! game-state (fn [s] (assoc s :direction new-dir)))))
  0)

;; Remove last element from vector
(defn drop-last-vec [v]
  (let [len (count v)]
    (if (<= len 1)
      []
      (loop [i 0
             result []]
        (if (>= i (dec len))
          result
          (recur (inc i) (conj result (nth v i))))))))

;; Prepend to vector (returns new vector with elem at front)
(defn prepend-vec [elem v]
  (loop [i 0
         result [elem]]
    (if (>= i (count v))
      result
      (recur (inc i) (conj result (nth v i))))))

;; Game tick - advance one frame
(defn tick []
  (if (get @game-state :game-over)
    0
    (let [state @game-state
          snake (get state :snake)
          dir (get state :direction)
          food (get state :food)
          score (get state :score)
          ;; Calculate new head position
          head (first snake)
          new-x (+ (pos-x head) (dir-dx dir))
          new-y (+ (pos-y head) (dir-dy dir))
          new-head (make-pos new-x new-y)
          ;; Check wall collision
          hit-wall (or (< new-x 0)
                       (>= new-x grid-width)
                       (< new-y 0)
                       (>= new-y grid-height))
          ;; Check self collision
          hit-self (pos-in-list? new-head snake)
          ;; Check if ate food
          ate-food (pos-eq? new-head food)]
      (cond
        ;; Game over
        (or hit-wall hit-self)
        (do (swap! game-state (fn [s] (assoc s :game-over true)))
            0)

        ;; Ate food - grow snake
        ate-food
        (let [new-snake (prepend-vec new-head snake)
              new-food (spawn-food new-snake)]
          (reset! game-state
                  {:snake new-snake
                   :direction dir
                   :food new-food
                   :score (inc score)
                   :game-over false})
          0)

        ;; Normal move
        :else
        (let [new-snake (prepend-vec new-head (drop-last-vec snake))]
          (swap! game-state (fn [s] (assoc s :snake new-snake)))
          0)))))

;; Seed the RNG (call from JS with timestamp)
(defn seed-random [seed]
  (reset! rng-state (if (= seed 0) 1 seed))
  0)

;; Test function to verify game logic
(defn test-snake []
  (seed-random 42)
  (init-game)
  (tick)
  (let [len (get-snake-length)
        x (get-snake-x 0)
        y (get-snake-y 0)]
    ;; After one tick moving right, head should be at (11,7)
    (if (and (= len 3)
             (= x 11) (= y 7))
      0  ;; pass
      1))) ;; fail
