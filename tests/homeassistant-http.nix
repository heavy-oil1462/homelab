# Home Assistant's reverse proxy settings, written by the homeassistant
# module into .storage/http
# (docs/adr/0022-home-assistant-http-settings-after-the-yaml.md):
#
# - the example server runs modules/homeassistant-http.py before the
#   container, wanted by it, with the trusted proxies of
#   homelab.homeassistant.trustedProxies, and a configuration.yaml with an
#   http: block fails the build;
# - against nixpkgs' Home Assistant, started on a temporary config
#   directory: with no store yet, the file the tool writes is taken over as
#   the stable config, with no trial pending, and the trusted proxy's
#   X-Forwarded-For is used while another address gets 400;
# - after settings were changed in Home Assistant's network settings (the
#   port and CORS origins in the stable slot, a trial in the pending slot),
#   other trusted proxies replace the old ones in both slots, everything
#   else stays, and Home Assistant applies the result;
# - an empty list turns X-Forwarded-For off, a run with nothing to do
#   leaves the file alone, and an unknown store version or a wrong network
#   fails and leaves the file alone.
#
# The image's Home Assistant is pinned on its own; this runs the one of
# flake.lock's nixpkgs, which must be on the same storage version. Home
# Assistant is killed at the end, so nothing holds the build's output open,
# and every wait has a deadline.
{ lib, runCommand, callPackage, writeText, python3, jq, curl, home-assistant, config, withYamlHttp }:

let
  tool = "${callPackage ../modules/homeassistant-http.nix { }}/bin/homeassistant-http";
  text = builtins.unsafeDiscardStringContext;
  unit = config.systemd.services.home-assistant-http;
  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  problems =
    lib.optional (!(lib.elem "podman-home-assistant.service" unit.wantedBy)) "the unit is not wanted by the container"
    ++ lib.optional (!(lib.elem "podman-home-assistant.service" unit.before)) "the unit does not run before the container"
    ++ lib.optional (!(lib.hasInfix "/bin/homeassistant-http \"$dir/.storage/http\"" (text unit.script))) "the unit does not run the tool on the volume's store"
    ++ lib.optional (config.homelab.homeassistant.trustedProxies != [ "${config.homelab.reverseProxy.address}/32" ]) "the example does not trust the reverse proxy"
    ++ lib.optional (!(lib.any (lib.hasInfix "remove the http: block") (failed withYamlHttp))) "an http: block in configuration.yaml passes";

  settings = proxies: writeText "settings.json" (builtins.toJSON {
    use_x_forwarded_for = proxies != [ ];
    trusted_proxies = proxies;
  });
