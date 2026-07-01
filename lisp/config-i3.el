;;; config-i3.el --- EXWM window manager configuration -*- lexical-binding: t; -*-

;; -------------------------------
;; 🪟 EXWM Window Manager
;; -------------------------------
;;
;; Basic EXWM settings
;;setq exwm-manage-force-tiling t)
;; Enable windmove mode
(windmove-mode +1)
;; allow windows with no-other-window side windows
(setq windmove-allow-all-windows t)


(defun my/emacs-kill-window ()
  (interactive)
  (delete-window)
  ;; (balance-windows)
  )

(defun my/wm-integration (command)
  (pcase command
    ((rx bos "focus")
     (windmove-do-window-select
      (intern (elt (split-string command) 1))))
    (- (error command))))

(defun my/emacs-i3-windmove (dir)
  (let ((other-window (windmove-find-other-window dir)))
    (if (or (null other-window) (window-minibuffer-p other-window))
        (progn
          (i3-msg "focus" (symbol-name dir))
          )
      (windmove-do-window-select dir))))

(defun my/emacs-i3-integration (command)
  (pcase command
    ((rx bos "focus")
     (my/emacs-i3-windmove
      (intern (elt (split-string command) 1))))
    ((rx bos "move")
     (my/emacs-i3-move-window
      (intern (elt (split-string command) 1))))
    ((rx bos "resize")
     (my/emacs-i3-resize-window
      (intern (elt (split-string command) 2))
      (intern (elt (split-string command) 1))
      (string-to-number (elt (split-string command) 3))))
    ("layout toggle split" (transpose-frame))
    ("split h" (evil-window-split))
    ("split v" (evil-window-vsplit))
    ("kill" (evil-quit))
    (- (i3-msg (format command)))))


(defun my/emacs-sway-windmove (dir)
  (let ((other-window (windmove-find-other-window dir)))
    (if (or (null other-window) (window-minibuffer-p other-window))
        (progn
          (sway-msg "focus" (symbol-name dir))
          )
      (windmove-do-window-select dir))))

(defun my/emacs-sway-integration (command)
  (pcase command
    ((rx bos "focus")
     (my/emacs-i3-windmove
      (intern (elt (split-string command) 1))))
    ((rx bos "move")
     (my/emacs-i3-move-window
      (intern (elt (split-string command) 1))))
    ((rx bos "resize")
     (my/emacs-i3-resize-window
      (intern (elt (split-string command) 2))
      (intern (elt (split-string command) 1))
      (string-to-number (elt (split-string command) 3))))
    ("layout toggle split" (transpose-frame))
    ("split h" (evil-window-split))
    ("split v" (evil-window-vsplit))
    ("kill" (evil-quit))
    (- (sway-msg (format command)))))

(defun my/close-window-or-frame ()
  (interactive)
  (condition-case nil
      (evil-window-delete)
    (error (delete-frame))))


(defun my/emacs-sway-integration (command)
  (evil-echo "sway:%s" command)
  (pcase command
    ((rx bos "focus")
     (my/emacs-sway-windmove
      (intern (elt (split-string command) 1))))
    ((rx bos "move")
     (my/emacs-sway-move-window
      (intern (elt (split-string command) 1))))
    ((rx bos "resize")
     (my/emacs-sway-resize-window
      (intern (elt (split-string command) 2))
      (intern (elt (split-string command) 1))
      (string-to-number (elt (split-string command) 3))))
    ("layout toggle split" (transpose-frame))
    ("split h" (evil-window-split))
    ("split v" (evil-window-vsplit))
    ("kill" (my/close-window-or-frame))
    (- (sway-msg (format command)))))

