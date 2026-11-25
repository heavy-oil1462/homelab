# The script behind modules/backups.nix's restic-check unit, built on its own
# so the flake's checks can run it against a local repository. restic is not
# among its inputs: the unit puts the jobs' lock-waiting restic on PATH.
{ writeShellApplication, gawk }:

writeShellApplication {
  name = "restic-check";
  runtimeInputs = [ gawk ];
  text = builtins.readFile ./backup-check.sh;
}
