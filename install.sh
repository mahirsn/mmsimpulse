#!/bin/bash
# mmsimpulse installer.
#
# Sets up a Wayland session made of a KWin compositor and this shell — no
# desktop environment, no plasmashell. Any KWin 6 works, as long as it
# provides kwin_wayland.
#
# Everything it writes is under $HOME, except the login-manager session entry.
#
#   ./install.sh            install / update
#   ./install.sh --shell    only refresh the shell config (fast iteration)
#   ./install.sh --yes      answer prompts with their default (for scripts)
set -euo pipefail

REPO="$(dirname "$(readlink -f "$0")")"
CONFIG=mmsimpulse
# This repository is the KWin-specific half; the widgets themselves are
# pctrade/end4-pC. Point MMSIMPULSE_BASE at an existing copy to reuse it,
# or let the installer fetch one.
SHELL_SRC="${MMSIMPULSE_BASE:-$HOME/.config/quickshell/end4-pC}"
BASE_REPO="${MMSIMPULSE_BASE_REPO:-https://github.com/pctrade/end4-pC.git}"
ASSUME_YES=0
SHELL_DIR="$HOME/.config/quickshell/$CONFIG"
BIN="$HOME/.local/bin"
SHIM="$HOME/.local/share/$CONFIG/bin"
SHELL_CONFIG="$HOME/.config/$CONFIG"
SESSION="/usr/share/wayland-sessions/$CONFIG.desktop"

for arg in "$@"; do [[ "$arg" == "--yes" ]] && ASSUME_YES=1; done

command -v kwin_wayland >/dev/null || {
    echo "kwin_wayland not found. Install the kwin package." >&2
    exit 1
}

ask() {
    # $1 question, $2 default (y/n). Non-interactive runs take the default.
    local reply
    if (( ASSUME_YES )) || [[ ! -t 0 ]]; then reply="$2"; else
        read -rp "$1 [$([[ $2 == y ]] && echo 'Y/n' || echo 'y/N')] " reply
        reply="${reply:-$2}"
    fi
    [[ "${reply,,}" == y* ]]
}

if [[ ! -d "$SHELL_SRC" ]]; then
    echo "The base skin (pctrade/end4-pC) is not at $SHELL_SRC."
    if ask "Clone it there now?" y; then
        command -v git >/dev/null || { echo "git is needed to clone it." >&2; exit 1; }
        git clone --depth 1 "$BASE_REPO" "$SHELL_SRC"
    else
        echo "Nothing to build on. Install it yourself and re-run, or set" >&2
        echo "MMSIMPULSE_BASE to an existing copy." >&2
        exit 1
    fi
fi

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
# The bar overlay is optional — there is nothing in it right now, and a glob
# that matches nothing would abort the install under `set -e`.
if compgen -G "$REPO/overlay/bar/*.qml" >/dev/null; then
    cp "$REPO"/overlay/bar/*.qml "$STAGE/modules/ii/bar/"
fi
mkdir -p "$STAGE/scripts/kwin"
cp "$REPO"/kwin-script/*.js "$STAGE/scripts/kwin/"
python3 "$REPO/overlay/patch-shell.py" "$STAGE"

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
install -m755 "$REPO"/bin/mmsimpulse-* "$BIN/"
# Only useful on a KWin fork that registers its own `noctalia msg …` shortcuts
# inside the compositor; harmless everywhere else, where nothing calls it.
mkdir -p "$SHIM"
install -m755 "$REPO/overlay/bin/noctalia" "$SHIM/"

# --- session script --------------------------------------------------------
echo "==> session script -> $BIN/start-$CONFIG"
install -m755 "$REPO/session/start-$CONFIG" "$BIN/"

# --- session entry ---------------------------------------------------------
# SDDM only reads /usr/share/wayland-sessions, so this one file needs root.
# Skip the sudo prompt when the entry is already in place and unchanged.
# The package ships the same entry pointing at /usr/bin, so accept either
# rendering as current rather than sudo-overwriting a package-owned file.
if sed "s|@BIN@|$BIN|" "$REPO/session/$CONFIG.desktop" | cmp -s - "$SESSION" 2>/dev/null \
   || sed "s|@BIN@|/usr/bin|" "$REPO/session/$CONFIG.desktop" | cmp -s - "$SESSION" 2>/dev/null; then
    echo "==> session entry already current"
else
    echo "==> session entry -> $SESSION (sudo)"
    sed "s|@BIN@|$BIN|" "$REPO/session/$CONFIG.desktop" | sudo tee "$SESSION" >/dev/null
fi

# --- portal backend --------------------------------------------------------
# xdg-desktop-portal reads ~/.config/xdg-desktop-portal/portals.conf for every
# session, and a machine that also runs Hyprland usually has one pinning
# default=hyprland;gtk. In a KDE session that sends screen-share requests to a
# backend with no compositor behind it: the frontend reports no sources at all
# and the picker never appears. A desktop-specific file outranks it and applies
# only here, so the other session keeps its own setup.
PORTAL_CONF="$HOME/.config/xdg-desktop-portal/kde-portals.conf"
if [[ ! -f "$PORTAL_CONF" ]]; then
    echo "==> portal backend -> $PORTAL_CONF"
    mkdir -p "$(dirname "$PORTAL_CONF")"
    cat > "$PORTAL_CONF" <<'PORTAL'
[preferred]
default=kde
org.freedesktop.impl.portal.Settings=kde;gtk;
org.freedesktop.impl.portal.Secret=kwallet
PORTAL
fi

# --- shortcuts -------------------------------------------------------------
"$REPO/shortcuts/install-shortcuts.sh"

cat <<MSG

Done. Log out and pick "mmsimpulse" in SDDM.
Any other session on this machine is untouched.

Iterate without logging out:  pkill -f "qs -c $CONFIG"; qs -c $CONFIG
Checklist:                    $REPO/TESTING.md
MSG
