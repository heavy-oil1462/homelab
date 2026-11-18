---
name: service-logs
description: Read service and system logs from the homelab hosts via Loki, instead of SSHing in. Use to view logs for a service or container, filter by severity, search messages, or see which units have been logging. Logs are the systemd journal shipped by fluent-bit.
---

# Service logs

Read-only access to the systemd-journal logs collected in Loki, so you can
read service logs without SSHing into a host. Every server ships its journal
via fluent-bit under `job="systemd-journal"` with a `host` label, a `unit`
label (`_SYSTEMD_UNIT`) and, for container lines, a `container` label
(`CONTAINER_NAME`). Each line is the journal record as JSON, so the syslog
identifier, priority and message are fields inside it.

## Scripts

Fetch logs, filtered:

```
python3 "${CLAUDE_SKILL_DIR}/get_logs.py" [--host H] [-u UNIT | -c CONTAINER | -s SERVICE] [--since 2h] [--level warning] [--grep REGEX] [--limit N]
```

- `--host`: limit to one host by hostname (omit for all; the host-metrics
  skill lists the hostnames).
- `-u/--unit`: the exact systemd unit (`-u restic-backups-forgejo.service`,
  `-u podman-caddy.service`). Selected by the `unit` label, so Loki reads
  only that unit's lines. Prefer it when you know the name.
- `-c/--container`: the exact container name (`-c vaka`), by the `container`
  label likewise.
- `-s/--service`: case-insensitive substring matched against the systemd unit,
  the syslog identifier, and the container name (e.g. `-s caddy`, `-s restic`).
  It parses every line of the window, so on a busy host a long window is
  slow; use it to find a name, then `-u` or `-c`.
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
python3 "${CLAUDE_SKILL_DIR}/get_logs.py" -u restic-backups-vaultwarden.service --since 1d

# Everything the vaka container logged on one host today
python3 "${CLAUDE_SKILL_DIR}/get_logs.py" --host myserver -c vaka --since 1d

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
- `unit` and `container` are labels only on lines shipped since the logging
  agent set them (`modules/logging-agent.nix`); older streams have only
  `job` and `host`. `-u` and `-c` also query those with a `| json` field
  filter, so a window reaching back before the change still finds them.
  Writing LogQL by hand, select `{host="h", container="vaka"}` or
  `{host="h", unit="sshd.service"}`; `| json` still works on every line.
  Kernel lines have no unit, so no `unit` label.
- The Loki endpoint resolves from HOMELAB_LOKI_URL, else a
  .claude/homelab-endpoints.json found upward from the current directory,
  else ~/.claude/homelab-endpoints.json (see lib/homelab/config.py at the
  plugin root). Logic lives in lib/homelab/logs.py on the shared Loki client.
