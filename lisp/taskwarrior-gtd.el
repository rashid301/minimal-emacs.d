;; taskwarrior-gtd.el --- Mu4e-style GTD interface for Taskwarrior -*- lexical-binding: t; -*-
;;
;; Keywords: taskwarrior, gtd, productivity
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;;
;; A single-buffer GTD interface for Taskwarrior. All views are just filters
;; on the same task list (type:inbox, type:next, etc.). Search is the only
;; special case.
;;
;;; Code:

(require 'json)
(require 'tabulated-list)
(require 'subr-x)

;; ---------------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------------

(defgroup taskwarrior-gtd nil
  "Single-buffer GTD interface for Taskwarrior."
  :group 'applications)

(defcustom taskwarrior-gtd-executable "task"
  "Path to the task executable."
  :type 'string
  :group 'taskwarrior-gtd)

(defcustom taskwarrior-gtd-taskrc nil
  "Path to .taskrc file, or nil to use default."
  :type '(choice (const :tag "Default" nil)
                 (string :tag "Path"))
  :group 'taskwarrior-gtd)

(defcustom taskwarrior-gtd-buckets
  '("inbox" "next" "waiting" "someday" "cal")
  "GTD type values available for task movement."
  :type '(repeat string)
  :group 'taskwarrior-gtd)

(defcustom taskwarrior-gtd-filters
  '(("in"      . "type:inbox")
    ("next"    . "type:next")
    ("waiting" . "type:waiting")
    ("someday" . "type:someday")
    ("cal"     . "type:cal")
    ("all"     . ""))
  "Alist of filter names and their Taskwarrior filter strings.
Empty string means no filter (all pending tasks)."
  :type '(alist :key-type string :value-type string)
  :group 'taskwarrior-gtd)

;; ---------------------------------------------------------------------------
;; Faces
;; ---------------------------------------------------------------------------

(defface taskwarrior-gtd-header-line
  '((t :inherit font-lock-keyword-face :weight bold :height 1.2))
  "Header line showing current filter and counts.")

(defface taskwarrior-gtd-hint
  '((t :inherit font-lock-comment-face))
  "Shortcut hints in the header line.")

(defface taskwarrior-gtd-overdue
  '((t :inherit font-lock-warning-face :weight bold))
  "Overdue dates in the list view.")

(defface taskwarrior-gtd-due-soon
  '((t :inherit font-lock-keyword-face :weight bold))
  "Due dates within a week in the list view.")

(defface taskwarrior-gtd-id
  '((t :inherit font-lock-constant-face))
  "Task IDs in the list view.")

(defface taskwarrior-gtd-description
  '((t :inherit default))
  "Task descriptions in the list view.")

(defface taskwarrior-gtd-tag
  '((t :inherit font-lock-builtin-face :weight bold))
  "Tags in the list view.")

(defface taskwarrior-gtd-project
  '((t :inherit font-lock-string-face))
  "Project names in the list view.")

(defface taskwarrior-gtd-active
  '((t :inherit font-lock-keyword-face :weight bold :foreground "#00ff00"))
  "Active (started) task indicator in the list view.")

(defface taskwarrior-gtd-count
  '((t :inherit font-lock-warning-face :weight bold))
  "Task counts in the header.")

(defface taskwarrior-gtd-filter-name
  '((t :inherit font-lock-function-name-face :weight bold :underline t))
  "Current filter name in the header.")

(defvar taskwarrior-gtd-list-columns
  '(("ID" 6 taskwarrior-gtd--col-id)
    ("Description" 40 taskwarrior-gtd--col-description)
    ("Project" 12 taskwarrior-gtd--col-project)
    ("Due" 12 taskwarrior-gtd--col-due)
    ("Type" 6 taskwarrior-gtd--col-type)
    ("Diff" 4 taskwarrior-gtd--col-difficulty)
    ("Tags" 15 taskwarrior-gtd--col-tags)
    ("Recur" 8 taskwarrior-gtd--col-recur)))

;; ---------------------------------------------------------------------------
;; Internal state
;; ---------------------------------------------------------------------------

(defvar taskwarrior-gtd--buffer nil
  "The single GTD list buffer.")
(defvar taskwarrior-gtd--current-filter nil
  "Buffer-local: current filter name (e.g. \"next\").")
(defvar taskwarrior-gtd--tasks nil
  "Buffer-local: list of task alists for the current view.")
(defvar taskwarrior-gtd--search-filter nil
  "Buffer-local: custom search filter string, or nil to use report.")
(defvar taskwarrior-gtd--all-tasks nil
  "Buffer-local: cached full list of all pending tasks.")
(defvar taskwarrior-gtd--active-id nil
  "Buffer-local: cached active task ID string, or nil.")
(defvar taskwarrior-gtd--active-task nil
  "Buffer-local: cached active task alist, or nil.")

(defvar taskwarrior-gtd--last-refresh nil
  "Timestamp of the last task list refresh.")

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd--base-command ()
  "Return the base task command as a list of strings."
  (let ((cmd (list taskwarrior-gtd-executable)))
    (when taskwarrior-gtd-taskrc
      (push taskwarrior-gtd-taskrc (cdr cmd))
      (push "rc" (cdr cmd)))
    (nreverse cmd)))

(defun taskwarrior-gtd--run (args)
  "Run task with ARGS and return output string."
  (let* ((cmd (append (taskwarrior-gtd--base-command) args))
         (out (with-output-to-string
                (with-current-buffer standard-output
                  (apply #'call-process (car cmd) nil t nil (cdr cmd))))))
    out))

(defun taskwarrior-gtd--run-async (args &optional sentinel)
  (make-process
   :name "taskwarrior"
   :command (append (taskwarrior-gtd--base-command) args)
   :sentinel sentinel
   :buffer "*taskwarrior*"))

(defun taskwarrior-gtd--run-json (args)
  "Run task with ARGS and return parsed JSON."
  (let ((out (taskwarrior-gtd--run args)))
    (condition-case nil
        (json-parse-string out :object-type 'alist :array-type 'list)
      (error nil))))

(defun taskwarrior-gtd--fetch-all-tasks ()
  "Fetch all pending tasks from taskwarrior once."
  (let ((data (taskwarrior-gtd--run-json '("status:pending" "export"))))
    (if (and data (sequencep data)) data nil)))

(defun taskwarrior-gtd--match-filter (task filter)
  "Return non-nil if TASK matches the FILTER name (client-side)."
  (let ((filter-str (cdr (assoc filter taskwarrior-gtd-filters))))
    (cond
     ((string= filter-str "") t)
     ((string-prefix-p "type:" filter-str)
      (let ((wanted (substring filter-str 5))
            (actual (cdr (assoc 'type task))))
        (equal actual wanted)))
     (t nil))))

(defun taskwarrior-gtd--filter-tasks (filter)
  "Filter `taskwarrior-gtd--all-tasks' by FILTER name (client-side)."
  (seq-filter (lambda (t) (taskwarrior-gtd--match-filter t filter))
              (or taskwarrior-gtd--all-tasks '())))

(defun taskwarrior-gtd--search-tasks (filter)
  "Return tasks matching a raw Taskwarrior FILTER string."
  (let ((data (taskwarrior-gtd--run-json
               (append (split-string filter) (list "export")))))
    (if (and data (sequencep data)) data nil)))

(defun taskwarrior-gtd--get-task-at-point ()
  "Return the task alist for the row at point, or nil."
  (let ((id (tabulated-list-get-id)))
    (when id
      (cl-find-if (lambda (t) (equal (taskwarrior-gtd--task-id t) id))
                  taskwarrior-gtd--tasks))))

(defun taskwarrior-gtd--task-id (task)
  (number-to-string (or (cdr (assoc 'id task)) 0)))

(defun taskwarrior-gtd--task-uuid (task)
  (or (cdr (assoc 'uuid task)) ""))

(defun taskwarrior-gtd--task-description (task)
  (or (cdr (assoc 'description task)) ""))

(defun taskwarrior-gtd--task-project (task)
  (or (cdr (assoc 'project task)) ""))

(defun taskwarrior-gtd--task-due (task)
  (let ((due (cdr (assoc 'due task))))
    (if due (taskwarrior-gtd--format-date due) "")))

(defun taskwarrior-gtd--task-urgency (task)
  (number-to-string (or (cdr (assoc 'urgency task)) 0)))

(defun taskwarrior-gtd--task-tags (task)
  (let ((tags (cdr (assoc 'tags task))))
    (if tags (string-join (mapcar (lambda (t) (format "%s" t)) tags) ", ") "")))

(defun taskwarrior-gtd--format-date (date-str)
  "Format a Taskwarrior ISO date string to a human-readable form."
  (when (and date-str (stringp date-str) (length> date-str 7))
    (let* ((s (substring date-str 0 10))
           (date (condition-case nil
                     (if (string-match-p "-" s)
                         s
                       (format "%s-%s-%s"
                               (substring s 0 4)
                               (substring s 4 6)
                               (substring s 6 8)))
                   (error nil)))
           (task-dt (when date (parse-time-string date)))
           (days (when task-dt
                   (condition-case nil
                       (let* ((now-dt (decode-time))
                              (task-day (encode-time 12 0 0
                                                     (nth 3 task-dt)
                                                     (nth 4 task-dt)
                                                     (nth 5 task-dt)))
                              (now-day (encode-time 12 0 0
                                                    (nth 3 now-dt)
                                                    (nth 4 now-dt)
                                                    (nth 5 now-dt))))
                         (truncate (/ (float-time (time-subtract task-day now-day))
                                      86400.0)))
                     (error nil)))))
      (cond
       ((or (not date) (not days)) date-str)
       ((= days 0) "today")
       ((= days 1) "tomorrow")
       ((and days (> days 0) (<= days 7)) (format "in %dd" days))
       ((and days (> days 7)) date)
       ((= days -1) "1d ago")
       ((and days (< days 0)) (format "%dd ago" (- days)))
       (t date)))))

;; ---------------------------------------------------------------------------
;; Column formatters
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd--col-id (task)
  (let* ((id (taskwarrior-gtd--task-id task))
         (active-id (taskwarrior-gtd--get-active-task-id))
         (is-active (equal id active-id)))
    (if is-active
        (propertize (concat "▶ " id) 'face 'taskwarrior-gtd-active)
      (propertize id 'face 'taskwarrior-gtd-id))))

(defun taskwarrior-gtd--col-description (task)
  (let ((desc (taskwarrior-gtd--task-description task)))
    (propertize (if (> (length desc) 50) (concat (substring desc 0 47) "...") desc)
                'face 'taskwarrior-gtd-description)))

(defun taskwarrior-gtd--col-project (task)
  (let ((proj (taskwarrior-gtd--task-project task)))
    (if (string= proj "")
        ""
      (propertize proj 'face 'taskwarrior-gtd-project))))

(defun taskwarrior-gtd--col-due (task)
  (let ((due (taskwarrior-gtd--task-due task)))
    (cond
     ((string-match-p "ago" due)
      (propertize due 'face 'taskwarrior-gtd-overdue))
     ((or (string= due "today") (string= due "tomorrow"))
      (propertize due 'face 'taskwarrior-gtd-due-soon))
     ((string-match-p "^in [0-9]*d$" due)
      (propertize due 'face 'taskwarrior-gtd-due-soon))
     (t due))))

(defun taskwarrior-gtd--col-tags (task)
  (let ((tags (taskwarrior-gtd--task-tags task)))
    (if (string= tags "")
        ""
      (propertize tags 'face 'taskwarrior-gtd-tag))))

(defun taskwarrior-gtd--col-recur (task)
  (or (cdr (assoc 'recur task)) ""))

(defun taskwarrior-gtd--col-type (task)
  (let ((type (cdr (assoc 'type task))))
    (if type (propertize type 'face 'taskwarrior-gtd-tag) "")))

(defun taskwarrior-gtd--col-difficulty (task)
  (let ((diff (cdr (assoc 'difficulty task))))
    (if diff (propertize diff 'face 'taskwarrior-gtd-count) "")))

(defun taskwarrior-gtd--get-active-task-id ()
  "Return the cached active task ID. Use `taskwarrior-gtd--refresh-active-id' to update."
  taskwarrior-gtd--active-id)

(defun taskwarrior-gtd--refresh-active-id ()
  "Query taskwarrior and update the cached active task info."
  (let ((data (taskwarrior-gtd--run-json '("+ACTIVE" "export"))))
    (if (and data (sequencep data) (> (length data) 0))
        (let ((task (car data)))
          (setq taskwarrior-gtd--active-id (number-to-string (cdr (assoc 'id task)))
                taskwarrior-gtd--active-task task))
      (setq taskwarrior-gtd--active-id nil
            taskwarrior-gtd--active-task nil))))

(defun taskwarrior-gtd--sort-by-due (tasks)
  (sort (copy-sequence tasks)
        (lambda (a b)
          (let ((a-date (or (cdr (assoc 'due a))
                            (cdr (assoc 'scheduled a))
                            (cdr (assoc 'entry a))))
                (b-date (or (cdr (assoc 'due b))
                            (cdr (assoc 'scheduled b))
                            (cdr (assoc 'entry b)))))
            (cond
             ((and a-date b-date)
              (string< a-date b-date))
             (a-date t)
             (b-date nil)
             (t nil))))))

;; ---------------------------------------------------------------------------
;; Header line
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd-bookmark-handler (_bookmark)
  "Restore a taskwarrior-gtd bookmark."
  (taskwarrior-gtd)
  (get-buffer taskwarrior-gtd--buffer))

(defun taskwarrior-gtd-bookmark-make-record ()
  "Create a bookmark record for the GTD buffer."
  `("taskwarrior-gtd"
    (handler . taskwarrior-gtd-bookmark-handler)))

(add-hook 'gtd-list-mode-hook
          (lambda ()
            (setq-local bookmark-make-record-function
                        #'taskwarrior-gtd-bookmark-make-record)))

;; ---------------------------------------------------------------------------
;; Header line
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd--update-header-line ()
  "Update the header line with current filter and counts."
  (let* ((filter taskwarrior-gtd--current-filter)
         (count (length (or taskwarrior-gtd--tasks '())))
         (filter-str (propertize (or filter "all") 'face 'taskwarrior-gtd-filter-name))
         (count-str (propertize (format "%d" count) 'face 'taskwarrior-gtd-count))
         (active-id (taskwarrior-gtd--get-active-task-id))
        (active-str (if active-id
                          (let* ((task taskwarrior-gtd--active-task)
                                 (desc (cdr (assoc 'description task)))
                                 (proj (cdr (assoc 'project task)))
                                 (proj-str (if proj (format " [%s]" proj) "")))
                            (propertize (format " ▶ [%s] %s%s" active-id desc proj-str)
                                        'face 'taskwarrior-gtd-active))
                        ""))
         (refresh-str (if taskwarrior-gtd--last-refresh
                           (propertize (format " (updated %s)"
                                               (format-time-string "%H:%M:%S" taskwarrior-gtd--last-refresh))
                                       'face 'shadow)
                         ""))
          (header (concat " GTD [" filter-str "] " count-str " tasks" active-str refresh-str)))
     (setq header-line-format header)))

;; ---------------------------------------------------------------------------
;; List mode
;; ---------------------------------------------------------------------------

(defvar gtd-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "1") (lambda () (interactive) (taskwarrior-gtd-filter "in")))
    (define-key map (kbd "2") (lambda () (interactive) (taskwarrior-gtd-filter "next")))
    (define-key map (kbd "3") (lambda () (interactive) (taskwarrior-gtd-filter "waiting")))
    (define-key map (kbd "4") (lambda () (interactive) (taskwarrior-gtd-filter "someday")))
    (define-key map (kbd "5") (lambda () (interactive) (taskwarrior-gtd-filter "cal")))
    (define-key map (kbd "6") (lambda () (interactive) (taskwarrior-gtd-filter "all")))
    (define-key map (kbd "d") #'taskwarrior-gtd-action-complete)
    (define-key map (kbd "x") #'taskwarrior-gtd-action-delete)
    (define-key map (kbd "m") #'taskwarrior-gtd-action-move)
    (define-key map (kbd "e") #'taskwarrior-gtd-action-edit)
    (define-key map (kbd "a") #'taskwarrior-gtd-action-add)
    (define-key map (kbd "c") #'taskwarrior-gtd-action-add)
    (define-key map (kbd "gt") #'taskwarrior-gtd-action-jump)
    (define-key map (kbd "r") #'taskwarrior-gtd-refresh)
    (define-key map (kbd "q") #'taskwarrior-gtd-quit)
    (define-key map (kbd "u") #'taskwarrior-gtd-action-undo)
    (define-key map (kbd "t") #'taskwarrior-gtd-action-toggle-start)
    (define-key map (kbd "s") #'taskwarrior-gtd-action-search)
    map)
  "Keymap for `gtd-list-mode'.")

(with-eval-after-load 'evil
  (evil-make-overriding-map gtd-list-mode-map 'normal)
  (add-hook 'gtd-list-mode-hook #'evil-normalize-keymaps)
  (evil-define-key 'normal gtd-list-mode-map
    (kbd "q") #'taskwarrior-gtd-quit
    (kbd "gg") #'beginning-of-buffer
    (kbd "G") #'end-of-buffer
    (kbd "gt") #'taskwarrior-gtd-action-jump
    (kbd "e") #'taskwarrior-gtd-action-edit
    (kbd "t") #'taskwarrior-gtd-action-toggle-start))

(define-derived-mode gtd-list-mode tabulated-list-mode "GTD"
  "Single-buffer GTD list for Taskwarrior."
  (setq tabulated-list-padding 2)
  (taskwarrior-gtd--update-header-line))

;; ---------------------------------------------------------------------------
;; Core: filter and populate
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd-filter (filter)
  "Switch to FILTER view in the single GTD buffer."
  (interactive (list (completing-read "Filter: "
                                      (mapcar #'car taskwarrior-gtd-filters)
                                      nil t)))
  (let ((buf (or taskwarrior-gtd--buffer
                 (get-buffer-create "*gtd*"))))
    (with-current-buffer buf
      (unless (derived-mode-p 'gtd-list-mode)
        (gtd-list-mode))
      (unless taskwarrior-gtd--all-tasks
        (make-local-variable 'taskwarrior-gtd--all-tasks)
        (setq taskwarrior-gtd--all-tasks (taskwarrior-gtd--fetch-all-tasks))
        (taskwarrior-gtd--refresh-active-id))
      (make-local-variable 'taskwarrior-gtd--current-filter)
      (setq taskwarrior-gtd--current-filter filter)
      (make-local-variable 'taskwarrior-gtd--search-filter)
      (setq taskwarrior-gtd--search-filter nil)
      (taskwarrior-gtd--populate)
      (tabulated-list-print t)
      (taskwarrior-gtd--update-header-line))
    (setq taskwarrior-gtd--buffer buf)
    (switch-to-buffer buf)))

(defun taskwarrior-gtd--populate ()
  "Populate the current buffer with tasks for the current filter."
  (setq taskwarrior-gtd--last-refresh (current-time))
  (let* ((filter taskwarrior-gtd--current-filter)
         (tasks (if taskwarrior-gtd--search-filter
                    (taskwarrior-gtd--search-tasks taskwarrior-gtd--search-filter)
                  (taskwarrior-gtd--filter-tasks filter)))
         (tasks (taskwarrior-gtd--sort-by-due tasks))
         (col-specs taskwarrior-gtd-list-columns)
         (cols (mapcar (lambda (s)
                         (list (car s) (cadr s) t))
                       col-specs)))
    (make-local-variable 'tabulated-list-format)
    (setq tabulated-list-format (vconcat cols))
    (tabulated-list-init-header)
    (make-local-variable 'taskwarrior-gtd--tasks)
    (setq taskwarrior-gtd--tasks tasks)
    (setq tabulated-list-entries
          (mapcar (lambda (task)
                    (list (taskwarrior-gtd--task-id task)
                          (vconcat (mapcar (lambda (col)
                                             (let ((fn (nth 2 col)))
                                               (if fn
                                                   (funcall fn task)
                                                 "")))
                                           col-specs))))
                  (or tasks '())))))

(defun taskwarrior-gtd-refresh (&optional preserve-pos)
  "Re-fetch tasks from taskwarrior and refresh the current view.
When PRESERVE-POS is non-nil, keep the cursor on the same row instead of
going to the top."
  (interactive)
  (when taskwarrior-gtd--buffer
    (with-current-buffer taskwarrior-gtd--buffer
      (setq taskwarrior-gtd--all-tasks (taskwarrior-gtd--fetch-all-tasks))
      (taskwarrior-gtd--refresh-active-id)
      (taskwarrior-gtd--populate)
      (tabulated-list-print t)
      (taskwarrior-gtd--update-header-line)
      (if preserve-pos
          (let ((target (line-number-at-pos)))
            (goto-char (point-min))
            (forward-line (1- target)))
        (goto-char (point-min)))
      (when (get-buffer-window taskwarrior-gtd--buffer)
        (with-selected-window (get-buffer-window taskwarrior-gtd--buffer)
          (recenter 0))))))

;; ---------------------------------------------------------------------------
;; Search
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd-action-search ()
  "Search tasks using a Taskwarrior filter expression.
E.g: project:Home due:today +urgent \"buy milk\""
  (interactive)
  (let ((filter (read-string "Search (taskwarrior filter): ")))
    (when (length> filter 0)
      (let ((buf (or taskwarrior-gtd--buffer
                     (get-buffer-create "*gtd*"))))
        (with-current-buffer buf
          (unless (derived-mode-p 'gtd-list-mode)
            (gtd-list-mode))
          (make-local-variable 'taskwarrior-gtd--current-filter)
          (setq taskwarrior-gtd--current-filter "search")
          (make-local-variable 'taskwarrior-gtd--search-filter)
          (setq taskwarrior-gtd--search-filter filter)
          (taskwarrior-gtd--populate)
          (tabulated-list-print t)
          (taskwarrior-gtd--update-header-line))
        (setq taskwarrior-gtd--buffer buf)
        (switch-to-buffer buf)))))

;; ---------------------------------------------------------------------------
;; Actions
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd-action-toggle-start ()
  "Toggle start/stop on the task at point."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let* ((id (taskwarrior-gtd--task-id task))
             (desc (taskwarrior-gtd--task-description task))
             (active-id (taskwarrior-gtd--get-active-task-id)))
        (cond
         ((equal id active-id)
           (taskwarrior-gtd--run (list id "stop"))
           (message "Task %s stopped" id)
           (taskwarrior-gtd-refresh t))
          (active-id
            (let ((active-desc (cdr (assoc 'description taskwarrior-gtd--active-task))))
             (when (y-or-n-p (format "Task %s is active (%s). Stop it and start task %s (%s)? "
                                     active-id (or active-desc "?") id desc))
               (taskwarrior-gtd--run (list active-id "stop"))
               (taskwarrior-gtd--run (list id "start"))
               (message "Stopped task %s, started task %s" active-id id)
               (taskwarrior-gtd-refresh t))))
          (t
           (taskwarrior-gtd--run (list id "start"))
           (message "Task %s started" id)
           (taskwarrior-gtd-refresh t)))))))

(defun taskwarrior-gtd-action-complete ()
  "Mark the task at point as done."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let* ((id (taskwarrior-gtd--task-id task))
             (desc (taskwarrior-gtd--task-description task)))
        (when (y-or-n-p (format "Complete task %s: %s? " id desc))
          (taskwarrior-gtd--run (list id "done"))
          (message "Task %s marked done" id)
          (taskwarrior-gtd-refresh))))))

(defun taskwarrior-gtd-action-delete ()
  "Delete the task at point after confirmation."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let* ((id (taskwarrior-gtd--task-id task))
             (desc (taskwarrior-gtd--task-description task)))
        (when (y-or-n-p (format "Delete task %s: %s? " id desc))
          (shell-command (format "echo yes | %s %s delete" taskwarrior-gtd-executable id))
          (message "Task %s deleted" id)
          (taskwarrior-gtd-refresh))))))

(defun taskwarrior-gtd-action-move ()
  "Move the task at point to a different GTD bucket."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let* ((id (taskwarrior-gtd--task-id task))
             (bucket (completing-read "Move to bucket: "
                                      taskwarrior-gtd-buckets
                                      nil t)))
        (when (length> bucket 0)
          (taskwarrior-gtd--run (list id "modify" (format "type:%s" bucket)))
         (message "Task %s moved to type:%s" id bucket)
           (taskwarrior-gtd-refresh t))))))

(defun taskwarrior-gtd-action-add (&optional initial-input)
  "Add a new task, supporting native project, tag, and date syntax."
  (interactive)
  (let ((raw-input (read-string "Task input (supports project:X, +tag, due:Y): " initial-input)))
    (when (length> raw-input 0)
      (let* ((bucket (completing-read "Bucket (default inbox): "
                                      taskwarrior-gtd-buckets
                                      nil nil "inbox"))
             (parsed-args (split-string-and-unquote raw-input))
             (final-cmd (append '("add") parsed-args (list (format "type:%s" bucket)))))
        (taskwarrior-gtd--run final-cmd)
        (message "Added task: %s (type:%s)" raw-input bucket)
        (taskwarrior-gtd-refresh)))))

(defun taskwarrior-gtd-action-undo ()
  "Undo the last taskwarrior operation."
  (interactive)
  (let ((out (shell-command-to-string (format "%s undo" taskwarrior-gtd-executable))))
    (if (string-match-p "Nothing to undo" out)
        (message "Nothing to undo")
      (let ((buf (get-buffer-create "*gtd-undo*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert out)))
        (pop-to-buffer buf)
        (when (y-or-n-p "Revert these changes? (not reversible)")
          (shell-command (format "echo yes | %s undo" taskwarrior-gtd-executable))
          (kill-buffer buf)
          (message "Last change reverted")
          (taskwarrior-gtd-refresh))))))

(defun taskwarrior-gtd-action-edit ()
  "Edit the task at point using taskwarrior's native editor."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let ((id (taskwarrior-gtd--task-id task)))
        (taskwarrior-gtd--run-async
         (list id "edit")
         (lambda (_proc _event)
            (message "Task %s modified" id)
            (taskwarrior-gtd-refresh t)))))))

(defun taskwarrior-gtd-action-jump ()
  "Jump to a task by ID, searching across all tasks if needed."
  (interactive)
  (let ((id (read-string "Task ID: ")))
    (when (length> id 0)
      (if (not (derived-mode-p 'gtd-list-mode))
          (message "Open a GTD view first")
        (let ((found nil))
          (save-excursion
            (goto-char (point-min))
            (while (not (or found (eobp)))
              (when (equal (tabulated-list-get-id) id)
                (setq found t))
              (unless found (forward-line 1))))
          (if found
              (message "Task %s found" id)
            (taskwarrior-gtd-filter "all")
            (save-excursion
              (goto-char (point-min))
              (while (not (or found (eobp)))
                (when (equal (tabulated-list-get-id) id)
                  (setq found t))
                (unless found (forward-line 1))))
            (unless found
              (message "Task %s not found" id))))))))

;; ---------------------------------------------------------------------------
;; SPC m action minor mode
;; ---------------------------------------------------------------------------

(defvar gtd-action-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'taskwarrior-gtd-action-complete)
    (define-key map (kbd "x") #'taskwarrior-gtd-action-delete)
    (define-key map (kbd "m") #'taskwarrior-gtd-action-move)
    (define-key map (kbd "e") #'taskwarrior-gtd-action-edit)
    (define-key map (kbd "a") #'taskwarrior-gtd-action-add)
    (define-key map (kbd "j") #'taskwarrior-gtd-action-jump)
    (define-key map (kbd "t") #'taskwarrior-gtd-action-toggle-start)
    (define-key map (kbd "r") #'taskwarrior-gtd-refresh)
    (define-key map (kbd "u") #'taskwarrior-gtd-action-undo)
    (define-key map (kbd "s") #'taskwarrior-gtd-action-search)
    map)
  "Keymap for `gtd-action-minor-mode'.")

(define-minor-mode gtd-action-minor-mode
  "Minor mode for GTD task actions on `SPC m'."
  :lighter " GTD-A"
  :keymap gtd-action-minor-mode-map)

;; ---------------------------------------------------------------------------
;; Entry / quit
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd ()
  "Open the Taskwarrior GTD buffer."
  (interactive)
  (taskwarrior-gtd-filter "all"))

(defun taskwarrior-gtd-quit ()
  "Quit the GTD buffer."
  (interactive)
  (when taskwarrior-gtd--buffer
    (kill-buffer taskwarrior-gtd--buffer)
    (setq taskwarrior-gtd--buffer nil))
  ;; (when (> (length (window-list)) 1)
  ;;   (delete-other-windows))
  )

(defun taskwarrior-gtd-capture ()
  "Add a task with an org link to current context."
  (interactive)
  (require 'org)
  (let* ((link (org-store-link nil))
         (prefill (if link (format " %s" link) "")))
    (taskwarrior-gtd-action-add prefill)))

;; ---------------------------------------------------------------------------
;; Provide
;; ---------------------------------------------------------------------------

(provide 'taskwarrior-gtd)
;;; taskwarrior-gtd.el ends here
