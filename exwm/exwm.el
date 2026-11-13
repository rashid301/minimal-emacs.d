;;; exwm.el --- EXWM layer loaded AFTER your normal ~/.emacs.d config  -*- lexical-binding: t; -*-
;; Loaded with: emacs -l ~/exwm-test/exwm.el   (no -Q, so ~/.emacs.d/init.el runs first)

;; EXWM + XELB live in ~/exwm-test/elpa (installed separately from your config's packages).
(dolist (d (append (file-expand-wildcards "/home/dev/exwm-test/elpa/exwm-*")
                   (file-expand-wildcards "/home/dev/exwm-test/elpa/xelb-*")))
  (when (file-directory-p d) (add-to-list 'load-path d)))
(require 'exwm)
(require 'exwm-randr)

;; Server so the running session can be inspected from outside (emacsclient).
(require 'server)
;; Default socket ($XDG_RUNTIME_DIR/emacs/server): a plain `emacsclient' works from ghostel too.
(unless (server-running-p) (server-start))

;; App launcher (M-a), see apps.el
(load "/home/dev/exwm-test/apps.el")

;; ghostel-claude / ghostel-tasks (ported from the Windows config)
(with-demoted-errors "ghostel-extras: %S" (load "/home/dev/exwm-test/ghostel-extras.el"))

;; Portable Super nav/swap/split bindings (ported from config-ewm.el)
(with-demoted-errors "config-super: %S" (load "/home/dev/.emacs.d/lisp/config-super.el"))

(setq exwm-workspace-number 1)   ; tabs, not workspaces

;; Keep X buffer names in sync with the window: "Class: title" (title truncated).
(defun my/exwm-sync-buffer-name ()
  (exwm-workspace-rename-buffer
   (if (and exwm-title (not (string-empty-p exwm-title)))
       (format "%s: %s" exwm-class-name (truncate-string-to-width exwm-title 60 nil nil "…"))
     exwm-class-name)))
(add-hook 'exwm-update-class-hook #'my/exwm-sync-buffer-name)
(add-hook 'exwm-update-title-hook #'my/exwm-sync-buffer-name)

;; Windows keeps the Win key, so start.sh maps Caps Lock -> Super inside Xephyr (setxkbmap
;; -option caps:super). Global EXWM keys use that Super (s-), which leaves Emacs's M- keys alone.
(setq exwm-input-global-keys
      (append
       (list
        (cons (kbd "s-r") #'exwm-reset)
        (cons (kbd "s-=") #'my/exwm-dpi-toggle)
        (cons (kbd "s-&")
              (lambda (cmd)
                (interactive (list (read-shell-command "$ ")))
                (start-process-shell-command cmd nil cmd)))
        (cons (kbd "s-t")
              (lambda () (interactive) (start-process "xterm" nil "xterm"))))
       ;; s-1..s-8 select tab N, s-9 the last tab, s-0 the previous one (matches tab-bar-select-tab-modifiers)
       (cl-loop for i from 0 to 9
                collect (cons (kbd (format "s-%d" i))
                              (let ((n i))
                                (lambda () (interactive)
                                  (cond ((= n 0) (tab-recent))
                                        ((= n 9) (tab-last))
                                        (t (tab-bar-select-tab n)))))))
       ;; every portable Super binding, so they also work while an X window has focus
       (mapcar (lambda (b) (cons (kbd (car b)) (cdr b)))
               (and (boundp (quote my/super-bindings)) my/super-bindings))))

;; Xephyr sends no RandR event EXWM reacts to, and it only brings its RandR monitor
;; geometry up to date when some client runs a full RandR query (xrandr does; EXWM's own
;; query does not). So poll the real root size straight from the X server, and when it
;; differs from EXWM's workarea (and has held steady), run `xrandr --listmonitors' to make
;; Xephyr refresh, then `exwm-randr-refresh'. Retries are capped per size so a persistent
;; mismatch cannot cause an endless refresh/flicker loop.
(exwm-randr-mode 1)
(defvar my/exwm-prev-size nil)
(defvar my/exwm-fix-tries 0)
(defun my/exwm-root-size ()
  (with-slots (width height)
      (xcb:+request-unchecked+reply exwm--connection
          (make-instance 'xcb:GetGeometry :drawable exwm--root))
    (cons width height)))
(defun my/exwm-check-resize ()
  (ignore-errors
    (let ((size (my/exwm-root-size))
          (wa (car exwm-workspace--workareas)))
      (unless (equal size my/exwm-prev-size)
        (setq my/exwm-fix-tries 0))
      (when (and wa
                 (equal size my/exwm-prev-size) ; stable for one tick: dragging is done
                 (< my/exwm-fix-tries 5)
                 (or (/= (car size) (slot-value wa 'width))
                     (/= (cdr size) (slot-value wa 'height))))
        (setq my/exwm-fix-tries (1+ my/exwm-fix-tries))
        (call-process "xrandr" nil nil nil "--listmonitors")
        (exwm-randr-refresh))
      (setq my/exwm-prev-size size))))
(run-with-timer 2 0.3 #'my/exwm-check-resize)

;; XSETTINGS: one source of truth for DPI/font rendering, pushed to every GTK/Qt app (even
;; running ones). The DPI comes from XFT_DPI (exported by start.sh), so Xephyr, xrdb, Firefox's
;; scale pref and this all agree. Must be enabled before `exwm-wm-mode'.
(require 'exwm-xsettings)
(load "/home/dev/exwm-test/dpi.el")   ; defines my/exwm-dpi, my/exwm-set-dpi (s-= toggles 96/144)
(setq exwm-xsettings (my/exwm-xsettings-for my/exwm-dpi))
;; GTK theme follows Emacs light/dark (picked from the default face background; see my/toggle-theme-mode)
(setq exwm-xsettings-theme '("Adwaita" . "Adwaita-dark"))
(exwm-xsettings-mode 1)

(exwm-wm-mode 1)

;; Open URLs in the running Firefox as a new tab. This needs a D-Bus session bus, which start.sh provides.
;; Emacs inherits WAYLAND_DISPLAY from WSLg; hide it so Firefox runs as an X11 client inside Xephyr (EXWM)
;; instead of opening its own window in WSLg.
(setenv "WAYLAND_DISPLAY" nil)
(setq browse-url-browser-function 'browse-url-firefox
      browse-url-firefox-new-window-is-tab t)

;; config-editor.el sets `tab-bar-select-tab-modifiers' to (super meta), i.e. s-M-1..9. The plain s-1..9 binding
;; in config-ewm.el only exists in `ewm-mode-map' (Wayland), so under EXWM use plain Super. `setopt' re-runs
;; the setter, which moves the bindings in `tab-bar-mode-map'.
(setopt tab-bar-select-tab-modifiers '(super))
