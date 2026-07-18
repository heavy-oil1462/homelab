"""Minimal read-only client for the Loki HTTP API.

Reused by the service-logs skill. Read-only: it only calls the query and
label endpoints, and uses the standard library only.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request
from typing import Any

from . import config


class LokiError(RuntimeError):
    """Raised when a Loki query cannot be completed."""


class LokiClient:
    def __init__(self, base_url: str | None = None, timeout: float | None = None):
        base = base_url or config.LOKI_URL
        if not base:
            raise LokiError("no Loki endpoint configured; " + config.HELP)
        self.base_url = base.rstrip("/")
        self.timeout = timeout if timeout is not None else config.HTTP_TIMEOUT

    def query_range(
        self, query: str, since_seconds: float = 3600, limit: int = 200, direction: str = "backward"
    ) -> dict[str, Any]:
        """Run a range query over the last since_seconds and return the data block."""
        end = int(time.time() * 1e9)
        start = int((time.time() - since_seconds) * 1e9)
        return self._get(
            "/loki/api/v1/query_range",
            {
                "query": query,
                "start": str(start),
                "end": str(end),
                "limit": str(limit),
                "direction": direction,
            },
        )

    def query(self, query: str) -> dict[str, Any]:
        """Run an instant query (used for metric queries like count_over_time)."""
        return self._get("/loki/api/v1/query", {"query": query})

    def label_values(self, label: str, since_seconds: float = 3600) -> list[str]:
        start = int((time.time() - since_seconds) * 1e9)
        data = self._get(f"/loki/api/v1/label/{label}/values", {"start": str(start)})
        return data or []

    def _get(self, path: str, params: dict[str, str]) -> Any:
        url = self.base_url + path + "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = json.load(resp)
        except Exception as exc:
            raise LokiError(f"request to {url} failed: {exc}") from exc
        if payload.get("status") != "success":
            raise LokiError(f"query failed: {payload.get('error', payload)}")
        return payload["data"]
