;;; browser-ewm.el --- Glide browser EWM integration -*- lexical-binding: t; -*-

;;; This module contains EWM-specific browser integrations.
;;; Requires config-browser.el to be loaded first.

(require 'config-browser)
(require 'ewm)

;;; ---- EWM buffer management ----

(defun glide--ewm-list ()
  "List EWM buffers that belong to Glide Browser."
  (cl-remove-if-not
   (lambda (buf)
     (with-current-buffer buf
       (string-prefix-p "glide" (or ewm-surface-app ""))))
   (hash-table-values ewm--surfaces)))


(defun glide--ewm-candidate (buf)
  (with-current-buffer buf
    (let* ((title (or ewm-surface-title "Untitled"))
           ;; prefer the buffer-local set by Glide's WindowLoaded autocmd,
           ;; fall back to parsing the window title
           (profile (or glide-profile (glide--extract-profile title)))
           (domain (glide--extract-domain (or glide-url "")))
           )
      (propertize
       (truncate-string-to-width title 50 0 nil t)
       'glide-profile profile
       'glide-title title
       'glide-domain domain
       'ewm-buffer buf
       'ewm-app 'glide
       ))))


(setq consult--glide-current-url
      '(:name "Current URL"
              :items (lambda ()
                       (list (or (and (bound-and-true-p glide-url)
                                      (not (string-empty-p glide-url))
                                      glide-url)
                                 "")))))

(setq consult--glide-windows
      `(:name "Glide Windows"
              :narrow ?g
              :category glide
              :require-match t
              :action ,(lambda (cand)
                         (let ((buf (get-text-property 0 'ewm-buffer cand)))
                           (when buf (switch-to-buffer buf))))
              :items
              ,(lambda ()
                 (delq nil (mapcar #'glide--ewm-candidate (glide--ewm-list))))))


;;; ---- Glide bookmark support (EWM-specific) ----

(defun glide-bookmark--ewm-buffer-alive-p (title)
  "Return the EWM buffer for a Glide window with TITLE, or nil."
  (let ((buf-name (concat "*ewm:" title "*")))
    (get-buffer buf-name)))

(defun glide-bookmark--make-record (&optional _always-create bmk-name)
  "Create a bookmark record for Glide EWM buffers."
  (when (boundp 'ewm-surface-title)
    (let* ((title ewm-surface-title)
           ;; prefer buffer-locals set by Glide autocmds, fall back to
           ;; title parsing + places.sqlite lookup
           (profile (or glide-profile (glide--extract-profile title)))
           (url (or glide-url
                    (glide--lookup-url-by-title (glide--extract-history-title title) profile))))
      (unless url
        (user-error "No URL found in %s's history for title: %s" profile title)
        )
      `((,(or bmk-name (buffer-name)))
        (handler . glide-bookmark--handler)
        (filename . ,url)
        (glide-title . ,title)
        (glide-url . ,url)
        (glide-profile . ,(or profile "Personal"))))))

(defun glide-bookmark--handler (bmk)
  "Jump to a Glide bookmark.
If the EWM buffer still exists, switch to it.
Otherwise, look up the URL in places.sqlite and open it."
  (let* ((title (bookmark-prop-get bmk 'glide-title))
         (profile (bookmark-prop-get bmk 'glide-profile))
         (url (bookmark-prop-get bmk 'glide-url))
         (buf (glide-bookmark--ewm-buffer-alive-p title)))
    (if buf
        (progn
          (switch-to-buffer buf)
          buf)
      (progn
        (unless title
          (user-error "Glide bookmark '%s' has no title stored" (bookmark-name bmk)))
        (if url
            (progn
              ;; (message "Opening %s in %s..." url profile)
              (glide--open-url url profile)
              (switch-to-buffer "*scratch*"))
          (user-error "No URL found in %s's history for title: %s" profile title))))))

(defun glide-bookmark--setup ()
  "Set up bookmark support for Glide EWM buffers."
  (when (and (boundp 'ewm-surface-title)
             (string-prefix-p "glide" (or ewm-surface-app "")))
    (make-local-variable 'bookmark-make-record-function)
    (setq bookmark-make-record-function #'glide-bookmark--make-record)))

(add-hook 'ewm-update-title-hook #'glide-bookmark--setup)
(add-hook 'ewm-surface-mode-hook #'glide-bookmark--setup)


;; ── Doom modeline for Glide browser surfaces ───────────────────────

(doom-modeline-def-segment glide-buffer-info
  "Glide: show profile + page title."
  (concat
   (doom-modeline-spc)
   (propertize
    (format "<%s> %s" (or glide-profile "?")
            (truncate-string-to-width (or ewm-surface-title "Untitled") 40 0 nil t))
    'face 'doom-modeline-buffer-file)))

(doom-modeline-def-segment glide-url-segment
  "Glide: show full URL."
  (when glide-url
    (concat
     (doom-modeline-spc)
     (propertize (truncate-string-to-width glide-url 60 0 nil t)
                 'face 'doom-modeline-info))))

(doom-modeline-def-modeline 'glide
  '(bar modals glide-buffer-info)
  '(glide-url-segment))

(defun glide--modeline-setup ()
  "Switch to the 'glide modeline in Glide EWM surface buffers."
  (when (and (boundp 'ewm-surface-app)
             (string-prefix-p "glide" ewm-surface-app))
    (doom-modeline-set-modeline 'glide)))

(add-hook 'ewm-update-title-hook #'glide--modeline-setup)
(add-hook 'ewm-surface-mode-hook #'glide--modeline-setup)

(provide 'browser-ewm)
;;; browser-ewm.el ends here
