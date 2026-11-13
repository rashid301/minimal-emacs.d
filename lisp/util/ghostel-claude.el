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

(require 'cl-lib)
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

(defvar ghostel-claude--counter 0 "Creation counter for Claude buffers.")
(defvar-local ghostel-claude--seq nil
  "Creation order of this Claude buffer; gives lists a stable order.")

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
    (setq-local ghostel-claude--seq (or ghostel-claude--seq (cl-incf ghostel-claude--counter))
                ghostel-claude--base base
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
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer :object-type 'alist))
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

;; Bookmarks saved before this existed (or by plain ghostel) restore through
;; `ghostel-bookmark-handler', which would leave a Claude buffer without the
;; title naming and session-aware bookmarks above, so it would keep saving old
;; style records.  Adopt such a buffer once it is restored.
(defun ghostel-claude--adopt-restored (buf)
  "If BUF, just restored by ghostel's bookmark handler, runs claude, set it up."
  (when (and (buffer-live-p buf)
             (buffer-local-boundp 'ghostel-identity buf)
             (not (buffer-local-value 'ghostel-claude--base buf)))
    (let ((cmd (alist-get 'command (buffer-local-value 'ghostel-identity buf))))
      (when (and (consp cmd) (stringp (car cmd))
                 (string-match-p "\\`claude\\(\\.exe\\)?\\'" (file-name-nondirectory (car cmd))))
        (with-current-buffer buf
          (ghostel-claude--setup-buffer
           buf (file-name-nondirectory (directory-file-name default-directory)))
          (when (fboundp 'ghostel--update-title) (ghostel--update-title))))))
  buf)
(advice-add 'ghostel-bookmark-handler :filter-return #'ghostel-claude--adopt-restored)

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
       (buffer-local-boundp 'ghostel--process buffer)
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

;; The sidebar groups Claudes by project (their directory), most urgent first.
;; Keys:  RET / click on a Claude  show it in the main (right) window (focus stays),
;;        o  same and move focus to it
;;        c  start another Claude in that group's / Claude's project (stays here)
;;        RET / click on a project header, or t  jump to that project's tab
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
  (if-let* ((n (buffer-local-value 'ghostel-claude--seq buf)))
      (format "%08d" n)
    (or (car (last (buffer-local-value 'ghostel-claude--names buf)))
        (buffer-name buf))))

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

(defun ghostel-claude--tab-matches-base (tab-name base)
  "Non-nil if TAB-NAME is BASE's project: the same, or BASE is \"TAB.branch\"."
  (let ((a (replace-regexp-in-string "\\`α: " "" tab-name)))
    (and (stringp base) (not (string-empty-p a))
         (or (equal a base) (string-prefix-p (concat a ".") base)))))

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

(defun ghostel-claude--project-of (buf)
  "Project (directory name) BUF's Claude runs in."
  (or (buffer-local-value 'ghostel-claude--base buf)
      (let ((n (replace-regexp-in-string "\\`\\*claude:\\|\\*\\(<[0-9]+>\\)?\\'" "" (buffer-name buf))))
        (replace-regexp-in-string ": .*\\'" "" n))))

(defun ghostel-claude-workspace--rank (buf)
  "Urgency of BUF: 0 needs you, 1 done (unread), 2 working, 3 idle."
  (cond ((gethash buf ghostel-claude-workspace--needs) 0)
        ((gethash buf ghostel-claude-workspace--unread) 1)
        ((eq (ghostel-claude-workspace--state buf) 'working) 2)
        (t 3)))

(defun ghostel-claude-workspace--row (buf &optional bare)
  "Description of BUF: (BUF LABEL TEXT HELP).  With BARE, TEXT is just the title."
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
          (cond ((and bare title (not (string-empty-p title))) title)
                (bare short)
                ((and title (not (string-empty-p title))) (format "%s  (%s)" title short))
                (t short))
          (format "%s\n%s" name (or title "")))))

(defface ghostel-claude-current '((t :inherit font-lock-keyword-face :weight bold))
  "Marker for the Claude you are on in the agents sidebar." :group 'ghostel)

(defun ghostel-claude-workspace--current (claudes)
  "The Claude you are on: the selected window's, else one visible next to the sidebar."
  (let ((sel (window-buffer (selected-window))))
    (if (memq sel claudes)
        sel
      (seq-some (lambda (w) (let ((b (window-buffer w))) (and (memq b claudes) b)))
                (window-list nil 'no-minibuffer)))))

(defun ghostel-claude-workspace--groups (claudes)
  "Group CLAUDES by project: list of (PROJECT . ROWS), most urgent first.
Each row notes, dimmed, the tab(s) where that Claude is on screen."
  (let ((here (ghostel-claude-workspace--agents-tab-name))
        (cur (ghostel-claude-workspace--current claudes))
        (by-proj (make-hash-table :test #'equal))
        projects)
    (dolist (b claudes)
      (let ((p (ghostel-claude--project-of b)))
        (unless (gethash p by-proj) (push p projects))
        (puthash p (cons b (gethash p by-proj)) by-proj)))
    (let ((rank (lambda (b) (ghostel-claude-workspace--rank b))))
      (mapcar
       (lambda (p)
         (cons p (mapcar
                  (lambda (b)
                    (let ((row (ghostel-claude-workspace--row b t))
                          (tabs (remove here (ghostel-claude-workspace--tabs b))))
                      (when tabs
                        (setf (nth 2 row)
                              (concat (nth 2 row)
                                      (propertize (format "  [%s]"
                                                          (mapconcat (lambda (tb) (replace-regexp-in-string "\\`α: " "" tb))
                                                                     tabs ", "))
                                                  'face 'shadow))))
                      (append row (list (eq b cur)))))
                  (sort (copy-sequence (gethash p by-proj))
                        (lambda (a b) (or (< (funcall rank a) (funcall rank b))
                                          (and (= (funcall rank a) (funcall rank b))
                                               (string< (ghostel-claude-workspace--sort-key a)
                                                        (ghostel-claude-workspace--sort-key b)))))))))
       (sort projects
             (lambda (a b)
               (let ((ra (apply #'min (mapcar rank (gethash a by-proj))))
                     (rb (apply #'min (mapcar rank (gethash b by-proj)))))
                 (or (< ra rb) (and (= ra rb) (string< a b))))))))))

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
        (let ((tab (car g)))   ; the project
          (insert (propertize
                   (format "%s %s  (%d)\n" "▾" tab (length (cdr g)))
                   'face 'bold 'ghostel-claude-project tab 'ghostel-claude-header t
                   'mouse-face 'highlight
                   'help-echo "RET / mouse-1: jump to this project's tab, c: new session"))
          (pcase-dolist (`(,buf ,label ,text ,help ,cur) (cdr g))
            (insert (propertize (format " %s %s  %s\n"
                                        (if cur (propertize "▶" 'face 'ghostel-claude-current) " ")
                                        label text)
                                'ghostel-claude-agent buf 'ghostel-claude-project tab
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
                   (tab (get-text-property (line-beginning-position) 'ghostel-claude-project))
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
              (tb (get-text-property (point) 'ghostel-claude-project))
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
    (define-key m (kbd "c") #'ghostel-claude-agents-new)
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
      (kbd "c") #'ghostel-claude-agents-new
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

(defun ghostel-claude-agents--project-at-point ()
  (get-text-property (line-beginning-position) 'ghostel-claude-project))

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

;;;; Session picker
;; Claude has no "list sessions" command, but every session is a transcript
;; PROJECTS/<encoded dir>/<id>.jsonl holding its latest `aiTitle' and `lastPrompt'.

(defcustom ghostel-claude-session-limit 40
  "How many of a project's most recent sessions the picker offers."
  :type 'integer
  :group 'ghostel-claude)

(defun ghostel-claude--encode-dir (path)
  "PATH as Claude encodes it in ~/.claude/projects (non-alphanumerics become -)."
  (replace-regexp-in-string "[^[:alnum:]]" "-" path))

(defun ghostel-claude--transcript-dirs (root)
  "Existing transcript directories for project ROOT (Linux and Windows Claude)."
  (let* ((root (directory-file-name (expand-file-name root)))
         (dirs (list (expand-file-name
                      (concat "~/.claude/projects/" (ghostel-claude--encode-dir root))))))
    (when (string-match "\\`/mnt/\\([a-z]\\)\\(/.*\\)?\\'" root)
      (let ((win (format "%s:%s" (upcase (match-string 1 root)) (or (match-string 2 root) "/"))))
        (dolist (u (ignore-errors (directory-files "/mnt/c/Users" t "\\`[^.]")))
          (push (expand-file-name (concat ".claude/projects/" (ghostel-claude--encode-dir win)) u)
                dirs))))
    (seq-filter (lambda (d) (ignore-errors (file-directory-p d))) dirs)))

(defun ghostel-claude--last-field (key)
  "Value of JSON string field KEY in its last occurrence in this buffer, or nil."
  (goto-char (point-max))
  (when (re-search-backward (format "\"%s\":\"" key) nil t)
    (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
      (condition-case nil
          (alist-get (intern key) (json-parse-string line :object-type 'alist))
        (error nil)))))

(defun ghostel-claude--transcript-info (file)
  "(TITLE . LAST-PROMPT) from the tail of transcript FILE."
  (with-temp-buffer
    (let* ((size (file-attribute-size (file-attributes file)))
           (coding-system-for-read 'utf-8))
      (insert-file-contents file nil (max 0 (- size 400000)) size)
      (cons (ghostel-claude--last-field "aiTitle")
            (ghostel-claude--last-field "lastPrompt")))))

(defun ghostel-claude--project-sessions (root)
  "Recent sessions of ROOT: list of (ID TITLE PROMPT MTIME), newest first."
  (let (files out)
    (dolist (d (ghostel-claude--transcript-dirs root))
      (dolist (f (directory-files d t "\\.jsonl\\'"))
        (push (cons f (file-attribute-modification-time (file-attributes f))) files)))
    (setq files (seq-take (sort files (lambda (a b) (time-less-p (cdr b) (cdr a))))
                          ghostel-claude-session-limit))
    (pcase-dolist (`(,f . ,mtime) files)
      (let ((info (ghostel-claude--transcript-info f)))
        (when (or (car info) (cdr info))
          (push (list (file-name-base f) (car info) (cdr info) mtime) out))))
    (nreverse out)))

(defun ghostel-claude--pick-session (root)
  "Ask which Claude session to open in ROOT.  Return nil for a new one, else an id."
  (let* ((new "＋ New session")
         (live (delq nil (mapcar (lambda (b)
                                   (and (ghostel-claude--live-p b)
                                        (buffer-local-value 'ghostel-claude--base b)
                                        (ghostel-claude--session-id b)))
                                 (buffer-list))))
         (alist (list (cons new nil))))
    (pcase-dolist (`(,id ,title ,prompt ,mtime) (ghostel-claude--project-sessions root))
      (push (cons (concat (or title (substring (or prompt id) 0 (min 40 (length (or prompt id)))))
                          (and prompt title
                               (propertize (concat "  —  "
                                                   (truncate-string-to-width
                                                    (replace-regexp-in-string "[\n\r]+" " " prompt) 60 nil nil "…"))
                                           'face 'shadow))
                          (propertize (format "  %s%s" (format-time-string "%m-%d %H:%M" mtime)
                                              (if (member id live) "  ● running" ""))
                                      'face 'shadow)
                          (propertize (concat "  " (substring id 0 8)) 'face 'font-lock-comment-face))
                  id)
            alist))
    (setq alist (cons (car (last alist)) (nreverse (butlast alist))))
    (cdr (assoc (completing-read
                 (format "Claude in %s: " (abbreviate-file-name (directory-file-name root)))
                 (lambda (str pred action)
                   (if (eq action 'metadata)
                       '(metadata (display-sort-function . identity)
                                  (cycle-sort-function . identity))
                     (complete-with-action action alist str pred)))
                 nil t nil nil new)
                alist))))

(defun ghostel-claude--open-session (root id)
  "Claude buffer for session ID in ROOT: the live one if any, else a new process.
ID nil starts a new session; otherwise `claude --resume ID'."
  (or (and id (seq-find (lambda (b)
                          (and (ghostel-claude--live-p b)
                               (buffer-local-value 'ghostel-claude--base b)
                               (equal (ghostel-claude--session-id b) id)))
                        (buffer-list)))
      (ghostel-claude--start (expand-file-name root) (and id (list "--resume" id)))))

(defun ghostel-claude-agents-new ()
  "Open a Claude session in the project of the group (or Claude) at point.
Asks for a new session or one of the project's earlier ones (resumed with
`claude --resume ID'; one already running is just shown).
Stays in this tab: the new Claude opens in the main window, grouped
under its project, so the agents tab works as a control center."
  (interactive)
  (let* ((buf (or (get-text-property (line-beginning-position) 'ghostel-claude-agent)
                  (save-excursion
                    (forward-line 1)
                    (get-text-property (line-beginning-position) 'ghostel-claude-agent))))
         (root (and (buffer-live-p buf) (buffer-local-value 'default-directory buf))))
    (unless root (user-error "Put point on a group or a Claude first"))
    (let* ((root (expand-file-name root))
           (new (ghostel-claude--open-session root (ghostel-claude--pick-session root))))
      (let ((win (ghostel-claude-agents--main-window)))
        (set-window-buffer win new)
        (select-window win))
      (ghostel-claude-workspace--tick))))

;;;; Keyboard switcher

(defun ghostel-claude--show-here (buf)
  "Show Claude BUF without leaving this tab and select it.
In the agents tab it takes the main window; a visible Claude is just selected."
  (cond ((get-buffer-window buf) (select-window (get-buffer-window buf)))
        ((get-buffer-window ghostel-claude-workspace--buffer-name)
         (let ((w (ghostel-claude-agents--main-window)))
           (set-window-buffer w buf) (select-window w)))
        (t (ghostel-claude--show buf)))
  (remhash buf ghostel-claude-workspace--unread)
  (remhash buf ghostel-claude-workspace--needs)
  (ghostel-claude-workspace--tick))

(defun ghostel-claude--switch-candidates ()
  "Alist (DISPLAY . BUFFER) of live Claudes, needing-you first, then done, working, idle."
  (let* ((bufs (sort (ghostel-claude-workspace--claudes)
                     (lambda (a b) (< (ghostel-claude-workspace--rank a)
                                      (ghostel-claude-workspace--rank b)))))
         seen)
    (mapcar (lambda (b)
              (pcase-let* ((`(,_b ,label ,text ,_h) (ghostel-claude-workspace--row b))
                           (tabs (remove (ghostel-claude-workspace--agents-tab-name)
                                         (ghostel-claude-workspace--tabs b)))
                           (str (concat label "  " text
                                        (and tabs (propertize
                                                   (concat "  ["
                                                           (mapconcat (lambda (tb) (replace-regexp-in-string "\\`α: " "" tb))
                                                                      tabs ", ")
                                                           "]")
                                                   'face 'shadow)))))
                (when (member str seen) (setq str (concat str (format " <%s>" (buffer-name b)))))
                (push str seen)
                (cons str b)))
            bufs)))

(defvar ghostel-claude--history-cache nil "(TIME . DIRS) cache for `ghostel-claude--history-roots'.")

(defun ghostel-claude--transcript-cwd (file)
  "Working directory recorded in transcript FILE (as a local path), or nil."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file nil 0 65536))
    (goto-char (point-min))
    (when (re-search-forward "\"cwd\":\"\\([^\"]*\\)\"" nil t)
      (let ((cwd (ignore-errors (json-parse-string (concat "\"" (match-string 1) "\"")))))
        (cond ((null cwd) nil)
              ((ghostel-claude--win-path cwd))
              ((string-prefix-p "/" cwd) cwd))))))

(defun ghostel-claude--history-roots ()
  "Directories you have run Claude in (from its transcripts), most recent first.
Cached for a few minutes: the Windows side lives on a slow mount."
  (if (and ghostel-claude--history-cache
           (< (- (float-time) (car ghostel-claude--history-cache)) 300))
      (cdr ghostel-claude--history-cache)
    (let (found)
      (dolist (base (cons (expand-file-name "~/.claude/projects")
                          (mapcar (lambda (u) (expand-file-name ".claude/projects" u))
                                  (ignore-errors (directory-files "/mnt/c/Users" t "\\`[^.]")))))
        (dolist (d (ignore-errors (directory-files base t "\\`[^.]")))
          (let ((newest (car (sort (ignore-errors
                                     (directory-files-and-attributes d t "\\.jsonl\\'" t))
                                   (lambda (a b)
                                     (time-less-p (file-attribute-modification-time (cdr b))
                                                  (file-attribute-modification-time (cdr a))))))))
            (when newest
              (when-let* ((cwd (ignore-errors (ghostel-claude--transcript-cwd (car newest)))))
                (push (cons (file-attribute-modification-time (cdr newest)) cwd) found))))))
      (let (dirs)
        (dolist (x (sort found (lambda (a b) (time-less-p (car b) (car a)))))
          (let ((dir (file-name-as-directory (cdr x))))
            (when (and (not (string-match-p "/AppData/\\|\\`/tmp/\\|/\\.claude/" dir))
                       (ignore-errors (file-directory-p dir)))
              (cl-pushnew (abbreviate-file-name dir) dirs :test #'equal))))
        (setq dirs (nreverse dirs))
        (setq ghostel-claude--history-cache (cons (float-time) dirs))
        dirs))))

(defun ghostel-claude--project-roots ()
  "Directories to offer for a new Claude: running ones, then ones Claude has
been used in (most recent first), then Emacs's known projects."
  (let (roots)
    (dolist (d (append
                (mapcar (lambda (b) (buffer-local-value 'default-directory b))
                        (ghostel-claude-workspace--claudes))
                (ghostel-claude--history-roots)
                (seq-remove #'file-remote-p (ignore-errors (project-known-project-roots)))))
      (let ((d (abbreviate-file-name (file-name-as-directory (expand-file-name d)))))
        (unless (member d roots) (setq roots (append roots (list d))))))
    roots))

;; Cycling uses a stable order (project, then start order), not the sidebar's urgency
;; order: that one reshuffles whenever a state changes, which would make next/prev jump.
(defun ghostel-claude--cycle (dir)
  "Show the Claude DIR (+1 or -1) places after the current one, wrapping."
  (let* ((bufs (sort (ghostel-claude-workspace--claudes)
                     (lambda (a b)
                       (let ((pa (ghostel-claude--project-of a))
                             (pb (ghostel-claude--project-of b)))
                         (if (equal pa pb)
                             (string< (ghostel-claude-workspace--sort-key a)
                                      (ghostel-claude-workspace--sort-key b))
                           (string< pa pb))))))
         (n (length bufs))
         (cur (cond ((memq (current-buffer) bufs) (current-buffer))
                    ;; in the sidebar: the Claude in the main window
                    ((equal (buffer-name) ghostel-claude-workspace--buffer-name)
                     (seq-find (lambda (b) (get-buffer-window b)) bufs))))
         (idx (and cur (cl-position cur bufs))))
    (when (zerop n) (user-error "No Claude running"))
    (let* ((next (if idx (mod (+ idx dir) n) (if (> dir 0) 0 (1- n))))
           (buf (nth next bufs)))
      (ghostel-claude--show-here buf)
      (message "Claude %d/%d: %s" (1+ next) n (or (ghostel-claude-workspace--title buf) (buffer-name buf))))))

;;;###autoload
(defun ghostel-claude-next ()
  "Show the next running Claude (by project, then start order), wrapping around."
  (interactive)
  (ghostel-claude--cycle 1))

;;;###autoload
(defun ghostel-claude-prev ()
  "Show the previous running Claude (by project, then start order), wrapping around."
  (interactive)
  (ghostel-claude--cycle -1))

;;;###autoload
(defun ghostel-claude-jump ()
  "Switch to a running Claude by name, or start one.
Candidates are the running Claudes (needing you first), then
\"＋ New Claude…\", which asks for a project and then for a new or earlier
session.  Never changes tab: use it from the agents tab as a control center."
  (interactive)
  (let* ((new "＋ New Claude…")
         (cands (ghostel-claude--switch-candidates))
         (choice (completing-read
                  "Claude: "
                  (lambda (str pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity)
                                   (cycle-sort-function . identity))
                      (complete-with-action action (append cands (list new)) str pred)))
                  nil t nil nil (caar cands))))
    (if-let* ((buf (cdr (assoc choice cands))))
        (ghostel-claude--show-here buf)
      (let* ((root (expand-file-name
                    (completing-read "Project: " (ghostel-claude--project-roots) nil nil)))
             (id (ghostel-claude--pick-session root)))
        (ghostel-claude--show-here (ghostel-claude--open-session root id))))))

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
  "Jump to the tab where the Claude at point is shown, else the project's tab.
The project's tab is the one named after it (\"clearcompany\" for
\"clearcompany.feature-X\")."
  (interactive)
  (let* ((project (ghostel-claude-agents--project-at-point))
         (buf (get-text-property (line-beginning-position) 'ghostel-claude-agent))
         (here (ghostel-claude-workspace--agents-tab-name))
         (tab (or (and buf (car (remove here (ghostel-claude-workspace--tabs buf))))
                  (seq-find (lambda (n) (ghostel-claude--tab-matches-base n project))
                            (remove here (mapcar (lambda (tb) (alist-get 'name tb))
                                                 (funcall tab-bar-tabs-function)))))))
    (unless tab (user-error "No tab named after %s" project))
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

;; Keep the sidebar's ▶ marker in step with where you are, without waiting for the 1 s tick.
(defun ghostel-claude-workspace--on-window-change (&rest _)
  "Redraw the sidebar (cheap; only if something changed) after a window/buffer change."
  (when (get-buffer ghostel-claude-workspace--buffer-name)
    (ghostel-claude-workspace--refresh)))
(add-hook 'window-selection-change-functions #'ghostel-claude-workspace--on-window-change)
(add-hook 'window-buffer-change-functions #'ghostel-claude-workspace--on-window-change)

;; Claude buffers that predate (re)loading this file: follow their title and save session bookmarks too.
;; Number the ones without a creation order, oldest process first.
(dolist (b (sort (seq-filter (lambda (b)
                               (and (string-prefix-p "*claude:" (buffer-name b))
                                    (ghostel-claude--live-p b)
                                    (null (buffer-local-value 'ghostel-claude--seq b))))
                             (buffer-list))
                 (lambda (a b) (< (or (buffer-local-value 'ghostel--pid a) 0)
                                  (or (buffer-local-value 'ghostel--pid b) 0)))))
  (with-current-buffer b (setq-local ghostel-claude--seq (cl-incf ghostel-claude--counter))))
(dolist (b (buffer-list))
  (when (and (string-prefix-p "*claude:" (buffer-name b))
             (ghostel-claude--live-p b))
    (cond ((buffer-local-value 'ghostel-claude--base b)
           (with-current-buffer b
             (setq-local bookmark-make-record-function #'ghostel-claude--bookmark-make-record)))
          ((string-match "\\`\\*claude:\\([^*:]+\\)\\*\\(<[0-9]+>\\)?\\'" (buffer-name b))
           (ghostel-claude--setup-buffer b (match-string 1 (buffer-name b)))
           (with-current-buffer b
             (when (fboundp 'ghostel--update-title) (ghostel--update-title)))))))

;; The sidebar side window sets `window-preserved-size' (preserve-size).  If its buffer was dead
;; when an activity was saved, activities stored a nil buffer name and restoring it called
;; (get-buffer nil), which signals (the debugger opens under `debug-on-error').  Make both
;; directions tolerate a missing buffer by dropping the parameter.
(with-eval-after-load 'activities
  (defvar activities-window-parameters-translators)
  (setf (alist-get 'window-preserved-size activities-window-parameters-translators)
        (list (cons 'serialize
                    (lambda (v)
                      (pcase v
                        (`(,b ,d ,sz) (and (bufferp b) (buffer-live-p b)
                                           (list (buffer-name b) d sz))))))
              (cons 'deserialize
                    (lambda (v)
                      (pcase v
                        (`(,n ,d ,sz) (when-let* ((b (and (stringp n) (get-buffer n))))
                                        (list b d sz)))))))))

(provide 'ghostel-claude)
;;; ghostel-claude.el ends here
