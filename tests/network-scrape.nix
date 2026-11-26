# The example server's scrapers of network gear,
# homelab.observability.scrape
# (docs/adr/0029-network-gear-scraped-through-exporters.md):
#
# - each option makes its scrape jobs, in the file Prometheus mounts at
#   /etc/prometheus/scrape-configs.yml, which promtool accepts with the
#   example's prometheus.yml, and a host with neither has no jobs there;
# - each makes its exporter's container, unprivileged, with the secret as
#   an environment file the store never sees and a tmpfiles rule that
#   makes it empty, and unpoller's config for the controller;
# - each exporter's unit first checks its secret, and a missing, empty or
#   incomplete one fails the check, naming the file and the variables,
#   while a complete one passes;
# - nothing in Prometheus, Loki or Grafana waits for the exporters, so a
#   failed one leaves them running;
# - the host refuses a prometheus.yml that does not list the file, and
#   insecure together with a CA or certificate.
#
# Pure evaluation, then the files and the check script, run here; the
# exporters against a real router and controller were not run.
{ lib, runCommand, writeText, prometheus, yq-go, jq, config, off, broken }:

let
  scrape = config.homelab.observability.scrape;
  containers = config.virtualisation.oci-containers.containers;
  services = config.systemd.services;
  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  refuses = cfg: text: lib.any (lib.hasInfix text) (failed cfg);

  # The store file mounted at the path; removeSuffix keeps its context.
  mounted = c: path:
    let v = lib.findFirst (v: lib.hasSuffix ":${path}:ro" v) null c.volumes;
    in if v == null then null else lib.removeSuffix ":${path}:ro" v;
  scrapeConfigs = mounted containers.prometheus "/etc/prometheus/scrape-configs.yml";
  offScrapeConfigs = mounted off.virtualisation.oci-containers.containers.prometheus "/etc/prometheus/scrape-configs.yml";
  unpollerConfig = mounted containers.unpoller "/etc/unpoller/up.conf";

  firstPre = unit: builtins.head services.${unit}.serviceConfig.ExecStartPre;

  exporters = {
    opnsense-exporter = {
      secretFile = scrape.opnsense.secretFile;
      environment = {
        OPNSENSE_EXPORTER_OPS_PROTOCOL = "https";
        OPNSENSE_EXPORTER_OPS_API = "192.0.2.1";
        OPNSENSE_EXPORTER_OPS_INSECURE = "false";
        OPNSENSE_EXPORTER_INSTANCE_LABEL = "router";
        SSL_CERT_FILE = "/etc/ssl/opnsense-ca.pem";
      };
      volumes = [ "${scrape.opnsense.caFile}:/etc/ssl/opnsense-ca.pem:ro" ];
    };
    unpoller = {
      secretFile = scrape.unifi.secretFile;
      environment = { };
      volumes = [ "${unpollerConfig}:/etc/unpoller/up.conf:ro" "${scrape.unifi.certFile}:/etc/unpoller/controller.pem:ro" ];
    };
  };

  # What the stack's units wait for or stop with.
  ties = unit: lib.concatMap (k: services.${unit}.${k} or [ ])
    [ "requires" "requisite" "bindsTo" "partOf" "after" "wants" "upholds" ]
    ++ lib.concatMap (k: lib.toList (services.${unit}.unitConfig.${k} or [ ]))
    [ "Requires" "Requisite" "BindsTo" "PartOf" "After" "Wants" ];

  problems =
    lib.optional (failed config != [ ]) "the example fails: ${toString (failed config)}"
    ++ lib.optional (scrapeConfigs == null) "Prometheus does not mount /etc/prometheus/scrape-configs.yml"
    ++ lib.optional (offScrapeConfigs == null) "Prometheus does not mount /etc/prometheus/scrape-configs.yml with nothing enabled"
    ++ lib.concatLists (lib.mapAttrsToList (name: want:
      let c = containers.${name} or null; in
      if c == null then [ "no ${name} container" ] else
      lib.optional (c.environmentFiles != [ want.secretFile ])
        "${name}'s environment files are ${toString c.environmentFiles}, not ${want.secretFile}"
      ++ lib.optional (lib.any (lib.hasPrefix "/nix/store") c.environmentFiles) "${name}'s secret is in the store"
      ++ lib.mapAttrsToList (k: v: "${name} has ${k}=${c.environment.${k} or "nothing"}, not ${v}")
        (lib.filterAttrs (k: v: (c.environment.${k} or null) != v) want.environment)
      ++ lib.optional (c.volumes != want.volumes) "${name} mounts ${toString c.volumes}"
      ++ lib.optional (c.ports != [ ]) "${name} publishes ${toString c.ports}"
      ++ lib.optional (!(lib.hasInfix "/ghcr.io/" "/${c.image}" && lib.hasInfix "@sha256:" c.image)) "${name}'s image is not pinned by digest"
      ++ lib.optional (!(lib.elem "f ${want.secretFile} 0400 root root -" config.systemd.tmpfiles.rules))
        "no tmpfiles rule makes ${want.secretFile} empty, root's, 0400"
      ++ lib.optional (!(lib.hasInfix "scrape-secret-check" (firstPre "podman-${name}")
        && lib.hasInfix want.secretFile (firstPre "podman-${name}")))
        "podman-${name} does not check ${want.secretFile} first"
      ++ lib.concatMap (unit:
        lib.optional (lib.any (t: lib.hasInfix name t) (ties unit)) "${unit} waits for ${name}")
        [ "podman-prometheus" "podman-loki" "podman-grafana" ]
    ) exporters)
    ++ lib.optional (lib.any (n: off.virtualisation.oci-containers.containers ? ${n}) (lib.attrNames exporters))
      "a host with nothing enabled runs an exporter"
    ++ lib.optional (!refuses broken.noScrapeConfigFiles "does not name")
      "a prometheus.yml without the scrape config file is taken"
    ++ lib.optional (!refuses broken.opnsenseInsecureWithCa "insecure and caFile")
      "insecure with caFile is taken"
    ++ lib.optional (!refuses broken.unifiInsecureWithCert "insecure and certFile")
      "insecure with certFile is taken";

  checkOpnsense = builtins.unsafeDiscardStringContext (firstPre "podman-opnsense-exporter");
  checkUnpoller = builtins.unsafeDiscardStringContext (firstPre "podman-unpoller");
