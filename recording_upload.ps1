# =============================================================================
#  recording_upload.ps1 — Continuous recording uploader → Google Drive (Windows)
# =============================================================================
#
#  SETUP (one-time):
#    1. Install rclone:          winget install Rclone.Rclone
#       Or download from:        https://rclone.org/downloads/
#    2. Configure Google Drive:  rclone config
#       → Name the remote "gdrive" (or change $RcloneRemote below)
#    3. Allow script execution (run PowerShell as Administrator, once):
#           Set-ExecutionPolicy RemoteSigned
#    4. Run:
#           .\recording_upload.ps1
#
# =============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────

$RcloneRemote       = "gdrive"

$RecordingsDir      = "$HOME\Desktop\recordings"
$RecordingsArchive  = "$HOME\Desktop\uploaded_archive\recordings"
$GdriveRecordings   = "${RcloneRemote}:AutoUpload/recordings"

$ScanInterval       = 60       # seconds between scans
$MinAge             = 4200     # seconds — skip files newer than this (still recording, ~70 min)

$LogFile            = "$HOME\Desktop\recording_upload.log"
$MaxLogLines        = 5000

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Invoke-LogRotate {
    if (-not (Test-Path $LogFile)) { return }
    $lines = Get-Content $LogFile
    if ($lines.Count -gt $MaxLogLines) {
        $lines | Select-Object -Last ($MaxLogLines / 2) | Set-Content $LogFile
        Write-Log "Log rotated (was $($lines.Count) lines)."
    }
}

function Is-OldEnough {
    param([System.IO.FileInfo]$File)
    $age = (Get-Date) - $File.LastWriteTime
    return $age.TotalSeconds -ge $MinAge
}

function Upload-AndArchive {
    param(
        [string]$SrcFile,
        [string]$GdriveDestDir,
        [string]$LocalArchiveDir
    )

    $filename = Split-Path $SrcFile -Leaf

    Write-Log "↑ Uploading: $SrcFile → $GdriveDestDir/"

    $result = & rclone copy $SrcFile $GdriveDestDir `
        --transfers 4 `
        --checkers 8 `
        --retries 5 `
        --low-level-retries 10 `
        --stats 0 `
        --log-level ERROR 2>&1

    if ($LASTEXITCODE -eq 0) {
        New-Item -ItemType Directory -Force -Path $LocalArchiveDir | Out-Null
        Move-Item -Path $SrcFile -Destination "$LocalArchiveDir\$filename" -Force
        Write-Log "✔ Archived: $LocalArchiveDir\$filename"
    } else {
        Write-Log "✖ Upload FAILED: $SrcFile (will retry next cycle)"
        if ($result) { Write-Log "   rclone error: $result" }
    }
}

function Invoke-ScanRecordings {
    Write-Log "── Scanning recordings ──────────────────────────────────"

    $subfolders = Get-ChildItem -Path $RecordingsDir -Directory -ErrorAction SilentlyContinue
    if (-not $subfolders) {
        Write-Log "  No sub-folders found in $RecordingsDir"
        return
    }

    foreach ($subfolder in $subfolders) {
        $subfolderName = $subfolder.Name

        # Get all files sorted oldest → newest
        $allFiles = Get-ChildItem -Path $subfolder.FullName -File |
                    Where-Object { $_.Name -notlike ".*" } |
                    Sort-Object LastWriteTime   # oldest first

        $total = $allFiles.Count

        if ($total -eq 0) {
            Write-Log "  [$subfolderName] No files found."
            continue
        }

        if ($total -eq 1) {
            Write-Log "  [$subfolderName] Only one file present — skipping (assumed active)."
            continue
        }

        # All except the newest are candidates
        $candidates = $allFiles | Select-Object -First ($total - 1)

        Write-Log "  [$subfolderName] $($candidates.Count) candidate(s) (newest skipped as active)."

        foreach ($file in $candidates) {
            if (Is-OldEnough $file) {
                Upload-AndArchive `
                    -SrcFile $file.FullName `
                    -GdriveDestDir "$GdriveRecordings/$subfolderName" `
                    -LocalArchiveDir "$RecordingsArchive\$subfolderName"
            } else {
                Write-Log "  [$subfolderName] Skipping (too new): $($file.Name)"
            }
        }
    }
}

# ── Init ──────────────────────────────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $RecordingsArchive | Out-Null
if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile | Out-Null }

Write-Log "════════════════════════════════════════════════════════"
Write-Log "  recording_upload.ps1 started (PID $PID)"
Write-Log "  Source  : $RecordingsDir"
Write-Log "  Drive   : $GdriveRecordings"
Write-Log "  Archive : $RecordingsArchive"
Write-Log "════════════════════════════════════════════════════════"

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Log "ERROR: rclone not found. Install it with: winget install Rclone.Rclone"
    exit 1
}

$remotes = & rclone listremotes 2>&1
if ($remotes -notmatch "^${RcloneRemote}:") {
    Write-Log "ERROR: rclone remote '$RcloneRemote' not found."
    Write-Log "Run: rclone config   (create a remote named '$RcloneRemote')"
    exit 1
}

if (-not (Test-Path $RecordingsDir)) {
    Write-Log "ERROR: Recordings folder not found: $RecordingsDir"
    exit 1
}

# ── Main loop ─────────────────────────────────────────────────────────────────

while ($true) {
    Invoke-LogRotate
    Invoke-ScanRecordings
    Start-Sleep -Seconds $ScanInterval
}
