;; ── mu4e + org email ───────────────────────────────────────────────────

(require 'mu4e)

(defun my/mu4e()
  (interactive)
  (when-let ((emaila (map-elt activities-activities "mu4e")))
    (activities-resume emaila)
    )
  )

;; for activities el
(defun my/mu4e-bookmark-handler (_bookmark)
  "Restore a mu4e bookmark."
  (mu4e)
  (get-buffer "*mu4e-main*"))

(defun my/mu4e-bookmark-make-record ()
  `("mu4e"
    (handler . my/mu4e-bookmark-handler)))

(add-hook 'mu4e-main-mode-hook
          (lambda ()
            (setq-local bookmark-make-record-function
                        #'my/mu4e-bookmark-make-record)))

(use-package mu4e
  :ensure nil
  :defer t
  :config
  (setq mu4e-maildir "/data/mbsync-mail/"
        mu4e-context-policy 'pick-first
        mu4e-completing-read-function #'completing-read ;; vertico
        mu4e-maildir-shortcuts '((:maildir "/Inbox/" :key ?i))
        mu4e-compose-context-policy 'ask-if-none
        send-mail-function 'smtpmail-send-it
        smtpmail-debug-info t
        mu4e-sent-folder "/Sent"
        mu4e-drafts-folder "/Drafts"
        mu4e-trash-folder "/Trash"
        mu4e-refile-folder "/Archive"
        mu4e-attachment-dir "/home/rashid/Downloads/attachments"
        mu4e-get-mail-command "mu index --nocolor"
        mu4e-update-interval 600
        mu4e-headers-visible-columns 60
        mu4e-split-view 'vertical
        smtpmail-stream-type 'ssl)
  (setq mu4e-contexts
        `(,(make-mu4e-context
            :name "personal"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/personal" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rashid301@gmail.com")
                    (mu4e-sent-folder   . "/personal/[Gmail]/Sent Mail")
                    (mu4e-drafts-folder . "/personal/Drafts")
                    (mu4e-trash-folder  . "/personal/[Gmail]/Trash")
                    (mu4e-refile-folder . "/personal/Archive")
                    (smtpmail-smtp-user . "rashid301@gmail.com")
                    (smtpmail-smtp-server . "smtp.gmail.com")
                    (smtpmail-smtp-service . 465)
                    (user-full-name . "Rashid Shaikh")))
          ,(make-mu4e-context
            :name "sensai"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/sensai" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rshaikh@coachsensai.com")
                    (mu4e-drafts-folder . "/sensai/Drafts")
                    (mu4e-sent-folder   . "/sensai/[Gmail]/Sent Mail")
                    (mu4e-trash-folder  . "/sensai/[Gmail]/Trash")
                    (mu4e-refile-folder . "/sensai/Archive")))
          ,(make-mu4e-context
            :name "yahoo"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/yahoo" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rashidali.shaikh@yahoo.com")
                    (mu4e-sent-folder   . "/yahoo/Sent")
                    (mu4e-drafts-folder . "/yahoo/Drafts")
                    (mu4e-trash-folder  . "/yahoo/Trash")
                    (mu4e-refile-folder . "/yahoo/Archive")))
          ,(make-mu4e-context
            :name "zoho"
            :match-func (lambda (msg)
                          (when msg
                            (string-prefix-p "/zoho" (mu4e-message-field msg :maildir))))
            :vars '((user-mail-address . "rashid@bitbute.tech")
                    (mu4e-sent-folder   . "/zoho/Sent")
                    (mu4e-drafts-folder . "/zoho/Drafts")
                    (mu4e-trash-folder  . "/zoho/Trash")
                    (mu4e-refile-folder . "/zoho/Archive")
                    (smtpmail-smtp-user . "rashid@bitbute.tech")
                    (smtpmail-smtp-server . "smtppro.zoho.com")
                    (smtpmail-smtp-service . 465)
                    (user-full-name . "Rashid Shaikh")))))
  (setq mu4e-headers-fields
        '(
          ;; (:account-stripe . 1)
          (:human-date . 12)
          (:flags . 6)
          (:from . 22)
          (:subject . 50)
          (:maildir . 50)))

  (defvar +mu4e-gmail-accounts 
    (setq +mu4e-gmail-accounts
          '(
            ("rashid301@gmail.com" . "personal")
            ("rshaikh@coachsensai.com" . "sensai")
            ))
    "Gmail accounts that do not contain \"gmail\" in address and maildir.

