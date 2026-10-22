#!/bin/bash
# Installs the NTAKO Timer GNOME Shell extension for the current user.
#
#   ./install.sh          symlink (development: edits apply on next login)
#   ./install.sh --copy   copy the files instead
#
# On Wayland, GNOME Shell only discovers a new extension after logging out
# and back in; then enable it with the command printed at the end.

set -euo pipefail

UUID="ntako-timer@ntako.com"
SRC="$(cd "$(dirname "$0")" && pwd)/$UUID"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$UUID"

glib-compile-schemas "$SRC/schemas"

mkdir -p "$(dirname "$DEST")"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    rm -rf "$DEST"
fi
if [ "${1:-}" = "--copy" ]; then
    cp -r "$SRC" "$DEST"
else
    ln -s "$SRC" "$DEST"
fi

echo "Installata in $DEST"
echo "Se è la prima installazione: esci e rientra nella sessione GNOME, poi:"
echo "  gnome-extensions enable $UUID"
