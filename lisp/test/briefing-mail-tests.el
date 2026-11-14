;;; briefing-mail-tests.el --- Tests for the mail section  -*- lexical-binding: t; -*-

;; Run:  emacs --batch -L lisp/util -L lisp/test -l briefing-mail-tests \
;;         -f ert-run-tests-batch-and-exit
;; No real mailbox, network account or password is used: the IMAP worker talks
;; to `fake-imap.py' on localhost, and `pass' is replaced by a stub script.

(require 'ert)
(require 'briefing)
(require 'briefing-mail)

(defvar gnus-select-method)
(defvar gnus-secondary-select-methods)

(defconst briefing-mail-test--dir (file-name-directory (or load-file-name buffer-file-name)))
(defconst briefing-mail-test--worker (expand-file-name "../util/briefing-imap.py" briefing-mail-test--dir))

;;;; Helpers

(defmacro briefing-mail-test-with-server (vars &rest body)
  "Run BODY with a fake IMAP server; VARS is (PORT LOG) symbols to bind.
Extra server arguments can be set in `briefing-mail-test-server-args'."
  (declare (indent 1))
  `(let* ((log (make-temp-file "fake-imap-log"))
          (buf (generate-new-buffer " *fake-imap*"))
          (proc (make-process
                 :name "fake-imap" :buffer buf :noquery t :connection-type 'pipe
                 :command (append (list "python3" "-I"
                                        (expand-file-name "fake-imap.py" briefing-mail-test--dir) log)
                                  briefing-mail-test-server-args)))
          (port nil))
     (unwind-protect
         (progn
           (let ((deadline (+ (float-time) 5)))
             (while (and (not port) (< (float-time) deadline))
               (accept-process-output proc 0.05)
               (with-current-buffer buf
                 (when (string-match "PORT \\([0-9]+\\)" (buffer-string))
                   (setq port (string-to-number (match-string 1 (buffer-string))))))))
           (should port)
           (let ((,(car vars) port) (,(cadr vars) log)) ,@body))
       (delete-process proc) (kill-buffer buf) (ignore-errors (delete-file log)))))

(defvar briefing-mail-test-server-args nil)

(defun briefing-mail-test--run-worker (cfg-plist)
  "Run the worker with CFG-PLIST as its JSON stdin; return (EXIT . OUTPUT)."
  (with-temp-buffer
    (insert (json-serialize cfg-plist))
    (let ((code (call-process-region (point-min) (point-max) "python3" t t nil
                                     "-I" briefing-mail-test--worker)))
      (cons code (string-trim (buffer-string))))))

(defun briefing-mail-test--data (output)
  (should (string-match "^BRIEFING-JSON:\\(.*\\)$" output))
  (json-parse-string (match-string 1 output) :object-type 'alist :array-type 'list))

(defun briefing-mail-test--log-lines (log)
  (with-temp-buffer (insert-file-contents log) (split-string (buffer-string) "\n" t)))

;;;; The IMAP worker against the fake server

(ert-deftest briefing-mail-worker-lists-newest-unread ()
  (briefing-mail-test-with-server (port log)
    (let* ((res (briefing-mail-test--run-worker
                 `(:host "127.0.0.1" :port ,port :user "me" :password "secret" :limit 3 :ssl :false)))
           (data (briefing-mail-test--data (cdr res)))
           (msgs (alist-get 'messages data)))
      (should (= 0 (car res)))
      (should (= 3 (alist-get 'unseen data)))
      ;; Newest first by Date header, whatever the uid order.
      (should (equal (mapcar (lambda (m) (alist-get 'subject m)) msgs)
                     '("Lunch?" "Ändere Frage" "Re: budget")))
      ;; Display names win over addresses; quoted names are unquoted; bare addresses stay.
      (should (equal (mapcar (lambda (m) (alist-get 'from m)) msgs)
                     '("bob@example.com" "Ann Lee" "Carol, Q.")))
      (should (equal (alist-get 'msgid (car msgs)) "<m2@example.com>")))))

(ert-deftest briefing-mail-worker-respects-the-limit-and-reports-the-total ()
  (briefing-mail-test-with-server (port log)
    (let ((data (briefing-mail-test--data
                 (cdr (briefing-mail-test--run-worker
                       `(:host "127.0.0.1" :port ,port :user "me" :password "secret" :limit 1 :ssl :false))))))
      (should (= 1 (length (alist-get 'messages data))))
      (should (= 3 (alist-get 'unseen data))))
    ;; limit 0 means "count only", not "use the default".
    (let ((data (briefing-mail-test--data
                 (cdr (briefing-mail-test--run-worker
                       `(:host "127.0.0.1" :port ,port :user "me" :password "secret" :limit 0 :ssl :false))))))
      (should (null (alist-get 'messages data)))
      (should (= 3 (alist-get 'unseen data))))))

(ert-deftest briefing-mail-worker-never-writes-to-the-mailbox ()
  (briefing-mail-test-with-server (port log)
    (briefing-mail-test--run-worker
     `(:host "127.0.0.1" :port ,port :user "me" :password "secret" :limit 3 :ssl :false))
    (let* ((lines (briefing-mail-test--log-lines log))
           (text (string-join lines "\n")))
      ;; Opened read-only (EXAMINE, not SELECT) and fetched with PEEK.
      (should (cl-some (lambda (l) (string-prefix-p "EXAMINE" l)) lines))
      (should-not (string-match-p "\\bSELECT\\b" text))
      (should (string-match-p "BODY\\.PEEK\\[HEADER" text))
      (should-not (string-match-p "BODY\\[" text))
      ;; Nothing that changes mail.
      (dolist (verb '("STORE" "COPY" "EXPUNGE" "APPEND" "DELETE" "MOVE"))
        (should-not (string-match-p (concat "\\b" verb "\\b") text)))
      ;; And the password was not logged by the fake either way.
      (should-not (string-match-p "secret" text)))))

(ert-deftest briefing-mail-worker-wrong-password-is-a-clear-error ()
  (briefing-mail-test-with-server (port log)
    (let ((res (briefing-mail-test--run-worker
                `(:host "127.0.0.1" :port ,port :user "me" :password "nope" :limit 3 :ssl :false))))
      (should (= 2 (car res)))
      (should (string-match-p "^BRIEFING-ERROR:.*AUTHENTICATIONFAILED" (cdr res)))
      (should-not (string-match-p "nope" (cdr res))))))

(ert-deftest briefing-mail-worker-unreachable-server-is-an-error-not-a-hang ()
  ;; A port that was open a moment ago and is now closed: refused at once.  (Port 1
  ;; is no good here: some systems drop it silently and the worker then waits out
  ;; its 30 s timeout, which is right but slow.)
  (let* ((srv (make-network-process :name "closed-port" :server t :service t :host "127.0.0.1"
                                    :noquery t))
         (port (process-contact srv :service)))
    (delete-process srv)
    (let ((res (briefing-mail-test--run-worker
                `(:host "127.0.0.1" :port ,port :user "me" :password "x" :limit 3 :ssl :false))))
      (should (= 2 (car res)))
      (should (string-match-p "^BRIEFING-ERROR:.*\\(Refused\\|refused\\)" (cdr res))))))

(ert-deftest briefing-mail-worker-needs-some-password-source ()
  (let ((res (briefing-mail-test--run-worker '(:host "127.0.0.1" :port 1 :user "me" :limit 3 :ssl :false))))
    (should (= 2 (car res)))
    (should (string-match-p "no password configured" (cdr res)))))

;;;; Gmail search and the password from `pass'

(defun briefing-mail-test--python (code)
  "Run Python CODE with the worker importable as `w'; return stdout."
  (with-temp-buffer
    (progn
     ;; -B: do not leave a __pycache__ next to the worker (-I would ignore the env var).
     (call-process "python3" nil t nil "-I" "-B" "-c"
                  (concat "import importlib.util as u\n"
                          "s=u.spec_from_file_location('w', " (prin1-to-string briefing-mail-test--worker) ")\n"
                          "w=u.module_from_spec(s); s.loader.exec_module(w)\n"
                          code)))
    (string-trim (buffer-string))))

(ert-deftest briefing-mail-gmail-searches-the-primary-tab ()
  (should (equal (briefing-mail-test--python "
class C:
    calls=[]
    def uid(self,*a): C.calls.append(a); return ('OK',[b'7 8'])
c=C(); print(w.search_unread(c,'imap.gmail.com'), 'X-GM-RAW' in C.calls[0], 'category:primary' in C.calls[0][-1])")
                 "[b'7', b'8'] True True")))

(ert-deftest briefing-mail-gmail-falls-back-to-unseen ()
  (should (equal (briefing-mail-test--python "
class C:
    calls=[]
    def uid(self,*a):
        C.calls.append(a)
        return ('BAD',[b'no']) if 'X-GM-RAW' in a else ('OK',[b'1 2 3'])
c=C(); print(len(w.search_unread(c,'imap.gmail.com')), C.calls[-1][-1])")
                 "3 UNSEEN")))

(ert-deftest briefing-mail-other-servers-use-plain-unseen ()
  (should (equal (briefing-mail-test--python "
class C:
    calls=[]
    def uid(self,*a): C.calls.append(a); return ('OK',[b'4'])
c=C(); w.search_unread(c,'imappro.zoho.com'); print(len(C.calls), C.calls[0][-1])")
                 "1 UNSEEN")))

(defun briefing-mail-test--fake-pass-dir (script-body)
  "A directory containing an executable `pass' that runs SCRIPT-BODY."
  (let* ((dir (make-temp-file "fakepass" t)) (f (expand-file-name "pass" dir)))
    (with-temp-file f (insert "#!/bin/sh\n" script-body "\n"))
    (set-file-modes f #o755)
    dir))

(ert-deftest briefing-mail-password-comes-from-pass-first-line-only ()
  (let ((dir (briefing-mail-test--fake-pass-dir
              "[ \"$1 $2\" = \"show email/x\" ] && printf 'the-secret\\nuser: ignored\\n' || exit 1")))
    (unwind-protect
        (let ((process-environment (cons (concat "PATH=" dir ":" (getenv "PATH")) process-environment)))
          (should (equal (briefing-mail-test--python
                          "print(w.password_from({'pass_entry':'email/x'}))")
                         "the-secret"))
          (should (string-match-p "could not read email/missing from pass"
                                  (briefing-mail-test--python
                                   "
try: w.password_from({'pass_entry':'email/missing'})
except Exception as e: print(e)"))))
      (delete-directory dir t))))

(ert-deftest briefing-mail-worker-logs-in-with-the-pass-password ()
  (let ((dir (briefing-mail-test--fake-pass-dir "printf 'secret\\n'")))
    (unwind-protect
        (briefing-mail-test-with-server (port log)
          (let* ((process-environment (cons (concat "PATH=" dir ":" (getenv "PATH")) process-environment))
                 (res (briefing-mail-test--run-worker
                       `(:host "127.0.0.1" :port ,port :user "me" :pass_entry "email/x" :limit 1 :ssl :false))))
            (should (= 0 (car res)))
            (should (= 3 (alist-get 'unseen (briefing-mail-test--data (cdr res)))))))
      (delete-directory dir t))))

(ert-deftest briefing-mail-missing-pass-is-reported-without-connecting ()
  (let ((process-environment (cons "PATH=/nonexistent" process-environment)))
    (should (string-match-p "pass. is not installed"
                            (with-temp-buffer
                              (insert (json-serialize '(:host "127.0.0.1" :port 1 :user "me" :pass_entry "email/x")))
                              (call-process-region (point-min) (point-max) "/usr/bin/python3" t t nil
                                                   "-I" briefing-mail-test--worker)
                              (buffer-string))))))

;;;; Accounts and requests

(ert-deftest briefing-mail-accounts-come-from-gnus ()
  (let ((gnus-select-method '(nnimap "gmail" (nnimap-address "imap.gmail.com") (nnimap-server-port 993)
                                     (nnimap-user "a@gmail.com") (nnimap-stream ssl)))
        (gnus-secondary-select-methods
         '((nnimap "zoho" (nnimap-address "imappro.zoho.com") (nnimap-user "z@x.tech"))
           (nntp "news" (nntp-address "n.example"))                  ; not IMAP: ignored
           (nnimap "broken" (nnimap-address "h.example")))))         ; no user: ignored
    (let ((accts (briefing-mail--gnus-accounts)))
      (should (equal (mapcar (lambda (a) (plist-get a :name)) accts) '("Gmail" "Zoho")))
      (should (equal (plist-get (nth 1 accts) :host) "imappro.zoho.com"))
      (should (= 993 (plist-get (nth 1 accts) :port)))
      (should (equal (plist-get (nth 0 accts) :user) "a@gmail.com")))))

(ert-deftest briefing-mail-request-prefers-pass-and-never-embeds-it ()
  (let* ((briefing-mail-pass-entries '(("u@x" . "email/u")))
         (req (json-parse-string (briefing-mail--request '(:name "N" :host "h" :user "u@x")))))
    (should (equal (gethash "pass_entry" req) "email/u"))
    (should-not (gethash "password" req))
    (should (eq (gethash "ssl" req) t))))

(ert-deftest briefing-mail-request-falls-back-to-authinfo-then-nothing ()
  (let ((briefing-mail-pass-entries nil))
    (cl-letf (((symbol-function 'auth-source-pick-first-password) (lambda (&rest _) "from-authinfo")))
      (should (equal (gethash "password" (json-parse-string (briefing-mail--request '(:name "N" :host "h" :user "u"))))
                     "from-authinfo")))
    (cl-letf (((symbol-function 'auth-source-pick-first-password) (lambda (&rest _) nil)))
      (should-not (briefing-mail--request '(:name "N" :host "h" :user "u"))))))

(ert-deftest briefing-mail-account-without-a-password-says-how-to-fix-it ()
  (let ((briefing-mail-pass-entries nil) result)
    (cl-letf (((symbol-function 'auth-source-pick-first-password) (lambda (&rest _) nil)))
      (briefing-mail--fetch-account '(:name "Gmail" :host "h" :user "u@x") (lambda (r) (setq result r))))
    (should (eq (car-safe result) 'error))
    (should (string-match-p "Gmail: no password for u@x.*pass-entries" (cdr result)))))

;;;; Items

(ert-deftest briefing-mail-items-and-links ()
  (let* ((acct '(:name "Gmail" :host "imap.gmail.com" :user "me@gmail.com"))
         (now (float-time))
         (items (briefing-mail--items
                 acct `((unseen . 9)
                        (messages . (((uid . "5") (from . "Ann") (subject . "Hi") (date . ,(- now 7200))
                                      (msgid . "<abc@mail.x>"))))))))
    (should (= 2 (length items)))
    (let ((it (car items)))
      (should (eq (briefing-item-source it) 'mail))
      (should (equal (briefing-item-key it) "Gmail|5"))
      (should (equal (briefing-item-why it) "Gmail"))
      (should (equal (briefing-item-age it) "2h"))
      (should (equal (briefing-item-task-title it) "Reply to Ann: Hi"))
      ;; A deep link to exactly this message, with the address of the right account.
      (should (string-match-p "authuser=me%40gmail.com#search/rfc822msgid%3Aabc%40mail.x\\'"
                              (briefing-item-url it))))
    ;; 9 unread, 1 shown: say so.
    (should (equal (briefing-item-title (cadr items)) "… 8 more unread"))
    (should (string-match-p "is%3Aunread" (briefing-item-url (cadr items))))))

(ert-deftest briefing-mail-no-more-row-when-everything-is-shown ()
  (let ((items (briefing-mail--items '(:name "Zoho" :host "imappro.zoho.com" :user "z")
                                     '((unseen . 1) (messages . (((uid . "1") (from . "A") (subject . "S") (date . 0) (msgid . ""))))))))
    (should (= 1 (length items)))
    (should (equal (briefing-item-age (car items)) ""))        ; no usable Date header
    (should (string-match-p "zoho" (briefing-item-url (car items))))))

(ert-deftest briefing-mail-unknown-hosts-have-no-link ()
  (should-not (briefing-mail--web-url '(:host "mail.example.org" :user "u"))))

;;;; The section

(defmacro briefing-mail-test-with-accounts (accounts &rest body)
  "Run BODY with ACCOUNTS (name . result-or-error) standing in for real fetches."
  (declare (indent 1))
  `(let ((briefing-mail-accounts (mapcar (lambda (a) (list :name (car a) :host "h" :user (car a))) ,accounts))
         (briefing-mail-providers nil))
     (cl-letf (((symbol-function 'briefing-mail--fetch-account)
                (lambda (acct cb) (funcall cb (cdr (assoc (plist-get acct :name) ,accounts))))))
       ,@body)))

(defun briefing-mail-test--msg (title date)
  (briefing-item-create :source 'mail :key title :title title :why "x" :data date))

(ert-deftest briefing-mail-merges-accounts-newest-first ()
  (let (result)
    (briefing-mail-test-with-accounts
        `(("A" ,(briefing-mail-test--msg "old" 100) ,(briefing-mail-test--msg "mid" 200))
          ("B" ,(briefing-mail-test--msg "new" 300)))
      (briefing-mail-fetch (lambda (r) (setq result r)) nil))
    (should (equal (mapcar #'briefing-item-title result) '("new" "mid" "old")))))

(ert-deftest briefing-mail-one-failing-account-does-not-hide-the-rest ()
  (let (result)
    (briefing-mail-test-with-accounts
        `(("A" ,(briefing-mail-test--msg "ok" 100))
          ("B" error . "B: Invalid credentials"))
      (briefing-mail-fetch (lambda (r) (setq result r)) nil))
    (should (equal (mapcar #'briefing-item-title result) '("B: Invalid credentials" "ok")))
    (should (eq (briefing-item-source (car result)) 'mailerr))
    (should (eq (briefing--section-of (car result)) 'mail))))

(ert-deftest briefing-mail-everything-failing-is-an-error ()
  (let (result)
    (briefing-mail-test-with-accounts '(("A" error . "A: down") ("B" error . "B: down"))
      (briefing-mail-fetch (lambda (r) (setq result r)) nil))
    (should (eq (car-safe result) 'error))
    (should (string-match-p "A: down; B: down" (cdr result)))))

(ert-deftest briefing-mail-no-accounts-is-a-clear-error ()
  (let ((briefing-mail-accounts nil) (briefing-mail-providers nil) result)
    (briefing-mail-fetch (lambda (r) (setq result r)) nil)
    (should (eq (car-safe result) 'error))
    (should (string-match-p "no mail accounts" (cdr result)))))

(ert-deftest briefing-mail-extra-providers-are-merged ()
  (let (result)
    (briefing-mail-test-with-accounts `(("A" ,(briefing-mail-test--msg "imap" 100)))
      (let ((briefing-mail-providers
             (list (lambda (cb &optional _force) (funcall cb (list (briefing-mail-test--msg "work" 500)))))))
        (briefing-mail-fetch (lambda (r) (setq result r)) nil)))
    (should (equal (mapcar #'briefing-item-title result) '("work" "imap")))))

(ert-deftest briefing-mail-error-rows-cannot-become-tasks ()
  (should (memq 'mailerr briefing-task-source-ids)))

;;;; Work mail through the Gmail connector

(defun briefing-work-test--reply (&rest threads)
  "What `claude -p --output-format json' prints for a search that returned THREADS."
  (json-serialize
   `(:type "result" :is_error :false
     :result ,(json-serialize `(:searched t :threads ,(vconcat threads))))))

(defun briefing-work-test--thread (&rest kv)
  (append kv '(:id "1a188d03380004eb" :from "Ann" :subject "Hello" :date "2026-11-13T21:39:21Z"
               :url "https://mail.google.com/mail/?authuser=me%40x.test#all/thread-f:1" :count 2)))

(ert-deftest briefing-work-mail-may-only-search ()
  ;; The safety property: the command allows ToolSearch and the Gmail *search* tool,
  ;; and nothing that sends, trashes, labels or touches files.
  (let ((cmd (briefing-work-mail--command)))
    (should (equal briefing-work-mail-allowed-tools
                   '("ToolSearch" "mcp__claude_ai_Gmail__search_threads")))
    (should (equal (nth (1+ (cl-position "--tools" cmd :test #'equal)) cmd) "ToolSearch"))
    (let* ((i (cl-position "--allowedTools" cmd :test #'equal)))
      (should (equal (cl-subseq cmd (1+ i) (+ i 3)) briefing-work-mail-allowed-tools))
      (should (equal (nth (+ i 3) cmd) "--output-format")))
    (should (member "--no-session-persistence" cmd))
    (dolist (bad '("send" "trash" "label" "draft" "forward" "reply" "Bash" "Write" "Edit"))
      (should-not (cl-some (lambda (a) (and (string-match-p (concat "__" bad) a) t)) cmd)))))

(ert-deftest briefing-work-mail-prompt-treats-mail-as-data ()
  (let ((p (briefing-work-mail--prompt)))
    (should (string-match-p "never instructions" p))
    (should (string-match-p "searched" p))
    (should (string-match-p (regexp-quote briefing-work-mail-query) p))))

(ert-deftest briefing-work-mail-parses-a-good-reply ()
  (let ((th (briefing-work-mail--parse (briefing-work-test--reply (briefing-work-test--thread)))))
    (should (= 1 (length th)))
    (should (equal (alist-get 'subject (car th)) "Hello"))))

(ert-deftest briefing-work-mail-strips-code-fences ()
  (let* ((inner (concat "```json\n" (json-serialize '(:searched t :threads [])) "\n```"))
         (out (json-serialize `(:result ,inner :is_error :false))))
    (should (null (briefing-work-mail--parse out)))))

(ert-deftest briefing-work-mail-empty-search-is-empty-not-an-error ()
  (let ((r (briefing-work-mail--parse (briefing-work-test--reply))))
    (should-not (eq (car-safe r) 'error))
    (should (null r))))

(ert-deftest briefing-work-mail-a-search-that-did-not-run-is-an-error ()
  ;; Without this an unfinished search would read as "no mail", the worst answer.
  (dolist (out (list
                (json-serialize `(:result ,(json-serialize '(:searched :false :threads [] :problem "no tool")) :is_error :false))
                (json-serialize `(:result "I could not run the Gmail search." :is_error :false))
                (json-serialize `(:result ,(json-serialize '(:threads [])) :is_error :false))   ; no "searched"
                (json-serialize '(:result "x" :is_error t))
                "not json at all" ""))
    (should (eq (car-safe (briefing-work-mail--parse out)) 'error))))

(ert-deftest briefing-work-mail-the-problem-text-is-shown-cleaned ()
  (let ((r (briefing-work-mail--parse
            (json-serialize `(:result ,(json-serialize '(:searched :false :threads [] :problem "tool\nmissing")) :is_error :false)))))
    (should (equal (cdr r) "tool missing"))))

(ert-deftest briefing-work-mail-items-and-safety-filters ()
  (let* ((good (alist-get 'x (list (cons 'x (car (alist-get 'threads
                                                 (json-parse-string
                                                  (json-serialize `(:threads [,(briefing-work-test--thread :subject "Real\nline")]))
                                                  :object-type 'alist :array-type 'list)))))))
         (threads (json-parse-string
                   (json-serialize
                    `(:threads [,(briefing-work-test--thread)
                                ,(briefing-work-test--thread :url "https://evil.example/phish")   ; not a Gmail link
                                ,(briefing-work-test--thread :id "not-an-id!")                    ; malformed id
                                ,(briefing-work-test--thread :url "javascript:alert(1)")
                                ,(briefing-work-test--thread :subject "Real\nline" :id "ffffffff00000001")]))
                   :object-type 'alist :array-type 'list))
         (items (briefing-work-mail--items (alist-get 'threads threads))))
    (ignore good)
    (should (= 2 (length items)))
    (should (cl-every (lambda (i) (string-prefix-p "https://mail.google.com/" (briefing-item-url i))) items))
    ;; Control characters cannot break the row layout.
    (should (equal (briefing-item-title (cadr items)) "Real line"))
    (should (eq (briefing-item-source (car items)) 'mail))
    (should (equal (briefing-item-why (car items)) "Work"))
    (should (equal (briefing-item-key (car items)) "Work|1a188d03380004eb"))
    (should (equal (briefing-item-task-title (car items)) "Reply to Ann: Hello"))
    (should (> (briefing-item-data (car items)) 0))))

(ert-deftest briefing-work-mail-retries-when-the-model-skips-the-search ()
  (let ((calls 0) result
        (answers (list "{\"result\": \"<invoke name=ToolSearch>\"}"
                       (json-serialize '(:result "I cannot run this" :is_error :false))
                       (briefing-work-test--reply (briefing-work-test--thread)))))
    (cl-letf (((symbol-function 'briefing-run)
               (lambda (_prog _args cb &optional _input)
                 ;; Count first: the retry happens inside the callback.
                 (let ((n calls)) (cl-incf calls) (funcall cb (cons 0 (nth n answers)))))))
      (briefing-work-mail-fetch (lambda (r) (setq result r)) t))
    (should (= calls 3))
    (should (= 1 (length result)))))

(ert-deftest briefing-work-mail-gives-up-with-a-clear-error ()
  (let ((calls 0) result (briefing-work-mail-attempts 2))
    (cl-letf (((symbol-function 'briefing-run)
               (lambda (_prog _args cb &optional _input) (cl-incf calls) (funcall cb (cons 0 "garbage")))))
      (briefing-work-mail-fetch (lambda (r) (setq result r)) t))
    (should (= calls 2))
    (should (eq (car-safe result) 'error))
    (should (string-match-p "Work: .*after 2 tries" (cdr result)))))

(ert-deftest briefing-work-mail-nonzero-exit-is-retried-then-reported ()
  (let ((calls 0) result)
    (cl-letf (((symbol-function 'briefing-run)
               (lambda (_prog _args cb &optional _input) (cl-incf calls) (funcall cb (cons 1 "")))))
      (briefing-work-mail-fetch (lambda (r) (setq result r)) t))
    (should (= calls briefing-work-mail-attempts))
    (should (string-match-p "status 1" (cdr result)))))

(ert-deftest briefing-work-mail-runs-in-a-neutral-directory ()
  (let (dir)
    (cl-letf (((symbol-function 'briefing-run)
               (lambda (_prog _args cb &optional _input)
                 (setq dir default-directory)
                 (funcall cb (cons 0 (briefing-work-test--reply))))))
      (briefing-work-mail-fetch #'ignore t))
    (should (equal (file-truename dir) (file-truename temporary-file-directory)))))

(ert-deftest briefing-work-mail-merges-with-imap-accounts ()
  (let (result)
    (briefing-mail-test-with-accounts `(("A" ,(briefing-mail-test--msg "imap" 100)))
      (let ((briefing-mail-providers (list #'briefing-work-mail-fetch)))
        (cl-letf (((symbol-function 'briefing-run)
                   (lambda (_p _a cb &optional _i)
                     (funcall cb (cons 0 (briefing-work-test--reply (briefing-work-test--thread)))))))
          (briefing-mail-fetch (lambda (r) (setq result r)) t))))
    (should (equal (mapcar #'briefing-item-why result) '("Work" "x")))))

(provide 'briefing-mail-tests)
;;; briefing-mail-tests.el ends here
