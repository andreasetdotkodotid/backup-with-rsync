#!/bin/bash
set -Eeuo pipefail

##########################################################################
# Load Environment
##########################################################################

ENV_FILE="$PWD/backup-filesystem.env"

METRIC_HOST="${METRIC_HOST:-$(hostname -f)}"
BACKUP_TYPE="${BACKUP_TYPE:-filesystem}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-3x_week}"

start_time=$(date +%s)

backup_result=0
backup_exit_code=0

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found."
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

##########################################################################
# Validate Configuration
##########################################################################

: "${RSYNC_PASSWORD:?RSYNC_PASSWORD is required}"
: "${BACKUP_HOST_MEDAN:?BACKUP_HOST_MEDAN is required}"
: "${BACKUP_HOST_JAKARTA:?BACKUP_HOST_JAKARTA is required}"

BACKUP_USER="${BACKUP_USER:-$(hostname -f)}"

if [[ -z "$BACKUP_USER" ]]; then
    BACKUP_USER="$(hostname -f)"
fi

BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-300}"
BACKUP_CONNECT_TIMEOUT="${BACKUP_CONNECT_TIMEOUT:-60}"
BACKUP_LOCK_FILE="${BACKUP_LOCK_FILE:-/var/lock/rsync-fullbackup.lock}"

##########################################################################
# Lock
##########################################################################

mkdir -p "$(dirname "$BACKUP_LOCK_FILE")"

exec 9>"$BACKUP_LOCK_FILE"

flock -n 9 || {
    echo "$(date -Is) Backup already running."
    exit 1
}

##########################################################################
# Temporary Exclude File
##########################################################################

tmp=$(mktemp)

trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<'EOF'
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


push_metric() {

    local ts
    ts=$(date +%s)

    local duration
    duration=$((ts - start_time))

    local body="backup_status{host=\"$METRIC_HOST\",job=\"backup-exporter\",type=\"$BACKUP_TYPE\",name=\"$rsync_target\",schedule=\"$BACKUP_SCHEDULE\"} $backup_result
backup_last_run_timestamp_seconds{host=\"$METRIC_HOST\",job=\"backup-exporter\",type=\"$BACKUP_TYPE\",name=\"$rsync_target\",schedule=\"$BACKUP_SCHEDULE\"} $ts
backup_duration_seconds{host=\"$METRIC_HOST\",job=\"backup-exporter\",type=\"$BACKUP_TYPE\",name=\"$rsync_target\",schedule=\"$BACKUP_SCHEDULE\"} $duration
backup_exit_code{host=\"$METRIC_HOST\",job=\"backup-exporter\",type=\"$BACKUP_TYPE\",name=\"$rsync_target\",schedule=\"$BACKUP_SCHEDULE\"} $backup_exit_code"

    if [[ $backup_result -eq 1 ]]; then
        body="$body
backup_last_success_timestamp_seconds{host=\"$METRIC_HOST\",job=\"backup-exporter\",type=\"$BACKUP_TYPE\",name=\"$rsync_target\",schedule=\"$BACKUP_SCHEDULE\"} $ts"
    fi

    curl -fsS \
        -X POST \
        "$METRICS_URL" \
        -H "Authorization: $METRICS_AUTH" \
        -H "Content-Type: text/plain" \
        --data-binary "$body" \
        >/dev/null || true
}


##########################################################################
# Backup Function
##########################################################################

cmd_rsync() {

    #
    # Remove old marker
    #
    find / -maxdepth 1 -type f -name 'snap-*-rsync' -delete

    #
    # Create new marker
    #
    MARKER_FILE="/snap-$(date +%Y%m%d)-rsync"

    cat > "$MARKER_FILE" <<EOF
Backup Date : $(date -Is)
Hostname    : $(hostname -f 2>/dev/null || hostname)
EOF

    echo "=================================================="
    echo "Start Time  : $(date -Is)"
    echo "Source      : /"
    echo "Destination : rsync://$rsync_user@$rsync_host/$rsync_target"
    echo

    RSYNC_OPTS=(
        -aAXH
        --no-devices
        --no-specials
        --numeric-ids
        --delete-delay
        --partial
        --timeout="$BACKUP_TIMEOUT"
        --contimeout="$BACKUP_CONNECT_TIMEOUT"
        --stats
        --exclude-from="$tmp"
    )

    set +e

    rsync \
        "${RSYNC_OPTS[@]}" \
        / \
        "rsync://$rsync_user@$rsync_host/$rsync_target"

    backup_exit_code=$?

    set -e

    if [[ $backup_exit_code -eq 0 ]]; then
        backup_result=1
        echo "$(date -Is) Backup completed successfully."
    else
        backup_result=0
        echo "$(date -Is) Backup failed. Exit code: $backup_exit_code"
    fi

    push_metric

    return "$backup_exit_code"
}

##########################################################################
# Schedule
##########################################################################

weekday=$(date +%u)

case "$weekday" in

    7)
        #
        # Sunday -> Medan
        #
        rsync_host="$BACKUP_HOST_MEDAN"
        rsync_user="$BACKUP_USER"
        rsync_target="backup-$rsync_user/fs/"
        cmd_rsync
        ;;

    2|4)
        #
        # Tuesday & Thursday -> Jakarta
        #
        rsync_host="$BACKUP_HOST_JAKARTA"
        rsync_user="$BACKUP_USER"
        rsync_target="$rsync_user/filesystem/$weekday/"
        cmd_rsync
        ;;

    *)
        echo "$(date -Is) No backup schedule today."
        ;;
esac
