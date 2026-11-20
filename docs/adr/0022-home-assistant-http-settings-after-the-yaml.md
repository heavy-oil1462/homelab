# ADR-0022: Home Assistant's HTTP settings after the YAML

Status: Accepted

## Context

The homeassistant module mounts the consumer's `configuration.yaml`, and
its `http:` block set the reverse proxy settings, `use_x_forwarded_for`
and `trusted_proxies`. Since 2026.8 Home Assistant takes that block over
into `.storage/http` on its first start and ignores it afterwards; 2027.2
drops it (`breaks_in_ha_version="2027.2.0"`). From then on the settings
live in Home Assistant's network settings and its store, which goes
against "services are configured from Nix" (DIRECTION.md, ADR-0010).

`components/http/config.py` at 2026.11.1, nixpkgs' Home Assistant at our
pin and the release the image pins (2026.11.2), keeps the store this way:

- `.storage/http` is a `Store` file, key `http`, version 3, minor version
  1, written privately and atomically. Its data has a `stable` slot, the
  config Home Assistant applies on start; a `pending` slot, a config the
  network settings stage for a trial of five minutes, after which Home
  Assistant restarts with `stable` unless the user confirmed it; and
  `yaml_migration_done`.
- Loading the store does not run the slots through the schema. `stable`
  is applied as stored, with no trial: the store is the source of truth
  and Home Assistant does not track who wrote it. A config that cannot be
  applied, such as an invalid network in `trusted_proxies`, fails at
  server start instead.
- Older versions are migrated on load. A version 1 file is a plain config,
  which the migration runs through the storage schema, filling in every
  default, as the `stable` slot.
- With no `http:` block in the YAML, Home Assistant marks the YAML as
  taken over and keeps the store as it is. With a block, before the
  takeover, the block becomes a pending trial whenever it differs from
  `stable`.

Three ways were weighed:

1. A oneshot unit, before the container starts, that merges the two
   settings from Nix options into `.storage/http`.
2. Home Assistant's websocket API after it starts (`http/update_config`),
   with a long-lived token. That needs a token secret the owner creates in
   the UI, and the change is staged as pending: it applies only after a
   restart and a confirmation within five minutes, or Home Assistant
   reverts it.
3. Leaving the settings to the network settings, as an owner step.

## Decision

The module merges the settings into the store before Home Assistant
starts (option 1).

- `homelab.homeassistant.trustedProxies`, a list of addresses or
  networks, default null. Set, the module adds the `home-assistant-http`
  unit, a oneshot wanted by and ordered before `podman-home-assistant`, so
  it runs on every start of the container. It finds the
  `homeassistant-config` volume through podman, creating it on a new host,
  and runs `modules/homeassistant-http.py` on its `.storage/http`.
- The tool sets `trusted_proxies`, normalised as Home Assistant's own
  schema does and refused if invalid, and `use_x_forwarded_for`, true when
  the list is not empty, in the `stable` slot and in the `pending` slot if
  there is one, so a trial from the UI cannot change them. Every other
  key, the slots' other settings and `yaml_migration_done`, stays as Home
  Assistant left it. A file that would not change is not written.
- With no store yet, the tool writes a version 1 file with only the two
  settings; Home Assistant migrates it on start through its own schema, so
  the module never copies Home Assistant's defaults.
- A store of another key or of a version the tool does not know (above 3)
  is left alone: the unit fails, which the failed unit alert reports, and
  Home Assistant starts with the settings it has. A new major version
  needs the tool reviewed with the image bump.
- A change of the option restarts the container, through its restart
  triggers; Home Assistant reads the store only when it starts.
- With the option set, a `configurationFile` that still has an `http:`
  block fails the build: Home Assistant would take it over as a trial on
  a new host and ignore it on an old one, and 2027.2 refuses it.

The websocket API is rejected: it needs a long-lived token the owner makes
by hand, Home Assistant must be running and restarted, and every change
is a trial a person has to confirm. Leaving the settings to the UI is the
gap DIRECTION.md says to close.

## Consequences

- The reverse proxy settings are declared in Nix, before and after
  2027.2, with no secret and no new image; the example's
  `configuration.yaml` has no `http:` block.
- Other HTTP settings (port, CORS origins, SSL, login attempts, IP bans)
  stay in Home Assistant's network settings and store. They can be made
  options of the same tool later if a host needs them.
- A change to the two settings in the UI holds until the container next
  starts, when the tool sets them back. A restart from within Home
  Assistant keeps the container running and does not run the tool.
- The tool depends on the store's layout, which is Home Assistant's own
  and not an API. The `homeassistant-http` check starts nixpkgs' Home
  Assistant on the files the tool writes: with no store, after settings
  changed in the slots, and with no proxy, a trusted proxy's
  X-Forwarded-For is used and an untrusted one gets 400. It runs the Home
  Assistant of `flake.lock`, not the image's: a bump of the image to a new
  storage version passes the check until nixpkgs follows, and the unit
  failing on the unknown version is what shows it.
- Consumers who set the option remove the `http:` block from their
  `configuration.yaml`. Nothing new to provision.
