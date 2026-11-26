# Proxmox VE's OTLP pushes into Prometheus, with
# homelab.observability.otlpReceiver
# (docs/adr/0030-proxmox-pushes-opentelemetry-into-prometheus.md).
#
# The example server's config, evaluated:
#
# - Prometheus runs with --web.enable-otlp-receiver, and the image's own
#   command otherwise;
# - the host's otlp-receiver socket listens on 4318 and hands connections
#   to Caddy's address; the firewall takes 4318 from the allowed source
#   only, on iptables and on nftables, and nowhere else;
# - off, none of that, and Prometheus keeps the image's command;
# - no allowed sources, 0.0.0.0/0, or no Caddy address fail the build.
#
# Then the real thing: nixpkgs' Prometheus, the version the image runs,
# with the container's flags and the example's prometheus.yml, behind the
# OTLP site from the example server's generated Caddyfile in a real Caddy.
# A push shaped as Proxmox VE 9's OpenTelemetry plugin sends it
# (PVE/Status/OpenTelemetry.pm: JSON, gzip, a gauge and a monotonic sum,
# times as numbers) goes to /v1/metrics and is queried back by the names
# Grafana dashboard 23855 uses. Proxmox's connection test, an empty push,
# is taken too. Every other path through Caddy, Prometheus's own receiver
# path and its API included, answers 404.
#
# It cannot open a connection through the socket and the firewall: that
# needs the host in a VM, which the checks do not start.
{ lib, runCommand, writeText, caddy, curl, python3, prometheus
, on, nftables, off, broken, prometheusConfig }:

let
  otlpRule = cfg: lib.hasInfix "--dport 4318" cfg.networking.firewall.extraCommands;
  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  cmd = cfg: cfg.virtualisation.oci-containers.containers.prometheus.cmd;
  caddyfile = cfg: lib.removeSuffix ":/etc/caddy/Caddyfile"
    (builtins.head cfg.virtualisation.oci-containers.containers.caddy.volumes);
  imageCmd = [ "--config.file=/etc/prometheus/prometheus.yml" "--storage.tsdb.path=/prometheus" ];

  expect = what: want: have:
    lib.optional (want != have) "${what}: expected ${builtins.toJSON want}, got ${builtins.toJSON have}";
  expectFailure = what: needle: cfg:
    lib.optional (!(lib.any (lib.hasInfix needle) (failed cfg)))
      "${what}: no failed assertion with ${builtins.toJSON needle}, got ${builtins.toJSON (failed cfg)}";

  problems =
    expect "on: Prometheus's command" (imageCmd ++ [ "--web.enable-otlp-receiver" ]) (cmd on)
    ++ expect "on: the socket's ports" [ "4318" ] on.systemd.sockets.otlp-receiver.listenStreams
    ++ expect "on: the socket proxy's target" true
      (lib.hasSuffix "/systemd-socket-proxyd\" \"10.88.255.2:4318\"" on.systemd.services.otlp-receiver.serviceConfig.ExecStart)
    ++ expect "on: iptables rule for the allowed source" true (lib.hasInfix
      "iptables -A nixos-fw -p tcp --dport 4318 -s 192.0.2.30 -j nixos-fw-accept\n"
      on.networking.firewall.extraCommands)
    ++ expect "on: iptables rules for 4318" 1
      (lib.length (lib.filter (lib.hasInfix "--dport 4318") (lib.splitString "\n" on.networking.firewall.extraCommands)))
    ++ expect "on: ports open on every interface" [ ] on.networking.firewall.allowedTCPPorts
    ++ expect "on: nftables input rules, unused on iptables" "" on.networking.firewall.extraInputRules
    ++ expect "on: Prometheus's published ports" [ ] on.virtualisation.oci-containers.containers.prometheus.ports
    ++ expect "on: Caddy's published ports, as without the receiver"
      off.virtualisation.oci-containers.containers.caddy.ports on.virtualisation.oci-containers.containers.caddy.ports
    ++ expect "on: failed assertions" [ ] (failed on)
    ++ expect "nftables: input rules" ''
      ip saddr { 192.0.2.30 } tcp dport 4318 accept
    ''
      nftables.networking.firewall.extraInputRules
    ++ expect "nftables: iptables rules, unused on nftables" false (otlpRule nftables)
    ++ expect "nftables: failed assertions" [ ] (failed nftables)
    ++ expect "off: Prometheus's command" imageCmd (cmd off)
    ++ expect "off: the socket" false (off.systemd.sockets ? otlp-receiver)
    ++ expect "off: an iptables rule for 4318" false (otlpRule off)
    ++ expectFailure "noSources" "allowedSources" broken.noSources
    ++ expectFailure "everyone" "prefix length 0" broken.everyone
    ++ expectFailure "noCaddyAddress" "Caddy" broken.noCaddyAddress;

  # PVE/Status/OpenTelemetry.pm's request: one resource with its four
  # attributes, an empty scope, and the data points' own attributes.
  push = writeText "pve-push.py" ''
    import gzip, json, sys, time

    now = int(time.time())
    node = [{"key": "node", "value": {"stringValue": "pve1"}}]
    vm = [
        {"key": "vmid", "value": {"stringValue": "100"}},
        {"key": "node", "value": {"stringValue": "pve1"}},
        {"key": "name", "value": {"stringValue": "web"}},
        {"key": "type", "value": {"stringValue": "qemu"}},
    ]

    def point(attributes, value):
        p = {"timeUnixNano": now * 1_000_000_000, "attributes": attributes}
        p["asDouble" if isinstance(value, float) else "asInt"] = value
        return p

    metrics = [
        {"name": "proxmox_node_uptime", "unit": "seconds",
         "gauge": {"dataPoints": [point(node, 86400)]}},
        {"name": "proxmox_node_cpustat_avg1", "unit": "1",
         "gauge": {"dataPoints": [point(node, 0.25)]}},
        {"name": "proxmox_vm_netin_total", "unit": "bytes",
         "sum": {"dataPoints": [point(vm, 987654)],
                 "aggregationTemporality": 2, "isMonotonic": True}},
    ]
    if sys.argv[1] == "empty":
        resource, metrics = [], []
    else:
        resource = [
            {"key": "service.name", "value": {"stringValue": "proxmox-ve"}},
            {"key": "service.version", "value": {"stringValue": "9.1.1"}},
            {"key": "proxmox.cluster", "value": {"stringValue": "single-node"}},
            {"key": "proxmox.node", "value": {"stringValue": "pve1"}},
        ]
    body = {"resourceMetrics": [{
        "resource": {"attributes": resource},
        "scopeMetrics": [{"scope": {}, "metrics": metrics}],
    }]}
    sys.stdout.buffer.write(gzip.compress(json.dumps(body).encode()))
  '';

  # The series the push should have made, as dashboard 23855 queries them.
  expectSeries = writeText "expect-series.py" ''
    import json, sys

    result = json.load(sys.stdin)["data"]["result"]
    have = {r["metric"]["__name__"]: r for r in result}
    want = {
        "proxmox_node_uptime_seconds": "86400",
        "proxmox_node_cpustat_avg1_ratio": "0.25",
        "proxmox_vm_netin_bytes_total": "987654",
    }
    problems = []
    for name, value in want.items():
        if name not in have:
            problems.append(f"no {name} in {sorted(have)}")
            continue
        labels, v = have[name]["metric"], have[name]["value"][1]
        if v != value:
            problems.append(f"{name} is {v}, not {value}")
        for k, w in {"job": "proxmox-ve", "node": "pve1",
                     "proxmox_cluster": "single-node", "proxmox_node": "pve1"}.items():
            if labels.get(k) != w:
                problems.append(f"{name} has {k}={labels.get(k)!r}, not {w!r}")
    vm = have.get("proxmox_vm_netin_bytes_total", {}).get("metric", {})
    if (vm.get("vmid"), vm.get("name"), vm.get("type")) != ("100", "web", "qemu"):
        problems.append(f"proxmox_vm_netin_bytes_total lacks the VM's labels: {vm}")
    if problems:
        sys.exit("\n".join(problems))
  '';

  run = runCommand "otlp-receiver-test" {
    nativeBuildInputs = [ caddy curl python3 prometheus ];
    cmd = lib.escapeShellArgs (cmd on);
  } ''
    set -euo pipefail
    export HOME=$PWD XDG_DATA_HOME=$PWD XDG_CONFIG_HOME=$PWD
    . ${./identity-harness.sh}

    sed -n '/^http:\/\/:4318 {$/,/^}$/p' ${caddyfile on} > otlp-site
    grep -q 'reverse_proxy prometheus:9090' otlp-site || fail "no OTLP site in the generated Caddyfile"
    {
      printf '{\n\tauto_https off\n\tadmin off\n}\n\n'
      sed -e 's|^http://:4318 {$|http://:{$OTLP_PORT} {|' \
        -e 's|prometheus:9090|127.0.0.1:{$PROM_PORT}|' otlp-site
    } > Caddyfile

    # Without the receiver, the generated Caddyfile has no OTLP site.
    ! grep -q otlp_metrics ${caddyfile off} || fail "the OTLP site is in the Caddyfile with the receiver off"

    # The container's command, with the host's paths for its mounts. As
    # with Caddy, another listener can take the port first; Prometheus
    # then exits and gets three more tries on other ports.
    eval "args=($cmd)"
    args=("''${args[@]/#--config.file=*/--config.file=${prometheusConfig}}")
    args=("''${args[@]/#--storage.tsdb.path=*/--storage.tsdb.path=$PWD/data}")
    up=
    for _ in 1 2 3 4; do
      export PROM_PORT=$(free_port)
      prometheus "''${args[@]}" --web.listen-address=127.0.0.1:$PROM_PORT > prometheus.log 2>&1 &
      pid=$!
      for _ in $(seq 300); do
        kill -0 "$pid" 2> /dev/null || break
        if curl -sf --max-time 2 -o /dev/null http://127.0.0.1:$PROM_PORT/-/ready; then up=1; break; fi
        sleep 0.2
      done
      if [ -n "$up" ]; then pids+=("$pid"); break; fi
      kill "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
    done
    [ -n "$up" ] || fail "Prometheus did not start"

    start_caddy OTLP_PORT

    post() {
      curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -H 'Content-Encoding: gzip' \
        --data-binary @"$1" "http://127.0.0.1:$OTLP_PORT$2" || true
    }

    python3 -I ${push} full > full.json.gz
    python3 -I ${push} empty > empty.json.gz

    code=$(post empty.json.gz /v1/metrics)
    [ "$code" = 200 ] || fail "Proxmox's connection test got $code"
    code=$(post full.json.gz /v1/metrics)
    [ "$code" = 200 ] || fail "the push got $code"

    for i in $(seq 150); do
      curl -s --max-time 5 -G http://127.0.0.1:$PROM_PORT/api/v1/query \
        --data-urlencode 'query={job="proxmox-ve", __name__=~"proxmox_.*"}' > series.json || true
      python3 -I ${expectSeries} < series.json 2> series.err && break
      [ "$i" = 150 ] && fail "the pushed series: $(cat series.err)"
      sleep 0.2
    done

    # Nothing else of Prometheus through Caddy.
    code=$(post full.json.gz /api/v1/otlp/v1/metrics)
    [ "$code" = 404 ] || fail "POST /api/v1/otlp/v1/metrics through Caddy got $code"
    code=$(post full.json.gz /api/v1/write)
    [ "$code" = 404 ] || fail "POST /api/v1/write through Caddy got $code"
    for path in /v1/metrics /api/v1/query?query=up /api/v1/status/config /metrics /graph /-/ready; do
      code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$OTLP_PORT$path" || true)
      [ "$code" = 404 ] || fail "GET $path through Caddy got $code"
    done
    code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
      --data-urlencode 'query=up' "http://127.0.0.1:$OTLP_PORT/api/v1/query" || true)
    [ "$code" = 404 ] || fail "POST /api/v1/query through Caddy got $code"

    stop
    cp series.json $out
  '';
in
if problems == [ ] then
  run
else
  throw "The OTLP receiver breaks docs/adr/0030-proxmox-pushes-opentelemetry-into-prometheus.md:\n${lib.concatStringsSep "\n" problems}"
