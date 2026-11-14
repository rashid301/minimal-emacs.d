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
                      :family "Iosevka Nerd Font"
                      :height (or font-size 145)
                      :weight 'normal)
  ;; Emoji fallback (noto-fonts-emoji)
  (set-fontset-font t 'emoji (font-spec :family "Noto Color Emoji") nil 'prepend))

(load-theme 'newcomers-presets)
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
;;(add-hook 'server-after-make-frame-hook #'my/set-font)
(if (daemonp)
    (add-hook 'after-make-frame-functions
              (defun my-theme-daemon-init (frame)
                (my/set-font)
                (remove-hook 'after-make-frame-functions 'my-theme-daemon-init)))
  (my/set-font))

(winner-mode)

;; ── Line numbers ───────────────────────────────────────────────────────

(global-display-line-numbers-mode 1)
(setq display-line-numbers-width 2)
(set-fringe-mode 0)
(setq-default top-margin-width 0)
(setq-default left-margin-width 0)
(setq-default right-margin-width 0)

(defun turn-off-line-numbers ()
  (display-line-numbers-mode -1))
;; Hide line numbers in eshell buffers
(add-hook 'eshell-mode-hook #'turn-off-line-numbers)
(add-hook 'eat-mode-hook #'turn-off-line-numbers)
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
(add-hook 'pdf-view-mode-hook #'turn-off-line-numbers)
(add-hook 'ghostel-mode-hook #'turn-off-line-numbers)

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
  ;; (dolist (mode my-hidden-modeline-modes)
  ;;   (let ((hook (intern (concat (symbol-name mode) "-hook"))))
  ;;     (add-hook hook #'hide-mode-line-mode)))
  )

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
  :ensure t
  :config
  ;; Point nerd-icons at the Nerd Font actually installed on this system
  (setq nerd-icons-font-family "Iosevka Nerd Font"))

(use-package nerd-icons-completion
  :ensure t
  :after nerd-icons
  :config
  (nerd-icons-completion-mode 1)
  (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup))

(use-package ligature
  :ensure t
  :config
  ;; Enable all Iosevka ligatures for typographic and programming modes
  (ligature-set-ligatures 'prog-mode
                          '("|||=" "||=" "||" "|=" "|>" "感知" "::=" "::" ":=" "==" "===" "==>" "=>" "!=" "!==" "->" "-->" "->>" "->=" "<-" "<--" "<-" "<=" "<==" "<=>" "<~" "<~>" "<>" "<<" "<<-" "<<=" "<<<" ">>" ">>-" ">>=" ">>>" ".-" ".=" ".." "..." "++" "+++" "+=" "/=" "///" "/*" "*/" "safe" "&&" "&&=" "&&&" "&=" "==" "===" "==>" "=>"))
  ;; Activate ligature-mode globally
  (global-ligature-mode t))

(use-package dired
  :ensure nil
  :hook (dired-mode . dired-hide-details-mode))

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
  (let* ((rs/theme-mode (if (member my/dark-theme custom-enabled-themes)
                            "light"
                          "dark"))
         (th (if (string-equal rs/theme-mode "dark")
                 my/dark-theme
               my/light-theme))
         (is-noctalia (member 'noctalia custom-enabled-themes)))

    ;; --- Switch Doom theme ---
    (if is-noctalia
        (call-process "noctalia" nil 0 nil "msg" "theme-mode-toggle")
      (progn
        (ignore-errors (call-process "noctalia" nil 0 nil
                                     "msg" "theme-mode-set"
                                     rs/theme-mode))

        (my/load-theme th)

        ;; EXWM: make GTK/Qt apps follow the new light/dark theme (XSETTINGS picks the
        ;; light or dark member of `exwm-xsettings-theme' from the default face background).
        (when (bound-and-true-p exwm-xsettings-mode)
          (exwm-xsettings--update-settings))

        ;; Fix: Use rs/theme-mode (not rs/theme-dark) and correct string comparison
        (when (executable-find "noctalia")
          (call-process "noctalia" nil 0 nil
                        "msg" "wallpaper-set"
                        (format "~/Community-wallpapers/eos_wallpapers_community/%s"
                                (if (string-equal rs/theme-mode "light")
                                    "endeavour_os_simple_wallpaper_light.png"
                                  "endeavour_os_simple_wallpaper_dark.png")))))

      (message "Theme toggled: %s mode" rs/theme-mode))))

;; default settings
;;(add-to-list 'default-frame-alist '(alpha-background . 70))

;; --- EWM window visual separation ---
;; Dim unfocused app surfaces (compositor level)
(when (featurep 'ewm)
  (setopt ewm-unfocused-alpha 0.9))

;; Colored dividers between split windows
(setopt window-divider-width 2)
;; (custom-set-faces
;;  '(window-divider ((t (:background "#333333")))))

;; Transparent fringes so wallpaper shows through pane edges
(set-fringe-mode 0)
(set-face-attribute 'fringe nil :background nil)

;; (add-to-list 'display-buffer-alist
;;              '((lambda (buf _)
;;                  (with-current-buffer buf
;;                    (and (bound-and-true-p ewm-surface-app)
;;                         (member ewm-surface-app '("foot" "mpv")))))
;;                (display-buffer-reuse-mode-window display-buffer-at-bottom)
;;                (dedicated . t)
;;                (window-height . 0.3)
;;                (window-parameters . ((mode-line-format . none)))
;;                (post-command-select-window . t)))

;; ── Popper (popup management) ──────────────────────────────────────────

(defun my/task-buffer-p (buffer)
  "Return non-nil if BUFFER is a `ghostel-tasks' buffer (*task:...*)."
  (string-prefix-p "*task:" (buffer-name (get-buffer buffer))))

(defun my/compilation-buffer-p (buffer)
  "Return non-nil if BUFFER is a compile buffer (*compilation*, *PROJECT-compilation*)."
  (and (string-match-p "compilation\\*\\'" (buffer-name (get-buffer buffer))) t))

(defun my/left-popup-p (buffer)
  "Return non-nil if BUFFER belongs in the left popper column.
That is a `ghostel-tasks' buffer or a compile buffer."
  (or (my/task-buffer-p buffer) (my/compilation-buffer-p buffer)))

(defun my/display-task-left (buffer &optional _alist)
  "Show BUFFER in a left side window, 25% of the frame wide.
Tasks and compile buffers each get their own slot, so several stack in
the same column instead of replacing one another.  Does not select the
window."
  (let ((slot (or (cl-position buffer
                               (sort (seq-filter #'my/left-popup-p (buffer-list))
                                     (lambda (a b) (string< (buffer-name a)
                                                            (buffer-name b)))))
                  0)))
    (display-buffer-in-side-window
     buffer `((side . left) (slot . ,slot) (window-width . 0.25)))))

(defun my/popper-select-at-bottom (buffer &optional alist)
  (let ((window (if (my/left-popup-p buffer)
                    (my/display-task-left buffer alist)
                  (display-buffer-below-selected buffer '((window-height . 0.3))))))
    (if window (select-window window))))

(use-package popper
  :ensure t
  :demand t 
  :init
  
  (defun my/tridactyl-editor-buffer-p (buf)
    "Return t if BUF is a Tridactyl or Glide external-editor temp file."
    (let ((name (buffer-file-name buf)))
      (and name (or (string-match-p "^/tmp/tmp_.*\\.txt$" name)
                    (string-match-p "^/tmp/glide_text_.*\\.txt$" name)))))

  :bind (("C-`" . popper-toggle)
         ("M-`" . popper-cycle)
         ("C-M-`" . popper-toggle-type))
  :custom
  (popper-window-height 0.3)
  (popper-display-function #'my/popper-select-at-bottom)
  (popper-reference-buffers
   '("\\*Messages\\*"
     "\\*emacs-float\\*"
     "\\*Warnings\\*"
     "\\*compilation\\*"
     "^\\*.*-compilation\\*"
     "^\\*task:"
     "\\*Completions\\*"
     "\\*Compile-Log\\*"
     "\\*Help\\*"
     helpful-mode
     "\\*helpful.*\\*"
     ;;"\\*Embark Actions\\*"
     "\\*tramp\\*"
     "\\*magit-process\\*"
     "\\*Process List\\*"
     "\\*eldoc\\*"
     "\\*prodigy\\*"
     "\\*Flycheck errors\\*"
     "^\\*eglot"
     "^\\*tree-view\\*"
     "\\*Buffer List\\*"
     "\\*Ibuffer\\*"
     "\\*Apropos\\*"
     "\\*Quick Help\\*"
     "\\*Calendar\\*"
     "\\*eww buffers\\*"
     "\\*eww history\\*"
     "^claude-prompt-.*\\.md"   ; Claude Code's external-editor prompt file (no asterisks in its name)
     my/tridactyl-editor-buffer-p
     ))
  :config
  (popper-mode +1)
  (popper-echo-mode +1) ; Shows popup status cleanly in the minibuffer
  )

(provide 'config-ui)
;; config-ui.el ends here
