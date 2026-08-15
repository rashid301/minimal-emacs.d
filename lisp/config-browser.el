;;; config-browser.el -*- lexical-binding: t; -*-


;;; ---- Glide browser integration (EWM) ----

(require 'subr-x)
(require 'consult)
(require 'bookmark)


(setq glide-profile-dir "/home/rashid/.config/glide/glide")

(setq glide-personal-profile-dir
      (expand-file-name "f3s4ga1h.default-glide" glide-profile-dir)

      glide-senzo-profile-dir
      (expand-file-name "zsrT9in0.Profile 1" glide-profile-dir)

      glide-siddiqua-profile-dir
      (expand-file-name "9QWhOHMr.Profile 2" glide-profile-dir)

      glide-brandjet-profile-dir
      (expand-file-name "TfnOBXOS.Profile 3" glide-profile-dir))

(setq glide-profile-alist
      `(("Personal"  . ,glide-personal-profile-dir)
        ("Senzo"     . ,glide-senzo-profile-dir)
        ("Siddiqua"  . ,glide-siddiqua-profile-dir)
        ("Brandjet"  . ,glide-brandjet-profile-dir)))

(setq glide-profile-indexed-alist
      `(("1" . ("Personal"  . ,glide-personal-profile-dir))
        ("2" . ("Senzo"     . ,glide-senzo-profile-dir))
        ("3" . ("Siddiqua"  . ,glide-siddiqua-profile-dir))
        ("4" . ("Brandjet"  . ,glide-brandjet-profile-dir))))


(defun glide-profile-path (profile-name)
  (cdr (assoc-string profile-name glide-profile-alist t)))


(defun glide--select-profile ()
  (let* ((candidates
          (mapcar (lambda (e)
                    (format "%s %s" (car e) (cadr e)))
                  glide-profile-indexed-alist))
         (choice
          (consult--read
           candidates
           :prompt "Choose Glide profile: "
           :sort nil
           :history nil
           :require-match t))
         (key (car (split-string choice)))
         (profile (cadr (assoc key glide-profile-indexed-alist)))
         )
    profile))


(defun glide--history-query (&optional profile)
  "Return browser history rows: title<TAB>url<TAB>last_visit.
Returns nil if the profile or places.sqlite does not exist."
  (let* ((profile (or profile "Personal"))
         (profile-dir (glide-profile-path profile)))
    (when (and profile-dir
               (file-directory-p profile-dir))
      (let* ((src-db (expand-file-name "places.sqlite" profile-dir)))
        (when (file-exists-p src-db)
          (let* ((tmp-db (make-temp-file "glide-history-" nil ".sqlite"))
                 (wal (concat src-db "-wal"))
                 (shm (concat src-db "-shm"))
                 (tmp-wal (concat tmp-db "-wal"))
                 (tmp-shm (concat tmp-db "-shm"))
                 (sql
                  "SELECT
                     p.title,
                     p.url,
                     datetime(MAX(h.visit_date)/1000000,'unixepoch') AS last_visit
                   FROM moz_places p
                   LEFT JOIN moz_historyvisits h
                          ON p.id = h.place_id
                   WHERE p.url LIKE 'http%'
                   GROUP BY p.id
                   ORDER BY MAX(h.visit_date) DESC
                   LIMIT 500;"))

            ;; Copy DB + WAL safely
            (copy-file src-db tmp-db t)
            (when (file-exists-p wal) (copy-file wal tmp-wal t))
            (when (file-exists-p shm) (copy-file shm tmp-shm t))

            ;; Query
            (split-string
             (shell-command-to-string
              (format "sqlite3 -separator '\t' %s \"%s\""
                      (shell-quote-argument tmp-db)
                      sql))
             "\n" t)))))))


(defun glide--open-url (url &optional profile)
  "Open URL in Glide as a truly new window."
  (let* ((profile-name (or profile "Personal"))
         (profile-dir (glide-profile-path profile-name)))
    (start-process
     "glide" nil
     "/usr/bin/glide-bin"
     "--new-window"
     url
     "--profile"
     profile-dir)))


;;;###autoload
(defun glide-browse-history ()
  "Consult-based history picker for Glide Browser."
  (interactive)
  (let* ((lines (glide--history-query))
         (alist (cl-loop for row in lines
                         for parts = (split-string row "\t")
                         for title = (string-trim (or (nth 0 parts) ""))
                         for url   = (nth 1 parts)
                         for ts    = (or (nth 2 parts) "")
                         for display = (if (string-blank-p title)
                                           (format "%s — %s" url ts)
                                         (format "%s — %s" title url))
                         collect (cons display url)))
         (candidates (mapcar #'car alist))
         (choice (consult--read
                  candidates
                  :prompt "History: "
                  :category 'url
                  :require-match t)))
    (let ((url (alist-get choice alist nil nil #'string=)))
      (if (and url (stringp url) (> (length url) 0))
          (glide--open-url url)
        (user-error "No URL found for selection")))))


(defun glide--ewm-list ()
  "List EWM buffers that belong to Glide Browser."
  (require 'ewm)
  (cl-remove-if-not
   (lambda (buf)
     (with-current-buffer buf
       (and (ewm-surface-buffer-p (current-buffer))
            (string-prefix-p "glide" (or ewm-surface-app "")))))
   (buffer-list)))


(defun glide-switch-window ()
  "Switch to a Glide Browser window using consult."
  (interactive)
  (let* ((list (glide--ewm-list))
         (names (mapcar #'buffer-name list))
         (choice (consult--read names :prompt "Glide windows: ")))
    (switch-to-buffer choice)))


(defun glide--looks-like-url-p (s)
  "Return t if S looks like a URL."
  (or
   ;; http:// https://
   (string-match-p "\\`https?://.+\\'" s)

   ;; about:config, about:profiles, chrome://settings, file:///…
   (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:.*" s)

   ;; localhost or localhost:8080
   (string-match-p "\\`localhost\\(:[0-9]+\\)?\\'" s)

   ;; IPv4: 127.0.0.1 or 127.0.0.1:8080
   (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)\\{3\\}\\(:[0-9]+\\)?\\'" s)

   ;; bare domains like example.com or sub.domain.co
   (string-match-p "\\`[^ ]+\\.[^ ]+\\'" s)))



(defun glide--ewm-candidate (buf)
  (with-current-buffer buf
    (let* ((title (or ewm-surface-title "Untitled"))
           (profile (glide--extract-profile title)))
      (propertize
       (truncate-string-to-width title 80 0 nil t)
       'glide-profile profile
       'glide-title title
       'ewm-buffer buf
       'ewm-app 'glide
       ))))

(defun glide--extract-profile (title)
  "Extract profile name from EWM title.

Title format: 'Page Title — Profile Name — Glide Browser'
Returns the profile name (second-to-last segment) or empty string."
  (let* ((parts (split-string title "[–—]" t "[[:space:]]*"))
         (n (length parts)))
    (if (>= n 2)
        (nth (- n 2) parts)
      "")))

(defun glide--extract-history-title (title)
  "Extract history title name from EWM title.

Title format: 'Page Title — Profile Name — Glide Browser'
Returns the title name (1st segment) or empty string."
  (let* ((parts (split-string title "[–—]" t "[[:space:]]*"))
         (n (length parts)))
    (nth 0 parts)
    ))

(defun glide--extract-domain (url)
  "Extract domain from a URL string. Returns empty string if not found."
  (if-let ((match (string-match "\\(https?://[^[:space:]/?#]+\\)" (or url ""))))
      (match-string 1 url)
    ""))

(defun glide--history-candidate (title url profile)
  (let ((domain (glide--extract-domain url)))
    (propertize
     ;; (format "%s  %s" title domain)
     (truncate-string-to-width title 80 0 nil t)
     ;; 'display (truncate-string-to-width title 60)
     'glide-profile profile
     'glide-title title
     'glide-domain domain
     'glide-url url
     'ewm-app 'glide
     )))


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


(setq consult--glide-personal-history
      `(:name     "History (Personal)"
                  :narrow   ?p
                  :category glide
                  :require-match t
                  :action ,(lambda (value) (glide--open-url (get-text-property 0 'glide-url value)))
                  :items ,(lambda () (glide--history-candidates "Personal"))))

(setq consult--glide-senzo-history
      `(:name     "History (Senzo)"
                  :narrow   ?s
                  :category glide
                  :require-match t
                  :action ,(lambda (value) (glide--open-url (get-text-property 0 'glide-url value) "Senzo"))
                  :items ,(lambda () (glide--history-candidates "Senzo"))))

(setq consult--glide-siddiqua-history
      `(:name     "History (Siddiqua)"
                  :narrow   ?d
                  :require-match t
                  :category glide
                  :action ,(lambda (value) (glide--open-url (get-text-property 0 'glide-url value) "Siddiqua"))
                  :items ,(lambda () (glide--history-candidates "Siddiqua"))))

(setq consult--glide-brandjet-history
      `(:name     "History (Brandjet)"
                  :narrow   ?j
                  :require-match t
                  :category glide
                  :action ,(lambda (value) (glide--open-url (get-text-property 0 'glide-url value) "Brandjet"))
                  :items ,(lambda () (glide--history-candidates "Brandjet"))))


(defun glide-search-keyword (value &optional profile)
  (let ((profile (or profile (glide--select-profile))))
    (glide--open-url
     (format "https://duckduckgo.com/?q=%s"
             (url-hexify-string value))
     profile)))


(require 'json)
(require 'cl-lib)

(setq consult--source-buku
      `(:name     "Buku Bookmarks"
                  :narrow   ?u
                  :category buku
                  :items    glide/consult-buku-candidates
                  :action
                  (lambda (cand)
                    (let* ((url  (get-text-property 0 'buku-url cand))
                           (tags (get-text-property 0 'buku-tags cand))
                           (profile
                            (cond
                             ((member "personal" tags) "Personal")
                             ((member "senzo" tags)    "Senzo")
                             ((member "siddiqua" tags) "Siddiqua")
                             ((member "brandjet" tags) "Brandjet")
                             (t                        nil))))
                      (my-handle-glide-url url profile)))
                  :sort nil))


(defun glide-launcher (&optional initial-query)
  "Unified launcher: open Glide windows, browser history, or new URL/search."
  (interactive)
  (let* ((choice
          (consult--multi
           '(consult--glide-windows
             consult--source-buku
             consult--glide-personal-history
             consult--glide-senzo-history
             consult--glide-siddiqua-history
             consult--glide-brandjet-history)
           :prompt "Glide: "
           :initial (or initial-query "")
           :default nil
           :history nil
           :sort nil))
         (value (car choice))
         (meta  (cdr choice))
         (name  (plist-get meta :name)))

    (if (not (plist-get meta :match))
        (if (glide--looks-like-url-p value)
            (my-handle-glide-url value)
          (glide-search-keyword value)
          )
      )))


(defun glide--group-header (title)
  (propertize title 'face '(:foreground "cyan" :weight bold)))


(defun glide--window-candidates ()
  "Return list of (display . buffer)"
  (mapcar (lambda (b)
            (cons (format "  %s" (buffer-name b)) b))
          (glide--ewm-list)))


(defun glide--history-candidates (&optional profile)
  (delq nil
        (mapcar
         (lambda (row)
           (let* ((p     (split-string row "\t"))
                  (title (string-trim (or (nth 0 p) "")))
                  (url   (nth 1 p)))
             (when (> (length title) 0)
               (glide--history-candidate title url (or profile "Personal")))))
         (glide--history-query profile))))


(defun my-handle-glide-url (url &optional profile)
  "Prompt for Glide profile and open URL in Glide."
  (let ((profile (or profile (glide--select-profile))))
    (glide--open-url url profile)))

;;; ---- Glide bookmark support ----

(defun glide--lookup-url-by-title (title profile)
  "Look up a URL in PROFILE's places.sqlite that matches TITLE.
Returns the first matching URL, or nil if not found.
TITLE is matched case-insensitively against moz_places.title." 
  (let* ((profile-dir (glide-profile-path profile)))
    (when (and profile-dir (file-directory-p profile-dir))
      (let* ((src-db (expand-file-name "places.sqlite" profile-dir)))
        (when (file-exists-p src-db)
          (let* ((tmp-db (make-temp-file "glide-bookmark-" nil ".sqlite"))
                 (wal (concat src-db "-wal"))
                 (shm (concat src-db "-shm"))
                 (tmp-wal (concat tmp-db "-wal"))
                 (tmp-shm (concat tmp-db "-shm")))
            (copy-file src-db tmp-db t)
            (when (file-exists-p wal) (copy-file wal tmp-wal t))
            (when (file-exists-p shm) (copy-file shm tmp-shm t))
            (let* ((escaped (replace-regexp-in-string "'" "''" title))
                   (sql (format "SELECT p.url FROM moz_places p WHERE p.title LIKE '%%%s%%' AND p.url LIKE 'http%%' ORDER BY p.last_visit_date DESC LIMIT 1;" escaped))
                   (sql-file (make-temp-file "glide-sql-" nil ".sql"))
                   (result (progn
                             (with-temp-file sql-file (insert sql))
                             (with-temp-buffer
                               (call-process "sqlite3" nil t nil (shell-quote-argument tmp-db) (shell-quote-argument sql-file))
                               (buffer-string))))
                   (_ (ignore-errors (delete-file sql-file))))
              (when (> (length (string-trim result)) 0)
                (string-trim result)))))))))

(defun glide-bookmark--ewm-buffer-alive-p (title)
  "Return the EWM buffer for a Glide window with TITLE, or nil." 
  (let ((buf-name (concat "*ewm:" title "*")))
    (get-buffer buf-name)))

(defun glide-bookmark--make-record (&optional _always-create bmk-name)
  "Create a bookmark record for Glide EWM buffers."
  (when (boundp 'ewm-surface-title)
    (let* ((title ewm-surface-title)
           (profile (glide--extract-profile title)))
      `((,(or bmk-name (buffer-name)))
        (handler . glide-bookmark--handler)
        (glide-title . ,title)
        (glide-profile . ,(or profile "Personal"))))))

(defun glide-bookmark--handler (bmk)
  "Jump to a Glide bookmark.
If the EWM buffer still exists, switch to it.
Otherwise, look up the URL in places.sqlite and open it." 
  (let* ((title (bookmark-prop-get bmk 'glide-title))
         (profile (bookmark-prop-get bmk 'glide-profile))
         (buf (glide-bookmark--ewm-buffer-alive-p title)))
    (if buf
        (progn
          (switch-to-buffer buf)
          buf)
      (progn
        (unless title
          (user-error "Glide bookmark '%s' has no title stored" (bookmark-name bmk)))
        (let ((url (glide--lookup-url-by-title (glide--extract-history-title title) profile)))
          (if url
              (progn
                (message "Opening %s in %s..." url profile)
                (glide--open-url url profile)
                (get-buffer-create "*scratch*"))
            (user-error "No URL found in %s's history for title: %s" profile title)))))))

(defun glide-bookmark--setup ()
  "Set up bookmark support for Glide EWM buffers." 
  (when (and (boundp 'ewm-surface-title)
             (string-prefix-p "glide" (or ewm-surface-app "")))
    (make-local-variable 'bookmark-make-record-function)
    (setq bookmark-make-record-function #'glide-bookmark--make-record)))

(add-hook 'ewm-update-title-hook #'glide-bookmark--setup)
(add-hook 'ewm-surface-mode-hook #'glide-bookmark--setup)


;; Glide browser window annotator
(defun glide/marginalia-annotator (cand)
  (let* ((profile (get-text-property 0 'glide-profile cand))
         )
    (marginalia--fields
     ((or profile "") :face 'marginalia-documentation :width 10))))


(add-to-list 'marginalia-annotators
             '(glide glide/marginalia-annotator nil builtin none))

;; ── EWW (Emacs Web Wowser) configuration ───────────────────────────────

(defun eww-rdrview-update-title ()
  "Update `eww-data' :title from the first line of the buffer
(which rdrview prepends as the page title)."
  (when (eq major-mode 'eww-mode)
    (save-excursion
      (goto-char (point-min))
      (when-let ((title (thing-at-point 'line t)))
        (plist-put eww-data :title (string-trim title))))
    (eww--after-page-change)))

(defun my-eww-rename-buffer ()
  "Rename EWW buffers to show the page title."
  (when (eq major-mode 'eww-mode)
    (when-let ((string (or (plist-get eww-data :title)
                           (plist-get eww-data :url))))
      (format "%s *eww*" string))))

(define-minor-mode eww-rdrview-mode
  "Toggle reader view in EWW using `rdrview' (Mozilla Readability C port).
When enabled, EWW pipes page HTML through rdrview for cleaner rendering."
  :lighter " rdrview"
  (if eww-rdrview-mode
      (progn
        (setq eww-retrieve-command '("rdrview" "-T" "title,sitename,body" "-H"))
        (add-hook 'eww-after-render-hook #'eww-rdrview-update-title))
    (progn
      (setq eww-retrieve-command nil)
      (remove-hook 'eww-after-render-hook #'eww-rdrview-update-title))))

(defun eww-rdrview-toggle-and-reload ()
  "Toggle `eww-rdrview-mode' and reload the current EWW page."
  (interactive)
  (if eww-rdrview-mode
      (eww-rdrview-mode -1)
    (eww-rdrview-mode 1))
  (eww-reload))

(setq eww-auto-rename-buffer #'my-eww-rename-buffer)

;; ── EWW display settings ───────────────────────────────────────────────

(setq shr-width 100)
(setq shr-max-width 120)
(setq shr-indentation 4)
(setq shr-use-fonts nil)
(setq shr-max-image-size '(800 . 600))
(setq shr-image-animate t)
(setq eww-search-prefix "https://html.duckduckgo.com/html/?q=")
(setq shr-use-colors nil
      shr-bullet "• "
      shr-folding-mode t)

(provide 'config-browser)
;;; config-browser.el ends here
