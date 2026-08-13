;; post-init.el --- Modular Emacs configuration loader -*- lexical-binding: t; -*-

;; Add lisp/ to load-path so `require` can find our modules
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; ── Mouse horizontal scroll ─────────────────────────────────────────────
;; Enable horizontal scrolling when tilting the mouse wheel
(setq mouse-wheel-tilt-scroll t)

;; Bind the MX Master 3 thumb wheel directly to horizontal scrolling
(global-set-key [mouse-6] #'scroll-right)
(global-set-key [mouse-7] #'scroll-left)

;; ── Load modules ─────────────────────────────────────────────────────────

;; UI: themes, font, line numbers, modeline, icons
(load "config-ui")

;; Keybindings: evil, general, leader keys, navigation, activities
(load "config-keybindings")

;; Email: mu4e + org email (loads org first)
;;(load "config-email")

;; Email: GNUS (personal Gmail via IMAP)
(load "config-gnus")

;; Org + Org-roam
(load "config-org")

;; Utils
(load "config-utils")

;; EWM integration
(load "config-ewm")

;; i3 integration
(load "config-i3")

;; Activities EWM bridge
(load "activities-ewm")


(defun rs/shell-scroll-setup ()
  (setq-local scroll-conservatively 101))

;; ── Remaining configuration (not yet extracted) ─────────────────────────

;; ── Tree-sitter (built-in) + LSP (built-in) ────────────────────────────

(require 'treesit)
(setq treesit-enabled-modes t)

;; At 3 (the default), too many users think syntax highlighting is broken or
;; simply "looks off."
(setq treesit-font-lock-level 4)

;; Associate .tsx files with typescript-ts-mode
(add-to-list 'auto-mode-alist '("\\.ts\\'" . typescript-ts-mode))
(add-to-list 'auto-mode-alist '("\\.jsx\\'" . js-ts-mode))
(add-to-list 'auto-mode-alist '("\\.py\\'" . python-ts-mode))
(setq major-mode-remap-alist '((python-mode . python-ts-mode)))


;; Tree-sitter grammar recipes (not in built-in list)
(setq treesit-language-source-alist
      '((javascript "https://github.com/tree-sitter/tree-sitter-javascript" "master" "src")
        (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "master" "tsx/src")
        (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "master" "typescript/src")
        (python "https://github.com/tree-sitter/tree-sitter-python")
        (bash "https://github.com/tree-sitter/tree-sitter-bash")
        (json "https://github.com/tree-sitter/tree-sitter-json")
        (yaml "https://github.com/ikatyang/tree-sitter-yaml")
        (toml "https://github.com/tree-sitter/tree-sitter-toml")
        (elisp "https://github.com/Wilfred/tree-sitter-elisp")
        (commonlisp "https://github.com/tree-sitter-grammars/tree-sitter-commonlisp")
        (markdown "https://github.com/tree-sitter/tree-sitter-markdown")))

(use-package eglot
  :demand t
  :hook
  ((python-ts-mode . eglot-ensure)
   (typescript-ts-mode . eglot-ensure)
   (js-ts-mode . eglot-ensure)))


(setq eglot-server-programs
      (append
       '((python-mode . ("pyright"))
         (js-mode . ("typescript-language-server" "--stdio"))
         (typescript-ts-mode . ("tsc" "--lsp" "--stdio")))
       (assq-delete-all 'python-mode 
                        (assq-delete-all 'js-mode
                                         (assq-delete-all 'typescript-ts-mode eglot-server-programs)))))
(use-package apheleia
  :ensure t
  :init
  (apheleia-global-mode +1)
  :config
  (setf (alist-get 'prettier apheleia-formatters)
        '("apheleia-npx" "prettier" "--stdin-filepath" filepath))
  )

;; Tell Eglot NEVER to attempt formatting so it won't conflict with Apheleia
(with-eval-after-load 'eglot
  (add-to-list 'eglot-ignored-server-capabilities :documentFormattingProvider))


(use-package link-hint
  :ensure t)

(use-package pdf-tools
  :ensure t
  :mode ("\\.pdf\\'" . pdf-view-mode)
  :config
  (pdf-tools-install t t))


;; ── Completion (Doom-style) ────────────────────────────────────────────

;; Vertico — vertical completion UI
(use-package vertico
  :ensure t
  :custom
  (vertico-count 17)
  (vertico-resize nil)
  (vertico-cycle t)
  (vertico-scroll-margin 2)
  (vertico-buffer-display-action
   '(display-buffer-in-direction (direction . below) (window-height . 20)))
  :config
  (vertico-mode 1)
  (vertico-buffer-mode 1)

  ;; Clean up shadowed path syntax (e.g. ~/foo/bar/// → /)
  (add-hook 'rfn-eshadow-update-overlay-hook #'vertico-directory-tidy)
  (add-hook 'minibuffer-setup-hook #'vertico-repeat-save)

  (general-define-key
   :keymaps 'vertico-map
   :states '(insert normal)
   "C-n"   #'vertico-next
   "C-p"   #'vertico-previous
   "C-j"   #'vertico-next
   "C-k"   #'vertico-previous
   "C-h"   #'vertico-directory-up
   "C-l"   #'vertico-directory-enter
   "C-SPC" #'vertico-exit-input)
  ;;"DEL"   #'vertico-directory-delete-char)

  ;; Give the minibuffer and echo area left margin padding
  (dolist (hook '(minibuffer-setup-hook
                  minibuffer-inactive-mode-hook
                  which-key-init-buffer-hook
                  ))
    (add-hook hook
              (lambda ()
                (let ((win (minibuffer-window)))
                  (with-current-buffer (window-buffer win)
                    (setq-local left-margin-width 4))
                  (set-window-buffer win (window-buffer win))))))

  ;; Highlight directories and enabled modes (Doom-style)
  (require 'vertico-multiform)
  (vertico-multiform-mode 1)
  (defun +vertico-highlight-directory (f)
    (when (string-suffix-p "/" f)
      (add-face-text-property 0 (length f) 'marginalia-file-priv-dir 'append f))
    f)
  (defun +vertico-highlight-enabled-mode (cmd)
    (let ((sym (intern cmd)))
      (with-current-buffer (nth 1 (buffer-list))
        (when (or (eq sym major-mode)
                  (and (memq sym minor-mode-list)
                       (boundp sym) (symbol-value sym)))
          (add-face-text-property 0 (length cmd) 'font-lock-constant-face 'append cmd))))
    cmd)
  (add-to-list 'vertico-multiform-categories
               '(file (+vertico-transform-functions . +vertico-highlight-directory)))
  (add-to-list 'vertico-multiform-commands
               '(execute-extended-command
                 (+vertico-transform-functions . +vertico-highlight-enabled-mode))))

;; Marginalia — rich annotations
(use-package marginalia
  :ensure t
  :after vertico
  :config
  (marginalia-mode 1)
  (general-define-key
   :keymaps 'minibuffer-local-map
   "M-A" #'marginalia-cycle))

;; Solaire — dual-background mode for side windows and minibuffer
(use-package solaire-mode
  :ensure t
  :demand t
  :custom
  (solaire-mode-supported-themes :all)
  :config
  (add-hook 'vertico-mode-hook #'solaire-mode)
  (add-hook 'marginalia-mode-hook #'solaire-mode)
  (add-hook 'embark-collect-mode-hook #'solaire-mode)
  (add-hook 'consult-src-mode-hook #'solaire-mode)
  (add-hook 'consult--process-filter-hook #'solaire-mode)
  (solaire-global-mode +1))

;; Orderless — flexible completion style
(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles orderless partial-completion))))
  (orderless-component-separator #'orderless-escapable-split)
  (orderless-affix-dispatch-alist
   '((?! . orderless-without-literal)
     (?& . orderless-annotation)
     (?% . char-fold-to-regexp)
     (?` . orderless-initialism)
     (?= . orderless-literal)
     (?^ . orderless-literal-prefix)
     (?~ . orderless-flex))))

;; Corfu — in-buffer completion
(use-package corfu
  :after evil-collection
  :custom
  (corfu-auto t)
  (corfu-auto-delay 0.2)
  (read-extended-command-predicate #'command-completion-default-include-p)
  (text-mode-ispell-word-completion nil)
  (tab-always-indent 'complete)
  :bind (:map corfu-map
              ("<mouse-1>" . corfu-select)
              ("TAB" . corfu-next)
              ("BACKTAB" . corfu-previous))
  :config
  (global-corfu-mode +1)
  (setq
   corfu-preselect 'prompt
   corfu-count 16
   corfu-max-width 120
   corfu-on-exact-match nil
   corfu-quit-at-boundary 'separator
   corfu-quit-no-match corfu-quit-at-boundary)
  
  (add-to-list 'completion-category-overrides `(lsp-capf (styles ,@completion-styles)))
  (add-hook 'evil-insert-state-exit-hook #'corfu-quit)
  )

(use-package expreg
  :ensure t
  :after evil
  :bind (:map evil-visual-state-map
              ("RET" . expreg-expand)   ;; Press 'v' in visual mode to expand
              ("-" . expreg-contract) ;; Press capital 'V' to contract selection
              :map global-map
              ("C-=" . expreg-expand))) ;; Global key fallback


;; ── Search (Doom-style) ────────────────────────────────────────────────

;; Consult — efficient searching and previewing
(use-package consult
  :ensure t
  :bind (
         ("M-y" . consult-yank-pop)
         ("M-g g" . consult-goto-line)
         ("M-g i" . consult-imenu)
         ("M-g M-g" . consult-goto-line))
  :config
  (setq consult-narrow-key "<"
        consult-line-numbers-widen t
        consult-async-min-input 2
        consult-async-refresh-delay 0.15
        consult-async-input-throttle 0.2
        consult-async-input-debounce 0.1
        register-preview-delay 0.3
        register-preview-function #'consult-register-format)

  (consult-customize
   consult-ripgrep consult-git-grep consult-grep
   consult-bookmark consult-recent-file consult-theme
   :preview-key "C-SPC")

  (defun consult--orderless-regexp-compiler (input type &rest _config)
    (setq input (cdr (orderless-compile input)))
    (cons
     (mapcar (lambda (r) (consult--convert-regexp r type)) input)
     (lambda (str) (orderless--highlight input t str))))

  ;; Apply it globally to consult-find, consult-grep, and consult-ripgrep
  (setq consult--regexp-compiler #'consult--orderless-regexp-compiler)

  (setq consult-line-start-from-top nil)

  

  (defun noct-consult-line-evil-history (&rest _)
    "Add latest `consult-line' search pattern to the evil search history ring.
This only works with orderless and for the first component of the search."
    (when (and (bound-and-true-p evil-mode)
               (eq evil-search-module 'evil-search))
      (let ((pattern (car consult--line-history)))
        (add-to-history 'evil-ex-search-history pattern)
        (setq evil-ex-search-pattern (list pattern t t))
        ;;(evil-push-search-history pattern t)
        (add-to-history 'regexp-search-ring pattern)
        (setq evil-ex-search-direction 'forward)
        (when evil-ex-search-persistent-highlight
          (evil-ex-search-activate-highlight evil-ex-search-pattern)))))

  (advice-add #'consult-line :after #'noct-consult-line-evil-history)

  (evil-define-key 'normal 'global "/" #'consult-line)
  )

(use-package consult-dir
  :ensure t
  :bind (("C-x C-d" . consult-dir)
         :map minibuffer-local-completion-map
         ("C-x C-d" . consult-dir)
         ("C-x C-j" . consult-dir-jump-file)))

;; Embark — context-sensitive actions
(use-package embark
  :ensure t
  :bind (("C-." . embark-act)
         :map minibuffer-local-map
         ("C-." . embark-act))
  :config
  (setq prefix-help-command #'embark-prefix-help-command)

  ;; (defun my-embark-which-key-indicator (&rest args)
  ;;   "Safely send embark actions straight to which-key."
  ;;   (let ((bindings (car args)))
  ;;     (when (keymapp bindings)
  ;;       (let ((embark-indicators nil))
  ;;         (which-key--show-keymap "Embark Actions"
  ;;                                 (embark-collect-aligned-bindings bindings)
  ;;                                 nil nil t)))))
  ;; 
  ;; ;; Reset and cleanly register our new indicator
  ;; (setq embark-indicators
  ;;       '(embark-highlight-indicator
  ;;         embark-mixed-indicator
  ;;         embark-isearch-highlight-indicator))
  
  )

;; Embark-consult — integration
(use-package embark-consult
  :ensure t
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

;; ── Recent files ───────────────────────────────────────────────────────

(use-package recentf
  :config
  (recentf-mode 1)
  (setq recentf-max-saved-items 200)
  ;; exclude tridactly buffers
  (add-to-list 'recentf-exclude "/tmp/tmp_[^/]*$") 
  (add-to-list 'recentf-exclude "/tmp/\glide_text_[^/]*$")
  )

;; ── Project (built-in) ─────────────────────────────────────────────────

(use-package project
  :demand t
  ;; :bind (("C-c p" . project-find-file)
  ;;        ("C-c M-g" . magit-status)
  ;;        ("C-c M-s" . consult-projectile-grep))
  :config
  (setq project-vc-extra-file-search-functions nil)
  (project-remember-project (cons 'transient (expand-file-name "~/Dropbox/")))

  (defvar my-project-git-root-cache (make-hash-table :test 'equal)
    "Cache of directory -> git project root, to avoid repeated locate-dominating-file walks over TRAMP.")

  (defun my-project-try-git (dir)
    "Detect a Git project root by checking for a .git directory.
Works over TRAMP without relying on `vc-handled-backends'.
Caches result per DIR to avoid repeated ancestor walks."
    (let ((cached (gethash dir my-project-git-root-cache 'not-found)))
      (if (not (eq cached 'not-found))
          cached
        (let ((result
               (when-let ((root (locate-dominating-file dir ".git")))
                 (when (file-directory-p (expand-file-name ".git" root))
                   (list 'vc 'Git root)))))
          (puthash dir result my-project-git-root-cache)
          result))))

  (add-hook 'project-find-functions #'my-project-try-git 'append)
  )



;; ── Git ────────────────────────────────────────────────────────────────

(use-package forge
  :ensure t
  :if (locate-library "forge")
  :after magit
  :config
  (setq forge-add-default-bindings nil)
  )

(use-package magit
  :commands magit-file-delete
  :custom
  (magit-status-show-untracked-files t)
  (magit-process-apply-ansi-colors t)
  (magit-save-repository-buffers nil)
  (magit-revision-insert-related-refs nil)
  (magit-uniquify-buffer-names nil)
  (magit-diff-refine-hunk t)
  (magit-display-buffer-function 'magit-display-buffer-same-window-except-diff-v1)
  ;; (magit-git-executable (or (executable-find magit-git-executable) "git"))
  :config
  ;; Turn ref links into clickable buttons
  ;;(add-hook 'magit-process-mode-hook #'goto-address-mode)

  (require 'evil-collection-magit)

  (general-define-key
   :states 'normal
   :keymaps 'magit-mode-map

   "]" #'magit-section-forward-sibling
   "[" #'magit-section-backward-sibling

   "]c" #'magit-section-forward
   "[c" #'magit-section-backward

   "]]" #'magit-section-forward-sibling
   "[[" #'magit-section-backward-sibling)
  (add-hook 'git-commit-setup-hook #'evil-insert-state)
  )

;; (use-package forge
;;   :after magit)

(use-package transient
  :ensure nil
  :config
  (setq transient-default-level 5
        transient-display-buffer-action
        '(display-buffer-below-selected
          (dedicated . t)
          (inhibit-same-window . t))
        transient-show-during-minibuffer-read t)
  (define-key transient-map [escape] #'transient-quit-one))

;; ── Smartparens ────────────────────────────────────────────────────────

(use-package smartparens
  :ensure t
  :after evil
  :init
  (smartparens-global-strict-mode 1)
  :config
  (require 'smartparens-config)
  ;; (sp-local-pair 'org-mode "(" ")" :postchain "\\C-m" :skip-self t)
  ;; (sp-local-pair 'org-mode "{" "}" :postchain "\\C-m" :skip-self t)
  )

;; Make smartparens work with evil
(use-package evil-smartparens
  :ensure t
  :after (smartparens evil))


;; ── Popper (popup management) ──────────────────────────────────────────

(defun my/popper-select-at-bottom (buffer &optional alist)
  (let ((window (display-buffer-below-selected buffer '((window-height . 0.3)))))
    (select-window window)))

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
     "^\\*v?term.*"
     "\\*Buffer List\\*"
     "\\*Ibuffer\\*"
     "\\*Apropos\\*"
     "\\*Quick Help\\*"
     "\\*Calendar\\*"
     "\\*eww buffers\\*"
     "\\*eww history\\*"
     my/tridactyl-editor-buffer-p
     ))
  :config
  (popper-mode +1)
  (popper-echo-mode +1) ; Shows popup status cleanly in the minibuffer
  )

;; ── Lookup (Doom-style "K") ────────────────────────────────────────────────

(define-key evil-normal-state-map (kbd "K")
            (lambda () (interactive)
              (if (or (eq major-mode 'helpful-mode) (eq major-mode 'help-mode) (eq major-mode 'emacs-lisp-mode))
                  (helpful-at-point)
                (eglot-help-at-point))))

;; ── Dirvish (improved dired) ───────────────────────────────────────────

(use-package dirvish
  :ensure t
  :defer t
  :init
  :config
  (add-to-list 'load-path (concat user-emacs-directory "elpa/dirvish-2.3.0/extensions"))
  (require 'dirvish)
  (require 'dirvish-icons)
  (require 'dirvish-quick-access)
  (require 'dirvish-yank)
  (dirvish-override-dired-mode 1)
  (setq dired-kill-when-openinging-new-dired-buffer t)
  )

;; ── EWW rdrview (reader view via Mozilla Readability C port) ───────────

(defun eww-rdrview-update-title ()
  "Update `eww-data' :title from the first line of the buffer
(which rdrview prepends as the page title)."
  (when (eq major-mode 'eww-mode)
    (save-excursion
      (goto-char (point-min))
      (when-let ((title (thing-at-point 'line t)))
        (plist-put eww-data :title (string-trim title))))
    (eww--after-page-change)))

(defun my-eww-rename-buffer ()
  "Rename EWW buffers to show the page title."
  (when (eq major-mode 'eww-mode)
    (when-let ((string (or (plist-get eww-data :title)
                           (plist-get eww-data :url))))
      (format "%s *eww*" string))))

(define-minor-mode eww-rdrview-mode
  "Toggle reader view in EWW using `rdrview' (Mozilla Readability C port).
When enabled, EWW pipes page HTML through rdrview for cleaner rendering."
  :lighter " rdrview"
  (if eww-rdrview-mode
      (progn
        (setq eww-retrieve-command '("rdrview" "-T" "title,sitename,body" "-H"))
        (add-hook 'eww-after-render-hook #'eww-rdrview-update-title))
    (progn
      (setq eww-retrieve-command nil)
      (remove-hook 'eww-after-render-hook #'eww-rdrview-update-title))))

(defun eww-rdrview-toggle-and-reload ()
  "Toggle `eww-rdrview-mode' and reload the current EWW page."
  (interactive)
  (if eww-rdrview-mode
      (eww-rdrview-mode -1)
    (eww-rdrview-mode 1))
  (eww-reload))

(setq eww-auto-rename-buffer #'my-eww-rename-buffer)

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
  (rmh-elfeed-org-files '("~/notes/elfeed.org"))
  :config
  (elfeed-org))

(use-package lobsters
  :ensure t)
;; ── Eat (terminal emulator) ────────────────────────────────────────────


(use-package eshell
  :config
  (setq eshell-scroll-to-bottom-on-input t)
  (setq-local tab-always-indent 'complete)
  (setq eshell-history-size 10000)
  (setq eshell-save-history-on-exit t) ;; Enable history saving on exit
  (setq eshell-hist-ignoredups t) ;; Ignore duplicates

  (setenv "EDITOR" "emacsclient")
  (setenv "VISUAL" "emacsclient")

  ;; (general-def
  ;;   :keymaps 'eshell-prompt-mode-map
  ;;   :states 'insert
  ;;   "C-p" #'eshell-previous-matching-input-from-input
  ;;   "C-n" #'eshell-next-matching-input-from-input
  ;; )
  )

(use-package eat
  :hook (eat-mode . rs/shell-scroll-setup)
  :ensure t
  :config
  (eat-eshell-mode 1)
  (evil-set-initial-state 'eat-term-mode 'emacs)

  (defun my/eat-left ()
    (interactive)
    (eat-self-input 1 'left))

  (defun my/eat-right ()
    (interactive)
    (eat-self-input 1 'right))

  (defun my/eat-left-word ()
    (interactive)
    (backward-word 1))

  (defun my/eat-right-word ()
    (interactive)
    (forward-word 1))

  (defun my/eat-down ()
    (interactive)
    (eat-self-input 1 'down))

  ;; (evil-define-key 'normal eat-semi-char-mode-map
  ;;   "h" #'my/eat-left
  ;;   "f" #'forward-word
  ;;   "b" #'backward-word
  ;;   ;; "j" #'my/eat-down
  ;;   ;; "k" #'my/eat-up
  ;;   "l" #'my/eat-right)
  )

(with-eval-after-load 'eshell
  (require 'em-hist)
  (add-hook 'eshell-mode-hook  #'rs/shell-scroll-setup)
  (add-to-list 'eshell-modules-list 'eshell-rebind)
  ;; (add-to-list 'eshell-modules-list 'eshell-smart)

  (setq eshell-history-size 10000)

  (add-hook 'eshell-expand-input-functions
            #'eshell-expand-history-references)

  (setq eshell-command-aliases-list
        '(("st" "systemctl $*")
          ("stu" "systemctl --user $*")
          ("f" "find-file $1")
          ("ff" "find-alternate-file $1")
          ("doom" "$HOME/.config/emacs/bin/doom $*")
          ("zshconfig" "ff ~/.zshrc")
          ("i3config" "ff ~/.config/i3/config")
          ("niriconfig" "ff ~/.config/niri/config.kdl")
          ("swayconfig" "ff ~/.config/sway/config")
          ("ewmconfig" "ff ~/.config/doom/config-ewm.el")
          ("ohmyzsh" "ff ~/.oh-my-zsh")
          ("rewaybar" "killall waybar; nohup waybar >/dev/null 2>&1 &"))
        ))

(with-eval-after-load 'evil-collection
  (with-eval-after-load 'eshell
    (setq eshell-visual-commands '()
          eat-term-name "xterm-256color")
    (define-key eshell-mode-map (kbd "RET") #'eshell-send-input)))


;; ── diminish (hide minor modes from modeline) ───────────────────────

(use-package diminish
  :ensure t)

;; ── Golden Ratio (automatic window resizing) ─────────────────────────

;; (use-package golden-ratio
;;   :ensure t
;;   :diminish golden-ratio-mode
;;   :config
;;   (setq golden-ratio-auto-scale t)  ; Auto-scale for wide screens
;;   (golden-ratio-mode -1))

;; ── Tmux control mode ──────────────────────────────────────────────────

(use-package tmux-control
  :vc (:url "https://github.com/csheaff/tmux-control" :rev "6cba37a20c9e0eb3620cd1cd7aae757e4707cb9")
  :config
  (setq tmux-control-default-host "desktop-pc"
        tmux-control-default-socket-name "/tmp/tmux-1000/default"
        tmux-control-default-session "main"
        tmux-control-windows-buffers nil)

  (defun my/desktop-pc ()
    "Connect to desktop-pc via tmux-control, prompting only for session."
    (interactive)
    (let ((session (tmux-control--read-session "desktop-pc" "default")))
      (tmux-control-connect "desktop-pc" "default" session))
    )
  (defun my/laptop-pc ()
    "Connect to desktop-pc via tmux-control, prompting only for session."
    (interactive)
    (let ((session (tmux-control--read-session "" "default")))
      (tmux-control-connect "" "default" session))
    )
  (my-leader-def
    "od" '(my/desktop-pc :which-key "Tmux Desktop")
    "ol" '(my/laptop-pc :which-key "Tmux Laptop"))

  ;; ── Bookmark support (like mu4e) ──────────────────────────────────────

  (defun my/tmux-control-bookmark-handler (bookmark)
    "Restore a tmux-control bookmark by reconnecting to the saved session."
    (let* ((bmk-data (bookmark-get-bookmark-record bookmark))
           (host (cdr (assq 'host bmk-data)))
           (socket (cdr (assq 'socket bmk-data)))
           (session (cdr (assq 'session bmk-data))))
      (if (get-buffer (format "*tmux-control:%s:%s*" (or host "") session))
          (pop-to-buffer (format "*tmux-control:%s:%s*" (or host "") session))
        (tmux-control--connect-or-switch host socket session))))

  (defun my/tmux-control-bookmark-make-record ()
    "Create a bookmark record for the current tmux-control buffer."
    (let* ((host tmux-control--host)
           (socket (or tmux-control--socket-name "default"))
           (session (or tmux-control--session "main")))
      `("tmux-control"
        (handler . my/tmux-control-bookmark-handler)
        (host . ,host)
        (socket . ,socket)
        (session . ,session))))

  (add-hook 'tmux-control-mode-hook
            (lambda ()
              (setq-local bookmark-make-record-function
                          #'my/tmux-control-bookmark-make-record)))
  )

;; ── rg (ripgrep integration) ───────────────────────────────────────────

(use-package rg
  :ensure t
  :config
  (rg-enable-menu))

;; ── HTTP / API testing (verb) ──────────────────────────────────────────

(use-package verb
  :ensure t
  :defer t
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((verb . t)))
  (setq verb-suppress-load-unsecure-prelude-warning t))

;; ── Copy-as-format ─────────────────────────────────────────────────────

;; (use-package copy-as-format
;;   :ensure t)

;; ── Bookmark manager (ebuku) ───────────────────────────────────────────

;; (use-package ebuku
;;   :ensure t
;;   :defer t)

;; ── Org Super Agenda ──────────────────────────────────────────────────

;; (use-package org-super-agenda
;;   :ensure t)

;; ── agent-shell ecosystem ─────────────────────────────────────────────

(use-package exec-path-from-shell
  :ensure t
  :config
  (exec-path-from-shell-initialize)
  )

;; (use-package pinentry
;;   :ensure t)

;; ── acp (agent client protocol) ───────────────────────────────────────────
(use-package acp
  :ensure t)

;; ── agent-shell + notifications + bookmarks ────────────────────────────

(use-package agent-shell
  :hook (agent-shell-mode . rs/shell-scroll-setup)
  :ensure t
  :defer t
  :config
  (setq agent-shell-anthropic-claude-environment
        (agent-shell-make-environment-variables
         "AWS_PROFILE" "hermes"
         )
        agent-shell-opencode-environment
        (agent-shell-make-environment-variables
         "OPENCODE_ENABLE_EXA" "1"
         )
        agent-shell-pi-environment
        (agent-shell-make-environment-variables
         ;; "PI_ACP_PI_COMMAND" "little-coder"
         "LITTLE_CODER_BASH_ALLOW" "docker ,npm ,tmux, emacsclient"
         ))
  (add-to-list 'agent-shell-agent-configs (agent-shell-hermes-make-agent-config) t)
  (setq agent-shell-confirm-interrupt nil
        agent-shell-hermes-acp-command '("hermes" "-p" "chief-of-staff" "acp"))
  ;; (add-hook 'diff-mode-hook
  ;;           (lambda ()
  ;;             (when (string-match-p "\\*agent-shell-diff\\*" (buffer-name))
  ;;               (evil-emacs-state))))
  ;; Mode-specific keys — only active in agent-shell-mode buffers
  ;; (general-define-key
  ;;  :states 'normal
  ;;  :keymaps 'agent-shell-mode-map
  ;;  "["   #'agent-shell-previous-item
  ;;  "]"   #'agent-shell-next-item
  ;;  "TAB" #'agent-shell-ui-toggle-fragment
  ;;  "q"   #'agent-shell-toggle
  ;;  "c"   #'agent-shell-prompt-compose
  ;;  "x"   #'agent-shell-interrupt)
  ;; 
  (defun agent-shell/setup ()
    (evil-collection-unimpaired-mode -1)
    (evil-commentary-mode -1)
    (evil-define-key 'normal agent-shell-mode-map
      [tab]       #'agent-shell-ui-toggle-fragment
      (kbd "TAB") #'agent-shell-ui-toggle-fragment
      (kbd "]")   #'agent-shell-next-item
      (kbd "[")   #'agent-shell-previous-item)
    )
  

  (add-hook 'agent-shell-mode-hook #'agent-shell/setup)

  (with-eval-after-load 'evil-collection-agent-shell
    (agent-shell/setup)
    )
  )

(use-package agent-shell-tramp
  :vc (:url "https://github.com/junyi-hou/agent-shell-tramp" :rev "ebdeb204973beb116017a977bee52cdced78e447")
  :config
  (agent-shell-tramp-mode 1)
  ;; (connection-local-set-profile-variables
  ;;  'remote-direct-async-process
  ;;  '((tramp-direct-async-process . t)))
  ;; 
  ;; (connection-local-set-profiles
  ;;  '(:application tramp)
  ;;  'remote-direct-async-process)


  )

(use-package agent-shell-bookmark
  :vc (:url "https://github.com/dcluna/agent-shell-bookmark" :rev "c1eab34bff4f35bf929885ed5045c6100afcf496")
  :config

  (defun my-agent-shell-bookmark--find-config (agent-identifier)
    "Find config by identifier, supporting both maker symbols and alists."
    (when agent-identifier (or
                            ;; Newer style: maker function symbols
                            (let ((maker
                                   (seq-find (lambda (entry)
                                               (and (symbolp entry) (string-match-p (format "-%s-" (symbol-name agent-identifier)) (symbol-name entry))))
                                             agent-shell-agent-configs)))
                              (when maker (funcall maker)))
                            ;; Older style: realized config alists
                            (seq-find (lambda (entry)
                                        (and (listp entry)
                                             (eq (alist-get :identifier entry) agent-identifier)))
                                      agent-shell-agent-configs))))

  (defun my-agent-shell-bookmark--find-config (agent-identifier)
    "Work around agent-shell-agent-configs containing maker function symbols."
    (and agent-identifier
         (seq-find (lambda (config) (and (listp config) (eq (alist-get :identifier config) agent-identifier))) agent-shell-agent-configs)))

  (advice-add 'agent-shell-bookmark--find-config :override #'my-agent-shell-bookmark--find-config)
  )

;; ── agent-recall (search/browse agent-shell transcripts) ───────────────

(use-package agent-recall
  :ensure t
  :hook (agent-shell-mode . agent-recall-track-sessions)
  :config
  (setq agent-recall-search-paths '("~/Dropbox" "~/.config/emacs" "~/projects" "~/work" "~/.agent-shell")
        agent-recall-search-function 'consult-ripgrep
        agent-recall-browse-sort 'modified-desc))

;; ── gptel ──────────────────────

(use-package gptel
  :ensure t
  :config
  (setq gptel-api-key "your key")
  (setq gptel-backend (gptel-make-openai "Beellama"             ;Any name of your choosing
                        :protocol "http"
                        :host "desktop-pc:8020"               ;Where it's running
                        :stream t                             ;Stream responses
                        :models '(Qwen3.6-27B-MTP-IQ4_KS.gguf)))          ;List of models
  )

;; ── shell-maker (create custom shells in eshell) ──────────────────────

(use-package shell-maker
  :ensure t
  :config
  (advice-add 'shell-maker-submit :after
              (lambda (&rest _)
                (goto-char (point-max))
                (evil-normal-state 1)
                )))

;; ── capf-autosuggest (eshell completion hints) ─────────────────────────

(use-package capf-autosuggest
  :ensure t
  :hook (eshell-mode . capf-autosuggest-mode)
  :config

  (add-hook 'eshell-mode-hook #'capf-autosuggest-mode)
  (setq capf-autosuggest-backends '(capf-autosuggest-eshell-history))
  (with-eval-after-load 'eshell
    (define-key eshell-mode-map (kbd "C-f") #'capf-autosuggest-accept)
    ;; (define-key capf-autosuggest-mode-map (kbd "M-p") #'eshell-previous-input)
    ;; (define-key capf-autosuggest-mode-map (kbd "M-n") #'eshell-next-input)
    )
  )

;; ── Quickrun ───────────────────────────────────────────────────────────

(use-package quickrun
  :ensure t)

;; ── EWM (Wayland compositor) integration ───────────────────────────────

(if (getenv "EWM_MODULE_PATH")
    (load-file (expand-file-name "lisp/config-ewm.el" user-emacs-directory))
  (load-file (expand-file-name "lisp/config-i3.el" user-emacs-directory)))


;; server edit
;; for tridactyl
(setq server-window 'pop-to-buffer)
(defun my/evil-save-modified-and-close (orig &rest args)
  (if server-buffer-clients
      (progn
        (save-buffer)
        (server-edit)
        ;;        (evil-window-delete)
        )
    (apply orig args)))

(add-hook 'server-done-hook
          (defun my/on-server-done ()
            (let ((win (get-buffer-window)))
              (when win
                ;; If popper is tracking this window, use popper to close it cleanly
                (if (bound-and-true-p popper-mode)
                    (with-selected-window win
                      (popper-close-latest))
                  ;; Otherwise, just delete the window normally
                  (delete-window win))))))


(advice-add #'evil-save-modified-and-close
            :around #'my/evil-save-modified-and-close)

(add-hook 'server-visit-hook
          (defun my/server-visit-insert ()
            (when server-buffer-clients
              (evil-insert-state))))

(defun my/save-client-buffer()
  (interactive)
  (save-buffer) (server-edit)
  )

(defun my/save-client-abort-buffer()
  (interactive)
  (server-edit-abort)
  ;; (delete-window)
  (if (bound-and-true-p popper-mode)
      (popper-close-latest)
    )
  )

(define-minor-mode tridactyl-edit-mode
  "A minor mode for editing text fields sent from Firefox via Tridactyl."
  :lighter " Tri"
  :keymap (let ((map (make-sparse-keymap)))
            ;; Standard Emacs keys
            (define-key map (kbd "C-c C-c") #'my/save-client-buffer)
            (define-key map (kbd "C-c C-k") 'my/save-client-abort-buffer)
            map)
  
  ;; --- THE EVIL MODE FIX ---
  ;; This automatically redefines ":q", ":wq", and "ZZ" ONLY inside Tridactyl buffers
  (evil-insert-state)
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "ZZ")))
  (evil-local-set-key 'normal (kbd "ZQ") #'my/save-client-buffer)
  (with-eval-after-load 'evil-ex
    (evil-ex-define-local-cmd "q" 'my/save-client-abort-buffer)
    (evil-ex-define-local-cmd "wq" #'my/save-client-buffer)
    (evil-ex-define-local-cmd "x" #'my/save-client-buffer)))

(add-to-list 'auto-mode-alist '("/tmp/tmp_[^/]*$" . tridactyl-edit-mode))
(add-to-list 'auto-mode-alist '("/tmp/glide_text_[^/]*$" . tridactyl-edit-mode))


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

(defun thanos/wtype-text (text)
  "Process TEXT for wtype, handling newlines properly."
  (let* ((has-final-newline (string-match-p "\n$" text))
         (lines (split-string text "\n"))
         (last-idx (1- (length lines))))
    (string-join
     (cl-loop for line in lines
              for i from 0
              collect (cond
                       ;; Last line without final newline
                       ((and (= i last-idx) (not has-final-newline))
                        (format "wtype -s 350 \"%s\""
                                (replace-regexp-in-string "\"" "\\\\\"" line)))
                       ;; Any other line
                       (t
                        (format "wtype -s 350 \"%s\" && wtype -k Return"
                                (replace-regexp-in-string "\"" "\\\\\"" line)))))
     " && ")))

(defvar thanos/type-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c")
                (lambda () (interactive)
                  (let ((value (buffer-string)))
                    (if (bound-and-true-p popper-mode)
                        (popper-close-latest)
                      )
                    (start-process-shell-command
                     "wtype " nil
                     (thanos/wtype-text value)))
                  ))
    (define-key map (kbd "C-c C-k")
                (lambda () (interactive)
                  (kill-new (buffer-string))
                  (if (bound-and-true-p popper-mode)
                      (popper-close-latest)
                    )
                  )
                )
    map))

(define-minor-mode thanos/type-mode
  ""
  :keymap thanos/type-mode-map)

(defun thanos/type ()
  "Launch a temporary frame with a clean buffer for typing."
  (interactive)
  (let ((buf (get-buffer-create "*emacs-float*")))
    (pop-to-buffer buf)
    (erase-buffer)
    (org-mode)
    (thanos/type-mode 1)
    (evil-insert-state)
    (setq-local header-line-format
                (format " %s to insert text or %s to cancel."
                        (propertize "C-c C-c" 'face 'help-key-binding)
                        (propertize "C-c C-k" 'face 'help-key-binding)))
    
    ))

(with-eval-after-load 'eww
  (define-key eww-mode-map (kbd "=") #'text-scale-increase)
  (define-key eww-mode-map (kbd "-") #'text-scale-decrease)
  (define-key eww-mode-map (kbd "0") #'text-scale-adjust))

(setq shr-width 100)
(setq shr-max-width 120)
(setq shr-indentation 4)

(setq shr-use-fonts nil)
(setq shr-max-image-size '(800 . 600))
(setq shr-image-animate t)
(setq eww-search-prefix "https://html.duckduckgo.com/html/?q=")
(setq eww-auto-rename-buffer t)
(setq
 shr-use-colors nil
 shr-bullet "• "
 shr-folding-mode t
 )

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


;; Glide  browser
(load "config-browser")


;; Swap trackpad horizontal scroll for non-natural scrolling
(global-set-key [horizontal-scroll left] #'scroll-left)
(global-set-key [horizontal-scroll right] #'scroll-right)

(provide 'post-init)

