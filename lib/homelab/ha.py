"""Home Assistant helpers built on the Prometheus exporter (hass_ metrics).

These read entity-level state: availability, area, domain, friendly name, and
whatever value metrics HA exports for an entity. HA's device grouping is not
exposed by the exporter, so this works at the entity level; an HA REST or
WebSocket backend can be added later for device grouping and attributes.
"""
from __future__ import annotations

from typing import Any

from .prometheus import PrometheusClient


def _label(series: dict[str, Any], key: str, default: str = "") -> str:
    return series.get("metric", {}).get(key, default)


def list_entities(client: PrometheusClient | None = None) -> list[dict[str, Any]]:
    """Return every HA entity with its area, domain, friendly name, and availability.

    Joins hass_entity_available (the per-entity availability series, which also
    carries friendly_name and domain labels) with hass_entity_info (which maps
    each entity to its area). Sorted by area, then domain, then entity id.
    """
    client = client or PrometheusClient()
    avail = client.query("hass_entity_available")
    info = client.query("hass_entity_info")
    area_by_entity = {_label(s, "entity"): _label(s, "area") for s in info}

    out: list[dict[str, Any]] = []
    for s in avail:
        entity = _label(s, "entity")
        out.append(
            {
                "entity": entity,
                "friendly_name": _label(s, "friendly_name"),
                "domain": _label(s, "domain"),
                "area": area_by_entity.get(entity, ""),
                "available": float(s["value"][1]) == 1.0,
            }
        )
    # Entities without an area sort last (the "~" sentinel beats real names).
    out.sort(key=lambda e: (e["area"] or "~", e["domain"], e["entity"]))
    return out


def find_entities(needle: str, client: PrometheusClient | None = None) -> list[dict[str, Any]]:
    """Return entities whose id or friendly name contains needle (case-insensitive)."""
    needle_l = needle.lower()
    return [
        e
        for e in list_entities(client)
        if needle_l in e["entity"].lower() or needle_l in e["friendly_name"].lower()
    ]


def entity_state(entity: str, client: PrometheusClient | None = None) -> dict[str, Any]:
    """Return all hass_ value metrics exported for a single entity id.

    Selects every hass_ series carrying the given entity label, which is the
    closest thing the exporter offers to "the current state" of one entity.
    """
    client = client or PrometheusClient()
    # entity ids do not contain double quotes, so simple interpolation is safe.
    series = client.query('{__name__=~"hass_.+", entity="%s"}' % entity)
    metrics = []
    for s in series:
        metrics.append(
            {
                "metric": _label(s, "__name__"),
                "value": s["value"][1],
                "labels": {
                    k: v
                    for k, v in s.get("metric", {}).items()
                    if k not in ("__name__", "entity", "instance", "job")
                },
            }
        )
    metrics.sort(key=lambda m: m["metric"])
    return {"entity": entity, "metrics": metrics}
