
$ErrorActionPreference = "Continue"
$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync.log"
$BucketName = "dagster-poc-sand-bucket-7a45862"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-03-03"
$RetentionDays = 30 # Configurable retention period

function Write-SyncLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    $line | Out-File -FilePath $LogPath -Append -Encoding utf8
    Write-Host $line
}

function Test-FileNotLocked {
    param([string]$FilePath)
    try {
        $s = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
        $s.Close(); $s.Dispose()
        return $true
    } catch { return $false }
}

function Get-FileStableSize {
    param([string]$FilePath, [int]$WaitSeconds = 5)
    $s1 = (Get-Item $FilePath).Length
    Start-Sleep -Seconds $WaitSeconds
    $s2 = (Get-Item $FilePath).Length
    return $s1 -eq $s2
}

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

        $relativePath = $fileDir.Substring($BasePath.Length).TrimStart('\') -replace '\\', '/'
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $s3Key = "$relativePath/${timestamp}_$fileName"

        Write-SyncLog "[$relativePath] Processing: $fileName ($([math]::Round($file.Length/1MB,2)) MB)"

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$relativePath] Locked: $fileName" -Level "WARN"
            $totalSkipped++; continue
        }
        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$relativePath] Transferring: $fileName" -Level "WARN"
            $totalSkipped++; continue
        }

        try {
            Write-SyncLog "[$relativePath] Uploading to s3://$BucketName/$s3Key"
            Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion

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

Write-SyncLog "Completed: Success=$totalSuccess | Errors=$totalErrors | Skipped=$totalSkipped"

$cutoffDate = (Get-Date).AddDays(-30)
Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |

Write-SyncLog "=========================================="
Write-SyncLog "Sync completed"
Write-SyncLog "  - Successful: $totalSuccess"
Write-SyncLog "  - Errors: $totalErrors"
Write-SyncLog "  - Skipped: $totalSkipped"
Write-SyncLog "=========================================="

# CLEANUP: Delete files in processed/ older than configurable retention period
$cutoffDate = (Get-Date).AddDays(-$RetentionDays)
$oldFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match 'processed$' -and $_.LastWriteTime -lt $cutoffDate }

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
