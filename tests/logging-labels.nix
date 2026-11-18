# The logging agent labels journal lines with their unit and container, and
# leaves the body the journal record it was.
#
# - Evaluation: the example server's fluent-bit config copies _SYSTEMD_UNIT
#   to unit and CONTAINER_NAME to container, and its loki output labels on
#   the copies besides job and host.
# - A run of fluent-bit with that config, its systemd input swapped for
#   three dummy journal records and its output pointed at a stand-in for
#   Loki: a container's line gets unit and container, a host service's
#   only unit, a kernel line neither (no label, not an empty one), and
#   every body is the record unchanged, _SYSTEMD_UNIT and CONTAINER_NAME
#   included, so `| json` queries keep working.
#
# Nothing here may outlive or stall the build: the stand-in listens on a
# free port, and it and fluent-bit are killed at the end or on a deadline.
{ lib, runCommand, python3, fluent-bit, settings, hostName }:

let
  filters = settings.pipeline.filters or [ ];
  outputs = settings.pipeline.outputs or [ ];
  loki = lib.findFirst (o: o.name == "loki") null outputs;
  copies = lib.concatMap (f: lib.toList (f.copy or [ ])) (lib.filter (f: f.name == "modify") filters);

  problems =
    lib.optional (loki == null) "no loki output"
    ++ lib.optional (!(lib.elem "_SYSTEMD_UNIT unit" copies)) "no modify filter copies _SYSTEMD_UNIT to unit"
    ++ lib.optional (!(lib.elem "CONTAINER_NAME container" copies)) "no modify filter copies CONTAINER_NAME to container"
    ++ lib.optional (loki != null && (loki.label_keys or null) != "$unit, $container")
      "the loki output's label_keys are ${builtins.toJSON (loki.label_keys or null)}, not \"$unit, $container\"";

  record = fields: builtins.toJSON fields;
  test = settings // {
    service = settings.service // { flush = 1; log_level = "warn"; };
    pipeline = settings.pipeline // {
      inputs = [
        { name = "dummy"; tag = "host.container"; samples = 1;
          dummy = record { _SYSTEMD_UNIT = "podman-vaka.service"; CONTAINER_NAME = "vaka"; MESSAGE = "started"; PRIORITY = "6"; }; }
        { name = "dummy"; tag = "host.service"; samples = 1;
          dummy = record { _SYSTEMD_UNIT = "sshd.service"; MESSAGE = "accepted"; PRIORITY = "6"; }; }
        { name = "dummy"; tag = "host.kernel"; samples = 1;
          dummy = record { _TRANSPORT = "kernel"; MESSAGE = "link up"; PRIORITY = "5"; }; }
      ];
      outputs = map (o: if o.name == "loki"
        then o // { host = "127.0.0.1"; port = "@PORT@"; tls = "Off"; "tls.verify" = "Off"; }
        else o) outputs;
    };
  };
in
if problems != [ ] then
  throw "the logging agent does not label journal lines with their unit and container:\n${lib.concatStringsSep "\n" problems}"
else
runCommand "logging-labels-test"
{
  nativeBuildInputs = [ python3 fluent-bit ];
  config = builtins.toJSON test;
  passAsFile = [ "config" ];
} ''
  set -euo pipefail
  fake= fb=
  stop() {
    [ -z "$fb" ] || kill "$fb" 2> /dev/null || true
    [ -z "$fake" ] || kill "$fake" 2> /dev/null || true
  }
  fail() { echo "FAIL: $*" >&2; [ ! -e fb.log ] || cat fb.log >&2; stop; exit 1; }

  python3 -I ${./fake-loki.py} port pushes > fake.log 2>&1 &
  fake=$!
  for _ in $(seq 100); do [ -e port ] && break; sleep 0.1; done
  [ -e port ] || fail "the stand-in for Loki did not start"
  sed "s/\"@PORT@\"/$(cat port)/" "$configPath" > fluent-bit.yaml

  fluent-bit -c fluent-bit.yaml > fb.log 2>&1 &
  fb=$!
  for _ in $(seq 300); do
    [ -e pushes ] && [ "$(python3 -c 'import json,sys; print(sum(len(s["values"]) for l in open(sys.argv[1]) for s in json.loads(l)["streams"]))' pushes)" -ge 3 ] && break
    sleep 0.1
  done
  stop

  [ -e pushes ] || fail "fluent-bit pushed nothing"
  python3 - pushes <<'PY' || fail "the pushed streams are wrong"
  import json, sys
  got = {}
  for line in open(sys.argv[1]):
      for stream in json.loads(line)["streams"]:
          for _, body in stream["values"]:
              record = json.loads(body)
              got[record["MESSAGE"]] = (stream["stream"], record)
  base = {"job": "systemd-journal", "host": "${hostName}"}
  want = {
      "started": (dict(base, unit="podman-vaka.service", container="vaka"),
                  {"_SYSTEMD_UNIT": "podman-vaka.service", "CONTAINER_NAME": "vaka", "MESSAGE": "started", "PRIORITY": "6"}),
      "accepted": (dict(base, unit="sshd.service"),
                   {"_SYSTEMD_UNIT": "sshd.service", "MESSAGE": "accepted", "PRIORITY": "6"}),
      "link up": (base, {"_TRANSPORT": "kernel", "MESSAGE": "link up", "PRIORITY": "5"}),
  }
  ok = True
  for message, (labels, record) in want.items():
      if message not in got:
          print(f"no line {message!r}", file=sys.stderr)
          ok = False
      elif got[message] != (labels, record):
          print(f"{message!r}: labels {got[message][0]} and body {got[message][1]},"
                f" want {labels} and {record}", file=sys.stderr)
          ok = False
  sys.exit(0 if ok else 1)
  PY
  cp fluent-bit.yaml "$out"
''
