#!/usr/bin/env bash
# Syncs the standalone "Learning Turkish" Obsidian vault with Google Drive.
# Google Docs live locally as .md; PDFs/images/audio move byte-for-byte.
# Drive is authoritative for anything that is a native Google file.
# See README.md in this directory for the full design and its limits.
set -Eeuo pipefail

VAULT="$HOME/Documents/Obsidian Vault - Learning Turkish"   # its own vault, not inside the iCloud one
REMOTE="gdrive:"                           # root_folder_id pins this to the folder
EXPORT_FMTS="md,xlsx,pptx"
CONF_DIR="$HOME/.config/rclone"
LOG_DIR="$HOME/.local/share/gdrive-turkish-sync"
LOG_FILE="$LOG_DIR/sync.log"
LOCK_FILE="$LOG_DIR/sync.lock"

# Outage bookkeeping. Being offline is normal, not a fault, so it is skipped
# quietly and escalated exactly once — only after the vault has been stale long
# enough to actually matter.
OFFLINE_SINCE="$LOG_DIR/offline-since"       # epoch of the first offline run
OFFLINE_NOTIFIED="$LOG_DIR/offline-notified" # marker: at most one alert/outage
OFFLINE_ALERT_AFTER=1800                     # 30 minutes

MAX_LOG_BYTES=$((5 * 1024 * 1024))

mkdir -p "$LOG_DIR" "$VAULT"

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
# it is where rclone burns minutes before giving up. Then a TLS HEAD, which is
# what catches a captive portal: it cannot present a valid cert for this host,
# so the TLS handshake fails even though its DNS answers happily.
#
# The URL must answer <400 — curl -f treats 4xx as failure, so probing something
# like www.googleapis.com (404 to a HEAD) would report a permanent false outage.
# drive.google.com answers 302, which -f accepts.
online() {
    timeout 5 getent hosts drive.google.com >/dev/null 2>&1 || return 1
    curl -sfI --max-time 8 https://drive.google.com >/dev/null 2>&1
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
# the first run of it, so an offline night does not add one line every 5
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
        notify normal "Learning Turkish Drive sync paused" \
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

fail() {
    local status=$?
    trap - ERR   # never re-enter this handler

    # A pass can fail simply because the link went away mid-run. That is an
    # outage, not a broken sync — no critical popup, and the next run resumes.
    # Re-probing is the cheapest test here: unlike the iCloud wrapper, this
    # script streams rclone output straight to the log instead of capturing it,
    # so there is no text to pattern-match against.
    if ! online; then
        begin_outage "connection lost mid-sync at pass ${PASS:-?} — will retry next run"
        exit 0
    fi

    echo "=== $(date -Iseconds) sync FAILED (exit $status) at pass ${PASS:-?} ==="
    notify critical "Learning Turkish Drive sync failed" \
        "Check $LOG_FILE — token may need: rclone config reconnect gdrive:"
    exit "$status"
}

# Don't even start if Drive is unreachable — the failure is guaranteed, slow,
# and used to surface as a critical "token may need reconnect" popup.
if ! online; then
    begin_outage "skipped: offline (Google Drive unreachable)"
    exit 0
fi
end_outage

{
    trap fail ERR
    echo "=== $(date -Iseconds) starting sync ==="

    # Pass 1 — PULL. Native Google files export on the way down:
    # Doc -> .md, Sheet -> .xlsx, Slides -> .pptx. Everything else is
    # copied as-is. Only pulls when the Drive mtime is newer.
    PASS="1/pull"
    rclone copy "$REMOTE" "$VAULT" \
        --drive-export-formats "$EXPORT_FMTS" \
        -v

    # Pass 2 — PUSH assets. PDFs/images/audio only; newer mtime wins.
    # The filter keeps .md out of this pass and never pushes an .xlsx or
    # .pptx that pass 1 generated from a Sheet/Slides.
    PASS="2/push-assets"
    rclone copy "$VAULT" "$REMOTE" \
        --filter-from "$CONF_DIR/turkish-push-assets.txt" \
        -v

    # Pass 3 — PUSH genuinely new markdown, converting it to a Google Doc.
    # --ignore-existing is what makes Drive authoritative: a Doc named
    # "Lesson 1" already lists remotely as "Lesson 1.md", so local edits to
    # Doc-derived notes are skipped. Only notes with no remote counterpart
    # go up. Once uploaded, a note is a Doc and Drive owns it from then on.
    PASS="3/push-new-md"
    rclone copy "$VAULT" "$REMOTE" \
        --filter-from "$CONF_DIR/turkish-push-md.txt" \
        --drive-export-formats md \
        --drive-import-formats md \
        --ignore-existing \
        -v

    # Pass 4 — mark Doc-derived files read-only so the Drive-authoritative
    # rule is visible in Obsidian. Native Google files are exactly the ones
    # with an unknown size. rclone can still replace them: it downloads to
    # a .partial temp and renames over the target.
    PASS="4/chmod"
    rclone lsjson "$REMOTE" -R --files-only \
        --drive-export-formats "$EXPORT_FMTS" \
        | jq -r '.[] | select(.Size == -1) | .Path' \
        | while IFS= read -r path; do
              if [ -f "$VAULT/$path" ]; then
                  chmod a-w "$VAULT/$path"
              fi
          done

    echo "=== $(date -Iseconds) sync OK ==="
} >>"$LOG_FILE" 2>&1
