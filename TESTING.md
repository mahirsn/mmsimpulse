# mmsimpulse test checklist

Log into the **mmsimpulse** session from SDDM. Work down the list; each item is
independent, so a failure early on does not invalidate what comes after.

Keep a terminal open — almost everything is fixable with
`pkill -f "qs -c mmsimpulse"; qs -c mmsimpulse` without leaving the session.

## Already verified in a nested session

These were exercised against a real session, so
they should not need re-checking unless something looks wrong:

| | |
|---|---|
| Bar renders, tray, clock, battery, wallpaper | ✅ |
| Launcher opens with a working search field | ✅ fixed — it was an empty rectangle |
| Overview grid, active workspace highlight | ✅ |
| Windows appear in the overview, on the right workspace | ✅ as icon + frame, no live preview |
| Workspace indicator follows a desktop switch, live | ✅ D-Bus signal path |
| Session screen with all eight actions | ✅ renders; logout itself is untested, see below |
| Notification popup | ✅ |
| Every panel toggle (sidebars, settings, media, OSK, clipboard, emoji, wallpaper, overlay) | ✅ opens without errors |
| All 24 shortcut names reachable over IPC | ✅ `qs -c mmsimpulse ipc show` |

What a nested session cannot cover, and why:

- **Logout, reboot, shutdown.** In a nested session `XDG_SESSION_ID` belongs to
  the host, so triggering logout would end the real session rather than the
  nested one. Untested on purpose.
- **Multi-monitor behaviour.** The nested compositor has one output. The
  focused-screen bug you hit is fixed at the source (`WM.focusedMonitor` instead
  of `Hyprland.focusedMonitor`), but only a real two-screen session proves it.
- **Actual key presses.** Shortcuts were driven over IPC, which is the second
  half of the path; the kglobalaccel half needs a real key press.
- **Screen lock.** Needs `ext-session-lock-v1` and a real session to be
  meaningful.

Everything below is the full checklist; the items above are marked so you can
skip them.

## 0. Ground truth (do this first)

This is the one step that could not be checked from outside a live session, so
it confirms the assumptions everything else rests on.

- [ ] `echo $XDG_CURRENT_DESKTOP` prints `KDE` (this is what selects the KWin backend)
- [ ] `kreadconfig6 --file kwinrc --group Tiling --key Enabled` prints `false`
- [ ] `qdbus6 org.kde.KWin` lists `/KWin`, `/VirtualDesktopManager`, `/WindowsRunner`, `/Scripting`, `/Effects`
- [ ] `qdbus6 org.kde.KWin /VirtualDesktopManager` shows the `VirtualDesktopManager` interface
- [ ] `busctl --user list | grep -c plasmashell` is `0` — no plasmashell anywhere
- [ ] `qdbus6 org.kde.KWin /KWin org.kde.KWin.currentDesktop` returns a number
- [ ] `qdbus6 | grep mmsimpulse` shows `org.mmsimpulse.KWin` (bridge is up)
- [ ] `qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded mmsimpulse-windows` returns `true`

If `org.kde.KWin.Tiling` shows up in the first check, the packaged KineticWE is
newer than the one this was written against — harmless, but worth noting.

## 1. Bar render

- [ ] Bar appears, on every monitor it should be on
- [ ] Clock, battery, network, audio, tray icons all populate
- [ ] `Meta+B` toggles the bar
- [ ] Bar hides for a fullscreen window and comes back on exit (`fullscreenOnMonitor`)
- [ ] Wallpaper/background renders behind it

## 2. Workspace indicator

- [ ] Correct number of workspaces shown, matching `qdbus6 org.kde.KWin /VirtualDesktopManager` count
- [ ] Active workspace is highlighted
- [ ] `Meta+Ctrl+Right` / `Left` moves between desktops and the indicator follows
- [ ] Clicking a workspace in the bar switches to it
- [ ] Adding a desktop in System Settings > Virtual Desktops updates the indicator live (no restart)
- [ ] Window icons/previews appear on the right workspace

## 3. Overview

- [ ] `Meta+G` opens the overview
- [ ] Windows appear, on the correct workspaces, at roughly the right positions
- [ ] Clicking a window focuses it and closes the overview
- [ ] Middle-click / close button closes a window
- [ ] Dragging a window to another workspace moves it (this is the one-shot KWin script path)
- [ ] Window titles and app icons resolve

## 4. Launcher and search

