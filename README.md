# mmsimpulse

The [end-4 illogical-impulse](https://github.com/end-4/dots-hyprland) shell — via the
[pctrade/end4-pC](https://github.com/pctrade/end4-pC) skin — running on
**KineticWE** instead of Hyprland, with **no plasmashell**.

**Tiling is off.** mmsimpulse assumes KineticWE runs with `[Tiling] Enabled=false`
in `~/.config/kwinrc`: plain floating window management. Nothing here implements
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

## KineticWE-specific parts

Everything else in this repo is generic KWin 6 and would work on stock Plasma.
These are the pieces that exist because of KineticWE in particular:

| Part | Why it is KineticWE-specific |
|---|---|
| `session/mmsimpulse.desktop`, the generated `start-mmsimpulse` | Derived from `/usr/bin/start-kineticwe`, which is KineticWE's own session script. The only edits are the shell command and `PATH`. |
| Replacing `noctalia` as the shell | KineticWE hardcodes Noctalia as its shell in step 8 of that script, and registers ~21 `noctalia msg …` shortcuts from inside the compositor (`src/noctaliasettings.cpp`). Those stay registered and simply do nothing here. |
| Relying on kglobalaccel without a daemon | KineticWE links `libKGlobalAccelD` into the compositor and masks `plasma-kglobalaccel.service`. On stock Plasma the standalone daemon provides the same interface, so the shortcut mechanism is portable, but the handover in `start-kineticwe` is not. |
| The Arch packaging assumption | The `kineticwe` AUR package installs into `/usr`, not `/opt` as the Gentoo ebuilds do, and it *provides* `/usr/bin/kwin_wayland`. `install.sh` looks for `kinetic-we` on `PATH`. |
| `[Tiling] Enabled=false` | KineticWE's native tiling; upstream KWin has nothing to switch off. |

Tiling itself is untouched: KineticWE 6.7.80 exposes no `org.kde.KWin.Tiling`
D-Bus interface — layouts live in `kwinrc [Tiling]` and as kglobalaccel actions
("Tiling Cycle Layout", "Tiling Switch To MasterStack", …). Noctalia's
`kineticwe-layouts` community plugin targets such an interface, so it is written
against a different revision than the one packaged here. Irrelevant while tiling
is off, but worth knowing before using that plugin as a reference.

## Install

```sh
./install.sh
```

Requires an already-installed `kineticwe` — the compositor is not rebuilt. Also
needs the upstream skin at `~/.config/quickshell/end4-pC` (override with
`MMSIMPULSE_BASE=…`), `python-dbus`, `python-gobject` and `rsync`.

The install copies the skin to `~/.config/quickshell/mmsimpulse`, lays the
KWin-specific files over it, installs the bridge to `~/.local/bin`, derives the
session script from `/usr/bin/start-kineticwe`, and adds an SDDM entry named
**mmsimpulse**. Your existing KineticWE+Noctalia session is not modified.

Iterate on the shell without logging out:

```sh
killall qs; qs -c mmsimpulse
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

## Tests

```sh
python3 test_bridge.py     # snapshot merging, id normalisation, desktop mapping
```

`TESTING.md` is the per-component checklist for a live session.

## Layout

```
bin/mmsimpulse-kwin-bridge      KWin <-> shell bridge daemon
kwin-script/                    KWin script that publishes the window list
overlay/services/               files laid over the upstream skin
  KwinBackend.qml               the WM backend for KWin
  WM.qml                        upstream + "kde" detection and KwinBackend
  CompositorGlobalShortcut.qml  upstream + the kglobalaccel path
session/                        SDDM session entry
shortcuts/                      shortcut table and installer
```

`WM.qml` and `CompositorGlobalShortcut.qml` are full copies of the upstream
files rather than patches, so they need re-syncing if the skin changes them.
