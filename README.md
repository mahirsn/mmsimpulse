# mmsimpulse

A Wayland session made of a **KWin** compositor and the
[end-4 illogical-impulse](https://github.com/end-4/dots-hyprland) shell — via the
[pctrade/end4-pC](https://github.com/pctrade/end4-pC) skin — and nothing else.

No desktop environment: no plasmashell, no session manager. Everything the shell
needs is started by `start-mmsimpulse`, which is about 200 lines.

Any KWin 6 that provides `kwin_wayland` works. **Tiling is off**: mmsimpulse
expects `[Tiling] Enabled=false` in `~/.config/kwinrc` and implements no swap,
split or layout switching.

## Install

Every dependency is in the official repositories, so no AUR helper is needed
for anything but this package itself.

```sh
paru -S mmsimpulse-git      # or yay
mmsimpulse-install
```

Or from a checkout:

```sh
git clone https://github.com/mahirsn/mmsimpulse && cd mmsimpulse && ./install.sh
```

A checkout installs no packages, so bring them yourself: `kwin kglobalacceld
quickshell xdg-desktop-portal-kde python-dbus python-gobject rsync jq
imagemagick wl-clipboard libnotify spectacle`, plus `kdeplasma-addons` for a
task switcher — KWin ships no Alt+Tab layout of its own and draws nothing
without one.

Then log out and pick **mmsimpulse**.

The widgets themselves are pctrade/end4-pC, which is not vendored here. If it is
not already at `~/.config/quickshell/end4-pC` the installer offers to clone it;
set `MMSIMPULSE_BASE` to use a copy elsewhere, or `--yes` to take every prompt's
default. Re-run the installer to pick up an updated skin or a new release.

## Shortcuts

Only the launcher is bound, to `Meta+Space`, and only when nothing else holds
that key — a session with no way to open the launcher has no way to start
anything. Every other action is installed as a hidden `.desktop` entry and
appears in **System Settings > Shortcuts** under `mmsimpulse`, unbound, for you
to assign:

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
- **Right-clicking a tray icon opens no menu.** Quickshell creates the window,
  sizes it, anchors it to the bar and reports it visible, but no Wayland
  surface ever reaches KWin — while a plain `PopupWindow` with the identical
  anchor, opened from the same handler, maps and paints. `TESTING.md` records
  everything measured and everything ruled out.

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

test/vm.sh up               # a clean Arch VM, installed the way a stranger would
test/vm.sh ssh <command>
test/vm.sh click 900 20     # real input, through the guest's virtio tablet
test/vm.sh shot launcher
test/vm.sh down

test/nested.sh up           # faster, but shares this session's logind and bus
test/nested.sh ipc searchToggle
test/nested.sh down
```

The VM is what proves the project's central claim, because it starts from the
same blank state a stranger does: no KWin fork, no leftovers, nothing from this
machine's `~/.config`. `up gui` puts it in a window you can drive by hand, and
`up dual` gives it two outputs. Input and screenshots go through QMP, so a
scripted test presses real keys and clicks real buttons.

The nested harness is for quick iteration on shell behaviour only. It gets its
own config directory, because KWin persists virtual desktops on exit and a test
run must not write those back, and it shares the host's logind session — so the
host locking locks it too, and logout from it would end the real session.

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
test/                           VM and nested harnesses, QMP client, fake tray
```
