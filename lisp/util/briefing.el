;;; briefing.el --- One read-only "what needs me" buffer for the morning  -*- lexical-binding: t; -*-

;;; Commentary:

;; `briefing' opens a buffer with one section per source (GitHub, calendar,
;; Slack, mail, Taskwarrior ...).  It only reads.  What you can do with a row:
;;
;;   RET  open the item in its own tool (PR -> review activity, else browser)
;;   o    open it in the browser
;;   y    copy its URL
;;   T    add a Taskwarrior task for it (never twice for the same item)
;;   r    refresh everything          gr  refresh the section at point
;;   n/p  next/previous row           TAB fold the section
;;
;; There is no dismissal: a source only lists what is still waiting on you,
;; so working an item down to zero removes it.
;;
;; A source is a function (CALLBACK) that eventually calls CALLBACK once with
;; either a list of `briefing-item's or (error . "message").  Sources run in
;; parallel; a slow or failing one only affects its own section.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defgroup briefing nil "Morning briefing." :group 'applications)

(defcustom briefing-task-command '("task")
  "Taskwarrior command (a list, so wrappers with arguments work)."
  :type '(repeat string))

(defcustom briefing-task-project "Work.ClearCo"
  "Project for tasks created with `T', unless the item names its own."
  :type '(choice (const nil) string))

(defcustom briefing-task-bucket "inbox"
  "GTD `type' for tasks created with `T' (untriaged items belong in the inbox)."
  :type 'string)

(defcustom briefing-task-tag "briefing"
  "Tag on tasks created from the briefing; used to find them again."
  :type 'string)

(defcustom briefing-board-limit 12
  "Rows shown in the Taskwarrior section."
  :type 'integer)

(defcustom briefing-github-stale-seconds 120
  "GitHub data younger than this is reused by a plain `briefing' open."
  :type 'integer)

(defcustom briefing-folded-sections '(wait)
  "Sections that start folded (TAB opens them)."
  :type '(repeat symbol))

(defcustom briefing-header-functions nil
  "Functions returning a string (or nil) to append to the header line."
  :type 'hook)

(defconst briefing-task-source-ids '(inbox next wait caltask task calerr)
  "Sections whose rows already are Taskwarrior tasks (so `T' has nothing to add).")

(defface briefing-section '((t :inherit font-lock-keyword-face :weight bold :height 1.1))
  "Section titles.")
(defface briefing-dim '((t :inherit shadow)) "Secondary text.")
(defface briefing-why '((t :inherit warning :weight bold)) "Why an item needs you.")
(defface briefing-tracked '((t :inherit success)) "Marker for items already a task.")

;;;; Items

(cl-defstruct (briefing-item (:constructor briefing-item-create) (:copier nil))
  source        ; symbol naming where the item comes from (part of its task marker)
  section       ; optional: the section it is shown in, when that differs from SOURCE
  key           ; stable string, unique within SOURCE (used to find its task)
  title who age ; strings; AGE is already formatted ("2h")
  task-title    ; optional: the title to use in a task, when TITLE carries extras
  why           ; short reason it needs you ("REVIEW", "DM", "unread")
  url           ; opened by `o' and `y'
  open          ; optional function of the item, run by RET (default: browse URL)
  project       ; optional Taskwarrior project, overriding `briefing-task-project'
  data)         ; whatever the source wants to keep (e.g. the gh-inbox item)

;;;; Sources

(defvar briefing-sources nil
  "Sections, in display order: list of (ID LABEL FETCH-FUNCTION).
FETCH-FUNCTION takes (CALLBACK FORCE); see the commentary.  FORCE is non-nil
for a manual refresh and means \"do not serve from a cache\".")

(defun briefing-register-source (id label fetch &optional before)
  "Add or replace the source ID shown as LABEL, fetched by FETCH.
New sources go last, or just ahead of the source BEFORE when it exists."
  (let ((cell (assq id briefing-sources)))
    (if cell
        (setcdr cell (list label fetch))
      (let ((entry (list id label fetch))
            (pos (and before (seq-position briefing-sources before
                                           (lambda (s b) (eq (car s) b))))))
        (setq briefing-sources
              (if pos
                  (append (seq-take briefing-sources pos) (list entry)
                          (nthcdr pos briefing-sources))
                (append briefing-sources (list entry))))))))

;;;; State

(defvar briefing--results nil
  "Alist (ID . RESULT).  RESULT is `loading', (error . MSG) or a list of items.")
(defvar briefing--generation 0
  "Bumped by every full refresh so a slow source cannot overwrite a newer one.")
(defvar briefing--refreshed nil "Float time of the last full refresh.")
(defvar briefing--tracked nil "Hash set of \"SOURCE KEY\" strings that already have a task.")
(defvar-local briefing--folded nil "Source ids whose section is folded in this buffer.")

(defconst briefing-buffer-name "*briefing*")

(defun briefing--result (id) (alist-get id briefing--results))

(defun briefing--section-of (item)
  "The section id ITEM is displayed in."
  (or (briefing-item-section item) (briefing-item-source item)))

(defun briefing--set-result (id result)
  (setf (alist-get id briefing--results) result))

;;;; Running sources

(defun briefing--fetch-one (source force)
  "Start SOURCE (a `briefing-sources' entry); its result lands in the buffer."
  (let ((id (car source)) (gen briefing--generation))
    (briefing--set-result id 'loading)
    (condition-case err
        (funcall (nth 2 source)
                 (lambda (result)
                   (when (= gen briefing--generation)
                     (briefing--set-result
                      id (if (or (null result) (listp result)) result
                           (cons 'error "bad result")))
                     (briefing--render)))
                 force)
      (error
       (briefing--set-result id (cons 'error (error-message-string err)))))))

(defun briefing--refresh-all (&optional force)
  "Refresh every source in parallel."
  (cl-incf briefing--generation)
  (setq briefing--refreshed (float-time))
  (briefing--load-tracked)
  (dolist (s briefing-sources) (briefing--fetch-one s force))
  (briefing--render))

;;;; Taskwarrior plumbing (shared by the board section and `T')

(defun briefing--task (&rest args)
  "Run Taskwarrior with ARGS; return (EXIT . OUTPUT).  Synchronous and quick."
  (with-temp-buffer
    (let ((code (apply #'call-process (car briefing-task-command) nil t nil
                       (append (cdr briefing-task-command)
                               '("rc.confirmation=no" "rc.verbose=nothing"
                                 "rc.json.array=on" "rc.bulk=0")
                               args))))
      (cons code (buffer-string)))))

(defun briefing--task-marker (item)
  "String that identifies ITEM inside a task description."
  (format "[%s %s]" (briefing-item-source item) (briefing-item-key item)))

(defun briefing--parse-json (string)
  "Parse STRING as JSON into alists/lists, or nil when it is not JSON."
  (condition-case nil
      (json-parse-string string :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil)
    (error nil)))

(defun briefing--load-tracked ()
  "Remember which items already have a pending task."
  (let* ((res (briefing--task "status:pending" "export"))
         (tasks (and (eq (car res) 0) (briefing--parse-json (cdr res))))
         (set (make-hash-table :test 'equal)))
    (dolist (tk tasks)
      (let ((d (alist-get 'description tk)))
        (when (and d (string-match "\\`\\[\\([a-z]+\\) \\([^]]+\\)\\]" d))
          (puthash (concat (match-string 1 d) " " (match-string 2 d)) t set))))
    (setq briefing--tracked set)))

(defun briefing--tracked-p (item)
  (and briefing--tracked
       (gethash (concat (symbol-name (briefing-item-source item)) " "
                        (briefing-item-key item))
                briefing--tracked)))

(defun briefing--add-task (item)
  "Create a task for ITEM.  Return t on success."
  (let* ((desc (format "%s %s" (briefing--task-marker item)
                       (or (briefing-item-task-title item) (briefing-item-title item) "")))
         (project (or (briefing-item-project item) briefing-task-project))
         (res (apply #'briefing--task
                     "add"
                     (append (and project (list (concat "project:" project)))
                             (list (concat "type:" briefing-task-bucket)
                                   (concat "+" briefing-task-tag)
                                   "--" desc)))))
    (when (eq (car res) 0)
      (when (briefing-item-url item)
        (briefing--task "+LATEST" "annotate" (briefing-item-url item)))
      (when briefing--tracked
        (puthash (concat (symbol-name (briefing-item-source item)) " "
                         (briefing-item-key item))
                 t briefing--tracked))
      t)))

;;;; Rendering

(defun briefing--pad (s width)
  (truncate-string-to-width (or s "") width nil ?\s "…"))

(defun briefing--row (item)
  "One display line for ITEM, with the item stored as a text property."
  (let ((line (concat
               (if (briefing--tracked-p item)
                   (propertize "✓ " 'face 'briefing-tracked)
                 "  ")
               (let ((why (briefing--pad (briefing-item-why item) 14)))
                 ;; Sources may bring their own faces (GitHub's tag colours).
                 (if (text-property-not-all 0 (length why) 'face nil why)
                     why
                   (propertize why 'face 'briefing-why)))
               " "
               (briefing--pad (briefing-item-title item) 64)
               " "
               (propertize (briefing--pad (briefing-item-who item) 16) 'face 'briefing-dim)
               " "
               (propertize (briefing--pad (briefing-item-age item) 5) 'face 'briefing-dim))))
    (propertize (string-trim-right line) 'briefing-item item)))

(defun briefing--insert-section (source)
  (pcase-let* ((`(,id ,label ,_) source)
               (res (briefing--result id))
               (folded (memq id briefing--folded))
               (count (and (listp res) (not (eq (car-safe res) 'error)) (length res))))
    (insert (propertize
             (format "%s %s%s\n" (if folded "▸" "▾") label
                     (cond ((eq res 'loading) "  loading…")
                           ((eq (car-safe res) 'error) "")
                           (count (format "  (%d)" count))
                           (t "")))
             'face 'briefing-section 'briefing-section id))
    (unless folded
      (cond
       ((eq res 'loading))
       ((eq (car-safe res) 'error)
        (insert (propertize (format "  ! %s\n" (cdr res)) 'face 'error)))
       ((null res) (insert (propertize "  nothing waiting\n" 'face 'briefing-dim)))
       (t (dolist (it res) (insert (briefing--row it) "\n")))))
    (insert "\n")))

(defun briefing--header ()
  (concat
   (format "Briefing · %s%s"
           (format-time-string "%a %b %-d")
           (if briefing--refreshed
               (format " · refreshed %s" (format-time-string "%H:%M" briefing--refreshed))
             ""))
   (mapconcat (lambda (f) (let ((x (ignore-errors (funcall f)))) (if x (concat " · " x) "")))
              briefing-header-functions "")
   "    r refresh · RET open · T task · ? help"))

(defun briefing--render ()
  "Redraw the buffer, keeping point on the same item or section."
  (when-let* ((buf (get-buffer briefing-buffer-name)))
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (item (get-text-property (point) 'briefing-item))
             (section (get-text-property (point) 'briefing-section))
             (line (line-number-at-pos))
             (win-start (and (get-buffer-window buf) (window-start (get-buffer-window buf)))))
        (erase-buffer)
        (setq header-line-format (briefing--header))
        (dolist (s briefing-sources) (briefing--insert-section s))
        (goto-char (point-min))
        (cond
         ((and item (briefing--goto-item item)))
         ((and section (briefing--goto-section section)))
         (t (forward-line (1- (min line (line-number-at-pos (point-max)))))))
        (when (and win-start (get-buffer-window buf))
          (set-window-start (get-buffer-window buf) (min win-start (point-max))))))))

(defun briefing--goto-item (item)
  "Move to the row whose item matches ITEM by source and key."
  (let ((pos (point-min)) found)
    (while (and (not found) (setq pos (next-single-property-change pos 'briefing-item)))
      (let ((it (get-text-property pos 'briefing-item)))
        (when (and it (eq (briefing-item-source it) (briefing-item-source item))
                   (equal (briefing-item-key it) (briefing-item-key item)))
          (setq found pos))))
    (when found (goto-char found) t)))

(defun briefing--goto-section (id)
  (let ((pos (point-min)) found)
    (while (and (not found) (setq pos (next-single-property-change pos 'briefing-section)))
      (when (eq (get-text-property pos 'briefing-section) id) (setq found pos)))
    (when found (goto-char found) t)))

;;;; Commands

(defun briefing--item ()
  (or (get-text-property (line-beginning-position) 'briefing-item)
      (user-error "No item on this line")))

(defun briefing-open ()
  "Open the item at point in its own tool, or its URL in the browser."
  (interactive)
  (if-let* ((sec (get-text-property (line-beginning-position) 'briefing-section)))
      (briefing-toggle-fold sec)
    (let ((item (briefing--item)))
      (cond ((briefing-item-open item) (funcall (briefing-item-open item) item))
            ((briefing-item-url item) (browse-url (briefing-item-url item)))
            (t (user-error "Nothing to open for this item"))))))

(defun briefing-browse ()
  "Open the item at point in the browser."
  (interactive)
  (let ((item (briefing--item)))
    (if (briefing-item-url item)
        (browse-url (briefing-item-url item))
      (user-error "This item has no URL"))))

(defun briefing-copy-url ()
  "Copy the URL of the item at point."
  (interactive)
  (let ((url (briefing-item-url (briefing--item))))
    (unless url (user-error "This item has no URL"))
    (kill-new url)
    (message "Copied %s" url)))

(defun briefing-task ()
  "Add a Taskwarrior task for the item at point, unless it already has one."
  (interactive)
  (let ((item (briefing--item)))
    (cond
     ((memq (briefing-item-source item) briefing-task-source-ids)
      (message "That is already a task (or not an item)"))
     ((briefing--tracked-p item) (message "Already a task"))
     ((briefing--add-task item)
      (briefing--render)
      (message "Task added in %s: %s" briefing-task-bucket (briefing-item-title item)))
     (t (message "Could not add the task (is `task' working?)")))))

(defun briefing-refresh ()
  "Refresh every section."
  (interactive)
  (briefing--refresh-all t)
  (message "Briefing: refreshing…"))

(defun briefing-refresh-section ()
  "Refresh only the section at point."
  (interactive)
  (let* ((id (or (get-text-property (line-beginning-position) 'briefing-section)
                 (when-let* ((it (get-text-property (line-beginning-position) 'briefing-item)))
                   (briefing--section-of it))))
         (source (and id (assq id briefing-sources))))
    (unless source (user-error "Not in a section"))
    (briefing--fetch-one source t)
    (briefing--render)))

(defun briefing-toggle-fold (&optional id)
  "Fold or unfold the section at point (or ID)."
  (interactive)
  (let ((id (or id (get-text-property (line-beginning-position) 'briefing-section)
                (when-let* ((it (get-text-property (line-beginning-position) 'briefing-item)))
                  (briefing--section-of it)))))
    (unless id (user-error "Not in a section"))
    (setq briefing--folded (if (memq id briefing--folded)
                               (delq id briefing--folded)
                             (cons id briefing--folded)))
    (briefing--render)
    (briefing--goto-section id)))

(defun briefing--step (dir)
  "Move to the next (1) or previous (-1) item row."
  (let ((start (point)) (done nil))
    (while (and (not done) (zerop (forward-line dir)))
      (when (get-text-property (point) 'briefing-item) (setq done t)))
    (unless done (goto-char start) (message "No more items"))))

(defun briefing--section-starts ()
  "Buffer positions of the section titles, in order."
  (let ((pos (point-min)) out)
    (while (setq pos (next-single-property-change pos 'briefing-section))
      (when (get-text-property pos 'briefing-section)
        (push pos out)))
    (when (get-text-property (point-min) 'briefing-section) (push (point-min) out))
    (sort (delete-dups out) #'<)))

(defun briefing-next-section ()
  "Move to the title of the next section."
  (interactive)
  (let* ((here (line-beginning-position))
         (target (seq-find (lambda (p) (> p here)) (briefing--section-starts))))
    (if target (goto-char target) (message "Last section"))))

(defun briefing-previous-section ()
  "Move to the title of this section, or of the previous one when already on it."
  (interactive)
  (let* ((here (line-beginning-position))
         (target (seq-find (lambda (p) (< p here)) (reverse (briefing--section-starts)))))
    (if target (goto-char target) (message "First section"))))

(defun briefing-next () (interactive) (briefing--step 1))
(defun briefing-previous () (interactive) (briefing--step -1))

(defun briefing-help ()
  "Show the keys."
  (interactive)
  (with-help-window "*briefing help*"
    (princ "Briefing: read-only. It lists what is waiting on you.\n\n")
    (princ "  RET   open the item in its own tool (PR: review activity; else browser)\n")
    (princ "        on a section title: fold it\n")
    (princ "  o     open in the browser\n")
    (princ "  y     copy the URL\n")
    (princ "  T     add a Taskwarrior task (type:inbox, tag +briefing); a ✓ marks items\n")
    (princ "        that already have one\n")
    (princ "  n p   next / previous row\n")
    (princ "  ]] [[ next / previous section\n")
    (princ "  TAB   fold the section\n")
    (princ "  r     refresh all sections     gr  refresh the section at point\n")
    (princ "  q     close\n\n")
    (princ "Nothing is ever sent, archived or changed at the source.\n")))

(defvar briefing-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'briefing-open)
    (define-key m (kbd "o") #'briefing-browse)
    (define-key m (kbd "y") #'briefing-copy-url)
    (define-key m (kbd "T") #'briefing-task)
    (define-key m (kbd "r") #'briefing-refresh)
    (define-key m (kbd "g") #'briefing-refresh)
    (define-key m (kbd "n") #'briefing-next)
    (define-key m (kbd "p") #'briefing-previous)
    (define-key m (kbd "TAB") #'briefing-toggle-fold)
    (define-key m (kbd "]]") #'briefing-next-section)
    (define-key m (kbd "[[") #'briefing-previous-section)
    (define-key m (kbd "q") #'quit-window)
    (define-key m (kbd "?") #'briefing-help)
    m))

(define-derived-mode briefing-mode special-mode "Briefing"
  "Major mode for the morning briefing.
\\{briefing-mode-map}"
  (setq truncate-lines t
        buffer-read-only t
        briefing--folded (copy-sequence briefing-folded-sections))
  (setq-local bookmark-make-record-function #'briefing--bookmark-record)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'briefing-mode 'motion)
    (evil-define-key* 'motion briefing-mode-map
      (kbd "RET") #'briefing-open
      (kbd "o") #'briefing-browse
      (kbd "y") #'briefing-copy-url
      (kbd "T") #'briefing-task
      (kbd "r") #'briefing-refresh
      (kbd "gr") #'briefing-refresh-section
      (kbd "n") #'briefing-next
      (kbd "p") #'briefing-previous
      (kbd "j") #'briefing-next
      (kbd "k") #'briefing-previous
      (kbd "TAB") #'briefing-toggle-fold
      (kbd "]]") #'briefing-next-section
      (kbd "[[") #'briefing-previous-section
      (kbd "q") #'quit-window
      (kbd "?") #'briefing-help)))

;;;; Bookmarks (so `activities' can save and restore the buffer)

(defun briefing--bookmark-record ()
  `("Briefing" (handler . briefing-bookmark-handler)))

(defun briefing-bookmark-handler (_bmk)
  "Reopen the briefing without refetching what is already there."
  (briefing--ensure-buffer)
  (briefing--render)
  (set-buffer briefing-buffer-name))

(put 'briefing-bookmark-handler 'bookmark-handler-type "Briefing")

;;;; Entry point

(defun briefing--ensure-buffer ()
  (let ((buf (get-buffer-create briefing-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'briefing-mode) (briefing-mode)))
    buf))

;;;###autoload
(defun briefing ()
  "Open the morning briefing.  A fresh open fetches; reopening shows what is there.
Press r to refresh by hand."
  (interactive)
  (let ((buf (briefing--ensure-buffer)))
    (switch-to-buffer buf)
    (if briefing--refreshed
        (briefing--render)
      (briefing--refresh-all))))

(provide 'briefing)
;;; briefing.el ends here
