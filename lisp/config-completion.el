;;; config-completion.el --- Completion framework configuration -*- lexical-binding: t; -*-

;; ── Vertico — vertical completion UI ───────────────────────────────────

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

  ;; Give the minibuffer and echo area left margin padding
  (dolist (hook '(minibuffer-setup-hook
                  minibuffer-inactive-mode-hook
                  which-key-init-buffer-hook))
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

;; ── Marginalia — rich annotations ──────────────────────────────────────

(use-package marginalia
  :ensure t
  :after vertico
  :config
  (marginalia-mode 1)
  (general-define-key
   :keymaps 'minibuffer-local-map
   "M-A" #'marginalia-cycle))

;; ── Solaire — dual-background mode for side windows and minibuffer ─────

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

;; ── Orderless — flexible completion style ──────────────────────────────

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

;; ── Corfu — in-buffer completion ───────────────────────────────────────

(use-package corfu
  :after evil-collection
  :custom
  (corfu-auto t)
  (corfu-auto-delay 0.2)
  (read-extended-command-predicate #'command-completion-default-include-p)
  (text-mode-ispell-word-completion nil)
  (tab-always-indent 'complete)
  (tab-always-indent nil)
  (corfu-preview-current 'insert)
  :bind (:map corfu-map
              ("<mouse-1>" . corfu-select)
              ("TAB" . corfu-complete)
              ("RET" . corfu-insert)
              ("<return>" . corfu-insert)
              ([tab] . corfu-complete)
              ("<tab>" . corfu-insert))
  
  :config
  (global-corfu-mode +1)
  (setq
   corfu-preselect 'first
   corfu-count 16
   corfu-max-width 120
   corfu-on-exact-match nil
   corfu-quit-at-boundary 'separator
   corfu-quit-no-match corfu-quit-at-boundary)

  (add-to-list 'completion-category-overrides `(lsp-capf (styles ,@completion-styles)))
  (add-hook 'evil-insert-state-exit-hook #'corfu-quit))

;; ── Expreg — expand region ─────────────────────────────────────────────

(use-package expreg
  :ensure t
  :after evil
  :bind (:map evil-visual-state-map
              ("RET" . expreg-expand)
              ("-" . expreg-contract)
              :map global-map
              ("C-=" . expreg-expand)))

(provide 'config-completion)
;;; config-completion.el ends here
