;;; ref-open-tests.el --- Tests for ref-open  -*- lexical-binding: t; -*-

;; emacs --batch -L lisp/util -L lisp/test -l ref-open-tests -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'ref-open)
(require 'gh-inbox-review)

(defun ref-open-test--kinds (s)
  (mapcar (lambda (r) (cons (ref-open-ref-kind r) (ref-open-ref-text r))) (ref-open-parse s)))

(ert-deftest ref-open-parse-jira ()
  (should (equal (ref-open-test--kinds "see DEV-33555 and ISO-8601, UTF-8, SHA-256")
                 '((jira . "DEV-33555"))))
  ;; Branch names and commit subjects.
  (should (equal (ref-open-test--kinds "feature/DEV-33555-limit-resend") '((jira . "DEV-33555"))))
  (should (equal (ref-open-test--kinds "[feature] DEV-33555: Limit") '((jira . "DEV-33555"))))
  (should-not (ref-open-test--kinds "XDEV-1 DEVS-2 dev-3"))
  (let ((ref-open-jira-projects '("DEV" "OPS")))
    (should (= 2 (length (ref-open-parse "DEV-1 and OPS-22"))))))

(ert-deftest ref-open-parse-urls ()
  ;; Key inside a Jira URL is the URL's, not a second reference.
  (should (equal (ref-open-test--kinds "(https://clearco.atlassian.net/browse/DEV-12?focusedId=1).")
                 '((jira-url . "https://clearco.atlassian.net/browse/DEV-12?focusedId=1"))))
  (should (equal (ref-open-test--kinds "https://github.com/clearcompany/clearcompany/pull/6157/files#diff-x]")
                 '((github-pr . "https://github.com/clearcompany/clearcompany/pull/6157/files#diff-x"))))
  (should (equal (ref-open-test--kinds "https://clearco.atlassian.net/wiki/spaces/ENG/pages/1/T and https://docs.google.com/document/d/abc/edit.")
                 '((confluence . "https://clearco.atlassian.net/wiki/spaces/ENG/pages/1/T")
                   (gdoc . "https://docs.google.com/document/d/abc/edit"))))
  (should (equal (ref-open-test--kinds "https://github.com/o/r/issues/9")
                 '((github-issue . "https://github.com/o/r/issues/9")))))

(ert-deftest ref-open-parse-pr-shorthand ()
  ;; The form Taskwarrior review tasks carry.
  (let ((r (car (ref-open-parse "[gh clearcompany/web-clearcompany#1059] Review: x"))))
    (should (eq (ref-open-ref-kind r) 'github-pr))
    (should (equal (alist-get 'repo (ref-open-ref-data r)) "clearcompany/web-clearcompany"))
    (should (equal (alist-get 'number (ref-open-ref-data r)) 1059)))
  ;; Unknown owners and path-like text are not PRs.
  (should-not (ref-open-parse "foo/bar#2 docs/readme#3")))

(ert-deftest ref-open-parse-positions ()
  (let* ((s "go DEV-1, then clearcompany/x#2.")
         (refs (ref-open-parse s)))
    (should (equal (mapcar (lambda (r) (substring s (ref-open-ref-beg r) (ref-open-ref-end r))) refs)
                   '("DEV-1" "clearcompany/x#2")))))

(defmacro ref-open-test-with-stubs (&rest body)
  `(let (opened prs (gh-inbox-jira-base-url "https://x.atlassian.net/browse/"))
     (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (push u opened)))
               ((symbol-function 'gh-inbox-review-pr-review)
                (lambda (item) (push (list 'pr-review (gh-inbox-item-repo item) (gh-inbox-item-number item)) prs)))
               ((symbol-function 'gh-inbox-review-open)
                (lambda (item) (push (list 'activity (gh-inbox-item-number item)) prs))))
       ,@body)))

(ert-deftest ref-open-at-point-and-line ()
  (ref-open-test-with-stubs
   (with-temp-buffer
     (insert "fix for DEV-100 (see https://docs.google.com/document/d/abc) done")
     ;; At point.
     (goto-char (+ (point-min) (string-match "DEV-100" (buffer-string)) 2))
     (ref-open)
     (should (equal opened '("https://x.atlassian.net/browse/DEV-100")))
     (setq opened nil)
     (goto-char (+ (point-min) (string-match "docs.google" (buffer-string)) 3))
     (ref-open)
     (should (equal opened '("https://docs.google.com/document/d/abc"))))
   ;; Not on a reference but exactly one on the line: that one.
   (with-temp-buffer
     (insert "nothing here, just DEV-7")
     (goto-char (point-min))
     (setq opened nil)
     (ref-open)
     (should (equal opened '("https://x.atlassian.net/browse/DEV-7"))))))

(ert-deftest ref-open-picks-among-several ()
  (ref-open-test-with-stubs
   (with-temp-buffer
     (insert "DEV-1 and DEV-2")
     (goto-char (point-min)) (end-of-line) ; point is on neither
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_p coll &rest _) (should (= 2 (length coll))) (car (last coll)))))
       (ref-open))
     (should (equal opened '("https://x.atlassian.net/browse/DEV-2"))))))

(ert-deftest ref-open-clipboard-and-prompt ()
  "With nothing anywhere: a plain prompt; typing nonsense is an error."
  (ref-open-test-with-stubs
   (with-temp-buffer
     (insert "no references on this line")
     (goto-char (point-min))
     (let ((kill-ring nil))
       (cl-letf (((symbol-function 'ref-open--visible-refs) (lambda () nil))
                 ((symbol-function 'read-string) (lambda (&rest _) "typed DEV-55 here")))
         (ref-open))
       (should (equal opened '("https://x.atlassian.net/browse/DEV-55")))
       (cl-letf (((symbol-function 'ref-open--visible-refs) (lambda () nil))
                 ((symbol-function 'read-string) (lambda (&rest _) "nothing")))
         (should-error (ref-open) :type 'user-error))))))

(ert-deftest ref-open-visible-in-other-windows ()
  "Point on nothing: offer what the frame's windows show, clipboard included."
  (ref-open-test-with-stubs
   (let ((a (generate-new-buffer "ro-a")) (b (generate-new-buffer "ro-b")))
     (unwind-protect
         (progn
           (with-current-buffer a (insert "empty pane\n"))
           (with-current-buffer b (insert "task: [gh clearcompany/web-clearcompany#1059] and DEV-77 and DEV-77\n"))
           (delete-other-windows)
           (switch-to-buffer a)
           (set-window-buffer (split-window) b)
           (let ((refs (ref-open--visible-refs)))
             ;; Duplicates collapse; each says where it was seen.
             (should (equal (mapcar (lambda (c) (ref-open-ref-text (car c))) refs)
                            '("clearcompany/web-clearcompany#1059" "DEV-77")))
             (should (equal (cdr (car refs)) "ro-b")))
           (with-current-buffer a (goto-char (point-min)))
           (let ((kill-ring (list "DEV-1")) offered)
             ;; Picking a visible one opens it; the clipboard is listed too.
             (cl-letf (((symbol-function 'completing-read)
                        (lambda (_p coll &rest _)
                          (setq offered coll)
                          (seq-find (lambda (c) (string-match-p "DEV-77" c)) coll))))
               (with-current-buffer a (ref-open)))
             (should (= 3 (length offered)))
             (should (seq-find (lambda (c) (string-match-p "clipboard" c)) offered))
             (should (equal opened '("https://x.atlassian.net/browse/DEV-77")))
             ;; Typing something that is not in the list is parsed instead.
             (setq opened nil)
             (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "see DEV-88")))
               (with-current-buffer a (ref-open)))
             (should (equal opened '("https://x.atlassian.net/browse/DEV-88")))))
       (delete-other-windows)
       (kill-buffer a) (kill-buffer b)))))

(ert-deftest ref-open-pr-actions ()
  (ref-open-test-with-stubs
   (with-temp-buffer
     (insert "[gh clearcompany/clearcompany#6157] Review: x")
     (goto-char (+ (point-min) 10))
     ;; Default: pr-review.  Item carries repo and number (the rest is fetched later).
     (ref-open)
     (should (equal prs '((pr-review "clearcompany/clearcompany" 6157))))
     ;; C-u: choose; "review activity" opens the worktree flow.
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_p coll &rest _)
                  (should (seq-find (lambda (c) (string-match-p "review activity" c)) coll))
                  (seq-find (lambda (c) (string-match-p "review activity" c)) coll))))
       (ref-open t))
     (should (equal (car prs) '(activity 6157)))
     ;; browser is always available.
     (cl-letf (((symbol-function 'completing-read) (lambda (_p coll &rest _) (car (last coll)))))
       (ref-open t))
     (should (equal opened '("https://github.com/clearcompany/clearcompany/pull/6157"))))))

(ert-deftest ref-open-jira-needs-base-url ()
  (let ((gh-inbox-jira-base-url nil))
    (with-temp-buffer
      (insert "DEV-1")
      (goto-char (point-min))
      (should-error (ref-open) :type 'user-error))))

(ert-deftest ref-open-embark-target ()
  (with-temp-buffer
    (insert "see DEV-9 now")
    (goto-char (+ (point-min) 6))
    (let ((tgt (ref-open-embark-target)))
      (should (eq (car tgt) 'ref-open))
      (should (equal (cadr tgt) "DEV-9"))
      (should (equal (cddr tgt) '(5 . 10))))
    (goto-char (point-min))
    (should-not (ref-open-embark-target))))

(ert-deftest ref-open-buttons ()
  (with-temp-buffer
    (insert "ticket DEV-3 and clearcompany/x#4\nsecond line DEV-5\n")
    (ref-open-buttons-mode 1)
    (let ((ovs (seq-filter (lambda (o) (overlay-get o 'ref-open)) (overlays-in (point-min) (point-max)))))
      (should (= 3 (length ovs)))
      (should (equal (sort (mapcar (lambda (o) (buffer-substring (overlay-start o) (overlay-end o))) ovs)
                           #'string<)
                     '("DEV-3" "DEV-5" "clearcompany/x#4")))
      ;; Clicks only: no key such as RET is taken from the buffer.
      (should (eq (lookup-key (overlay-get (car ovs) 'keymap) [mouse-1]) #'ref-open-click))
      (should-not (lookup-key (overlay-get (car ovs) 'keymap) (kbd "RET"))))
    ;; Editing re-marks the line; no stale or duplicate overlays.
    (goto-char (point-min))
    (search-forward "DEV-3")
    (replace-match "DEV-30")
    (ref-open--fontify (point-min) (point-max))
    (should (= 3 (length (seq-filter (lambda (o) (overlay-get o 'ref-open))
                                     (overlays-in (point-min) (point-max))))))
    (ref-open-buttons-mode -1)
    (should-not (seq-filter (lambda (o) (overlay-get o 'ref-open))
                            (overlays-in (point-min) (point-max))))))

(provide 'ref-open-tests)
;;; ref-open-tests.el ends here
