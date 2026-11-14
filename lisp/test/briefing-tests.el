;;; briefing-tests.el --- Tests for briefing  -*- lexical-binding: t; -*-

;; Run:  emacs --batch -L lisp/util -L lisp/test -l briefing-tests \
;;         -f ert-run-tests-batch-and-exit
;; Taskwarrior is replaced by a fake script; nothing here touches real data.

(require 'ert)
(require 'briefing)
(require 'briefing-sources)

(defvar briefing-test--log nil)

(defun briefing-test--fake-task (json)
  "Write an executable that logs its args and prints JSON; return its path."
  (let ((script (make-temp-file "fake-task" nil ".sh"))
        (log (make-temp-file "fake-task-log")))
    (setq briefing-test--log log)
    (with-temp-file script
      (insert "#!/bin/sh\n"
              (format "echo \"$@\" >> %s\n" log)
              ;; `add' prints nothing; `export' prints JSON.
              (format "case \"$*\" in *export*) cat <<'EOF'\n%s\nEOF\n;; esac\n" json)))
    (set-file-modes script #o755)
    script))

(defun briefing-test--logged ()
  (with-temp-buffer (insert-file-contents briefing-test--log) (buffer-string)))

(defmacro briefing-test-with-env (json &rest body)
  "Run BODY with a fresh buffer, no sources and a fake `task' printing JSON."
  (declare (indent 1))
  `(let* ((briefing-sources nil)
          (briefing--results nil)
          (briefing--generation 0)
          (briefing--refreshed nil)
          (briefing--tracked nil)
          (briefing-task-command (list (briefing-test--fake-task ,json))))
     (when (get-buffer briefing-buffer-name) (kill-buffer briefing-buffer-name))
     (unwind-protect
         (progn (briefing--ensure-buffer) ,@body)
       (when (get-buffer briefing-buffer-name) (kill-buffer briefing-buffer-name)))))

(defun briefing-test--item (&rest args)
  (apply #'briefing-item-create
         (append args (list :source 'x :key "k1" :title "Title" :why "WHY"))))

(defun briefing-test--text ()
  (with-current-buffer briefing-buffer-name (buffer-string)))

(defun briefing-test--item-lines ()
  "Titles of the item rows, in order."
  (with-current-buffer briefing-buffer-name
    (let (out)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((it (get-text-property (point) 'briefing-item)))
            (push (briefing-item-title it) out))
          (forward-line 1)))
      (nreverse out))))

;;;; Rendering

(ert-deftest briefing-renders-sections-and-items ()
  (briefing-test-with-env "[]"
    (briefing-register-source 'a "Alpha" (lambda (cb _f) (funcall cb (list (briefing-test--item :title "one")))))
    (briefing-register-source 'b "Beta" (lambda (cb _f) (funcall cb nil)))
    (briefing--refresh-all)
    (let ((text (briefing-test--text)))
      (should (string-match-p "Alpha  (1)" text))
      (should (string-match-p "one" text))
      (should (string-match-p "Beta" text))
      (should (string-match-p "nothing waiting" text)))
    ;; Sections appear in registration order.
    (should (< (string-match "Alpha" (briefing-test--text))
               (string-match "Beta" (briefing-test--text))))))

(ert-deftest briefing-shows-loading-then-result ()
  (briefing-test-with-env "[]"
    (let (finish)
      (briefing-register-source 'slow "Slow" (lambda (cb _f) (setq finish cb)))
      (briefing--refresh-all)
      (should (string-match-p "Slow  loading" (briefing-test--text)))
      (funcall finish (list (briefing-test--item :title "late")))
      (should (string-match-p "late" (briefing-test--text)))
      (should-not (string-match-p "loading" (briefing-test--text))))))

(ert-deftest briefing-failing-source-does-not-break-others ()
  (briefing-test-with-env "[]"
    (briefing-register-source 'bad "Bad" (lambda (_cb _f) (error "boom")))
    (briefing-register-source 'err "Err" (lambda (cb _f) (funcall cb (cons 'error "no network"))))
    (briefing-register-source 'ok "Ok" (lambda (cb _f) (funcall cb (list (briefing-test--item :title "fine")))))
    (briefing--refresh-all)
    (let ((text (briefing-test--text)))
      (should (string-match-p "! boom" text))
      (should (string-match-p "! no network" text))
      (should (string-match-p "fine" text)))))

(ert-deftest briefing-stale-refresh-cannot-overwrite-newer ()
  (briefing-test-with-env "[]"
    (let (callbacks)
      (briefing-register-source 's "S" (lambda (cb _f) (push cb callbacks)))
      (briefing--refresh-all)
      (briefing--refresh-all)
      ;; callbacks = (newer older)
      (funcall (car callbacks) (list (briefing-test--item :title "new")))
      (funcall (cadr callbacks) (list (briefing-test--item :title "old")))
      (should (equal (briefing-test--item-lines) '("new"))))))

(ert-deftest briefing-fold-hides-rows ()
  (briefing-test-with-env "[]"
    (briefing-register-source 'a "Alpha" (lambda (cb _f) (funcall cb (list (briefing-test--item :title "row")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min))
      (briefing-toggle-fold)
      (should-not (briefing-test--item-lines))
      (should (string-match-p "▸ Alpha" (briefing-test--text)))
      (briefing-toggle-fold)
      (should (equal (briefing-test--item-lines) '("row"))))))

(ert-deftest briefing-render-keeps-point-on-same-item ()
  (briefing-test-with-env "[]"
    (briefing-register-source
     'a "A" (lambda (cb _f)
              (funcall cb (list (briefing-test--item :key "1" :title "first")
                                (briefing-test--item :key "2" :title "second")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min))
      (briefing-next) (briefing-next)
      (should (equal (briefing-item-title (briefing--item)) "second"))
      (briefing--render)
      (should (equal (briefing-item-title (briefing--item)) "second")))))

(ert-deftest briefing-next-previous-skip-headings ()
  (briefing-test-with-env "[]"
    (briefing-register-source 'a "A" (lambda (cb _f) (funcall cb (list (briefing-test--item :key "1" :title "a1")))))
    (briefing-register-source 'b "B" (lambda (cb _f) (funcall cb (list (briefing-test--item :key "2" :title "b1")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min))
      (briefing-next)
      (should (equal (briefing-item-title (briefing--item)) "a1"))
      (briefing-next)
      (should (equal (briefing-item-title (briefing--item)) "b1"))
      (briefing-previous)
      (should (equal (briefing-item-title (briefing--item)) "a1")))))

;;;; Opening

(ert-deftest briefing-open-uses-item-function-else-browser ()
  (briefing-test-with-env "[]"
    (let (opened browsed)
      (briefing-register-source
       'a "A" (lambda (cb _f)
                (funcall cb (list (briefing-test--item :key "1" :title "custom"
                                                       :open (lambda (it) (setq opened (briefing-item-key it))))
                                  (briefing-test--item :key "2" :title "plain" :url "https://x.test/p")))))
      (briefing--refresh-all)
      (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (setq browsed u))))
        (with-current-buffer briefing-buffer-name
          (goto-char (point-min)) (briefing-next)
          (briefing-open)
          (should (equal opened "1"))
          (briefing-next)
          (briefing-open)
          (should (equal browsed "https://x.test/p")))))))

(ert-deftest briefing-open-without-target-is-an-error-not-a-crash ()
  (briefing-test-with-env "[]"
    (briefing-register-source 'a "A" (lambda (cb _f) (funcall cb (list (briefing-test--item)))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min)) (briefing-next)
      (should-error (briefing-open) :type 'user-error)
      (goto-char (point-min))
      (should-error (briefing-copy-url) :type 'user-error))))

;;;; Tasks

(ert-deftest briefing-task-adds-once ()
  (briefing-test-with-env "[]"
    (briefing-register-source
     'x "X" (lambda (cb _f) (funcall cb (list (briefing-test--item :title "Do it" :url "https://x.test/1")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min)) (briefing-next)
      (briefing-task)
      (briefing-task)
      (briefing-task))
    (let ((log (briefing-test--logged)))
      ;; Exactly one `add', with the marker and the literal description after `--'.
      (should (= 1 (1- (length (split-string log " add project:")))))
      (should (string-match-p "type:inbox +\\+briefing -- \\[x k1\\] Do it" log))
      (should (string-match-p "project:Work.ClearCo" log))
      (should (string-match-p "annotate https://x.test/1" log)))
    (should (string-match-p "✓" (briefing-test--text)))))

(ert-deftest briefing-task-uses-task-title-and-item-project ()
  (briefing-test-with-env "[]"
    (briefing-register-source
     'x "X" (lambda (cb _f)
              (funcall cb (list (briefing-test--item :title "display only" :task-title "for the task"
                                                     :project "Personal")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min)) (briefing-next) (briefing-task))
    (let ((log (briefing-test--logged)))
      (should (string-match-p "\\[x k1\\] for the task" log))
      (should-not (string-match-p "display only" log))
      (should (string-match-p "project:Personal" log)))))

(ert-deftest briefing-existing-tasks-are-marked-and-not-duplicated ()
  (briefing-test-with-env
      "[{\"uuid\":\"u1\",\"description\":\"[x k1] Already here\",\"status\":\"pending\"}]"
    (briefing-register-source
     'x "X" (lambda (cb _f) (funcall cb (list (briefing-test--item :title "Already here")))))
    (briefing--refresh-all)
    (should (string-match-p "✓" (briefing-test--text)))
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min)) (briefing-next) (briefing-task))
    (should-not (string-match-p " add " (briefing-test--logged)))))

