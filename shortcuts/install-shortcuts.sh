#!/bin/bash
# Install mmsimpulse's shell shortcuts into KDE's global shortcut system.
#
# kglobalacceld's KServiceActionComponent launches a .desktop entry when its
# shortcut fires.  So each shell action becomes a
# hidden .desktop that runs `qs -c mmsimpulse ipc call <name> trigger`, and the
# default key lives in X-KDE-Shortcuts.  kglobalacceld only notices entries
# that ksycoca indexes, hence the kbuildsycoca6 run at the end.
#
# Nothing here edits ~/.config/kglobalshortcutsrc.  That file is shared with
# another session on this machine and rewriting it would change bindings
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
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        name=$(cut -f1 <<< "$line")
        kwriteconfig6 --file kglobalshortcutsrc --group services \
            --group "$CONFIG-$name.desktop" --key _launch --delete 2>/dev/null || true
    done < "$TSV"
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    echo "Removed. Rebind or restart the session for kglobalacceld to drop them."
    exit 0
fi

mkdir -p "$APPDIR"
conflicts=()
written=()

key_taken() {
    # A key is taken when it is some action's *live* binding — the first field.
    # A suggested default in the second field is only an offer, not a claim.
    # Compared as a whole field rather than matched as a pattern: a key name
    # is full of regex metacharacters, and "Meta+Space" as an ERE matches
    # "MetaaSpace" but never itself.
    [[ -f "$SHORTCUTSRC" ]] || return 1
    cut -d= -f2- "$SHORTCUTSRC" | cut -d, -f1 | grep -qxF "$1"
}

# Read whole lines and cut the columns: `IFS=$'\t' read` folds consecutive
# tabs, which silently shifts the description into the key column on any row
# that has no suggested key.
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    name=$(cut -f1 <<< "$line")
    keys=$(cut -f2 <<< "$line")
    desc=$(cut -f3 <<< "$line")

    # Only worth mentioning as a heads-up now: the key is offered as the KCM's
    # default, not bound, so nothing is actually stolen.
    if [[ -n "$keys" && -f "$SHORTCUTSRC" ]] && grep -qF "=$keys," "$SHORTCUTSRC"; then
        conflicts+=("$keys ($name)")
    fi

    # X-KDE-Shortcuts is what makes kglobalacceld notice the entry at all, so
    # it has to carry a key. The binding written below is what decides whether
    # that key is actually live, and it is not.
    cat > "$APPDIR/$CONFIG-$name.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=mmsimpulse: $desc
Exec=env -u QT_QPA_PLATFORM qs -c $CONFIG ipc call $name trigger
NoDisplay=true
Terminal=false
X-KDE-GlobalAccel-CommandShortcut=true
X-KDE-Shortcuts=$keys
DESKTOP

    # Register the action unbound: the third field is the friendly name, the
    # second the default the Shortcuts KCM offers, the first the live key.
    # Anything already in the file is a binding the user chose, so leave it.
    #
    # The launcher is the one exception. A session with no way to open the
    # launcher has no way to start anything, so it gets Meta+Space — but only
    # if nothing else holds that key.
    entry="$CONFIG-$name.desktop"
    current="$(kreadconfig6 --file kglobalshortcutsrc --group services --group "$entry" \
        --key _launch 2>/dev/null)"
    # The live binding is the first comma-separated field. kglobalacceld writes
    # an unbound action as an empty field, not as "none", so both count as
    # "nothing here yet" — otherwise re-running would never bind the launcher.
    bound="${current%%,*}"
    if [[ -n "$current" && -n "$bound" && "$bound" != none ]]; then
        continue
    fi
    live=none
    if [[ "$name" == searchToggle ]] && ! key_taken "Meta+Space"; then
        live="Meta+Space"
    fi
    kwriteconfig6 --file kglobalshortcutsrc --group services --group "$entry" \
        --key _k_friendly_name "mmsimpulse: $desc"
    # kglobalaccel reads this value as one key sequence, not as the
    # active,default,friendly triple the [kwin] group uses: writing
    # "Meta+Shift+1,Meta+Shift+1,..." registers a two-chord sequence that a single
    # press can never match. The key on its own is what works.
    kwriteconfig6 --file kglobalshortcutsrc --group services --group "$entry" \
        --key _launch "$live"
    written+=("$entry"$'\t'"$desc"$'\t'"$live")
done < "$TSV"

kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

# kglobalshortcutsrc is only read when the daemon starts. KWin 6.5 embeds
# kglobalacceld, so installing from inside a running session hands the new
# .desktop files to a daemon that is already up: it registers each one with the
# key in X-KDE-Shortcuts as the *live* binding and never looks at the _launch
# values written above. That is the opposite of what this script decided —
# every suggested default ends up bound, and the launcher key is not. D-Bus is
# the only thing the daemon listens to while it runs, so say it again there.
if busctl --user status org.kde.kglobalaccel >/dev/null 2>&1; then
    for row in "${written[@]}"; do
        IFS=$'\t' read -r entry desc live <<< "$row"
        # An empty key list is what unbinds one. Meta+Space is the single key
        # this script binds, so its Qt keycode is spelled out rather than
        # parsed: Qt::MetaModifier (0x10000000) | Qt::Key_Space (0x20).
        keys=0
        [[ "$live" == "Meta+Space" ]] && keys="1 268435488"
        busctl --user call org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel \
            setForeignShortcut asai 4 "$entry" _launch "mmsimpulse: $desc" \
            "mmsimpulse: $desc" $keys >/dev/null 2>&1 || true
    done
fi
echo "Installed $(ls "$APPDIR"/$CONFIG-*.desktop | wc -l) shortcut entries in $APPDIR"

echo "Only the launcher is bound by default (Meta+Space). Assign the rest in"
echo "System Settings > Shortcuts, search for \"mmsimpulse\"."

if (( ${#conflicts[@]} )); then
    printf '\nThese suggested defaults are already taken elsewhere, so pick something\nelse for them:\n'
    printf '  %s\n' "${conflicts[@]}"
fi
