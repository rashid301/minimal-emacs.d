;; ── GNUS email (personal Gmail) ────────────────────────────────────────

;; GNUS is built into Emacs — no packages to install.
;; Connects directly to IMAP/SMTP, no local maildir needed.

(use-package gnus
  :ensure nil ;; built-in
  :config

  (setq user-full-name "Rashid Shaikh"
        user-mail-address "rashid301@gmail.com")
  (setq nnimap-record-commands t)


  ;; IMAP Setup for Gmail
  (setq gnus-select-method
        '(nnimap "gmail"
                 (nnimap-address "imap.gmail.com")
                 (nnimap-server-port 993)
                 (nnimap-user "rashid301@gmail.com")
                 (nnimap-stream ssl)))

  (add-to-list 'gnus-secondary-select-methods
               '(nnimap "zoho"
                        (nnimap-address "imappro.zoho.com")  ; Use "imappro.zoho.com" if using a custom organization domain
                        (nnimap-server-port 993)
                        (nnimap-stream ssl)
                        (nnimap-user "rashid@bitbute.tech"))) ; Put your full Zoho email here

  (add-to-list 'gnus-secondary-select-methods
               '(nnimap "senzo"
                        (nnimap-address "imap.gmail.com")  ; 
                        (nnimap-server-port 993)
                        (nnimap-stream ssl)
                        (nnimap-user "rshaikh@coachsensai.com"))) ; Put your full Zoho email here


  ;; SMTP Setup for Sending Mail
  (setq message-send-mail-function 'message-smtpmail-send-it)
  (setq smtpmail-auth-credentials "~/.authinfo.gpg")

  (defun my-gnus-dynamic-archive (group)
    "Dynamically determine the archive folder based on the IMAP server."
    (cond
     ;; Match Gmail and send to All Mail
     ((string-match "^nnimap\\+gmail:" group)
      "nnimap+gmail:[Gmail]/All Mail")
     
     ;; Match Senzo and send to its Archive folder
     ((string-match "^nnimap\\+senzo:" group)
      "nnimap+senzo:Archive")
     
     ;; Match Zoho and send to its Archive folder
     ((string-match "^nnimap\\+zoho:" group)
      "nnimap+zoho:Archive")
     
     ;; Fallback safety net (deletes the message if no server matches)
     (t 'delete)))

  ;; Apply this function globally to all your INBOX folders
  (setq gnus-parameters
        '(("^nnimap\\+\\(gmail\\|senzo\\|zoho\\):INBOX$"
           (total-expire . t)
           (nnmail-expiry-wait . immediate)
           (nnmail-expiry-target . my-gnus-dynamic-archive))))


  (defun set-smtp-server-by-from-header ()
    "Dynamically updates SMTP server settings based on the email address in the From field."
    (save-excursion
      (let ((from (save-restriction
                    (message-narrow-to-headers)
                    (message-fetch-field "from"))))
        (cond
         ((string-match-p "gmail.com" from)
          (setq smtpmail-smtp-server "smtp.gmail.com"
                smtpmail-smtp-service 587
                smtpmail-stream-type 'starttls))
         ((string-match-p "zoho.com" from)
          (setq smtpmail-smtp-server "smtp.zoho.com"
                smtpmail-smtp-service 587
                smtpmail-stream-type 'starttls))))))

  (add-hook 'message-send-hook 'set-smtp-server-by-from-header)

  ;; Authentication via .authinfo (Recommended)
  (setq auth-sources '("~/.authinfo.gpg" "~/.authinfo"))

  ;; Tell Gnus to look at the hidden SMTP method header when sending
  (setq message-send-mail-function 'message-use-send-mail-function)
  (setq send-mail-function 'smtpmail-send-it)

  ;; Configure posting styles based on the IMAP folder context
  (setq gnus-posting-styles
        '(
          ;; If inside any Gmail folder, use your Gmail persona and SMTP
          ("^nnimap\\+gmail:"
           (address "rashid301@gmail.com")
           (name "Rashid Shaikh")
           ("X-Message-SMTP-Method" "smtp smtp.gmail.com 587 rashid301@gmail.com"))

          ;; If inside any Zoho folder, use your Zoho persona and SMTP
          ("^nnimap\\+zoho:"
           (address "rashid@bitbute.tech")
           (name "Rashid Shaikh")
           ("X-Message-SMTP-Method" "smtp ://zoho.com 587 rashid@bitbute.tech"))

          ("^nnimap\\+senzo:"
           (address "rshaikh@coachsensai.com")
           (name "Rashid Shaikh")
           ("X-Message-SMTP-Method" "smtp smtp.gmail.com 587 rshaikh@coachsensai.com"))
          ))
  )


(provide 'config-gnus)