(defmacro i3-msg (&rest args)
  `(start-process "emacs-i3-windmove" nil "i3-msg" ,@args))

(defun sway-msg (&rest args)
  (evil-echo "send to sway: %s"
             (string-join (mapcar #'identity args) " "))
  (apply #'start-process
         "emacs-i3-windmove" nil
         "swaymsg" args))

;; -------------------------------
;; Niri Window Manager Support
;; -------------------------------

(defun my/niri-find-socket ()
  "Find the current niri socket, ignoring stale NIRI_SOCKET env."
  (let ((uid (user-uid)))
    ;; Find the most recently modified niri socket
    (car (sort (file-expand-wildcards
                (format "/run/user/%d/niri.*.sock" uid))
               (lambda (a b)
                 (let ((ta (file-attribute-modification-time (file-attributes a)))
                       (tb (file-attribute-modification-time (file-attributes b))))
                   (time-less-p tb ta)))))))

(defun niri-msg (&rest args)
  "Send a command to niri via niri msg action."
  (let* ((action-name (if (= (length args) 1)
                          (car args)
                        (mapconcat #'identity args " ")))
         (socket-path (my/niri-find-socket))
         (current-env (getenv "NIRI_SOCKET")))
    (if (not socket-path)
        (message "niri-msg: ERROR - no socket found!")
      ;; Set NIRI_SOCKET for this subprocess
      (setenv "NIRI_SOCKET" socket-path)
      ;;(message "niri-msg: socket=%s, action=%s (was %s)" socket-path action-name (or current-env "unset"))
      ;; Run: niri msg action ACTION-NAME
      (make-process
       :name "emacs-niri-windmove"
       :buffer nil
       :command (list "niri" "msg" "action" action-name)
       :noquery t))))

(defun my/emacs-niri-windmove (dir)
  (let ((other-window (windmove-find-other-window dir)))
    (if (or (null other-window) (window-minibuffer-p other-window))
        (progn
          (niri-msg (pcase dir
                      ('left "focus-column-or-monitor-left")
                      ('right "focus-column-or-monitor-right")
                      ('up "focus-window-or-workspace-up")
                      ('down "focus-window-or-workspace-down"))))
      (windmove-do-window-select dir))))

(defun my/emacs-niri-move-window (dir)
  (let ((other-window (windmove-find-other-window dir))
        (other-direction (my/emacs-i3-direction-exists-p
                          (pcase dir
                            ('up 'width)
                            ('down 'width)
                            ('left 'height)
                            ('right 'height)))))
    (cond
     ((and other-window (not (window-minibuffer-p other-window)))
      (window-swap-states (selected-window) other-window))
     (other-direction
      (evil-move-window dir))
     (t (niri-msg (pcase dir
                    ('left "move-column-left-or-to-monitor-left")
                    ('right "move-column-right-or-to-monitor-right")
                    ('up "move-column-to-workspace-up")
                    ('down "move-column-to-workspace-down")))))))

(defun my/emacs-niri-resize-window (dir kind value)
  (if (or (one-window-p)
          (not (my/emacs-i3-direction-exists-p dir)))
      (niri-msg "set-column-width" (format "%s" value))
    (setq value (/ value 2))
    (pcase kind
      ('shrink
       (pcase dir
         ('width
          (evil-window-decrease-width value))
         ('height
          (evil-window-decrease-height value))))
      ('grow
       (pcase dir
         ('width
          (evil-window-increase-width value))
         ('height
          (evil-window-increase-height value)))))))

(defun my/emacs-niri-integration (command)
  (evil-echo "niri:%s" command)
  (pcase command
    ((rx bos "focus")
     (my/emacs-niri-windmove
      (intern (elt (split-string command) 1))))
    ((rx bos "move")
     (my/emacs-niri-move-window
      (intern (elt (split-string command) 1))))
    ((rx bos "resize")
     (my/emacs-niri-resize-window
      (intern (elt (split-string command) 2))
      (intern (elt (split-string command) 1))
      (string-to-number (elt (split-string command) 3))))
    ("layout toggle split" (transpose-frame))
    ("split h" (evil-window-vsplit))
    ("split v" (evil-window-split))
    ("kill" (my/close-window-or-frame))
    (- (niri-msg (format command)))))

(defun my/emacs-i3-direction-exists-p (dir)
  (let* ((predicate
          (lambda (d)
            (let ((win (windmove-find-other-window d)))
              (and win (not (window-minibuffer-p win))))))
         (dirs
          (pcase dir
            ('width  '(left right))
            ('height '(up down)))))
    (seq-some predicate dirs)))


(defun my/emacs-sway-direction-exists-p (dir)
  (let* ((predicate
          (lambda (d)
            (let ((win (windmove-find-other-window d)))
              (and win (not (window-minibuffer-p win))))))
         (dirs
          (pcase dir
            ('width  '(left right))
            ('height '(up down)))))
    (seq-some predicate dirs)))

(defun my/emacs-i3-move-window (dir)
  (let ((other-window (windmove-find-other-window dir))
        (other-direction (my/emacs-i3-direction-exists-p
                          (pcase dir
                            ('up 'width)
                            ('down 'width)
                            ('left 'height)
                            ('right 'height)))))
    (cond
     ((and other-window (not (window-minibuffer-p other-window)))
      (window-swap-states (selected-window) other-window))
     (other-direction
      (evil-move-window dir))
     (t (i3-msg "move" (symbol-name dir))))))

(defun my/emacs-sway-move-window (dir)
  (let ((other-window (windmove-find-other-window dir))
        (other-direction (my/emacs-sway-direction-exists-p
                          (pcase dir
                            ('up 'width)
                            ('down 'width)
                            ('left 'height)
                            ('right 'height)))))
    (cond
     ((and other-window (not (window-minibuffer-p other-window)))
      (window-swap-states (selected-window) other-window))
     (other-direction
      (evil-move-window dir))
     (t (sway-msg "move" (symbol-name dir))))))

(defun my/emacs-i3-resize-window (dir kind value)
  (if (or (one-window-p)
          (not (my/emacs-i3-direction-exists-p dir)))
      (i3-msg "resize" (symbol-name kind) (symbol-name dir)
              (format "%s px or %s ppt" value value))
    (setq value (/ value 2))
    (pcase kind
      ('shrink
       (pcase dir
         ('width
          (evil-window-decrease-width value))
         ('height
          (evil-window-decrease-height value))))
      ('grow
       (pcase dir
         ('width
          (evil-window-increase-width value))
         ('height
          (evil-window-increase-height value)))))))


(defun my/emacs-sway-resize-window (dir kind value)
  (if (or (one-window-p)
          (not (my/emacs-sway-direction-exists-p dir)))
      (sway-msg "resize" (symbol-name kind) (symbol-name dir)
                (format "%s px or %s ppt" value value))
    (setq value (/ value 2))
    (pcase kind
      ('shrink
       (pcase dir
         ('width
          (evil-window-decrease-width value))
         ('height
          (evil-window-decrease-height value))))
      ('grow
       (pcase dir
         ('width
          (evil-window-increase-width value))
         ('height
          (evil-window-increase-height value)))))))

(defvar my/summon-enable-frame-reuse t)     ;; Phase 1
(defvar my/summon-enable-external-apps t)   ;; Phase 2
(defvar my/summon-enable-actions t)         ;; Phase 3
(defvar my/summon-enable-firefox nil)       ;; Phase 4 (off by default)

(defvar my/summon-frame nil)

(defun my/get-summon-frame ()
  (when (and my/summon-frame
             (frame-live-p my/summon-frame))
    my/summon-frame))

(defun my/create-summon-frame ()
  (setq my/summon-frame
        (make-frame
         '((name . "emacs-summon")
           (minibuffer . t)
           (width . 120)
           (height . 12)
           (undecorated . t)
           (skip-taskbar . t)
           (no-other-frame . t))))
  my/summon-frame)

(defvar my/external-apps
  '(("Firefox" . "i3-msg '[class=\"Firefox\"] focus'")
    ("Terminal" . "i3-msg '[class=\"Alacritty\"] focus'")
    ("Slack" . "i3-msg '[class=\"Slack\"] focus'")))

(defun my/external-app-candidates ()
  (mapcar (lambda (x)
            (propertize (car x) 'app-cmd (cdr x)))
          my/external-apps))

(defun my/action-open-chatgpt ()
  (browse-url "https://chat.openai.com"))

(defun my/action-open-browser ()
  (start-process-shell-command "browser" nil "firefox"))

(defvar my/actions
  '(("Open ChatGPT" . my/action-open-chatgpt)
    ("Open Browser" . my/action-open-browser)))

(defun my/action-candidates ()
  (mapcar (lambda (x)
            (propertize (car x) 'action (cdr x)))
          my/actions))

(defun my/summon-candidates ()
  (append
   (consult--buffer-query :sort 'visibility)
   (when my/summon-enable-external-apps
     (my/external-app-candidates))
   (when my/summon-enable-actions
     (my/action-candidates))))
(defun my/emacs-summon ()
  "Global Emacs control plane."
  (interactive)
  (let* ((frame (or (and my/summon-enable-frame-reuse
                         (my/get-summon-frame))
                    (my/create-summon-frame))))
    (select-frame-set-input-focus frame)
    (unwind-protect
        (let ((choice
               (consult--read
                (my/summon-candidates)
                :prompt "→ "
                :sort nil)))
          (cond
           ((get-text-property 0 'app-cmd choice)
            (start-process-shell-command
             "app" nil (get-text-property 0 'app-cmd choice)))
           ((get-text-property 0 'action choice)
            (call-interactively
             (get-text-property 0 'action choice)))
           (t
            (switch-to-buffer choice))))
      (when my/summon-enable-frame-reuse
        (make-frame-invisible frame t)))))

(defun my/i3-power-menu-action (choice)
  "Run power-related commands based on CHOICE."
  (pcase choice
    ("Restart Emacs"
     ;; clean restart of daemon
     (start-process-shell-command
      "restart-emacs" nil
      "systemctl --user restart emacs.service"))

    ("Shutdown"
     (start-process-shell-command
      "shutdown" nil
      "systemctl poweroff"))

    ("Reboot"
     (start-process-shell-command
      "reboot" nil
      "systemctl reboot"))

    ("Suspend"
     (start-process-shell-command
      "suspend" nil
      "systemctl suspend"))

    ("Logout"
     ;; this logs you out of KDE/i3 cleanly
     (start-process-shell-command
      "logout" nil
      "loginctl terminate-session $XDG_SESSION_ID"))

    (_ (message "Cancelled"))))



(defun my/i3-power-menu ()
  "Show a rofi-like power menu using consult in a transient frame."
  (interactive)
  (let* ((frame
          (make-frame
           '((name . "emacs-power-menu")
             (minibuffer . only)
             (width . 60)
             (height . 8)
             (undecorated . t)
             (skip-taskbar . t)
             (no-other-frame . t)
             (visibility . nil))))
         (choices '("Restart Emacs"
                    "Shutdown"
                    "Reboot"
                    "Suspend"
                    "Logout")))
    (select-frame-set-input-focus frame)
    (unwind-protect
        (let ((choice
               (consult--read
                choices
                :prompt "Power ▸ "
                :sort nil
                :require-match t
                :preview-key nil)))
          (when choice
            (my/i3-power-menu-action choice)))
      (delete-frame frame))))

(provide 'config-i3)
;;; config-exwm.el ends here
