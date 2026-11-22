# The script behind modules/tailscale.nix's tailscale-ssh-off unit, built on
# its own so the flake's checks can run it against tailscaled and a stub.
# tailscale is not among its inputs: the unit puts the host's on PATH.
{ writeShellApplication, jq, coreutils, gawk }:

writeShellApplication {
  name = "tailscale-ssh-off";
  runtimeInputs = [ jq coreutils gawk ];
  text = builtins.readFile ./tailscale-ssh-off.sh;
}
