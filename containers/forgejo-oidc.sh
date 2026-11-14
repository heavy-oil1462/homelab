# Keeps Forgejo's OpenID Connect sign in source in step with the host's
# config, inside the forgejo container.
#
#   forgejo-oidc <source name> <issuer URL> <client id file> <client secret file> <state file>
#
# Waits until Forgejo answers and the issuer's discovery document can be
# fetched from the container. Then adds the source, or updates it when the
# issuer, client id or secret changed since the last run, which <state file>
# records as a hash. Forgejo sets its sign in sources up only when it starts,
# and fetches their discovery documents then, so it is restarted after a
# change, and also when it started before the issuer answered: the start of
# a sign in must redirect to the issuer.
#
# The id and secret go to the container on stdin, not on podman's command
# line. FORGEJO_OIDC_TRIES (60) and FORGEJO_OIDC_WAIT (5 seconds) set how
# long it waits.

if [ "$#" -ne 5 ]; then
  echo "usage: forgejo-oidc <source name> <issuer URL> <client id file> <client secret file> <state file>" >&2
  exit 2
fi
name=$1
issuer=$2
id_file=$3
secret_file=$4
state=$5
tries=${FORGEJO_OIDC_TRIES:-60}
delay=${FORGEJO_OIDC_WAIT:-5}
discovery=$issuer/.well-known/openid-configuration

# Runs the command until it succeeds, at most $tries times.
retry() {
  local try=1
  until "$@" >/dev/null 2>&1; do
    if [ "$try" -ge "$tries" ]; then
      return 1
    fi
    try=$((try + 1))
    sleep "$delay"
  done
}

forgejo_up() {
  podman exec forgejo wget -q -O /dev/null http://127.0.0.1:3000/api/healthz
}

issuer_up() {
  podman exec forgejo curl -fsS -o /dev/null "$discovery"
}

# The start of a sign in redirects to the issuer once Forgejo has set the
# source up; otherwise it fails or goes back to the sign in page.
registered() {
  local location
  location=$(podman exec forgejo curl -s -o /dev/null -w '%{redirect_url}' \
    "http://127.0.0.1:3000/user/oauth2/$name") || return 1
  case "$location" in
    "$issuer"/*) return 0 ;;
    *) return 1 ;;
  esac
}

if ! id=$(cat "$id_file") || [ -z "$id" ]; then
  echo "The client id file $id_file is missing or empty; no sign in source set up." >&2
  exit 1
fi
if ! secret=$(cat "$secret_file") || [ -z "$secret" ]; then
  echo "The client secret file $secret_file is missing or empty; no sign in source set up." >&2
  exit 1
fi

if ! retry forgejo_up; then
  echo "Forgejo did not answer in the forgejo container after $tries tries; no sign in source set up." >&2
  exit 1
fi
if ! retry issuer_up; then
  echo "The forgejo container could not fetch $discovery after $tries tries; no sign in source set up." >&2
  exit 1
fi

# Forgejo's own messages on stderr go to the journal as they are.
if ! sources=$(podman exec forgejo forgejo admin auth list); then
  echo "Listing Forgejo's sign in sources failed." >&2
  exit 1
fi
# A header line, then ID, name, type and enabled per source.
source_id=$(printf '%s\n' "$sources" | tail -n +2 | awk -v n="$name" '$2 == n { print $1; exit }')

want=$(printf '%s\n%s\n%s\n' "$issuer" "$id" "$secret" | sha256sum | cut -d ' ' -f 1)
have=$(cat "$state" 2>/dev/null || true)

changed=
if [ -z "$source_id" ] || [ "$want" != "$have" ]; then
  if [ -n "$source_id" ]; then
    action=(update-oauth --id "$source_id")
  else
    action=(add-oauth)
  fi
  # The scopes give the email and preferred_username claims; openid is
  # always added.
  # shellcheck disable=SC2016 # expanded by the container's shell
  if ! printf '%s\n%s\n' "$id" "$secret" | podman exec -i forgejo sh -c \
    'read -r key && read -r secret && exec forgejo admin auth "$@" --key "$key" --secret "$secret"' \
    sh "${action[@]}" --name "$name" --provider openidConnect \
    --auto-discover-url "$discovery" --scopes email --scopes profile; then
    echo "Setting up the sign in source $name failed." >&2
    exit 1
  fi
  printf '%s\n' "$want" > "$state"
  changed=1
  if [ -n "$source_id" ]; then
    echo "Updated the sign in source $name for $issuer."
  else
    echo "Added the sign in source $name for $issuer."
  fi
fi

if [ -z "$changed" ] && registered; then
  echo "The sign in source $name is set up; nothing to do."
  exit 0
fi

echo "Restarting Forgejo to set up the sign in source $name."
systemctl restart podman-forgejo.service
if ! retry forgejo_up; then
  echo "Forgejo did not answer after the restart." >&2
  exit 1
fi
if ! registered; then
  echo "Forgejo did not set up the sign in source $name; see journalctl -u podman-forgejo." >&2
  exit 1
fi
echo "The sign in source $name is set up."
