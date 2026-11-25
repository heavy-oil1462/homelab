# The script behind modules/backups.nix's restic-restore-test unit, built on
# its own so the flake's checks can run it against a local repository.
# restic is not among its inputs: the unit puts the jobs' lock-waiting
# restic on PATH.
{ writeShellApplication, coreutils, findutils, gawk, git, jq, sqlite }:

writeShellApplication {
  name = "restic-restore-test";
  runtimeInputs = [ coreutils findutils gawk git jq sqlite ];
  text = builtins.readFile ./backup-restore-test.sh;
}
