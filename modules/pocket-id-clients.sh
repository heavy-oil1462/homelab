# Declares the host's OIDC clients in Pocket ID through its admin API and
# writes each client's id and secret file, as root (the pocket-id-clients
# unit, after Pocket ID has started).
#
#   pocket-id-clients <spec file> <socket> <API key file> <state file>
#
# The spec is a JSON list from homelab.pocketId.clients, one object per
# client: id, displayName, redirectUris, logoutRedirectUris, pkce, idFile,
# secretFile, owner ("user:group") and units. The API key is Pocket ID's
# STATIC_API_KEY, an admin's. It needs Pocket ID 2.14 or later, whose
# clients hold several secrets. For each client:
#
# - The client is created with its id, which Pocket ID keeps, or updated
#   when its name, redirect URIs, PKCE or confidentiality differ. A client
#   with the id that is already there, made by hand or by a run that
#   failed half way, is taken over. Settings made in the admin UI that the
#   spec does not name (group restriction, launch URL, logo, token
#   lifetimes) are kept.
# - Pocket ID makes client secrets itself and keeps only their hash, so the
#   secret file is checked against them by introspecting a dummy token with
#   the client's credentials: 200 means Pocket ID took them, 401 that it
#   did not. A new client, a missing or empty secret file and a refused
#   secret get a new secret, written to the file: the one Pocket ID made
#   with a new client, or else one asked for. The client's other secrets
#   are then deleted, so only the file's works.
# - The id and secret files are mode 0400, owned by owner, written to a
#   temporary file and renamed into place. When either changed, the
#   client's units are restarted, without waiting for them.
#
# A client declared before and no longer is deleted from Pocket ID; the ids
# declared last time are kept in the state file. Its files are left.
# Clients made in the admin UI are left alone.
#
# POCKET_ID_CLIENTS_TRIES and POCKET_ID_CLIENTS_WAIT (seconds) set how
# long it waits for Pocket ID to answer, 60 times 1 second by default.

if [ "$#" -ne 4 ]; then
  echo "usage: pocket-id-clients <spec file> <socket> <API key file> <state file>" >&2
  exit 2
fi
spec=$1
socket=$2
key_file=$3
declared=$4
tries=${POCKET_ID_CLIENTS_TRIES:-60}
wait=${POCKET_ID_CLIENTS_WAIT:-1}

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! jq -e 'type == "array"' "$spec" >/dev/null; then
  echo "The spec $spec is not a JSON list." >&2
  exit 1
fi

# The key goes to curl in a header file, never on a command line.
if [ ! -s "$key_file" ]; then
  echo "Pocket ID's API key file $key_file is missing or empty." >&2
  exit 1
fi
printf 'X-API-Key: %s\n' "$(tr -d '\n' < "$key_file")" > "$tmp/key-header"

# request <method> <path> [<JSON body>]: prints the HTTP status, the body
# goes to $tmp/body.
request() {
  local args=(--silent --show-error --max-time 30 --unix-socket "$socket"
    -X "$1" -o "$tmp/body" -w '%{http_code}' -H @"$tmp/key-header")
  if [ "$#" -gt 2 ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$3")
  fi
  curl "${args[@]}" "http://pocket-id$2"
}

# Writes stdin to the file, mode 0400 and owned by $2, by a rename.
write_secret_file() {
  local file=$1 owner=$2 dir tmpfile
  dir=$(dirname "$file")
  if [ ! -d "$dir" ]; then
    install -d -m 0700 "$dir"
  fi
  tmpfile=$(mktemp "$dir/.pocket-id-clients.XXXXXX")
  cat > "$tmpfile"
  chmod 0400 "$tmpfile"
  chown "$owner" "$tmpfile"
  mv -f "$tmpfile" "$file"
}

# Whether Pocket ID takes the secret in $2 for client $1. The credentials
# go to curl in a header file.
secret_accepted() {
  local status
  printf 'Authorization: Basic %s\n' \
    "$(printf '%s:%s' "$1" "$(sed -e 's/[[:space:]]*$//' "$2")" | base64 -w0)" > "$tmp/auth-header"
  status=$(curl --silent --show-error --max-time 30 --unix-socket "$socket" \
    -o /dev/null -w '%{http_code}' -H @"$tmp/auth-header" \
    --data-urlencode token=none "http://pocket-id/api/oidc/introspect")
  rm -f "$tmp/auth-header"
  case $status in
    200) return 0 ;;
    401) return 1 ;;
    *)
      echo "Pocket ID answered $status when checking the client secret of $1." >&2
      exit 1
      ;;
  esac
}

# Pocket ID starts listening a moment after its unit has started.
for ((i = 1; ; i++)); do
  status=$(curl --silent --max-time 5 --unix-socket "$socket" -o /dev/null -w '%{http_code}' \
    http://pocket-id/healthz || true)
  case $status in
    2??) break ;;
  esac
  if [ "$i" -ge "$tries" ]; then
    echo "Pocket ID did not answer on $socket (last status: ${status:-none})." >&2
    exit 1
  fi
  sleep "$wait"
done

previous='[]'
if [ -s "$declared" ]; then
  previous=$(jq -c 'if type == "array" then . else [] end' "$declared" 2>/dev/null || echo '[]')
fi
now=$(jq -c 'map(.id)' "$spec")

