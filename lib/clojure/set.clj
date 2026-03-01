(ns clojure.set)

;; ============================================
;; clojure.set - Set operations library
;; ============================================

;; union, intersection, difference are in core — re-export them
;; so (clojure.set/union ...) works

(defn union
  ([] (hash-set))
  ([s1] s1)
  ([s1 s2] (into (or s1 (hash-set)) s2))
  ([s1 s2 & sets] (reduce union (union s1 s2) sets)))

(defn intersection
  ([s1] s1)
  ([s1 s2] (reduce (fn [result item]
                     (if (contains? s2 item) result (disj result item)))
                   s1 s1))
  ([s1 s2 & sets] (reduce intersection (intersection s1 s2) sets)))

(defn difference
  ([s1] s1)
  ([s1 s2] (reduce disj s1 s2))
  ([s1 s2 & sets] (reduce difference (difference s1 s2) sets)))

(defn select [pred xset]
  (reduce (fn [s x]
            (if (pred x)
              (set-conj s x)
              s))
          (hash-set) xset))

(defn project [xrel ks]
  (set (map (fn [m] (select-keys m ks)) xrel)))

(defn rename-keys [m kmap]
  (reduce-kv (fn [acc old-key new-key]
               (if (contains? acc old-key)
                 (assoc (dissoc acc old-key) new-key (get acc old-key))
                 acc))
             m kmap))

(defn rename [xrel kmap]
  (set (map (fn [m] (rename-keys m kmap)) xrel)))

(defn map-invert [m]
  (reduce-kv (fn [acc k v] (assoc acc v k)) {} m))

(defn index [xrel ks]
  (reduce (fn [m x]
            (let [ik (select-keys x ks)]
              (assoc m ik (set-conj (get m ik (hash-set)) x))))
          {} xrel))

(defn join-natural [xrel yrel]
  ;; Natural join - find common keys
  (let [ks (if (and (seq xrel) (seq yrel))
             (intersection (set (keys (first xrel))) (set (keys (first yrel))))
             (hash-set))]
    (if (empty? ks)
      ;; Cross join
      (set (mapcat (fn [x] (map (fn [y] (merge x y)) yrel)) xrel))
      ;; Join on common keys
      (let [idx (index yrel ks)]
        (reduce (fn [result x]
                  (let [matches (get idx (select-keys x ks))]
                    (if (nil? matches)
                      result
                      (reduce (fn [r y] (set-conj r (merge x y))) result matches))))
                (hash-set) xrel)))))

(defn join
  ([xrel yrel] (join-natural xrel yrel))
  ([xrel yrel km]
   (join-natural xrel (rename yrel (map-invert km)))))

(defn subset? [set1 set2]
  (every? (fn [x] (contains? set2 x)) set1))

(defn superset? [set1 set2]
  (subset? set2 set1))
