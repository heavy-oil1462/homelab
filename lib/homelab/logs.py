"""Service-log helpers built on Loki (the systemd-journal stream).

Logs are shipped as journal JSON, so service identity (_SYSTEMD_UNIT,
SYSLOG_IDENTIFIER, CONTAINER_NAME), PRIORITY, and MESSAGE are fields inside
each line rather than Loki labels. These helpers build the LogQL to filter on
those fields and parse the lines for display.
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


def build_query(
    host: str | None = None,
    service: str | None = None,
    priority: int | None = None,
    grep: str | None = None,
) -> str:
    """Build a LogQL query against the systemd-journal stream.

    service is matched case-insensitively as a substring against the unit, the
    syslog identifier, and the container name. priority keeps lines at that
    severity or worse (PRIORITY <= n). grep is a case-insensitive regex on the
    message text.
    """
    selectors = ['job="systemd-journal"']
    if host:
        selectors.append(f'host="{_escape(host)}"')
    query = "{" + ", ".join(selectors) + "} | json"
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
) -> list[dict[str, Any]]:
    """Return parsed log lines (chronological) matching the filters."""
    client = client or LokiClient()
    data = client.query_range(
        build_query(host, service, priority, grep), since_seconds=since_seconds, limit=limit
    )
    rows: list[dict[str, Any]] = []
    for stream in data.get("result", []):
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
    return rows


def list_services(
    host: str | None = None, since_seconds: float = 3600, client: LokiClient | None = None
) -> list[dict[str, Any]]:
    """Return units that have logged in the window, with line counts (descending)."""
    client = client or LokiClient()
    selectors = ['job="systemd-journal"']
    if host:
        selectors.append(f'host="{_escape(host)}"')
    sel = "{" + ", ".join(selectors) + "}"
    window = f"{int(since_seconds)}s"
    expr = f"sum by (_SYSTEMD_UNIT) (count_over_time({sel} | json [{window}]))"
    data = client.query(expr)
    rows = []
    for series in data.get("result", []):
        unit = series.get("metric", {}).get("_SYSTEMD_UNIT", "")
        if not unit:
            continue
        rows.append({"unit": unit, "count": int(float(series["value"][1]))})
    rows.sort(key=lambda r: r["count"], reverse=True)
    return rows
