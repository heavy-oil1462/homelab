{ config, lib, ... }:

# tsidp, Tailscale's OpenID Connect provider, with nixpkgs' services.tsidp
# (docs/adr/0006-tsidp-for-oidc-sign-in.md). It joins the tailnet as its own
# node through tsnet, homelab.tsidp.hostName, and serves HTTPS with that
# node's ts.net certificate on port 443 of the node's own address. Nothing
# listens on the host's interfaces. The issuer URL is
# https://<hostName>.<tailnet>.ts.net.
#
# The auth key is an environment file provisioned out of band, read only
# until the node has state:
#
#   echo TS_AUTHKEY=tskey-auth-... > /var/lib/secrets/tsidp.env
#   chmod 0400 /var/lib/secrets/tsidp.env
#
# Use a one-off key with a tag, so the node key does not expire. The admin
# UI, where clients are registered, is denied until the tailnet policy
# grants the tailscale.com/cap/tsidp capability with allow_admin_ui to its
# users; the README shows a grant.

let
  cfg = config.homelab.tsidp;
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    services.tsidp = {
      enable = true;
      environmentFile = cfg.authKeyFile;
      settings = {
        inherit (cfg) hostName;
        # tsnet, not the host's tailscaled: with the host's node, tsidp would
        # take 443 on the host's tailnet address, where Caddy is.
        useLocalTailscaled = false;
        enableFunnel = false;
        # Token exchange (RFC 8693) is for services that act for a user;
        # none of ours do.
        enableSts = false;
      };
    };

    # nixpkgs' module keeps its state in this StateDirectory under a
    # DynamicUser; homelab.tsidp.stateDir names it for backups.
    assertions = [
      {
        assertion = config.systemd.services.tsidp.serviceConfig.StateDirectory == baseNameOf cfg.stateDir;
        message = "nixpkgs' services.tsidp no longer keeps its state in ${cfg.stateDir}; update homelab.tsidp.stateDir.";
      }
    ];
  };
}
