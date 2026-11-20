# The tool behind containers/homeassistant.nix's reverse proxy settings, run
# before Home Assistant starts, built on its own so the flake's checks can
# run it against nixpkgs' Home Assistant.
{ writers }:

writers.writePython3Bin "homeassistant-http" {
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./homeassistant-http.py)
