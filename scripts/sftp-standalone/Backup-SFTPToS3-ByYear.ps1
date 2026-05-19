# =============================================================================
# Backup-SFTPToS3-ByYear.ps1
# =============================================================================
# Creates yearly backups from a local SFTP mirror to S3.
#
# S3 key format:
#   <S3RootPrefix>/<Year>/<original relative path>
#
# Example:
#   Local: C:\CEB_FTP_Data\SFTP\providers\abc\file.csv
#   Date : 2025-08-10 (LastWriteTime)
#   S3   : yearly-backups/2025/providers/abc/file.csv
#
# Note:
#   S3 LastModified is set by AWS at upload time and cannot be overwritten.
#   This script preserves original file dates in S3 object metadata.
#
# Usage examples:
#   .\Backup-SFTPToS3-ByYear.ps1
#   .\Backup-SFTPToS3-ByYear.ps1 -Years 2024,2025
#   .\Backup-SFTPToS3-ByYear.ps1 -DateField CreationTime
#   .\Backup-SFTPToS3-ByYear.ps1 -S3RootPrefix "backups/sftp" -ForceUpload
# =============================================================================

param(
    [string]$BasePath = "C:\CEB_FTP_Data\SFTP",
    [string]$BucketName = "cebroker-sftp-raw-test-backup",
    [string]$AwsRegion = "us-east-1",

    [ValidateSet("LastWriteTime", "CreationTime")]
    [string]$DateField = "LastWriteTime",

    [int[]]$Years,

    [string]$S3RootPrefix = "yearly-backups",
    [string]$LogPath = "C:\CEB_FTP_Data\Logs\backup-by-year.log",

    [ValidateRange(1, 500)]
    [int]$BatchSize = 5,

    [switch]$ForceUpload
)

$ErrorActionPreference = "Stop"

function Write-BackupLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    $logDir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Add-Content -Path $LogPath -Value $line

    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        default { "Gray" }
    }

    Write-Host $line -ForegroundColor $color
}

function Get-RelativeS3Path {
    param(
        [string]$Root,
        [string]$FilePath
    )

    $relative = $FilePath.Substring($Root.Length).TrimStart('\\')
    return ($relative -replace '\\', '/')
}

function Join-S3Key {
    param(
        [string]$Prefix,
        [string]$Year,
        [string]$RelativePath
    )

    $cleanPrefix = [string]::IsNullOrWhiteSpace($Prefix) ? "" : ($Prefix.Trim('/'))
    if ([string]::IsNullOrWhiteSpace($cleanPrefix)) {
        return "$Year/$RelativePath"
    }

    return "$cleanPrefix/$Year/$RelativePath"
}

