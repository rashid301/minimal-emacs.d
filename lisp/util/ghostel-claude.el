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
;; Buffers start out as *claude:PROJECT* (then *claude:PROJECT*<2>, ...) and are
;; renamed *claude:PROJECT: TITLE* from the terminal title Claude sets (the
;; session topic / /rename), via ghostel's buffer-local
;; `ghostel-buffer-name-function'.  Only Claude buffers are renamed.
;; When Claude exits, the buffer is killed (ghostel's default), so the next
;; call starts a fresh one.  Local directories only.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function ghostel-exec "ghostel")
(defvar ghostel--process)
(defvar ghostel--initial-name)

(defvar-local ghostel-claude--base nil
  "Project directory name of this Claude buffer (the PROJECT in its name).")
(defvar-local ghostel-claude--names nil
  "Names this Claude buffer has had, newest first.
Saved window states (tab layouts) refer to buffers by name, so lookups
also accept a former name.")

(defcustom ghostel-claude-title-max 50
  "Longest terminal title (characters) put in a Claude buffer name."
  :type 'integer
  :group 'ghostel-claude)

(defun ghostel-claude--clean-title (title)
  "TITLE without Claude's leading state glyph, or nil if empty."
  (when (stringp title)
    (let ((x (string-trim (replace-regexp-in-string "\\`[^[:alnum:]]+" "" title))))
      (unless (string-empty-p x) x))))

(defun ghostel-claude--name-from-title (title)
  "Buffer name for this Claude from terminal TITLE, nil to keep the name.
Used as the buffer-local `ghostel-buffer-name-function'."
  (when-let* ((base ghostel-claude--base)
              (clean (ghostel-claude--clean-title title)))
    (setq clean (replace-regexp-in-string "[*\n]+" " " clean))
    (when (> (length clean) ghostel-claude-title-max)
      (setq clean (concat (substring clean 0 (1- ghostel-claude-title-max)) "…")))
    (let ((name (format "*claude:%s: %s*" base clean)))
      (unless (equal name (buffer-name))
        (setq ghostel-claude--names
              (seq-take (delete-dups (cons name ghostel-claude--names)) 30)))
      name)))

(defun ghostel-claude--setup-buffer (buf base)
  "Make BUF (a Claude buffer for project dir name BASE) follow its title."
  (with-current-buffer buf
    (setq-local ghostel-claude--base base
                ghostel-claude--names (list (buffer-name))
                ghostel-buffer-name-function #'ghostel-claude--name-from-title
                bookmark-make-record-function #'ghostel-claude--bookmark-make-record)))

;;;; Bookmarks (also used by activities.el to save/restore buffers)
;;
;; Claude does not print its session id, but each running Claude keeps a file
;; ~/.claude/sessions/PID.json with it.  The Windows claude.exe (used on /mnt)
;; writes the same under C:\Users\...\.claude\sessions with a *Windows* pid, so
;; those are matched by working directory and start time instead.

(declare-function ghostel-bookmark-make-record "ghostel-bookmark")
(declare-function ghostel-bookmark-handler "ghostel-bookmark")
(declare-function bookmark-prop-get "bookmark")
(defvar ghostel--pid)

(defun ghostel-claude--read-session (file)
  "Parsed session FILE (an alist), or nil."
  (condition-case nil
      (if (fboundp 'json-parse-file)
          (json-parse-file file :object-type 'alist)
        (require 'json)
        (let ((json-object-type 'alist) (json-key-type 'symbol))
          (json-read-file file)))
    (error nil)))

(defun ghostel-claude--win-path (path)
  "Convert Windows PATH like D:\\repos\\x to /mnt/d/repos/x."
  (when (and (stringp path) (string-match "\\`\\([A-Za-z]\\):[\\\\/]\\(.*\\)" path))
    (concat "/mnt/" (downcase (match-string 1 path)) "/"
            (replace-regexp-in-string "\\\\" "/" (match-string 2 path)))))