An alist of Gmail addresses of the format \((\"username@domain.com\" . \"account-maildir\"))
to which Gmail integrations (behind the `+gmail' flag of the `mu4e' module) should be applied.

See `+mu4e-msg-gmail-p' and `mu4e-sent-messages-behavior'.")

  ;; don't save message to Sent Messages, Gmail/IMAP takes care of this
  (setq mu4e-sent-messages-behavior
        (lambda () ;; TODO: make use +mu4e-msg-gmail-p
          (if (or (string-match-p "@gmail.com\\'" (message-sendmail-envelope-from))
                  (member (message-sendmail-envelope-from)
                          (mapcar #'car +mu4e-gmail-accounts)))
              'delete 'sent)))

  (defun +mu4e-msg-gmail-p (msg)
    (let ((root-maildir
           (replace-regexp-in-string "/.*" ""
                                     (substring (mu4e-message-field msg :maildir) 1))))
      (or (string-match-p "gmail" root-maildir)
          (member root-maildir (mapcar #'cdr +mu4e-gmail-accounts)))))

  ;; In my workflow, emails won't be moved at all. Only their flags/labels are
  ;; changed. Se we redefine the trash and refile marks not to do any moving.
  ;; However, the real magic happens in `+mu4e-gmail-fix-flags-h'.
  ;;
  ;; Gmail will handle the rest.
  (defun +mu4e--mark-seen (docid _msg target)
    (mu4e--server-move docid (mu4e--mark-check-target target) "+S-u-N"))

  (defvar +mu4e--last-invalid-gmail-action 0)

  (setf (alist-get 'delete mu4e-marks)
        (list
         :char '("D" . "✘")
         :prompt "Delete"
         :show-target (lambda (_target) "delete")
         :action (lambda (docid msg target)
                   (if (+mu4e-msg-gmail-p msg)
                       (progn (message "The delete operation is invalid for Gmail accounts. Trashing instead.")
                              (+mu4e--mark-seen docid msg target)
                              (when (< 2 (- (float-time) +mu4e--last-invalid-gmail-action))
                                (sit-for 1))
                              (setq +mu4e--last-invalid-gmail-action (float-time)))
                     (mu4e--server-remove docid))))
        (alist-get 'trash mu4e-marks)
        (list :char '("d" . "▼")
              :prompt "dtrash"
              :dyn-target (lambda (_target msg) (mu4e-get-trash-folder msg))
              :action (lambda (docid msg target)
                        (if (+mu4e-msg-gmail-p msg)
                            (+mu4e--mark-seen docid msg target)
                          (mu4e--server-move docid (mu4e--mark-check-target target) "+T-N"))))
        ;; Refile will be my "archive" function.
        (alist-get 'refile mu4e-marks)
        (list :char '("r" . "▼")
              :prompt "rrefile"
              :dyn-target (lambda (_target msg) (mu4e-get-refile-folder msg))
              :action (lambda (docid msg target)
                        (if (+mu4e-msg-gmail-p msg)
                            (+mu4e--mark-seen docid msg target)
                          (mu4e--server-move docid (mu4e--mark-check-target target) "-N")))
              #'+mu4e--mark-seen))

  ;; This hook correctly modifies gmail flags on emails when they are marked.
  ;; Without it, refiling (archiving), trashing, and flagging (starring) email
  ;; won't properly result in the corresponding gmail action, since the marks
  ;; are ineffectual otherwise.
  (add-hook 'mu4e-mark-execute-pre-hook
            (defun +mu4e-gmail-fix-flags-h (mark msg)
              (when (+mu4e-msg-gmail-p msg)
                (pcase mark
                  (`trash  (mu4e-action-retag-message msg "-\\Inbox,+\\Trash,-\\Draft"))
                  (`delete (mu4e-action-retag-message msg "-\\Inbox,+\\Trash,-\\Draft"))
                  (`refile (mu4e-action-retag-message msg "-\\Inbox"))
                  (`flag   (mu4e-action-retag-message msg "+\\Starred"))
                  (`unflag (mu4e-action-retag-message msg "-\\Starred"))))))


  ;; Call EWW to display HTML messages
  (defun jcs-view-in-eww (msg)
    (let ((browse-url-browser-function 'eww-browse-url))
      (mu4e-action-view-in-browser msg)))

  
  ;; Arrange to view messages in either the default browser or EWW
  (add-to-list 'mu4e-view-actions '("Eww view" . jcs-view-in-eww) t)
  )

(use-package mu4e-org
  :ensure nil)

(use-package auth-source-pass
  :config
  (auth-source-pass-enable))

(setq auth-source-debug nil
      auth-source-do-cache nil
      auth-sources '(password-store))
(provide 'config-email)
