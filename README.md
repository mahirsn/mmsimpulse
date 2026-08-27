# mmsimpulse

A Wayland session made of a **KWin** compositor and the
[end-4 illogical-impulse](https://github.com/end-4/dots-hyprland) shell — via the
[pctrade/end4-pC](https://github.com/pctrade/end4-pC) skin — and nothing else.

No desktop environment: no plasmashell, no session manager. Everything the shell
needs is started by `start-mmsimpulse`, which is about 150 lines.

Any KWin 6 works — the stock `kwin` package, or a fork such as
[KineticWE](https://gitlab.com/theblackdon/kineticwe), which provides the same
binary. **Tiling is off**: mmsimpulse expects `[Tiling] Enabled=false` in
`~/.config/kwinrc` and implements no swap, split or layout switching.

## Install

```sh
yay -S mmsimpulse-git
mmsimpulse-install
```

Or from a checkout:

```sh
git clone https://github.com/mahirsn/mmsimpulse && cd mmsimpulse && ./install.sh
```

Then log out and pick **mmsimpulse**.

The widgets themselves are pctrade/end4-pC, which is not vendored here. If it is
not already at `~/.config/quickshell/end4-pC` the installer offers to clone it;
set `MMSIMPULSE_BASE` to use a copy elsewhere, or `--yes` to take every prompt's
default. Re-run the installer to pick up an updated skin or a new release.

## Shortcuts

Nothing is bound by default. The shell's actions are installed as hidden
`.desktop` entries and appear in **System Settings > Shortcuts** under
`mmsimpulse`, unbound, for you to assign:

```sh
/usr/share/mmsimpulse/shortcuts/install-shortcuts.sh
```

Hyprland-style workspace keys are a separate, opt-in script, because that one
does bind keys:

```sh
/usr/share/mmsimpulse/shortcuts/install-workspace-keys.sh
```

| | |
|---|---|
| `Meta+1`..`0` | switch workspace |
| `Meta+Alt+1`..`0` | send window there |
| `Meta+Shift+1`..`0` | send window there and follow |
| `Meta+Ctrl+Left/Right` | previous / next workspace |
| `Meta+Shift+Left/Right` | send window to previous / next |

Most of these are KWin's own actions, so they honour
`kwinrc [Windows] PerOutputVirtualDesktops` — turn it on for per-monitor
workspaces, the way Hyprland behaves.

## Known gaps

- **No live window previews in the overview.** They need a foreign-toplevel
  protocol KWin does not implement, so windows show as an icon and frame.
- **Hold-to-show shortcuts do not exist.** kglobalaccel launches a command and
  has no release event, so the `*Open`/`*Close` pairs stay unbound.
- **Free-form window dragging in the overview is Hyprland-only.** Dropping a
  window on another workspace works; dropping it at a position does not.
- **The overview covers the bar's strip**, because KWin reports no struts.
- **Hyprland-only settings pages are inert** — animations, `hyprland.conf`
  editing, monitor layout, hyprsunset. Their KDE equivalents are in System
  Settings, and night light is `org.kde.KWin.NightLight`.

## Screen sharing

If the machine also runs Hyprland it probably has
`~/.config/xdg-desktop-portal/portals.conf` pinning `default=hyprland;gtk`.
That file applies to every session, so a KDE session asks the Hyprland backend
for screen sources it cannot provide, the frontend reports none at all, and the
share picker never appears. The installer writes a `kde-portals.conf` beside it,
which outranks it and applies only here.

## How it works

The skin routes compositor access through `services/WM.qml`, which already has
Hyprland and niri backends. This adds a KWin one.

KWin publishes no window list on D-Bus, and Quickshell has no D-Bus API in QML
and sees nothing of KWin's windows natively. The only place the window list
exists is inside a KWin script, whose only way out is `callDBus()`. So
`mmsimpulse-kwin-bridge` owns a bus name, loads that script, merges its pushes
with virtual-desktop state read off `org.kde.KWin`, and prints one JSON snapshot
per line — the same shape `NiriBackend.qml` gets from `niri msg event-stream`.

About twenty files in the skin reach past `WM.qml` and call `Quickshell.Hyprland`
directly. `overlay/patch-shell.py` rewrites those as scripted edits rather than
shipping copies of upstream files, and fails the install if a rule stops
matching — so an upstream rename is loud instead of silently leaving a Hyprland
call behind.

## Development

```sh
python3 test_bridge.py      # snapshot merging, id normalisation, desktop mapping
test/nested.sh up           # the whole session nested inside the current one
test/nested.sh ipc searchToggle
test/nested.sh shot launcher
test/nested.sh down
```

The nested compositor gets its own config directory, because KWin persists
virtual desktops on exit and a test run must not write those back. Do not
trigger logout from a nested session: `XDG_SESSION_ID` there belongs to the
host.

`TESTING.md` is the per-component checklist for a live session.

## Layout

```
bin/mmsimpulse-kwin-bridge      KWin <-> shell bridge daemon
kwin-script/                    KWin script that publishes the window list
overlay/services/               KwinBackend.qml, and WM.qml and
                                CompositorGlobalShortcut.qml with a KWin branch
overlay/bin/noctalia            shim for a fork's built-in shell shortcuts
overlay/patch-shell.py          scripted edits to the rest of the skin
session/                        session script and login-manager entry
shortcuts/                      shortcut tables and installers
packaging/                      PKGBUILD
```
