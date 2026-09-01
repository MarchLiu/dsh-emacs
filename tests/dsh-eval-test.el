;;; dsh-eval-test.el --- batch tests for dsh-eval -*- lexical-binding: t; -*-

(require 'cl-lib)

;; 1. risk classification table
(defconst dsh-eval-test--cases
  '(("(+ 1 2)" . safe)
    ("(message \"%s\" (buffer-name))" . safe)
    ("(let ((x 1)) (+ x 2))" . safe)
    ("(let ((names (mapcar #'buffer-name (buffer-list)))) (string-join names \", \"))" . safe)
    (";; comment\n(concat \"a\" \"b\")" . safe)
    ("(setq dsh-api-base \"http://x\")" . change)
    ("(customize-set-variable 'fill-column 99)" . change)
    ("(dsh-rpc \"host.describe\")" . change)
    ("(switch-to-buffer \"*scratch*\")" . change)
    ("(delete-file \"/tmp/x\")" . danger)
    ("(shell-command-to-string \"ls\")" . danger)
    ("(kill-emacs)" . danger)
    ("(let ((f \"x\")) (write-region \"a\" nil f))" . danger)))
(pcase-dolist (`(,code . ,want) dsh-eval-test--cases)
  (let ((got (dsh-eval--risk-level code)))
    (princ (format "%-72s => %s %s\n" code got
                   (if (eq got want) "OK" (format "FAIL (want %s)" want))))))

;; 2. end-to-end request/response cycle (no interactive prompt)
(let* ((dir (expand-file-name "test-spool" temporary-file-directory))
       (req (expand-file-name "req-test.el" dir)))
  (make-directory dir t)
  (let ((dsh-eval-allow-level 'all))
    ;; ok path
    (with-temp-file req
      (insert ";;; dsh-eval-request\n"
              ";;; meta: ((source . \"ai\") (purpose . \"unit test\"))\n"
              "(let ((names (mapcar #'buffer-name (buffer-list))))\n"
              "  (length names))\n"))
    (princ (format "e2e ok => %s, resp=%S\n"
                   (dsh-eval--handle-request req)
                   (with-temp-buffer (insert-file-contents (concat req ".resp"))
                                     (buffer-string))))
    ;; error path
    (with-temp-file req
      (insert "(+ 1 \"not-a-number\")\n"))
    (princ (format "e2e error => %s, resp=%S\n"
                   (dsh-eval--handle-request req)
                   (with-temp-buffer (insert-file-contents (concat req ".resp"))
                                     (buffer-string)))))
  ;; denied path
  (let ((dsh-eval-allow-level 'safe))
    (with-temp-file req
      (insert "(setq foo 1)\n"))
    (princ (format "e2e denied => %s, resp=%S\n"
                   (dsh-eval--handle-request req)
                   (with-temp-buffer (insert-file-contents (concat req ".resp"))
                                     (buffer-string))))))
