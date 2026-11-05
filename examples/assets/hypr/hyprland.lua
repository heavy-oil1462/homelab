-- Example Hyprland config for the desktop-hyprland module. The module
-- installs this as ~/.config/hypr/hyprland.lua and the per-host monitor
-- layout as monitors.lua next to it. Hyprland 0.57 and later read only Lua
-- configs.
require("monitors")

-- Runs once per session, like exec-once did. Top-level code runs again on
-- every config reload.
hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("dunst")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("nm-applet --indicator")
end)

hl.config({
    input = {
        kb_layout = "us",
    },
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 2,
    },
})

hl.window_rule({
    name  = "float-blueman",
    match = { class = "^(blueman-manager)$" },
    float = true,
})

local mod = "SUPER"
hl.bind(mod .. " + Q", hl.dsp.exec_cmd("kitty"))
hl.bind(mod .. " + R", hl.dsp.exec_cmd("rofi -show drun"))
hl.bind(mod .. " + C", hl.dsp.window.close())
hl.bind(mod .. " + M", hl.dsp.exit())
hl.bind(mod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mod .. " + L", hl.dsp.exec_cmd("hypr-power lock"))
hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd("hypr-screenshot region"))
hl.bind("Print", hl.dsp.exec_cmd("hypr-screenshot full"))
