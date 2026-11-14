;;; briefing-ical-tests.el --- Tests for the calendar worker  -*- lexical-binding: t; -*-

;; Run:  emacs --batch -L lisp/util -L lisp/test -l briefing-ical-tests \
;;         -f ert-run-tests-batch-and-exit
;; All feeds here are synthetic; the machine's time zone is pinned to UTC.

(require 'ert)
(require 'briefing-ical)

(defun briefing-ical-test--feed (&rest events)
  "An iCalendar feed whose VEVENTs are the strings in EVENTS (no BEGIN/END)."
  (replace-regexp-in-string
   "\n" "\r\n"
   (concat "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//test//EN\nX-WR-CALNAME:me@x.test\n"
           (mapconcat (lambda (e) (concat "BEGIN:VEVENT\n" e "\nEND:VEVENT\n")) events "")
           "END:VCALENDAR\n")))

(defun briefing-ical-test--ev (uid summary &rest lines)
  (concat "UID:" uid "\nDTSTAMP:20260101T000000Z\nSUMMARY:" summary "\n"
          (mapconcat #'identity lines "\n")))

(defconst briefing-ical-test--day '(16 11 2026) "Monday 2026-11-16.")

(defmacro briefing-ical-test-in-utc (&rest body)
  `(unwind-protect
       (progn (set-time-zone-rule t) ,@body)
     (set-time-zone-rule nil)))

(defun briefing-ical-test--titles (feed &optional self day)
  "Titles of the events on DAY (default the 16th) in FEED, in order."
  (briefing-ical-test-in-utc
   (let* ((d (or day briefing-ical-test--day))
          (lo (float-time (encode-time (list 0 0 0 (nth 0 d) (nth 1 d) (nth 2 d) nil -1 t))))
          (cal (briefing-ical-parse-string feed)))
     (should cal)
     (mapcar (lambda (e) (alist-get 'title e))
             (briefing-ical-events-between cal lo (+ lo 86400) self)))))

(defun briefing-ical-test--events (feed &optional self)
  (briefing-ical-test-in-utc
   (let* ((lo (float-time (encode-time (list 0 0 0 16 11 2026 nil -1 t))))
          (cal (briefing-ical-parse-string feed)))
     (briefing-ical-events-between cal lo (+ lo 86400) self))))

(ert-deftest briefing-ical-single-event-in-window ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "a" "Today" "DTSTART:20261116T100000Z" "DTEND:20261116T110000Z")
               (briefing-ical-test--ev "b" "Tomorrow" "DTSTART:20261117T100000Z" "DTEND:20261117T110000Z")
               (briefing-ical-test--ev "c" "Yesterday" "DTSTART:20261115T100000Z" "DTEND:20261115T110000Z"))))
    (should (equal (briefing-ical-test--titles feed) '("Today")))))

(ert-deftest briefing-ical-sorted-by-start ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "a" "Late" "DTSTART:20261116T150000Z" "DTEND:20261116T160000Z")
               (briefing-ical-test--ev "b" "Early" "DTSTART:20261116T080000Z" "DTEND:20261116T090000Z"))))
    (should (equal (briefing-ical-test--titles feed) '("Early" "Late")))))

(ert-deftest briefing-ical-weekly-series-expands-with-its-own-length ()
  ;; The expander reports end = start for these; the length must come from DTEND-DTSTART.
  (let* ((feed (briefing-ical-test--feed
                (briefing-ical-test--ev "s" "Standup" "DTSTART:20261102T140000Z" "DTEND:20261102T143000Z"
                                        "RRULE:FREQ=WEEKLY;BYDAY=MO")))
         (evs (briefing-ical-test--events feed)))
    (should (= 1 (length evs)))
    (should (= 1800 (- (alist-get 'end (car evs)) (alist-get 'start (car evs)))))))

(ert-deftest briefing-ical-series-not-on-other-weekdays ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "s" "Standup" "DTSTART:20261102T140000Z" "DTEND:20261102T143000Z"
                                       "RRULE:FREQ=WEEKLY;BYDAY=MO"))))
    (should-not (briefing-ical-test--titles feed nil '(17 11 2026)))
    (should (equal (briefing-ical-test--titles feed nil '(23 11 2026)) '("Standup")))))

(ert-deftest briefing-ical-exdate-removes-an-occurrence ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "s" "Skipped" "DTSTART:20261102T150000Z" "DTEND:20261102T153000Z"
                                       "RRULE:FREQ=WEEKLY;BYDAY=MO" "EXDATE:20261116T150000Z"))))
    (should-not (briefing-ical-test--titles feed))
    ;; ...but the following week is still there.
    (should (equal (briefing-ical-test--titles feed nil '(23 11 2026)) '("Skipped")))))

(ert-deftest briefing-ical-override-replaces-the-occurrence ()
  ;; "Moved" normally runs Mondays at 16:00; this Monday it is at 18:00.
  (let* ((feed (briefing-ical-test--feed
                (briefing-ical-test--ev "m" "Moved" "DTSTART:20261102T160000Z" "DTEND:20261102T170000Z"
                                        "RRULE:FREQ=WEEKLY;BYDAY=MO")
                (briefing-ical-test--ev "m" "Moved" "DTSTART:20261116T180000Z" "DTEND:20261116T190000Z"
                                        "RECURRENCE-ID:20261116T160000Z")))
         (evs (briefing-ical-test--events feed)))
    (should (= 1 (length evs)))
    (should (= (alist-get 'start (car evs))
               (briefing-ical-test-in-utc
                (float-time (encode-time '(0 0 18 16 11 2026 nil -1 t))))))))

(ert-deftest briefing-ical-cancelled-override-removes-the-occurrence ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "x" "Series" "DTSTART:20261102T190000Z" "DTEND:20261102T200000Z"
                                       "RRULE:FREQ=WEEKLY;BYDAY=MO")
               (briefing-ical-test--ev "x" "Series" "DTSTART:20261116T190000Z" "DTEND:20261116T200000Z"
                                       "RECURRENCE-ID:20261116T190000Z" "STATUS:CANCELLED"))))
    (should-not (briefing-ical-test--titles feed))))

(ert-deftest briefing-ical-cancelled-event-is-hidden ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "a" "Gone" "DTSTART:20261116T100000Z" "DTEND:20261116T110000Z"
                                       "STATUS:CANCELLED"))))
    (should-not (briefing-ical-test--titles feed))))

(ert-deftest briefing-ical-declined-events-are-hidden-for-me-only ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "a" "Declined" "DTSTART:20261116T100000Z" "DTEND:20261116T110000Z"
                                       "ATTENDEE;PARTSTAT=DECLINED:mailto:me@x.test"
                                       "ATTENDEE;PARTSTAT=ACCEPTED:mailto:other@x.test"))))
    (should-not (briefing-ical-test--titles feed "me@x.test"))
    ;; Someone else declining does not hide it from me.
    (should (equal (briefing-ical-test--titles feed "other@x.test") '("Declined")))
    ;; Without knowing who I am nothing is hidden.
    (should (equal (briefing-ical-test--titles feed nil) '("Declined")))))

(ert-deftest briefing-ical-all-day-events-come-first-and-are-flagged ()
  (let* ((feed (briefing-ical-test--feed
                (briefing-ical-test--ev "t" "Timed" "DTSTART:20261116T080000Z" "DTEND:20261116T090000Z")
                (briefing-ical-test--ev "d" "Holiday" "DTSTART;VALUE=DATE:20261116" "DTEND;VALUE=DATE:20261117")))
         (evs (briefing-ical-test--events feed)))
    (should (equal (mapcar (lambda (e) (alist-get 'title e)) evs) '("Holiday" "Timed")))
    (should (= 1 (alist-get 'allday (car evs))))
    (should (= 0 (alist-get 'allday (cadr evs))))))

(ert-deftest briefing-ical-multi-day-all-day-event-covers-the-day ()
  (let ((feed (briefing-ical-test--feed
               (briefing-ical-test--ev "d" "Trip" "DTSTART;VALUE=DATE:20261114" "DTEND;VALUE=DATE:20261118"))))
    (should (equal (briefing-ical-test--titles feed) '("Trip")))
    (should-not (briefing-ical-test--titles feed nil '(18 11 2026)))))

(ert-deftest briefing-ical-finds-the-call-link ()
  (let* ((feed (briefing-ical-test--feed
                (briefing-ical-test--ev "z" "Call" "DTSTART:20261116T100000Z" "DTEND:20261116T110000Z"
                                        "DESCRIPTION:Join https://acme.zoom.us/j/123456?pwd=abc now")
                (briefing-ical-test--ev "g" "Meet" "DTSTART:20261116T120000Z" "DTEND:20261116T130000Z"
                                        "LOCATION:https://meet.google.com/abc-defg-hij")
                (briefing-ical-test--ev "n" "Plain" "DTSTART:20261116T140000Z" "DTEND:20261116T150000Z")))
         (evs (briefing-ical-test--events feed)))
    (should (equal (alist-get 'link (nth 0 evs)) "https://acme.zoom.us/j/123456?pwd=abc"))
    (should (equal (alist-get 'link (nth 1 evs)) "https://meet.google.com/abc-defg-hij"))
    (should (equal (alist-get 'link (nth 2 evs)) ""))))

(ert-deftest briefing-ical-owner-comes-from-the-calendar-name ()
  (let ((cal (briefing-ical-parse-string (briefing-ical-test--feed))))
    (should (equal (briefing-ical-calendar-owner cal) "me@x.test"))))

(ert-deftest briefing-ical-main-prints-one-json-line ()
  "End to end, in a real child Emacs: stdin feed in, one JSON line out."
  (let* ((feed (briefing-ical-test--feed
                (briefing-ical-test--ev "a" "Child" "DTSTART:20261116T100000Z" "DTEND:20261116T110000Z")))
         (lo (briefing-ical-test-in-utc (float-time (encode-time '(0 0 0 16 11 2026 nil -1 t)))))
         (lib (file-name-directory (locate-library "briefing-ical")))
         (out (with-temp-buffer
                (insert feed)
                (let ((process-environment (cons "TZ=UTC" process-environment)))
                  (call-process-region (point-min) (point-max)
                                       (expand-file-name invocation-name invocation-directory)
                                       t t nil "-Q" "--batch" "-L" lib "-l" "briefing-ical"
                                       "-f" "briefing-ical-main"
                                       (format "%d" lo) (format "%d" (+ lo 86400))))
                (buffer-string))))
    (should (string-match "^BRIEFING-JSON:\\(.*\\)$" out))
    (let ((evs (json-parse-string (match-string 1 out) :object-type 'alist :array-type 'list)))
      (should (equal (mapcar (lambda (e) (alist-get 'title e)) evs) '("Child"))))))

(ert-deftest briefing-ical-main-reports-garbage ()
  (let* ((lib (file-name-directory (locate-library "briefing-ical")))
         (out (with-temp-buffer
                (insert "<html>login required</html>")
                (call-process-region (point-min) (point-max)
                                     (expand-file-name invocation-name invocation-directory)
                                     t t nil "-Q" "--batch" "-L" lib "-l" "briefing-ical"
                                     "-f" "briefing-ical-main" "0" "1")
                (buffer-string))))
    (should (string-match-p "BRIEFING-ERROR" out))
    (should-not (string-match-p "BRIEFING-JSON" out))))

(provide 'briefing-ical-tests)
;;; briefing-ical-tests.el ends here
