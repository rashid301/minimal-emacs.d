;;; briefing-ical.el --- Today's events from an iCal feed, run in a child Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Parsing a real Google Calendar feed (1 MB+) takes seconds, which would freeze
;; the Emacs you are typing in.  So the briefing runs this file in a throwaway
;; `emacs --batch' that reads the feed on stdin and prints one line:
;;
;;   BRIEFING-JSON:[{"start":..,"end":..,"allday":0|1,"title":..,...}, ...]
;;
;; Recurring events are expanded with Emacs' own `icalendar-recur'.  calfw-ical
;; does not expand them, so a daily stand-up would never show up.
;;
;; Handled: RRULE/RDATE/EXDATE, per-occurrence overrides (RECURRENCE-ID, which
;; replace the series' occurrence), STATUS:CANCELLED, events you declined,
;; all-day events, and time zones.  Not handled: THISANDFUTURE overrides.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'icalendar-parser)
(require 'icalendar-recur)
(require 'icalendar-utils)

(defun briefing-ical--child (type node)
  "First child of NODE with TYPE, or nil."
  (icalendar-ast-node-first-child-of type node))

(defun briefing-ical--value (type node)
  "Innermost value of NODE's first TYPE property, or nil.
Typed values are wrapped in a node of their own, hence the two steps."
  (when-let* ((prop (briefing-ical--child type node)))
    (let ((v (icalendar-ast-node-value prop)))
      (if (icalendar-ast-node-p v) (icalendar-ast-node-value v) v))))

(defun briefing-ical--wrapped (type node)
  "The typed value node of NODE's first TYPE property (to tell date from date-time)."
  (when-let* ((prop (briefing-ical--child type node)))
    (icalendar-ast-node-value prop)))

(defun briefing-ical--instant (value kind)
  "Seconds since the epoch for VALUE, a date or date-time of KIND.
A date means local midnight, so an all-day event follows your own day."
  (pcase kind
    ('icalendar-date
     (pcase-let ((`(,m ,d ,y) value))
       (float-time (encode-time (list 0 0 0 d m y nil -1 nil)))))
    (_ (float-time (encode-time value)))))

(defun briefing-ical--kind (node)
  "`icalendar-date' or `icalendar-date-time' for NODE's DTSTART."
  (let ((w (briefing-ical--wrapped 'icalendar-dtstart node)))
    (and w (icalendar-ast-node-type w))))

(defun briefing-ical--text (type node)
  (let ((v (briefing-ical--value type node)))
    (and (stringp v) v)))

(defun briefing-ical--self-declined-p (event self)
  "Non-nil if EVENT has an attendee SELF whose answer is DECLINED."
  (when self
    (seq-some
     (lambda (att)
       (let ((addr (icalendar-ast-node-value att)))
         (when (icalendar-ast-node-p addr) (setq addr (icalendar-ast-node-value addr)))
         (and (stringp addr)
              (string-equal-ignore-case addr (concat "mailto:" self))
              (seq-some
               (lambda (p)
                 (and (eq (icalendar-ast-node-type p) 'icalendar-partstatparam)
                      (equal (icalendar-ast-node-value p) "DECLINED")))
               (icalendar-ast-node-children att)))))
     (icalendar-ast-node-children-of 'icalendar-attendee event))))

(defconst briefing-ical--link-regexp
  (concat "https://[A-Za-z0-9.-]*\\(?:zoom\\.us\\|zoomgov\\.com\\)/j/[^ \t\n\"<>\\\\]+"
          "\\|https://meet\\.google\\.com/[a-z0-9-]+"
          "\\|https://teams\\.microsoft\\.com/l/meetup-join/[^ \t\n\"<>\\\\]+")
  "Video-call links worth opening with RET.")

(defun briefing-ical--link (event)
  "A video-call URL from EVENT's location or description, or nil."
  (seq-some (lambda (s)
              (and s (string-match briefing-ical--link-regexp s) (match-string 0 s)))
            (list (briefing-ical--text 'icalendar-location event)
                  (briefing-ical--text 'icalendar-description event))))

(defun briefing-ical--timezone-for (event cal)
  "The VTIMEZONE of CAL matching EVENT's DTSTART TZID, or nil."
  (when-let* ((prop (briefing-ical--child 'icalendar-dtstart event))
              (tzparam (seq-find (lambda (p) (eq (icalendar-ast-node-type p) 'icalendar-tzidparam))
                                 (icalendar-ast-node-children prop)))
              (tzid (icalendar-ast-node-value tzparam)))
    (seq-find (lambda (tz) (equal (briefing-ical--value 'icalendar-tzid tz) tzid))
              (icalendar-ast-node-children-of 'icalendar-vtimezone cal))))

(defun briefing-ical--single-span (event kind)
  "(START . END) instants for the non-recurring EVENT of KIND."
  (let* ((s (briefing-ical--instant (briefing-ical--value 'icalendar-dtstart event) kind))
         (end-node (briefing-ical--wrapped 'icalendar-dtend event))
         (e (cond (end-node (briefing-ical--instant
                             (icalendar-ast-node-value end-node)
                             (icalendar-ast-node-type end-node)))
                  ((eq kind 'icalendar-date) (+ s 86400))
                  (t s))))
    (cons s e)))

(defun briefing-ical--exdates (event)
  "Instants (epoch seconds) of EVENT's EXDATEs, whatever form they are written in.
The expander compares them by representation, so a UTC EXDATE on a series
written in a local zone (or the reverse) would not match; comparing instants does."
  (let (out)
    (dolist (prop (icalendar-ast-node-children-of 'icalendar-exdate event))
      (let ((v (icalendar-ast-node-value prop)))
        (dolist (node (if (icalendar-ast-node-p v) (list v) v))
          (when (icalendar-ast-node-p node)
            (condition-case nil
                (push (briefing-ical--instant (icalendar-ast-node-value node)
                                              (icalendar-ast-node-type node))
                      out)
              (error nil))))))
    out))

(defun briefing-ical--spans (event cal kind lower upper)
  "List of (START . END) instants of EVENT, recurrences expanded, near LOWER..UPPER."
  (if (or (briefing-ical--child 'icalendar-rrule event)
          (briefing-ical--child 'icalendar-rdate event))
      ;; Take only the start times from the expander: its end times come back
      ;; equal to the start for these feeds.  The series' own length is DTEND
      ;; minus DTSTART on the master event.
      (let* ((w (decode-time (- lower 86400) t))
             (u (decode-time (+ upper 86400) t))
             (master (briefing-ical--single-span event kind))
             (len (- (cdr master) (car master)))
             (exdates (briefing-ical--exdates event)))
        (seq-remove
         (lambda (span) (seq-some (lambda (x) (< (abs (- x (car span))) 1)) exdates))
         (mapcar (lambda (start)
                   (let ((s (briefing-ical--instant start kind)))
                     (cons s (+ s len))))
                 (icalendar-recur-recurrences-in-window
                  w u event (briefing-ical--timezone-for event cal)))))
    (list (briefing-ical--single-span event kind))))

(defun briefing-ical-events-between (cal lower upper &optional self)
  "Events of parsed CAL overlapping LOWER..UPPER (epoch seconds), as alists.
SELF is your address, used to hide events you declined."
  (let* ((events (icalendar-ast-node-children-of 'icalendar-vevent cal))
         (overridden (make-hash-table :test 'equal))
         out)
    ;; An override replaces exactly one occurrence of its series.
    (dolist (e events)
      (when-let* ((rid (briefing-ical--wrapped 'icalendar-recurrence-id e)))
        (puthash (format "%s|%.0f" (briefing-ical--text 'icalendar-uid e)
                         (briefing-ical--instant (icalendar-ast-node-value rid)
                                                 (icalendar-ast-node-type rid)))
                 t overridden)))
    (dolist (e events)
      (let ((status (briefing-ical--value 'icalendar-status e))
            (kind (briefing-ical--kind e)))
        (unless (or (null kind)
                    (equal status "CANCELLED")
                    (briefing-ical--self-declined-p e self))
          (condition-case nil
              (dolist (span (briefing-ical--spans e cal kind lower upper))
                (let ((s (car span)) (en (cdr span))
                      (is-override (briefing-ical--child 'icalendar-recurrence-id e)))
                  (when (and (< s upper) (if (> en s) (> en lower) (>= s lower))
                             (or is-override
                                 (not (gethash (format "%s|%.0f"
                                                       (briefing-ical--text 'icalendar-uid e) s)
                                               overridden))))
                    (push `((start . ,(round s)) (end . ,(round en))
                            (allday . ,(if (eq kind 'icalendar-date) 1 0))
                            (title . ,(or (briefing-ical--text 'icalendar-summary e) "(no title)"))
                            (location . ,(or (briefing-ical--text 'icalendar-location e) ""))
                            (link . ,(or (briefing-ical--link e) ""))
                            (uid . ,(or (briefing-ical--text 'icalendar-uid e) "")))
                          out))))
            ;; One odd event must not hide the rest of the day.
            (error nil)))))
    (sort out (lambda (a b)
                (let ((aa (alist-get 'allday a)) (ab (alist-get 'allday b)))
                  (if (/= aa ab) (> aa ab)   ; all-day first
                    (< (alist-get 'start a) (alist-get 'start b))))))))

(defun briefing-ical-calendar-owner (cal)
  "The calendar's own address from X-WR-CALNAME, if it looks like one."
  (seq-some (lambda (p)
              (let ((v (icalendar-ast-node-value p)))
                (when (icalendar-ast-node-p v) (setq v (icalendar-ast-node-value v)))
                (and (stringp v) (string-match-p "\\`[^ @]+@[^ @]+\\'" v) v)))
            (icalendar-ast-node-children-of 'icalendar-other-property cal)))

(defun briefing-ical-parse-string (ics)
  "Parse the iCalendar text ICS into a VCALENDAR node, or nil."
  ;; CRLF line ends inserted from a string defeat the parser (a file read has
  ;; them normalised already), so do the same here.
  (with-temp-buffer
    (insert (replace-regexp-in-string "\r\n" "\n" ics t t))
    (goto-char (point-min))
    (icalendar-parse (current-buffer))))

(defun briefing-ical-main ()
  "Batch entry: read a feed on stdin, print today's events as one JSON line.
Command line: LOWER UPPER (epoch seconds)."
  (let* ((lower (string-to-number (or (nth 0 command-line-args-left) "0")))
         (upper (string-to-number (or (nth 1 command-line-args-left) "0")))
         (ics (with-temp-buffer
                (let ((coding-system-for-read 'utf-8))
                  (insert-file-contents "/dev/stdin"))
                (buffer-string)))
         (cal (and (string-match-p "BEGIN:VCALENDAR" ics) (briefing-ical-parse-string ics))))
    (setq command-line-args-left nil)
    (if (not cal)
        (progn (princ "BRIEFING-ERROR:the feed did not parse as a calendar\n") (kill-emacs 2))
      (let ((events (briefing-ical-events-between
                     cal lower upper (briefing-ical-calendar-owner cal))))
        (princ (concat "BRIEFING-JSON:" (json-serialize (vconcat events)) "\n"))))))

(provide 'briefing-ical)
;;; briefing-ical.el ends here
