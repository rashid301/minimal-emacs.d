;;; worktrunk-activities.el --- One activity per Worktrunk worktree  -*- lexical-binding: t; -*-

;;; Commentary:

;; Glue between `worktrunk' and `activities'.  After a worktree is switched
;; to or created, this opens (or resumes) an activity named after the
;; worktree folder, e.g. "clearcompany.feature-DEV-33054-...".  When the
;; worktree is removed, the matching activity is closed.

;;; Code:

(require 'worktrunk)
(require 'activities)

(defcustom worktrunk-activities-open-function #'dired
  "Function called with the worktree path to populate a new activity.
Its result becomes the activity's default state.  Use `magit-status' to
start on Magit instead (slower on large repos)."
  :type 'function
  :group 'worktrunk)

(defcustom worktrunk-activities-terminal-function
  (and (fboundp 'ghostel-project) #'ghostel-project)
  "Function run in the worktree to start a terminal beside the first buffer.
Called with `default-directory' set to the worktree, in a new window on
the right.  Nil means no terminal."
  :type '(choice (const :tag "None" nil) function)
  :group 'worktrunk)

(defun worktrunk-activities--name (path)
  "Return the activity name for worktree PATH: its folder name."
  (file-name-nondirectory (directory-file-name path)))

(defun worktrunk-activities--create (name path)
  "Create activity NAME for the worktree at PATH in a new tab or frame.
The tab/frame is made first and populated before `activities-define'
runs, so the saved default state already contains the worktree."
  (if (bound-and-true-p activities-tabs-mode)
      (tab-bar-new-tab)
    (select-frame (make-frame)))
  (let ((default-directory path))
    (funcall worktrunk-activities-open-function path)
    (delete-other-windows)
    (when worktrunk-activities-terminal-function
      (select-window (split-window-right))
      ;; Force the terminal into this window instead of letting it pop up.
      (let ((display-buffer-overriding-action
             '(display-buffer-same-window)))
        (funcall worktrunk-activities-terminal-function))
      (select-window (frame-first-window))))
  (activities-define name))

(defun worktrunk-activities-open (path)
  "Open or resume the activity for the worktree at PATH."
  (let* ((path (file-name-as-directory (expand-file-name path)))
         (name (worktrunk-activities--name path))
         (activity (activities-named name)))
    ;; Drop a half-created activity (no saved state) from an earlier failure.
    (when (and activity (null (activities-activity-default activity)))
      (setf activities-activities (map-delete activities-activities name)
            activity nil))
    (if activity
        (activities-resume activity)
      (worktrunk-activities--create name path))))

(defun worktrunk-activities-close (path)
  "Close the activity for the removed worktree at PATH, if there is one."
  (when-let ((activity (activities-named (worktrunk-activities--name path))))
    (when (activities-activity-active-p activity)
      (activities-close activity))
    (setf activities-activities
          (map-delete activities-activities (activities-activity-name activity)))
    (activities--persist)))

;;;; Every project in its own activity

(defun worktrunk-activities--new-container ()
  "Open a new tab (tabs mode) or frame to hold a new activity."
  (if (bound-and-true-p activities-tabs-mode)
      (tab-bar-new-tab)
    (select-frame (make-frame))))

(defun worktrunk-activities--discard-container ()
  "Undo `worktrunk-activities--new-container' after an aborted switch."
  (if (bound-and-true-p activities-tabs-mode)
      (tab-bar-close-tab)
    (delete-frame)))

(defun worktrunk-activities--project-switch (orig dir &rest args)
  "Around advice for `project-switch-project': give each project an activity.
An existing activity for DIR is resumed and the dispatch menu is skipped.
Otherwise a new tab/frame is made, ORIG runs in it, and the result is
saved as the activity's default state.  Aborting the menu (\\[keyboard-quit])
discards the new tab/frame."
  (let* ((name (worktrunk-activities--name (expand-file-name dir)))
         (activity (activities-named name))
         (current (activities-current)))
    (cond
     ;; Already in this project's activity: nothing to switch.
     ((and current (equal name (activities-activity-name current)))
      (apply orig dir args))
     ;; Has saved state: resume it.
     ((and activity (activities-activity-default activity))
      (activities-resume activity))
     ;; New project: fresh tab/frame, run the normal command, then define.
     (t
      (when activity            ; half-created leftover
        (setf activities-activities (map-delete activities-activities name)))
      (worktrunk-activities--new-container)
      (let ((done nil))
        (unwind-protect
            (progn (apply orig dir args)
                   (delete-other-windows)
                   (activities-define name)
                   (setq done t))
          (unless done (worktrunk-activities--discard-container))))))))

;;;###autoload
(define-minor-mode worktrunk-activities-project-mode
  "Open each project chosen with `project-switch-project' in its own activity.
The activity is named after the project folder, so it matches the one
`worktrunk-switch' creates for a worktree."
  :global t
  :group 'worktrunk
  (if worktrunk-activities-project-mode
      (advice-add 'project-switch-project :around
                  #'worktrunk-activities--project-switch)
    (advice-remove 'project-switch-project
                   #'worktrunk-activities--project-switch)))

(add-hook 'worktrunk-after-switch-functions #'worktrunk-activities-open)
(add-hook 'worktrunk-after-remove-functions #'worktrunk-activities-close)

(provide 'worktrunk-activities)
;;; worktrunk-activities.el ends here
