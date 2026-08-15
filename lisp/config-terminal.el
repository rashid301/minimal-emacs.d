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

;; ── Tmux control mode ──────────────────────────────────────────────────

(use-package tmux-control
  :vc (:url "https://github.com/csheaff/tmux-control" :rev "6cba37a20c9e0eb3620cd1cd7aae757e4707cb9")
  :config
  (setq tmux-control-default-host "desktop-pc"
        tmux-control-default-socket-name "/tmp/tmux-1000/default"
        tmux-control-default-session "main"
        tmux-control-window-buffers nil)

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



(provide 'config-terminal)
;;; config-terminal.el ends here
