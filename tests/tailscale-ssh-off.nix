# Servers take SSH through sshd only
# (docs/adr/0026-servers-ssh-through-sshd-only.md).
#
# Evaluation of the example hosts:
#
# - server: no --ssh at tailscale up, and the tailscale-ssh-off unit, of
#   Type exec so a switch does not wait for it, wanted by multi-user.target
#   and waiting 10 minutes with no session, polling every 15 seconds;
# - workstation: --ssh as before, and no tailscale-ssh-off;
# - server with homelab.tailscale.ssh on: --ssh, and no tailscale-ssh-off;
# - a server with Tailscale SSH off and sshd off, on loopback only, or with
#   its port closed on tailscale0 fails the build.
#
# Then modules/tailscale-ssh-off.sh runs against nixpkgs' tailscaled,
# logged out, in userspace networking with its state in memory: with
# RunSSH on it turns it off. And against a stub that plays tailscaled's
# counters: already off, idle, a session open, a new connection, and the
# session gauge gone. It cannot open a Tailscale SSH session: that needs a
# tailnet, and was tested by hand.
{ lib, runCommand, callPackage, runtimeShell, tailscale, jq, server, workstation, serverSsh, broken }:

let
  script = callPackage ../modules/tailscale-ssh-off-script.nix { };
  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  unit = cfg: cfg.systemd.services.tailscale-ssh-off or null;

  expect = what: want: have:
    lib.optional (want != have) "${what}: expected ${builtins.toJSON want}, got ${builtins.toJSON have}";
  expectFailure = what: cfg:
    lib.optional (!(lib.any (lib.hasInfix "homelab.tailscale.ssh is off") (failed cfg)))
      "${what}: no failed assertion about sshd, got ${builtins.toJSON (failed cfg)}";

  serverUnit = unit server;
  problems =
    expect "server: homelab.tailscale.ssh" false server.homelab.tailscale.ssh
    ++ expect "server: tailscale up flags" [ ] server.services.tailscale.extraUpFlags
    ++ expect "server: has tailscale-ssh-off" true (serverUnit != null)
    ++ lib.optionals (serverUnit != null) (
      expect "server: tailscale-ssh-off's Type" "exec" serverUnit.serviceConfig.Type
      ++ expect "server: tailscale-ssh-off wanted by" [ "multi-user.target" ] serverUnit.wantedBy
      ++ expect "server: tailscale-ssh-off's poll and quiet time" true
        (lib.hasSuffix "/bin/tailscale-ssh-off 15 600" serverUnit.serviceConfig.ExecStart))
    ++ expect "server: failed assertions" [ ] (failed server)
    ++ expect "workstation: homelab.tailscale.ssh" true workstation.homelab.tailscale.ssh
    ++ expect "workstation: tailscale up flags" [ "--ssh" ] workstation.services.tailscale.extraUpFlags
    ++ expect "workstation: has tailscale-ssh-off" false (unit workstation != null)
    ++ expect "serverSsh: tailscale up flags" [ "--ssh" ] serverSsh.services.tailscale.extraUpFlags
    ++ expect "serverSsh: has tailscale-ssh-off" false (unit serverSsh != null)
    ++ expect "serverSsh: failed assertions" [ ] (failed serverSsh)
    ++ expectFailure "noSshd" broken.noSshd
    ++ expectFailure "loopbackOnly" broken.loopbackOnly
    ++ expectFailure "closedOnTailnet" broken.closedOnTailnet;
in
if problems != [ ] then
  throw "Tailscale SSH on servers breaks docs/adr/0026-servers-ssh-through-sshd-only.md:\n${lib.concatStringsSep "\n" problems}"
