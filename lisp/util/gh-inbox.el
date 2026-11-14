;;; gh-inbox.el --- GitHub review inbox for Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer that answers "what does GitHub need from me right now?"
;; instead of making you click through github.com/pulls and /notifications.
;;
;; Data comes from the `gh' CLI (already authenticated), in two parallel
;; calls: one GraphQL query for PRs (review requested of you, authored by
;; you, reviewed by you) and one REST call for participating notifications
;; (mentions, replies).  Everything is merged by URL into items, and each
;; item is classified into "why it needs you" tags:
;;
;;   CHANGES    a reviewer requested changes on your PR
;;   REVIEW     your review was requested
;;   RE-REVIEW  you reviewed it and the author pushed since
;;   MENTION    you were @-mentioned (or your team was)
;;   ASSIGNED   you were assigned to someone else's PR/issue
;;   THREADS:n  n unresolved review threads on your PR awaiting your reply
;;   CI✗        CI is failing on your PR
;;   READY      your PR is approved, green and mergeable
;;   COMMENT    new comments on something you take part in
;;
;; Views (keys 1-5): Needs me, Reviews, Mine, Mentions, All.
;; `x'/`d' dismisses an item until it has new activity.
;;
;; Entry point: `gh-inbox'.  Row actions live in `gh-inbox-review.el'
;; (open as a review activity, Claude first pass, unresolved threads) and
;; `gh-inbox-notify.el' (background polling, toasts, Taskwarrior sync).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'iso8601)
(require 'bookmark)

(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")
(declare-function gh-inbox-review-open "gh-inbox-review")
(declare-function gh-inbox-review-claude "gh-inbox-review")
(declare-function gh-inbox-review-threads "gh-inbox-review")
(declare-function gh-inbox-review-notes "gh-inbox-review")
(declare-function iso8601-parse "iso8601")
(declare-function gh-inbox-review-pr-review "gh-inbox-review")
(declare-function gh-inbox-notify-task "gh-inbox-notify")

;;;; Customization

(defgroup gh-inbox nil
  "GitHub review inbox."
  :group 'tools
  :prefix "gh-inbox-")

(defcustom gh-inbox-executable "gh"
  "The GitHub CLI."
  :type 'string)

(defcustom gh-inbox-search-qualifiers ""
  "Extra search qualifiers added to every PR search, e.g. \"org:clearcompany\"."
  :type 'string)

(defcustom gh-inbox-max-results 30
  "Maximum PRs fetched per search."
  :type 'integer)

(defcustom gh-inbox-jira-base-url nil
  "Base URL for Jira browse links, e.g. \"https://example.atlassian.net/browse/\".
When nil, `gh-inbox-browse-jira' refuses to guess."
  :type '(choice (const nil) string))

