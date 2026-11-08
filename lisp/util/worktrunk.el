;;; worktrunk.el --- Thin Emacs wrapper over the Worktrunk CLI (git-wt)  -*- lexical-binding: t; -*-

;;; Commentary:

;; List, switch/create and remove git worktrees through `git-wt'.
;; Worktrunk owns the folder naming (<repo>.<branch>) and its hooks, so
;; this file never builds paths itself: it asks `git-wt' to do the work and
;; reads the result back with `git-wt list --format json'.
;;
;; Entry points:
;;   `worktrunk-switch'  pick a worktree/branch, or type a new branch to create
;;   `worktrunk-remove'  remove a worktree (confirms first)
;;   `worktrunk-list'    return worktrees as a list of alists (for other code)
;;
;; With a prefix argument, the commands ask which project to act on instead
;; of using the current one.
;;
;; Glue lives in the hooks `worktrunk-after-switch-functions' and
;; `worktrunk-after-remove-functions'; each receives the worktree path.

;;; Code:

(require 'project)
(require 'json)
(require 'subr-x)

(defgroup worktrunk nil
  "Emacs front end for the Worktrunk CLI."
  :group 'tools)

(defcustom worktrunk-executable
  (if (eq system-type 'windows-nt) "git-wt" "wt")
  "Worktrunk executable.
On Windows this is `git-wt', because there `wt' is Windows Terminal.
Everywhere else it is `wt'."
  :type 'string)

(defcustom worktrunk-auto-approve-hooks nil
  "When non-nil, pass `-y' so Worktrunk runs hooks without prompting.
Emacs has no terminal for Worktrunk to prompt on, so hooks that need
approval will fail unless they were approved before or this is set.
Note that this also approves hooks defined by the repository itself."
  :type 'boolean)

(defcustom worktrunk-timeout 600
  "Seconds before an async `git-wt' call is killed."
  :type 'integer)

(defcustom worktrunk-after-switch-functions nil
  "Abnormal hook run after a successful switch/create.
Each function is called with the worktree path."
  :type 'hook)

(defcustom worktrunk-after-remove-functions nil
  "Abnormal hook run after a successful remove.
Each function is called with the removed worktree path."
  :type 'hook)

;;;; Process helpers

(defun worktrunk--args (root args)
  "Return full argument list for ROOT and ARGS."
  (append (list "-C" (expand-file-name root))
          (and worktrunk-auto-approve-hooks '("-y"))
          args))

(defun worktrunk--call (root &rest args)
  "Run `git-wt' synchronously in ROOT with ARGS and return stdout.
Signals an error with the output if the exit code is non-zero.
Only for fast read-only commands like `list'."
  (with-temp-buffer
    (let ((code (apply #'call-process worktrunk-executable nil
                       (list t nil) nil
                       (worktrunk--args root args))))
      (unless (eq code 0)
        (error "git-wt %s failed (%s): %s"
               (string-join args " ") code (string-trim (buffer-string))))
      (buffer-string))))

(defun worktrunk--run-async (root args on-success)
  "Run `git-wt' in ROOT with ARGS asynchronously.
Call ON-SUCCESS with no arguments when it exits 0.  Output goes to the
*worktrunk* buffer, which is shown on failure."
  (let* ((buf (get-buffer-create "*worktrunk*"))
         (default-directory (file-name-as-directory (expand-file-name root)))
         (command (cons worktrunk-executable (worktrunk--args root args))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n$ %s\n" (string-join command " ")))))
    (let ((proc (make-process
                 :name "worktrunk"
                 :buffer buf
                 :command command
                 :noquery t
                 :sentinel
                 (lambda (p _event)
                   (when (memq (process-status p) '(exit signal))
                     (if (and (eq (process-status p) 'exit)
                              (eq (process-exit-status p) 0))
                         (funcall on-success)
                       (display-buffer buf)
                       (message "git-wt %s failed; see *worktrunk*"
                                (car args))))))))
      (run-at-time worktrunk-timeout nil
                   (lambda ()
                     (when (process-live-p proc)
                       (kill-process proc)
                       (message "git-wt timed out after %ss" worktrunk-timeout))))
      (message "git-wt %s..." (car args))
      proc)))

;;;; Reading worktrees

(defun worktrunk--root (choose)
  "Return the project root to act on.
Prompt for one if CHOOSE is non-nil, else use the current project."
  (let ((dir (if choose
                 (project-prompt-project-dir)
               (project-root (project-current t)))))
    (expand-file-name dir)))

(defun worktrunk-list (root &optional branches)
  "Return worktrees of the repo at ROOT as a list of alists.
Each has keys `branch' (nil when detached), `path' (nil for a branch
without a worktree), `main' and `current'.  With BRANCHES, also include
local branches that have no worktree."
  (let* ((out (apply #'worktrunk--call root "list" "--format" "json"
                     (and branches '("--branches"))))
         (json (json-parse-string out :object-type 'alist
                                  :null-object nil :false-object nil)))
    (mapcar (lambda (item)
              (let ((wt (alist-get 'worktree item)))
                `((branch  . ,(alist-get 'branch item))
                  (path    . ,(alist-get 'path wt))
                  (main    . ,(alist-get 'main wt))
                  (current . ,(alist-get 'current wt)))))
            (alist-get 'items json))))

(defun worktrunk--label (item)
  "Completion label for worktree ITEM."
  (let ((branch (alist-get 'branch item))
        (path (alist-get 'path item)))
    (concat (or branch (format "(detached) %s" (file-name-nondirectory path)))
            (cond ((null path) "  [no worktree]")
                  ((alist-get 'main item) "  [main]")
                  ((alist-get 'current item) "  [current]")
                  (t "")))))

(defun worktrunk--find-path (root branch)
  "Return the worktree path for BRANCH in the repo at ROOT, or nil."
  (alist-get 'path
             (seq-find (lambda (i) (equal (alist-get 'branch i) branch))
                       (worktrunk-list root))))

;;;; Commands

;;;###autoload
(defun worktrunk-switch (&optional choose-project)
  "Switch to a worktree, creating it when the branch name is new.
Pick an existing entry, or type a new branch name to create one.  With
prefix argument CHOOSE-PROJECT, ask which project to use."
  (interactive "P")
  (let* ((root (worktrunk--root choose-project))
         (items (worktrunk-list root t))
         (table (mapcar (lambda (i) (cons (worktrunk--label i) i)) items))
         (input (completing-read
                 (format "Worktree (%s): "
                         (file-name-nondirectory (directory-file-name root)))
                 (mapcar #'car table)))
         (item (cdr (assoc input table)))
         (branch (if item (alist-get 'branch item) (string-trim input)))
         (create (null item))
         (base (and create
                    (string-trim
                     (read-string "Base branch (RET for default): ")))))
    (when (and item (null branch))
      (user-error "Detached worktree has no branch; open it directly instead"))
    (when (string-empty-p branch)
      (user-error "No branch given"))
    (worktrunk--run-async
     root
     (append (list "switch" branch "--no-cd")
             (and create '("--create"))
             (and base (not (string-empty-p base)) (list "--base" base)))
     (lambda ()
       (if-let ((path (worktrunk--find-path root branch)))
           (progn
             (message "Worktree ready: %s" path)
             (run-hook-with-args 'worktrunk-after-switch-functions path))
         (message "git-wt succeeded but no worktree found for %s" branch))))))

;;;###autoload
(defun worktrunk-remove (&optional choose-project)
  "Remove a worktree after confirming.
With prefix argument CHOOSE-PROJECT, ask which project to use."
  (interactive "P")
  (let* ((all (worktrunk-list (worktrunk--root choose-project)))
         ;; Run from the main worktree: a process started inside the
         ;; worktree being removed can lock it on Windows.
         (root (or (alist-get 'path (seq-find (lambda (i) (alist-get 'main i)) all))
                   (worktrunk--root choose-project)))
         (items (seq-remove (lambda (i) (alist-get 'main i)) all))
         (table (mapcar (lambda (i) (cons (worktrunk--label i) i)) items)))
    (unless table
      (user-error "No removable worktrees in %s" root))
    (let* ((item (cdr (assoc (completing-read "Remove worktree: "
                                              (mapcar #'car table) nil t)
                             table)))
           (path (alist-get 'path item))
           (target (or (alist-get 'branch item) path)))
      (when (yes-or-no-p (format "Remove worktree %s? " path))
        (worktrunk--run-async
         root (list "remove" target "--foreground")
         (lambda ()
           (message "Removed %s" path)
           (run-hook-with-args 'worktrunk-after-remove-functions path)))))))

(provide 'worktrunk)
;;; worktrunk.el ends here
