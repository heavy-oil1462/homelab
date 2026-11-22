{ config, lib, pkgs, ... }:

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

  # One PIN and touch per working session to each of the site's hosts
  # (docs/adr/0025-yubikey-prompts-once-per-session.md). Only the owner's
  # user: the socket lives in /run/user/<uid>, which a user without a
  # session (root under sudo) lacks, and ssh exits when it cannot make it.
  # The Host * after it closes the Match for whatever follows.
  programs.ssh.extraConfig = lib.mkIf (config.homelab.workstation.sshSharedHosts != [ ]) ''
    Match originalhost ${lib.concatStringsSep "," config.homelab.workstation.sshSharedHosts} localuser ${username}
      ControlMaster auto
      ControlPath /run/user/%i/ssh-%C
      ControlPersist 4h
    Host *
  '';

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
