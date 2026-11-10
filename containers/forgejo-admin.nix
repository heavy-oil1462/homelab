# The script behind containers/forgejo.nix's forgejo-admin unit, built on
# its own so the flake's checks can run it against a stubbed podman. podman
# is not among its inputs: the unit puts the host's podman on PATH.
{ writeShellApplication, coreutils, gnugrep, gnused }:

writeShellApplication {
  name = "forgejo-admin";
  runtimeInputs = [ coreutils gnugrep gnused ];
  text = builtins.readFile ./forgejo-admin.sh;
}
