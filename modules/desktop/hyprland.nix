{ config, pkgs, ... }:

let
  username = config.homelab.username;
  hypr = config.homelab.hyprland;
in
{
  imports = [ ../options.nix ];

  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };

  # Screen locker. The NixOS module also registers the PAM service hyprlock
  # needs to check the password; installing the bare package is not enough.
  programs.hyprlock.enable = true;

  # File open/save dialogs (browser uploads and downloads, discord attach,
  # and so on) come from the desktop portal, and the hyprland portal backend
  # does not implement FileChooser; the gtk backend that programs.hyprland
  # also installs provides it. Routing normally comes from the
  # hyprland-portals.conf shipped in the hyprland package, but that file is
  # only matched when the portal service sees XDG_CURRENT_DESKTOP=Hyprland,
  # which depends on the compositor exporting it into the systemd user
  # environment before the portal is dbus-activated. When the match fails
  # the gtk backend falls back to its legacy UseIn=gnome restriction and
  # FileChooser has no backend at all: clicking browse silently does
  # nothing. This generic fallback applies to any desktop name, so the
  # dialogs work regardless of environment propagation timing.
  xdg.portal.config.common.default = [ "hyprland" "gtk" ];

  # Force Electron and Chromium apps to use Wayland native
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";

    # Slim cursor theme. Without this the session falls back to the chunky
    # default X11 cursor; these point both Wayland and XWayland apps at Bibata.
    XCURSOR_THEME = "Bibata-Modern-Classic";
    XCURSOR_SIZE = "24";
  };

  # Battery/power state over D-Bus. waybar's battery module and poweralertd
  # both read from here; on a laptop it also drives the critical-power action
  # (set per-host).
  services.upower.enable = true;

  # Nerd font so the waybar battery/network/volume glyphs render instead of
  # showing tofu boxes.
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  # Optional but highly recommended packages for a functional Hyprland session
  environment.systemPackages = with pkgs; [
    kitty # The default terminal for Hyprland
    rofi # App launcher

    bibata-cursors # Slim cursor theme (set via XCURSOR_* and hyprctl setcursor)

    dunst # Notification daemon
    hyprpaper # Wallpaper utility
    wl-clipboard # Clipboard utility

    waybar # Status bar (battery, clock, workspaces, volume, network)
    poweralertd # Sends low/critical battery notifications to dunst
    hypridle # Idle daemon: locks and blanks the screen after a timeout
    networkmanagerapplet # nm-applet tray icon for picking wifi networks

    grim # Screenshot capture
    slurp # Region picker for screenshots
    cliphist # Clipboard history (the autostart store hooks need this)
    libnotify # notify-send, used by the screenshot helper

    # Region screenshot to clipboard, or full screen saved to a file (and
    # copied). Bound to Print / SUPER+SHIFT+S in hyprland.conf.
    (pkgs.writeShellScriptBin "hypr-screenshot" ''
      set -euo pipefail
      dir="$HOME/Pictures/Screenshots"
      mkdir -p "$dir"
      file="$dir/$(date +%Y-%m-%d_%H-%M-%S).png"
      case "''${1:-region}" in
        full)
          grim "$file"
          wl-copy < "$file"
          notify-send "Screenshot" "Saved $file (and copied)"
          ;;
        region)
          grim -g "$(slurp)" - | wl-copy
          notify-send "Screenshot" "Region copied to clipboard"
          ;;
      esac
    '')

    # Lock, reboot, or power off. Locking goes through loginctl so hypridle's
    # lock_cmd stays the single place that actually starts hyprlock; reboot
    # and poweroff ask for confirmation in rofi since a stray click on the
    # waybar button should not take the machine down.
    (pkgs.writeShellScriptBin "hypr-power" ''
      set -euo pipefail
      case "''${1:-}" in
        lock)
          exec loginctl lock-session
          ;;
        reboot|poweroff)
          choice=$(printf 'cancel\nconfirm' | rofi -dmenu -i -p "$1?")
          if [ "$choice" = "confirm" ]; then
            exec systemctl "$1"
          fi
          ;;
        *)
          echo "usage: hypr-power lock|reboot|poweroff" >&2
          exit 1
          ;;
      esac
    '')

    # Pick a past clipboard entry from rofi and put it back on the clipboard.
    (pkgs.writeShellScriptBin "hypr-cliphist" ''
      cliphist list | rofi -dmenu -i -p "Clipboard" | cliphist decode | wl-copy
    '')

    # Readable keybind cheatsheet in a rofi window (SUPER+SHIFT+/).
    (pkgs.writeShellScriptBin "hypr-help" ''
            cat <<'EOF' | rofi -dmenu -i -p "Hyprland keybinds"
      SUPER + Q                 Open terminal (kitty)
      SUPER + R                 App launcher (rofi)
      SUPER + E                 File manager (yazi)
      SUPER + C                 Close active window
      SUPER + V                 Toggle floating
      SUPER + F                 Fullscreen
      SUPER + SHIFT + F         Maximize within gaps
      SUPER + G                 Group/tab windows together
      SUPER + L                 Lock screen
      SUPER + 1..9              Switch to workspace
      SUPER + SHIFT + 1..9      Move window to workspace
      SUPER + arrows / h j k    Move focus (vim l is taken by lock)
      SUPER + SHIFT + move key  Move window in layout
      SUPER + CTRL + h j k l    Resize active window
      SUPER + SHIFT + V         Clipboard history
      SUPER + SHIFT + S         Screenshot region -> clipboard
      Print                     Screenshot full screen -> file
      SUPER + SHIFT + /         Show this help
      SUPER + M                 Exit Hyprland
      Volume                    Hardware media keys
      EOF
    '')
  ];

  system.activationScripts.hyprlandConfig = {
    deps = [ "users" ];
    text = ''
      # Ensure .config exists and is owned by the user
      mkdir -p /home/${username}/.config
      chown ${username}:users /home/${username}/.config

      # Ensure hypr directory exists
      mkdir -p /home/${username}/.config/hypr
      chown ${username}:users /home/${username}/.config/hypr

      # Install the Hyprland config verbatim.
      cp -f ${hypr.hyprlandConf} /home/${username}/.config/hypr/hyprland.conf

      # Host-specific monitor layout, sourced by hyprland.conf.
      cp -f ${hypr.monitorsConf} /home/${username}/.config/hypr/monitors.conf
      chown ${username}:users /home/${username}/.config/hypr/monitors.conf
      chmod 644 /home/${username}/.config/hypr/monitors.conf

      # Set correct ownership and permissions
      chown ${username}:users /home/${username}/.config/hypr/hyprland.conf
      chmod 644 /home/${username}/.config/hypr/hyprland.conf

      # Copy hyprpaper config
      cp -f ${hypr.hyprpaperConf} /home/${username}/.config/hypr/hyprpaper.conf
      chown ${username}:users /home/${username}/.config/hypr/hyprpaper.conf
      chmod 644 /home/${username}/.config/hypr/hyprpaper.conf

      # Lock screen and idle daemon configs
      cp -f ${hypr.hyprlockConf} /home/${username}/.config/hypr/hyprlock.conf
      cp -f ${hypr.hypridleConf} /home/${username}/.config/hypr/hypridle.conf
      chown ${username}:users /home/${username}/.config/hypr/hyprlock.conf /home/${username}/.config/hypr/hypridle.conf
      chmod 644 /home/${username}/.config/hypr/hyprlock.conf /home/${username}/.config/hypr/hypridle.conf

      # Waybar config (status bar with battery indicator)
      mkdir -p /home/${username}/.config/waybar
      chown ${username}:users /home/${username}/.config/waybar
      cp -f ${hypr.waybarConfig} /home/${username}/.config/waybar/config.jsonc
      cp -f ${hypr.waybarStyle} /home/${username}/.config/waybar/style.css
      chown ${username}:users /home/${username}/.config/waybar/config.jsonc /home/${username}/.config/waybar/style.css
      chmod 644 /home/${username}/.config/waybar/config.jsonc /home/${username}/.config/waybar/style.css
    '';
  };
}
