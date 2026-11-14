;; config-apps.el --- App configurations (elfeed, ement, link-hint, pdf-tools) -*- lexical-binding: t; -*-

;; ── Elfeed (RSS reader) ────────────────────────────────────────────────
(use-package elfeed
  :ensure t
  :defer t
  :custom
  (elfeed-search-filter "@3days +unread")
  :config
  (add-hook 'elfeed-search-mode-hook #'elfeed-update)
  )

(use-package elfeed-org
  :after elfeed
  :ensure t
  :custom
  (rmh-elfeed-org-files '("~/Dropbox/notes/elfeed.org"))
  :config
  (elfeed-org))


;; ── link-hint ─────────────────────────────────────────────────────────

(use-package link-hint
  :ensure t)

;; ── pdf-tools ─────────────────────────────────────────────────────────

;; jka-compat is the C extension that pdf-view requires. The Nix store build
;; of pdf-tools ships without it, so install via package.el (compiles against
;; the running Emacs). Must load before pdf-tools.
(use-package jka-compr
  :ensure t)

(use-package pdf-tools
  ;; Provided by Nix (epkgs.pdf-tools in the EWM emacsPackage build).
  ;; use-package-always-ensure is on globally, so :ensure nil is REQUIRED
  ;; here — otherwise package.el would install a second copy from MELPA.
  :ensure nil
  :mode ("\\.pdf\\'" . pdf-view-mode)
  :config
  ;; epdfinfo is NOT auto-discovered: pdf-info.el's default falls back to the
  ;; relative name "epdfinfo", resolved against your cwd at runtime. Derive
  ;; the path from the loaded library so Nix rebuilds (new store hash) don't
  ;; break it.
  (setq pdf-info-epdfinfo-program
        (expand-file-name "epdfinfo"
                          (file-name-directory
                           (locate-library "pdf-tools"))))
  )


;; ── ement ─────────────────────────────────────────────────────────────

(use-package ement
  :custom
  (ement-save-sessions t)
  ;; (ement-view-room-display-buffer-action
  ;;  '((display-buffer-reuse-window)))
  ;; (ement-view-room-display-buffer-action
  ;;  '((display-buffer-reuse-window)
  ;;    (window-parameters . ((quit-restore . delete)))))


  (ement-room-compose-buffer-display-action
   (cons 'display-buffer-below-selected
         '((window-height . 15)
           (inhibit-same-window . t)
           (reusable-frames . nil))))
  (ement-view-room-display-buffer-action
   '((display-buffer-reuse-window
      display-buffer-pop-up-window)
     (window-parameters . ((quit-restore . delete)))))

  (ement-room-send-message-filter #'ement-room-send-org-filter)
  (setopt
   evil-collection-ement-want-auto-retro t
   ement-room-buffer-name-prefix "Ement Room:" ;; remove asterisk for persp
   ement-room-buffer-name-suffix ""
   )

  :config
  (defun my/ement-ret ()
    (interactive)
    (if (or (button-at (point))
            (get-text-property (point) 'mouse-face))
        (push-button)
      (ement-room-send-message)))

  (defun rs/ement-fundamental-save-binding ()
    (local-set-key (kbd "C-c C-c") #'save-buffer))

  (add-hook 'ement-room-compose-hook #'rs/ement-fundamental-save-binding)

  (evil-collection-define-key '(normal motion) 'ement-room-mode-map
    (kbd "<")  'ement-room-transient
    (kbd "<return>")   'my/ement-ret
    (kbd "RET")        'my/ement-ret))

;; (use-package docker
;;   :ensure t
;;   )

(provide 'config-apps)

;; ── Slack (emacs-slack) ────────────────────────────────────────────────
;; Token/cookie live in auth-source (~/.authinfo, chmod 600):
;;   machine clearcompany.slack.com login clearcompany password xoxc-...
;;   machine clearcompany.slack.com login clearcompany^cookie password xoxd-...
;; Get them interactively with M-x slack-refresh-token. Then M-x slack-start.
(use-package alert
  :ensure t
  :commands (alert)
  :init (setq alert-default-style 'notifier))

(use-package slack
  :ensure t
  :commands (slack-start slack-select-rooms slack-select-unread-rooms slack-refresh-token)
  :bind (("C-c S s" . slack-start)
         ("C-c S c" . slack-select-rooms)
         ("C-c S u" . slack-select-unread-rooms)
         ("C-c S U" . slack-user-select)
         ("C-c S t" . slack-thread-show-or-create)
         ("C-c S K" . slack-stop))
  :custom
  (slack-buffer-emojify t)
  (slack-prefer-current-team t)
  :config
  (slack-register-team
   :name "clearcompany"
   :token (auth-source-pick-first-password :host "clearcompany.slack.com" :user "clearcompany")
   :cookie (auth-source-pick-first-password :host "clearcompany.slack.com" :user "clearcompany^cookie")
   :full-and-display-names t
   :mark-as-read-immediately nil
   :default t))

;; Slack: evil bindings (normal state) for message/thread buffers.
(with-eval-after-load 'slack
  (with-eval-after-load 'evil
    (evil-define-key* '(normal motion) slack-mode-map
      (kbd "]m") #'slack-buffer-goto-next-message
      (kbd "[m") #'slack-buffer-goto-prev-message
      (kbd "C-j") #'slack-buffer-goto-next-message
      (kbd "C-k") #'slack-buffer-goto-prev-message
      "r" #'slack-message-add-reaction
      "R" #'slack-message-remove-reaction
      "e" #'slack-message-edit
      "D" #'slack-message-delete
      "t" #'slack-thread-show-or-create
      "gq" #'slack-quote-and-reply
      "gQ" #'slack-quote-and-reply-with-link
      "gs" #'slack-message-share
      "gb" #'slack-jump-to-browser
      "q" #'quit-window)
    (evil-define-key* 'normal slack-message-compose-buffer-mode-map
      (kbd "RET") #'slack-message-send-from-buffer)
    (evil-define-key* '(normal motion) slack-message-buffer-mode-map
      "o" #'slack-message-write-another-buffer)))

;; ── Slack: minimal bookmark support (so activities.el can restore) ─────
;; Records team + room ids; on jump, opens the room if Slack is connected,
;; otherwise returns a stub buffer so activities.el never shows its error
;; placeholder.
(with-eval-after-load 'slack
  (defun my/slack-bookmark-make-record ()
    "Bookmark record for the current Slack buffer: team + room ids."
    (let ((b slack-current-buffer))
      `(,(buffer-name)
        (team-id . ,(and b (oref b team-id)))
        (room-id . ,(and b (slot-boundp b 'room-id) (oref b room-id)))
        (handler . my/slack-bookmark-jump))))

  (defun my/slack-bookmark-jump (bmk)
    "Open the room in BMK; if Slack isn't connected, show a stub buffer."
    ;; Callers (activities.el) judge success by whether the *current buffer*
    ;; changed, so always leave a Slack buffer or a stub current.
    (let* ((team (ignore-errors (slack-team-find (bookmark-prop-get bmk 'team-id))))
           (room-id (bookmark-prop-get bmk 'room-id))
           (room (and team room-id (ignore-errors (slack-room-find room-id team))))
           (open (and room (slack-buffer-find 'slack-message-buffer team room)))
           (open-buf (and open (oref open buf))))
      (if (buffer-live-p open-buf)
          (set-buffer open-buf)
        ;; Room not open yet: fetch it (async) and hold the place with a stub.
        (when room (slack-room-display room team))
        (let ((stub (get-buffer-create
                     (format "*Slack (%s): %s*"
                             (if room "opening" "not connected")
                             (bookmark-name-from-full-record bmk)))))
          (with-current-buffer stub
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (if room
                          "Opening room...\n"
                        (concat "Slack isn't connected or the room wasn't found.\n"
                                "Run C-c S s (slack-start), then C-c S c to reopen it.\n")))))
          (set-buffer stub)))))

  (dolist (hook '(slack-message-buffer-mode-hook
                  slack-thread-message-buffer-mode-hook))
    (add-hook hook (lambda ()
                     (setq-local bookmark-make-record-function
                                 #'my/slack-bookmark-make-record)))))

;; Slack: auto-connect a few seconds after startup (idle, so it doesn't slow
;; init). `slack-start' is autoloaded, so this also loads the package and runs
;; the :config that registers the team. Don't re-run `slack-start' manually
;; afterwards: it kills open Slack buffers before reconnecting.
(add-hook 'emacs-startup-hook
          (lambda ()
            (run-with-idle-timer
             5 nil
             (lambda ()
               (condition-case err
                   (slack-start)
                 (error (message "slack auto-start failed: %S" err)))))))
