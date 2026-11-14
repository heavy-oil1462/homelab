# The script behind containers/forgejo.nix's forgejo-oidc unit, built on its
# own so the flake's checks can run it against a stubbed podman and
# systemctl. Neither is among its inputs: the unit puts the host's on PATH.
{ writeShellApplication, coreutils, gawk }:

writeShellApplication {
  name = "forgejo-oidc";
  runtimeInputs = [ coreutils gawk ];
  text = builtins.readFile ./forgejo-oidc.sh;
}
