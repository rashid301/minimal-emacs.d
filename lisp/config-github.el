;;; config-github.el --- GitHub review inbox, pr-review, ghub via gh  -*- lexical-binding: t; -*-

;; The pieces live in lisp/util:
;;   ghub-gh.el          forge / pr-review authenticate through `gh auth token'
;;   gh-inbox.el         the inbox buffer          (SPC g i)
;;   gh-inbox-review.el  PR -> worktree activity, threads, Claude review
;;   gh-inbox-notify.el  background polling, toasts, status count, Taskwarrior sync
;; Tests: emacs --batch -L lisp/util -L lisp/test -l gh-inbox-tests -f ert-run-tests-batch-and-exit

(add-to-list 'load-path (expand-file-name "lisp/util" user-emacs-directory))

;; ghub (forge, pr-review) gets its token and login from `gh', not a second copy on disk.
(use-package ghub-gh
  :ensure nil
  :demand t
  :config (ghub-gh-enable))

;; Review UI: description, timeline, inline threads, submit review.
(use-package pr-review
  :defer t
  :commands (pr-review pr-review-open-url pr-review-search pr-review-notification))

(use-package gh-inbox
  :ensure nil
  :commands (gh-inbox)
  ;; Ticket keys in titles/branches (DEV-33054) open on J.
  ;; Limit searches to one org with: (gh-inbox-search-qualifiers "org:clearcompany")
  :custom
  (gh-inbox-jira-base-url "https://clearco.atlassian.net/browse/")
  ;; The inbox, review tasks and toasts belong to the work login.  If `gh' is switched to
  ;; another account (gh auth switch), fetches are discarded instead of looking like "all
  ;; review requests are gone" (which would close the Taskwarrior review tasks).
  (gh-inbox-expected-login "rashid-cc"))

(use-package gh-inbox-review
  :ensure nil
  :commands (gh-inbox-activity gh-inbox-review-threads-here gh-inbox-review-browse-here gh-inbox-review-open
             gh-inbox-review-claude)
  :custom
  (gh-inbox-review-search-roots '("/mnt/d/repos/")))

(use-package gh-inbox-notify
  :ensure nil
  :demand t
  :custom
  ;; Review requests become Taskwarrior tasks (+ghreview, type:next) and close themselves
  ;; when the request goes away.  Set to nil to stop touching Taskwarrior.
  (gh-inbox-notify-task-sync t)
  :config
  (gh-inbox-notify-mode 1))

;; One "open this" for tickets (DEV-123), PRs (URL or owner/repo#N), Confluence and Google Docs.
;; SPC o o at point / on the line / from the clipboard (C-u: choose the action); `C-.' (embark)
;; offers the same on a reference; org/text buffers underline them (click opens).
(use-package ref-open
  :ensure nil
  :commands (ref-open ref-open-buttons-mode)
  :hook ((org-mode text-mode) . ref-open-buttons-mode)
  :config (ref-open-setup-embark))

(with-eval-after-load 'general
  (my-leader-def
    "oo" '(ref-open :which-key "open ticket/PR/doc at point")
    "gi" '(gh-inbox-activity :which-key "GitHub inbox (own activity)")
    "gI" '(gh-inbox :which-key "GitHub inbox (this window)")
    "gt" '(gh-inbox-review-threads-here :which-key "PR threads (this branch)")
    "go" '(gh-inbox-review-browse-here :which-key "open PR in browser")))

(provide 'config-github)
;;; config-github.el ends here
