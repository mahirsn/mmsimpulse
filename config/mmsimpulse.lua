-- mmsimpulse config: ~/.config/mmsimpulse/mmsimpulse.lua
--
-- The files in ~/.config/mmsimpulse are written once by mmsimpulse-install
-- and are yours from then on: each one explains what it can hold. It is Lua,
-- as Hyprland's hyprland.lua is, and split the same way: this file only
-- loads the others. Saving any of them applies it at once (each file says
-- what waits for the next login); a mistake shows a notification and leaves
-- everything as it was. The log is ~/.local/share/mmsimpulse.log.
--
-- hl.* works too, so a Hyprland Lua file can be copied in as it is.

require("keybinds")   -- keys
require("input")      -- keyboard layout, key repeat, mouse and touchpad
require("monitors")   -- resolution, refresh rate, position, scale, rotation
require("autostart")  -- programs to start with the session
require("env")        -- environment variables
require("decoration") -- borders, corners, opacity, blur, dimming
require("rules")      -- window rules
require("animations") -- animations on or off, and their speed
require("misc")       -- focus on activation

-- mms.shell("dux")   -- the shell to start, instead of ~/.config/mmsimpulse/shell

-- Another compositor's config
--
-- mms.source(path) runs a Hyprland Lua file, or reads a hyprland.conf or a
-- niri config.kdl, and takes in what has a KWin counterpart. Two ways:
--
--   mms.source("~/.config/hypr/keybinds.lua")
--       one file, with everything in it.
--
--   mms.source("~/.config/hypr/hyprland.lua", { "binds", "input", "monitors" })
--       a whole config, but only the parts named: binds, input, monitors,
--       autostart, env, general, decoration, rules, animations, misc.
--       Without the list, a whole config also starts its autostart programs
--       (Hyprland's bar, wallpaper and the like) here.
--
-- What comes from there: commands become global shortcuts; close, kill,
-- fullscreen, pin, focus, move and resize become the matching KWin actions;
-- the settings and rules as the files above describe them. Workspace
-- binds, layouts and mouse binds are left out (the log names each setting
-- with no KWin counterpart). A KWin action bound only there
-- keeps its other keys. Remove the "-- " in front to use one.
