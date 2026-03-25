param(
    [switch]$BackfillMetadataForExisting,
    [switch]$AuditOnly,   # Scan and report what needs to be synced, WITHOUT uploading anything
    [switch]$DryRunDelete # Validate orphan deletes without actually removing from S3
)

function Initialize-ReportFile {
    param([string]$Path)

    $reportDir = Split-Path -Parent $Path
    if (-not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }

    if (Test-Path $Path) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }

    Write-ReportRow -Path $Path -Row "FilePath,Status,Message"
}

function Write-ReportRow {
    param(
        [string]$Path,
        [string]$Row,
        [int]$MaxRetries = 5
    )

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            # Use explicit stream handling to avoid intermittent Add-Content stream errors.
            $fileStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = New-Object System.IO.StreamWriter($fileStream)
            $writer.WriteLine($Row)
            $writer.Flush()
            $writer.Dispose()
            $fileStream.Dispose()
            return
        } catch {
            if ($i -eq ($MaxRetries - 1)) {
                throw "Unable to write report row after $MaxRetries attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 300
        }
    }
}

# -----------------------------------------------------------------------------
# CSV Report Setup
# -----------------------------------------------------------------------------
$ReportPath     = "C:\CEB_FTP_Data\Logs\sync-all-report.csv"
$AuditReportPath = "C:\CEB_FTP_Data\Logs\sync-all-audit.csv"
Initialize-ReportFile -Path $ReportPath
if ($AuditOnly) {
    Initialize-ReportFile -Path $AuditReportPath
    # Overwrite header with audit-specific columns
    $fs = New-Object System.IO.FileStream($AuditReportPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $wr = New-Object System.IO.StreamWriter($fs); $wr.WriteLine("Status,LocalPath,S3Key,LocalSizeKB,S3SizeKB,Reason"); $wr.Flush(); $wr.Dispose(); $fs.Dispose()
}

# -----------------------------------------------------------------------------
# MD5 Hash Function
# -----------------------------------------------------------------------------
function Get-FileMD5 {
    param([string]$FilePath)
    try {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $stream = [System.IO.File]::OpenRead($FilePath)
        $hash = $md5.ComputeHash($stream)
        $stream.Close()
        return [BitConverter]::ToString($hash) -replace '-', ''
    } catch {
        return "ERROR"
    }
}

# -----------------------------------------------------------------------------
# S3 MD5 Hash Function (ETag)
# -----------------------------------------------------------------------------
function Get-S3MD5 {
    param([string]$Bucket, [string]$Key, [string]$Region)
    try {
        $obj = Get-S3Object -BucketName $Bucket -Region $Region -Key $Key
        if ($obj -and $obj.ETag) {
            return $obj.ETag.Trim('"')
        } else {
            return ""
        }
    } catch {
        return ""
    }
}

# =============================================================================
# Sync-AllSFTPToS3.ps1 - Full SFTP Sync Script (No processed/ move)
# =============================================================================
# Recursively scans the entire structure under the base path and uploads ALL files
# to S3, preserving the full path, including files in "processed" folders.
# Does NOT move files after upload, does NOT create processed folders.
# =============================================================================

# =============================================================================
# LOCK FILE TO PREVENT CONCURRENT EXECUTIONS
# =============================================================================
$LockFile = "C:\CEB_FTP_Data\Logs\Sync-AllSFTPToS3.lock"
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
if (Test-Path $GlobalLockFile) {
    $globalLockAge = (Get-Date) - (Get-Item $GlobalLockFile).LastWriteTime
    $existingGlobalPid = $null
    $globalLockInfo = Get-Content -Path $GlobalLockFile -Raw -ErrorAction SilentlyContinue
    if ($globalLockInfo -match 'PID=(\d+)') {
        $existingGlobalPid = [int]$Matches[1]
    }

    $isGlobalRunning = $false
    if ($null -ne $existingGlobalPid -and $existingGlobalPid -eq $PID) {
        Write-Host "[WARN] Global lock belongs to current PowerShell session (PID: $existingGlobalPid). Treating as stale and continuing..."
    }
    if ($null -ne $existingGlobalPid -and $globalLockAge.TotalMinutes -lt $GlobalLockMaxAgeMinutes) {
        $globalProc = if ($existingGlobalPid -eq $PID) { $null } else { Get-Process -Id $existingGlobalPid -ErrorAction SilentlyContinue }
        if ($globalProc -and ($globalProc.ProcessName -match 'powershell|pwsh')) {
            $isGlobalRunning = $true
        }
    }

    if ($isGlobalRunning) {
        Write-Host "[ERROR] Another sync script is already running (global lock PID: $existingGlobalPid, age: $([math]::Round($globalLockAge.TotalMinutes, 1)) min). Exiting..."
        exit 1
    }

    Write-Host "[WARN] Removing stale global lock file and continuing..."
    Remove-Item $GlobalLockFile -Force -ErrorAction SilentlyContinue
}
Set-Content -Path $GlobalLockFile -Value "PID=$PID`nScript=Sync-AllSFTPToS3`nStarted=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -Force

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync-all.log"
$BucketName = "cebroker-sftp-raw-test-backup"
$AwsRegion = "us-east-1"
$EnableMirrorDelete = $true       # Delete S3 objects that no longer exist on SFTP
$DeleteOrphanAfterDays = 7        # Grace period: only delete after orphan is absent this many days
$OrphanStateFile = "C:\CEB_FTP_Data\Logs\.sync_orphans_all.json"  # Tracks first-seen orphan timestamps

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

    $consoleColor = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        default { "Gray" }
    }
    Write-Host $logMessage -ForegroundColor $consoleColor

    $source = "AllSFTPSync"
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

