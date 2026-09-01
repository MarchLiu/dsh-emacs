;;; dsh-eval.el --- AI-driven elisp eval gateway for a running Emacs -*- lexical-binding: t; -*-

;; Reverse bridge of dsh-emacs: lets an AI session (via the `bin/dsh-eval'
;; CLI and `emacsclient --eval') evaluate freshly constructed elisp in THIS
;; running Emacs — no restart needed.  Every request is risk-classified:
;;
;;   safe    — read-only/pure forms (inspection, formatting, message)
;;             auto-executed under every policy.
;;   change  — anything else that is not explicitly flagged (setq,
;;             customize-set-variable, dsh-* commands, buffer/window ops)
;;             gated by `dsh-eval-allow-level'.
;;   danger  — matches `dsh-eval-danger-regexps' (shell-command,
;;             delete-file, kill-emacs, ...): always confirmed unless the
;;             user explicitly lowers `dsh-eval-danger-always-confirm'.
;;
;; Wire format (request file):
;;   ;;; dsh-eval-request
;;   ;;; meta: ((source . "ai") (purpose . "why this code runs"))
;;   <elisp code, one or more forms>
;; Response file (<req>.resp), first line "STATUS\tsummary":
;;   ok | denied | error, remaining lines: prin1 of the last value.

;;; Code:

(require 'cl-lib)
(require 'json nil t)

(defgroup dsh-eval nil
  "AI -> running-Emacs elisp eval gateway."
  :prefix "dsh-eval-"
  :group 'dsh)

(defcustom dsh-eval-spool-dir
  (expand-file-name "dsh-eval" user-emacs-directory)
  "Directory where CLI requests and Emacs responses are exchanged."
  :type 'directory
  :group 'dsh-eval)

(defcustom dsh-eval-allow-level 'confirm
  "How much the AI may run without asking.
  safe     auto-run only risk level `safe'; everything else denied.
  confirm  auto-run `safe'; prompt (y-or-n-p in Emacs) for the rest.
  all      auto-run everything except `danger'."
  :type '(choice (const :tag "Only safe forms" safe)
                 (const :tag "Confirm non-safe forms" confirm)
                 (const :tag "Auto-run all but danger" all))
  :group 'dsh-eval)

(defcustom dsh-eval-danger-always-confirm t
  "If non-nil, `danger'-level code prompts even when level is `all'."
  :type 'boolean
  :group 'dsh-eval)

(defcustom dsh-eval-result-limit 4000
  "Truncate printed results to this many characters."
  :type 'natnum
  :group 'dsh-eval)

(defconst dsh-eval--special-forms
  '(progn prog1 prog2 let let* if cond when unless while and or quote
    function lambda interactive cond-alist with-current-buffer
    save-current-buffer save-excursion save-restriction save-window-excursion
    with-temp-buffer with-temp-file condition-case unwind-protect catch throw
    track-mouse dolist dotimes pcase seq-doseq cl-loop loop delay-mode-hooks
    combine-after-change-calls ignore-errors with-demoted-errors
    with-slots with-output-to-string with-temp-message)
  "Forms whose head is allowed and whose body is walked recursively.")

(defconst dsh-eval--safe-functions
  '(buffer-list buffer-name buffer-file-name buffer-size buffer-string
    buffer-substring buffer-substring-no-properties point point-min point-max
    point-marker line-beginning-position line-end-position line-number-at-pos
    position-bytes bobp eobp bolp eolp beginning-of-line end-of-line
    char-after char-before following-char preceding-char
    window-list window-buffer window-point window-frame window-dedicated-p
    selected-window selected-frame frame-list window-frame frame-parameter
    frame-parameters window-parameters get-buffer get-buffer-window
    get-buffer-create generate-new-buffer buffer-name buffer-live-p
    window-live-p frame-live-p window-valid-p frame-visible-p
    buffer-local-variables buffer-modified-p buffer-size
    boundp fboundp symbol-value default-value symbol-name symbol-plist
    indirect-variable local-variable-p default-boundp
    format format-message message prin1-to-string princ prin1 print terpri
    + - * / = < > <= >= 1+ 1- mod % min max abs expt sqrt floor ceiling
    truncate round
    concat length safe-length listp consp stringp numberp integerp floatp
    symbolp sequencep nlistp zerop natnump wholenump
    list append reverse nreverse copy-sequence copy-alist copy-tree
    nth nthcdr last butlast car cdr caar cadr cdar cddr caddr
    assoc assq alist-get rassoc rassq member memq memql
    mapcar mapc mapconcat seq-map seq-filter seq-remove seq-sort seq-into
    seq-length seq-elt seq-do seq-reduce seq-contains-p seq-find
    string-trim string-trim-left string-trim-right string-empty-p
    string-blank-p string-join string-split split-string
    string-prefix-p string-suffix-p string-match string-match-p
    replace-regexp-in-string regexp-quote substring
    upcase downcase capitalize string-to-number number-to-string
    string-to-list string-to-vector vconcat append
    file-exists-p file-directory-p file-regular-p file-symlink-p
    file-readable-p file-attributes file-nlinks file-size
    directory-files directory-files-and-attributes
    expand-file-name file-name-directory file-name-nondirectory
    file-name-extension file-name-sans-extension file-truename
    locate-file executable-find getenv
    time-to-seconds float-time current-time format-time-string
    read read-from-string ignore identity error user-error signal
    called-interactively-p string-prefix-p cl-position cl-member
    cl-find cl-remove cl-remove-if cl-remove-if-not cl-count
    cl-loop cl-incf cl-decf cl-pushnew cl-assoc cl-every cl-some
    json-serialize json-read-from-string json-parse-string)
  "Functions considered read-only/pure (risk level `safe').")

