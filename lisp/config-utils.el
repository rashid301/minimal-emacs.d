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
