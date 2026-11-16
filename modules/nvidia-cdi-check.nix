# The script behind homelab.nvidia.cdiCheck, built on its own so the flake's
# checks can run it against stub specs.
{ writeShellApplication, coreutils, jq }:

writeShellApplication {
  name = "nvidia-cdi-check";
  runtimeInputs = [ coreutils jq ];
  text = builtins.readFile ./nvidia-cdi-check.sh;
}
