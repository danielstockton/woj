(ns clojure.walk)

;; ============================================
;; clojure.walk - Tree walking library
;; ============================================

(defn walk [inner outer form]
  (cond
    (map? form) (outer (into {} (map (fn [e] [(inner (key e)) (inner (val e))]) form)))
    (vector? form) (outer (mapv inner form))
    (set? form) (outer (set (map inner form)))
    (sequential? form) (outer (doall (map inner form)))
    :else (outer form)))

(defn postwalk [f form]
  (walk (fn [x] (postwalk f x)) f form))

(defn prewalk [f form]
  (walk (fn [x] (prewalk f x)) identity (f form)))

(defn keywordize-keys [m]
  (postwalk (fn [x]
              (if (map? x)
                (into {} (map (fn [e]
                                (let [k (key e)]
                                  (if (string? k)
                                    [(keyword k) (val e)]
                                    [k (val e)])))
                              x))
                x))
            m))

(defn stringify-keys [m]
  (postwalk (fn [x]
              (if (map? x)
                (into {} (map (fn [e]
                                (let [k (key e)]
                                  (if (keyword? k)
                                    [(name k) (val e)]
                                    [k (val e)])))
                              x))
                x))
            m))

(defn postwalk-replace [smap form]
  (postwalk (fn [x] (if (contains? smap x) (get smap x) x)) form))

(defn prewalk-replace [smap form]
  (prewalk (fn [x] (if (contains? smap x) (get smap x) x)) form))
