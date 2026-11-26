# restic-prune TEXTFILE_DIR
#
# Prunes the backup repository: removes the data no snapshot refers to any
# more, after the jobs have forgotten their old snapshots. It first removes
# stale locks, those of restic processes that died, as the jobs did before
# their forget --prune. It writes the result for the node exporter's
# textfile collector into TEXTFILE_DIR/homelab_restic_prune.prom:
#
#   homelab_backup_prune_last_run_timestamp_seconds     every run
#   homelab_backup_prune_last_success_timestamp_seconds the last prune that
#                                                       succeeded, kept on
#                                                       failure
#   homelab_backup_prune_ok                             1 succeeded, 0 failed
#
# restic comes from PATH, with the repository and its credentials in the
# environment (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE and the rclone
# remote's). The script exits with restic's status, so a failed prune also
# leaves the unit failed.

if [ "$#" -ne 1 ]; then
  echo "usage: restic-prune TEXTFILE_DIR" >&2
  exit 64
fi
dir=$1
out=$dir/homelab_restic_prune.prom

status=0
restic unlock || status=$?
if [ "$status" -eq 0 ]; then
  restic prune || status=$?
fi
now=$(date +%s)

if [ "$status" -eq 0 ]; then
  ok=1
  last_success=$now
else
  ok=0
  last_success=$(awk '$1 == "homelab_backup_prune_last_success_timestamp_seconds" { print $2 }' "$out" 2>/dev/null || true)
  case "$last_success" in *[!0-9]* | "") last_success= ;; esac
fi

# Written under a name without .prom and renamed, so a scrape never sees
# half of it.
mkdir -p "$dir"
{
  echo '# HELP homelab_backup_prune_last_run_timestamp_seconds When the backup repository prune last ran.'
  echo '# TYPE homelab_backup_prune_last_run_timestamp_seconds gauge'
  echo "homelab_backup_prune_last_run_timestamp_seconds $now"
  if [ -n "$last_success" ]; then
    echo '# HELP homelab_backup_prune_last_success_timestamp_seconds When the backup repository prune last succeeded.'
    echo '# TYPE homelab_backup_prune_last_success_timestamp_seconds gauge'
    echo "homelab_backup_prune_last_success_timestamp_seconds $last_success"
  fi
  echo '# HELP homelab_backup_prune_ok Whether the last backup repository prune succeeded.'
  echo '# TYPE homelab_backup_prune_ok gauge'
  echo "homelab_backup_prune_ok $ok"
} > "$out.tmp"
mv "$out.tmp" "$out"

if [ "$status" -ne 0 ]; then
  echo "restic prune failed with status $status; check the repository (docs/backups.md, \"Prune\")" >&2
fi
exit "$status"
