(ns woj.nrepl
  (:require [woj.repl :as repl]
            [nrepl.server :as nrepl-server]
            [nrepl.middleware :as middleware]
            [nrepl.transport :as transport]
            [clojure.java.io :as io]))

;; ============================================
;; Per-session State
;; ============================================

(def ^:private session-states (atom {}))

(defn- get-session-state [session-id]
  (or (get @session-states session-id)
      (let [state (repl/make-repl-state)]
        (swap! session-states assoc session-id state)
        state)))

;; ============================================
;; Eval Handler
;; ============================================

(defn- eval-handler [handler]
  (fn [{:keys [op code session transport] :as msg}]
    (if (= op "eval")
      (let [state (get-session-state (str session))
            result (repl/eval-string code state)]
        (if (:error result)
          (do
            (transport/send transport
                            (merge (select-keys msg [:id :session])
                                   {:err (str (:error result) "\n")
                                    :status #{:done :eval-error}}))
            ;; Also send done status
            (transport/send transport
                            (merge (select-keys msg [:id :session])
                                   {:status #{:done}})))
          (do
            (transport/send transport
                            (merge (select-keys msg [:id :session])
                                   {:value (:value result)
                                    :ns "woj.user"}))
            (transport/send transport
                            (merge (select-keys msg [:id :session])
                                   {:status #{:done}})))))
      (handler msg))))

(middleware/set-descriptor! #'eval-handler
  {:requires #{"clone" "close"}
   :expects #{}
   :handles {"eval" {:doc "Evaluates woj code via woj compiler + wasmtime"
                     :requires {"code" "The code to evaluate"}
                     :returns {"value" "The result of evaluation"}}}})

;; ============================================
;; Server
;; ============================================

(defn start-nrepl
  "Start an nREPL server for woj."
  [& {:keys [port] :or {port 7888}}]
  (let [server (nrepl-server/start-server
                 :port port
                 :handler (nrepl-server/default-handler #'eval-handler))]
    ;; Write .nrepl-port for editor auto-discovery
    (spit ".nrepl-port" (str port))
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. (fn []
                                 (io/delete-file ".nrepl-port" true)
                                 (nrepl-server/stop-server server))))
    (println (str "woj nREPL server started on port " (:port server)))
    (println (str "Connect with: cider-connect localhost:" (:port server)))
    server))

(defn -main [& args]
  (let [port (if (seq args) (parse-long (first args)) 7888)]
    (start-nrepl :port port)
    ;; Keep alive
    @(promise)))
