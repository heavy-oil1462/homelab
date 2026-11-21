# The script behind modules/tailscale.nix's tailscale-metrics unit, built on
# its own so the flake's checks can run it against tailscale status samples.
# tailscale is not among its inputs: the unit puts the host's on PATH.
{ writeShellApplication, jq, coreutils }:

writeShellApplication {
  name = "tailscale-metrics";
  runtimeInputs = [ jq coreutils ];
  text = builtins.readFile ./tailscale-metrics.sh;
}
