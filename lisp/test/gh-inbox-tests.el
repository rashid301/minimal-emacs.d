;;; gh-inbox-tests.el --- Tests for gh-inbox  -*- lexical-binding: t; -*-

;; Run:  emacs --batch -L lisp/util -L lisp/test -l gh-inbox-tests \
;;         -f ert-run-tests-batch-and-exit
;; Nothing here talks to GitHub or touches your Taskwarrior data.

(require 'ert)
(require 'gh-inbox)
(require 'gh-inbox-review)
(require 'gh-inbox-notify)
(require 'worktrunk)

(defmacro gh-inbox-test-with-state (&rest body)
  "Run BODY with a throwaway dismissed-state file."
  `(let* ((gh-inbox-state-file (make-temp-file "gh-inbox-state" nil ".eld"))
          (gh-inbox--dismissed nil)
          (gh-inbox--dismissed-loaded nil))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file gh-inbox-state-file)))))

(defun gh-inbox-test--item (&rest args)
  ;; The constructor takes the FIRST of duplicate keys, so ARGS go first.
  (apply #'gh-inbox-item-create
         (append args
                 (list :url "https://github.com/o/r/pull/1" :repo "o/r" :number 1 :title "T"
                       :kind 'pr :author "someone" :updated "2026-11-10T00:00:00Z"))))

(defun gh-inbox-test--tags (item &optional viewer)
  (mapcar #'car (gh-inbox-item-tags (gh-inbox-classify item (or viewer "me")))))

;;;; URLs, times

(ert-deftest gh-inbox-api-url ()
  (should (equal (gh-inbox--api-url->html "https://api.github.com/repos/o/r/pulls/12")
                 "https://github.com/o/r/pull/12"))
  (should (equal (gh-inbox--api-url->html "https://api.github.com/repos/o/r/issues/5")
                 "https://github.com/o/r/issues/5"))
  (should-not (gh-inbox--api-url->html "https://api.github.com/repos/o/r/commits/abc"))
  (should-not (gh-inbox--api-url->html nil)))

(ert-deftest gh-inbox-age-string ()
  (let ((now (float-time)))
    (cl-flet ((ago (secs) (format-time-string "%FT%TZ" (- now secs) t)))
      (should (equal (gh-inbox--age-string (ago 120)) "2m"))
      (should (equal (gh-inbox--age-string (ago 7200)) "2h"))
      (should (equal (gh-inbox--age-string (ago (* 3 86400))) "3d"))
      (should (equal (gh-inbox--age-string (ago (* 21 86400))) "3w"))
      (should (equal (gh-inbox--age-string nil) "")))))

(ert-deftest gh-inbox-snippet ()
  (should (equal (gh-inbox--snippet "\n\n  hello   world \nsecond") "hello world"))
  (should (equal (gh-inbox--snippet nil) ""))
  (should (<= (length (gh-inbox--snippet (make-string 500 ?x))) 200)))

(ert-deftest gh-inbox-ticket ()
  (should (equal (gh-inbox--ticket (gh-inbox-test--item :title "[feature] DEV-33555 x")) "DEV-33555"))
  (should (equal (gh-inbox--ticket (gh-inbox-test--item :title "plain" :head "feature/dev-42-thing"))
                 "DEV-42"))
  (should-not (gh-inbox--ticket (gh-inbox-test--item :title "plain" :head "main"))))

;;;; Classification

(ert-deftest gh-inbox-classify-review-requested ()
  (should (equal (gh-inbox-test--tags (gh-inbox-test--item :roles '(requested))) '(review)))
  ;; Someone else's draft never needs you.
  (should-not (gh-inbox-test--tags (gh-inbox-test--item :roles '(requested) :draft t))))

(ert-deftest gh-inbox-classify-my-pr ()
  (let ((tags (gh-inbox-test--tags
               (gh-inbox-test--item :author "me" :roles '(authored)
                                    :decision "CHANGES_REQUESTED" :threads 3 :ci "FAILURE"))))
    (should (equal tags '(changes threads ci))))
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :author "me" :roles '(authored) :decision "APPROVED"
                                       :ci "SUCCESS" :mergeable "MERGEABLE"))
                 '(ready)))
  ;; Approved but red, conflicting or draft is not READY.
  (should-not (gh-inbox-test--tags
               (gh-inbox-test--item :author "me" :roles '(authored) :decision "APPROVED"
                                    :ci "SUCCESS" :mergeable "CONFLICTING")))
  (should-not (gh-inbox-test--tags
               (gh-inbox-test--item :author "me" :roles '(authored) :draft t :decision "APPROVED"
                                    :ci "SUCCESS" :mergeable "MERGEABLE")))
  ;; My own draft still reports failing CI.
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :author "me" :roles '(authored) :draft t :ci "FAILURE"))
                 '(ci))))

(ert-deftest gh-inbox-classify-re-review ()
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :roles '(reviewed) :head-oid "b" :my-review-oid "a"
                                       :my-review-state "CHANGES_REQUESTED"))
                 '(re-review)))
  ;; Same commit: nothing new.
  (should-not (gh-inbox-test--tags
               (gh-inbox-test--item :roles '(reviewed) :head-oid "a" :my-review-oid "a")))
  ;; I approved: pushes after approval do not nag.
  (should-not (gh-inbox-test--tags
               (gh-inbox-test--item :roles '(reviewed) :head-oid "b" :my-review-oid "a"
                                    :my-review-state "APPROVED")))
  ;; Re-requested review is a plain REVIEW, not both.
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :roles '(reviewed requested) :head-oid "b"
                                       :my-review-oid "a" :my-review-state "COMMENTED"))
                 '(review))))

(ert-deftest gh-inbox-classify-notifications ()
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :roles '(notified) :notif-reason "mention")) '(mention)))
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :roles '(notified) :notif-reason "team_mention")) '(mention)))
  ;; Assignment on someone else's PR matters; on my own it is noise.
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :roles '(notified) :notif-reason "assign")) '(assigned)))
  (should-not (gh-inbox-test--tags
               (gh-inbox-test--item :author "me" :roles '(notified authored) :notif-reason "assign")))
  ;; A comment thread where I spoke last is not waiting on me.
  (should (equal (gh-inbox-test--tags
                  (gh-inbox-test--item :roles '(notified) :notif-reason "comment"
                                       :latest-author "bob")) '(comment)))
  (should-not (gh-inbox-test--tags
               (gh-inbox-test--item :roles '(notified) :notif-reason "comment"
                                    :latest-author "me"))))

(ert-deftest gh-inbox-rank ()
  (let ((a (gh-inbox-classify (gh-inbox-test--item :roles '(requested)) "me"))
        (b (gh-inbox-classify (gh-inbox-test--item :author "me" :roles '(authored)
                                                   :decision "CHANGES_REQUESTED") "me"))
        (c (gh-inbox-classify (gh-inbox-test--item :roles '(authored) :author "me") "me")))
    (should (< (gh-inbox-item-rank b) (gh-inbox-item-rank a)))
    (should (= (gh-inbox-item-rank c) 99))))

;;;; Query shape

(ert-deftest gh-inbox-query-cost-shape ()
  "Review threads (the expensive part) are requested only for `mine'."
  (let ((q gh-inbox--query))
    (should (string-match-p "mine: +search([^)]*) { nodes { \\.\\.\\.PR \\.\\.\\.Threads }" q))
    (should (string-match-p "rq: +search([^)]*) { nodes { \\.\\.\\.PR }" q))
    (should (string-match-p "rev: +search([^)]*) { nodes { \\.\\.\\.PR }" q))
    (should (string-match-p "rateLimit" q))
    ;; The shared fragment must not drag threads in.
    (should-not (string-match-p "fragment PR on PullRequest {[^}]*reviewThreads" q))))

;;;; Wrong GitHub account (gh auth switch)

(ert-deftest gh-inbox-wrong-account-changes-nothing ()
  "A fetch for another login must not touch items, run hooks or allow task sync."
  (gh-inbox-test-with-state
   (let* ((gh-inbox--known-login nil) (gh-inbox-expected-login nil)
          (gh-inbox--last-error nil) (gh-inbox--fetch-clean t) (gh-inbox--fetching (float-time))
          (gh-inbox-items (list (gh-inbox-test--item :roles '(requested))))
          (before gh-inbox-items) (hook-ran 0) (called nil)
          (gh-inbox-refresh-hook nil)
          (work (gh-inbox--parse "{\"data\":{\"viewer\":{\"login\":\"work\"},\"rq\":{\"nodes\":[]},\"mine\":{\"nodes\":[]},\"rev\":{\"nodes\":[]}}}"))
          (personal (gh-inbox--parse "{\"data\":{\"viewer\":{\"login\":\"personal\"},\"rq\":{\"nodes\":[]},\"mine\":{\"nodes\":[]},\"rev\":{\"nodes\":[]}}}")))
     (add-hook 'gh-inbox-refresh-hook (lambda () (cl-incf hook-ran)))
     ;; First fetch learns the account and proceeds (state is saved to disk).
     (gh-inbox--finish work nil (lambda (_) (setq called t)))
     (should called)
     (should (equal gh-inbox--known-login "work"))
     (should (= hook-ran 1))
     ;; gh switched to another account: nothing changes.
     (setq called nil gh-inbox-items before gh-inbox--fetch-clean t gh-inbox--fetching (float-time))
     (gh-inbox--finish personal nil (lambda (_) (setq called t)))
     (should-not called)
     (should (= hook-ran 1))                  ; hooks (task sync!) did not run
     (should (eq gh-inbox-items before))      ; the old items are kept
     (should-not gh-inbox--fetch-clean)       ; and nothing may treat the fetch as complete
     (should-not gh-inbox--fetching)
     (should (string-match-p "gh auth switch --user work" gh-inbox--last-error))
     ;; Switching back resumes normally and clears the error.
     (setq gh-inbox--fetching (float-time))
     (gh-inbox--finish work nil (lambda (_) (setq called t)))
     (should called)
     (should-not gh-inbox--last-error)
     (should (= hook-ran 2))
     ;; The learned account survives a restart.
     (setq gh-inbox--known-login nil gh-inbox--dismissed-loaded nil)
     (gh-inbox--load-state)
     (should (equal gh-inbox--known-login "work"))
     ;; An explicit expectation wins, and forgetting lets a new account in.
     (let ((gh-inbox-expected-login "other"))
       (should-not (gh-inbox--account-ok-p "work")))
     (gh-inbox-forget-account)
     (should (gh-inbox--account-ok-p "personal"))
     (should (equal gh-inbox--known-login "personal")))))

;;;; Merging

(defconst gh-inbox-test--graphql
  (gh-inbox--parse "{\"data\":{\"viewer\":{\"login\":\"me\"},
 \"rq\":{\"nodes\":[{\"number\":1,\"title\":\"Req\",\"url\":\"https://github.com/o/r/pull/1\",
   \"isDraft\":false,\"updatedAt\":\"2026-11-10T00:00:00Z\",\"author\":{\"login\":\"al\"},
   \"repository\":{\"nameWithOwner\":\"o/r\"},\"headRefName\":\"feat\",\"baseRefName\":\"main\",
   \"headRefOid\":\"h1\",\"reviewDecision\":null,\"mergeable\":\"MERGEABLE\",
   \"commits\":{\"nodes\":[{\"commit\":{\"oid\":\"h2\",\"statusCheckRollup\":{\"state\":\"SUCCESS\"}}}]},
   \"reviewThreads\":{\"nodes\":[{\"isResolved\":false,\"comments\":{\"nodes\":[{\"author\":{\"login\":\"al\"}}]}},{\"isResolved\":true},{\"isResolved\":false,\"comments\":{\"nodes\":[{\"author\":{\"login\":\"me\"}}]}}]},
   \"latestReviews\":{\"nodes\":[{\"author\":{\"login\":\"me\"},\"state\":\"COMMENTED\",\"commit\":{\"oid\":\"h0\"}}]}}]},
 \"mine\":{\"nodes\":[{\"number\":2,\"title\":\"Mine\",\"url\":\"https://github.com/o/r/pull/2\",
   \"author\":{\"login\":\"me\"},\"repository\":{\"nameWithOwner\":\"o/r\"},\"updatedAt\":\"2026-11-11T00:00:00Z\",
   \"commits\":{\"nodes\":[]},\"reviewThreads\":{\"nodes\":[]},\"latestReviews\":{\"nodes\":[]}}]},
 \"rev\":{\"nodes\":[{\"number\":1,\"url\":\"https://github.com/o/r/pull/1\"}]}}}"))

(defconst gh-inbox-test--notifs
  (gh-inbox--parse "[{\"id\":\"9\",\"reason\":\"mention\",\"updated_at\":\"2026-11-12T00:00:00Z\",
 \"subject\":{\"title\":\"Issue\",\"type\":\"Issue\",\"url\":\"https://api.github.com/repos/o/r/issues/7\"},
 \"repository\":{\"full_name\":\"o/r\"}},
 {\"id\":\"10\",\"reason\":\"mention\",\"updated_at\":\"2026-11-13T00:00:00Z\",
 \"subject\":{\"title\":\"Req\",\"type\":\"PullRequest\",\"url\":\"https://api.github.com/repos/o/r/pulls/1\"},
 \"repository\":{\"full_name\":\"o/r\"}},
 {\"id\":\"11\",\"reason\":\"ci_activity\",\"subject\":{\"type\":\"CheckSuite\",\"url\":null,\"title\":\"x\"},
 \"repository\":{\"full_name\":\"o/r\"}}]"))

(ert-deftest gh-inbox-merge ()
  (let* ((items (gh-inbox--merge gh-inbox-test--graphql gh-inbox-test--notifs "me"))
         (by (lambda (n) (seq-find (lambda (i) (eql (gh-inbox-item-number i) n)) items))))
    ;; PR 1 (rq + rev + notification) is one item; CheckSuite is dropped.
    (should (= (length items) 3))
    (let ((pr1 (funcall by 1)))
      (should (equal (sort (mapcar #'symbol-name (gh-inbox-item-roles pr1)) #'string<)
                     '("notified" "requested" "reviewed")))
      (should (equal (gh-inbox-item-head-oid pr1) "h2"))     ; latest commit wins
      (should (equal (gh-inbox-item-ci pr1) "SUCCESS"))
      (should (= (gh-inbox-item-threads pr1) 1))
      (should (equal (gh-inbox-item-my-review-oid pr1) "h0"))
      (should (equal (gh-inbox-item-notif-id pr1) "10"))
      ;; updated = newest of PR and notification
      (should (equal (gh-inbox-item-updated pr1) "2026-11-13T00:00:00Z")))
    (should (eq (gh-inbox-item-kind (funcall by 7)) 'issue))
    (should (equal (gh-inbox-item-roles (funcall by 2)) '(authored)))))

;;;; Dismissing, views, sorting

(ert-deftest gh-inbox-dismiss-until-new-activity ()
  (gh-inbox-test-with-state
   (let ((it (gh-inbox-test--item :updated "2026-11-10T00:00:00Z")))
     (should-not (gh-inbox--dismissed-p it))
     (gh-inbox--dismiss it)
     (should (gh-inbox--dismissed-p it))
     ;; New activity brings it back.
     (setf (gh-inbox-item-updated it) "2026-11-11T00:00:00Z")
     (should-not (gh-inbox--dismissed-p it))
     ;; State survives a reload from disk.
     (setf (gh-inbox-item-updated it) "2026-11-10T00:00:00Z")
     (setq gh-inbox--dismissed nil gh-inbox--dismissed-loaded nil)
     (should (gh-inbox--dismissed-p it)))))

(ert-deftest gh-inbox-views-and-sort ()
  (gh-inbox-test-with-state
   (let* ((old-req (gh-inbox-classify (gh-inbox-test--item :url "u1" :number 1 :roles '(requested)
                                                           :updated "2026-11-01T00:00:00Z") "me"))
          (new-req (gh-inbox-classify (gh-inbox-test--item :url "u2" :number 2 :roles '(requested)
                                                           :updated "2026-11-09T00:00:00Z") "me"))
          (changes (gh-inbox-classify (gh-inbox-test--item :url "u3" :number 3 :author "me"
                                                           :roles '(authored) :decision "CHANGES_REQUESTED"
                                                           :updated "2026-11-05T00:00:00Z") "me"))
          (quiet (gh-inbox-classify (gh-inbox-test--item :url "u4" :number 4 :author "me"
                                                         :roles '(authored)) "me"))
          (items (list new-req quiet old-req changes)))
     ;; Needs me: CHANGES first, then reviews oldest-first; quiet PR excluded.
     (should (equal (mapcar #'gh-inbox-item-number (gh-inbox--visible items 'needs nil nil))
                    '(3 1 2)))
     (should (equal (sort (mapcar #'gh-inbox-item-number (gh-inbox--visible items 'mine nil nil)) #'<)
                    '(3 4)))
     (should (= (length (gh-inbox--visible items 'all nil nil)) 4))
     ;; Filter is case-insensitive over repo/title/author.
     (should (= (length (gh-inbox--visible items 'all "SOMEONE" nil)) 2))
     ;; Dismissed items vanish unless asked for.
     (gh-inbox--dismiss old-req)
     (should (equal (mapcar #'gh-inbox-item-number (gh-inbox--visible items 'needs nil nil))
                    '(3 2)))
     (should (= (length (gh-inbox--visible items 'needs nil t)) 3)))))

(ert-deftest gh-inbox-render ()
  "Rendering produces one row per visible item and survives odd data."
  (gh-inbox-test-with-state
   (let ((gh-inbox-items
          (list (gh-inbox-classify
                 (gh-inbox-test--item :roles '(requested) :ci "FAILURE" :decision "REVIEW_REQUIRED"
                                      :latest "hi" :latest-author "bob") "me")
                (gh-inbox-classify (gh-inbox-test--item :url "u9" :title nil :number nil
                                                        :author nil :updated nil :roles '(notified)
                                                        :notif-reason "mention") "me")))
         (gh-inbox--viewer "me"))
     (with-current-buffer (get-buffer-create "*gh-inbox*")
       (gh-inbox-mode)
       (gh-inbox--render)
       (should (= (length tabulated-list-entries) 2))
       (should (string-match-p "REVIEW" (buffer-string)))
       (should (string-match-p "@bob: hi" (buffer-string)))
       (should (string-match-p "Needs me (2)" (gh-inbox--header)))
       (gh-inbox-set-view 'review)
       (should (= (length tabulated-list-entries) 1))
       (kill-buffer)))))

;;;; Empty states

(ert-deftest gh-inbox-render-empty ()
  "Loading and empty views render without touching read-only text."
  (gh-inbox-test-with-state
   (with-current-buffer (get-buffer-create "*gh-inbox*")
     (gh-inbox-mode)
     (let ((gh-inbox-items nil))
       (gh-inbox--render)
       (should (string-match-p "Loading" (buffer-string))))
     (let ((gh-inbox-items (list (gh-inbox-test--item))))   ; no tags: not in "needs"
       (gh-inbox--render)
       (should (string-match-p "Nothing in this view" (buffer-string)))
       (gh-inbox-set-view 'all)
       (should (= (length tabulated-list-entries) 1))
       (should-not (string-match-p "Nothing in this view" (buffer-string))))
     (kill-buffer))))

;;;; Repo detection

(defun gh-inbox-test--make-repo (dir remote-url &optional extra)
  (make-directory (expand-file-name ".git" dir) t)
  (with-temp-file (expand-file-name ".git/config" dir)
    (insert "[core]\n\tbare = false\n" (or extra "")
            "[remote \"origin\"]\n\turl = " remote-url "\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
            "[branch \"main\"]\n\tremote = origin\n")))

(ert-deftest gh-inbox-origin-repo ()
  (let ((tmp (make-temp-file "ghr" t)))
    (unwind-protect
        (progn
          (dolist (c '(("a" . "https://github.com/Owner/Repo.git")
                       ("b" . "git@github.com:Owner/Repo.git")
                       ("c" . "https://github.com/Owner/Repo")
                       ("d" . "https://user@github.com/Owner/my.repo.git")))
            (let ((d (expand-file-name (car c) tmp)))
              (gh-inbox-test--make-repo d (cdr c))
              (should (equal (gh-inbox-review--origin-repo d)
                             (if (equal (car c) "d") "Owner/my.repo" "Owner/Repo")))))
          ;; A fork remote listed before origin must not win.
          (let ((d (expand-file-name "e" tmp)))
            (gh-inbox-test--make-repo d "https://github.com/real/one.git"
                                      "[remote \"fork\"]\n\turl = https://github.com/me/fork.git\n")
            (should (equal (gh-inbox-review--origin-repo d) "real/one")))
          ;; Not a main checkout (.git is a file) or not GitHub.
          (let ((d (expand-file-name "f" tmp)))
            (make-directory d t)
            (with-temp-file (expand-file-name ".git" d) (insert "gitdir: /x/.git/worktrees/f\n"))
            (should-not (gh-inbox-review--origin-repo d)))
          (let ((d (expand-file-name "g" tmp)))
            (gh-inbox-test--make-repo d "https://gitlab.com/o/r.git")
            (should-not (gh-inbox-review--origin-repo d))))
      (delete-directory tmp t))))

(ert-deftest gh-inbox-repo-directory-lookup ()
  (let* ((tmp (make-temp-file "ghr" t))
         (gh-inbox-review--cache nil)
         (gh-inbox-review--cache-loaded t)
         (gh-inbox-review-cache-file (expand-file-name "cache.eld" tmp))
         (gh-inbox-review-repo-directories nil)
         (gh-inbox-review-search-roots (list tmp)))
    (unwind-protect
        (progn
          (gh-inbox-test--make-repo (expand-file-name "clone" tmp) "https://github.com/Acme/Thing.git")
          (gh-inbox-test--make-repo (expand-file-name "other" tmp) "https://github.com/Acme/Other.git")
          (cl-letf (((symbol-function 'project-known-project-roots) (lambda () nil)))
            ;; Case-insensitive match through the search root, then cached.
            (should (equal (gh-inbox-review-repo-directory "acme/thing")
                           (file-name-as-directory (expand-file-name "clone" tmp))))
            (should (file-exists-p gh-inbox-review-cache-file))
            ;; Configured entry wins.
            (let ((gh-inbox-review-repo-directories `(("acme/thing" . ,(expand-file-name "other" tmp)))))
              (should (equal (gh-inbox-review-repo-directory "acme/thing")
                             (file-name-as-directory (expand-file-name "other" tmp)))))))
      (delete-directory tmp t))))

;;;; Worktree lookup

(defconst gh-inbox-test--wt-json
  "{\"items\":[{\"branch\":\"main\",\"worktree\":{\"path\":\"/r/repo\",\"main\":true,\"current\":true}},
 {\"branch\":\"feat/x\",\"worktree\":{\"path\":\"/r/repo.feat-x\"}},
 {\"branch\":\"loose\",\"worktree\":null},
 {\"branch\":null,\"worktree\":{\"path\":\"/r/repo.detached\"}}]}")

(ert-deftest gh-inbox-review-parse-worktrees ()
  (let ((wts (gh-inbox-review--parse-worktrees gh-inbox-test--wt-json)))
    (should (= (length wts) 3))               ; branch without worktree is dropped
    (should (equal (gh-inbox-review--find-branch-path wts "feat/x") "/r/repo.feat-x"))
    (should-not (gh-inbox-review--find-branch-path wts "loose"))
    (should-not (gh-inbox-review--find-branch-path wts nil))
    (should-not (gh-inbox-review--parse-worktrees "not json"))))

(ert-deftest gh-inbox-review-worktrees-async-and-local-directory ()
  "Async lookup through a fake `wt', then the cache feeds `local-directory'."
  (let* ((tmp (make-temp-file "gwt" t))
         (fake (expand-file-name "wt" tmp))
         (gh-inbox-review--wt-cache (make-hash-table :test #'equal))
         (gh-inbox-review-repo-directories `(("o/r" . ,tmp)))
         (worktrunk-executable fake)
         (item (gh-inbox-test--item :head "feat/x"))
         wts done)
    (unwind-protect
        (progn
          (with-temp-file fake
            (insert "#!/bin/sh\ncat <<'EOF'\n" gh-inbox-test--wt-json "\nEOF\n"))
          (set-file-modes fake #o755)
          (require 'worktrunk)
          ;; Before any lookup there is nothing cached: fall back to the main checkout.
          (should (equal (gh-inbox-review--local-directory item) (file-name-as-directory tmp)))
          (gh-inbox-review--worktrees-async (file-name-as-directory tmp) (lambda (w) (setq wts w done t)))
          (should (gh-inbox-test--wait (lambda () done)))
          (should (equal (gh-inbox-review--find-branch-path wts "feat/x") "/r/repo.feat-x"))
          (should (equal (gh-inbox-review--local-directory item) "/r/repo.feat-x"))
          ;; A failing `wt' yields nil and keeps the old cache.
          (with-temp-file fake (insert "#!/bin/sh\nexit 3\n"))
          (setq done nil wts 'unset)
          (gh-inbox-review--worktrees-async (file-name-as-directory tmp) (lambda (w) (setq wts w done t)))
          (should (gh-inbox-test--wait (lambda () done)))
          (should-not wts)
          (should (equal (gh-inbox-review--local-directory item) "/r/repo.feat-x")))
      (delete-directory tmp t))))

;;;; Review range and prompts

(ert-deftest gh-inbox-review-range ()
  (let ((it (gh-inbox-classify
             (gh-inbox-test--item :roles '(reviewed) :base "main" :head-oid "new" :my-review-oid "old"
                                  :my-review-state "CHANGES_REQUESTED")
             "me")))
    (should (equal (gh-inbox-review--range it) "old..HEAD")))
  (let ((it (gh-inbox-classify (gh-inbox-test--item :roles '(requested) :base "main"
                                                    :head-oid "new" :my-review-oid "old") "me")))
    (should (equal (gh-inbox-review--range it) "origin/main...HEAD"))))

(ert-deftest gh-inbox-review-prompts ()
  (let* ((gh-inbox-review-notes-directory "/tmp/notes/")
         (it (gh-inbox-test--item :roles '(requested) :base "main" :head "feat" :title "Do thing"))
         (p (gh-inbox-review--prompt-review it "/wt/path/")))
    (should (string-match-p "READ-ONLY" p))
    (should (string-match-p "do not post anything to GitHub" p))
    (should (string-match-p "/tmp/notes/o-r-1\\.org" p))
    (should (string-match-p "git diff origin/main\\.\\.\\.HEAD" p))
    (should (string-match-p "\\[\\[file:/wt/path/path::line\\]\\]" p)))
  (let ((p (gh-inbox-review--prompt-address
            (gh-inbox-test--item :head "feat") "a.cs:3: @bob: fix\n")))
    (should (string-match-p "a\\.cs:3: @bob: fix" p))
    (should (string-match-p "Do not commit or push" p))))

(ert-deftest gh-inbox-review-ensure-details ()
  (let ((it (gh-inbox-test--item :number 5)) done)
    ;; Known branches: no network.
    (gh-inbox-review--ensure-details (gh-inbox-test--item :head "a" :base "b") (lambda () (setq done t)))
    (should done)
    ;; Notification-only PR: fetched through `gh pr view'.
    (setq done nil)
    (cl-letf (((symbol-function 'gh-inbox--gh)
               (lambda (args cb)
                 (should (member "5" args))
                 (should (member "o/r" args))
                 (funcall cb t "{\"headRefName\":\"feat\",\"baseRefName\":\"main\",\"headRefOid\":\"abc\",\"author\":{\"login\":\"zed\"}}" ""))))
      (gh-inbox-review--ensure-details it (lambda () (setq done t))))
    (should done)
    (should (equal (gh-inbox-item-head it) "feat"))
    (should (equal (gh-inbox-item-base it) "main"))
    (should (equal (gh-inbox-item-head-oid it) "abc"))
    ;; Existing author is kept.
    (should (equal (gh-inbox-item-author it) "someone"))))

(ert-deftest gh-inbox-review-show-diff-runs-in-worktree ()
  "magit must diff the PR's worktree, not whatever directory is current."
  (require 'magit-diff)                 ; so the stub is not replaced by the real load
  (let ((item (gh-inbox-test--item :base "main" :head "feat")) seen)
    (cl-letf (((symbol-function 'magit-diff-range)
               (lambda (range &rest _) (push (cons range default-directory) seen))))
      (let ((default-directory "/somewhere/else/"))
        (gh-inbox-review--show-diff item nil "/wt/pr")
        (gh-inbox-review--show-diff item t "/wt/pr/")))
    (should (equal (mapcar #'cdr seen) '("/wt/pr/" "/wt/pr/")))
    (should (equal (car (car seen)) "origin/main...HEAD"))))

(ert-deftest gh-inbox-review-browse-here ()
  "Opens the PR URL through `browse-url' (never `gh --web'); failures say why."
  (let (opened msg)
    (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u)))
              ((symbol-function 'gh-inbox--gh)
               (lambda (args cb)
                 (should (member "--json" args))
                 (should-not (member "--web" args))
                 (funcall cb t "{\"number\":5,\"url\":\"https://github.com/o/r/pull/5\",\"title\":\"t\",\"headRefName\":\"f\",\"baseRefName\":\"main\",\"author\":{\"login\":\"me\"}}" ""))))
      (gh-inbox-review-browse-here))
    (should (equal opened "https://github.com/o/r/pull/5"))
    (setq opened nil)
    (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u)))
              ((symbol-function 'message) (lambda (f &rest a) (setq msg (apply #'format f a))))
              ((symbol-function 'gh-inbox--gh)
               (lambda (_args cb) (funcall cb nil "" "no pull requests found for branch \"x\""))))
      (gh-inbox-review-browse-here))
    (should-not opened)
    (should (string-match-p "no pull requests found" msg))))

(ert-deftest gh-inbox-review-skill-command ()
  (let ((gh-inbox-review-skills
         '(("clearcompany/clearcompany" (review . "/insync:clearco-pr-review")
            (address . "/insync:clearco-feedback-resolver")))))
    (let ((it (gh-inbox-test--item :repo "clearcompany/clearcompany" :number 6157)))
      (should (equal (gh-inbox-review--skill-command it 'review) "/insync:clearco-pr-review 6157"))
      (should (equal (gh-inbox-review--skill-command it 'address)
                     "/insync:clearco-feedback-resolver 6157"))
      ;; No skill for CI, nor for other repos or other case spellings of the repo.
      (should-not (gh-inbox-review--skill-command it 'ci)))
    (should (gh-inbox-review--skill-command
             (gh-inbox-test--item :repo "ClearCompany/ClearCompany" :number 1) 'review))
    (should-not (gh-inbox-review--skill-command
                 (gh-inbox-test--item :repo "clearcompany/web-clearcompany" :number 1) 'review))))

(ert-deftest gh-inbox-review-claude-uses-skill-or-prompt ()
  "`c' sends the slash command for configured repos, the built-in prompt elsewhere."
  (let (sent (gh-inbox--viewer "me")
        (gh-inbox-review-notes-directory (make-temp-file "notes" t)))
    (cl-letf (((symbol-function 'gh-inbox-review--prepare) (lambda (_i cb) (funcall cb "/wt/")))
              ((symbol-function 'gh-inbox-review--activity) (lambda (&rest _) nil))
              ((symbol-function 'gh-inbox-review--start-claude)
               (lambda (_path prompt) (push prompt sent))))
      (let ((cc (gh-inbox-classify (gh-inbox-test--item :repo "clearcompany/clearcompany" :number 7
                                                        :roles '(requested) :base "main" :head "f") "me"))
            (other (gh-inbox-classify (gh-inbox-test--item :repo "clearcompany/web-clearcompany" :number 8
                                                           :roles '(requested) :base "main" :head "f"
                                                           :title "Web") "me"))
            (mine (gh-inbox-classify (gh-inbox-test--item :repo "clearcompany/clearcompany" :number 9
                                                          :author "me" :roles '(authored) :threads 2
                                                          :head "f") "me"))
            (ci (gh-inbox-classify (gh-inbox-test--item :repo "clearcompany/clearcompany" :number 10
                                                        :author "me" :roles '(authored) :ci "FAILURE"
                                                        :head "f") "me")))
        (gh-inbox-review-claude cc)
        (should (equal (pop sent) "/insync:clearco-pr-review 7"))
        (gh-inbox-review-claude mine)
        (should (equal (pop sent) "/insync:clearco-feedback-resolver 9"))
        (gh-inbox-review-claude other)
        (should (string-match-p "first-pass code review" (pop sent)))
        (gh-inbox-review-claude ci)
        (should (string-match-p "CI is failing" (pop sent)))))
    (delete-directory gh-inbox-review-notes-directory t)))

(ert-deftest gh-inbox-review-notes-lookup ()
  (let* ((dir (make-temp-file "skillout" t))
         (gh-inbox-review-notes-directory (expand-file-name "own/" dir))
         (gh-inbox-review-skill-output-dir (expand-file-name "skill/" dir))
         (it (gh-inbox-test--item :number 123)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "skill/DEV-1/" dir) t)
          (should-error (gh-inbox-review-notes it) :type 'user-error)
          (with-temp-file (expand-file-name "skill/DEV-1/123-review.md" dir) (insert "draft"))
          (with-temp-file (expand-file-name "skill/DEV-1/1234-review.md" dir) (insert "other pr"))
          (gh-inbox-review-notes it)
          (should (equal (file-name-nondirectory (buffer-file-name)) "123-review.md"))
          (kill-buffer))
      (delete-directory dir t))))

(ert-deftest gh-inbox-review-claude-mode ()
  (let ((gh-inbox--viewer "me"))
    (cl-flet ((mode (item &rest _) (gh-inbox-review--claude-mode (gh-inbox-classify item "me") nil)))
      (should (eq (mode (gh-inbox-test--item :roles '(requested))) 'review))
      (should (eq (mode (gh-inbox-test--item :author "me" :roles '(authored) :threads 2)) 'address))
      (should (eq (mode (gh-inbox-test--item :author "me" :roles '(authored) :ci "FAILURE")) 'ci)))))

;;;; Threads buffer

(defconst gh-inbox-test--pr
  (gh-inbox--parse "{\"title\":\"My PR\",\"url\":\"https://github.com/o/r/pull/1\",
 \"reviewThreads\":{\"nodes\":[
  {\"isResolved\":false,\"isOutdated\":false,\"path\":\"src/a.txt\",\"line\":7,
   \"comments\":{\"nodes\":[{\"author\":{\"login\":\"bob\"},\"body\":\"Please rename\\nthis variable\"},
                           {\"author\":{\"login\":\"me\"},\"body\":\"why?\"}]}},
  {\"isResolved\":true,\"isOutdated\":false,\"path\":\"src/b.txt\",\"line\":3,
   \"comments\":{\"nodes\":[{\"author\":{\"login\":\"al\"},\"body\":\"done thing\"}]}},
  {\"isResolved\":false,\"isOutdated\":true,\"path\":\"src/c.txt\",\"line\":null,\"originalLine\":2,
   \"comments\":{\"nodes\":[{\"author\":{\"login\":\"cy\"},\"body\":\"old\"}]}}]}}"))

(ert-deftest gh-inbox-threads-text ()
  (let ((open (gh-inbox-review--threads-text gh-inbox-test--pr nil))
        (all (gh-inbox-review--threads-text gh-inbox-test--pr t)))
    (should (string-match-p "2 awaiting you · 0 you replied · 1 resolved" open))
    (should (string-match-p "^src/a\\.txt:7: @bob: Please rename$" open))
    ;; The heading carries the first line; the body must not repeat it.
    (should (= 1 (with-temp-buffer (insert open) (how-many "Please rename" (point-min)))))
    (should (string-match-p "^      this variable$" open))
    (should (string-match-p "^src/c\\.txt:2: \\[outdated\\] @cy" open))
    (should-not (string-match-p "b\\.txt" open))
    (should (string-match-p "^src/b\\.txt:3: \\[resolved\\]" all))))

(ert-deftest gh-inbox-threads-awaiting-me ()
  (let* ((gh-inbox--viewer "me")
         (pr (gh-inbox--parse "{\"title\":\"P\",\"url\":\"u\",\"reviewThreads\":{\"nodes\":[
  {\"isResolved\":false,\"path\":\"a\",\"line\":1,\"comments\":{\"nodes\":[{\"author\":{\"login\":\"bob\"},\"body\":\"x\"},{\"author\":{\"login\":\"me\"},\"body\":\"Done\"}]}},
  {\"isResolved\":false,\"path\":\"b\",\"line\":2,\"comments\":{\"nodes\":[{\"author\":{\"login\":\"bob\"},\"body\":\"y\"}]}}]}}"))
         (text (gh-inbox-review--threads-text pr nil)))
    (should (string-match-p "1 awaiting you · 1 you replied" text))
    ;; Awaiting thread is listed before the one you answered.
    (should (< (string-match "^b:2:" text) (string-match "^a:1: \\[you replied\\]" text)))
    ;; Claude is only asked about threads waiting on you.
    (let (got)
      (cl-letf (((symbol-function 'gh-inbox-review--fetch-threads)
                 (lambda (_item cb) (funcall cb pr))))
        (gh-inbox-review--threads-for-prompt (gh-inbox-test--item) (lambda (tx) (setq got tx))))
      (should (string-match-p "^b:2:" got))
      (should-not (string-match-p "^a:1:" got)))))

(ert-deftest gh-inbox-threads-next-error ()
  "next-error from the threads buffer lands on the right file and line."
  (let* ((dir (make-temp-file "wt" t))
         (default-directory (file-name-as-directory dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "src" dir))
          (with-temp-file (expand-file-name "src/a.txt" dir)
            (dotimes (i 20) (insert (format "line %d\n" (1+ i)))))
          (with-temp-file (expand-file-name "src/c.txt" dir)
            (dotimes (i 5) (insert (format "c %d\n" (1+ i)))))
          (with-current-buffer (get-buffer-create "*threads-test*")
            (gh-inbox-threads-mode)
            (setq default-directory (file-name-as-directory dir))
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (gh-inbox-review--threads-text gh-inbox-test--pr nil))
              (goto-char (point-min))
              (compilation--flush-parse (point-min) (point-max))
              (font-lock-ensure))
            (goto-char (point-min))
            (setq next-error-last-buffer (current-buffer))
            (switch-to-buffer (current-buffer))
            (next-error)
            (with-current-buffer (window-buffer (selected-window))
              (should (equal buffer-file-name (expand-file-name "src/a.txt" dir)))
              (should (= (line-number-at-pos) 7)))
            (switch-to-buffer "*threads-test*")
            (setq next-error-last-buffer (current-buffer))
            (next-error)
            (with-current-buffer (window-buffer (selected-window))
              (should (equal buffer-file-name (expand-file-name "src/c.txt" dir)))
              (should (= (line-number-at-pos) 2)))))
      (ignore-errors (kill-buffer "*threads-test*"))
      (delete-directory dir t))))

;;;; Bookmarks (activities restores buffers through these)

(ert-deftest gh-inbox-threads-bookmark-roundtrip ()
  (let ((item (gh-inbox-test--item :base "main" :head "feat" :number 42)) rec)
    (cl-letf (((symbol-function 'gh-inbox-review--fetch-threads) (lambda (&rest _) nil))
              ((symbol-function 'gh-inbox-review--local-directory) (lambda (_) nil)))
      (let ((buf (gh-inbox-review-threads item t t)))
        (with-current-buffer buf
          (should (eq bookmark-make-record-function #'gh-inbox-review--threads-bookmark-record))
          (setq rec (funcall bookmark-make-record-function)))
        (kill-buffer buf))
      (should (eq (alist-get 'handler (cdr rec)) 'gh-inbox-review-threads-bookmark-handler))
      (should (equal (alist-get 'number (cdr rec)) 42))
      ;; The record must survive printing and reading, as activities saves it to disk.
      (setq rec (car (read-from-string (prin1-to-string rec))))
      (funcall (alist-get 'handler (cdr rec)) rec)
      (should (string-match-p "pr-threads: r#42" (buffer-name)))
      (should (eq gh-inbox-review--threads-all t))
      (should (equal (gh-inbox-item-head gh-inbox-review--threads-item) "feat"))
      (kill-buffer))))

(ert-deftest gh-inbox-inbox-bookmark-roundtrip ()
  (gh-inbox-test-with-state
   (let ((gh-inbox-items nil) (gh-inbox--last-fetch (float-time)))
     (with-current-buffer (get-buffer-create "*gh-inbox*")
       (gh-inbox-mode)
       (setq gh-inbox--view 'mine)
       (let ((rec (funcall bookmark-make-record-function)))
         (kill-buffer)
         (funcall (alist-get 'handler (cdr rec)) rec)
         (should (equal (buffer-name) "*gh-inbox*"))
         (should (eq gh-inbox--view 'mine))
         (kill-buffer))))))

;;;; Worktree sync (real git, local remotes only)

(defun gh-inbox-test--git (dir &rest args)
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (let ((code (apply #'call-process "git" nil t nil
                         "-c" "user.name=t" "-c" "user.email=t@t" args)))
        (unless (eq code 0) (error "git %S failed: %s" args (buffer-string)))
        (string-trim (buffer-string))))))

(defun gh-inbox-test--wait (pred)
  (let ((t0 (float-time)))
    (while (and (not (funcall pred)) (< (- (float-time) t0) 20))
      (accept-process-output nil 0.05))
    (funcall pred)))

(ert-deftest gh-inbox-review-sync-worktree ()
  (skip-unless (executable-find "git"))
  (let* ((tmp (make-temp-file "gsync" t))
         (origin (expand-file-name "origin.git" tmp))
         (author (expand-file-name "author" tmp))
         (wt (expand-file-name "wt" tmp))
         (item (gh-inbox-test--item :base "main" :head "feat")))
    (unwind-protect
        (progn
          (gh-inbox-test--git tmp "init" "-q" "--bare" "-b" "main" origin)
          (gh-inbox-test--git tmp "clone" "-q" origin author)
          (with-temp-file (expand-file-name "f.txt" author) (insert "one\n"))
          (gh-inbox-test--git author "add" ".")
          (gh-inbox-test--git author "commit" "-qm" "one")
          (gh-inbox-test--git author "push" "-q" "origin" "main")
          (gh-inbox-test--git author "checkout" "-qb" "feat")
          (gh-inbox-test--git author "push" "-q" "origin" "feat")
          (gh-inbox-test--git tmp "clone" "-q" "-b" "feat" origin wt)
          ;; The author pushes a new commit to the PR branch.
          (with-temp-file (expand-file-name "f.txt" author) (insert "two\n"))
          (gh-inbox-test--git author "commit" "-qam" "two")
          (gh-inbox-test--git author "push" "-q" "origin" "feat")
          ;; Clean worktree: fetched and fast-forwarded.
          (let (done)
            (gh-inbox-review--sync-worktree wt item (lambda () (setq done t)))
            (should (gh-inbox-test--wait (lambda () done))))
          (should (equal (gh-inbox-test--git wt "log" "-1" "--format=%s") "two"))
          ;; Another push while the worktree has local edits: fetch only, never touch the tree.
          (with-temp-file (expand-file-name "f.txt" author) (insert "three\n"))
          (gh-inbox-test--git author "commit" "-qam" "three")
          (gh-inbox-test--git author "push" "-q" "origin" "feat")
          (with-temp-file (expand-file-name "wip.txt" wt) (insert "my notes\n"))
          (let (done)
            (gh-inbox-review--sync-worktree wt item (lambda () (setq done t)))
            (should (gh-inbox-test--wait (lambda () done))))
          (should (equal (gh-inbox-test--git wt "log" "-1" "--format=%s") "two"))
          (should (equal (gh-inbox-test--git wt "rev-parse" "origin/feat")
                         (gh-inbox-test--git author "rev-parse" "HEAD")))
          ;; Failure to fetch must still call back (the diff is still readable).
          (let (done (item (gh-inbox-test--item :base "nope" :head "nope")))
            (gh-inbox-review--sync-worktree wt item (lambda () (setq done t)))
            (should (gh-inbox-test--wait (lambda () done)))))
      (delete-directory tmp t))))

;;;; Notifications

(ert-deftest gh-inbox-notify-detects-new ()
  (gh-inbox-test-with-state
   (let* ((gh-inbox-notify--seen nil)
          (a (gh-inbox-classify (gh-inbox-test--item :url "ua" :number 1 :roles '(requested)) "me"))
          (b (gh-inbox-classify (gh-inbox-test--item :url "ub" :number 2 :roles '(requested)) "me")))
     ;; First poll primes silently.
     (should-not (gh-inbox-notify--new (list a)))
     ;; Same data: nothing.
     (should-not (gh-inbox-notify--new (list a)))
     ;; New item: announced once.
     (let ((new (gh-inbox-notify--new (list a b))))
       (should (equal (mapcar (lambda (p) (gh-inbox-item-number (car p))) new) '(2)))
       (should (eq (cdr (car new)) 'review)))
     (should-not (gh-inbox-notify--new (list a b)))
     ;; Dismissed items do not alert, and re-alert after leaving and returning.
     (should-not (gh-inbox-notify--new (list a)))
     (should (= (length (gh-inbox-notify--new (list a b))) 1))
     (gh-inbox--dismiss a)
     (should-not (gh-inbox-notify--new (list a b))))))

(ert-deftest gh-inbox-notify-count ()
  (gh-inbox-test-with-state
   (let ((gh-inbox-items (list (gh-inbox-classify (gh-inbox-test--item :roles '(requested)) "me")
                               (gh-inbox-classify (gh-inbox-test--item :url "q" :author "me"
                                                                       :roles '(authored)) "me"))))
     (should (= (gh-inbox-notify-count) 1))
     (should (equal (gh-inbox-notify-status-string) "GH 1"))
     (gh-inbox--dismiss (car gh-inbox-items))
     (should-not (gh-inbox-notify-status-string)))))

;;;; Taskwarrior (scratch database)

(defmacro gh-inbox-test-with-taskwarrior (&rest body)
  `(let* ((dir (make-temp-file "tw" t))
          (rc (expand-file-name "taskrc" dir))
          (process-environment (append (list (concat "TASKRC=" rc)
                                             (concat "TASKDATA=" dir))
                                       process-environment)))
     (with-temp-file rc
       (insert "data.location=" dir "\nuda.type.type=string\nuda.type.label=Type\n"
               "uda.type.values=inbox,next,waiting,someday,cal\nverbose=nothing\n"))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(defun gh-inbox-test--task-descs ()
  (mapcar (lambda (tk) (alist-get 'description tk))
          (gh-inbox--parse (cdr (gh-inbox-notify--task "status:pending" "export")))))

(ert-deftest gh-inbox-notify-task-sync ()
  (skip-unless (executable-find "task"))
  (gh-inbox-test-with-taskwarrior
   (let* ((gh-inbox--fetch-clean t)
          (a (gh-inbox-classify (gh-inbox-test--item :url "https://github.com/o/r/pull/1" :number 1
                                                     :title "fix: due:tomorrow project:x" :roles '(requested)) "me"))
          (b (gh-inbox-classify (gh-inbox-test--item :url "https://github.com/o/r/pull/2" :number 2
                                                     :title "second" :roles '(requested)) "me")))
     ;; Creates one task per request; text like due:/project: stays literal.
     (should (equal (gh-inbox-notify-sync-tasks (list a b)) '(2 . 0)))
     (should (equal (sort (gh-inbox-test--task-descs) #'string<)
                    '("[gh o/r#1] Review: fix: due:tomorrow project:x" "[gh o/r#2] Review: second")))
     (let ((tk (car (gh-inbox--parse (cdr (gh-inbox-notify--task "+ghreview" "export"))))))
       (should (equal (alist-get 'project tk) "Work.ClearCo"))
       (should (equal (alist-get 'type tk) "next"))
       (should-not (alist-get 'due tk)))
     ;; Idempotent.
     (should (equal (gh-inbox-notify-sync-tasks (list a b)) '(0 . 0)))
     ;; An error-ridden fetch never completes anything.
     (let ((gh-inbox--fetch-clean nil))
       (should (equal (gh-inbox-notify-sync-tasks nil) '(0 . 0))))
     (should (= (length (gh-inbox-test--task-descs)) 2))
     ;; Request gone after a clean fetch: its task completes, the other stays.
     (should (equal (gh-inbox-notify-sync-tasks (list b)) '(0 . 1)))
     (should (equal (gh-inbox-test--task-descs) '("[gh o/r#2] Review: second")))
     ;; Tasks not made by us are never touched.
     (gh-inbox-notify--task "add" "--" "unrelated")
     (gh-inbox-notify-sync-tasks nil)
     (should (member "unrelated" (gh-inbox-test--task-descs))))))

(ert-deftest gh-inbox-notify-manual-task ()
  (skip-unless (executable-find "task"))
  (gh-inbox-test-with-taskwarrior
   (let ((it (gh-inbox-classify (gh-inbox-test--item :roles '(notified)
                                                     :notif-reason "mention" :title "Look") "me")))
     (gh-inbox-notify-task it)
     (gh-inbox-notify-task it)           ; second call is a no-op
     (should (equal (gh-inbox-test--task-descs) '("[gh o/r#1] Follow up: Look")))
     ;; A sync after a clean fetch must not close a follow-up you made yourself.
     (let ((gh-inbox--fetch-clean t))
       (should (equal (gh-inbox-notify-sync-tasks nil) '(0 . 0))))
     (should (equal (gh-inbox-test--task-descs) '("[gh o/r#1] Follow up: Look"))))))

(provide 'gh-inbox-tests)
;;; gh-inbox-tests.el ends here
