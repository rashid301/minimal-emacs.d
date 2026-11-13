;;; dpi.el --- switch the display DPI live (external monitor 96 <-> laptop 144)  -*- lexical-binding: t; -*-

;;; Commentary:

;; X11 apps in Xephyr get no Windows scaling, so DPI is set by hand.  One command
;; changes it everywhere:
;;  - Emacs + GTK/Qt apps: via EXWM's XSETTINGS manager, immediately (tested: Emacs
;;    resizes its fonts live when Xft/DPI changes).
;;  - xterm & other X-resource apps: `xrdb' Xft.dpi, for newly started apps.
;;  - Firefox: follows Xft.dpi itself; devPixelsPerPx is pinned to -1 (automatic) since an explicit value double-scales.
;;  - The choice is saved in ~/exwm-test/dpi, which start.sh and keepkeys.sh read.
;;
;;   s-=            toggle 96 <-> 144
;;   M-x my/exwm-set-dpi   pick any value

;;; Code:

(defvar my/exwm-dpi-file (expand-file-name "~/exwm-test/dpi"))
(defvar my/exwm-dpi
  (let ((v (getenv "XFT_DPI"))) (if v (string-to-number v) 144))
  "Current display DPI.")

(defun my/exwm-xsettings-for (dpi)
  "The `exwm-xsettings' alist for DPI (XSETTINGS stores DPI in 1024ths)."
  `(("Xft/DPI" . ,(* dpi 1024))
    ("Xft/Antialias" . 1)
    ("Xft/Hinting" . 1)
    ("Xft/HintStyle" . "hintslight")))

(defun my/exwm--set-xrdb-dpi (dpi)
  (with-temp-buffer
    (insert (format "Xft.dpi: %d\nXTerm*faceName: Iosevka Nerd Font Mono\nXTerm*faceSize: 11\nUXTerm*faceName: Iosevka Nerd Font Mono\nUXTerm*faceSize: 11\n" dpi))
    (call-process-region (point-min) (point-max) "xrdb" nil nil nil "-merge")))

(defun my/exwm--set-firefox-scale (dpi)
  "Keep Firefox's devPixelsPerPx at its automatic default (-1).
Firefox already scales by Xft.dpi/XSETTINGS; an explicit DPI/96 value double-scales it.  DPI is unused."
  (ignore dpi)
  (let ((val "-1.0"))
    (dolist (d (file-expand-wildcards
                (expand-file-name "~/.config/mozilla/firefox/*.default-release")))
      (let ((f (expand-file-name "user.js" d)))
        (with-temp-buffer
          (when (file-exists-p f) (insert-file-contents f))
          (goto-char (point-min))
          (flush-lines "layout\\.css\\.devPixelsPerPx")
          (goto-char (point-max))
          (insert (format "user_pref(\"layout.css.devPixelsPerPx\", \"%s\");\n" val))
          (write-region (point-min) (point-max) f nil 'silent))))))

(defun my/exwm-set-dpi (dpi)
  "Set the display DPI to DPI everywhere (see the Commentary)."
  (interactive
   (list (string-to-number
          (completing-read "DPI (96 = monitor, 144 = laptop): "
                           '("96" "120" "144" "168") nil nil nil nil
                           (number-to-string my/exwm-dpi)))))
  (setq my/exwm-dpi dpi)
  (setopt exwm-xsettings (my/exwm-xsettings-for dpi))
  (my/exwm--set-xrdb-dpi dpi)
  (my/exwm--set-firefox-scale dpi)
  (write-region (format "%d\n" dpi) nil my/exwm-dpi-file nil 'silent)
  (message "DPI %d: Emacs and GTK/Qt apps updated; restart Firefox (and open new xterms) to pick it up" dpi))

(defun my/exwm-dpi-toggle ()
  "Toggle between 96 and 144 DPI."
  (interactive)
  (my/exwm-set-dpi (if (< my/exwm-dpi 120) 144 96)))

(provide 'dpi)
;;; dpi.el ends here
