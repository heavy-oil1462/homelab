{ config, pkgs, lib, ... }:

{
  imports = [
    ./options.nix
    ./user.nix
    ./firewall.nix
  ];

  # Default on; the server role turns this off so server updates are always
  # deliberate (paired with a pinned stable channel in the consumer's flake).
  system.autoUpgrade = {
    enable = lib.mkDefault true;
    dates = "weekly";
  };

  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 10d";
    };

    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
  };
}
