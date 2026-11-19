# The example server with Forgejo and Grafana signing in through Pocket ID
# (docs/adr/0018-pocket-id-is-the-oidc-provider.md) instead of tsidp, so the
# flake's checks evaluate both providers. server.nix declares each
# service's client in homelab.pocketId.clients once its provider is
# pocket-id. A site switching deletes its tsidp issuer instead, which then
# defaults to homelab.pocketId.url; here server.nix's is overridden.
{ config, lib, ... }:

{
  imports = [ ./server.nix ];

  homelab = {
    forgejo.oidc = {
      provider = "pocket-id";
      issuer = lib.mkForce config.homelab.pocketId.url;
    };
    observability.grafanaOidc = {
      provider = "pocket-id";
      issuer = lib.mkForce config.homelab.pocketId.url;
      # The emails of the admins' Pocket ID accounts.
      admins = lib.mkForce [ "alice@example.com" ];
    };
  };
}
