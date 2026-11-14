# EXWM-in-Xephyr on WSLg (Arch distro) — pickup notes

Read this first when resuming. Everything here lives in `/home/dev/exwm-test/` inside the **`archlinux`** WSL
distro (user `dev`, shell zsh). The Ubuntu distro is `cc-local` (the user's main one; don't confuse them).

## What this is
Emacs 31.1 + EXWM 0.35 acting as a window manager inside a **nested X server (Xephyr, display :1)** that shows up as
one window on the Windows desktop through WSLg. The user's *real* Emacs config (`~/.emacs.d`, a minimal-emacs.d
setup copied from cc-local) loads first; `exwm.el` is layered on top. Reason for EXWM: the user's real setup is EWM
(Emacs Wayland compositor), which has no nested mode. (niri was also tried nested; see bottom.)

## Launch / stop
- Desktop shortcut **"EXWM (Arch).lnk"** = `wslg.exe -d archlinux -u dev --cd /home/dev -- /home/dev/exwm-test/start.sh`
  (wslg.exe = no console window). Or from a shell: `wsl -d archlinux` then `~/exwm-test/start.sh`.
- `start.sh` kills any old Xephyr/clipsync/keepkeys, starts everything, then `exec`s Emacs. Close the Xephyr window to stop.
- **Old session running as another user/older run holds display :1**; close it before starting a new one.
- Fallback with a throwaway `-Q` config: `start-minimal.sh` (+ `init-minimal.el`).
- First start after a config change can take minutes (package install, native compile).

## Files in this folder
| File | Purpose |
|---|---|
| `start.sh` | Launcher: Xephyr (`-listen tcp -resizeable -dpi N`), clipsync, Super mapping, xrdb DPI, keepkeys, Firefox scale pref, then Emacs. |
| `exwm.el` | EXWM layer, loaded with `emacs -l` AFTER `~/.emacs.d/init.el`: global keys, RandR resize timer, XSETTINGS, loads the files below. Starts an Emacs server (see Debugging). |
| `dpi.el` | `my/exwm-set-dpi` / `my/exwm-dpi-toggle` (`s-=`): switch 96 <-> 144 live. Saves choice in `dpi` file. |
| `apps.el` | `my/exwm-launch-app`: completing-read launcher over `.desktop` files (terminal-only apps hidden). |
| `ghostel-extras.el` | Wires `ghostel-claude` / `ghostel-tasks` (ported from the Windows Emacs config): `SPC p c` (= `C-x p c`) = Claude in project; `ghostel-tasks-projects` (clearcompany: workers + webapp, paths as `/mnt/d/...`) and the left-column task display. |
| `clipsync.sh` | Two-way text CLIPBOARD sync WSLg `:0` <-> Xephyr `:1` (WSLg already syncs `:0` <-> Windows). Event-driven via `clipnotify` (pacman; no polling, the old 0.4 s xclip loop flooded weston with ~42k selection requests/day). Exits when Xephyr dies. |
| `keepkeys.sh` | Watchdog (every 3 s): re-applies F13->Super keymap and `Xft.dpi` if lost. Exits when Xephyr dies. |
| `dpi` | One number: last chosen DPI (read by start.sh and keepkeys.sh). |
| `elpa/` | EXWM + XELB packages (separate from `~/.emacs.d/elpa`). The Emacs server uses the default socket (`$XDG_RUNTIME_DIR/emacs/server`), so a plain `emacsclient` works, in ghostel too. |
Related files elsewhere: `~/.emacs.d/lisp/config-wsl-host.el` (Windows-native tools for `/mnt` projects, see below),
`~/.local/bin/{git,rg,fd,winwrap,pwsh-c,wt}` (PATH wrappers, same section), `~/.emacs.d/lisp/config-super.el` (portable Super bindings), `~/.emacs.d/lisp/util/ghostel-{claude,tasks}.el`,
`~/.emacs.d/lisp/config-ui.el` (Arch copy: theme toggle also refreshes XSETTINGS; noctalia call guarded).

## The Super key chain (the part that took longest)
Windows keeps the Win key, and Left/Right Alt both arrive in Xephyr as keycode 64 (indistinguishable). So:
1. **kmonad on Windows** (`C:\Users\shaik\kmonad\conf.kbd`): holding `f` or `j` (home-row mods, `tap-hold-next-release 180`) sends **F13**.
   Windows ignores F13. Backups beside it: `conf.kbd.bak-before-f13` (original), `.bak-ralt-f13`, `.bak-lalt-f13` (my failed attempts).
   A byte-identical copy lives in `Dropbox\kmonad\conf.kbd` (NOT edited).
