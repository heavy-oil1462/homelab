{ config, pkgs, lib, ... }:

let
  domain = config.homelab.domain;
  tailnetIp = config.homelab.tailnetIp;
  cfg = config.homelab.reverseProxy;

  caddyFile = pkgs.writeText "caddyfile" (
    builtins.replaceStrings [ "__DOMAIN__" ] [ domain ] (builtins.readFile cfg.caddyfile)
  );
  notFoundHtml = pkgs.writeText "404.html" (builtins.readFile cfg.notFoundPage);

  # The tailnet_identity snippet in the example Caddyfile dials this path.
  # It sits in its own directory, mounted into the container, rather than
  # under nginx-auth's RuntimeDirectory: systemd deletes and recreates that
  # one when the service restarts, and the container's bind mount would keep
  # pointing at the deleted directory.
  identitySocketDir = "/run/tailnet-identity";
in
{
  imports = [ ../modules/options.nix ];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.tailscaleIdentity.enable
            || !(lib.hasInfix "import tailnet_identity" (builtins.readFile cfg.caddyfile));
          message = "The Caddyfile imports tailnet_identity, which needs homelab.reverseProxy.tailscaleIdentity.enable.";
        }
      ];

      virtualisation.oci-containers.containers.caddy = {
        image = "docker.io/library/caddy@sha256:25cdc846626b62d05f6b633b9b40c2c9f6ef89b515dc76133cefd920f7dbe562";
        # When homelab.tailnetIp is set, publishing 443 bound to that address
        # (instead of 0.0.0.0) is what makes every site tailnet-only: there is
        # simply no listener on the LAN interfaces. This replaces a per-vhost
        # tailnet matcher in the Caddyfile, which could not work because
        # tailscale source-NATs the forwarded connections to the bridge
        # gateway before Caddy sees the client IP, unless
        # tailscaleIdentity turns that off.
        ports = [ (if tailnetIp != null then "${tailnetIp}:443:443" else "443:443") ];
        autoStart = true;
        volumes = [
          "${caddyFile}:/etc/caddy/Caddyfile"
          "${notFoundHtml}:/var/www/404.html:ro"
          "/var/lib/acme/${domain}:/certs:ro"
          "caddy-volume:/data"
        ] ++ lib.optional cfg.tailscaleIdentity.enable "${identitySocketDir}:${identitySocketDir}";
      };

      # The tailnet port bind only succeeds once tailscale has assigned the
      # tailnet IP. On a cold boot podman can start before that, so order after
      # tailscaled and retry on failure (with the start-rate limiter disabled)
      # until the address exists, instead of leaving Caddy down.
      systemd.services.podman-caddy = lib.mkIf (tailnetIp != null) {
        after = [ "tailscaled.service" ];
        wants = [ "tailscaled.service" ];
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = lib.mkForce "on-failure";
          RestartSec = lib.mkForce 5;
        };
      };
    }

    (lib.mkIf cfg.tailscaleIdentity.enable {
      # tailscale's nginx-auth answers a request carrying Remote-Addr and
      # Remote-Port with the tailnet user behind that address (204 and
      # Tailscale-User), 403 for a tagged node and 401 for an address that is
      # not a tailnet peer. Caddy runs as root in the container, so the
      # socket's 0660 mode does not keep it out.
      services.tailscaleAuth = {
        enable = true;
        socketPath = "${identitySocketDir}/whois.sock";
      };

      # tailscale marks everything forwarded in from tailscale0 and
      # masquerades it on the way out (its subnet-route SNAT, on by default).
      # Podman DNATs 443 to the caddy container, so these connections are
      # forwarded and arrive from the podman bridge address, which WhoIs
      # cannot resolve. podman itself only masquerades hairpin and localhost
      # traffic. Without the SNAT the container sees the tailnet peer.
      services.tailscale.extraSetFlags = [ "--snat-subnet-routes=false" ];

      systemd.services.podman-caddy = {
        after = [ "tailscale-nginx-auth.socket" ];
        requires = [ "tailscale-nginx-auth.socket" ];
      };
    })
  ];
}