function Get-OrphanState {
    if (-not (Test-Path $OrphanStateFile)) { return @{} }
    try {
        $raw = Get-Content -Path $OrphanStateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        # Convert PSCustomObject to hashtable
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
try {
# -----------------------------------------------------------------------------

Write-SyncLog "=========================================="
if ($AuditOnly) {
    Write-SyncLog "Mode: AUDIT ONLY - no files will be uploaded"
    Write-SyncLog "Audit report: $AuditReportPath"
} else {
    Write-SyncLog "Starting full recursive sync (including processed/)..."
}
Write-SyncLog "Base: $BasePath"
Write-SyncLog "Bucket: $BucketName"
if ($BackfillMetadataForExisting) {
    Write-SyncLog "Mode: Backfill metadata for existing S3 objects is ENABLED" -Level "WARN"
}
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0
$totalDeleted = 0
$totalWouldDelete = 0
$auditSynced   = 0
$auditMissing  = 0
$auditChanged  = 0
$auditOrphaned = 0

# Tracks all local keys seen - used for mirror delete and audit orphan detection
$localKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Build S3 index once for fast lookups (avoids per-file Get-S3Object calls)
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

# Find ALL files recursively in all subfolders, including processed folders
Write-SyncLog "Scanning SFTP tree under $BasePath ..."
try {
    $allFiles = @(Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction Stop)
    Write-SyncLog "SFTP files discovered: $($allFiles.Count)"
} catch {
    Write-SyncLog "ERROR scanning SFTP tree '$BasePath': $($_.Exception.Message)" -Level "ERROR"
    throw
}

if ($allFiles.Count -eq 0) {
    Write-SyncLog "No files found to sync"
} else {
    Write-SyncLog "Found $($allFiles.Count) files to sync"

    foreach ($file in $allFiles) {
        $filePath = $file.FullName
        $fileName = $file.Name
        $fileDir = $file.DirectoryName

        # Calculate relative path from BasePath for the S3 key (preserve original path and name)
        $relativePath = $filePath.Substring($BasePath.Length).TrimStart('\') -replace '\\', '/'
        $s3Key = $relativePath
        [void]$localKeys.Add($s3Key)

        Write-SyncLog "[$relativePath] Processing: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        $sourceLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
        $sourceCreationUtc  = $file.CreationTimeUtc.ToString("o")
        $metadata = @{
            "source-last-write-time-utc" = $sourceLastWriteUtc
            "source-creation-time-utc"   = $sourceCreationUtc
        }

        # Check existence and size from the pre-built S3 index
        $existsInS3     = $s3Objects.ContainsKey($s3Key)
        $existingS3Size = if ($existsInS3) { $s3Objects[$s3Key] } else { $null }

        # ------------------------------------------------------------------
        # AUDIT ONLY MODE: just classify and report, no upload
        # ------------------------------------------------------------------
        if ($AuditOnly) {
            if (-not $existsInS3) {
                $auditRow = "MISSING,$filePath,$s3Key,$([math]::Round($file.Length/1KB,1)),,Not in S3"
                Write-ReportRow -Path $AuditReportPath -Row $auditRow
                Write-SyncLog "[$relativePath] MISSING - not in S3 ($([math]::Round($file.Length/1KB,1)) KB)"
                $auditMissing++
            } elseif ($existingS3Size -ne $file.Length) {
                $auditRow = "SIZE_MISMATCH,$filePath,$s3Key,$([math]::Round($file.Length/1KB,1)),$([math]::Round($existingS3Size/1KB,1)),Local vs S3 size differ"
                Write-ReportRow -Path $AuditReportPath -Row $auditRow
                Write-SyncLog "[$relativePath] SIZE_MISMATCH - local $($file.Length) B vs S3 $existingS3Size B"
                $auditChanged++
            } else {
                # Same size - check metadata
                $metadataMatches = $false
                try {
                    $s3Head = Get-S3ObjectMetadata -BucketName $BucketName -Key $s3Key -Region $AwsRegion -ErrorAction Stop
                    $s3LastWrite = [string]$s3Head.Metadata["source-last-write-time-utc"]
                    $s3Creation  = [string]$s3Head.Metadata["source-creation-time-utc"]
                    if ($s3LastWrite -eq $sourceLastWriteUtc -and $s3Creation -eq $sourceCreationUtc) {
                        $metadataMatches = $true
                    }
                } catch {
                    Write-SyncLog "[$relativePath] WARN: Could not read S3 metadata - $($_.Exception.Message)" -Level "WARN"
                }

                if ($metadataMatches) {
                    $auditRow = "SYNCED,$filePath,$s3Key,$([math]::Round($file.Length/1KB,1)),$([math]::Round($existingS3Size/1KB,1)),Up to date"
                    Write-ReportRow -Path $AuditReportPath -Row $auditRow
                    Write-SyncLog "[$relativePath] SYNCED - up to date"
                    $auditSynced++
                } else {
                    $auditRow = "METADATA_DRIFT,$filePath,$s3Key,$([math]::Round($file.Length/1KB,1)),$([math]::Round($existingS3Size/1KB,1)),Same size but metadata differs"
                    Write-ReportRow -Path $AuditReportPath -Row $auditRow
                    Write-SyncLog "[$relativePath] METADATA_DRIFT - same size but metadata differs"
                    $auditChanged++
                }
            }
            continue
        }

        if ($existsInS3 -and -not $BackfillMetadataForExisting) {
            # Size matches - compare metadata to decide whether to skip
            if ($existingS3Size -eq $file.Length) {
                $metadataMatches = $false
                try {
                    $s3Head = Get-S3ObjectMetadata -BucketName $BucketName -Key $s3Key -Region $AwsRegion -ErrorAction Stop
                    $s3LastWrite = [string]$s3Head.Metadata["source-last-write-time-utc"]
                    $s3Creation  = [string]$s3Head.Metadata["source-creation-time-utc"]
                    if ($s3LastWrite -eq $sourceLastWriteUtc -and $s3Creation -eq $sourceCreationUtc) {
                        $metadataMatches = $true
                    }
                } catch {
                    Write-SyncLog "[$relativePath] WARN: Could not read S3 metadata for compare - $($_.Exception.Message)" -Level "WARN"
                }

                if ($metadataMatches) {
                    Write-SyncLog "[$relativePath] Unchanged in S3 (same key/size/metadata), skipping: $fileName"
                    Write-ReportRow -Path $ReportPath -Row "$filePath,SKIPPED,Unchanged in S3"
                    $totalSkipped++
                    continue
                }
                # Size matches but metadata differs - re-upload
            } else {
                # Different size - re-upload
                Write-SyncLog "[$relativePath] Size changed (local: $($file.Length), S3: $existingS3Size), re-uploading"
            }
        }

        if ($existsInS3 -and $BackfillMetadataForExisting -and $null -ne $existingS3Size -and $existingS3Size -ne $file.Length) {
            Write-SyncLog "[$relativePath] ERROR: Backfill skipped because local size ($($file.Length)) differs from S3 size ($existingS3Size)" -Level "ERROR"
            Write-ReportRow -Path $ReportPath -Row "$filePath,ERROR,Backfill skipped due to size mismatch with existing S3 object"
            $totalErrors++
            continue
        }

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$relativePath] File is locked, skipping: $fileName" -Level "WARN"
            Write-ReportRow -Path $ReportPath -Row "$filePath,SKIPPED,File locked"
            $totalSkipped++
            continue
        }

        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$relativePath] File is being transferred, skipping: $fileName" -Level "WARN"
            Write-ReportRow -Path $ReportPath -Row "$filePath,SKIPPED,File unstable"
            $totalSkipped++
            continue
        }

        $maxRetries = 3
        $attempt = 0
        $uploaded = $false
        $errorMsg = ""

        if ($existsInS3 -and $BackfillMetadataForExisting) {
            Write-SyncLog "[$relativePath] Backfill mode active: object exists in S3, updating metadata from local file timestamps"
        }

        while (-not $uploaded -and $attempt -lt $maxRetries) {
            try {
                Write-SyncLog "[$relativePath] Uploading to s3://$BucketName/$s3Key (Attempt $($attempt+1))"
                Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion -Metadata $metadata -ErrorAction Stop
                $uploaded = $true
            } catch {
                $errorMsg = $_.Exception.Message
                Write-SyncLog "[$relativePath] ERROR: $fileName - $errorMsg" -Level "ERROR"

                if ($errorMsg -match "not authorized to perform: s3:PutObject") {
                    Write-SyncLog "FATAL: Missing IAM permission s3:PutObject for role on bucket '$BucketName'. Aborting run to avoid repetitive failures." -Level "ERROR"
                    $totalErrors++
                    break
                }

                $attempt++
                Start-Sleep -Seconds 5
            }
        }

        if ($uploaded) {
            # Validación de integridad
            $localMD5 = Get-FileMD5 $filePath
            $s3MD5 = Get-S3MD5 $BucketName $s3Key $AwsRegion
            if ($localMD5 -eq $s3MD5) {
                $status = if ($existsInS3 -and $BackfillMetadataForExisting) { "BACKFILLED" } else { "UPLOADED" }
                Write-SyncLog "[$relativePath] OK: $fileName -> $s3Key (MD5 match) [$status]"
                Write-ReportRow -Path $ReportPath -Row "$filePath,$status,MD5 match"
                $totalSuccess++
            } else {
                Write-SyncLog "[$relativePath] WARNING: MD5 mismatch for $fileName (local: $localMD5, S3: $s3MD5)" -Level "WARN"
                $status = if ($existsInS3 -and $BackfillMetadataForExisting) { "BACKFILLED" } else { "UPLOADED" }
                Write-ReportRow -Path $ReportPath -Row "$filePath,ERROR,MD5 mismatch after $status"
                $totalErrors++
            }
        } else {
            Write-SyncLog "[$relativePath] ERROR: $fileName - Upload failed after $maxRetries attempts" -Level "ERROR"
            Write-ReportRow -Path $ReportPath -Row "$filePath,ERROR,Upload failed after $maxRetries attempts: $errorMsg"
            $totalErrors++
        }
    }
}

