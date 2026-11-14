;;; ref-open.el --- Open tickets, PRs and docs from anywhere in Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; One command, `ref-open', for "open this thing I am looking at", wherever
;; it is: an org note, a commit message in magit, a branch name, a task
;; description, a terminal, the clipboard.  It recognizes
;;
;;   DEV-33555                                Jira ticket key
;;   https://<site>.atlassian.net/browse/KEY  Jira URL
;;   https://<site>.atlassian.net/wiki/...    Confluence page
;;   https://docs.google.com/... drive...     Google Docs / Sheets / Slides
;;   https://github.com/OWNER/REPO/pull/N     pull request
;;   OWNER/REPO#N                             pull request shorthand
;;                                            (the form Taskwarrior review tasks use)
;;
;; and opens each in the best place we have: PRs in `pr-review', tickets and
;; documents in the browser for now.  The point of one dispatcher is that
;; "better place" becomes a one-line change (an Emacs ticket buffer, a
;; Confluence reader) without relearning any keys.
;;
;;   `ref-open'           at point; else the only/chosen one on the line; else a
;;                        list of every reference visible in the frame's windows
;;                        and the clipboard (type or paste to open anything);
;;                        else ask.  C-u: choose the action.
;;   embark               `C-.' on a reference offers the same actions.
;;   `ref-open-buttons-mode'  underlines references in the buffer; click opens.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup ref-open nil
  "Open references to tickets, PRs and documents."
  :group 'tools
  :prefix "ref-open-")

(defcustom ref-open-jira-projects '("DEV")
  "Jira project keys recognized in bare keys like DEV-123.
Kept explicit because text like UTF-8 or ISO-8601 looks just like a key."
  :type '(repeat string))

(defcustom ref-open-github-owners '("clearcompany")
  "GitHub owners recognized in the OWNER/REPO#N shorthand.
Kept explicit because paths like docs/readme#2 look just like it."
  :type '(repeat string))

(defface ref-open-link '((t :inherit link))
  "Face of references marked by `ref-open-buttons-mode'.")

(declare-function gh-inbox-item-create "gh-inbox")
(declare-function gh-inbox-review-pr-review "gh-inbox-review")
(declare-function gh-inbox-review-open "gh-inbox-review")
(declare-function gh-inbox-review-threads "gh-inbox-review")
(declare-function gh-inbox-review-claude "gh-inbox-review")
(defvar gh-inbox-jira-base-url)

;;;; Recognizing references

(cl-defstruct (ref-open-ref (:constructor ref-open-ref--make (kind text beg end data)))
  kind text beg end data)

(defconst ref-open--url-char "[^] \t\n)>\"']"
  "One character a URL may contain.  (`]' first: that is how it is literal.)")

(defconst ref-open--tail (concat ref-open--url-char "*")
  "Zero or more URL characters.")

