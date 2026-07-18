{ config, pkgs, ... }:

{
  imports = [ ./options.nix ];

  services = {
    openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
  };

  users.users.${config.homelab.username}.openssh.authorizedKeys.keys =
    config.homelab.adminKeys;
}
