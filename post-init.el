;; post-init.el --- Modular Emacs configuration loader -*- lexical-binding: t; -*-

;; Add lisp/ to load-path so `require` can find our modules
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; ── Load modules ─────────────────────────────────────────────────────────

;; UI: themes, font, line numbers, modeline, icons
(load "config-ui")

;; Keybindings: evil, general, leader keys, navigation, activities
(load "config-keybindings")

;; Email: mu4e + org email (loads org first)
(load "config-email")

;; Org + Org-roam
(load "config-org")

;; EWM integration
(load "config-ewm")

;; i3 integration
(load "config-i3")

;; Activities EWM bridge
(load "activities-ewm")

;; ── Remaining configuration (not yet extracted) ─────────────────────────

;; ── Tree-sitter (built-in) + LSP (built-in) ────────────────────────────

(require 'treesit)
(setq treesit-enabled-modes t)

;; At 3 (the default), too many users think syntax highlighting is broken or
;; simply "looks off."
(setq treesit-font-lock-level 4)

;; Associate .tsx files with typescript-ts-mode
(add-to-list 'auto-mode-alist '("\\.tsx\\'" . typescript-ts-mode))
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
         (typescript-ts-mode . ("typescript-language-server" "--stdio")))
       (assq-delete-all 'python-mode 
                        (assq-delete-all 'js-mode
                                         (assq-delete-all 'typescript-ts-mode eglot-server-programs)))))
(use-package apheleia
  :ensure t
  :init
  (apheleia-global-mode +1))

;; Tell Eglot NEVER to attempt formatting so it won't conflict with Apheleia
(with-eval-after-load 'eglot
  (add-to-list 'eglot-ignored-server-capabilities :documentFormattingProvider))


(use-package link-hint
  :ensure t)

(use-package pdf-tools
  :ensure t)


;; ── Completion (Doom-style) ────────────────────────────────────────────

;; Vertico — vertical completion UI
(use-package vertico
  :ensure t
  :custom
  (vertico-count 17)
  (vertico-resize nil)
  (vertico-cycle t)
  (vertico-scroll-margin 2)
  :config
  (vertico-mode 1)
  (setq completion-in-region-function
        #'consult-completion-in-region)

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

;; Orderless — flexible completion style
(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles orderless partial-completion))))
  (orderless-component-separator #'orderless-escapable-split-on-space)
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
  (global-corfu-mode)
  (setq
   corfu-preselect 'prompt
   corfu-count 16
   corfu-max-width 120
   corfu-on-exact-match nil
   corfu-quit-at-boundary (if (or (modulep! :completion vertico)
                                  (modulep! +orderless))
                              'separator t)
   corfu-quit-no-match corfu-quit-at-boundary)
  
  (add-to-list 'completion-category-overrides `(lsp-capf (styles ,@completion-styles)))
  (add-to-list 'corfu-continue-commands #'+corfu/move-to-minibuffer)
  (add-to-list 'corfu-continue-commands #'+corfu/smart-sep-toggle-escape)
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
  (setq prefix-help-command #'embark-prefix-help-command))

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

  (defun my-project-try-git (dir)
    "Detect a Git project root by checking for a .git directory.
Works over TRAMP without relying on `vc-handled-backends'."
    (when-let ((root (locate-dominating-file dir ".git")))
      (when (file-directory-p (expand-file-name ".git" root))
        (list 'vc 'Git root))))

  (add-hook 'project-find-functions #'my-project-try-git 'append)
  )



;; ── Git ────────────────────────────────────────────────────────────────

(use-package magit
  :commands magit-file-delete
  :custom
  (magit-status-show-untracked-files t)
  (magit-process-apply-ansi-colors t)
  (magit-save-repository-buffers nil)
  (magit-revision-insert-related-refs nil)
  (magit-uniquify-buffer-names nil)
  (magit-diff-refine-hunk t)
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

(use-package popper
  :ensure t
  :demand t  ; <--- CRITICAL FIX: Forces immediate loading, bypassing :bind lazy-loading
  :bind (("C-`" . popper-toggle)
         ("M-`" . popper-cycle)
         ("C-M-`" . popper-toggle-type))
  :custom
  (popper-window-height 0.3)
  (popper-reference-buffers
   '("\\*Messages\\*"
     "\\*Warnings\\*"
     "\\*compilation\\*"
     "\\*Completions\\*"
     "\\*Help\\*"
     helpful-mode
     "\\*helpful.*\\*"
     "\\*tramp\\*"
     "\\*magit-process\\*"
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
     ))
  :config
  (popper-mode +1)
  (popper-echo-mode +1)) ; Shows popup status cleanly in the minibuffer

;; ── Lookup (Doom-style "K") ────────────────────────────────────────────────

(define-key evil-normal-state-map (kbd "K")
            (lambda () (interactive)
              (if (or (eq major-mode 'helpful-mode) (eq major-mode 'help-mode) (eq major-mode 'emacs-lisp-mode))
                  (helpful-at-point)
                (eglot-help-at-point))))

;; ── Dirvish (improved dired) ───────────────────────────────────────────

(use-package dirvish
  :ensure t
  :defer t)

;; ── Elfeed (RSS reader) ────────────────────────────────────────────────
(use-package elfeed
  :ensure t
  :defer t
  :config
  (setopt rmh-elfeed-org-files '("~/notes/elfeed.org"))
  (setopt elfeed-search-filter "@3days +unread")
  (add-hook 'elfeed-search-mode-hook #'elfeed-update)
  )

(use-package elfeed-org
  :after elfeed
  :ensure t
  :config
  (elfeed-org))

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
  :ensure t
  :hook ((eshell-mode . eat-eshell-mode)
         ;;(eat-mode-hook . mode-line-invisible-mode)
         )
  :config
  (evil-set-initial-state 'eat-term-mode 'emacs)
  )

(with-eval-after-load 'eshell
  (require 'em-hist)

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

;; ── Tmux control mode ──────────────────────────────────────────────────

(use-package tmux-control
  :vc (:url "https://github.com/csheaff/tmux-control" :rev :newest)
  :config
  (setq tmux-control-default-host "desktop-pc"
        tmux-control-default-socket-name "/tmp/tmux-1000/default"
        tmux-control-default-session "main"))

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

;; ── acp (Auto-Complete Plus) ───────────────────────────────────────────

(use-package acp
  :ensure t)

;; ── agent-shell + notifications + bookmarks ────────────────────────────

(use-package agent-shell
  :ensure t
  :defer t
  :config
  (setq agent-shell-anthropic-claude-environment
        (agent-shell-make-environment-variables
         "AWS_PROFILE" "hermes"
         "OPENCODE_ENABLE_EXA" "1"
         )

        )
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
  (defun agent-shell/turn-off-minor-mode-overrides ()
    (evil-collection-unimpaired-mode -1)
    (evil-commentary-mode -1))

  (add-hook 'agent-shell-mode-hook #'agent-shell/turn-off-minor-mode-overrides)

  (with-eval-after-load 'evil-collection-agent-shell
    (evil-define-key 'normal agent-shell-mode-map
      (kbd "TAB") #'agent-shell-ui-toggle-fragment
      (kbd "]")   #'agent-shell-next-item
      (kbd "[")   #'agent-shell-previous-item)
    )
  ;; (general-def
  ;;   :states '(motion normal)          ; Dired defaults to 'motion state in Evil
  ;;   :keymaps 'agent-shell-mode-map
  ;;   "RET" #'agent-shell-submit)
  ;; 
  ;; (my-local-leader
  ;;   :keymaps 'agent-shell-mode-map
  ;;   "R" #'agent-shell-restart
  ;;   "f" #'agent-shell-fork
  ;;   "m" #'agent-shell-set-session-mode
  ;;   "M" #'agent-shell-set-session-model
  ;;   )
  )

(use-package agent-shell-tramp
  :vc (:url "https://github.com/junyi-hou/agent-shell-tramp" :rev :newest)
  :config
  (agent-shell-tramp-mode 1))

(use-package agent-shell-bookmark
  :vc (:url "https://github.com/dcluna/agent-shell-bookmark" :rev :newest))

;; ── agent-recall (search/browse agent-shell transcripts) ───────────────

(use-package agent-recall
  :ensure t
  :hook (agent-shell-mode . agent-recall-track-sessions)
  :config
  (setq agent-recall-search-paths '("~/Dropbox" "~/.config/emacs" "~/projects" "~/work" "~/.agent-shell")
        agent-recall-search-function 'consult-ripgrep
        agent-recall-browse-sort 'modified-desc))

;; ── shell-maker (create custom shells in eshell) ──────────────────────

(use-package shell-maker
  :ensure t
  :config
  (advice-add 'shell-maker-submit :after
              (lambda (&rest _)
                (goto-char (point-max))))
  ;; (with-eval-after-load 'agent-shell
  ;;   (with-eval-after-load 'evil-collection
  ;;     (evil-define-key 'insert 'agent-shell-mode-map "RET" #'agent-shell-submit)
  ;;     (evil-define-key 'normal 'agent-shell-mode-map (kbd "RET") #'agent-shell-submit)
  ;;     )
  ;;   )
  )

;; ── capf-autosuggest (eshell completion hints) ─────────────────────────

(use-package capf-autosuggest
  :ensure t
  :hook (eshell-mode . capf-autosuggest-mode)
  :config
  (setq capf-autosuggest-backends '(capf-autosuggest-eshell-history))
  (with-eval-after-load 'eshell
    (define-key eshell-mode-map (kbd "C-f") #'capf-autosuggest-accept)))

;; ── Quickrun ───────────────────────────────────────────────────────────

(use-package quickrun
  :ensure t)

;; ── EWM (Wayland compositor) integration ───────────────────────────────

(if (getenv "EWM_MODULE_PATH")
    (load-file (expand-file-name "lisp/config-ewm.el" user-emacs-directory))
  (load-file (expand-file-name "lisp/config-i3.el" user-emacs-directory)))


;; server edit
(defun my/evil-save-modified-and-close (orig &rest args)
  (if server-buffer-clients
      (progn
        (save-buffer)
        (server-edit))
    (apply orig args)))

(advice-add #'evil-save-modified-and-close
            :around #'my/evil-save-modified-and-close)

(add-hook 'server-visit-hook
          (lambda ()
            (when server-buffer-clients
              (evil-insert-state))))


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

(defun thanos/type ()
  "Launch a temporary frame with a clean buffer for typing."
  (interactive)
  (let ((buf (get-buffer-create "emacs-float")))
    (switch-to-buffer buf)
    (erase-buffer)
    (org-mode)
    (evil-insert 1)
    (setq-local header-line-format
                (format " %s to insert text or %s to cancel."
                        (propertize "C-c C-c" 'face 'help-key-binding)
                        (propertize "C-c C-k" 'face 'help-key-binding)))
    (local-set-key (kbd "C-c C-k")
                   (lambda () (interactive)
                     (kill-new (buffer-string))
                     (kill-buffer buf)
                     ))
    (local-set-key (kbd "C-c C-c")
                   (lambda () (interactive)
                     (let ((value (buffer-string)))
                       (kill-buffer buf)
                       (start-process-shell-command
                        "wtype " nil
                        (thanos/wtype-text value)))
                     ))))

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

(provide 'post-init)