(ert-deftest briefing-github-tasks-share-the-sync-marker ()
  ;; The review sync names tasks "[gh owner/repo#N] ..."; the briefing must
  ;; recognise them so a review request is not offered as a new task.
  (briefing-test-with-env
      "[{\"uuid\":\"u1\",\"description\":\"[gh o/r#5] Review: thing\",\"status\":\"pending\"}]"
    (briefing--load-tracked)
    (should (briefing--tracked-p (briefing-item-create :source 'gh :key "o/r#5")))
    (should-not (briefing--tracked-p (briefing-item-create :source 'gh :key "o/r#6")))))

(ert-deftest briefing-task-on-board-row-is-refused ()
  (briefing-test-with-env "[]"
    (briefing-register-source
     'task "Board" (lambda (cb _f) (funcall cb (list (briefing-item-create :source 'task :key "u" :title "t")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min)) (briefing-next) (briefing-task))
    (should-not (string-match-p " add " (briefing-test--logged)))))

(ert-deftest briefing-description-is-literal ()
  ;; A title that looks like a Taskwarrior attribute must not become one.
  (briefing-test-with-env "[]"
    (briefing-register-source
     'x "X" (lambda (cb _f) (funcall cb (list (briefing-test--item :title "fix due:today +urgent project:Evil")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min)) (briefing-next) (briefing-task))
    (should (string-match-p "-- \\[x k1\\] fix due:today" (briefing-test--logged)))))

;;;; Taskwarrior board source

(defun briefing-test--await (fn)
  "Call FN with a callback; wait up to 5 s for it and return what it received."
  (let (result called)
    (funcall fn (lambda (r) (setq result r called t)))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not called) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (should called)
    result))

(ert-deftest briefing-board-follows-gtd-order-not-urgency ()
  ;; Due first (earliest first), then scheduled, then entry; urgency is ignored.
  (let ((items (briefing-sources--tasks
                '(((uuid . "late") (description . "due late") (urgency . 99) (due . "20261120T000000Z") (entry . "20260101T000000Z"))
                  ((uuid . "none") (description . "no dates") (urgency . 50) (entry . "20260301T000000Z"))
                  ((uuid . "soon") (description . "due soon") (urgency . 1) (due . "20261101T000000Z") (entry . "20260901T000000Z"))
                  ((uuid . "sched") (description . "scheduled") (urgency . 5) (scheduled . "20261110T000000Z") (entry . "20260101T000000Z"))))))
    (should (equal (mapcar #'briefing-item-title items)
                   '("no dates" "due soon" "scheduled" "due late")))))

(ert-deftest briefing-board-limit-adds-a-more-row ()
  (let* ((tasks (mapcar (lambda (i) `((uuid . ,(format "u%d" i)) (description . ,(format "t%d" i))
                                      (entry . ,(format "2026010%dT000000Z" i))))
                        '(1 2 3 4 5)))
         (items (briefing-sources--tasks tasks :source 'next :limit 3)))
    (should (= 4 (length items)))
    (should (equal (mapcar #'briefing-item-title (seq-take items 3)) '("t1" "t2" "t3")))
    (should (string-match-p "2 more" (briefing-item-title (nth 3 items))))
    (should (briefing-item-open (nth 3 items)))
    ;; Nothing extra when everything fits.
    (should (= 5 (length (briefing-sources--tasks tasks :limit 5))))))

(ert-deftest briefing-board-sections-and-sources ()
  (let ((it (car (briefing-sources--tasks '(((uuid . "u") (description . "x") (entry . "20260101T000000Z")))
                                          :source 'caltask :section 'today))))
    (should (eq (briefing-item-source it) 'caltask))
    (should (eq (briefing--section-of it) 'today))))

(ert-deftest briefing-board-due-annotation-and-age ()
  (let* ((it (car (briefing-sources--tasks
                   '(((uuid . "a") (description . "t") (urgency . 1) (due . "20261116T000000Z")
                      (entry . "20200101T000000Z") (project . "Work")
                      (annotations . (((description . "see https://x.test/pr/1 now"))))))))))
    (should (equal (briefing-item-why it) "due 11-16"))
    (should (equal (briefing-item-url it) "https://x.test/pr/1"))
    (should (equal (briefing-item-who it) "Work"))
    (should (string-match-p "w\\'" (briefing-item-age it)))))

(ert-deftest briefing-gtd-sources-read-real-process-output ()
  (let ((briefing-task-command
         (list (briefing-test--fake-task
                "[{\"uuid\":\"a\",\"description\":\"from process\",\"entry\":\"20260101T000000Z\"}]"))))
    (dolist (fn '(briefing-sources-inbox briefing-sources-next briefing-sources-wait))
      (let ((result (briefing-test--await (lambda (cb) (funcall fn cb nil)))))
        (should (equal (mapcar #'briefing-item-title result) '("from process")))))
    ;; The right bucket is asked for.
    (should (string-match-p "type:inbox" (briefing-test--logged)))
    (should (string-match-p "type:next" (briefing-test--logged)))
    (should (string-match-p "type:waiting" (briefing-test--logged)))))

(ert-deftest briefing-gtd-source-reports-failure ()
  (let* ((briefing-task-command '("/nonexistent/task-binary"))
         (result (briefing-test--await (lambda (cb) (briefing-sources-next cb nil)))))
    (should (eq (car-safe result) 'error))))

(ert-deftest briefing-gtd-source-survives-garbage-output ()
  (let* ((briefing-task-command (list (briefing-test--fake-task "not json at all")))
         (result (briefing-test--await (lambda (cb) (briefing-sources-next cb nil)))))
    (should (null result))))

(ert-deftest briefing-board-hides-tracking-marker ()
  (let ((items (briefing-sources--tasks
                '(((uuid . "a") (description . "[gh o/r#1] Review: thing") (urgency . 1))
                  ((uuid . "b") (description . "[not a marker") (urgency . 0))
                  ((uuid . "c") (description . "plain [x y] inside") (urgency . 0))))))
    (should (equal (mapcar #'briefing-item-title items)
                   '("Review: thing" "[not a marker" "plain [x y] inside")))))

;;;; GitHub source

(require 'gh-inbox)

(defun briefing-test--gh-item (n tags)
  (gh-inbox-item-create :url (format "https://github.com/o/r/pull/%d" n) :repo "o/r"
                        :number n :title (format "PR %d" n) :kind 'pr :author "ann"
                        :updated "2026-11-10T00:00:00Z" :tags tags))

(ert-deftest briefing-github-maps-needs-me-items ()
  (let ((gh-inbox-items (list (briefing-test--gh-item 1 '((review)))
                              (briefing-test--gh-item 2 nil)))
        (gh-inbox--dismissed nil)
        (gh-inbox--dismissed-loaded t))
    (let ((items (briefing-sources--github-items)))
      (should (= 1 (length items)))
      (let ((it (car items)))
        (should (eq (briefing-item-source it) 'gh))
        (should (equal (briefing-item-key it) "o/r#1"))
        (should (string-match-p "r#1 PR 1" (briefing-item-title it)))
        (should (equal (briefing-item-task-title it) "Follow up: PR 1"))
        (should (string-match-p "REVIEW" (briefing-item-why it)))))))

(ert-deftest briefing-github-uses-fresh-cache-unless-forced ()
  (let ((gh-inbox-items (list (briefing-test--gh-item 1 '((review)))))
        (gh-inbox--last-fetch (float-time))
        (gh-inbox--dismissed nil)
        (gh-inbox--dismissed-loaded t)
        (fetched 0) result)
    (cl-letf (((symbol-function 'gh-inbox-fetch)
               (lambda (&optional cb) (cl-incf fetched) (funcall cb gh-inbox-items) t)))
      (briefing-sources-github (lambda (r) (setq result r)) nil)
      (should (= fetched 0))
      (should (= 1 (length result)))
      (setq result nil)
      (briefing-sources-github (lambda (r) (setq result r)) t)
      (should (= fetched 1))
      (should (= 1 (length result))))))

(ert-deftest briefing-github-waits-for-a-fetch-already-running ()
  (let ((gh-inbox-items nil)
        (gh-inbox--last-fetch nil)
        (gh-inbox--dismissed nil)
        (gh-inbox--dismissed-loaded t)
        (gh-inbox-refresh-hook nil)
        result)
    (cl-letf (((symbol-function 'gh-inbox-fetch) (lambda (&optional _cb) nil)))
      (briefing-sources-github (lambda (r) (setq result r)) t)
      (should-not result)
      (setq gh-inbox-items (list (briefing-test--gh-item 7 '((review)))))
      (run-hooks 'gh-inbox-refresh-hook)
      (should (= 1 (length result)))
      ;; The one-shot hook removed itself.
      (should-not gh-inbox-refresh-hook))))

;;;; Today (calendar) source

(defun briefing-test--ev (uid title start end &optional allday)
  `((uid . ,uid) (title . ,title) (start . ,start) (end . ,end)
    (allday . ,(if allday 1 0)) (location . "") (link . "")))

(defmacro briefing-test-with-today (cal-results task-result &rest body)
  "Run BODY with calendars faked: CAL-RESULTS is an alist (NAME . RESULT) of feed
outcomes, TASK-RESULT what the cal-bucket task fetch returns."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'briefing-sources--calendars)
              (lambda () (mapcar (lambda (c) (cons (car c) "http://x")) ,cal-results)))
             ((symbol-function 'briefing-sources--fetch-calendar)
              (lambda (cal _bounds cb)
                (let ((r (cdr (assoc (car cal) ,cal-results))))
                  (funcall cb (if (eq (car-safe r) 'error) r
                                (briefing-sources--event-items (car cal) r))))))
             ((symbol-function 'briefing-sources--fetch-tasks)
              (lambda (_filter cb &rest args)
                (funcall cb (if (eq (car-safe ,task-result) 'error) ,task-result
                              (apply #'briefing-sources--tasks ,task-result args))))))
     ,@body))

(ert-deftest briefing-today-merges-calendars-and-tasks ()
  (let ((now (float-time)) result)
    (briefing-test-with-today
        `(("Work" ,(briefing-test--ev "b" "Later" (+ now 7200) (+ now 9000))
                  ,(briefing-test--ev "h" "Holiday" now (+ now 86400) t))
          ("Personal" ,(briefing-test--ev "a" "Sooner" (+ now 3600) (+ now 5400))))
        '(((uuid . "t1") (description . "Pay rent") (due . "20261114T183000Z") (entry . "20260101T000000Z")))
      (briefing-sources-today (lambda (r) (setq result r)) nil))
    (should (equal (mapcar #'briefing-item-title result)
                   '("Holiday" "Sooner" "Later" "Pay rent")))
    ;; Everything is shown in the Today section, whatever its source.
    (should (equal (mapcar #'briefing--section-of result) '(today today today today)))
    (should (equal (mapcar #'briefing-item-source result) '(cal cal cal caltask)))
    (should (equal (briefing-item-why (nth 0 result)) "all day"))
    (should (equal (briefing-item-who (nth 1 result)) "Personal"))
    (should (equal (briefing-item-age (nth 1 result)) "30m"))))

(ert-deftest briefing-today-shows-partial-results-and-names-the-failure ()
  (let ((now (float-time)) result)
    (briefing-test-with-today
        `(("Work" ,(briefing-test--ev "b" "Meeting" (+ now 3600) (+ now 5400)))
          ("Personal" error . "Personal: feed down"))
        nil
      (briefing-sources-today (lambda (r) (setq result r)) nil))
    (should (listp result))
    (should-not (eq (car-safe result) 'error))
    (should (member "Meeting" (mapcar #'briefing-item-title result)))
    (should (member "Personal: feed down" (mapcar #'briefing-item-title result)))))

(ert-deftest briefing-today-all-failed-is-an-error ()
  (let (result)
    (briefing-test-with-today
        '(("Work" error . "Work: no network"))
        '(error . "task failed")
      (briefing-sources-today (lambda (r) (setq result r)) nil))
    (should (eq (car-safe result) 'error))
    (should (string-match-p "Work: no network" (cdr result)))))

(ert-deftest briefing-today-without-calendars-still-lists-tasks ()
  (let (result)
    (briefing-test-with-today nil
        '(((uuid . "t1") (description . "Call bank") (due . "20261115T000000Z") (entry . "20260101T000000Z")))
      (briefing-sources-today (lambda (r) (setq result r)) nil))
    (should (equal (mapcar #'briefing-item-title result) '("Call bank")))))

(ert-deftest briefing-next-event-header ()
  (let* ((now (float-time))
         (briefing--results
          `((today . ,(briefing-sources--event-items
                       "Work" (list (briefing-test--ev "p" "Over" (- now 7200) (- now 3600))
                                    (briefing-test--ev "n" "Standup" (+ now 1800) (+ now 3600))
                                    (briefing-test--ev "l" "Retro" (+ now 9000) (+ now 10000))
                                    (briefing-test--ev "d" "Holiday" now (+ now 86400) t)))))))
    (let ((s (briefing-sources--next-event-string)))
      (should (string-match-p "next: .* Standup (in 30m)" s))
      (should-not (string-match-p "Holiday\\|Over\\|Retro" s))))
  ;; In progress
  (let* ((now (float-time))
         (briefing--results
          `((today . ,(briefing-sources--event-items
                       "Work" (list (briefing-test--ev "n" "Planning" (- now 600) (+ now 600)))))))
         (s (briefing-sources--next-event-string)))
    (should (string-match-p "now: Planning (until " s)))
  ;; Nothing left today / still loading / failed: no header text, no error.
  (let ((briefing--results '((today . loading)))) (should-not (briefing-sources--next-event-string)))
  (let ((briefing--results '((today error . "x")))) (should-not (briefing-sources--next-event-string)))
  (let ((briefing--results nil)) (should-not (briefing-sources--next-event-string))))

(ert-deftest briefing-header-includes-the-next-event ()
  (let* ((now (float-time))
         (briefing--results
          `((today . ,(briefing-sources--event-items
                       "Work" (list (briefing-test--ev "n" "Standup" (+ now 1800) (+ now 3600))))))))
    (let ((briefing-header-functions '(briefing-sources--next-event-string)))
      (should (string-match-p "Standup" (briefing--header))))
    ;; A function that blows up must not break the header.
    (let ((briefing-header-functions (list (lambda () (error "boom")))))
      (should (string-match-p "Briefing" (briefing--header))))))

;;;; Order and folding

(ert-deftest briefing-register-before-inserts-ahead ()
  (let ((briefing-sources nil))
    (briefing-register-source 'a "A" #'ignore)
    (briefing-register-source 'c "C" #'ignore)
    (briefing-register-source 'b "B" #'ignore 'c)
    (should (equal (mapcar #'car briefing-sources) '(a b c)))
    ;; Unknown BEFORE appends; re-registering replaces in place.
    (briefing-register-source 'd "D" #'ignore 'nope)
    (briefing-register-source 'a "A2" #'ignore)
    (should (equal (mapcar #'car briefing-sources) '(a b c d)))
    (should (equal (nth 1 (assq 'a briefing-sources)) "A2"))))

(ert-deftest briefing-default-sections-in-gtd-order ()
  (should (equal (mapcar #'car (let ((briefing-sources nil))
                                 (briefing-sources-register-defaults)
                                 briefing-sources))
                 '(today gh inbox next wait))))

(ert-deftest briefing-waiting-for-starts-folded ()
  (briefing-test-with-env "[]"
    (briefing-register-source 'wait "Waiting" (lambda (cb _f) (funcall cb (list (briefing-test--item :source 'wait :title "hidden")))))
    (briefing-register-source 'next "Next" (lambda (cb _f) (funcall cb (list (briefing-test--item :source 'next :title "shown")))))
    (with-current-buffer briefing-buffer-name
      (kill-all-local-variables) (briefing-mode))
    (briefing--refresh-all)
    (should (equal (briefing-test--item-lines) '("shown")))
    (should (string-match-p "▸ Waiting" (briefing-test--text)))))

(ert-deftest briefing-refresh-section-works-from-an-item-in-another-section-id ()
  ;; Calendar rows have source `cal' but live in the `today' section.
  (briefing-test-with-env "[]"
    (let ((fetches 0))
      (briefing-register-source
       'today "Today" (lambda (cb _f) (cl-incf fetches)
                        (funcall cb (list (briefing-item-create :source 'cal :section 'today
                                                                :key "e" :title "event" :why "09:00")))))
      (briefing--refresh-all)
      (with-current-buffer briefing-buffer-name
        (goto-char (point-min)) (briefing-next)
        (briefing-refresh-section)
        (should (= fetches 2))
        (briefing-toggle-fold)
        (should (string-match-p "▸ Today" (briefing-test--text)))))))

(ert-deftest briefing-task-on-calendar-error-row-is-refused ()
  (briefing-test-with-env "[]"
    (briefing-register-source
     'today "Today" (lambda (cb _f) (funcall cb (list (briefing-item-create :source 'calerr :section 'today
                                                                            :key "x" :title "Work: down" :why "!")))))
    (briefing--refresh-all)
    (with-current-buffer briefing-buffer-name
      (goto-char (point-min)) (briefing-next) (briefing-task))
    (should-not (string-match-p " add " (briefing-test--logged)))))

;;;; Misc

(ert-deftest briefing-help-and-mode-load ()
  (briefing-test-with-env "[]"
    (with-current-buffer briefing-buffer-name
      (should (derived-mode-p 'briefing-mode))
      (should (consp (briefing--bookmark-record))))))

(provide 'briefing-tests)
;;; briefing-tests.el ends here
