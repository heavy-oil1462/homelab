# Keeps Grafana's Git Sync repository in step with the host's config,
# through Grafana's API (docs/adr/0009-dashboards-through-grafana-git-sync.md).
#
#   grafana-git-sync <container> <repository JSON> <token file> <API token file> <state file> [<seed>]
#
# <repository JSON> is the Repository resource without its secure part.
# With <seed>, a directory of dashboard JSON files, the script first asks
# the Git server for the repository's refs. A repository without any is
# seeded once: one commit with the seed's dashboards under the spec's path,
# pushed to its branch (docs/adr/0011-git-sync-seeds-an-empty-repository.md).
# A repository with history is never touched, and a failed seed fails the
# unit before anything reaches Grafana. Then the script waits until
# Grafana answers in <container>, on the container's address on podman's
# network, then creates the repository with the token from <token file>,
# or replaces it when its spec in Grafana differs from the config or the
# spec or token changed since the last run, which <state file> records as
# a hash. Finally Grafana tests the repository: a token the Git server
# refuses fails the unit.
#
# When <API token file> is missing or empty, the script makes the token
# once Grafana answers
# (docs/adr/0012-git-sync-service-account-made-by-the-host.md): it signs
# in to Grafana as its built-in admin through Grafana's proxy
# authentication, which Grafana takes from 127.0.0.1 only, so from inside
# the container's network namespace (nsenter, from the host's PATH like
# podman). It finds or makes the service account grafana-git-sync with the
# Admin role, adds a token, writes it to the file, mode 0400, and deletes
# the account's other tokens. A file with a token in it is used as it is.
# GRAFANA_GIT_SYNC_USER_HEADER and GRAFANA_GIT_SYNC_ROLE_HEADER
# (X-Grafana-Git-Sync-User and X-Grafana-Git-Sync-Role) name the headers
# Grafana reads, GRAFANA_GIT_SYNC_ADMIN (admin) the admin's login.
#
# Both tokens stay off command lines and out of the logs: the API token
# goes to curl as a header file and comes from Grafana in a file of a
# private directory, the Git token inside the request body on stdin, and to git
# through GRAFANA_GIT_SYNC_ASKPASS, which reads it from <token file>.
# GRAFANA_GIT_SYNC_TRIES (60) and GRAFANA_GIT_SYNC_WAIT (5 seconds) set how
# long it waits, GRAFANA_GIT_SYNC_PORT (3000) where Grafana listens.
#
# Nothing waits without a deadline: each git command gets 60 seconds,
# podman 10 seconds a try, each health check 5, each API call 60, so a run
# that fails ends after about 25 minutes at the defaults, within the
# unit's TimeoutStartSec.

if [ "$#" -ne 5 ] && [ "$#" -ne 6 ]; then
  echo "usage: grafana-git-sync <container> <repository JSON> <token file> <API token file> <state file> [<seed>]" >&2
  exit 2
fi
container=$1
repository=$2
token_file=$3
api_token_file=$4
state=$5
seed=${6:-}
tries=${GRAFANA_GIT_SYNC_TRIES:-60}
delay=${GRAFANA_GIT_SYNC_WAIT:-5}
port=${GRAFANA_GIT_SYNC_PORT:-3000}

if ! token=$(cat "$token_file") || [ -z "$token" ]; then
  echo "The Git token file $token_file is missing or empty; the repository is not set up." >&2
  exit 1
fi
# Made below, once Grafana answers, when missing or empty.
api_token=$(cat "$api_token_file" 2>/dev/null || true)

name=$(jq -r .metadata.name "$repository")
# git runs the askpass in other directories.
token_path=$(realpath "$token_file")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Git with no configuration but its own, asking GRAFANA_GIT_SYNC_ASKPASS
# for the user and token, never a terminal or a credential helper, and
# given 60 seconds.
git_() {
  HOME=$work GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=$GRAFANA_GIT_SYNC_ASKPASS GRAFANA_GIT_SYNC_TOKEN_FILE=$token_path \
    GRAFANA_GIT_SYNC_USER=$(jq -r '.spec.git.tokenUser // "git"' "$repository") \
    timeout 60 git -c credential.helper= "$@"
}

