# =============================================================================
# Sync-BoardFilesToS3.ps1 - Recursive SFTP Sync Script
# =============================================================================
# Recursively scans the entire structure under the base path and uploads new files
# to S3, preserving the full path and original file name.
# Example: providers/Provider_XYZ/subfolder/file.csv
#       -> s3://bucket/providers/Provider_XYZ/subfolder/file.csv
# Does NOT move or rename files in SFTP.
# Includes files in any subfolder, including "processed".
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
    if ($null -ne $existingPid -and $lockAge.TotalMinutes -lt $LockMaxAgeMinutes) {
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
$BucketName = "cebroker-sftp-raw-test-backup"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-03-20"
$StateFile = "C:\CEB_FTP_Data\Logs\.sync_state_boardfiles.json"
$DeltaLookbackMinutes = 20
$FullReconcileIntervalMinutes = 60
$EnableMirrorDelete = $true       # Delete S3 objects that no longer exist on SFTP (only during full scans)
$DeleteOrphanAfterDays = 7        # Grace period: only delete after orphan is absent this many days
$OrphanStateFile = "C:\CEB_FTP_Data\Logs\.sync_orphans_boardfiles.json"  # Tracks first-seen orphan timestamps

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

    $maxAttempts = 5
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        try {
            $logDir = Split-Path $LogPath -Parent
            if (-not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            $fileStream = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = New-Object System.IO.StreamWriter($fileStream)
            $writer.WriteLine($logMessage)
            $writer.Flush()
            $writer.Dispose()
            $fileStream.Dispose()
            break
        } catch {
            if ($i -eq ($maxAttempts - 1)) {
                Write-Host "[ERROR] Could not write to log file: $LogPath ($($_.Exception.Message))"
            }
            Start-Sleep -Milliseconds 300
        }
    }

    # Also print to console so logs are visible during interactive runs.
    $consoleColor = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        default { "Gray" }
    }
    Write-Host $logMessage -ForegroundColor $consoleColor

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

function Get-OrphanState {
    if (-not (Test-Path $OrphanStateFile)) { return @{} }
    try {
        $raw = Get-Content -Path $OrphanStateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $ht = @{}
        foreach ($prop in $obj.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        return $ht
    } catch {
        Write-SyncLog "WARN reading orphan state file: $($_.Exception.Message)" -Level "WARN"
        return @{}
    }
}

function Save-OrphanState {
    param([hashtable]$State)
    try {
        $State | ConvertTo-Json | Set-Content -Path $OrphanStateFile -Force
    } catch {
        Write-SyncLog "WARN saving orphan state file: $($_.Exception.Message)" -Level "WARN"
    }
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
$totalDeleted = 0

# Tracks local keys seen during this run (used for mirror delete in full scans)
$localKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Build S3 index once for fast lookups
$s3Objects = @{}
try {
    $s3List = Get-S3Object -BucketName $BucketName -Region $AwsRegion
    foreach ($obj in $s3List) {
        $s3Objects[$obj.Key] = $obj.Size
    }
    Write-SyncLog "S3 indexed objects: $($s3Objects.Count)"
} catch {
    Write-SyncLog "ERROR listing S3 objects: $($_.Exception.Message)" -Level "ERROR"
    throw
}

# Load scan state and determine whether this run is full or delta
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

$doFullScan = ($lastFullScanUtc -eq [DateTime]::MinValue) -or (($nowUtc - $lastFullScanUtc).TotalMinutes -ge $FullReconcileIntervalMinutes)

if ($doFullScan) {
    $allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.LastWriteTime -gt $SyncAfterDate -or $_.CreationTime -gt $SyncAfterDate)
        }
    Write-SyncLog "SFTP FULL scan mode"
} else {
    $deltaSinceUtc = $lastDeltaScanUtc.AddMinutes(-$DeltaLookbackMinutes)
    $syncAfterUtc = $SyncAfterDate.ToUniversalTime()
    if ($deltaSinceUtc -lt $syncAfterUtc) {
        $deltaSinceUtc = $syncAfterUtc
    }

    $allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTimeUtc -ge $deltaSinceUtc
        }
    Write-SyncLog "SFTP DELTA scan mode since UTC $($deltaSinceUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
}

