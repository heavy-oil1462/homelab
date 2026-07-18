---
name: service-logs
description: Read service and system logs from the homelab hosts via Loki, instead of SSHing in. Use to view logs for a service or container, filter by severity, search messages, or see which units have been logging. Logs are the systemd journal shipped by fluent-bit.
---

# Service logs

Read-only access to the systemd-journal logs collected in Loki, so you can
read service logs without SSHing into a host. Every server ships its journal
via fluent-bit under `job="systemd-journal"` with a `host` label; the service
identity (unit, syslog identifier, container name), priority, and message are
fields inside each JSON line.

## Scripts

Fetch logs, filtered:

```
python3 "${CLAUDE_SKILL_DIR}/get_logs.py" [--host H] [-s SERVICE] [--since 2h] [--level warning] [--grep REGEX] [--limit N]
```

- `--host`: limit to one host by hostname (omit for all; the host-metrics
  skill lists the hostnames).
- `-s/--service`: case-insensitive substring matched against the systemd unit,
  the syslog identifier, and the container name (e.g. `-s caddy`, `-s restic`).
- `--since`: time window, `30m`, `2h`, `1d` (default 1h).
- `--level`: minimum severity, a name (`emerg alert crit err warning notice info debug`)
  or number 0-7. Keeps that level and worse.
- `--grep`: case-insensitive regex on the message text.
- `--limit`: max lines (default 200). `--json` for structured output.

Output is chronological: `MM-DD HH:MM:SS host unit level: message`.

Discover which units are logging (to find a service name):

```
python3 "${CLAUDE_SKILL_DIR}/list_services.py" [--host H] [--since 6h]
```

Lists units by line count over the window.

## Examples

```
# Caddy errors on the reverse-proxy host in the last 6 hours
python3 "${CLAUDE_SKILL_DIR}/get_logs.py" --host myserver -s caddy --level err --since 6h

# Why the vaultwarden backup failed
python3 "${CLAUDE_SKILL_DIR}/get_logs.py" -s restic-backups-vaultwarden --since 1d

# Anything mentioning "oom" across all hosts today
python3 "${CLAUDE_SKILL_DIR}/get_logs.py" --grep oom --since 1d
```

## Notes

- Container PRIORITY caveat: containerized services (podman units) journal
  stdout and stderr at fixed priorities, so `--level` reflects which stream a
  line came from, not the app's own log level. Caddy logs access lines to
  stderr, so they all show as `err` even though they are info. For container
  apps, filter on the message (`--grep`) or read the level inside the JSON
  message instead.
- Long messages are truncated to 300 chars in the text view; pass `--full` (or
  `--json`) for the complete line. Container logs are often JSON themselves.
- Service identity is filtered inside the JSON line, not via a Loki label, to
  keep stream cardinality low. If unit-as-label is wanted later, fluent-bit can
  promote `_SYSTEMD_UNIT` with `label_keys` in `modules/logging-agent.nix`.
- The Loki endpoint resolves from HOMELAB_LOKI_URL, else a
  .claude/homelab-endpoints.json found upward from the current directory,
  else ~/.claude/homelab-endpoints.json (see lib/homelab/config.py at the
  plugin root). Logic lives in lib/homelab/logs.py on the shared Loki client.
