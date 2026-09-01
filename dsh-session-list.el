;;; dsh-session-list.el --- DSH session browser (tabulated-list) -*- lexical-binding: t; -*-

;;; Code:

(require 'tabulated-list)
(require 'cl-lib)
(require 'dsh-connection)
(require 'dsh-conversation)

(defun dsh--true (v)
  "JSON booleans arrive as t/:json-false; normalize to Lisp truth."
  (not (eq v :json-false)))

(defvar dsh-session-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'dsh-session-list-open)
    (define-key map (kbd "n") #'dsh-session-list-new)
    (define-key map (kbd "g") #'dsh-session-list-refresh)
    (define-key map (kbd "a") #'dsh-session-list-archive)
    (define-key map (kbd "A") #'dsh-session-list-toggle-archived)
    (define-key map (kbd "s") #'dsh-session-list-toggle-subagents)
    (define-key map (kbd "b") #'dsh-session-list-toggle-blank)
    map))

(define-derived-mode dsh-session-list-mode tabulated-list-mode "DSH Sessions"
  "List DSH sessions of the connected host."
  (setq tabulated-list-format
        [("Title" 44 t)
         ("Status" 9 t)
         ("Model" 16 nil)
         ("Context" 9 t)
         ("Updated" 12 t)
         ("cwd" 30 nil)])
  (setq tabulated-list-sort-key '("Updated" . t))
  (tabulated-list-init-header))

(defvar-local dsh--show-archived nil
  "When non-nil, archived sessions are listed (marked) instead of hidden.")

(defvar-local dsh--show-subagents nil
  "When non-nil, subagent sessions (origin=subagent) are listed too.

The Web sidebar never lists them standalone; each lives nested under its
parent session. Default hidden to mirror that visibility.")

(defvar-local dsh--show-blank nil
  "When non-nil, blank sessions (no turn ever run) are listed too.

The Web hides blank sessions and reuses one per workspace on demand;
untitled blank leftovers from abandoned new-chat gestures never become
visible there. Default hidden to mirror that visibility.")

(defun dsh-session-list--archived-ids ()
  "Set (hash table) of archived session ids from workspace.list."
  (let ((value (dsh-rpc "workspace.list"))
        (set (make-hash-table :test 'equal)))
    (dolist (id (append (alist-get 'archivedSessionIds value) nil))
      (puthash id t set))
    set))

(defun dsh-session-list--subagent-p (summary)
  "Non-nil when session SUMMARY is a subagent descendant session."
  (or (equal (alist-get 'origin summary) "subagent")
      (alist-get 'parentSessionId summary)))

(defun dsh-session-list--rows ()
  "Build tabulated rows from session.list, honoring the archive filter."
  (let* ((value (dsh-rpc "session.list"))
         (archived (dsh-session-list--archived-ids))
         (rows nil))
    (dolist (s (append (alist-get 'items value) nil))
      (let* ((id (alist-get 'sessionId s))
             (archived-p (gethash id archived))
             (proj (alist-get 'values (alist-get 'projections s)))
             (title (or (alist-get 'title proj) "(untitled)"))
             (running (alist-get 'running s))
             (blank (alist-get 'blank s))
             (usage (alist-get 'tokenUsage proj))
             (pressure (alist-get 'contextPressure proj))
             (ctx (let ((proj-toks (alist-get 'projectedTokens pressure))
                        (window (alist-get 'contextWindow pressure)))
                    (if (and (numberp proj-toks) (numberp window) (> window 0))
                        (format "%.0f%%" (* 100 (/ (float proj-toks) window)))
                      "")))
             (model (let ((in (alist-get 'uncachedInputTokens usage))
                          (out (alist-get 'outputTokens usage)))
                      (if (and (numberp in) (numberp out))
                          (format "%sk" (round (/ (+ in out) 1024.0)))
                        "")))
             (updated (let ((ts (alist-get 'updatedAt s)))
                        (if (numberp ts)
                            (format-time-string "%m-%d %H:%M" (/ ts 1000))
                          "")))
             (cwd (or (alist-get 'cwd s) ""))
             (subagent-p (dsh-session-list--subagent-p s)))
        (when (and (or dsh--show-archived (not archived-p))
                   (or dsh--show-subagents (not subagent-p))
                   (or dsh--show-blank (not (dsh--true blank))))
          (push
           (list id
                 (vector title
                         (propertize
                          (cond ((dsh--true running) "running")
                                ((dsh--true blank) "blank")
                                (t "idle"))
                          'face (if (dsh--true running) 'bold 'shadow))
                         (cond (archived-p
                                (propertize "archived" 'face 'italic))
                               (subagent-p
                                (propertize "sub" 'face 'italic))
                               (t model))
                         ctx
                         updated
                         cwd))
           rows))))
    (nreverse rows)))

(defun dsh-session-list-refresh ()
  "Refresh the session list buffer."
  (interactive)
  (setq tabulated-list-entries (dsh-session-list--rows))
  (tabulated-list-print))

(defun dsh-session-list ()
  "Open the DSH session browser, spawning a host if none is reachable."
  (interactive)
  (dsh-ensure-host)
  (let ((buf (get-buffer-create "*dsh:sessions*")))
    (with-current-buffer buf
      (dsh-session-list-mode)
      (dsh-session-list-refresh))
    (pop-to-buffer buf)))

(defun dsh-session-list--session-at-point ()
  (or (tabulated-list-get-id)
      (user-error "No session at point")))

(defun dsh-session-list-open ()
  "Open the session at point in a conversation buffer."
  (interactive)
  (dsh-open-session (dsh-session-list--session-at-point)))

(defun dsh-session-list-archive ()
  "Archive the session at point after confirmation.
Archiving hides it from grouping surfaces without touching its log."
  (interactive)
  (let* ((id (dsh-session-list--session-at-point))
         (entry (tabulated-list-get-entry))
         (title (if entry (aref entry 0) "(untitled)")))
    (when (yes-or-no-p
           (format "Archive session %s (%s)? " title (substring id 0 16)))
      (dsh-rpc "workspace.archiveSession" `((sessionId . ,id)))
      (message "dsh: session archived")
      (dsh-session-list-refresh))))

(defun dsh-session-list-toggle-blank ()
  "Toggle whether blank sessions are listed."
  (interactive)
  (setq dsh--show-blank (not dsh--show-blank))
  (dsh-session-list-refresh))

(defun dsh-session-list-toggle-subagents ()
  "Toggle whether subagent sessions are listed."
  (interactive)
  (setq dsh--show-subagents (not dsh--show-subagents))
  (dsh-session-list-refresh))

(defun dsh-session-list-toggle-archived ()
  "Toggle whether archived sessions are listed."
  (interactive)
  (setq dsh--show-archived (not dsh--show-archived))
  (dsh-session-list-refresh))

(defun dsh-session-list-new ()
  "Create a session in cwd read from the minibuffer and open it."
  (interactive)
  (let* ((cwd (read-directory-name "New DSH session cwd: " nil nil t))
         (value (dsh-rpc "session.create" `((cwd . ,(expand-file-name cwd))))))
    (dsh-open-session (alist-get 'sessionId value))))

(provide 'dsh-session-list)
;;; dsh-session-list.el ends here
