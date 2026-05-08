# =============================================================================
# Get-SftpFileStats.ps1 - File stats by year for the SFTP folder
# =============================================================================
# Recursively scans the base path and reports, per year, how many files exist
# and the total size in GB. Useful to understand storage growth over time.
#
# Usage:
#   .\Get-SftpFileStats.ps1                              # uses LastWriteTime
#   .\Get-SftpFileStats.ps1 -DateField CreationTime
#   .\Get-SftpFileStats.ps1 -BasePath "D:\OtherData"
#   .\Get-SftpFileStats.ps1 -CsvPath "C:\CEB_FTP_Data\Logs\sftp-stats.csv"
# =============================================================================

param(
    [string]$BasePath = "C:\CEB_FTP_Data\SFTP",

    [ValidateSet("LastWriteTime", "CreationTime")]
    [string]$DateField = "LastWriteTime",

    [string]$CsvPath
)

if (-not (Test-Path $BasePath)) {
    Write-Error "Path not found: $BasePath"
    exit 1
}

Write-Host "Scanning $BasePath (grouping by $DateField year) ..." -ForegroundColor Cyan
$start = Get-Date

$files = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue

if (-not $files) {
    Write-Host "No files found under $BasePath" -ForegroundColor Yellow
    exit 0
}

$stats = $files |
    Group-Object { $_.$DateField.Year } |
    ForEach-Object {
        $totalBytes = ($_.Group | Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{
            Year     = [string]$_.Name
            Files    = $_.Count
            SizeGB   = [math]::Round($totalBytes / 1GB, 2)
            SizeMB   = [math]::Round($totalBytes / 1MB, 2)
        }
    } |
    Sort-Object Year

$totalFiles = ($files | Measure-Object).Count
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$totalGB    = [math]::Round($totalBytes / 1GB, 2)
$totalMB    = [math]::Round($totalBytes / 1MB, 2)
$elapsed    = (Get-Date) - $start

$totalRow = [PSCustomObject]@{
    Year   = "TOTAL"
    Files  = $totalFiles
    SizeGB = $totalGB
    SizeMB = $totalMB
}

$statsWithTotal = @($stats) + $totalRow
$statsWithTotal | Format-Table -AutoSize

Write-Host ""
Write-Host "Scan took $([math]::Round($elapsed.TotalSeconds,1))s" -ForegroundColor Green

if ($CsvPath) {
    $statsWithTotal | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV saved: $CsvPath" -ForegroundColor Cyan
}