(defcustom gh-inbox-stale-seconds 120
  "Seconds before `gh-inbox' re-fetches when you switch to it."
  :type 'integer)

(defcustom gh-inbox-hide-others-drafts t
  "When non-nil, drafts by other people never count as needing you."
  :type 'boolean)

(defcustom gh-inbox-state-file
  (expand-file-name "var/gh-inbox.eld" user-emacs-directory)
  "File remembering dismissed items."
  :type 'file)

(defcustom gh-inbox-expected-login nil
  "GitHub login the inbox belongs to, or nil to learn it from the first fetch.
When `gh' is switched to another account, fetches are discarded instead of
being taken for \"all your review requests are gone\"; that would close your
Taskwarrior review tasks.  See `gh-inbox-forget-account'."
  :type '(choice (const :tag "Learn from the first fetch" nil) string))

(defcustom gh-inbox-refresh-hook nil
  "Normal hook run after a successful fetch.
Runs with `gh-inbox-items' set to the new list of items."
  :type 'hook)

(defcustom gh-inbox-comment-fetch-limit 20
  "Latest-comment snippets fetched per refresh (one API call each)."
  :type 'integer)

;;;; Faces

(defface gh-inbox-tag-urgent '((t :inherit error :weight bold))
  "Tags that block someone or you: CHANGES, CI failure.")
(defface gh-inbox-tag-action '((t :inherit warning :weight bold))
  "Tags that ask you to act: REVIEW, RE-REVIEW, MENTION.")
(defface gh-inbox-tag-good '((t :inherit success :weight bold))
  "Good-news tags: READY.")
(defface gh-inbox-tag-info '((t :inherit font-lock-keyword-face))
  "Informational tags: THREADS, COMMENT.")
(defface gh-inbox-dim '((t :inherit shadow))
  "Secondary text: repo, author, age, drafts.")
(defface gh-inbox-stale '((t :inherit warning))
  "Age of a review request that has waited too long.")
(defface gh-inbox-view-active '((t :inherit highlight :weight bold))
  "Active view in the header line.")

;;;; Item model

(cl-defstruct (gh-inbox-item (:constructor gh-inbox-item-create) (:copier nil))
  url repo number title author kind  ; kind: `pr' or `issue'
  draft created updated
  head base head-oid
  decision mergeable ci threads      ; threads: unresolved count
  additions deletions files
  roles                              ; subset of requested authored reviewed notified
  my-review-oid my-review-state
  notif-id notif-reason notif-updated
  latest latest-author               ; last comment snippet (from notification)
  tags)                              ; list of (SYMBOL . COUNT-or-nil)

(defvar gh-inbox--viewer nil "Login of the authenticated user.")
(defvar gh-inbox-items nil "Items from the last successful fetch.")
(defvar gh-inbox--last-fetch nil "Float time of the last successful fetch.")
(defvar gh-inbox--fetching nil "Non-nil (start time) while a fetch is running.")
(defvar gh-inbox--fetch-clean nil
  "Non-nil when the last successful fetch finished without any error.
Consumers that remove things when an item disappears must check this.")
(defvar gh-inbox--last-error nil "Message of the last failed fetch, or nil.")
(defvar gh-inbox--dismissed nil
  "Alist (URL . UPDATED) of dismissed items.  Loaded lazily.")
(defvar gh-inbox--dismissed-loaded nil)
(defvar gh-inbox--known-login nil
  "Login learned from the first successful fetch (kept in `gh-inbox-state-file').")

(defun gh-inbox--g (obj &rest keys)
  "Walk alist OBJ through KEYS, returning nil on any missing step."
  (while (and keys obj)
    (setq obj (and (consp obj) (alist-get (pop keys) obj))))
  (and (null keys) obj))

;;;; Time helpers

(defun gh-inbox--time (iso)
  "Float time of ISO 8601 string ISO, or nil."
  (when (and (stringp iso) (not (string-empty-p iso)))
    (ignore-errors (float-time (encode-time (iso8601-parse iso))))))

(defun gh-inbox--age-seconds (iso)
  "Seconds since ISO, or nil."
  (when-let* ((tm (gh-inbox--time iso)))
    (max 0 (- (float-time) tm))))

(defun gh-inbox--age-string (iso)
  "Short age string for ISO: 5m, 3h, 2d, 6w."
  (if-let* ((s (gh-inbox--age-seconds iso)))
      (cond ((< s 3600) (format "%dm" (max 1 (/ s 60))))
            ((< s 86400) (format "%dh" (/ s 3600)))
            ((< s (* 14 86400)) (format "%dd" (/ s 86400)))
            (t (format "%dw" (/ s (* 7 86400)))))
    ""))

;;;; Running gh

(defun gh-inbox--gh (args callback)
  "Run `gh' with ARGS asynchronously.
CALLBACK is called with (OK STDOUT STDERR) when it exits.  Returns the process."
  (let* ((out (generate-new-buffer " *gh-inbox-out*"))
         (err (generate-new-buffer " *gh-inbox-err*"))
         (proc (condition-case e
                   (make-process
                    :name "gh-inbox" :buffer out :stderr err
                    :command (cons gh-inbox-executable args)
                    :noquery t :connection-type 'pipe
                    :sentinel
                    (lambda (p _event)
                      (when (memq (process-status p) '(exit signal))
                        (let ((o (with-current-buffer out (buffer-string)))
                              (er (with-current-buffer err (buffer-string)))
                              (ok (and (eq (process-status p) 'exit)
                                       (eq (process-exit-status p) 0))))
                          (kill-buffer out)
                          (kill-buffer err)
                          (funcall callback ok o (string-trim er))))))
                 (error
                  (kill-buffer out) (kill-buffer err)
                  (funcall callback nil "" (error-message-string e))
                  nil))))
    proc))

(defun gh-inbox--parse (string)
  "Parse JSON STRING into alists/lists, or nil."
  (and (stringp string) (not (string-empty-p (string-trim string)))
       (condition-case nil
           (json-parse-string string :object-type 'alist :array-type 'list
                              :null-object nil :false-object nil)
         (error nil))))

;;;; The GraphQL query

(defconst gh-inbox--pr-fragment "
fragment PR on PullRequest {
  number title url isDraft createdAt updatedAt
  author { login }
  repository { nameWithOwner }
  headRefName baseRefName headRefOid
  reviewDecision mergeable
  additions deletions changedFiles
  commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
  latestReviews(first: 20) { nodes { author { login } state submittedAt commit { oid } } }
}
fragment Threads on PullRequest {
  reviewThreads(first: 100) {
    nodes { isResolved comments(last: 1) { nodes { author { login } } } }
  }
}")

;; Review threads are the expensive part of the query (100 nodes per PR), and
;; only matter on your own PRs, so only the `mine' search asks for them.
(defconst gh-inbox--query
  (concat gh-inbox--pr-fragment "
query($rq: String!, $mine: String!, $rev: String!, $n: Int!) {
  viewer { login }
  rateLimit { cost remaining resetAt }
  rq:   search(query: $rq,   type: ISSUE, first: $n) { nodes { ...PR } }
  mine: search(query: $mine, type: ISSUE, first: $n) { nodes { ...PR ...Threads } }
  rev:  search(query: $rev,  type: ISSUE, first: $n) { nodes { ...PR } }
}"))

(defvar gh-inbox--rate-remaining nil
  "GraphQL points left after the last fetch, or nil.")

(defun gh-inbox--search-string (base)
  "BASE plus the user's extra qualifiers."
  (string-trim (concat base " archived:false " gh-inbox-search-qualifiers)))

(defun gh-inbox--graphql-args ()
  "Arguments for the PR query."
  (list "api" "graphql"
        "-f" (concat "query=" gh-inbox--query)
        "-f" (concat "rq=" (gh-inbox--search-string
                            "is:pr is:open review-requested:@me"))
        "-f" (concat "mine=" (gh-inbox--search-string
                              "is:pr is:open author:@me"))
        "-f" (concat "rev=" (gh-inbox--search-string
                             "is:pr is:open reviewed-by:@me -author:@me"))
        "-F" (format "n=%d" gh-inbox-max-results)))

;;;; Building items

(defun gh-inbox--pr-item (node roles viewer)
  "Make an item from GraphQL PR NODE with ROLES (a list)."
  (let* ((commit (gh-inbox--g (car (gh-inbox--g node 'commits 'nodes)) 'commit))
         (threads (gh-inbox--g node 'reviewThreads 'nodes))
         (mine (seq-find (lambda (r)
                           (equal (gh-inbox--g r 'author 'login) viewer))
                         (gh-inbox--g node 'latestReviews 'nodes))))
    (gh-inbox-item-create
     :url (gh-inbox--g node 'url)
     :repo (gh-inbox--g node 'repository 'nameWithOwner)
     :number (gh-inbox--g node 'number)
     :title (gh-inbox--g node 'title)
     :author (gh-inbox--g node 'author 'login)
     :kind 'pr
     :draft (gh-inbox--g node 'isDraft)
     :created (gh-inbox--g node 'createdAt)
     :updated (gh-inbox--g node 'updatedAt)
     :head (gh-inbox--g node 'headRefName)
     :base (gh-inbox--g node 'baseRefName)
     :head-oid (or (gh-inbox--g commit 'oid) (gh-inbox--g node 'headRefOid))
     :decision (gh-inbox--g node 'reviewDecision)
     :mergeable (gh-inbox--g node 'mergeable)
     :ci (gh-inbox--g commit 'statusCheckRollup 'state)
     ;; Unresolved threads where the last word is not yours: the ones
     ;; waiting on you.  Threads you answered are waiting on the reviewer.
     :threads (seq-count
               (lambda (th)
                 (and (not (gh-inbox--g th 'isResolved))
                      (not (equal (gh-inbox--g (car (last (gh-inbox--g th 'comments 'nodes)))
                                               'author 'login)
                                  viewer))))
               threads)
     :additions (gh-inbox--g node 'additions)
     :deletions (gh-inbox--g node 'deletions)
     :files (gh-inbox--g node 'changedFiles)
     :roles roles
     :my-review-oid (gh-inbox--g mine 'commit 'oid)
     :my-review-state (gh-inbox--g mine 'state))))

(defun gh-inbox--api-url->html (url)
  "Turn a GitHub API subject URL into its html URL, or nil."
  (when (and (stringp url)
             (string-match
              "\\`https://api\\.github\\.com/repos/\\([^/]+/[^/]+\\)/\\(pulls\\|issues\\)/\\([0-9]+\\)"
              url))
    (format "https://github.com/%s/%s/%s"
            (match-string 1 url)
            (if (equal (match-string 2 url) "pulls") "pull" "issues")
            (match-string 3 url))))

(defun gh-inbox--notif-item (n)
  "Make a bare item from notification alist N, or nil if not a PR/issue."
  (let* ((subject (alist-get 'subject n))
         (type (alist-get 'type subject))
         (url (gh-inbox--api-url->html (alist-get 'url subject))))
    (when (and url (member type '("PullRequest" "Issue")))
      (gh-inbox-item-create
       :url url
       :repo (gh-inbox--g n 'repository 'full_name)
       :number (string-to-number (car (last (split-string url "/"))))
       :title (alist-get 'title subject)
       :kind (if (equal type "PullRequest") 'pr 'issue)
       :updated (alist-get 'updated_at n)))))

(defun gh-inbox--merge (graphql notifications viewer)
  "Merge GRAPHQL data and NOTIFICATIONS into a list of items for VIEWER."
  (let ((table (make-hash-table :test #'equal))
        (order nil))
    (cl-flet ((add-role (item role)
                (cl-pushnew role (gh-inbox-item-roles item))))
      (dolist (spec '((rq . requested) (mine . authored) (rev . reviewed)))
        (dolist (node (gh-inbox--g graphql 'data (car spec) 'nodes))
          (when (gh-inbox--g node 'url)
            (let ((existing (gethash (alist-get 'url node) table)))
              (if existing
                  (add-role existing (cdr spec))
                (let ((item (gh-inbox--pr-item node (list (cdr spec)) viewer)))
                  (puthash (gh-inbox-item-url item) item table)
                  (push item order)))))))
      (dolist (n notifications)
        (when-let* ((item (gh-inbox--notif-item n)))
          (let ((existing (gethash (gh-inbox-item-url item) table)))
            (unless existing
              (setq existing item)
              (puthash (gh-inbox-item-url item) item table)
              (push item order))
            (setf (gh-inbox-item-notif-id existing) (alist-get 'id n)
                  (gh-inbox-item-notif-reason existing) (alist-get 'reason n)
                  (gh-inbox-item-notif-updated existing) (alist-get 'updated_at n))
            (add-role existing 'notified)
            (when (or (null (gh-inbox-item-updated existing))
                      (string> (or (alist-get 'updated_at n) "")
                               (gh-inbox-item-updated existing)))
              (setf (gh-inbox-item-updated existing) (alist-get 'updated_at n)))))))
    (nreverse order)))

;;;; Classification

(defconst gh-inbox--tag-rank
  '((changes . 0) (review . 1) (re-review . 2) (mention . 3) (assigned . 3)
    (threads . 4) (ci . 5) (ready . 6) (comment . 7))
  "Sort priority of tags (lower is more urgent).")

(defun gh-inbox--add-tag (item tag &optional count)
  "Add TAG with optional COUNT to ITEM."
  (unless (assq tag (gh-inbox-item-tags item))
    (setf (gh-inbox-item-tags item)
          (append (gh-inbox-item-tags item) (list (cons tag count))))))

(defun gh-inbox-classify (item viewer)
  "Compute the tags of ITEM for VIEWER.  Mutates and returns ITEM.
Pure given ITEM's fields, so it can be tested without GitHub."
  (setf (gh-inbox-item-tags item) nil)
  (let* ((roles (gh-inbox-item-roles item))
         (pr (eq (gh-inbox-item-kind item) 'pr))
         (mine (and pr (or (memq 'authored roles)
                           (equal (gh-inbox-item-author item) viewer))))
         (others-draft (and (gh-inbox-item-draft item) (not mine)
                            gh-inbox-hide-others-drafts))
         (reason (gh-inbox-item-notif-reason item)))
    (when (and pr mine)
      (let ((decision (gh-inbox-item-decision item))
            (ci (gh-inbox-item-ci item))
            (threads (or (gh-inbox-item-threads item) 0)))
        (when (equal decision "CHANGES_REQUESTED")
          (gh-inbox--add-tag item 'changes))
        (when (> threads 0)
          (gh-inbox--add-tag item 'threads threads))
        (when (member ci '("FAILURE" "ERROR"))
          (gh-inbox--add-tag item 'ci))
        (when (and (equal decision "APPROVED")
                   (equal ci "SUCCESS")
                   (equal (gh-inbox-item-mergeable item) "MERGEABLE")
                   (not (gh-inbox-item-draft item)))
          (gh-inbox--add-tag item 'ready))))
    (when (and pr (not mine) (not others-draft))
      (when (memq 'requested roles)
        (gh-inbox--add-tag item 'review))
      (when (and (memq 'reviewed roles)
                 (not (memq 'requested roles))
                 (gh-inbox-item-my-review-oid item)
                 (gh-inbox-item-head-oid item)
                 (not (equal (gh-inbox-item-my-review-oid item)
                             (gh-inbox-item-head-oid item)))
                 (not (equal (gh-inbox-item-my-review-state item) "APPROVED")))
        (gh-inbox--add-tag item 're-review)))
    (when (and (memq 'notified roles) (not others-draft))
      (cond
       ((member reason '("mention" "team_mention"))
        (gh-inbox--add-tag item 'mention))
       ((and (equal reason "assign") (not mine))
        (gh-inbox--add-tag item 'assigned))
       ((member reason '("comment" "author"))
        (unless (equal (gh-inbox-item-latest-author item) viewer)
          (gh-inbox--add-tag item 'comment)))))
    item))

(defun gh-inbox-item-rank (item)
  "Sort rank of ITEM: its most urgent tag, or 99."
  (if-let* ((tags (gh-inbox-item-tags item)))
      (apply #'min (mapcar (lambda (tg) (alist-get (car tg) gh-inbox--tag-rank 50))
                           tags))
    99))

(defun gh-inbox--tag-label (tag)
  "Propertized label for TAG, a (SYMBOL . COUNT) cons."
  (let ((sym (car tag)) (n (cdr tag)))
    (pcase sym
      ('changes   (propertize "CHANGES" 'face 'gh-inbox-tag-urgent))
      ('review    (propertize "REVIEW" 'face 'gh-inbox-tag-action))
      ('re-review (propertize "RE-REVIEW" 'face 'gh-inbox-tag-action))
      ('mention   (propertize "MENTION" 'face 'gh-inbox-tag-action))
      ('assigned  (propertize "ASSIGNED" 'face 'gh-inbox-tag-action))
      ('threads   (propertize (format "THREADS:%d" (or n 0)) 'face 'gh-inbox-tag-info))
      ('ci        (propertize "CI✗" 'face 'gh-inbox-tag-urgent))
      ('ready     (propertize "READY" 'face 'gh-inbox-tag-good))
      ('comment   (propertize "COMMENT" 'face 'gh-inbox-tag-info))
      (_ (symbol-name sym)))))

;;;; Dismissed items

(defun gh-inbox--load-state ()
  "Load dismissed items from disk once."
  (unless gh-inbox--dismissed-loaded
    (setq gh-inbox--dismissed-loaded t)
    (when (file-readable-p gh-inbox-state-file)
      (setq gh-inbox--dismissed
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents gh-inbox-state-file)
                  (let ((data (read (current-buffer))))
                    (when (listp data)
                      (setq gh-inbox--known-login (alist-get 'viewer data))
                      (alist-get 'dismissed data))))
              (error nil))))))

(defun gh-inbox--save-state ()
  "Write dismissed items to disk, keeping at most 500."
  (condition-case err
      (progn
        (make-directory (file-name-directory gh-inbox-state-file) t)
        (when (> (length gh-inbox--dismissed) 500)
          (setq gh-inbox--dismissed (seq-take gh-inbox--dismissed 500)))
        (with-temp-file gh-inbox-state-file
          (let ((print-length nil) (print-level nil))
            (prin1 `((dismissed . ,gh-inbox--dismissed)
                     (viewer . ,gh-inbox--known-login))
                   (current-buffer)))))
    (error (message "gh-inbox: could not save state: %s" (error-message-string err)))))

(defun gh-inbox--dismissed-p (item)
  "Non-nil if ITEM was dismissed and has had no activity since."
  (gh-inbox--load-state)
  (when-let* ((hit (assoc (gh-inbox-item-url item) gh-inbox--dismissed)))
    (let ((then (cdr hit)) (now (gh-inbox-item-updated item)))
      (or (null now) (null then) (not (string> now then))))))

(defun gh-inbox--dismiss (item)
  "Dismiss ITEM until it has new activity."
  (gh-inbox--load-state)
  (setq gh-inbox--dismissed
        (cons (cons (gh-inbox-item-url item) (or (gh-inbox-item-updated item) ""))
              (assoc-delete-all (gh-inbox-item-url item) gh-inbox--dismissed)))
  (gh-inbox--save-state))

;;;; Fetching

(defun gh-inbox--snippet (body)
  "First non-empty line of BODY, whitespace collapsed, cut to 200 chars."
  (let* ((line (seq-find (lambda (l) (not (string-empty-p (string-trim l))))
                         (split-string (or body "") "[\r\n]+")
                         ""))
         (line (replace-regexp-in-string "[ \t]+" " " (string-trim line))))
    (truncate-string-to-width line 200 nil nil "…")))

(defun gh-inbox--hydrate (notifications items done)
  "Fetch latest-comment snippets for notified ITEMS, then call DONE.
NOTIFICATIONS are the raw alists (for their comment URLs)."
  (let* ((targets
          (seq-take
           (seq-filter
            (lambda (n)
              (and (member (alist-get 'reason n)
                           '("mention" "team_mention" "comment" "author"))
                   (gh-inbox--g n 'subject 'latest_comment_url)))
            notifications)
           gh-inbox-comment-fetch-limit))
         (pending (length targets))
         (by-url (make-hash-table :test #'equal)))
    (dolist (it items) (puthash (gh-inbox-item-url it) it by-url))
    (if (zerop pending)
        (funcall done items)
      (dolist (n targets)
        (let ((n n))
          (gh-inbox--gh
           (list "api" (gh-inbox--g n 'subject 'latest_comment_url))
           (lambda (ok out _err)
             (when ok
               (when-let* ((c (gh-inbox--parse out))
                           (item (gethash (gh-inbox--api-url->html
                                           (gh-inbox--g n 'subject 'url))
                                          by-url)))
                 (setf (gh-inbox-item-latest item)
                       (gh-inbox--snippet (alist-get 'body c))
                       (gh-inbox-item-latest-author item)
                       (gh-inbox--g c 'user 'login))))
             (when (zerop (cl-decf pending))
               (funcall done items)))))))))

(defun gh-inbox--account-ok-p (viewer)
  "Non-nil if VIEWER is the account the inbox belongs to; learns it when unknown.
When it is another account, records an error and returns nil."
  (gh-inbox--load-state)
  (let ((expected (or gh-inbox-expected-login gh-inbox--known-login)))
    (cond
     ((null viewer) nil)
     ((null expected)
      (setq gh-inbox--known-login viewer)
      (gh-inbox--save-state)
      t)
     ((equal viewer expected) t)
     (t
      (let ((msg (format "gh is on account %s, the inbox is for %s; switch back with `gh auth switch --user %s'"
                         viewer expected expected)))
        (unless (equal msg gh-inbox--last-error) (message "gh-inbox: %s" msg))
        (setq gh-inbox--last-error msg
              gh-inbox--fetch-clean nil
              gh-inbox--fetching nil))
      nil))))

(defun gh-inbox-forget-account ()
  "Forget which account the inbox belongs to; the next fetch learns it again.
Use this when you really want the inbox to follow a different login."
  (interactive)
  (setq gh-inbox--known-login nil gh-inbox--last-error nil)
  (gh-inbox--save-state)
  (message "gh-inbox: will learn the account on the next refresh"))

(defun gh-inbox--finish (graphql notifications callback)
  "Build items from GRAPHQL and NOTIFICATIONS, then CALLBACK with them.
Does nothing (and keeps the old items) when `gh' is on the wrong account."
  (if (not (gh-inbox--account-ok-p (gh-inbox--g graphql 'data 'viewer 'login)))
      (gh-inbox--render)
    (gh-inbox--finish-1 graphql notifications callback)))

(defun gh-inbox--finish-1 (graphql notifications callback)
  "The part of `gh-inbox--finish' that runs for the right account."
  (let* ((viewer (gh-inbox--g graphql 'data 'viewer 'login))
         (items (gh-inbox--merge graphql notifications viewer)))
    (setq gh-inbox--rate-remaining (gh-inbox--g graphql 'data 'rateLimit 'remaining))
    (gh-inbox--hydrate
     notifications items
     (lambda (items)
       (dolist (it items) (gh-inbox-classify it viewer))
       (setq gh-inbox--viewer viewer
             gh-inbox-items items
             gh-inbox--last-fetch (float-time)
             gh-inbox--last-error nil
             gh-inbox--fetching nil)
       (run-hooks 'gh-inbox-refresh-hook)
       (when callback (funcall callback items))))))

(defun gh-inbox-fetch (&optional callback)
  "Fetch PRs and notifications asynchronously, then run CALLBACK with items.
Also updates `gh-inbox-items' and runs `gh-inbox-refresh-hook'."
  (if (and gh-inbox--fetching (< (- (float-time) gh-inbox--fetching) 90))
      nil
    (setq gh-inbox--fetching (float-time))
    (let ((pending 2) graphql notifs errors)
      (cl-flet ((joined ()
                  (when (zerop (cl-decf pending))
                    (cond
                     ((and (null (gh-inbox--g graphql 'data)) errors)
                      (let ((msg (string-join (reverse errors) "; ")))
                        ;; Background polls would repeat the same message forever.
                        (unless (equal msg gh-inbox--last-error)
                          (message "gh-inbox: %s" msg))
                        (setq gh-inbox--fetching nil
                              gh-inbox--last-error msg))
                      (gh-inbox--render))
                     (t
                      (when errors
                        (message "gh-inbox: partial data (%s)"
                                 (truncate-string-to-width
                                  (string-join errors "; ") 120 nil nil "…")))
                      (setq gh-inbox--fetch-clean (null errors))
                      (gh-inbox--finish graphql notifs callback))))))
        (gh-inbox--gh
         (gh-inbox--graphql-args)
         (lambda (ok out err)
           ;; GraphQL may exit non-zero yet return usable partial data
           ;; (e.g. an org enforcing SAML), so parse regardless.
           (setq graphql (gh-inbox--parse out))
           (when (and (not ok) (not (gh-inbox--g graphql 'data)))
             (push (format "graphql: %s"
                           (truncate-string-to-width
                            (if (string-empty-p err) out err) 160 nil nil "…"))
                   errors))
           (joined)))
        (gh-inbox--gh
         (list "api" "notifications?participating=true&per_page=50")
         (lambda (ok out err)
           (if ok
               (setq notifs (let ((p (gh-inbox--parse out))) (and (listp p) p)))
             (push (format "notifications: %s"
                           (truncate-string-to-width err 160 nil nil "…"))
                   errors))
           (joined)))))
    t))

;;;; Views

(defconst gh-inbox-views
  '((needs "Needs me" "1")
    (review "Reviews" "2")
    (mine "Mine" "3")
    (mentions "Mentions" "4")
    (all "All" "5"))
  "Views: (SYMBOL LABEL KEY).")

(defvar-local gh-inbox--view 'needs "Current view in this buffer.")
(defvar-local gh-inbox--filter nil "Regexp filtering rows, or nil.")
(defvar-local gh-inbox--show-dismissed nil "Non-nil shows dismissed items.")

(defun gh-inbox--in-view-p (item view)
  "Non-nil if ITEM belongs to VIEW."
  (let ((roles (gh-inbox-item-roles item)))
    (pcase view
      ('needs (and (gh-inbox-item-tags item) t))
      ('review (or (memq 'requested roles) (memq 'reviewed roles)))
      ('mine (memq 'authored roles))
      ;; Review requests have their own view; this is mentions, replies, assignments.
      ('mentions (and (memq 'notified roles)
                      (not (equal (gh-inbox-item-notif-reason item) "review_requested"))))
      (_ t))))

(defun gh-inbox--item-text (item)
  "Searchable text of ITEM for the filter."
  (mapconcat (lambda (s) (or s ""))
             (list (gh-inbox-item-repo item)
                   (number-to-string (or (gh-inbox-item-number item) 0))
                   (gh-inbox-item-title item) (gh-inbox-item-author item)
                   (gh-inbox-item-head item) (gh-inbox-item-latest item))
             " "))

(defun gh-inbox--visible (items view filter show-dismissed)
  "ITEMS to display for VIEW, FILTER and SHOW-DISMISSED, sorted."
  (let ((case-fold-search t))
    (sort (seq-filter
           (lambda (it)
             (and (gh-inbox--in-view-p it view)
                  (or show-dismissed (not (gh-inbox--dismissed-p it)))
                  (or (null filter)
                      (string-match-p filter (gh-inbox--item-text it)))))
           items)
          (lambda (a b)
            (let ((ra (gh-inbox-item-rank a)) (rb (gh-inbox-item-rank b)))
              (if (/= ra rb)
                  (< ra rb)
                ;; Same urgency: reviews oldest-first (they wait on you),
                ;; everything else freshest-first.
                (let ((ua (or (gh-inbox-item-updated a) ""))
                      (ub (or (gh-inbox-item-updated b) "")))
                  (if (memq ra '(1 2)) (string< ua ub) (string> ua ub)))))))))

;;;; Rendering

(defun gh-inbox--short-repo (repo)
  "REPO without its owner."
  (if repo (replace-regexp-in-string "\\`[^/]*/" "" repo) ""))

(defun gh-inbox--ci-glyph (state)
  "Propertized glyph for CI STATE."
  (pcase state
    ("SUCCESS" (propertize "✓" 'face 'success))
    ((or "FAILURE" "ERROR") (propertize "✗" 'face 'error))
    ((or "PENDING" "EXPECTED") (propertize "…" 'face 'warning))
    (_ " ")))

(defun gh-inbox--decision-glyph (item)
  "Review state glyph for ITEM."
  (pcase (gh-inbox-item-decision item)
    ("APPROVED" (propertize "✔" 'face 'success))
    ("CHANGES_REQUESTED" (propertize "✖" 'face 'error))
    ("REVIEW_REQUIRED" (propertize "○" 'face 'gh-inbox-dim))
    (_ " ")))

(defun gh-inbox--age-cell (item)
  "Age of ITEM's last update, flagged when a review request is stale."
  (let* ((iso (gh-inbox-item-updated item))
         (str (gh-inbox--age-string iso))
         (secs (gh-inbox--age-seconds iso)))
    (propertize str 'face
                (if (and secs (memq 'requested (gh-inbox-item-roles item))
                         (> secs (* 2 86400)))
                    'gh-inbox-stale 'gh-inbox-dim))))

(defun gh-inbox--entry (item)
  "Tabulated-list entry for ITEM."
  (let* ((tags (mapconcat #'gh-inbox--tag-label (gh-inbox-item-tags item) " "))
         (tags (if (and (string-empty-p tags) (gh-inbox-item-draft item))
                   (propertize "draft" 'face 'gh-inbox-dim)
                 tags))
         (latest (if (gh-inbox-item-latest item)
                     (format "@%s: %s" (or (gh-inbox-item-latest-author item) "?")
                             (gh-inbox-item-latest item))
                   "")))
    (list (gh-inbox-item-url item)
          (vector tags
                  (propertize (gh-inbox--short-repo (gh-inbox-item-repo item))
                              'face 'gh-inbox-dim)
                  (propertize (format "#%s" (or (gh-inbox-item-number item) "?"))
                              'face 'gh-inbox-dim)
                  (or (gh-inbox-item-title item) "")
                  (propertize (or (gh-inbox-item-author item) "") 'face 'gh-inbox-dim)
                  (gh-inbox--ci-glyph (gh-inbox-item-ci item))
                  (gh-inbox--decision-glyph item)
                  (gh-inbox--age-cell item)
                  (propertize latest 'face 'gh-inbox-dim)))))

(defun gh-inbox--counts ()
  "Alist (VIEW . COUNT) over undismissed items."
  (let ((items (seq-remove #'gh-inbox--dismissed-p gh-inbox-items)))
    (mapcar (lambda (v)
              (cons (car v)
                    (seq-count (lambda (it) (gh-inbox--in-view-p it (car v))) items)))
            gh-inbox-views)))

(defun gh-inbox--header ()
  "Header-line string for the current buffer."
  (let ((counts (gh-inbox--counts)))
    (concat
     " "
     (mapconcat
      (lambda (v)
        (let ((txt (format " %s %s (%d) " (nth 2 v) (nth 1 v)
                           (alist-get (car v) counts 0))))
          (if (eq (car v) gh-inbox--view)
              (propertize txt 'face 'gh-inbox-view-active)
            (propertize txt 'face 'gh-inbox-dim))))
      gh-inbox-views " ")
     (cond ((and gh-inbox--rate-remaining (< gh-inbox--rate-remaining 300))
            (propertize (format "  ⚠ GitHub API budget low (%d)" gh-inbox--rate-remaining)
                        'face 'error))
           (gh-inbox--fetching (propertize "  ⟳ refreshing…" 'face 'warning))
           (gh-inbox--last-error (propertize (format "  ✗ %s" gh-inbox--last-error)
                                             'face 'error))
           (gh-inbox--last-fetch
            (propertize (format "  updated %s" (format-time-string
                                                "%H:%M" gh-inbox--last-fetch))
                        'face 'gh-inbox-dim))
           (t ""))
     (if gh-inbox--filter (format "  /%s/" gh-inbox--filter) "")
     (if gh-inbox--show-dismissed (propertize "  +dismissed" 'face 'gh-inbox-dim) ""))))

(defun gh-inbox--render ()
  "Redraw the inbox buffer from `gh-inbox-items'."
  (when-let* ((buf (get-buffer "*gh-inbox*")))
    (with-current-buffer buf
      (let ((items (gh-inbox--visible gh-inbox-items gh-inbox--view
                                      gh-inbox--filter gh-inbox--show-dismissed)))
        (setq tabulated-list-entries (mapcar #'gh-inbox--entry items))
        (setq header-line-format '(:eval (gh-inbox--header)))
        (tabulated-list-print t)
        (when (null items)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (propertize
                     (if gh-inbox-items
                         "\n  Nothing in this view. 🎉  (5 shows everything)\n"
                       "\n  Loading…\n")
                     'face 'gh-inbox-dim))))
        (force-mode-line-update)))))

;;;; Mode

(defvar gh-inbox-mode-map
  (let ((m (make-sparse-keymap)))
    (dolist (v gh-inbox-views)
      (let ((view (car v)))
        (define-key m (nth 2 v)
                    (lambda () (interactive) (gh-inbox-set-view view)))))
    (define-key m (kbd "RET") #'gh-inbox-open)
    (define-key m (kbd "o") #'gh-inbox-browse)
    (define-key m (kbd "y") #'gh-inbox-copy-url)
    (define-key m (kbd "v") #'gh-inbox-pr-review)
    (define-key m (kbd "c") #'gh-inbox-claude)
    (define-key m (kbd "L") #'gh-inbox-threads)
    (define-key m (kbd "N") #'gh-inbox-notes)
    (define-key m (kbd "d") #'gh-inbox-done)
    (define-key m (kbd "x") #'gh-inbox-done)
    (define-key m (kbd "D") #'gh-inbox-toggle-dismissed)
    (define-key m (kbd "T") #'gh-inbox-task)
    (define-key m (kbd "A") #'gh-inbox-approve)
    (define-key m (kbd "J") #'gh-inbox-browse-jira)
    (define-key m (kbd "s") #'gh-inbox-filter)
    (define-key m (kbd "r") #'gh-inbox-refresh)
    (define-key m (kbd "R") #'gh-inbox-refresh)
    (define-key m (kbd "TAB") #'gh-inbox-next-view)
    (define-key m (kbd "q") #'quit-window)
    (define-key m (kbd "?") #'gh-inbox-help)
    m)
  "Keymap for `gh-inbox-mode'.")

(define-derived-mode gh-inbox-mode tabulated-list-mode "GH-Inbox"
  "Major mode for the GitHub review inbox.
\\{gh-inbox-mode-map}"
  (setq tabulated-list-format
        [("Why" 22 nil) ("Repo" 16 nil) ("#" 6 nil) ("Title" 62 nil)
         ("Author" 14 nil) ("CI" 2 nil) ("Rv" 2 nil) ("Age" 4 nil)
         ("Latest" 0 nil)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil
        truncate-lines t)
  (setq-local bookmark-make-record-function #'gh-inbox--bookmark-record)
  (tabulated-list-init-header)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'gh-inbox-mode 'motion)
    (evil-define-key* 'motion gh-inbox-mode-map
      (kbd "RET") #'gh-inbox-open
      (kbd "o") #'gh-inbox-browse
      (kbd "y") #'gh-inbox-copy-url
      (kbd "v") #'gh-inbox-pr-review
      (kbd "c") #'gh-inbox-claude
      (kbd "L") #'gh-inbox-threads
      (kbd "N") #'gh-inbox-notes
      (kbd "d") #'gh-inbox-done
      (kbd "x") #'gh-inbox-done
      (kbd "D") #'gh-inbox-toggle-dismissed
      (kbd "T") #'gh-inbox-task
      (kbd "A") #'gh-inbox-approve
      (kbd "J") #'gh-inbox-browse-jira
      (kbd "s") #'gh-inbox-filter
      (kbd "r") #'gh-inbox-refresh
      (kbd "R") #'gh-inbox-refresh
      (kbd "gr") #'gh-inbox-refresh
      (kbd "TAB") #'gh-inbox-next-view
      (kbd "q") #'quit-window
      (kbd "?") #'gh-inbox-help
      (kbd "1") (lambda () (interactive) (gh-inbox-set-view 'needs))
      (kbd "2") (lambda () (interactive) (gh-inbox-set-view 'review))
      (kbd "3") (lambda () (interactive) (gh-inbox-set-view 'mine))
      (kbd "4") (lambda () (interactive) (gh-inbox-set-view 'mentions))
      (kbd "5") (lambda () (interactive) (gh-inbox-set-view 'all)))))

;;;; Bookmarks (so `activities' can save and restore the inbox)

(defun gh-inbox--bookmark-record ()
  "Bookmark record for the inbox buffer."
  `("GitHub inbox" (handler . gh-inbox-bookmark-handler) (view . ,gh-inbox--view)))

(defun gh-inbox-bookmark-handler (bmk)
  "Restore the inbox from bookmark BMK, refreshing when stale."
  (let ((buf (get-buffer-create "*gh-inbox*"))
        (view (or (bookmark-prop-get bmk 'view) 'needs)))
    (with-current-buffer buf
      (unless (derived-mode-p 'gh-inbox-mode) (gh-inbox-mode))
      (setq gh-inbox--view view))
    (gh-inbox--render)
    (when (or (null gh-inbox--last-fetch)
              (> (- (float-time) gh-inbox--last-fetch) gh-inbox-stale-seconds))
      (gh-inbox-fetch))
    (set-buffer buf)))

(put 'gh-inbox-bookmark-handler 'bookmark-handler-type "GH-Inbox")

;;;; Commands

(defun gh-inbox--item ()
  "Item at point, or a user error."
  (let ((id (tabulated-list-get-id)))
    (or (and id (seq-find (lambda (it) (equal (gh-inbox-item-url it) id))
                          gh-inbox-items))
        (user-error "No item at point"))))

(defun gh-inbox--pr-item-at-point ()
  "Item at point, which must be a PR."
  (let ((it (gh-inbox--item)))
    (unless (eq (gh-inbox-item-kind it) 'pr)
      (user-error "That is an issue, not a PR (o opens it in the browser)"))
    it))

;;;###autoload
(defun gh-inbox ()
  "Open the GitHub review inbox, refreshing if the data is stale."
  (interactive)
  (let ((buf (get-buffer-create "*gh-inbox*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'gh-inbox-mode) (gh-inbox-mode)))
    (switch-to-buffer buf)
    (gh-inbox--render)
    (when (or (null gh-inbox--last-fetch)
              (> (- (float-time) gh-inbox--last-fetch) gh-inbox-stale-seconds))
      (gh-inbox-refresh))))

(defun gh-inbox-refresh ()
  "Re-fetch everything from GitHub."
  (interactive)
  (if (gh-inbox-fetch)
      (progn (message "gh-inbox: refreshing…") (gh-inbox--render))
    (message "gh-inbox: already refreshing")))

(add-hook 'gh-inbox-refresh-hook #'gh-inbox--render)

(defun gh-inbox-set-view (view)
  "Show VIEW."
  (setq gh-inbox--view view)
  (gh-inbox--render)
  (goto-char (point-min)))

(defun gh-inbox-help ()
  "Show the inbox key bindings."
  (interactive)
  (with-help-window "*gh-inbox help*"
    (princ "GitHub inbox\n\n")
    (princ "Views      1 needs me   2 reviews   3 mine   4 mentions   5 all   TAB cycle\n")
    (princ "Open       RET review activity (worktree + diff + threads)   o browser\n")
    (princ "           v pr-review   L unresolved threads (C-u: all)   J Jira   y copy URL\n")
    (princ "Claude     c review someone's PR / address threads / fix CI   (C-u: choose)\n")
    (princ "           clearcompany/clearcompany runs your /insync:clearco-pr-review and\n")
    (princ "           /insync:clearco-feedback-resolver; see `gh-inbox-review-skills'\n")
    (princ "           N open the review draft Claude wrote\n")
    (princ "Triage     d or x dismiss until new activity   D show dismissed\n")
    (princ "           T Taskwarrior task   A approve (asks first)\n")
    (princ "Other      s filter (regexp)   r / gr refresh   q quit   ? this help\n\n")
    (princ "Tags: CHANGES REVIEW RE-REVIEW MENTION ASSIGNED THREADS:n CI✗ READY COMMENT\n")
    (princ "Columns: CI ✓/✗/…   Rv ✔ approved ✖ changes ○ required   Age since last activity\n")))

(defun gh-inbox-next-view ()
  "Cycle to the next view."
  (interactive)
  (let* ((names (mapcar #'car gh-inbox-views))
         (next (or (cadr (memq gh-inbox--view names)) (car names))))
    (gh-inbox-set-view next)))

(defun gh-inbox-filter (regexp)
  "Filter rows by REGEXP (empty clears)."
  (interactive (list (read-string "Filter (regexp, empty clears): " gh-inbox--filter)))
  (setq gh-inbox--filter (and (not (string-empty-p regexp)) regexp))
  (gh-inbox--render))

(defun gh-inbox-toggle-dismissed ()
  "Toggle showing dismissed items."
  (interactive)
  (setq gh-inbox--show-dismissed (not gh-inbox--show-dismissed))
  (gh-inbox--render))

(defun gh-inbox-browse ()
  "Open the item at point in the browser."
  (interactive)
  (browse-url (gh-inbox-item-url (gh-inbox--item))))

(defun gh-inbox-copy-url ()
  "Copy the item's URL."
  (interactive)
  (let ((url (gh-inbox-item-url (gh-inbox--item))))
    (kill-new url)
    (message "Copied %s" url)))

(defun gh-inbox--ticket (item)
  "Jira-style key in ITEM's title or branch, or nil."
  (let ((re "\\b[A-Z][A-Z0-9]+-[0-9]+\\b"))
    (or (and (gh-inbox-item-title item)
             (string-match re (gh-inbox-item-title item))
             (match-string 0 (gh-inbox-item-title item)))
        (and (gh-inbox-item-head item)
             (let ((case-fold-search nil)
                   (br (upcase (gh-inbox-item-head item))))
               (and (string-match re br) (match-string 0 br)))))))

(defun gh-inbox-browse-jira ()
  "Open the Jira ticket named in the item's title or branch."
  (interactive)
  (let* ((item (gh-inbox--item))
         (key (gh-inbox--ticket item)))
    (cond ((null key) (user-error "No ticket key in title or branch"))
          ((null gh-inbox-jira-base-url)
           (kill-new key)
           (user-error "Set `gh-inbox-jira-base-url' to open %s (key copied)" key))
          (t (browse-url (concat gh-inbox-jira-base-url key))))))

(defun gh-inbox--mark-done-on-github (item)
  "Mark ITEM's GitHub notification thread as done, if it has one."
  (when-let* ((id (gh-inbox-item-notif-id item)))
    (gh-inbox--gh (list "api" "-X" "DELETE" (format "notifications/threads/%s" id))
                  (lambda (ok _o err)
                    (unless ok (message "gh-inbox: could not mark done: %s" err))))))

(defun gh-inbox-done ()
  "Dismiss the item until it has new activity; mark its notification done."
  (interactive)
  (let ((item (gh-inbox--item)))
    (gh-inbox--dismiss item)
    (gh-inbox--mark-done-on-github item)
    (gh-inbox--render)
    (message "Dismissed %s#%s (returns on new activity)"
             (gh-inbox--short-repo (gh-inbox-item-repo item))
             (gh-inbox-item-number item))))

(defun gh-inbox-approve ()
  "Approve the PR at point after confirmation."
  (interactive)
  (let ((item (gh-inbox--pr-item-at-point)))
    (when (yes-or-no-p (format "Approve %s#%s \"%s\"? "
                               (gh-inbox--short-repo (gh-inbox-item-repo item))
                               (gh-inbox-item-number item)
                               (gh-inbox-item-title item)))
      (let ((body (read-string "Review comment (optional): ")))
        (gh-inbox--gh
         (append (list "pr" "review" (number-to-string (gh-inbox-item-number item))
                       "-R" (gh-inbox-item-repo item) "--approve")
                 (unless (string-empty-p body) (list "--body" body)))
         (lambda (ok _o err)
           (if ok
               (progn (message "Approved %s#%s" (gh-inbox-item-repo item)
                               (gh-inbox-item-number item))
                      (gh-inbox-refresh))
             (message "gh-inbox: approve failed: %s" err))))))))

;; Actions implemented in other files, reached through the same keys.

(defun gh-inbox-open ()
  "Open the PR at point as a review activity (worktree, diff, threads)."
  (interactive)
  (let ((item (gh-inbox--item)))
    (if (eq (gh-inbox-item-kind item) 'pr)
        (progn (require 'gh-inbox-review) (gh-inbox-review-open item))
      (browse-url (gh-inbox-item-url item)))))

(defun gh-inbox-claude ()
  "Start Claude on the PR at point: a first-pass review, or fix your own.
With a prefix argument, choose between review, address and ci."
  (interactive)
  (require 'gh-inbox-review)
  (gh-inbox-review-claude (gh-inbox--pr-item-at-point) current-prefix-arg))

(defun gh-inbox-notes ()
  "Open the findings file Claude wrote for the PR at point."
  (interactive)
  (require 'gh-inbox-review)
  (gh-inbox-review-notes (gh-inbox--pr-item-at-point)))

(defun gh-inbox-threads ()
  "Show unresolved review threads of the PR at point as a `next-error' list."
  (interactive)
  (require 'gh-inbox-review)
  (gh-inbox-review-threads (gh-inbox--pr-item-at-point) current-prefix-arg))

(defun gh-inbox-pr-review ()
  "Open the PR at point in `pr-review'."
  (interactive)
  (require 'gh-inbox-review)
  (gh-inbox-review-pr-review (gh-inbox--pr-item-at-point)))

(defun gh-inbox-task ()
  "Create a Taskwarrior task for the item at point."
  (interactive)
  (require 'gh-inbox-notify)
  (gh-inbox-notify-task (gh-inbox--item)))

(provide 'gh-inbox)
;;; gh-inbox.el ends here
