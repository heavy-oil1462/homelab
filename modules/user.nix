{ config, pkgs, ... }:

let
  username = config.homelab.username;
in
{
  imports = [ ./options.nix ];

  users = {
    users = {
      ${username} = {
        isNormalUser = true;
        description = username;
        extraGroups = [ "networkmanager" "wheel" ];
      };
    };
    mutableUsers = false;
    allowNoPasswordLogin = true;
  };
}
