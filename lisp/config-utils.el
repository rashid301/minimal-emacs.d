(defun my/pdf-decrypt ()
  "Create an unencrypted copy of the current PDF using qpdf."
  (interactive)
  (unless (and (buffer-file-name)
               (string-match-p "\\.pdf\\'" (buffer-file-name)))
    (user-error "Current buffer is not visiting a PDF"))

  (let* ((input (buffer-file-name))
         (output (concat (file-name-sans-extension input)
                         "-decrypted.pdf"))
         (password (read-passwd "PDF password: "))
         (buf (get-buffer-create "*qpdf*")))
    (with-current-buffer buf
      (erase-buffer))
    (let ((status
           (call-process
            "qpdf" nil buf t
            (format "--password=%s" password)
            "--decrypt"
            input
            output)))
      (cond
       ((memq status '(0 3))
        (when (= status 3)
          (display-buffer buf))
        (message "Saved: %s" output)
        (find-file output))
       (t
        (display-buffer buf)
        (error "qpdf failed (exit %d)" status))))))



;; Full config reload (like Doom's `SPC h R`)
(defun my/copy-file-path ()
  "Copy the full file path of the current buffer to the kill ring."
  (interactive)
  (if buffer-file-name
      (progn
        (kill-new buffer-file-name)
        (message "Copied: %s" buffer-file-name))
    (message "Current buffer is not visiting a file")))

(defun my/config-reload ()
  "Reload post-init.el without restarting Emacs."
  (interactive)
  (let* ((config-dir (expand-file-name "~/.config/emacs/"))
         (post-init (expand-file-name "post-init.el" config-dir)))
    (message "Reloading configuration...")
    (when (file-exists-p post-init)
      (load-file post-init))
    (message "Configuration reloaded.")))

;; Journal directory
(defvar my/journal-dir (expand-file-name "~/notes/journal/")
  "Directory for daily journal files.")
(unless (file-exists-p my/journal-dir)
  (make-directory my/journal-dir t))

;; Taskwarrior GTD
(use-package taskwarrior-gtd
  :load-path "lisp/")

;; affects dotfiles repo config files
(setq find-file-visit-truename nil
      vc-follow-symlinks nil)

(defun my/dotfiles ()
  (interactive)
  (find-file "~/dotfiles"))

(use-package markdown-mermaid
  :ensure t
  :after markdown-mode
  :config
  ;; Automatically match diagram background colors to your active Emacs theme
  (setq markdown-mermaid-theme "default")) 



(defun my/show-in-sidebar (buffer side)
  "Display BUFFER in a reusable SIDE window (left or right).
BUFFER may be a buffer object or a buffer name (string)."
  (when buffer
    ;; normalize buffer arg → real live buffer or nil
    (setq buffer (cond
                  ((bufferp buffer) (and (buffer-live-p buffer) buffer))
                  ((stringp buffer) (get-buffer buffer))
                  (t nil)))
    ;; if buffer is dead or missing — bail safely
    (unless (buffer-live-p buffer)
      (message "Sidebar: buffer %S not live" buffer)
      (cl-return-from my/show-in-sidebar nil)))

  (let* ((win (get-window-with-predicate
               (lambda (w)
                 (eq (window-parameter w 'window-side) side)))))

    ;; If no existing side window, create one
    (unless win
      (setq win
            (display-buffer
             buffer
             `((display-buffer-in-side-window
                display-buffer-reuse-window)
               (side . ,side)
               (slot . 0)
               (modeline . t)
               (window-width . 0.25)))))

    ;; display-buffer sometimes returns (win . alist)
    (when (listp win) (setq win (car win)))

    ;; make final safety check
    (unless (window-live-p win)
      (message "Sidebar: could not get/create window for %S" buffer)
      (cl-return-from my/show-in-sidebar nil))

    ;; focus & show buffer
    (when (and buffer (buffer-live-p buffer))
      (message "move buffer")
      (with-selected-window win
        ;; EXWM is optional — call only if available + buffer exists
        (when (and (fboundp 'exwm-workspace-switch-to-buffer)
                   (buffer-live-p buffer))
          (message "workspace buffer")
          (exwm-workspace-switch-to-buffer buffer))
        ))

    win))

(defun my/toggle-sidebar (side prev)
  "Toggle the left sidebar."
  (let ((win (get-window-with-predicate
              (lambda (w)
                (eq (window-parameter w 'window-side) side)))))
    (if win
        (delete-window win)
      (my/show-in-sidebar (or prev (current-buffer)) side))))

(defun my/toggle-left-sidebar ()
  "Toggle the left sidebar."
  (interactive)
  (my/toggle-sidebar  'left (my/sidebar--get :left)))

(defun my/toggle-right-sidebar ()
  "Toggle the left sidebar."
  (interactive)
  (my/toggle-sidebar  'right (my/sidebar--get :right)))

(defun my/sidebar--state ()
  "Return the frame-local sidebar state plist, creating it if needed."
  (or (frame-parameter nil 'my/sidebar-state)
      (let ((state (list :left nil :right nil)))
        (set-frame-parameter nil 'my/sidebar-state state)
        state)))

(defun my/sidebar--get (side)
  (plist-get (my/sidebar--state) side))

(defun my/sidebar--set (side buffer)
  (let ((state (my/sidebar--state)))
    (plist-put state side buffer)
    (set-frame-parameter nil 'my/sidebar-state state)))

;; 1. Increase max allowed slots per side (Top Bottom Left Right)
;;(setq window-sides-slots '(2 2 2 2))

;; 2. Core function to send the current buffer to a specific side and slot
(defun my/send-buffer-to-side-slot (side slot &optional size)
  "Send the current buffer to a specific SIDE and SLOT."
  (let ((buf (current-buffer))
        ;; Left/right get both width and height;
        ;; height is fixed per slot (-1 -> 0.25, else 0.75)
        (size-param-list
         (cond ((memq side '(left right))
                `((window-width . ,(or size 0.25))
                  (window-height . ,(if (= slot -1) 0.25 0.75))))
               (t `(window-height . ,(or size 0.25))))))
    ;; Display the buffer using the side window action
    (display-buffer buf
                    `(display-buffer-in-side-window
                      (side . ,side)
                      (slot . ,slot)
                      ,size-param-list))))

;; 3. Helper functions for the 4 specific slots
(defun my/send-to-left-top ()
  "Send current buffer to Left Side, Top Slot."
  (interactive) (my/send-buffer-to-side-slot 'left -1))

(defun my/send-to-left-bottom ()
  "Send current buffer to Left Side, Bottom Slot."
  (interactive) (my/send-buffer-to-side-slot 'left 1))

(defun my/send-to-right-top ()
  "Send current buffer to Right Side, Top Slot."
  (interactive) (my/send-buffer-to-side-slot 'right -1))

(defun my/send-to-right-bottom ()
  "Send current buffer to Right Side, Bottom Slot."
  (interactive) (my/send-buffer-to-side-slot 'right 1))

;; 4. Interactive Consult List Selection
(defun my/consult-send-to-side-slot ()
  "Select a side-window destination using Consult and send the current buffer there."
  (interactive)
  (unless (fboundp 'consult--read)
    (user-error "The `consult` package is required for this function"))
  
  (let* ((options '(("Left Side - Top Slot"    . my/send-to-left-top)
                    ("Left Side - Bottom Slot" . my/send-to-left-bottom)
                    ("Right Side - Top Slot"   . my/send-to-right-top)
                    ("Right Side - Bottom Slot" . my/send-to-right-bottom)))
         (choice (consult--read
                  options
                  :prompt "Send current buffer to side slot: "
                  :category 'side-slot-move
                  :sort nil)))
    ;; Execute the corresponding function chosen from the list
    (command-execute (cdr (assoc choice options)))))

;; 5. Keybindings (Using general.el or standard Emacs)
;; If you use Evil/General (Common for SPC leader layouts):

(define-key evil-window-map (kbd "s") #'my/consult-send-to-side-slot) 
(define-key evil-window-map (kbd "l") #'my/toggle-left-sidebar) 
(define-key evil-window-map (kbd "r") #'my/toggle-right-sidebar) 
