#!/bin/bash
# Two-way CLIPBOARD (text) sync between WSLg's X display (:0, which WSLg already syncs with
# Windows) and Xephyr's display (:1, which has its own separate clipboard).
# Event-driven: `clipnotify` blocks until the CLIPBOARD owner changes on a display, so there is no
# polling (the old 0.4 s xclip loop sent ~42k selection requests/day through WSLg's weston).
# Exits by itself when the Xephyr display goes away.
#
# Every xclip call has a timeout: `xclip -o` waits forever when the selection owner doesn't answer
# (e.g. WSLg holding non-text content).  Asking for UTF8_STRING makes non-text content fail fast and
# keeps non-ASCII text intact.
A=:0; B=:1
last_a=""; last_b=""; misses=0
get() { DISPLAY=$1 timeout 2 xclip -selection clipboard -t UTF8_STRING -o 2>/dev/null; }
put() { printf '%s' "$2" | DISPLAY=$1 timeout 5 xclip -selection clipboard -t UTF8_STRING -i 2>/dev/null; }
sync_once() {
  a=$(get $A); b=$(get $B)
  if [ -n "$a" ] && [ "$a" != "$last_a" ]; then       # Windows/WSLg side changed
    last_a=$a; last_b=$a; [ "$a" != "$b" ] && put $B "$a"
  elif [ -n "$b" ] && [ "$b" != "$last_b" ]; then     # Xephyr/EXWM side changed
    last_b=$b; last_a=$b; [ "$b" != "$a" ] && put $A "$b"
  fi
}
trap 'kill $pa $pb 2>/dev/null' EXIT
while :; do
  if ! DISPLAY=$B timeout 2 xprop -root >/dev/null 2>&1; then
    misses=$((misses+1)); [ $misses -ge 3 ] && exit 0; sleep 1; continue
  fi
  misses=0
  # start the watchers BEFORE syncing so a change during the sync is not lost
  DISPLAY=$A clipnotify -s clipboard & pa=$!
  DISPLAY=$B clipnotify -s clipboard & pb=$!
  sync_once
  wait -n $pa $pb          # returns when either clipboard changes (or a display died)
  kill $pa $pb 2>/dev/null; wait $pa $pb 2>/dev/null
  sleep 0.1                # debounce rapid changes / avoid a spin if a display is gone
done
