#!/bin/sh
# Register the claude-focus:// URL scheme for the current Windows user (HKCU, no admin).
# Undo: reg.exe delete 'HKCU\Software\Classes\claude-focus' /f
d=$(cd "$(dirname "$0")" && pwd)
cmd="\"C:\\Program Files\\WSL\\wslg.exe\" -d archlinux -u $(id -un) -- $d/claude-focus \"%1\""
k='HKCU\Software\Classes\claude-focus'
reg.exe add "$k" /ve /d 'URL:Claude Focus' /f >/dev/null
reg.exe add "$k" /v 'URL Protocol' /d '' /f >/dev/null
reg.exe add "$k\\shell\\open\\command" /ve /d "$cmd" /f >/dev/null
echo "registered: $cmd"
