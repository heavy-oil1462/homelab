# restic-restore-test CONFIG
#
# Restores the latest snapshot of every backup job into a scratch
# directory and checks that its data comes back whole and usable:
#
# - the job has a snapshot of this host, at most maxAgeSeconds old;
# - restic restore --verify restores it and reads every file back against
#   the snapshot's content hashes;
# - the restored regular files and their bytes match the counts restic
#   kept in the snapshot's summary;
# - every SQLite database of the job (its copy under STAGING/<job>)
#   passes PRAGMA integrity_check and has a table;
# - every git repository among the restored files (a directory with HEAD
#   and objects/, bare or not) passes git fsck, all of them within
#   gitFsckTimeoutSeconds.
#
# CONFIG is JSON:
#
#   { "textfileDir": "/var/lib/prometheus-node-exporter/textfile",
#     "scratchDir": "/var/tmp/restic-restore-test",
#     "stagingDir": "/var/backup",
#     "gitFsckTimeoutSeconds": 3600, "maxAgeSeconds": 172800,
#     "jobs": [ { "name": "forgejo",
#                 "sqliteDatabases": [ "/var/lib/forgejo/data/gitea.db" ] } ] }
#
# Each job's result goes to TEXTFILE_DIR/homelab_restore_test.prom for the
# node exporter's textfile collector, rewritten after every job:
#
#   homelab_backup_restore_test_ok{backup_job}                1 passed, 0 failed
#   homelab_backup_restore_test_last_run_timestamp_seconds{backup_job}
#   homelab_backup_restore_test_last_success_timestamp_seconds{backup_job}
#                                                    kept from earlier runs
#   homelab_backup_restore_test_restored_bytes{backup_job}
#                                                    when this run restored
#
# Every job logs one line, its summary or why it failed. restic comes from
# PATH, with the repository and its credentials in the environment. The
# script exits 1 when any job failed.

if [ "$#" -ne 1 ]; then
  echo "usage: restic-restore-test CONFIG" >&2
  exit 64
fi
config=$1
textfile=$(jq -r .textfileDir "$config")
scratch=$(jq -r .scratchDir "$config")
staging=$(jq -r .stagingDir "$config")
git_timeout=$(jq -r .gitFsckTimeoutSeconds "$config")
max_age=$(jq -r .maxAgeSeconds "$config")
mapfile -t jobs < <(jq -r '.jobs[].name' "$config")
out=$textfile/homelab_restore_test.prom
host=$(cat /proc/sys/kernel/hostname)

# A restored repository is owned by its service's user, which git refuses
# to look at by default; nothing of the host's git config applies either.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# The restore goes into SCRATCH/<job>, which holds this marker. A directory
# without it is not ours and is never restored into or removed.
marker=.restic-restore-test
current=
cleanup() {
  if [ -n "$current" ] && [ -e "$current/$marker" ]; then
    rm -rf -- "$current"
  fi
  current=
}
trap cleanup EXIT

# The label value as the exposition format needs it.
label() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "${s//$'\n'/\\n}"
}

# The value of metric{backup_job="<job>"} in the file as it was before
# this run, or nothing.
previous() {
  local prefix
  prefix="$1{backup_job=\"$(label "$2")\"} "
  [ -f "$out" ] || return 0
  awk -v p="$prefix" 'index($0, p) == 1 { v = $NF } END { print v }' "$out"
}

declare -A ok last_run last_success restored
for job in "${jobs[@]}"; do
  ok[$job]=$(previous homelab_backup_restore_test_ok "$job")
  last_run[$job]=$(previous homelab_backup_restore_test_last_run_timestamp_seconds "$job")
  last_success[$job]=$(previous homelab_backup_restore_test_last_success_timestamp_seconds "$job")
  restored[$job]=
done

# One metric for every job that has a value. Written under a name without
# .prom and renamed, so a scrape never sees half of it.
write_metric() {
  local name=$1 help=$2 job
  local -n values=$3
  local any=
  for job in "${jobs[@]}"; do
    case "${values[$job]}" in *[!0-9]* | "") continue ;; esac
    if [ -z "$any" ]; then
      echo "# HELP $name $help"
      echo "# TYPE $name gauge"
      any=1
    fi
    echo "$name{backup_job=\"$(label "$job")\"} ${values[$job]}"
  done
}
write_metrics() {
  mkdir -p "$textfile"
  {
    write_metric homelab_backup_restore_test_ok 'Whether the last restore test of the backup job passed.' ok
    write_metric homelab_backup_restore_test_last_run_timestamp_seconds 'When the restore test of the backup job last ran.' last_run
    write_metric homelab_backup_restore_test_last_success_timestamp_seconds 'When the restore test of the backup job last passed.' last_success
    write_metric homelab_backup_restore_test_restored_bytes 'Bytes the last restore test of the backup job restored.' restored
  } > "$out.tmp"
  mv "$out.tmp" "$out"
}

