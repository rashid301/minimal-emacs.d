(windmove-mode +1)

(setq my/ewm-activities-use-frame t)

(defun my/emacs-ewm-swap (dir)
  (let ((other-window (windmove-find-other-window dir)))
    (cond
     ((and other-window (not (window-minibuffer-p other-window)))
      (window-swap-states (selected-window) other-window))
     (t (if my/ewm-activities-use-frame
            (pcase dir
              ('left (ewm-frame-move-left))
              ('right (ewm-frame-move-right)))
          (pcase dir
            ('left (tab-bar-move-tab-backward))
            ('right (tab-bar-move-tab 1))
            ))))))

(defun my/emacs-ewm-focus (dir)
  (let ((other-window (windmove-find-other-window dir)))
    (cond
     ((and other-window (not (window-minibuffer-p other-window)))
      (pcase dir
        ('left (ewm-focus-left))
        ('right (ewm-focus-right))
        ('up (ewm-focus-up))
        ('down (ewm-focus-down))
        ))
     (t (if my/ewm-activities-use-frame
            (pcase dir
              ('left (ewm-frame-left))
              ('right (ewm-frame-right)))
          (pcase dir
            ('left (tab-bar-switch-to-prev-tab))
            ('right (tab-bar-switch-to-next-tab))
            ))))))

(defun my/ewm-swap-left ()  (interactive) (my/emacs-ewm-swap 'left))
(defun my/ewm-swap-down ()  (interactive) (my/emacs-ewm-swap 'down))
(defun my/ewm-swap-up ()   (interactive) (my/emacs-ewm-swap 'up))
(defun my/ewm-swap-right ()(interactive) (my/emacs-ewm-swap 'right))

(defun my/ewm-focus-left ()  (interactive) (my/emacs-ewm-focus 'left))
(defun my/ewm-focus-right () (interactive) (my/emacs-ewm-focus 'right))

(defun my/move-buffer-to (direction)
  (let* ((this (selected-window))
         (other (windmove-find-other-window direction)))
    (if other
        (let ((buf-this (window-buffer this))
              (buf-other (window-buffer other)))
          (switch-to-prev-buffer this)
          (select-window other)
          (switch-to-buffer buf-this))
      (message "no window to the %s" direction))))

(defun my/move-buffer-left ()  (interactive) (my/move-buffer-to 'left))
(defun my/move-buffer-right ()(interactive) (my/move-buffer-to 'right))
(defun my/move-buffer-up ()   (interactive) (my/move-buffer-to 'up))
(defun my/move-buffer-down () (interactive) (my/move-buffer-to 'down))

(defun my/ewm-workspace-name ()
  (alist-get 'name (assq 'current-tab (funcall tab-bar-tabs-function))))

(defun my/ewm-workspace-all-names ()
  (mapcar #'(lambda (tab) (alist-get 'name tab))
          (funcall tab-bar-tabs-function)))

(defun my/ewm-workspace-switch ()
  (interactive)
  (call-interactively 'activities-resume))

(with-eval-after-load 'ewm
  (define-key ewm-mode-map (kbd "s-h") #'my/ewm-focus-left)
  (define-key ewm-mode-map (kbd "s-j") #'ewm-focus-down)
  (define-key ewm-mode-map (kbd "s-k") #'ewm-focus-up)
  (define-key ewm-mode-map (kbd "s-l") #'my/ewm-focus-right)

  (define-key ewm-mode-map (kbd "C-s-h") #'my/move-buffer-left)
  (define-key ewm-mode-map (kbd "C-s-j") #'my/move-buffer-down)
  (define-key ewm-mode-map (kbd "C-s-k") #'my/move-buffer-up)
  (define-key ewm-mode-map (kbd "C-s-l") #'my/move-buffer-right)

  (define-key ewm-mode-map (kbd "s-H") #'my/ewm-swap-left)
  (define-key ewm-mode-map (kbd "s-J") #'my/ewm-swap-down)
  (define-key ewm-mode-map (kbd "s-K") #'my/ewm-swap-up)
  (define-key ewm-mode-map (kbd "s-L") #'my/ewm-swap-right)
  (define-key ewm-mode-map (kbd "s-?") #'evil-window-split)
  (define-key ewm-mode-map (kbd "s-/") #'evil-window-vsplit)
  (define-key ewm-mode-map (kbd "s-q") #'kill-current-buffer)
  (define-key ewm-mode-map (kbd "s-b") #'consult-buffer)
  (define-key ewm-mode-map (kbd "s-<return>") #'eshell)
  (define-key ewm-mode-map (kbd "s-a") #'activities-resume)
  (define-key ewm-mode-map (kbd "s-p") #'previous-buffer)
  (define-key ewm-mode-map (kbd "s-n") #'next-buffer)
  (define-key ewm-mode-map (kbd "s-Q") #'my/session-noc)
  (define-key ewm-mode-map (kbd "s-d") #'ewm-launch-app)

  (defun my/session-noc ()
    (interactive)
    (make-process :buffer " *noctalia-session*"
                  :name "noctalia-session"
                  :command '("noctalia" "msg" "panel-toggle" "session")
                  :noquery t))

  (unless my/ewm-activities-use-frame
    (define-key ewm-mode-map (kbd "s-1") #'tab-bar-select-tab)
    (define-key ewm-mode-map (kbd "s-2") #'tab-bar-select-tab)
    (define-key ewm-mode-map (kbd "s-3") #'tab-bar-select-tab)
    (define-key ewm-mode-map (kbd "s-4") #'tab-bar-select-tab)
    (define-key ewm-mode-map (kbd "s-5") #'tab-bar-select-tab)
    (define-key ewm-mode-map (kbd "s-6") #'tab-bar-select-tab))

  (add-hook 'ewm-surface-mode-hook
            (defun ewm-hide-modeline () (mode-line-invisible-mode 1)))

  (when (daemonp)
    (add-hook 'after-make-frame-functions
              (defun +ewm-trigger-server-hooks-h (frame)
                (when (display-graphic-p frame)
                  (remove-hook 'after-make-frame-functions #'+ewm-trigger-server-hooks-h)
                  (with-selected-frame frame
                    (run-hooks 'server-after-make-frame-hook))))))

  (setq tab-bar-select-tab-modifiers '(meta))
  (setq ewm-focus-follows-mouse t)

  (setq ewm-output-config
        '(("DP-1" :scale 1.5)))

  (setq ewm-input-config
        '((touchpad :natural-scroll t :tap t :dwt t)
          (mouse :accel-profile "flat")))

  (when my/ewm-activities-use-frame
    (add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))
    (require 'activities-ewm)
    (activities-ewm-mode 1)))

(defvar consult-source-xdg-apps
  `(:name "Apps"
    :narrow ?a
    :category app
    :items ,(lambda ()
              (mapcar #'car (ewm-list-xdg-apps)))
    :action ,#'ewm-launch-xdg-command))

(with-eval-after-load 'consult
  (add-to-list 'consult-buffer-sources consult-source-xdg-apps t))

(defun my/signal-noctalia-workspace-update (&rest _)
  (let* ((all-names (my/ewm-workspace-all-names))
         (cur-name (my/ewm-workspace-name))
         (payload (format "\"%s|%s\""
                          cur-name
                          (mapconcat #'identity all-names ","))))
    (make-process :buffer nil
                  :name "noctalia-workspace-signal"
                  :command (list "noctalia" "msg" "plugin" "noctalia/emacs-tabs:emacs-tabs" "all:default" "refresh" payload)
                  :noquery t)))

(add-to-list 'tab-bar-tab-post-select-functions #'my/signal-noctalia-workspace-update)
(add-to-list 'tab-bar-tab-post-open-functions #'my/signal-noctalia-workspace-update)

(add-hook 'server-after-make-frame-hook
          (defun sarg/noctalia ()
            (setq tab-bar-show nil)
            (setenv "LABWC_PID" (format "%s" (emacs-pid)))
            (setenv "NOCTALIA_PAM_SERVICE" "fingerprint")
            (make-process :buffer " *noctalia*"
                          :name "noctalia"
                          :command '("noctalia" "--daemon")
                          :noquery t)))

(defun my/activity-name ()
  (interactive)
  (message (activities-name-for (activities-current))))
