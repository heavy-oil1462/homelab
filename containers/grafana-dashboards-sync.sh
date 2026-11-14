# Copies Grafana's dashboards from one directory of one branch of a Git
# repository into the directory the grafana container provisions from
# (docs/adr/0008-dashboards-synced-from-git.md).
#
#   grafana-dashboards-sync <url> <branch> <path> <key file> <state dir> <live dir>
#
# Fetches the branch's head into a bare repository under <state dir>, with
# the SSH key in <key file>, and extracts <path> of it into a staging
# directory. Every *.json there must parse as a JSON object with a
# non-empty string title. Only then is the staging directory copied into
# <live dir> with rsync --delete, each file renamed into place, so Grafana
# sees whole files. A failed fetch or a bad commit leaves <live dir> as it
# was, says why and exits non-zero, which fails the unit.
#
# The last commit synced, with the URL, branch and path it came from, is
# in <state dir>/synced; a run that finds the same again does nothing and
# stays quiet. Host keys are trusted on first use
# and kept in <state dir>/known_hosts.

if [ "$#" -ne 6 ]; then
  echo "usage: grafana-dashboards-sync <url> <branch> <path> <key file> <state dir> <live dir>" >&2
  exit 2
fi
url=$1
branch=$2
path=${3%/}
key_file=$4
state=$5
live=$6
repo=$state/repo.git
staging=$state/staging

fail() {
  echo "dashboards not synced, Grafana keeps the last good set: $*" >&2
  exit 1
}

mkdir -p "$state" "$live"
if [ ! -d "$repo" ]; then
  git init --quiet --bare "$repo"
fi

export GIT_SSH_COMMAND="ssh -i $key_file -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$state/known_hosts"
# The repository's own configuration never runs anything here.
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

if ! git -C "$repo" fetch --quiet --depth 1 --no-tags "$url" "+refs/heads/$branch:refs/heads/sync" 2>"$state/fetch.err"; then
  fail "fetching branch $branch failed: $(cat "$state/fetch.err")"
fi
commit=$(git -C "$repo" rev-parse --verify "sync^{commit}")

synced_from="$url $branch $path $commit"
if [ -e "$state/synced" ] && [ "$(cat "$state/synced")" = "$synced_from" ]; then
  exit 0
fi

rm -rf "$staging"
mkdir -p "$staging"
if ! git -C "$repo" archive --format=tar sync -- "$path" 2>"$state/archive.err" | tar -x -C "$staging"; then
  fail "commit $commit has no directory $path: $(cat "$state/archive.err")"
fi
src=$staging/$path
[ -d "$src" ] || fail "$path is not a directory in commit $commit"

bad=0
while IFS= read -r -d '' file; do
  if ! jq -e 'type == "object" and (.title | type == "string" and length > 0)' "$file" >/dev/null 2>&1; then
    echo "${file#"$src"/} in commit $commit is not JSON with a title" >&2
    bad=1
  fi
done < <(find "$src" -type f -name '*.json' -print0)
[ "$bad" -eq 0 ] || fail "commit $commit has invalid dashboards"

# Regular files and directories only: rsync without --links leaves out
# symbolic links, which could point anywhere on the host.
rsync --recursive --times --perms --checksum --delete --chmod=D0755,F0644 "$src/" "$live/" \
  || fail "copying commit $commit into $live failed"
echo "$synced_from" > "$state/synced"
echo "dashboards synced from $branch at $commit"
rm -rf "$staging"