in
if problems != [ ] then throw "homeassistant-http: ${lib.concatStringsSep "; " problems}" else
runCommand "homeassistant-http-test" { nativeBuildInputs = [ python3 jq curl ]; } ''
  set -euo pipefail
  mkdir -p config/.storage
  store=config/.storage/http
  printf 'homeassistant:\napi:\n' > config/configuration.yaml
  pid=
  fail() {
    echo "FAIL: $*" >&2
    tail -n 20 ha.log >&2 || true
    [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
    exit 1
  }

  # start <port>: Home Assistant on the config directory, until its API
  # answers on the port.
  start() {
    ${lib.getExe' home-assistant "hass"} -c config --skip-pip > ha.log 2>&1 &
    pid=$!
    for _ in $(seq 600); do
      [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/api/" || true)" = 401 ] && break
      kill -0 "$pid" 2> /dev/null || fail "Home Assistant exited"
      sleep 0.1
    done
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/api/" || true)" = 401 ] \
      || fail "Home Assistant did not answer on $1 in 60 seconds"
  }
  stop() {
    kill "$pid"
    for _ in $(seq 300); do kill -0 "$pid" 2> /dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2> /dev/null && fail "Home Assistant did not stop"
    pid=
  }
  # forwarded <from> <port>: the status of a request with X-Forwarded-For
  # from that loopback address. 401 means it got past the proxy check to
  # authentication, 400 that Home Assistant refused the header.
  forwarded() {
    curl -s -o /dev/null -w '%{http_code}' --interface "$1" \
      -H 'X-Forwarded-For: 198.51.100.7' "http://127.0.0.1:$2/api/"
  }
  expect() {
    [ "$2" = "$3" ] || fail "$1: expected $2, got $3"
  }

  # A first start: no store yet.
  ${tool} "$store" ${settings [ "127.0.0.1" ]}
  expect "first file's version" 1 "$(jq .version "$store")"
  start 8123
  expect "trusted proxy" 401 "$(forwarded 127.0.0.1 8123)"
  grep -q "invalid authentication from 198.51.100.7" ha.log || fail "the forwarded address was not used"
  expect "untrusted proxy" 400 "$(forwarded 127.0.0.2 8123)"
  grep -q "untrusted proxy 127.0.0.2" ha.log || fail "no untrusted proxy in the log"
  stop
  expect "store version after Home Assistant" 3 "$(jq .version "$store")"
  expect "no trial" null "$(jq -c .data.pending "$store")"
  expect "stable proxies" '["127.0.0.1/32"]' "$(jq -c .data.stable.trusted_proxies "$store")"

  # Settings changed in the network settings: a port and CORS origin
  # confirmed, and a trial with other proxies.
  jq '.data.stable.server_port = 18123
    | .data.stable.cors_allowed_origins += ["https://ha.example.com"]
    | .data.pending = (.data.stable + {trusted_proxies: ["192.0.2.0/24"], login_attempts_threshold: 5, error: "not_promoted"})' \
    "$store" > edited && cp edited "$store"
  ${tool} "$store" ${settings [ "127.0.0.2" "2001:db8::/32" ]}
  expect "file mode" 600 "$(stat -c %a "$store")"
  expect "stable after the merge" \
    "$(jq -c '.data.stable | .trusted_proxies = ["127.0.0.2/32", "2001:db8::/32"]' edited)" \
    "$(jq -c .data.stable "$store")"
  expect "pending after the merge" \
    "$(jq -c '.data.pending | .trusted_proxies = ["127.0.0.2/32", "2001:db8::/32"]' edited)" \
    "$(jq -c .data.pending "$store")"
  expect "the rest of the store" "$(jq -c 'del(.data.stable, .data.pending)' edited)" "$(jq -c 'del(.data.stable, .data.pending)' "$store")"
  start 18123
  expect "new trusted proxy" 401 "$(forwarded 127.0.0.2 18123)"
  expect "former trusted proxy" 400 "$(forwarded 127.0.0.1 18123)"
  stop
  expect "CORS origins kept" '["https://cast.home-assistant.io","https://ha.example.com"]' \
    "$(jq -c .data.stable.cors_allowed_origins "$store")"

  # No proxy at all.
  ${tool} "$store" ${settings [ ]}
  expect "X-Forwarded-For off" false "$(jq .data.stable.use_x_forwarded_for "$store")"
  start 18123
  expect "no proxy trusted" 400 "$(forwarded 127.0.0.2 18123)"
  stop

  # Nothing to do, and what the tool refuses.
  touch -d 2000-01-01 "$store"
  ${tool} "$store" ${settings [ ]} | grep -q "already in place" || fail "a run with nothing to do wrote"
  expect "untouched file" 946684800 "$(stat -c %Y "$store")"
  cp "$store" before
  ${tool} "$store" ${settings [ "192.0.2.1/24" ]} 2> err && fail "a network with host bits passed"
  grep -q "192.0.2.1/24" err || fail "no message for the wrong network"
  jq '.version = 4' before > "$store"
  cp "$store" before
  ${tool} "$store" ${settings [ "127.0.0.1" ]} 2> err && fail "an unknown version passed"
  grep -q "version 4" err || fail "no message for the unknown version"
  cmp -s before "$store" || fail "the unknown version was changed"
  touch "$out"
''
