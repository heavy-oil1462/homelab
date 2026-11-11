# Example headless VM: the server role on a disk laid out by vm-disko. Used by
# the flake's checks, which add disko's NixOS module; a consumer adds it from
# their own disko input. disko provides the root filesystem and the GRUB
# device from the layout. All values here are placeholders.
{ config, pkgs, ... }:

{
  imports = [
    ../modules/common.nix
    ../roles/server.nix
    ../modules/vm-disko.nix
  ];

  homelab = {
    username = "alice";
    domain = "home.example.com";
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPlaceholderPlaceholder0000000000A alice@example"
    ];
    tailnetIp = "100.64.0.2";
  };

  networking.hostName = "example-vm";

  system.stateVersion = "25.05";
}
