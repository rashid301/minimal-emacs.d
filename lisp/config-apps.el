;; config-apps.el --- App configurations (elfeed, ement, link-hint, pdf-tools) -*- lexical-binding: t; -*-

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


;; ── link-hint ─────────────────────────────────────────────────────────

(use-package link-hint
  :ensure t)

;; ── pdf-tools ─────────────────────────────────────────────────────────

;; jka-compat is the C extension that pdf-view requires. The Nix store build
;; of pdf-tools ships without it, so install via package.el (compiles against
;; the running Emacs). Must load before pdf-tools.
(use-package jka-compr
  :ensure t)

(use-package pdf-tools
  ;; Provided by Nix (epkgs.pdf-tools in the EWM emacsPackage build).
  ;; use-package-always-ensure is on globally, so :ensure nil is REQUIRED
  ;; here — otherwise package.el would install a second copy from MELPA.
  :ensure nil
  :mode ("\\.pdf\\'" . pdf-view-mode)
  :config
  ;; epdfinfo is NOT auto-discovered: pdf-info.el's default falls back to the
  ;; relative name "epdfinfo", resolved against your cwd at runtime. Derive
  ;; the path from the loaded library so Nix rebuilds (new store hash) don't
  ;; break it.
  (setq pdf-info-epdfinfo-program
        (expand-file-name "epdfinfo"
                          (file-name-directory
                           (locate-library "pdf-tools"))))
  )


;; ── ement ─────────────────────────────────────────────────────────────

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

  (defun rs/ement-fundamental-save-binding ()
    (local-set-key (kbd "C-c C-c") #'save-buffer))

  (add-hook 'ement-room-compose-hook #'rs/ement-fundamental-save-binding)

  (evil-collection-define-key '(normal motion) 'ement-room-mode-map
    (kbd "<")  'ement-room-transient
    (kbd "<return>")   'my/ement-ret
    (kbd "RET")        'my/ement-ret))

;; (use-package docker
;;   :ensure t
;;   )

(provide 'config-apps)
