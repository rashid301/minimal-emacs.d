;;; whisper-setup.el --- speech-to-text via whisper.el + system whisper.cpp  -*- lexical-binding: t; -*-
;; s-v toggles: press to start recording, press again to stop and transcribe.  The text goes to
;; point in Emacs buffers, `ghostel-send-string' in ghostel, and clipboard + fake C-v in EXWM
;; (X) windows (whisper--insert-text handles each case from the buffer you started in).
;; whisper-cli: pacman -S whisper-cpp.  Model: ~/.local/share/whisper/ggml-small.en.bin
;; (curl -L -o <that> https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin).

(add-to-list 'load-path "/home/dev/.emacs.d/elpa/whisper")
(require 'whisper)

(setq whisper-install-whispercpp nil            ; use the pacman binary, don't build our own
      whisper-language "en"
      whisper-recording-timeout 120
      whisper-return-cursor 'end
      whisper-show-progress-in-mode-line nil
      whisper--ffmpeg-input-format "pulse"      ; WSLg's PulseAudio; auto-detect wants a local pulseaudio binary
      whisper--ffmpeg-input-device "default")

(defvar my/whisper-model (expand-file-name "~/.local/share/whisper/ggml-small.en.bin"))

(defun whisper-command (input-file)
  "whisper-cli command for INPUT-FILE (overrides whisper.el's, which assumes its own build)."
  `("whisper-cli" "--language" ,whisper-language "--model" ,my/whisper-model
    "--no-timestamps" "--no-prints" "--threads" "8" "--file" ,input-file))

;; Runs in whisper's stdout buffer: drop non-speech markers, trim whitespace.
(defun my/whisper-clean ()
  (goto-char (point-min))
  (while (re-search-forward "\\[[A-Z_ ]+\\]\\|([a-z ]+)" nil t) (replace-match ""))
  (goto-char (point-min))
  (while (re-search-forward "[ \t\n]+" nil t) (replace-match " "))
  (let ((s (string-trim (buffer-string))))
    (erase-buffer) (insert s)))
(add-hook 'whisper-after-transcription-hook #'my/whisper-clean)

;; whisper's own read-only check rejects EXWM buffers (read-only, but we paste via the X
;; clipboard + fake C-v, not by inserting), so replace it with one that exempts those.
(defun my/whisper-check-read-only ()
  (when (and whisper-insert-text-at-point
             buffer-read-only
             (not (memq major-mode '(exwm-mode ghostel-mode vterm-mode eat-mode))))
    (error "Buffer is read-only, can't insert text here")))
(remove-hook 'whisper-before-transcription-hook #'whisper--check-buffer-read-only-p)
(add-hook 'whisper-before-transcription-hook #'my/whisper-check-read-only)

(defun my/whisper-toggle ()
  "Start/stop dictation into the current buffer (EXWM windows included)."
  (interactive)
  (whisper-run))

(provide 'whisper-setup)
