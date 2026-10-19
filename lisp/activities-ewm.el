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
(require 'map)
(require 'activities)

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
  (advice-add 'ewm--assign-surface-to-frame :filter-return #'activities-ewm--after-surface-assigned)
  (advice-add 'activities-switch-buffer :override #'activities-ewm--switch-buffer)
  (advice-add 'activities-state :filter-return #'activities-ewm--save-buffer-list-advice)
  (add-hook 'activities-after-resume-functions #'activities-ewm--restore-buffer-list)
  )

(defun activities-ewm--deactivate ()
  (advice-remove 'activities--switch #'activities-ewm--switch)
  (advice-remove 'activities-close   #'activities-ewm-close)
  (advice-remove 'ewm--assign-surface-to-frame #'activities-ewm--after-surface-assigned)
  (advice-remove 'activities-switch-buffer #'activities-ewm--switch-buffer)
  (advice-remove 'activities-state #'activities-ewm--save-buffer-list-advice)
  (remove-hook 'activities-after-resume-functions #'activities-ewm--restore-buffer-list))

;;;; Switch buffer

(defun activities-ewm--switch-buffer (activity)
  "Switch to a buffer associated with ACTIVITY.
Interactively, select from buffers associated with ACTIVITY; or,
with prefix argument, choose another activity."
  (interactive
   (list (if current-prefix-arg
             (activities-completing-read)
           (or (activities-current) (activities-completing-read)))))
  (let* ((frame (activities--frame activity))
         (activity-buffer-names (when frame
                                  (mapcar #'buffer-name
                                          (frame-parameter frame 'buffer-list))))
         (current-buffer-name (buffer-name (current-buffer)))
         (rbts-completion-table
          (apply-partially
           #'completion-table-with-predicate
           #'internal-complete-buffer
           (lambda (buffer-name)
             (let ((buffer-name (if (consp buffer-name) (car buffer-name) buffer-name)))
               (and (not (equal buffer-name current-buffer-name))
                    (cl-member buffer-name activity-buffer-names))))
           nil))
         (selected-buffer
          (minibuffer-with-setup-hook
              (lambda ()
                (setq-local minibuffer-completion-table rbts-completion-table))
            (read-buffer "Switch to activity buffer:" (other-buffer (current-buffer))
                         (confirm-nonexistent-file-or-buffer)))))
    (when frame
      (select-frame frame))
    (switch-to-buffer selected-buffer)))

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
                     (ewm-focus-on-create . t)
                     (buffer-predicate . my/activity-buffer-p)
                     ))))
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

;;;; Buffer list persistence

;; (defun activities-ewm--save-buffer-list-advice (state)
;;   "Save the current frame's buffer list into STATE's etc property.
;; Intended as :filter-return advice on `activities-state'."
;;   (when-let* ((frame (selected-frame))
;;               (buffer-list (frame-parameter frame 'buffer-list))
;;               (buffer-structs (delq nil (mapcar #'activities-ewm--serialize-buffer buffer-list)))
;;               )
;;     (setf (map-elt (activities-activity-state-etc state) 'activities-ewm-buffer-list)
;;           buffer-structs))
;;   state)

(defun activities-ewm--save-buffer-list-advice (state)
  "Save buffer list into STATE's etc slot."
  (when-let* ((frame (selected-frame))
              (buffer-list (frame-parameter frame 'buffer-list))
              (buffer-structs (delq nil (mapcar #'activities-ewm--serialize-buffer buffer-list))))
    (setf (alist-get 'activities-ewm-buffer-list (activities-activity-state-etc state))
          buffer-structs))
  state)

(defun activities-ewm--restore-buffer-list (activity)
  "Restore buffers from ACTIVITY's saved buffer list."
  (when-let* ((frame (activities--frame activity))
              (state (or (activities-activity-last activity)
                         (activities-activity-default activity)))
              (buffer-structs (map-elt (activities-activity-state-etc state) 'activities-ewm-buffer-list)))
    (dolist (struct buffer-structs)
      (condition-case err
          (when-let ((buf (activities--deserialize struct)))
            ;; Add to frame's buffer-list parameter
            (set-frame-parameter frame 'buffer-list
                                 (cons buf (frame-parameter frame 'buffer-list))))
        (error (message "activities-ewm: Failed to restore buffer: %S" err))))))

(defun activities-ewm--serialize-buffer (buffer)
  "Serialize BUFFER to an activities-buffer struct.
Returns nil if the buffer cannot be serialized."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (condition-case nil
          (make-activities-buffer
           :bookmark (bookmark-make-record)
           :filename (buffer-file-name buffer)
           :name (buffer-name buffer)
           :etc `((indirectp . ,(not (not (buffer-base-buffer buffer))))
                  (narrowedp . ,(buffer-narrowed-p)))
           :local-variables
           (when (bound-and-true-p activities-buffer-local-variables)
             (cl-loop for variable in activities-buffer-local-variables
                      when (buffer-local-boundp variable (current-buffer))
                      collect (cons variable (buffer-local-value variable (current-buffer))))))
        (error nil)))))

;;;; Commands

(defun activities-ewm-remove-buffer-from-activity ()
  "Remove current buffer from the current activity's buffer list and switch to previous."
  (interactive)
  (if-let* ((activity (activities-current))
            (frame (activities--frame activity))
            (buf (current-buffer))
            (buffer-list (frame-parameter frame 'buffer-list)))
      (progn
        (set-frame-parameter frame 'buffer-list (delq buf buffer-list))
        (switch-to-prev-buffer)
        (message "Removed %s from activity %s" (buffer-name buf) (activities-name-for activity)))
    (user-error "No current activity or buffer")))

(provide 'activities-ewm)
;;; activities-ewm.el ends here
