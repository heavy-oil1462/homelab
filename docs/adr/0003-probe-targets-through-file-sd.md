# ADR-0003: Probe targets reach Prometheus through file_sd
Status: Proposed

## Context

The blackbox exporter probes the sites listed in
`homelab.observability.probeTargets`. Prometheus scrapes it through a job in
prometheus.yml, which the consumer provides and the observability module
mounts verbatim. The targets need one source of truth: either the option,
with the module getting them into Prometheus, or a static list in
prometheus.yml with no option at all. Rewriting or templating the
consumer's prometheus.yml to inject a job would be a scheme no other module
uses.

## Decision

The option is the source of truth. The observability module writes it as a
file_sd file and mounts it read-only at
`/etc/prometheus/probe-targets.json`. The consumer's prometheus.yml carries
the blackbox job (module parameter, relabeling, exporter address) and reads
its targets with `file_sd_configs`; it lists no URLs itself. The example
prometheus.yml has that job.

## Consequences

- prometheus.yml stays the consumer's file, never rewritten. The job is
  written once and does not change when sites are added.
- Adding a site is a change to the host's Nix config only.
- The same pattern fits any later list of targets the Nix side knows
  better than prometheus.yml does: a file under `/etc/prometheus/` and a
  file_sd job.
- A consumer who leaves the job out of prometheus.yml probes nothing and
  gets no error; the README and the example say the job is needed.
