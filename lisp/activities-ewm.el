;;; activities-ewm.el --- Integrate activities.el with EWM frames  -*- lexical-binding: t; -*-

;;; Commentary:
;; Bridges activities.el with EWM's Wayland frame management.
;;
;; When active, overrides activities--switch and activities-close so
;; that frame creation uses EWM's per-output mechanism, focus goes
;; through the compositor, and frame deletion respects EWM's strip
;; constraints.
;;
;; All requires are lazy -- run only when the mode is activated.

;;; Code:

(require 'cl-lib)

(declare-function ewm--focused-frame "ewm" ())
(declare-function ewm--assign-surface-to-frame "ewm" (id output))
(declare-function ewm--create-frame-for-output "ewm" (output-name &optional after-frame extra-params))
(declare-function ewm--strip-frames "ewm" (output))
(declare-function ewm-prepare-frame-close-module "ewm" (id))
(declare-function ewm-workspace-rename "ewm" (name &optional frame))

;;;; Mode

;;;###autoload
(define-minor-mode activities-ewm-mode
  "Integrate Activities with EWM's Wayland frame management.
Disables `activities-tabs-mode' and manages activities as
EWM-bound frames instead of tab-bar tabs."
  :global t
  :group 'activities
  (if activities-ewm-mode
      (activities-ewm--activate)
    (activities-ewm--deactivate)))

(defun activities-ewm--activate ()
  (require 'activities)
  (require 'ewm)
  (require 'ewm-layout)
  (activities-tabs-mode -1)
  (setopt activities-resume-into-frame 'current)
  (advice-add 'activities--switch :override #'activities-ewm--switch)
  (advice-add 'activities-close   :override #'activities-ewm-close)
  (advice-add 'ewm--assign-surface-to-frame :filter-return #'activities-ewm--after-surface-assigned))

(defun activities-ewm--deactivate ()
  (advice-remove 'activities--switch #'activities-ewm--switch)
  (advice-remove 'activities-close   #'activities-ewm-close)
  (advice-remove 'ewm--assign-surface-to-frame #'activities-ewm--after-surface-assigned))

;;;; Overrides

(defun activities-ewm--switch (activity)
  "Switch to ACTIVITY using EWM frame management."
  (if-let ((frame (activities--frame activity)))
      (progn
        (select-frame frame)
        (unless activities-saving-p
          (activities-ewm--focus-frame frame activity)))
    (let* ((eframe (ewm--focused-frame))
           (frame (ewm--create-frame-for-output
                   (frame-parameter eframe 'ewm-output) eframe
                   `((activity . ,activity)
                     (ewm-focus-on-create . t)))))
      (select-frame frame)
      (activities-ewm--name-frame eframe activity)
      (activities--set activity)))
  )

(defun activities-ewm-close (activity)
  "Close ACTIVITY respecting EWM per-output strip constraints."
  (activities--switch activity)
  (activities--kill-buffers)
  (let* ((frame (selected-frame))
         (output (frame-parameter frame 'ewm-output))
         (alone (and output
                     (<= (length (ewm--strip-frames output)) 1))))
    (if alone
        (progn
          (set-frame-parameter frame 'activity nil)
          (activities-ewm--name-frame frame nil))
      (when-let ((id (frame-parameter frame 'ewm-surface-id)))
        (ewm-prepare-frame-close-module id))
      (delete-frame frame 'force))))

;;;; Frame helpers

(defun activities-ewm--focus-frame (frame activity)
  "Focus FRAME via compositor."
  (if (frame-parameter frame 'ewm-surface-id)
      (select-frame-set-input-focus frame)
    (select-frame frame))
  (activities-ewm--name-frame frame activity))

(defun activities-ewm--name-frame (frame activity)
  "Set FRAME's display name.
Uses `activities-name-for' when ACTIVITY is non-nil, clears it
otherwise."
  (when frame
    (set-frame-name (if activity
                        (activities-name-for activity)
                      ""))))

(defun activities-ewm--after-surface-assigned (frame)
  "Rename FRAME's activity workspace when its surface is assigned.
Intended as `:filter-return' advice on `ewm--assign-surface-to-frame'."
  (when (frame-live-p frame)
    (when-let ((activity (frame-parameter frame 'activity)))
      (ewm-workspace-rename (activities-name-for activity) frame)))
  frame)

(defun activities-ewm--rename-workspace (activity)
  "Rename ACTIVITY's frame workspace to match the activity name.
Only renames when the frame already has a surface ID — for new
frames the rename happens via `activities-ewm--after-surface-assigned'."
  (when-let ((frame (activities--frame activity))
             ((frame-parameter frame 'ewm-surface-id)))
    (ewm-workspace-rename (activities-name-for activity) frame)))

(provide 'activities-ewm)
;;; activities-ewm.el ends here
