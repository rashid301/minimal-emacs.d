;;; gh-repo-account.el --- Pin a GitHub account to one repo  -*- lexical-binding: t; -*-

;;; Commentary:

;; With several accounts logged in to `gh', `git push' uses whichever is active, and
;; `gh auth git-credential' refuses to hand out another account's token even when the
;; URL or config names it.  `my/fix-gh-repo' fixes one repo for good: it pins the
;; username and gives the repo its own credential helper that asks `gh' for exactly
;; that account's token, so pushing works whichever account is active and nobody has
;; to run `gh auth switch'.  Other repos keep the global behaviour.

;;; Code:

(require 'project)
(require 'subr-x)

(defconst my/gh-credential-key "credential.https://github.com.helper")
(defconst my/gh-username-key "credential.https://github.com.username")

(defun my/gh-credential-helper (username)
  "Git credential helper (a shell snippet) serving USERNAME's `gh' token.
It answers only `get', says nothing when `gh' has no token for USERNAME (git then
asks as usual), and never prints the token anywhere but to git."
  (unless (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9-]*\\'" username)
    (user-error "Not a GitHub username: %S" username))
  (format "!f() { [ \"$1\" = get ] || exit 0; t=$(gh auth token --user %s 2>/dev/null); [ -n \"$t\" ] || exit 0; echo username=%s; echo password=$t; }; f"
          username username))

(defun my/gh--git (dir &rest args)
  "Run git ARGS in DIR; return its exit status."
  (let ((default-directory (file-name-as-directory dir)))
    (apply #'call-process "git" nil nil nil args)))

;;;###autoload
(defun my/fix-gh-repo (dir username)
  "Make `git push' in the repo at DIR always use the GitHub account USERNAME.
Pins USERNAME as the credential username and gives the repo its own credential
helper that fetches that account's token from `gh', replacing the inherited
helpers.  Safe to run again.  Prompts for a project and a username."
  (interactive (list (project-prompt-project-dir)
                     (read-string "GitHub username: " "rashid-cc")))
  (let ((helper (my/gh-credential-helper username))   ; validates USERNAME first
        (dir (file-name-as-directory (expand-file-name dir))))
    (unless (file-exists-p (expand-file-name ".git" dir))
      (user-error "%s is not a git repo root" dir))
    (unless (zerop (my/gh--git dir "config" "--local" my/gh-username-key username))
      (user-error "git config failed in %s" dir))
    ;; Start from a clean list, then: "" (forget the global gh helper), then ours.
    (my/gh--git dir "config" "--local" "--unset-all" my/gh-credential-key)
    (unless (and (zerop (my/gh--git dir "config" "--local" "--add" my/gh-credential-key ""))
                 (zerop (my/gh--git dir "config" "--local" "--add" my/gh-credential-key helper)))
      (user-error "Could not set the credential helper in %s" dir))
    (message "%s: pushes now use %s (pinned, with its own credential helper)" dir username)))

(provide 'gh-repo-account)
;;; gh-repo-account.el ends here
