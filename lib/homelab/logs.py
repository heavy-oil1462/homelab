"""Service-log helpers built on Loki (the systemd-journal stream).

Logs are shipped as journal JSON. Each line's stream carries the labels
job, host and, since the logging agent labels them, unit (_SYSTEMD_UNIT)
and container (CONTAINER_NAME) where the record has them. Everything else,
SYSLOG_IDENTIFIER, PRIORITY and MESSAGE included, is a field inside the
line. These helpers build the LogQL to select and filter on those and parse
the lines for display.

Streams written before the agent labelled them have only job and host. A
query by unit or container therefore runs twice: once on the label, which
reads only that stream, and once on the streams without the label, parsing
their lines with `| json`. The second is cheap once the old streams have
aged out, as the only unlabelled lines left are those without the field.
"""
from __future__ import annotations

import json
from typing import Any

from .loki import LokiClient

# syslog priority number to name (lower is more severe).
PRIORITY_NAMES = {
    0: "emerg",
    1: "alert",
    2: "crit",
    3: "err",
    4: "warning",
    5: "notice",
    6: "info",
    7: "debug",
}
LEVEL_TO_PRIORITY = {v: k for k, v in PRIORITY_NAMES.items()}


def _escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


# The labels the logging agent sets from journal fields.
LABEL_FIELDS = {"unit": "_SYSTEMD_UNIT", "container": "CONTAINER_NAME"}


def build_queries(
    host: str | None = None,
    service: str | None = None,
    priority: int | None = None,
    grep: str | None = None,
    unit: str | None = None,
    container: str | None = None,
) -> list[str]:
    """Build the LogQL queries against the systemd-journal stream.

    unit and container are exact names (podman-caddy.service, caddy). Given
    either, the result is two queries whose lines together are the answer:
    one selecting on the labels, and one for the streams written before the
    labels existed, matching the fields with `| json`. Otherwise it is one.
    See build_query for the other filters.
    """
    exact = {k: v for k, v in (("unit", unit), ("container", container)) if v}
    if not exact:
        return [build_query(host, service, priority, grep)]
    labelled = {k: f'"{_escape(v)}"' for k, v in exact.items()}
    # The streams written before the labels lack unit; Loki takes a missing
    # label as equal to "". Of the new ones only lines without a unit lack
    # it, as kernel lines do; container lines have their podman-<name>
    # service's.
    unlabelled = {"unit": '""'}
    fields = {LABEL_FIELDS[k]: v for k, v in exact.items()}
    return [
        build_query(host, service, priority, grep, labels=labelled),
        build_query(host, service, priority, grep, labels=unlabelled, fields=fields),
    ]


def build_query(
    host: str | None = None,
    service: str | None = None,
    priority: int | None = None,
    grep: str | None = None,
    labels: dict[str, str] | None = None,
    fields: dict[str, str] | None = None,
) -> str:
    """Build a LogQL query against the systemd-journal stream.

    service is matched case-insensitively as a substring against the unit, the
    syslog identifier, and the container name. priority keeps lines at that
    severity or worse (PRIORITY <= n). grep is a case-insensitive regex on the
    message text. labels are further stream selectors, name to quoted value;
    fields are journal fields the line must have, exactly.
    """
    selectors = ['job="systemd-journal"']
    if host:
        selectors.append(f'host="{_escape(host)}"')
    selectors += [f"{k}={v}" for k, v in (labels or {}).items()]
    query = "{" + ", ".join(selectors) + "} | json"
    for k, v in (fields or {}).items():
        query += f' | {k}="{_escape(v)}"'
    if service:
        s = _escape(service)
        query += (
            f' | _SYSTEMD_UNIT=~"(?i).*{s}.*" '
            f'or SYSLOG_IDENTIFIER=~"(?i).*{s}.*" '
            f'or CONTAINER_NAME=~"(?i).*{s}.*"'
        )
    if priority is not None:
        query += f' | PRIORITY <= {int(priority)}'
    if grep:
        query += f' | MESSAGE=~"(?i){_escape(grep)}"'
    return query


def fetch_logs(
    host: str | None = None,
    service: str | None = None,
    since_seconds: float = 3600,
    limit: int = 200,
    priority: int | None = None,
    grep: str | None = None,
    client: LokiClient | None = None,
    unit: str | None = None,
    container: str | None = None,
) -> list[dict[str, Any]]:
    """Return parsed log lines (chronological) matching the filters.

    With unit or container, the latest limit lines of the labelled and the
    unlabelled streams together.
    """
    client = client or LokiClient()
    streams: list[dict[str, Any]] = []
    for query in build_queries(host, service, priority, grep, unit, container):
        data = client.query_range(query, since_seconds=since_seconds, limit=limit)
        streams += data.get("result", [])
    rows: list[dict[str, Any]] = []
    for stream in streams:
        stream_host = stream.get("stream", {}).get("host")
        for ts, line in stream["values"]:
            try:
                d = json.loads(line)
            except (ValueError, TypeError):
                d = {"MESSAGE": line}
            pr = d.get("PRIORITY")
            rows.append(
                {
                    "ns": int(ts),
                    "host": d.get("_HOSTNAME") or stream_host,
                    "unit": d.get("_SYSTEMD_UNIT")
                    or d.get("SYSLOG_IDENTIFIER")
                    or d.get("CONTAINER_NAME")
                    or "?",
                    "priority": int(pr) if isinstance(pr, str) and pr.isdigit() else None,
                    "message": d.get("MESSAGE", ""),
                }
            )
    rows.sort(key=lambda r: r["ns"])
    return rows[-limit:] if limit > 0 else rows


def list_services(
    host: str | None = None, since_seconds: float = 3600, client: LokiClient | None = None
) -> list[dict[str, Any]]:
    """Return units that have logged in the window, with line counts (descending).

    Counts the unit label's streams without reading their lines, and adds
    the units of streams without the label, from their parsed lines.
    """
    client = client or LokiClient()
    selectors = ['job="systemd-journal"']
    if host:
        selectors.append(f'host="{_escape(host)}"')
    window = f"{int(since_seconds)}s"
    labelled = "{" + ", ".join(selectors + ['unit!=""']) + "}"
    unlabelled = "{" + ", ".join(selectors + ['unit=""']) + "}"
    counts: dict[str, int] = {}
    for expr, key in (
        (f"sum by (unit) (count_over_time({labelled} [{window}]))", "unit"),
        (f"sum by (_SYSTEMD_UNIT) (count_over_time({unlabelled} | json [{window}]))", "_SYSTEMD_UNIT"),
    ):
        for series in client.query(expr).get("result", []):
            unit = series.get("metric", {}).get(key, "")
            if not unit:
                continue
            counts[unit] = counts.get(unit, 0) + int(float(series["value"][1]))
    rows = [{"unit": u, "count": c} for u, c in counts.items()]
    rows.sort(key=lambda r: r["count"], reverse=True)
    return rows
