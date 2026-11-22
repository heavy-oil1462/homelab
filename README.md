# homelab

Reusable NixOS modules for a container-based homelab. Services run as pinned
OCI containers under podman, sites are published tailnet-only through a Caddy
reverse proxy with ACME DNS-01 certificates, and hosts ship logs and metrics
to a Loki/Prometheus/Grafana stack. A workstation role provides a Hyprland
desktop, YubiKey login, and a sandboxed environment for AI coding agents.

Everything personal (domain, user, keys, service configs) is injected through
a typed `homelab.*` options namespace, so this repo contains no site-specific
values. You keep those in your own (typically private) config repo and
consume this one as a flake input.

## Usage

```nix
inputs.homelab.url = "github:heavy-oil1462/homelab";
```

Import the modules a host needs and set the options:

```nix
modules = [
  homelab.nixosModules.common
  homelab.nixosModules.server-role
  homelab.nixosModules.reverse-proxy
  {
    homelab = {
      username = "alice";
      domain = "home.example.com";
      adminKeys = [ "ssh-ed25519 AAAA... alice@laptop" ];
      tailnetIp = "100.64.0.1";
      reverseProxy.caddyfile = ./assets/Caddyfile;
      reverseProxy.notFoundPage = ./assets/404.html;
    };
  }
]
```

See `examples/` for a full server host, a workstation host, a VM host on a
disko layout, and a consumer flake. `examples/assets/` holds commented
starting points for every config file a module consumes (Caddyfile, Frigate,
Prometheus, homepage, Home Assistant, Hyprland). All example IPs are from
RFC 5737 documentation ranges.

## Modules

Roles:

