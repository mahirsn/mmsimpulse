-- mmsimpulse config: ~/.config/mmsimpulse/mmsimpulse.lua
--
-- Written once by mmsimpulse-install and yours from then on. Saving it binds
-- the keys again at once; a mistake shows a notification and leaves the keys
-- as they were. It is Lua, as Hyprland's hyprland.lua: hl.bind and
-- hl.dsp.* work here too, and require("name") loads
-- ~/.config/mmsimpulse/name.lua.
--
--   mms.bind(keys, action)          keys as in Hyprland: "SUPER + SHIFT + 1"
--   mms.exec(command)               run a command
--   mms.kwin(action)                a KWin action, by its name in
--                                   System Settings > Shortcuts > KWin
--   mms.workspace(n)                show workspace n (or "prev", "next") on
--                                   the monitor under the mouse
--   mms.movetoworkspace(n)          send the window there and follow it
--   mms.movetoworkspacesilent(n)    send the window there (or "prev", "next")
--   mms.shell(name)                 the shell to start, as in
--                                   ~/.config/mmsimpulse/shell
--   mms.source(path)                take in the keys of a Hyprland
--                                   (.lua or .conf) or niri (.kdl) config
--
-- A key bound here wins over the shell's profile and takes the key from
-- whatever else held it. A KWin action bound here gets exactly the keys
-- given here.

local mod = "SUPER"

-- Workspaces 1..10 on keys 1..0.
for i = 1, 10 do
  local key = tostring(i % 10)
  mms.bind(mod .. " + " .. key, mms.workspace(i))
  mms.bind(mod .. " + ALT + " .. key, mms.movetoworkspacesilent(i))
  mms.bind(mod .. " + SHIFT + " .. key, mms.movetoworkspace(i))
end
mms.bind(mod .. " + CTRL + Left", mms.workspace("prev"))
mms.bind(mod .. " + CTRL + Right", mms.workspace("next"))
mms.bind(mod .. " + SHIFT + Left", mms.movetoworkspacesilent("prev"))
mms.bind(mod .. " + SHIFT + Right", mms.movetoworkspacesilent("next"))

-- Examples:
-- mms.bind(mod .. " + Return", mms.exec("kitty"))
-- mms.bind(mod .. " + Q", mms.kwin("Window Close"))
-- mms.bind(mod .. " + F", mms.kwin("Window Maximize"))
-- require("keybinds")

-- Keys from another compositor's config. mms.source runs a Hyprland Lua
-- config (or reads a hyprland.conf / niri config.kdl) and binds what it can
-- here: commands become global shortcuts; close, kill, fullscreen, pin,
-- focus, move and resize become the matching KWin actions. Workspace binds,
-- layouts and mouse binds are left out. A KWin action bound only there keeps
-- its other keys. Remove the "-- " in front to use one.
