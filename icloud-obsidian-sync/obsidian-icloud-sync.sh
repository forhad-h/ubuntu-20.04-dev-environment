#!/usr/bin/env bash
set -euo pipefail

VAULT_LOCAL="$HOME/Documents/Obsidian Vault"
VAULT_REMOTE="iclouddrive:Documents/Obsidian Vault"
FILTERS="$HOME/.config/rclone/obsidian-filters.txt"
LOG_DIR="$HOME/.local/share/obsidian-icloud-sync"
LOG_FILE="$LOG_DIR/sync.log"
LOCK_FILE="$LOG_DIR/sync.lock"

mkdir -p "$LOG_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date -Iseconds) Skipped: previous sync still running" >>"$LOG_FILE"
    exit 0
fi

{
    echo "=== $(date -Iseconds) starting sync ==="
    if rclone bisync "$VAULT_LOCAL" "$VAULT_REMOTE" --filters-file "$FILTERS" --conflict-resolve newer -v; then
        echo "=== $(date -Iseconds) sync OK ==="
    else
        status=$?
        echo "=== $(date -Iseconds) sync FAILED (exit $status) ==="
        DISPLAY="${DISPLAY:-:0}" notify-send -u critical "Obsidian iCloud sync failed" \
            "Check $LOG_FILE — trust token may have expired. Run: rclone config reconnect iclouddrive:" || true
        exit "$status"
    fi
} >>"$LOG_FILE" 2>&1
