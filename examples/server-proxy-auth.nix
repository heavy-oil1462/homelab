# The example server with Forgejo and Grafana on proxy authentication
# (docs/adr/0005-proxy-auth-only-from-caddy.md) instead of tsidp, so the
# flake's checks evaluate that path too and run the identity snippets it
# generates. A host uses one or the other for each service.
{ lib, ... }:

let
  # The git and status sites of the example Caddyfile, as proxy
  # authentication needs them.
  caddyfile = lib.replaceStrings
    [
      "\treverse_proxy forgejo:3000\n"
      "\treverse_proxy grafana:3000\n"
    ]
    [
      "\timport forgejo_identity\n\treverse_proxy unix//run/forgejo-http/http.sock\n"
      "\timport grafana_identity\n\treverse_proxy grafana:3000\n"
    ]
    (builtins.readFile ./assets/caddy/Caddyfile);
in
{
  imports = [ ./server.nix ];

  assertions = [
    {
      assertion = lib.hasInfix "import forgejo_identity\n" caddyfile
        && lib.hasInfix "import grafana_identity\n" caddyfile;
      message = "examples/server-proxy-auth.nix no longer finds the git and status sites in the example Caddyfile.";
    }
  ];

  homelab = {
    reverseProxy.caddyfile = lib.mkForce (builtins.toFile "Caddyfile" caddyfile);
    observability = {
      grafanaOidc.enable = lib.mkForce false;
      grafanaProxyAuth = {
        enable = true;
        admins = [ "alice@example" ];
      };
    };
    forgejo = {
      oidc.enable = lib.mkForce false;
      proxyAuth = {
        enable = true;
        users."alice@example" = "alice";
      };
    };
  };
}
