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


(defvar glide--history-cache '()
  "Cache of history queries: list of (PROFILE . (MTIMES . ROWS)).
MTIMES is the pair of modification times of places.sqlite and its
-wal file at query time; rows are reused until either file changes.")

(defun glide--db-mtimes (src-db)
  "Return (DB-MTIME . WAL-MTIME) for SRC-DB, or nil if the DB is missing."
  (when (file-exists-p src-db)
    (cons (nth 5 (file-attributes src-db))
          (let ((wal (concat src-db "-wal")))
            (if (file-exists-p wal)
                (nth 5 (file-attributes wal))
              0)))))

(defun glide--history-query--live (src-db)
  "Query SRC-DB for the 500 most recent http(s) history rows."
  (let ((sql
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
    ;; Query the live DB read-only. immutable=1 lets us bypass the WAL lock
    ;; held (or left stale) by a running Glide; we may miss very recent
    ;; uncheckpointed history.
    (split-string
     (shell-command-to-string
      (format "sqlite3 -separator '\t' 'file:%s?mode=ro&immutable=1' \"%s\""
              src-db
              sql))
     "\n" t)))

(defun glide--history-query (&optional profile)
  "Return browser history rows: title<TAB>url<TAB>last_visit.
Results are cached per profile and reused while places.sqlite (and its
-wal file) are unmodified. Returns nil if the profile or DB is missing."
  (let* ((profile (or profile "Personal"))
         (profile-dir (glide-profile-path profile)))
    (when (and profile-dir
               (file-directory-p profile-dir))
      (let* ((src-db (expand-file-name "places.sqlite" profile-dir))
             (mtimes (glide--db-mtimes src-db)))
        (when mtimes
          (let* ((entry (assoc-string profile glide--history-cache))
                 (cached-rows (and entry (cddr entry))))
            (if (equal mtimes (cdr entry))
                cached-rows
              (let ((rows (glide--history-query--live src-db)))
                (setq glide--history-cache
                      (cons (cons profile (cons mtimes rows))
                            (remq profile glide--history-cache)))
                rows))))))))


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


(defun glide--ewm-list ()
  "List EWM buffers that belong to Glide Browser."
  (require 'ewm)
  (cl-remove-if-not
   (lambda (buf)
     (with-current-buffer buf
       (string-prefix-p "glide" (or ewm-surface-app ""))))
   (hash-table-values ewm--surfaces)))


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
     (truncate-string-to-width title 50 0 nil t)
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


(require 'cl-lib)

(defun glide-launcher (&optional initial-query)
  "Unified launcher: open Glide windows, browser history, or new URL/search."
  (interactive)
  (let* (
         (choice
          (consult--multi
           `((:name "Current URL"
                    :items (lambda ()
                             (list (or (and (bound-and-true-p glide-url)
                                            (not (string-empty-p glide-url))
                                            glide-url)
                                       ""))))
             consult--glide-windows
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

(defun glide--sql-literal (s)
  "Return a safe SQL string literal for S (embedded quotes escaped)."
  (concat "'" (replace-regexp-in-string "'" "''" s) "'"))

(defun glide--lookup-url-by-title (title profile &optional days)
  "Look up a URL in PROFILE's places.sqlite that matches TITLE.
Returns the most recently visited matching URL, or nil if not found.
TITLE is matched case-insensitively against moz_places.title.
DAYS bounds the scan to the last N days (default 90) so the LIKE
query stays fast as history grows." 
  (let* ((profile-dir (glide-profile-path profile)))
    (when (and profile-dir (file-directory-p profile-dir))
      (let* ((src-db (expand-file-name "places.sqlite" profile-dir)))
        (when (file-exists-p src-db)
          ;; Escape LIKE wildcards in the title so they match literally
          (let* ((like-escaped (replace-regexp-in-string "[\\%_]" "\\\\&" title))
                 (cutoff-us (* (or days 90) 86400000000)) ; microseconds
                 (esc-char (char-to-string #o47)) ; backslash as escape char
                 (sql (format "SELECT p.url FROM moz_places p\nWHERE p.title LIKE '%%%s%%' ESCAPE '%s'\n  AND p.url LIKE 'http%%'\n  AND p.last_visit_date > (strftime('%%s','now')*1000000 - %d)\nORDER BY p.last_visit_date DESC LIMIT 1;"
                              like-escaped esc-char cutoff-us)))
            ;; Query the live DB read-only (immutable=1 bypasses WAL lock)
            (let ((result
                   (with-temp-buffer
                     (call-process "sqlite3" nil t nil
                                   (concat "file:" src-db "?mode=ro&immutable=1") sql)
                     (buffer-string))))
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
              (message "Opening %s in %s..." url profile)
              (glide--open-url url profile)
              (get-buffer-create "*scratch*"))
          (user-error "No URL found in %s's history for title: %s" profile title))))))

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
  (let* (
         (profile (get-text-property 0 'glide-profile cand))
         (domain (get-text-property 0 'glide-domain cand))
         )
    (marginalia--fields
     ((or profile "") :face 'marginalia-type :width 10)
     ((or domain "") :face 'marginalia-documentation :width 30)
     )))


(add-to-list 'marginalia-annotators
             '(glide glide/marginalia-annotator nil builtin none))


(when (fboundp 'consult-buffer)
  (add-to-list 'consult-bookmark-narrow `(?b "Browser" glide-bookmark--handler))
  )
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

;; ── firefox settings ───────────────────────────────────────────────

(defun my/firefox-copy-url()
  (interactive)
  (evil-echo "wtype")
  ;; send yy to glide browser
  (start-process-shell-command
   "wtype " nil "wtype -s 350 yy"
   ))


(defun glide-get-url ()
  "Return the current Glide URL for this buffer.
If the buffer-local `glide-url' (set by Glide's UrlEnter autocmd) is
bound, return it. Otherwise fall back to yanking the URL from the
browser via wtype and reading the kill-ring."
  (interactive)
  (if glide-url
      glide-url
    (progn
      (my/firefox-copy-url)
      (sleep-for 0.05)
      (let ((url (current-kill 0)))
        (unless (and url (string-match-p "\\`https?://" url))
          (user-error "Could not retrieve URL from kill-ring"))
        url))))


;; Glide -> Emacs mode sync entry point.
;; Called from glide.ts via: emacsclient -e '(glide-mode-changed "old" "new")'
(defvar-local glide-url nil
  "Current URL of the Glide tab shown in this buffer.\nSet by `glide-url-enter' from a Glide UrlEnter autocmd.")

(defvar-local glide-profile nil
  "Friendly name of the Glide profile for this buffer (e.g. \"Personal\").\nSet by `glide-set-profile' from a Glide WindowLoaded autocmd.")


(defun glide--profile-name-from-dir (dir)
  "Return the friendly profile name for profile directory DIR, or nil."
  (let ((found nil))
    (dolist (p glide-profile-alist)
      (when (string= (cdr p) dir)
        (setq found (car p))))
    found))

(defun glide-url-enter (url)
  "Set `glide-url' in the selected window's buffer. Called from glide.ts."
  (with-current-buffer (window-buffer)
    (setq glide-url url)))

(defun glide-set-profile (profile-dir)
  "Set `glide-profile' in the selected window's buffer. Called from glide.ts."
  (with-current-buffer (window-buffer)
    (setq glide-profile (glide--profile-name-from-dir profile-dir))))

(defun glide-mode-changed (old-mode new-mode)
  "Sync evil state in the selected window's buffer from a Glide mode change.\nCalled from glide.ts via: emacsclient -e '(glide-mode-changed \"old\" \"new\")'"
  (with-current-buffer (window-buffer)
    (cond ((string= new-mode "insert") (evil-insert-state))
          ((string= new-mode "normal") (evil-normal-state)))))


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

(provide 'config-browser)
;;; config-browser.el ends here
