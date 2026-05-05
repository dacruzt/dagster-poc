# Setup: SFTP to S3 Sync - ceb-sftp-01

## Resumen

Guia paso a paso para configurar el script de sincronizacion (modo mirror) de archivos desde la EC2 Windows `ceb-sftp-01` hacia el bucket S3 `cebroker-sftp-raw-prod-backup`.

El script preserva la ruta y el nombre original. **No** mueve ni renombra archivos en SFTP. Cuando un archivo desaparece de SFTP, se elimina de S3 despues de un periodo de gracia (ver mirror delete).

**Flujo:**
```
EC2 (ceb-sftp-01)                              S3 (mirror)
C:\CEB_FTP_Data\SFTP\                          cebroker-sftp-raw-prod-backup
  Boards\Board_183\archivo.csv         -->       Boards/Board_183/archivo.csv
  Boards\Board_NDSBOTP\archivo.csv     -->       Boards/Board_NDSBOTP/archivo.csv
  Providers\archivo.csv                -->       Providers/archivo.csv
```

---

## AWS

EC2 y bucket S3 viven ambos en la misma cuenta `118233265530` (same-account).

| Recurso | Valor |
|---------|-------|
| Account ID | `118233265530` |
| EC2 Instance | `i-0947a572049fe5f8b` (`ceb-sftp-01`) |
| Bucket S3 | `cebroker-sftp-raw-prod-backup` |
| Region | `us-east-1` |

---

## Paso 1: Crear IAM Role para la EC2

Si la instancia EC2 no tiene un IAM Role asignado, crear uno nuevo. Si ya tiene un role, agregar la inline policy del paso 1.2 al role existente.

### 1.1 Crear el Role

1. Ir a **IAM > Roles > Create Role**
2. Seleccionar **AWS service > EC2**
3. En Step 2 (Add permissions): **Skip** (no seleccionar ninguna policy)
4. En Step 3: **Role name:** `ceb-sftp-s3-sync-role`
5. Click **Create role**

### 1.2 Agregar Inline Policy al Role

