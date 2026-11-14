{ config, lib, pkgs, utils, ... }:

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
# Use a one-off key with a tag, so the node key does not expire.
#
# The clients in homelab.tsidp.clients are written into tsidp's clients file
# before it starts, by tsidp-clients.sh as root, which also generates each
# client's id and secret file when missing
# (docs/adr/0010-tsidp-clients-declared-in-nix.md). Other clients can still
# be registered in the admin UI, which is denied until the tailnet policy
# grants the tailscale.com/cap/tsidp capability with allow_admin_ui to its
# users; the README shows a grant.

let
  cfg = config.homelab.tsidp;

  clientsScript = pkgs.callPackage ./tsidp-clients.nix { };
  clientsSpec = pkgs.writeText "tsidp-clients.json" (builtins.toJSON (lib.mapAttrsToList (id: c: {
    inherit id;
    inherit (c) redirectUris idFile secretFile;
    owner = "${c.owner}:${(config.users.users.${c.owner} or { group = c.owner; }).group}";
  }) cfg.clients));
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

    # tsidp reads its clients only when it starts, so it is restarted when
    # the declared ones change. "+" runs the script as root, outside the
    # sandbox, after systemd has made the state directory: it writes the
    # secret files and the clients file, owned like the directory.
    systemd.services.tsidp = {
      restartTriggers = [ clientsSpec ];
      serviceConfig.ExecStartPre = [
        "+${clientsScript}/bin/tsidp-clients ${utils.escapeSystemdExecArgs [ clientsSpec cfg.stateDir ]}"
      ];
    };

    assertions = [
      # nixpkgs' module keeps its state in this StateDirectory under a
      # DynamicUser; homelab.tsidp.stateDir names it for backups.
      {
        assertion = config.systemd.services.tsidp.serviceConfig.StateDirectory == baseNameOf cfg.stateDir;
        message = "nixpkgs' services.tsidp no longer keeps its state in ${cfg.stateDir}; update homelab.tsidp.stateDir.";
      }
    ] ++ lib.concatLists (lib.mapAttrsToList (id: c: [
      {
        assertion = builtins.match "[A-Za-z0-9._-]+" id != null;
        message = "homelab.tsidp.clients.\"${id}\": a client id is letters, digits, '.', '_' and '-' only.";
      }
      {
        assertion = config.users.users ? ${c.owner};
        message = "homelab.tsidp.clients.${id}.owner: there is no user ${c.owner}.";
      }
    ]) cfg.clients);
  };
}
