# ADR-0017: Running images are scanned for known vulnerabilities

Status: Accepted

## Context

The owner wants the containers kept up to date with security fixes, and
agreed to look into a vulnerability scan (board, cue entries 01a1ef79-dda6
and 01a1ef85-86fd, 2026-11-18). The image-updates skill of
[ADR-0016](0016-image-updates-as-reviewed-bumps.md) finds images whose tag
has moved. It cannot say which known vulnerabilities are in what a host runs now,
whether a fixed version exists, or anything about an image whose tag
never moves: a pinned major version with an unpatched dependency, or our
own images.

Servers change only when deliberately rebuilt, so a scanner must only
read. Every image a host runs is already in its config, as
`virtualisation.oci-containers.containers.<name>.image`, and in podman's
storage, pinned by digest.

Trivy is in nixpkgs (0.69.3 at our pin). It can read an image three ways
that do not pull:

- `--image-src podman`, through podman's API socket
  (`pkg/fanal/image/daemon/podman.go`). Our hosts do not run the socket,
  and whoever can talk to the rootful one is root on the host.
- Reading podman's storage directly, which needs root and the storage's
  locks.
- `--input` with an image archive, docker-archive or OCI, which
  `podman save` writes.

Trivy's vulnerability database is an OCI artifact. Read at 0.69.3
(`pkg/db/db.go`, the `--db-repository` default in `pkg/flag/db_flags.go`),
it is fetched from `mirror.gcr.io/aquasec/trivy-db:2`, Google's mirror of
Docker Hub, and from `ghcr.io/aquasecurity/trivy-db:2` when that fails.
Aqua rebuilds it several times a day; its `metadata.json` says when. The
Java database, for images with JAR files, comes the same way from
`mirror.gcr.io/aquasec/trivy-java-db:1` or
`ghcr.io/aquasecurity/trivy-java-db:1`, and only when a scan finds one.

## Decision

- `modules/vulnerability-scan.nix`, turned on per host with
  `homelab.vulnerabilityScan.enable`, scans the image of every container in
  `virtualisation.oci-containers.containers`, taken from the config and not
  guessed at runtime. A systemd timer starts it on
  `homelab.vulnerabilityScan.schedule` (daily), with up to an hour of
  random delay, and catches a missed run up after boot.
- Images are read from the local storage with `podman save`, by image id,
  into a docker-archive in `/var/cache/vulnerability-scan`, and Trivy scans
  each archive with `--input`. Nothing is pulled. An image whose archive
  would leave less than a tenth of that filesystem free, or 5 GiB, is not
  saved.
- The unit runs as a `DynamicUser` with `ProtectSystem=strict`, no
  capabilities, a system call filter and no access to podman. Only two steps
  run as root, outside that sandbox (`+`): the save, which needs podman's
  rootful storage, and the publish of the metrics into the node exporter's
  textfile directory, which belongs to root. Trivy, which parses whatever
  the images contain, never runs as root. That is ADR-0014's rule for
  containers applied to the host service that reads them.
- Each run first lets Trivy update its vulnerability database in the state
  directory, `/var/lib/vulnerability-scan/trivy`, from the registries above
  over HTTPS, and then scans with `--skip-db-update` and `--offline-scan`,
  so the database is fetched at most once a run, and so once a day. When
  the download fails, the run scans with the last database and reports its
  age. Trivy's version check and telemetry are off. Only the vulnerability
  scanner runs; no secrets or misconfiguration scans.
- Each container's full report is written to
  `/var/lib/vulnerability-scan/<container>.json`, so the CVEs are read on
  the host. Prometheus gets counts only, with no CVE id as a label, in
  `homelab_vulnerability_scan.prom` in
  `homelab.observabilityAgent.textfileDirectory`, as
  [ADR-0007](0007-backup-freshness-textfile-metric.md) has the backups do:
  - `homelab_image_vulnerabilities{image, container, severity, fixable}`,
    the count per severity `CRITICAL`, `HIGH`, `MEDIUM` and `LOW`, with
    `fixable="true"` for those Trivy names a fixed version for. A failed
    scan keeps the last report's counts, under the image that report
    scanned.
  - `homelab_image_scan_success{container}`, 1 when the last run scanned
    the container's image.
  - `homelab_image_scan_timestamp_seconds{container}`, its last successful
    scan; until the first, when scanning it was first tried, so a container
    that never scans ages like one that stopped.
  - `homelab_vulnerability_db_age_seconds`, the age of the database the
    last run used, from its build time.
- The example's provisioned Grafana alerts gain two rules, both
  `severity: warning` like the other rules that lose no data:
  "Fixable vulnerability in a running image", the sum of fixable CRITICAL
  and HIGH counts per container above 0 for 24 hours, and "Vulnerability
  scan failing or stale", no successful scan of a container in 3 days, for
  an hour. The sum makes one alert per container, and keeps the series'
  `severity` label from clashing with the rule's.
- The checks evaluate the example server's unit against its containers,
  run the script against a stubbed podman and Trivy with a fixture report,
  and test the rules in promtool.

## Consequences

- A fixable vulnerability shows whether an image bump is urgent; an
  unfixable one shows that a bump would not help yet. The update itself
  stays a deliberate change, through ADR-0016's skill or by hand.
- The hosts reach `mirror.gcr.io` (or `ghcr.io`) once a day over HTTPS,
  which they could already. Hosts without that access get no database and
  every scan fails, which the stale rule reports after 3 days.
- While a run lasts, the archives take about as much room in `/var/cache`
  as the images in podman's storage, usually on the same filesystem. Each
  is removed once scanned. So that a daily background job cannot fill the
  root filesystem, save measures the free space before each image and
  skips one whose size would leave less than a tenth of the filesystem, or
  5 GiB if that is more, with a message in the journal. Its scan then
  fails and shows in `homelab_image_scan_success`, and after 3 days in the
  stale rule. A host short of space gets some images unscanned rather
  than a full disk.
- Images built with Nix, vaka's among them, have no OS package database, so
  Trivy sees only what it finds in their files, mainly the modules built
  into Go binaries. A vulnerable C library in such an image does not show.
  The same holds for any image without a package database, distroless or
  scratch.
- Only `oci-containers` are scanned. podium's rootless images on
  nixserver1, run by its own user's podman, are out of scope, as are the
  containers the Nextcloud AIO mastercontainer starts through podman's
  socket and the agent sandboxes. They need a scan in their user's podman,
  if wanted later.
- The labels stay bounded: a container contributes 8 vulnerability series
  and 2 for its scan, whatever it contains.
- The database's own coverage decides what counts as known: Trivy follows
  the distributions' advisories, so a vulnerability a distribution marks
  as not affecting it, or not yet fixed, is counted that way.

Related: [ADR-0014](0014-containers-run-unprivileged.md) (unprivileged
containers), [ADR-0016](0016-image-updates-as-reviewed-bumps.md) (moved
tags), [ADR-0007](0007-backup-freshness-textfile-metric.md) (textfile
metrics).