if ($allFiles.Count -eq 0) {
    Write-SyncLog "No new files to sync"
} else {
    Write-SyncLog "Found $($allFiles.Count) new files (since $SyncAfterDate)"

    foreach ($file in $allFiles) {
        $filePath = $file.FullName
        $fileName = $file.Name
        $fileDir = $file.DirectoryName

        # Keep the exact original relative path and file name in S3
        $relativePath = $filePath.Substring($BasePath.Length).TrimStart('\\') -replace '\\', '/'
        $s3Key = $relativePath
        [void]$localKeys.Add($s3Key)
        $sourceLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
        $sourceCreationUtc = $file.CreationTimeUtc.ToString("o")
        $metadata = @{
            "source-last-write-time-utc" = $sourceLastWriteUtc
            "source-creation-time-utc" = $sourceCreationUtc
        }

        Write-SyncLog "[$relativePath] Processing: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        # Skip upload when key/size/metadata already match in S3
        if ($s3Objects.ContainsKey($s3Key) -and $s3Objects[$s3Key] -eq $file.Length) {
            $metadataMatches = $false
            try {
                $s3Head = Get-S3ObjectMetadata -BucketName $BucketName -Key $s3Key -Region $AwsRegion -ErrorAction Stop
                $s3SourceLastWriteUtc = [string]$s3Head.Metadata["source-last-write-time-utc"]
                $s3SourceCreationUtc = [string]$s3Head.Metadata["source-creation-time-utc"]

                if ($s3SourceLastWriteUtc -eq $sourceLastWriteUtc -and $s3SourceCreationUtc -eq $sourceCreationUtc) {
                    $metadataMatches = $true
                }
            } catch {
                Write-SyncLog "[$relativePath] WARN: Could not read S3 metadata for compare - $($_.Exception.Message)" -Level "WARN"
            }

            if ($metadataMatches) {
                Write-SyncLog "[$relativePath] Unchanged in S3 (same key/size/metadata), skipping upload"
                $totalSkipped++
                continue
            }
        }

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
            Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion -Metadata $metadata -ErrorAction Stop

            Write-SyncLog "[$relativePath] OK: $fileName -> $s3Key"
            $totalSuccess++
        } catch {
            $errorMessage = $_.Exception.Message
            Write-SyncLog "[$relativePath] ERROR: $fileName - $errorMessage" -Level "ERROR"
            $totalErrors++

            if ($errorMessage -match "not authorized to perform: s3:PutObject") {
                Write-SyncLog "FATAL: Missing IAM permission s3:PutObject for role on bucket '$BucketName'. Aborting run to avoid repetitive failures." -Level "ERROR"
                break
            }
        }
    }
}

if ($doFullScan) {
    Save-SyncState -LastDeltaScanUtc $nowUtc -LastFullScanUtc $nowUtc

    # Mirror delete: remove S3 objects that no longer exist on SFTP (with grace period)
    if ($EnableMirrorDelete) {
        Write-SyncLog "Mirror mode: checking for S3 orphans (grace period: $DeleteOrphanAfterDays days)..."
        $orphanState = Get-OrphanState
        $updatedOrphanState = @{}

        foreach ($orphanKey in $s3Objects.Keys) {
            if ($localKeys.Contains($orphanKey)) { continue }  # Still exists on SFTP

            if ($orphanState.ContainsKey($orphanKey)) {
                try {
                    $firstSeen = ([DateTimeOffset]::Parse([string]$orphanState[$orphanKey])).UtcDateTime
                } catch {
                    $firstSeen = $nowUtc
                }
                $ageDays = ($nowUtc - $firstSeen).TotalDays

                if ($ageDays -ge $DeleteOrphanAfterDays) {
                    try {
                        Remove-S3Object -BucketName $BucketName -Key $orphanKey -Region $AwsRegion -Force -ErrorAction Stop
                        Write-SyncLog "DELETED orphan from S3 (absent $([math]::Round($ageDays,1)) days): $orphanKey"
                        $totalDeleted++
                    } catch {
                        Write-SyncLog "ERROR deleting S3 orphan '$orphanKey': $($_.Exception.Message)" -Level "ERROR"
                        $totalErrors++
                        $updatedOrphanState[$orphanKey] = $orphanState[$orphanKey]  # Keep tracking
                    }
                } else {
                    Write-SyncLog "[$orphanKey] Orphan pending delete ($([math]::Round($ageDays,1))/$DeleteOrphanAfterDays days elapsed)"
                    $updatedOrphanState[$orphanKey] = $orphanState[$orphanKey]  # Keep tracking
                }
            } else {
                # First time detected as orphan — start grace period clock
                Write-SyncLog "[$orphanKey] New orphan detected — grace period started (will delete after $DeleteOrphanAfterDays days)"
                $updatedOrphanState[$orphanKey] = $nowUtc.ToString("o")
            }
        }

        Save-OrphanState -State $updatedOrphanState
        Write-SyncLog "Mirror delete complete. Deleted: $totalDeleted | Pending: $($updatedOrphanState.Count)"
    }
} else {
    Save-SyncState -LastDeltaScanUtc $nowUtc -LastFullScanUtc $lastFullScanUtc
}

Write-SyncLog "=========================================="
Write-SyncLog "Sync completed"
Write-SyncLog "  - Successful: $totalSuccess"
Write-SyncLog "  - Errors: $totalErrors"
Write-SyncLog "  - Skipped: $totalSkipped"
Write-SyncLog "  - Deleted (orphans): $totalDeleted"
Write-SyncLog "=========================================="

Write-SyncLog "Script finished"
Write-SyncLog "Final summary:"
Write-SyncLog "  - Files uploaded: $totalSuccess"
Write-SyncLog "  - Files skipped: $totalSkipped"
Write-SyncLog "  - Errors: $totalErrors"
Write-SyncLog "  - Orphans deleted: $totalDeleted"

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
