"""Minimal read-only client for the Prometheus HTTP API.

Reused by every skill that reads metrics: Home Assistant entity state today,
per-host node_exporter metrics later. Read-only by design, it only calls the
query endpoints, and it uses the standard library only (no pip deps).
"""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
from typing import Any

from . import config


class PrometheusError(RuntimeError):
    """Raised when a Prometheus query cannot be completed."""


class PrometheusClient:
    def __init__(self, base_url: str | None = None, timeout: float | None = None):
        base = base_url or config.PROM_URL
        if not base:
            raise PrometheusError("no Prometheus endpoint configured; " + config.HELP)
        self.base_url = base.rstrip("/")
        self.timeout = timeout if timeout is not None else config.HTTP_TIMEOUT

    def query(self, expr: str) -> list[dict[str, Any]]:
        """Run an instant query and return the list of result series."""
        return self._get("/api/v1/query", {"query": expr})

    def query_range(self, expr: str, start: str, end: str, step: str) -> list[dict[str, Any]]:
        """Run a range query and return the list of result series."""
        return self._get(
            "/api/v1/query_range",
            {"query": expr, "start": start, "end": end, "step": step},
        )

    def _get(self, path: str, params: dict[str, str]) -> list[dict[str, Any]]:
        url = self.base_url + path + "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = json.load(resp)
        except Exception as exc:  # network, HTTP, or decode error
            raise PrometheusError(f"request to {url} failed: {exc}") from exc
        if payload.get("status") != "success":
            raise PrometheusError(f"query failed: {payload.get('error', payload)}")
        return payload["data"]["result"]
