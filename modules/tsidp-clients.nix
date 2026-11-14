# The script behind modules/tsidp.nix's declared clients, run before tsidp
# starts, built on its own so the flake's checks can run it against a fake
# state directory.
{ writeShellApplication, coreutils, jq }:

writeShellApplication {
  name = "tsidp-clients";
  runtimeInputs = [ coreutils jq ];
  text = builtins.readFile ./tsidp-clients.sh;
}
