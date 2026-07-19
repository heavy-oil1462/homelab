# Example workstation host: Hyprland desktop, yubikey login, agent sandbox.
# Used by the flake's checks; copy it as a starting point for your own host.
{ config, pkgs, ... }:

{
  imports = [
    ../modules/common.nix
    ../roles/workstation.nix
    ../modules/desktop/bluetooth.nix
  ];

  homelab = {
    username = "alice";
    domain = "home.example.com";
    keyboard = {
      layout = "us";
      variant = "";
      consoleKeyMap = "us";
    };
    yubikey.u2fKeysFile = ./assets/u2f_keys;
    hyprland = {
      hyprlandConf = ./assets/hypr/hyprland.conf;
      hyprpaperConf = ./assets/hypr/hyprpaper.conf;
      monitorsConf = ./assets/hypr/monitors.conf;
      hyprlockConf = ./assets/hypr/hyprlock.conf;
      hypridleConf = ./assets/hypr/hypridle.conf;
      waybarConfig = ./assets/waybar/config.jsonc;
      waybarStyle = ./assets/waybar/style.css;
    };
    agentSandbox = {
      gitName = "alice";
      gitEmail = "1+alice@users.noreply.github.com";
      allowedEmails = [ "1+alice@users.noreply.github.com" ];
      skillsRepo = "https://github.com/alice/skills";
    };
  };

  networking.hostName = "example-workstation";

  # The workstation role pulls in a few unfree packages (vscode).
  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "25.05";
}
