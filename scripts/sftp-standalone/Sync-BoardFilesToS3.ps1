# =============================================================================
# Sync-BoardFilesToS3.ps1 - Recursive SFTP Sync Script
# =============================================================================
# Recursively scans the entire structure under BoardFiles/ and uploads new files
# to S3, preserving the full path.
# Example: Boards/Board_NDSBOTP/subfolder/file.csv
#       -> s3://bucket/Boards/Board_NDSBOTP/subfolder/20260219_file.csv
# After uploading, moves the file to processed/ in its same folder.
# Ignores any folder named "processed".
# =============================================================================

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync.log"
$BucketName = "data-do-ent-file-ingestion-test-landing"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-02-19"

# -----------------------------------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------------------------------

function Write-SyncLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $logMessage -Force

    $source = "BoardFileSync"
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        try { New-EventLog -LogName Application -Source $source -ErrorAction SilentlyContinue } catch {}
    }
    $eventType = switch ($Level) {
        "ERROR" { "Error" }
        "WARN"  { "Warning" }
        default { "Information" }
    }
    try {
        Write-EventLog -LogName Application -Source $source -EventId 1000 -EntryType $eventType -Message $Message -ErrorAction SilentlyContinue
    } catch {}
}

function Test-FileNotLocked {
    param([string]$FilePath)
    try {
        $fileStream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
        $fileStream.Close()
        $fileStream.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Get-FileStableSize {
    param([string]$FilePath, [int]$WaitSeconds = 5)
    $size1 = (Get-Item $FilePath).Length
    Start-Sleep -Seconds $WaitSeconds
    $size2 = (Get-Item $FilePath).Length
    return $size1 -eq $size2
}

# -----------------------------------------------------------------------------
# MAIN PROCESS - Recursive scan
# -----------------------------------------------------------------------------

Write-SyncLog "=========================================="
Write-SyncLog "Starting recursive sync..."
Write-SyncLog "Base: $BasePath"
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0

# Find ALL files recursively, excluding "processed" folders
$allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CreationTime -ge $SyncAfterDate -and
        $_.DirectoryName -notmatch '\\processed(\\|$)'
    }

if ($allFiles.Count -eq 0) {
    Write-SyncLog "No new files to sync"
} else {
    Write-SyncLog "Found $($allFiles.Count) new files (since $SyncAfterDate)"

    foreach ($file in $allFiles) {
        $filePath = $file.FullName
        $fileName = $file.Name
        $fileDir = $file.DirectoryName

        # Calculate relative path from BasePath for the S3 key
        $relativePath = $fileDir.Substring($BasePath.Length).TrimStart('\') -replace '\\', '/'
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $s3Key = "$relativePath/${timestamp}_$fileName"

        Write-SyncLog "[$relativePath] Processing: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$relativePath] File is locked, skipping: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$relativePath] File is being transferred, skipping: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        try {
            Write-SyncLog "[$relativePath] Uploading to s3://$BucketName/$s3Key"
            Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion

            # Move to processed/ in the same folder
            $processedPath = Join-Path $fileDir "processed"
            if (-not (Test-Path $processedPath)) {
                New-Item -ItemType Directory -Path $processedPath -Force | Out-Null
            }
            Move-Item -Path $filePath -Destination (Join-Path $processedPath $fileName) -Force

            Write-SyncLog "[$relativePath] OK: $fileName -> $s3Key"
            $totalSuccess++
        } catch {
            Write-SyncLog "[$relativePath] ERROR: $fileName - $($_.Exception.Message)" -Level "ERROR"
            $totalErrors++
        }
    }
}

Write-SyncLog "=========================================="
Write-SyncLog "Sync completed"
Write-SyncLog "  - Successful: $totalSuccess"
Write-SyncLog "  - Errors: $totalErrors"
Write-SyncLog "  - Skipped: $totalSkipped"
Write-SyncLog "=========================================="

# -----------------------------------------------------------------------------
# CLEANUP: Delete files in processed/ older than 30 days
# -----------------------------------------------------------------------------
$cutoffDate = (Get-Date).AddDays(-30)
$oldFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DirectoryName -match '\\processed(\\|$)' -and
        $_.LastWriteTime -lt $cutoffDate
    }

if ($oldFiles.Count -gt 0) {
    Write-SyncLog "Cleaning $($oldFiles.Count) old files from processed/..."
    foreach ($old in $oldFiles) {
        Remove-Item $old.FullName -Force
        Write-SyncLog "Deleted: $($old.FullName.Substring($BasePath.Length))"
    }
}

Write-SyncLog "Script finished"
