# Checks the NVIDIA container toolkit's CDI spec before a GPU container
# starts, and writes it again with this system's generator when it is stale
# (docs/nvidia.md, docs/adr/0013-gpu-containers-check-the-cdi-spec.md).
#
#   nvidia-cdi-check UNIT SPEC DRIVER GENERATOR
#
# UNIT names the unit in the log lines, SPEC is the spec's path
# (/run/cdi/nvidia-container-toolkit.json), DRIVER the driver's library
# store path and GENERATOR the ExecStart of
# nvidia-container-toolkit-cdi-generator. Exits 0 when the spec is right,
# as found or once written again, and 1 when it is still wrong after that.

unit=$1 spec=$2 driver=$3 generator=$4

# Prints why the spec is stale and succeeds, or fails when it is right: it
# must mount this system's driver, and every path it names (mounts and
# hooks) must exist, since a spec from an older system can name paths the
# garbage collector has deleted since.
stale() {
  if [ ! -s "$spec" ]; then
    echo "no CDI spec at $spec"
    return 0
  fi
  if ! jq -e --arg d "$driver" 'any(.. | objects | .hostPath?; . == $d)' "$spec" >/dev/null 2>&1; then
    echo "the CDI spec does not mount this system's driver, $driver"
    return 0
  fi
  gone=$(jq -r '.. | objects | (.hostPath? // empty), (select(has("hookName")) | .path)' "$spec" |
    while IFS= read -r p; do [ -e "$p" ] || printf ' %s' "$p"; done)
  if [ -n "$gone" ]; then
    echo "the CDI spec names paths that are gone:$gone"
    return 0
  fi
  return 1
}

why=$(stale) || exit 0
echo "$unit: $why; writing it again" >&2
dir=$(dirname "$spec")
mkdir -p "$dir"
# The generator writes into its RuntimeDirectory. It is run directly:
# restarting its unit from here would restart this unit too, which
# requires it.
RUNTIME_DIRECTORY=$dir "$generator"
if why=$(stale); then
  echo "$unit: $why, even after writing it again" >&2
  exit 1
fi
