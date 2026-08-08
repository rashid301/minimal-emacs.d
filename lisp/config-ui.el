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

(setq scroll-conservatively 101)
(global-superword-mode 1)
(global-subword-mode 1)

(use-package nano-theme
  :ensure t
  )

;; ── Ultra-scroll (smooth scrolling) ────────────────────────────────────

(use-package ultra-scroll
  :ensure t
  :init
  (setq scroll-margin 0)
  :config
  (ultra-scroll-mode 1))

;; ── Font (GUI only) ────────────────────────────────────────────────────

(defun my/set-font (&optional frame font-size)
  ;;(nano-mode)
  (my/load-theme 'modus-operandi)
  ;;(my/load-theme 'noctalia)
  (set-face-attribute 'default frame
                      :family "Iosevka Extended"
                      :height (or font-size 140)
                      :weight 'normal))

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
(add-hook 'image-mode-hook #'turn-off-line-numbers)
(add-hook 'pdf-view-mode-hook #'turn-off-line-numbers)

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
      ;;ewm-surface-mode
      eshell-mode
      eat-mode
      dashboard-mode
      completion-list-mode
      agent-shell-mode)
    "List of major modes where the mode-line should be completely hidden.")

  :config
  ;; 2. Loop through the list and automatically bind the hide function to their hooks
  (dolist (mode my-hidden-modeline-modes)
    (let ((hook (intern (concat (symbol-name mode) "-hook"))))
      (add-hook hook #'hide-mode-line-mode))))

;; ── Visual line wrap ──────────────────────────────────────────────────

;;(global-visual-line-mode 1)
(global-visual-wrap-prefix-mode 1)

;; ── Visual-fill-column (SPC t c to toggle) ────────────────────────────

(use-package visual-fill-column
  :ensure t
  :hook ((elfeed-search-mode elfeed-show-mode eww-mode mu4e-main-mode) . visual-fill-column-mode)
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

(use-package ligature
  :ensure t
  :config
  ;; Enable all Iosevka ligatures for typographic and programming modes
  (ligature-set-ligatures 'prog-mode
                          '("|||=" "||=" "||" "|=" "|>" "感知" "::=" "::" ":=" "==" "===" "==>" "=>" "!=" "!==" "->" "-->" "->>" "->=" "<-" "<--" "<-" "<=" "<==" "<=>" "<~" "<~>" "<>" "<<" "<<-" "<<=" "<<<" ">>" ">>-" ">>=" ">>>" ".-" ".=" ".." "..." "++" "+++" "+=" "/=" "///" "/*" "*/" "safe" "&&" "&&=" "&&&" "&=" "==" "===" "==>" "=>"))
  ;; Activate ligature-mode globally
  (global-ligature-mode t))

(use-package nerd-icons-dired
  :ensure t
  :hook
  (dired-mode . nerd-icons-dired-mode))

(setq
 my/light-theme 'modus-operandi  ; Placeholder for light toggle (not yet wired)
 my/dark-theme 'modus-vivendi    ; Nano dark theme
 )



(defun my/toggle-theme-mode ()
  "Toggle between dark and light themes, update GTK theme, and restart Firefox."
  (interactive)

  ;; --- Detect current theme ---
  (setq rs/theme-dark (eq (frame-parameter nil 'background-mode) 'dark))

  ;; --- Switch Doom theme ---
  (if (member 'noctalia custom-enabled-themes)
      (progn
        (call-process "noctalia" nil 0 nil "msg" "theme-mode-toggle")
        )
    (let ((th
           (if rs/theme-dark
               my/light-theme
             my/dark-theme)
           ))

      ;; (mapc #'disable-theme custom-enabled-themes)
      (call-process "noctalia" nil 0 nil
                    "msg" "theme-mode-set"
                    (if rs/theme-dark "light" "dark"))

      (my/load-theme th)
      )
    )
  (call-process "noctalia" nil 0 nil
                "msg" "wallpaper-set"
                (format "~/Community-wallpapers/eos_wallpapers_community/%s"  (if rs/theme-dark "endeavour_os_simple_wallpaper_light.png" "endeavour_os_simple_wallpaper_dark.png")))
  
  (message "Theme toggled: %s"
           (if rs/theme-dark "Light mode" "Dark mode")))

;; default settings
(add-to-list 'default-frame-alist '(alpha-background . 70))

;; --- EWM window visual separation ---
;; Dim unfocused app surfaces (compositor level)
(when (featurep 'ewm)
  (setopt ewm-unfocused-alpha 0.9))

;; Colored dividers between split windows
(setopt window-divider-width 2)
(custom-set-faces
 '(window-divider ((t (:background "#333333")))))

;; Transparent fringes so wallpaper shows through pane edges
(set-fringe-mode 4)
(set-face-attribute 'fringe nil :background nil)

(provide 'config-ui)
;; config-ui.el ends here
