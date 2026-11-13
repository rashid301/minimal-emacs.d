;;; ghostel-tasks.el --- Per-project long-running tasks in ghostel  -*- lexical-binding: t; -*-

;;; Commentary:

;; VS Code-style tasks for dev servers and watchers, run in ghostel.
;;
;; Tasks are declared centrally in `ghostel-tasks-projects', keyed by the
;; *repository* name, so every git worktree of a repo shares one entry:
;;
;;   (setq ghostel-tasks-projects
;;         '(("clearcompany"
;;            ("api" . "dotnet watch run")
;;            ("web" :command "npm run dev" :dir "src/web"))))
;;
;; A task is (NAME . COMMAND) or (NAME :command COMMAND [:dir SUBDIR]).
;; COMMAND is a shell string, or a list (PROGRAM ARG...) run without a shell.
;; Tasks run in the current worktree (plus :dir if given; an absolute :dir
;; is used as is).
;;
;; The repo key is the folder of the main checkout (from
;; `git rev-parse --git-common-dir'), falling back to the project folder.
;; If the current project has no entry, or with a prefix argument, you
;; pick a project from a list.
;;
;; Each task runs as the buffer's *process* (via `ghostel-exec'), not typed
;; into a shell.  So `process-live-p' really means the server is running,
;; and ghostel's bookmark handler respawns the same command when a
;; bookmarked task buffer is restored.  A task that exits keeps its buffer,
;; so its output stays readable.
;;
;; Buffers are named *task:WORKTREE:NAME*.  Starting is idempotent: a task
;; whose process is alive is left alone.
;;
;; Local directories only; remote terminals are not handled here.
;;
;; Commands: `ghostel-tasks-start-all', `ghostel-tasks-start',
;; `ghostel-tasks-stop', `ghostel-tasks-restart', `ghostel-tasks-switch'.

;;; Code:

