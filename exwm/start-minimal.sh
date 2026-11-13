#!/bin/sh
# Starts a nested X server and runs Emacs 31 + EXWM inside it.
# -listen tcp: EXWM's xcb library connects over TCP (localhost:6001), and WSLg's
# read-only /tmp/.X11-unix means no unix socket file can be created for :1.
pkill -x Xephyr 2>/dev/null; sleep 0.5
Xephyr :1 -screen 1280x800 -resizeable -ac -listen tcp &
sleep 1
DISPLAY=:1 exec emacs --debug-init -Q -l "$HOME/exwm-test/init-minimal.el"
