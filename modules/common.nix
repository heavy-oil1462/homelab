{ config, pkgs, lib, ... }:

{
  imports = [
    ./options.nix
    ./user.nix
    ./firewall.nix
    ./deploy-ca.nix
  ];

  # Default on; the server role turns this off so server updates are always
  # deliberate (paired with a pinned stable channel in the consumer's flake).
  system.autoUpgrade = {
    enable = lib.mkDefault true;
    dates = "weekly";
  };

  # The terminfo of every terminal nixpkgs packages, so ncurses programs work
  # over SSH from whatever terminal the client runs: nano on a server refused
  # $TERM=xterm-kitty ("can this be fixed once and for all too", owner,
  # board, 2026-11-14).
  #
  # This is environment.enableAllTerminfo's list (nixos/modules/config/
  # terminfo.nix), which cannot leave one out, without termite: its patched
  # vte fails to compile at our nixpkgs pin ("'to_integral' is not a member
  # of 'vte'") and is not in the binary cache; its authors have retired it
  # for alacritty. Keep the list in step with nixpkgs' on a bump.
  environment.systemPackages = lib.mkIf config.homelab.allTerminfo (
    map (p: p.terminfo) (with pkgs.pkgsBuildBuild; [
      alacritty
      contour
      foot
      ghostty
      kitty
      mtm
      rio
      rxvt-unicode-unwrapped
      rxvt-unicode-unwrapped-emoji
      st
      tmux
      wezterm
      yaft
    ])
  );

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
