{ config, pkgs, lib, ... }:

let
  domain = config.homelab.domain;
  tailnetIp = config.homelab.tailnetIp;
  cfg = config.homelab.reverseProxy;

  caddyFile = pkgs.writeText "caddyfile" (
    builtins.replaceStrings [ "__DOMAIN__" ] [ domain ] (builtins.readFile cfg.caddyfile)
  );
  notFoundHtml = pkgs.writeText "404.html" (builtins.readFile cfg.notFoundPage);
in
{
  imports = [ ../modules/options.nix ];

  virtualisation.oci-containers.containers.caddy = {
    image = "docker.io/library/caddy@sha256:25cdc846626b62d05f6b633b9b40c2c9f6ef89b515dc76133cefd920f7dbe562";
    # When homelab.tailnetIp is set, publishing 443 bound to that address
    # (instead of 0.0.0.0) is what makes every site tailnet-only: there is
    # simply no listener on the LAN interfaces. This replaces a per-vhost
    # tailnet matcher in the Caddyfile, which could not work because podman
    # source-NATs inbound connections to the bridge gateway before Caddy sees
    # the client IP.
    ports = [ (if tailnetIp != null then "${tailnetIp}:443:443" else "443:443") ];
    autoStart = true;
    volumes = [
      "${caddyFile}:/etc/caddy/Caddyfile"
      "${notFoundHtml}:/var/www/404.html:ro"
      "/var/lib/acme/${domain}:/certs:ro"
      "caddy-volume:/data"
    ];
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
