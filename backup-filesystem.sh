#!/bin/bash
set -Eeuo pipefail

export RSYNC_PASSWORD="PASSWORD"

LOG_DIR="/var/log/backup"
LOG_FILE="$LOG_DIR/rsync-fullbackup-$(date +%Y%m%d).log"
LOCK_FILE="/var/lock/rsync-fullbackup.lock"
MARKER_FILE="/root/.backup-marker"

exec 9>"$LOCK_FILE"
flock -n 9 || {
  echo "$(date -Is) Backup already running" | tee -a "$LOG_FILE"
  exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" << 'EOF'
/dev/*
/proc/*
/sys/*
/tmp/*
/run/*
/mnt/*
/media/*
/cdrom/*
/lost+found
/snap/*
/var/lib/snapd/snaps/*
/var/lib/snapd/cache/*
/var/cache/*
/var/tmp/*
/var/log/journal/*
/var/lib/systemd/coredump/*
EOF

cmd_rsync() {
  : "${rsync_host:?rsync_host is empty}"
  : "${rsync_user:?rsync_user is empty}"
  : "${rsync_target:?rsync_target is empty}"

  echo "Backup date: $(date -Is)" > "$MARKER_FILE"
  echo "Hostname: $(hostname -f 2>/dev/null || hostname)" >> "$MARKER_FILE"

  echo "==================================================" | tee -a "$LOG_FILE"
  echo "$(date -Is) Starting backup to rsync://$rsync_user@$rsync_host/$rsync_target" | tee -a "$LOG_FILE"

  rm -rf /snap-*
  touch /snap-$(date +%Y%m%d)
  rsync -aAXHv \
    --numeric-ids \
    --delete-delay \
    --partial \
    --timeout=300 \
    --contimeout=60 \
    --exclude-from="$tmp" \
    / "rsync://$rsync_user@$rsync_host/$rsync_target" \
    >> "$LOG_FILE" 2>&1

  rc=$?

  if [ "$rc" -eq 0 ]; then
    echo "$(date -Is) Backup completed successfully" | tee -a "$LOG_FILE"
  else
    echo "$(date -Is) Backup failed with exit code $rc" | tee -a "$LOG_FILE"
  fi

  return "$rc"
}

weekday=$(date +%u)

if [ "$weekday" = "7" ]; then
  # Sunday: store to Medan
  rsync_host="IP-BACKUP-MEDAN"
  rsync_user="$(hostname -f)"
  rsync_target="backup-$rsync_user/fs/"
  cmd_rsync

elif [[ "$weekday" =~ ^(2|4)$ ]]; then
  # Tuesday and Thursday: store to Jakarta
  rsync_host="IP-BACKUP-JAKARTA"
  rsync_user="$(hostname -f)"
  rsync_target="$rsync_user/filesystem/$weekday/"
  cmd_rsync

else
  echo "$(date -Is) No backup schedule for weekday $weekday" | tee -a "$LOG_FILE"
fi
