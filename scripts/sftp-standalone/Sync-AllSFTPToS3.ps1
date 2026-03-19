# -----------------------------------------------------------------------------
# CSV Report Setup
# -----------------------------------------------------------------------------
$ReportPath = "C:\CEB_FTP_Data\Logs\sync-all-report.csv"
if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force }
Add-Content -Path $ReportPath -Value "FilePath,Status,Message"

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
$LockFile = "$PSScriptRoot\Sync-AllSFTPToS3.lock"
if (Test-Path $LockFile) {
    Write-Host "[ERROR] Another instance is already running. Exiting..."
    exit 1
}
New-Item -ItemType File -Path $LockFile -Force | Out-Null

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync-all.log"
$BucketName = "dagster-poc-sand-bucket-7a45862"
$AwsRegion = "us-east-1"

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
    try {
        if (-not (Test-Path $LogPath)) {
            New-Item -ItemType File -Path $LogPath -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $logMessage -Force
    } catch {
        Write-Host "[ERROR] Could not write to log file: $LogPath ($($_.Exception.Message))"
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
    param([string]$FilePath, [int]$WaitSeconds = 5)
    $size1 = (Get-Item $FilePath).Length
    Start-Sleep -Seconds $WaitSeconds
    $size2 = (Get-Item $FilePath).Length
    return $size1 -eq $size2
}

# -----------------------------------------------------------------------------
# MAIN PROCESS - Recursive scan
try {
# -----------------------------------------------------------------------------

Write-SyncLog "=========================================="
Write-SyncLog "Starting full recursive sync (including processed/)..."
Write-SyncLog "Base: $BasePath"
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0

# Find ALL files recursively in all subfolders, including processed folders
$allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue

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

        Write-SyncLog "[$relativePath] Processing: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        # Check if file already exists in S3
        $existsInS3 = $false
        try {
            $s3Objects = Get-S3Object -BucketName $BucketName -Region $AwsRegion -KeyPrefix $relativePath
            foreach ($obj in $s3Objects) {
                if ($obj.Key -eq $s3Key) {
                    $existsInS3 = $true
                    break
                }
            }
        } catch {
            Write-SyncLog "[$relativePath] WARN: Could not verify S3 existence for $fileName - $($_.Exception.Message)" -Level "WARN"
        }

        if ($existsInS3) {
            Write-SyncLog "[$relativePath] File already exists in S3, skipping: $fileName" -Level "INFO"
            Add-Content -Path $ReportPath -Value "$filePath,SKIPPED,Already exists in S3"
            $totalSkipped++
            continue
        }

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$relativePath] File is locked, skipping: $fileName" -Level "WARN"
            Add-Content -Path $ReportPath -Value "$filePath,SKIPPED,File locked"
            $totalSkipped++
            continue
        }

        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$relativePath] File is being transferred, skipping: $fileName" -Level "WARN"
            Add-Content -Path $ReportPath -Value "$filePath,SKIPPED,File unstable"
            $totalSkipped++
            continue
        }

        $maxRetries = 3
        $attempt = 0
        $uploaded = $false
        $errorMsg = ""
        while (-not $uploaded -and $attempt -lt $maxRetries) {
            try {
                Write-SyncLog "[$relativePath] Uploading to s3://$BucketName/$s3Key (Attempt $($attempt+1))"
                Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion
                $uploaded = $true
            } catch {
                $errorMsg = $_.Exception.Message
                Write-SyncLog "[$relativePath] ERROR: $fileName - $errorMsg" -Level "ERROR"
                $attempt++
                Start-Sleep -Seconds 5
            }
        }

        if ($uploaded) {
            # Validación de integridad
            $localMD5 = Get-FileMD5 $filePath
            $s3MD5 = Get-S3MD5 $BucketName $s3Key $AwsRegion
            if ($localMD5 -eq $s3MD5) {
                Write-SyncLog "[$relativePath] OK: $fileName -> $s3Key (MD5 match)"
                Add-Content -Path $ReportPath -Value "$filePath,UPLOADED,MD5 match"
                $totalSuccess++
            } else {
                Write-SyncLog "[$relativePath] WARNING: MD5 mismatch for $fileName (local: $localMD5, S3: $s3MD5)" -Level "WARN"
                Add-Content -Path $ReportPath -Value "$filePath,UPLOADED,MD5 mismatch"
                $totalSuccess++
            }
        } else {
            Write-SyncLog "[$relativePath] ERROR: $fileName - Upload failed after $maxRetries attempts" -Level "ERROR"
            Add-Content -Path $ReportPath -Value "$filePath,ERROR,Upload failed after $maxRetries attempts: $errorMsg"
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

Write-SyncLog "Script finished"
Write-SyncLog "Final summary:"
Write-SyncLog "  - Files uploaded: $totalSuccess"
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
