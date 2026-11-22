# The tailscale-ssh-off unit of modules/tailscale.nix: turns Tailscale SSH
# off on a node that runs it, once nobody is using it
# (docs/adr/0026-servers-ssh-through-sshd-only.md).
#
#   tailscale-ssh-off <poll seconds> <quiet seconds>
#
# `tailscale set --ssh=false` stops tailscaled taking port 22 on the
# tailnet address at once, and the next packet of every open Tailscale SSH
# connection goes to the kernel, which resets it (ShouldInterceptTCPPort in
# ipn/ipnlocal, at tailscale 1.104.6). A deploy over Tailscale SSH that
# switched this host would lose its session, and the steps it runs after
# the switch. So it waits for <quiet seconds> in a row with no Tailscale
# SSH session open and none started, polling tailscaled's own counters
# every <poll seconds>:
#
#   ssh_active_sessions       sessions (a shell or command) open now
#   ssh_incoming_connections  connections ever accepted
#
# A connection with no session, such as an idle ssh ControlMaster, is not
# counted; the quiet time is what covers a deploy's pauses between
# commands. Then it turns Tailscale SSH off.
#
# Nothing to do once the node's prefs have RunSSH off, which it checks
# before every poll. It fails, leaving Tailscale SSH on, when tailscaled
# answers but no longer reports ssh_active_sessions: without it, it cannot
# tell whether a session is open. While tailscaled does not answer at all,
# it keeps waiting.

usage() {
  echo "usage: tailscale-ssh-off <poll seconds> <quiet seconds>" >&2
  exit 64
}
[ "$#" -eq 2 ] || usage
poll=$1
quiet=$2

ssh_off() {
  local prefs
  prefs=$(timeout 30 tailscale debug prefs) \
    && [ "$(jq -r '.RunSSH' <<< "$prefs")" = false ]
}

if ssh_off; then
  echo "Tailscale SSH is off"
  exit 0
fi
echo "turning Tailscale SSH off after ${quiet}s with no Tailscale SSH session"
idle=0
last=
while ! ssh_off; do
  if metrics=$(timeout 30 tailscale debug metrics); then
    sessions=$(awk '$1 == "ssh_active_sessions" { print $2 }' <<< "$metrics")
    accepted=$(awk '$1 == "ssh_incoming_connections" { print $2 }' <<< "$metrics")
    if [ -z "$sessions" ]; then
      echo "tailscaled reports no ssh_active_sessions; leaving Tailscale SSH on" >&2
      exit 1
    fi
    if [ "$sessions" -gt 0 ] || [ "$accepted" != "$last" ]; then
      idle=0
    else
      idle=$((idle + poll))
    fi
    last=$accepted
  else
    idle=0
  fi
  if [ "$idle" -ge "$quiet" ]; then
    tailscale set --ssh=false
    break
  fi
  sleep "$poll"
done
echo "Tailscale SSH is off"
