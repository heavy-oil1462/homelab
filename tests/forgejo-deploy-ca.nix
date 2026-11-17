# Forgejo's built in SSH server trusts the deploy CA only with
# homelab.forgejo.trustDeployCa (docs/adr/0015-forgejo-trusts-the-deploy-ca.md).
# Pure evaluation of two host configs:
#
# - on: the forgejo container's environment carries every key of
#   homelab.deployCaKeys as SSH_TRUSTED_USER_CA_KEYS, and principals may only
#   be a user's own name;
# - off: it trusts no CA and allows no principals. The image keeps settings
#   in app.ini after their variable goes away, so the off state is stated
#   rather than left out.
#
# It cannot sign in with a certificate: that needs the Forgejo image running,
# which the checks do not start.
{ lib, writeText, on, off }:

let
  env = config: config.virtualisation.oci-containers.containers.forgejo.environment;
  caKeys = config: (env config).FORGEJO__server__SSH_TRUSTED_USER_CA_KEYS or null;
  allow = config: (env config).FORGEJO__server__SSH_AUTHORIZED_PRINCIPALS_ALLOW or null;

  problems =
    lib.optional (!on.homelab.forgejo.trustDeployCa) "on: homelab.forgejo.trustDeployCa is off"
    ++ lib.optional (on.homelab.deployCaKeys == [ ]) "on: homelab.deployCaKeys is empty"
    ++ lib.optional (caKeys on != lib.concatStringsSep "," on.homelab.deployCaKeys)
      "on: SSH_TRUSTED_USER_CA_KEYS is ${builtins.toJSON (caKeys on)}, not homelab.deployCaKeys joined with commas"
    ++ lib.optional (allow on != "username")
      "on: SSH_AUTHORIZED_PRINCIPALS_ALLOW is ${builtins.toJSON (allow on)}, not \"username\""
    ++ lib.optional off.homelab.forgejo.trustDeployCa "off: homelab.forgejo.trustDeployCa is on"
    ++ lib.optional (caKeys off != "")
      "off: SSH_TRUSTED_USER_CA_KEYS is ${builtins.toJSON (caKeys off)}, not empty"
    ++ lib.optional (allow off != "off")
      "off: SSH_AUTHORIZED_PRINCIPALS_ALLOW is ${builtins.toJSON (allow off)}, not \"off\"";
in
if problems == [ ] then
  writeText "forgejo-deploy-ca" (caKeys on + "\n")
else
  throw "Forgejo's deploy CA settings break docs/adr/0015-forgejo-trusts-the-deploy-ca.md:\n${lib.concatStringsSep "\n" problems}"
