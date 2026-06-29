;; post-init.el --- My customizations -*- no-byte-compile: t; lexical-binding: t; -*-

;; ── Themes ──────────────────────────────────────────────────────────────

(use-package doom-themes
  :ensure t
  :custom
  (doom-themes-enable-bold t)
  (doom-themes-enable-italic t)
  :config
  (doom-themes-visual-bell-config)
  (doom-themes-org-config))

(use-package nano-theme
  :ensure t
  :config
  ;; (load-theme 'nano-dark t))
  ;; (load-theme 'noctalia t)
  )

(setq scroll-conservatively 101)
(global-superword-mode 1)
;;(load-theme 'noctalia t)

;; ── Font (GUI only) ────────────────────────────────────────────────────

(defun my/set-font (&optional frame)
  (set-face-attribute 'default frame
                      :height 153
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

(my/set-font)
(my/load-theme 'nano-light)
(add-hook 'after-make-frame-functions #'my/set-font)
(winner-mode)

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

  ;; Clean up shadowed path syntax (e.g. ~/foo/bar/// → /)
  (add-hook 'rfn-eshadow-update-overlay-hook #'vertico-directory-tidy)
  (add-hook 'minibuffer-setup-hook #'vertico-repeat-save)

  (general-define-key
   :keymaps 'vertico-map
   "C-n"   #'vertico-next
   "C-p"   #'vertico-previous
   "C-j"   #'vertico-next
   "C-k"   #'vertico-previous
   "C-h"   #'vertico-directory-up
   "C-l"   #'vertico-directory-enter
   "C-SPC" #'vertico-exit-input
   "DEL"   #'vertico-directory-delete-char)

  ;; Give the minibuffer and echo area left margin padding
  (dolist (hook '(minibuffer-setup-hook
                  minibuffer-inactive-mode-hook
                  which-key-init-buffer-hook
                  ))
    (add-hook hook
              (lambda ()
                (let ((win (minibuffer-window)))
                  (with-current-buffer (window-buffer win)
                    (setq-local left-margin-width 1))
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
  (read-extended-command-predicate #'command-completion-default-include-p)
  (text-mode-ispell-word-completion nil)
  (tab-always-indent 'complete)
  :bind (:map corfu-map
              ("<mouse-1>" . corfu-select)
              ("TAB" . corfu-next)
              ("BACKTAB" . corfu-previous))
  :config
  (global-corfu-mode))

;; ── Search (Doom-style) ────────────────────────────────────────────────

;; Consult — efficient searching and previewing
(use-package consult
  :ensure t
  :bind (("C-x b" . consult-buffer)
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
   :preview-key "C-SPC"))

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
  :custom
  (magit-status-show-untracked-files t)
  (magit-process-apply-ansi-colors t))

;; ── Evil (Vim keybindings) ─────────────────────────────────────────────

(use-package evil
  :ensure t
  :init
  (setq evil-want-keybinding nil)
  (setq evil-want-integration t)
  (setq evil-want-C-u-scroll t)
  (setq evil-symbol-word-search t)
  (setq evil-undo-system 'undo-redo)
  :config
  (evil-mode 1)
  (setq evil-search-module 'isearch
        evil-respect-visual-line-mode t
        evil-want-C-u-scroll t
        evil-leader-key "SPC"
        evil-localleader-key "m"
        evil-vsplit-window-right t
        evil-split-window-below t)
  (define-key evil-normal-state-map (kbd ";") #'evil-ex)
  (define-key evil-visual-state-map (kbd ";") #'evil-ex)
  (define-key evil-motion-state-map [escape] #'keyboard-quit)
  (define-key evil-normal-state-map (kbd "M-q") #'evil-window-delete)
  (define-key evil-motion-state-map (kbd "M-q") #'evil-window-delete)

  ;; Doom-style enhancements
  (define-key evil-normal-state-map (kbd "TAB") #'evil-jump-item)
  (define-key evil-normal-state-map (kbd "*") #'evil-search-word-forward)
  (define-key evil-normal-state-map (kbd "#") #'evil-search-word-backward)

  (evil-set-initial-state 'minibuffer-local-map 'insert))

(use-package evil-collection
  :ensure t
  :after evil
  ;; :init
  :config
  (setq evil-collection-mode-list
        (cl-set-difference evil-collection-mode-list
                           '(comint eshell agent-shell shell-maker)))
  (evil-collection-init))

;; ── Leader key (Doom-style) ────────────────────────────────────────────

;; Full config reload (like Doom's `SPC h R`)
(defun my/config-reload ()
  "Byte-compile and load the user's full Emacs configuration."
  (interactive)
  (let* ((config-dir (expand-file-name "~/.config/emacs/"))
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
  :load-path "lisp/")

(defun my/dotfiles ()
  (interactive)
  (find-file "~/dotfiles"))

;; ── Local leader (SPC m) — mode-specific bindings (like Doom) ──────────

(defvar my-local-leader-alist ()
  "Alist of (major-mode . keymap) for local leader (SPC m) bindings.")

(defun my-local-leader ()
  "Read next key and dispatch to the current mode's local leader map."
  (interactive)
  (let* ((key (read-key-sequence-vector nil))
         (map (cdr (assq major-mode my-local-leader-alist))))
    (if (and map (lookup-key map key))
        (lookup-key map key)
      (user-error "No local leader binding for %s in %s" key major-mode))))

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
   "hm" '(describe-mode :which-key "describe mode")
   "hv" '(describe-variable :which-key "describe variable")
   "hf" '(describe-function :which-key "describe function")
   "hF" '(describe-face :which-key "describe face")
   "hk" '(describe-key :which-key "describe key")
   "ht" '(my/load-theme :which-key "load theme")
   "hR" '(my/config-reload :which-key "reload config")

   ;; --- Buffer bindings ---
   "bb" '(consult-buffer :which-key "switch buffer")
   "br" '(revert-buffer :which-key "revert buffer")
   "b[" '(previous-buffer :which-key "previous buffer")
   "b]" '(next-buffer :which-key "next buffer")

   ;; --- File bindings ---
   "ff" '(find-file :which-key "find file")
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

   ;; --- Mode / local leader ---
   "m"  '(my-local-leader :which-key "mode")

   ;; --- Activities ---
   "TAB"  '(nil :which-key "activities")
   "TAB n" '(activities-new :which-key "new activity")
   "TAB d" '(activities-define :which-key "define activity")
   "TAB a" '(activities-resume :which-key "resume activity")
   "TAB s" '(activities-suspend :which-key "suspend activity")
   "TAB k" '(activities-kill :which-key "kill activity")
   "TAB l" '(activities-list :which-key "list activities")
   "TAB b" '(activities-switch-buffer :which-key "switch buffer")
   "TAB g" '(activities-revert :which-key "revert activity"))



  ;; 1. Initialize your custom global prefix map
  (general-create-definer my-local-leader
    :states '(normal motion visual)
    :prefix "SPC m") ; Binds globally to SPC m and sets up structural inheritance

  ;; 2. Easily attach commands directly to major modes
  (my-local-leader
    :keymaps 'agent-shell-mode-map
    "R" #'agent-shell-restart
    "f" #'agent-shell-fork)
  )

;; ── Agent shell / app shortcuts (in global leader) ──────────────────────

(general-define-key
 :states '(normal visual motion)
 :prefix "SPC"
 "f." '(my/dotfiles :which-key "dotfiles")
 "ga" '(agent-shell-toggle :which-key "agent shell toggle")
 "og" '(taskwarrior-gtd :which-key "GTD dashboard")
 "oc" '(taskwarrior-gtd-capture :which-key "GTD capture")
 "oj" '(my/open-todays-journal :which-key "today's journal")
 "o-" #'dired-jump
 ;; "os" '(agent-shell-manager-toggle :which-key "agent shell manager")
 )


;; ── Activities (workspace management) ──────────────────────────────────

(use-package activities
  :ensure t
  :init
  (activities-mode 1)
  :config
  (setq activities-always-persist t))

;; ── Navigation ─────────────────────────────────────────────────────────

;; Avy — jump to any location with 1-2 keystrokes
(use-package avy
  :bind (("C-;" . avy-goto-char-2)
         :map evil-normal-state-map
         ("s" . evil-avy-goto-char-2))
  :config
  (setq avy-style 'at-full
        avy-background t
        avy-all-windows t
        avy-highlight-first t
        avy-timeout-seconds 0.3))


(with-eval-after-load 'dired
  ;; dired binds SPC and ; by default — unbind so evil/general can handle them
  (define-key dired-mode-map " " nil)
  (define-key dired-mode-map ";" nil)

  (general-def
    :states '(motion normal)          ; Dired defaults to 'motion state in Evil
    :keymaps 'dired-mode-map
    "SPC" nil                ; Reclaims SPC globally or for your leader key
    ";"   nil                ; Reclaims semicolon
    "h"   'dired-up-directory
    "l"   'dired-find-alternate-file)
  (evil-define-key 'normal dired-mode-map
    (kbd "h") 'dired-up-directory
    (kbd "l") 'dired-find-alternate-file)

  (require 'tramp-sshfs)
  (defun my/tramp-aware-dired-open-advice (orig-fun &rest args)
    (let* ((files (dired-get-marked-files nil (car args)))
           (is-remote (file-remote-p default-directory))
           (method (if is-remote (file-remote-p default-directory 'method) nil)))
      (if (string-equal method "sshfs")
          (dolist (file files)
            (let ((local-fuse-path (tramp-fuse-local-file-name (expand-file-name file))))
              (if (and local-fuse-path (file-exists-p local-fuse-path))
                  (start-process "dired-tramp-external-open" nil "xdg-open" local-fuse-path)
                (message "Error: Unable to resolve local FUSE mount path for %s" file))))
        (apply orig-fun args))))
  (advice-add 'dired-do-open :around #'my/tramp-aware-dired-open-advice)
  )


;; ── Which-key ──────────────────────────────────────────────────────────

(use-package which-key
  :diminish
  :config
  (which-key-mode)
  (setq which-key-idle-delay 1.5)
  )

;; ── Org + Org-roam ─────────────────────────────────────────────────────

(use-package org
  :bind (("C-c a" . org-agenda))
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
        org-export-preserve-breaks nil
        org-todo-keywords
        '((sequence "TODO(t)" "NEXT(n)" "WAITING(w)" "PROJECT(p)"
                    "|" "DONE(d)" "CANCELLED(c)" "SOMEDAY(s)"))
        org-todo-keyword-faces
        '(("TODO"      . (:foreground "yellow"       :weight bold))
          ("NEXT"      . (:foreground "orange"       :weight bold))
          ("WAITING"   . (:foreground "red"          :weight bold))
          ("PROJECT"   . (:foreground "blue"         :weight bold))
          ("DONE"      . (:foreground "forest green" :weight bold))
          ("CANCELLED" . (:foreground "gray"         :weight bold))
          ("SOMEDAY"   . (:foreground "goldenrod"    :weight bold))))
  (setq org-capture-templates
        '(("i" "Inbox" entry
           (file ,(expand-file-name "inbox.org" org-directory))
           "* TODO %?\n  %U\n  %a\n")
          ("t" "Task" entry
           (file ,(expand-file-name "tasks.org" org-directory))
           "* TODO %?\n  %U\n  %a\n")
          ("p" "Project" entry
           (file ,(expand-file-name "projects.org" org-directory))
           "* PROJECT %?")
          ("s" "Someday" entry
           (file ,(expand-file-name "someday.org" org-directory))
           "* SOMEDAY %?")
          ("n" "Idea" entry
           (file ,(expand-file-name "ideas.org" org-directory))
           "* IDEA %?")))
  (setq org-refile-targets
        '((nil :maxlevel . 3)
          (org-agenda-files :maxlevel . 3)
          ("~/notes/ideas.org" :maxlevel . 2)
          ("~/notes/projects.org" :maxlevel . 2)
          ("~/notes/tasks.org" :maxlevel . 2)
          ("~/notes/someday.org" :maxlevel . 2))
        org-refile-allow-creating-parent-nodes 'confirm)
  (setq org-agenda-custom-commands
        '(("g" "GTD Dashboard"
           ((agenda "" ((org-agenda-span 3)
                        (org-agenda-overriding-header "Calendar (Next 3 Days)")
                        (org-agenda-start-day "+0d")))
            (todo "NEXT"
                  ((org-agenda-overriding-header "Next Actions")
                   (org-agenda-sorting-strategy '(priority-down effort-up))))
            (todo "WAITING"
                  ((org-agenda-overriding-header "Waiting On")))
            (todo "SOMEDAY"
                  ((org-agenda-overriding-header "Someday / Maybe")
                   (org-agenda-files '("~/notes/someday.org"))))
            (todo "DONE"
                  ((org-agenda-overriding-header "Recently Completed")
                   (org-agenda-files '("~/notes/tasks.org" "~/notes/projects.org"))
                   (org-agenda-skip-function
                    '(org-agenda-skip-entry-if 'nottodo 'done))))))
          ("w" "Weekly Review"
           ((agenda "" ((org-agenda-span 7)
                        (org-agenda-start-day "-1d")
                        (org-agenda-overriding-header "Review Calendar")))
            (todo "PROJECT" ((org-agenda-overriding-header "Active Projects")))
            (todo "WAITING" ((org-agenda-overriding-header "Waiting For")))
            (todo "SOMEDAY" ((org-agenda-overriding-header "Someday / Maybe")))
            (tags "inbox"
                  ((org-agenda-overriding-header "Inbox Items")
                   (org-agenda-files '("~/notes/inbox.org"))))))
          ("t" "Today Focus"
           ((agenda "" ((org-agenda-span 1)
                        (org-agenda-start-day "+0d")
                        (org-agenda-overriding-header "Today")))
            (todo "NEXT"
                  ((org-agenda-overriding-header "Next Actions")
                   (org-agenda-sorting-strategy '(priority-down effort-up))))))))
  (setq org-agenda-prefix-format
        '((agenda . " %i %-12:c%?-12t% s")
          (todo   . " %i %-12:c")
          (tags   . " %i %-12:c")
          (search . " %i %-12:c"))))

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
(setq display-line-numbers-width 4)
(set-fringe-mode 0)

;; Hide line numbers in eshell buffers
(add-hook 'eshell-mode-hook #'display-line-numbers-mode)
(add-hook 'agent-shell-mode-hook #'display-line-numbers-mode)


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
  :init (doom-modeline-mode 1)
  :config
  (setq doom-modeline-modal-icon nil
        doom-modeline-buffer-file-name-style 'file-name))

;; ── Evil goodies ───────────────────────────────────────────────────────

(use-package evil-surround
  :ensure t
  :after evil
  :config
  (global-evil-surround-mode 1)
  (let ((orig (default-value 'evil-surround-pairs-alist)))
    (setq-default evil-surround-pairs-alist
                  (push '(?~ . ("``" . "``")) evil-surround-pairs-alist))
    (setq-default evil-surround-pairs-alist
                  (append orig
                          '((?F . (lambda ()
                                    (let ((name (read-from-minibuffer "Type name: ")))
                                      (cons (concat name "[") "]")))))))))

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

;; ── Evil-commentary (gc / gcc to comment) ──────────────────────────────

(use-package evil-commentary
  :ensure t
  :after evil
  :config
  (evil-commentary-mode)
  ;; evil-commentary-mode's keymap doesn't integrate with evil's `g` prefix,
  ;; so bind gc/gy directly in the evil state maps
  (define-key evil-normal-state-map (kbd "gc") #'evil-commentary)
  (define-key evil-visual-state-map (kbd "gc") #'evil-commentary)
  (define-key evil-normal-state-map (kbd "gy") #'evil-commentary-yank)
  (define-key evil-visual-state-map (kbd "gy") #'evil-commentary-yank))

;; ── Evil-visualstar (* and # search for symbol at point) ─────────────

(use-package evil-visualstar
  :ensure t
  :after evil
  :config
  (global-evil-visualstar-mode))

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
     "\\*compilation\\*" ; Fixed to match standard Emacs compilation buffer lowercase
     "\\*Completions\\*"
     "\\*Help\\*"
     "\\*tramp\\*"
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
     "#"))
  :config
  (popper-mode +1)
  (popper-echo-mode +1)) ; Shows popup status cleanly in the minibuffer

;; ── Lookup (Doom-style "K") ────────────────────────────────────────────────

(define-key evil-normal-state-map (kbd "K")
            (lambda () (interactive)
              (if (eq major-mode 'emacs-lisp-mode)
                  (describe-symbol (intern (thing-at-point 'symbol)))
                (eglot-help-at-point))))

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

(require 'mu4e)
(use-package mu4e
  :ensure nil
  :defer t
  :config
  (setq mu4e-maildir "/data/mbsync-mail/"
        mu4e-maildir-shortcuts '((:maildir "/Inbox/" :key ?i))
        mu4e-compose-context-policy 'ask-if-none
        send-mail-function 'smtpmail-send-it
        smtpmail-debug-info t
        mu4e-sent-folder "/Sent"
        mu4e-drafts-folder "/Drafts"
        mu4e-trash-folder "/Trash"
        mu4e-refile-folder "/Archive"
        mu4e-attachment-dir "/home/rashid/Downloads/attachments"
        mu4e-get-mail-command "mu index"
        mu4e-update-interval 600
        mu4e-headers-visible-columns 60
        mu4e-split-view 'vertical
        smtpmail-stream-type 'ssl)
  (setq mu4e-contexts
        `(,(make-mu4e-context
            :name "personal"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/personal" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rashid301@gmail.com")
                    (mu4e-sent-folder   . "/personal/[Gmail]/Sent Mail")
                    (mu4e-drafts-folder . "/personal/Drafts")
                    (mu4e-trash-folder  . "/personal/[Gmail]/Trash")
                    (mu4e-refile-folder . "/personal/Archive")
                    (smtpmail-smtp-user . "rashid301@gmail.com")
                    (smtpmail-smtp-server . "smtp.gmail.com")
                    (smtpmail-smtp-service . 465)
                    (user-full-name . "Rashid Shaikh")))
          ,(make-mu4e-context
            :name "sensai"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/sensai" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rshaikh@coachsensai.com")
                    (mu4e-drafts-folder . "/sensai/Drafts")
                    (mu4e-sent-folder   . "/sensai/[Gmail]/Sent Mail")
                    (mu4e-trash-folder  . "/sensai/[Gmail]/Trash")
                    (mu4e-refile-folder . "/sensai/Archive")))
          ,(make-mu4e-context
            :name "yahoo"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/yahoo" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rashidali.shaikh@yahoo.com")
                    (mu4e-sent-folder   . "/yahoo/Sent")
                    (mu4e-drafts-folder . "/yahoo/Drafts")
                    (mu4e-trash-folder  . "/yahoo/Trash")
                    (mu4e-refile-folder . "/yahoo/Archive")))
          ,(make-mu4e-context
            :name "zoho"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/zoho" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rashid@bitbute.tech")
                    (mu4e-sent-folder   . "/zoho/Sent")
                    (mu4e-drafts-folder . "/zoho/Drafts")
                    (mu4e-trash-folder  . "/zoho/Trash")
                    (mu4e-refile-folder . "/zoho/Archive")
                    (smtpmail-smtp-user . "rashid@bitbute.tech")
                    (smtpmail-smtp-server . "smtppro.zoho.com")
                    (smtpmail-smtp-service . 465)
                    (user-full-name . "Rashid Shaikh")))))
  (setq mu4e-headers-fields
        '(
          ;; (:account-stripe . 1)
          (:human-date . 12)
          (:flags . 6)
          (:from . 22)
          (:subject . 50)
          (:maildir . 50)))

  (defvar +mu4e-gmail-accounts 
    (setq +mu4e-gmail-accounts
          '(
            ("rashid301@gmail.com" . "personal")
            ("rshaikh@coachsensai.com" . "sensai")
            ))
    "Gmail accounts that do not contain \"gmail\" in address and maildir.

An alist of Gmail addresses of the format \((\"username@domain.com\" . \"account-maildir\"))
to which Gmail integrations (behind the `+gmail' flag of the `mu4e' module) should be applied.

See `+mu4e-msg-gmail-p' and `mu4e-sent-messages-behavior'.")

  ;; don't save message to Sent Messages, Gmail/IMAP takes care of this
  (setq mu4e-sent-messages-behavior
        (lambda () ;; TODO: make use +mu4e-msg-gmail-p
          (if (or (string-match-p "@gmail.com\\'" (message-sendmail-envelope-from))
                  (member (message-sendmail-envelope-from)
                          (mapcar #'car +mu4e-gmail-accounts)))
              'delete 'sent)))

  (defun +mu4e-msg-gmail-p (msg)
    (let ((root-maildir
           (replace-regexp-in-string "/.*" ""
                                     (substring (mu4e-message-field msg :maildir) 1))))
      (or (string-match-p "gmail" root-maildir)
          (member root-maildir (mapcar #'cdr +mu4e-gmail-accounts)))))

  ;; In my workflow, emails won't be moved at all. Only their flags/labels are
  ;; changed. Se we redefine the trash and refile marks not to do any moving.
  ;; However, the real magic happens in `+mu4e-gmail-fix-flags-h'.
  ;;
  ;; Gmail will handle the rest.
  (defun +mu4e--mark-seen (docid _msg target)
    (mu4e--server-move docid (mu4e--mark-check-target target) "+S-u-N"))

  (defvar +mu4e--last-invalid-gmail-action 0)

  (setf (alist-get 'delete mu4e-marks)
        (list
         :char '("D" . "✘")
         :prompt "Delete"
         :show-target (lambda (_target) "delete")
         :action (lambda (docid msg target)
                   (if (+mu4e-msg-gmail-p msg)
                       (progn (message "The delete operation is invalid for Gmail accounts. Trashing instead.")
                              (+mu4e--mark-seen docid msg target)
                              (when (< 2 (- (float-time) +mu4e--last-invalid-gmail-action))
                                (sit-for 1))
                              (setq +mu4e--last-invalid-gmail-action (float-time)))
                     (mu4e--server-remove docid))))
        (alist-get 'trash mu4e-marks)
        (list :char '("d" . "▼")
              :prompt "dtrash"
              :dyn-target (lambda (_target msg) (mu4e-get-trash-folder msg))
              :action (lambda (docid msg target)
                        (if (+mu4e-msg-gmail-p msg)
                            (+mu4e--mark-seen docid msg target)
                          (mu4e--server-move docid (mu4e--mark-check-target target) "+T-N"))))
        ;; Refile will be my "archive" function.
        (alist-get 'refile mu4e-marks)
        (list :char '("r" . "▼")
              :prompt "rrefile"
              :dyn-target (lambda (_target msg) (mu4e-get-refile-folder msg))
              :action (lambda (docid msg target)
                        (if (+mu4e-msg-gmail-p msg)
                            (+mu4e--mark-seen docid msg target)
                          (mu4e--server-move docid (mu4e--mark-check-target target) "-N")))
              #'+mu4e--mark-seen))

  ;; This hook correctly modifies gmail flags on emails when they are marked.
  ;; Without it, refiling (archiving), trashing, and flagging (starring) email
  ;; won't properly result in the corresponding gmail action, since the marks
  ;; are ineffectual otherwise.
  (add-hook 'mu4e-mark-execute-pre-hook
            (defun +mu4e-gmail-fix-flags-h (mark msg)
              (when (+mu4e-msg-gmail-p msg)
                (pcase mark
                  (`trash  (mu4e-action-retag-message msg "-\\Inbox,+\\Trash,-\\Draft"))
                  (`delete (mu4e-action-retag-message msg "-\\Inbox,+\\Trash,-\\Draft"))
                  (`refile (mu4e-action-retag-message msg "-\\Inbox"))
                  (`flag   (mu4e-action-retag-message msg "+\\Starred"))
                  (`unflag (mu4e-action-retag-message msg "-\\Starred"))))))

  )

(use-package mu4e-org
  :ensure nil)

(use-package auth-source-pass
  :config
  (auth-source-pass-enable))

(setq auth-source-debug nil
      auth-source-do-cache nil
      auth-sources '(password-store))

;; ── Eat (terminal emulator) ────────────────────────────────────────────

(use-package eat
  :ensure t
  :hook ((eshell-mode . eat-eshell-mode)
         ;; (eat-mode-hook . mode-line-invisible-mode)
         )
  :config
  ;;(evil-set-initial-state 'eat-term-mode 'emacs)
  )

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
         "AWS_PROFILE" "hermes"))
  (setq agent-shell-confirm-interrupt nil
        agent-shell-hermes-acp-command '("hermes" "-p" "chief-of-staff" "acp"))
  (add-hook 'diff-mode-hook
            (lambda ()
              (when (string-match-p "\\*agent-shell-diff\\*" (buffer-name))
                (evil-emacs-state))))
  ;; Mode-specific keys — only active in agent-shell-mode buffers
  (general-define-key
   :states 'normal
   :keymaps 'agent-shell-mode-map
   "["   #'agent-shell-previous-item
   "]"   #'agent-shell-next-item
   "TAB" #'agent-shell-ui-toggle-fragment
   "q"   #'agent-shell-toggle
   "c"   #'agent-shell-prompt-compose
   "x"   #'agent-shell-interrupt)
  ;; RET works in all three states
  (general-define-key
   :states '(normal visual insert)
   :keymaps 'agent-shell-mode-map
   "RET" #'agent-shell-submit)


  (general-def
    :states '(motion normal)          ; Dired defaults to 'motion state in Evil
    :keymaps 'agent-shell-mode-map
    "RET" #'agent-shell-submit)

  (my-local-leader
    :keymaps 'agent-shell-mode-map
    "R" #'agent-shell-restart
    "f" #'agent-shell-fork
    "m" #'agent-shell-set-session-mode
    "M" #'agent-shell-set-session-model
    )
  )

(use-package agent-shell-tramp
  :vc (:url "https://github.com/junyi-hou/agent-shell-tramp" :rev :newest)
  :config
  (agent-shell-tramp-mode 1))

(use-package agent-shell-bookmark
  :vc (:url "https://github.com/dcluna/agent-shell-bookmark" :rev :newest))

;; ── shell-maker (create custom shells in eshell) ──────────────────────

(use-package shell-maker
  :ensure t
  :config
  (advice-add 'shell-maker-submit :after
              (lambda (&rest _)
                (goto-char (point-max))))
  (with-eval-after-load 'agent-shell
    (with-eval-after-load 'evil-collection
      (define-key agent-shell-mode-map (kbd "RET") #'agent-shell-submit))))

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


;; dotfiles
(general-define-key
 :states 'normal
 "f ." #'my/dotfiles
 )

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
  (setq vc-handled-backends nil)
  (setq remote-file-name-inhibit-cache nil)
  (setq tramp-verbose 3))

(provide 'post-init)
