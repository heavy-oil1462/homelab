# The script behind containers/observability.nix's grafana-git-sync unit,
# built on its own so the flake's checks can run it against a stubbed
# podman and a stand-in for Grafana. podman is not among its inputs: the
# unit puts the host's on PATH.
{ writeShellApplication, writeShellScript, coreutils, curl, findutils, git, gnugrep, jq }:

let
  # git asks this for the user and the token when seeding, so the token
  # goes from its file to git's stdin, never into argv, the URL or the
  # environment.
  askpass = writeShellScript "grafana-git-sync-askpass" ''
    case "$1" in
      Username*) printf '%s\n' "$GRAFANA_GIT_SYNC_USER" ;;
      *) cat "$GRAFANA_GIT_SYNC_TOKEN_FILE" ;;
    esac
  '';
in
writeShellApplication {
  name = "grafana-git-sync";
  runtimeInputs = [ coreutils curl findutils git gnugrep jq ];
  runtimeEnv.GRAFANA_GIT_SYNC_ASKPASS = askpass;
  text = builtins.readFile ./grafana-git-sync.sh;
}
