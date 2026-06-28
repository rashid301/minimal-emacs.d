;;; post-init.el --- My customizations -*- no-byte-compile: t; lexical-binding: t; -*-

;; ── Themes ──────────────────────────────────────────────────────────────

(use-package doom-themes
  :ensure t
  :custom
  ;; Global settings (defaults)
  (doom-themes-enable-bold t)   ; if nil, bold is universally disabled
  (doom-themes-enable-italic t) ; if nil, italics is universally disabled
  ;; for treemacs users
  (doom-themes-treemacs-theme "doom-atom") ; use "doom-colors" for less minimal icon theme
  :config
  (load-theme 'doom-gruvbox t)

  ;; Enable flashing mode-line on errors
  (doom-themes-visual-bell-config)
  ;; ;; Enable custom neotree theme (nerd-icons must be installed!)
  ;; (doom-themes-neotree-config)
  ;; ;; or for treemacs users
  ;; (doom-themes-treemacs-config)
  ;; Corrects (and improves) org-mode's native fontification.
  (doom-themes-org-config))

(use-package catppuccin-theme
  :ensure t
  :config
  )

;; ── Font (GUI only) ────────────────────────────────────────────────────

(set-face-attribute 'default nil
                    :font "JetBrainsMono Nerd Font-14"
                    :weight 'normal)

;; ── Tree-sitter (built-in) + LSP (built-in) ────────────────────────────

(require 'treesit)

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
        (markdown "https://github.com/tree-sitter/tree-sitter-markdown")))

;; (use-package eglot
;;   :demand t
;;   :config
;;   (add-to-list 'eglot-server-programs '(typescript-ts-mode . ["typescript-language-server" "--stdio"]))
;;   (add-to-list 'eglot-server-programs '(js-mode . ["typescript-language-server" "--stdio"]))
;;   (add-to-list 'eglot-server-programs '(python-mode . ["pyright"])))

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


;; ── Completion ──────────────────────────────────────────────────────────

;; Vertico — vertical completion in minibuffer
(use-package vertico
  :custom
  (vertico-count 10)
  :config
  (vertico-mode))

;; Orderless — flexible completion style
(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

;; Marginalia — rich annotations for completions
(use-package marginalia
  :bind (:map minibuffer-local-map
              ("M-A" . marginalia-cycle))
  :config
  (marginalia-mode))

;; Corfu — in-buffer completion
(use-package corfu
  :custom
  (read-extended-command-predicate #'command-completion-default-include-p)
  (text-mode-ispell-word-completion nil)
  (tab-always-indent 'complete)
  :bind (:map corfu-map
              ("<mouse-1>" . corfu-select)
              ("TAB" . corfu-next)
              ("BACKTAB" . corfu-previous))
  :config
  (global-corfu-mode))

;; ── Search ─────────────────────────────────────────────────────────────

;; Consult — efficient searching and previewing
(use-package consult
  ;; :bind (("C-x b" . consult-buffer)
  ;;        ("C-c r" . consult-recent-file)
  ;;        ("M-g M-g" . consult-grep)
  ;;        ("C-c /" . consult-line)
  ;;        :map minibuffer-local-map
  ;;        ("M-V" . consult-history)
  ;;        :map mode-specific-map
  ;;        ("M-V" . consult-history))
  :config
  (consult-customize
   consult-theme :preview-key 'C-z)
  (setq register-preview-delay 0.3
        register-preview-function #'consult-register-format))

;; Embark — context-sensitive actions
(use-package embark
  :bind (("C-." . embark-act)))

;; Embark-consult — integration
(use-package embark-consult
  :after (embark consult)
  :config
  ;;(add-to-list 'embark-keymap-commands #'consult-line)
  )

;; ── Recent files ───────────────────────────────────────────────────────

(use-package recentf
  :config
  (recentf-mode 1)
  (setq recentf-max-saved-items 200))

;; ── Project (built-in) ─────────────────────────────────────────────────

(use-package project
  :demand t
  ;; :bind (("C-c p" . project-find-file)
  ;;        ("C-c M-g" . magit-status)
  ;;        ("C-c M-s" . consult-projectile-grep))
  :config
  (setq project-vc-extra-file-search-functions nil)
  (project-remember-project (cons 'transient (expand-file-name "~/Dropbox/"))))

;; ── Git ────────────────────────────────────────────────────────────────

(use-package magit
  ;; :bind (("C-c g" . magit-status))
  )

;; ── Evil (Vim keybindings) ─────────────────────────────────────────────

(use-package evil
  :ensure t
  :init
  (setq evil-want-keybinding nil)
  (setq evil-want-integration t)
  (setq evil-want-C-u-scroll t)
  :config
  (evil-mode 1)
  (setq evil-search-module 'isearch
        evil-respect-visual-line-mode t
        evil-want-C-u-scroll t
        evil-leader-key "SPC"
        evil-localleader-key "m")
  (define-key evil-normal-state-map (kbd ";") #'evil-ex)
  (define-key evil-visual-state-map (kbd ";") #'evil-ex)
  (evil-set-initial-state 'minibuffer-local-map 'insert))

(use-package evil-collection
  :ensure t
  :init
  :after evil
  :config
  (evil-collection-init))

;; ── Leader key (Doom-style) ────────────────────────────────────────────

;; Full config reload (like Doom's `SPC h R`)
(defun my/config-reload ()
  "Byte-compile and load the user's full Emacs configuration."
  (interactive)
  (let* ((config-dir (expand-file-name "~/.minimal-emacs.d"))
         (init-el (expand-file-name "post-init.el" config-dir))
         (early-init (expand-file-name "early-init.el" config-dir)))
    (message "Reloading configuration...")
    (when (file-exists-p init-el)
      (load-file init-el))
    (when (file-exists-p early-init)
      (load-file early-init))
    (message "Configuration reloaded.")))

;; Journal directory
(defvar my/journal-dir (expand-file-name "~/notes/journal/")
  "Directory for daily journal files.")
(unless (file-exists-p my/journal-dir)
  (make-directory my/journal-dir t))

;; Taskwarrior GTD
(use-package taskwarrior-gtd
  :load-path "~/.minimal-emacs.d/lisp/")

(use-package general
  :ensure t
  :after evil
  :config
  (general-evil-setup t)

  ;; Automatically clear out conflicting keys (like evil's default SPC)
  (general-auto-unbind-keys)

  (general-define-key
   :states '(normal visual motion)
   :prefix "SPC"

   ;; --- Named Prefix Groups for which-key ---
   "f"  '(nil :which-key "file")
   "g"  '(nil :which-key "git")
   "s"  '(nil :which-key "search")
   "n"  '(nil :which-key "notes/roam")
   "b"  '(nil :which-key "buffer")
   "o"  '(nil :which-key "apps")
   "h"  '(nil :which-key "help")
   "t"  '(nil :which-key "toggle")

   ;; --- help ---
   "hv" '(describe-variable :which-key "describe variable")
   "hf" '(describe-function :which-key "describe function")
   "hF" '(describe-face :which-key "describe face")
   "hk" '(describe-key :which-key "describe key")
   "ht" '(load-theme :which-key "load theme")
   "hR" '(my/config-reload :which-key "reload config")

   ;; --- Buffer bindings ---
   "bb" '(consult-buffer :which-key "switch buffer")
   "br" '(revert-buffer :which-key "revert buffer")
   "b[" '(previous-buffer :which-key "previous buffer")
   "b]" '(next-buffer :which-key "next buffer")

   ;; --- File bindings ---
   "ff" '(consult-find :which-key "find file")
   "fr" '(consult-recent-file :which-key "recent files")
   "fb" '(consult-buffer :which-key "buffer list")

   ;; --- Git bindings ---
   "gg" '(magit-status :which-key "magit status")

   ;; --- Project bindings ---
   "p"  '(:keymap project-prefix-map :which-key "project")

   ;; --- Search bindings ---
   "sg" '(consult-grep :which-key "grep search")
   "sd" '(consult-ripgrep :which-key "search directory")

   ;; --- Org-roam bindings ---
   "nl" '(org-roam-node-find :which-key "find node")
   "nc" '(org-roam-capture :which-key "capture")
   "ni" '(org-roam-node-insert :which-key "insert node")

   ;; --- Toggle bindings ---
   "tw" '(visual-line-mode :which-key "word wrap")

   ;; --- Global Shortcut ---
   "TAB" '(consult-buffer :which-key "alternate buffer")))


;; ── Navigation ─────────────────────────────────────────────────────────

;; Avy — jump to any location with 1-2 keystrokes
(use-package avy
  :bind (("C-;" . avy-goto-char-2)
         :map evil-normal-state-map
         ("s" . avy-goto-char-2))
  :config
  (setq avy-style 'at-full
        avy-background t))

;; ── Which-key ──────────────────────────────────────────────────────────

(use-package which-key
  :diminish
  :config
  (which-key-mode)
  (setq which-key-idle-delay 1.5)
  )

;; ── Org + Org-roam ─────────────────────────────────────────────────────

(use-package org
  ;; :bind (("C-c a" . org-agenda))
  :config
  (setq org-directory (expand-file-name "~/notes/")
        org-id-link-to-frametree t
        org-confirm-babel-evaluate nil
        org-agenda-files '("~/notes/tasks.org"
                           "~/notes/my-gtd"
                           "~/notes/projects.org"
                           "~/notes/ideas.org"
                           "~/notes/vaccines.org"
                           "~/notes/health.org"
                           "~/notes/someday.org")
        org-default-notes-file (expand-file-name "inbox.org" org-directory)
        org-log-done 'time
        org-log-into-drawer t
        org-startup-align-all-tables t
        org-use-speed-commands t
        org-todo-keywords
        '((sequence "TODO(t)" "NEXT(n)" "WAITING(w)" "PROJECT(p)"
           "|" "DONE(d)" "CANCELLED(c)" "SOMEDAY(s)"))))

(use-package org-roam
  :ensure t
  :after org
  :custom
  (org-roam-v2-ack t)
  (org-roam-directory (expand-file-name "~/notes/"))
  (org-roam-completion-everywhere t)
  (org-roam-capture-templates
   '(("d" "default" plain
      "%?"
      :target (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                         "#+title: ${title}\n#+startup: shrink\n"))))
  :config
  (org-roam-setup)
  ;; Global keybindings
  ;; (global-set-key (kbd "C-c n l") #'org-roam-node-find)
  ;; (global-set-key (kbd "C-c n i") #'org-roam-node-insert)
  ;; (global-set-key (kbd "C-c n c") #'org-roam-capture)
  )

;; ── Line numbers ───────────────────────────────────────────────────────

(global-display-line-numbers-mode 1)
(setq display-line-numbers-width-width 4)


;; Quick reload of this file
(defun reload-post-init ()
  "Reload post-init.el without restarting Emacs."
  (interactive)
  (load (expand-file-name "post-init.el" user-emacs-directory) nil t))

;; -- journal -------------------
(defun my/open-todays-journal ()
  "Open today's journal file, creating skeleton if needed."
  (interactive)
  (let* ((date-str (format-time-string "%Y-%m-%d"))
         (file-path (expand-file-name (concat date-str ".org") my/journal-dir)))
    (unless (file-exists-p file-path)
      (with-temp-file file-path
        (let ((day-name (format-time-string "%A")))
          (insert (format "* %s, %s\n" day-name date-str))
          (insert ":PROPERTIES:\n")
          (insert ":ENERGY_START:\n")
          (insert ":ENERGY_END:\n")
          (insert ":SLEEP:\n")
          (insert ":SLEEP_QUALITY:\n")
          (insert ":END:\n\n")
          (insert "| Time | Activity | Category | Notes |\n")
          (insert "|------|----------+----------+-------|\n\n")
          (insert "** Summary\n\n\n")
          (insert "** Pattern\n\n\n")
          (insert "** Thoughts\n\n"))))
    (find-file file-path)
    (goto-char (point-max))))


;; doom-modeline
(use-package doom-modeline
  :ensure t
  :init (doom-modeline-mode 1))

;; ── Evil goodies ───────────────────────────────────────────────────────

(use-package evil-surround
  :ensure t
  :after evil
  :config
  (global-evil-surround-mode 1))

;; (use-package evil-textobj-line
;;   :ensure t
;;   :after evil)

;; (use-package evil-textobj-sentence
;;   :ensure t
;;   :after evil)

;; (use-package evil-textobj-outerword
;;   :ensure t
;;   :after evil)

;; (use-package evil-indent-plus
;;   :ensure t
;;   :after evil)

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
  ;; :bind (:map popper-context-keymap
  ;;             ("o" . popper-line-mode-toggle)
  ;;             ("q" . popper-close)
  ;;             ("M-TAB" . popper-cycle)
  ;;             ("M-S-TAB" . popper-prev)
  ;;             )
  :custom
  (popop-size-threshold 0.25)
  (popop-line-position 'top)
  (popper-reference-buffers
   (list "*compilation*" "magit" "^\\*eglot" "#"))
  :init
  (popper-mode +1))

;; ── Lookup (Doom's "K") ────────────────────────────────────────────────

(use-package consult
  :demand nil)

;; ── Lookup (Doom-style "K") ────────────────────────────────────────────────

;; Basic help / reference lookup on "K" using built-in xref + help-at-point
(global-set-key (kbd "<remap> help-at-pt-display-when-idle") 'my/help-or-xref)

(defun my/help-or-xref (&optional arg)
  "Try help-at-point first, fall back to xref-find-definitions.

With universal argument ARG, reverse the order."
  (interactive "P")
  (if arg
      (xref-find-definitions (thing-at-point 'symbol t))
    (condition-case nil
        (help-at-point)
      (user-error (xref-find-definitions (thing-at-point 'symbol t))))))

;; ── Icons (nerd-icons) ────────────────────────────────────────────────

(use-package nerd-icons
  :ensure t
  :config
  ;; (nerd-icons-install-fonts t)
  )

;; ── Dirvish (improved dired) ───────────────────────────────────────────

(use-package dirvish
  :ensure t
  :defer t)

;; ── Elfeed (RSS reader) ────────────────────────────────────────────────

(use-package elfeed
  :ensure t
  :defer t)

;; ── mu4e + org email ───────────────────────────────────────────────────

(use-package mu4e
  :ensure nil
  :defer t)

(use-package mu4e-org
  :ensure nil)

;; ── Eat (terminal emulator) ────────────────────────────────────────────

(use-package eat
  :ensure t
  :defer t)

;; ── diminish (hide minor modes from modeline) ───────────────────────

(use-package diminish
  :ensure t)

;; ── Tmux control mode ──────────────────────────────────────────────────

(use-package tmux-control
  :vc (:url "https://github.com/csheaff/tmux-control" :rev :newest))

;; ── rg (ripgrep integration) ───────────────────────────────────────────

(use-package rg
  :ensure t)

;; ── HTTP / API testing (verb) ──────────────────────────────────────────

(use-package verb
  :ensure t
  :defer t)

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

;; (use-package exec-path-from-shell
;;   :ensure t)

;; (use-package pinentry
;;   :ensure t)

;; ── acp (Auto-Complete Plus) ───────────────────────────────────────────

(use-package acp
  :ensure t)

;; ── agent-shell + notifications + bookmarks ────────────────────────────

(use-package agent-shell
  :ensure t
  :defer t)

(use-package agent-shell-tramp
  :vc (:url "https://github.com/junyi-hou/agent-shell-tramp" :rev :newest))

(use-package agent-shell-bookmark
  :vc (:url "https://github.com/dcluna/agent-shell-bookmark" :rev :newest))

;; ── shell-maker (create custom shells in eshell) ──────────────────────

(use-package shell-maker
  :ensure t)

;; ── capf-autosuggest (eshell completion hints) ─────────────────────────

(use-package capf-autosuggest
  :ensure t)

;; ── Quickrun ───────────────────────────────────────────────────────────

(use-package quickrun
  :ensure t)

(provide 'post-init)
