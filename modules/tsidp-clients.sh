# Puts the host's declared OIDC clients into tsidp's clients file before
# tsidp starts, as root (ExecStartPre=+ of the tsidp unit).
#
#   tsidp-clients <spec file> <state directory>
#
# The spec is a JSON list from homelab.tsidp.clients, one object per client:
# id, redirectUris, idFile, secretFile and owner ("user:group"). For each:
#
# - The id file gets the id, and the secret file a random secret, when
#   missing or empty; a secret already there is kept. Both are mode 0400 and
#   owned by owner, written to a temporary file and renamed into place.
# - The client in <state directory>/oidc-funnel-clients.json, which tsidp
#   0.0.12 reads once at start (LoadFunnelClients in server/clients.go), is
#   set to the id, the name, the redirect URIs and the secret from the file.
#   Clients with other ids, registered by hand in tsidp's admin UI, are left
#   as they are.
#
# A client declared before and no longer is removed from tsidp; the ids
# declared last time are kept in <state directory>/homelab-clients.json. Its
# id and secret files are left. The clients file is written only when it
# changes, mode 0600 and owned like the state directory, which is tsidp's
# DynamicUser.

if [ "$#" -ne 2 ]; then
  echo "usage: tsidp-clients <spec file> <state directory>" >&2
  exit 2
fi
spec=$1
state=$2
clients=$state/oidc-funnel-clients.json
declared=$state/homelab-clients.json

# Writes stdin to the file, mode 0400 and owned by $2, by a rename.
write_secret_file() {
  local file=$1 owner=$2 dir tmp
  dir=$(dirname "$file")
  if [ ! -d "$dir" ]; then
    install -d -m 0700 "$dir"
  fi
  tmp=$(mktemp "$dir/.tsidp-clients.XXXXXX")
  cat > "$tmp"
  chmod 0400 "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$file"
}

# Writes stdin to a file in the state directory, mode 0600 and owned like
# the directory, by a rename.
write_state_file() {
  local file=$1 tmp
  tmp=$(mktemp "$state/.tsidp-clients.XXXXXX")
  cat > "$tmp"
  chmod 0600 "$tmp"
  chown --reference="$state" "$tmp"
  mv -f "$tmp" "$file"
}

if ! jq -e 'type == "array"' "$spec" >/dev/null; then
  echo "The spec $spec is not a JSON list." >&2
  exit 1
fi

current='{}'
if [ -s "$clients" ]; then
  if ! current=$(jq -c 'if type == "object" then . else error("not an object") end' "$clients"); then
    echo "tsidp's clients file $clients is not a JSON object; left as it is." >&2
    exit 1
  fi
fi
before=$(jq -cS . <<< "$current")

previous='[]'
if [ -s "$declared" ]; then
  previous=$(jq -c 'if type == "array" then . else [] end' "$declared" 2>/dev/null || echo '[]')
fi

ids=()
while IFS= read -r id; do
  ids+=("$id")
done < <(jq -r '.[].id' "$spec")

# Clients declared last time and no longer go.
current=$(jq -c --argjson previous "$previous" --slurpfile spec "$spec" '
  ($spec[0] | map(.id)) as $now
  | with_entries(select(.key as $k | ($previous | index($k)) == null or ($now | index($k)) != null))
' <<< "$current")

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in "${!ids[@]}"; do
  id=${ids[$i]}
  client=$(jq -c --argjson i "$i" '.[$i]' "$spec")
  id_file=$(jq -r .idFile <<< "$client")
  secret_file=$(jq -r .secretFile <<< "$client")
  owner=$(jq -r .owner <<< "$client")

  if [ "$(cat "$id_file" 2>/dev/null || true)" != "$id" ]; then
    printf '%s' "$id" | write_secret_file "$id_file" "$owner"
    echo "Wrote the client id of $id to $id_file."
  fi
  if [ ! -s "$secret_file" ]; then
    # 32 random bytes as hex, like the 64 hex digits tsidp makes itself.
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n' | write_secret_file "$secret_file" "$owner"
    echo "Generated the client secret of $id in $secret_file."
  fi

  # The secret goes to jq as a file, never on a command line. The file's
  # trailing newline is dropped, as the services reading it do.
  if ! current=$(jq -c --argjson client "$client" --rawfile secret "$secret_file" --arg now "$now" '
    ($secret | sub("\\s+$"; "")) as $s
    | if $s == "" then error("empty secret") else . end
    | .[$client.id] = ((.[$client.id] // {created_at: $now}) + {
        client_id: $client.id,
        client_secret: $s,
        client_name: $client.id,
        redirect_uris: $client.redirectUris,
        redirect_uri: $client.redirectUris[0]
      })
  ' <<< "$current"); then
    echo "Could not read the client secret of $id from $secret_file." >&2
    exit 1
  fi
done

if [ "$(jq -cS . <<< "$current")" != "$before" ]; then
  jq . <<< "$current" | write_state_file "$clients"
  echo "Updated tsidp's clients: ${ids[*]:-none declared}."
else
  echo "tsidp's clients are up to date: ${ids[*]:-none declared}."
fi
if [ "$(jq -c 'map(.id)' "$spec")" != "$previous" ]; then
  jq -c 'map(.id)' "$spec" | write_state_file "$declared"
fi
