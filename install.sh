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
mkdir -p "$SHELL_DIR"
rsync -a --delete --exclude '.git' "$SHELL_SRC/" "$SHELL_DIR/"
cp -v "$REPO"/overlay/services/*.qml "$SHELL_DIR/services/"
mkdir -p "$SHELL_DIR/scripts/kwin"
cp -v "$REPO"/kwin-script/*.js "$SHELL_DIR/scripts/kwin/"
python3 "$REPO/overlay/patch-shell.py" "$SHELL_DIR"

# The skin defaults to ~/.config/illogical-impulse, which the Hyprland session
# also writes to; patch-shell.py points this copy at ~/.config/mmsimpulse, so
# seed it once from whatever is already configured.
if [[ ! -d "$SHELL_CONFIG" && -d "$HOME/.config/illogical-impulse" ]]; then
    echo "==> seeding $SHELL_CONFIG from ~/.config/illogical-impulse"
    cp -a "$HOME/.config/illogical-impulse" "$SHELL_CONFIG"
fi
mkdir -p "$SHELL_CONFIG"

[[ "${1:-}" == "--shell" ]] && { echo "Done. Reload with: killall qs; qs -c $CONFIG"; exit 0; }

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
    ('        noctalia >"$HOME/.local/share/noctalia.log" 2>&1',
     '        qs -c mmsimpulse >"$HOME/.local/share/mmsimpulse.log" 2>&1'),
    ('        echo "noctalia exited (code $?), restarting in 2s..."',
     '        echo "mmsimpulse exited (code $?), restarting in 2s..."'),
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
echo "==> session entry -> $SESSION (sudo)"
sed "s|@BIN@|$BIN|" "$REPO/session/$CONFIG.desktop" | sudo tee "$SESSION" >/dev/null

# --- shortcuts -------------------------------------------------------------
"$REPO/shortcuts/install-shortcuts.sh"

cat <<MSG

Done. Log out and pick "mmsimpulse" in SDDM.
Your KineticWE+Noctalia session is untouched.

Iterate without logging out:  killall qs; qs -c $CONFIG
Checklist:                    $REPO/TESTING.md
MSG
