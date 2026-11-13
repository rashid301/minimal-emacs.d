#!/bin/bash
# Keeps the X settings that start.sh makes alive on Xephyr (:1): F13 (keycode 191) as Super, and Xft.dpi.
# Why: xmodmap refuses to change the keymap while any key is physically held ("please release the
# following keys"), so a one-shot call at startup can silently fail; Xephyr can also re-sync its keymap
# from the host.  Checks every 3 s and re-applies.  Exits when Xephyr goes away.
export DISPLAY=:1
misses=0
while :; do
  if ! xprop -root >/dev/null 2>&1; then
    misses=$((misses+1)); [ $misses -ge 3 ] && exit 0; sleep 1; continue
  fi
  misses=0
  if ! xmodmap -pke 2>/dev/null | grep -q '^keycode 191 = Super_L'; then
    timeout 20 xmodmap -e 'keycode 191 = Super_L' -e 'add mod4 = Super_L' >/dev/null 2>&1
  fi
  if ! xrdb -query 2>/dev/null | grep -q '^Xft.dpi:'; then
    DPI=$(cat "$HOME/exwm-test/dpi" 2>/dev/null || echo "${XFT_DPI:-144}")
    xrdb -merge <<XRES
Xft.dpi: $DPI
XTerm*faceName: Iosevka Nerd Font Mono
XTerm*faceSize: 11
UXTerm*faceName: Iosevka Nerd Font Mono
UXTerm*faceSize: 11
XRES
  fi
  sleep 3
done
