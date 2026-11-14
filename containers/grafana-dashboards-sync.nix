# The script behind containers/observability.nix's grafana-dashboards-sync
# unit, built on its own so the flake's checks can run it against a local
# repository.
{ writeShellApplication, coreutils, findutils, git, gnutar, jq, openssh, rsync }:

writeShellApplication {
  name = "grafana-dashboards-sync";
  runtimeInputs = [ coreutils findutils git gnutar jq openssh rsync ];
  text = builtins.readFile ./grafana-dashboards-sync.sh;
}
