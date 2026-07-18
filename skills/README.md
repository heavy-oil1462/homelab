# Homelab skills

Claude Code skills for introspecting the homelab stack this library deploys.
Each skill is a directory with a `SKILL.md` (frontmatter `name` +
`description`, then usage) and one or more runnable scripts. The repo doubles
as a Claude Code plugin, so the skills can be installed into any project:

```
claude plugin marketplace add heavy-oil1462/homelab
claude plugin install homelab@homelab
```

## Layout

```
skills/                 one directory per skill (thin entry points)
  ha-state/             inspect HA entity state
  host-metrics/         node_exporter host health
  service-logs/         journal logs from Loki
lib/homelab/            shared, reusable backend code (not entry points)
  config.py             endpoint resolution (env, endpoints file), no secrets
  prometheus.py         read-only Prometheus HTTP client
  loki.py               read-only Loki HTTP client
  ha.py, nodeexporter.py, logs.py
```

## Conventions

- Skills are thin entry points. Real logic lives in `lib/homelab` so it is
  shared across skills. Scripts locate the lib relative to their own file
  (two directories up), so they work from a checkout and from the plugin
  cache alike; SKILL.md bodies invoke them via `${CLAUDE_SKILL_DIR}`.
- Read-only by default. Anything that changes state should say so loudly in
  its SKILL.md and be a separate, clearly named script.
- No secrets in the tree. Endpoints resolve from HOMELAB_* environment
  variables, else a `.claude/homelab-endpoints.json` found upward from the
  current directory (commit one in your private config repo), else
  `~/.claude/homelab-endpoints.json`. Tokens stay server-side.
- Standard library only, so scripts run without a pip install.
- Each script supports `--help` and a `--json` output mode.

## Planned

- HA REST/WebSocket backend for device grouping and attributes (needs a token).
- Generic NixOS helper skills for common recurring tasks.
