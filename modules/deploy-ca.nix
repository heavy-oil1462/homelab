{ config, lib, ... }:

let
  cfg = config.homelab;
in
{
  imports = [ ./options.nix ];

  # Root SSH logins with short-lived certificates signed by the deploy CA.
  # A fleet update signs one certificate (a single hardware key touch) and
  # reuses it for every host, instead of authenticating once per connection.
  # Root has no authorized keys, so a certificate is the only way in.
  config = lib.mkIf (cfg.deployCaKeys != [ ]) {
    environment.etc."ssh/deploy_ca.pub".text =
      lib.concatStringsSep "\n" cfg.deployCaKeys + "\n";

    services.openssh = {
      enable = true;
      # Hosts that do not import the openssh module still need sshd so the
      # machine running the update can deploy to itself without sudo. Keep it
      # on loopback there; openssh.nix resets this to all addresses.
      listenAddresses = lib.mkDefault [
        { addr = "127.0.0.1"; port = 22; }
        { addr = "[::1]"; port = 22; }
      ];
      settings = {
        TrustedUserCAKeys = "/etc/ssh/deploy_ca.pub";
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
  };
}
