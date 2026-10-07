# mmsimpulse

KWin session running the end-4 illogical-impulse shell, with Hyprland-style workspaces. No Plasma, no session manager.

- Compositor: any KWin 6, tiling off (`[Tiling] Enabled=false` in `~/.config/kwinrc`).
- Shell: [end-4 illogical-impulse](https://github.com/end-4/dots-hyprland) via the [pctrade/end4-pC](https://github.com/pctrade/end4-pC) skin, patched for KWin at install.
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

Other distributions: install KWin 6, kglobalaccel, Quickshell, xdg-desktop-portal-kde, python-dbus, python-gobject, rsync, jq, ImageMagick, wl-clipboard, libnotify and Spectacle from your package manager, plus cmake, extra-cmake-modules and the KWin development headers for workspace sharing. Then:

```
git clone https://github.com/mahirsn/mmsimpulse
cd mmsimpulse
./install.sh
```

Log out and pick **mmsimpulse**. After a KWin update, reinstall the package (Arch) or run `./install.sh` again: the workspace-sharing effect is built against the installed KWin.

## Keys

`Meta+Space` launcher, `Meta+Z` overlay. The installer binds the workspace keys:

```
Meta+1..0               switch workspace (monitor under the mouse)
Meta+Alt+1..0           send window there
Meta+Shift+1..0         send window there and follow
Meta+Ctrl+Left/Right    previous / next workspace
```

## Workspace sharing

Pick **Share virtual screen** in a screen-share dialog. The app gets the workspace you are on, live, even after you switch away. The overlay's **Share workspace** picks another one.
