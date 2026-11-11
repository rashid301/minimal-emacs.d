;;; config-wsl.el --- WSL helpers (Windows only)  -*- lexical-binding: t; -*-

;;; Commentary:

;; `my/wsl' opens a WSL shell in a ghostel buffer named after the distro,
;; using `ghostel-exec' to run `wsl.exe' directly as the buffer's process.
;; Loaded from post-init.el only when `system-type' is `windows-nt'.

;;; Code:

(require 'seq)

(declare-function ghostel-exec "ghostel")
(declare-function my/wsl-parse-dir "config-terminal")
(defvar ghostel--process)

(defun my/wsl-distros ()
  "Return the list of installed WSL distro names."
  (with-temp-buffer
    ;; `wsl.exe -l' writes UTF-16LE, so decode it explicitly.
    (let ((coding-system-for-read 'utf-16le-dos))
      (call-process "wsl.exe" nil t nil "-l" "-q"))
    (split-string (buffer-string) "[\r\n\0]+" t
                  (concat "[ \t" (string #xfeff) "]+"))))

(defun my/wsl (&optional new)
  "Open a WSL shell in a ghostel buffer named after the distro.
Uses the distro and directory of the current buffer when it is a WSL
path, otherwise asks for a distro (or takes the only one) and starts in
its home.  Reuses the running `*wsl:DISTRO*' buffer; with prefix NEW
start another."
  (interactive "P")
  (require 'ghostel)
  (let* ((parsed (and (fboundp 'my/wsl-parse-dir)
                      (my/wsl-parse-dir default-directory)))
         (distro (or (nth 0 parsed)
                     (let ((ds (my/wsl-distros)))
                       (if (cdr ds)
                           (completing-read "WSL distro: " ds nil t)
                         (or (car ds) (user-error "No WSL distro found"))))))
         (name (format "*wsl:%s*" distro))
         (old (get-buffer name))
         (live (and old (let ((p (buffer-local-value 'ghostel--process old)))
                          (and p (process-live-p p))))))
    (if (and live (not new))
        (pop-to-buffer old)
      (when (and old (not live)) (kill-buffer old))
      (let ((buf (generate-new-buffer name)))
        ;; ghostel spawns in the buffer's own `default-directory'; wsl.exe
        ;; itself takes the Linux directory through --cd.
        (with-current-buffer buf (setq default-directory (expand-file-name "~/")))
        (ghostel-exec buf "wsl.exe"
                      `("-d" ,distro
                        ,@(and (nth 1 parsed) (list "--user" (nth 1 parsed)))
                        "--cd" ,(or (nth 2 parsed) "~")))
        (pop-to-buffer buf)))))

(provide 'config-wsl)
;;; config-wsl.el ends here
