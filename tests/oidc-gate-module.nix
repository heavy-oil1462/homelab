# The example server's OIDC login gate, as evaluated
# (docs/adr/0020-oidc-login-gate-at-the-proxy.md):
#
# - oauth2-proxy signs in at Pocket ID with PKCE, takes the user name as
#   the email, serves only on its socket, and keeps the cookie Secure on
#   homelab.domain and its subdomains;
# - it runs as its own user without capabilities, after the unit that
#   makes its cookie secret and after pocket-id-clients, and gets both
#   secrets as credentials;
# - the socket's directory is the caddy group's and mounted into Caddy;
# - the host refuses a Caddyfile importing the snippets with the gate off,
#   the gate on Pocket ID without its client or with users allowed to
#   change their own username, and a session shorter than its renewal.
#
# The sign-in itself is tests/oidc-gate.nix.
{ lib, writeText, config, withoutGate, withoutClient, ownAccountEdit, shortSession }:

let
  gate = config.homelab.reverseProxy.oidcGate;
  socketDir = dirOf gate.socket;
  service = config.systemd.services.oauth2-proxy;
  command = service.serviceConfig.ExecStart;
  caddy = config.virtualisation.oci-containers.containers.caddy;
  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  refuses = cfg: text: lib.any (lib.hasInfix text) (failed cfg);

  flags = [
    "--provider='oidc'"
    "--oidc-issuer-url='https://id.home.example.com'"
    "--client-id='oidc-gate'"
    "--client-secret-file='%d/client-secret'"
    "--cookie-secret-file='%d/cookie-secret'"
    "--code-challenge-method='S256'"
    "--oidc-email-claim='preferred_username'"
    "--http-address='unix:///run/oidc-gate/oauth2-proxy.sock,mode=0666'"
    "--cookie-domain='.home.example.com'"
    "--cookie-secure=true"
    "--cookie-expire='24h'"
    "--cookie-refresh='30m'"
    "--reverse-proxy=false"
    "--upstream='static://202'"
  ];

  problems =
    lib.optional (failed config != [ ]) "the example fails: ${toString (failed config)}"
    ++ lib.concatMap (f: lib.optional (!lib.hasInfix " ${f}" command) "oauth2-proxy is not run with ${f}") flags
    ++ lib.optional (lib.hasInfix "--http-address='http" command) "oauth2-proxy listens on a port"
    ++ lib.optional (service.serviceConfig.User != "oauth2-proxy") "oauth2-proxy runs as ${service.serviceConfig.User}"
    ++ lib.optional ((service.serviceConfig.CapabilityBoundingSet or null) != "") "oauth2-proxy keeps capabilities"
    ++ lib.optional (!(service.serviceConfig.NoNewPrivileges or false)) "oauth2-proxy may gain privileges"
    ++ lib.optional (service.serviceConfig.LoadCredential != [
      "client-secret:${gate.clientSecretFile}"
      "cookie-secret:${gate.cookieSecretFile}"
    ]) "oauth2-proxy's credentials are ${toString service.serviceConfig.LoadCredential}"
    ++ lib.optional (!(lib.elem "oidc-gate-cookie-secret.service" service.requires
      && lib.elem "oidc-gate-cookie-secret.service" service.after))
      "oauth2-proxy does not start after its cookie secret is made"
    ++ lib.optional (!(lib.hasInfix gate.cookieSecretFile config.systemd.services.oidc-gate-cookie-secret.serviceConfig.ExecStart))
      "the cookie secret is not made at ${gate.cookieSecretFile}"
    ++ lib.optional (!(lib.elem "oauth2-proxy.service" config.systemd.services.pocket-id-clients.before))
      "oauth2-proxy does not start after pocket-id-clients"
    ++ lib.optional (!(lib.elem socketDir service.serviceConfig.ReadWritePaths)) "oauth2-proxy cannot write ${socketDir}"
    ++ lib.optional (!(lib.elem "d ${socketDir} 0750 oauth2-proxy caddy - -" config.systemd.tmpfiles.rules))
      "no tmpfiles rule makes ${socketDir} the caddy group's, mode 0750"
    ++ lib.optional (!(lib.elem "${socketDir}:${socketDir}" caddy.volumes)) "the caddy container does not mount ${socketDir}"
    ++ lib.optional (!refuses withoutGate "imports oidc_gate or oidc_owner_only")
      "a Caddyfile importing the snippets is taken with the gate off"
    ++ lib.optional (!refuses withoutClient "homelab.pocketId.clients.oidc-gate")
      "the gate is taken without its Pocket ID client"
    ++ lib.optional (!refuses ownAccountEdit "lets users through by their Pocket ID username")
      "the gate is taken with users allowed to rename themselves"
    ++ lib.optional (!refuses shortSession "sessionLifetime")
      "a session shorter than its renewal is taken";
in
if problems != [ ] then
  throw "The OIDC gate breaks docs/adr/0020-oidc-login-gate-at-the-proxy.md:\n${lib.concatStringsSep "\n" problems}"
else
  writeText "oidc-gate-module" "ok"