2. **WSLg** forwards F13 to Xephyr as keycode **191**.
3. **start.sh / keepkeys.sh** run `xmodmap -e 'keycode 191 = Super_L' -e 'add mod4 = Super_L'`. Emacs/EXWM then see a normal held Super (`s-`).
   `xmodmap` REFUSES to run while any key is physically held ("please release the following keys") — that is why a one-shot call
   failed once and keepkeys.sh exists.
4. In **Windows Emacs** there is no Xephyr: F13 arrives as plain `<f13>`, translated by `config-super.el` into a one-shot Super prefix
   (`key-translation-map` + `event-apply-super-modifier`). See Open items.

## Keybindings (Super = hold f or j)
EXWM global keys (work in X windows like Firefox too; EXWM only passes listed keys): `s-r` reset (`exwm-reset`, a recovery command),
`s-=` DPI toggle, `s-&` run shell command, `s-t` xterm. **There is one EXWM workspace on purpose** (`exwm-workspace-number 1`): the user uses
**tabs** (tab-bar), not workspaces, so the workspace keys (`s-w`, `s-0..3`) were removed. Plus every entry of `my/super-bindings`
(`config-super.el`): `s-h/j/k/l` focus (at the edge of the layout `s-h`/`s-l` switch **tab**; in EWM they move between frames), `C-s-h/j/k/l` move buffer, `s-H/J/K/L` swap (edge: move the tab), `s-< s->` prev/next tab (EWM: frame), `s-?`/`s-/` splits, `s-q` kill buffer, `s-b` consult-buffer, `s-p/n` prev/next buffer, `s-<return>` ghostel,
`s-a` activities-resume, `s-d` app launcher, `s-f` maximize toggle, `s-o`, `s-i`, `s-SPC`.
`config-super.el` is also copied into the Ubuntu (`~/.emacs.d/lisp/`) and Windows (`...\Roaming\.emacs.d\lisp\`) configs and loaded from
their `post-init.el` — so the same keys work in all three Emacs (EWM / EXWM / Windows).

## WSLg + Xephyr quirks (each cost real time; keep these fixes)
- **EXWM hangs in `connect()` unless Xephyr runs with `-listen tcp`**: xcb.el connects to localhost:6000+N over TCP, and WSLg's
  `/tmp/.X11-unix` is a read-only tmpfs so no unix socket file can exist for :1. (Xephyr thus listens on 0.0.0.0:6001 with `-ac`.)
- **Xephyr only refreshes its RandR monitor data when a client does a full RandR query.** After a Windows-side resize EXWM sees stale
  sizes. `exwm.el` runs a 0.3 s timer: read the real root size via xcb, and on a stable mismatch run `xrandr --listmonitors`
  then `exwm-randr-refresh` (max 5 tries per size). Emacs's own `x-display-pixel-width` goes stale too — don't use it.
- **Fullscreen (hides the WSLg/Windows title bar): toggle it at runtime with `s-<f11>`, never with Xephyr's `-fullscreen` flag.**
  Launching with `-fullscreen` (also tried `-softCursor`, `-no-host-grab`) leaves the X server with no pointer motion at all — keyboard
  works, mouse is dead (checked with `xdotool getmouselocation` on the Xephyr display). Setting `_NET_WM_STATE_FULLSCREEN` on the already-open
  host window works and keeps the mouse. `my/xephyr-toggle-fullscreen` (exwm.el) does this: it finds the host window `Xephyr on :1.*`
  on WSLg's `:0` and runs `xdotool windowstate --toggle FULLSCREEN` on it. Needs `xdotool`. (The gist
  mle98/2deb6e0aa1da3aed70a73dad9c29e8f7 patches `system.vhd` for a different fullscreen problem, affects EVERY WSL distro — NOT applied.)
- **Stale Emacs holds the server socket**: if an old EXWM Emacs hangs (its Xephyr was killed by `start.sh`), `server-running-p` still says yes,
  the new Emacs gets no server, and every `emacsclient` times out. `exwm.el` now does `server-force-delete` before `server-start`;
  if it still happens, `pgrep -ax emacs` and `kill -9` the old one.
- **No scaling for X11 apps**: Windows is at 125% but Xephyr is 1:1. One knob `XFT_DPI` (default = `dpi` file, else 144):
  Xephyr `-dpi`, `xrdb Xft.dpi` (xterm etc.), **XSETTINGS** via `exwm-xsettings` (GTK/Qt + Emacs fonts, live), `QT_FONT_DPI`.
  **Firefox ignores Xft.dpi/XSETTINGS for scale on X11** (verified: devicePixelRatio stayed 1) -> `layout.css.devPixelsPerPx = DPI/96`
  in its `user.js` (`~/.config/mozilla/firefox/*.default-release`), read only at Firefox start.
- GTK theme follows Emacs light/dark: `exwm-xsettings-theme = ("Adwaita" . "Adwaita-dark")` (needs `gnome-themes-extra`).
- Fresh Arch had **no fonts** (apps start, can't load a font, exit -> blank screen); `ttf-iosevka-nerd` etc. installed. Needs `man-db`
  (evil-collection byte-compile does `(require 'man)`), `git`, `ripgrep`, `fd`, `base-devel` (treesit grammars), `tmux`, `openssh`.
- Node comes from **nvm** (22.23.5 and 24.22.3, default 24), not pacman. `claude` is in `~/.local/bin`; `claude-agent-acp` is a global npm
  package under nvm's node. start.sh sources nvm so Emacs inherits them.
- Emacs under `sh`: EXWM needs the X11/GTK Emacs build (Arch `emacs`, not `emacs-wayland`).

## Windows drive projects (/mnt/<drive>): native speed
Repos like `/mnt/d/repos/clearcompany` are slow over 9p (`rg -l` 100 s vs 2 s native) and root-owned (git: "dubious ownership", status 128).
So everything that touches them uses the **Windows** binaries, switched on the working directory. Two layers:
- **PATH wrappers in `~/.local/bin`** (first on PATH, inherited by Emacs/ghostel/Claude): `wt` (worktrunk, pacman `worktrunk`) -> `git-wt.exe` with `D:/x` mapped back to `/mnt/d/x` (Linux wt can't follow git.exe's `D:/` worktree paths); `git` -> `git.exe`; `rg`/`fd` are symlinks to `winwrap`
  -> `rg.exe`/`fd.exe`. They decide by `$PWD` (and `-C`, or an absolute `/mnt/x` argument), else exec the Linux binary. `winwrap` adds
  `--path-separator /`, strips CR, maps `D:/x` <-> `/mnt/d/x`. The `git` wrapper also maps `D:/x` back to `/mnt/d/x` for `rev-parse`/`worktree`
  output (ghostel-tasks needs that). Overrides: `GIT_FORCE_LINUX=1`, `GIT_FORCE_WINDOWS=1`, `WIN_FORCE_LINUX=1`. magit/vc/consult-ripgrep/consult-fd
  need no config: they call `git`/`rg`/`fd` by name with `default-directory` as cwd. Dired keeps Linux `ls` (cost is per-file stat, not the binary).
- **`~/.emacs.d/lisp/config-wsl-host.el`** (loaded from `post-init.el`; no-op outside WSL), advice on ghostel:
  - ghostel buffers whose `default-directory` is on `/mnt` run **`pwsh.exe`** (WSL interop translates the cwd to `D:\...`); a prompt hook sends OSC 7
    with a `/mnt/...` path so `default-directory` stays a Linux path. No OSC 133 prompt marks in PowerShell.
  - `ghostel-tasks`: string commands run via `pwsh.exe -Command` for `/mnt` roots (list-form commands are exec'd as given).
  - `ghostel-claude`: runs Windows `claude.exe` on `/mnt` (uses the *Windows* `~/.claude`: separate login/settings/memory). `my/wsl-host-claude-windows` = nil -> Linux claude.
  - `M-x compile` / `recompile` on `/mnt` run through PowerShell: `compilation-start` advice (plain compiles only, not grep/rgrep) binds `shell-file-name`
    to `~/.local/bin/pwsh-c` (a `-c CMD` -> `pwsh.exe -NoProfile -Command CMD` shim). Build-output paths `D:\x\F.cs(1,2)` are mapped to `/mnt/d/x` for jump-to-error.
  - `/mnt` buffers auto-revert by **polling** (inotify never sees Windows-side writes from claude.exe/builds); `recentf-keep` skips the stat for `/mnt` files.
  - Not done on purpose: `xref-search-program` = ripgrep (xref pipes the file list through `xargs -0 rg`: one rg.exe spawn per batch + `wslpath` per arg). Use `consult-ripgrep`.
  - Switch off: `my/wsl-host-use-pwsh` = nil. Explicit `ghostel-shell` overrides are respected.
- **`gh`** (pacman `github-cli`) needs no wrapper on `/mnt`: it calls `git` by name, which the git wrapper routes to `git.exe` (tested: `repo view`, `pr status`, `pr list`, `browse`).
  Logged in separately as `rashid-cc` (token in `~/.config/gh/hosts.yml`); Windows `gh.exe` is a different account (`rashid-clearco`, Windows keyring).
- **zmx / term-sessions** (remote session persistence over TRAMP, e.g. `/ssh:desktop-wsl:`): `zmx list` reports a session's cwd as the OSC 7 URI its shell sent
  (`file://desktop-pc/home/x/proj`), which term-sessions prefixed with the TRAMP root and `cd`'d into (`cd: can't cd to /home/shaik/file:/desktop-pc/...`).
  `config-terminal.el` (Arch copy) advises `term-sessions--parse-key-value-fields` to turn `file://HOST/path` / `kitty-shell-cwd://HOST/path` back into `/path`.
  A one-off "Cannot find zmx executable" on a remote was a transient probe failure (zmx is in `/usr/bin` there; failed probes are retried, not cached). zmx is not installed on Arch itself.
- Known quirks: `git.exe` under a pty (magit) may print a stray `ESC[6n` (cursor-position query) in the process buffer; cosmetic, unconfirmed cause.
  Possible fix if it bothers: have the wrapper pipe `git.exe` output when called from Emacs (not ghostel). Not done.
- `config-ui.el` (Arch copy) has `my/display-task-left` / `my/left-popup-p`: task + compile buffers go to a left popper column (25% wide, stacked by slot).

## Lid close kills Xephyr (weston crash)
Closing the laptop drops WSLg's RDP session; weston (WSLg's compositor, shared by all distros) then segfaults while destroying the `archlinux` app windows
(`/mnt/wslg/stderr.log`: `weston ... terminated with signal 11`), and every client incl. Xephyr gets "Connection reset by peer". Seen 4x since the Nov 12 boot.
Tried: clipsync polling -> `clipnotify` (suspected load), and `wsl --update` on Nov 13 (WSL 2.7.14 -> 3.0.5, WSLg 1.0.73.2 -> 1.0.79). Crash count reset to 0 by that restart; unconfirmed whether either helps. If it still crashes: run Xephyr's content on Xvnc inside WSL (survives weston restarts).
Beware `pkill -f "exwm-test/clipsync.sh"` from a Claude shell: it matches the shell's own command line and kills it; start it via `(setsid nohup ./clipsync.sh &)`.

## Debugging recipes
- **Talk to the running Emacs**: `emacsclient -e '(...)'` (server starts only after init succeeds).
  Great for checking state/bindings; if init errors out the server is not up -> reproduce on a hidden display (below).
- **Raw keys reaching Xephyr**: `DISPLAY=:1 xinput test-xi2 --root > /tmp/xi.log` (needs `xorg-xinput`), press keys, read keycodes; map with
  `DISPLAY=:1 xmodmap -pke`. (Mouse motion floods the log; keep the mouse still.)
- **Hung Emacs**: `gdb -p PID -batch -ex "bt 15"` showed `exwm--init -> xcb:connect -> connect()`.
- **Reproduce without disturbing the user**: `Xvfb :2 -screen 0 1280x800x24 +extension RANDR -listen tcp`, run Emacs with `DISPLAY=:2`.
- **See the screen**: `DISPLAY=:1 scrot /tmp/x.png`, then view the PNG.
- **Emacs init error with a backtrace you can't copy**: screenshot it; or hook `debugger` via an `EMACSLOADPATH` dir containing a `site-start.el`.
- Beware `pkill -f emacs` / `pkill -x emacs`: it kills the user's session. `wsl.exe ... pkill -f` can also match its own shell.
- Calling Windows tools from WSL: a `powershell.exe` reading stdin will swallow the rest of a here-doc script — add `</dev/null`.

## Open items / pending decisions
1. **Windows Emacs and held Super**: F13 is only a one-shot there, so the user must re-press `f`/`j` for every nav. Before the F13 change, kmonad sent the
   real Win key and the Windows config's `w32-lwindow-modifier 'super` made it a held modifier — but Windows steals Win (and Xephyr never sees it).
   Options offered: (1) kmonad sends the Menu/Apps key instead of F13 + `w32-apps-modifier 'super` in Windows Emacs + map keycode 135 to Super in
   Xephyr (downside: context menu on release in other Windows apps); (2) make the `<f13>` translation sticky for ~0.5 s; (3) leave it. **Awaiting the user's pick.**
2. SSH: `~/.ssh` is a copy of cc-local's (same config/key/known_hosts), plus the Windows hosts `desktop-ee` / `desktop-ee-tunnel` merged in (the tunnel block sits above `Host *`
   with `ControlMaster no`, else it would reuse a multiplexed connection and skip its LocalForwards). Backup: `~/.ssh/config.bak-before-windows-merge`. Windows `known_hosts` not merged.
   Still missing here: the keys the config references (`carbon_github`, `id_rsa`, `hole_intel`, `springeats_github`, `internal_springeats.pem`, `bb_analytics.pem`, `devpod.pem`, `neo4j.pem`,
   `LightsailDefaultKey-us-east-1.pem`, `id_brandjet`, `springeats_kinsta`). `desktop-pc`/`desktop-wsl`/`desktop-ee*` all resolve to the Tailscale name `desktop-pc.tail5be64e.ts.net` (22 / 2222).
3. `ghostel-tasks-projects` ported (clearcompany: `cc-workers-ghostel`, `cc-webapp-ghostel`, `cc-build`) and `my/display-task-left` ported. **User-verified working**: the tasks,
   worktrunk (`wt`), ghostel + ghostel-claude on `/mnt`, zmx/term-sessions. Magit on `/mnt` not confirmed (see Known quirks).
4. Not installed (config references them, email block is commented out): `aspell`, `mu`/`notmuch`. (`task` 3.5.0 is installed from pacman; `~/.taskrc` is a copy of the cc-local one, data in the shared Dropbox dir via `/mnt/c/Users/shaik/Dropbox/taskwarrior`.)
5. Stale copies in `/root/.emacs.d` and `/root/exwm-test` from before the move to user `dev` (safe to delete).
6. Xephyr listens on TCP 6001 on all interfaces with `-ac` (`.wslconfig` has `networkingMode=mirrored`, so WSL and Windows share `localhost`: an `ssh -L` tunnel from WSL is reachable from Windows browsers).
7. Never verified with real hardware: F13 -> Super path inside Windows Emacs, the `config-super` edge behaviours inside EWM (Ubuntu), Firefox DPI look.

## niri (earlier experiment)
niri 26.04 runs nested under WSLg as root (`/root/.config/niri/config.kdl`, a copy of the user's config with `mod-key-nested "Alt"`, Mod+Return=foot,
Mod+A/D=fuzzel, noctalia include commented out). Needs fonts/foot/fuzzel. Abandoned in favour of EXWM; kept for reference.

Memory notes for the assistant: `/home/dev/.claude/projects/-home-dev-repos-niri/memory/wslg-arch-exwm-setup.md` (in the cc-local distro).

## Decision: staying on X11 (no Wayland migration)
Considered nested river + reka/rau (Emacs-based WMs for river, see codeberg.org/river/wiki wm-list.md) instead of Xephyr + EXWM. **Decided not to migrate; not worth it.**
Reasons: WSLg already composites everything so Wayland's rendering/scaling wins mostly don't apply; EXWM is mature and this config (fullscreen toggle, socket takeover, Super chain, Firefox evil) works;
`xdotool` (Firefox link hints via Alt+j) is X11-only and would need rework; reka/rau are young and unverified in WSL2. Don't re-propose unless EXWM's single-event-loop fragility or Xephyr HiDPI becomes a real pain.

## Backup / restore
Branch `exwm-wsl` of github.com/rashid301/minimal-emacs.d holds this folder. After cloning into `~/.emacs.d`, run `exwm/bin/install.sh` (PATH wrappers), `ln -s ~/.emacs.d/exwm ~/exwm-test`, then re-create `elpa/` by starting once.
