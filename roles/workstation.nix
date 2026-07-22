{ config, pkgs, ... }:

let
  username = config.homelab.username;
  domain = config.homelab.domain;
in
{
  imports = [
    ../modules/options.nix
    ../modules/user.nix
    ../modules/desktop/sound.nix
    ../modules/desktop/greeter.nix
    ../modules/desktop/hyprland.nix
    ../modules/desktop/removable-media.nix
    ../modules/locale.nix
    ../modules/podman.nix
    ../modules/yubikey.nix
    ../containers/agent-sandbox.nix
    ../modules/tailscale.nix
  ];

  networking = {
    networkmanager.enable = true;
  };
  homelab.network.role = "workstation";

  users = {
    users = {
      ${username}.extraGroups = [
        "libvirtd"
      ];
    };
    groups = {
      libvirtd.members = [ username ];
    };
  };

  virtualisation = {
    libvirtd = {
      enable = true;
      qemu = {
        swtpm.enable = true;
      };
    };
    spiceUSBRedirection.enable = true;
  };

  environment.systemPackages = with pkgs; [
    bitwarden-desktop
    chromium
    wget
    git
    nextcloud-client
    virt-manager
    zed-editor
    btop
    yazi
    kdePackages.dolphin # GUI file manager (SUPER+E)
    fzf
    zellij
    (vscode-with-extensions.override {
      vscodeExtensions = with vscode-extensions; [
      ];
    })
  ];

  programs.chromium = {
    enable = true;
    extensions = [
      "nngceckbapebfimnlniiiahkandclblb"
      "ddkjiahejlhfcafbddmgiahcphecmpfh"
    ];
    extraOpts = {
      "HomepageLocation" = "https://${domain}/";
      "HomepageIsNewTabPage" = false;
      "RestoreOnStartup" = 4;
      "RestoreOnStartupURLs" = [
        "https://${domain}/"
      ];
      "ManagedBookmarks" = [
        {
          "name" = "Homelab Dashboard";
          "url" = "https://${domain}/";
        }
      ];
    };
  };
}
