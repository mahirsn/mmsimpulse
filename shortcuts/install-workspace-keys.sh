#!/bin/bash
# Hyprland-style workspace keys.
#
# Separate from install-shortcuts.sh on purpose: that one installs the shell's
# own actions and deliberately binds nothing, while this is an explicit opt-in
# that does bind keys.
#
# Most of it is KWin's own actions rather than anything of ours. "Switch to
# Desktop N" already exists, already honours [Windows] PerOutputVirtualDesktops
# (it resolves the active output), and is editable in System Settings. The one
# gap is move-and-follow — Hyprland's Super+Shift+N follows the window, KWin's
# "Window to Desktop N" does not — so those ten go through the bridge.
#
# Bindings live in ~/.config/kglobalshortcutsrc, which is shared with the daily
# KineticWE session. `--uninstall` puts back what was displaced.
set -euo pipefail

CONFIG=mmsimpulse
APPDIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
KEYS=(1 2 3 4 5 6 7 8 9 0)

kw() { kwriteconfig6 --file kglobalshortcutsrc --group "$1" --key "$2" "$3"; }

if [[ "${1:-}" == "--uninstall" ]]; then
    for i in "${!KEYS[@]}"; do
        n=$((i + 1))
        kw kwin "Switch to Desktop $n" "none,none,Switch to Desktop $n"
        kw kwin "Window to Desktop $n" "none,none,Window to Desktop $n"
        kwriteconfig6 --file kglobalshortcutsrc --group services \
            --group "$CONFIG-workspace$n.desktop" --key _launch --delete 2>/dev/null || true
    done
    rm -fv "$APPDIR"/$CONFIG-workspace*.desktop
    # Restore what these keys displaced.
    kw plasmashell "activate task manager entry 1" "Meta+1,Meta+1,Activate Task Manager Entry 1"
    kw kwin "Window One Desktop to the Left" "Meta+Ctrl+Shift+Left,Meta+Ctrl+Shift+Left,Window One Desktop to the Left"
    kw kwin "Window One Desktop to the Right" "Meta+Ctrl+Shift+Right,Meta+Ctrl+Shift+Right,Window One Desktop to the Right"
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    echo "Removed. Log out and back in for kglobalacceld to drop them."
    exit 0
fi

mkdir -p "$APPDIR"

for i in "${!KEYS[@]}"; do
    n=$((i + 1))
    key="${KEYS[$i]}"

    # Meta+N — switch. KWin's own action, so it follows the focused output.
    kw kwin "Switch to Desktop $n" "Meta+$key,Meta+$key,Switch to Desktop $n"

    # Meta+Alt+N — send the window without following.
    kw kwin "Window to Desktop $n" "Meta+Alt+$key,Meta+Alt+$key,Window to Desktop $n"

    # Meta+Shift+N — send and follow. No KWin action does this, so it calls the
    # bridge, which runs a one-shot KWin script.
    cat > "$APPDIR/$CONFIG-workspace$n.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=mmsimpulse: Send window to workspace $n and follow
Exec=busctl --user call org.mmsimpulse.KWin /Windows org.mmsimpulse.KWin MoveActiveWindowToDesktop ib $n true
NoDisplay=true
Terminal=false
X-KDE-GlobalAccel-CommandShortcut=true
X-KDE-Shortcuts=Meta+Shift+$key
DESKTOP
    kwriteconfig6 --file kglobalshortcutsrc --group services \
        --group "$CONFIG-workspace$n.desktop" --key _k_friendly_name \
        "mmsimpulse: Send window to workspace $n and follow"
    # kglobalaccel reads this value as one key sequence, not as the
    # active,default,friendly triple the [kwin] group uses: writing
    # "Meta+Shift+1,Meta+Shift+1,..." registers a two-chord sequence that a single
    # press can never match. The key on its own is what works.
    kwriteconfig6 --file kglobalshortcutsrc --group services \
        --group "$CONFIG-workspace$n.desktop" --key _launch "Meta+Shift+$key"
done

# Meta+1..9 belonged to plasmashell's task manager entries, which nothing in
# this session runs — plasmashell is never started here.
for n in 1 2 3 4 5 6 7 8 9 0; do
    kw plasmashell "activate task manager entry $n" "none,none,Activate Task Manager Entry $n"
done

# Meta+Shift+arrows were tiling swaps, and tiling is off.
kw kwin "Swap Tiled Window Left" "none,none,Swap Tiled Window Left"
kw kwin "Swap Tiled Window Right" "none,none,Swap Tiled Window Right"
kw kwin "Window One Desktop to the Left" "Meta+Shift+Left,Meta+Ctrl+Shift+Left,Window One Desktop to the Left"
kw kwin "Window One Desktop to the Right" "Meta+Shift+Right,Meta+Ctrl+Shift+Right,Window One Desktop to the Right"

kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

cat <<MSG
Workspace keys installed:

  Meta+1..0          switch to workspace 1..10   (KWin, per focused monitor)
  Meta+Alt+1..0      send window there
  Meta+Shift+1..0    send window there and follow
  Meta+Ctrl+Left/Right    previous / next workspace
  Meta+Shift+Left/Right   send window to previous / next workspace

Existing bindings are only rewritten where they were dead: plasmashell's task
manager entries (plasmashell never runs here) and the tiling swaps (tiling is
off). Log out and back in for kglobalacceld to pick all of this up.
MSG