(require 'project)
(require 'subr-x)
(require 'seq)

(declare-function ghostel-exec "ghostel")
(defvar ghostel--process)
(defvar ghostel-kill-buffer-on-exit)

(defcustom ghostel-tasks-projects nil
  "Tasks per repository.
Alist of (REPO . TASKS).  REPO is the main checkout's folder name, or an
absolute path to it.  Each task is (NAME . COMMAND) or
\(NAME :command COMMAND [:dir SUBDIR])."
  :type '(alist :key-type string :value-type sexp)
  :group 'ghostel)

(defcustom ghostel-tasks-shell-function #'ghostel-tasks--default-shell
  "Function mapping a shell command string to a list (PROGRAM ARG...)."
  :type 'function
  :group 'ghostel)

(defcustom ghostel-tasks-display-action nil
  "Display action used when a task starts, or nil to leave it hidden."
  :type '(choice (const :tag "Do not display" nil) sexp)
  :group 'ghostel)

(defun ghostel-tasks--default-shell (command)
  "Return argv running COMMAND through the platform shell."
  (if (eq system-type 'windows-nt)
      (list (or (executable-find "pwsh.exe") "powershell.exe")
            "-NoLogo" "-NoProfile" "-Command" command)
    (list (or (executable-find "sh") shell-file-name) "-c" command)))

(defun ghostel-tasks--root (&optional dir)
  "Return the project root for DIR (default `default-directory')."
  (let ((default-directory (or dir default-directory)))
    (if-let* ((pr (project-current)))
        (expand-file-name (project-root pr))
      (expand-file-name default-directory))))

(defun ghostel-tasks--project-name (root)
  "Return a short name for project ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun ghostel-tasks--repo-dir (root)
  "Return the main checkout directory of the repo containing ROOT, or nil.
Worktrees resolve to the repo they were created from."
  (let ((default-directory root))
    (with-temp-buffer
      (when (eq 0 (ignore-errors
                    (call-process "git" nil '(t nil) nil "rev-parse"
                                  "--path-format=absolute" "--git-common-dir")))
        (let ((common (string-trim (buffer-string))))
          (unless (string-empty-p common)
            (file-name-as-directory
             (file-name-directory (directory-file-name common)))))))))

(defun ghostel-tasks--keys (root)
  "Return candidate `ghostel-tasks-projects' keys for ROOT, best first."
  (let ((repo (ghostel-tasks--repo-dir root)))
    (delq nil (list (and repo (directory-file-name repo))
                    (and repo (ghostel-tasks--project-name repo))
                    (directory-file-name root)
                    (ghostel-tasks--project-name root)))))

(defun ghostel-tasks--project-key (root &optional ask)
  "Return the `ghostel-tasks-projects' key to use for ROOT.
Pick from the configured projects when ASK is non-nil or nothing matches."
  (unless ghostel-tasks-projects
    (user-error "`ghostel-tasks-projects' is empty"))
  (let ((hit (seq-find (lambda (k) (assoc k ghostel-tasks-projects))
                       (ghostel-tasks--keys root))))
    (if (and hit (not ask))
        hit
      (completing-read (format "Tasks for project (%s): "
                               (ghostel-tasks--project-name root))
                       (mapcar #'car ghostel-tasks-projects) nil t nil nil hit))))

(defun ghostel-tasks--spec (root &optional key)
  "Return the tasks for ROOT as a list of (NAME COMMAND DIR).
KEY is the `ghostel-tasks-projects' key; resolved from ROOT when nil."
  (mapcar
   (lambda (task)
     (let ((name (car task)) (rest (cdr task)))
       (if (keywordp (car-safe rest))
           (list name (plist-get rest :command) (plist-get rest :dir))
         (list name rest nil))))
   (cdr (assoc (or key (ghostel-tasks--project-key root))
               ghostel-tasks-projects))))

(defun ghostel-tasks--buffer-name (root name)
  "Return the buffer name for task NAME in worktree ROOT."
  (format "*task:%s:%s*" (ghostel-tasks--project-name root) name))

(defun ghostel-tasks--argv (command)
  "Return (PROGRAM . ARGS) for task COMMAND."
  (cond ((stringp command) (funcall ghostel-tasks-shell-function command))
        ((and (consp command) (stringp (car command))) command)
        (t (user-error "Bad task command: %S" command))))

(defun ghostel-tasks--running-p (buffer)
  "Return non-nil if BUFFER has a live ghostel process."
  (and (buffer-live-p buffer)
       (let ((p (buffer-local-value 'ghostel--process buffer)))
         (and p (process-live-p p)))))

(defun ghostel-tasks--start-one (root task)
  "Start TASK, a (NAME COMMAND DIR) entry, in worktree ROOT if not running.
Return the buffer."
  (require 'ghostel)
  (pcase-let* ((`(,name ,command ,dir) task)
               (bufname (ghostel-tasks--buffer-name root name))
               (buf (get-buffer-create bufname)))
    (unless (ghostel-tasks--running-p buf)
      (let ((argv (ghostel-tasks--argv command))
            (cwd (if dir (expand-file-name dir root) root)))
        ;; ghostel spawns in the buffer's own `default-directory', which
        ;; is fixed when the buffer is created, so set it explicitly.
        (with-current-buffer buf (setq default-directory cwd))
        (ghostel-exec buf (car argv) (cdr argv))
        ;; Keep the buffer when the task exits, so a crash leaves its
        ;; output to read instead of vanishing.
        (with-current-buffer buf
          (setq-local ghostel-kill-buffer-on-exit nil))
        (message "Started task %s" bufname)))
    (when ghostel-tasks-display-action
      (display-buffer buf ghostel-tasks-display-action))
    buf))

(defun ghostel-tasks--task-buffers (root)
  "Return the task buffers belonging to worktree ROOT."
  (let ((prefix (format "*task:%s:" (ghostel-tasks--project-name root))))
    (seq-filter (lambda (b) (string-prefix-p prefix (buffer-name b)))
                (buffer-list))))

(defun ghostel-tasks--interactive (prompt)
  "Return (NAME KEY) for an interactive command, asking PROMPT.
A prefix argument forces the project dropdown."
  (let* ((root (ghostel-tasks--root))
         (key (ghostel-tasks--project-key root current-prefix-arg))
         (spec (ghostel-tasks--spec root key)))
    (unless spec (user-error "No tasks declared for %s" key))
    (list (completing-read prompt (mapcar #'car spec) nil t) key)))

(defun ghostel-tasks--find (root name key)
  "Return the (NAME COMMAND DIR) task called NAME for ROOT and KEY."
  (or (assoc name (ghostel-tasks--spec root key))
      (user-error "No task %s" name)))

;;;###autoload
(defun ghostel-tasks-start-all (&optional ask dir)
  "Start every task for the current project, skipping running ones.
With prefix argument ASK, choose the project from a list.  DIR overrides
the worktree.  Idempotent, so it can run from
`activities-after-resume-functions'."
  (interactive "P")
  (let* ((root (ghostel-tasks--root dir))
         (key (ghostel-tasks--project-key root ask))
         (spec (ghostel-tasks--spec root key)))
    (unless spec (user-error "No tasks declared for %s" key))
    (dolist (task spec)
      (ghostel-tasks--start-one root task))))

;;;###autoload
(defun ghostel-tasks-start (name &optional key)
  "Start task NAME of project KEY (default: the current project)."
  (interactive (ghostel-tasks--interactive "Start task: "))
  (let ((root (ghostel-tasks--root)))
    (pop-to-buffer
     (ghostel-tasks--start-one root (ghostel-tasks--find root name key)))))

;;;###autoload
(defun ghostel-tasks-stop (name &optional _key)
  "Stop task NAME of the current worktree."
  (interactive (ghostel-tasks--interactive "Stop task: "))
  (let ((buf (get-buffer (ghostel-tasks--buffer-name (ghostel-tasks--root) name))))
    (if (ghostel-tasks--running-p buf)
        (delete-process (buffer-local-value 'ghostel--process buf))
      (message "Task %s is not running" name))))

;;;###autoload
(defun ghostel-tasks-restart (name &optional key)
  "Stop and start task NAME of project KEY (default: the current project)."
  (interactive (ghostel-tasks--interactive "Restart task: "))
  (let* ((root (ghostel-tasks--root))
         (task (ghostel-tasks--find root name key))
         (buf (get-buffer (ghostel-tasks--buffer-name root name))))
    (when buf
      (when (ghostel-tasks--running-p buf)
        (delete-process (buffer-local-value 'ghostel--process buf)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf)))
    (pop-to-buffer (ghostel-tasks--start-one root task))))

;;;###autoload
(defun ghostel-tasks-switch ()
  "Switch to one of the current worktree's task buffers."
  (interactive)
  (let* ((root (ghostel-tasks--root))
         (bufs (ghostel-tasks--task-buffers root)))
    (unless bufs (user-error "No task buffers for %s" root))
    (pop-to-buffer
     (completing-read
      "Task buffer: "
      (mapcar (lambda (b)
                (propertize (buffer-name b) 'face
                            (if (ghostel-tasks--running-p b) 'success 'shadow)))
              bufs)
      nil t))))

(provide 'ghostel-tasks)
;;; ghostel-tasks.el ends here
