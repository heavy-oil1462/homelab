# The tailscale-metrics unit of modules/tailscale.nix: the node's key
# expiry, whether it is on the tailnet and its Tailnet Lock state, for the
# node exporter's textfile collector.
#
#   tailscale-metrics <textfile dir> <state dir>
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
# and, from `tailscale lock status --json` (tslockjsonv1.StatusResponse):
#
#   homelab_tailscale_lock_enabled
#     .Enabled as 1 or 0, once this node has seen Tailnet Lock on. Before
#     that the series is left out, so a tailnet that has not set the lock
#     up yet does not alert as "Tailnet Lock off".
#   homelab_tailscale_lock_node_signed
#     .NodeKeySigned as 1 or 0: whether the lock trusts this node's key.
#     tailscaled fills it in only while the lock is on, so it is left out
#     when the lock is off.
#
# The state dir keeps two markers: lock-seen, made the first time the lock
# is on and kept for good, and lock-unknown, while `tailscale lock status`
# fails or has no .Enabled (a tailscaled without Tailnet Lock, or one not
# answering). Then both lock series are left out rather than written as 0,
# and the failure is logged once, not every 5 minutes.
#
# An expired key keeps its expiry, now in the past, as long as tailscaled
# keeps its last network map. The file is written under a name without
# .prom and renamed, so a scrape never sees half of it.

usage() {
  echo "usage: tailscale-metrics <textfile dir> <state dir>" >&2
  exit 64
}
[ "$#" -eq 2 ] || usage

out=$1/homelab_tailscale.prom
state_dir=$2
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

lock_enabled=
lock_signed=
if lock=$(timeout 30 tailscale lock status --json 2> "$state_dir/lock.err") \
  && jq -e '.Enabled | type == "boolean"' <<< "$lock" > /dev/null 2>&1; then
  rm -f "$state_dir/lock-unknown"
  if [ "$(jq -r .Enabled <<< "$lock")" = true ]; then
    touch "$state_dir/lock-seen"
    lock_enabled=1
    case $(jq -r .NodeKeySigned <<< "$lock") in
      true) lock_signed=1 ;;
      false) lock_signed=0 ;;
    esac
  elif [ -e "$state_dir/lock-seen" ]; then
    lock_enabled=0
  fi
elif [ ! -e "$state_dir/lock-unknown" ]; then
  echo "tailscale lock status gave no Tailnet Lock state; leaving it out until it does" >&2
  head -c 500 "$state_dir/lock.err" >&2
  touch "$state_dir/lock-unknown"
fi
rm -f "$state_dir/lock.err"

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
  if [ -n "$lock_enabled" ]; then
    echo '# HELP homelab_tailscale_lock_enabled Whether Tailnet Lock is on, as this host sees it.'
    echo '# TYPE homelab_tailscale_lock_enabled gauge'
    echo "homelab_tailscale_lock_enabled $lock_enabled"
  fi
  if [ -n "$lock_signed" ]; then
    echo '# HELP homelab_tailscale_lock_node_signed Whether Tailnet Lock trusts the node key of this host.'
    echo '# TYPE homelab_tailscale_lock_node_signed gauge'
    echo "homelab_tailscale_lock_node_signed $lock_signed"
  fi
} > "$out.tmp"
mv "$out.tmp" "$out"
