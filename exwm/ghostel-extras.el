;;; ghostel-extras.el --- ghostel-claude / ghostel-tasks from the Windows config  -*- lexical-binding: t; -*-
;; Loaded from exwm.el, so ~/.emacs.d itself stays untouched.
;; Ported from the Windows branch's config-terminal.el, minus its Windows-only parts
;; (D:/repos task paths, Git-for-Windows bash, the `my/display-task-left' side-window layout).

(add-to-list 'load-path (expand-file-name "lisp/util" "~/.emacs.d"))

(require 'project)
(require 'ghostel-tasks)
(require 'ghostel-claude)

;; Claude Code as the process of a project ghostel buffer.  SPC p c (= C-x p c); C-u starts another.
(define-key project-prefix-map "c" #'ghostel-claude)
(add-to-list 'project-switch-commands '(ghostel-claude "Claude") t)

;; Per-project dev servers, ported from the Windows config (D:/ -> /mnt/d/).  Keyed by repository
;; name.  String commands run through pwsh.exe on /mnt projects (config-wsl-host.el).  workers/ is
;; git-excluded, so it only exists in the main checkout; hence the absolute :dir.  The list form is
;; exec'd directly: Git's bash, since `bash' on PATH would be Linux bash (or the WSL launcher).
;; Tasks open in the left popper column (`my/display-task-left', config-ui.el).
(setq ghostel-tasks-display-action '(my/display-task-left))
(setq ghostel-tasks-projects
      '(("clearcompany"
         ("cc-workers-ghostel"
          :command ("/mnt/c/Program Files/Git/bin/bash.exe" "./runparallel.sh" "bgc-by-cc.csv")
          :dir "/mnt/d/repos/clearcompany/workers")
         ("cc-webapp-ghostel"
          :command "npm run dev"
          :dir "/mnt/d/repos/web-clearcompany/clearco-webapp")
         ;; Builds only what the branch needs.  -NoLauncher: the webapp has its own task above
         ;; (the script would otherwise start a second vite dev server).  Runs via pwsh.exe.
         ("cc-build"
          :command "./ccbuild.ps1 -NoPause -NoLauncher"))))
(add-to-list 'project-switch-commands '(ghostel-tasks-start-all "Start tasks") t)
(add-to-list 'project-switch-commands '(ghostel-tasks-switch "Task buffers") t)

;; Let a command run in a ghostel terminal open magit in Emacs.
(with-eval-after-load 'ghostel
  (add-to-list 'ghostel-eval-cmds '("magit-status-setup-buffer" magit-status-setup-buffer)))
