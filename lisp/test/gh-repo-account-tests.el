;;; gh-repo-account-tests.el --- Tests for gh-repo-account  -*- lexical-binding: t; -*-

;; Run:  emacs --batch -L lisp/util -L lisp/test -l gh-repo-account-tests \
;;         -f ert-run-tests-batch-and-exit
;; Uses throwaway repos and a fake `gh'; no real token or account is touched.

(require 'ert)
(require 'gh-repo-account)

(defun gh-repo-test--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (list (apply #'call-process "git" nil t nil args) (string-trim-right (buffer-string))))))

(defmacro gh-repo-test-with-repo (gh-script &rest body)
  "Run BODY with DIR a fresh git repo and a fake `gh' (running GH-SCRIPT) first on PATH.
The user's global git config is hidden, so only the repo's own settings count."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "ghrepo" t))
          (bin (make-temp-file "fakegh" t))
          (gh (expand-file-name "gh" bin))
          (process-environment (append (list (concat "PATH=" bin ":" (getenv "PATH"))
                                             "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"
                                             "GIT_TERMINAL_PROMPT=0")
                                       process-environment)))
     (with-temp-file gh (insert "#!/bin/sh\n" ,gh-script "\n"))
     (set-file-modes gh #o755)
     (unwind-protect
         (progn (gh-repo-test--git dir "init" "-q") ,@body)
       (delete-directory dir t) (delete-directory bin t))))

(defun gh-repo-test--fill (dir)
  "What git's credential machinery returns for github.com in DIR: alist of key=value."
  (with-temp-buffer
    (insert "protocol=https\nhost=github.com\n\n")
    (let ((default-directory (file-name-as-directory dir)))
      (call-process-region (point-min) (point-max) "git" t t nil "credential" "fill"))
    (let (out)
      (dolist (l (split-string (buffer-string) "\n" t))
        (when (string-match "\\`\\([a-z]+\\)=\\(.*\\)\\'" l)
          (push (cons (match-string 1 l) (match-string 2 l)) out)))
      out)))

(ert-deftest gh-repo-helper-rejects-unsafe-usernames ()
  ;; The name is put into a shell snippet, so anything odd must be refused.
  (dolist (bad '("" "a b" "x;rm -rf ~" "a$(id)" "-lead" "a`b`" "a'b" "x\ny" "a/b"))
    (should-error (my/gh-credential-helper bad) :type 'user-error))
  (should (stringp (my/gh-credential-helper "rashid301")))
  (should (stringp (my/gh-credential-helper "rashid-cc"))))

(ert-deftest gh-repo-helper-only-answers-get-and-asks-gh-for-that-user ()
  (let ((h (my/gh-credential-helper "rashid301")))
    (should (string-prefix-p "!" h))
    (should (string-match-p "gh auth token --user rashid301" h))
    (should (string-match-p "\\[ \"\\$1\" = get \\] || exit 0" h))))

(ert-deftest gh-repo-pushes-use-the-pinned-account-whatever-is-active ()
  ;; Fake gh knows a token per account; the repo is pinned to rashid301.
  (gh-repo-test-with-repo
      "[ \"$1 $2\" = \"auth token\" ] || exit 1
case \"$4\" in rashid301) echo tok-301;; rashid-cc) echo tok-cc;; *) exit 1;; esac"
    (my/fix-gh-repo dir "rashid301")
    (let ((fill (gh-repo-test--fill dir)))
      (should (equal (cdr (assoc "username" fill)) "rashid301"))
      (should (equal (cdr (assoc "password" fill)) "tok-301")))
    ;; Pinning the other account gives the other token.
    (my/fix-gh-repo dir "rashid-cc")
    (should (equal (cdr (assoc "password" (gh-repo-test--fill dir))) "tok-cc"))))

(ert-deftest gh-repo-no-token-for-the-account-means-no-credentials-not-a-wrong-one ()
  ;; gh has no token for "ghost": git must end up without a password (it would then
  ;; ask), and above all must not push as some other account.
  (gh-repo-test-with-repo "exit 1"
    (my/fix-gh-repo dir "ghost")
    (let ((fill (gh-repo-test--fill dir)))
      (should-not (assoc "password" fill)))))

(ert-deftest gh-repo-replaces-the-inherited-helpers-and-is-repeatable ()
  (gh-repo-test-with-repo "echo tok"
    (my/fix-gh-repo dir "rashid301")
    (my/fix-gh-repo dir "rashid301")
    (my/fix-gh-repo dir "rashid301")
    (let* ((vals (split-string (cadr (gh-repo-test--git dir "config" "--local" "--get-all" my/gh-credential-key))
                               "\n"))
           (user (cadr (gh-repo-test--git dir "config" "--local" "--get" my/gh-username-key))))
      ;; Exactly: reset marker, then our helper; never duplicated by re-running.
      (should (= 2 (length vals)))
      (should (equal (car vals) ""))
      (should (string-match-p "gh auth token --user rashid301" (cadr vals)))
      (should (equal user "rashid301")))))

(ert-deftest gh-repo-switching-the-pinned-account-leaves-only-the-new-one ()
  (gh-repo-test-with-repo "echo tok"
    (my/fix-gh-repo dir "rashid301")
    (my/fix-gh-repo dir "rashid-cc")
    (let ((all (cadr (gh-repo-test--git dir "config" "--local" "--get-all" my/gh-credential-key))))
      (should (string-match-p "rashid-cc" all))
      (should-not (string-match-p "rashid301" all)))))

(ert-deftest gh-repo-refuses-a-directory-that-is-not-a-repo-root ()
  (let ((d (make-temp-file "notrepo" t)))
    (unwind-protect (should-error (my/fix-gh-repo d "rashid301") :type 'user-error)
      (delete-directory d t))))

(ert-deftest gh-repo-bad-username-changes-nothing ()
  (gh-repo-test-with-repo "echo tok"
    (should-error (my/fix-gh-repo dir "x;y") :type 'user-error)
    (should-not (zerop (car (gh-repo-test--git dir "config" "--local" "--get" my/gh-username-key))))
    (should-not (zerop (car (gh-repo-test--git dir "config" "--local" "--get-all" my/gh-credential-key))))))

(provide 'gh-repo-account-tests)
;;; gh-repo-account-tests.el ends here
