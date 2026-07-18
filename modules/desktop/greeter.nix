{ config, pkgs, ... }:

# Wayland login greeter for the Hyprland workstations.
# greetd + tuigreet present a TTY session picker and launch Hyprland via UWSM.
{
  imports = [ ../options.nix ];

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --remember-session --sessions /run/current-system/sw/share/wayland-sessions:/run/current-system/sw/share/xsessions --cmd start-hyprland-uwsm";
        user = "greeter";
      };
    };
  };

  # Session keyboard layout. Hyprland itself sets its own kb_layout, and the
  # greeter runs on the console with the default keymap.
  services.xserver.xkb = {
    layout = config.homelab.keyboard.layout;
    variant = config.homelab.keyboard.variant;
  };

  systemd.services = {
    "getty@tty1".enable = false;
    "autovt@tty1".enable = false;
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "start-hyprland-uwsm" ''
      exec uwsm start hyprland-uwsm.desktop
    '')
  ];
}