else
  runCommand "tailscale-ssh-off-test" { nativeBuildInputs = [ jq ]; } ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    mkdir bin state
    export HOME=$PWD STUB=$PWD
    export PATH=$PWD/bin:$PATH
    off=${script}/bin/tailscale-ssh-off

    # The real daemon, logged out: RunSSH on, then turned off after a
    # second with no session.
    ${tailscale}/bin/tailscaled --tun=userspace-networking --state=mem: \
      --socket="$PWD/tailscaled.sock" --statedir="$PWD/state" --port=0 \
      --no-logs-no-support > tailscaled.log 2>&1 &
    daemon=$!
    cat > bin/tailscale <<STUB
    #!${runtimeShell}
    exec ${tailscale}/bin/tailscale --socket="$PWD/tailscaled.sock" "\$@"
    STUB
    chmod +x bin/tailscale
    for _ in $(seq 60); do
      tailscale set --ssh 2> /dev/null && break
      sleep 0.5
    done
    [ "$(tailscale debug prefs | jq .RunSSH)" = true ] \
      || { cat tailscaled.log; fail "tailscaled: RunSSH did not go on"; }
    tailscale debug metrics | grep -q '^ssh_active_sessions 0$' \
      || fail "tailscaled: no ssh_active_sessions 0 in its metrics"
    $off 1 1 > run.out || fail "tailscaled: failed"
    [ "$(tailscale debug prefs | jq .RunSSH)" = false ] || fail "tailscaled: RunSSH still on"
    $off 1 1 > run.out || fail "tailscaled, off: failed"
    grep -q "^Tailscale SSH is off$" run.out || fail "tailscaled, off: says nothing"
    kill "$daemon"

    # The stub: RunSSH from $STUB/runssh. Each `debug metrics` takes the
    # first line of $STUB/polls, "<sessions> <connections>", and drops it
    # unless it is the last; "none" leaves the session gauge out. Every
    # call is logged in $STUB/calls.
    cat > bin/tailscale <<'STUB'
    #!${runtimeShell}
    echo "$*" >> "$STUB/calls"
    case "$*" in
      "debug prefs") echo "{\"RunSSH\": $(cat "$STUB/runssh")}" ;;
      "debug metrics")
        read -r sessions accepted < "$STUB/polls"
        [ "$(wc -l < "$STUB/polls")" -le 1 ] || sed -i 1d "$STUB/polls"
        echo "# TYPE ssh_incoming_connections counter"
        echo "ssh_incoming_connections ''${accepted:-0}"
        if [ "$sessions" != none ]; then
          echo "# TYPE ssh_active_sessions gauge"
          echo "ssh_active_sessions $sessions"
        fi ;;
      "set --ssh=false") echo false > "$STUB/runssh" ;;
      *) exit 64 ;;
    esac
    STUB
    chmod +x bin/tailscale
    polls() { grep -c "^debug metrics$" calls || true; }
    sets() { grep -c "^set --ssh=false$" calls || true; }
    # case <name> <RunSSH> <expected exit> <expected polls> <expected sets> <polls...>
    case_() {
      local name=$1 runssh=$2 rc=$3 want_polls=$4 want_sets=$5 status=0
      shift 5
      echo "$runssh" > runssh
      printf '%s\n' "$@" > polls
      : > calls
      $off 1 2 > run.out 2> run.err || status=$?
      [ "$status" = "$rc" ] || { cat run.out run.err; fail "$name: exit $status, not $rc"; }
      [ "$(polls)" = "$want_polls" ] || fail "$name: $(polls) polls, not $want_polls"
      [ "$(sets)" = "$want_sets" ] || fail "$name: $(sets) sets, not $want_sets"
    }

    # Already off: nothing polled or set.
    case_ already-off false 0 0 0 "0 0"
    # Idle: the first poll is the baseline, then two quiet seconds.
    case_ idle true 0 3 1 "0 5"
    [ "$(cat runssh)" = false ] || fail "idle: RunSSH still on"
    # A session open for three polls: two quiet seconds after it closes.
    case_ session true 0 5 1 "1 5" "1 5" "1 5" "0 5"
    # A connection accepted between polls starts the quiet time again.
    case_ new-connection true 0 5 1 "0 1" "0 1" "0 2"
    # No session gauge: fails and leaves Tailscale SSH on.
    case_ no-gauge true 1 1 0 "none 0"
    grep -q "leaving Tailscale SSH on" run.err || fail "no-gauge: says nothing"

    touch $out
  ''
