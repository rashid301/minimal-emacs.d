; post-init.el --- Modular Emacs configuration loader -*- lexical-binding: t; -*-

;; Add lisp/ to load-path so `require` can find our modules
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))


;; ── Load modules ─────────────────────────────────────────────────────────

;; UI: themes, font, line numbers, modeline, icons
(load "config-ui")

;; Keybindings: evil, general, leader keys, navigation, activities
(load "config-keybindings")

;; Completion: Vertico, Corfu, Orderless, Marginalia
(load "config-completion")

;; Project: project.el, magit, eglot, apheleia, rg
(load "config-project")

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

;; Activities EWM bridge
(load "activities-ewm")

;; LLM integrations
(load "config-llm")

;; Editor: Dirvish, Smartparens, Consult, Embark, Tridactyl, Thanos, TRAMP
(load "config-editor")

;; Apps: Elfeed, ement, link-hint, pdf-tools
(load "config-apps")


;; ── Remaining configuration (not yet extracted) ─────────────────────────

;; ── EWM (Wayland compositor) integration ───────────────────────────────

(if (getenv "EWM_MODULE_PATH")
    (load-file (expand-file-name "lisp/config-ewm.el" user-emacs-directory))
  (load-file (expand-file-name "lisp/config-i3.el" user-emacs-directory)))


;; Browser configuration (EWW + Glide)
(load "config-browser")


(provide 'post-init)
