;;; dsh-conversation.el --- DSH conversation buffers (render, prompt, poll) -*- lexical-binding: t; -*-

;; One DSH session maps to one read-only conversation buffer rendering the
;; folded history (dsh-history.el). Turn activity is followed by polling
;; (v1 has no WebSocket downlink); approval/question server-requests must
;; be answered from another attached client (e.g. the Web GUI) for now.

;;; Code:

(require 'cl-lib)
(require 'dsh-connection)
(require 'dsh-history)

(defgroup dsh nil
  "Emacs client for DeepSeek Harness (DSH)."
  :prefix "dsh-"
  :group 'tools)

(defcustom dsh-poll-interval 1.0
  "Seconds between history polls while a turn is running."
  :type 'number
  :group 'dsh)

(defcustom dsh-history-window 400
  "How many surface messages of the history tail to render."
  :type 'integer
  :group 'dsh)

(defface dsh-face-user '((t :weight bold)) "User messages.")
(defface dsh-face-assistant '((t nil)) "Assistant text.")
(defface dsh-face-reasoning '((t :inherit shadow :slant italic)) "Thinking text.")
(defface dsh-face-tool-title '((t :foreground "dark cyan")) "Folded tool line.")
(defface dsh-face-tool-output '((t :inherit shadow)) "Tool output.")
(defface dsh-face-header '((t :inherit header-line)) "Status header.")

(defvar-local dsh--session nil)
(defvar-local dsh--watch-timer nil)

(defvar dsh-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'dsh-send-prompt)
    (define-key map (kbd "i") #'dsh-send-prompt)
    (define-key map (kbd "TAB") #'dsh-cycle-tool)
    (define-key map (kbd "g") #'dsh-refresh)
    (define-key map (kbd "c") #'dsh-cancel-turn)
    map))

(define-derived-mode dsh-conversation-mode special-mode "DSH"
  "Major mode for one DSH session's conversation buffer."
  (setq-local truncate-lines t)
  (setq-local header-line-format
              (substitute-command-keys
               "\<dsh-conversation-mode-map>对话: \\[dsh-send-prompt]  折叠工具: \\[dsh-cycle-tool]  刷新: \\[dsh-refresh]  取消: \\[dsh-cancel-turn]  会话列表: \\[dsh-session-list]")))

;;;###autoload
(defun dsh-open-session (session-id)
  "Open SESSION-ID's conversation buffer, rendering its history."
  (interactive "sSession id: ")
  (let ((buf (dsh--buf session-id)))
    (with-current-buffer buf
      (unless (eq major-mode 'dsh-conversation-mode)
        (dsh-conversation-mode))
      (setq dsh--session session-id)
      (dsh-refresh)
      (goto-char (point-max)))
    (pop-to-buffer buf)))

;;;###autoload
(defun dsh-new-session (&optional cwd)
  "Create a DSH session in CWD (default `default-directory') and open it."
  (interactive)
  (let* ((dir (expand-file-name (or cwd default-directory)))
         (value (dsh-rpc "session.create" `((cwd . ,dir)))))
    (dsh-open-session (alist-get 'sessionId value))))

(defun dsh--buf (session-id)
  (get-buffer-create (format "*dsh:%s*" (substring session-id 0 16))))

(defun dsh-refresh ()
  "Re-render the conversation buffer from the current history tail."
  (interactive)
  (unless dsh--session
    (user-error "Buffer is not attached to a DSH session"))
  (let ((inhibit-read-only t)
        (follow (>= (point) (point-max)))   ; stick to the tail when at it
        (pos (point)))
    (erase-buffer)
    (dsh--render-header)
    (let* ((fetched (dsh-history-fetch dsh--session dsh-history-window))
           (events (nth 0 fetched))
           (msgs (dsh-history-fold events)))
      (dolist (msg msgs)
        (dsh--render-msg msg)))
    (goto-char (if follow (point-max) (min pos (point-max))))))

(defun dsh--session-summary (session-id)
  "Fetch the session.list row of SESSION-ID (nil when absent)."
  (let ((value (dsh-rpc "session.list")))
    (cl-find-if (lambda (s) (equal (alist-get 'sessionId s) session-id))
                (append (alist-get 'items value) nil))))

(defun dsh--true (v)
  "JSON booleans arrive as t/:json-false; normalize to Lisp truth."
  (not (eq v :json-false)))

(defun dsh--render-header ()
  "Insert the session status line."
  (let* ((sum (dsh--session-summary dsh--session))
         (proj (when sum (alist-get 'values (alist-get 'projections sum))))
         (running (and sum (alist-get 'running sum)))
         (title (or (alist-get 'title proj) "(DSH session)"))
         (pressure (alist-get 'contextPressure proj))
         (ctx (let ((proj-toks (alist-get 'projectedTokens pressure))
                    (window (alist-get 'contextWindow pressure)))
                (if (and (numberp proj-toks) (numberp window) (> window 0))
                    (format "ctx %.0f%%" (* 100 (/ (float proj-toks) window)))
                  ""))))
    (insert (propertize
             (format " %s  %s  %s" title ctx
                     (if (dsh--true running) (propertize "● running" 'face 'bold) "○ idle"))
             'face 'dsh-face-header))
    (insert "\n\n")))

(defun dsh--indent (text)
  (mapconcat (lambda (line) (concat "  " line))
             (split-string (string-trim text) "\n") "\n"))

(defun dsh--render-msg (msg)
  "Render one folded `dsh-msg' MSG."
  (cond
   ((eq (dsh-msg-kind msg) 'user)
    (insert (propertize
             (concat "You ▸ " (string-trim (or (dsh-msg-text msg) "")) "\n")
             'face 'dsh-face-user))
    (insert "\n"))
   ((eq (dsh-msg-kind msg) 'assistant)
    (dsh--render-assistant msg))
   ((eq (dsh-msg-kind msg) 'tool)
    (dsh--render-tool-line
     (dsh--tool-title (or (dsh-msg-tool-name msg) "tool") nil
                      (dsh-msg-tool-card msg))
     (dsh-msg-tool-output msg)
     (dsh-msg-tool-id msg)))
   ((eq (dsh-msg-kind msg) 'turn-end)
    (insert "\n"))))

(defun dsh--render-assistant (msg)
  "Render one assistant MSG with thinking, text and tool calls."
  (let ((reasoning (or (dsh-msg-reasoning msg) ""))
        (text (or (dsh-msg-text msg) "")))
    (unless (string-empty-p reasoning)
      (insert (propertize (dsh--indent reasoning)
                          'face 'dsh-face-reasoning))
      (insert "\n"))
    (unless (string-empty-p text)
      (insert (propertize (concat (dsh--indent text) "\n")
                          'face 'dsh-face-assistant))
      (insert "\n"))
    (dolist (call (dsh-msg-tool-calls msg))
      (let* ((id (nth 0 call))
             (result (gethash id (dsh-msg-results msg))))
        (dsh--render-tool-line
         (dsh--tool-title (nth 1 call) (nth 2 call)
                          (and result (dsh-msg-tool-card result)))
         (and result (dsh-msg-tool-output result))
         id)))
    (dolist (stray (dsh-msg-stray-results msg))
      (dsh--render-tool-line
       (dsh--tool-title (or (dsh-msg-tool-name stray) "tool") nil
                        (dsh-msg-tool-card stray))
       (dsh-msg-tool-output stray)
       (dsh-msg-tool-id stray)))))

(defun dsh--tool-title (name args card)
  "One-line title for tool NAME with JSON ARGS and host CARD kind."
  (let ((short args))
    (when (equal card "terminal")
      (let ((parsed (condition-case nil (json-read-from-string args)
                      (error nil))))
        (when parsed
          (setq short (alist-get 'command parsed)))))
    (setq short (or short ""))
    (setq short (replace-regexp-in-string "[\n\r]+" " " short))
    (when (> (length short) 120)
      (setq short (concat (substring short 0 120) "…")))
    (format "%s: %s" name short)))

(defun dsh--render-tool-line (title output call-id)
  "Render one foldable tool line with TITLE.
OUTPUT, when non-empty, is the hidden body toggled by TAB."
  (insert "  ⚙ ")
  (insert (propertize title 'face 'dsh-face-tool-title 'dsh-tool call-id))
  (when (and output (not (string-empty-p output)))
    (let* ((shown (if (> (length output) 4000)
                      (concat (substring output 0 4000) "\n  …(truncated)")
                    output))
           (text (dsh--indent shown)))
      (insert "\n")
      (let ((out-begin (point)))
        (insert (propertize text 'face 'dsh-face-tool-output))
        (put-text-property out-begin (point) 'invisible 'dsh-tool-out)
        (put-text-property (1- out-begin) out-begin 'dsh-tool-toggle
                           (cons out-begin (point)))))))

(defun dsh-cycle-tool ()
  "Toggle the tool output expansion near point."
  (interactive)
  (if (get-text-property (point) 'dsh-tool-toggle)
      (dsh--cycle-at (point))
    (let ((pos (previous-single-property-change
                (point) 'dsh-tool-toggle nil (point-min))))
      (when pos
        (goto-char (max (point-min) (1- pos)))
        (dsh--cycle-at (point))))))

(defun dsh--cycle-at (pos)
  "Toggle invisibility of the output span whose toggle marker sits at POS."
  (let ((span (get-text-property pos 'dsh-tool-toggle)))
    (when (consp span)
      (let ((beg (car span))
            (end (cdr span)))
        (if (eq (get-text-property beg 'invisible) 'dsh-tool-out)
            (remove-text-properties beg end '(invisible nil))
          (put-text-property beg end 'invisible 'dsh-tool-out))))))

(defun dsh-send-prompt ()
  "Read a prompt from the minibuffer and send it to this session."
  (interactive)
  (unless dsh--session
    (user-error "Buffer is not attached to a DSH session"))
  (let ((text (read-string "dsh ▸ ")))
    (unless (string-empty-p (string-trim text))
      (dsh-rpc "session.prompt"
               `((sessionId . ,dsh--session)
                 (mode . "queue")
                 (content . [((type . "text") (text . ,text))])))
      (dsh--watch-turn))))

(defun dsh-cancel-turn ()
  "Cancel the active turn of this session."
  (interactive)
  (dsh-rpc "session.cancel" `((sessionId . ,dsh--session)))
  (message "dsh: cancel requested"))

(defun dsh--watch-turn ()
  "Poll history until the turn quiesces, refreshing the buffer."
  (let ((buf (current-buffer)))
    (setq dsh--watch-timer
          (run-with-timer
           dsh-poll-interval nil
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (dsh-refresh)
                 (let ((sum (dsh--session-summary dsh--session)))
                   (if (and sum (dsh--true (alist-get 'running sum)))
                       (dsh--watch-turn)
                     (message "dsh: turn finished"))))))))))

(provide 'dsh-conversation)
;;; dsh-conversation.el ends here
