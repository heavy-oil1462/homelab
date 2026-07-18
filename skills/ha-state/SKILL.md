---
name: ha-state
description: Inspect Home Assistant entity state (availability, area, domain, battery, sensor values, lock/light state) by querying the Prometheus exporter. Use when asked about HA devices, what is unavailable, an entity's current value, battery levels, or to build an inventory of entities by area.
---

# Home Assistant state

Read-only inspection of Home Assistant entities via the Prometheus exporter
(the hass_ metrics from the home-assistant scrape job). No HA token is
needed; this reads the metrics endpoint. It works at the entity level: HA
device grouping is not exposed by the exporter.

## Scripts

List every entity with area, domain, friendly name, and availability:

```
python3 "${CLAUDE_SKILL_DIR}/get_entities.py" [--json] [--area AREA] [--domain DOMAIN] [--unavailable]
```

- `--area` filters by area substring (e.g. `--area kitchen`).
- `--domain` filters by HA domain (`light`, `sensor`, `lock`, `automation`, ...).
- `--unavailable` shows only entities that are currently unavailable.
- `--json` emits structured JSON instead of the grouped text table.

Show the full exported state of one entity (by exact id or a name substring):

```
python3 "${CLAUDE_SKILL_DIR}/get_entity.py" <entity_id-or-name> [--json]
```

If the term matches several entities it lists the candidates instead of guessing.

## Configuration

The Prometheus endpoint resolves from HOMELAB_PROM_URL, else a
.claude/homelab-endpoints.json found upward from the current directory, else
~/.claude/homelab-endpoints.json (see lib/homelab/config.py at the plugin
root). The shared client lives in lib/homelab and is reused by the other
homelab skills.
