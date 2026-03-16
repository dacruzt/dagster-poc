# -----------------------------------------------------------------------------
# LOCK FILE TO PREVENT CONCURRENT EXECUTIONS
# -----------------------------------------------------------------------------
$LockFile = "$PSScriptRoot\Sync-LegacySFTP-ToS3.lock"
if (Test-Path $LockFile) {
    Write-Host "[ERROR] Another instance is already running. Exiting..."
    exit 1
}
New-Item -ItemType File -Path $LockFile -Force | Out-Null

try {
    # =============================================================================
    # Sync-LegacySFTP-ToS3.ps1
    # =============================================================================
    # Script for legacy-sftp-02 server
    # Keeps S3 as an exact mirror of C:\CEB_FTP_Data\SFTP\
    #
    # - Uploads new or modified files to the S3 bucket
    # - Removes from S3 files that no longer exist on SFTP (after grace period)
    # - Does NOT move or rename files: S3 reflects the real SFTP structure
    # - move-file-api manages the file lifecycle on SFTP, this script only syncs
    # =============================================================================

    $ErrorActionPreference = "Continue"

    # -----------------------------------------------------------------------------
    # CONFIGURATION  <-- CHANGE HERE
    # -----------------------------------------------------------------------------
    $BasePath           = "C:\CEB_FTP_Data\SFTP"
    $LogPath            = "C:\CEB_FTP_Data\Logs\sync.log"
    $PendingDeletesFile = "C:\CEB_FTP_Data\Logs\.pending_deletes"
    $BucketName         = "CHANGE-BUCKET-NAME"               # <-- CHANGE to target bucket
    $AwsRegion          = "us-east-1"
    $S3Prefix           = ""                                  # S3 prefix (leave empty for root)
    $DeleteAfterDays    = 7                                   # Grace period (days) before deleting from S3
    $SyncAfterDate      = [DateTime]"2026-02-19"               # Ignore files created before this date (remove once initial sync is done)

    # -----------------------------------------------------------------------------
    # FUNCTIONS
    # -----------------------------------------------------------------------------

    function Write-SyncLog {
        param(
            [string]$Message,
            [string]$Level = "INFO"
        )
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
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

    # Converts local path to S3 key
    function Get-S3Key {
        param([string]$FullPath)
        $relative = $FullPath.Substring($BasePath.Length).TrimStart('\') -replace '\\', '/'
        if ($S3Prefix -ne "") {
            return "$S3Prefix/$relative"
        }
        return $relative
    }

    # -----------------------------------------------------------------------------
    # STEP 1: Index S3 — get all current objects
    # -----------------------------------------------------------------------------

    Write-SyncLog "=========================================="
    Write-SyncLog "Starting sync (SFTP mirror -> S3)"
    Write-SyncLog "Base: $BasePath"
    Write-SyncLog "Bucket: $BucketName"
    Write-SyncLog "=========================================="

    $s3Objects = @{}
    try {
        $s3List = Get-S3Object -BucketName $BucketName -Region $AwsRegion -Prefix $S3Prefix
        foreach ($obj in $s3List) {
            $s3Objects[$obj.Key] = $obj.Size
        }
        Write-SyncLog "S3: $($s3Objects.Count) objects indexed"
    } catch {
        Write-SyncLog "ERROR listing S3: $($_.Exception.Message)" -Level "ERROR"
        throw
    }

    # -----------------------------------------------------------------------------
    # STEP 2: Scan SFTP and upload new or modified files
    # -----------------------------------------------------------------------------

    $totalUploaded = 0
    $totalSkipped = 0
    $totalErrors = 0
    $totalDeleted = 0

    # Set of S3 keys that correspond to existing SFTP files
    $sftpKeys = @{}

    $allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -ge $SyncAfterDate }

    if ($allFiles.Count -eq 0) {
        Write-SyncLog "No files found on SFTP"
    } else {
        Write-SyncLog "SFTP: $($allFiles.Count) files found"

        foreach ($file in $allFiles) {
            $filePath = $file.FullName
            $s3Key = Get-S3Key -FullPath $filePath
            $sftpKeys[$s3Key] = $true

            # Already exists in S3 with the same size, skip
            if ($s3Objects.ContainsKey($s3Key) -and $s3Objects[$s3Key] -eq $file.Length) {
                $totalSkipped++
                continue
            }

            if (-not (Test-FileNotLocked -FilePath $filePath)) {
                Write-SyncLog "File locked, skipping: $s3Key" -Level "WARN"
                $totalSkipped++
                continue
            }

            if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
                Write-SyncLog "File still being transferred, skipping: $s3Key" -Level "WARN"
                $totalSkipped++
                continue
            }

            try {
                Write-SyncLog "Uploading: $s3Key ($([math]::Round($file.Length / 1MB, 2)) MB)"
                Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion
                $totalUploaded++
            } catch {
                Write-SyncLog "ERROR uploading $s3Key : $($_.Exception.Message)" -Level "ERROR"
                $totalErrors++
            }
        }
    }

    # -----------------------------------------------------------------------------
    # STEP 3: Remove from S3 files no longer on SFTP (with grace period)
    # -----------------------------------------------------------------------------

    # Load pending deletes: format "s3Key|detected_date"
    $pendingDeletes = @{}
    if (Test-Path $PendingDeletesFile) {
        Get-Content $PendingDeletesFile | ForEach-Object {
            $parts = $_ -split '\|', 2
            if ($parts.Count -eq 2) {
                $pendingDeletes[$parts[0]] = [DateTime]$parts[1]
            }
        }
    }

    $cutoffDate = (Get-Date).AddDays(-$DeleteAfterDays)

    foreach ($s3Key in $s3Objects.Keys) {
        # Skip keys outside the prefix (safety check)
        if ($S3Prefix -ne "" -and -not $s3Key.StartsWith($S3Prefix)) { continue }

        if (-not $sftpKeys.ContainsKey($s3Key)) {
            if (-not $pendingDeletes.ContainsKey($s3Key)) {
                # First time we detect the file is missing from SFTP: record date
                $pendingDeletes[$s3Key] = Get-Date
                Write-SyncLog "Marked for future deletion ($DeleteAfterDays days): $s3Key"
            } elseif ($pendingDeletes[$s3Key] -lt $cutoffDate) {
                # Grace period has passed: delete from S3
                try {
                    Write-SyncLog "Deleting from S3 (absent for $DeleteAfterDays+ days): $s3Key"
                    Remove-S3Object -BucketName $BucketName -Key $s3Key -Region $AwsRegion -Force
                    $pendingDeletes.Remove($s3Key)
                    $totalDeleted++
                } catch {
                    Write-SyncLog "ERROR deleting $s3Key : $($_.Exception.Message)" -Level "ERROR"
                    $totalErrors++
                }
            }
        } else {
            # File reappeared on SFTP: remove from pending
            if ($pendingDeletes.ContainsKey($s3Key)) {
                $pendingDeletes.Remove($s3Key)
            }
        }
    }

    # Save updated pending deletes
    $pendingLines = $pendingDeletes.GetEnumerator() | ForEach-Object {
        "$($_.Key)|$($_.Value.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
    if ($pendingLines.Count -gt 0) {
        Set-Content -Path $PendingDeletesFile -Value $pendingLines -Force
    } elseif (Test-Path $PendingDeletesFile) {
        Remove-Item $PendingDeletesFile -Force
    }

    # -----------------------------------------------------------------------------
    # SUMMARY
    # -----------------------------------------------------------------------------

    Write-SyncLog "=========================================="
    Write-SyncLog "Sync completed"
    Write-SyncLog "  - Uploaded: $totalUploaded"
    Write-SyncLog "  - Unchanged: $totalSkipped"
    Write-SyncLog "  - Deleted from S3: $totalDeleted"
    Write-SyncLog "  - Errors: $totalErrors"
    Write-SyncLog "=========================================="

    Remove-Item $LockFile -Force
} catch {
    Remove-Item $LockFile -Force
    throw $_
}
