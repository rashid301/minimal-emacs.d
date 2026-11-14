;;; config-calendar.el --- Aggregated Google calendars (calfw + iCal) -*- lexical-binding: t; -*-

;; Secret iCal URLs live in auth-source (~/.authinfo, chmod 600), one per calendar:
;;   machine gcal-work     login ical password https://calendar.google.com/calendar/ical/.../private-.../basic.ics
;;   machine gcal-personal login ical password https://calendar.google.com/calendar/ical/.../private-.../basic.ics
;; Calendars without an entry are skipped.  Open the grid with C-c C c.

(defvar my/calendar-sources
  '(("gcal-work"     "#2a6fdb" "Work")
    ("gcal-personal" "#2a9d4b" "Personal"))
  "List of (AUTH-HOST COLOR NAME) iCal calendars to aggregate.")

(defvar my/calendar-hidden nil
  "Names (the NAME in `my/calendar-sources') of calendars currently hidden.")

(defun my/calendar--sources ()
  "Build calfw iCal sources for every calendar that has a URL in auth-source.
Each source returns no events while its name is in `my/calendar-hidden'."
  (let (srcs)
    (dolist (c my/calendar-sources)
      (let ((url (auth-source-pick-first-password :host (nth 0 c) :user "ical")))
        (when (and url (string-prefix-p "http" url))
          (let* ((name (nth 2 c))
                 (src (calfw-ical-create-source url name (nth 1 c)))
                 (data (calfw-source-data src)))
            ;; `cl-struct-slot-value', not `(setf (calfw-source-data ..))': calfw isn't loaded when
            ;; this file is, so setf wouldn't know the accessor and would expand to a void function.
            (setf (cl-struct-slot-value 'calfw-source 'data src)
                  (lambda (&rest args)
                    (unless (member name my/calendar-hidden)
                      (apply data args))))
            (push src srcs)))))
    (nreverse srcs)))

(defun my/calendar-filter ()
  "Choose which calendar to show: All, or just one of `my/calendar-sources'."
  (interactive)
  (let* ((names (mapcar (lambda (c) (nth 2 c)) my/calendar-sources))
         (choice (completing-read "Show calendar: " (cons "All" names) nil t)))
    (setq my/calendar-hidden
          (if (equal choice "All")
              nil
            (remove choice names)))
    (message "Calendar: showing %s" choice)
    (when (derived-mode-p 'calfw-calendar-mode)
      (calfw-refresh-calendar-buffer nil))))

(use-package calfw
  :ensure t
  :commands (calfw-open-calendar-buffer)
  :custom
  (calfw-display-calendar-holidays nil)
  (calfw-fchar-junction ?╋)
  (calfw-fchar-vertical-line ?┃)
  (calfw-fchar-horizontal-line ?━)
  (calfw-fchar-left-junction ?┣)
  (calfw-fchar-right-junction ?┫)
  (calfw-fchar-top-junction ?┯)
  (calfw-fchar-top-left-corner ?┏)
  (calfw-fchar-top-right-corner ?┓))

(use-package calfw-ical
  :ensure t
  :after calfw)

(defun my/calendar-open ()
  "Open the aggregated calendar grid."
  (interactive)
  (require 'calfw)
  (require 'calfw-ical)
  (let ((srcs (my/calendar--sources)))
    (unless srcs
      (user-error "No calendar URLs in auth-source (see config-calendar.el)"))
    (calfw-open-calendar-buffer :contents-sources srcs :view 'week)))

(defun my/calendar--default-sources (args)
  "Filter ARGS of `calfw-open-calendar-buffer', adding our iCal sources if none given."
  (if (plist-member args :contents-sources)
      args
    (require 'calfw-ical)
    (let ((srcs (my/calendar--sources)))
      (if srcs
          (append args (list :contents-sources srcs))
        args))))

(with-eval-after-load 'calfw
  (advice-add 'calfw-open-calendar-buffer :filter-args #'my/calendar--default-sources))

(defun my/calendar-open-browser ()
  "Open Google Calendar (work account) in the browser."
  (interactive)
  (browse-url "https://calendar.google.com/calendar/u/0/r/week"))

(global-set-key (kbd "C-c C c") #'my/calendar-open)
(global-set-key (kbd "C-c C b") #'my/calendar-open-browser)

;; Evil: calfw ships its own h/j/k/l/t/M/W/D/T/q keys; make that map override
;; evil's motion-state bindings instead of redefining them.
(with-eval-after-load 'calfw
  (define-key calfw-calendar-mode-map (kbd "F") #'my/calendar-filter))

(with-eval-after-load 'evil
  (with-eval-after-load 'calfw
    (evil-set-initial-state 'calfw-calendar-mode 'motion)
    (evil-make-overriding-map calfw-calendar-mode-map 'motion)))

(provide 'config-calendar)
;;; config-calendar.el ends here
