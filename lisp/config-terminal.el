;; config-terminal.el --- Terminal and shell configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; Configuration for Eshell, Eat terminal emulator, and related shell tools.

;;; Code:

(defun rs/shell-scroll-setup ()
  (setq-local scroll-conservatively 101))

;; ── Eshell ─────────────────────────────────────────────────────────────

(use-package eshell
  :config
  (setq eshell-scroll-to-bottom-on-input t)
  (setq-local tab-always-indent 'complete)
  (setq eshell-history-size 10000)
  (setq eshell-save-history-on-exit t) ;; Enable history saving on exit
  (setq eshell-hist-ignoredups t) ;; Ignore duplicates

  (setenv "EDITOR" "emacsclient")
  (setenv "VISUAL" "emacsclient")
  (setenv "BROWSER" nil) ;; let browser use xdg-open

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

(provide 'config-terminal)
;;; config-terminal.el ends here
