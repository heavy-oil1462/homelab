# The script behind modules/pocket-id.nix's declared clients, built on its
# own so the flake's checks can run it against nixpkgs' Pocket ID and a
# stubbed systemctl. systemctl is not among its inputs: the unit puts the
# host's on PATH.
{ writeShellApplication, coreutils, curl, gnused, jq }:

writeShellApplication {
  name = "pocket-id-clients";
  runtimeInputs = [ coreutils curl gnused jq ];
  text = builtins.readFile ./pocket-id-clients.sh;
}
