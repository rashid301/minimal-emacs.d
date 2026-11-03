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
    (delete-other-windows))
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

(add-hook 'worktrunk-after-switch-functions #'worktrunk-activities-open)
(add-hook 'worktrunk-after-remove-functions #'worktrunk-activities-close)

(provide 'worktrunk-activities)
;;; worktrunk-activities.el ends here
