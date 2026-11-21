# Runs modules/tailscale-metrics.sh against tailscale status --json:
#
# - logged out, from nixpkgs' tailscaled itself, in userspace networking
#   with its state in memory;
# - expiry set, expiry disabled, a zero expiry, an expiry with a zone
#   offset and an expired key: the logged out output with the fields
#   tailscaled fills in from the network map (ipn/ipnlocal/local.go,
#   updateStatusLocked and peerStatusFromNode, at tailscale 1.104.6);
# - tailscaled not answering.
#
# Each file is checked with promtool and must leave no temporary file.
{ runCommand, callPackage, runtimeShell, tailscale, jq, prometheus }:

let
  script = callPackage ../modules/tailscale-metrics-script.nix { };
in
runCommand "tailscale-metrics-test" { nativeBuildInputs = [ jq prometheus.cli ]; } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  mkdir bin textfile state
  export HOME=$PWD STUB=$PWD
  prom=textfile/homelab_tailscale.prom

  value() {
    awk -v series="$1" '$1 == series { print $2 }' "$prom"
  }
  run() {
    ${script}/bin/tailscale-metrics textfile 2> run.err || { cat run.err; fail "$1: failed"; }
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
  expect logged-out "" 0 0
  kill "$daemon"
  if grep -q '^homelab_tailscale_key_expiry_timestamp_seconds' "$prom"; then
    fail "logged-out: an expiry series"
  fi

  # The other states: tailscale prints the sample in $STUB/status.json.
  cat > bin/tailscale <<'STUB'
  #!${runtimeShell}
  [ "$*" = "status --json" ] || exit 64
  [ -f "$STUB/status.json" ] || exit 1
  cat "$STUB/status.json"
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

  rm status.json
  expect no-daemon "" 0 0
  grep -q "writing the node as offline" run.err || fail "no-daemon: says nothing"

  touch $out
''
