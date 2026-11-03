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

## Config

`~/.config/mmsimpulse/` is the config, in Lua and split as Hyprland's: `mmsimpulse.lua` loads `keybinds.lua`, `input.lua`, `monitors.lua`, `autostart.lua` and `env.lua` with `require`. The installer writes each file once, with every setting explained in it; after that they are yours. Saving one applies it at once (autostart and env at the next login); a mistake shows a notification and leaves everything as it was.

```lua
local mod = "SUPER"
mms.bind(mod .. " + Return", mms.exec("kitty"))
mms.bind(mod .. " + Q", mms.kwin("Window Close"))         -- a KWin action, by its name
mms.bind(mod .. " + 2", mms.workspace(2))                 -- also movetoworkspace, movetoworkspacesilent
mms.config({ input = { kb_layout = "us,tr", repeat_delay = 250, sensitivity = 0.2 } })
mms.monitor({ output = "HDMI-A-1", mode = "1920x1080@180", position = "-1920x0", scale = 1 })
mms.exec_once("kdeconnectd")
mms.env("XCURSOR_SIZE", "24")
mms.shell("dux")                                          -- instead of ~/.config/mmsimpulse/shell
```

`hl.*` works too (`hl.bind`, `hl.config`, `hl.monitor`, `hl.env`, `hl.on("hyprland.start", ...)`), so Hyprland Lua files can be copied in, or taken in where they are:

```lua
mms.source("~/.config/hypr/keybinds.lua")                                   -- one file, all of it
mms.source("~/.config/hypr/hyprland.lua", { "binds", "input", "monitors" })  -- a whole config, these parts
```

The parts are `binds`, `input`, `monitors`, `autostart` and `env`; a `hyprland.conf` or niri `config.kdl` gives its binds. Settings go into KWin's own configuration (kxkbrc, kcminputrc, kwinrc, kscreen), so System Settings shows them; what has no KWin counterpart is named in `~/.local/share/mmsimpulse.log`. The installer adds the `mms.source` lines, commented out, for the Hyprland or niri config it finds. Without `mmsimpulse.lua` the session takes the Hyprland or niri config's keys on its own, as before.

## Keys

`Meta+Return` opens a terminal (`xdg-terminal-exec`, else kitty) and the volume keys work, whatever the shell. The default workspace keys (`keybinds.lua`):

```
Meta+1..0               switch workspace (monitor under the mouse)
Meta+Alt+1..0           send window there
Meta+Shift+1..0         send window there and follow
Meta+Ctrl+Left/Right    previous / next workspace
Meta+Shift+Left/Right   send window to the previous / next workspace
```

## Workspace sharing

Pick **Share virtual screen** in a screen-share dialog. The app gets the workspace you are on, live, even after you switch away.