1. Ir a **IAM > Roles > ceb-sftp-s3-sync-role**
2. Pestana **Permissions > Add permissions > Create inline policy**
3. Click pestana **JSON**
4. Pegar:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowWriteToBucket",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:PutObjectAcl",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::cebroker-sftp-raw-prod-backup/*"
        },
        {
            "Sid": "AllowListBucket",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::cebroker-sftp-raw-prod-backup"
        }
    ]
}
```

5. Click **Next**
6. **Policy name:** `s3-sftp-mirror-write`
7. Click **Create policy**

> **Nota:** `s3:DeleteObject` es necesario para el mirror delete de archivos huerfanos despues del periodo de gracia. Si se prefiere modo append-only, eliminar esta accion y poner `$EnableMirrorDelete = $false` en el script.

### 1.3 Asignar el Role a la instancia EC2

1. Ir a **EC2 > Instances**
2. Seleccionar `i-0947a572049fe5f8b`
3. **Actions > Security > Modify IAM role**
4. Seleccionar `ceb-sftp-s3-sync-role`
5. Click **Update IAM role**

---

## Paso 2: Instalar AWS PowerShell en la EC2

Conectarse a la instancia via RDP y abrir **PowerShell como Administrador**:

```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name AWSPowerShell -Force -AllowClobber
```

### Verificar conectividad

```powershell
Write-S3Object -BucketName "cebroker-sftp-raw-prod-backup" -Key "test/connection-test.txt" -Content "test" -Region "us-east-1"
```

Si no da error, el role tiene acceso al bucket correctamente.

---

## Paso 3: Crear estructura de carpetas

La estructura `C:\CEB_FTP_Data\SFTP\` ya existe en esta instancia. Crear las carpetas adicionales para scripts y logs:

```powershell
New-Item -Path "C:\CEB_FTP_Data\Scripts" -ItemType Directory -Force
New-Item -Path "C:\CEB_FTP_Data\Logs" -ItemType Directory -Force
```

### Estructura esperada en C:\CEB_FTP_Data\

```
C:\CEB_FTP_Data\
├── Logs\
│   ├── sync.log
│   ├── Sync-BoardFilesToS3.lock                  (lock local del script)
│   ├── Sync-S3-Mirror.global.lock                (lock global compartido)
│   ├── .sync_state_boardfiles.json               (estado FULL/DELTA)
│   └── .sync_orphans_boardfiles.json             (tracking de huerfanos)
├── Scripts\
│   └── Sync-BoardFilesToS3.ps1
└── SFTP\
    ├── Boards\
    │   └── Board_183\
    ├── CEB_SFTP_TESTER\
    ├── CEBroker\
    ├── dagster_user\
    ├── Employers\
    ├── LicenseVerification\
    ├── OtherUsers\
    ├── Prehire\
    ├── Providers\
    ├── sre_synthetic\
    └── States\
```

---

## Paso 4: Crear el script de sincronizacion

El script tambien vive en este repo en [scripts/sftp-standalone/Sync-BoardFilesToS3.ps1](https://github.com/dacruzt/dagster-poc/blob/main/scripts/sftp-standalone/Sync-BoardFilesToS3.ps1). Para crearlo directamente en la EC2, en PowerShell como Administrador, ejecutar:

```powershell
Set-Content -Path "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1" -Value @'
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

param(
    [switch]$DryRunDelete  # Validate orphan deletes without actually removing from S3
)

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

    if ($null -ne $existingGlobalPid -and $existingGlobalPid -eq $PID) {
        Write-Host "[WARN] Global lock belongs to current PowerShell session (PID: $existingGlobalPid). Treating as stale and continuing..."
        Remove-Item $GlobalLockFile -Force -ErrorAction SilentlyContinue
        $globalLockAcquired = $true
        break
    }

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
$BucketName = "cebroker-sftp-raw-prod-backup"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-03-20"
$StateFile = "C:\CEB_FTP_Data\Logs\.sync_state_boardfiles.json"
$DeltaLookbackMinutes = 20
$FullReconcileIntervalMinutes = 60
$EnableMirrorDelete = $true       # Delete S3 objects that no longer exist on SFTP (only during full scans)
$DeleteOrphanAfterDays = 7        # Grace period: only delete after orphan is absent this many days
$OrphanStateFile = "C:\CEB_FTP_Data\Logs\.sync_orphans_boardfiles.json"

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
$totalWouldDelete = 0

$localKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

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
    $allLocalFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue

    foreach ($localFile in $allLocalFiles) {
        $localRelativePath = $localFile.FullName.Substring($BasePath.Length).TrimStart('\\') -replace '\\', '/'
        [void]$localKeys.Add($localRelativePath)
    }

    $allFiles = $allLocalFiles |
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

    if ($EnableMirrorDelete) {
        Write-SyncLog "Mirror mode: checking for S3 orphans (grace period: $DeleteOrphanAfterDays days)..."
        $orphanState = Get-OrphanState
        $updatedOrphanState = @{}

        foreach ($orphanKey in $s3Objects.Keys) {
            if ($localKeys.Contains($orphanKey)) { continue }

            if ($orphanState.ContainsKey($orphanKey)) {
                try {
                    $firstSeen = ([DateTimeOffset]::Parse([string]$orphanState[$orphanKey])).UtcDateTime
                } catch {
                    $firstSeen = $nowUtc
                }
                $ageDays = ($nowUtc - $firstSeen).TotalDays

                if ($ageDays -ge $DeleteOrphanAfterDays) {
                    try {
                        $orphanLocalPath = Join-Path $BasePath ($orphanKey -replace '/', '\\')
                        if (Test-Path $orphanLocalPath) {
                            Write-SyncLog "SKIP delete for '$orphanKey': key exists on disk at '$orphanLocalPath'" -Level "WARN"
                            $updatedOrphanState[$orphanKey] = $orphanState[$orphanKey]
                            continue
                        }

                        if ($DryRunDelete) {
                            Write-SyncLog "DRY-RUN delete candidate (absent $([math]::Round($ageDays,1)) days): $orphanKey" -Level "WARN"
                            $updatedOrphanState[$orphanKey] = $orphanState[$orphanKey]
                            $totalWouldDelete++
                            continue
                        }

                        Remove-S3Object -BucketName $BucketName -Key $orphanKey -Region $AwsRegion -Force -ErrorAction Stop
                        Write-SyncLog "DELETED orphan from S3 (absent $([math]::Round($ageDays,1)) days): $orphanKey"
                        $totalDeleted++
                    } catch {
                        Write-SyncLog "ERROR deleting S3 orphan '$orphanKey': $($_.Exception.Message)" -Level "ERROR"
                        $totalErrors++
                        $updatedOrphanState[$orphanKey] = $orphanState[$orphanKey]
                    }
                } else {
                    Write-SyncLog "[$orphanKey] Orphan pending delete ($([math]::Round($ageDays,1))/$DeleteOrphanAfterDays days elapsed)"
                    $updatedOrphanState[$orphanKey] = $orphanState[$orphanKey]
                }
            } else {
                Write-SyncLog "[$orphanKey] New orphan detected -- grace period started (will delete after $DeleteOrphanAfterDays days)"
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
if ($DryRunDelete) {
    Write-SyncLog "  - Dry-run delete candidates: $totalWouldDelete"
}
Write-SyncLog "=========================================="

Write-SyncLog "Script finished"

} catch {
    Write-SyncLog "ERROR: Script failed with exception: $($_.Exception.Message)" -Level "ERROR"
    throw $_
} finally {
    if (Test-Path $GlobalLockFile) {
        Remove-Item $GlobalLockFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        Write-SyncLog "Lock file cleaned up"
    }
}
'@ -Encoding UTF8
```

### Configuracion del script

| Variable | Valor por defecto | Descripcion |
|----------|-------------------|-------------|
| `$BasePath` | `C:\CEB_FTP_Data\SFTP` | Carpeta raiz que se escanea |
| `$BucketName` | `cebroker-sftp-raw-prod-backup` | Bucket S3 destino |
| `$AwsRegion` | `us-east-1` | Region AWS |
| `$SyncAfterDate` | `2026-03-20` | Solo sincroniza archivos modificados/creados desde esta fecha |
| `$DeltaLookbackMinutes` | `20` | Ventana extra hacia atras en cada DELTA scan |
| `$FullReconcileIntervalMinutes` | `60` | Cada cuanto hacer un FULL scan |
| `$EnableMirrorDelete` | `$true` | Borrar de S3 huerfanos (no presentes en SFTP) |
| `$DeleteOrphanAfterDays` | `7` | Periodo de gracia antes de borrar huerfanos |

### Parametros

- `-DryRunDelete` — valida candidatos a borrado sin eliminar de S3 (loguea como `DRY-RUN delete candidate`).

### Que hace el script

1. **Locks**: Adquiere un lock local (`Sync-BoardFilesToS3.lock`) y un lock global compartido (`Sync-S3-Mirror.global.lock`) para evitar ejecuciones concurrentes con otros scripts hermanos. Si el lock global esta tomado, reintenta hasta 15 veces cada 2 minutos (~30 min max).
2. **Indexa S3** una sola vez con `Get-S3Object` para lookups rapidos (key + size).
3. **Modo mixto FULL/DELTA**:

   - **DELTA** (corridas frecuentes): solo archivos con `LastWriteTimeUtc` desde la ultima ventana (con lookback de 20 min).
   - **FULL** (cada 60 min): escanea TODOS los archivos del SFTP, calcula `localKeys` completo y habilita mirror delete.

4. **Sube a S3** preservando ruta y nombre original (`Boards/Board_183/archivo.csv`). Adjunta metadata `source-last-write-time-utc` y `source-creation-time-utc`.
5. **Skip si S3 ya esta al dia**: si key + size + metadata coinciden, no resube.
6. **Verifica** que el archivo no este bloqueado ni en transferencia (tamano estable por 3s).
7. **Mirror delete con gracia**: si un objeto en S3 ya no esta en SFTP, lo registra en `.sync_orphans_boardfiles.json` con timestamp. Solo lo borra de S3 si lleva `>= 7 dias` ausente. Antes del delete final, valida una vez mas que el archivo no exista en disco.
8. **Logging triple**: archivo (`sync.log`), consola con colores y Windows Event Log (source `BoardFileSync`, log `Application`).
9. **Cleanup garantizado**: bloque `finally` libera los lock files aunque haya excepciones.
10. **Aborta** si recibe `Access Denied` por `s3:PutObject` (evita repetir errores).

---

## Paso 5: Crear tarea programada (cada 5 minutos)

**Importante:** El script usa modo mixto:

- **DELTA** en corridas frecuentes (cada 5 min)
- **FULL** cada 60 min para reconciliacion completa del mirror

Esto permite mantener la tarea cada 5 minutos sin sobrecargar cada ejecucion.

En PowerShell como Administrador:

```powershell
$taskName   = "BoardFiles-S3-Sync"
$scriptPath = "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"
$workDir    = "C:\CEB_FTP_Data\Scripts"

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
    -WorkingDirectory $workDir

$trigger = New-ScheduledTaskTrigger `
    -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 14) `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Sincroniza archivos de SFTP a S3 cada 5 minutos (mirror)"
```

Resultado esperado:
```
TaskPath   TaskName            State
--------   --------            -----
\          BoardFiles-S3-Sync  Ready
```

---

## Paso 6: Verificacion

### Ejecutar el script manualmente

```powershell
& "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"
```

### Probar mirror delete sin borrar nada

```powershell
& "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1" -DryRunDelete
```

Buscar en el log lineas `DRY-RUN delete candidate (absent X.X days): <key>`.

### Revisar logs

```powershell
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Tail 30
```

### Validar modo DELTA/FULL

En `sync.log` deberias ver alternar:

- `SFTP DELTA scan mode since UTC ...` en corridas normales
- `SFTP FULL scan mode` aproximadamente cada 60 minutos
- En FULL: `Mirror mode: checking for S3 orphans (grace period: 7 days)...`

### Verificar la tarea programada

```powershell
Get-ScheduledTask -TaskName "BoardFiles-S3-Sync" | Format-List TaskName, State, Description
```

### Ver archivos en S3 (desde la EC2)

```powershell
Get-S3Object -BucketName "cebroker-sftp-raw-prod-backup" -KeyPrefix "Boards/" -Region "us-east-1" |
    Select-Object Key, Size, LastModified
```

### Ver Event Log

```powershell
Get-EventLog -LogName Application -Source "BoardFileSync" -Newest 20 |
    Format-Table TimeGenerated, EntryType, Message -AutoSize
```

---

## Troubleshooting

| Problema | Solucion |
|----------|----------|
| `Access Denied` en Write-S3Object | Verificar IAM Role asignado a la EC2 y la inline policy |
| `Access Denied` en Remove-S3Object | Verificar que `s3:DeleteObject` este en el role, o desactivar `$EnableMirrorDelete` |
| `Write-S3Object is not recognized` | Instalar AWS PowerShell: `Install-Module -Name AWSPowerShell -Force` |
| No aparecen archivos nuevos | Verificar `$SyncAfterDate` - archivos antes de esa fecha son ignorados |
| Script no se ejecuta automaticamente | Verificar tarea: `Get-ScheduledTask -TaskName "BoardFiles-S3-Sync"` |
| Necesita instalar como Admin | Abrir PowerShell con click derecho > Run as Administrator |
| `Another instance is already running (PID: XXXX)` | Una instancia real esta corriendo. Esperar que termine o matar: `Stop-Process -Id XXXX -Force` |
| `Could not acquire global lock after 15 retries` | Otro script hermano esta corriendo > 30 min. Revisar `Sync-S3-Mirror.global.lock` |
| `Orphan lock file detected` | El proceso anterior termino inesperadamente. El script lo detecta y continua automaticamente |
| Lock file permanece despues de ejecucion | Eliminar manualmente: `Remove-Item C:\CEB_FTP_Data\Logs\Sync-BoardFilesToS3.lock -Force` |
| Huerfano no se borra | Revisar `.sync_orphans_boardfiles.json` y la fecha de `first-seen`. Solo borra despues de 7 dias |
| Quiero forzar un FULL scan | Borrar `C:\CEB_FTP_Data\Logs\.sync_state_boardfiles.json` |

### Verificar estado del lock

```powershell
foreach ($lock in @(
    "C:\CEB_FTP_Data\Logs\Sync-BoardFilesToS3.lock",
    "C:\CEB_FTP_Data\Logs\Sync-S3-Mirror.global.lock"
)) {
    if (Test-Path $lock) {
        Write-Host "=== $lock ==="
        Get-Content $lock
    } else {
        Write-Host "Sin lock: $lock"
    }
}
```

### Inspeccionar huerfanos pendientes de borrar

```powershell
Get-Content "C:\CEB_FTP_Data\Logs\.sync_orphans_boardfiles.json" | ConvertFrom-Json
```

### Ver logs en tiempo real

```powershell
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Wait -Tail 10
```

### Detener la tarea programada

```powershell
Stop-ScheduledTask -TaskName "BoardFiles-S3-Sync"
```

### Eliminar la tarea programada

```powershell
Unregister-ScheduledTask -TaskName "BoardFiles-S3-Sync" -Confirm:$false
```

---

## Fecha de implementacion

- **Fecha inicial:** 2026-03-03
- **Última actualización:** 2026-05-05
- **Implementado por:** Diego Cruz
- **Estado:** Funcionando correctamente (modo mirror)

### Cambios 2026-05-05

- Bucket destino: `cebroker-sftp-raw-prod-backup` (same-account, no cross-account)
- **Mirror real**: la S3 key ahora preserva la ruta y nombre original (sin prefijo timestamp)
- Archivos ya **no** se mueven a `processed/` despues de subir
- **Skip dedup por metadata**: si key + size + metadata `source-last-write-time-utc`/`source-creation-time-utc` coinciden, no resube
- **Mirror delete con gracia**: huerfanos se trackean en `.sync_orphans_boardfiles.json` y se borran tras `$DeleteOrphanAfterDays` (7) dias
- Parametro `-DryRunDelete` para validar borrados sin eliminar
- **Lock global compartido** (`Sync-S3-Mirror.global.lock`) con retry (15 × 2 min) para serializar con scripts hermanos
- Logging adicional a Windows Event Log (source `BoardFileSync`)
- Bloque `try/finally` garantiza liberar locks ante excepciones
- `s3:DeleteObject` agregado al role

### Cambios 2026-03-19

- Lock file movido de `$PSScriptRoot\*.lock` a `C:\CEB_FTP_Data\Logs\*.lock` (ruta hardcodeada para compatibilidad con Task Scheduler)
- Lock ahora guarda PID y fecha de inicio en lugar de ser un archivo vacío
- Validación de lock verifica si el PID sigue activo antes de bloquear
- Locks huérfanos (proceso ya no existe) se limpian automáticamente
- Configuración `MultipleInstances IgnoreNew` agregada para prevenir solapamiento
- `ExecutionTimeLimit` de 14 minutos agregado como failsafe
- Modo mixto FULL+DELTA implementado para mantener baja latencia y mirror completo
- Archivo de estado `.sync_state_boardfiles.json` para recordar ventanas de escaneo
- Correccion de parse UTC del estado para evitar FULL en cada corrida
- Métricas de duración agregadas al log por fase y total
