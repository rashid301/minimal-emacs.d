;; post-init.el --- Modular Emacs configuration loader -*- lexical-binding: t; -*-

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

;; Editor: Dirvish, Smartparens, Consult, Embark, Tridactyl, Thanos
(load "config-editor")


;; ── Remaining configuration (not yet extracted) ─────────────────────────

(use-package link-hint
  :ensure t)

(use-package pdf-tools
  :ensure t
  :mode ("\\.pdf\\'" . pdf-view-mode)
  :config
  (pdf-tools-install t t))


;; ── Elfeed (RSS reader) ────────────────────────────────────────────────
(use-package elfeed
  :ensure t
  :defer t
  :custom
  (elfeed-search-filter "@3days +unread")
  :config
  (add-hook 'elfeed-search-mode-hook #'elfeed-update)
  )

(use-package elfeed-org
  :after elfeed
  :ensure t
  :custom
  (rmh-elfeed-org-files '("/home/rashid/Dropbox/notes/elfeed.org"))
  :config
  (elfeed-org))


;; ── diminish (hide minor modes from modeline) ───────────────────────

(use-package diminish
  :ensure t)

;; ── Autorevert (refresh buffers when files change on disk) ────────────
(use-package autorevert
  :ensure t
  :config
  (global-auto-revert-mode 1)
  ;; Also refresh non-file buffers (magit, elfeed, gnus status) on the
  ;; same cycle — no "File was modified" prompts for files agents and
  ;; background tools rewrite continuously.
  (setq global-auto-revert-non-file-buffers t
        auto-revert-interval 2))  ; poll every 2s

;; ── HTTP / API testing (verb) ──────────────────────────────────────────

(use-package verb
  :ensure t
  :defer t
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((verb . t)))
  (setq verb-suppress-load-unsecure-prelude-warning t))

;; ── Quickrun ───────────────────────────────────────────────────────────

(use-package quickrun
  :ensure t)

;; ── EWM (Wayland compositor) integration ───────────────────────────────

(if (getenv "EWM_MODULE_PATH")
    (load-file (expand-file-name "lisp/config-ewm.el" user-emacs-directory))
  (load-file (expand-file-name "lisp/config-i3.el" user-emacs-directory)))


;; ── TRAMP ─────────────────────────────────────────────────────────────

(use-package tramp
  :ensure nil
  :config
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path)
  (setq tramp-use-ssh-controlmaster-options nil)
  (setq tramp-inline-compress-start-size 10000)
  (setq tramp-copy-size-limit 100000)
  (setq vc-handled-backends '(git))
  (setq remote-file-name-inhibit-cache nil)
  (setq tramp-verbose 3))


;; ── ement ──────────────────────

(use-package ement
  :custom
  (ement-save-sessions t)
  ;; (ement-view-room-display-buffer-action
  ;;  '((display-buffer-reuse-window)))
  ;; (ement-view-room-display-buffer-action
  ;;  '((display-buffer-reuse-window)
  ;;    (window-parameters . ((quit-restore . delete)))))


  (ement-room-compose-buffer-display-action
   (cons 'display-buffer-below-selected
         '((window-height . 15)
           (inhibit-same-window . t)
           (reusable-frames . nil))))
  (ement-view-room-display-buffer-action
   '((display-buffer-reuse-window
      display-buffer-pop-up-window)
     (window-parameters . ((quit-restore . delete)))))

  (ement-room-send-message-filter #'ement-room-send-org-filter)
  (setopt
   evil-collection-ement-want-auto-retro t
   ement-room-buffer-name-prefix "Ement Room:" ;; remove asterisk for persp
   ement-room-buffer-name-suffix ""
   )

  :config
  (defun my/ement-ret ()
    (interactive)
    (if (or (button-at (point))
            (get-text-property (point) 'mouse-face))
        (push-button)
      (ement-room-send-message)))

  ;; (defun rs/ement-fundamental-save-binding ()
  ;;   (local-set-key (kbd "C-c C-c") #'save-buffer))

  (add-hook 'ement-room-compose-hook #'rs/ement-fundamental-save-binding)

  (evil-collection-define-key '(normal motion) 'ement-room-mode-map
    (kbd "<")  'ement-room-transient
    (kbd "<return>")   'my/ement-ret
    (kbd "RET")        'my/ement-ret))


;; Browser configuration (EWW + Glide)
(load "config-browser")


(provide 'post-init)
