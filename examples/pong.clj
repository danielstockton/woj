;; examples/pong.clj
;; Two-player Pong game in woj - Idiomatic Clojure Style
;; All coordinates scaled x100 for fixed-point precision
;; Uses atom for state, threading macros, and functional updates

;; ============================================
;; Constants (scaled x100)
;; ============================================
(def width 80000)         ;; 800px
(def height 60000)        ;; 600px
(def paddle-height 10000) ;; 100px
(def paddle-width 1000)   ;; 10px
(def ball-size 1000)      ;; 10px
(def ball-speed 400)
(def paddle-speed 800)
(def half-paddle 5000)    ;; paddle-height / 2
(def half-ball 500)       ;; ball-size / 2

;; ============================================
;; Initial state
;; ============================================
(def initial-state
  {:ball-x 40000
   :ball-y 30000
   :vel-x 400
   :vel-y 300
   :paddle-left 25000
   :paddle-right 25000
   :score-left 0
   :score-right 0
   :input-left 0
   :input-right 0})

;; ============================================
;; Game state (atom holding immutable map)
;; ============================================
(def state (atom initial-state))

;; ============================================
;; Pure helper functions
;; ============================================
(defn clamp [val minv maxv]
  (cond
    (< val minv) minv
    (> val maxv) maxv
    :else val))

(defn negate [x]
  (- 0 x))

;; ============================================
;; Input functions (called from JS)
;; ============================================
(defn set-left-input [dir]
  (swap! state (fn [s] (assoc s :input-left dir)))
  dir)

(defn set-right-input [dir]
  (swap! state (fn [s] (assoc s :input-right dir)))
  dir)

;; ============================================
;; State getters (called from JS)
;; ============================================
(defn get-ball-x [] (get @state :ball-x))
(defn get-ball-y [] (get @state :ball-y))
(defn get-paddle-left [] (get @state :paddle-left))
(defn get-paddle-right [] (get @state :paddle-right))
(defn get-score-left [] (get @state :score-left))
(defn get-score-right [] (get @state :score-right))

;; ============================================
;; Pure state update functions
;; ============================================

(defn move-paddle [s paddle-key input-key]
  (let [paddle (get s paddle-key)
        input (get s input-key)
        new-paddle (clamp (+ paddle (* input paddle-speed))
                          half-paddle
                          (- height half-paddle))]
    (assoc s paddle-key new-paddle)))

(defn update-paddles [s]
  (-> s
      (move-paddle :paddle-left :input-left)
      (move-paddle :paddle-right :input-right)))

(defn update-ball-position [s]
  (-> s
      (assoc :ball-x (+ (get s :ball-x) (get s :vel-x)))
      (assoc :ball-y (+ (get s :ball-y) (get s :vel-y)))))

(defn bounce-top [s]
  (if (< (get s :ball-y) half-ball)
    (-> s
        (assoc :ball-y half-ball)
        (assoc :vel-y (negate (get s :vel-y))))
    s))

(defn bounce-bottom [s]
  (if (> (get s :ball-y) (- height half-ball))
    (-> s
        (assoc :ball-y (- height half-ball))
        (assoc :vel-y (negate (get s :vel-y))))
    s))

(defn bounce-walls [s]
  (-> s
      bounce-top
      bounce-bottom))

(defn paddle-hit? [ball-y paddle-y]
  (and (>= ball-y (- paddle-y half-paddle))
       (<= ball-y (+ paddle-y half-paddle))))

(defn check-left-paddle [s]
  (let [ball-x (get s :ball-x)
        ball-y (get s :ball-y)
        vel-x (get s :vel-x)
        paddle (get s :paddle-left)]
    (if (and (<= (- ball-x half-ball) paddle-width)
             (< vel-x 0)
             (paddle-hit? ball-y paddle))
      (-> s
          (assoc :ball-x (+ paddle-width half-ball))
          (assoc :vel-x (negate vel-x)))
      s)))

(defn check-right-paddle [s]
  (let [ball-x (get s :ball-x)
        ball-y (get s :ball-y)
        vel-x (get s :vel-x)
        paddle (get s :paddle-right)]
    (if (and (>= (+ ball-x half-ball) (- width paddle-width))
             (> vel-x 0)
             (paddle-hit? ball-y paddle))
      (-> s
          (assoc :ball-x (- (- width paddle-width) half-ball))
          (assoc :vel-x (negate vel-x)))
      s)))

(defn check-paddles [s]
  (-> s
      check-left-paddle
      check-right-paddle))

(defn reset-ball [s direction]
  (assoc s
         :ball-x 40000
         :ball-y 30000
         :vel-x (* direction ball-speed)
         :vel-y 300))

(defn check-scoring [s]
  (let [ball-x (get s :ball-x)]
    (cond
      ;; Ball past left edge - right scores
      (< ball-x 0)
      (-> s
          (assoc :score-right (inc (get s :score-right)))
          (reset-ball 1))

      ;; Ball past right edge - left scores
      (> ball-x width)
      (-> s
          (assoc :score-left (inc (get s :score-left)))
          (reset-ball (negate 1)))

      ;; No scoring
      :else s)))

;; ============================================
;; Main game tick - pure state transformation
;; ============================================
(defn tick-state [s]
  (-> s
      update-paddles
      update-ball-position
      bounce-walls
      check-paddles
      check-scoring))

;; ============================================
;; Entry points (called from JS)
;; ============================================
(defn init []
  (reset! state initial-state)
  0)

(defn tick []
  (swap! state (fn [s] (tick-state s)))
  0)
