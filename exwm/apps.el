;;; apps.el --- tiny .desktop app launcher for EXWM  -*- lexical-binding: t; -*-
;; M-x my/exwm-launch-app : pick an application by name (completing-read, so
;; vertico/consult/orderless apply) and run its Exec line.

(defvar my/desktop-app-dirs
  '("/usr/share/applications"
    "/usr/local/share/applications"
    "~/.local/share/applications"))

(defun my/desktop--field (key)
  "Value of KEY in the current buffer's [Desktop Entry] group, or nil."
  (goto-char (point-min))
  (when (re-search-forward "^\\[Desktop Entry\\][ \t]*$" nil t)
    (let ((end (save-excursion
                 (if (re-search-forward "^\\[" nil t) (match-beginning 0) (point-max)))))
      (when (re-search-forward (format "^%s=\\(.*\\)$" (regexp-quote key)) end t)
        (string-trim (match-string 1))))))

(defun my/desktop-apps ()
  "Return an alist (NAME . COMMAND) for visible graphical .desktop applications."
  (let (apps)
    (dolist (dir my/desktop-app-dirs)
      (setq dir (expand-file-name dir))
      (when (file-directory-p dir)
        (dolist (f (directory-files dir t "\\.desktop\\'"))
          (with-temp-buffer
            (insert-file-contents f)
            (let ((name (my/desktop--field "Name"))
                  (exec (my/desktop--field "Exec"))
                  (hidden (or (equal (my/desktop--field "NoDisplay") "true")
                              (equal (my/desktop--field "Hidden") "true")
                              (equal (my/desktop--field "Terminal") "true")
                              (not (member (my/desktop--field "Type") '(nil "Application"))))))
              (when (and name exec (not hidden) (not (assoc name apps)))
                ;; drop field codes (%U %f ...), keep a literal %%
                (setq exec (replace-regexp-in-string "%%" "\0" exec))
                (setq exec (replace-regexp-in-string "%[a-zA-Z]" "" exec))
                (setq exec (string-trim (replace-regexp-in-string "\0" "%" exec)))
                (push (cons name exec) apps)))))))
    (sort apps (lambda (a b) (string-lessp (downcase (car a)) (downcase (car b)))))))

(defun my/exwm-launch-app ()
  "Choose a desktop application by name and start it."
  (interactive)
  (let* ((apps (my/desktop-apps))
         (name (completing-read "Run app: " (mapcar #'car apps) nil t))
         (cmd (cdr (assoc name apps))))
    (when cmd
      (start-process-shell-command name nil cmd))))
