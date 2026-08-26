#!/bin/bash
# mmsimpulse installer.
#
# Installs a KineticWE session that runs the mmsimpulse Quickshell shell instead
# of Noctalia, without touching the existing KineticWE+Noctalia session.
#
#   ./install.sh            install / update
#   ./install.sh --shell    only refresh the shell config (fast iteration)
set -euo pipefail

REPO="$(dirname "$(readlink -f "$0")")"
CONFIG=mmsimpulse
SHELL_SRC="${MMSIMPULSE_BASE:-$HOME/.config/quickshell/end4-pC}"
SHELL_DIR="$HOME/.config/quickshell/$CONFIG"
BIN="$HOME/.local/bin"
SHIM="$HOME/.local/share/$CONFIG/bin"
SHELL_CONFIG="$HOME/.config/$CONFIG"
SESSION="/usr/share/wayland-sessions/$CONFIG.desktop"

command -v kinetic-we >/dev/null || { echo "kinetic-we not found; install the kineticwe package first." >&2; exit 1; }
[[ -d "$SHELL_SRC" ]] || { echo "Base shell not found at $SHELL_SRC (set MMSIMPULSE_BASE)." >&2; exit 1; }

# --- shell config ----------------------------------------------------------
# The upstream skin is copied wholesale and the KWin-specific files are laid
# over it, so upstream stays a clean base you can re-copy after it updates.
echo "==> shell config -> $SHELL_DIR"
# Assembled in a staging directory and swapped into place. A running shell
# watches this tree and hot-reloads on any change, so copying into it directly
# makes it reload a half-written config and fail to load.
STAGE="$SHELL_DIR.new"
rm -rf "$STAGE"
mkdir -p "$STAGE"
rsync -a --exclude '.git' "$SHELL_SRC/" "$STAGE/"
cp "$REPO"/overlay/services/*.qml "$STAGE/services/"
mkdir -p "$STAGE/scripts/kwin"
cp "$REPO"/kwin-script/*.js "$STAGE/scripts/kwin/"
python3 "$REPO/overlay/patch-shell.py" "$STAGE"

# Plugin widgets live beside the skin rather than inside its modules. Carry
# over anything already installed so a plugin the user added by hand is not
# deleted by a reinstall.
mkdir -p "$STAGE/plugins"
[[ -d "$SHELL_DIR/plugins" ]] && cp -a "$SHELL_DIR/plugins/." "$STAGE/plugins/"
cp -a "$REPO"/plugins/. "$STAGE/plugins/"
chmod +x "$STAGE"/plugins/*/*.py 2>/dev/null || true
rm -rf "$SHELL_DIR.old"
[[ -d "$SHELL_DIR" ]] && mv "$SHELL_DIR" "$SHELL_DIR.old"
mv "$STAGE" "$SHELL_DIR"
rm -rf "$SHELL_DIR.old"

# The skin defaults to ~/.config/illogical-impulse, which the Hyprland session
# also writes to; patch-shell.py points this copy at ~/.config/mmsimpulse, so
# seed it once from whatever is already configured.
if [[ ! -d "$SHELL_CONFIG" && -d "$HOME/.config/illogical-impulse" ]]; then
    echo "==> seeding $SHELL_CONFIG from ~/.config/illogical-impulse"
    cp -a "$HOME/.config/illogical-impulse" "$SHELL_CONFIG"
fi
mkdir -p "$SHELL_CONFIG"

[[ "${1:-}" == "--shell" ]] && { echo "Done. Reload with: pkill -f 'qs -c $CONFIG'; qs -c $CONFIG"; exit 0; }

# --- bridge ----------------------------------------------------------------
echo "==> bridge -> $BIN"
mkdir -p "$BIN"
install -m755 "$REPO/bin/mmsimpulse-kwin-bridge" "$BIN/"
mkdir -p "$SHIM"
install -m755 "$REPO/overlay/bin/noctalia" "$SHIM/"

