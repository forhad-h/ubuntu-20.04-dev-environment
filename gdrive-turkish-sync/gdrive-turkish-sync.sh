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

mkdir -p "$LOG_DIR" "$VAULT"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date -Iseconds) Skipped: previous sync still running" >>"$LOG_FILE"
    exit 0
fi

fail() {
    local status=$?
    echo "=== $(date -Iseconds) sync FAILED (exit $status) at pass ${PASS:-?} ==="
    DISPLAY="${DISPLAY:-:0}" notify-send -u critical "Learning Turkish Drive sync failed" \
        "Check $LOG_FILE — token may need: rclone config reconnect gdrive:" || true
    exit "$status"
}

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