in
if problems != [ ] then
  throw "The network scrapers break docs/adr/0029-network-gear-scraped-through-exporters.md:\n${lib.concatStringsSep "\n" problems}"
else
  runCommand "network-scrape"
  {
    nativeBuildInputs = [ prometheus.cli yq-go jq ];
    # The units' commands, run below with the secret file swapped for test
    # files. Their strings' context is dropped above; this brings in the
    # script they run.
    inherit scrapeConfigs offScrapeConfigs unpollerConfig checkOpnsense checkUnpoller;
    secretCheck = lib.head (lib.splitString "\"" (lib.removePrefix "\"" (firstPre "podman-opnsense-exporter")));
  } ''
    set -euo pipefail
    fail() { echo "$*" >&2; exit 1; }

    # The jobs: the router's node_exporter and the exporters, each with the
    # device's name as instance.
    jobs=$(yq -o json '[.scrape_configs[] | {"job": .job_name, "targets": .static_configs[0].targets, "instance": .static_configs[0].labels.instance}]' "$scrapeConfigs" | jq -c .)
    want='[{"job":"opnsense","targets":["192.0.2.1:9100"],"instance":"router"},{"job":"opnsense-exporter","targets":["opnsense-exporter:8080"],"instance":"router"},{"job":"unifi","targets":["unpoller:9130"],"instance":"unifi"}]'
    [ "$jobs" = "$want" ] || fail "the jobs are $jobs, not $want"
    [ "$(yq -o json '.scrape_configs' "$offScrapeConfigs")" = "[]" ] || fail "a host with nothing enabled has jobs"

    # The example's prometheus.yml, with the files the module mounts in
    # /etc/prometheus here instead. A full check, as --syntax-only does
    # not read scrape_config_files; a job named like one of the example's
    # must fail it.
    sed "s|/etc/prometheus/|$PWD/|g" ${../examples/assets/prometheus.yml} > prometheus.yml
    echo token > ha-token
    echo '[]' > probe-targets.json
    echo '[]' > nvidia-gpu-targets.json
    install -m 0644 "$scrapeConfigs" scrape-configs.yml
    promtool check config prometheus.yml
    install -m 0644 "$offScrapeConfigs" scrape-configs.yml
    promtool check config prometheus.yml
    printf 'scrape_configs:\n  - job_name: blackbox\n' > scrape-configs.yml
    if promtool check config prometheus.yml; then fail "promtool did not read scrape-configs.yml"; fi

    # unpoller's config: the controller, its sites, the pinned certificate,
    # Prometheus only.
    conf=$(yq -p toml -o json '{"url": .unifi.defaults.url, "sites": .unifi.defaults.sites, "verify": .unifi.defaults.verify_ssl, "certs": .unifi.defaults.ssl_cert_paths, "listen": .prometheus.http_listen, "influx": .influxdb.disable, "dynamic": .unifi.dynamic}' "$unpollerConfig" | jq -c .)
    want='{"url":"https://192.0.2.2:11443","sites":["all"],"verify":true,"certs":["/etc/unpoller/controller.pem"],"listen":"0.0.0.0:9130","influx":true,"dynamic":false}'
    [ "$conf" = "$want" ] || fail "unpoller's config is $conf, not $want"

    # The secret check as each unit runs it, on test files in place of the
    # one under /var/lib/secrets.
    run() { # run <command> <file>
      local cmd=$1 file=$2
      eval "set -- $cmd"
      local args=("$@")
      args[3]=$file
      "''${args[@]}"
    }
    expect_fail() { # expect_fail <name> <command> <file> <text>...
      local name=$1 cmd=$2 file=$3
      shift 3
      if run "$cmd" "$file" 2> err; then fail "$name: the check passed"; fi
      for text in "$@"; do
        grep -qF -- "$text" err || fail "$name: the message lacks $text: $(cat err)"
      done
    }

    expect_fail "opnsense, missing" "$checkOpnsense" "$PWD/none.env" \
      "The OPNsense exporter does not start" "$PWD/none.env" \
      OPNSENSE_EXPORTER_OPS_API_KEY OPNSENSE_EXPORTER_OPS_API_SECRET docs/opnsense.md
    : > empty.env
    expect_fail "opnsense, empty" "$checkOpnsense" "$PWD/empty.env" \
      OPNSENSE_EXPORTER_OPS_API_KEY OPNSENSE_EXPORTER_OPS_API_SECRET
    printf 'OPNSENSE_EXPORTER_OPS_API_KEY=key\nOPNSENSE_EXPORTER_OPS_API_SECRET=\n' > half.env # public-check: fake
    expect_fail "opnsense, no secret" "$checkOpnsense" "$PWD/half.env" OPNSENSE_EXPORTER_OPS_API_SECRET
    grep -q OPNSENSE_EXPORTER_OPS_API_KEY err && fail "opnsense, no secret: the key is named as missing"
    printf 'OPNSENSE_EXPORTER_OPS_API_KEY=key\nOPNSENSE_EXPORTER_OPS_API_SECRET=secret\n' > opnsense.env # public-check: fake
    run "$checkOpnsense" "$PWD/opnsense.env" || fail "opnsense: a complete file fails the check"

    expect_fail "unifi, missing" "$checkUnpoller" "$PWD/none.env" \
      "unpoller does not start" UP_UNIFI_DEFAULT_USER UP_UNIFI_DEFAULT_PASS docs/unifi.md
    printf 'UP_UNIFI_DEFAULT_USER=unpoller\n' > unifi-half.env
    expect_fail "unifi, no password" "$checkUnpoller" "$PWD/unifi-half.env" UP_UNIFI_DEFAULT_PASS
    printf 'UP_UNIFI_DEFAULT_USER=unpoller\nUP_UNIFI_DEFAULT_PASS=password\n' > unifi.env # public-check: fake
    run "$checkUnpoller" "$PWD/unifi.env" || fail "unifi: a complete file fails the check"

    touch "$out"
  ''