(defconst dsh-eval--danger-regexps
  '("\\<\\(kill-emacs\\|save-buffers-kill-emacs\\|save-buffers-kill-terminal\\)\\>"
    "\\<\\(shell-command\\|shell-command-to-string\\|async-shell-command\\)\\>"
    "\\<\\(call-process\\|call-process-region\\|start-process\\|start-file-process\\)\\>"
    "\\<\\(delete-file\\|delete-directory\\|rename-file\\|copy-file\\|make-symbolic-link\\|add-name-to-file\\)\\>"
    "\\<\\(write-region\\|append-to-file\\|write-file\\|dired-delete-file\\)\\>"
    "\\<\\(setenv\\|load\\|load-file\\|require\\|provide\\|eval-buffer\\|eval-region\\|eval-last-sexp\\)\\>"
    "\\<\\(delete-process\\|kill-buffer\\|server-start\\|server-stop\\)\\>"
    "\\<\\(network-stream\\|make-network-process\\|url-retrieve\\|request\\)\\>"
    "\\<\\(desktop-kill\\|kill-rectangle\\|erase-buffer\\)\\>")
  "Code matching any of these regexps is `danger' level.")

(defvar dsh-eval--log-buffer "*dsh-eval requests*")

(defun dsh-eval--collect-symbols (form)
  "Collect every symbol used in a function position inside FORM.
Binding names, variable references and quoted data are ignored."
  (let ((syms ()))
    (cl-labels
        ((walk (x)
           (pcase x
             (`(,(or 'let 'let*) ,bindings . ,body)
              (dolist (b bindings)
                (pcase b
                  ((pred symbolp) nil)        ; (let (x) ...)
                  (`(,_ ,v) (walk v))))       ; walk value only
              (mapc #'walk body))
             (`(,(or 'lambda 'closure) ,_args . ,body)
              (mapc #'walk body))
             (`(,(or 'dolist 'dotimes 'cond-alist) (,_var ,init . ,_rest) . ,body)
              (walk init)
              (mapc #'walk body))
             (`(,(or 'quote 'function) (lambda . ,rest))
              (mapc #'walk (cddr rest)))
             (`(,(or 'quote 'function) . ,_) nil) ; quoted data is inert
             (`(,(pred symbolp) . ,args)      ; function call position
              (push (car x) syms)
              (mapc #'walk args))
             (`(,(pred consp) . ,args)        ; ((lambda ...) args)
              (walk (car x))
              (mapc #'walk args))
             (_ nil))))
      (walk form))
    (nreverse syms)))

(defun dsh-eval--risk-level (code)
  "Classify CODE string as `safe', `change' or `danger'."
  (catch 'level
    (dolist (rx dsh-eval--danger-regexps)
      (when (string-match-p rx code)
        (throw 'level 'danger)))
    (let ((forms (condition-case _ (dsh-eval--read-all code)
                   (error (throw 'level 'change))))
          risky)
      (dolist (form forms)
        (dolist (sym (dsh-eval--collect-symbols form))
          (unless (or (memq sym dsh-eval--special-forms)
                      (memq sym dsh-eval--safe-functions))
            (setq risky t))))
      (if risky 'change 'safe))))

(defun dsh-eval--read-all (code)
  "Read every top-level form in CODE, returning a list."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (let (forms)
      (while (progn
               (skip-chars-forward " \t\n\r\f")
               (< (point) (point-max)))
        (if (eq (char-after) ?\;)   ; skip whole comment lines
            (forward-line 1)
          (push (read (current-buffer)) forms)))
      (nreverse forms))))

(defun dsh-eval--log (status meta code result)
  "Append one request to the audit buffer."
  (with-current-buffer (get-buffer-create dsh-eval--log-buffer)
    (goto-char (point-max))
    (insert
     (format "\n[%s] %s %S\n" (format-time-string "%H:%M:%S") status meta)
     (if (<= (length code) 800) code (concat (substring code 0 800) " …"))
     "\n→ " (if result (prin1-to-string result) "") "\n")))

(defun dsh-eval--confirm (level meta code)
  "Ask the human user to approve this request.  Return non-nil to proceed."
  (let ((buf (get-buffer-create "*dsh-eval pending*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "AI requests to evaluate elisp in THIS Emacs\n\n")
        (insert (format "risk   : %s\nsource : %s\npurpose: %s\n\n"
                        level
                        (cdr (assq 'source meta))
                        (or (cdr (assq 'purpose meta)) "(none)")))
        (insert code)
        (special-mode)))
    (pop-to-buffer buf)
    (prog1 (y-or-n-p (format "dsh-eval: run %s code from AI? " level))
      (quit-window t))))

(defun dsh-eval--write-response (reqfile status summary value)
  (let ((file (concat reqfile ".resp")))
    (with-temp-file file
      (insert (format "%s\t%s\n" status (or summary "")))
      (when value (insert value)))))

(defun dsh-eval--handle-request (reqfile)
  "Entry point invoked via `emacsclient --eval'.  REQFILE holds the request."
  (condition-case err
      (dsh-eval--handle-request-1 reqfile)
    (error
     (dsh-eval--write-response reqfile 'error
                               (error-message-string err) nil)
     (format "dsh-eval: error: %s" (error-message-string err)))))

(defun dsh-eval--handle-request-1 (reqfile)
  (let* ((raw (with-temp-buffer
                (insert-file-contents reqfile)
                (buffer-string)))
         (meta (save-match-data
                 (and (string-match "^;;; meta: \\((.+)\\)\n" raw)
                      (read (match-string 1 raw)))))
         (code (replace-regexp-in-string
                "\\`;;; dsh-eval-request\n\\(;;; meta: .*\n\\)?" "" raw))
         level status action)
    (setq level (dsh-eval--risk-level code))
    (setq
     action
     (pcase level
       (`safe 'run)
       (`danger (if (and (eq dsh-eval-allow-level 'all)
                         (not dsh-eval-danger-always-confirm))
                    'run 'ask))
       (_ (pcase dsh-eval-allow-level
            (`safe 'deny)
            (`confirm 'ask)
            (`all 'run)))))
    (setq status
          (pcase action
            (`deny 'denied)
            (`ask (if (dsh-eval--confirm level meta code) 'run 'denied))
            (`run 'ok)))
    (dsh-eval--log status meta code nil)
    (if (not (eq status 'ok))
        (progn
          (dsh-eval--write-response reqfile status
                                    (format "%s code not approved (%s)"
                                            level action) nil)
          (format "dsh-eval: %s" status))
      (let ((value (condition-case err
                       (let ((forms (dsh-eval--read-all code))
                             last)
                         (dolist (f forms)
                           (setq last (eval f t)))
                         (if last (prin1-to-string last) "nil"))
                     (error (format "ERROR: %s" (error-message-string err))))))
        (if (string-prefix-p "ERROR:" value)
            (progn
              (dsh-eval--write-response reqfile 'error value nil)
              "dsh-eval: error")
          (when (> (length value) dsh-eval-result-limit)
            (setq value (substring value 0 dsh-eval-result-limit)))
          (dsh-eval--log status meta code value)
          (dsh-eval--write-response reqfile 'ok "" value)
          "dsh-eval: ok")))))

(defun dsh-eval-server-ensure ()
  "Make sure an Emacs server exists so `emacsclient' can reach us."
  (unless (and (boundp 'server-process) server-process
               (process-live-p server-process))
    (server-start)))

(provide 'dsh-eval)
;;; dsh-eval.el ends here
