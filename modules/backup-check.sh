# restic-check SUBSET TEXTFILE_DIR
#
# Checks the backup repository with restic check, reading SUBSET of its
# data packs (--read-data-subset: 5%, 1/7, 500M), and writes the result for
# the node exporter's textfile collector into
# TEXTFILE_DIR/homelab_restic_check.prom:
#
#   homelab_backup_check_last_run_timestamp_seconds     every run
#   homelab_backup_check_last_success_timestamp_seconds the last check that
#                                                       passed, kept on failure
#   homelab_backup_check_ok                             1 passed, 0 failed
#
# restic comes from PATH, with the repository and its credentials in the
# environment (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE and the rclone
# remote's). The script exits with restic's status, so a damaged repository
# also leaves the unit failed.

if [ "$#" -ne 2 ]; then
  echo "usage: restic-check SUBSET TEXTFILE_DIR" >&2
  exit 64
fi
subset=$1
dir=$2
out=$dir/homelab_restic_check.prom

status=0
restic check --read-data-subset="$subset" || status=$?
now=$(date +%s)

if [ "$status" -eq 0 ]; then
  ok=1
  last_success=$now
else
  ok=0
  last_success=$(awk '$1 == "homelab_backup_check_last_success_timestamp_seconds" { print $2 }' "$out" 2>/dev/null || true)
  case "$last_success" in *[!0-9]* | "") last_success= ;; esac
fi

# Written under a name without .prom and renamed, so a scrape never sees
# half of it.
mkdir -p "$dir"
{
  echo '# HELP homelab_backup_check_last_run_timestamp_seconds When the backup repository check last ran.'
  echo '# TYPE homelab_backup_check_last_run_timestamp_seconds gauge'
  echo "homelab_backup_check_last_run_timestamp_seconds $now"
  if [ -n "$last_success" ]; then
    echo '# HELP homelab_backup_check_last_success_timestamp_seconds When the backup repository check last passed.'
    echo '# TYPE homelab_backup_check_last_success_timestamp_seconds gauge'
    echo "homelab_backup_check_last_success_timestamp_seconds $last_success"
  fi
  echo '# HELP homelab_backup_check_ok Whether the last backup repository check passed.'
  echo '# TYPE homelab_backup_check_ok gauge'
  echo "homelab_backup_check_ok $ok"
} > "$out.tmp"
mv "$out.tmp" "$out"

if [ "$status" -ne 0 ]; then
  echo "restic check failed with status $status; the repository needs a repair (docs/backups.md, "Repository check")" >&2
fi
exit "$status"
