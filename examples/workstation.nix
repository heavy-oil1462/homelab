# Example workstation host: Hyprland desktop on an NVIDIA GPU, yubikey login,
# agent sandbox.
# Used by the flake's checks; copy it as a starting point for your own host.
{ config, lib, pkgs, ... }:

{
  imports = [
    ../modules/common.nix
    ../roles/workstation.nix
    ../modules/desktop/bluetooth.nix
    ../modules/nvidia.nix
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
    # The servers by their tailnet names, and Forgejo's SSH host.
    workstation.sshSharedHosts = [ "server" "nvr" "git.home.example.com" ];
    hyprland = {
      hyprlandLua = ./assets/hypr/hyprland.lua;
      hyprpaperConf = ./assets/hypr/hyprpaper.conf;
      monitorsLua = ./assets/hypr/monitors.lua;
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

  # Allow exactly the unfree packages this host uses rather than everything:
  # vscode from the workstation role, and the driver from the nvidia module.
  # A consumer importing either module needs the same predicate (or its own
  # allowUnfree) in their host.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "vscode"
      "nvidia-x11"
      "nvidia-settings"
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "25.05";
}
