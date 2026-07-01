;; config-ui.el --- Themes, font, line numbers, modeline, icons -*- lexical-binding: t -*-

;; ── Themes ──────────────────────────────────────────────────────────────

(use-package doom-themes
  :ensure t
  :hook (doom-load-theme . doom-themes-org-config)
  :custom
  (doom-themes-enable-bold t)
  (doom-themes-enable-italic t)
  :config
  (doom-themes-visual-bell-config)
  (doom-themes-org-config))

(setq scroll-conservatively 3)
(global-superword-mode 1)
(global-subword-mode 1)

;; ── Ultra-scroll (smooth scrolling) ────────────────────────────────────

(use-package ultra-scroll
  :ensure t
  :init
  (setq scroll-margin 0)
  :config
  (ultra-scroll-mode 1))

;; --- mini solaire
(require 'color)

(defun my-remap-background (&optional amount)
  "Remap the current buffer's background.

AMOUNT is the percentage to lighten/darken (default 4).  Dark
themes are lightened slightly; light themes are darkened."
  (unless (my-real-buffer-p)
    (turn-off-line-numbers)
    (let* ((amount (or amount 4))
           (bg (face-background 'default nil t))
           (fg (face-foreground 'default nil t))
           (new-bg (if (color-dark-p (color-name-to-rgb bg))
                       (color-lighten-name bg amount)
                     (color-darken-name bg amount))))
      (face-remap-add-relative
       'default
       `(:background ,new-bg))
      (face-remap-add-relative
       'fringe
       `(:background ,new-bg))
      (face-remap-add-relative
       'line-number
       `(:background ,new-bg)))))

(defun my-real-buffer-p ()
  "Return non-nil if the current buffer is visiting a real file."
  (and buffer-file-name
       (not (minibufferp))
       (not (string-prefix-p " " (buffer-name)))))


;; ── Font (GUI only) ────────────────────────────────────────────────────

(defun my/set-font (&optional frame)
  (my/load-theme 'noctalia)
  (add-hook 'after-change-major-mode-hook #'my-remap-background)
  (set-face-attribute 'default frame
                      :family "RobotoMono Nerd Font"
                      :height 140
                      :weight 'normal))

;; (defun my/load-nano-theme (&optional frame)
;;   (nano-mode)
;;   (my/load-theme nano-light)
;;   )

(defun my/load-theme (theme)
  "Completely disable all active themes before loading THEME safely."
  (interactive
   (list (intern (completing-read "Load theme: "
                                  (mapcar #'symbol-name (custom-available-themes))))))
  ;; 1. Loop through and forcefully turn off every currently active theme
  (dolist (active-theme custom-enabled-themes)
    (disable-theme active-theme))
  ;; 2. Load the fresh theme cleanly without layering onto old faces
  (load-theme theme t))

;; Only set font in GUI mode (not in terminal/batch)
(when (display-graphic-p)
  (my/set-font))
(add-hook 'after-make-frame-functions #'my/set-font)
(winner-mode)

;; ── Line numbers ───────────────────────────────────────────────────────

(global-display-line-numbers-mode 1)
(setq display-line-numbers-width 2)
(set-fringe-mode 0)
(setq-default top-margin-width 2)
(setq-default left-margin-width 1)
(setq-default right-margin-width 1)

(defun turn-off-line-numbers ()
  (display-line-numbers-mode -1))
;; Hide line numbers in eshell buffers
(add-hook 'eshell-mode-hook #'turn-off-line-numbers)
(add-hook 'eww-mode-hook #'turn-off-line-numbers)
(add-hook 'agent-shell-mode-hook #'turn-off-line-numbers)
(add-hook 'ewm-mode-hook #'turn-off-line-numbers)
(add-hook 'helpful-mode-hook #'turn-off-line-numbers)
(add-hook 'mu4e-main-mode-hook #'turn-off-line-numbers)
(add-hook 'mu4e-headers-mode-hook #'turn-off-line-numbers)
(add-hook 'mu4e:view #'turn-off-line-numbers)
(add-hook 'eww-mode-hook #'turn-off-line-numbers)

;;(setq 'ewm-mode-hook '())
;;(add-hook 'ewm-mode-hook #'mode-line-invisible-mode)

;; doom-modeline
(use-package doom-modeline
  :ensure t
  :init (doom-modeline-mode 1)
  :config
  (setq doom-modeline-modal-icon nil
        doom-modeline-buffer-file-name-style 'file-name))

(use-package hide-mode-line
  :ensure t
  :init
  ;; 1. Define the list of major modes where you want to hide the modeline
  (defvar my-hidden-modeline-modes
    '(vterm-mode
      neotree-mode
      treemacs-mode
      speedbar-mode
      ewm-surface-mode
      eshell-mode
      eat-mode
      dashboard-mode
      completion-list-mode)
    "List of major modes where the mode-line should be completely hidden.")

  :config
  ;; 2. Loop through the list and automatically bind the hide function to their hooks
  (dolist (mode my-hidden-modeline-modes)
    (let ((hook (intern (concat (symbol-name mode) "-hook"))))
      (add-hook hook #'hide-mode-line-mode))))

;; ── Visual line wrap ──────────────────────────────────────────────────

(global-visual-line-mode 1)
(global-visual-wrap-prefix-mode 1)

;; ── Visual-fill-column (SPC t c to toggle) ────────────────────────────

(use-package visual-fill-column
  :ensure t
  :hook ((elfeed-search-mode elfeed-show-mode eww-mode) . visual-fill-column-mode)
  :config
  (setq-default visual-fill-column-width 120)
  (setq-default visual-fill-column-center-text t))

;; ── Icons (nerd-icons) ────────────────────────────────────────────────

(use-package nerd-icons
  :ensure t)

(use-package nerd-icons-completion
  :ensure t
  :after nerd-icons
  :config
  (nerd-icons-completion-mode 1))

(provide 'config-ui)
;; config-ui.el ends here
