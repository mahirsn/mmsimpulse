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
# session. `--uninstall` puts back what was displaced.
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
    # Restore what these keys displaced. Deleting the entries rather than
    # writing a key back is what restores them: the install path overwrote both
    # the binding and the default column with "none", so leaving a value behind
    # would leave System Settings > Reset to Defaults with nothing to reset to.
    for n in 1 2 3 4 5 6 7 8 9 0; do
        kwriteconfig6 --file kglobalshortcutsrc --group plasmashell \
            --key "activate task manager entry $n" --delete 2>/dev/null || true
    done
    for swap in "Swap Tiled Window Left" "Swap Tiled Window Right"; do
        kwriteconfig6 --file kglobalshortcutsrc --group kwin \
            --key "$swap" --delete 2>/dev/null || true
    done
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

# A running kglobalacceld keeps its own copy and writes it back over the file,
# so the file alone only takes effect after a fresh login -- and was undone
# before that more than once. Tell the running daemon too.
#
# KWin hands kglobalaccel the character a key produces, with Shift already
# applied: Super+Shift+2 arrives as Super+@ on a US layout and as Super+' on a
# Turkish one, so "Meta+Shift+2" alone never fires. The keys are therefore
# worked out from the configured layouts (kxkbrc), level 1 for switching and
# level 2 for send-and-follow.
keycodes() {
    python3 - "$(kreadconfig6 --file kxkbrc --group Layout --key LayoutList 2>/dev/null)" <<'PY'
import ctypes, ctypes.util, sys
META, SHIFT, ALT = 0x10000000, 0x02000000, 0x08000000
x = ctypes.CDLL(ctypes.util.find_library("xkbcommon"))
class Names(ctypes.Structure):
    _fields_ = [(f, ctypes.c_char_p) for f in ("rules", "model", "layout", "variant", "options")]
x.xkb_context_new.restype = ctypes.c_void_p
x.xkb_keymap_new_from_names.restype = ctypes.c_void_p
x.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.POINTER(Names), ctypes.c_int]
x.xkb_keymap_key_get_syms_by_level.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                               ctypes.c_uint32, ctypes.POINTER(ctypes.POINTER(ctypes.c_uint32))]
x.xkb_keysym_to_utf32.restype = ctypes.c_uint32
ctx = x.xkb_context_new(0)

def qt(ch):                      # Qt key codes are the upper-case character
    return ord(ch.upper()) if len(ch.upper()) == 1 else ord(ch)

layouts = [l for l in sys.argv[1].split(",") if l] or ["us"]
switch, follow = [[] for _ in range(10)], [[] for _ in range(10)]
for lay in layouts:
    km = x.xkb_keymap_new_from_names(ctx, ctypes.byref(Names(None, None, lay.encode(), None, None)), 0)
    if not km:
        continue
    for i in range(10):                     # evdev KEY_1..KEY_0 are 2..11
        for level, into in ((0, switch), (1, follow)):
            p = ctypes.POINTER(ctypes.c_uint32)()
            if x.xkb_keymap_key_get_syms_by_level(km, i + 2 + 8, 0, level, ctypes.byref(p)):
                c = x.xkb_keysym_to_utf32(p[0])
                if c and qt(chr(c)) not in into[i]:
                    into[i].append(qt(chr(c)))
for i in range(10):
    n = i + 1
    s = switch[i]
    f = [k for k in follow[i] if k not in s]
    print(f"kwin\tSwitch to Desktop {n}\t" + " ".join(str(META + k) for k in s))
    print(f"kwin\tWindow to Desktop {n}\t" + " ".join(str(META + ALT + k) for k in s))
    print(f"mmsimpulse-workspace{n}.desktop\t_launch\t" + " ".join(str(META + k) for k in f))
PY
}
META=$((0x10000000)); SHIFT=$((0x02000000))
LEFT=$((0x01000012)); RIGHT=$((0x01000014))
live() {    # live COMPONENT ACTION [QT_KEY...]
    local c=$1 a=$2 keys=() k
    shift 2
    keys=($#)
    for k in "$@"; do keys+=(4 "$k" 0 0 0); done
    busctl --user call org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel \
        setForeignShortcutKeys 'asa(ai)' 4 "$c" "$a" "" "" "${keys[@]}" >/dev/null 2>&1 || true
}
if busctl --user status org.kde.kglobalaccel >/dev/null 2>&1; then
    for n in 1 2 3 4 5 6 7 8 9 0; do
        live plasmashell "activate task manager entry $n"
    done
    live kwin "Swap Tiled Window Left"
    live kwin "Swap Tiled Window Right"
    while IFS=$'\t' read -r comp action codes; do
        # shellcheck disable=SC2086
        live "$comp" "$action" $codes
    done < <(keycodes)
    live kwin "Window One Desktop to the Left" $((META + SHIFT + LEFT))
    live kwin "Window One Desktop to the Right" $((META + SHIFT + RIGHT))
fi

cat <<MSG
Workspace keys installed:

  Meta+1..0          switch to workspace 1..10   (KWin, per focused monitor)
  Meta+Alt+1..0      send window there
  Meta+Shift+1..0    send window there and follow
  Meta+Ctrl+Left/Right    previous / next workspace
  Meta+Shift+Left/Right   send window to previous / next workspace

Existing bindings are only rewritten where they were dead: plasmashell's task
manager entries (plasmashell never runs here) and the tiling swaps (tiling is
off). They work right away.
MSG
