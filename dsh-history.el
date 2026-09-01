;;; dsh-history.el --- fetch and fold DSH session history into messages -*- lexical-binding: t; -*-

;; dsh-history pages session.history and folds the raw event stream into a
;; compact message view for rendering. The durable log carries streaming
;; noise (assistant/chunk dupes, step lifecycle, usage) that the Web client
;; folds client-side; we keep only the surface-bearing types:
;;   user/message, assistant/message, tool/call, tool/result, turn/end.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'dsh-connection)

(cl-defstruct dsh-msg
  kind          ; user | assistant | tool | turn-end
  seq
  text          ; user text or assistant text
  reasoning     ; assistant thinking text (optional)
  tool-calls    ; assistant: list of (id name args)
  tool-id       ; tool result: callId
  tool-name     ; tool result: name (joined from the matching call when known)
  tool-output   ; tool result: text
  tool-card     ; tool result: host view card kind (terminal/diff/generic)
  tool-exit     ; tool result: exitCode when the view carries one
  results       ; assistant: hash callId -> result dsh-msg
  stray-results) ; assistant: unmatched result dsh-msgs at the cold tail

(defun dsh--parts-text (content)
  "Concatenate the text parts of message CONTENT blocks."
  (mapconcat
   (lambda (part)
     (when (equal (alist-get 'type part) "text")
       (alist-get 'text part)))
   (append content nil) ""))

(defun dsh-history-fetch (session-id &optional max-messages)
  "Fetch the tail history window of SESSION-ID.
Returns (events has-more) where events is the raw alist list."
  (let* ((payload `((sessionId . ,session-id)))
         (payload (if max-messages
                      (append payload `((maxMessages . ,max-messages)))
                    payload))
         (value (dsh-rpc "session.history" payload)))
    (list (append (alist-get 'events value) nil)
          (alist-get 'hasMore value))))

(defun dsh--result-msg (data view)
  "Build a result dsh-msg from a tool/result DATA plus its host VIEW."
  (let* ((message (alist-get 'message data))
         (result (car (append (alist-get 'content message) nil)))
         (out-parts (append (alist-get 'content result) nil)))
    (make-dsh-msg
     :kind 'tool
     :tool-id (alist-get 'toolCallId result)
     :tool-output (mapconcat (lambda (p) (or (alist-get 'text p) ""))
                             out-parts "")
     :tool-card (and view (alist-get 'card (alist-get 'view view)))
     :tool-exit (and view (alist-get 'exitCode (alist-get 'view view))))))

(defun dsh-history-fold (events)
  "Fold raw history EVENTS into a list of `dsh-msg' (oldest first).
Tool results are attached to the assistant tool-call with the same
callId; results whose assistant block fell outside the fetched window
are surfaced as stray-results on the nearest following assistant msg."
  (let ((msgs nil))
    (let ((last-assistant nil))
      (dolist (entry events)
        (let* ((event (alist-get 'event entry))
               (type (alist-get 'type event))
               (seq (alist-get 'seq event))
               (data (alist-get 'data event))
               (view (alist-get 'view entry)))
          (pcase type
            ("user/message"
             (setq last-assistant nil)
             (push (make-dsh-msg
                    :kind 'user :seq seq
                    :text (dsh--parts-text
                           (or (alist-get 'content data)
                               (alist-get 'content
                                          (alist-get 'message data)))))
                   msgs))
            ("assistant/message"
             (let* ((content (append (alist-get 'content
                                                (alist-get 'message data))
                                     nil))
                    (text (mapconcat
                           (lambda (p)
                             (when (equal (alist-get 'type p) "text")
                               (alist-get 'text p)))
                           content ""))
                    (reasoning (mapconcat
                                (lambda (p)
                                  (when (equal (alist-get 'type p) "reasoning")
                                    (alist-get 'text p)))
                                content ""))
                    (calls (delq nil
                                 (mapcar
                                  (lambda (p)
                                    (when (equal (alist-get 'type p) "tool-call")
                                      (list (alist-get 'id p)
                                            (alist-get 'name p)
                                            (alist-get 'arguments p))))
                                  content))))
               (setq last-assistant
                     (make-dsh-msg :kind 'assistant :seq seq
                                   :text text :reasoning reasoning
                                   :tool-calls calls
                                   :results (make-hash-table :test 'equal)
                                   :stray-results nil))
               (push last-assistant msgs)))
            ("tool/result"
             (let ((r (dsh--result-msg data view)))
               ;; Attach chronologically: stray results (assistant block
               ;; outside the fetched window) ride the nearest assistant.
               (if last-assistant
                   (push r (dsh-msg-stray-results last-assistant))
                 (push r msgs))))
            ("turn/end"
             (push (make-dsh-msg :kind 'turn-end :seq seq) msgs)))))
      ;; Move each stray onto its matching call when the id is known.
      (dolist (msg msgs)
        (when (eq (dsh-msg-kind msg) 'assistant)
          (dolist (stray (dsh-msg-stray-results msg))
            (let ((id (dsh-msg-tool-id stray)))
              (when (and id (cl-find id (dsh-msg-tool-calls msg)
                                     :key (lambda (c) (nth 0 c)) :test 'equal))
                (puthash id stray (dsh-msg-results msg))
                (setf (dsh-msg-stray-results msg)
                      (delete stray (dsh-msg-stray-results msg))))))))
      (nreverse msgs))))

(provide 'dsh-history)
;;; dsh-history.el ends here
