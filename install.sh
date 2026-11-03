#!/bin/bash
# mmsimpulse installer.
#
# Sets up a Wayland session made of a KWin compositor and nothing else — no
# desktop environment, no plasmashell, no shell of its own. The shell is
# yours to pick (README, "Shells"). Any KWin 6 works, as long as it provides
# kwin_wayland.
#
# Everything it writes is under $HOME, except the login-manager session entry
# and the KWin plugins.
#
#   ./install.sh            install / update
set -euo pipefail

REPO="$(dirname "$(readlink -f "$0")")"
CONFIG=mmsimpulse
BIN="$HOME/.local/bin"
DATA="$HOME/.local/share/$CONFIG"
SESSION="/usr/share/wayland-sessions/$CONFIG.desktop"

command -v kwin_wayland >/dev/null || {
    echo "kwin_wayland not found. Install the kwin package." >&2
    exit 1
}

# --- bridge ----------------------------------------------------------------
echo "==> bridge -> $BIN"
mkdir -p "$BIN"
install -m755 "$REPO"/bin/mmsimpulse-* "$BIN/"
# The KWin script behind the workspace pool and Meta+1..0; the bridge loads it.
mkdir -p "$DATA/kwin"
install -m644 "$REPO"/kwin-script/*.js "$DATA/kwin/"
# How to run each shell; the session reads them (start-mmsimpulse).
mkdir -p "$DATA/profiles"
install -m644 "$REPO"/profiles/* "$DATA/profiles/"

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
    # Not fatal. Without a terminal there is nowhere to type a password, and
    # aborting here would skip the portal config and the shortcuts for the sake
    # of one file the login manager may already have.
    if ! sed "s|@BIN@|$BIN|" "$REPO/session/$CONFIG.desktop" | sudo tee "$SESSION" >/dev/null; then
        echo "    could not write it; run this by hand:" >&2
        echo "    sudo cp <(sed 's|@BIN@|$BIN|' $REPO/session/$CONFIG.desktop) $SESSION" >&2
    fi
fi

# --- KWin plugins ------------------------------------------------------------
# Compiled against KWin, so they have to match the installed KWin. The Arch
# package builds them; from a checkout each is built here when it is missing or
# older than KWin (KWin was updated) or than its source. Needs cmake,
# extra-cmake-modules and KWin's development headers; the protocol plugin also
# needs wayland-protocols and wlr-protocols. Without them the rest still works,
# minus what the plugin does.
PLUGINS="$(qmake6 -query QT_INSTALL_PLUGINS 2>/dev/null || qtpaths6 --query QT_INSTALL_PLUGINS 2>/dev/null || true)"
owned_by_package() { command -v pacman >/dev/null && pacman -Qqo "$1" >/dev/null 2>&1; }
build_kwin_plugin() { # source dir, installed file, what it gives
    local src="$REPO/$1" so="$PLUGINS/$2"
    [[ -n "$PLUGINS" ]] && ! owned_by_package "$so" || return 0
    [[ ! -e "$so" || "$so" -ot "$(command -v kwin_wayland)" ]] \
        || [[ -n "$(find "$src" -newer "$so" -print -quit)" ]] || return 0
    echo "==> $1 (sudo to install)"
    local build
    build="$(mktemp -d)"
    if cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >"$build.log" 2>&1 \
       && cmake --build "$build" >>"$build.log" 2>&1 \
       && sudo cmake --install "$build" >>"$build.log" 2>&1; then
        rm -rf "$build" "$build.log"
    else
        echo "    not built (see $build.log); $3 needs cmake," >&2
        echo "    extra-cmake-modules and KWin's development headers" >&2
        rm -rf "$build"
    fi
}
build_kwin_plugin kwin-effect kwin/effects/plugins/mmsimpulse_workspaceshare.so "workspace sharing"
# Window list and workspaces for shells written for other compositors. KWin
# loads it at its next start.
build_kwin_plugin kwin-mmsimpulse kwin/plugins/kwin-mmsimpulse.so "other shells' window list and workspaces"

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

# --- config ----------------------------------------------------------------
# The user's own file, written once and never again. A Hyprland or niri
# config found here is offered at its end, commented out.
MMS_LUA="${XDG_CONFIG_HOME:-$HOME/.config}/$CONFIG/$CONFIG.lua"
if [[ ! -f "$MMS_LUA" ]]; then
    echo "==> config -> $MMS_LUA"
    mkdir -p "$(dirname "$MMS_LUA")"
    {
        cat "$REPO/config/$CONFIG.lua"
        for f in hypr/hyprland.lua hypr/hyprland.conf niri/config.kdl; do
            [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/$f" ]] && echo "-- mms.source(\"~/.config/$f\")"
        done
    } > "$MMS_LUA"
fi

# --- shortcuts -------------------------------------------------------------
# The workspace-sharing effect, if the package installed it, without waiting
# for the next login.
busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects loadEffect s \
    mmsimpulse_workspaceshare >/dev/null 2>&1 || true

"$REPO/shortcuts/install-shortcuts.sh"
# Super+1..0 for workspaces, as on Hyprland.
"$REPO/shortcuts/install-workspace-keys.sh" >/dev/null

cat <<MSG

Done. Pick a shell (README, "Shells"), for example:
    echo dux > ~/.config/$CONFIG/shell
then log out and pick "mmsimpulse" in SDDM.
Any other session on this machine is untouched.
MSG
