# The tailscale-metrics unit of modules/tailscale.nix: the node's key
# expiry and whether it is on the tailnet, for the node exporter's textfile
# collector.
#
#   tailscale-metrics <textfile dir>
#
# It reads `tailscale status --json` (ipnstate.Status) and writes
# <textfile dir>/homelab_tailscale.prom:
#
#   homelab_tailscale_key_expiry_timestamp_seconds
#     .Self.KeyExpiry as a Unix time. Left out when the node has no expiry:
#     tailscaled leaves the field out when the key does not expire, and
#     when it has no network map (logged out, or not yet connected).
#   homelab_tailscale_key_expiry_disabled
#     1 when the node is in its network map and has no expiry, else 0.
#   homelab_tailscale_online
#     1 when .Self.Online (connected to the control plane) and
#     .BackendState is "Running", else 0. Also 0 when tailscaled does not
#     answer.
#
# An expired key keeps its expiry, now in the past, as long as tailscaled
# keeps its last network map. The file is written under a name without
# .prom and renamed, so a scrape never sees half of it.

usage() {
  echo "usage: tailscale-metrics <textfile dir>" >&2
  exit 64
}
[ "$#" -eq 1 ] || usage

out=$1/homelab_tailscale.prom
umask 022

online=0
disabled=0
expiry=
if status=$(timeout 30 tailscale status --json); then
  state=$(jq -r '.BackendState // ""' <<< "$status")
  self_online=$(jq -r '.Self.Online // false' <<< "$status")
  in_map=$(jq -r '.Self.InNetworkMap // false' <<< "$status")
  key_expiry=$(jq -r '.Self.KeyExpiry // ""' <<< "$status")

  if [ "$state" = Running ] && [ "$self_online" = true ]; then
    online=1
  fi
  # Go writes a zero time as 0001-01-01T00:00:00Z, before the epoch.
  if [ -n "$key_expiry" ]; then
    expiry=$(date -d "$key_expiry" +%s)
    [ "$expiry" -gt 0 ] || expiry=
  fi
  if [ -z "$expiry" ] && [ "$in_map" = true ]; then
    disabled=1
  fi
else
  echo "tailscale status failed; writing the node as offline" >&2
fi

{
  if [ -n "$expiry" ]; then
    echo '# HELP homelab_tailscale_key_expiry_timestamp_seconds When the node key of this host expires.'
    echo '# TYPE homelab_tailscale_key_expiry_timestamp_seconds gauge'
    echo "homelab_tailscale_key_expiry_timestamp_seconds $expiry"
  fi
  echo '# HELP homelab_tailscale_key_expiry_disabled Whether key expiry is disabled for this host.'
  echo '# TYPE homelab_tailscale_key_expiry_disabled gauge'
  echo "homelab_tailscale_key_expiry_disabled $disabled"
  echo '# HELP homelab_tailscale_online Whether this host is logged in and connected to the tailnet.'
  echo '# TYPE homelab_tailscale_online gauge'
  echo "homelab_tailscale_online $online"
} > "$out.tmp"
mv "$out.tmp" "$out"