try {
    if (-not (Test-Path $BasePath)) {
        throw "BasePath not found: $BasePath"
    }

    Write-BackupLog "================================================="
    Write-BackupLog "Starting yearly backup to S3"
    Write-BackupLog "BasePath: $BasePath"
    Write-BackupLog "Bucket: $BucketName"
    Write-BackupLog "Region: $AwsRegion"
    Write-BackupLog "DateField: $DateField"
    Write-BackupLog "S3RootPrefix: $S3RootPrefix"
    Write-BackupLog "BatchSize: $BatchSize"
    if ($Years -and $Years.Count -gt 0) {
        Write-BackupLog "Year filter: $($Years -join ', ')"
    } else {
        Write-BackupLog "Year filter: all"
    }
    Write-BackupLog "================================================="

    $start = Get-Date

    $files = @(Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-BackupLog "No files found under $BasePath" "WARN"
        exit 0
    }

    if ($Years -and $Years.Count -gt 0) {
        $yearSet = @{}
        foreach ($y in $Years) { $yearSet[[string]$y] = $true }

        $files = @(
            $files | Where-Object {
                $fileYear = [string]($_.$DateField.Year)
                $yearSet.ContainsKey($fileYear)
            }
        )
    }

    if ($files.Count -eq 0) {
        Write-BackupLog "No files match the selected years." "WARN"
        exit 0
    }

    $totalFiles = $files.Count
    $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
    $totalGB = [math]::Round($totalBytes / 1GB, 2)

    Write-BackupLog "Files to process: $totalFiles (~$totalGB GB)"

    $grouped = $files | Group-Object { $_.$DateField.Year } | Sort-Object Name
    foreach ($g in $grouped) {
        $groupBytes = ($g.Group | Measure-Object -Property Length -Sum).Sum
        $groupGB = [math]::Round($groupBytes / 1GB, 2)
        Write-BackupLog "Year $($g.Name): $($g.Count) files (~$groupGB GB)"
    }

    $uploaded = 0
    $skipped = 0
    $errors = 0

    for ($offset = 0; $offset -lt $files.Count; $offset += $BatchSize) {
        $batchEnd = [Math]::Min($offset + $BatchSize - 1, $files.Count - 1)
        $batch = $files[$offset..$batchEnd]
        $batchNumber = [int]([Math]::Floor($offset / $BatchSize) + 1)
        $totalBatches = [int]([Math]::Ceiling($files.Count / [double]$BatchSize))
        $batchStart = Get-Date

        Write-BackupLog "Starting batch $batchNumber/$totalBatches ($($batch.Count) files)"

        foreach ($file in $batch) {
            $fileYear = [string]($file.$DateField.Year)
            $relativePath = Get-RelativeS3Path -Root $BasePath -FilePath $file.FullName
            $s3Key = Join-S3Key -Prefix $S3RootPrefix -Year $fileYear -RelativePath $relativePath

            $sourceLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
            $sourceCreationUtc = $file.CreationTimeUtc.ToString("o")
            $backupDateValueUtc = $file.$DateField.ToUniversalTime().ToString("o")

            $metadata = @{
                "source-last-write-time-utc" = $sourceLastWriteUtc
                "source-creation-time-utc" = $sourceCreationUtc
                "backup-date-field" = $DateField
                "backup-date-value-utc" = $backupDateValueUtc
                "backup-year" = $fileYear
            }

            try {
                if (-not $ForceUpload) {
                    $skipUpload = $false
                    try {
                        $head = Get-S3ObjectMetadata -BucketName $BucketName -Key $s3Key -Region $AwsRegion -ErrorAction Stop
                        $s3LastWrite = [string]$head.Metadata["source-last-write-time-utc"]
                        $s3Creation = [string]$head.Metadata["source-creation-time-utc"]

                        if (($head.ContentLength -eq $file.Length) -and ($s3LastWrite -eq $sourceLastWriteUtc) -and ($s3Creation -eq $sourceCreationUtc)) {
                            $skipUpload = $true
                        }
                    } catch {
                        $msg = $_.Exception.Message
                        if ($msg -notmatch "NotFound|NoSuchKey|does not exist|404|Not Found") {
                            Write-BackupLog "[$relativePath] WARN metadata check failed: $msg" "WARN"
                        }
                    }

                    if ($skipUpload) {
                        $skipped++
                        Write-BackupLog "[$relativePath] Skipped (already in S3 with same size + metadata)"
                        continue
                    }
                }

                Write-S3Object -BucketName $BucketName -Key $s3Key -File $file.FullName -Metadata $metadata -Region $AwsRegion | Out-Null
                $uploaded++
                Write-BackupLog "[$relativePath] Uploaded to s3://$BucketName/$s3Key"
            } catch {
                $errors++
                Write-BackupLog "[$relativePath] ERROR upload failed: $($_.Exception.Message)" "ERROR"
            }
        }

        $batchElapsed = (Get-Date) - $batchStart
        Write-BackupLog "Completed batch $batchNumber/$totalBatches in $([math]::Round($batchElapsed.TotalSeconds, 1))s"
    }

    $elapsed = (Get-Date) - $start
    Write-BackupLog "================================================="
    Write-BackupLog "Backup completed"
    Write-BackupLog "Uploaded: $uploaded"
    Write-BackupLog "Skipped : $skipped"
    Write-BackupLog "Errors  : $errors"
    Write-BackupLog "Duration: $([math]::Round($elapsed.TotalMinutes, 2)) min"
    Write-BackupLog "================================================="

    if ($errors -gt 0) {
        exit 2
    }

    exit 0
} catch {
    Write-BackupLog "Fatal error: $($_.Exception.Message)" "ERROR"
    exit 1
}