# Tests one job, setting summary on success and reason on failure.
test_job() {
  local job=$1 dir snapshots id short time time_s now files bytes
  local expect_files expect_bytes restore_json db ndb=0 ngit=0 head repo deadline left status
  summary='' reason=''
  case "$job" in */* | . | .. | "") reason="the job name is no directory name"; return 1 ;; esac

  if ! snapshots=$(restic snapshots --no-lock --json --latest 1 --tag "$job" --host "$host"); then
    reason="restic could not list the snapshots"
    return 1
  fi
  if ! read -r id short time < <(jq -r 'if length == 0 then empty else max_by(.time) | "\(.id) \(.short_id) \(.time)" end' <<< "$snapshots") \
    || [ -z "$id" ]; then
    reason="no snapshot tagged $job of host $host"
    return 1
  fi
  if ! time_s=$(date -d "$time" +%s); then
    reason="snapshot $short has a time date cannot read: $time"
    return 1
  fi
  time=$(date -u -d "@$time_s" +%Y-%m-%dT%H:%M:%SZ)
  now=$(date +%s)
  if [ $((now - time_s)) -gt "$max_age" ]; then
    reason="the latest snapshot, $short of $time, is older than $((max_age / 3600)) hours"
    return 1
  fi

  dir=$scratch/$job
  if [ -e "$dir" ] && [ ! -e "$dir/$marker" ]; then
    reason="$dir exists and is not a restore test's; remove it by hand"
    return 1
  fi
  current=$dir
  rm -rf -- "$dir"
  mkdir -m 0700 -- "$dir"
  touch "$dir/$marker"

  if ! restore_json=$(restic restore "$id" --target "$dir" --verify --json); then
    reason="restic restore --verify of snapshot $short of $time failed"
    return 1
  fi
  restored[$job]=$(jq -r 'select(.message_type == "summary") | .bytes_restored' <<< "$restore_json" | tail -n 1)

  # restic counts regular files in the summary of snapshots it made since
  # 0.17; older ones have none to compare with.
  read -r files bytes < <(find "$dir" -type f ! -path "$dir/$marker" -printf '%s\n' \
    | awk '{ n++; s += $1 } END { printf "%d %d\n", n, s }')
  read -r expect_files expect_bytes < <(jq -r 'max_by(.time) | .summary // {}
    | "\(.total_files_processed // "") \(.total_bytes_processed // "")"' <<< "$snapshots")
  if [ -n "$expect_files" ] && [ "$files" != "$expect_files" ]; then
    reason="restored $files files, the snapshot $short has $expect_files"
    return 1
  fi
  if [ -n "$expect_bytes" ] && [ "$bytes" != "$expect_bytes" ]; then
    reason="restored $bytes bytes of files, the snapshot $short has $expect_bytes"
    return 1
  fi

  while IFS= read -r db; do
    local copy=$dir$staging/$job$db result tables
    if [ ! -f "$copy" ]; then
      reason="the database copy $staging/$job$db is not in snapshot $short"
      return 1
    fi
    result=$(sqlite3 -bail "$copy" <<< 'PRAGMA integrity_check;' 2>&1) || true
    if [ "$result" != ok ]; then
      reason="database $db fails its integrity check: $(head -n 3 <<< "$result" | tr '\n' ' ')"
      return 1
    fi
    tables=$(sqlite3 -bail "$copy" <<< "SELECT count(*) FROM sqlite_schema WHERE type = 'table';" 2>&1) || true
    case "$tables" in *[!0-9]* | "" | 0)
      reason="database $db has no tables"
      return 1 ;;
    esac
    ndb=$((ndb + 1))
  done < <(jq -r --arg job "$job" '.jobs[] | select(.name == $job) | .sqliteDatabases[]' "$config")

  deadline=$(($(date +%s) + git_timeout))
  while IFS= read -r -d '' head; do
    repo=${head%/HEAD}
    [ -d "$repo/objects" ] || continue
    left=$((deadline - $(date +%s)))
    if [ "$left" -le 0 ]; then
      reason="git fsck of the repositories took over ${git_timeout}s, at ${repo#"$dir"}"
      return 1
    fi
    status=0
    timeout "$left" git -c safe.directory='*' --git-dir="$repo" fsck --no-dangling --no-progress >&2 || status=$?
    if [ "$status" -eq 124 ]; then
      reason="git fsck of the repositories took over ${git_timeout}s, at ${repo#"$dir"}"
      return 1
    elif [ "$status" -ne 0 ]; then
      reason="git fsck of ${repo#"$dir"} failed"
      return 1
    fi
    ngit=$((ngit + 1))
  done < <(find "$dir" -type f -name HEAD -print0)

  summary=$(awk -v j="$job" -v s="$short" -v t="$time" -v n="$files" -v b="${restored[$job]:-$bytes}" -v d="$ndb" -v g="$ngit" 'BEGIN {
    printf "%s: snapshot %s of %s, %d files, %.1f MiB restored and verified, %d databases ok, %d git repositories ok", j, s, t, n, b / 1048576, d, g }')
}

mkdir -p "$scratch"
chmod 0700 "$scratch"
failed=0
for job in "${jobs[@]}"; do
  if test_job "$job"; then
    echo "$summary"
    ok[$job]=1
    last_success[$job]=$(date +%s)
    last_run[$job]=${last_success[$job]}
  else
    echo "$job: FAILED: $reason" >&2
    # shellcheck disable=SC2034 # read through write_metric's nameref
    ok[$job]=0
    # shellcheck disable=SC2034
    last_run[$job]=$(date +%s)
    failed=$((failed + 1))
  fi
  cleanup
  write_metrics
done

if [ "$failed" -ne 0 ]; then
  echo "$failed of ${#jobs[@]} backup jobs failed their restore test; docs/backups.md, \"Restore test\"" >&2
  exit 1
fi