- `server-role`: headless VM baseline (grub, DHCP, podman, tailscale,
  node exporter, fluent-bit log shipping, tailnet-only SSH, and break-glass
  SSH from the LAN with `homelab.network.sshFrom`, see [SSH access](#ssh-access)).
- `workstation-role`: Hyprland desktop, greetd/tuigreet, pipewire, YubiKey
  login, libvirt, and the agent sandbox.

Services (OCI containers, pinned by digest):

- `reverse-proxy`: Caddy. With `homelab.tailnetIp` set, 443 binds to the
  tailnet address only, which makes every site tailnet-only.
  With `homelab.reverseProxy.tailscaleIdentity.enable`, sites that
  `import tailnet_identity` (example Caddyfile) pass the tailnet user's login
  name to their upstream as `Remote-User`, looked up through tailscale's
  nginx-auth. Client-sent identity headers are always deleted, and requests
  with an `Authorization` header pass without an identity. It turns off
  tailscale's subnet-route SNAT, so don't enable it on a subnet router or
  exit node (docs/adr/0003-tailscale-identity-for-sign-in.md).
  Caddy runs as the caddy user (606), with NET_BIND_SERVICE only; the
  certificate's group and the identity socket's are `caddy`.
  The caddy container has the fixed address `homelab.reverseProxy.address`
  (10.88.255.2) on podman's default network. With Forgejo's or Grafana's
  proxy authentication on, it also defines `forgejo_identity` and
  `grafana_identity`, which include `tailnet_identity` and map the login to
  the service's user (docs/adr/0005-proxy-auth-only-from-caddy.md).
  With `homelab.reverseProxy.oidcGate.enable`, sites that cannot sign
  anyone in themselves get a login gate: nixpkgs' oauth2-proxy runs on a
  socket only Caddy mounts, and sites that `import oidc_owner_only` (the
  `owners`) or `oidc_gate` (`owners` and `users`, Pocket ID usernames)
  send a browser without a session to sign in at Pocket ID, pass the
  username on as `Remote-User`, and sign out at `/oauth2/sign_out`. One
  sign-in covers every gated site under `homelab.domain` for 24 hours
  (`sessionLifetime`), renewed with Pocket ID every 30 minutes. Its client
  is declared in `homelab.pocketId.clients`, as the example server does
  (docs/adr/0020-oidc-login-gate-at-the-proxy.md).
- `observability`: Prometheus, Loki, Grafana with provisioned datasources,
  dashboards and alerting. A blackbox exporter on the host probes the HTTPS
  URLs in `homelab.observability.probeTargets` through Caddy, as clients
  reach them; it listens on the podman bridge only. The host must resolve the
  site names to Caddy's tailnet address (with Tailscale DNS, a split-DNS
  record for the domain). `examples/assets/grafana-alerting.yaml` alerts on
  failed units, failed backups, backups with no success in 36 hours or
  none at all, containers with a fixable critical or high vulnerability
  for a day and images not scanned in 3 days (the `vulnerability-scan`
  module), full disks, hosts that are down,
  certificates that expire within 14 days and sites that are down or serve
  an invalid certificate, through one placeholder contact point. The
  example dashboard `gpu.json` shows GPU load per instance from the NVIDIA
  GPU exporters listed in `homelab.observability.nvidiaGpuTargets`, which
  Prometheus reads from `/etc/prometheus/nvidia-gpu-targets.json` through
  the example's nvidia-gpu job. Grafana
  gives anyone who reaches it anonymous Admin access, unless
  `homelab.observability.grafanaProxyAuth.enable` is set: then only the
  tailnet logins in `homelab.observability.grafanaProxyAuth.admins` sign in,
  as Admin, through a status site that imports `grafana_identity`, and
  Grafana trusts `Remote-User` only from Caddy's address. With
  `homelab.observability.grafanaOidc.enable` instead, Grafana signs in
  through Pocket ID (the `pocket-id` module): the users in
  `homelab.observability.grafanaOidc.admins`, by Pocket ID email, get
  Admin, everyone else is refused. Its client has the redirect URI
  `https://status.<domain>/login/generic_oauth`; declared in
  `homelab.pocketId.clients` with owner `grafana` and
  `podman-grafana.service` among its units, as `examples/server.nix`
  does, Pocket ID writes its id and secret to
  `/var/lib/secrets/grafana-oidc-client-id` and
  `/var/lib/secrets/grafana-oidc-client-secret`. Grafana also finds an
  existing user by email, so a switch from another sign in keeps the
  owner's user, and needs Pocket ID's own-account editing off
  (docs/adr/0019-forgejo-and-grafana-on-pocket-id.md). Dashboards in
  `homelab.observability.dashboardsDir` are provisioned read-only into the
  Homelab folder and change with a rebuild. With
  `homelab.observability.grafanaGitSync`, Grafana's Git Sync keeps a
  folder of dashboards in step with a directory of a Forgejo repository,
  both ways: a change pushed to the branch shows in Grafana within a
  minute, and a dashboard saved in Grafana is committed to the branch. The
  `grafana-git-sync` unit sets the repository up in Grafana through its
  API, with a Forgejo token, and makes the Grafana service account and
  token it calls the API with when it has none
  (docs/adr/0012-git-sync-service-account-made-by-the-host.md). The
  repository must let Grafana push to the branch, so it is not a protected
  one. With `grafanaGitSync.seed`, a directory of dashboards, the unit
  first commits them to a repository that has no commits yet, once, and
  leaves any repository with history alone; `examples/assets/git-sync-seed`
  is a starting point. See [docs/dashboards.md](docs/dashboards.md)
  (docs/adr/0009-dashboards-through-grafana-git-sync.md,
  docs/adr/0011-git-sync-seeds-an-empty-repository.md).
- `vaultwarden`, `homepage` (runs as the homepage user, with the files it
  writes itself in the volumes `homepage-config` and `homepage-cache`).
- `homeassistant`: runs as root, with host networking; its state is the
  `homeassistant-config` volume, mounted at `/config`. Upgrading from
  2026.6 or earlier to 2026.11 migrates `/config/.storage` one way: the
  device registry moves to a storage version the older release cannot
  read. Back up first (an HA backup, or a copy of `/config`); to go back,
  restore `/config/.storage` from that backup along with the older pin.
  The recorder database is unchanged. From 2026.8, Home Assistant keeps
  its HTTP settings in `.storage/http` and reads the `http:` block of
  `configuration.yaml` only once; 2027.2 drops the block. Set the reverse
  proxies in `homelab.homeassistant.trustedProxies` instead and remove the
  block: the `home-assistant-http` unit writes them, with
  `use_x_forwarded_for`, into the store before every start of the
  container, keeps the other settings stored there, and needs no trial.
  The module refuses an `http:` block while the option is set. Changes
  to the proxies in the network settings last until the container next
  starts (docs/adr/0022-home-assistant-http-settings-after-the-yaml.md).
  Automations that use a trigger
  renamed in 2026.7 stop working until edited; they show under Repairs.
- `nextcloud`: Nextcloud All-in-One mastercontainer, pinned by digest. Its
  admin UI (8080) and the Apache container it starts (11000) bind to
  `homelab.nextcloud.bindAddress`, the tailnet address by default. To reach
  them from the LAN, set it to a LAN address (or `"0.0.0.0"`) and open the
  ports in the host's firewall. AIO updates the containers it manages from
  its UI when you ask it to; the AIO version itself changes with the pin.
- `nvr`: Frigate with GPU detection, recordings on `/surveillance`, state in
  `/var/lib/frigate`. Camera credentials (FRIGATE_* variables the config
  expands) come from `/var/lib/secrets/frigate.env`. Hosts that still have
  the old `/etc/secrets/frigate.env` get it copied over on the next start;
  remove the old file once Frigate works. It gets the GPU through the
  NVIDIA container toolkit's CDI spec; list `podman-frigate` in
  `homelab.nvidia.cdiCheck.units`, as `examples/server.nix` does, so it
  checks the spec before every start (docs/nvidia.md).
- `unifi`: UniFi Network controller (linuxserver image) with its own
  MongoDB container (auth enabled). Expects MONGO_INITDB_ROOT_USERNAME,
  MONGO_INITDB_ROOT_PASSWORD, MONGO_USER and MONGO_PASS in
  `/var/lib/secrets/unifi.env` at runtime.
- `registry`: private OCI image registry (Docker Official `registry` image,
  CNCF Distribution) for your own images, published through the reverse
  proxy. Every pull and push needs a login from a bcrypt htpasswd file at
  `/var/lib/secrets/registry.htpasswd` at runtime.
- `forgejo`: Forgejo git forge (rootless image, SQLite) at git.<domain>
  through the reverse proxy, with its built in SSH server published on the
  tailnet address, port 2222 (`homelab.forgejo.sshAddress`,
  `homelab.forgejo.sshPort`), Actions enabled and registration closed. Site
  specific settings go in `homelab.forgejo.extraEnvironment` as
  FORGEJO__section__KEY values. Expects a secret key at
  `/var/lib/secrets/forgejo-secret-key` at runtime (for example
  `openssl rand -hex 32`, owned by forgejo, mode 0400); Forgejo does not
  start while it is empty.
  With `homelab.forgejo.admin.name` and `homelab.forgejo.admin.email` set,
  the `forgejo-admin` unit creates that admin once Forgejo answers, if it
  has no admin yet, and safely does nothing on later boots. Its one-time
  password is only in one line of the unit's journal, with the sign in URL,
  https://git.<domain>/user/login:
  `journalctl -u forgejo-admin`. Forgejo asks for a new password at the
  first sign in; add a passkey after that. Unset, the admin is created by
  hand as the module's header comment shows. The module does not back
  itself up; add a backup job on the host, as `examples/server.nix` does:
  `homelab.backups.jobs.forgejo` with path `/var/lib/forgejo` and database
  `/var/lib/forgejo/data/gitea.db`.
  With `homelab.forgejo.proxyAuth.enable`, the tailnet logins in
  `homelab.forgejo.proxyAuth.users` sign in to the web UI as the Forgejo
  user they map to, through a git site that imports `forgejo_identity`.
  Users are not created on sign in. Forgejo then serves HTTP only on the
  socket `/run/forgejo-http/http.sock`, which the caddy container mounts,
  so the git site proxies to `unix//run/forgejo-http/http.sock` instead of
  `forgejo:3000`. Tokens and git over SSH work as before.
  With `homelab.forgejo.oidc.enable` instead, the web UI signs in through
  Pocket ID (the `pocket-id` module), and Forgejo creates an account on a
  user's first sign in. The `forgejo-oidc` unit adds Pocket ID as the
  sign in source `pocket-id` and restarts Forgejo when it changes; a
  source `tailscale` left from tsidp is updated and renamed in place. Its
  client has the redirect URI
  `https://git.<domain>/user/oauth2/pocket-id/callback`; declared in
  `homelab.pocketId.clients` with `forgejo-oidc.service` among its units,
  Pocket ID writes its id and secret to
  `/var/lib/secrets/forgejo-oidc-client-id` and
  `/var/lib/secrets/forgejo-oidc-client-secret`. An existing account is
  linked on a user's first sign in through Pocket ID once they give its
  password; [docs/pocket-id.md](docs/pocket-id.md) has the steps. A
  service uses proxy authentication or OIDC, never both
  (docs/adr/0019-forgejo-and-grafana-on-pocket-id.md).
  With `homelab.forgejo.trustDeployCa`, the SSH server also accepts user
  certificates signed by `homelab.deployCaKeys`, so the certificate a fleet
  run signs for the hosts fetches from Forgejo too
  (docs/adr/0015-forgejo-trusts-the-deploy-ca.md). A certificate signs in
  as the Forgejo user whose account lists one of its principals, and a user
  may list only their own user name: add it once under Settings, SSH / GPG
  keys, Manage SSH principals. The certificate then carries `root` for the
  hosts and that user name for Forgejo, and the SSH user stays `git`.
  Keep no Forgejo user named `root`: once it listed `root` as its
  principal, every host certificate would sign in as it.
- `agent-sandbox`: a rootless podman sandbox for AI coding agents (Claude
  Code, Antigravity) with per-project state, shared gh/Claude auth, pinned
  commit identity, and an optional personal skills repo synced into every
  session.

System:

- `common` (auto-upgrade, GC, flakes, user, firewall, and the terminfo of
  every common terminal, kitty's included, so ncurses programs work over
  SSH from any of them; `homelab.allTerminfo` turns that off), `openssh` (keys from
  `homelab.adminKeys`), `deploy-ca` (with `homelab.deployCaKeys` set, root
  logs in over SSH only with a certificate signed by one of those CA keys,
  so a fleet update signs one short-lived certificate, with one hardware key
  touch, for every host; `homelab.forgejo.trustDeployCa` lets the same
  certificate reach Forgejo), `acme` (Cloudflare DNS-01), `backups` (restic to any
  rclone remote: Vaultwarden, plus the jobs in `homelab.backups.jobs`, with
  consistent SQLite snapshots, and each job's last successful run as a
  node exporter metric; restoring is in [docs/backups.md](docs/backups.md)),
  `locale`, `yubikey` (pam_u2f with a
  host-independent origin), `firewall` (role-based baseline, and
  SSH from the networks in `homelab.network.sshFrom`), `nvidia` (proprietary driver;
  the host must allow the unfree `nvidia-x11` and `nvidia-settings`, as
  `examples/workstation.nix` does; with `homelab.nvidia.cdiCheck.units`,
  the listed GPU containers check the container toolkit's CDI spec before
  every start and write it again when it mounts another driver, see
  [docs/nvidia.md](docs/nvidia.md)), `vm-disko` (single-disk VM layout; needs
  disko's NixOS module from your own flake, as `examples/vm.nix` shows),
  `tailscale` (joins the tailnet with a one-off auth key at install; with
  the node exporter on, writes the node key's expiry and whether the node
  is online every 5 minutes, see
  [Tailscale key expiry](#tailscale-key-expiry)), `logging-agent` (fluent-bit ships the journal to Loki at
  `homelab.logsHost`; see [Logs](#logs)), `observability-agent` (node exporter with
  the systemd collector, and the textfile collector reading
  `homelab.observabilityAgent.textfileDirectory`; with
  `homelab.observabilityAgent.nvidiaGpu.enable`, also nixpkgs' NVIDIA GPU
  exporter on port 9835, open on `tailscale0` only, which needs the `nvidia`
  module and works on GeForce cards), and the desktop
  modules.
- `vulnerability-scan` (`homelab.vulnerabilityScan.enable`): Trivy, from
  nixpkgs, scans the image of every container in
  `virtualisation.oci-containers.containers` that root's podman runs, once
  a day
  (`homelab.vulnerabilityScan.schedule`), read from the host's podman
  storage with `podman save` and never pulled. Only the save runs as root;
  Trivy runs as a DynamicUser with no capabilities and a read-only system.
  It fetches its vulnerability database from `mirror.gcr.io` (`ghcr.io` as
  fallback) over HTTPS on each run, and keeps the last one when that fails.
  The counts reach Prometheus through the textfile collector, without CVE
  ids: `homelab_image_vulnerabilities{image, container, severity,
  fixable}` per severity (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`) and whether
  a fixed version exists, `homelab_image_scan_success{container}`,
  `homelab_image_scan_timestamp_seconds{container}` and
  `homelab_vulnerability_db_age_seconds`. Each container's full report is
  `/var/lib/vulnerability-scan/<container>.json`; read it on the host as
  root, for example its critical findings with
  `jq '.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL")' /var/lib/vulnerability-scan/caddy.json`,
  or the fixable ones with `select((.FixedVersion // "") != "")`. Run a
  scan now with `systemctl start vulnerability-scan`. While it runs, the
  saved images take about their size in `/var/cache`; an image that would
  leave less than a tenth of that filesystem free, or 5 GiB, is skipped
  and its scan fails. Images built with
  Nix (vaka's) have no package database, so only their Go binaries'
  modules are seen. Containers whose `podman.user` is set to another user
  than root run in that user's rootless podman and are not scanned
  (docs/adr/0017-running-images-are-scanned.md).
- `pocket-id` (`homelab.pocketId`): Pocket ID, the site's OpenID Connect
  provider, with nixpkgs' `services.pocket-id`, at
  `https://<hostName>.<domain>` (`id`), which is also the issuer URL
  (docs/adr/0018-pocket-id-is-the-oidc-provider.md), and the only one:
  tsidp is removed (docs/adr/0023-tsidp-retired-pocket-id-only.md), and
  a host still on it moves as [docs/pocket-id.md](docs/pocket-id.md#moving-off-tsidp)
  says. Users sign in with passkeys; the first run, the
  owner's account and the claims each app matches on are in
  [docs/pocket-id.md](docs/pocket-id.md). It serves only on the socket
  `/run/pocket-id-http/pocket-id.sock`, which the caddy container mounts,
  so it needs the reverse proxy on the same host and a site in the
  Caddyfile, as the example's `id` site. That site imports
  `pocket_id_setup`, generated from `homelab.pocketId.setupLogins`, which
  lets only those tailnet logins reach Pocket ID's first-admin setup and
  needs `homelab.reverseProxy.tailscaleIdentity.enable`. It runs as the `pocket-id` system
  user without capabilities. Its encryption key and admin API key are made
  on the first start in `/var/lib/secrets`. Its SQLite database and
  uploads are in `homelab.pocketId.dataDir` (`/var/lib/pocket-id`); back
  it up with a job that lists `homelab.pocketId.databaseFile` as a SQLite
  database, as `examples/server.nix` does. Clients are declared in
  `homelab.pocketId.clients.<id>` (`redirectUris`, `logoutRedirectUris`,
  `pkce`, `displayName`, `idFile`, `secretFile`, `owner`, `units`): once
  Pocket ID answers, the `pocket-id-clients` unit creates or updates each
  through its admin API, writes its id and the secret Pocket ID makes to
  its files under `/var/lib/secrets`, and restarts its `units`, which
  start after it. Clients added in the admin UI are left alone. Its
  application settings come from the config, with users' own-account
  editing off (`homelab.pocketId.allowOwnAccountEdit`) and a sign-in
  lasting `homelab.pocketId.sessionDuration` minutes (60, Pocket ID's
  default; the example sets 1440, the login gate's 24h); set others in
  `services.pocket-id.settings`. The example declares Forgejo's and Grafana's from their OIDC options once
  their provider is `pocket-id`.

## Logs

`logging-agent` ships each host's journal to Loki. Every line is the journal
record as JSON, so `| json` gives its fields (`MESSAGE`, `PRIORITY`,
`SYSLOG_IDENTIFIER` and the rest). Its stream has the labels:

- `job`: `systemd-journal`;
- `host`: the host name;
- `unit`: the record's `_SYSTEMD_UNIT`, such as `sshd.service`, or
  `podman-vaka.service` for a container's lines;
- `container`: the record's `CONTAINER_NAME`, on a container's lines.

A line without the field gets no label, not an empty one: kernel lines have
no `unit`, host services no `container`. Select by label, so Loki reads
only that stream:

```
{host="h", container="vaka"}
{host="h", unit="restic-backups-forgejo.service"} |= "error"
```

instead of `{host="h"} | json | CONTAINER_NAME="vaka"`, which reads and
parses every line of the host. Lines shipped before the labels existed have
only `job` and `host`, so for those the `| json` filter is still the way;
select them with `unit=""`. The labels are kept to the few units and
containers of a host; message, priority and process ids stay in the line,
as each value of a label is a stream of its own.

## Tailscale key expiry

Servers take SSH on the tailnet only, so a node key that expires cuts the
host off until someone logs it in again at its console, or over SSH from
the LAN where `homelab.network.sshFrom` allows it ([SSH access](#ssh-access)). On every host
with the `tailscale` and `observability-agent` modules, the
`tailscale-metrics` unit reads `tailscale status --json` every 5 minutes,
and at boot once tailscaled has had 2 minutes, and writes for the node
exporter's textfile collector:

- `homelab_tailscale_key_expiry_timestamp_seconds`: when the node key
  expires, as a Unix time; absent when expiry is disabled or the node is
  logged out.
- `homelab_tailscale_key_expiry_disabled`: 1 when expiry is disabled for
  the node, else 0.
- `homelab_tailscale_online`: 1 when the node is logged in and connected
  to the control plane, else 0.

The example rules alert as "Tailscale key expires soon" 14 days ahead, and
as "Tailscale down" after 10 minutes offline. Renew a key on the host with
`tailscale up --force-reauth` while it is still reachable.

Every server has key expiry disabled, a step of joining it to the
tailnet (DIRECTION.md). In the Tailscale admin console, open Machines, the
new machine's `...` menu, and choose Disable key expiry. Nodes logged in
with an auth key carrying tags, as `tailscale` installs them, have expiry
disabled from the start; a node logged in as a user gets the tailnet's key
expiry (180 days unless changed in the settings), so check the machine
there after every join. The alert then only fires for a server this step
was missed on.

## SSH access

Servers take SSH on `tailscale0`, and deploys and admin SSH go over the
tailnet. For when Tailscale is down, such as after a node key expired,
`homelab.network.sshFrom` lists the LAN's admin subnets that may reach
port 22 on any other interface
(docs/adr/0024-break-glass-ssh-from-the-lan.md):

```nix
homelab.network.sshFrom = [ "192.0.2.0/24" ];
```

Login stays keys only: the host refuses to build with password or
keyboard-interactive authentication on, with `PermitRootLogin = "yes"`, or
with an sshd that listens on loopback only (import `openssh`, as the
server role does). A prefix length of 0, such as `0.0.0.0/0` or `::/0`, is
refused. Empty, the default, the firewall is as before.

From a machine in one of those subnets, reach the host by its LAN address,
since MagicDNS names need Tailscale:

```sh
ssh alice@192.0.2.10
```

Then repair Tailscale on the host, for example with `tailscale up` and a
new auth key. Changing who may reach SSH is a change to ask the owner about
first (DIRECTION.md).

## Secrets

Secrets are never part of the configuration: modules reference runtime paths
under `/var/lib/secrets/` that you provision on the host out of band. For the
files containers read, a tmpfiles rule creates an empty file with the right
owner and mode if none exists, so a missing secret never stops podman from
starting a container or makes it create a directory in the file's place.

| File | Read by | Owner, mode | When empty or missing |
| --- | --- | --- | --- |
| `frigate.env` | `nvr` | root, 0400 | Frigate cannot expand the camera credentials in its config; no camera connects |
| `unifi.env` | `unifi` | root, 0400 | `unifi-db` refuses to start (MongoDB would run without auth), so `unifi` does not start |
| `homeassistant-secrets.yaml` | `homeassistant` | root, 0400 | Home Assistant starts; config that uses `!secret` does not load |
| `ha-prometheus-token` | `observability` | prometheus, 0640 | Prometheus runs; the home-assistant scrape fails with 401 |
| `registry.htpasswd` | `registry` | registry, 0400 | the registry refuses to start, naming the file |
| `forgejo-secret-key` | `forgejo` | forgejo, 0400 | Forgejo refuses to start |
| `grafana-oidc-client-id`, `grafana-oidc-client-secret` | `observability`, with `grafanaOidc` | grafana, 0400 | written by Pocket ID for a client in `homelab.pocketId.clients`; otherwise Grafana runs and no one can sign in |
| `forgejo-oidc-client-id`, `forgejo-oidc-client-secret` | `forgejo`, with `oidc` | root, 0400 | written by Pocket ID for a client in `homelab.pocketId.clients`; otherwise the `forgejo-oidc` unit fails and Forgejo runs without the sign in source |
| `grafana-git-sync-token` | `observability`, with `grafanaGitSync` | root, 0400 | the `grafana-git-sync` unit fails; Grafana keeps the repository it has, or has none on a new host |
| `grafana-git-sync-api-token` | `observability`, with `grafanaGitSync` | root, 0400 | written by the `grafana-git-sync` unit, with a new token of the service account `grafana-git-sync`, when missing or empty |
| `pocket-id-encryption-key` | `pocket-id` | root, 0400 | generated on the first start; with a database and no key, `pocket-id-keys` fails and Pocket ID does not start, since the database cannot be read without the key it was made with |
| `pocket-id-api-key` | `pocket-id` | root, 0400 | generated by `pocket-id-keys` before Pocket ID starts |
| `<id>-oidc-client-id`, `<id>-oidc-client-secret` | the service of a client in `homelab.pocketId.clients` | its `owner`, 0400 | written by `pocket-id-clients`; an empty secret file gets a new secret |
| `oidc-gate-cookie-secret` | `reverse-proxy`, with `oidcGate` | root, 0400 | generated by `oidc-gate-cookie-secret` before oauth2-proxy starts; a new one signs everyone out |
| `cloudflare.env` | `acme` | root | certificate renewal fails |
| `restic-password`, `rclone.env` | `backups` | root | backups fail |
| `tailscale-authkey` | `tailscale` | root | not needed once the host is on the tailnet; deleted after use |

`cloudflare.env`, the backup secrets, `tailscale-authkey`,
Pocket ID's keys, the OIDC gate's secrets, the Git Sync tokens and Forgejo's OIDC files are read by NixOS services, not containers, and get no
tmpfiles rule: missing, their units fail, as most would with an empty file,
and the Tailscale key must stay absent once used. Keep a copy of
`pocket-id-encryption-key` off the host with the backup password: a
restored Pocket ID database needs it.

## Containers run unprivileged

Every container runs with `--security-opt=no-new-privileges` and
`--cap-drop=ALL`, adding back only the capabilities its module names, each
with its reason, and runs as a dedicated host user unless its image supports
nothing but root (docs/adr/0014-containers-run-unprivileged.md):

| Container | Runs as | Capabilities added |
| --- | --- | --- |
| `caddy` (`reverse-proxy`) | caddy, 606 | NET_BIND_SERVICE, for 443 |
| `homepage` | homepage, 607 | none |
| `prometheus`, `loki`, `grafana` (`observability`) | prometheus 603, loki 604, grafana 605 | none |
| `vaultwarden` | vaultwarden, 600 | none |
| `registry` | registry, 601 | none |
| `forgejo` | forgejo, 602 | none |
| `unifi-db` (`unifi`) | unifi-db, 988 | none |
| `unifi` (`unifi`) | root, dropping to unifi (989) for the controller | CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, KILL |
| `home-assistant` (`homeassistant`) | root | NET_RAW, NET_BIND_SERVICE, CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, KILL |
| `frigate` (`nvr`) | root | DAC_OVERRIDE, CHOWN, FOWNER, SETUID, SETGID, KILL |
| `nextcloud-aio-mastercontainer` (`nextcloud`) | root | CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, KILL, NET_BIND_SERVICE |

The root ones are on the allowlist of the `container-hardening` check, with
their reasons. A new container module runs as a user, or joins the list with
the reason in its module.

Data follows the user. Named volumes carry `:U`, so podman hands them to the
container's user on every start, including data written while Caddy,
homepage and the observability stack ran as root; a deploy needs no step for
it. Caddy reads the certificate through the acme cert's group, which the
reverse proxy sets to `caddy` (the acme units re-own the files when the
rebuild restarts them), and the Tailscale identity socket
`/run/tailnet-identity/whois.sock` through its group, also `caddy`, mode
0660. With Forgejo's proxy authentication, Caddy also gets Forgejo's group,
for its socket directory.

systemd sets the identity socket's owner and mode only when it creates the
socket, and `switch-to-configuration` does not restart a changed `.socket`
unit. The reverse proxy therefore makes the socket's settings a restart
trigger of `tailscale-nginx-auth.service`: a switch that changes them stops
the service and the socket, Caddy with it, and creates the socket anew. The
`identity-socket` check holds the example servers to this, and to a group,
socket mode 0660 and directory mode 0755 that let Caddy's user in. On a
host, the socket should look like this:

```
$ ls -ld /run/tailnet-identity /run/tailnet-identity/whois.sock
drwxr-xr-x 2 root                 root  60 ... /run/tailnet-identity
srw-rw---- 1 tailscale-nginx-auth caddy  0 ... /run/tailnet-identity/whois.sock
$ sudo -u '#606' -g '#606' socat -u OPEN:/dev/null UNIX-CONNECT:/run/tailnet-identity/whois.sock && echo ok
ok
```

`Permission denied` from socat means Caddy gets it too, and every site that
imports `tailnet_identity` fails with 502;
`systemctl restart tailscale-nginx-auth.socket` makes the socket again with
the configured group.

Caddy and the observability containers share files with the host by their
user's name: the certificate, the identity socket, the secret files under
`/var/lib/secrets/`. Their units first run `host-user-check`, which refuses
to start the container when the host's user has other ids than the ones it
runs as, and says which to set; see below.

## Static user ids

Containers that run as a dedicated user need its uid at evaluation time, so
those users get static ids. NixOS assigns automatic system ids downward from
999 and never moves an existing user to a declared id; it also does not check
that a declared id is free. A static id near 999 can therefore silently share
a uid with a user that already exists on the host. New static ids come from
the block 600 to 699, which automatic assignment does not reach in practice:

- 600: vaultwarden
- 601: registry
- 602: forgejo
- 603: prometheus
- 604: loki
- 605: grafana
- 606: caddy
- 607: homepage

A host that already has one of these users from before keeps its ids: NixOS
warns and does not change them. Forgejo, Vaultwarden, the observability
users, caddy and homepage take their ids with `lib.mkDefault`, so such a
host sets the ids it has, from `id <user>`:

```nix
users.users.prometheus.uid = 997;
users.groups.prometheus.gid = 997;
```

Hosts that ran the observability module before have prometheus, loki and
grafana users with automatic ids; until they set them, those containers
refuse to start with the ids to set in the journal. homepage's user owns
nothing on the host, so there it only silences the warning.

Older modules predate the block and keep their ids, since changing the uid of
a deployed user is not applied by NixOS: 990 frigate (nvr), 989 unifi, 988
unifi-db. Config repos that add their own container users should use a
separate block (for example 700 to 799).

## Configuration files

Modules take their service configs as paths (`homelab.reverseProxy.caddyfile`,
`homelab.nvr.configFile`, ...). Files are templated at build time: the literal
`__DOMAIN__` is replaced with `homelab.domain`, so the same config works for
any domain.

## Checks

`nix flake check` deep-evaluates the example hosts down to derivation
paths, which catches option and type errors without building full systems.
`examples/server-proxy-auth.nix` is the example server with Forgejo and
Grafana on proxy authentication instead of Pocket ID, so both are
evaluated. The `oidc-providers` check holds Forgejo's and Grafana's OIDC
settings on Pocket ID to
docs/adr/0019-forgejo-and-grafana-on-pocket-id.md, and the assertions that
refuse a half-done setup or tsidp's removed options. The
`container-hardening` check holds every container of the example servers
to docs/adr/0014-containers-run-unprivileged.md: a user that is not root,
or the allowlist; `no-new-privileges`; all capabilities dropped. The
`identity-socket` check holds Caddy's access to the Tailscale identity
socket: its group, socket and directory modes, the mount, and the restart
trigger that makes a switch create it anew. The `forgejo-deploy-ca` check
holds Forgejo's SSH settings to `homelab.forgejo.trustDeployCa`: with it
on, the deploy CA keys and principals limited to user names; off, no CA
and no principals. The `break-glass-ssh` check holds
`homelab.network.sshFrom` to docs/adr/0024-break-glass-ssh-from-the-lan.md:
the example server with documentation ranges set gets the iptables rules,
or nftables ones on that firewall, and fails to build with password
authentication on, an sshd on loopback only, or `0.0.0.0/0` and `::/0`.
The `vulnerability-scan-images` check holds the example server's scan to
exactly its containers' images, with only the save and publish steps as
root, and the `vulnerability-scan` check runs the scan's script against a
stubbed podman and Trivy with a fixture report. The `alert-rules` check
turns the example's Grafana rules into Prometheus rules, parses every
query with promtool and tests the vulnerability and Tailscale rules in
it. The `tailscale-metrics` check runs the Tailscale metrics script
against nixpkgs' tailscaled, logged out, and against its status with a
key expiry, with none, and with an expired key.
The `logging-labels` check holds the example server's fluent-bit config to
the [log labels](#logs) and runs it against a stand-in for Loki: a
container's line labelled with unit and container, a host service's with
its unit, a kernel line with neither, and every body the record unchanged.
The `identity-mapping` check also runs the example's Pocket ID site with
its `pocket_id_setup` snippet in Caddy: the setup's pages and API call
reach Pocket ID only for the listed logins. The `pocket-id-module` check holds the example server's Pocket ID, with two
clients added, to docs/adr/0018-pocket-id-is-the-oidc-provider.md: the
socket and its directory, the mount in Caddy, the keys before Pocket ID,
the clients' units after `pocket-id-clients`, the spec it gets and the
backup. The `oidc-gate` check runs the example server's oauth2-proxy and
its `oidc_owner_only` and `oidc_gate` snippets in a real Caddy against a
stand-in for Pocket ID: the sign-in and back, one sign-in for two sites,
sign-out, forged headers and users who are not let in; the
`oidc-gate-module` check holds the evaluated service, its socket and the
configurations the host refuses (docs/adr/0020-oidc-login-gate-at-the-proxy.md).
The checks also run the `forgejo-admin` and `forgejo-oidc` scripts
against stubs, the latter through the rename of a source left from
tsidp, the `pocket-id-clients` script against nixpkgs' Pocket ID, run
with the example's settings on a temporary database, and the Caddy
identity snippets in a real Caddy.

## CI

`.forgejo/workflows/check.yml` runs
`nix flake check --no-update-lock-file --show-trace` in Forgejo Actions on
every push to any branch and on pull requests, in a digest-pinned `nixos/nix`
container.

## Deploy TUI

`nix run .#deploy` starts a small fzf picker over `scripts/deploy/*.sh` in
your config repo.

## Agent skills (Claude Code plugin)

This repo doubles as a Claude Code plugin shipping read-only observability
skills for the stack it deploys: host health from node_exporter
(host-metrics), journal logs from Loki (service-logs), and Home Assistant
entity state from the Prometheus exporter (ha-state). image-updates reports
the pinned container images whose tag has moved, asking the registries
directly, and its separate `image_bump.py` rewrites those pins for a
reviewed bump (docs/adr/0016-image-updates-as-reviewed-bumps.md). Install
per project:

```
claude plugin marketplace add heavy-oil1462/homelab
claude plugin install homelab@homelab
```

Endpoints resolve from HOMELAB_PROM_URL / HOMELAB_LOKI_URL environment
variables, else a `.claude/homelab-endpoints.json` found upward from the
current directory (commit one in your private config repo), else
`~/.claude/homelab-endpoints.json`:

```json
{
  "prom_url": "https://metrics.home.example.com",
  "loki_url": "https://logs.home.example.com"
}
```

See `skills/README.md` for layout and conventions.
