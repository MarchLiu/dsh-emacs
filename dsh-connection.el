;;; dsh-connection.el --- RPC carrier for the DSH /api bridge -*- lexical-binding: t; -*-

;; dsh-connection owns the client↔host wire: POST /api/<method> with the
;; four-quadrant envelope ({type: client-request, rpcId, method, payload}),
;; parse the {type: server-response, rpcId, result:{ok, value|error}} reply.
;; Mirrors dsh-client-connection's contract; the WebSocket downlinks
;; (/api/events.mux, /api/events.host) are deliberately not used in v1 —
;; this carrier is unary-request only, so sessions are watched by polling.

;;; Code:

(require 'json)
(require 'cl-lib)

(defgroup dsh nil
  "Emacs client for DeepSeek Harness (DSH)."
  :prefix "dsh-"
  :group 'tools)

(defcustom dsh-api-base "http://127.0.0.1:3080"
  "Base URL of the DSH web host (the /api bridge origin)."
  :type 'string
  :group 'dsh)

(defcustom dsh-curl-program "curl"
  "curl executable used as the HTTP transport."
  :type 'string
  :group 'dsh)

(defvar dsh--rpc-id 0)

;;; Host lifecycle: like `dsh --profile tui`, the client can own its harness
;;; process. `dsh-start-host' spawns a dedicated `dsh --profile web' child
;;; (`--no-open', a free local port), waits for the /api bridge to answer,
;;; and repoints `dsh-api-base' at it; `dsh-stop-host' tears it down.

(defcustom dsh-cli-program "dsh"
  "dsh CLI executable used to spawn a dedicated host."
  :type 'string
  :group 'dsh)

(defcustom dsh-host-profile "web"
  "Profile used when spawning a dedicated host."
  :type 'string
  :group 'dsh)

(defcustom dsh-host-start-timeout 30
  "Seconds to wait for a spawned host to answer its first RPC."
  :type 'number
  :group 'dsh)

(defvar dsh-host-process nil)
(defvar dsh-host-port nil)

(defun dsh--free-port ()
  "Ask the OS for a free TCP port on loopback."
  (let ((proc (make-network-process
               :name "dsh-port-probe" :family 'ipv4
               :host "127.0.0.1" :service 0 :server t)))
    (let ((port (process-contact proc :service)))
      (delete-process proc)
      port)))

(defun dsh--host-alive-p ()
  (and dsh-host-process (process-live-p dsh-host-process)))

(defun dsh-start-host ()
  "Spawn a dedicated DSH web host and wait until its /api bridge answers."
  (interactive)
  (if (dsh--host-alive-p)
      (message "dsh host already running (port %s)" dsh-host-port)
    (let* ((port (dsh--free-port))
           (proc (start-process
                  "dsh-host" "*dsh:host*"
                  dsh-cli-program "--profile" dsh-host-profile
                  "--port" (number-to-string port) "--no-open")))
      (setq dsh-host-process proc
            dsh-host-port port
            dsh-api-base (format "http://127.0.0.1:%d" port))
      (message "dsh: starting host on port %d..." port)
      (let ((deadline (+ (float-time) dsh-host-start-timeout))
            ready)
        (while (and (not ready) (< (float-time) deadline)
                    (process-live-p proc))
          (sit-for 0.5)
          (setq ready (ignore-errors (dsh-rpc "host.describe"))))
        (cond
         (ready (message "dsh host ready on port %d" port))
         (t (setq dsh-host-process nil dsh-host-port nil)
            (error "dsh host failed to start; see buffer *dsh:host*"))))
      port)))

(defun dsh-stop-host ()
  "Stop the client-spawned DSH host, if any."
  (interactive)
  (when (dsh--host-alive-p)
    (delete-process dsh-host-process)
    (setq dsh-host-process nil dsh-host-port nil)
    (message "dsh host stopped")))

(defun dsh-ensure-host ()
  "Return non-nil when a /api bridge is reachable, starting one if needed."
  (or (ignore-errors (dsh-rpc "host.describe"))
      (progn (dsh-start-host) (dsh-rpc "host.describe"))))

(defun dsh-rpc (method &optional payload)
  "Call METHOD with PAYLOAD on the DSH host; return result.value.
Signals `dsh-rpc-error' on transport or business failure."
  (cl-incf dsh--rpc-id)
  (let* ((body (json-encode
                `((type . "client-request")
                  (rpcId . ,(format "emacs-%d" dsh--rpc-id))
                  (method . ,method)
                  (payload . ,(or payload (make-hash-table))))))
         (url (concat dsh-api-base "/api/" method))
         (args (list "--silent" "--show-error" "--max-time" "30"
                     "-X" "POST" url
                     "-H" "Content-Type: application/json"
                     "--data-binary" "@-")))
    (with-temp-buffer
      (insert body)
      (let ((exit (apply #'call-process-region
                         (point-min) (point-max) dsh-curl-program
                         t t nil args)))
        (unless (zerop exit)
          (error "dsh-rpc: curl failed (%d) for %s" exit method))
        (let* ((reply (condition-case err
                          (json-read-from-string (buffer-string))
                        (error
                         (error "dsh-rpc: bad JSON from %s: %S" method err))))
               (result (alist-get 'result reply))
               (ok (alist-get 'ok result)))
          (unless ok
            (let ((err (alist-get 'error result)))
              (signal 'dsh-rpc-error
                      (list method
                            (alist-get 'code err)
                            (alist-get 'message err)))))
          (alist-get 'value result))))))

(define-error 'dsh-rpc-error "dsh RPC error" 'error)

(defun dsh-rpc-message (err)
  "Human-readable text for `dsh-rpc-error' ERR."
  (pcase-let ((`(,method ,code ,message) (cdr err)))
    (format "%s failed [%s]: %s" method code message)))

(provide 'dsh-connection)
;;; dsh-connection.el ends here
