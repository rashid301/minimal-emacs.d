;;; ghostel-claude.el --- Claude Code in a project ghostel buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-claude' runs `claude' as the process of a ghostel buffer
;; (via `ghostel-exec') in the current project's root.
;;
;;   M-x ghostel-claude        bring back this project's Claude (start it if
;;                             none is running).  Works from any buffer, so
;;                             after switching away just call it again.
;;   C-u M-x ghostel-claude    start another Claude for the project.
;;   M-x ghostel-claude-switch pick among the project's Claude buffers.
;;
;; Buffers are named *claude:PROJECT* (then *claude:PROJECT*<2>, ...).
;; When Claude exits, the buffer is killed (ghostel's default), so the next
;; call starts a fresh one.  Local directories only.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function ghostel-exec "ghostel")
(defvar ghostel--process)

(defcustom ghostel-claude-program "claude"
  "Program that starts Claude Code."
  :type 'string
  :group 'ghostel)

(defcustom ghostel-claude-args nil
  "Extra arguments passed to `ghostel-claude-program'."
  :type '(repeat string)
  :group 'ghostel)

(defcustom ghostel-claude-display-action
  '(display-buffer-in-side-window (side . right) (window-width . 0.4))
  "Display action used to show a Claude buffer."
  :type 'sexp
  :group 'ghostel)

(defun ghostel-claude--root ()
  "Return the current project root, or `default-directory'."
  (if-let* ((pr (project-current)))
      (expand-file-name (project-root pr))
    (expand-file-name default-directory)))

(defun ghostel-claude--prefix (root)
  "Return the buffer-name prefix for project ROOT."
  (format "*claude:%s*" (file-name-nondirectory (directory-file-name root))))

(defun ghostel-claude--live-p (buffer)
  "Return non-nil if BUFFER has a live ghostel process."
  (and (buffer-live-p buffer)
       (let ((p (buffer-local-value 'ghostel--process buffer)))
         (and p (process-live-p p)))))

(defun ghostel-claude--buffers (root)
  "Return live Claude buffers for ROOT, most recently used first."
  (let ((prefix (ghostel-claude--prefix root)))
    (seq-filter (lambda (b)
                  (and (string-prefix-p prefix (buffer-name b))
                       (ghostel-claude--live-p b)))
                (buffer-list))))

(defun ghostel-claude--start (root)
  "Start a new Claude buffer for ROOT and return it."
  (require 'ghostel)
  (let ((buf (generate-new-buffer (ghostel-claude--prefix root))))
    ;; ghostel spawns in the buffer's own `default-directory'.
    (with-current-buffer buf (setq default-directory root))
    (condition-case err
        (ghostel-exec buf ghostel-claude-program ghostel-claude-args)
      (error (kill-buffer buf) (signal (car err) (cdr err))))
    buf))

(defun ghostel-claude--show (buffer)
  "Display BUFFER with `ghostel-claude-display-action' and select it."
  (when-let* ((win (display-buffer buffer ghostel-claude-display-action)))
    (select-window win)))

;;;###autoload
(defun ghostel-claude (&optional new)
  "Bring up Claude Code for the current project in a ghostel buffer.
Show and select the project's most recent running Claude, or start one if
there is none.  With prefix argument NEW, start an additional Claude."
  (interactive "P")
  (let* ((root (ghostel-claude--root))
         (bufs (ghostel-claude--buffers root)))
    (ghostel-claude--show
     (if (and bufs (not new))
         (car bufs)
       (ghostel-claude--start root)))))

;;;###autoload
(defun ghostel-claude-switch ()
  "Show one of the current project's Claude buffers, chosen by name."
  (interactive)
  (let ((bufs (ghostel-claude--buffers (ghostel-claude--root))))
    (unless bufs (user-error "No Claude running for this project"))
    (ghostel-claude--show
     (get-buffer (completing-read "Claude: " (mapcar #'buffer-name bufs) nil t)))))

(provide 'ghostel-claude)
;;; ghostel-claude.el ends here
