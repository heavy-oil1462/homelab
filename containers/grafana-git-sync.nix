# The script behind containers/observability.nix's grafana-git-sync unit,
# built on its own so the flake's checks can run it against a stubbed
# podman and a stand-in for Grafana. podman is not among its inputs: the
# unit puts the host's on PATH.
{ writeShellApplication, coreutils, curl, jq }:

writeShellApplication {
  name = "grafana-git-sync";
  runtimeInputs = [ coreutils curl jq ];
  text = builtins.readFile ./grafana-git-sync.sh;
}
