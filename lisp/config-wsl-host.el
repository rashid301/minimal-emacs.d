;;; config-wsl-host.el --- Use Windows-native tools for projects on /mnt/<drive>  -*- lexical-binding: t; -*-

;; Projects on a Windows drive (/mnt/d/...) are slow (9p) and root-owned from Linux's view.
;; Two layers cooperate:
;;
;;  1. PATH wrappers in ~/.local/bin (outside Emacs, but Emacs inherits them):
;;       git          -> git.exe        (git)
;;       rg, fd       -> rg.exe, fd.exe (winwrap; '/' separators, no CR, /mnt paths restored)
;;     They switch on the working directory, so consult-ripgrep / consult-fd / magit / vc
;;     need no configuration here.
;;  2. This file: ghostel buffers whose `default-directory' is on /mnt start PowerShell 7
;;     (pwsh.exe).  WSL interop translates the cwd to D:\... (what `wslpath -w' would do);
;;     a prompt hook reports the directory back to Emacs as a /mnt/... path (OSC 7) so
;;     `default-directory' stays a usable Linux path.
;;
;;     The same applies to `ghostel-tasks': string commands run through pwsh.exe, so
;;     "npm run dev" / "dotnet run" use the Windows toolchain.  (List-form commands
;;     (PROGRAM ARG...) are exec'd as given, i.e. the Linux program of that name.)
;;
;;     `ghostel-claude' on /mnt runs the Windows claude.exe (`my/wsl-host-claude-windows').
;;
;;     `M-x compile' / `recompile' on /mnt run through PowerShell (~/.local/bin/pwsh-c); Windows
;;     paths in build output (D:\\x\\F.cs(1,2): error) are mapped to /mnt/d/x for jump-to-error.
;;
;;     /mnt buffers auto-revert by polling (no inotify for Windows-side writes); recentf does
;;     not stat /mnt files.  (`project-find-regexp' is slow on /mnt: use `consult-ripgrep'.)
;;
;; Escape hatches: `my/wsl-host-use-pwsh' = nil; GIT_FORCE_LINUX=1 / WIN_FORCE_LINUX=1 in the env.
;; Does nothing outside WSL.

;;; Code:

(require 'subr-x)

(defgroup my/wsl-host nil "Windows-native tooling for /mnt projects." :group 'tools)

(defcustom my/wsl-host-use-pwsh t
  "When non-nil, ghostel started under /mnt/<drive> runs PowerShell instead of the login shell."
  :type 'boolean :group 'my/wsl-host)

(defcustom my/wsl-host-pwsh-program "pwsh.exe"
  "PowerShell executable to use for /mnt buffers (falls back to powershell.exe)."
  :type 'string :group 'my/wsl-host)

(defun my/wsl-host-p ()
  "Non-nil when running inside WSL."
  (and (eq system-type 'gnu/linux) (getenv "WSL_DISTRO_NAME") t))

(defun my/wsl-mnt-p (&optional dir)
  "Non-nil when DIR (default `default-directory') is a local path on a Windows drive."
  (let ((dir (expand-file-name (or dir default-directory))))
    (and (not (file-remote-p dir))
         (string-match-p "\\`/mnt/[a-zA-Z]\\(/\\|\\'\\)" dir))))

(defconst my/wsl-host--pwsh-init
  "$global:__wslOrigPrompt = $function:prompt
function global:prompt {
  if ($PWD.Provider.Name -eq 'FileSystem') {
    $p = $PWD.ProviderPath; $u = $null
    if ($p -match '^([A-Za-z]):\\\\?(.*)$') { $u = '/mnt/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\\\','/') }
    elseif ($p -match '^\\\\\\\\wsl[^\\\\]*\\\\[^\\\\]+(.*)$') { $u = ($Matches[1] -replace '\\\\','/'); if (-not $u) { $u = '/' } }
    if ($u) { [Console]::Out.Write([char]27 + ']7;file://' + ($u -replace ' ','%20') + [char]27 + '\\') }
  }
  if ($global:__wslOrigPrompt) { & $global:__wslOrigPrompt } else { 'PS ' + $PWD + '> ' }
}
"
  "PowerShell snippet run after the profile: emit OSC 7 with a /mnt path on each prompt.")

(defun my/wsl-host--pwsh-spec ()
  "Return (PROGRAM . ARGS) for PowerShell, or nil if it is not installed."
  (when-let* ((exe (or (executable-find my/wsl-host-pwsh-program)
                       (executable-find "powershell.exe"))))
    (list exe "-NoLogo" "-NoExit" "-EncodedCommand"
          (base64-encode-string
           (encode-coding-string my/wsl-host--pwsh-init 'utf-16le) t))))

(defun my/wsl-host--ghostel-shell-spec (orig-fn &rest args)
  "Around advice for `ghostel--resolve-shell-spec': PowerShell on /mnt drives."
  (or (and my/wsl-host-use-pwsh
           (my/wsl-mnt-p)
           ;; Leave explicit `ghostel-shell' overrides (let-bound or customised) alone.
           (equal ghostel-shell (default-value 'ghostel-shell))
           (my/wsl-host--pwsh-spec))
      (apply orig-fn args)))

(defcustom my/wsl-host-claude-windows t
  "When non-nil, `ghostel-claude' on a /mnt project runs the Windows claude.exe.
That gives native file access and the Windows toolchain (git, dotnet, node), but it
uses the *Windows* ~/.claude (login, settings, memory), not the WSL one.  Set to nil
to run the Linux claude, whose git/rg/fd calls still go through the PATH wrappers."
  :type 'boolean :group 'my/wsl-host)

(defun my/wsl-host--claude-program (orig-fn root &rest args)
  "Around advice for `ghostel-claude--start': claude.exe when ROOT is on /mnt."
  (let ((ghostel-claude-program
         (or (and my/wsl-host-claude-windows
                  (my/wsl-mnt-p root)
                  (equal ghostel-claude-program "claude")
                  (executable-find "claude.exe"))
             ghostel-claude-program)))
    (apply orig-fn root args)))

(defun my/wsl-host--task-shell (command)
  "`ghostel-tasks-shell-function': run COMMAND in PowerShell on /mnt, else via sh."
  (if-let* (((and my/wsl-host-use-pwsh (my/wsl-mnt-p)))
            (exe (or (executable-find my/wsl-host-pwsh-program)
                     (executable-find "powershell.exe"))))
      (list exe "-NoLogo" "-NoProfile" "-Command" command)
    (ghostel-tasks--default-shell command)))

(defun my/wsl-host--task-in-root (orig-fn root &rest args)
  "Around advice for `ghostel-tasks--start-one': decide the shell by the task's ROOT."
  (let ((default-directory root))
    (apply orig-fn root args)))

;; ── Auto-revert, recentf, xref ─────────────────────────────────────────────
;; File notifications (inotify) on drvfs only fire for changes made from WSL, not for what
;; Windows processes write (claude.exe, cc-build, an IDE).  Buffers on /mnt therefore poll.
(defun my/wsl-host--revert-by-polling ()
  "Drop the file-notify watch for /mnt buffers so `auto-revert-mode' polls them."
  (when (and (my/wsl-mnt-p) (fboundp 'auto-revert-notify-rm-watch))
    (setq-local auto-revert-use-notify nil)
    (auto-revert-notify-rm-watch)))

;; `recentf' stats every remembered file when cleaning up; over 9p that is slow.  Files
;; matching a `recentf-keep' regexp are kept without a stat.
(defvar recentf-keep)

(when (my/wsl-host-p)
  (add-hook 'auto-revert-mode-hook #'my/wsl-host--revert-by-polling)
  (with-eval-after-load 'recentf
    (add-to-list 'recentf-keep "\\`/mnt/[a-zA-Z]/")))

;; NOT done on purpose: `xref-search-program' = ripgrep.  xref pipes the whole project file list
;; through `xargs -0 rg', i.e. one rg.exe spawn per batch plus a `wslpath' per path argument in
;; the wrapper - hopeless for a 30k-file repo.  Use `consult-ripgrep' on /mnt (one rg.exe call).

;; ── M-x compile ────────────────────────────────────────────────────────────
;; `compile'/`recompile' run COMMAND through `shell-file-name' -c; on /mnt that must be PowerShell
;; (`./ccbuild.ps1 ...', dotnet, npm).  Only plain compilations: grep/rgrep use `compilation-start'
;; with their own modes and need the Linux shell.  ~/.local/bin/pwsh-c adapts `-c CMD' to pwsh.exe.

(defun my/wsl-host--compilation-start (orig-fn command &optional mode &rest args)
  "Around advice for `compilation-start': PowerShell for plain compiles on /mnt."
  (if (and my/wsl-host-use-pwsh (null mode) (my/wsl-mnt-p) (executable-find "pwsh-c"))
      (let ((shell-file-name (executable-find "pwsh-c"))
            (shell-command-switch "-c"))
        (apply orig-fn command mode args))
    (apply orig-fn command mode args)))

(defun my/wsl-host--windows-file-name (filename)
  "Map a Windows-style FILENAME (D:\\x or D:/x) to /mnt/d/x; return other names unchanged."
  (if (and (stringp filename) (string-match "\\`\\([A-Za-z]\\):[\\\\/]" filename))
      (concat "/mnt/" (downcase (match-string 1 filename)) "/"
              (replace-regexp-in-string "\\\\" "/" (substring filename (match-end 0))))
    filename))

(defun my/wsl-host--compilation-find-file (orig-fn marker filename directory &rest formats)
  "Around advice for `compilation-find-file': understand D:\\... paths in build output."
  (apply orig-fn marker (my/wsl-host--windows-file-name filename) directory formats))

(when (my/wsl-host-p)
  (with-eval-after-load 'ghostel
    (advice-add 'ghostel--resolve-shell-spec :around #'my/wsl-host--ghostel-shell-spec))
  ;; ghostel-tasks: "npm run dev" etc. must run in Windows' node/dotnet for /mnt projects.
  (with-eval-after-load 'ghostel-tasks
    (setq ghostel-tasks-shell-function #'my/wsl-host--task-shell)
    (advice-add 'ghostel-tasks--start-one :around #'my/wsl-host--task-in-root))
  (with-eval-after-load 'compile
    (advice-add 'compilation-start :around #'my/wsl-host--compilation-start)
    (advice-add 'compilation-find-file :around #'my/wsl-host--compilation-find-file))
  (with-eval-after-load 'ghostel-claude
    (advice-add 'ghostel-claude--start :around #'my/wsl-host--claude-program)))

(provide 'config-wsl-host)
;;; config-wsl-host.el ends here
