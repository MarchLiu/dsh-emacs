;;; dsh-emacs.el --- Emacs client for DeepSeek Harness (DSH) -*- lexical-binding: t; -*-

;; Entry point: `dsh' opens the session browser; `dsh-new-session' starts a
;; session in a directory. Requires a running DSH web host (dsh web) whose
;; /api bridge is reachable at `dsh-api-base'.

;;; Code:

(defconst dsh-emacs-version "0.4"
  "dsh-emacs client version; M-: dsh-emacs-version to verify a reload.")

(require 'dsh-connection)
(require 'dsh-history)
(require 'dsh-conversation)
(require 'dsh-session-list)

;;;###autoload
(defun dsh ()
  "Open the DSH session browser."
  (interactive)
  (dsh-session-list))

(provide 'dsh-emacs)
;;; dsh-emacs.el ends here
