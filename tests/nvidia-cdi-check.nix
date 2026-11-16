# Runs modules/nvidia-cdi-check.sh against stub CDI specs and a stub
# generator: a current spec, none at all, a spec for another driver, a spec
# naming a deleted path, and a generator that cannot fix it. Then checks
# that the example server runs it first before Frigate starts, with its own
# driver and generator.
{ runCommand, callPackage, runtimeShell, lib, firstExecStartPre, requires, driver, generator }:

let
  script = callPackage ../modules/nvidia-cdi-check.nix { };
in
runCommand "nvidia-cdi-check-test" { } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  root=$PWD
  mkdir driver old-driver
  touch hook
  spec=$root/cdi/nvidia-container-toolkit.json

  # A spec like nvidia-ctk's: a hook, and a mount of the driver in $1.
  stub() {
    cat <<JSON
  {"cdiVersion": "0.5.0", "kind": "nvidia.com/gpu",
   "devices": [{"name": "all", "containerEdits": {"deviceNodes": [{"path": "/dev/null"}]}}],
   "containerEdits": {
     "hooks": [{"hookName": "createContainer", "path": "$root/hook", "args": ["nvidia-cdi-hook", "update-ldcache"]}],
     "mounts": [{"hostPath": "$1", "containerPath": "$1", "options": ["ro", "nosuid", "nodev", "bind"]}]}}
  JSON
  }
  write() { mkdir -p cdi; stub "$1" > "$spec"; }

  # The stub generator writes a spec for this system's driver into its
  # RuntimeDirectory and counts its runs.
  stub "$root/driver" > fresh.json
  cat > generator <<STUB
  #!${runtimeShell}
  echo run >> $root/runs
  cp $root/fresh.json "\$RUNTIME_DIRECTORY/nvidia-container-toolkit.json"
  STUB
  chmod +x generator

  check() {
    rm -f runs
    status=0
    ${lib.getExe script} podman-test "$spec" "$root/driver" "$root/generator" 2> err || status=$?
    runs=0
    if [ -e runs ]; then runs=$(wc -l < runs); fi
  }

  # A current spec is left alone, silently.
  write "$root/driver"
  check
  [ "$status" = 0 ] || fail "current: exit $status: $(cat err)"
  [ "$runs" = 0 ] || fail "current: generator ran"
  [ ! -s err ] || fail "current: said $(cat err)"

  # No spec: written.
  rm -r cdi
  check
  [ "$status" = 0 ] || fail "missing: exit $status: $(cat err)"
  [ "$runs" = 1 ] || fail "missing: generator ran $runs times"
  grep -q "podman-test: no CDI spec" err || fail "missing: said $(cat err)"
  grep -q "$root/driver" "$spec" || fail "missing: not written"

  # A spec for another driver, still in the store, while /run/opengl-driver
  # leads to this one (2026-11-16): written again.
  write "$root/old-driver"
  check
  [ "$status" = 0 ] || fail "other driver: exit $status: $(cat err)"
  [ "$runs" = 1 ] || fail "other driver: generator ran $runs times"
  grep -q "does not mount this system's driver, $root/driver" err || fail "other driver: said $(cat err)"
  grep -q "\"$root/driver\"" "$spec" || fail "other driver: not written again"

  # An empty spec, as a write cut short leaves it: written again.
  : > "$spec"
  check
  [ "$status" = 0 ] && [ "$runs" = 1 ] || fail "empty: exit $status, $runs runs"

  # A spec naming a deleted path: written again. The stub writes the same
  # hook path, still gone, so the start fails and Restart= tries again.
  write "$root/driver"
  rm hook
  check
  [ "$status" = 1 ] || fail "deleted: exit $status"
  [ "$runs" = 1 ] || fail "deleted: generator ran $runs times"
  grep -q "names paths that are gone: $root/hook; writing it again" err || fail "deleted: said $(cat err)"
  grep -q "even after writing it again" err || fail "deleted: said $(cat err)"

  # The example server: the check is Frigate's first ExecStartPre, with
  # its driver and generator, and Frigate requires the generator.
  first=${lib.escapeShellArg firstExecStartPre}
  case "$first" in
    ${lib.getExe script}" "*) ;;
    *) fail "example: first ExecStartPre is $first" ;;
  esac
  for word in podman-frigate /run/cdi/nvidia-container-toolkit.json ${driver} ${generator}; do
    case " $first " in *" $word "*) ;; *) fail "example: $word missing from $first" ;; esac
  done
  case "${toString requires}" in
    *nvidia-container-toolkit-cdi-generator.service*) ;;
    *) fail "example: Frigate does not require the generator" ;;
  esac

  touch $out
''
