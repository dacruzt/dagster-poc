# =============================================================================
# Run-Backup-ByYear-Batches.ps1
# =============================================================================
# Orchestrates yearly SFTP backup runs, executing one year at a time.
# It continues with the next year even if one year fails.
#
# Default behavior:
# - Detect years from file dates under BasePath (DateField)
# - Run newest to oldest
# - Use BatchSize 5 for each yearly run
#
# Usage examples:
#   .\Run-Backup-ByYear-Batches.ps1
#   .\Run-Backup-ByYear-Batches.ps1 -Years 2026,2025,2024
#   .\Run-Backup-ByYear-Batches.ps1 -BatchSize 10
#   .\Run-Backup-ByYear-Batches.ps1 -ForceUpload
# =============================================================================

param(
    [string]$BasePath = "C:\CEB_FTP_Data\SFTP",
    [string]$BucketName = "cebroker-sftp-raw-test-backup",
    [string]$AwsRegion = "us-east-1",

    [ValidateSet("LastWriteTime", "CreationTime")]
    [string]$DateField = "LastWriteTime",

    [int[]]$Years,

    [ValidateRange(1, 500)]
    [int]$BatchSize = 5,

    [string]$S3RootPrefix = "yearly-backups",
    [string]$LogPath = "C:\CEB_FTP_Data\Logs\backup-by-year-orchestrator.log",

    [switch]$ForceUpload,

    [string]$BackupScriptPath = "C:\CEB_FTP_Data\Scripts\yearly-backup\Backup-SFTPToS3-ByYear.ps1"
)

$ErrorActionPreference = "Stop"

function Write-OrchestratorLog {
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

try {
    if (-not (Test-Path $BasePath)) {
        throw "BasePath not found: $BasePath"
    }

    if (-not (Test-Path $BackupScriptPath)) {
        throw "Backup script not found: $BackupScriptPath"
    }

    if (-not $Years -or $Years.Count -eq 0) {
        Write-OrchestratorLog "No years provided. Detecting years from $BasePath using $DateField ..."

        $detected = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
            Group-Object { $_.$DateField.Year } |
            ForEach-Object { [int]$_.Name } |
            Sort-Object -Descending

        $Years = @($detected)
    } else {
        $Years = @($Years | Sort-Object -Descending)
    }

    if (-not $Years -or $Years.Count -eq 0) {
        Write-OrchestratorLog "No years found to process." "WARN"
        exit 0
    }

    Write-OrchestratorLog "================================================="
    Write-OrchestratorLog "Starting orchestrated yearly backup"
    Write-OrchestratorLog "Backup script: $BackupScriptPath"
    Write-OrchestratorLog "Years: $($Years -join ', ')"
    Write-OrchestratorLog "BatchSize: $BatchSize"
    Write-OrchestratorLog "================================================="

    $overallStart = Get-Date
    $results = @()

    foreach ($year in $Years) {
        $yearStart = Get-Date
        Write-OrchestratorLog "Starting year $year ..."

        $invokeArgs = @{
            BasePath = $BasePath
            BucketName = $BucketName
            AwsRegion = $AwsRegion
            DateField = $DateField
            Years = @($year)
            BatchSize = $BatchSize
            S3RootPrefix = $S3RootPrefix
        }

        if ($ForceUpload) {
            $invokeArgs["ForceUpload"] = $true
        }

        $yearStatus = "SUCCESS"
        $yearError = ""

        try {
            & $BackupScriptPath @invokeArgs
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                $yearStatus = "FAILED"
                $yearError = "Backup script exit code: $exitCode"
                Write-OrchestratorLog "Year $year failed with exit code $exitCode" "ERROR"
            } else {
                Write-OrchestratorLog "Year $year completed successfully"
            }
        } catch {
            $yearStatus = "FAILED"
            $yearError = $_.Exception.Message
            Write-OrchestratorLog "Year $year failed: $yearError" "ERROR"
        }

        $yearElapsed = (Get-Date) - $yearStart
        $results += [PSCustomObject]@{
            Year = $year
            Status = $yearStatus
            DurationMinutes = [math]::Round($yearElapsed.TotalMinutes, 2)
            Error = $yearError
        }
    }

    $overallElapsed = (Get-Date) - $overallStart
    Write-OrchestratorLog "================================================="
    Write-OrchestratorLog "Orchestrated backup finished in $([math]::Round($overallElapsed.TotalMinutes, 2)) minutes"

    foreach ($row in $results) {
        if ($row.Status -eq "SUCCESS") {
            Write-OrchestratorLog "Year $($row.Year): $($row.Status) ($($row.DurationMinutes) min)"
        } else {
            Write-OrchestratorLog "Year $($row.Year): $($row.Status) ($($row.DurationMinutes) min) - $($row.Error)" "ERROR"
        }
    }

    $failedCount = ($results | Where-Object { $_.Status -eq "FAILED" }).Count
    Write-OrchestratorLog "Failed years: $failedCount"
    Write-OrchestratorLog "================================================="

    $summaryPath = "C:\CEB_FTP_Data\Logs\backup-by-year-summary-$((Get-Date).ToString('yyyyMMdd_HHmmss')).csv"
    $results | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8
    Write-OrchestratorLog "Summary CSV: $summaryPath"

    if ($failedCount -gt 0) {
        exit 2
    }

    exit 0
} catch {
    Write-OrchestratorLog "Fatal error: $($_.Exception.Message)" "ERROR"
    exit 1
}
