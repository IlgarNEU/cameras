#!/bin/bash
# =============================================================================
#  photo_upload.sh — Continuous photo uploader → Google Drive (Linux)
# =============================================================================
#
#  SETUP (one-time):
#    1. Install rclone:         sudo apt install rclone
#       Or latest version:      curl https://rclone.org/install.sh | sudo bash
#    2. Configure Google Drive: rclone config
#       → Name the remote "gdrive" (or change RCLONE_REMOTE below)
#    3. Make executable:        chmod +x photo_upload.sh
#    4. Run:                    ./photo_upload.sh
#
# =============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────

RCLONE_REMOTE="gdrive"

PHOTOS_DIR="/home/het/Desktop/photos/59241JEBF06795"
PHOTOS_ARCHIVE="$HOME/uploaded_archive/photos"
GDRIVE_PHOTOS="$RCLONE_REMOTE:AutoUpload/photos_rpi"

SCAN_INTERVAL=10       # seconds between scans
MIN_AGE=5              # seconds — skip files newer than this (may still be writing)

LOG_FILE="$HOME/photo_upload.log"
MAX_LOG_LINES=5000

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

rotate_log() {
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -n $(( MAX_LOG_LINES / 2 )) "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log rotated (was $lines lines)."
    fi
}

is_old_enough() {
    local file="$1"
    local now mod_time age
    now=$(date +%s)
    mod_time=$(stat -c '%Y' "$file" 2>/dev/null) || return 1   # Linux stat syntax
    age=$(( now - mod_time ))
    [ "$age" -ge "$MIN_AGE" ]
}

# ── Init ──────────────────────────────────────────────────────────────────────

mkdir -p "$PHOTOS_ARCHIVE"
touch "$LOG_FILE"

log "════════════════════════════════════════════════════════"
log "  photo_upload.sh started (PID $$)"
log "  Source  : $PHOTOS_DIR"
log "  Drive   : $GDRIVE_PHOTOS"
log "  Archive : $PHOTOS_ARCHIVE"
log "════════════════════════════════════════════════════════"

if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
    log "ERROR: rclone remote '${RCLONE_REMOTE}' not found."
    log "Run: rclone config   (create a remote named '${RCLONE_REMOTE}')"
    exit 1
fi

# ── Main loop ─────────────────────────────────────────────────────────────────

while true; do
    rotate_log

    # Collect all ready files
    ready_files=()
    while IFS= read -r -d '' f; do
        if is_old_enough "$f"; then
            ready_files+=("$f")
        fi
    done < <(find "$PHOTOS_DIR" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null)

    if [ "${#ready_files[@]}" -eq 0 ]; then
        log "No new photos."
        sleep "$SCAN_INTERVAL"
        continue
    fi

    log "↑ Uploading ${#ready_files[@]} photo(s) in parallel..."

    # Upload all ready files in one rclone call (parallel via --transfers 10)
    if rclone copy "$PHOTOS_DIR" "$GDRIVE_PHOTOS" \
            --transfers 10 \
            --no-traverse \
            --files-from <(printf '%s\n' "${ready_files[@]}" | xargs -I{} basename {}) \
            --retries 5 \
            --low-level-retries 10 \
            --stats 0 \
            --log-level ERROR 2>>"$LOG_FILE"; then

        # Move successfully uploaded files to archive
        for f in "${ready_files[@]}"; do
            filename=$(basename "$f")
            mv "$f" "$PHOTOS_ARCHIVE/$filename"
            log "✔ Archived: $filename"
        done
    else
        log "✖ Batch upload had errors (will retry next cycle)."
    fi

    sleep "$SCAN_INTERVAL"
done
