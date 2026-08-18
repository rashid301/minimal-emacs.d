;; config-editor.el --- Editor specific configurations -*- lexical-binding: t; -*-

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


;; ── Lookup (Doom-style "K") ────────────────────────────────────────────────

(define-key evil-normal-state-map (kbd "K")
            (lambda () (interactive)
              (if (or (eq major-mode 'helpful-mode) (eq major-mode 'help-mode) (eq major-mode 'emacs-lisp-mode))
                  (helpful-at-point)
                (eglot-help-at-point))))

;; ── Server edit / Tridactyl ────────────────────────────────────────────────

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


;; ── Thanos / Wtype ────────────────────────────────────────────────────────

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

;; ── diminish (hide minor modes from modeline) ───────────────────────

(use-package diminish
  :ensure t)

;; ── Autorevert (refresh buffers when files change on disk) ────────────
(use-package autorevert
  :ensure t
  :config
  (global-auto-revert-mode 1)
  ;; Also refresh non-file buffers (magit, elfeed, gnus status) on the
  ;; same cycle — no "File was modified" prompts for files agents and
  ;; background tools rewrite continuously.
  (setq global-auto-revert-non-file-buffers t
        auto-revert-interval 2))  ; poll every 2s


;; ── Activities (workspace management) ──────────────────────────────────

(use-package activities
  :ensure t
  :init
  (activities-mode 1)
  :after consult
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

  (defun my/activity-buffer-p (buf)
    "Return non-nil if BUF belongs to the current activity's frame."
    (condition-case nil
        (if-let ((activity (activities-current))
                 (frame (activities--frame activity))
                 ((frame-live-p frame)))
            (memq buf (cl-loop for b in (frame-parameter frame 'buffer-list)
                               collect (if (consp b) (cdr b) b)))
          t)
      (error t)))

  ;; apply to future frames
  (add-to-list 'default-frame-alist '(buffer-predicate . my/activity-buffer-p))
  ;; and to the current one, since default-frame-alist only affects new frames
  (set-frame-parameter nil 'buffer-predicate #'my/activity-buffer-p)

  (when (fboundp 'consult-buffer)
    (add-to-list 'consult-bookmark-narrow `(?a "Activities" activities-bookmark-handler))
    )
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

(provide 'config-editor)
