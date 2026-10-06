# mmsimpulse

A Wayland session made of KWin and the
[end-4 illogical-impulse](https://github.com/end-4/dots-hyprland) shell (through
the [pctrade/end4-pC](https://github.com/pctrade/end4-pC) skin), with
Hyprland-style workspaces. No Plasma, no session manager.

Works with any KWin 6. Tiling must be off (`[Tiling] Enabled=false` in
`~/.config/kwinrc`).

## Install

Arch:

```
paru -S mmsimpulse-git
mmsimpulse-install
```

Then log out and pick **mmsimpulse** in the login screen. Run
`mmsimpulse-install` again to pick up a new release or an updated skin.

From a checkout: `./install.sh`. It installs no packages, so bring `kwin
kglobalacceld quickshell xdg-desktop-portal-kde python-dbus python-gobject
rsync jq imagemagick wl-clipboard libnotify spectacle`, and `kdeplasma-addons`
for an Alt+Tab switcher.

The package builds a KWin effect against the installed KWin: reinstall it after
a KWin update.

## Use

`Meta+Space` opens the launcher. Every other shell action is listed under
**mmsimpulse** in System Settings > Shortcuts, unbound. For Hyprland-style
workspace keys:

```
/usr/share/mmsimpulse/shortcuts/install-workspace-keys.sh
```

```
Meta+1..0               switch workspace
Meta+Alt+1..0           send window there
Meta+Shift+1..0         send window there and follow
Meta+Ctrl+Left/Right    previous / next workspace
Meta+Shift+Left/Right   send window to previous / next
```

`Meta+Z` opens the overlay: quick settings, media, OBS, Wi-Fi, Bluetooth,
recorder with instant replay, resources, notes and more. Hold Ctrl to snap
widgets to a grid.

### Several monitors

Turn on `[Windows] PerOutputVirtualDesktops=true` in `~/.config/kwinrc`. The
workspaces are then one pool, as in Hyprland: each monitor shows one of them,
the keys and the bar act on the monitor under the mouse, and asking for a
workspace another monitor shows moves the focus there. Fullscreen games stay
on screen when you click another window.

### Sharing a workspace

Pick **Share virtual screen** in an app's screen-share dialog (OBS, Discord, a
browser). The app receives the workspace you are on, live, even after you
switch to another one. **Share workspace** in the overlay picks a different
one.

### Another shell

```
echo nandoroid-kwin > ~/.config/mmsimpulse/shell
```

runs [NAnDoroid](https://github.com/na-ive/nandoroid-shell) instead, after
`./install.sh --nandoroid`. Delete the file to come back.

## Known gaps

- The overview shows windows as icons, without live previews.
- Right-clicking a tray icon opens no menu.
- Hyprland-only settings pages (animations, monitor layout) do nothing; use
  System Settings.

## Layout

```
bin/            KWin bridge and helpers
kwin-script/    KWin script: windows, workspace pool, screen sharing
kwin-effect/    KWin effect for workspace sharing
overlay/        shell additions and patch-shell.py, which edits the skin
session/        session script and login entry
shortcuts/      shortcut installers
packaging/      PKGBUILD
```
