#!/bin/bash
# Install mmsimpulse's shell shortcuts into KDE's global shortcut system.
#
# KineticWE embeds kglobalacceld, whose KServiceActionComponent launches a
# .desktop entry when its shortcut fires.  So each shell action becomes a
# hidden .desktop that runs `qs -c mmsimpulse ipc call <name> trigger`, and the
# default key lives in X-KDE-Shortcuts.  kglobalacceld only notices entries
# that ksycoca indexes, hence the kbuildsycoca6 run at the end.
#
# Nothing here edits ~/.config/kglobalshortcutsrc.  That file is shared with
# the daily KineticWE+Noctalia session and rewriting it would change bindings
# there; the shortcuts show up in System Settings > Shortcuts anyway, and
# rebinding one from there is what writes to it.
#
# Caveat worth knowing: ~/.local/share/applications is not per session, so
# these entries are visible to the daily session too and hold the same keys
# there.  In that session the command is a no-op (no mmsimpulse instance to
# talk to).  `--uninstall` removes them again.
set -euo pipefail

CONFIG=mmsimpulse
APPDIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
TSV="$(dirname "$(readlink -f "$0")")/shortcuts.tsv"
SHORTCUTSRC="${XDG_CONFIG_HOME:-$HOME/.config}/kglobalshortcutsrc"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -fv "$APPDIR"/$CONFIG-*.desktop
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    echo "Removed. Rebind or restart the session for kglobalacceld to drop them."
    exit 0
fi

mkdir -p "$APPDIR"
conflicts=()

while IFS=$'\t' read -r name keys desc; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue

    # Warn rather than steal: a key already claimed in kglobalshortcutsrc would
    # end up bound twice and only one owner would win, silently.
    if [[ -n "$keys" && -f "$SHORTCUTSRC" ]] && grep -qF "=$keys," "$SHORTCUTSRC"; then
        conflicts+=("$keys ($name)")
    fi

    cat > "$APPDIR/$CONFIG-$name.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=mmsimpulse: $desc
Exec=qs -c $CONFIG ipc call $name trigger
NoDisplay=true
Terminal=false
X-KDE-GlobalAccel-CommandShortcut=true
X-KDE-Shortcuts=$keys
DESKTOP
done < "$TSV"

kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
echo "Installed $(ls "$APPDIR"/$CONFIG-*.desktop | wc -l) shortcut entries in $APPDIR"

if (( ${#conflicts[@]} )); then
    printf '\nAlready bound elsewhere, rebind these in System Settings > Shortcuts:\n'
    printf '  %s\n' "${conflicts[@]}"
fi