# Mirror delete / Audit orphans: keys in S3 but not on SFTP
if ($AuditOnly) {
    foreach ($orphanKey in $s3Objects.Keys) {
        if (-not $localKeys.Contains($orphanKey)) {
            $auditRow = "ORPHAN,,$orphanKey,,,$([math]::Round($s3Objects[$orphanKey]/1KB,1)),In S3 but not on SFTP"
            Write-ReportRow -Path $AuditReportPath -Row $auditRow
            Write-SyncLog "[$orphanKey] ORPHAN - exists in S3 but not on SFTP"
            $auditOrphaned++
        }
    }
} elseif ($EnableMirrorDelete) {
    Write-SyncLog "Mirror mode: checking for S3 orphans (grace period: $DeleteOrphanAfterDays days)..."
    $nowUtc = (Get-Date).ToUniversalTime()
    $orphanState = Get-OrphanState
    $updatedOrphanState = @{}

    foreach ($orphanKey in $s3Objects.Keys) {
        if ($localKeys.Contains($orphanKey)) { continue }  # Still exists on SFTP, not an orphan

        if ($orphanState.ContainsKey($orphanKey)) {
            # Already tracked - check if grace period has elapsed
            try {
                $firstSeen = ([DateTimeOffset]::Parse([string]$orphanState[$orphanKey])).UtcDateTime
            } catch {
                $firstSeen = $nowUtc
            }
            $ageDays = ($nowUtc - $firstSeen).TotalDays

            if ($ageDays -ge $DeleteOrphanAfterDays) {
                try {
                    if ($DryRunDelete) {
                        Write-SyncLog "DRY-RUN delete candidate (absent $([math]::Round($ageDays,1)) days): $orphanKey" -Level "WARN"
                        Write-ReportRow -Path $ReportPath -Row ",WOULD_DELETE,Dry-run orphan delete after $([math]::Round($ageDays,1)) days: $orphanKey"
                        $updatedOrphanState[$orphanKey] = $orphanState[$orphanKey]
                        $totalWouldDelete++
                        continue
                    }

                    Remove-S3Object -BucketName $BucketName -Key $orphanKey -Region $AwsRegion -Force -ErrorAction Stop
                    Write-SyncLog "DELETED orphan from S3 (absent $([math]::Round($ageDays,1)) days): $orphanKey"
                    Write-ReportRow -Path $ReportPath -Row ",DELETED,Orphan removed after $([math]::Round($ageDays,1)) days: $orphanKey"
                    $totalDeleted++
                    # Don't carry forward to updatedOrphanState - it's gone
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
            # First time we see this key as orphan - start the grace period clock
            Write-SyncLog "[$orphanKey] New orphan detected - grace period started (will delete after $DeleteOrphanAfterDays days)"
            $updatedOrphanState[$orphanKey] = $nowUtc.ToString("o")
        }
    }

    Save-OrphanState -State $updatedOrphanState
    Write-SyncLog "Mirror delete complete. Deleted: $totalDeleted | Pending: $($updatedOrphanState.Count)"
}

Write-SyncLog "=========================================="
if ($AuditOnly) {
    $auditTotal = $auditSynced + $auditMissing + $auditChanged
    Write-SyncLog "Audit complete ($auditTotal files scanned)"
    Write-SyncLog "  - SYNCED (up to date):          $auditSynced"
    Write-SyncLog "  - MISSING (not in S3):          $auditMissing"
    Write-SyncLog "  - CHANGED (size/metadata diff):  $auditChanged"
    Write-SyncLog "  - ORPHANS (in S3, not on SFTP): $auditOrphaned"
    Write-SyncLog "  Report saved to: $AuditReportPath"
} else {
    Write-SyncLog "Sync completed"
    Write-SyncLog "  - Successful:          $totalSuccess"
    Write-SyncLog "  - Errors:              $totalErrors"
    Write-SyncLog "  - Skipped:             $totalSkipped"
    Write-SyncLog "  - Deleted (orphans):   $totalDeleted"
    if ($DryRunDelete) {
        Write-SyncLog "  - Dry-run delete candidates: $totalWouldDelete"
    }
}
Write-SyncLog "=========================================="

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
