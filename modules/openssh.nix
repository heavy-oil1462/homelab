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
        # Keyboard-interactive goes through PAM and takes a password too.
        # Off whenever SSH is open to the LAN (homelab.network.sshFrom);
        # deploy-ca.nix turns it off with the deploy CA as well.
        KbdInteractiveAuthentication =
          lib.mkIf (config.homelab.network.sshFrom != [ ]) false;
        # deploy-ca.nix allows root in with a CA certificate when configured.
        PermitRootLogin = lib.mkDefault "no";
      };
    };
  };

  users.users.${config.homelab.username}.openssh.authorizedKeys.keys =
    config.homelab.adminKeys;
}
