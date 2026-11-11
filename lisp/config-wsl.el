;;; config-wsl.el --- WSL helpers (Windows only)  -*- lexical-binding: t; -*-

;;; Commentary:

;; All WSL configuration, loaded from post-init.el only when `system-type'
;; is `windows-nt':
;;
;; - `my/wsl-parse-dir' recognizes WSL directories (/wsl:DISTRO:/path and
;;   //wsl$/DISTRO/path).
;; - An advice on `ghostel--start-process' makes a plain `ghostel' in such a
;;   directory run `wsl.exe' locally (no Tramp).
;; - `my/wsl' opens a WSL shell in a ghostel buffer named after the distro,
;;   using `ghostel-exec' to run `wsl.exe' directly as the buffer's process.

;;; Code:

(require 'seq)

(declare-function ghostel-exec "ghostel")
(defvar ghostel--process)
(defvar ghostel-shell)  ; special, so the `let' in the advice binds it dynamically

;; WSL directories: don't go through Tramp.  Tramp over wsl.exe gives the
;; remote shell no tty and no way to resize it, which breaks ghostel.
;; Instead start an ordinary local terminal that runs
;;   wsl.exe -d DISTRO --cd LINUX-PATH
;; so the pty is a local ConPTY and WSL's own default shell (zsh) starts
;; in the folder.  Handles /wsl:DISTRO:/path and //wsl$/DISTRO/path
;; (also //wsl.localhost/DISTRO/path).
(defun my/wsl-parse-dir (dir)
  "Return (DISTRO USER LINUX-PATH) if DIR is a WSL directory, else nil."
  (cond
   ((and dir (string-match "\\`/wsl:\\(?:\\([^@:/]+\\)@\\)?\\([^:/]+\\):\\(.*\\)\\'" dir))
    (list (match-string 2 dir) (match-string 1 dir)
          (let ((p (match-string 3 dir))) (if (string-empty-p p) "~" p))))
   ((and dir (string-match "\\`//wsl\\(?:\\$\\|\\.localhost\\)/\\([^/]+\\)\\(/.*\\)?\\'" dir))
    (list (match-string 1 dir) nil (or (match-string 2 dir) "/")))))

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
  (let* ((parsed (my/wsl-parse-dir default-directory))
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

;; Plain `ghostel' in a WSL directory: start a local terminal running
;; `wsl.exe' there instead of going through Tramp.
(with-eval-after-load 'ghostel
  (define-advice ghostel--start-process (:around (orig &rest args) my/wsl)
    (if-let* ((w (my/wsl-parse-dir default-directory)))
        (let ((default-directory (expand-file-name "~/"))
              (ghostel-shell `("wsl.exe" "-d" ,(nth 0 w)
                               ,@(and (nth 1 w) (list "--user" (nth 1 w)))
                               "--cd" ,(nth 2 w))))
          (apply orig args))
      (apply orig args))))

(provide 'config-wsl)
;;; config-wsl.el ends here
