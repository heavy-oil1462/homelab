# Forgejo's and Grafana's OIDC sign in on each provider, tsidp and Pocket
# ID, in the example servers (docs/adr/0019-forgejo-and-grafana-on-pocket-id.md).
# Pure evaluation of the host configs:
#
# - with tsidp, the default, everything is as before: the source
#   "tailscale", users named after the email claim, tsidp's endpoints, the
#   admins' tailnet logins in both forms and no email lookup in Grafana;
# - with Pocket ID, the issuer is homelab.pocketId.url, the source
#   "pocket-id" takes over a "tailscale" one in place, users are named
#   after preferred_username, Grafana uses Pocket ID's endpoints, matches
#   the admins' emails and looks existing users up by email, and both
#   clients are declared in homelab.pocketId.clients, written before the
#   services' units;
# - Forgejo links an existing account only with its password on both;
# - choosing Pocket ID without it, or without the service's client, and
#   tsidp without an issuer, fail the build with a clear message.
#
# It cannot sign anyone in: the forgejo-oidc check runs the script's
# update path, and sign in against a real provider is tested by hand.
{ lib, writeText, tsidp, pocketId, broken }:

let
  text = builtins.unsafeDiscardStringContext;
  forgejoEnv = cfg: cfg.virtualisation.oci-containers.containers.forgejo.environment;
  grafanaEnv = cfg: cfg.virtualisation.oci-containers.containers.grafana.environment;
  forgejoOidc = cfg: cfg.systemd.services.forgejo-oidc;
  # forgejo-oidc's arguments after the script, each quoted by
  # escapeSystemdExecArgs.
  args = cfg: map (lib.removeSuffix "\"") (lib.drop 1
    (lib.splitString " \"" (text (forgejoOidc cfg).serviceConfig.ExecStart)));
  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  clientOf = cfg: name: lib.mapNullable
    (lib.getAttrs [ "redirectUris" "idFile" "secretFile" "owner" "units" ])
    (cfg.homelab.pocketId.clients.${name} or null);

  expect = what: want: have:
    lib.optional (want != have) "${what}: expected ${builtins.toJSON want}, got ${builtins.toJSON have}";
  expectElem = what: x: xs:
    lib.optional (!(lib.elem x xs)) "${what}: ${builtins.toJSON x} not in ${builtins.toJSON xs}";
  expectFailure = what: needle: cfg:
    lib.optional (!(lib.any (lib.hasInfix needle) (failed cfg)))
      "${what}: no failed assertion with ${builtins.toJSON needle}, got ${builtins.toJSON (failed cfg)}";

  idp = "https://idp.tailnet.invalid";
  id = "https://id.home.example.com";

  problems =
    # tsidp, as before.
    expect "tsidp: Forgejo's USERNAME" "email" (forgejoEnv tsidp).FORGEJO__oauth2_client__USERNAME
    ++ expect "tsidp: Forgejo's ACCOUNT_LINKING" "login" (forgejoEnv tsidp).FORGEJO__oauth2_client__ACCOUNT_LINKING
    ++ expect "tsidp: forgejo-oidc's arguments, the former source names last"
      [ "tailscale" "${idp}" "/var/lib/secrets/forgejo-oidc-client-id" "/var/lib/secrets/forgejo-oidc-client-secret" "/var/lib/forgejo-oidc/applied" "pocket-id" ]
      (args tsidp)
    ++ expectElem "tsidp: forgejo-oidc runs after" "tsidp.service" (forgejoOidc tsidp).after
    ++ expect "tsidp: Grafana's provider name" "Tailscale" (grafanaEnv tsidp).GF_AUTH_GENERIC_OAUTH_NAME
    ++ expect "tsidp: Grafana's token URL" "${idp}/token" (grafanaEnv tsidp).GF_AUTH_GENERIC_OAUTH_TOKEN_URL
    ++ expect "tsidp: Grafana's userinfo URL" "${idp}/userinfo" (grafanaEnv tsidp).GF_AUTH_GENERIC_OAUTH_API_URL
    ++ expect "tsidp: Grafana's email lookup" null ((grafanaEnv tsidp).GF_AUTH_OAUTH_ALLOW_INSECURE_EMAIL_LOOKUP or null)
    ++ expect "tsidp: Grafana's role path"
      "contains(['alice@example.com', 'alice@github', 'alice@github.idp.tailnet.invalid'], email) && 'Admin'"
      (grafanaEnv tsidp).GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH
    ++ expectElem "tsidp: Grafana starts after" "tsidp.service" tsidp.systemd.services.podman-grafana.after
    ++ expect "tsidp: tsidp's clients" [ "forgejo" "grafana" ] (lib.attrNames tsidp.homelab.tsidp.clients)
    ++ expect "tsidp: Pocket ID's clients" [ ] (lib.attrNames tsidp.homelab.pocketId.clients)

    # Pocket ID.
    ++ expect "pocket-id: Forgejo's issuer" id pocketId.homelab.forgejo.oidc.issuer
    ++ expect "pocket-id: Forgejo's USERNAME" "preferred_username" (forgejoEnv pocketId).FORGEJO__oauth2_client__USERNAME
    ++ expect "pocket-id: Forgejo's ACCOUNT_LINKING" "login" (forgejoEnv pocketId).FORGEJO__oauth2_client__ACCOUNT_LINKING
    ++ expect "pocket-id: forgejo-oidc's arguments, the former source names last"
      [ "pocket-id" "${id}" "/var/lib/secrets/forgejo-oidc-client-id" "/var/lib/secrets/forgejo-oidc-client-secret" "/var/lib/forgejo-oidc/applied" "tailscale" ]
      (args pocketId)
    ++ expectElem "pocket-id: forgejo-oidc runs after" "pocket-id-clients.service" (forgejoOidc pocketId).after
    ++ expect "pocket-id: Grafana's issuer" id pocketId.homelab.observability.grafanaOidc.issuer
    ++ expect "pocket-id: Grafana's provider name" "Pocket ID" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_NAME
    ++ expect "pocket-id: Grafana's auth URL" "${id}/authorize" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_AUTH_URL
    ++ expect "pocket-id: Grafana's token URL" "${id}/api/oidc/token" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_TOKEN_URL
    ++ expect "pocket-id: Grafana's userinfo URL" "${id}/api/oidc/userinfo" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_API_URL
    ++ expect "pocket-id: Grafana's email lookup" "true" (grafanaEnv pocketId).GF_AUTH_OAUTH_ALLOW_INSECURE_EMAIL_LOOKUP
    ++ expect "pocket-id: Grafana's role path"
      "contains(['alice@example.com'], email) && 'Admin'"
      (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH
    ++ expectElem "pocket-id: Grafana starts after" "pocket-id-clients.service" pocketId.systemd.services.podman-grafana.after
    ++ expect "pocket-id: tsidp's clients" [ ] (lib.attrNames pocketId.homelab.tsidp.clients)
    ++ expect "pocket-id: Forgejo's client"
      {
        redirectUris = [ "https://git.home.example.com/user/oauth2/pocket-id/callback" ];
        idFile = "/var/lib/secrets/forgejo-oidc-client-id";
        secretFile = "/var/lib/secrets/forgejo-oidc-client-secret";
        owner = "root";
        units = [ "forgejo-oidc.service" ];
      }
      (clientOf pocketId "forgejo")
    ++ expect "pocket-id: Grafana's client"
      {
        redirectUris = [ "https://status.home.example.com/login/generic_oauth" ];
        idFile = "/var/lib/secrets/grafana-oidc-client-id";
        secretFile = "/var/lib/secrets/grafana-oidc-client-secret";
        owner = "grafana";
        units = [ "podman-grafana.service" ];
      }
      (clientOf pocketId "grafana")
    ++ expectElem "pocket-id: pocket-id-clients runs before" "forgejo-oidc.service"
      pocketId.systemd.services.pocket-id-clients.before
    ++ expectElem "pocket-id: pocket-id-clients runs before" "podman-grafana.service"
      pocketId.systemd.services.pocket-id-clients.before

    # The assertions.
    ++ expectFailure "Forgejo on Pocket ID without it" "homelab.forgejo.oidc.provider is pocket-id, but homelab.pocketId is not enabled" broken.noPocketId
    ++ expectFailure "Grafana on Pocket ID without it" "homelab.observability.grafanaOidc.provider is pocket-id, but homelab.pocketId is not enabled" broken.noPocketId
    ++ expectFailure "Forgejo on Pocket ID without its client" "declare Forgejo's client in homelab.pocketId.clients" broken.noClients
    ++ expectFailure "Grafana on Pocket ID without its client" "declare Grafana's client in homelab.pocketId.clients" broken.noClients
    ++ expectFailure "Forgejo on Pocket ID with tsidp's issuer" "homelab.forgejo.oidc.issuer is ${idp}, but with Pocket ID it is ${id}" broken.tsidpIssuer
    ++ expectFailure "Forgejo on tsidp without an issuer" "homelab.forgejo.oidc.provider is tsidp, which needs homelab.forgejo.oidc.issuer" broken.noIssuer
    ++ expectFailure "Grafana on tsidp without an issuer" "homelab.observability.grafanaOidc.provider is tsidp, which needs homelab.observability.grafanaOidc.issuer" broken.noIssuer
    ++ expect "the example servers' failed assertions" [ [ ] [ ] ] [ (failed tsidp) (failed pocketId) ];
in
if problems != [ ] then
  throw "OIDC sign in breaks docs/adr/0019-forgejo-and-grafana-on-pocket-id.md:\n${lib.concatStringsSep "\n" problems}"
else
  writeText "oidc-providers" "ok"