(defun ref-open--specs ()
  "List of (KIND REGEXP DATA-FUNCTION), most specific first.
DATA-FUNCTION runs right after a match and returns an alist."
  (let ((tail ref-open--tail))
    (list
     (list 'jira-url
           (concat "https://[A-Za-z0-9.-]+\\.atlassian\\.net/browse/"
                   "\\([A-Z][A-Z0-9]+-[0-9]+\\)" tail)
           (lambda () `((key . ,(match-string 1)) (url . ,(match-string 0)))))
     (list 'confluence
           (concat "https://[A-Za-z0-9.-]+\\.atlassian\\.net/wiki/" ref-open--url-char "+")
           (lambda () `((url . ,(match-string 0)))))
     (list 'gdoc
           (concat "https://\\(?:docs\\|drive\\)\\.google\\.com/" ref-open--url-char "+")
           (lambda () `((url . ,(match-string 0)))))
     (list 'github-pr
           (concat "https://github\\.com/\\([^/ \t\n]+\\)/\\([^/ \t\n]+\\)/pull/\\([0-9]+\\)" tail)
           (lambda () `((repo . ,(concat (match-string 1) "/" (match-string 2)))
                        (number . ,(string-to-number (match-string 3)))
                        (url . ,(match-string 0)))))
     (list 'github-issue
           (concat "https://github\\.com/\\([^/ \t\n]+\\)/\\([^/ \t\n]+\\)/issues/\\([0-9]+\\)" tail)
           (lambda () `((url . ,(match-string 0)))))
     (list 'github-pr
           (concat "\\b\\(" (regexp-opt ref-open-github-owners)
                   "/[A-Za-z0-9][A-Za-z0-9_.-]*\\)#\\([0-9]+\\)\\b")
           (lambda () `((repo . ,(match-string 1))
                        (number . ,(string-to-number (match-string 2)))
                        (url . ,(format "https://github.com/%s/pull/%s"
                                        (match-string 1) (match-string 2))))))
     (list 'jira
           (concat "\\b\\(" (regexp-opt ref-open-jira-projects) "-[0-9]+\\)\\b")
           (lambda () `((key . ,(match-string 1))))))))

(defun ref-open--trim-end (beg end)
  "END moved back over trailing sentence punctuation after BEG."
  (let ((case-fold-search nil))
    (while (and (> end beg)
                (memq (char-before end) '(?. ?, ?\; ?: ?! ??)))
      (setq end (1- end)))
    end))

(defun ref-open-parse (string)
  "All references in STRING as a list of `ref-open-ref', in text order.
A reference inside another (a ticket key within a Jira URL) is dropped."
  (let (found)
    (with-temp-buffer
      (insert string)
      (dolist (spec (ref-open--specs))
        (goto-char (point-min))
        (let ((case-fold-search nil))
          (while (re-search-forward (nth 1 spec) nil t)
            (let* ((beg (match-beginning 0))
                   (end (ref-open--trim-end beg (match-end 0)))
                   (data (funcall (nth 2 spec))))
              (unless (seq-find (lambda (r) (and (< beg (ref-open-ref-end r))
                                                 (> end (ref-open-ref-beg r))))
                                found)
                (push (ref-open-ref--make (car spec)
                                          (buffer-substring-no-properties beg end)
                                          (1- beg) (1- end) data)
                      found)))))))
    (sort found (lambda (a b) (< (ref-open-ref-beg a) (ref-open-ref-beg b))))))

(defun ref-open--shift (refs offset)
  "REFS with beg/end moved by OFFSET (string index to buffer position)."
  (mapc (lambda (r)
          (cl-incf (ref-open-ref-beg r) offset)
          (cl-incf (ref-open-ref-end r) offset))
        refs))

(defun ref-open--refs-in (beg end)
  "References in the buffer between BEG and END, with buffer positions."
  (ref-open--shift (ref-open-parse (buffer-substring-no-properties beg end)) beg))

(defun ref-open--label (ref)
  "Short description of REF for menus."
  (format "%-10s %s" (ref-open-ref-kind ref) (ref-open-ref-text ref)))

;;;; Opening them

(defun ref-open--jira-url (key)
  "Browse URL of ticket KEY."
  (unless (and (boundp 'gh-inbox-jira-base-url) gh-inbox-jira-base-url)
    (user-error "Set `gh-inbox-jira-base-url' (e.g. https://site.atlassian.net/browse/)"))
  (concat gh-inbox-jira-base-url key))

(defun ref-open--pr-item (ref)
  "A `gh-inbox-item' standing for the PR in REF."
  (require 'gh-inbox-review)
  (let ((d (ref-open-ref-data ref)))
    (gh-inbox-item-create :kind 'pr :repo (alist-get 'repo d)
                          :number (alist-get 'number d) :url (alist-get 'url d))))

(defun ref-open--browse (ref)
  "Open REF in the browser."
  (let ((d (ref-open-ref-data ref)))
    (browse-url (pcase (ref-open-ref-kind ref)
                  ('jira (ref-open--jira-url (alist-get 'key d)))
                  ('jira-url (ref-open--jira-url (alist-get 'key d)))
                  (_ (alist-get 'url d))))))

(defun ref-open-actions (ref)
  "Alist (LABEL . FUNCTION) of things to do with REF; the first is the default."
  (let ((browse (cons "browser" #'ref-open--browse)))
    (pcase (ref-open-ref-kind ref)
      ('github-pr
       (list (cons "pr-review (read the PR, comment, submit)"
                   (lambda (r) (gh-inbox-review-pr-review (ref-open--pr-item r))))
             (cons "review activity (worktree + diff + threads)"
                   (lambda (r) (gh-inbox-review-open (ref-open--pr-item r))))
             (cons "unresolved threads"
                   (lambda (r) (gh-inbox-review-threads (ref-open--pr-item r))))
             (cons "Claude on this PR"
                   (lambda (r) (gh-inbox-review-claude (ref-open--pr-item r))))
             browse))
      (_ (list browse)))))

(defun ref-open-dispatch (ref &optional choose)
  "Open REF with its default action, or with a chosen one when CHOOSE."
  (let* ((actions (ref-open-actions ref))
         (action (if (and choose (cdr actions))
                     (assoc (completing-read (format "%s: " (ref-open--label ref))
                                             (mapcar #'car actions) nil t)
                            actions)
                   (car actions))))
    (funcall (cdr action) ref)))

;;;; Finding the reference to open

(defun ref-open--at-point ()
  "The reference under point, or nil."
  (let ((pt (point)))
    (seq-find (lambda (r) (and (>= pt (ref-open-ref-beg r)) (<= pt (ref-open-ref-end r))))
              (ref-open--refs-in (line-beginning-position) (line-end-position)))))

(defun ref-open--pick (refs prompt)
  "One of REFS: the only one, or chosen from a menu with PROMPT."
  (if (cdr refs)
      (let ((table (mapcar (lambda (r) (cons (ref-open--label r) r)) refs)))
        (cdr (assoc (completing-read prompt (mapcar #'car table) nil t) table)))
    (car refs)))

(defun ref-open--visible-refs ()
  "References visible in any window of the selected frame, without duplicates.
Each is a cons (REF . BUFFER-NAME).  An activity's panes (a diff, a PR, a task
list, a terminal) are all in view, so this finds what you are looking at
even when point is on nothing."
  (let (seen out)
    (dolist (win (window-list nil 'no-minibuf))
      (with-current-buffer (window-buffer win)
        (save-excursion
          (dolist (r (ref-open--refs-in (window-start win) (min (window-end win t) (point-max))))
            (let ((key (cons (ref-open-ref-kind r) (ref-open-ref-text r))))
              (unless (member key seen)
                (push key seen)
                (push (cons r (buffer-name)) out)))))))
    (nreverse out)))

(defun ref-open--choose-visible (candidates)
  "Pick a reference from CANDIDATES (REF . SOURCE) or type/paste one.
Returns a `ref-open-ref', or nil when what was typed has no reference."
  (let* ((table (mapcar (lambda (c)
                          (cons (format "%s   [%s]" (ref-open--label (car c)) (cdr c))
                                (car c)))
                        candidates))
         (input (completing-read "Open (pick, or type/paste a ticket, PR or link): "
                                 (mapcar #'car table) nil nil)))
    (or (cdr (assoc input table))
        (car (ref-open-parse input)))))

(defun ref-open--find (&optional ask)
  "The reference to open: at point, on the line, in view, or asked.
Order: under point; the only (or a chosen) one on the line; any visible in the
selected frame's windows plus the clipboard; finally a prompt.  With ASK, go
straight to the prompt."
  (let* ((line-refs (ref-open--refs-in (line-beginning-position) (line-end-position)))
         (clip (ignore-errors (current-kill 0 t)))
         (clip-refs (and (stringp clip) (ref-open-parse clip))))
    (or (and (not ask) (ref-open--at-point))
        (and (not ask) line-refs (ref-open--pick line-refs "Open: "))
        (let* ((candidates (append (mapcar (lambda (r) (cons r "clipboard")) clip-refs)
                                   (unless ask (ref-open--visible-refs)))))
          (if candidates
              (or (ref-open--choose-visible candidates)
                  (user-error "No ticket, PR or link in that text"))
            (let* ((input (read-string "Open (ticket, PR or link): "))
                   (refs (ref-open-parse input)))
              (or (ref-open--pick refs "Open: ")
                  (user-error "No ticket, PR or link in \"%s\"" input))))))))

;;;###autoload
(defun ref-open (&optional choose)
  "Open the ticket, PR or document at point (or on the line, or the clipboard).
With prefix argument CHOOSE, pick what to do with it."
  (interactive "P")
  (ref-open-dispatch (ref-open--find) choose))

;;;; embark

(defun ref-open-embark-target ()
  "Embark target finder: the reference at point."
  (when-let* ((r (ref-open--at-point)))
    `(ref-open ,(ref-open-ref-text r) . (,(ref-open-ref-beg r) . ,(ref-open-ref-end r)))))

(defun ref-open-embark-open (text)
  "Embark action: open the reference TEXT."
  (if-let* ((r (car (ref-open-parse text))))
      (ref-open-dispatch r)
    (user-error "Not a reference: %s" text)))

(defun ref-open-embark-choose (text)
  "Embark action: open the reference TEXT, choosing what to do."
  (if-let* ((r (car (ref-open-parse text))))
      (ref-open-dispatch r t)
    (user-error "Not a reference: %s" text)))

(defun ref-open-embark-browse (text)
  "Embark action: open the reference TEXT in the browser."
  (if-let* ((r (car (ref-open-parse text))))
      (ref-open--browse r)
    (user-error "Not a reference: %s" text)))

;;;###autoload
(defun ref-open-setup-embark ()
  "Teach embark about references."
  (with-eval-after-load 'embark
    (defvar embark-target-finders)
    (defvar embark-keymap-alist)
    (defvar ref-open-embark-map
      (let ((m (make-sparse-keymap)))
        (define-key m (kbd "RET") #'ref-open-embark-open)
        (define-key m (kbd "o") #'ref-open-embark-choose)
        (define-key m (kbd "b") #'ref-open-embark-browse)
        m))
    (add-to-list 'embark-target-finders #'ref-open-embark-target)
    (add-to-list 'embark-keymap-alist '(ref-open . ref-open-embark-map))))

;;;; Buttons

(defvar ref-open-button-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'ref-open-click)
    (define-key m [mouse-2] #'ref-open-click)
    m)
  "Keymap on marked references: clicks only, so no key is taken from the buffer.")

(defun ref-open-click (event)
  "Open the reference clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (ref-open))

(defun ref-open--fontify (beg end)
  "Mark references between BEG and END (a `jit-lock' function)."
  (save-excursion
    (let ((beg (progn (goto-char beg) (line-beginning-position)))
          (end (progn (goto-char end) (line-end-position))))
      (remove-overlays beg end 'ref-open t)
      (dolist (r (ref-open--refs-in beg end))
        (let ((ov (make-overlay (ref-open-ref-beg r) (ref-open-ref-end r) nil t nil)))
          (overlay-put ov 'ref-open t)
          (overlay-put ov 'evaporate t)
          (overlay-put ov 'face 'ref-open-link)
          (overlay-put ov 'mouse-face 'highlight)
          (overlay-put ov 'keymap ref-open-button-map)
          (overlay-put ov 'help-echo
                       (format "%s: mouse-1 or SPC o o to open" (ref-open--label r))))))))

;;;###autoload
(define-minor-mode ref-open-buttons-mode
  "Underline tickets, PRs and document links; clicking one opens it.
Only mouse buttons are bound, so no key is taken from the buffer."
  :lighter nil
  (if ref-open-buttons-mode
      (progn (jit-lock-register #'ref-open--fontify)
             (ref-open--fontify (point-min) (point-max)))
    (jit-lock-unregister #'ref-open--fontify)
    (remove-overlays (point-min) (point-max) 'ref-open t)))

(provide 'ref-open)
;;; ref-open.el ends here
