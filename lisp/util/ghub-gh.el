;;; ghub-gh.el --- Let ghub (forge, pr-review) use the `gh' CLI's login  -*- lexical-binding: t; -*-

;;; Commentary:

;; forge and pr-review talk to GitHub through ghub, which wants a token in
;; auth-source (`USER^forge', `USER^emacs-pr-review' ...) and a `github.user'
;; git setting.  If `gh' is already logged in, both can be answered from it,
;; so no second copy of the token lives in a file:
;;
;;   token    `gh auth token', cached for ten minutes
;;   username `gh api user', cached for the session
;;
;; Real auth-source entries still win; this only fills in what is missing,
;; and only for api.github.com.

;;; Code:

(defvar ghub-gh-executable "gh" "The GitHub CLI.")

(defvar ghub-gh--token nil)
(defvar ghub-gh--token-time 0)
(defvar ghub-gh--login nil)

(defun ghub-gh--call (&rest args)
  "Run `gh' with ARGS, returning trimmed stdout or nil on failure."
  (when (executable-find ghub-gh-executable)
    (with-temp-buffer
      (when (eq 0 (apply #'call-process ghub-gh-executable nil '(t nil) nil args))
        (let ((s (string-trim (buffer-string))))
          (and (not (string-empty-p s)) s))))))

(defun ghub-gh-token ()
  "Token from `gh auth token', cached for ten minutes."
  (when (> (- (float-time) ghub-gh--token-time) 600)
    (let ((tok (ghub-gh--call "auth" "token")))
      (setq ghub-gh--token (and tok (not (string-match-p "[ \t\n]" tok)) tok)
            ghub-gh--token-time (float-time))))
  ghub-gh--token)

(defun ghub-gh-login ()
  "Login of the user `gh' is authenticated as."
  (or ghub-gh--login
      (setq ghub-gh--login (ghub-gh--call "api" "user" "--jq" ".login"))))

(defun ghub-gh--token-advice (orig host username package &optional nocreate forge)
  "Around advice for `ghub--token': fall back to `gh' for api.github.com."
  (or (funcall orig host username package t forge)
      (and (equal host "api.github.com") (ghub-gh-token))
      (funcall orig host username package nocreate forge)))

(defun ghub-gh--username-advice (orig host &optional forge)
  "Around advice for `ghub--username': fall back to the `gh' login."
  (or (condition-case nil (funcall orig host forge) (error nil))
      (and (member host '("api.github.com" nil))
           (memq (or forge 'github) '(github))
           (ghub-gh-login))
      (funcall orig host forge)))

;;;###autoload
(defun ghub-gh-enable ()
  "Install the advice once ghub is loaded."
  (with-eval-after-load 'ghub
    (advice-add 'ghub--token :around #'ghub-gh--token-advice)
    (advice-add 'ghub--username :around #'ghub-gh--username-advice)))

(provide 'ghub-gh)
;;; ghub-gh.el ends here