# A dashboard as Git Sync keeps it: the dashboard.grafana.app/v1 resource
# Grafana 13 writes, named after the dashboard's uid. Grafana takes plain
# dashboard JSON too, but only with panels, schemaVersion and tags, and
# drops the file without a uid. id and version belong to Grafana's
# storage, which drops them from the spec on reading. A file already in
# resource form is kept as it is.
as_resource() {
  jq --arg file "$1" '
    if has("apiVersion") and has("kind") then .
    elif (.uid | type) == "string" and .uid != "" then
      { apiVersion: "dashboard.grafana.app/v1", kind: "Dashboard",
        metadata: { name: .uid }, spec: del(.id, .uid, .version) }
    else error("\($file) has no uid; Git Sync names a dashboard after it") end' "$1"
}

# Seeds the repository from $seed when it has no refs at all.
seed_repository() {
  local url branch dir refs file
  url=$(jq -r .spec.git.url "$repository")
  branch=$(jq -r .spec.git.branch "$repository")
  dir=$(jq -r '.spec.git.path // ""' "$repository")
  dir=${dir#./}
  dir=${dir%/}

  if ! refs=$(git_ ls-remote "$url" 2> "$work/git-err"); then
    echo "Asking $url for its branches failed, so it was not seeded: $(cat "$work/git-err")" >&2
    exit 1
  fi
  if [ -n "$refs" ]; then
    if ! grep -q "[[:space:]]refs/heads/$branch\$" <<< "$refs"; then
      echo "$url has history but no branch $branch; it is not seeded." >&2
    fi
    return
  fi

  mkdir "$work/seed"
  (cd "$seed" && find . -name '*.json' -type f) | sort > "$work/seed-files"
  if [ ! -s "$work/seed-files" ]; then
    echo "The seed $seed holds no dashboard JSON files; $url is not seeded." >&2
    exit 1
  fi
  while IFS= read -r file; do
    file=${file#./}
    mkdir -p "$(dirname "$work/seed/${dir:+$dir/}$file")"
    if ! as_resource "$seed/$file" > "$work/seed/${dir:+$dir/}$file" 2> "$work/jq-err"; then
      echo "The seed file $file is not a dashboard Git Sync can read, so $url was not seeded: $(cat "$work/jq-err")" >&2
      exit 1
    fi
  done < "$work/seed-files"

  git_ -C "$work/seed" init -q -b "$branch"
  git_ -C "$work/seed" add -A
  git_ -C "$work/seed" -c user.name=grafana-git-sync -c user.email=grafana-git-sync@localhost.invalid \
    commit -q -m "Seed the dashboards from $seed" \
    -m "The grafana-git-sync unit seeded this empty repository once from homelab.observability.grafanaGitSync.seed."
  # No force: should the branch appear meanwhile, the push is refused.
  if ! git_ -C "$work/seed" push -q "$url" "HEAD:refs/heads/$branch" 2> "$work/git-err"; then
    echo "Pushing the seed to $branch of $url failed, so the repository is not set up in Grafana: $(cat "$work/git-err")" >&2
    exit 1
  fi
  echo "Seeded $url from $seed: $(wc -l < "$work/seed-files") files on $branch."
}

if [ -n "$seed" ]; then
  seed_repository
fi

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

# Calls Grafana's API as its built-in admin, on 127.0.0.1 inside the
# container's network namespace, the one address Grafana takes the admin's
# headers from. Leaves the answer in $work/answer and prints the status
# code. No proxy: one would make the call from elsewhere.
as_admin() {
  timeout 70 nsenter --target "$grafana_pid" --net \
    curl -sS --noproxy '*' --connect-timeout 10 --max-time 60 -o "$work/answer" -w '%{http_code}' \
    -H "${GRAFANA_GIT_SYNC_USER_HEADER:-X-Grafana-Git-Sync-User}: ${GRAFANA_GIT_SYNC_ADMIN:-admin}" \
    -H "${GRAFANA_GIT_SYNC_ROLE_HEADER:-X-Grafana-Git-Sync-Role}: Admin" \
    -H 'Content-Type: application/json' "$@"
}

admin_failed() {
  case "$2" in
    401 | 403)
      echo "Grafana refused the host's admin sign in to $1 ($2): $(jq -r '.message // .' "$work/answer" 2>/dev/null || cat "$work/answer"). Grafana takes it from 127.0.0.1 in its container only, once started with grafanaGitSync on. The token file $api_token_file is not written." >&2
      ;;
    *)
      echo "Asking Grafana to $1 answered $2: $(cat "$work/answer" 2>/dev/null). The token file $api_token_file is not written." >&2
      ;;
  esac
  exit 1
}

