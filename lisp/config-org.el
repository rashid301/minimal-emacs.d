;; config-org.el --- Org + Org-roam -*- lexical-binding: t -*-

;; ── Org + Org-roam ─────────────────────────────────────────────────────

(use-package org
  :demand t
  :bind (("C-c a" . org-agenda))
  :config
  (setq org-directory (expand-file-name "~/notes/"))
  (setq org-id-link-to-frametree t)
  (setq org-confirm-babel-evaluate nil)
  (setq org-agenda-files '("~/notes/tasks.org"
                           "~/notes/my-gtd"
                           "~/notes/projects.org"
                           "~/notes/ideas.org"
                           "~/notes/vaccines.org"
                           "~/notes/health.org"
                           "~/notes/someday.org"))
  (setq org-default-notes-file (expand-file-name "inbox.org" org-directory))
  (setq org-log-done 'time)
  (setq org-log-into-drawer t)
  (setq org-startup-align-all-tables t)
  (setq org-use-speed-commands t)
  (setq org-export-preserve-breaks nil)
  (setq org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "WAITING(w)" "PROJECT(p)"
                                      "|" "DONE(d)" "CANCELLED(c)" "SOMEDAY(s)")))
  (setq org-todo-keyword-faces '(("TODO"      . (:foreground "yellow"       :weight bold))
                                 ("NEXT"      . (:foreground "orange"       :weight bold))
                                 ("WAITING"   . (:foreground "red"          :weight bold))
                                 ("PROJECT"   . (:foreground "blue"         :weight bold))
                                 ("DONE"      . (:foreground "forest green" :weight bold))
                                 ("CANCELLED" . (:foreground "gray"         :weight bold))
                                 ("SOMEDAY"   . (:foreground "goldenrod"    :weight bold))))

  (setq org-capture-templates
        '(("i" "Inbox" entry
           (file ,(expand-file-name "inbox.org" org-directory))
           "* TODO %?\n  %U\n  %a\n")
          ("t" "Task" entry
           (file ,(expand-file-name "tasks.org" org-directory))
           "* TODO %?\n  %U\n  %a\n")
          ("p" "Project" entry
           (file ,(expand-file-name "projects.org" org-directory))
           "* PROJECT %?")
          ("s" "Someday" entry
           (file ,(expand-file-name "someday.org" org-directory))
           "* SOMEDAY %?")
          ("n" "Idea" entry
           (file ,(expand-file-name "ideas.org" org-directory))
           "* IDEA %?")))
  (setq org-refile-targets
        '((nil :maxlevel . 3)
          (org-agenda-files :maxlevel . 3)
          ("~/notes/ideas.org" :maxlevel . 2)
          ("~/notes/projects.org" :maxlevel . 2)
          ("~/notes/tasks.org" :maxlevel . 2)
          ("~/notes/someday.org" :maxlevel . 2)))
  (setq org-refile-allow-creating-parent-nodes 'confirm)
  (setq org-agenda-custom-commands
        '(("g" "GTD Dashboard"
           ((agenda "" ((org-agenda-span 3)
                        (org-agenda-overriding-header "Calendar (Next 3 Days)")
                        (org-agenda-start-day "+0d")))
            (todo "NEXT"
                  ((org-agenda-overriding-header "Next Actions")
                   (org-agenda-sorting-strategy '(priority-down effort-up))))
            (todo "WAITING"
                  ((org-agenda-overriding-header "Waiting On")))
            (todo "SOMEDAY"
                  ((org-agenda-overriding-header "Someday / Maybe")
                   (org-agenda-files '("~/notes/someday.org"))))
            (todo "DONE"
                  ((org-agenda-overriding-header "Recently Completed")
                   (org-agenda-files '("~/notes/tasks.org" "~/notes/projects.org"))
                   (org-agenda-skip-function
                    '(org-agenda-skip-entry-if 'nottodo 'done))))))
          ("w" "Weekly Review"
           ((agenda "" ((org-agenda-span 7)
                        (org-agenda-start-day "-1d")
                        (org-agenda-overriding-header "Review Calendar")))
            (todo "PROJECT" ((org-agenda-overriding-header "Active Projects")))
            (todo "WAITING" ((org-agenda-overriding-header "Waiting For")))
            (todo "SOMEDAY" ((org-agenda-overriding-header "Someday / Maybe")))
            (tags "inbox"
                  ((org-agenda-overriding-header "Inbox Items")
                   (org-agenda-files '("~/notes/inbox.org"))))))
          ("t" "Today Focus"
           ((agenda "" ((org-agenda-span 1)
                        (org-agenda-start-day "+0d")
                        (org-agenda-overriding-header "Today")))
            (todo "NEXT"
                  ((org-agenda-overriding-header "Next Actions")
                   (org-agenda-sorting-strategy '(priority-down effort-up)))))))
  )
  (setq org-agenda-prefix-format
        '((agenda . " %i %-12:c%?-12t% s")
          (todo   . " %i %-12:c")
          (tags   . " %i %-12:c")
          (search . " %i %-12:c")))
  )

(use-package org-roam
  :ensure t
  :after org
  :config
  (setq org-roam-v2-ack t
        org-roam-directory "~/notes/"
        org-roam-completion-everywhere t)
  (setq org-roam-capture-templates
        '(("d" "default" plain
           "%?"
           :target (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                              "#+title: ${title}\n#+startup: shrink\n"))))
  (setq org-roam-dailies-capture-templates
        '(("d" "default" entry
           "* %?"
           :target (file+head "%<%Y-%m-%d>.org"
                              "#+title: %<%Y-%m-%d>\n#+startup: shrink\n"))))
  (org-roam-dailies-setup)
  (org-roam-setup)
  ;; Global keybindings
  ;; (global-set-key (kbd "C-c n l") #'org-roam-node-find)
  ;; (global-set-key (kbd "C-c n i") #'org-roam-node-insert)
  ;; (global-set-key (kbd "C-c n c") #'org-roam-capture)
  )

(provide 'config-org)
;; config-org.el ends here
