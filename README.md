# mmsimpulse

A bare KWin Wayland session to run a shell of your choice on, with Hyprland-style workspaces. No Plasma, no session manager, no shell of its own.

- Compositor: any KWin 6, tiling off (`[Tiling] Enabled=false` in `~/.config/kwinrc`).
- Shells: KWin gets the protocols that shells and tools written for wlroots compositors, niri or Hyprland use, so they work unchanged:
  - window list: `zwlr_foreign_toplevel_management_v1`, `ext_foreign_toplevel_list_v1`
  - workspaces: `ext_workspace_v1`
  - screenshots, recording and window pictures (grim, wf-recorder, a shell's previews): `zwlr_screencopy_manager_v1`, `ext_image_copy_capture_manager_v1` with output and window sources
  - typing (wtype, on-screen keyboards): `zwp_virtual_keyboard_manager_v1`, in the keys the current layout has
  - screens (wlr-randr, kanshi): `zwlr_output_manager_v1`

  As on wlroots compositors, any client may use them. Windows marked to be hidden from capture stay hidden.
- Multi-monitor: one workspace pool across monitors with `[Windows] PerOutputVirtualDesktops=true`.

## Install

Arch, from the AUR:

```
paru -S mmsimpulse-git
mmsimpulse-install
```

Arch, from source:

```
git clone https://github.com/mahirsn/mmsimpulse
cd mmsimpulse/packaging
makepkg -si
mmsimpulse-install
```

Other distributions: install KWin 6, kglobalaccel, xdg-desktop-portal-kde, python-dbus, python-gobject and wl-clipboard from your package manager, plus cmake, extra-cmake-modules, wayland-protocols, wlr-protocols and the KWin development headers for the KWin plugins. Then:

```
git clone https://github.com/mahirsn/mmsimpulse
cd mmsimpulse
./install.sh
```

Pick a shell (below), log out and pick **mmsimpulse**. After a KWin update, reinstall the package (Arch) or run `./install.sh` again: the KWin plugins are built against the installed KWin.

## Shells

Write the shell's name into `~/.config/mmsimpulse/shell`. The name is:

- a profile in `~/.config/mmsimpulse/profiles/<name>`: how to start the shell and which keys it gets. `profiles/dux` (Dux Shell, which documents the format) and `profiles/noctalia` (Noctalia) come with it,
- a Quickshell config (`~/.config/quickshell/<name>/shell.qml`), or
- a command of that name, such as `noctalia`.

A profile's keys are the shell's defaults. Your own keys go in `~/.config/mmsimpulse/mmsimpulse.lua`, which wins over the profile (below).

Without a shell the session still starts, with KWin, Alt+Tab and `Meta+Return` for a terminal.

The lock screen stays KDE's: KWin has no `ext_session_lock_v1`.

## Keys

`~/.config/mmsimpulse/mmsimpulse.lua` is the config, in Lua as Hyprland's `hyprland.lua`. The installer writes it once, with the workspace keys; after that it is yours, and saving it binds the keys again at once. A mistake shows a notification and leaves the keys as they were.

```lua
local mod = "SUPER"
mms.bind(mod .. " + Return", mms.exec("kitty"))
mms.bind(mod .. " + Q", mms.kwin("Window Close"))        -- a KWin action, by its name
mms.bind(mod .. " + 2", mms.workspace(2))                -- also movetoworkspace, movetoworkspacesilent
mms.shell("dux")                                         -- instead of ~/.config/mmsimpulse/shell
require("keybinds")                                      -- ~/.config/mmsimpulse/keybinds.lua
mms.source("~/.config/hypr/hyprland.lua")                -- the keys of a Hyprland or niri config
```

`hl.bind` and `hl.dsp.*` work too. `mms.source` runs a Hyprland Lua config, or reads a `hyprland.conf` or niri `config.kdl`: commands become global shortcuts, and closing, fullscreen, pinning, focusing, moving and resizing windows become KWin's. The installer adds that line, commented out, for each such config it finds. Without `mmsimpulse.lua` the session takes the Hyprland or niri config's keys on its own, as before.

`Meta+Return` opens a terminal (`xdg-terminal-exec`, else kitty) and the volume keys work, whatever the shell. The default workspace keys:

```
Meta+1..0               switch workspace (monitor under the mouse)
Meta+Alt+1..0           send window there
Meta+Shift+1..0         send window there and follow
Meta+Ctrl+Left/Right    previous / next workspace
Meta+Shift+Left/Right   send window to the previous / next workspace
```

## Workspace sharing

Pick **Share virtual screen** in a screen-share dialog. The app gets the workspace you are on, live, even after you switch away.
