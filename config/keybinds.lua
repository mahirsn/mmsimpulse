-- Keys. Saved, they are bound at once.
--
--   mms.bind(keys, action)          keys as in Hyprland: "SUPER + SHIFT + 1"
--                                   (SUPER, CTRL, ALT, SHIFT; Return, Space,
--                                   Tab, Escape, Left, F1, XF86AudioRaiseVolume ...)
--   mms.exec(command)               run a command
--   mms.kwin(action)                a KWin action, by its name in
--                                   System Settings > Shortcuts > KWin
--   mms.workspace(n)                show workspace n (or "prev", "next") on
--                                   the monitor under the mouse
--   mms.movetoworkspace(n)          send the window there and follow it
--   mms.movetoworkspacesilent(n)    send the window there (or "prev", "next")
--
-- hl.bind(keys, hl.dsp.exec_cmd(...)) and the other hl.dsp actions work too.
-- A key bound here wins over the shell's profile and takes the key from
-- whatever else held it. A KWin action bound here gets exactly the keys
-- given here. require("name") loads ~/.config/mmsimpulse/name.lua.

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

-- mms.bind(mod .. " + Return", mms.exec("kitty"))
-- mms.bind(mod .. " + Q", mms.kwin("Window Close"))
-- mms.bind(mod .. " + F", mms.kwin("Window Maximize"))
-- mms.bind(mod .. " + SHIFT + F", mms.kwin("Window Fullscreen"))
-- mms.bind("XF86AudioPlay", mms.exec("playerctl play-pause"))
