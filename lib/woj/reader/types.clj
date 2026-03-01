;; Reader types for woj - port of cljs.tools.reader.reader-types
;; Protocols and concrete reader implementations

(ns woj.reader.types)

;; ==========================================
;; Reader protocols
;; ==========================================

(defprotocol Reader
  (-read-char [reader]
    "Returns the next char from the Reader as a single-char string, nil if EOF")
  (-peek-char [reader]
    "Returns the next char from the Reader without removing it"))

(defprotocol IPushbackReader
  (-unread [reader ch]
    "Pushes back a single character on to the stream"))

(defprotocol IndexingReader
  (-get-line-number [reader])
  (-get-column-number [reader])
  (-get-file-name [reader]))

;; ==========================================
;; Convenience functions
;; ==========================================

(defn read-char [reader] (-read-char reader))
(defn peek-char [reader] (-peek-char reader))
(defn unread [reader ch] (-unread reader ch))

(defn get-line-number [reader] (-get-line-number reader))
(defn get-column-number [reader] (-get-column-number reader))
(defn get-file-name [reader] (-get-file-name reader))

(defn indexing-reader? [rdr]
  (satisfies? IndexingReader rdr))

;; ==========================================
;; StringReader - reads from a string
;; ==========================================

(deftype StringReader [s s-len pos-atom]
  Reader
  (-read-char [reader]
    (let [p @pos-atom]
      (when (< p s-len)
        (reset! pos-atom (+ p 1))
        (nth s p))))
  (-peek-char [reader]
    (let [p @pos-atom]
      (when (< p s-len)
        (nth s p)))))

(defn string-reader [s]
  (StringReader. s (count s) (atom 0)))

;; ==========================================
;; PushbackReader - wraps a reader with pushback support
;; ==========================================

(deftype PushbackReader [rdr buf-atom]
  Reader
  (-read-char [reader]
    (let [buf @buf-atom]
      (if (> (count buf) 0)
        (let [ch (nth buf (- (count buf) 1))]
          (reset! buf-atom (vec (butlast buf)))
          ch)
        (read-char rdr))))
  (-peek-char [reader]
    (let [buf @buf-atom]
      (if (> (count buf) 0)
        (nth buf (- (count buf) 1))
        (peek-char rdr))))
  IPushbackReader
  (-unread [reader ch]
    (when ch
      (swap! buf-atom conj ch))))

(defn pushback-reader
  ([rdr] (PushbackReader. rdr (atom [])))
  ([rdr buf-len] (PushbackReader. rdr (atom []))))

;; ==========================================
;; IndexingPushbackReader - tracks line/column
;; ==========================================

(defn- newline? [ch]
  (or (= ch "\n") (nil? ch)))

(deftype IndexingPushbackReader
  [rdr line-atom column-atom line-start-atom prev-atom prev-column-atom file-name]
  Reader
  (-read-char [reader]
    (when-let [ch (read-char rdr)]
      ;; Normalize \r\n and \r to \n
      (let [ch (if (= ch "\r")
                 (do
                   (when (= (peek-char rdr) "\n")
                     (read-char rdr))
                   "\n")
                 ch)]
        (reset! prev-atom @line-start-atom)
        (reset! line-start-atom (newline? ch))
        (when @line-start-atom
          (reset! prev-column-atom @column-atom)
          (reset! column-atom 0)
          (swap! line-atom + 1))
        (swap! column-atom + 1)
        ch)))
  (-peek-char [reader]
    (peek-char rdr))
  IPushbackReader
  (-unread [reader ch]
    (if @line-start-atom
      (do (swap! line-atom - 1)
          (reset! column-atom @prev-column-atom))
      (swap! column-atom - 1))
    (reset! line-start-atom @prev-atom)
    (unread rdr ch))
  IndexingReader
  (-get-line-number [reader] @line-atom)
  (-get-column-number [reader] @column-atom)
  (-get-file-name [reader] file-name))

;; ==========================================
;; Public API
;; ==========================================

(defn string-push-back-reader
  ([s] (string-push-back-reader s 1))
  ([s buf-len] (pushback-reader (string-reader s) buf-len)))

(defn indexing-push-back-reader
  ([s-or-rdr]
   (indexing-push-back-reader s-or-rdr 1))
  ([s-or-rdr buf-len]
   (indexing-push-back-reader s-or-rdr buf-len nil))
  ([s-or-rdr buf-len file-name]
   (IndexingPushbackReader.
    (if (string? s-or-rdr)
      (string-push-back-reader s-or-rdr buf-len)
      s-or-rdr)
    (atom 1)     ;; line
    (atom 1)     ;; column
    (atom true)  ;; line-start?
    (atom nil)   ;; prev
    (atom 0)     ;; prev-column
    file-name)))

(defn read-line [rdr]
  (loop [sb ""]
    (let [ch (read-char rdr)]
      (if (or (newline? ch) (nil? ch))
        sb
        (recur (str sb ch))))))

(defn line-start? [rdr]
  (when (indexing-reader? rdr)
    (= 1 (get-column-number rdr))))
