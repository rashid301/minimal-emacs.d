;;; config-calendar.el --- Aggregated Google calendars (calfw + iCal) -*- lexical-binding: t; -*-

;; Secret iCal URLs live in auth-source (~/.authinfo, chmod 600), one per calendar:
;;   machine gcal-work     login ical password https://calendar.google.com/calendar/ical/.../private-.../basic.ics
;;   machine gcal-personal login ical password https://calendar.google.com/calendar/ical/.../private-.../basic.ics
;; Calendars without an entry are skipped.  Open the grid with C-c C c.

(defvar my/calendar-sources
  '(("gcal-work"     "#2a6fdb" "Work")
    ("gcal-personal" "#2a9d4b" "Personal"))
  "List of (AUTH-HOST COLOR NAME) iCal calendars to aggregate.")

(defun my/calendar--sources ()
  "Build calfw iCal sources for every calendar that has a URL in auth-source."
  (let (srcs)
    (dolist (c my/calendar-sources)
      (let ((url (auth-source-pick-first-password :host (nth 0 c) :user "ical")))
        (when (and url (string-prefix-p "http" url))
          (push (calfw-ical-create-source url (nth 2 c) (nth 1 c)) srcs))))
    (nreverse srcs)))

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

(defun my/calendar-open-browser ()
  "Open Google Calendar (work account) in the browser."
  (interactive)
  (browse-url "https://calendar.google.com/calendar/u/0/r/week"))

(global-set-key (kbd "C-c C c") #'my/calendar-open)
(global-set-key (kbd "C-c C b") #'my/calendar-open-browser)

;; Evil: calfw ships its own h/j/k/l/t/M/W/D/T/q keys; make that map override
;; evil's motion-state bindings instead of redefining them.
(with-eval-after-load 'evil
  (with-eval-after-load 'calfw
    (evil-set-initial-state 'calfw-calendar-mode 'motion)
    (evil-make-overriding-map calfw-calendar-mode-map 'motion)))

(provide 'config-calendar)
;;; config-calendar.el ends here
