# Dashboards

Drop Grafana dashboard JSON files in this directory. The observability
module mounts it read-only and provisions everything in it into the
Homelab folder, read-only. Dashboards you edit yourself belong in the
repository of `homelab.observability.grafanaGitSync` instead
(docs/dashboards.md); keep each dashboard in one place only.

- `gpu.json`: GPU, per instance: utilization, memory used and total,
  temperature, power draw and encoder and decoder utilization, from the
  NVIDIA GPU exporter (`homelab.observabilityAgent.nvidiaGpu.enable`)
  scraped by the nvidia-gpu job of the example prometheus.yml.
