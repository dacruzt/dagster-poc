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
# AWS MODULE BOOTSTRAP
# -----------------------------------------------------------------------------
# Prefer the modular AWS.Tools.S3 (loads in 2-5s) over the monolithic AWSPowerShell
# (60-90s). When both are installed side-by-side, force this script's session to
# use the modular one so the runspace pool inherits it. Other scripts on the box
# that rely on AWSPowerShell are not affected — only this PowerShell session.
if (Get-Module -Name AWS.Tools.S3 -ListAvailable -ErrorAction SilentlyContinue) {
    try { Remove-Module AWSPowerShell -ErrorAction SilentlyContinue } catch {}
    try { Remove-Module AWSPowerShell.NetCore -ErrorAction SilentlyContinue } catch {}
    Import-Module AWS.Tools.S3 -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync.log"
$LogMaxSizeMB = 50
$LogRetentionDays = 7
$BucketName = "cebroker-sftp-raw-test-backup"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-05-19"
$StateFile = "C:\CEB_FTP_Data\Logs\.sync_state_boardfiles.json"
$S3IndexCacheFile = "C:\CEB_FTP_Data\Logs\.s3_index_boardfiles.json"
$S3IndexCacheTtlHours = 168  # 7 days; full scan refreshes when exceeded
$DeltaLookbackMinutes = 10
$FullReconcileIntervalMinutes = 360
$AppendDateSuffixIfNoDateInName = $true
$DateSuffixFormat = "yyyyMMdd_HHmmss"
$VersionOnChangeAtExistingKey = $true
$ParallelUploadThrottle = 3
$ParallelMinFileCount = 15  # Only spin up the runspace pool when batch >= this

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

function Invoke-LogMaintenance {
    param(
        [string]$Path,
        [int]$MaxSizeMB,
        [int]$RetentionDays
    )

    try {
        $logDir = Split-Path $Path -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        if (Test-Path $Path) {
            $maxBytes = $MaxSizeMB * 1MB
            $currentSize = (Get-Item $Path).Length
            if ($currentSize -ge $maxBytes) {
                $logBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
                $logExt = [System.IO.Path]::GetExtension($Path)
                $archiveName = "{0}.{1}{2}" -f $logBaseName, (Get-Date -Format "yyyyMMdd_HHmmss"), $logExt
                $archivePath = Join-Path $logDir $archiveName

                Move-Item -Path $Path -Destination $archivePath -Force
            }
        }

        $retentionCutoff = (Get-Date).AddDays(-$RetentionDays)
        $logBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $logExt = [System.IO.Path]::GetExtension($Path)
        $archivePattern = "{0}.*{1}" -f $logBaseName, $logExt

        Get-ChildItem -Path $logDir -File -Filter $archivePattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ([System.IO.Path]::GetFileName($Path)) -and $_.LastWriteTime -lt $retentionCutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "[WARN] Log maintenance failed: $($_.Exception.Message)"
    }
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
    param(
        [string]$FilePath,
        [int]$WaitSeconds = 5,
        [int]$SkipIfOlderThanSeconds = 120
    )
    $item = Get-Item $FilePath
    # Files that haven't been touched in the last 2 minutes are almost certainly
    # fully written. Skip the blocking sleep for those — this is the biggest
    # parallelism win since most delta-detected files are already settled.
    if (((Get-Date) - $item.LastWriteTime).TotalSeconds -gt $SkipIfOlderThanSeconds) {
        return $true
    }
    $size1 = $item.Length
    Start-Sleep -Seconds $WaitSeconds
    $size2 = (Get-Item $FilePath).Length
    return $size1 -eq $size2
}

function Get-FileContentSha256 {
    param([string]$FilePath)

    try {
        return (Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch {
        Write-SyncLog "WARN: Could not calculate SHA256 for '$FilePath': $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}

function Get-FileContentMd5 {
    param([string]$FilePath)

    try {
        return (Get-FileHash -Path $FilePath -Algorithm MD5 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch {
        Write-SyncLog "WARN: Could not calculate MD5 for '$FilePath': $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}

function Test-FileNameHasDate {
    param([string]$FileName)

    $nameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $datePatterns = @(
        '20\d{2}[01]\d[0-3]\d',          # yyyyMMdd
        '[0-3]\d[01]\d20\d{2}',          # ddMMyyyy (CERosterAll style)
        '[01]\d[0-3]\d20\d{2}',          # MMddyyyy
        '20\d{2}[-_][01]\d[-_][0-3]\d',  # yyyy-MM-dd / yyyy_MM_dd
        '[0-3]\d[-_][01]\d[-_]20\d{2}',  # dd-MM-yyyy / dd_MM_yyyy
        '20\d{2}[01]\d'                   # yyyyMM
    )

    foreach ($pattern in $datePatterns) {
        if ($nameWithoutExt -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-S3KeyWithDateSuffixFallback {
    param(
        [string]$RelativePath,
        [DateTime]$FileLastWriteTimeUtc
    )

    if (-not $AppendDateSuffixIfNoDateInName) {
        return $RelativePath
    }

    $lastSlash = $RelativePath.LastIndexOf('/')
    $directoryPrefix = ""
    $fileName = $RelativePath

    if ($lastSlash -ge 0) {
        $directoryPrefix = $RelativePath.Substring(0, $lastSlash + 1)
        $fileName = $RelativePath.Substring($lastSlash + 1)
    }

    if (Test-FileNameHasDate -FileName $fileName) {
        return $RelativePath
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $extension = [System.IO.Path]::GetExtension($fileName)
    $dateSuffix = $FileLastWriteTimeUtc.ToString($DateSuffixFormat)
    $renamedFile = "$baseName`_$dateSuffix$extension"

    return "$directoryPrefix$renamedFile"
}

function Get-VersionedS3Key {
    param(
        [string]$S3Key,
        [DateTime]$VersionTimestampUtc
    )

    $lastSlash = $S3Key.LastIndexOf('/')
    $directoryPrefix = ""
    $fileName = $S3Key

    if ($lastSlash -ge 0) {
        $directoryPrefix = $S3Key.Substring(0, $lastSlash + 1)
        $fileName = $S3Key.Substring($lastSlash + 1)
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $extension = [System.IO.Path]::GetExtension($fileName)
    $dateSuffix = $VersionTimestampUtc.ToString($DateSuffixFormat)
    $versionedFile = "$baseName`_v$dateSuffix$extension"

    return "$directoryPrefix$versionedFile"
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
    $json = $state | ConvertTo-Json

    $maxAttempts = 5
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        try {
            if (Test-Path $StateFile) {
                # Clear read-only attribute if some other process set it.
                try { (Get-Item $StateFile).IsReadOnly = $false } catch {}
            }
            Set-Content -Path $StateFile -Value $json -Force -ErrorAction Stop
            return
        } catch {
            if ($i -eq ($maxAttempts - 1)) {
                Write-SyncLog "ERROR writing state file '$StateFile' after $maxAttempts attempts: $($_.Exception.Message)" -Level "ERROR"
                throw
            }
            Start-Sleep -Milliseconds 500
        }
    }
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

    $payload = [PSCustomObject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        BucketName     = $BucketName
        Objects        = $Objects
    }
    $json = $payload | ConvertTo-Json -Depth 5 -Compress

    $maxAttempts = 5
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        try {
            if (Test-Path $S3IndexCacheFile) {
                try { (Get-Item $S3IndexCacheFile).IsReadOnly = $false } catch {}
            }
            Set-Content -Path $S3IndexCacheFile -Value $json -Force -ErrorAction Stop
            return
        } catch {
            if ($i -eq ($maxAttempts - 1)) {
                Write-SyncLog "WARN saving S3 index cache after $maxAttempts attempts: $($_.Exception.Message)" -Level "WARN"
                return
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

# -----------------------------------------------------------------------------
# MAIN PROCESS - Recursive scan
# -----------------------------------------------------------------------------

try {

Invoke-LogMaintenance -Path $LogPath -MaxSizeMB $LogMaxSizeMB -RetentionDays $LogRetentionDays

Write-SyncLog "=========================================="
Write-SyncLog "Starting recursive sync..."
Write-SyncLog "Base: $BasePath"
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0
$totalTransferredBytes = [int64]0

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

# Refresh policy:
# - Always refresh if no cache file exists at all (first run after deploy)
# - Otherwise, only refresh during FULL scans when the cache has expired
$cacheFileExists = Test-Path $S3IndexCacheFile
$needRefresh = -not $cached -and (-not $cacheFileExists -or $doFullScan)
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

    # Per-file scriptblock — used by both sequential and parallel paths below.
    # Returns a PSCustomObject result; main thread aggregates counters after.
    $perFileScript = {
        param($file)

        $filePath = $file.FullName
        $relativePath = $filePath.Substring($BasePath.Length).TrimStart('\\') -replace '\\', '/'

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$relativePath] File is locked/being written, will retry next run" -Level "WARN"
            return [PSCustomObject]@{ Status = 'Skipped'; Bytes = 0; Key = $null }
        }
        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 5)) {
            Write-SyncLog "[$relativePath] File size still changing, will retry next run" -Level "WARN"
            return [PSCustomObject]@{ Status = 'Skipped'; Bytes = 0; Key = $null }
        }
        $baseS3Key = Get-S3KeyWithDateSuffixFallback -RelativePath $relativePath -FileLastWriteTimeUtc $file.LastWriteTimeUtc
        $s3Key = $baseS3Key
        $sourceLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
        $sourceCreationUtc = $file.CreationTimeUtc.ToString("o")
        $localContentSha256 = $null
        $existingFirstSeenUtc = $null
        $metadata = @{
            "source-last-write-time-utc" = $sourceLastWriteUtc
            "source-creation-time-utc" = $sourceCreationUtc
        }

        if ($baseS3Key -ne $relativePath) {
            Write-SyncLog "[$relativePath] No date detected in filename. Upload key changed to: $baseS3Key" -Level "WARN"
        }

        $shouldHead = $false
        $baseKeyExistsInS3 = $false
        if ($s3Objects.Count -gt 0) {
            if ($s3Objects.ContainsKey($baseS3Key)) {
                $baseKeyExistsInS3 = $true
                $shouldHead = $true
            }
            if (-not $s3Objects.ContainsKey($baseS3Key)) {
                $shouldHead = $true
            }
        } else {
            $shouldHead = $true
        }

        if ($shouldHead) {
            $metadataMatches = $false
            try {
                $s3Head = Get-S3ObjectMetadata -BucketName $BucketName -Key $baseS3Key -Region $AwsRegion -ErrorAction Stop
                $baseKeyExistsInS3 = $true
                $s3FirstSeenUtc = [string]$s3Head.Metadata["source-first-seen-utc"]
                if (-not [string]::IsNullOrWhiteSpace($s3FirstSeenUtc)) {
                    $existingFirstSeenUtc = $s3FirstSeenUtc
                }
                if ($s3Head.ContentLength -eq $file.Length) {
                    $s3SourceLastWriteUtc = [string]$s3Head.Metadata["source-last-write-time-utc"]
                    $s3SourceCreationUtc = [string]$s3Head.Metadata["source-creation-time-utc"]
                    if ($s3SourceLastWriteUtc -eq $sourceLastWriteUtc -and $s3SourceCreationUtc -eq $sourceCreationUtc) {
                        $metadataMatches = $true
                    } else {
                        $s3ContentSha256 = [string]$s3Head.Metadata["source-content-sha256"]
                        if (-not [string]::IsNullOrWhiteSpace($s3ContentSha256)) {
                            if ($null -eq $localContentSha256) {
                                $localContentSha256 = Get-FileContentSha256 -FilePath $filePath
                            }
                            if ($localContentSha256 -and ($localContentSha256 -eq $s3ContentSha256)) {
                                $metadataMatches = $true
                                Write-SyncLog "[$relativePath] Content hash matches existing S3 object, skipping upload"
                            }
                        }
                    }
                }
            } catch {
                $msg = $_.Exception.Message
                if ($msg -notmatch "NotFound|NoSuchKey|does not exist|404|Not Found") {
                    Write-SyncLog "[$relativePath] WARN: Could not read S3 metadata for compare - $msg" -Level "WARN"
                }
            }

            if ($metadataMatches) {
                Write-SyncLog "[$relativePath] Unchanged in S3 (same key/size/metadata), skipping upload"
                return [PSCustomObject]@{ Status = 'Skipped'; Bytes = 0; Key = $null }
            }
        }

        if ($VersionOnChangeAtExistingKey -and $baseKeyExistsInS3) {
            $s3Key = Get-VersionedS3Key -S3Key $baseS3Key -VersionTimestampUtc $file.LastWriteTimeUtc
            Write-SyncLog "[$relativePath] Existing key changed. Writing versioned key: $s3Key"
        }

        try {
            if ($null -eq $localContentSha256) {
                $localContentSha256 = Get-FileContentSha256 -FilePath $filePath
            }
            if ($localContentSha256) {
                $metadata["source-content-sha256"] = $localContentSha256
            }

            if ($existingFirstSeenUtc) {
                $metadata["source-first-seen-utc"] = $existingFirstSeenUtc
            } else {
                $firstSeenSource = if ($file.LastWriteTimeUtc -lt $file.CreationTimeUtc) {
                    $file.LastWriteTimeUtc
                } else {
                    $file.CreationTimeUtc
                }
                $metadata["source-first-seen-utc"] = $firstSeenSource.ToString("o")
            }

            $uploadStart = Get-Date
            Write-SyncLog "[$relativePath] Uploading file (size: $([math]::Round($file.Length / 1MB, 2)) MB)..."
            Write-S3Object -BucketName $BucketName -Key $s3Key -File $filePath -Metadata $metadata -Region $AwsRegion
            $uploadDuration = (Get-Date) - $uploadStart
            Write-SyncLog "[$relativePath] Upload completed in $($uploadDuration.TotalSeconds) seconds"
            return [PSCustomObject]@{ Status = 'Success'; Bytes = [int64]$file.Length; Key = $s3Key }
        } catch {
            Write-SyncLog "[$relativePath] ERROR during upload: $($_.Exception.Message)" -Level "ERROR"
            return [PSCustomObject]@{ Status = 'Error'; Bytes = 0; Key = $null }
        }
    }

    # Decide execution mode based on batch size. RunspacePool setup costs 30-90s
    # because each runspace cold-loads the AWS module on its own — that wins
    # back time only when the batch is big enough to amortize the cost.
    $useParallel = ($allFiles.Count -ge $ParallelMinFileCount) -and ($ParallelUploadThrottle -gt 1)

    if ($useParallel) {
        Write-SyncLog "PARALLEL mode (throttle=$ParallelUploadThrottle, batch=$($allFiles.Count) >= threshold=$ParallelMinFileCount)"

        # Build a runspace pool so this works in both Windows PowerShell 5.1 and
        # PowerShell 7+ (ForEach-Object -Parallel is PS 7-only).
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

        # Preload the AWS module so each runspace doesn't cold-start it on first use.
        # Prefer the modular AWS.Tools.S3 if available — much faster than the
        # monolithic AWSPowerShell. Fall back to whatever Write-S3Object resolves to.
        $awsModuleName = $null
        foreach ($candidate in @('AWS.Tools.S3', 'AWSPowerShell.NetCore', 'AWSPowerShell')) {
            if (Get-Module -Name $candidate -ListAvailable -ErrorAction SilentlyContinue) {
                $awsModuleName = $candidate
                break
            }
        }
        if (-not $awsModuleName) {
            $awsModuleName = (Get-Command Write-S3Object -ErrorAction SilentlyContinue).Module.Name
        }
        if ($awsModuleName) {
            $iss.ImportPSModule($awsModuleName)
            Write-SyncLog "Preloading AWS module '$awsModuleName' into runspace pool"
        } else {
            Write-SyncLog "WARN: Could not detect AWS module name; runspaces will auto-load on first cmdlet call (slow)" -Level "WARN"
        }

        # Inject helper functions into every runspace's session state.
        $functionsToInject = @(
            'Write-SyncLog', 'Test-FileNotLocked', 'Get-FileStableSize',
            'Get-FileContentSha256', 'Test-FileNameHasDate',
            'Get-S3KeyWithDateSuffixFallback', 'Get-VersionedS3Key'
        )
        foreach ($funcName in $functionsToInject) {
            $funcDef = (Get-Command $funcName).Definition
            $iss.Commands.Add(
                [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($funcName, $funcDef)
            )
        }

        # Inject shared config + the S3 index (read-only inside threads).
        $varsToInject = @{
            BucketName                     = $BucketName
            AwsRegion                      = $AwsRegion
            BasePath                       = $BasePath
            LogPath                        = $LogPath
            AppendDateSuffixIfNoDateInName = $AppendDateSuffixIfNoDateInName
            DateSuffixFormat               = $DateSuffixFormat
            VersionOnChangeAtExistingKey   = $VersionOnChangeAtExistingKey
            s3Objects                      = $s3Objects
        }
        foreach ($pair in $varsToInject.GetEnumerator()) {
            $iss.Variables.Add(
                [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($pair.Key, $pair.Value, '')
            )
        }

        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $ParallelUploadThrottle, $iss, $Host)
        $runspacePool.Open()

        # Submit every file as a job into the pool.
        $jobs = New-Object System.Collections.Generic.List[object]
        foreach ($file in $allFiles) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($perFileScript).AddArgument($file)
            $jobs.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }

        # EndInvoke each in submission order; pool runs them concurrently behind.
        $parallelResults = foreach ($job in $jobs) {
            try {
                $job.PS.EndInvoke($job.Handle)
            } catch {
                Write-SyncLog "Runspace job failed unexpectedly: $($_.Exception.Message)" -Level "ERROR"
                [PSCustomObject]@{ Status = 'Error'; Bytes = 0; Key = $null }
            } finally {
                $job.PS.Dispose()
            }
        }

        $runspacePool.Close()
        $runspacePool.Dispose()
    } else {
        Write-SyncLog "SEQUENTIAL mode (batch=$($allFiles.Count) < threshold=$ParallelMinFileCount)"
        # Invoke the scriptblock directly in script scope; helper functions and
        # config variables are already available there.
        $parallelResults = foreach ($file in $allFiles) {
            & $perFileScript $file
        }
    }

    # Aggregate results on main thread (single-threaded; safe to mutate state)
    foreach ($r in $parallelResults) {
        switch ($r.Status) {
            'Success' {
                $totalSuccess++
                $totalTransferredBytes += [int64]$r.Bytes
                if ($r.Key) {
                    $s3Objects[$r.Key] = [long]$r.Bytes
                    $s3CacheDirty = $true
                }
            }
            'Error'   { $totalErrors++ }
            'Skipped' { $totalSkipped++ }
        }
    }
}

$runCompletedUtc = (Get-Date).ToUniversalTime()
# If any uploads failed this run, keep the previous delta watermark so the next
# run re-scans the same window and retries failed files. Otherwise transient
# errors silently drop files (DeltaLookbackMinutes overlap is too small to be
# a reliable backstop).
$deltaAdvanceTo = if ($totalErrors -gt 0) {
    Write-SyncLog "$totalErrors upload(s) failed; keeping previous delta watermark to retry next run" -Level "WARN"
    $lastDeltaScanUtc
} else {
    $runCompletedUtc
}
if ($doFullScan) {
    $fullAdvanceTo = if ($totalErrors -gt 0) { $lastFullScanUtc } else { $runCompletedUtc }
    Save-SyncState -LastDeltaScanUtc $deltaAdvanceTo -LastFullScanUtc $fullAdvanceTo
} else {
    Save-SyncState -LastDeltaScanUtc $deltaAdvanceTo -LastFullScanUtc $lastFullScanUtc
}

# Persist S3 index cache once after all parallel uploads complete.
# Saving from inside the parallel block would corrupt the JSON.
if ($s3CacheDirty) {
    Save-S3IndexCache -Objects $s3Objects -BucketName $BucketName
    Write-SyncLog "S3 index cache updated with $totalSuccess new/changed entries"
}

Write-SyncLog "=========================================="
Write-SyncLog "Sync completed"
Write-SyncLog "  - Successful: $totalSuccess"
Write-SyncLog "  - Errors: $totalErrors"
Write-SyncLog "  - Skipped: $totalSkipped"
Write-SyncLog "  - Transferred: $([math]::Round($totalTransferredBytes / 1MB, 2)) MB ($([math]::Round($totalTransferredBytes / 1GB, 3)) GB)"
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
