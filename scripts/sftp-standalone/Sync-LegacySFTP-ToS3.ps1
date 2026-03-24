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
    $StateFile          = "C:\CEB_FTP_Data\Logs\.sync_state.json"
    $BucketName         = "CHANGE-BUCKET-NAME"               # <-- CHANGE to target bucket
    $AwsRegion          = "us-east-1"
    $S3Prefix           = ""                                  # S3 prefix (leave empty for root)
    $DeleteAfterDays    = 7                                   # Grace period (days) before deleting from S3
    $SyncAfterDate      = [DateTime]"2026-02-19"               # Ignore files created before this date (remove once initial sync is done)
    $DeltaLookbackMinutes = 20                                # Safety overlap for delta scans
    $FullReconcileIntervalMinutes = 60                        # Run full mirror reconcile every 60 minutes

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

    function Get-SyncState {
        if (-not (Test-Path $StateFile)) {
            return @{}
        }

        try {
            $raw = Get-Content -Path $StateFile -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) {
                return @{}
            }
            return ($raw | ConvertFrom-Json)
        } catch {
            Write-SyncLog "WARN reading state file, using defaults: $($_.Exception.Message)" -Level "WARN"
            return @{}
        }
    }

    function Save-SyncState {
        param(
            [DateTime]$LastDeltaScanUtc,
            [DateTime]$LastFullScanUtc
        )

        $state = @{
            LastDeltaScanUtc = $LastDeltaScanUtc.ToString("o")
            LastFullScanUtc  = if ($LastFullScanUtc -gt [DateTime]::MinValue) { $LastFullScanUtc.ToString("o") } else { $null }
        }

        $state | ConvertTo-Json | Set-Content -Path $StateFile -Force
    }

    function Convert-StateValueToUtc {
        param([string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return [DateTime]::MinValue
        }

        try {
            return ([DateTimeOffset]::Parse($Value)).UtcDateTime
        } catch {
            Write-SyncLog "WARN parsing UTC state value '$Value': $($_.Exception.Message)" -Level "WARN"
            return [DateTime]::MinValue
        }
    }

    function Format-Elapsed {
        param([TimeSpan]$Elapsed)
        return "{0:mm\:ss}.{1:000}" -f $Elapsed, $Elapsed.Milliseconds
    }

    $executionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # -----------------------------------------------------------------------------
    # STEP 1: Index S3 — get all current objects
    # -----------------------------------------------------------------------------

    Write-SyncLog "=========================================="
    Write-SyncLog "Starting sync (SFTP mirror -> S3)"
    Write-SyncLog "Base: $BasePath"
    Write-SyncLog "Bucket: $BucketName"
    Write-SyncLog "=========================================="

    $s3Objects = @{}
    $s3IndexStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $s3List = Get-S3Object -BucketName $BucketName -Region $AwsRegion -Prefix $S3Prefix
        foreach ($obj in $s3List) {
            $s3Objects[$obj.Key] = $obj.Size
        }
        Write-SyncLog "S3: $($s3Objects.Count) objects indexed"
        $s3IndexStopwatch.Stop()
        Write-SyncLog "S3 index duration: $(Format-Elapsed -Elapsed $s3IndexStopwatch.Elapsed)"
    } catch {
        $s3IndexStopwatch.Stop()
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
    $scanUploadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $syncState = Get-SyncState
    $nowUtc = (Get-Date).ToUniversalTime()

    $lastFullScanUtc = [DateTime]::MinValue
    if ($syncState.PSObject.Properties.Name -contains "LastFullScanUtc" -and -not [string]::IsNullOrWhiteSpace([string]$syncState.LastFullScanUtc)) {
        $lastFullScanUtc = Convert-StateValueToUtc -Value ([string]$syncState.LastFullScanUtc)
    }

    $lastDeltaScanUtc = $nowUtc.AddMinutes(-$DeltaLookbackMinutes)
    if ($syncState.PSObject.Properties.Name -contains "LastDeltaScanUtc" -and -not [string]::IsNullOrWhiteSpace([string]$syncState.LastDeltaScanUtc)) {
        $lastDeltaScanUtc = Convert-StateValueToUtc -Value ([string]$syncState.LastDeltaScanUtc)
    }

    $doFullReconcile = ($lastFullScanUtc -eq [DateTime]::MinValue) -or (($nowUtc - $lastFullScanUtc).TotalMinutes -ge $FullReconcileIntervalMinutes)

    if ($doFullReconcile) {
        $allSftpFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue
        Write-SyncLog "SFTP FULL scan mode (including processed folders)"
        Write-SyncLog "SFTP: $($allSftpFiles.Count) total files indexed"
    } else {
        $deltaSinceUtc = $lastDeltaScanUtc.AddMinutes(-$DeltaLookbackMinutes)
        $syncAfterUtc = $SyncAfterDate.ToUniversalTime()
        if ($deltaSinceUtc -lt $syncAfterUtc) {
            $deltaSinceUtc = $syncAfterUtc
        }

        $allSftpFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -ge $deltaSinceUtc }

        Write-SyncLog "SFTP DELTA scan mode since UTC $($deltaSinceUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-SyncLog "SFTP: $($allSftpFiles.Count) changed files indexed"
    }

    # Build full SFTP key set only on full reconcile runs.
    # This keeps delete logic accurate while making most runs fast.
    $sftpKeys = @{}
    if ($doFullReconcile) {
        foreach ($f in $allSftpFiles) {
            $sftpKeys[(Get-S3Key -FullPath $f.FullName)] = $true
        }
    }

    # Only upload files created after the cutoff date
    $allFiles = $allSftpFiles | Where-Object { $_.CreationTime -ge $SyncAfterDate }

    if ($allFiles.Count -eq 0) {
        Write-SyncLog "No new files to upload (after $SyncAfterDate)"
    } else {
        Write-SyncLog "SFTP: $($allFiles.Count) files to sync (since $SyncAfterDate)"

        foreach ($file in $allFiles) {
            $filePath = $file.FullName
            $s3Key = Get-S3Key -FullPath $filePath

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
    $scanUploadStopwatch.Stop()
    Write-SyncLog "Scan/upload duration: $(Format-Elapsed -Elapsed $scanUploadStopwatch.Elapsed)"

    # -----------------------------------------------------------------------------
    # STEP 3: Remove from S3 files no longer on SFTP (with grace period)
    # -----------------------------------------------------------------------------

    $deleteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($doFullReconcile) {
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

        Save-SyncState -LastDeltaScanUtc $nowUtc -LastFullScanUtc $nowUtc
    } else {
        Write-SyncLog "Skipping delete mirror check on delta run (next full reconcile in <= $FullReconcileIntervalMinutes min)"
        Save-SyncState -LastDeltaScanUtc $nowUtc -LastFullScanUtc $lastFullScanUtc
    }
    $deleteStopwatch.Stop()
    Write-SyncLog "Delete/reconcile duration: $(Format-Elapsed -Elapsed $deleteStopwatch.Elapsed)"

    # -----------------------------------------------------------------------------
    # SUMMARY
    # -----------------------------------------------------------------------------

    Write-SyncLog "=========================================="
    Write-SyncLog "Sync completed"
    Write-SyncLog "  - Uploaded: $totalUploaded"
    Write-SyncLog "  - Unchanged: $totalSkipped"
    Write-SyncLog "  - Deleted from S3: $totalDeleted"
    Write-SyncLog "  - Errors: $totalErrors"
    $executionStopwatch.Stop()
    Write-SyncLog "  - Duration: $(Format-Elapsed -Elapsed $executionStopwatch.Elapsed)"
    Write-SyncLog "=========================================="

    Remove-Item $LockFile -Force
} catch {
    Remove-Item $LockFile -Force
    throw $_
}
