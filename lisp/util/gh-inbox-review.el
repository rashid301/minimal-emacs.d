;;; gh-inbox-review.el --- Review a PR as a worktree activity  -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything that happens after you press RET on a row of `gh-inbox'.
;;
;; `gh-inbox-review-open'
;;     Find (or create, through Worktrunk) a worktree for the PR branch,
;;     bring it up to date, and open it as an `activities' activity: a
;;     magit diff of the PR on the left, `pr-review' (description, existing
;;     threads, inline commenting) on the right.  Re-reviews diff only what
;;     changed since your last review.
;;
;; `gh-inbox-review-threads'
;;     Unresolved review threads as a `compilation-minor-mode' buffer
;;     (`path:line: @author: comment'), so \\[next-error] walks through the
;;     feedback in the real files of the worktree.
;;
;; `gh-inbox-review-claude'
;;     A Claude session in the worktree with a ready-made prompt: a read-only
;;     first-pass review (findings go to an org file; nothing is posted to
;;     GitHub), or - on your own PR - addressing the unresolved threads or
;;     fixing failing CI.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'bookmark)
(require 'subr-x)
(require 'gh-inbox)

(declare-function worktrunk--args "worktrunk")
(declare-function worktrunk--run-async "worktrunk")
(declare-function worktrunk-activities-open "worktrunk-activities")
(declare-function worktrunk-activities--name "worktrunk-activities")
(declare-function worktrunk-activities--create "worktrunk-activities")
(declare-function activities-named "activities")
(declare-function activities-resume "activities")
(declare-function activities-activity-default "activities")
(declare-function activities-activity-name "activities")
(declare-function activities-current "activities")
(declare-function activities-define "activities")
(declare-function worktrunk-activities--new-container "worktrunk-activities")
(declare-function worktrunk-activities--discard-container "worktrunk-activities")
(defvar activities-activities)
(declare-function compilation--flush-parse "compile")
(declare-function compile-goto-error "compile")
(declare-function magit-diff-range "magit-diff")
(declare-function pr-review "pr-review")
(declare-function ghostel-claude--start "ghostel-claude")
(declare-function ghostel-claude--show "ghostel-claude")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")
(defvar magit-display-buffer-function)
(defvar worktrunk-executable)
(defvar worktrunk-activities-open-function)
(defvar worktrunk-activities-terminal-function)

;;;; Customization

(defcustom gh-inbox-review-repo-directories nil
  "Alist of (OWNER/REPO . DIRECTORY) naming each repo's main checkout.
Entries here win over auto-detection and over the cache."
  :type '(alist :key-type string :value-type directory)
  :group 'gh-inbox)

(defcustom gh-inbox-review-search-roots nil
  "Directories whose subdirectories are searched for clones of PR repos.
Known `project.el' projects are always searched."
  :type '(repeat directory)
  :group 'gh-inbox)

(defcustom gh-inbox-review-cache-file
  (expand-file-name "var/gh-inbox-repos.eld" user-emacs-directory)
  "File remembering which directory holds which repo."
  :type 'file
  :group 'gh-inbox)

(defcustom gh-inbox-review-notes-directory
  (expand-file-name "var/gh-reviews/" user-emacs-directory)
  "Where Claude's review findings (one org file per PR) are written."
  :type 'directory
  :group 'gh-inbox)

(defcustom gh-inbox-review-skills
  '(("clearcompany/clearcompany"
     (review . "/insync:clearco-pr-review")
     (address . "/insync:clearco-feedback-resolver")))
  "Claude skills to run instead of the built-in prompts, per repo.
Each entry is (OWNER/REPO (review . SKILL) (address . SKILL)), where SKILL
is a slash command that takes the PR number, like the InSync plugin's
`/insync:clearco-pr-review N'.  Repos or modes without an entry (CI fixing
always) fall back to the prompts in this file."
  :type '(alist :key-type string
                :value-type (alist :key-type (choice (const review) (const address))
                                   :value-type string))
  :group 'gh-inbox)

(defcustom gh-inbox-review-skill-output-dir nil
  "Where the review skill writes its drafts, for `gh-inbox-review-notes'.
The skill puts `<N>-review.md' under it (in a ticket subfolder).  Its
findings are also an unsubmitted pending review on the PR itself."
  :type '(choice (const nil) directory)
  :group 'gh-inbox)

(defcustom gh-inbox-review-right-pane 'pr-review
  "What the right half of a review activity shows.
`pr-review' uses the pr-review package when installed, `threads' always
shows the unresolved-thread list, nil leaves the right side empty."
  :type '(choice (const pr-review) (const threads) (const nil))
  :group 'gh-inbox)

(defcustom gh-inbox-review-update-worktree t
  "When non-nil, fast-forward a clean PR worktree to the PR's latest push."
  :type 'boolean
  :group 'gh-inbox)

;;;; Finding the local clone of a repo

(defvar gh-inbox-review--cache nil
  "Alist (OWNER/REPO . DIR) learned at run time.  Loaded lazily.")
(defvar gh-inbox-review--cache-loaded nil)

(defun gh-inbox-review--load-cache ()
  "Load the repo/directory cache once."
  (unless gh-inbox-review--cache-loaded
    (setq gh-inbox-review--cache-loaded t)
    (when (file-readable-p gh-inbox-review-cache-file)
      (setq gh-inbox-review--cache
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents gh-inbox-review-cache-file)
                  (let ((d (read (current-buffer)))) (and (listp d) d)))
              (error nil))))))

(defun gh-inbox-review--remember (repo dir)
  "Remember that REPO lives in DIR."
  (gh-inbox-review--load-cache)
  (setf (alist-get repo gh-inbox-review--cache nil nil #'equal) dir)
  (condition-case nil
      (progn
        (make-directory (file-name-directory gh-inbox-review-cache-file) t)
        (with-temp-file gh-inbox-review-cache-file
          (prin1 gh-inbox-review--cache (current-buffer))))
    (error nil)))

(defun gh-inbox-review--origin-repo (dir)
  "OWNER/REPO of the `origin' remote of the main checkout DIR, or nil.
Reads .git/config directly: no git process, so it is fast on any filesystem.
Linked worktrees (where .git is a file) return nil."
  (let ((cfg (expand-file-name ".git/config" dir)))
    (when (file-readable-p cfg)
      (with-temp-buffer
        (insert-file-contents cfg)
        (goto-char (point-min))
        (when (re-search-forward "^\\[remote \"origin\"\\]" nil t)
          (let ((end (save-excursion
                       (or (and (re-search-forward "^\\[" nil t) (match-beginning 0))
                           (point-max)))))
            (when (re-search-forward "^[ \t]*url[ \t]*=[ \t]*\\(.+?\\)[ \t]*$" end t)
              (let ((url (match-string 1)))
                (when (string-match
                       "github\\.com[:/]\\([^/]+\\)/\\([^/]+?\\)\\(?:\\.git\\)?/?\\'" url)
                  (concat (match-string 1 url) "/" (match-string 2 url)))))))))))

(defun gh-inbox-review--candidate-dirs ()
  "Directories that might be the main checkout of some repo."
  (let ((dirs nil))
    (dolist (root (ignore-errors (project-known-project-roots)))
      (push (directory-file-name root) dirs))
    (dolist (root gh-inbox-review-search-roots)
      (when (file-directory-p root)
        (dolist (d (directory-files root t "\\`[^.]" t))
          (when (file-directory-p d) (push d dirs)))))
    (delete-dups (nreverse dirs))))

(defun gh-inbox-review-repo-directory (repo &optional no-prompt)
  "Main checkout of REPO (OWNER/REPO): configured, cached, found or asked.
With NO-PROMPT, return nil instead of asking where the clone is."
  (gh-inbox-review--load-cache)
  (let ((configured (cdr (assoc-string repo gh-inbox-review-repo-directories t)))
        (cached (cdr (assoc-string repo gh-inbox-review--cache t))))
    (cond
     (configured (file-name-as-directory (expand-file-name configured)))
     ((and cached (file-directory-p cached)) cached)
     (t
      (let ((hit (seq-find (lambda (d)
                             (equal (downcase (or (gh-inbox-review--origin-repo d) ""))
                                    (downcase repo)))
                           (gh-inbox-review--candidate-dirs))))
        (when (and (null hit) (not no-prompt))
          (setq hit (read-directory-name
                     (format "Local clone of %s: " repo) nil nil t)))
        (when hit
          (setq hit (file-name-as-directory (expand-file-name hit)))
          (gh-inbox-review--remember repo hit))
        hit)))))

;;;; Async git

(defun gh-inbox-review--git (dir args callback)
  "Run git ARGS in DIR asynchronously; CALLBACK gets (OK OUTPUT)."
  (let* ((default-directory (file-name-as-directory dir))
         (buf (generate-new-buffer " *gh-inbox-git*")))
    (make-process
     :name "gh-inbox-git" :buffer buf :noquery t :connection-type 'pipe
     :command (cons "git" args)
     :sentinel
     (lambda (p _e)
       (when (memq (process-status p) '(exit signal))
         (let ((out (with-current-buffer buf (string-trim (buffer-string))))
               (ok (and (eq (process-status p) 'exit)
                        (eq (process-exit-status p) 0))))
           (kill-buffer buf)
           (funcall callback ok out)))))))

(defun gh-inbox-review--sync-worktree (path item callback)
  "Fetch ITEM's branches in worktree PATH, fast-forward if clean, then CALLBACK.
Failures are reported but never block: the user can still read the diff."
  (let ((base (gh-inbox-item-base item))
        (head (gh-inbox-item-head item)))
    (gh-inbox-review--git
     path (list "fetch" "--quiet" "origin" base head)
     (lambda (ok out)
       (unless ok (message "gh-inbox: fetch failed (%s); using local state"
                           (truncate-string-to-width out 80)))
       (if (not (and ok gh-inbox-review-update-worktree))
           (funcall callback)
         (gh-inbox-review--git
          path '("status" "--porcelain")
          (lambda (ok2 status)
            (if (not (and ok2 (string-empty-p status)))
                (funcall callback)
              (gh-inbox-review--git
               path (list "merge" "--ff-only" "--quiet" (concat "origin/" head))
               (lambda (_ok _o) (funcall callback)))))))))))

;;;; Worktrees

;; `wt list' takes a second or two on /mnt repos, so it never runs
;; synchronously here: lookups are asynchronous, and the results are cached
;; for the places (like the threads buffer) that only want a best guess.

(defvar gh-inbox-review--wt-cache (make-hash-table :test #'equal)
  "Repo root -> worktrees (alists of branch and path) from the last lookup.")

(defun gh-inbox-review--parse-worktrees (json)
  "Parse `wt list --format json' output JSON into ((branch . B) (path . P)) alists."
  (let* ((data (condition-case nil
                   (json-parse-string json :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil)
                 (error nil))))
    (delq nil
          (mapcar (lambda (item)
                    (let ((path (gh-inbox--g item 'worktree 'path)))
                      (and path `((branch . ,(alist-get 'branch item)) (path . ,path)))))
                  (alist-get 'items data)))))

(defun gh-inbox-review--find-branch-path (worktrees branch)
  "Path of the entry for BRANCH in WORKTREES, or nil."
  (and branch
       (alist-get 'path (seq-find (lambda (w) (equal (alist-get 'branch w) branch))
                                  worktrees))))

(defun gh-inbox-review--worktrees-async (root callback)
  "List the worktrees of the repo at ROOT without blocking; CALLBACK gets them.
CALLBACK receives nil when the lookup fails."
  (require 'worktrunk)
  (let* ((default-directory (file-name-as-directory (expand-file-name root)))
         (buf (generate-new-buffer " *gh-inbox-wt*")))
    (make-process
     ;; A pipe, not a pty: the `wt' wrapper only maps D:/ paths back to
     ;; /mnt/d/ when stdout is not a terminal.
     :name "gh-inbox-wt" :buffer buf :noquery t :connection-type 'pipe
     :command (cons worktrunk-executable
                    (worktrunk--args root '("list" "--format" "json")))
     :sentinel
     (lambda (p _e)
       (when (memq (process-status p) '(exit signal))
         (let* ((ok (and (eq (process-status p) 'exit) (eq (process-exit-status p) 0)))
                (out (with-current-buffer buf (buffer-string)))
                (wts (and ok (gh-inbox-review--parse-worktrees out))))
           (kill-buffer buf)
           (when wts (puthash root wts gh-inbox-review--wt-cache))
           (funcall callback wts)))))))

(defun gh-inbox-review--ensure-worktree (item callback)
  "Make sure ITEM's PR branch has a worktree, then call CALLBACK with its path."
  (require 'worktrunk)
  (let* ((repo (gh-inbox-item-repo item))
         (root (gh-inbox-review-repo-directory repo))
         (head (gh-inbox-item-head item)))
    (gh-inbox-review--worktrees-async
     root
     (lambda (wts)
       (if-let* ((existing (gh-inbox-review--find-branch-path wts head)))
           (funcall callback existing)
         (worktrunk--run-async
          root (list "switch" (format "pr:%d" (gh-inbox-item-number item)) "--no-cd")
          (lambda ()
            (gh-inbox-review--worktrees-async
             root
             (lambda (wts2)
               (if-let* ((path (gh-inbox-review--find-branch-path wts2 head)))
                   (funcall callback path)
                 (message "gh-inbox: worktree for %s not found after switch (see *worktrunk*)"
                          head)))))))))))

(defun gh-inbox-review--ensure-details (item callback)
  "Make sure ITEM knows its branches, then call CALLBACK.
PRs known only from a notification (a mention, a thread you joined) carry no
branch data; fetch it with `gh pr view'."
  (if (and (gh-inbox-item-head item) (gh-inbox-item-base item))
      (funcall callback)
    (gh-inbox--gh
     (list "pr" "view" (number-to-string (gh-inbox-item-number item))
           "-R" (gh-inbox-item-repo item)
           "--json" "headRefName,baseRefName,headRefOid,author,isDraft")
     (lambda (ok out err)
       (if-let* ((j (and ok (gh-inbox--parse out))))
           (progn
             (setf (gh-inbox-item-head item) (alist-get 'headRefName j)
                   (gh-inbox-item-base item) (alist-get 'baseRefName j)
                   (gh-inbox-item-head-oid item) (alist-get 'headRefOid j)
                   (gh-inbox-item-author item)
                   (or (gh-inbox-item-author item) (gh-inbox--g j 'author 'login)))
             (funcall callback))
         (message "gh-inbox: could not read PR details: %s"
                  (truncate-string-to-width (string-trim err) 120)))))))

(defun gh-inbox-review--prepare (item callback)
  "Worktree for ITEM, synced with GitHub, passed to CALLBACK."
  (gh-inbox-review--ensure-details
   item
   (lambda ()
     (gh-inbox-review--ensure-worktree
      item
      (lambda (path)
        (gh-inbox-review--sync-worktree path item (lambda () (funcall callback path))))))))

;;;; Review activity

(defun gh-inbox-review--range (item)
  "Revision range to review for ITEM.
Since your last review when the author pushed after it, else the whole PR."
  (let ((mine (gh-inbox-item-my-review-oid item))
        (head (gh-inbox-item-head-oid item)))
    (if (and mine head (not (equal mine head))
             (memq 're-review (mapcar #'car (gh-inbox-item-tags item))))
        (concat mine "..HEAD")
      (concat "origin/" (gh-inbox-item-base item) "...HEAD"))))

(defun gh-inbox-review--show-diff (item &optional same-window path)
  "Show ITEM's diff range, run from the worktree at PATH.
With SAME-WINDOW, in the selected window; otherwise wherever magit puts
diffs (another window), leaving the current layout alone.  PATH matters:
magit diffs the repo of `default-directory', which after resuming an
activity is whatever its restored buffer happened to be."
  (require 'magit-diff)
  (let ((range (gh-inbox-review--range item))
        (default-directory (if path (file-name-as-directory path) default-directory)))
    (if same-window
        (let ((magit-display-buffer-function
               (lambda (buf) (display-buffer buf '(display-buffer-same-window)))))
          (magit-diff-range range))
      (magit-diff-range range))))

(defun gh-inbox-review--right-pane (item)
  "Fill the selected window according to `gh-inbox-review-right-pane'."
  (pcase gh-inbox-review-right-pane
    ('pr-review
     (if (locate-library "pr-review")
         (gh-inbox-review-pr-review item)
       (gh-inbox-review-threads item)))
    ('threads (gh-inbox-review-threads item))
    (_ nil)))

(defun gh-inbox-review--activity (path item)
  "Open (or resume) the review activity for ITEM's worktree at PATH.
Already inside it: leave everything as it is."
  (require 'worktrunk-activities)
  (let* ((path (file-name-as-directory (expand-file-name path)))
         (name (worktrunk-activities--name path))
         (existing (activities-named name))
         (current (and (fboundp 'activities-current) (activities-current))))
    (cond
     ((and current (equal name (activities-activity-name current))) nil)
     ((and existing (activities-activity-default existing))
      (activities-resume existing)
      (gh-inbox-review--show-diff item nil path))
     (t
      (let ((worktrunk-activities-open-function
             (lambda (_) (gh-inbox-review--show-diff item t path)))
            (worktrunk-activities-terminal-function
             (and gh-inbox-review-right-pane
                  (lambda () (gh-inbox-review--right-pane item)))))
        (worktrunk-activities-open path))))))

(defcustom gh-inbox-activity-name "github"
  "Name of the activity that holds the inbox."
  :type 'string
  :group 'gh-inbox)

;;;###autoload
(defun gh-inbox-activity ()
  "Open the inbox in its own activity, creating it the first time.
Resumes the activity when it exists; inside it already, just shows the inbox."
  (interactive)
  (require 'worktrunk-activities)
  (let* ((name gh-inbox-activity-name)
         (activity (activities-named name))
         (current (activities-current)))
    (cond
     ((and current (equal name (activities-activity-name current)))
      (gh-inbox))
     ((and activity (activities-activity-default activity))
      (activities-resume activity)
      ;; Make sure the inbox is what is showing, and fresh.
      (unless (get-buffer-window "*gh-inbox*") (gh-inbox)))
     (t
      (when activity                    ; half-created leftover
        (setf activities-activities (map-delete activities-activities name)))
      (worktrunk-activities--new-container)
      (let ((done nil))
        (unwind-protect
            (progn (gh-inbox)
                   (delete-other-windows)
                   (activities-define name)
                   (setq done t))
          (unless done (worktrunk-activities--discard-container))))))))

;;;###autoload
(defun gh-inbox-review-open (item)
  "Open PR ITEM as a review activity."
  (interactive (list (gh-inbox--pr-item-at-point)))
  (message "Preparing %s#%s…" (gh-inbox-item-repo item) (gh-inbox-item-number item))
  (gh-inbox-review--prepare
   item (lambda (path) (gh-inbox-review--activity path item))))

;;;###autoload
(defun gh-inbox-review-pr-review (item)
  "Open PR ITEM in the `pr-review' package."
  (interactive (list (gh-inbox--pr-item-at-point)))
  (unless (require 'pr-review nil t)
    (user-error "pr-review is not installed (M-x package-install RET pr-review)"))
  ;; pr-review fetches the whole PR synchronously (3-9 s on big ones) and only
  ;; then shows the buffer, so say so first or the key looks dead.
  (message "Loading %s#%s in pr-review… (Emacs is busy for a few seconds)"
           (gh-inbox-item-repo item) (gh-inbox-item-number item))
  (redisplay t)
  (pr-review (gh-inbox-item-url item)))

;;;; Unresolved threads

(defconst gh-inbox-review--threads-query "
query($o: String!, $r: String!, $n: Int!) {
  viewer { login }
  repository(owner: $o, name: $r) {
    pullRequest(number: $n) {
      title url headRefName baseRefName
      reviewThreads(first: 100) {
        nodes {
          isResolved isOutdated path line originalLine
          comments(first: 30) { nodes { author { login } body createdAt } }
        }
      }
    }
  }
}")

(defvar-local gh-inbox-review--threads-item nil "The item a threads buffer shows.")
(defvar-local gh-inbox-review--threads-all nil "Non-nil when resolved threads are shown.")

(define-derived-mode gh-inbox-threads-mode special-mode "PR-Threads"
  "Review threads of a PR, navigable with `next-error'.
Lines of the form `path:line: ...' are error locations; use \\[next-error] and
\\[previous-error], or RET on a line.  \\<gh-inbox-threads-mode-map>\\[gh-inbox-threads-refresh] refreshes,
\\[gh-inbox-threads-toggle-resolved] toggles resolved threads."
  (setq truncate-lines nil)
  (setq-local bookmark-make-record-function #'gh-inbox-review--threads-bookmark-record)
  (visual-line-mode 1)
  (compilation-minor-mode 1))

(define-key gh-inbox-threads-mode-map (kbd "g") #'gh-inbox-threads-refresh)
(define-key gh-inbox-threads-mode-map (kbd "a") #'gh-inbox-threads-toggle-resolved)
(define-key gh-inbox-threads-mode-map (kbd "c") #'gh-inbox-threads-claude)
(define-key gh-inbox-threads-mode-map (kbd "o") #'gh-inbox-threads-browse)

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'gh-inbox-threads-mode 'motion)
    (evil-define-key* 'motion gh-inbox-threads-mode-map
      (kbd "RET") #'compile-goto-error
      (kbd "]e") #'next-error
      (kbd "[e") #'previous-error
      (kbd "gr") #'gh-inbox-threads-refresh
      (kbd "a") #'gh-inbox-threads-toggle-resolved
      (kbd "c") #'gh-inbox-threads-claude
      (kbd "o") #'gh-inbox-threads-browse
      (kbd "q") #'quit-window)))

(defun gh-inbox-review--first-line (body)
  "First line of BODY."
  (car (split-string (string-trim (or body "")) "[\r\n]+")))

(defun gh-inbox-review--awaiting-me-p (thread)
  "Non-nil when THREAD's last comment is not yours (it waits on you)."
  (let ((last (car (last (gh-inbox--g thread 'comments 'nodes)))))
    (not (equal (gh-inbox--g last 'author 'login) gh-inbox--viewer))))

(defun gh-inbox-review--body-lines (comment skip-first)
  "Lines of COMMENT's body, without the first line when SKIP-FIRST.
Blank lines at the start are dropped."
  (let ((lines (split-string (string-trim (or (alist-get 'body comment) "")) "\r?\n")))
    (when skip-first (setq lines (cdr lines)))
    (while (and lines (string-empty-p (string-trim (car lines))))
      (setq lines (cdr lines)))
    lines))

(defun gh-inbox-review--format-thread (thread)
  "Render THREAD (a GraphQL node) as text.
The first line is `path:line: @author: first line', which `next-error'
understands; the rest of the discussion is indented below it."
  (let* ((path (or (alist-get 'path thread) "(general)"))
         (line (or (alist-get 'line thread) (alist-get 'originalLine thread) 1))
         (comments (gh-inbox--g thread 'comments 'nodes))
         (first (car comments))
         (tags (concat (cond ((alist-get 'isResolved thread) " [resolved]")
                             ((not (gh-inbox-review--awaiting-me-p thread)) " [you replied]")
                             (t ""))
                       (if (alist-get 'isOutdated thread) " [outdated]" ""))))
    (with-temp-buffer
      (insert (format "%s:%d:%s @%s: %s\n" path line tags
                      (or (gh-inbox--g first 'author 'login) "?")
                      (gh-inbox-review--first-line (alist-get 'body first))))
      (dolist (c comments)
        (unless (eq c first)
          (insert (format "    ↳ @%s:\n" (or (gh-inbox--g c 'author 'login) "?"))))
        (dolist (l (gh-inbox-review--body-lines c (eq c first)))
          (insert "      " l "\n")))
      (insert "\n")
      (buffer-string))))

(defun gh-inbox-review--threads-text (pr all)
  "Whole text of the threads buffer for GraphQL PR node PR.
Unresolved threads awaiting you come first, then the ones you answered;
with ALL, resolved threads too."
  (let* ((threads (gh-inbox--g pr 'reviewThreads 'nodes))
         (open (seq-remove (lambda (th) (alist-get 'isResolved th)) threads))
         (awaiting (seq-filter #'gh-inbox-review--awaiting-me-p open))
         (replied (seq-remove #'gh-inbox-review--awaiting-me-p open))
         (resolved (seq-filter (lambda (th) (alist-get 'isResolved th)) threads))
         (shown (append awaiting replied (and all resolved))))
    (concat
     (format "%s\n%s\n%d awaiting you · %d you replied · %d resolved\n\n"
             (alist-get 'title pr) (alist-get 'url pr)
             (length awaiting) (length replied) (length resolved))
     (if shown
         (mapconcat #'gh-inbox-review--format-thread shown "")
       "No unresolved threads. 🎉\n"))))

(defun gh-inbox-review--threads-for-prompt (item callback)
  "Fetch unresolved threads of ITEM and call CALLBACK with their text."
  (gh-inbox-review--fetch-threads
   item
   (lambda (pr)
     (funcall callback
              (mapconcat #'gh-inbox-review--format-thread
                         (seq-filter
                          (lambda (th)
                            (and (not (alist-get 'isResolved th))
                                 (gh-inbox-review--awaiting-me-p th)))
                          (gh-inbox--g pr 'reviewThreads 'nodes))
                         "")))))

(defun gh-inbox-review--fetch-threads (item callback &optional errback)
  "Fetch the PR node with review threads for ITEM; call CALLBACK with it.
ERRBACK, if given, is called with a message string on failure."
  (let* ((parts (split-string (gh-inbox-item-repo item) "/")))
    (gh-inbox--gh
     (list "api" "graphql"
           "-f" (concat "query=" gh-inbox-review--threads-query)
           "-f" (concat "o=" (car parts))
           "-f" (concat "r=" (cadr parts))
           "-F" (format "n=%d" (gh-inbox-item-number item)))
     (lambda (ok out err)
       (let* ((data (and ok (gh-inbox--g (gh-inbox--parse out) 'data)))
              (pr (gh-inbox--g data 'repository 'pullRequest)))
         (unless gh-inbox--viewer
           (setq gh-inbox--viewer (gh-inbox--g data 'viewer 'login)))
         (if pr
             (funcall callback pr)
           (let ((msg (truncate-string-to-width
                       (string-trim (if (and ok (not (string-empty-p out))) out err)) 160 nil nil "…")))
             (message "gh-inbox: could not fetch threads: %s" msg)
             (when errback (funcall errback msg)))))))))

(defun gh-inbox-review--threads-buffer (item)
  "The threads buffer for ITEM."
  (get-buffer-create (format "*pr-threads: %s#%s*"
                             (gh-inbox--short-repo (gh-inbox-item-repo item))
                             (gh-inbox-item-number item))))

(defun gh-inbox-review--local-directory (item)
  "Best guess of the local directory for ITEM's files, or nil.
Never runs a process and never prompts: the PR's worktree if a previous
lookup found it, else the repo's main checkout."
  (when-let* ((root (ignore-errors
                      (gh-inbox-review-repo-directory (gh-inbox-item-repo item) t))))
    (or (gh-inbox-review--find-branch-path
         (gethash root gh-inbox-review--wt-cache) (gh-inbox-item-head item))
        root)))

;;;###autoload
(defun gh-inbox-review-threads (item &optional all no-display)
  "Show unresolved review threads of PR ITEM; with ALL, resolved ones too.
With NO-DISPLAY, only prepare the buffer (used when restoring bookmarks)."
  (interactive (list (gh-inbox--pr-item-at-point) current-prefix-arg))
  (let ((buf (gh-inbox-review--threads-buffer item))
        (dir (gh-inbox-review--local-directory item)))
    (with-current-buffer buf
      (unless (derived-mode-p 'gh-inbox-threads-mode) (gh-inbox-threads-mode))
      (setq gh-inbox-review--threads-item item
            gh-inbox-review--threads-all all)
      (when dir (setq default-directory (file-name-as-directory dir)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Loading threads…\n" 'face 'gh-inbox-dim))))
    (gh-inbox-review--fetch-threads
     item
     (lambda (pr)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (gh-inbox-review--threads-text pr gh-inbox-review--threads-all))
             (goto-char (point-min))
             ;; Let compilation-minor-mode (re)scan the new text.
             (when (fboundp 'compilation--flush-parse)
               (compilation--flush-parse (point-min) (point-max)))
             (font-lock-flush)
             (forward-line 4)))))
     (lambda (msg)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize (format "Could not load threads: %s\n" msg)
                                 'face 'error)))))))
    (unless no-display (display-buffer buf))
    buf))

(defun gh-inbox-threads-refresh ()
  "Re-fetch the threads."
  (interactive)
  (gh-inbox-review-threads gh-inbox-review--threads-item
                           gh-inbox-review--threads-all))

(defun gh-inbox-threads-toggle-resolved ()
  "Toggle showing resolved threads."
  (interactive)
  (gh-inbox-review-threads gh-inbox-review--threads-item
                           (not gh-inbox-review--threads-all)))

(defun gh-inbox-threads-browse ()
  "Open the PR in the browser."
  (interactive)
  (browse-url (gh-inbox-item-url gh-inbox-review--threads-item)))

(defun gh-inbox-threads-claude ()
  "Start Claude on this PR."
  (interactive)
  (gh-inbox-review-claude gh-inbox-review--threads-item))

(defun gh-inbox-review--item-for-current-branch (callback)
  "Build an item for the PR of the current branch via `gh pr view'; CALLBACK it."
  (let ((default-directory (or (and (project-current) (project-root (project-current)))
                               default-directory)))
    (gh-inbox--gh
     (list "pr" "view" "--json" "number,title,url,headRefName,baseRefName,author")
     (lambda (ok out err)
       (if-let* ((j (and ok (gh-inbox--parse out)))
                 (url (alist-get 'url j)))
           (funcall callback
                    (gh-inbox-item-create
                     :url url :kind 'pr
                     :repo (and (string-match "github\\.com/\\([^/]+/[^/]+\\)/pull" url)
                                (match-string 1 url))
                     :number (alist-get 'number j) :title (alist-get 'title j)
                     :head (alist-get 'headRefName j) :base (alist-get 'baseRefName j)
                     :author (gh-inbox--g j 'author 'login)
                     :roles '(authored)))
         (message "gh-inbox: no PR for this branch (%s)"
                  (truncate-string-to-width err 100)))))))

;;;###autoload
(defun gh-inbox-review-threads-here (&optional all)
  "Show review threads of the PR for the current branch; ALL includes resolved."
  (interactive "P")
  (let ((dir default-directory))
    (gh-inbox-review--item-for-current-branch
     (lambda (item)
       (let ((default-directory dir))
         (gh-inbox-review-threads item all))))))

;;;; Bookmarks (so `activities' can restore these buffers)

(defvar pr-review--pr-path)
(defvar pr-review--host)
(declare-function pr-review-open "pr-review")

(defun gh-inbox-review--threads-bookmark-record ()
  "Bookmark record for a threads buffer."
  (let ((it gh-inbox-review--threads-item))
    `(,(format "PR threads %s#%s" (gh-inbox-item-repo it) (gh-inbox-item-number it))
      (handler . gh-inbox-review-threads-bookmark-handler)
      (repo . ,(gh-inbox-item-repo it)) (number . ,(gh-inbox-item-number it))
      (url . ,(gh-inbox-item-url it)) (head . ,(gh-inbox-item-head it))
      (base . ,(gh-inbox-item-base it)) (all . ,gh-inbox-review--threads-all))))

(defun gh-inbox-review-threads-bookmark-handler (bmk)
  "Restore a threads buffer from bookmark BMK."
  (let ((item (gh-inbox-item-create
               :kind 'pr :repo (bookmark-prop-get bmk 'repo)
               :number (bookmark-prop-get bmk 'number)
               :url (bookmark-prop-get bmk 'url)
               :head (bookmark-prop-get bmk 'head) :base (bookmark-prop-get bmk 'base))))
    (gh-inbox-review-threads item (bookmark-prop-get bmk 'all) t)
    (set-buffer (gh-inbox-review--threads-buffer item))))

(put 'gh-inbox-review-threads-bookmark-handler 'bookmark-handler-type "PR-Threads")

(defun gh-inbox-review--pr-review-bookmark-record ()
  "Bookmark record for a `pr-review' buffer."
  (let ((p pr-review--pr-path))
    `(,(format "PR review %s/%s#%s" (nth 0 p) (nth 1 p) (nth 2 p))
      (handler . gh-inbox-review-pr-review-bookmark-handler)
      (host . ,pr-review--host) (path . ,p))))

(defun gh-inbox-review-pr-review-bookmark-handler (bmk)
  "Restore a `pr-review' buffer from bookmark BMK."
  (require 'pr-review)
  (let ((path (bookmark-prop-get bmk 'path)))
    (save-window-excursion
      (apply #'pr-review-open (bookmark-prop-get bmk 'host) path))
    (set-buffer (format "*pr-review %s/%s/%s*" (nth 0 path) (nth 1 path) (nth 2 path)))))

(put 'gh-inbox-review-pr-review-bookmark-handler 'bookmark-handler-type "PR-Review")

(with-eval-after-load 'pr-review
  (add-hook 'pr-review-mode-hook
            (lambda ()
              (setq-local bookmark-make-record-function
                          #'gh-inbox-review--pr-review-bookmark-record))))

;;;###autoload
(defun gh-inbox-review-browse-here ()
  "Open the PR of the current branch in the browser.
The URL comes from `gh pr view --json' and is opened with `browse-url', not
`gh pr view --web', which needs xdg-open and fails where there is none."
  (interactive)
  (gh-inbox-review--item-for-current-branch
   (lambda (item) (browse-url (gh-inbox-item-url item)))))

;;;; Claude

(defun gh-inbox-review-notes-file (item)
  "Org file where Claude's findings for ITEM go."
  (expand-file-name
   (format "%s-%s.org"
           (replace-regexp-in-string "/" "-" (gh-inbox-item-repo item))
           (gh-inbox-item-number item))
   gh-inbox-review-notes-directory))

(defun gh-inbox-review--mine-p (item)
  "Non-nil when ITEM is your own PR."
  (or (memq 'authored (gh-inbox-item-roles item))
      (equal (gh-inbox-item-author item) gh-inbox--viewer)))

(defun gh-inbox-review--prompt-review (item path)
  "Prompt for a first-pass review of ITEM, worktree at PATH."
  (let ((range (gh-inbox-review--range item))
        (notes (gh-inbox-review-notes-file item)))
    (format
     "You are doing a first-pass code review of GitHub PR %s#%s: \"%s\" by @%s.
This worktree (%s) has the PR branch (%s) checked out; its base is origin/%s.

1. Read the PR description and existing discussion: gh pr view %s -R %s --comments
2. Review the changes: git diff %s  (read the surrounding code, callers and tests as needed; this range is %s)
3. Look for correctness bugs, missing error handling, security issues, races, missing or weak tests, API/contract breaks, and anything that will bite in production. Skip style nits unless they hide a bug.

Rules: this is READ-ONLY. Do not edit repo files, do not commit or push, and do not post anything to GitHub (no `gh pr review`, no comments).

Write the findings to %s as an org-mode file. Start with a 3-5 line overall summary and a verdict (approve / approve with comments / request changes). Then one heading per finding:
  * [BLOCKER|SUGGESTION|NIT|QUESTION] path:line - one-line summary
followed by why it matters, what you would change, and an org link [[file:%s/path::line]] to the code. Prefer a few high-signal findings over many nitpicks. Tell me when it is written."
     (gh-inbox-item-repo item) (gh-inbox-item-number item)
     (gh-inbox-item-title item) (gh-inbox-item-author item)
     path (gh-inbox-item-head item) (gh-inbox-item-base item)
     (gh-inbox-item-number item) (gh-inbox-item-repo item)
     range
     (if (string-prefix-p "origin/" range) "the whole PR" "only what changed since my last review")
     notes (string-remove-suffix "/" path))))

(defun gh-inbox-review--prompt-address (item threads)
  "Prompt to address THREADS (text) on ITEM."
  (format
   "Address the unresolved review comments on my PR %s#%s \"%s\" (branch %s). This worktree has the branch checked out.

Unresolved threads (path:line: first comment, then the discussion):

%s
For each thread: read the code it points at, decide whether the reviewer is right, and make the change in this worktree when they are. Do not commit or push, do not resolve threads and do not post replies. When you are done, give me a per-thread summary: what you changed, or why you did not, plus a one-paragraph reply I can paste to the reviewer where useful."
   (gh-inbox-item-repo item) (gh-inbox-item-number item)
   (gh-inbox-item-title item) (gh-inbox-item-head item) threads))

(defun gh-inbox-review--prompt-ci (item)
  "Prompt to fix failing CI on ITEM."
  (format
   "CI is failing on my PR %s#%s \"%s\" (branch %s); this worktree has it checked out.

Find the failures: gh pr checks %s -R %s, then the failing logs with gh run view <run-id> --log-failed. Work out the root cause (distinguish a real regression from a flaky or infrastructure failure) and fix it in this worktree if it is a real one. Reproduce locally when feasible. Do not commit or push. Tell me what failed, why, and what you changed."
   (gh-inbox-item-repo item) (gh-inbox-item-number item)
   (gh-inbox-item-title item) (gh-inbox-item-head item)
   (gh-inbox-item-number item) (gh-inbox-item-repo item)))

(defun gh-inbox-review--claude-mode (item choose)
  "Pick what Claude should do for ITEM; CHOOSE forces a prompt."
  (let* ((tags (mapcar #'car (gh-inbox-item-tags item)))
         (auto (cond ((not (gh-inbox-review--mine-p item)) 'review)
                     ((or (memq 'threads tags) (memq 'changes tags)) 'address)
                     ((memq 'ci tags) 'ci)
                     (t 'address))))
    (if choose
        (intern (completing-read "Claude should: "
                                 '("review" "address" "ci") nil t nil nil
                                 (symbol-name auto)))
      auto)))

(defun gh-inbox-review--skill-command (item mode)
  "Slash command for MODE (`review' or `address') on ITEM, or nil.
Comes from `gh-inbox-review-skills'; the PR number is the argument."
  (when-let* ((skill (alist-get mode
                                (cdr (assoc-string (gh-inbox-item-repo item)
                                                   gh-inbox-review-skills t)))))
    (format "%s %s" skill (gh-inbox-item-number item))))

(defun gh-inbox-review--start-claude (path prompt)
  "Start Claude in worktree PATH with PROMPT and show it."
  (require 'ghostel-claude)
  (let ((buf (ghostel-claude--start (file-name-as-directory path) (list prompt))))
    (ghostel-claude--show buf)))

;;;###autoload
(defun gh-inbox-review-claude (item &optional choose)
  "Start Claude on PR ITEM.
Reviews someone else's PR (read-only, findings to an org file); on your own
PR addresses unresolved threads or fixes CI.  With prefix CHOOSE, pick."
  (interactive (list (gh-inbox--pr-item-at-point) current-prefix-arg))
  (let ((mode (gh-inbox-review--claude-mode item choose)))
    (message "Preparing Claude (%s) for %s#%s…" mode
             (gh-inbox-item-repo item) (gh-inbox-item-number item))
    (gh-inbox-review--prepare
     item
     (lambda (path)
       (let ((skill (gh-inbox-review--skill-command item mode)))
         (when (and (eq mode 'review) (not skill))
           (make-directory gh-inbox-review-notes-directory t))
         ;; Claude lands in the PR's own activity, next to the diff.
         (gh-inbox-review--activity path item)
         (pcase mode
           ('review
            (gh-inbox-review--start-claude
             path (or skill (gh-inbox-review--prompt-review item path))))
           ('ci
            (gh-inbox-review--start-claude
             path (gh-inbox-review--prompt-ci item)))
           (_
            (if skill
                ;; The skill reads the threads itself.
                (gh-inbox-review--start-claude path skill)
              (gh-inbox-review--threads-for-prompt
               item
               (lambda (threads)
                 (if (string-empty-p (string-trim threads))
                     (message "No unresolved threads on %s#%s"
                              (gh-inbox-item-repo item) (gh-inbox-item-number item))
                   (gh-inbox-review--start-claude
                    path (gh-inbox-review--prompt-address item threads)))))))))))))

;;;###autoload
(defun gh-inbox-review-notes (item)
  "Open the review draft written for PR ITEM.
Claude's own findings file, else the review skill's `<N>-review.md'."
  (interactive (list (gh-inbox--pr-item-at-point)))
  (let* ((file (gh-inbox-review-notes-file item))
         (skill-hit
          (and gh-inbox-review-skill-output-dir
               (file-directory-p gh-inbox-review-skill-output-dir)
               (car (sort (directory-files-recursively
                           gh-inbox-review-skill-output-dir
                           (format "\\`%s-review.*\\.md\\'" (gh-inbox-item-number item)))
                          #'file-newer-than-file-p)))))
    (cond ((file-exists-p file) (find-file file))
          (skill-hit (find-file skill-hit))
          (t (user-error "No draft file for %s#%s; a skill review is a pending review on the PR (v or o)"
                         (gh-inbox-item-repo item) (gh-inbox-item-number item))))))

(provide 'gh-inbox-review)
;;; gh-inbox-review.el ends here
