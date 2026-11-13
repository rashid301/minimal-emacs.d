;;; ghostel-claude.el --- Claude Code in a project ghostel buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-claude' runs `claude' as the process of a ghostel buffer
;; (via `ghostel-exec') in the current project's root.
;;
;;   M-x ghostel-claude        bring back this project's Claude (start it if
;;                             none is running).  Works from any buffer, so
;;                             after switching away just call it again.
;;   C-u M-x ghostel-claude    start another Claude for the project.
;;   M-x ghostel-claude-switch pick among the project's Claude buffers.
;;
;;   M-x ghostel-claude-workspace  open the "agents" tab/activity: a left sidebar
;;                             listing every Claude (state + the tab(s) it is
;;                             shown in), the chosen one opens on the right.
;;
;; Buffers are named *claude:PROJECT* (then *claude:PROJECT*<2>, ...).
;; When Claude exits, the buffer is killed (ghostel's default), so the next
;; call starts a fresh one.  Local directories only.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function ghostel-exec "ghostel")
(defvar ghostel--process)

(defcustom ghostel-claude-program "claude"
  "Program that starts Claude Code."
  :type 'string
  :group 'ghostel)

(defcustom ghostel-claude-args nil
  "Extra arguments passed to `ghostel-claude-program'."
  :type '(repeat string)
  :group 'ghostel)

(defcustom ghostel-claude-display-action
  '(display-buffer-in-side-window (side . right) (window-width . 0.5))
  "Display action used to show a Claude buffer."
  :type 'sexp
  :group 'ghostel)

(defun ghostel-claude--root ()
  "Return the current project root, or `default-directory'."
  (if-let* ((pr (project-current)))
      (expand-file-name (project-root pr))
    (expand-file-name default-directory)))

(defun ghostel-claude--prefix (root)
  "Return the buffer-name prefix for project ROOT."
  (format "*claude:%s*" (file-name-nondirectory (directory-file-name root))))

(defun ghostel-claude--live-p (buffer)
  "Return non-nil if BUFFER has a live ghostel process."
  (and (buffer-live-p buffer)
       (let ((p (buffer-local-value 'ghostel--process buffer)))
         (and p (process-live-p p)))))

(defun ghostel-claude--buffers (root)
  "Return live Claude buffers for ROOT, most recently used first."
  (let ((prefix (ghostel-claude--prefix root)))
    (seq-filter (lambda (b)
                  (and (string-prefix-p prefix (buffer-name b))
                       (ghostel-claude--live-p b)))
                (buffer-list))))

(defun ghostel-claude--start (root)
  "Start a new Claude buffer for ROOT and return it."
  (require 'ghostel)
  (let ((buf (generate-new-buffer (ghostel-claude--prefix root))))
    ;; ghostel spawns in the buffer's own `default-directory'.
    (with-current-buffer buf (setq default-directory root))
    (condition-case err
        (ghostel-exec buf ghostel-claude-program ghostel-claude-args)
      (error (kill-buffer buf) (signal (car err) (cdr err))))
    buf))

(defun ghostel-claude--show (buffer)
  "Display BUFFER with `ghostel-claude-display-action' and select it."
  (when-let* ((win (display-buffer buffer ghostel-claude-display-action)))
    (select-window win)))

;;;###autoload
(defun ghostel-claude (&optional new)
  "Bring up Claude Code for the current project in a ghostel buffer.
Show and select the project's most recent running Claude, or start one if
there is none.  With prefix argument NEW, start an additional Claude."
  (interactive "P")
  (let* ((root (ghostel-claude--root))
         (bufs (ghostel-claude--buffers root)))
    (ghostel-claude--show
     (if (and bufs (not new))
         (car bufs)
       (ghostel-claude--start root)))))

;;;###autoload
(defun ghostel-claude-switch ()
  "Show one of the current project's Claude buffers, chosen by name."
  (interactive)
  (let ((bufs (ghostel-claude--buffers (ghostel-claude--root))))
    (unless bufs (user-error "No Claude running for this project"))
    (ghostel-claude--show
     (get-buffer (completing-read "Claude: " (mapcar #'buffer-name bufs) nil t)))))

;;;; Workspace: sidebar of all Claudes in an "agents" tab / activity

;; Sidebar keys:  RET / click  show the Claude in the main (right) window
;;                t / click on the Tab column  jump to a tab showing it
;;                g refresh, n/p move.
;; State comes from the terminal title Claude sets: a spinner glyph means it
;; is working, "✳" means idle.  Working -> idle while you were not looking
;; turns into "done" (unread) until you visit the buffer.

(require 'tabulated-list)
(require 'tab-bar)
(declare-function activities-named "activities")
(declare-function activities-new "activities")
(declare-function activities-switch "activities")
(declare-function activities-resume "activities")
(declare-function activities-activity-active-p "activities")
(declare-function activities-activity-name "activities")
(defvar activities-tabs-mode)
(defvar ghostel-title)

(defcustom ghostel-claude-workspace-name "agents"
  "Name of the workspace tab / activity."
  :type 'string :group 'ghostel)

(defcustom ghostel-claude-workspace-width 56
  "Width in columns of the agents sidebar."
  :type 'integer :group 'ghostel)

(defcustom ghostel-claude-workspace-working-glyphs "◐◑◒◓⠁⠂⠄⡀⢀⠠⠐⠈"
  "First characters of the terminal title that mean Claude is working."
  :type 'string :group 'ghostel)

(defface ghostel-claude-working '((t :inherit warning))
  "State face: Claude is working." :group 'ghostel)
(defface ghostel-claude-done '((t :inherit success :weight bold))
  "State face: Claude finished while you were elsewhere." :group 'ghostel)
(defface ghostel-claude-idle '((t :inherit shadow))
  "State face: Claude is idle." :group 'ghostel)

(defconst ghostel-claude-workspace--buffer-name "*claude-agents*")
(defvar ghostel-claude-workspace--timer nil)
(defvar ghostel-claude-workspace--last (make-hash-table :test #'eq)
  "Claude buffer -> last seen state.")
(defvar ghostel-claude-workspace--unread (make-hash-table :test #'eq)
  "Claude buffer -> non-nil if it finished while unseen.")
(defvar-local ghostel-claude-workspace--signature nil)

(defun ghostel-claude-workspace--claudes ()
  "Live Claude buffers, sorted by name."
  (sort (seq-filter (lambda (b)
                      (and (string-prefix-p "*claude:" (buffer-name b))
                           (ghostel-claude--live-p b)))
                    (buffer-list))
        (lambda (a b) (string< (buffer-name a) (buffer-name b)))))

(defun ghostel-claude-workspace--title (buf)
  "Terminal title of BUF without its state glyph."
  (let ((title (buffer-local-value 'ghostel-title buf)))
    (and (stringp title)
         (string-trim (replace-regexp-in-string "\\`[^[:alnum:]]+" "" title)))))

(defun ghostel-claude-workspace--state (buf)
  "Return `working', `idle' or `starting' for BUF."
  (let ((title (buffer-local-value 'ghostel-title buf)))
    (cond ((or (not (stringp title)) (string-empty-p title)) 'starting)
          ((seq-contains-p ghostel-claude-workspace-working-glyphs (aref title 0)) 'working)
          (t 'idle))))

(defun ghostel-claude-workspace--ws-buffers (ws)
  "Buffer names mentioned in window-state WS."
  (let (acc)
    (cl-labels ((walk (x)
                  (cond ((and (consp x) (eq (car x) 'buffer) (stringp (cadr x)))
                         (push (cadr x) acc))
                        ((consp x)
                         (while (consp x) (walk (car x)) (setq x (cdr x)))))))
      (walk ws))
    acc))

(defun ghostel-claude-workspace--tabs (buf)
  "Names of the tabs (selected frame) whose layout shows BUF."
  (let ((name (buffer-name buf)) acc)
    (dolist (tab (funcall tab-bar-tabs-function))
      (when (if (eq (car tab) 'current-tab)
                (get-buffer-window buf nil)
              (member name (ghostel-claude-workspace--ws-buffers (alist-get 'ws tab))))
        (push (alist-get 'name tab) acc)))
    (nreverse acc)))

(defun ghostel-claude-workspace--shorten (name)
  "Drop the activity prefix, the project part and \"feature-\" from NAME."
  (let ((n (replace-regexp-in-string "\\`α: \\|\\`\\*claude:\\|\\*\\'" "" name t)))
    (setq n (replace-regexp-in-string "\\*\\'" "" n))
    (when (string-match "\\`[^.*]+\\.\\(.+\\)" n) (setq n (match-string 1 n)))
    (replace-regexp-in-string "\\`\\(feature\\|bugfix\\|hotfix\\)[-/]" "" n)))

(defun ghostel-claude-workspace--tick ()
  "Update states, flag unread completions, refresh the sidebar."
  (let ((sidebar (get-buffer ghostel-claude-workspace--buffer-name))
        (claudes (ghostel-claude-workspace--claudes)))
    (if (not sidebar)
        (ghostel-claude-workspace--stop)
      (dolist (b claudes)
        (let ((new (ghostel-claude-workspace--state b))
              (old (gethash b ghostel-claude-workspace--last)))
          (when (and (eq old 'working) (eq new 'idle))
            (puthash b t ghostel-claude-workspace--unread))
          (when (eq b (window-buffer (selected-window)))
            (remhash b ghostel-claude-workspace--unread))
          (puthash b new ghostel-claude-workspace--last)))
      (ghostel-claude-workspace--refresh sidebar claudes))))

(defun ghostel-claude-workspace--stop ()
  (when (timerp ghostel-claude-workspace--timer)
    (cancel-timer ghostel-claude-workspace--timer))
  (setq ghostel-claude-workspace--timer nil))

(defun ghostel-claude-workspace--entry (buf)
  (let* ((name (buffer-name buf))
         (short (replace-regexp-in-string
                 "\\`\\*claude:\\(.*?\\)\\*\\(<[0-9]+>\\)?\\'" "\\1\\2" name))
         (short (ghostel-claude-workspace--shorten short))
         (state (ghostel-claude-workspace--state buf))
         (unread (gethash buf ghostel-claude-workspace--unread))
         (label (cond ((eq state 'working) (propertize "● work" 'face 'ghostel-claude-working))
                      (unread (propertize "✓ done" 'face 'ghostel-claude-done))
                      ((eq state 'starting) (propertize "… start" 'face 'ghostel-claude-idle))
                      (t (propertize "· idle" 'face 'ghostel-claude-idle))))
         (tabs (mapcar #'ghostel-claude-workspace--shorten
                       (ghostel-claude-workspace--tabs buf)))
         (help (format "%s\n%s" name (or (ghostel-claude-workspace--title buf) ""))))
    (list buf
          (vector (propertize label 'help-echo help)
                  (propertize short 'help-echo help)
                  (propertize (if tabs (string-join tabs ", ") "-")
                              'mouse-face 'highlight
                              'help-echo "mouse-1: jump to this tab")))))

(defun ghostel-claude-workspace--refresh (&optional sidebar claudes)
  "Re-print SIDEBAR for CLAUDES when something changed."
  (let ((sidebar (or sidebar (get-buffer ghostel-claude-workspace--buffer-name))))
    (when sidebar
      (with-current-buffer sidebar
        (let ((entries (mapcar #'ghostel-claude-workspace--entry
                               (or claudes (ghostel-claude-workspace--claudes)))))
          (unless (equal entries ghostel-claude-workspace--signature)
            (setq ghostel-claude-workspace--signature entries
                  tabulated-list-entries entries)
            (tabulated-list-print t t)))))))

;;;; Sidebar mode

(defvar ghostel-claude-agents-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m tabulated-list-mode-map)
    (define-key m (kbd "RET") #'ghostel-claude-agents-open)
    (define-key m [mouse-1] #'ghostel-claude-agents-click)
    (define-key m (kbd "t") #'ghostel-claude-agents-jump-tab)
    (define-key m (kbd "g") #'ghostel-claude-workspace--refresh)
    (define-key m (kbd "n") #'next-line)
    (define-key m (kbd "p") #'previous-line)
    m))

(define-derived-mode ghostel-claude-agents-mode tabulated-list-mode "Agents"
  "Sidebar listing all Claude Code buffers."
  (setq tabulated-list-format [("State" 8 nil) ("Agent" 24 nil) ("Tab" 0 nil)]
        tabulated-list-padding 1
        cursor-in-non-selected-windows nil)
  (tabulated-list-init-header)
  (display-line-numbers-mode -1)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'ghostel-claude-agents-mode 'emacs)))

(defun ghostel-claude-agents--buffer-at-point ()
  (or (tabulated-list-get-id) (user-error "No agent on this line")))

(defun ghostel-claude-agents--main-window ()
  "A window that is not a side window nor the sidebar."
  (or (seq-find (lambda (w)
                  (and (not (window-parameter w 'window-side))
                       (not (eq (window-buffer w)
                                (get-buffer ghostel-claude-workspace--buffer-name)))))
                (window-list nil 'no-minibuffer))
      (split-window (frame-root-window) nil 'right)))

(defun ghostel-claude-agents-open ()
  "Show the agent on this line in the main window and select it."
  (interactive)
  (let ((buf (ghostel-claude-agents--buffer-at-point))
        (win (ghostel-claude-agents--main-window)))
    (unless (buffer-live-p buf) (user-error "That Claude is gone"))
    (set-window-buffer win buf)
    (remhash buf ghostel-claude-workspace--unread)
    (select-window win)
    (ghostel-claude-workspace--tick)))

(defun ghostel-claude-agents-click (event)
  "Open the agent clicked; the Tab column jumps to its tab instead."
  (interactive "e")
  (mouse-set-point event)
  (if (and (tabulated-list-get-id)
           (>= (current-column) (+ 1 8 24)))
      (ghostel-claude-agents-jump-tab)
    (ghostel-claude-agents-open)))

(defun ghostel-claude-agents-jump-tab ()
  "Jump to a tab that shows the agent on this line."
  (interactive)
  (let* ((buf (ghostel-claude-agents--buffer-at-point))
         (tabs (remove (alist-get 'name (tab-bar--current-tab))
                       (ghostel-claude-workspace--tabs buf))))
    (unless tabs (user-error "Not shown in any other tab"))
    (tab-bar-select-tab-by-name
     (if (cdr tabs) (completing-read "Tab: " tabs nil t) (car tabs)))
    (when-let* ((w (get-buffer-window buf)))
      (select-window w))))

;;;; Entry point

(defun ghostel-claude-workspace--sidebar ()
  (or (get-buffer ghostel-claude-workspace--buffer-name)
      (with-current-buffer (get-buffer-create ghostel-claude-workspace--buffer-name)
        (ghostel-claude-agents-mode)
        (current-buffer))))

(defun ghostel-claude-workspace--ensure-layout ()
  "Make the current tab show the sidebar on the left.  Return its window."
  (let* ((sidebar (ghostel-claude-workspace--sidebar))
         (win (display-buffer-in-side-window
               sidebar `((side . left) (slot . -10)
                         (window-width . ,ghostel-claude-workspace-width)
                         (preserve-size . (t . nil))
                         (window-parameters (no-delete-other-windows . t))))))
    (set-window-dedicated-p win t)
    ;; Never leave the sidebar buffer as the main window's content.
    (dolist (w (window-list nil 'no-minibuffer))
      (when (and (eq (window-buffer w) sidebar) (not (eq w win)))
        (set-window-buffer w (other-buffer sidebar))))
    (unless (timerp ghostel-claude-workspace--timer)
      (setq ghostel-claude-workspace--timer
            (run-with-timer 1 1 #'ghostel-claude-workspace--tick)))
    (setq ghostel-claude-workspace--signature nil)
    (ghostel-claude-workspace--tick)
    win))

(defun ghostel-claude-workspace--on-activity (activity &rest _)
  (when (equal (activities-activity-name activity) ghostel-claude-workspace-name)
    (ghostel-claude-workspace--ensure-layout)))

;;;###autoload
(defun ghostel-claude-workspace ()
  "Go to the agents workspace (tab, and activity when `activities' is on).
Creates it on first use: a left sidebar lists every Claude with its state
and the tab(s) it is shown in; RET or a click opens one in the right window."
  (interactive)
  (let ((name ghostel-claude-workspace-name))
    (if (and (require 'activities nil t) (bound-and-true-p activities-tabs-mode))
        (let ((act (activities-named name)))
          (add-hook 'activities-after-switch-functions #'ghostel-claude-workspace--on-activity)
          (add-hook 'activities-after-resume-functions #'ghostel-claude-workspace--on-activity)
          (cond ((null act) (activities-new name))
                ((activities-activity-active-p act) (activities-switch act))
                (t (activities-resume act))))
      (if (member name (mapcar (lambda (tb) (alist-get 'name tb)) (funcall tab-bar-tabs-function)))
          (tab-bar-select-tab-by-name name)
        (tab-bar-new-tab)
        (tab-bar-rename-tab name))))
  (select-window (ghostel-claude-workspace--ensure-layout)))

(provide 'ghostel-claude)
;;; ghostel-claude.el ends here