# Makes a token of the service account grafana-git-sync, and the account
# when there is none, and writes it to the API token file. The account's
# other tokens, from an earlier run or by hand, are deleted once the file
# holds the new one.
make_api_token() {
  local sa=grafana-git-sync accounts id code old tmp t
  if ! grafana_pid=$(timeout 10 podman inspect -f '{{.State.Pid}}' "$container") \
    || [ -z "$grafana_pid" ] || [ "$grafana_pid" = 0 ]; then
    echo "Finding the $container container's process failed; the token file $api_token_file is not written." >&2
    exit 1
  fi
  accounts=http://127.0.0.1:$port/api/serviceaccounts

  code=$(as_admin "$accounts/search?query=$sa") || code=000
  [ "$code" = 200 ] || admin_failed "find the service account $sa" "$code"
  id=$(jq -r --arg sa "$sa" 'first(.serviceAccounts[] | select(.name == $sa) | .id) // empty' "$work/answer")
  if [ -z "$id" ]; then
    code=$(as_admin -X POST --data-binary "{\"name\":\"$sa\",\"role\":\"Admin\"}" "$accounts") || code=000
    case "$code" in
      200 | 201) id=$(jq -r .id "$work/answer") ;;
      *) admin_failed "make the service account $sa" "$code" ;;
    esac
    echo "Made the Grafana service account $sa, with the Admin role."
  fi

  code=$(as_admin "$accounts/$id/tokens") || code=000
  [ "$code" = 200 ] || admin_failed "list the tokens of the service account $sa" "$code"
  old=$(jq -r '.[].id' "$work/answer")

  code=$(as_admin -X POST --data-binary "{\"name\":\"$sa-$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)\"}" "$accounts/$id/tokens") || code=000
  [ "$code" = 200 ] || admin_failed "add a token to the service account $sa" "$code"
  if ! tmp=$(mktemp "$api_token_file.XXXXXX"); then
    echo "Writing the token file $api_token_file failed." >&2
    exit 1
  fi
  if ! jq -j '.key | select(type == "string" and . != "")' "$work/answer" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "Grafana gave no token for the service account $sa; the token file $api_token_file is not written." >&2
    exit 1
  fi
  rm -f "$work/answer"
  chmod 0400 "$tmp"
  mv -f "$tmp" "$api_token_file"
  echo "Wrote a new token of the service account $sa to $api_token_file."

  for t in $old; do
    code=$(as_admin -X DELETE "$accounts/$id/tokens/$t") || code=000
    [ "$code" = 200 ] \
      || echo "Deleting the old token $t of the service account $sa answered $code; delete it under Administration, Service accounts." >&2
  done
  api_token=$(cat "$api_token_file")
}

if [ -z "$api_token" ]; then
  make_api_token
fi

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
