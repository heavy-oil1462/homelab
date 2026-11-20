# Forgejo's and Grafana's OIDC sign in on Pocket ID, the only provider
# (docs/adr/0019-forgejo-and-grafana-on-pocket-id.md,
# docs/adr/0023-tsidp-retired-pocket-id-only.md), in the example server.
# Pure evaluation of the host configs:
#
# - the issuer is homelab.pocketId.url, the source "pocket-id" takes over
#   tsidp's former "tailscale" in place, users are named after
#   preferred_username, Grafana uses Pocket ID's endpoints, matches the
#   admins' emails and looks existing users up by email, and both clients
#   are declared in homelab.pocketId.clients, written before the services'
#   units, and Pocket ID's users cannot change their own email;
# - Forgejo links an existing account only with its password;
# - a host that still names the provider builds as one that does not;
# - OIDC without Pocket ID, or without the service's client, Grafana on a
#   Pocket ID whose users may edit their own accounts, and tsidp's removed
#   options fail the build with a clear message.
#
# It cannot sign anyone in: the forgejo-oidc check runs the script's
# update path, and the pocket-id-clients check runs against Pocket ID.
{ lib, writeText, pocketId, broken }:

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

  id = "https://id.home.example.com";

  problems =
    expect "pocket-id: Forgejo's USERNAME" "preferred_username" (forgejoEnv pocketId).FORGEJO__oauth2_client__USERNAME
    ++ expect "pocket-id: Forgejo's ACCOUNT_LINKING" "login" (forgejoEnv pocketId).FORGEJO__oauth2_client__ACCOUNT_LINKING
    ++ expect "pocket-id: forgejo-oidc's arguments, the former source names last"
      [ "pocket-id" "${id}" "/var/lib/secrets/forgejo-oidc-client-id" "/var/lib/secrets/forgejo-oidc-client-secret" "/var/lib/forgejo-oidc/applied" "tailscale" ]
      (args pocketId)
    ++ expectElem "pocket-id: forgejo-oidc runs after" "pocket-id-clients.service" (forgejoOidc pocketId).after
    ++ expect "pocket-id: Grafana's provider name" "Pocket ID" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_NAME
    ++ expect "pocket-id: Grafana's auth URL" "${id}/authorize" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_AUTH_URL
    ++ expect "pocket-id: Grafana's token URL" "${id}/api/oidc/token" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_TOKEN_URL
    ++ expect "pocket-id: Grafana's userinfo URL" "${id}/api/oidc/userinfo" (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_API_URL
    ++ expect "pocket-id: Grafana's email lookup" "true" (grafanaEnv pocketId).GF_AUTH_OAUTH_ALLOW_INSECURE_EMAIL_LOOKUP
    ++ expect "pocket-id: Grafana's role path"
      "contains(['alice@example.com'], email) && 'Admin'"
      (grafanaEnv pocketId).GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH
    ++ expect "pocket-id: Pocket ID's settings from the environment" true
      pocketId.services.pocket-id.settings.UI_CONFIG_DISABLED
    ++ expect "pocket-id: own-account editing" false
      pocketId.services.pocket-id.settings.ALLOW_OWN_ACCOUNT_EDIT
    ++ expectElem "pocket-id: Grafana starts after" "pocket-id-clients.service" pocketId.systemd.services.podman-grafana.after
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
    ++ expect "a host naming the provider: forgejo-oidc's arguments" (args pocketId) (args broken.providerNamed)
    ++ expect "a host naming the provider: Grafana's environment" (grafanaEnv pocketId) (grafanaEnv broken.providerNamed)
    ++ expectFailure "Forgejo on OIDC without Pocket ID" "homelab.forgejo.oidc signs in through Pocket ID, but homelab.pocketId is not enabled" broken.noPocketId
    ++ expectFailure "Grafana on OIDC without Pocket ID" "homelab.observability.grafanaOidc signs in through Pocket ID, but homelab.pocketId is not enabled" broken.noPocketId
    ++ expectFailure "Forgejo on Pocket ID without its client" "declare Forgejo's client in homelab.pocketId.clients" broken.noClients
    ++ expectFailure "Grafana on Pocket ID without its client" "declare Grafana's client in homelab.pocketId.clients" broken.noClients
    ++ expectFailure "Grafana on Pocket ID with own-account editing" "turn homelab.pocketId.allowOwnAccountEdit off" broken.ownEdit
    ++ expectFailure "Grafana on Pocket ID with own-account editing set directly" "turn homelab.pocketId.allowOwnAccountEdit off" broken.ownEditDirect
    ++ expect "Forgejo on Pocket ID with own-account editing" [ ]
      (lib.filter (lib.hasPrefix "homelab.forgejo") (failed broken.ownEdit))
    ++ expectFailure "tsidp's options" "`homelab.tsidp' in" broken.tsidp
    ++ expectFailure "Forgejo's issuer" "`homelab.forgejo.oidc.issuer' in" broken.tsidp
    ++ expectFailure "Grafana's issuer" "`homelab.observability.grafanaOidc.issuer' in" broken.tsidp
    ++ expectFailure "the removed options' message" "docs/adr/0023-tsidp-retired-pocket-id-only.md" broken.tsidp
    ++ expect "the example server's failed assertions" [ ] (failed pocketId)
    ++ expect "a host naming the provider: failed assertions" [ ] (failed broken.providerNamed);
in
if problems != [ ] then
  throw "OIDC sign in breaks docs/adr/0019-forgejo-and-grafana-on-pocket-id.md:\n${lib.concatStringsSep "\n" problems}"
else
  writeText "oidc-providers" "ok"
