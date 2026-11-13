;;; init.el --- throwaway EXWM test config (run inside Xephyr)  -*- lexical-binding: t; -*-
(require 'package)
(setq package-user-dir (expand-file-name "elpa" (file-name-directory load-file-name)))
(add-to-list 'package-archives '("gnu" . "https://elpa.gnu.org/packages/"))
(package-initialize)
(unless (package-installed-p 'exwm)
  (package-refresh-contents)
  (package-install 'exwm))

(require 'exwm)
(setq exwm-workspace-number 4)
(add-hook 'exwm-update-class-hook
          (lambda () (exwm-workspace-rename-buffer exwm-class-name)))

;; Windows grabs Super, so use Alt for global keys.
(setq exwm-input-global-keys
      (append
       (list
        (cons (kbd "M-r") #'exwm-reset)
        (cons (kbd "M-w") #'exwm-workspace-switch)
        (cons (kbd "M-&")
              (lambda (cmd)
                (interactive (list (read-shell-command "$ ")))
                (start-process-shell-command cmd nil cmd)))
        (cons (kbd "M-t")
              (lambda () (interactive) (start-process "xterm" nil "xterm"))))
       (mapcar (lambda (i)
                 (cons (kbd (format "M-%d" i))
                       (lambda () (interactive) (exwm-workspace-switch-create i))))
               (number-sequence 0 3))))

;; Emacs server so the setup can be inspected from outside (emacsclient).
(require 'server)
(server-start)

;; Follow Xephyr window resizes (maximize / drag) so Emacs fills the screen.
(require 'exwm-randr)
(exwm-randr-mode 1)

;; Xephyr doesn't deliver a RandR screen-change event that EXWM reacts to, so
;; poll the display size and refresh when it changes (maximize / drag resize).
(defvar my/exwm-last-size nil)
(defun my/exwm-check-resize ()
  (let ((size (cons (x-display-pixel-width) (x-display-pixel-height))))
    (unless (equal size my/exwm-last-size)
      (setq my/exwm-last-size size)
      (when (and (bound-and-true-p exwm-randr-mode) (fboundp 'exwm-randr-refresh))
        (ignore-errors (exwm-randr-refresh))))))
(run-with-timer 2 0.5 #'my/exwm-check-resize)

(exwm-wm-mode 1)
