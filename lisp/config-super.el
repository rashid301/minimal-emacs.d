;;; config-super.el --- Portable Super (s-) nav / swap / split bindings  -*- lexical-binding: t; -*-

;;; Commentary:

;; The navigation and swap shortcuts from config-ewm.el, made portable so the
;; same keys work in all three setups:
;;
;;  - EWM (Wayland):  Super is native.  The keys are also put in `ewm-mode-map',
;;                    because EWM intercepts Super itself.
;;  - EXWM (WSLg):    kmonad turns a held f/j into F13 and Xephyr maps F13 to
;;                    Super, so Super is native here too.  exwm.el must also
;;                    register `my/super-bindings' as EXWM global keys so they
;;                    work while a browser/X window has focus.
;;  - Windows Emacs:  kmonad's F13 arrives as a plain <f13> key.  It is
;;                    translated below into a Super prefix for the next key.
;;
;; Every command degrades gracefully when ewm/exwm are absent.
;; Use:  (load "config-super")   after the rest of the config.

;;; Code:

(require 'windmove)
(require 'subr-x)

;; Where F13 arrives as a plain key (Windows), make it a Super prefix.  C-<f13>
;; covers C-s-<key> chords when Ctrl is held first.  Harmless elsewhere: under
;; X/EWM F13 never reaches Emacs as <f13> (it is already Super).
(define-key key-translation-map (kbd "<f13>")   #'event-apply-super-modifier)
(define-key key-translation-map (kbd "C-<f13>") #'event-apply-super-modifier)

(defun my/super--other-window (dir)
  "Return the window in DIR from the selected one, ignoring the minibuffer."
  (let ((w (windmove-find-other-window dir)))
    (and w (not (window-minibuffer-p w)) w)))

(defun my/super--space (dir)
  "Go to the neighbouring frame (EWM) or tab in DIR (left or right)."
  (cond
   ((and (eq dir 'left) (fboundp 'ewm-frame-left))
    (unless (ewm-frame-left)
      (when (fboundp 'ewm-output-focus-left) (ewm-output-focus-left))))
   ((and (eq dir 'right) (fboundp 'ewm-frame-right))
    (unless (ewm-frame-right)
      (when (fboundp 'ewm-output-focus-right) (ewm-output-focus-right))))
   ((eq dir 'left) (tab-bar-switch-to-prev-tab))
   (t (tab-bar-switch-to-next-tab))))

(defun my/super-focus (dir)
  "Focus the window in DIR; at the edge of the layout, go to the next space."
  (cond
   ;; EWM can also focus Wayland surfaces, so keep its own up/down.
   ((and (fboundp 'ewm-focus-down) (memq dir '(up down)))
    (if (eq dir 'up) (ewm-focus-up) (ewm-focus-down)))
   ((my/super--other-window dir)
    (if (fboundp 'ewm-focus-left)
        (pcase dir ('left (ewm-focus-left)) ('right (ewm-focus-right))
               ('up (ewm-focus-up)) ('down (ewm-focus-down)))
      (windmove-do-window-select dir)))
   ((memq dir '(left right)) (my/super--space dir))
   (t (message "no window to the %s" dir))))

(defun my/super--plain-p (w)
  "Non-nil if W is an ordinary window: not a side window and not dedicated.
Swapping/moving these with side windows (agents sidebar, right side window)
corrupts the window tree (\"same side ... but no common parent\")."
  (and (window-live-p w)
       (not (window-parameter w 'window-side))
       (not (window-dedicated-p w))))

(defun my/super-swap (dir)
  "Swap the selected window with the one in DIR; at the edge, move the frame/tab."
  (let ((other (my/super--other-window dir)))
    (cond
     ((and other (not (and (my/super--plain-p (selected-window)) (my/super--plain-p other))))
      (message "Side/dedicated window: not swapping"))
     (other (window-swap-states (selected-window) other))
     ((and (eq dir 'left) (fboundp 'ewm-frame-move-left)) (ewm-frame-move-left))
     ((and (eq dir 'right) (fboundp 'ewm-frame-move-right)) (ewm-frame-move-right))
     ((and (bound-and-true-p tab-bar-mode) (eq dir 'left)) (tab-bar-move-tab-backward))
     ((and (bound-and-true-p tab-bar-mode) (eq dir 'right)) (tab-bar-move-tab 1))
     (t (message "no window to the %s" dir)))))

(defun my/super-move-buffer (dir)
  "Move the current buffer into the window in DIR."
  (let* ((this (selected-window))
         (other (windmove-find-other-window dir)))
    (cond
     ((and other (not (and (my/super--plain-p this) (my/super--plain-p other))))
      (message "Side/dedicated window: not moving"))
     (other
      (let ((buf-this (window-buffer this)))
        (switch-to-prev-buffer this)
        (select-window other)
        (switch-to-buffer buf-this)))
     (t (message "no window to the %s" dir)))))

(defun my/window-repair ()
  "Recover a tab whose window tree is corrupted (cannot delete windows).
Drops all other windows without the usual sanity checks and clears side flags."
  (interactive)
  (let ((win (selected-window)))
    (set-window-parameter win 'window-side nil)
    (set-window-parameter win 'window-slot nil)
    (set-window-dedicated-p win nil)
    (delete-other-windows-internal win)
    (message "Window tree reset; re-open the layout (e.g. s-c).")))

;; my/super-focus-left, my/super-swap-down, my/super-move-buffer-up, ...
(dolist (kind '(focus swap move-buffer))
  (dolist (dir '(left right up down))
    (defalias (intern (format "my/super-%s-%s" kind dir))
      (let ((fn (intern (format "my/super-%s" kind))) (d dir))
        (lambda () (interactive) (funcall fn d))))))

(defun my/super-space-left ()  (interactive) (my/super--space 'left))
(defun my/super-space-right () (interactive) (my/super--space 'right))

(defun my/super-split-below () (interactive)
       (if (fboundp 'evil-window-split) (evil-window-split) (split-window-below)))
(defun my/super-split-right () (interactive)
       (if (fboundp 'evil-window-vsplit) (evil-window-vsplit) (split-window-right)))

(defun my/super-toggle-maximize ()
  "Toggle maximizing the current window, restoring the layout on the second call."
  (interactive)
  (if (frame-parameter nil 'my/saved-window-configuration)
      (progn
        (set-window-configuration (frame-parameter nil 'my/saved-window-configuration))
        (set-frame-parameter nil 'my/saved-window-configuration nil)
        (message "Window configuration restored."))
    (when (> (count-windows) 1)
      (set-frame-parameter nil 'my/saved-window-configuration (current-window-configuration))
      (delete-other-windows)
      (message "Window maximized."))))

(defun my/super-launch-app ()
  "Run the app launcher of whichever environment this is."
  (interactive)
  (cond ((fboundp 'ewm-launch-app) (call-interactively 'ewm-launch-app))
        ((fboundp 'my/exwm-launch-app) (call-interactively 'my/exwm-launch-app))
        (t (user-error "No app launcher in this environment"))))

;; ghostel-claude lives in lisp/util (put on `load-path' by exwm/ghostel-extras.el).
(autoload 'ghostel-claude-jump "ghostel-claude" nil t)
(autoload 'ghostel-claude-next "ghostel-claude" nil t)
(autoload 'ghostel-claude-prev "ghostel-claude" nil t)
(autoload 'ghostel-claude-right-shell "ghostel-claude" nil t)
(autoload 'ghostel-claude-right-dired "ghostel-claude" nil t)
(autoload 'ghostel-claude-right-find-file "ghostel-claude" nil t)
(autoload 'ghostel-claude-right-close "ghostel-claude" nil t)

(defvar my/super-bindings
  '(;; focus
    ("s-h" . my/super-focus-left)  ("s-j" . my/super-focus-down)
    ("s-k" . my/super-focus-up)    ("s-l" . my/super-focus-right)
    ;; move the buffer to the neighbouring window
    ("C-s-h" . my/super-move-buffer-left)  ("C-s-j" . my/super-move-buffer-down)
    ("C-s-k" . my/super-move-buffer-up)    ("C-s-l" . my/super-move-buffer-right)
    ;; swap windows (at the edge: move the frame/tab)
    ("s-H" . my/super-swap-left)  ("s-J" . my/super-swap-down)
    ("s-K" . my/super-swap-up)    ("s-L" . my/super-swap-right)
    ;; frames / workspaces
    ("s-<" . my/super-space-left) ("s->" . my/super-space-right)
    ;; splits, buffers, misc (from config-ewm.el)
    ("s-?" . my/super-split-below) ("s-/" . my/super-split-right)
    ("s-q" . kill-current-buffer)  ("s-b" . consult-buffer)
    ("s-p" . previous-buffer)      ("s-n" . next-buffer)
    ("s-<return>" . ghostel)       ("s-a" . activities-resume)
    ("s-SPC" . my-leader)          ("s-o" . visual-fill-column-mode)
    ("s-f" . my/super-toggle-maximize) ("s-d" . my/super-launch-app)
    ("s-w" . tab-bar-close-tab)
    ("s-i" . thanos/type)
    ;; running Claude by name, or start one (needs ghostel-claude on `load-path')
    ("s-c" . ghostel-claude-jump)
    ("s-]" . ghostel-claude-next)  ("s-[" . ghostel-claude-prev)
    ;; right-hand window next to the agent (20|40|40); outside the agents tab: plain commands
    ("s-t" . ghostel-claude-right-shell) ("s-e" . ghostel-claude-right-dired) ("s-g" . ghostel-claude-right-find-file)
    ("s-w" . ghostel-claude-right-close))
  "Alist of (KEY-STRING . COMMAND) for the portable Super bindings.")

(defvar my/super-mode-map (make-sparse-keymap)
  "Keymap of `my/super-mode'.")
(dolist (b my/super-bindings)
  (define-key my/super-mode-map (kbd (car b)) (cdr b)))

(define-minor-mode my/super-mode
  "Portable Super (s-) navigation, swap and split bindings."
  :global t
  :keymap my/super-mode-map)
(my/super-mode 1)

;; EWM intercepts Super itself, so the keys must be in its own map too.
(with-eval-after-load 'ewm
  (dolist (b my/super-bindings)
    (define-key ewm-mode-map (kbd (car b)) (cdr b))))

(provide 'config-super)
;;; config-super.el ends here
