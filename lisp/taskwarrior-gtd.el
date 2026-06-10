;;; taskwarrior-gtd.el --- Mu4e-style GTD interface for Taskwarrior -*- lexical-binding: t; -*-
;;
;; Keywords: taskwarrior, gtd, productivity
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;;
;; A mu4e-inspired interface for Taskwarrior with GTD workflow views.
;; Uses existing .taskrc reports (in, next, waiting, someday, all).
;;
;;; Code:

(require 'json)
(require 'tabulated-list)
(require 'subr-x)

;; ---------------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------------

(defgroup taskwarrior-gtd nil
  "Mu4e-style GTD interface for Taskwarrior."
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

(defcustom taskwarrior-gtd-reports
  '(("in"      . "type:inbox status:pending")
    ("next"    . "type:next status:pending")
    ("waiting" . "type:waiting status:pending")
    ("someday" . "type:someday status:pending")
    ("cal"     . "type:cal status:pending")
    ("all"     . "status:pending"))
  "Alist of report names and their Taskwarrior filters."
  :type '(alist :key-type string :value-type string)
  :group 'taskwarrior-gtd)

;; ---------------------------------------------------------------------------
;; Faces
;; ---------------------------------------------------------------------------

(defface taskwarrior-gtd-title
  '((t :inherit font-lock-keyword-face :weight bold :height 1.3))
  "Title text in the dashboard.")

(defface taskwarrior-gtd-section-header
  '((t :inherit font-lock-function-name-face :weight bold))
  "Section headers in the dashboard.")

(defface taskwarrior-gtd-bucket-name
  '((t :inherit font-lock-type-face :weight bold :underline t))
  "Bucket names in the dashboard.")

(defface taskwarrior-gtd-count
  '((t :inherit font-lock-warning-face :weight bold))
  "Task counts in the dashboard.")

(defface taskwarrior-gtd-count-zero
  '((t :inherit font-lock-comment-face))
  "Zero counts in the dashboard.")

(defface taskwarrior-gtd-hint
  '((t :inherit font-lock-comment-face))
  "Shortcut hints in the dashboard.")

(defface taskwarrior-gtd-overdue
  '((t :inherit font-lock-warning-face :weight bold))
  "Overdue dates in the list view.")

(defface taskwarrior-gtd-due-soon
  '((t :inherit font-lock-doc-face :weight bold))
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

(defface taskwarrior-gtd-header
  '((t :inherit font-lock-keyword-face :weight bold :underline t))
  "Column headers in the list view.")

(defface taskwarrior-gtd-active
  '((t :inherit font-lock-keyword-face :weight bold :foreground "#00ff00"))
  "Active (started) task indicator in the list view.")

(defface taskwarrior-gtd-detail-label
  '((t :inherit font-lock-type-face :weight bold))
  "Labels in the detail view.")

(defface taskwarrior-gtd-detail-value
  '((t :inherit default))
  "Values in the detail view.")

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

(defvar taskwarrior-gtd--current-report nil
  "Buffer-local: current report name for the list buffer.")
(defvar taskwarrior-gtd--tasks nil
  "Buffer-local: list of task alists for the current report.")
(defvar taskwarrior-gtd--detail-task nil
  "Buffer-local: the task alist shown in the detail buffer.")
(defvar taskwarrior-gtd--detail-window nil)
(defvar taskwarrior-gtd--list-buffer nil
  "The most recent gtd-list-mode buffer.")

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

(defun taskwarrior-gtd--run-json (args)
  "Run task with ARGS and return parsed JSON."
  (let ((out (taskwarrior-gtd--run args)))
    (condition-case nil
        (json-parse-string out :object-type 'alist :array-type 'list)
      (error nil))))

(defun taskwarrior-gtd--report-count (report)
  "Return the count of tasks for REPORT."
  (let* ((filter (cdr (assoc report taskwarrior-gtd-reports)))
         (out (taskwarrior-gtd--run (append (split-string filter) (list "count"))))
         (n (string-trim out)))
    (condition-case nil (string-to-number n) (error 0))))

(defun taskwarrior-gtd--report-tasks (report)
  "Return the list of task objects for REPORT."
  (let* ((filter (cdr (assoc report taskwarrior-gtd-reports)))
         (data (taskwarrior-gtd--run-json (append (split-string filter) (list "export")))))
    (if (and data (sequencep data)) data nil)))

(defun taskwarrior-gtd--get-task-at-point ()
  "Return the task alist for the row at point, or nil.
Works from list and detail buffers."
  (cond
   ((derived-mode-p 'gtd-detail-mode)
    taskwarrior-gtd--detail-task)
   ((derived-mode-p 'gtd-list-mode)
    (let ((id (tabulated-list-get-id)))
      (when id
        (cl-find-if (lambda (t) (equal (taskwarrior-gtd--task-id t) id))
                    taskwarrior-gtd--tasks))))))

(defun taskwarrior-gtd--task-id (task)
  "Return the id of TASK as a string."
  (number-to-string (or (cdr (assoc 'id task)) 0)))

(defun taskwarrior-gtd--task-uuid (task)
  "Return the uuid of TASK."
  (or (cdr (assoc 'uuid task)) ""))

(defun taskwarrior-gtd--task-description (task)
  "Return the description of TASK."
  (or (cdr (assoc 'description task)) ""))

(defun taskwarrior-gtd--task-project (task)
  "Return the project of TASK."
  (or (cdr (assoc 'project task)) ""))

(defun taskwarrior-gtd--task-due (task)
  "Return formatted due date of TASK."
  (let ((due (cdr (assoc 'due task))))
    (if due (taskwarrior-gtd--format-date due) "")))

(defun taskwarrior-gtd--task-urgency (task)
  "Return the urgency of TASK."
  (number-to-string (or (cdr (assoc 'urgency task)) 0)))

(defun taskwarrior-gtd--task-tags (task)
  "Return comma-separated tags of TASK."
  (let ((tags (cdr (assoc 'tags task))))
    (if tags (string-join (mapcar (lambda (t) (format "%s" t)) tags) ", ") "")))

(defun taskwarrior-gtd--task-wait (task)
  "Return formatted wait date of TASK."
  (let ((wait (cdr (assoc 'wait task))))
    (if wait (taskwarrior-gtd--format-date wait) "")))

(defun taskwarrior-gtd--task-age (task)
  "Return formatted age of TASK."
  (let ((entry (cdr (assoc 'entry task))))
    (if entry (taskwarrior-gtd--format-age entry) "")))

(defun taskwarrior-gtd--format-date (date-str)
  "Format a Taskwarrior ISO date string to a human-readable form."
  (when (and date-str (stringp date-str) (length> date-str 7))
    (let* ((s (if (string-match-p "T" date-str)
                  (substring date-str 0 8)
                (substring date-str 0 10)))
           (date (condition-case nil
                     (if (length= s 8)
                         (format "%s-%s-%s"
                                 (substring s 0 4)
                                 (substring s 4 6)
                                 (substring s 6 8))
                       s)
                   (error nil)))
           (days (when date
                   (condition-case nil
                       (truncate
                        (float-time
                         (time-subtract
                          (encode-time (decoded-time-set-defaults
                                        (parse-time-string date)))
                          (current-time))))
                     (error nil)))))
      (cond
       ((not date) date-str)
       ((= days 0) "today")
       ((= days 1) "tomorrow")
       ((and days (> days 0) (<= days 7)) (format "in %dd" days))
       ((and days (> days 7)) date)
       ((= days -1) "1d ago")
       ((and days (< days 0) (>= days -7)) (format "%dd ago" (- days)))
       (t date)))))

(defun taskwarrior-gtd--format-age (date-str)
  "Format an entry date string as a relative age."
  (let* ((date (taskwarrior-gtd--format-date date-str))
         (days (when date
                 (condition-case nil
                     (truncate
                      (float-time
                       (time-subtract
                        (current-time)
                        (encode-time (decoded-time-set-defaults
                                      (parse-time-string date))))))
                   (error nil)))))
    (cond
     ((not days) "")
     ((= days 0) "today")
     ((= days 1) "1d")
     ((< days 7) (format "%dd" days))
     ((< days 30) (format "%dw" (/ days 7)))
     (t (format "%dmo" (/ days 30))))))

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

(defun taskwarrior-gtd--col-urgency (task)
  (taskwarrior-gtd--task-urgency task))

(defun taskwarrior-gtd--col-tags (task)
  (let ((tags (taskwarrior-gtd--task-tags task)))
    (if (string= tags "")
        ""
      (propertize tags 'face 'taskwarrior-gtd-tag))))

(defun taskwarrior-gtd--col-wait (task)
  (taskwarrior-gtd--task-wait task))

(defun taskwarrior-gtd--col-age (task)
  (taskwarrior-gtd--task-age task))

(defun taskwarrior-gtd--col-recur (task)
  "Return the recurrence of TASK."
  (or (cdr (assoc 'recur task)) ""))

(defun taskwarrior-gtd--col-type (task)
  (let ((type (cdr (assoc 'type task))))
    (if type (propertize type 'face 'taskwarrior-gtd-tag) "")))

(defun taskwarrior-gtd--col-difficulty (task)
  (let ((diff (cdr (assoc 'difficulty task))))
    (if diff (propertize diff 'face 'taskwarrior-gtd-count) "")))

(defun taskwarrior-gtd--get-active-task-id ()
  "Query taskwarrior in real time and return the ID string of the active task, or nil."
  (let ((data (taskwarrior-gtd--run-json '("+ACTIVE" "export"))))
    (when (and data (sequencep data) (> (length data) 0))
      (number-to-string (cdr (assoc 'id (car data)))))))

(defun taskwarrior-gtd-action-toggle-start ()
  "Toggle start/stop on the task at point.
If a different task is already active, prompt to stop it first.
If the task at point is the active one, stop it."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let* ((id (taskwarrior-gtd--task-id task))
             (desc (taskwarrior-gtd--task-description task))
             (active-id (taskwarrior-gtd--get-active-task-id)))
        (cond
         ;; Task at point IS the active task — stop it
         ((equal id active-id)
          (taskwarrior-gtd--run (list id "stop"))
          (message "Task %s stopped" id)
          (taskwarrior-gtd-list-refresh))
         ;; Another task is active — confirm switch
         (active-id
          (let ((active-desc (cdr (assoc 'description
                                         (car (taskwarrior-gtd--run-json
                                               '("+ACTIVE" "export")))))))
            (when (y-or-n-p (format "Task %s is active (%s). Stop it and start task %s (%s)? "
                                    active-id (or active-desc "?") id desc))
              (taskwarrior-gtd--run (list active-id "stop"))
              (taskwarrior-gtd--run (list id "start"))
              (message "Stopped task %s, started task %s" active-id id)
              (taskwarrior-gtd-list-refresh))))
         ;; No active task — just start
         (t
          (taskwarrior-gtd--run (list id "start"))
          (message "Task %s started" id)
          (taskwarrior-gtd-list-refresh)))))))

(defun taskwarrior-gtd--sort-by-due (tasks)
  "Sort TASKS by due date, then scheduled, then entry.
Tasks without dates go last."
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
             (a-date t)   ; a has a date, b doesn't
             (b-date nil) ; b has a date, a doesn't
             (t nil)))))) ; neither has a date

;; ---------------------------------------------------------------------------
;; Dashboard
;; ---------------------------------------------------------------------------

(defvar gtd-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "1") #'taskwarrior-gtd--dashboard-open-in)
    (define-key map (kbd "2") #'taskwarrior-gtd--dashboard-open-next)
    (define-key map (kbd "3") #'taskwarrior-gtd--dashboard-open-waiting)
    (define-key map (kbd "4") #'taskwarrior-gtd--dashboard-open-someday)
    (define-key map (kbd "5") #'taskwarrior-gtd--dashboard-open-cal)
    (define-key map (kbd "6") #'taskwarrior-gtd--dashboard-open-all)
    (define-key map (kbd "e") #'taskwarrior-gtd-action-edit)
    (define-key map (kbd "a") #'taskwarrior-gtd-action-add)
    (define-key map (kbd "r") #'taskwarrior-gtd-dashboard)
    (define-key map (kbd "u") #'taskwarrior-gtd-action-undo)
    (define-key map (kbd "q") #'taskwarrior-gtd-quit)
    (define-key map (kbd "RET") #'taskwarrior-gtd--dashboard-ret)
    map)
  "Keymap for `gtd-dashboard-mode'.")

(with-eval-after-load 'evil
  (evil-make-overriding-map gtd-dashboard-mode-map 'normal)
  (add-hook 'gtd-dashboard-mode-hook #'evil-normalize-keymaps)
  (evil-define-key 'normal gtd-dashboard-mode-map
    (kbd "q") #'taskwarrior-gtd-quit))

(define-derived-mode gtd-dashboard-mode special-mode "GTD-Dashboard"
  "Dashboard for Taskwarrior GTD."
  (read-only-mode 1)
  (setq truncate-lines t))

(defun taskwarrior-gtd--dashboard-format-line (num name count)
  "Return a formatted dashboard line string."
  (let* ((count-face (if (= count 0) 'taskwarrior-gtd-count-zero 'taskwarrior-gtd-count))
         (count-str (propertize (format "(%d)" count) 'face count-face))
         (name-str (propertize (upcase name) 'face 'taskwarrior-gtd-bucket-name))
         (key-str (propertize (format "[%s]" num) 'face 'taskwarrior-gtd-section-header)))
    (format "  %s %-12s %s\n" key-str name-str count-str)))

(defun taskwarrior-gtd-dashboard ()
  "Open the GTD dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*gtd-dashboard*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (gtd-dashboard-mode)
        (insert "\n")
        (insert (propertize "  Taskwarrior GTD\n" 'face 'taskwarrior-gtd-title))
        (insert "\n")
        (let ((active-id (taskwarrior-gtd--get-active-task-id)))
          (if active-id
              (let* ((data (taskwarrior-gtd--run-json '("+ACTIVE" "export")))
                     (task (car data))
                     (desc (cdr (assoc 'description task)))
                     (proj (cdr (assoc 'project task)))
                     (proj-str (if proj (format " [%s]" proj) ""))
                     (line (format "  ▶ [%s] %s%s\n" active-id desc proj-str)))
                (insert (propertize line 'face 'taskwarrior-gtd-active)))
            (insert (propertize "  No active task\n" 'face 'taskwarrior-gtd-hint)))
          (insert "\n"))
        (dolist (i '(0 1 2 3 4))
          (let* ((entry (nth i taskwarrior-gtd-reports))
                 (name (car entry))
                 (count (taskwarrior-gtd--report-count name)))
            (let ((line (taskwarrior-gtd--dashboard-format-line (1+ i) name count)))
              (insert (propertize line
                                  'taskwarrior-gtd-report name
                                  'mouse-face 'highlight)))))
        (insert "\n")
        (insert (propertize "  Shortcuts\n" 'face 'taskwarrior-gtd-section-header))
        (insert (propertize "  1-6  Open view    a  Add task    e  Edit task    r  Refresh    u  Undo    q  Quit\n"
                            'face 'taskwarrior-gtd-hint))
        (insert "\n")
        (goto-char (point-min)))
      (switch-to-buffer buf))))

(defun taskwarrior-gtd--dashboard-report-at-point ()
  "Return the report name at point, or nil."
  (get-text-property (point) 'taskwarrior-gtd-report))

(defun taskwarrior-gtd--dashboard-open-in () (interactive) (taskwarrior-gtd-list "in"))
(defun taskwarrior-gtd--dashboard-open-next () (interactive) (taskwarrior-gtd-list "next"))
(defun taskwarrior-gtd--dashboard-open-waiting () (interactive) (taskwarrior-gtd-list "waiting"))
(defun taskwarrior-gtd--dashboard-open-someday () (interactive) (taskwarrior-gtd-list "someday"))
(defun taskwarrior-gtd--dashboard-open-cal () (interactive) (taskwarrior-gtd-list "cal"))
(defun taskwarrior-gtd--dashboard-open-all () (interactive) (taskwarrior-gtd-list "all"))

(defun taskwarrior-gtd--dashboard-ret ()
  "Open the report under point."
  (interactive)
  (let ((report (taskwarrior-gtd--dashboard-report-at-point)))
    (when report (taskwarrior-gtd-list report))))

;; ---------------------------------------------------------------------------
;; List view
;; ---------------------------------------------------------------------------

(defvar gtd-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "1") (lambda () (interactive) (taskwarrior-gtd-list "in")))
    (define-key map (kbd "2") (lambda () (interactive) (taskwarrior-gtd-list "next")))
    (define-key map (kbd "3") (lambda () (interactive) (taskwarrior-gtd-list "waiting")))
    (define-key map (kbd "4") (lambda () (interactive) (taskwarrior-gtd-list "someday")))
    (define-key map (kbd "5") (lambda () (interactive) (taskwarrior-gtd-list "cal")))
    (define-key map (kbd "6") (lambda () (interactive) (taskwarrior-gtd-list "all")))
    (define-key map (kbd "RET") #'taskwarrior-gtd-action-detail)
    (define-key map (kbd "d") #'taskwarrior-gtd-action-complete)
    (define-key map (kbd "x") #'taskwarrior-gtd-action-delete)
    (define-key map (kbd "m") #'taskwarrior-gtd-action-move)
    (define-key map (kbd "e") #'taskwarrior-gtd-action-edit)
    (define-key map (kbd "a") #'taskwarrior-gtd-action-add)
    (define-key map (kbd "c") #'taskwarrior-gtd-action-add)
    (define-key map (kbd "gt") #'taskwarrior-gtd-action-jump)
    (define-key map (kbd "r") #'taskwarrior-gtd-list-refresh)
    (define-key map (kbd "q") #'taskwarrior-gtd-list-quit)
    (define-key map (kbd "u") #'taskwarrior-gtd-action-undo)
    (define-key map (kbd "s") #'taskwarrior-gtd-action-toggle-start)
    (define-key map (kbd "h") #'taskwarrior-gtd-dashboard)
    map)
  "Keymap for `gtd-list-mode'.")

(with-eval-after-load 'evil
  (evil-make-overriding-map gtd-list-mode-map 'normal)
  (add-hook 'gtd-list-mode-hook #'evil-normalize-keymaps)
  (evil-define-key 'normal gtd-list-mode-map
    (kbd "q") #'taskwarrior-gtd-list-quit))

(define-derived-mode gtd-list-mode tabulated-list-mode "GTD-List"
  "List view for a Taskwarrior GTD report."
  (setq tabulated-list-padding 2))

(defun taskwarrior-gtd-list (report)
  "Open the task list for REPORT."
  (interactive (list (completing-read "Report: "
                                      (mapcar #'car taskwarrior-gtd-reports)
                                      nil t)))
  (let ((buf (get-buffer-create (format "*gtd-list:%s*" report))))
    (with-current-buffer buf
      (gtd-list-mode)
      (make-local-variable 'taskwarrior-gtd--current-report)
      (setq taskwarrior-gtd--current-report report)
      (taskwarrior-gtd--list-populate)
      (tabulated-list-print t))
    (setq taskwarrior-gtd--list-buffer buf)
    (switch-to-buffer buf)))

(defun taskwarrior-gtd--list-populate ()
  "Populate the current list buffer with tasks."
  (let* ((report taskwarrior-gtd--current-report)
         (tasks (taskwarrior-gtd--report-tasks report))
         (tasks (if (string= report "cal")
                    (taskwarrior-gtd--sort-by-due tasks)
                  tasks))
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

(defun taskwarrior-gtd-list-refresh ()
  "Refresh the list view.
Works from list or detail buffers."
  (interactive)
  (let ((buf (if (derived-mode-p 'gtd-list-mode)
                 (current-buffer)
               taskwarrior-gtd--list-buffer)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (derived-mode-p 'gtd-list-mode)
          (taskwarrior-gtd--list-populate)
          (tabulated-list-print t)
          (goto-char (point-min))
          (when (get-buffer-window buf)
            (with-selected-window (get-buffer-window buf)
              (recenter 0))))))))

(defun taskwarrior-gtd-list-quit ()
  "Quit list view back to dashboard."
  (interactive)
  (taskwarrior-gtd-dashboard))

;; ---------------------------------------------------------------------------
;; Detail view
;; ---------------------------------------------------------------------------

(defvar gtd-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'taskwarrior-gtd-detail-quit)
    (define-key map (kbd "c") #'taskwarrior-gtd-action-complete)
    (define-key map (kbd "x") #'taskwarrior-gtd-action-delete)
    (define-key map (kbd "m") #'taskwarrior-gtd-action-move)
    (define-key map (kbd "s") #'taskwarrior-gtd-action-toggle-start)
    map)
  "Keymap for `gtd-detail-mode'.")

(define-derived-mode gtd-detail-mode special-mode "GTD-Detail"
  "Detail view for a single task."
  (read-only-mode 1)
  (setq truncate-lines t))

(defun taskwarrior-gtd--show-detail (task &optional same-window)
  "Show detail for TASK in a side window or popup."
  (let ((buf (get-buffer-create (format "*gtd-detail:%s*" (taskwarrior-gtd--task-id task))))
        (inhibit-read-only t))
    (with-current-buffer buf
      (erase-buffer)
      (gtd-detail-mode)
      (make-local-variable 'taskwarrior-gtd--detail-task)
      (setq taskwarrior-gtd--detail-task task)
      (insert (propertize (format "  %s\n\n" (taskwarrior-gtd--task-description task))
                          'face 'taskwarrior-gtd-title))
      (insert (format "  %-12s %s\n" "ID:" (taskwarrior-gtd--task-id task)))
      (insert (format "  %-12s %s\n" "UUID:" (taskwarrior-gtd--task-uuid task)))
      (insert (format "  %-12s %s\n" "Project:" (taskwarrior-gtd--task-project task)))
      (insert (format "  %-12s %s\n" "Due:" (taskwarrior-gtd--task-due task)))
      (insert (format "  %-12s %s\n" "Tags:" (taskwarrior-gtd--task-tags task)))
      (insert (format "  %-12s %s\n" "Urgency:" (taskwarrior-gtd--task-urgency task)))
      (let ((type (cdr (assoc 'type task))))
        (when type (insert (format "  %-12s %s\n" "Type:" type))))
      (let ((difficulty (cdr (assoc 'difficulty task))))
        (when difficulty (insert (format "  %-12s %s\n" "Difficulty:" difficulty))))
      (let ((status (or (cdr (assoc 'status task)) "")))
        (insert (format "  %-12s %s\n" "Status:" status)))
      (let ((recur (or (cdr (assoc 'recur task)) "")))
        (when (length> recur 0)
          (insert (format "  %-12s %s\n" "Recurrence:" recur))))
      (let ((annotations (cdr (assoc 'annotations task))))
        (when (and annotations (length> annotations 0))
          (insert "\n  Annotations:\n")
          (dolist (ann annotations)
            (let ((entry (or (cdr (assoc 'entry ann)) ""))
                  (desc (or (cdr (assoc 'description ann)) "")))
              (insert (format "    [%s] %s\n" (substring entry 0 (min 10 (length entry))) desc))))))
      (insert "\n  q: close  |  c: done  |  x: delete  |  m: move\n"))
    (if same-window
        (switch-to-buffer buf)
      (let ((win (display-buffer buf
                                 '((display-buffer-in-side-window)
                                   (side . right)
                                   (window-width . 0.55)
                                   (window-parameters . ((no-delete-other-windows . t)))))))
        (select-window win)))))

(defun taskwarrior-gtd-detail-quit ()
  "Close the detail view and return to list."
  (interactive)
  (if (window-parent)
      (delete-window)
    (taskwarrior-gtd-list-quit)))

;; ---------------------------------------------------------------------------
;; Actions
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd-action-detail ()
  "Open detail for the task at point."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (when task (taskwarrior-gtd--show-detail task))))

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
          (taskwarrior-gtd-list-refresh))))))

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
          (taskwarrior-gtd-list-refresh))))))

(defun taskwarrior-gtd-action-move ()
  "Move the task at point to a different GTD bucket."
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let* ((id (taskwarrior-gtd--task-id task))
             (current-type (cdr (assoc 'type task)))
             (bucket (completing-read "Move to bucket: "
                                      taskwarrior-gtd-buckets
                                      nil t)))
        (when (length> bucket 0)
          (taskwarrior-gtd--run (list id "modify" (format "type:%s" bucket)))
          (message "Task %s moved to type:%s" id bucket)
          (taskwarrior-gtd-list-refresh))))))

(defun taskwarrior-gtd-action-add ()
  "Add a new task, supporting native project, tag, and date syntax."
  (interactive)
  (let ((raw-input (read-string "Task input (supports project:X, +tag, due:Y): ")))
    (when (length> raw-input 0)
      (let* ((bucket (completing-read "Bucket (default inbox): "
                                      taskwarrior-gtd-buckets
                                      nil nil "inbox"))
             ;; Split input string into a list of words, respecting quotes
             (parsed-args (split-string-and-unquote raw-input))
             ;; Build the final CLI argument list dynamically
             (final-cmd (append '("add") parsed-args (list (format "type:%s" bucket)))))

        (taskwarrior-gtd--run final-cmd)
        (message "Added task: %s (type:%s)" raw-input bucket)
        (when (derived-mode-p 'gtd-list-mode)
          (taskwarrior-gtd-list-refresh))))))

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
          (taskwarrior-gtd-list-refresh))))))

(defun taskwarrior-gtd-action-edit ()
  "Modify the task at point. Prompts for taskwarrior modify string.
E.g: project:Home due:tomorrow +urgent priority:H"
  (interactive)
  (let ((task (taskwarrior-gtd--get-task-at-point)))
    (if (not task)
        (message "No task at point")
      (let* ((id (taskwarrior-gtd--task-id task))
             (desc (taskwarrior-gtd--task-description task))
             (mods (read-string (format "Modify task %s [%s]: " id desc))))
        (when (length> mods 0)
          (let ((args (append (list id "modify") (split-string mods))))
            (taskwarrior-gtd--run args)
            (message "Task %s modified" id)
            (taskwarrior-gtd-list-refresh)))))))

(defun taskwarrior-gtd-action-jump ()
  "Jump to a task by ID, searching across all views if needed."
  (interactive)
  (let ((id (read-string "Task ID: ")))
    (when (length> id 0)
      (if (derived-mode-p 'gtd-list-mode)
          (let ((found nil))
            (save-excursion
              (goto-char (point-min))
              (while (not (or found (eobp)))
                (when (equal (tabulated-list-get-id) id)
                  (setq found t))
                (unless found (forward-line 1))))
            (if found
                (message "Task %s found in current view" id)
              (taskwarrior-gtd-list "all")
              (save-excursion
                (goto-char (point-min))
                (while (not (or found (eobp)))
                  (when (equal (tabulated-list-get-id) id)
                    (setq found t))
                  (unless found (forward-line 1))))
              (unless found
                (message "Task %s not found" id))))
        (message "Open a list view first")))))

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
    (define-key map (kbd "d") #'taskwarrior-gtd-action-detail)
    (define-key map (kbd "s") #'taskwarrior-gtd-action-toggle-start)
    (define-key map (kbd "r") #'taskwarrior-gtd-list-refresh)
    (define-key map (kbd "u") #'taskwarrior-gtd-action-undo)
    (define-key map (kbd "h") #'taskwarrior-gtd-dashboard)
    map)
  "Keymap for `gtd-action-minor-mode'.")

(define-minor-mode gtd-action-minor-mode
  "Minor mode for GTD task actions on `SPC m'.
Provides a which-key-friendly prefix for task operations."
  :lighter " GTD-A"
  :keymap gtd-action-minor-mode-map)

;; ---------------------------------------------------------------------------
;; Entry / quit
;; ---------------------------------------------------------------------------

(defun taskwarrior-gtd ()
  "Open the Taskwarrior GTD dashboard."
  (interactive)
  (taskwarrior-gtd-dashboard))

(defun taskwarrior-gtd-quit ()
  "Quit all GTD windows and buffers."
  (interactive)
  (dolist (buf (list (get-buffer "*gtd-dashboard*")
                     (get-buffer "*gtd-detail*")))
    (when buf (kill-buffer buf)))
  (dolist (buf (buffer-list))
    (when (string-match-p "^\\*gtd-" (buffer-name buf))
      (kill-buffer buf)))
  (when (> (length (window-list)) 1)
    (delete-other-windows)))

;; ---------------------------------------------------------------------------
;; Evil integration helpers
;; ---------------------------------------------------------------------------
(with-eval-after-load 'evil
  (evil-make-overriding-map gtd-detail-mode-map 'normal)
  (add-hook 'gtd-detail-mode-hook #'evil-normalize-keymaps)
  (evil-define-key 'normal gtd-detail-mode-map
    (kbd "q") #'taskwarrior-gtd-detail-quit
    (kbd "c") #'taskwarrior-gtd-action-complete
    (kbd "x") #'taskwarrior-gtd-action-delete
    (kbd "m") #'taskwarrior-gtd-action-move
    (kbd "e") #'taskwarrior-gtd-action-edit
    (kbd "s") #'taskwarrior-gtd-action-toggle-start)

  (evil-define-key 'normal gtd-list-mode-map
    (kbd "gg") #'beginning-of-buffer
    (kbd "G") #'end-of-buffer
    (kbd "gt") #'taskwarrior-gtd-action-jump
    (kbd "e") #'taskwarrior-gtd-action-edit
    (kbd "s") #'taskwarrior-gtd-action-toggle-start)

  (evil-define-key 'normal gtd-dashboard-mode-map
    (kbd "gg") #'beginning-of-buffer
    (kbd "G") #'end-of-buffer
    (kbd "e") #'taskwarrior-gtd-action-edit))


;; ---------------------------------------------------------------------------
;; Provide
;; ---------------------------------------------------------------------------

(provide 'taskwarrior-gtd)
;;; taskwarrior-gtd.el ends here
