;;; gh-inbox-notify.el --- Background polling, toasts and Taskwarrior sync  -*- lexical-binding: t; -*-

;;; Commentary:

;; `gh-inbox-notify-mode' keeps `gh-inbox' fresh without you looking at it:
;;
;;  - polls GitHub every `gh-inbox-notify-interval' seconds,
;;  - shows a Windows toast (winnotify) and an echo-area line when something
;;    NEW needs you (review requested, changes requested, mention, CI red on
;;    your PR, PR ready to merge),
;;  - exposes a count for the status area (`gh-inbox-notify-status-string'),
;;  - optionally mirrors review requests into Taskwarrior, so reviews sit in
;;    the same list as the rest of your work and close themselves when the
;;    request goes away.
;;
;; The first poll after starting only records what is already there, so
;; starting Emacs never produces a burst of toasts.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'gh-inbox)

;;;; Customization

(defcustom gh-inbox-notify-interval 600
  "Seconds between background polls."
  :type 'integer
  :group 'gh-inbox)

(defcustom gh-inbox-notify-max-idle 1800
  "Skip background polls once Emacs has been idle this many seconds."
  :type 'integer
  :group 'gh-inbox)

(defcustom gh-inbox-notify-tags '(review re-review changes mention assigned ci ready)
  "Tags that raise a notification when they newly appear on an item."
  :type '(repeat symbol)
  :group 'gh-inbox)

(defcustom gh-inbox-notify-toast-program "winnotify"
  "Program showing a desktop toast: PROGRAM TITLE BODY [URL].
When it is not found, only the echo area is used."
  :type 'string
  :group 'gh-inbox)

(defcustom gh-inbox-notify-task-sync nil
  "When non-nil, mirror review requests into Taskwarrior."
  :type 'boolean
  :group 'gh-inbox)

(defcustom gh-inbox-notify-task-command '("task")
  "Taskwarrior command as a list (program and leading arguments)."
  :type '(repeat string)
  :group 'gh-inbox)

(defcustom gh-inbox-notify-task-project "Work.ClearCo"
  "Taskwarrior project for synced tasks."
  :type 'string
  :group 'gh-inbox)

(defcustom gh-inbox-notify-task-bucket "next"
  "GTD `type' for synced tasks (see `taskwarrior-gtd-buckets')."
  :type 'string
  :group 'gh-inbox)

(defcustom gh-inbox-notify-task-tag "ghreview"
  "Tag on tasks created from GitHub; only these are ever auto-completed."
  :type 'string
  :group 'gh-inbox)

;;;; Detecting what is new

(defvar gh-inbox-notify--seen nil
  "Hash table of \"URL TAG\" keys already announced, or nil before the first poll.")

(defun gh-inbox-notify--keys (items)
  "Alist (KEY . ITEM-AND-TAG) of alertable tags currently on ITEMS."
  (let (out)
    (dolist (it items)
      (unless (gh-inbox--dismissed-p it)
        (dolist (tg (gh-inbox-item-tags it))
          (when (memq (car tg) gh-inbox-notify-tags)
            (push (cons (format "%s %s" (gh-inbox-item-url it) (car tg))
                        (cons it (car tg)))
                  out)))))
    (nreverse out)))

(defun gh-inbox-notify--new (items)
  "Return the (ITEM . TAG) pairs in ITEMS not announced before; mark them seen.
The first call only primes the table and returns nil."
  (let* ((keys (gh-inbox-notify--keys items))
         (first (null gh-inbox-notify--seen))
         (seen (or gh-inbox-notify--seen
                   (setq gh-inbox-notify--seen (make-hash-table :test #'equal))))
         (new nil))
    (dolist (k keys)
      (unless (gethash (car k) seen)
        (puthash (car k) t seen)
        (unless first (push (cdr k) new))))
    ;; Forget tags that went away so they can alert again if they return.
    (let ((live (make-hash-table :test #'equal)))
      (dolist (k keys) (puthash (car k) t live))
      (maphash (lambda (k _) (unless (gethash k live) (remhash k seen))) seen))
    (nreverse new)))

(defun gh-inbox-notify--describe (pair)
  "One-line description of (ITEM . TAG) PAIR."
  (let ((it (car pair)) (tag (cdr pair)))
    (format "%s %s#%s %s"
            (pcase tag
              ('review "Review requested:") ('re-review "New commits since your review:")
              ('changes "Changes requested:") ('mention "You were mentioned:")
              ('assigned "Assigned to you:") ('ci "CI failing:")
              ('ready "Ready to merge:") (_ (symbol-name tag)))
            (gh-inbox--short-repo (gh-inbox-item-repo it))
            (gh-inbox-item-number it)
            (or (gh-inbox-item-title it) ""))))

(defun gh-inbox-notify--toast (title body url)
  "Show a desktop toast with TITLE, BODY, clicking opens URL."
  (when-let* ((prog (executable-find gh-inbox-notify-toast-program)))
    (apply #'start-process "gh-inbox-toast" nil prog
           (delq nil (list title body url)))))

(defun gh-inbox-notify--announce (pairs)
  "Tell the user about new (ITEM . TAG) PAIRS."
  (when pairs
    (message "GitHub: %s" (string-join (mapcar #'gh-inbox-notify--describe pairs) " | "))
    (let ((first (car pairs)))
      (gh-inbox-notify--toast
       (if (cdr pairs)
           (format "GitHub: %d new" (length pairs))
         "GitHub")
       (mapconcat #'gh-inbox-notify--describe (seq-take pairs 3) "\n")
       (gh-inbox-item-url (car first))))))

;;;; Status string

(defun gh-inbox-notify-count ()
  "Number of undismissed items that need you."
  (seq-count (lambda (it)
               (and (gh-inbox-item-tags it) (not (gh-inbox--dismissed-p it))))
             gh-inbox-items))

(defun gh-inbox-notify-status-string ()
  "Short status like \"GH 3\" (plain text), or nil when nothing needs you."
  (let ((n (gh-inbox-notify-count)))
    (when (> n 0) (format "GH %d" n))))

(defvar gh-inbox-notify-mode-line-string ""
  "Propertized string kept up to date for `global-mode-string'.")
(put 'gh-inbox-notify-mode-line-string 'risky-local-variable t)

(defun gh-inbox-notify--update-mode-line ()
  "Refresh `gh-inbox-notify-mode-line-string'."
  (setq gh-inbox-notify-mode-line-string
        (if-let* ((s (gh-inbox-notify-status-string)))
            (propertize (concat " " s)
                        'face 'gh-inbox-tag-action
                        'mouse-face 'highlight
                        'help-echo "GitHub items that need you (mouse-1: open inbox)"
                        'local-map (let ((m (make-sparse-keymap)))
                                     (define-key m [mode-line mouse-1] #'gh-inbox)
                                     (define-key m [tab-bar mouse-1] #'gh-inbox)
                                     m))
          ""))
  (force-mode-line-update t))

;;;; Taskwarrior

(defun gh-inbox-notify--task-key (item)
  "Stable key identifying ITEM in task descriptions."
  (format "%s#%s" (gh-inbox-item-repo item) (gh-inbox-item-number item)))

(defun gh-inbox-notify--task (&rest args)
  "Run Taskwarrior with ARGS; return (EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((code (apply #'call-process (car gh-inbox-notify-task-command) nil t nil
                       (append (cdr gh-inbox-notify-task-command)
                               '("rc.confirmation=no" "rc.verbose=nothing"
                                 "rc.json.array=on" "rc.bulk=0")
                               args))))
      (cons code (buffer-string)))))

(defun gh-inbox-notify--tracked ()
  "Alist (KEY UUID . AUTO-CLOSE) of pending tasks created from GitHub."
  (let* ((res (gh-inbox-notify--task (concat "+" gh-inbox-notify-task-tag)
                                     "status:pending" "export"))
         (tasks (and (eq (car res) 0) (gh-inbox--parse (cdr res)))))
    (delq nil
          (mapcar (lambda (tk)
                    (let ((d (alist-get 'description tk)))
                      (when (and d (string-match "\\`\\[gh \\([^]]+\\)\\]" d))
                        ;; (KEY UUID . AUTO-CLOSE): only "Review:" tasks may be
                        ;; completed automatically; follow-ups are yours to close.
                        (cons (match-string 1 d)
                              (cons (alist-get 'uuid tk)
                                    (string-match-p "\\`\\[gh [^]]+\\] Review: " d))))))
                  tasks))))

(defun gh-inbox-notify--add-task (item &optional prefix)
  "Create a task for ITEM titled PREFIX (default \"Review\").\nReturn t on success."
  (let* ((desc (format "[gh %s] %s: %s" (gh-inbox-notify--task-key item)
                       (or prefix "Review") (or (gh-inbox-item-title item) "")))
         (res (gh-inbox-notify--task
               "add"
               (concat "project:" gh-inbox-notify-task-project)
               (concat "type:" gh-inbox-notify-task-bucket)
               (concat "+" gh-inbox-notify-task-tag)
               "--" desc)))
    (when (eq (car res) 0)
      ;; +LATEST is the task just added.
      (gh-inbox-notify--task "+LATEST" "annotate" (gh-inbox-item-url item))
      t)))

(defun gh-inbox-notify-sync-tasks (&optional items)
  "Mirror review requests in ITEMS into Taskwarrior.
Creates a task per review request that has none; completes tasks (only
those carrying `gh-inbox-notify-task-tag') whose request is gone, but only
after a fetch that finished without errors."
  (interactive)
  (let* ((items (or items gh-inbox-items))
         (wanted (seq-filter
                  (lambda (it)
                    (seq-intersection '(review) (mapcar #'car (gh-inbox-item-tags it))))
                  items))
         (tracked (gh-inbox-notify--tracked))
         (wanted-keys (mapcar #'gh-inbox-notify--task-key wanted))
         (added 0) (closed 0))
    (dolist (it wanted)
      (unless (assoc (gh-inbox-notify--task-key it) tracked)
        (when (gh-inbox-notify--add-task it) (cl-incf added))))
    (when gh-inbox--fetch-clean
      (dolist (tr tracked)
        (unless (or (member (car tr) wanted-keys) (not (cddr tr)))
          (when (eq 0 (car (gh-inbox-notify--task (cadr tr) "done")))
            (cl-incf closed)))))
    (when (or (> added 0) (> closed 0))
      (message "gh-inbox: tasks +%d, done %d" added closed))
    (cons added closed)))

(defun gh-inbox-notify-task (item)
  "Create a Taskwarrior task for ITEM unless one exists."
  (interactive (list (gh-inbox--item)))
  (if (assoc (gh-inbox-notify--task-key item) (gh-inbox-notify--tracked))
      (message "Already tracked: %s" (gh-inbox-notify--task-key item))
    (if (gh-inbox-notify--add-task
         item (if (memq 'review (mapcar #'car (gh-inbox-item-tags item)))
                  "Review" "Follow up"))
        (message "Task created for %s" (gh-inbox-notify--task-key item))
      (message "Could not create task (is `task' working?)"))))

;;;; The mode

(defvar gh-inbox-notify--timer nil)

(defun gh-inbox-notify--on-refresh ()
  "Run after each fetch: announce news, update status, sync tasks."
  (gh-inbox-notify--announce (gh-inbox-notify--new gh-inbox-items))
  (gh-inbox-notify--update-mode-line)
  (when gh-inbox-notify-task-sync
    (with-demoted-errors "gh-inbox task sync: %S"
      (gh-inbox-notify-sync-tasks))))

(defun gh-inbox-notify--poll ()
  "Timer function: fetch quietly.\nSkipped when you have been away or the API budget is low."
  (unless (or (and gh-inbox--rate-remaining (< gh-inbox--rate-remaining 200))
              (let ((idle (current-idle-time)))
                (and idle (> (float-time idle) gh-inbox-notify-max-idle))))
    (gh-inbox-fetch)))

;;;###autoload
(define-minor-mode gh-inbox-notify-mode
  "Poll GitHub in the background and announce what needs you."
  :global t
  :group 'gh-inbox
  (when gh-inbox-notify--timer
    (cancel-timer gh-inbox-notify--timer)
    (setq gh-inbox-notify--timer nil))
  (remove-hook 'gh-inbox-refresh-hook #'gh-inbox-notify--on-refresh)
  (if gh-inbox-notify-mode
      (progn
        (add-hook 'gh-inbox-refresh-hook #'gh-inbox-notify--on-refresh)
        (unless (member '(:eval gh-inbox-notify-mode-line-string) global-mode-string)
          (setq global-mode-string
                (append (or global-mode-string '(""))
                        '((:eval gh-inbox-notify-mode-line-string)))))
        (setq gh-inbox-notify--timer
              (run-at-time 20 gh-inbox-notify-interval #'gh-inbox-notify--poll)))
    (setq global-mode-string
          (delete '(:eval gh-inbox-notify-mode-line-string) global-mode-string))))

(provide 'gh-inbox-notify)
;;; gh-inbox-notify.el ends here
