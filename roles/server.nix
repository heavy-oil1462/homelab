{ config, pkgs, ... }:

{
  imports = [
    ../modules/options.nix
    ../modules/openssh.nix
    ../modules/locale.nix
    ../modules/podman.nix
    ../modules/observability-agent.nix
    ../modules/logging-agent.nix
    ../modules/tailscale.nix
  ];

  boot = {
    loader.grub = {
      enable = true;
    };
    growPartition = true;
  };

  networking = {
    useDHCP = true;
  };

  homelab.network.role = "server";

  # Servers update deliberately, not on a timer: they track the pinned stable
  # channel in the consumer's flake and are rebuilt by hand via the deploy
  # scripts.
  system.autoUpgrade.enable = false;

  services.qemuGuest.enable = true;

  nix.settings = {
    trusted-users = [ "root" "@wheel" ];
  };

  security.sudo.wheelNeedsPassword = false;
}
