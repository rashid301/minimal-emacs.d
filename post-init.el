;; post-init.el --- Modular Emacs configuration loader -*- lexical-binding: t; -*-

;; Add lisp/ to load-path so `require` can find our modules
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))


;; ── Load modules ─────────────────────────────────────────────────────────

;; UI: themes, font, line numbers, modeline, icons
(load "config-ui")

;; Keybindings: evil, general, leader keys, navigation, activities
(load "config-keybindings")


;; Editor: Dirvish, Smartparens, Consult, Embark, Tridactyl, Thanos, TRAMP
(load "config-editor")

;; Project: project.el, magit, eglot, apheleia, rg
(load "config-project")

;; Worktrunk: git-wt wrapper + one activity per worktree
(add-to-list 'load-path (expand-file-name "lisp/util" user-emacs-directory))
(require 'worktrunk)
(require 'worktrunk-activities)
(worktrunk-activities-project-mode 1)

;; Email: mu4e + org email (loads org first)
;;(load "config-email")

;; Email: GNUS (personal Gmail via IMAP)
(load "config-gnus")

;; Org + Org-roam
(load "config-org")

;; Calendar: aggregated Google iCal feeds (calfw)
(load "config-calendar")

;; Utils
(load "config-utils")

;; Terminal: Eshell, Eat, shell utilities
(load "config-terminal")

;; WSL: Windows-native tools (pwsh in ghostel) for projects on /mnt/<drive>
(load "config-wsl-host")

;; Activities EWM bridge
(load "activities-ewm")

;; LLM integrations
(load "config-llm")


;; Apps: Elfeed, ement, link-hint, pdf-tools
(load "config-apps")

;; Completion: Vertico, Corfu, Orderless, Marginalia
(load "config-completion")

;; ── Remaining configuration (not yet extracted) ─────────────────────────

;; ── EWM (Wayland compositor) integration ───────────────────────────────

(defun is_ewm()
  (or
   (string-match-p "ewm" (or (getenv "XDG_CURRENT_DESKTOP") ""))
   (string-match-p "wayland-ewm-vt1" (or (getenv "WAYLAND_DISPLAY") ""))
   ))

;; Browser configuration (EWW + Glide common)
(load "config-browser")

(if (is_ewm)
    (progn (load-file (expand-file-name "lisp/config-ewm.el" user-emacs-directory))
           ;; Browser EWM integration
           (load "browser-ewm")
           )
  (load-file (expand-file-name "lisp/config-i3.el" user-emacs-directory)))





(provide 'post-init)
