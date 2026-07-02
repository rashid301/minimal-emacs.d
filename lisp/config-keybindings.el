;; config-keybindings.el --- Evil, general, leader keys -*- lexical-binding: t -*-

;; ── Evil (Vim keybindings) ─────────────────────────────────────────────

(use-package evil
  :ensure t
  :init
  (setq evil-want-keybinding nil)
  (setq evil-want-minibuffer nil)
  (setq evil-want-integration t)
  (setq evil-want-C-u-scroll t)
  (setq evil-symbol-word-search t)
  (setq evil-undo-system 'undo-redo)
  :config
  (setq evil-want-minibuffer nil)
  (add-to-list 'evil-emacs-state-modes 'minibuffer-mode)
  (add-to-list 'evil-emacs-state-modes 'minibuffer-inactive-mode)
  (evil-mode 1)
  (setq evil-search-module 'evil-search
        evil-respect-visual-line-mode t
        evil-want-C-u-scroll t
        evil-vsplit-window-right t
        evil-split-window-below t
        evil-ex-search-persistent-highlight nil)
  (define-key evil-normal-state-map (kbd ";") #'evil-ex)
  (define-key evil-visual-state-map (kbd ";") #'evil-ex)
  (define-key evil-motion-state-map [escape] #'keyboard-quit)
  (define-key evil-normal-state-map (kbd "M-q") #'evil-window-delete)
  (define-key evil-motion-state-map (kbd "M-q") #'evil-window-delete)

  ;; Doom-style enhancements
  (define-key evil-normal-state-map (kbd "*") #'evil-search-word-forward)
  (define-key evil-normal-state-map (kbd "#") #'evil-search-word-backward)

  (define-key evil-normal-state-map (kbd "C-i") #'evil-jump-forward)
  (evil-set-initial-state 'minibuffer-local-map 'emacs)
  )

(use-package evil-escape
  :ensure t
  :after evil
  :config
  (setq-default evil-escape-key-sequence "jk"
                evil-escape-delay 0.2)
  (evil-escape-mode 1))


(use-package evil-collection
  :ensure t
  :after evil
  :init
  (setq
   evil-collection-setup-minibuffer nil
   evil-collection-repl-submit-state 'insert
   )
  :config
  ;; (setq evil-collection-mode-list
  ;;       (cl-set-difference evil-collection-mode-list
  ;;                          '(comint eshell agent-shell shell-maker)))
  (evil-collection-init))

(use-package evil-textobj-tree-sitter
  :ensure t
  :after evil
  :config

  (add-to-list 'evil-textobj-tree-sitter-major-mode-language-alist
               '(emacs-lisp-mode . "common-lisp"))
  ;; --- PARAMETERS (Overwriting paragraph 'p') ---
  (define-key evil-inner-text-objects-map "p" (evil-textobj-tree-sitter-get-textobj "parameter.inner"))
  (define-key evil-outer-text-objects-map "p" (evil-textobj-tree-sitter-get-textobj "parameter.outer"))

  ;; --- CONDITIONALS (Using 'i' for if/conditional to keep your 'o' symbol binding) ---
  (define-key evil-inner-text-objects-map "i" (evil-textobj-tree-sitter-get-textobj "conditional.inner"))
  (define-key evil-outer-text-objects-map "i" (evil-textobj-tree-sitter-get-textobj "conditional.outer"))
  
  ;; --- FUNCTIONS & CLASSES ---
  (define-key evil-inner-text-objects-map "f" (evil-textobj-tree-sitter-get-textobj "function.inner"))
  (define-key evil-outer-text-objects-map "f" (evil-textobj-tree-sitter-get-textobj "function.outer"))
  (define-key evil-inner-text-objects-map "c" (evil-textobj-tree-sitter-get-textobj "class.inner"))
  (define-key evil-outer-text-objects-map "c" (evil-textobj-tree-sitter-get-textobj "class.outer")))

(use-package helpful
  :ensure t
  :bind (;; Replace standard commands globally
         ([remap describe-function] . helpful-function)
         ([remap describe-command]  . helpful-command)
         ([remap describe-variable] . helpful-variable)
         ([remap describe-key]      . helpful-key)))

(use-package elisp-def
  :ensure t
  :hook (emacs-lisp-mode . elisp-def-mode))

(use-package macrostep
  :ensure t
  :bind (:map emacs-lisp-mode-map
              ("C-c e" . macrostep-expand)))


(use-package markdown-mode
  :mode ("\\.md\\'" . markdown-mode)
  :config
  (setq markdown-command "multimarkdown")) 

;; ── Evil goodies ───────────────────────────────────────────────────────

(use-package evil-surround
  :ensure t
  :after evil
  :config
  (global-evil-surround-mode 1)
  
  ;; Directly prepend all your custom rules to the default list safely
  (setq-default evil-surround-pairs-alist
                (append '((?~   . ("``" . "``"))
                          (?F   . (lambda ()
                                    (let ((name (read-from-minibuffer "Type name: ")))
                                      (cons (concat name "[") "]"))))
                          (?\C-f . (lambda ()
                                     (let ((name (read-from-minibuffer "Function name: ")))
                                       (cons (concat "(" name " ") ")")))))
                        (default-value 'evil-surround-pairs-alist))))

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
  (evil-visualstar-mode 1))

;; ── General (keybinding framework) ─────────────────────────────────────

(use-package general
  :ensure t
  :after evil
  :config
  (general-evil-setup t)

  ;; Automatically clear out conflicting keys (like evil's default SPC)
  (general-auto-unbind-keys)
  (general-override-mode 1)
  
  (general-create-definer my-leader-def
    :states '(normal visual motion)
    :keymaps 'override
    :prefix "SPC"
    :prefix-command 'my-leader
    :prefix-map 'my-leader-map)

  ;; 1. Initialize your custom global prefix map
  (general-create-definer my-local-leader
    :states '(normal motion visual)
    :prefix "SPC m") ; Binds globally to SPC m and sets up structural inheritance

  (general-define-key
   :states '(normal visual motion)
   :prefix "g"
   "R" '(eval-region :which-key "Eval region")
   )

  (defun my/open-links()
    (interactive)
    (let ((browse-url-browser-function 'eww-browse-url))
      (link-hint-open-link)
      ))
  (define-key evil-window-map (kbd "u") #'winner-undo)
  (define-key evil-window-map (kbd "U") #'winner-redo) 

  (my-leader-def
    ;; --- Named Prefix Groups for which-key ---
    "f"  '(nil :which-key "file")
    "g"  '(nil :which-key "git")
    "s"  '(nil :which-key "search")
    "n"  '(nil :which-key "notes/roam")
    "b"  '(nil :which-key "buffer")
    "o"  '(nil :which-key "apps")

    "h"  '(nil :which-key "help")
    "t"  '(nil :which-key "toggle")
    "w"  '(nil :which-key "window")
    "u"  #'universal-argument

    ;; --- help ---
    "hm" '(describe-mode :which-key "describe mode")
    "hM" '(consult-minor-mode-menu :which-key "describe minor modes")
    "hv" '(describe-variable :which-key "describe variable")
    "hf" '(describe-function :which-key "describe function")
    "hF" '(describe-face :which-key "describe face")
    "hk" '(describe-key :which-key "describe key")

    "hR" '(my/config-reload :which-key "reload config")

    "ht" '(consult-theme :which-key "Load theme")

    ;; --- Buffer bindings ---
    "bb" '(consult-buffer :which-key "switch buffer")
    "br" '(revert-buffer :which-key "revert buffer")
    "b[" '(previous-buffer :which-key "previous buffer")
    "b]" '(next-buffer :which-key "next buffer")
    "bd" '(kill-this-buffer :which-key "kill buffer")

    ;; --- File bindings ---
    "ff" '(find-file :which-key "find file")
    "fr" '(consult-recent-file :which-key "recent files")
    "fb" '(consult-buffer :which-key "buffer list")
    "fy" '(my/copy-file-path :which-key "copy file path")
    "fs" '(save-buffer :which-key "save buffer")

    ;; --- Git bindings ---
    "gg" '(magit-status :which-key "magit status")

    ;; --- Project bindings ---
    "p"  '(:keymap project-prefix-map :which-key "project")

    ;; --- Search bindings ---
    "sg" '(consult-grep :which-key "grep search")
    "sd" '(consult-ripgrep :which-key "search directory")
    "sb" '(consult-line :which-key "search directory")
    "sl" '(my/open-links :which-key "search links")

    ;; --- Org-roam bindings ---
    "nf" '(org-roam-node-find :which-key "find node")
    "nc" '(org-roam-capture :which-key "capture")
    "nd" '(org-roam-dailies-find-today :which-key "daily")

    ;; --- Toggle bindings ---
    "tw" '(visual-line-mode :which-key "word wrap")
    "tc" '(visual-fill-column-mode :which-key "center text")
    "tn" '(display-line-numbers-mode :which-key "line numbers")

    ;; --- Window management ---

    "w" #'evil-window-map

    ;; --- Mode / local leader ---
    ;; --- Activities ---
    "TAB"  '(nil :which-key "activities")
    "TAB n" '(activities-new :which-key "new activity")
    "TAB d" '(activities-define :which-key "define activity")
    "TAB a" '(activities-resume :which-key "resume activity")
    "TAB b" '(activities-switch-buffer :which-key "switch buffer")
    "TAB s" '(activities-suspend :which-key "suspend activity")
    "TAB k" '(activities-kill :which-key "kill activity")
    "TAB l" '(activities-list :which-key "list activities")
    "TAB g" '(activities-revert :which-key "revert activity")))

;; ── Leader key (Doom-style) ────────────────────────────────────────────

;; Full config reload (like Doom's `SPC h R`)
(defun my/copy-file-path ()
  "Copy the full file path of the current buffer to the kill ring."
  (interactive)
  (if buffer-file-name
      (progn
        (kill-new buffer-file-name)
        (message "Copied: %s" buffer-file-name))
    (message "Current buffer is not visiting a file")))

(defun my/config-reload ()
  "Reload post-init.el without restarting Emacs."
  (interactive)
  (let* ((config-dir (expand-file-name "~/.config/emacs/"))
         (post-init (expand-file-name "post-init.el" config-dir)))
    (message "Reloading configuration...")
    (when (file-exists-p post-init)
      (load-file post-init))
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

(with-eval-after-load 'org
  (my-local-leader
    "#" '(org-update-statistics-cookies :which-key "update stats")
    "'" '(org-edit-special :which-key "edit special")
    "*" '(org-ctrl-c-star :which-key "ctrl-c star")
    "-" '(org-ctrl-c-minus :which-key "ctrl-c minus")
    "," '(org-switchb :which-key "switch buffer")
    "." '(org-goto :which-key "goto")
    "@" '(org-cite-insert :which-key "insert citation")
    "A" '(org-archive-subtree-default :which-key "archive")
    "e" '(org-export-dispatch :which-key "export")
    "f" '(org-footnote-action :which-key "footnote")
    "h" '(org-toggle-heading :which-key "toggle heading")
    "i" '(org-toggle-item :which-key "toggle item")
    "I" '(org-id-get-create :which-key "create ID")
    "k" '(org-babel-remove-result :which-key "remove babel result")
    "n" '(org-store-link :which-key "store link")
    "o" '(org-set-property :which-key "set property")
    "q" '(org-set-tags-command :which-key "set tags")
    "t" '(org-todo :which-key "todo")
    "T" '(org-todo-list :which-key "todo list")
    "x" '(org-toggle-checkbox :which-key "toggle checkbox")
    "a"  '(nil :which-key "attachments")
    "aa" '(org-attach :which-key "attach")
    "ad" '(org-attach-delete-one :which-key "delete one")
    "aD" '(org-attach-delete-all :which-key "delete all")
    "an" '(org-attach-new :which-key "new")
    "ao" '(org-attach-open :which-key "open")
    "aO" '(org-attach-open-in-emacs :which-key "open in emacs")
    "ar" '(org-attach-reveal :which-key "reveal")
    "aR" '(org-attach-reveal-in-emacs :which-key "reveal in emacs")
    "as" '(org-attach-set-directory :which-key "set directory")
    "aS" '(org-attach-sync :which-key "sync")
    "au" '(org-attach-url :which-key "attach from url")
    "b"  '(nil :which-key "tables")
    "b-" '(org-table-insert-hline :which-key "insert hline")
    "ba" '(org-table-align :which-key "align")
    "bb" '(org-table-blank-field :which-key "blank field")
    "bc" '(org-table-create-or-convert-from-region :which-key "create table")
    "be" '(org-table-edit-field :which-key "edit field")
    "bf" '(org-table-edit-formulas :which-key "edit formulas")
    "bh" '(org-table-field-info :which-key "field info")
    "bs" '(org-table-sort-lines :which-key "sort")
    "br" '(org-table-recalculate :which-key "recalculate")
    "bR" '(org-table-recalculate-buffer-tables :which-key "recalculate all")
    "bd" '(nil :which-key "delete")
    "bdc" '(org-table-delete-column :which-key "delete column")
    "bdr" '(org-table-kill-row :which-key "delete row")
    "bi" '(nil :which-key "insert")
    "bic" '(org-table-insert-column :which-key "insert column")
    "bih" '(org-table-insert-hline :which-key "insert hline")
    "bir" '(org-table-insert-row :which-key "insert row")
    "biH" '(org-table-hline-and-move :which-key "insert hline and move")
    "bt" '(nil :which-key "toggle")
    "btf" '(org-table-toggle-formula-debugger :which-key "toggle debugger")
    "bto" '(org-table-toggle-coordinate-overlays :which-key "toggle overlays")
    "c"  '(nil :which-key "clock")
    "ci" '(org-clock-in :which-key "clock in")
    "co" '(org-clock-out :which-key "clock out")
    "cc" '(org-clock-cancel :which-key "clock cancel")
    "cg" '(org-clock-goto :which-key "clock goto")
    "cI" '(org-clock-in-last :which-key "clock in last")
    "cr" '(org-resolve-clocks :which-key "resolve clocks")
    "cR" '(org-clock-report :which-key "clock report")
    "ct" '(org-evaluate-time-range :which-key "evaluate time range")
    "cd" '(org-clock-mark-default-task :which-key "mark default")
    "ce" '(org-clock-modify-effort-estimate :which-key "modify effort")
    "cE" '(org-set-effort :which-key "set effort")
    "c=" '(org-clock-timestamps-up :which-key "timestamps up")
    "c-" '(org-clock-timestamps-down :which-key "timestamps down")
    "d"  '(nil :which-key "date/deadline")
    "dd" '(org-deadline :which-key "deadline")
    "ds" '(org-schedule :which-key "schedule")
    "dt" '(org-time-stamp :which-key "timestamp")
    "dT" '(org-time-stamp-inactive :which-key "inactive timestamp")
    "g"  '(nil :which-key "goto")
    "gg" '(org-goto :which-key "goto")
    "gc" '(org-clock-goto :which-key "clock goto")
    "gi" '(org-id-goto :which-key "goto ID")
    "gr" '(org-refile-goto-last-stored :which-key "goto last refile")
    "gx" '(org-capture-goto-last-stored :which-key "goto last capture")
    "l"  '(nil :which-key "links")
    "li" '(org-insert-link :which-key "insert link")
    "ll" '(org-insert-link :which-key "insert link")
    "ls" '(org-store-link :which-key "store link")
    "lS" '(org-insert-last-stored-link :which-key "last stored link")
    "lt" '(org-toggle-link-display :which-key "toggle link display")
    "lii" '(org-id-store-link :which-key "store ID link")
    "lL" '(org-insert-all-links :which-key "insert all links")
    "p"  '(nil :which-key "priority")
    "pd" '(org-priority-down :which-key "priority down")
    "pp" '(org-priority :which-key "priority")
    "pu" '(org-priority-up :which-key "priority up")
    "s"  '(nil :which-key "subtree")
    "sa" '(org-toggle-archive-tag :which-key "archive tag")
    "sb" '(org-tree-to-indirect-buffer :which-key "tree to indirect")
    "sc" '(org-clone-subtree-with-time-shift :which-key "clone subtree")
    "sd" '(org-cut-subtree :which-key "cut subtree")
    "sh" '(org-promote-subtree :which-key "promote subtree")
    "sj" '(org-move-subtree-down :which-key "move subtree down")
    "sk" '(org-move-subtree-up :which-key "move subtree up")
    "sl" '(org-demote-subtree :which-key "demote subtree")
    "sn" '(org-narrow-to-subtree :which-key "narrow to subtree")
    "sr" '(org-refile :which-key "refile")
    "ss" '(org-sparse-tree :which-key "sparse tree")
    "sA" '(org-archive-subtree-default :which-key "archive subtree")
    "sN" '(widen :which-key "widen")
    "sS" '(org-sort :which-key "sort")
    "P"  '(nil :which-key "publish")
    "Pa" '(org-publish-all :which-key "publish all")
    "Pf" '(org-publish-current-file :which-key "publish file")
    "Pp" '(org-publish :which-key "publish")
    "PP" '(org-publish-current-project :which-key "publish project")
    "Ps" '(org-publish-sitemap :which-key "sitemap")
    "r"  '(nil :which-key "roam")
    "rf" '(org-roam-node-find :which-key "find node")
    "rc" '(org-roam-capture :which-key "capture")
    "rd" '(org-roam-dailies-find-today :which-key "daily")))

;; ── Agent shell / app shortcuts (in global leader) ──────────────────────

(with-eval-after-load 'general
  (my-leader-def
    "f." '(my/dotfiles :which-key "dotfiles")
    "ga" '(agent-shell-toggle :which-key "agent shell toggle")
    "og" '(taskwarrior-gtd :which-key "GTD dashboard")
    "oc" '(taskwarrior-gtd-capture :which-key "GTD capture")
    "oj" '(my/open-todays-journal :which-key "today's journal")
    "o-" '(dired-jump :which-key "dired")
    "om" '(my/mu4e :which-key "mu4e")
    "on" '(elfeed :which-key "elfeed")
    "ob" '(eww :which-key "eww")
    ))

;; ── Activities (workspace management) ──────────────────────────────────

(use-package activities
  :ensure t
  :init
  (activities-mode 1)
  :config
  (setq activities-always-persist t)

  (defun my/consult-buffer-list--activity ()
    "Return buffers from the current activity's frame, or all buffers if none active."
    (condition-case nil
        (if-let ((activity (activities-current))
                 (frame (activities--frame activity))
                 ((frame-live-p frame)))
            (cl-loop for buf in (frame-parameter frame 'buffer-list)
                     collect (if (consp buf) (cdr buf) buf))
          (buffer-list))
      (error (buffer-list))))

  (setq consult-buffer-list-function #'my/consult-buffer-list--activity)
  )

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
        avy-timeout-seconds 0.3
        avy-keys '(?j ?k ?l ?u ?i ?o ?p ?m)))


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

(provide 'config-keybindings)
;; config-keybindings.el ends here
