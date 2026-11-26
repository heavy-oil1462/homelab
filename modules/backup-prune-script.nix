# The script behind modules/backups.nix's restic-prune unit, built on its own
# so the flake's checks can run it against a local repository. restic is not
# among its inputs: the unit puts the jobs' lock-waiting restic on PATH.
{ writeShellApplication, gawk }:

writeShellApplication {
  name = "restic-prune";
  runtimeInputs = [ gawk ];
  text = builtins.readFile ./backup-prune.sh;
}