restart=()
count=$(jq length "$spec")
for ((i = 0; i < count; i++)); do
  client=$(jq -c --argjson i "$i" '.[$i]' "$spec")
  id=$(jq -r .id <<< "$client")
  id_file=$(jq -r .idFile <<< "$client")
  secret_file=$(jq -r .secretFile <<< "$client")
  owner=$(jq -r .owner <<< "$client")
  want=$(jq -c '{
    name: .displayName,
    callbackURLs: .redirectUris,
    logoutCallbackURLs: .logoutRedirectUris,
    isPublic: false,
    pkceEnabled: .pkce
  }' <<< "$client")
  created=
  changed=
  rm -f "$tmp/new-secret"

  status=$(request GET "/api/oidc/clients/$id")
  case $status in
    200)
      have=$(jq -c '{
        name,
        callbackURLs: (.callbackURLs // []),
        logoutCallbackURLs: (.logoutCallbackURLs // []),
        isPublic,
        pkceEnabled
      }' "$tmp/body")
      if [ "$(jq -cS . <<< "$have")" != "$(jq -cS . <<< "$want")" ]; then
        # The update replaces every field, so those the spec leaves to the
        # admin UI are sent back as they are. Pocket ID ignores the ones it
        # does not take, such as the secrets.
        body=$(jq -c --argjson want "$want" '. + $want' "$tmp/body")
        status=$(request PUT "/api/oidc/clients/$id" "$body")
        if [ "$status" != 200 ]; then
          echo "Pocket ID answered $status when updating client $id: $(cat "$tmp/body")" >&2
          exit 1
        fi
        echo "Updated client $id in Pocket ID."
      fi
      ;;
    404)
      status=$(request POST /api/oidc/clients "$(jq -c --arg id "$id" '. + {id: $id}' <<< "$want")")
      case $status in
        200 | 201) ;;
        *)
          echo "Pocket ID answered $status when creating client $id: $(cat "$tmp/body")" >&2
          exit 1
          ;;
      esac
      if [ "$(jq -r .id "$tmp/body")" != "$id" ]; then
        echo "Pocket ID made client $id with the id $(jq -r .id "$tmp/body") instead; it must keep the id it is given." >&2
        exit 1
      fi
      created=1
      # The secret Pocket ID makes with a new client, unless
      # AUTO_CREATE_OIDC_CLIENT_SECRET is off. Shown only in this answer.
      jq '.createdSecret // {}' "$tmp/body" > "$tmp/new-secret"
      rm -f "$tmp/body"
      echo "Created client $id in Pocket ID."
      ;;
    *)
      echo "Pocket ID answered $status when reading client $id: $(cat "$tmp/body")" >&2
      exit 1
      ;;
  esac

  if [ "$(cat "$id_file" 2>/dev/null || true)" != "$id" ]; then
    printf '%s' "$id" | write_secret_file "$id_file" "$owner"
    changed=1
    echo "Wrote the client id of $id to $id_file."
  fi

  if [ -n "$created" ] || [ ! -s "$secret_file" ] || ! secret_accepted "$id" "$secret_file"; then
    if [ "$(jq -r '.secret // ""' "$tmp/new-secret" 2>/dev/null)" = "" ]; then
      status=$(request POST "/api/oidc/clients/$id/secrets" '{}')
      if [ "$status" != 201 ]; then
        echo "Pocket ID answered $status when making a secret for client $id: $(cat "$tmp/body")" >&2
        exit 1
      fi
      mv -f "$tmp/body" "$tmp/new-secret"
    fi
    jq -j '.secret // error("no secret in the answer")' "$tmp/new-secret" | write_secret_file "$secret_file" "$owner"
    keep=$(jq -r .id "$tmp/new-secret")
    rm -f "$tmp/new-secret"
    changed=1
    echo "Wrote a new client secret of $id to $secret_file."

    # The secrets made before, by the admin UI, a failed run or Pocket ID
    # with the client, stop working.
    status=$(request GET "/api/oidc/clients/$id/secrets")
    if [ "$status" != 200 ]; then
      echo "Pocket ID answered $status when listing the secrets of client $id: $(cat "$tmp/body")" >&2
      exit 1
    fi
    while IFS= read -r secret_id; do
      status=$(request DELETE "/api/oidc/clients/$id/secrets/$secret_id")
      case $status in
        200 | 204 | 404) ;;
        *)
          echo "Pocket ID answered $status when deleting an old secret of client $id: $(cat "$tmp/body")" >&2
          exit 1
          ;;
      esac
      echo "Deleted an old secret of client $id."
    done < <(jq -r --arg keep "$keep" '.[].id | select(. != $keep)' "$tmp/body")
  fi

  if [ -n "$changed" ]; then
    while IFS= read -r unit; do
      restart+=("$unit")
    done < <(jq -r '.units[]' <<< "$client")
  fi
done

# Clients declared last time and no longer go.
while IFS= read -r id; do
  status=$(request DELETE "/api/oidc/clients/$id")
  case $status in
    200 | 204 | 404) echo "Deleted client $id from Pocket ID." ;;
    *)
      echo "Pocket ID answered $status when deleting client $id: $(cat "$tmp/body")" >&2
      exit 1
      ;;
  esac
done < <(jq -r --argjson now "$now" '.[] | select(. as $id | $now | index($id) | not)' <<< "$previous")

if [ "$now" != "$previous" ]; then
  next=$(mktemp "$(dirname "$declared")/.pocket-id-clients.XXXXXX")
  printf '%s\n' "$now" > "$next"
  mv -f "$next" "$declared"
fi

if [ "${#restart[@]}" -gt 0 ]; then
  # --no-block: the units are ordered after this one, and a restart of one
  # still starting would wait for this unit to finish.
  systemctl try-restart --no-block -- "${restart[@]}"
  echo "Restarted ${restart[*]} for their new client files."
fi
echo "Pocket ID's declared clients are up to date: $(jq -r 'join(" ")' <<< "$now")."
