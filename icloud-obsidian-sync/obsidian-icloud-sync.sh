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

# Outage bookkeeping. Being offline is normal, not a fault, so it is skipped
# quietly and escalated exactly once — only after the vault has been stale long
# enough to actually matter.
OFFLINE_SINCE="$LOG_DIR/offline-since"       # epoch of the first offline run
OFFLINE_NOTIFIED="$LOG_DIR/offline-notified" # marker: at most one alert/outage
OFFLINE_ALERT_AFTER=1800                     # 30 minutes

MAX_LOG_BYTES=$((5 * 1024 * 1024))

mkdir -p "$LOG_DIR" "$WORKDIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date -Iseconds) Skipped: previous sync still running" >>"$LOG_FILE"
    exit 0
fi

# Rotate under the lock so two runs cannot race the move. One generation is
# plenty: this log is a diagnostic tail, not an archive.
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

# log <message>
log() {
    echo "=== $(date -Iseconds) $1 ===" >>"$LOG_FILE"
}

# notify <urgency> <title> <body>
notify() {
    DISPLAY="${DISPLAY:-:0}" notify-send -u "$1" "$2" "$3" || true
}

# online — cheap, bounded reachability probe.
# DNS first, because that is exactly what fails when the machine is offline and
# it is where rclone burns 3+ minutes before giving up. Then a TLS HEAD, which
# is what catches a captive portal: it cannot present a valid cert for this
# host, so the TLS handshake fails even though its DNS answers happily.
# Worst case here is ~13s instead of 3m20s.
#
# The URL must answer <400 — curl -f treats 4xx as failure and would report a
# permanent false outage. www.icloud.com answers 200.
online() {
    timeout 5 getent hosts www.icloud.com >/dev/null 2>&1 || return 1
    curl -sfI --max-time 8 https://www.icloud.com >/dev/null 2>&1
}

# offline_since — epoch when the current outage started, healing a missing or
# corrupt state file by treating now as the start.
offline_since() {
    local now since
    now=$(date +%s)
    since=$(cat "$OFFLINE_SINCE" 2>/dev/null || true)
    case "$since" in
        '' | *[!0-9]*) since=$now ;;
    esac
    printf '%s' "$since"
}

# begin_outage <log message> — record the start of an outage (logging only on
# the first run of it, so an offline night does not add one line every 2
# minutes), then escalate once if the vault has been stale past the threshold.
begin_outage() {
    local now since elapsed
    now=$(date +%s)

    if [ -f "$OFFLINE_SINCE" ]; then
        since=$(offline_since)
    else
        since=$now
        printf '%s\n' "$since" >"$OFFLINE_SINCE"
        log "$1"
    fi

    elapsed=$((now - since))
    if [ "$elapsed" -ge "$OFFLINE_ALERT_AFTER" ] && [ ! -f "$OFFLINE_NOTIFIED" ]; then
        : >"$OFFLINE_NOTIFIED"
        log "offline for $((elapsed / 60))m — notified once"
        notify normal "Obsidian iCloud sync paused" \
            "No connection for $((elapsed / 60)) minutes, so the vault is not syncing. It will resume on its own once you are back online."
    fi
}

# end_outage — clear the bookkeeping once connectivity is back.
end_outage() {
    local now since
    [ -f "$OFFLINE_SINCE" ] || return 0
    now=$(date +%s)
    since=$(offline_since)
    log "network restored after $(( (now - since) / 60 ))m — resuming"
    rm -f "$OFFLINE_SINCE" "$OFFLINE_NOTIFIED"
}

# Anything here means "the network went away", not "the sync is broken". rclone
# reports these as bisync critical errors, but they are retryable without
# --resync thanks to --resilient, so the next run just picks up where it left off.
NETWORK_ERRORS='dial tcp|i/o timeout|no such host|lookup .+ on |network is unreachable|no route to host|TLS handshake timeout|temporary failure in name resolution|connection reset by peer|error reading destination root directory'

# Don't even start if the remote is unreachable — the failure is guaranteed and
# slow, and it used to surface as a critical "unclassified failure" popup.
if ! online; then
    begin_outage "skipped: offline (iCloud unreachable)"
    exit 0
fi
end_outage

# Hardened flag set shared by the normal run and the recovery run.
# --resilient --recover --max-lock let bisync auto-recover from stale locks /
# interrupted prior runs on the next run instead of hard-aborting.
COMMON=(--filters-file "$FILTERS" --conflict-resolve newer
        --workdir "$WORKDIR" --resilient --recover --max-lock 2m -v)

log "starting sync"

# Capture output so we can both log it and diagnose the failure cause.
set +e
out="$(rclone bisync "$VAULT_LOCAL" "$VAULT_REMOTE" "${COMMON[@]}" 2>&1)"
status=$?
set -e
printf '%s\n' "$out" >>"$LOG_FILE"

if [ "$status" -eq 0 ]; then
    log "sync OK"
    exit 0
fi

log "sync FAILED (exit $status)"

# The preflight probe is inherently a race: a multi-minute bisync can lose the
# connection after the probe passed. Checked before everything else so we never
# burn a --resync attempt on a link that is already down.
if printf '%s' "$out" | grep -qiE "$NETWORK_ERRORS"; then
    begin_outage "connection lost mid-sync — will retry next run"
    exit 0
fi

# Lost baseline listings ("must run --resync"): self-heal by rebuilding them once.
if printf '%s' "$out" | grep -qiE 'must run --resync|cannot find prior|prior Path1 or Path2 listings'; then
    log "baseline lost — auto-recovering with --resync"
    set +e
    rout="$(rclone bisync "$VAULT_LOCAL" "$VAULT_REMOTE" "${COMMON[@]}" --resync 2>&1)"
    rstatus=$?
    set -e
    printf '%s\n' "$rout" >>"$LOG_FILE"

    if [ "$rstatus" -eq 0 ]; then
        log "auto-recovery OK (--resync)"
        notify normal "Obsidian iCloud sync recovered" \
            "Baseline listings were lost; rebuilt automatically with --resync. Sync is healthy again."
        exit 0
    fi

    log "auto-recovery FAILED (exit $rstatus)"

    if printf '%s' "$rout" | grep -qiE "$NETWORK_ERRORS"; then
        begin_outage "connection lost during --resync — will retry next run"
        exit 0
    fi

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
