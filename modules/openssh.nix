{ config, lib, pkgs, ... }:

{
  imports = [ ./options.nix ];

  services = {
    openssh = {
      enable = true;
      openFirewall = false;
      # Listen on every address; overrides the loopback default deploy-ca.nix
      # sets for hosts without this module.
      listenAddresses = [ ];
      settings = {
        PasswordAuthentication = false;
        # deploy-ca.nix allows root in with a CA certificate when configured.
        PermitRootLogin = lib.mkDefault "no";
      };
    };
  };

  users.users.${config.homelab.username}.openssh.authorizedKeys.keys =
    config.homelab.adminKeys;
}