- [ ] `Meta+Space` opens search
- [ ] Typing filters applications; Enter launches one
- [ ] `Meta+Period` opens the emoji picker
- [ ] `Meta+Shift+V` opens clipboard history
- [ ] Escape closes cleanly and returns focus to the previous window

## 5. Notifications

- [ ] `notify-send hello world` shows a popup
- [ ] Popup appears on the focused monitor
- [ ] It is clickable and dismissable
- [ ] The notification centre in the right sidebar lists past notifications

## 6. Shortcuts

- [ ] Every key in `shortcuts/shortcuts.tsv` fires its action
- [ ] The entries appear in **System Settings > Shortcuts**, searchable as "mmsimpulse"
- [ ] Rebinding one there takes effect without a restart
- [ ] KWin's own keys still work: `Alt+Tab`, `Meta+Q` (close), `Meta+Ctrl+arrows`
- [ ] Nothing double-fires (a sign of a key bound both here and in `kglobalshortcutsrc`)

## 7. Panels and session

- [ ] `Meta+A` / `Meta+N` toggle the sidebars
- [ ] `Meta+I` opens settings; changes persist across `pkill -f "qs -c mmsimpulse"; qs -c mmsimpulse`
- [ ] `Meta+M` shows media controls, and they drive a playing MPRIS client
- [ ] `Meta+X` opens the session screen; log out from it returns to SDDM (not a black screen)
- [ ] `Meta+Ctrl+L` locks, and the password unlocks — Quickshell's `WlSessionLock` needs
      `ext-session-lock-v1`, which is the least certain item on this list

## 8. Screen capture and regions

- [ ] `Meta+Shift+S` region screenshot
- [ ] `Meta+Alt+R` region recording (needs the portal, already started by the session script)
- [ ] `Meta+Shift+T` OCR, `Meta+Shift+F` region search

## 9. Known-absent by design

Confirm these are *missing*, not broken:

- [ ] No tiling actions in the shell — layout switching, swap, split are out of scope
- [ ] `searchToggleRelease` / `workspaceNumber` hold-to-show behaviour does not
      work, because kglobalaccel has no release event
- [ ] Hyprland-only settings pages (animations, `hyprland.conf` editing,
      hyprsunset, monitor config writing to `monitors.lua`) are inert; the KDE
      equivalents live in System Settings, and night light is
      `org.kde.KWin.NightLight`

## 10. Stability

- [ ] `pkill -f "qs -c mmsimpulse"` — the supervisor restarts the shell within ~2s and the bridge comes back with it
- [ ] Open and close 10 windows quickly; the window list stays correct (bridge debounce)
- [ ] Drag a window around for several seconds; no lag and no flood in `~/.local/share/mmsimpulse.log`
- [ ] Leave the session running for an hour, then re-check the workspace indicator

## Known broken

**Right-clicking a system tray icon opens no menu.** Verified in a clean Arch VM
against stock KWin 6.7.4 and Quickshell 0.3.1, with a purpose-built tray item
serving a valid three-entry DBusMenu.

What was measured, so nobody has to repeat it:

- Left-click reaches the item and calls `activate()`; the tray item receives it.
- Right-click reaches the same MouseArea (`event.button == 2`), `item.hasMenu`
  is true and `menu.open()` runs.
- The `QsMenuOpener` has all three DBusMenu entries, `trayItemId` is set, and
  every row reports a sensible size (93x36 for the pin row, 66-105x36 for the
  entries).
- The `SysTrayMenu` window ends up `visible`, 133x181, anchored to the bar's
  layer surface, on the right screen, with a fully opaque background.
- KWin never receives a popup surface for it. A minimal `PopupWindow` with the
  identical anchor, opened from the same handler, maps and paints immediately —
  so the anchor and the layer-shell parent are not the problem.

Ruled out: the tooltip occupying the layer surface (disabling it changes
nothing), opening one frame too early (`Qt.callLater` changes nothing), and the
menu being empty (its rows are all present and sized).

One real defect was found and fixed along the way: the `ColumnLayout` holding
the rows reported no implicit size, which left the window at 28x37 — the size
of its own padding. `overlay/patch-shell.py` now measures the rows instead.
That is necessary but not sufficient, and the menu is still not usable.

## Reporting

For anything that fails, `~/.local/share/mmsimpulse.log` has both the shell's
output and the bridge's stderr (prefixed `[bridge]` / `[KwinBackend]`).
