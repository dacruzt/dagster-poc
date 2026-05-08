# =============================================================================
# Sync-BoardFilesToS3.ps1 - Recursive SFTP Sync Script (append/update only)
# =============================================================================
# Recursively scans the entire structure under the base path and uploads new files
# to S3, preserving the full path and original file name.
# Example: providers/Provider_XYZ/subfolder/file.csv
#       -> s3://bucket/providers/Provider_XYZ/subfolder/file.csv
# Does NOT move or rename files in SFTP, and does NOT delete from S3.
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
    if ($null -ne $existingPid -and $existingPid -eq $PID) {
        Write-Host "[WARN] Local lock belongs to current PowerShell session (PID: $existingPid). Treating as stale and continuing..."
    }
    if ($null -ne $existingPid -and $lockAge.TotalMinutes -lt $LockMaxAgeMinutes) {
        $existingProc = if ($existingPid -eq $PID) { $null } else { Get-Process -Id $existingPid -ErrorAction SilentlyContinue }
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

# Shared lock across sync scripts to prevent concurrent execution of Board + All scripts.
$GlobalLockFile = "C:\CEB_FTP_Data\Logs\Sync-S3-Mirror.global.lock"
$GlobalLockMaxAgeMinutes = 180
$GlobalLockRetryAttempts = 15       # Max retries before giving up
$GlobalLockRetryIntervalSeconds = 120  # Wait 2 minutes between retries (total max wait: 30 min)
$globalLockAcquired = $false

for ($attempt = 1; $attempt -le ($GlobalLockRetryAttempts + 1); $attempt++) {
    if (-not (Test-Path $GlobalLockFile)) {
        $globalLockAcquired = $true
        break
    }

    $globalLockAge = (Get-Date) - (Get-Item $GlobalLockFile).LastWriteTime
    $existingGlobalPid = $null
    $globalLockInfo = Get-Content -Path $GlobalLockFile -Raw -ErrorAction SilentlyContinue
    if ($globalLockInfo -match 'PID=(\d+)') {
        $existingGlobalPid = [int]$Matches[1]
    }

    # If lock belongs to current session, treat as stale
    if ($null -ne $existingGlobalPid -and $existingGlobalPid -eq $PID) {
        Write-Host "[WARN] Global lock belongs to current PowerShell session (PID: $existingGlobalPid). Treating as stale and continuing..."
        Remove-Item $GlobalLockFile -Force -ErrorAction SilentlyContinue
        $globalLockAcquired = $true
        break
    }

    # Check if lock holder is still running
    $isGlobalRunning = $false
    if ($null -ne $existingGlobalPid -and $globalLockAge.TotalMinutes -lt $GlobalLockMaxAgeMinutes) {
        $globalProc = Get-Process -Id $existingGlobalPid -ErrorAction SilentlyContinue
        if ($globalProc -and ($globalProc.ProcessName -match 'powershell|pwsh')) {
            $isGlobalRunning = $true
        }
    }

    if (-not $isGlobalRunning) {
        Write-Host "[WARN] Removing stale/orphan global lock file and continuing..."
        Remove-Item $GlobalLockFile -Force -ErrorAction SilentlyContinue
        $globalLockAcquired = $true
        break
    }

    # Another script is actively running - wait and retry
    if ($attempt -le $GlobalLockRetryAttempts) {
        Write-Host "[INFO] Another sync script is running (global lock PID: $existingGlobalPid, age: $([math]::Round($globalLockAge.TotalMinutes, 1)) min). Waiting $GlobalLockRetryIntervalSeconds seconds... (attempt $attempt/$GlobalLockRetryAttempts)"
        Start-Sleep -Seconds $GlobalLockRetryIntervalSeconds
    }
}

if (-not $globalLockAcquired) {
    Write-Host "[ERROR] Could not acquire global lock after $GlobalLockRetryAttempts retries (~$([math]::Round(($GlobalLockRetryAttempts * $GlobalLockRetryIntervalSeconds) / 60)) min). Exiting..."
    exit 1
}
Set-Content -Path $GlobalLockFile -Value "PID=$PID`nScript=Sync-BoardFilesToS3`nStarted=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -Force

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
$S3IndexCacheFile = "C:\CEB_FTP_Data\Logs\.s3_index_boardfiles.json"
$S3IndexCacheTtlHours = 168  # 7 days; full scan refreshes when exceeded
$DeltaLookbackMinutes = 20
$FullReconcileIntervalMinutes = 60

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

function Get-S3IndexFromCache {
    param([string]$ExpectedBucket, [int]$TtlHours)

    if (-not (Test-Path $S3IndexCacheFile)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $S3IndexCacheFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

        $cache = $raw | ConvertFrom-Json
        if ($cache.BucketName -ne $ExpectedBucket) { return $null }

        $generatedAt = ([DateTimeOffset]::Parse([string]$cache.GeneratedAtUtc)).UtcDateTime
        $ageHours = ((Get-Date).ToUniversalTime() - $generatedAt).TotalHours
        if ($ageHours -gt $TtlHours) { return $null }

        $ht = @{}
        foreach ($prop in $cache.Objects.PSObject.Properties) {
            $ht[$prop.Name] = [long]$prop.Value
        }
        return @{
            Objects  = $ht
            AgeHours = $ageHours
        }
    } catch {
        Write-SyncLog "WARN reading S3 index cache: $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}

function Save-S3IndexCache {
    param([hashtable]$Objects, [string]$BucketName)

    try {
        $payload = [PSCustomObject]@{
            GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            BucketName     = $BucketName
            Objects        = $Objects
        }
        $payload | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $S3IndexCacheFile -Force
    } catch {
        Write-SyncLog "WARN saving S3 index cache: $($_.Exception.Message)" -Level "WARN"
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

# Build S3 index. Try the disk cache first (key->size dict) — listing the bucket
# can take minutes. The cache is refreshed on FULL scans when stale or missing.
# DELTA runs use whatever is in cache, falling back to per-key HEAD if no cache.
$s3Objects = @{}
$s3CacheDirty = $false

$cached = Get-S3IndexFromCache -ExpectedBucket $BucketName -TtlHours $S3IndexCacheTtlHours
if ($cached) {
    $s3Objects = $cached.Objects
    Write-SyncLog "S3 index loaded from cache: $($s3Objects.Count) objects (age: $([math]::Round($cached.AgeHours, 1))h)"
}

$needRefresh = $doFullScan -and -not $cached
if ($needRefresh) {
    $listStart = Get-Date
    try {
        $s3List = Get-S3Object -BucketName $BucketName -Region $AwsRegion
        $s3Objects = @{}
        foreach ($obj in $s3List) {
            $s3Objects[$obj.Key] = $obj.Size
        }
        Save-S3IndexCache -Objects $s3Objects -BucketName $BucketName
        Write-SyncLog "S3 index refreshed from bucket: $($s3Objects.Count) objects ($([math]::Round(((Get-Date) - $listStart).TotalSeconds, 1))s)"
    } catch {
        Write-SyncLog "ERROR listing S3 objects: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

# Enumerate files via Get-ChildItem. Benchmarks on this environment show it
# beats [IO.Directory]::EnumerateFiles + FileInfo::new because Get-ChildItem
# returns FileInfo with metadata already populated.
$scanStart = Get-Date

if ($doFullScan) {
    $allFiles = @(
        Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $SyncAfterDate -or $_.CreationTime -gt $SyncAfterDate }
    )
    Write-SyncLog "SFTP FULL scan mode (enum took $([math]::Round(((Get-Date) - $scanStart).TotalSeconds, 1))s)"
} else {
    $deltaSinceUtc = $lastDeltaScanUtc.AddMinutes(-$DeltaLookbackMinutes)
    $syncAfterUtc = $SyncAfterDate.ToUniversalTime()
    if ($deltaSinceUtc -lt $syncAfterUtc) {
        $deltaSinceUtc = $syncAfterUtc
    }

    $allFiles = @(
        Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -ge $deltaSinceUtc }
    )
    Write-SyncLog "SFTP DELTA scan mode since UTC $($deltaSinceUtc.ToString('yyyy-MM-dd HH:mm:ss')) (enum took $([math]::Round(((Get-Date) - $scanStart).TotalSeconds, 1))s)"
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
        $sourceLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
        $sourceCreationUtc = $file.CreationTimeUtc.ToString("o")
        $metadata = @{
            "source-last-write-time-utc" = $sourceLastWriteUtc
            "source-creation-time-utc" = $sourceCreationUtc
        }

        Write-SyncLog "[$relativePath] Processing: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        # Decide whether to do a HEAD to compare custom metadata before uploading:
        # - If we have an index (cache or fresh listing) AND the key+size match → HEAD to verify metadata
        # - If we have an index AND the key is missing or size differs → upload directly (no HEAD)
        # - If we have no index (DELTA without cache) → HEAD to know if it's a new upload or a no-op
        $shouldHead = $false
        if ($s3Objects.Count -gt 0) {
            if ($s3Objects.ContainsKey($s3Key) -and $s3Objects[$s3Key] -eq $file.Length) {
                $shouldHead = $true
            }
        } else {
            $shouldHead = $true
        }

        if ($shouldHead) {
            $metadataMatches = $false
            $headExists = $true
            try {
                $s3Head = Get-S3ObjectMetadata -BucketName $BucketName -Key $s3Key -Region $AwsRegion -ErrorAction Stop
                if ($s3Head.ContentLength -eq $file.Length) {
                    $s3SourceLastWriteUtc = [string]$s3Head.Metadata["source-last-write-time-utc"]
                    $s3SourceCreationUtc = [string]$s3Head.Metadata["source-creation-time-utc"]
                    if ($s3SourceLastWriteUtc -eq $sourceLastWriteUtc -and $s3SourceCreationUtc -eq $sourceCreationUtc) {
                        $metadataMatches = $true
                    }
                }
            } catch {
                # 404 / NotFound = object does not exist; any other error logged
                $msg = $_.Exception.Message
                if ($msg -match "NotFound|NoSuchKey|does not exist|404|Not Found") {
                    $headExists = $false
                } else {
                    Write-SyncLog "[$relativePath] WARN: Could not read S3 metadata for compare - $msg" -Level "WARN"
                }
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

            # Write-through: keep the index in sync so the next run can fast-skip this key.
            $s3Objects[$s3Key] = $file.Length
            $s3CacheDirty = $true

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
} else {
    Save-SyncState -LastDeltaScanUtc $nowUtc -LastFullScanUtc $lastFullScanUtc
}

# Persist S3 index cache if any uploads happened during this run (write-through).
# Refreshes done above have already saved; this only covers incremental updates.
if ($s3CacheDirty -and -not $needRefresh) {
    Save-S3IndexCache -Objects $s3Objects -BucketName $BucketName
    Write-SyncLog "S3 index cache updated with $totalSuccess new/changed entries"
}

Write-SyncLog "=========================================="
Write-SyncLog "Sync completed"
Write-SyncLog "  - Successful: $totalSuccess"
Write-SyncLog "  - Errors: $totalErrors"
Write-SyncLog "  - Skipped: $totalSkipped"
Write-SyncLog "=========================================="

Write-SyncLog "Script finished"

} catch {
    Write-SyncLog "ERROR: Script failed with exception: $($_.Exception.Message)" -Level "ERROR"
    throw $_
} finally {
    # Always cleanup lock files, even if errors occur
    if (Test-Path $GlobalLockFile) {
        Remove-Item $GlobalLockFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        Write-SyncLog "Lock file cleaned up"
    }
}