# --- session script --------------------------------------------------------
# Derived from the installed start-kineticwe rather than forked, so a kineticwe
# upgrade is picked up by re-running this script. Every substitution is checked:
# a silent miss would start the real Noctalia in our session.
echo "==> session script -> $BIN/start-$CONFIG"
python3 - "$BIN/start-$CONFIG" <<'PY'
import pathlib, sys

src = pathlib.Path("/usr/bin/start-kineticwe").read_text()
edits = [
    # `|| true` matters: start-kineticwe runs under `set -e`, which the
    # supervisor subshell inherits, so the first non-zero exit from the shell
    # kills the loop that is supposed to restart it. Upstream has the same bug
    # with Noctalia — the shell comes back once and never again.
    ('        noctalia >"$HOME/.local/share/noctalia.log" 2>&1',
     '        qs -c mmsimpulse >"$HOME/.local/share/mmsimpulse.log" 2>&1 || true'),
    ('        echo "noctalia exited (code $?), restarting in 2s..."',
     '        echo "mmsimpulse exited (code $?), restarting in 2s..."'),
    # The Hyprland session exports QT_QPA_PLATFORM="wayland;xcb" and the user
    # systemd manager outlives a logout, so the value leaks into this session.
    # Quickshell's IPC client does not recognise the multi-value form, decides
    # the caller is on X11, and then refuses to talk to a shell it recorded as
    # Wayland — which silently breaks every shortcut kglobalaccel launches.
    ('dbus-update-activation-environment --systemd --all 2>/dev/null || true',
     'unset QT_QPA_PLATFORM\n'
     'systemctl --user unset-environment QT_QPA_PLATFORM 2>/dev/null || true\n'
     'dbus-update-activation-environment --systemd --all 2>/dev/null || true'),
    # start-kineticwe restarts the portals but leaves other compositors'
    # backends running. A leftover xdg-desktop-portal-hyprland keeps owning
    # its impl name with no Hyprland behind it, which is a trap for anything
    # that negotiates ScreenCast.
    ('killall -q xdg-desktop-portal-kde xdg-desktop-portal xdg-desktop-portal-gtk xdg-document-portal 2>/dev/null || true',
     'killall -q xdg-desktop-portal-kde xdg-desktop-portal xdg-desktop-portal-gtk xdg-document-portal '
     'xdg-desktop-portal-hyprland xdg-desktop-portal-wlr 2>/dev/null || true'),
    ('pkill -x noctalia 2>/dev/null || true',
     'pkill -f "qs -c mmsimpulse" 2>/dev/null || true'),
    # the bridge lives in ~/.local/bin, which a display-manager session does
    # not necessarily have on PATH
    ('export PATH="$INSTALL_PREFIX/bin:$PATH"',
     'export PATH="$HOME/.local/share/mmsimpulse/bin:$HOME/.local/bin:$INSTALL_PREFIX/bin:$PATH"'),
]
for old, new in edits:
    if old not in src:
        sys.exit(f"start-kineticwe changed; this line is gone:\n  {old}")
    src = src.replace(old, new)

out = pathlib.Path(sys.argv[1])
out.write_text(src)
out.chmod(0o755)
PY

# --- session entry ---------------------------------------------------------
# SDDM only reads /usr/share/wayland-sessions, so this one file needs root.
# Skip the sudo prompt when the entry is already in place and unchanged.
if ! sed "s|@BIN@|$BIN|" "$REPO/session/$CONFIG.desktop" | cmp -s - "$SESSION" 2>/dev/null; then
    echo "==> session entry -> $SESSION (sudo)"
    sed "s|@BIN@|$BIN|" "$REPO/session/$CONFIG.desktop" | sudo tee "$SESSION" >/dev/null
else
    echo "==> session entry already current"
fi

# --- shortcuts -------------------------------------------------------------
"$REPO/shortcuts/install-shortcuts.sh"

cat <<MSG

Done. Log out and pick "mmsimpulse" in SDDM.
Your KineticWE+Noctalia session is untouched.

Iterate without logging out:  pkill -f "qs -c $CONFIG"; qs -c $CONFIG
Checklist:                    $REPO/TESTING.md
MSG
