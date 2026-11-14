#!/bin/sh
# Nested X server + Emacs 31 with YOUR config (~/.emacs.d) and EXWM layered on top.
# -listen tcp: EXWM's xcb library connects over TCP (localhost:6001); WSLg's read-only
# /tmp/.X11-unix means no unix socket file can be created for :1.
# Old throwaway setup: ./start-minimal.sh
export PATH="$HOME/.local/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1  # puts nvm default node + global npm bins on PATH
pkill -x Xephyr 2>/dev/null; pkill -x picom 2>/dev/null; pkill -f "exwm-test/clipsync.sh" 2>/dev/null; pkill -f "exwm-test/keepkeys.sh" 2>/dev/null; sleep 0.5
# ONE knob for scaling (X11 apps get no Windows scaling): XFT_DPI env, else the last DPI chosen with s-= / my/exwm-set-dpi, else 144
export XFT_DPI=${XFT_DPI:-$(cat "$HOME/exwm-test/dpi" 2>/dev/null || echo 144)}
# Log why Xephyr/Emacs die (WSLg sleep/lid-close deaths left no trace before): ~/exwm-test/logs/
LOGD="$HOME/exwm-test/logs"; mkdir -p "$LOGD"
echo "=== $(date '+%F %T') start.sh (uptime $(cut -d' ' -f1 /proc/uptime)s)" >> "$LOGD/xephyr.log"
( Xephyr :1 -screen 1280x800 -dpi "$XFT_DPI" -resizeable -ac -listen tcp 2>>"$LOGD/xephyr.log"
  echo "=== $(date '+%F %T') Xephyr exited status $? (uptime $(cut -d' ' -f1 /proc/uptime)s)" >> "$LOGD/xephyr.log" ) &
"$HOME/exwm-test/clipsync.sh" &   # mirrors clipboard WSLg(:0) <-> Xephyr(:1); exits when Xephyr exits
# wait until Xephyr actually accepts connections (a fixed sleep lost Xft.dpi before)
for i in $(seq 1 50); do DISPLAY=:1 xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done

# Compositor: shadows + rounded corners for EXWM's floating windows only (see picom.conf).  It exits by itself
# when Xephyr goes away.  Remove this block (or uninstall picom) to run without it.
if command -v picom >/dev/null && [ -f "$HOME/exwm-test/picom.conf" ]; then
  DISPLAY=:1 picom --config "$HOME/exwm-test/picom.conf" --log-file "$LOGD/picom.log" &
fi

# Super key: Windows keeps the Win key and Right/Left Alt look identical to X, so kmonad turns a held
# f or j into F13 (see Windows ~/kmonad/conf.kbd) and F13 (keycode 191) becomes Super here.
DISPLAY=:1 setxkbmap -option ""
DISPLAY=:1 xmodmap -e 'keycode 191 = Super_L' -e 'add mod4 = Super_L'

# DPI: X11 apps get no Windows scaling. Xft.dpi covers GTK/Xft apps (xterm, arandr), Qt via QT_FONT_DPI.
DISPLAY=:1 xrdb -merge <<XRES
Xft.dpi: $XFT_DPI
XTerm*faceName: Iosevka Nerd Font Mono
XTerm*faceSize: 11
UXTerm*faceName: Iosevka Nerd Font Mono
UXTerm*faceSize: 11
XRES
"$HOME/exwm-test/keepkeys.sh" &   # re-applies Super (F13) and Xft.dpi if they get lost; exits with Xephyr
export QT_FONT_DPI="$XFT_DPI"
# Firefox (X11) already scales by Xft.dpi/XSETTINGS, so an explicit devPixelsPerPx would double-scale it
# (measured: 2.2x at 144 DPI). Pin the pref to its default (-1 = automatic); a stale value would otherwise
# stay in prefs.js.
for d in "$HOME"/.config/mozilla/firefox/*.default-release; do
  [ -d "$d" ] || continue
  sed -i '/layout.css.devPixelsPerPx/d' "$d/user.js" 2>/dev/null
  echo 'user_pref("layout.css.devPixelsPerPx", "-1.0");' >> "$d/user.js"
done
export GDK_DPI_SCALE=1   # keep GTK at 1x; Xft.dpi does the work

# Firefox finds its running instance over the D-Bus session bus; WSL has none, so every `firefox URL'
# from Emacs would start a second instance ("Firefox is already running"). Give Emacs a session bus.
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && command -v dbus-run-session >/dev/null; then
  DISPLAY=:1 dbus-run-session -- emacs --debug-init -l "$HOME/exwm-test/exwm.el" 2>>"$LOGD/emacs.log"
else
  DISPLAY=:1 emacs --debug-init -l "$HOME/exwm-test/exwm.el" 2>>"$LOGD/emacs.log"
fi
echo "=== $(date '+%F %T') Emacs exited status $? (uptime $(cut -d' ' -f1 /proc/uptime)s)" >> "$LOGD/xephyr.log"