(defun ghostel-claude--session-id (&optional buffer)
  "Claude session id of BUFFER (default current), or nil if unknown."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((pid ghostel--pid)
           (native (and pid (expand-file-name (format "~/.claude/sessions/%d.json" pid)))))
      (if (and native (file-exists-p native))
          (alist-get 'sessionId (ghostel-claude--read-session native))
        (ghostel-claude--windows-session-id pid)))))

(defun ghostel-claude--windows-session-files ()
  "Session files of all readable Windows users (unreadable profiles are skipped)."
  (seq-mapcat (lambda (u)
                (ignore-errors
                  (directory-files (expand-file-name ".claude/sessions" u) t "\\.json\\'")))
              (ignore-errors (directory-files "/mnt/c/Users" t "\\`[^.]"))))

(defun ghostel-claude--windows-session-id (pid)
  "Session id of a Windows claude.exe started by WSL process PID, or nil.
Match on working directory, then the start time closest to PID's."
  (when-let* ((start (and pid (alist-get 'start (process-attributes pid))))
              (ms (* 1000 (float-time start)))
              (dir (directory-file-name (expand-file-name default-directory))))
    (let (best (best-delta 120000.0))
      (dolist (f (ghostel-claude--windows-session-files))
        (let ((d (ghostel-claude--read-session f)))
          (when (and d (equal (alist-get 'kind d) "interactive")
                     (equal (ghostel-claude--win-path (alist-get 'cwd d)) dir))
            (let ((delta (abs (- (alist-get 'startedAt d) ms))))
              (when (< delta best-delta)
                (setq best (alist-get 'sessionId d) best-delta delta))))))
      best)))

(defun ghostel-claude--bookmark-make-record ()
  "Bookmark record for this Claude buffer: ghostel's plus the session id."
  (let ((rec (ghostel-bookmark-make-record))
        (id (ghostel-claude--session-id)))
    (setf (alist-get 'handler (cdr rec)) #'ghostel-claude-bookmark-handler)
    (when id (setf (alist-get 'claude-session (cdr rec)) id))
    rec))

(defun ghostel-claude-bookmark-handler (bmk)
  "Restore Claude bookmark BMK: a live buffer for its session, else
`claude --resume SESSION' in the bookmarked directory.  Without a recorded
session id, behave like a plain ghostel bookmark."
  (let ((id (bookmark-prop-get bmk 'claude-session))
        (dir (bookmark-prop-get bmk 'location)))
    (if (not id)
        (ghostel-bookmark-handler bmk)
      (set-buffer
       (or (seq-find (lambda (b)
                       (and (ghostel-claude--live-p b)
                            (equal (ghostel-claude--session-id b) id)))
                     (seq-filter (lambda (b) (buffer-local-value 'ghostel-claude--base b))
                                 (buffer-list)))
           (ghostel-claude--start (expand-file-name dir) (list "--resume" id)))))))

(put 'ghostel-claude-bookmark-handler 'bookmark-handler-type "Claude")

(defun ghostel-claude--buffer-for-name (name)
  "Live Claude buffer now or formerly called NAME, or nil."
  (or (get-buffer name)
      (seq-find (lambda (b)
                  (and (buffer-local-value 'ghostel-claude--base b)
                       (member name (buffer-local-value 'ghostel-claude--names b))))
                (buffer-list))))

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
  (let ((prefix (ghostel-claude--prefix root))
        (base (file-name-nondirectory (directory-file-name root))))
    (seq-filter (lambda (b)
                  (and (or (equal (buffer-local-value 'ghostel-claude--base b) base)
                           (string-prefix-p prefix (buffer-name b)))
                       (ghostel-claude--live-p b)))
                (buffer-list))))

(defun ghostel-claude--start (root &optional extra-args)
  "Start a new Claude buffer for ROOT and return it.
EXTRA-ARGS are appended to `ghostel-claude-args'."
  (require 'ghostel)
  (let ((buf (generate-new-buffer (ghostel-claude--prefix root))))
    ;; ghostel spawns in the buffer's own `default-directory'.
    (with-current-buffer buf (setq default-directory root))
    (condition-case err
        (ghostel-exec buf ghostel-claude-program
                      (append ghostel-claude-args extra-args))
      (error (kill-buffer buf) (signal (car err) (cdr err))))
    (ghostel-claude--setup-buffer
     buf (file-name-nondirectory (directory-file-name root)))
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

;; The sidebar groups Claudes under the tab that shows them.
;; Keys:  RET / click on a Claude  show it in the main (right) window (focus stays),
;;        o  same and move focus to it
;;        RET / click on a tab header, or t  jump to that tab
;;        j/k (n/p) move, r refresh, q close.
;; State comes from the terminal title Claude sets: a spinner glyph means it
;; is working, "✳" means idle.  Working -> idle while you were not looking
;; turns into "done" (unread) until you visit the buffer.

(require 'tabulated-list)
(require 'tab-bar)
(declare-function evil-define-key* "evil-core")
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
(defface ghostel-claude-needs '((t :inherit error :weight bold))
  "State face: Claude is waiting for you." :group 'ghostel)
(defface ghostel-claude-idle '((t :inherit shadow))
  "State face: Claude is idle." :group 'ghostel)

(defconst ghostel-claude-workspace--buffer-name "*claude-agents*")
(defvar ghostel-claude-workspace--timer nil)
(defvar ghostel-claude-workspace--last (make-hash-table :test #'eq)
  "Claude buffer -> last seen state.")
(defvar ghostel-claude-workspace--unread (make-hash-table :test #'eq)
  "Claude buffer -> non-nil if it finished while unseen.")
(defvar ghostel-claude-workspace--needs (make-hash-table :test #'eq)
  "Claude buffer -> non-nil if it asked for you (permission / question).")
(defvar-local ghostel-claude-workspace--signature nil)

(defun ghostel-claude-workspace--claudes ()
  "Live Claude buffers, sorted by name."
  (sort (seq-filter (lambda (b)
                      (and (string-prefix-p "*claude:" (buffer-name b))
                           (ghostel-claude--live-p b)))
                    (buffer-list))
        (lambda (a b) (string< (ghostel-claude-workspace--sort-key a)
                               (ghostel-claude-workspace--sort-key b)))))

(defun ghostel-claude-workspace--sort-key (buf)
  "Sort key for BUF that does not change when its title does."
  (or (car (last (buffer-local-value 'ghostel-claude--names buf)))
      (buffer-name buf)))

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
  (let ((names (or (buffer-local-value 'ghostel-claude--names buf)
                   (list (buffer-name buf))))
        acc)
    (dolist (tab (funcall tab-bar-tabs-function))
      (when (if (eq (car tab) 'current-tab)
                (get-buffer-window buf nil)
              (let ((in-tab (ghostel-claude-workspace--ws-buffers (alist-get 'ws tab))))
                (seq-some (lambda (n) (member n in-tab)) names)))
        (push (alist-get 'name tab) acc)))
    (nreverse acc)))

(defun ghostel-claude-workspace--shorten (name)
  "Drop the activity prefix, the project part and \"feature-\" from NAME."
  (let ((n (replace-regexp-in-string "\\`α: \\|\\`\\*claude:\\|\\*\\'" "" name t)))
    (setq n (replace-regexp-in-string "\\*\\'" "" n))
    (setq n (replace-regexp-in-string ": .*\\'" "" n))   ; drop the ": TITLE" part
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
          ;; A new turn started: whatever it asked for was answered.
          (when (and (eq new 'working) old (not (eq old 'working)))
            (remhash b ghostel-claude-workspace--needs))
          (when (eq b (window-buffer (selected-window)))
            (remhash b ghostel-claude-workspace--unread)
            (remhash b ghostel-claude-workspace--needs))
          (puthash b new ghostel-claude-workspace--last)))
      (ghostel-claude-workspace--refresh sidebar claudes))))

(defun ghostel-claude-workspace--stop ()
  (when (timerp ghostel-claude-workspace--timer)
    (cancel-timer ghostel-claude-workspace--timer))
  (setq ghostel-claude-workspace--timer nil))

(defun ghostel-claude-workspace--row (buf)
  "Description of BUF: (BUF LABEL TEXT HELP)."
  (let* ((name (buffer-name buf))
         (short (ghostel-claude-workspace--shorten name))
         (title (ghostel-claude-workspace--title buf))
         (state (ghostel-claude-workspace--state buf))
         (unread (gethash buf ghostel-claude-workspace--unread))
         (label (cond ((gethash buf ghostel-claude-workspace--needs)
                       (propertize "? need" 'face 'ghostel-claude-needs))
                      ((eq state 'working) (propertize "● work" 'face 'ghostel-claude-working))
                      (unread (propertize "✓ done" 'face 'ghostel-claude-done))
                      ((eq state 'starting) (propertize "… start" 'face 'ghostel-claude-idle))
                      (t (propertize "· idle" 'face 'ghostel-claude-idle)))))
    (list buf label
          (if (and title (not (string-empty-p title)))
              (format "%s  (%s)" title short)
            short)
          (format "%s\n%s" name (or title "")))))

(defun ghostel-claude-workspace--groups (claudes)
  "Group CLAUDES by tab: list of (TAB-NAME . ROWS); nil TAB-NAME = not shown.
The agents tab itself is ignored, tab order is kept."
  (let ((here (ghostel-claude-workspace--agents-tab-name))
        (by-tab (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'eq))
        groups loose)
    (dolist (b claudes)
      (dolist (tab (ghostel-claude-workspace--tabs b))
        (unless (equal tab here)
          (puthash b t seen)
          (puthash tab (append (gethash tab by-tab) (list (ghostel-claude-workspace--row b))) by-tab)))
      (unless (gethash b seen) (push (ghostel-claude-workspace--row b) loose)))
    (dolist (tab (funcall tab-bar-tabs-function))
      (let ((n (alist-get 'name tab)))
        (when (gethash n by-tab) (push (cons n (gethash n by-tab)) groups))))
    (nconc (nreverse groups) (and loose (list (cons nil (nreverse loose)))))))

(defun ghostel-claude-workspace--agents-tab-name ()
  "Name of the workspace tab (the activity tab or a plain tab)."
  (let ((n ghostel-claude-workspace-name))
    (seq-find (lambda (name) (member name (list n (concat "α: " n))))
              (mapcar (lambda (tb) (alist-get 'name tb)) (funcall tab-bar-tabs-function)))))

(defun ghostel-claude-workspace--insert (groups)
  "Print GROUPS in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (null groups)
        (insert (propertize "  no Claude running\n" 'face 'ghostel-claude-idle))
      (dolist (g groups)
        (let ((tab (car g)))
          (insert (propertize
                   (format "%s %s  (%d)\n" "▾"
                           (if tab (replace-regexp-in-string "\\`α: " "" tab) "not shown in a tab")
                           (length (cdr g)))
                   'face 'bold 'ghostel-claude-tab tab 'ghostel-claude-header t
                   'mouse-face 'highlight
                   'help-echo (and tab "RET / mouse-1: jump to this tab")))
          (pcase-dolist (`(,buf ,label ,text ,help) (cdr g))
            (insert (propertize (format "  %s  %s\n" label text)
                                'ghostel-claude-agent buf 'ghostel-claude-tab tab
                                'mouse-face 'highlight 'help-echo help))))))
    (goto-char (point-min))))

(defun ghostel-claude-workspace--refresh (&optional sidebar claudes)
  "Re-print SIDEBAR for CLAUDES when something changed."
  (interactive)
  (let ((sidebar (or sidebar (get-buffer ghostel-claude-workspace--buffer-name))))
    (when sidebar
      (with-current-buffer sidebar
        (let ((groups (ghostel-claude-workspace--groups
                       (or claudes (ghostel-claude-workspace--claudes)))))
          (unless (equal groups ghostel-claude-workspace--signature)
            (setq ghostel-claude-workspace--signature groups)
            (let* ((win (get-buffer-window sidebar t))
                   (agent (get-text-property (line-beginning-position) 'ghostel-claude-agent))
                   (tab (get-text-property (line-beginning-position) 'ghostel-claude-tab))
                   (hdr (get-text-property (line-beginning-position) 'ghostel-claude-header))
                   (line (line-number-at-pos)))
              (ghostel-claude-workspace--insert groups)
              ;; Put point back on the same agent / header, else the same line.
              (let ((found (ghostel-claude-workspace--find agent tab hdr)))
                (if found (goto-char found)
                  (goto-char (point-min)) (forward-line (1- line))))
              (when win (set-window-point win (point))))))))))

(defun ghostel-claude-workspace--find (agent tab header)
  "Buffer position of the line for AGENT under TAB (or header of TAB)."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (while (not (eobp))
        (let ((a (get-text-property (point) 'ghostel-claude-agent))
              (tb (get-text-property (point) 'ghostel-claude-tab))
              (h (get-text-property (point) 'ghostel-claude-header)))
          (when (if agent (and (eq a agent) (equal tb tab))
                  (and header h (equal tb tab)))
            (throw 'found (point))))
        (forward-line 1))
      nil)))

;;;; Sidebar mode

(defvar ghostel-claude-agents-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'ghostel-claude-agents-open)
    (define-key m [mouse-1] #'ghostel-claude-agents-click)
    (define-key m (kbd "t") #'ghostel-claude-agents-jump-tab)
    (define-key m (kbd "o") #'ghostel-claude-agents-open-and-select)
    (define-key m (kbd "r") #'ghostel-claude-workspace--refresh)
    (define-key m (kbd "j") #'next-line)
    (define-key m (kbd "k") #'previous-line)
    (define-key m (kbd "n") #'next-line)
    (define-key m (kbd "p") #'previous-line)
    (define-key m (kbd "q") #'quit-window)
    m))

(define-derived-mode ghostel-claude-agents-mode special-mode "Agents"
  "Sidebar listing all Claude Code buffers, grouped by tab.
\\{ghostel-claude-agents-mode-map}"
  (setq cursor-in-non-selected-windows nil
        truncate-lines t)
  (display-line-numbers-mode -1)
  (hl-line-mode 1))

;; evil: motion state keeps j/k/gg/G/C-d etc. and these bindings on top.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'ghostel-claude-agents-mode 'motion)
    (evil-define-key* 'motion ghostel-claude-agents-mode-map
      (kbd "RET") #'ghostel-claude-agents-open
      (kbd "t") #'ghostel-claude-agents-jump-tab
      (kbd "o") #'ghostel-claude-agents-open-and-select
      (kbd "r") #'ghostel-claude-workspace--refresh
      (kbd "q") #'quit-window)))

(defun ghostel-claude-agents--main-window ()
  "A window that is not a side window nor the sidebar."
  (or (seq-find (lambda (w)
                  (and (not (window-parameter w 'window-side))
                       (not (eq (window-buffer w)
                                (get-buffer ghostel-claude-workspace--buffer-name)))))
                (window-list nil 'no-minibuffer))
      (split-window (frame-root-window) nil 'right)))

(defun ghostel-claude-agents--tab-at-point ()
  (get-text-property (line-beginning-position) 'ghostel-claude-tab))

(defun ghostel-claude-agents-open ()
  "On an agent: show it in the main window, keeping focus in the sidebar.
On a tab header: jump to the tab."
  (interactive)
  (let ((buf (get-text-property (line-beginning-position) 'ghostel-claude-agent)))
    (if (null buf)
        (ghostel-claude-agents-jump-tab)
      (unless (buffer-live-p buf) (user-error "That Claude is gone"))
      (set-window-buffer (ghostel-claude-agents--main-window) buf)
      (remhash buf ghostel-claude-workspace--unread)
      (remhash buf ghostel-claude-workspace--needs)
      (ghostel-claude-workspace--tick))))

(defun ghostel-claude-agents-open-and-select ()
  "Like `ghostel-claude-agents-open' but also move focus to the Claude."
  (interactive)
  (ghostel-claude-agents-open)
  (when-let* ((buf (get-text-property (line-beginning-position) 'ghostel-claude-agent))
              (w (get-buffer-window buf)))
    (select-window w)))

(defun ghostel-claude-agents-click (event)
  "Open the agent clicked, or jump to the clicked tab header."
  (interactive "e")
  (mouse-set-point event)
  (ghostel-claude-agents-open))

(defun ghostel-claude-agents-jump-tab ()
  "Jump to the tab of the group at point (and its agent window if shown)."
  (interactive)
  (let ((tab (ghostel-claude-agents--tab-at-point))
        (buf (get-text-property (line-beginning-position) 'ghostel-claude-agent)))
    (unless tab (user-error "Not shown in any tab"))
    (tab-bar-select-tab-by-name tab)
    (when-let* ((w (and buf (get-buffer-window buf))))
      (select-window w))))

;;;; Claude Code hooks (Notification / Stop) -> sidebar state + Windows toast

(defun ghostel-claude-workspace--by-pids (pids)
  "Claude buffer whose process is one of PIDS, or nil."
  (seq-find (lambda (b)
              (let ((p (buffer-local-value 'ghostel--process b)))
                (and p (memq (process-id p) pids))))
            (ghostel-claude-workspace--claudes)))

;;;###autoload
(defun ghostel-claude-workspace-event (pids event message)
  "Called by the Claude hook script (via emacsclient).
PIDS are the hook's ancestor process ids, EVENT is \"Notification\" or
\"Stop\".  Mark the matching buffer and return \"SHORT\\nBUFFER\\nTOAST\"
where TOAST is 1 unless you are already looking at that Claude."
  (ignore message)
  (if-let* ((buf (ghostel-claude-workspace--by-pids pids)))
      (let ((looking (and (eq buf (window-buffer (selected-window)))
                          (eq (frame-focus-state) t))))
        (unless looking
          (if (equal event "Notification")
              (puthash buf t ghostel-claude-workspace--needs)
            (puthash buf t ghostel-claude-workspace--unread)))
        (ghostel-claude-workspace--tick)
        (format "%s\n%s\n%s"
                (ghostel-claude-workspace--shorten (buffer-name buf))
                (buffer-name buf) (if looking 0 1)))
    ""))

;;;###autoload
(defun ghostel-claude-workspace-focus (buffer-name)
  "Go to the Claude BUFFER-NAME (toast click): its tab, else the agents tab."
  (when-let* ((buf (ghostel-claude--buffer-for-name buffer-name)))
    (let* ((here (ghostel-claude-workspace--agents-tab-name))
           (tabs (remove here (ghostel-claude-workspace--tabs buf))))
      (if tabs
          (progn (tab-bar-select-tab-by-name (car tabs))
                 (when-let* ((w (get-buffer-window buf))) (select-window w)))
        (ghostel-claude-workspace)
        (let ((w (ghostel-claude-agents--main-window)))
          (set-window-buffer w buf) (select-window w)))
      (remhash buf ghostel-claude-workspace--unread)
      (remhash buf ghostel-claude-workspace--needs)
      (select-frame-set-input-focus (selected-frame))
      (ghostel-claude-workspace--tick)
      t)))

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

;; Claude buffers that predate (re)loading this file: follow their title and save session bookmarks too.
(dolist (b (buffer-list))
  (when (ghostel-claude--live-p b)
    (cond ((buffer-local-value 'ghostel-claude--base b)
           (with-current-buffer b
             (setq-local bookmark-make-record-function #'ghostel-claude--bookmark-make-record)))
          ((string-match "\\`\\*claude:\\([^*:]+\\)\\*\\(<[0-9]+>\\)?\\'" (buffer-name b))
           (ghostel-claude--setup-buffer b (match-string 1 (buffer-name b)))
           (with-current-buffer b
             (when (fboundp 'ghostel--update-title) (ghostel--update-title)))))))

(provide 'ghostel-claude)
;;; ghostel-claude.el ends here
