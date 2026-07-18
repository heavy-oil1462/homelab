"""Central configuration for the homelab toolkit.

Nothing site-specific is baked in. Each endpoint resolves at import, first
hit wins:

1. Environment variables: HOMELAB_PROM_URL, HOMELAB_LOKI_URL,
   HOMELAB_HTTP_TIMEOUT.
2. A .claude/homelab-endpoints.json found by walking up from the current
   directory (commit one in your private config repo). Flat JSON:
   {"prom_url": "https://metrics.example.com",
    "loki_url": "https://logs.example.com",
    "http_timeout": 10}
3. ~/.claude/homelab-endpoints.json as a user-wide fallback.

Unresolved values stay None; the HTTP clients raise a clear error at
construction, so imports and --help keep working without configuration.
"""
import json
import os
import pathlib


def _load_endpoints_file() -> dict:
    cwd = pathlib.Path.cwd()
    candidates = [p / ".claude" / "homelab-endpoints.json" for p in [cwd, *cwd.parents]]
    candidates.append(pathlib.Path.home() / ".claude" / "homelab-endpoints.json")
    for path in candidates:
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            return data
    return {}


_FILE = _load_endpoints_file()

# One-line remediation hint used by the client error messages.
HELP = (
    "set HOMELAB_PROM_URL / HOMELAB_LOKI_URL, or provide "
    ".claude/homelab-endpoints.json in the project (found by walking up "
    "from the current directory) or at ~/.claude/homelab-endpoints.json"
)

# Prometheus HTTP API base (None when unconfigured).
PROM_URL = os.environ.get("HOMELAB_PROM_URL") or _FILE.get("prom_url")

# Loki HTTP API base (None when unconfigured).
LOKI_URL = os.environ.get("HOMELAB_LOKI_URL") or _FILE.get("loki_url")

# Default HTTP timeout in seconds for read queries.
HTTP_TIMEOUT = float(os.environ.get("HOMELAB_HTTP_TIMEOUT") or _FILE.get("http_timeout") or 10)
