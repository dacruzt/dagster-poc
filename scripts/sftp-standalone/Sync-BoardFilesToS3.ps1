# =============================================================================
# Sync-BoardFilesToS3.ps1 - Multi-Folder Board Files Sync Script
# =============================================================================
# Este script sincroniza archivos desde subfolders de Landing hacia S3,
# manteniendo la misma estructura de folders en el bucket.
# Cada subfolder (board-files, nursing-files, pharmacy) se sube al mismo
# prefijo en S3.
# =============================================================================

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# CONFIGURACION - Modificar segun el ambiente
# -----------------------------------------------------------------------------
$BaseLandingPath = "C:\SFTP\BoardFiles\Landing"
$BaseArchivePath = "C:\SFTP\BoardFiles\Archive"
$LogPath = "C:\SFTP\Logs\sync.log"
$BucketName = "data-do-ent-file-ingestion-test-landing"
$AwsRegion = "us-east-1"
$DatasetFolders = @("board-files", "nursing-files", "pharmacy")

# -----------------------------------------------------------------------------
# FUNCIONES
# -----------------------------------------------------------------------------

function Write-SyncLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    # Escribir al archivo de log
    Add-Content -Path $LogPath -Value $logMessage -Force

    # Tambien escribir al Event Log de Windows
    $source = "BoardFileSync"
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        try {
            New-EventLog -LogName Application -Source $source -ErrorAction SilentlyContinue
        } catch {
            # Ignorar si no se puede crear
        }
    }

    $eventType = switch ($Level) {
        "ERROR" { "Error" }
        "WARN"  { "Warning" }
        default { "Information" }
    }

    try {
        Write-EventLog -LogName Application -Source $source -EventId 1000 -EntryType $eventType -Message $Message -ErrorAction SilentlyContinue
    } catch {
        # Ignorar errores de Event Log
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
        [int]$WaitSeconds = 5
    )
    $size1 = (Get-Item $FilePath).Length
    Start-Sleep -Seconds $WaitSeconds
    $size2 = (Get-Item $FilePath).Length
    return $size1 -eq $size2
}

# -----------------------------------------------------------------------------
# PROCESO PRINCIPAL
# -----------------------------------------------------------------------------

Write-SyncLog "=========================================="
Write-SyncLog "Iniciando sincronizacion multi-folder..."
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "Folders: $($DatasetFolders -join ', ')"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0

foreach ($datasetFolder in $DatasetFolders) {
    $landingPath = Join-Path $BaseLandingPath $datasetFolder
    $archivePath = Join-Path $BaseArchivePath $datasetFolder

    # Crear carpetas si no existen
    if (-not (Test-Path $landingPath)) {
        New-Item -ItemType Directory -Path $landingPath -Force | Out-Null
        Write-SyncLog "Carpeta Landing creada: $landingPath"
    }
    if (-not (Test-Path $archivePath)) {
        New-Item -ItemType Directory -Path $archivePath -Force | Out-Null
        Write-SyncLog "Carpeta Archive creada: $archivePath"
    }

    # Obtener lista de archivos
    $files = Get-ChildItem -Path $landingPath -File -ErrorAction SilentlyContinue

    if ($files.Count -eq 0) {
        continue
    }

    Write-SyncLog "[$datasetFolder] Encontrados $($files.Count) archivos para procesar"

    foreach ($file in $files) {
        $filePath = $file.FullName
        $fileName = $file.Name

        Write-SyncLog "[$datasetFolder] Procesando: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        # Verificar que el archivo no esta bloqueado
        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$datasetFolder] Archivo bloqueado, omitiendo: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        # Verificar que el archivo no esta siendo transferido
        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$datasetFolder] Archivo en transferencia, omitiendo: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        try {
            # S3 key: {folder}/{timestamp}_{filename}
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $s3Key = "$datasetFolder/${timestamp}_$fileName"

            Write-SyncLog "[$datasetFolder] Subiendo a s3://$BucketName/$s3Key"

            # Subir a S3
            Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion

            Write-SyncLog "[$datasetFolder] Archivo subido exitosamente a S3"

            # Mover a Archive
            $archiveFileName = "${timestamp}_$fileName"
            $archiveDest = Join-Path $archivePath $archiveFileName
            Move-Item -Path $filePath -Destination $archiveDest -Force

            Write-SyncLog "[$datasetFolder] Archivo movido a Archive: $archiveFileName"
            $totalSuccess++

        } catch {
            Write-SyncLog "[$datasetFolder] ERROR procesando $fileName : $($_.Exception.Message)" -Level "ERROR"
            $totalErrors++
        }
    }
}

Write-SyncLog "=========================================="
Write-SyncLog "Sincronizacion completada"
Write-SyncLog "  - Exitosos: $totalSuccess"
Write-SyncLog "  - Errores: $totalErrors"
Write-SyncLog "  - Omitidos: $totalSkipped"
Write-SyncLog "=========================================="

# -----------------------------------------------------------------------------
# LIMPIEZA DE ARCHIVOS ANTIGUOS (mas de 30 dias) en todos los folders
# -----------------------------------------------------------------------------
$cutoffDate = (Get-Date).AddDays(-30)
foreach ($datasetFolder in $DatasetFolders) {
    $archivePath = Join-Path $BaseArchivePath $datasetFolder
    if (Test-Path $archivePath) {
        $oldFiles = Get-ChildItem -Path $archivePath -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($oldFiles.Count -gt 0) {
            Write-SyncLog "[$datasetFolder] Limpiando $($oldFiles.Count) archivos antiguos del Archive..."
            foreach ($oldFile in $oldFiles) {
                Write-SyncLog "[$datasetFolder] Eliminando: $($oldFile.Name)"
                Remove-Item $oldFile.FullName -Force
            }
        }
    }
}

Write-SyncLog "Script finalizado"
