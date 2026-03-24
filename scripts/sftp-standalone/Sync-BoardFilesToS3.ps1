# =============================================================================
# Sync-BoardFilesToS3.ps1 - Recursive SFTP Sync Script
# =============================================================================
# Recursively scans the entire structure under the base path and uploads new files
# to S3, preserving the full path.
# Example: providers/Provider_XYZ/subfolder/file.csv
#       -> s3://bucket/providers/Provider_XYZ/subfolder/20260219_file.csv
# After uploading, moves the file to processed/ in its same folder.
# Ignores any folder named "processed".
# =============================================================================

# =============================================================================
# LOCK FILE TO PREVENT CONCURRENT EXECUTIONS
# =============================================================================
$LockFile = "C:\CEB_FTP_Data\Logs\Sync-BoardFilesToS3.lock"
$LockMaxAgeMinutes = 120  # Consider lock stale after 2 hours
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    $existingPid = $null
    $lockInfo = Get-Content -Path $LockFile -Raw -ErrorAction SilentlyContinue
    if ($lockInfo -match 'PID=(\d+)') {
        $existingPid = [int]$Matches[1]
    }

    $isRunning = $false
    if ($null -ne $existingPid) {
        $existingProc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
        if ($existingProc -and ($existingProc.ProcessName -match 'powershell|pwsh')) {
            $isRunning = $true
        }
    }

    if ($isRunning) {
        Write-Host "[ERROR] Another instance is already running (PID: $existingPid, lock age: $([math]::Round($lockAge.TotalMinutes, 1)) min). Exiting..."
        exit 1
    }

    if ($lockAge.TotalMinutes -lt $LockMaxAgeMinutes) {
        Write-Host "[WARN] Orphan lock file detected (PID not running, age: $([math]::Round($lockAge.TotalMinutes, 1)) min). Removing and continuing..."
    } else {
        Write-Host "[WARN] Stale lock file detected (age: $([math]::Round($lockAge.TotalMinutes, 1)) min). Removing and continuing..."
    }
    Remove-Item $LockFile -Force
}
Set-Content -Path $LockFile -Value "PID=$PID`nStarted=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -Force

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync.log"
$BucketName = "data-do-ent-file-ingestion-test-landing"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-02-19"
$RetentionDays = 30 # Configurable retention period

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

    # Try to write to log file, handle locked/corrupt file, retry up to 3 times
    $maxAttempts = 3
    $attempt = 0
    $logged = $false
    while (-not $logged -and $attempt -lt $maxAttempts) {
        try {
            # If file does not exist, create it
            if (-not (Test-Path $LogPath)) {
                New-Item -ItemType File -Path $LogPath -Force | Out-Null
            }
            Add-Content -Path $LogPath -Value $logMessage -Force
            $logged = $true
        } catch {
            Start-Sleep -Milliseconds 200
            $attempt++
            if ($attempt -eq $maxAttempts) {
                Write-Host "[ERROR] Could not write to log file: $LogPath ($($_.Exception.Message))"
            }
        }
    }

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

try {

Write-SyncLog "=========================================="
Write-SyncLog "Starting recursive sync..."
Write-SyncLog "Base: $BasePath"
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0

# Find ALL files recursively in all subfolders, excluding "processed" folders
$allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CreationTime -ge $SyncAfterDate -and
        $_.DirectoryName -notmatch 'processed$'
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
            $destPath = Join-Path $processedPath $fileName
            try {
                Move-Item -Path $filePath -Destination $destPath -Force
                Write-SyncLog "[$relativePath] Moved to processed: $destPath"
                if (Test-Path $destPath) {
                    Write-SyncLog "[$relativePath] Confirmed in processed: $destPath"
                } else {
                    Write-SyncLog "[$relativePath] ERROR: File not found in processed after move: $destPath" -Level "ERROR"
                }
            } catch {
                Write-SyncLog "[$relativePath] ERROR: Move-Item failed for $fileName - $($_.Exception.Message)" -Level "ERROR"
                $totalErrors++
                continue
            }

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
# CLEANUP: Delete files in processed/ older than configurable retention period
# -----------------------------------------------------------------------------
$cutoffDate = (Get-Date).AddDays(-$RetentionDays)
$oldFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DirectoryName -match 'processed$' -and
        $_.LastWriteTime -lt $cutoffDate
    }

$deletedCount = 0
if ($oldFiles.Count -gt 0) {
    Write-SyncLog "Cleaning $($oldFiles.Count) old files from processed/..."
    foreach ($old in $oldFiles) {
        $oldName = $old.FullName.Substring($BasePath.Length)
        $oldDate = $old.LastWriteTime
        Write-SyncLog "Candidate for deletion: $oldName (LastWrite: $oldDate)"

        # Check existence in S3 before deleting
        $relativeOldPath = $old.DirectoryName.Substring($BasePath.Length).TrimStart('\') -replace '\\', '/'
        $s3KeyPattern = "$relativeOldPath/*_$($old.Name)"
        $existsInS3 = $false
        try {
            $s3Objects = Get-S3Object -BucketName $BucketName -Region $AwsRegion -KeyPrefix $relativeOldPath
            foreach ($obj in $s3Objects) {
                if ($obj.Key -like "*$($old.Name)") {
                    $existsInS3 = $true
                    break
                }
            }
        } catch {
            Write-SyncLog "ERROR: Could not verify S3 existence for $oldName - $($_.Exception.Message)" -Level "ERROR"
        }

        if ($existsInS3) {
            Remove-Item $old.FullName -Force
            Write-SyncLog "Deleted: $oldName"
            $deletedCount++
        } else {
            Write-SyncLog "SKIPPED deletion (not found in S3): $oldName" -Level "WARN"
        }
    }
}

Write-SyncLog "Script finished"
Write-SyncLog "Final summary:"
Write-SyncLog "  - Files uploaded: $totalSuccess"
Write-SyncLog "  - Files moved: $totalSuccess"
Write-SyncLog "  - Files deleted: $deletedCount"
Write-SyncLog "  - Files skipped: $totalSkipped"
Write-SyncLog "  - Errors: $totalErrors"

} catch {
    Write-SyncLog "ERROR: Script failed with exception: $($_.Exception.Message)" -Level "ERROR"
    throw $_
} finally {
    # Always cleanup lock file, even if errors occur
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        Write-SyncLog "Lock file cleaned up"
    }
}
