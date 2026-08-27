# mmsimpulse

A Wayland session made of a **KWin** compositor and the
[end-4 illogical-impulse](https://github.com/end-4/dots-hyprland) shell — via the
[pctrade/end4-pC](https://github.com/pctrade/end4-pC) skin — and **nothing else**.

No desktop environment: no plasmashell, no session manager, no Plasma workspace.
Everything a Plasma session would normally provide and the shell actually needs
is started explicitly by `start-mmsimpulse`, which is about 150 lines.

Any KWin 6 works — the stock `kwin` package, or a fork such as
[KineticWE](https://gitlab.com/theblackdon/kineticwe), which provides the same
binary. The backend talks to stock KWin D-Bus and the stock scripting API, so
nothing here is tied to a particular fork.

**Tiling is off.** mmsimpulse expects `[Tiling] Enabled=false` in
`~/.config/kwinrc` — stock KWin has nothing to switch off, and on a fork with
native tiling this turns it off: plain floating window management. Nothing here implements
window swap, split, resize-by-direction or layout switching, and none of that is
planned — the upstream shell's compositor abstraction (`services/WM.qml`) has no
such calls in its contract to begin with, so the tiling-specific half of the
Hyprland dispatchers was never in scope.

## How it fits together

```
SDDM ──> start-mmsimpulse            derived from /usr/bin/start-kineticwe
          ├─ kinetic-we --xwayland   compositor (KWin 6.7 fork)
          ├─ portals, powerdevil,    all from start-kineticwe, unchanged
          │  upowerd, kglobalaccel
          └─ qs -c mmsimpulse        the shell (replaces `noctalia`)
                └─ KwinBackend.qml
                      └─ mmsimpulse-kwin-bridge  (owns org.mmsimpulse.KWin)
                            ├─ loads mmsimpulse-windows.js into KWin
                            └─ reads org.kde.KWin.VirtualDesktopManager
```

`plasmashell` is never started — and never needs to be. `start-kineticwe`
already brings up everything a Plasma session would provide besides the shell
itself (portals, power management, global shortcuts, the KDE service cache), so
there is no gap for plasmashell to fill once mmsimpulse draws the bar, launcher,
notifications and OSDs.

## Why there is a bridge process

Three facts, each verified against the installed packages rather than docs:

1. `libkwin.so` implements `org_kde_plasma_window_management` and **not**
   `ext-workspace-v1`, `ext-foreign-toplevel-list-v1` or
   `zwlr_foreign_toplevel_management`.
2. Quickshell's `Quickshell.WindowManager` module is backed **only** by
   `ext-workspace-v1`, and `Quickshell.Wayland` exposes just session locking.
   So Quickshell sees nothing of KWin's windows or desktops natively.
3. Quickshell has no D-Bus API in QML and owns no bus name, and KWin publishes
   no window list on D-Bus.

The only place the window list exists is inside a KWin script, whose only way
out of the compositor is `callDBus()`. `mmsimpulse-kwin-bridge` is the thing it
calls: it owns `org.mmsimpulse.KWin`, loads the script, merges its pushes with
virtual-desktop state read off `org.kde.KWin`, and prints one JSON snapshot per
line for `KwinBackend.qml` — the same shape `NiriBackend.qml` gets from
`niri msg event-stream`.

## Running on a fork with native tiling

Everything in this repo is generic KWin 6. Two things are worth knowing if the
compositor is KineticWE rather than stock KWin:

| | |
|---|---|
| It hardcodes Noctalia as its shell | Its session script starts `noctalia`, and it registers about 21 `noctalia msg …` shortcuts from inside the compositor (`src/noctaliasettings.cpp`). mmsimpulse brings its own session script, so the former does not apply; the latter stay registered and reach this shell through the `noctalia` shim on the session's PATH. |
| It embeds kglobalacceld | The compositor claims `org.kde.kglobalaccel` itself. `start-mmsimpulse` only starts a daemon when nothing already owns that name, so the same script covers stock KWin, which has none. |

Tiling itself is untouched: KineticWE 6.7.80 exposes no `org.kde.KWin.Tiling`
D-Bus interface (`/Tiling` returns `UnknownObject`) — layouts live in `kwinrc [Tiling]` and as kglobalaccel actions
("Tiling Cycle Layout", "Tiling Switch To MasterStack", …). Noctalia's
`kineticwe-layouts` community plugin targets such an interface, so it is written
against a different revision than the one packaged here. Irrelevant while tiling
is off, but worth knowing before using that plugin as a reference.

## Install

From the AUR:

```sh
yay -S mmsimpulse-git   # or: paru -S mmsimpulse-git
mmsimpulse-install      # the per-user half; safe to re-run
```

Or from a checkout:

```sh
git clone https://github.com/mahirsn/mmsimpulse && cd mmsimpulse
./install.sh
```

The package owns the session entry and `start-mmsimpulse`, so installing it
needs no sudo prompt. `install.sh` from a checkout writes the same two files
and does ask for sudo once, for the login-manager entry.

Requires an already-installed `kineticwe` — the compositor is not rebuilt.

This repository is only the KWin-specific half; the widgets themselves are
[pctrade/end4-pC](https://github.com/pctrade/end4-pC). If it is not already at
`~/.config/quickshell/end4-pC` the installer offers to clone it, so nothing is
vendored here and an existing copy is reused as-is. Point `MMSIMPULSE_BASE` at
another location to use that instead, and `--yes` takes every prompt's default
for unattended runs.

Also needs `python-dbus`, `python-gobject`, `rsync` and `git`.

The install copies the skin to `~/.config/quickshell/mmsimpulse`, lays the
KWin-specific files over it, installs the bridge to `~/.local/bin`, derives the
session script from `/usr/bin/start-kineticwe`, and adds an SDDM entry named
**mmsimpulse**. Your existing KineticWE+Noctalia session is not modified.

Iterate on the shell without logging out:

```sh
pkill -f "qs -c mmsimpulse"; qs -c mmsimpulse
```

Full session restart is only needed for changes to `start-mmsimpulse` or the
bridge.

## Shortcuts

Hyprland delivers shortcuts to the shell over `hyprland-global-shortcuts-v1`.
KWin has no such protocol, so `shortcuts/install-shortcuts.sh` writes one hidden
`.desktop` per action running `qs -c mmsimpulse ipc call <name> trigger`, with
its default key in `X-KDE-Shortcuts`. KineticWE's embedded kglobalacceld picks
those up and they appear in **System Settings > Shortcuts** like any other
command shortcut. Edit `shortcuts/shortcuts.tsv` and re-run to change defaults;
`--uninstall` removes them.

Two things to know:

- kglobalaccel launches a command and has no release event, so the shell's
  press/release pairs (`searchToggleRelease`, `workspaceNumber`, the
  `*Open`/`*Close` variants, `osdVolume*`) have no KDE equivalent and are
  unbound.
- `~/.local/share/applications` is not per-session, so these entries are visible
  to the daily Noctalia session too and hold the same keys there — where the
  command is a harmless no-op. The installer warns about keys already bound in
  `kglobalshortcutsrc` instead of overwriting them.

## Testing without logging out

`test/nested.sh` runs a whole mmsimpulse session nested inside whatever session
you are already in. The compositor renders into a window, so the host can
screenshot it, and panels can be driven straight over the shell's IPC:

```sh
test/nested.sh up
test/nested.sh ipc searchToggle
test/nested.sh shot launcher      # -> test/shots/launcher.png
test/nested.sh logs
test/nested.sh down
```

The nested compositor gets its own config directory, because KWin persists
virtual desktops and output layout on exit and a test run must not write those
back into the session you actually use.

Two things do not work nested and must be checked in a real session: the
**global shortcuts**, since keys have to reach the nested window, and
**logout** — `XDG_SESSION_ID` there belongs to the host, so triggering it would
end your real session.

```sh
python3 test_bridge.py     # snapshot merging, id normalisation, desktop mapping
```

`TESTING.md` is the per-component checklist.

## Layout

```
bin/mmsimpulse-kwin-bridge      KWin <-> shell bridge daemon
kwin-script/                    KWin script that publishes the window list
overlay/services/               files laid over the upstream skin
  KwinBackend.qml               the WM backend for KWin
  WM.qml                        upstream + "kde" detection and KwinBackend
  CompositorGlobalShortcut.qml  upstream + the kglobalaccel path
overlay/patch-shell.py          scripted edits to the rest of the skin
overlay/bin/noctalia            PATH shim, this session only
session/                        session entry
shortcuts/                      shortcut table and installer
test/nested.sh                  run a session nested inside the current one
```

`WM.qml` and `CompositorGlobalShortcut.qml` are full copies of the upstream
files rather than patches, so they need re-syncing if the skin changes them.
Everything else is rewritten by `patch-shell.py`, which fails the install if a
rule stops matching — that is the signal to re-read the upstream file.

## Known gaps

- **No live window previews in the overview.** They need a foreign-toplevel
  protocol KWin does not implement, so windows show as an icon and frame.
- **Hold-to-show shortcuts do not exist.** kglobalaccel launches a command and
  has no release event, so `searchToggleRelease`, `workspaceNumber` and the
  `*Open`/`*Close` pairs stay unbound.
- **Free-form window dragging in the overview is Hyprland-only.** Dropping a
  window on another workspace works; dropping it at a position does not.
- **The overview covers the bar's strip**, because KWin reports no struts over
  D-Bus and `reserved` is therefore all zeroes.
- **Hyprland-only settings pages are inert** — animations, `hyprland.conf`
  editing, monitor layout, hyprsunset. The KDE equivalents are in System
  Settings, and night light is `org.kde.KWin.NightLight`.
- **`overview.style: "niri"` is not ported**; leave it at the default.
- **The overview grid follows the real virtual desktops**, not Config's
  rows x columns. Hyprland numbers workspaces 1..N whether they exist or not;
  KWin does not, so a fixed 5x2 would be mostly empty cells. Set
  `overview.enable: false` to drop the grid from the launcher entirely.
