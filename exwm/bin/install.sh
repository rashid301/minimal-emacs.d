#!/bin/sh
# Install the /mnt-aware PATH wrappers into ~/.local/bin (symlinks, so edits here apply live).
mkdir -p ~/.local/bin
d=$(cd "$(dirname "$0")" && pwd)
for f in git pwsh-c winwrap wt rg fd; do ln -sfn "$d/$f" ~/.local/bin/$f; done
