{ config, pkgs, ... }:

let
  cfg = config.homelab;
in
{
  imports = [ ./options.nix ];

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = cfg.acmeEmail;
      server = "https://acme-v02.api.letsencrypt.org/directory";
    };

    certs."${cfg.domain}" = {
      domain = cfg.domain;
      extraDomainNames = [ "*.${cfg.domain}" ];
      dnsProvider = "cloudflare";
      environmentFile = "/var/lib/secrets/cloudflare.env";
    };
  };
}
