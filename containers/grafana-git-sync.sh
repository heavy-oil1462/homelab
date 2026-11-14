# Keeps Grafana's Git Sync repository in step with the host's config,
# through Grafana's API (docs/adr/0009-dashboards-through-grafana-git-sync.md).
#
#   grafana-git-sync <container> <repository JSON> <token file> <API token file> <state file>
#
# <repository JSON> is the Repository resource without its secure part. The
# script waits until Grafana answers in <container>, on the container's
# address on podman's network, then creates the repository with the token
# from <token file>, or replaces it when its spec in Grafana differs from
# the config or the spec or token changed since the last run, which
# <state file> records as a hash. Finally Grafana tests the repository: a
# token the Git server refuses fails the unit.
#
# Both tokens stay off command lines: the API token goes to curl as a
# header file, the Git token inside the request body on stdin.
# GRAFANA_GIT_SYNC_TRIES (60) and GRAFANA_GIT_SYNC_WAIT (5 seconds) set how
# long it waits, GRAFANA_GIT_SYNC_PORT (3000) where Grafana listens.
#
# Nothing waits without a deadline: podman gets 10 seconds a try, each
# health check 5, each API call 60, so a run that fails ends after about
# 23 minutes at the defaults, within the unit's TimeoutStartSec.

if [ "$#" -ne 5 ]; then
  echo "usage: grafana-git-sync <container> <repository JSON> <token file> <API token file> <state file>" >&2
  exit 2
fi
container=$1
repository=$2
token_file=$3
api_token_file=$4
state=$5
tries=${GRAFANA_GIT_SYNC_TRIES:-60}
delay=${GRAFANA_GIT_SYNC_WAIT:-5}
port=${GRAFANA_GIT_SYNC_PORT:-3000}

if ! token=$(cat "$token_file") || [ -z "$token" ]; then
  echo "The Git token file $token_file is missing or empty; the repository is not set up." >&2
  exit 1
fi
if ! api_token=$(cat "$api_token_file") || [ -z "$api_token" ]; then
  echo "The Grafana API token file $api_token_file is missing or empty; the repository is not set up." >&2
  exit 1
fi

name=$(jq -r .metadata.name "$repository")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Grafana's address on podman's network, and whether it answers there.
grafana_up() {
  local address
  address=$(timeout 10 podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$container") || return 1
  address=${address%% *}
  [ -n "$address" ] || return 1
  base=http://$address:$port
  curl -fsS --connect-timeout 5 --max-time 5 -o /dev/null "$base/api/health"
}

try=1
until grafana_up 2>/dev/null; do
  if [ "$try" -ge "$tries" ]; then
    echo "Grafana did not answer in the $container container after $tries tries; the repository is not set up." >&2
    exit 1
  fi
  try=$((try + 1))
  sleep "$delay"
done
api=$base/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories

# Calls the API, with a request body on stdin when given --data-binary @-.
# Leaves the answer in $work/answer and prints the status code.
call() {
  curl -sS --connect-timeout 10 --max-time 60 -o "$work/answer" -w '%{http_code}' \
    -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$api_token") \
    "$@"
}

refused() {
  echo "Grafana refused the API token in $api_token_file ($1); it must belong to a service account with the Admin role." >&2
  exit 1
}

code=$(call "$api/$name") || { echo "Reading the repository $name from Grafana failed." >&2; exit 1; }
case "$code" in
  200) cp "$work/answer" "$work/have" ;;
  404) ;;
  401 | 403) refused "$code" ;;
  *)
    echo "Reading the repository $name from Grafana answered $code: $(cat "$work/answer")" >&2
    exit 1
    ;;
esac

want=$( { cat "$repository"; printf '%s\n' "$token"; } | sha256sum | cut -d ' ' -f 1)
have=$(cat "$state" 2>/dev/null || true)

# Whether every field the config sets has its value in Grafana's spec;
# Grafana may add fields of its own.
in_step() {
  jq -e -n --slurpfile want "$repository" --slurpfile have "$work/have" '
    def within($a; $b):
      if ($a | type) == "object"
      then ($b | type) == "object" and all($a | to_entries[]; within(.value; $b[.key]))
      else $a == $b end;
    within($want[0].spec; $have[0].spec)' > /dev/null
}

# The resource with the token. A replacement carries no resourceVersion:
# Grafana's controller writes the repository's status every few seconds,
# so the version just read is often stale by the time of the PUT, and
# Grafana takes an update without one.
body() {
  jq --rawfile token "$token_file" \
    '.secure = { token: { create: ($token | rtrimstr("\n")) } }' "$repository"
}

if [ ! -e "$work/have" ]; then
  code=$(body | call -X POST --data-binary @- "$api") || code=000
  case "$code" in
    200 | 201 | 202) echo "Created the Git Sync repository $name." ;;
    401 | 403) refused "$code" ;;
    *)
      echo "Creating the repository $name answered $code: $(cat "$work/answer")" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$want" > "$state"
elif [ "$want" != "$have" ] || ! in_step; then
  code=$(body | call -X PUT --data-binary @- "$api/$name") || code=000
  case "$code" in
    200 | 201) echo "Updated the Git Sync repository $name." ;;
    401 | 403) refused "$code" ;;
    *)
      echo "Updating the repository $name answered $code: $(cat "$work/answer")" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$want" > "$state"
else
  echo "The Git Sync repository $name is in step with the config."
fi

# Grafana reaches the Git server with the token, as each sync does.
code=$(call -X POST --data-binary '{}' "$api/$name/test") || code=000
if ! jq -e '.success == true' "$work/answer" > /dev/null 2>&1; then
  echo "Grafana's test of the repository $name failed ($code): $(jq -c '.errors // .' "$work/answer" 2>/dev/null || cat "$work/answer")" >&2
  exit 1
fi
echo "Grafana reaches the repository $name."
