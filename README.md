# mmsimpulse

A bare KWin Wayland session to run a shell of your choice on, with Hyprland-style workspaces. No Plasma, no session manager, no shell of its own.

- Compositor: any KWin 6, tiling off (`[Tiling] Enabled=false` in `~/.config/kwinrc`).
- Shells: KWin gets the window-list and workspace protocols that shells written for wlroots compositors, niri or Hyprland use (`zwlr_foreign_toplevel_management_v1`, `ext_workspace_v1`), so their task bars and workspace widgets work unchanged.
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

The shell's keys are the ones you already have for it on Hyprland (`hyprland.lua` or `hyprland.conf`) or niri (`config.kdl`): commands become global shortcuts, and closing, fullscreen, pinning, focusing, moving and resizing windows become KWin's. A profile's own keys come after them, and `binds=niri` or `binds=none` in a profile picks another source or none.

Without a shell the session still starts, with KWin, Alt+Tab and `Meta+Return` for a terminal.

The lock screen stays KDE's: KWin has no `ext_session_lock_v1`.

## Keys

`Meta+Return` opens a terminal (`xdg-terminal-exec`, else kitty) and the volume keys work, whatever the shell. The installer also binds the workspace keys:

```
Meta+1..0               switch workspace (monitor under the mouse)
Meta+Alt+1..0           send window there
Meta+Shift+1..0         send window there and follow
Meta+Ctrl+Left/Right    previous / next workspace
```

## Workspace sharing

Pick **Share virtual screen** in a screen-share dialog. The app gets the workspace you are on, live, even after you switch away.
