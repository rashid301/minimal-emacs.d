;; post-init.el --- Modular Emacs configuration loader -*- lexical-binding: t; -*-

;; Add lisp/ to load-path so `require` can find our modules
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; Force native Gpg4win
(setq epg-gpg-program "C:/Program Files/GnuPG/bin/gpg.exe")
;;(setq package-check-signature nil)

;; Dedicated package keyring
(setq package-gnupghome-dir
      (expand-file-name "elpa/gnupg/" user-emacs-directory))

(make-directory package-gnupghome-dir t)

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

(require 'agent-shell-manager)
;; Options: 'left, 'right, 'top, 'bottom, or nil
(setq agent-shell-manager-side 'left)

;; Email: mu4e + org email (loads org first)
;;(load "config-email")

;; Email: GNUS (personal Gmail via IMAP)
(load "config-gnus")

;; Org + Org-roam
(load "config-org")

;; Utils
(load "config-utils")

;; Terminal: Eshell, Eat, shell utilities
(load "config-terminal")

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

(if (is_ewm)
    (progn (load-file (expand-file-name "lisp/config-ewm.el" user-emacs-directory))
           ;; Browser configuration (EWW + Glide)
           (load "config-browser")
           ;; Activities EWM bridge
           (load "activities-ewm")

           )
  (load-file (expand-file-name "lisp/config-i3.el" user-emacs-directory)))

(provide 'post-init)
