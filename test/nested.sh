#!/bin/bash
# Run a whole mmsimpulse session nested inside the current Wayland session, so
# the shell can be exercised without logging out.
#
# kinetic-we renders into a window on the host compositor, which means the host
# can screenshot it with grim — no need for KWin's ScreenShot2 pipe dance.
#
#   test/nested.sh up            start the nested compositor and shell
#   test/nested.sh ipc <target>  trigger a shell action inside it
#   test/nested.sh run <cmd...>  run any command against the nested session
#   test/nested.sh shot <name>   screenshot the host screen into test/shots/
#   test/nested.sh logs          tail the nested shell log
#   test/nested.sh down          stop everything
#
# Never touches the host shell. Cleanup targets the nested pids only, so a
# stray `killall qs` cannot take the host session down with it.
set -uo pipefail

CONFIG=mmsimpulse
REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
RUN="${XDG_RUNTIME_DIR:-/tmp}/mmsimpulse-nested"
SHOTS="$REPO/test/shots"
LOG="$RUN/shell.log"

mkdir -p "$RUN" "$SHOTS"

nested_env() {
    [[ -f "$RUN/wayland" ]] || { echo "not running; use: $0 up" >&2; exit 1; }
    # Its own session bus. On the host bus the nested compositor and shell would
    # fight the real ones for org.kde.KWin and org.mmsimpulse.KWin, and every
    # measurement would be of whichever won.
    [[ -s "$RUN/dbus" ]] && export DBUS_SESSION_BUS_ADDRESS="$(head -1 "$RUN/dbus")"
    export WAYLAND_DISPLAY="$(cat "$RUN/wayland")"
    export XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE
    # Inherited from the host session; leaving it set makes Quickshell.Hyprland
    # chase the host's socket, which the real session never has.
    unset HYPRLAND_INSTANCE_SIGNATURE
    export PATH="$HOME/.local/share/$CONFIG/bin:$HOME/.local/bin:$PATH"
    [[ -s "$RUN/display" ]] && export DISPLAY="$(cat "$RUN/display")"
}

case "${1:-}" in
up)
    "$0" down >/dev/null 2>&1

    # --nofork, because with --fork the address never reaches the redirect.
    setsid dbus-daemon --session --nofork --print-address > "$RUN/dbus" 2>/dev/null </dev/null &
    echo $! > "$RUN/dbus.pid"
    for _ in $(seq 1 30); do [[ -s "$RUN/dbus" ]] && break; sleep 0.1; done
    [[ -s "$RUN/dbus" ]] || { echo "no private dbus; refusing to test on the host bus" >&2; exit 1; }
    export DBUS_SESSION_BUS_ADDRESS="$(head -1 "$RUN/dbus")"

    before="$(ls -1 "${XDG_RUNTIME_DIR:-/tmp}" | grep '^wayland-' || true)"
    # KWin script errors are silent unless the scripting category is on,
    # and a script that throws just stops publishing without a word.
    # Give the nested compositor its own config dir, seeded from the real one.
    # KWin persists virtual desktops and output layout on exit, and a test run
    # must not write any of that back into the session you actually use.
    mkdir -p "$RUN/config"
    cp -f "${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc" "$RUN/config/kwinrc" 2>/dev/null
    # A nested session gets no input, so the idle lock fires mid-test and hides
    # everything behind the lock screen.
    printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > "$RUN/config/kscreenlockerrc"

    # KWin logs to journald when it can; force stderr so kwin.log is useful.
    # A nested compositor that dies should just die: KCrash's handler and
    # auto-restart make a crash noisier for the host session than it needs
    # to be.
    XDG_CONFIG_HOME="$RUN/config" \
    KDE_DEBUG=1 KCRASH_AUTO_RESTART=0 \
    QT_FORCE_STDERR_LOGGING=1 \
    QT_LOGGING_RULES="${QT_LOGGING_RULES:-}${QT_LOGGING_RULES:+;}kwin_scripting.debug=true;kwin_scripting.warning=true" \
        kwin_wayland --xwayland --width "${WIDTH:-1920}" --height "${HEIGHT:-1080}" >"$RUN/kwin.log" 2>&1 &
    echo $! > "$RUN/kwin.pid"

    sock=""
    for _ in $(seq 1 40); do
        sleep 0.25
        for s in "${XDG_RUNTIME_DIR:-/tmp}"/wayland-*; do
            [[ -S "$s" ]] || continue
            n="$(basename "$s")"
            grep -qx "$n" <<< "$before" || { sock="$n"; break 2; }
        done
    done
    [[ -n "$sock" ]] || { echo "nested compositor never came up; see $RUN/kwin.log" >&2; exit 1; }
    echo "$sock" > "$RUN/wayland"

    nested_env
    # Same resolution the session script does, so X11 clients work in here too.
    DISPLAY="$(mmsimpulse-xdisplay "$(cat "$RUN/kwin.pid")" 2>/dev/null)" && export DISPLAY
    echo "${DISPLAY:-}" > "$RUN/display"
    qs -c "$CONFIG" >"$LOG" 2>&1 &
    echo $! > "$RUN/shell.pid"
    sleep 3
    echo "up: compositor on $sock, shell pid $(cat "$RUN/shell.pid")"
    echo "log: $LOG"
    ;;

ipc)
    nested_env
    qs -c "$CONFIG" ipc call "$2" "${3:-trigger}"
    ;;

run)
    nested_env
    shift
    "$@"
    ;;

shot)
    out="$SHOTS/${2:-shot}.png"
    # Captured from inside, through the nested compositor's own ScreenShot2.
    # Cropping the host's screen instead would mean hunting for the nested
    # window and would only ever be as accurate as that guess.
    nested_env
    name="$(busctl --user --no-pager call org.kde.KWin /KWin org.kde.KWin \
        activeOutputName 2>/dev/null | sed 's/^s //; s/"//g')"
    mmsimpulse-screenshot "${name:-WL-0}" "$out" && echo "$out"
    ;;

logs)
    tail -n "${2:-40}" "$LOG"
    ;;

down)
    [[ -f "$RUN/dbus.pid" ]] && kill "$(cat "$RUN/dbus.pid")" 2>/dev/null
    rm -f "$RUN/dbus" "$RUN/dbus.pid"
    for p in shell kwin; do
        [[ -f "$RUN/$p.pid" ]] && kill "$(cat "$RUN/$p.pid")" 2>/dev/null
        rm -f "$RUN/$p.pid"
    done
    # Belt and braces, but scoped to this config so the host shell is safe.
    pkill -f "qs -c $CONFIG" 2>/dev/null
    rm -f "$RUN/wayland"
    echo "down"
    ;;

*)
    sed -n '2,20p' "$0"
    ;;
esac
