;;; config-project.el --- Project, Git, and LSP configuration -*- lexical-binding: t; -*-

;; ── Project (built-in) ─────────────────────────────────────────────────

(use-package project
  :demand t
  :config
  (setq project-vc-extra-file-search-functions nil)
  (project-remember-project (cons 'transient (expand-file-name "~/Dropbox/")))

  (defvar my-project-git-root-cache (make-hash-table :test 'equal)
    "Cache of directory -> git project root, to avoid repeated locate-dominating-file walks over TRAMP.")


  (defun my-project-try-git (dir)
    "Detect a Git project root by checking for a .git file or directory.
Works perfectly for worktrees and over TRAMP.
Caches result per DIR to avoid repeated ancestor walks."
    (let ((cached (gethash dir my-project-git-root-cache 'not-found)))
      (if (not (eq cached 'not-found))
          cached
        (let ((result
               (when-let ((dotgit-loc (locate-dominating-file dir ".git")))
                 ;; Enforce that the root is the clean, literal directory holding the .git file
                 (let ((root (file-name-as-directory (expand-file-name dotgit-loc))))
                   (when (file-exists-p (expand-file-name ".git" root))
                     (list 'vc 'Git root))))))
          (puthash dir result my-project-git-root-cache)
          result))))

  ;; Put it at the front of the hook so Emacs doesn't use its broken fallback
  (add-hook 'project-find-functions #'my-project-try-git 'append))

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
  (magit-display-buffer-function 'magit-display-buffer-same-window-except-diff-v1)
  :config
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
  (add-hook 'git-commit-setup-hook #'evil-insert-state))

(use-package forge
  :ensure t
  :if (locate-library "forge")
  :after magit
  :config
  (setq forge-add-default-bindings nil))

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

;; ── LSP (Eglot - built-in) ─────────────────────────────────────────────

(use-package eglot
  :demand t
  :hook
  ((python-ts-mode . eglot-ensure)
   (typescript-ts-mode . eglot-ensure)
   (js-ts-mode . eglot-ensure))
  :config
  (setq eglot-server-programs
        (append
         '((python-mode . ("pyright"))
           (js-mode . ("typescript-language-server" "--stdio"))
           (typescript-ts-mode . ("tsc" "--lsp" "--stdio")))
         (assq-delete-all 'python-mode 
                          (assq-delete-all 'js-mode
                                           (assq-delete-all 'typescript-ts-mode eglot-server-programs)))))
  ;; Tell Eglot NEVER to attempt formatting so it won't conflict with Apheleia
  (add-to-list 'eglot-ignored-server-capabilities :documentFormattingProvider))

;; ── Apheleia (code formatting) ─────────────────────────────────────────

(use-package apheleia
  :ensure t
  :init
  (apheleia-global-mode +1)
  :config
  (setf (alist-get 'prettier apheleia-formatters)
        '("apheleia-npx" "prettier" "--stdin-filepath" filepath)))

;; ── rg (ripgrep integration) ───────────────────────────────────────────

(use-package rg
  :ensure t
  :config
  (rg-enable-menu))

;; ── Tree-sitter (built-in) ─────────────────────────────────────────────

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

(provide 'config-project)

;;; config-project.el ends here
