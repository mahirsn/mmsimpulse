# mmsimpulse

KWin session running the end-4 illogical-impulse shell, with Hyprland-style workspaces. No Plasma, no session manager.

- Compositor: any KWin 6, tiling off (`[Tiling] Enabled=false` in `~/.config/kwinrc`).
- Shell: [end-4 illogical-impulse](https://github.com/end-4/dots-hyprland) via the [pctrade/end4-pC](https://github.com/pctrade/end4-pC) skin, patched for KWin at install.
- Multi-monitor: one workspace pool across monitors with `[Windows] PerOutputVirtualDesktops=true`.

## Install

Arch:

```
git clone https://github.com/mahirsn/mmsimpulse
cd mmsimpulse/packaging
makepkg -si
mmsimpulse-install
```

Log out and pick **mmsimpulse**. Rebuild after a KWin update; the workspace-sharing effect is built against the installed KWin.

## Keys

`Meta+Space` launcher, `Meta+Z` overlay. Workspace keys:

```
/usr/share/mmsimpulse/shortcuts/install-workspace-keys.sh
```

```
Meta+1..0               switch workspace (monitor under the mouse)
Meta+Alt+1..0           send window there
Meta+Shift+1..0         send window there and follow
Meta+Ctrl+Left/Right    previous / next workspace
```

## Workspace sharing

Pick **Share virtual screen** in a screen-share dialog. The app gets the workspace you are on, live, even after you switch away. The overlay's **Share workspace** picks another one.
