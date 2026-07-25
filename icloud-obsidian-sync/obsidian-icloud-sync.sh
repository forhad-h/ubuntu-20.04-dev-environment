#!/usr/bin/env bash
set -euo pipefail

VAULT_LOCAL="$HOME/Documents/Obsidian Vault"
VAULT_REMOTE="iclouddrive:Documents/Obsidian Vault"
FILTERS="$HOME/.config/rclone/obsidian-filters.txt"
LOG_DIR="$HOME/.local/share/obsidian-icloud-sync"
LOG_FILE="$LOG_DIR/sync.log"
LOCK_FILE="$LOG_DIR/sync.lock"
# Persistent bisync state — deliberately NOT under ~/.cache, which is disposable
# and was being wiped mid-session (losing the baseline listings).
WORKDIR="$LOG_DIR/bisync-workdir"

mkdir -p "$LOG_DIR" "$WORKDIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date -Iseconds) Skipped: previous sync still running" >>"$LOG_FILE"
    exit 0
fi

# notify <urgency> <title> <body>
notify() {
    DISPLAY="${DISPLAY:-:0}" notify-send -u "$1" "$2" "$3" || true
}

# Hardened flag set shared by the normal run and the recovery run.
# --resilient --recover --max-lock let bisync auto-recover from stale locks /
# interrupted prior runs on the next run instead of hard-aborting.
COMMON=(--filters-file "$FILTERS" --conflict-resolve newer
        --workdir "$WORKDIR" --resilient --recover --max-lock 2m -v)

echo "=== $(date -Iseconds) starting sync ===" >>"$LOG_FILE"

# Capture output so we can both log it and diagnose the failure cause.
set +e
out="$(rclone bisync "$VAULT_LOCAL" "$VAULT_REMOTE" "${COMMON[@]}" 2>&1)"
status=$?
set -e
printf '%s\n' "$out" >>"$LOG_FILE"

if [ "$status" -eq 0 ]; then
    echo "=== $(date -Iseconds) sync OK ===" >>"$LOG_FILE"
    exit 0
fi

echo "=== $(date -Iseconds) sync FAILED (exit $status) ===" >>"$LOG_FILE"

# Lost baseline listings ("must run --resync"): self-heal by rebuilding them once.
if printf '%s' "$out" | grep -qiE 'must run --resync|cannot find prior|prior Path1 or Path2 listings'; then
    echo "=== $(date -Iseconds) baseline lost — auto-recovering with --resync ===" >>"$LOG_FILE"
    set +e
    rout="$(rclone bisync "$VAULT_LOCAL" "$VAULT_REMOTE" "${COMMON[@]}" --resync 2>&1)"
    rstatus=$?
    set -e
    printf '%s\n' "$rout" >>"$LOG_FILE"

    if [ "$rstatus" -eq 0 ]; then
        echo "=== $(date -Iseconds) auto-recovery OK (--resync) ===" >>"$LOG_FILE"
        notify normal "Obsidian iCloud sync recovered" \
            "Baseline listings were lost; rebuilt automatically with --resync. Sync is healthy again."
        exit 0
    fi

    echo "=== $(date -Iseconds) auto-recovery FAILED (exit $rstatus) ===" >>"$LOG_FILE"
    notify critical "Obsidian iCloud sync failed" \
        "Automatic --resync recovery also failed (exit $rstatus). Check $LOG_FILE. Last lines: $(printf '%s' "$rout" | tail -n 3)"
    exit "$rstatus"
fi

# Other failures: classify and notify with the right fix.
if printf '%s' "$out" | grep -qiE 'oauth|token|401|403|unauthor|reconnect|expired|invalid_grant|missing.*token'; then
    msg="iCloud auth/trust token appears expired. Fix: rclone config reconnect iclouddrive:"
elif printf '%s' "$out" | grep -qiE 'too many changes|--force|deltas'; then
    msg="Too many changes since last sync (safety abort). Review the diff, then re-run with --resync or --force."
elif printf '%s' "$out" | grep -qiE 'directory not found|no such file|failed to (stat|open)|not mounted|transport endpoint'; then
    msg="Vault path or remote not reachable (drive unmounted?). Verify $VAULT_LOCAL exists and iCloud remote is up."
else
    msg="Unclassified failure (exit $status). Check $LOG_FILE for details."
fi

notify critical "Obsidian iCloud sync failed" "$msg — see $LOG_FILE"
exit "$status"
