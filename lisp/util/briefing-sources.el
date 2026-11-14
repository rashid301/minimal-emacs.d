;;; briefing-sources.el --- Sources for `briefing'  -*- lexical-binding: t; -*-

;;; Commentary:

;; Today (calendar events and calendar-bucket tasks), GitHub, and your GTD
;; buckets from Taskwarrior (inbox, next, waiting for).  Each source is one
;; function (CALLBACK FORCE) that eventually calls CALLBACK with items or
;; (error . MSG).  Slack and mail will be added the same way.
;;
;; The GTD sections follow your own board (`taskwarrior-gtd'): bucket by
;; `type', ordered by due, then scheduled, then entry date.  No urgency.

;;; Code:

(require 'briefing)
(require 'cl-lib)
(require 'subr-x)

(declare-function gh-inbox-fetch "gh-inbox")
(declare-function gh-inbox--visible "gh-inbox")
(declare-function gh-inbox--tag-label "gh-inbox")
(declare-function gh-inbox--age-string "gh-inbox")
(declare-function gh-inbox-review-open "gh-inbox-review")
(declare-function taskwarrior-gtd "taskwarrior-gtd")
(defvar gh-inbox-items)
(defvar gh-inbox--last-fetch)
(defvar gh-inbox--last-error)
(defvar gh-inbox-refresh-hook)
(defvar my/calendar-sources)

;;;; Shared: an async process that collects its output

(defun briefing-sources--run (program args callback &optional input)
  "Run PROGRAM with ARGS without blocking; call CALLBACK with (EXIT . OUTPUT).
INPUT, if given, is sent on stdin (so secrets stay off the command line).
Uses a pipe, not a pty: some wrappers behave differently on a tty."
  (let ((buf (generate-new-buffer " *briefing-proc*")))
    (condition-case err
        (let ((proc (make-process
                     :name "briefing" :buffer buf :connection-type 'pipe :noquery t
                     :command (cons program args)
                     :sentinel (lambda (proc _event)
                                 (unless (process-live-p proc)
                                   (let ((out (with-current-buffer buf (buffer-string))))
                                     (kill-buffer buf)
                                     (funcall callback (cons (process-exit-status proc) out))))))))
          (when input (process-send-string proc input))
          (process-send-eof proc))
      (error
       (kill-buffer buf)
       (funcall callback (cons -1 (error-message-string err)))))))

;;;; GitHub

(defun briefing-sources--github-items ()
  "Briefing items for the review inbox's \"needs me\" rows."
  (mapcar
   (lambda (it)
     (let ((repo (gh-inbox-item-repo it)) (n (gh-inbox-item-number it)))
       (briefing-item-create
        :source 'gh
        :key (format "%s#%s" repo n)
        :title (format "%s#%s %s" (replace-regexp-in-string "\\`[^/]*/" "" (or repo ""))
                       n (or (gh-inbox-item-title it) ""))
        :task-title (format "Follow up: %s" (or (gh-inbox-item-title it) ""))
        :who (or (gh-inbox-item-author it) "")
        :age (gh-inbox--age-string (gh-inbox-item-updated it))
        :why (mapconcat #'gh-inbox--tag-label (gh-inbox-item-tags it) " ")
        :url (gh-inbox-item-url it)
        :open (lambda (_)
                (if (eq (gh-inbox-item-kind it) 'pr)
                    (progn (require 'gh-inbox-review) (gh-inbox-review-open it))
                  (browse-url (gh-inbox-item-url it))))
        :data it)))
   (gh-inbox--visible gh-inbox-items 'needs nil nil)))

(defun briefing-sources-github (callback force)
  "Deliver GitHub items to CALLBACK, reusing fresh data unless FORCE."
  (require 'gh-inbox)
  (if (and (not force) gh-inbox--last-fetch
           (< (- (float-time) gh-inbox--last-fetch) briefing-github-stale-seconds))
      (funcall callback (briefing-sources--github-items))
    (let ((done nil) timer)
      (cl-flet ((finish (result)
                  (unless done
                    (setq done t)
                    (when timer (cancel-timer timer))
                    (funcall callback result))))
        ;; `gh-inbox-fetch' only calls back on success, so a failure would leave
        ;; the section "loading" forever without this timeout.
        (setq timer (run-at-time
                     75 nil
                     (lambda ()
                       (finish (cons 'error (or (bound-and-true-p gh-inbox--last-error)
                                                "GitHub did not answer in time"))))))
        (unless (gh-inbox-fetch (lambda (_) (finish (briefing-sources--github-items))))
          ;; A fetch (the poller's, say) is already running: use its result.
          (let (hook)
            (setq hook (lambda ()
                         (remove-hook 'gh-inbox-refresh-hook hook)
                         (finish (briefing-sources--github-items))))
            (add-hook 'gh-inbox-refresh-hook hook)))))))

;;;; Taskwarrior: your GTD buckets

(defun briefing-sources--due (due)
  "\"due 11-16\" from a Taskwarrior DUE like 20261116T000000Z, or nil."
  (when (and due (string-match "\\`[0-9]\\{4\\}\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)" due))
    (format "due %s-%s" (match-string 1 due) (match-string 2 due))))

(defun briefing-sources--entry-age (entry)
  "Age string for a Taskwarrior ENTRY timestamp like 20261110T120000Z."
  (when (and entry (string-match
                    "\\`\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)T\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)Z"
                    entry))
    (let* ((secs (- (float-time)
                    (float-time (date-to-time
                                 (format "%s-%s-%sT%s:%s:%sZ"
                                         (match-string 1 entry) (match-string 2 entry)
                                         (match-string 3 entry) (match-string 4 entry)
                                         (match-string 5 entry) (match-string 6 entry))))))
           (m (/ secs 60)))
      (cond ((< m 60) (format "%dm" (max 0 m)))
            ((< m 1440) (format "%dh" (/ m 60)))
            ((< m 20160) (format "%dd" (/ m 1440)))
            (t (format "%dw" (/ m 10080)))))))

(defun briefing-sources--task-url (task)
  "First URL among TASK's annotations, or nil."
  (cl-some (lambda (a)
             (let ((d (alist-get 'description a)))
               (and d (string-match "https?://[^ \t\n]+" d) (match-string 0 d))))
           (alist-get 'annotations task)))

(defun briefing-sources--gtd-sort (tasks)
  "TASKS ordered like `taskwarrior-gtd': due, else scheduled, else entry; oldest first."
  (sort (copy-sequence tasks)
        (lambda (a b)
          (let ((da (or (alist-get 'due a) (alist-get 'scheduled a) (alist-get 'entry a) ""))
                (db (or (alist-get 'due b) (alist-get 'scheduled b) (alist-get 'entry b) "")))
            (string< da db)))))

(cl-defun briefing-sources--tasks (tasks &key (source 'task) section limit)
  "Briefing items for TASKS (parsed Taskwarrior JSON) in GTD order.
At most LIMIT rows, then one row saying how many more there are."
  (let* ((sorted (briefing-sources--gtd-sort tasks))
         (shown (if limit (seq-take sorted limit) sorted))
         (more (- (length sorted) (length shown)))
         (items
          (mapcar
           (lambda (tk)
             (briefing-item-create
              :source source :section section
              :key (alist-get 'uuid tk)
              ;; Hide the "[gh o/r#1] " tracking marker; it is for the code, not for you.
              :title (replace-regexp-in-string "\\`\\[[a-z]+ [^]]+\\] " ""
                                               (or (alist-get 'description tk) ""))
              :who (or (alist-get 'project tk) "")
              :age (or (briefing-sources--entry-age (alist-get 'entry tk)) "")
              :why (or (briefing-sources--due (alist-get 'due tk)) "")
              :url (briefing-sources--task-url tk)))
           shown)))
    (if (> more 0)
        (append items
                (list (briefing-item-create
                       :source source :section section :key "more"
                       :title (format "… %d more (RET opens your GTD board)" more)
                       :open (lambda (_)
                               (require 'taskwarrior-gtd)
                               (call-interactively #'taskwarrior-gtd)))))
      items)))

(defun briefing-sources--fetch-tasks (filter callback &rest item-args)
  "Export tasks matching FILTER (a list) and call CALLBACK with items.
ITEM-ARGS are passed to `briefing-sources--tasks'."
  (briefing-sources--run
   (car briefing-task-command)
   (append (cdr briefing-task-command)
           '("rc.confirmation=no" "rc.verbose=nothing" "rc.json.array=on")
           filter '("export"))
   (lambda (res)
     (if (eq (car res) 0)
         (let ((tasks (briefing--parse-json (cdr res))))
           (funcall callback (apply #'briefing-sources--tasks
                                    (and (listp tasks) tasks) item-args)))
       (funcall callback
                (cons 'error (format "task failed: %s"
                                     (truncate-string-to-width
                                      (string-trim (cdr res)) 120 nil nil "…"))))))))

(defcustom briefing-next-limit 12
  "Rows of next actions shown before \"… N more\"."
  :type 'integer)

(defun briefing-sources-inbox (callback _force)
  "GTD inbox: everything still to process (the goal is zero)."
  (briefing-sources--fetch-tasks '("type:inbox" "status:pending") callback :source 'inbox))

(defun briefing-sources-next (callback _force)
  "GTD next actions, in your board's order."
  (briefing-sources--fetch-tasks '("type:next" "status:pending") callback
                                 :source 'next :limit briefing-next-limit))

(defun briefing-sources-wait (callback _force)
  "GTD waiting-for."
  (briefing-sources--fetch-tasks '("type:waiting" "status:pending") callback :source 'wait))

;;;; Today: calendar events and calendar-bucket tasks

(defcustom briefing-calendar-timeout 45
  "Seconds before giving up on downloading one calendar feed."
  :type 'integer)

(defun briefing-sources--day-bounds (&optional time)
  "(START . END) epoch seconds of the local day containing TIME (default now)."
  (let* ((d (decode-time (or time (current-time))))
         (start (float-time (encode-time (list 0 0 0 (nth 3 d) (nth 4 d) (nth 5 d) nil -1 nil)))))
    (cons start (float-time (encode-time (list 0 0 0 (1+ (nth 3 d)) (nth 4 d) (nth 5 d) nil -1 nil))))))

(defun briefing-sources--calendars ()
  "List of (NAME . URL) for the configured calendars that have a URL."
  (when (boundp 'my/calendar-sources)
    (delq nil
          (mapcar (lambda (c)
                    (let ((url (auth-source-pick-first-password :host (nth 0 c) :user "ical")))
                      (and url (string-prefix-p "http" url) (cons (nth 2 c) url))))
                  my/calendar-sources))))

(defun briefing-sources--duration-string (secs)
  (let ((m (round (/ secs 60.0))))
    (cond ((<= m 0) "") ((< m 60) (format "%dm" m))
          ((zerop (% m 60)) (format "%dh" (/ m 60)))
          (t (format "%dh%02d" (/ m 60) (% m 60))))))

(defun briefing-sources--event-items (name events)
  "Briefing items for EVENTS (parsed worker JSON) of calendar NAME."
  (mapcar
   (lambda (e)
     (let* ((start (alist-get 'start e)) (end (alist-get 'end e))
            (allday (eql (alist-get 'allday e) 1))
            (link (alist-get 'link e)))
       (briefing-item-create
        :source 'cal :section 'today
        :key (format "%s|%s" (alist-get 'uid e) start)
        :title (alist-get 'title e)
        :who (or name "")
        :age (if allday "" (briefing-sources--duration-string (- end start)))
        :why (if allday "all day" (format-time-string "%H:%M" start))
        :url (and link (not (string-empty-p link)) link)
        :data (list start end allday))))
   events))

(defun briefing-sources--parse-worker (output)
  "Events from the child Emacs' OUTPUT, or (error . MSG)."
  (if (string-match "^BRIEFING-JSON:\\(.*\\)$" output)
      (let ((v (briefing--parse-json (match-string 1 output))))
        (if (listp v) v (cons 'error "bad calendar data")))
    (cons 'error (truncate-string-to-width
                  (string-trim (replace-regexp-in-string "BRIEFING-ERROR:" "" output))
                  120 nil nil "…"))))

(defun briefing-sources--fetch-calendar (cal bounds callback)
  "Fetch and parse calendar CAL (NAME . URL) in the background for BOUNDS.
CALLBACK gets a list of items or (error . MSG).  The feed is parsed in a
child Emacs because that takes seconds."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lib (file-name-directory (or (locate-library "briefing-ical")
                                       (error "briefing-ical.el not on load-path"))))
         (cmd (format "curl -sS --max-time %d -K - | %s -Q --batch -L %s -l briefing-ical -f briefing-ical-main %d %d 2>&1"
                      briefing-calendar-timeout
                      (shell-quote-argument emacs) (shell-quote-argument lib)
                      (car bounds) (cdr bounds))))
    (briefing-sources--run
     "sh" (list "-c" cmd)
     (lambda (res)
       (let ((events (briefing-sources--parse-worker (cdr res))))
         (funcall callback
                  (if (eq (car-safe events) 'error)
                      (cons 'error (format "%s: %s" (car cal) (cdr events)))
                    (briefing-sources--event-items (car cal) events)))))
     (format "url = \"%s\"\n" (cdr cal)))))

(defun briefing-sources--event-order (a b)
  "Non-nil if event item A sorts before B: all-day first, then by start."
  (let ((da (briefing-item-data a)) (db (briefing-item-data b)))
    (cond ((and (nth 2 da) (not (nth 2 db))) t)
          ((and (nth 2 db) (not (nth 2 da))) nil)
          (t (< (car da) (car db))))))

(defun briefing-sources-today (callback _force)
  "Today's calendar events, then calendar-bucket tasks due today or overdue."
  (let* ((cals (briefing-sources--calendars))
         (bounds (briefing-sources--day-bounds))
         (pending (1+ (length cals)))
         (events nil) (tasks nil) (errors nil) (done nil))
    (cl-flet ((joined ()
                (when (and (zerop (cl-decf pending)) (not done))
                  (setq done t)
                  (funcall callback
                           (if (and errors (null events) (null tasks))
                               (cons 'error (string-join (reverse errors) "; "))
                             ;; Partial results beat nothing: show what arrived and
                             ;; say what did not.
                             (append (mapcar (lambda (e)
                                               (briefing-item-create
                                                :source 'calerr :section 'today :key e
                                                :why "!" :title e))
                                             (reverse errors))
                                     (sort events #'briefing-sources--event-order)
                                     tasks))))))
      (dolist (cal cals)
        (briefing-sources--fetch-calendar
         cal bounds
         (lambda (r)
           (if (eq (car-safe r) 'error)
               (push (cdr r) errors)
             (setq events (append events r)))
           (joined))))
      (briefing-sources--fetch-tasks
       '("type:cal" "status:pending" "due.before:tomorrow")
       (lambda (r)
         (if (eq (car-safe r) 'error)
             (push (cdr r) errors)
           (setq tasks r))
         (joined))
       :source 'caltask :section 'today))))

(defun briefing-sources--next-event-string ()
  "Header text about the current or next calendar event, or nil."
  (let ((res (briefing--result 'today)) (now (float-time)) best)
    (when (and (listp res) (not (eq (car-safe res) 'error)))
      (dolist (it res)
        (when (eq (briefing-item-source it) 'cal)
          (pcase-let ((`(,s ,e ,allday) (briefing-item-data it)))
            (when (and (not allday) (> e now))
              (when (or (null best) (< s (car (briefing-item-data best))))
                (setq best it)))))))
    (when best
      (pcase-let ((`(,s ,e ,_) (briefing-item-data best)))
        (if (<= s now)
            (format "now: %s (until %s)" (briefing-item-title best) (format-time-string "%H:%M" e))
          (let ((m (round (/ (- s now) 60))))
            (format "next: %s %s (in %s)" (format-time-string "%H:%M" s)
                    (briefing-item-title best)
                    (if (< m 60) (format "%dm" m) (format "%dh%02d" (/ m 60) (% m 60))))))))))

;;;; Registration

(defun briefing-sources-register-defaults ()
  "Register the sources, in display order."
  (briefing-register-source 'today "Today" #'briefing-sources-today)
  (briefing-register-source 'gh "GitHub: waiting on you" #'briefing-sources-github)
  (briefing-register-source 'inbox "Inbox: to process" #'briefing-sources-inbox)
  (briefing-register-source 'next "Next actions" #'briefing-sources-next)
  (briefing-register-source 'wait "Waiting for" #'briefing-sources-wait)
  (add-hook 'briefing-header-functions #'briefing-sources--next-event-string))

(setq briefing-sources nil)
(briefing-sources-register-defaults)

(provide 'briefing-sources)
;;; briefing-sources.el ends here
