# Runs modules/tailscale-metrics.sh against tailscale status --json:
#
# - logged out, from nixpkgs' tailscaled itself, in userspace networking
#   with its state in memory;
# - expiry set, expiry disabled, a zero expiry, an expiry with a zone
#   offset and an expired key: the logged out output with the fields
#   tailscaled fills in from the network map (ipn/ipnlocal/local.go,
#   updateStatusLocked and peerStatusFromNode, at tailscale 1.104.6);
# - tailscaled not answering;
#
# and its Tailnet Lock state from tailscale lock status --json, which the
# real daemon answers as off when logged out: on and signed, on and not
# signed, off before and after the node has seen it on, the output of a
# tailscaled from before the v1 schema, and a tailscale without the lock
# command or without .Enabled, which leave both series out and log once.
#
# Each file is checked with promtool and must leave no temporary file.
{ runCommand, callPackage, runtimeShell, tailscale, jq, prometheus }:

let
  script = callPackage ../modules/tailscale-metrics-script.nix { };
in
runCommand "tailscale-metrics-test" { nativeBuildInputs = [ jq prometheus.cli ]; } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  mkdir bin textfile state metrics-state
  export HOME=$PWD STUB=$PWD
  prom=textfile/homelab_tailscale.prom

  value() {
    awk -v series="$1" '$1 == series { print $2 }' "$prom"
  }
  run() {
    ${script}/bin/tailscale-metrics textfile metrics-state 2> run.err || { cat run.err; fail "$1: failed"; }
    promtool check metrics < "$prom" || fail "$1: not valid exposition format"
    [ -z "$(ls textfile | grep -v '\.prom$')" ] || fail "$1: temporary file left"
  }
  expect() {
    local name=$1 expiry=$2 disabled=$3 online=$4
    run "$name"
    [ "$(value homelab_tailscale_key_expiry_timestamp_seconds)" = "$expiry" ] \
      || fail "$name: expiry is '$(value homelab_tailscale_key_expiry_timestamp_seconds)', not '$expiry'"
    [ "$(value homelab_tailscale_key_expiry_disabled)" = "$disabled" ] || fail "$name: disabled is not $disabled"
    [ "$(value homelab_tailscale_online)" = "$online" ] || fail "$name: online is not $online"
  }
  # Empty for a series that must be left out.
  expect_lock() {
    local name=$1 enabled=$2 signed=$3
    run "$name"
    [ "$(value homelab_tailscale_lock_enabled)" = "$enabled" ] \
      || fail "$name: lock enabled is '$(value homelab_tailscale_lock_enabled)', not '$enabled'"
    [ "$(value homelab_tailscale_lock_node_signed)" = "$signed" ] \
      || fail "$name: node signed is '$(value homelab_tailscale_lock_node_signed)', not '$signed'"
    [ "$(value homelab_tailscale_online)" = 1 ] || fail "$name: online is not 1"
  }
  logs() {
    grep -q "gave no Tailnet Lock state" run.err
  }

  # Logged out: the real daemon, which never gets a key.
  ${tailscale}/bin/tailscaled --tun=userspace-networking --state=mem: \
    --socket="$PWD/tailscaled.sock" --statedir="$PWD/state" --port=0 \
    --no-logs-no-support > tailscaled.log 2>&1 &
  daemon=$!
  cat > bin/tailscale <<STUB
  #!${runtimeShell}
  exec ${tailscale}/bin/tailscale --socket="$PWD/tailscaled.sock" "\$@"
  STUB
  chmod +x bin/tailscale
  export PATH=$PWD/bin:$PATH
  for _ in $(seq 60); do
    tailscale status --json > logged-out.json 2> /dev/null && break
    sleep 0.5
  done
  [ "$(jq -r .BackendState logged-out.json)" = NeedsLogin ] \
    || { cat tailscaled.log; fail "tailscaled did not answer as logged out"; }
  tailscale lock status --json > lock-logged-out.json
  [ "$(jq -c . lock-logged-out.json)" = '{"SchemaVersion":"1","Enabled":false}' ] \
    || fail "tailscaled answered the lock status as $(cat lock-logged-out.json)"
  expect logged-out "" 0 0
  for series in homelab_tailscale_lock_enabled homelab_tailscale_lock_node_signed; do
    ! grep -q "^$series" "$prom" || fail "logged-out: a $series series before the lock was on"
  done
  kill "$daemon"
  if grep -q '^homelab_tailscale_key_expiry_timestamp_seconds' "$prom"; then
    fail "logged-out: an expiry series"
  fi

  # The other states: tailscale prints the sample in $STUB/status.json.
  # and lock status the one in $STUB/lock.json, failing as a tailscale
  # without the lock command does when there is none.
  cat > bin/tailscale <<'STUB'
  #!${runtimeShell}
  case "$*" in
    "status --json")
      [ -f "$STUB/status.json" ] || exit 1
      cat "$STUB/status.json" ;;
    "lock status --json")
      [ -f "$STUB/lock.json" ] || { echo "tailscale: unknown subcommand: lock" >&2; exit 1; }
      cat "$STUB/lock.json" ;;
    *) exit 64 ;;
  esac
  STUB
  sample() {
    jq "$1" logged-out.json > status.json
  }
  connected='.BackendState = "Running" | .Self += {
    ID: "nEXAMPLE1CNTRL", NodeID: 1, HostName: "server1",
    DNSName: "server1.tailnet.invalid.", TailscaleIPs: ["100.64.0.1"],
    InNetworkMap: true, Online: true }'

  # 2027-05-20T08:30:00Z
  sample "$connected | .Self.KeyExpiry = \"2027-05-20T08:30:00Z\""
  expect expiry-set 1810801800 0 1
  # lock.json is not there yet: the lock command is missing.
  logs || fail "expiry-set: says nothing of the missing lock command"

  sample "$connected"
  expect expiry-disabled "" 1 1

  sample "$connected | .Self.KeyExpiry = \"0001-01-01T00:00:00Z\""
  expect expiry-zero "" 1 1

  sample "$connected | .Self.KeyExpiry = \"2027-05-20T10:30:00+02:00\""
  expect expiry-offset 1810801800 0 1

  # An expired key: tailscaled keeps the network map, needs a login and is
  # no longer in the control plane's poll.
  sample "$connected | .BackendState = \"NeedsLogin\"
    | .Self += {Online: false, Expired: true, KeyExpiry: \"2026-11-01T00:00:00Z\"}"
  expect expired 1793491200 0 0

  # Running but not connected to the control plane.
  sample "$connected | .Self.Online = false | .Self.KeyExpiry = \"2027-05-20T08:30:00Z\""
  expect not-polling 1810801800 0 0

  # Tailnet Lock, on a connected node. Without the lock command: nothing
  # written, and not said again, as expiry-set said it.
  sample "$connected"
  expect_lock lock-missing "" ""
  ! logs || fail "lock-missing: says it again"

  # Off on a node that has never seen it on: the tailnet has no lock yet.
  cp lock-logged-out.json lock.json
  expect_lock lock-not-set-up "" ""

  # On, with this node signed by a trusted key: the fields tailscaled adds
  # once the lock is on (tslockjsonv1.StatusResponse at 1.104.6).
  on='.Enabled = true | . += {
    PublicKey: "tlpub:0000000000000000000000000000000000000000000000000000000000000001",
    NodeKey: "nodekey:0000000000000000000000000000000000000000000000000000000000000002",
    Head: "EXAMPLEHEAD", TrustedKeys: [], VisiblePeers: [], FilteredPeers: [] }'
  jq "$on | .NodeKeySigned = true" lock-logged-out.json > lock.json
  expect_lock lock-signed 1 1

  jq "$on | .NodeKeySigned = false" lock-logged-out.json > lock.json
  expect_lock lock-not-signed 1 0

  # Off once it has been on: someone disabled it.
  cp lock-logged-out.json lock.json
  expect_lock lock-turned-off 0 ""

  # A tailscaled from before the v1 schema printed ipnstate's
  # NetworkLockStatus, with both fields always there.
  echo '{"Enabled": true, "NodeKeySigned": true, "PublicKey": "tlpub:01", "TrustedKeys": null}' > lock.json
  expect_lock lock-old-schema 1 1

  # An answer without .Enabled, and the command gone again: nothing
  # written, said once.
  echo '{"SchemaVersion": "2"}' > lock.json
  expect_lock lock-no-field "" ""
  logs || fail "lock-no-field: says nothing"
  rm lock.json
  expect_lock lock-missing-later "" ""
  ! logs || fail "lock-missing-later: says it again"

  rm status.json
  expect no-daemon "" 0 0
  grep -q "writing the node as offline" run.err || fail "no-daemon: says nothing"
  [ -z "$(ls metrics-state | grep -v '^lock-\(seen\|unknown\)$')" ] || fail "state: a stray file"

  touch $out
''
