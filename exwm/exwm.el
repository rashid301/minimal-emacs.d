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
;; A hung Emacs left over from an earlier start.sh run still owns the socket and makes
;; `server-running-p' say yes, so this session would get no server and every emacsclient would
;; time out. This EXWM Emacs is the only one meant to own the socket: take it over.
(server-force-delete)
(server-start)

;; App launcher (M-a), see apps.el
(load "/home/dev/exwm-test/apps.el")

;; ghostel-claude / ghostel-tasks (ported from the Windows config)
(with-demoted-errors "ghostel-extras: %S" (load "/home/dev/exwm-test/ghostel-extras.el"))

;; Portable Super nav/swap/split bindings (ported from config-ewm.el)
(with-demoted-errors "config-super: %S" (load "/home/dev/.emacs.d/lisp/config-super.el"))

(setq exwm-workspace-number 1)   ; tabs, not workspaces
;; Every extra Emacs frame becomes an EXWM workspace, which is what made navigation confusing.
;; `display-buffer' ends with `display-buffer-pop-up-frame' as a last resort (e.g. *Backtrace*, *Help*
;; when no window can be split/reused); drop it so buffers always land in a window of the one frame.
(setq pop-up-frames nil
      display-buffer-fallback-action
      (list (seq-remove (lambda (f) (eq f 'display-buffer-pop-up-frame))
                        (car display-buffer-fallback-action))))
;; Safety net: if a frame still appears (emacsclient -c, other packages), say so loudly.
(add-hook 'after-make-frame-functions
          (lambda (f) (message "EXWM: new frame %S = new workspace; close it with C-x 5 0" (frame-parameter f 'name))))

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
;; s-b: Firefox.  Bring up the running one (in the agents tab: in the right-hand window, next to the
;; agent), else start it.  config-super.el binds s-b to `consult-buffer' for the other environments.
(defun my/exwm--firefox-p (buf)
  (with-current-buffer buf
    (and (derived-mode-p 'exwm-mode) (member exwm-class-name '("firefox" "Firefox")))))

(defun my/exwm--in-right-p ()
  (and (fboundp 'ghostel-claude--agents-tab-p) (ghostel-claude--agents-tab-p)))

(defun my/exwm-firefox ()
  "Show the running Firefox, or start one."
  (interactive)
  (let ((buf (seq-find #'my/exwm--firefox-p (buffer-list))))
    (cond
     ((and buf (get-buffer-window buf))
      (select-window (get-buffer-window buf)))
     (buf
      (if (my/exwm--in-right-p)
          (let ((w (ghostel-claude--right-window t #'my/exwm--firefox-p)))
            (set-window-buffer w buf)
            (ghostel-claude-layout-reset)
            (select-window w))
        (switch-to-buffer buf)))
     (t
      ;; EXWM puts a new X window in the selected window, so pick the right-hand one first.
      (when (my/exwm--in-right-p)
        (select-window (ghostel-claude--right-window t))
        (ghostel-claude-layout-reset))
      (message "Starting Firefox...")
      (start-process "firefox" nil "firefox")))))

(setf (alist-get "s-b" my/super-bindings nil nil #'equal) #'my/exwm-firefox)
(define-key my/super-mode-map (kbd "s-b") #'my/exwm-firefox)

(load "/home/dev/exwm-test/whisper-setup.el")   ; defines my/whisper-toggle (s-v)
(define-key my/super-mode-map (kbd "s-v") #'my/whisper-toggle)

(setq exwm-input-global-keys
      (append
       (list
        (cons (kbd "s-r") #'exwm-reset)
        (cons (kbd "s-=") #'my/exwm-dpi-toggle)
        (cons (kbd "s-v") #'my/whisper-toggle)
        (cons (kbd "s-<f11>") #'my/xephyr-toggle-fullscreen)   ; hide/show the WSLg title bar
        (cons (kbd "s-&")
              (lambda (cmd)
                (interactive (list (read-shell-command "$ ")))
                (start-process-shell-command cmd nil cmd))))
       ;; (s-t is now `ghostel-claude-right-shell' via `my/super-bindings'; it was an xterm launcher.)
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

;; Toggle fullscreen on the WSLg host window of this Xephyr (hides the Windows title bar).
;; Xephyr itself is an X client of WSLg's :0, so ask :0 to flip _NET_WM_STATE_FULLSCREEN.
;; Not bound to a key on purpose: run with M-x.  Caveat: while fullscreen, WSLg may stop
;; delivering mouse input to Xephyr; this command works from the keyboard to toggle back.
(defun my/xephyr-toggle-fullscreen ()
  "Toggle the host (WSLg) window of this Xephyr between windowed and fullscreen."
  (interactive)
  (let* ((name (format "^Xephyr on %s\\." (regexp-quote (or (getenv "DISPLAY") ":1"))))
         (process-environment (cons "DISPLAY=:0" process-environment))
         (id (with-temp-buffer
               (when (zerop (call-process "xdotool" nil t nil "search" "--name" name))
                 (car (split-string (buffer-string) "\n" t))))))
    (if (not id)
        (user-error "No Xephyr host window found on :0")
      (call-process "xdotool" nil nil nil "windowstate" "--toggle" "FULLSCREEN" id)
      (message "Toggled fullscreen on Xephyr host window %s" id))))

;; XSETTINGS: one source of truth for DPI/font rendering, pushed to every GTK/Qt app (even
;; running ones). The DPI comes from XFT_DPI (exported by start.sh), so Xephyr, xrdb, Firefox's
;; scale pref and this all agree. Must be enabled before `exwm-wm-mode'.
(require 'exwm-xsettings)
(load "/home/dev/exwm-test/dpi.el")   ; defines my/exwm-dpi, my/exwm-set-dpi (s-= toggles 96/144)
(setq exwm-xsettings (my/exwm-xsettings-for my/exwm-dpi))
;; GTK theme follows Emacs light/dark (picked from the default face background; see my/toggle-theme-mode)
(setq exwm-xsettings-theme '("Adwaita" . "Adwaita-dark"))
(exwm-xsettings-mode 1)

;; ---- EXWM behavior ------------------------------------------------------------------------
;; Focus follows the mouse.  MUST be set before `exwm-wm-mode': EXWM registers its pointer-enter events
;; at startup, so changing it later only affects Emacs windows, not X windows.  Remove this line for
;; click-to-focus again (restart needed).
(setq mouse-autoselect-window t)
;; When focus moves by keyboard (s- navigation), warp the pointer into that window so pointer and
;; keyboard focus never disagree (matters with focus-follows-mouse on).
(setq exwm-workspace-warp-cursor t)

;; Per-app window rules.  Dialogs, pickers and auth prompts float, centered, without a mode line;
;; Picture-in-Picture floats small in the top-right corner; everything else tiles as before.
;; x/y/width/height as fractions (0..1) are fractions of the screen.  First matching rule wins.
(let ((dialog '(floating t floating-mode-line nil width 0.5 height 0.6 x 0.25 y 0.2)))
  (setq exwm-manage-configurations
        `(((string-match-p "Picture-in-Picture" (or exwm-title ""))
           floating t floating-mode-line nil width 0.28 height 0.28 x 0.70 y 0.06)
          ((member exwm-class-name
                   '("Pinentry" "pinentry" "Pinentry-gtk-2" "Gcr-prompter" "Zenity"
                     "Xdg-desktop-portal-gtk" "xdg-desktop-portal-gtk" "Blueman-manager"
                     "Nm-connection-editor" "Pavucontrol" "Polkit-gnome-authentication-agent-1"
                     "Lxpolkit"))
           ,@dialog)
          ((and (member exwm-class-name '("firefox" "Firefox"))
                (string-match-p "\\`\\(File Upload\\|Save As\\|Open File\\|Choose File\\)"
                                (or exwm-title "")))
           ,@dialog))))

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

;; ---- Evil in Firefox ---------------------------------------------------------------------
;; exwm-firefox-evil (MELPA): in Firefox, normal mode hands keys to Vimium/Tridactyl.
;; :ensure nil because its package deps include `exwm', which lives in ~/exwm-test/elpa (load-path),
;; so letting use-package install it would try to pull a second copy of exwm.  Install by hand with:
;;   (package-install-from-archive (cadr (assq 'exwm-firefox-core package-archive-contents)))
;;   (package-install-from-archive (cadr (assq 'exwm-firefox-evil package-archive-contents)))
;; (exwm-evil is not in any of your package archives, so it is not set up.)
(dolist (d (file-expand-wildcards "/home/dev/.emacs.d/elpa/exwm-firefox-*"))
  (add-to-list 'load-path d))   ; not auto-activated: package.el skips it (unmet `exwm' dep)
(use-package exwm-firefox-evil
  :ensure nil
  :after (exwm evil)
  :hook (exwm-manage-finish . exwm-firefox-evil-activate-if-firefox))

;; Normal state keeps `exwm-input-line-mode-passthrough' on (keys go to Emacs), so the Alt+j would land in
;; Emacs ("buffer is read-only").  So switch to insert state first (that turns passthrough off).
(defun my/exwm-firefox-link-hints ()
  (interactive)
  ;; Insert state = keys go to Firefox, so the hint letters you type next reach the addon too.
  ;; Escape (see `my/exwm-escape') returns to normal state.
  (evil-insert-state)
  (call-process "xdotool" nil 0 nil "key" "--clearmodifiers" "alt+j"))

;; Link hints: `f' in Firefox normal mode sends a real Alt+j via xdotool (XTEST);
;; Firefox ignores the synthetic events `exwm-input--fake-key' sends for addon shortcuts.
(with-eval-after-load 'exwm-firefox-evil
  (evil-define-key 'normal exwm-firefox-evil-mode-map (kbd "f")
    #'my/exwm-firefox-link-hints))

;; Escape in Firefox insert state: exwm-firefox-evil sends all keys to Firefox while inserting, so
;; Emacs never sees <escape>.  Make it an EXWM global key so Emacs gets it; leave insert state, and
;; also pass Escape on to Firefox (closes find bars etc.).  Anywhere else it behaves as before.
(defun my/exwm-escape ()
  (interactive)
  (cond ((and (derived-mode-p 'exwm-mode) (bound-and-true-p exwm-firefox-evil-mode))
         (when (evil-insert-state-p) (evil-normal-state))
         (exwm-input--fake-key 'escape))
        ((derived-mode-p 'exwm-mode) (exwm-input--fake-key 'escape))
        (t (call-interactively (or (and (fboundp 'evil-force-normal-state) (evil-normal-state-p)
                                        #'evil-force-normal-state)
                                   #'keyboard-escape-quit)))))
(exwm-input-set-key (kbd "<escape>") #'my/exwm-escape)
(exwm-input--update-global-prefix-keys)

;; Padding around windows / frame edge / tab bar (replaces the old hand-made tab-bar gap element).
;; Pairs with modus-themes; changes sizes only, not colors.  Fringes stay 0 as in config-ui.el.
(use-package spacious-padding
  :ensure nil   ; installed by hand like the other EXWM-side packages; keeps startup free of install prompts
  :custom
  (spacious-padding-widths '( :internal-border-width 10
                              :header-line-width 2
                              :mode-line-width 2
                              :tab-width 6
                              :right-divider-width 6
                              :scroll-bar-width 0
                              :fringe-width 0))
  :config (spacious-padding-mode 1))

;; Dim every window except the focused one (text buffers, terminals, mode lines; X windows like Firefox
;; are not Emacs text so they stay as they are).  Colors are set in `my/exwm-style-ui'.
(use-package auto-dim-other-buffers
  :config (auto-dim-other-buffers-mode 1))

;; Tab bar + window borders styled relative to the active theme, so they follow any theme (light or dark).
;; Something already overrides the modus tab-bar colors (the bar was dark under every modus theme), so the
;; faces are set directly and re-applied whenever a theme is enabled.
(require 'color)
;; Top border of the windows = a line right under the tab bar.  A full-width element only works with
;; `tab-bar-auto-width' off (with it on, `tab-bar-auto-width' counts the stretch as huge and signals
;; args-out-of-range on every redraw).  Natural-width tabs also read more like tabs.
(setq tab-bar-auto-width nil)
(setq exwm-floating-border-width 2)
(defface my/tab-bar-rule '((t :underline t)) "Line under the tab bar = top border of the windows.")
(defun my/tab-bar-format-rule-right ()
  "Stretch element (underlined = the line under the tab bar) followed by the status items on the right."
  (let* ((rest (tab-bar-format-list (cdr (memq 'my/tab-bar-format-rule-right tab-bar-format))))
         (rest (mapconcat (lambda (item) (nth 2 item)) rest ""))
         (hpos (progn (add-face-text-property 0 (length rest) 'tab-bar t rest)
                      (string-pixel-width rest)))
         (str (propertize " " 'display `(space :align-to (- right (,hpos)))
                          'face 'my/tab-bar-rule)))
    `((my-rule menu-item ,str ignore))))
(defun my/tab-bar-format-status ()
  "Clock + battery, underlined so the line under the tab bar is unbroken.
Reads `display-time-string' / `battery-mode-line-string' directly (cheap; both are timer-updated)."
  (let ((s (string-trim (concat (and (bound-and-true-p display-time-mode) (stringp display-time-string)
                                     (substring-no-properties display-time-string))
                                (and (bound-and-true-p display-battery-mode) (stringp battery-mode-line-string)
                                     (concat " " (substring-no-properties battery-mode-line-string)))))))
    (unless (string-empty-p s)
      (setq s (concat " " s "  "))
      (add-face-text-property 0 (length s) 'my/tab-bar-rule t s)
      `((my-status menu-item ,s ignore)))))
;; Clock + battery on the right of the tab bar (there is no separate panel under EXWM).
(setq display-time-format "%a %H:%M" display-time-default-load-average nil
      battery-mode-line-format " %b%p%%")
(display-time-mode 1)
(display-battery-mode 1)
(setq tab-bar-format '(tab-bar-format-history tab-bar-format-tabs tab-bar-separator
                       tab-bar-format-add-tab my/tab-bar-format-rule-right my/tab-bar-format-status))
;; Echo area + minibuffer: strip background (matches the tab bar), accent prompt.
(defvar my/exwm-strip nil "Current strip color, set by `my/exwm-style-ui'.")
(defvar-local my/exwm-echo-remap nil)
(defun my/exwm-style-echo-buffer ()
  "Give the current (echo area / minibuffer) buffer the strip background.
config-completion.el pads these with `left-margin-width' 4, but window margins are always painted in the
plain default background (a white patch).  Keep the same 4-column padding as a strip-colored `line-prefix'."
  (when my/exwm-strip
    (when my/exwm-echo-remap (face-remap-remove-relative my/exwm-echo-remap))
    (setq my/exwm-echo-remap
          (face-remap-add-relative 'default :background my/exwm-strip))
    (setq-local left-margin-width 0)
    (setq-local line-prefix (propertize "    " 'face (list :background my/exwm-strip)))
    (when (eq (current-buffer) (window-buffer (minibuffer-window)))
      (set-window-margins (minibuffer-window) 0 0))))
;; Depth 90: run after config-completion.el's hook that sets the margin.
(add-hook 'minibuffer-setup-hook #'my/exwm-style-echo-buffer 90)
(add-hook 'minibuffer-inactive-mode-hook #'my/exwm-style-echo-buffer 90)
;; Vertico's candidate count ("1/7714") is a faceless overlay string, which ignores the buffer-local `default'
;; remap above and shows the window's plain background (a white patch).  Give it the strip background.
(with-eval-after-load 'vertico
  (when (fboundp 'vertico--format-count)
    (advice-add 'vertico--format-count :filter-return
                (lambda (str)
                  (if my/exwm-strip
                      (propertize str 'face `(:background ,my/exwm-strip))
                    str)))))

(defun my/exwm-style-ui (&rest _)
  (let* ((bg (face-attribute 'default :background nil t))
         (fg (face-attribute 'default :foreground nil t))
         (dark (eq (frame-parameter nil 'background-mode) 'dark))
         (shift (lambda (pct) (if dark (color-lighten-name bg pct) (color-darken-name bg pct))))
         (strip (funcall shift 8))    ; tab bar strip; the selected tab keeps the window background
         (dim (funcall shift 45))     ; inactive tab text
         (edge (funcall shift 22))    ; window border line
         (accent (or (ignore-errors (face-attribute 'link :foreground nil t)) fg)))
    (set-face-attribute 'tab-bar nil :background strip :foreground fg :box nil)
    ;; Selected tab: same color as the windows below (reads as "attached" to them), bold, accent line on top.
    ;; Inactive tabs: the strip color, dim text.
    (set-face-attribute 'tab-bar-tab nil :background bg :foreground fg :weight 'bold
                        :overline accent :box `(:line-width (8 . 4) :color ,bg))
    (set-face-attribute 'tab-bar-tab-inactive nil :background strip :foreground dim :weight 'normal
                        :overline 'unspecified :box `(:line-width (8 . 4) :color ,strip))
    ;; Mode line = focus indicator.  X windows (Firefox...) can't be dimmed, so this is what shows which
    ;; window has focus.  Active: strip color + accent line on top.  Inactive: flat, window color, faint line.
    (let ((w (or (ignore-errors (plist-get (face-attribute 'mode-line :box nil t) :line-width)) 2)))
      (dolist (spec `((mode-line-active ,strip ,fg ,accent)
                      (mode-line-inactive ,bg ,dim ,edge)))
        (pcase-let ((`(,face ,b ,f ,line) spec))
          (set-face-attribute face nil :background b :foreground f :overline line
                              :box `(:line-width ,w :color ,b :style nil))))
      (set-face-attribute 'mode-line nil :background strip :foreground fg
                          :box `(:line-width ,w :color ,strip :style nil)))
    (setq my/exwm-strip strip)
    ;; Frame margin (spacious-padding's internal border) = strip color: tab bar, side/bottom margins and echo
    ;; area become one continuous frame around the windows.
    (set-face-attribute 'internal-border nil :background strip)
    (set-face-attribute 'minibuffer-prompt nil :foreground accent :weight 'bold)
    ;; The row at the bottom shows " *Minibuf-N*" when idle and " *Echo Area N*" for messages.
    (dolist (b (buffer-list))
      (when (string-match-p "\\` \\*\\(Minibuf-[0-9]+\\|Echo Area [0-9]+\\)\\*\\'" (buffer-name b))
        (with-current-buffer b (my/exwm-style-echo-buffer))))
    (when (facep 'auto-dim-other-buffers)
      (set-face-attribute 'auto-dim-other-buffers nil :background (funcall shift 3) :foreground (funcall shift 50)))
    ;; Floating X windows (dialogs, pickers): accent border, like the selected tab.
    (ignore-errors (customize-set-variable 'exwm-floating-border-color accent))
    (set-face-attribute 'my/tab-bar-rule nil :underline `(:color ,edge :position t))
    ;; Dividers are the gaps (spacious-padding); the first/last pixel of each divider is the border line.
    (set-face-attribute 'window-divider nil :foreground bg)
    (set-face-attribute 'window-divider-first-pixel nil :foreground edge)
    (set-face-attribute 'window-divider-last-pixel nil :foreground edge)))
;; Depth 90 = run after the other theme hooks (spacious-padding resets the divider faces too).
(add-hook 'enable-theme-functions #'my/exwm-style-ui 90)
(my/exwm-style-ui)
