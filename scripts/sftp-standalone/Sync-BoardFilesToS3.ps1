# =============================================================================
# Sync-BoardFilesToS3.ps1 - CE Broker Board Files Sync Script
# =============================================================================
# Este script sincroniza archivos desde la carpeta Landing hacia S3
# y los mueve a Archive después de subirlos exitosamente.
# =============================================================================

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# CONFIGURACION - Modificar según el ambiente
# -----------------------------------------------------------------------------
$LandingPath = "C:\SFTP\BoardFiles\Landing"
$ArchivePath = "C:\SFTP\BoardFiles\Archive"
$LogPath = "C:\SFTP\Logs\sync.log"
$BucketName = "data-do-ent-file-ingestion-test-landing"
$S3Prefix = ""
$AwsRegion = "us-east-1"

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

    # También escribir al Event Log de Windows
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
Write-SyncLog "Iniciando sincronizacion de archivos..."
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "Prefix: $S3Prefix"
Write-SyncLog "=========================================="

# Verificar que las carpetas existen
if (-not (Test-Path $LandingPath)) {
    Write-SyncLog "ERROR: Carpeta Landing no existe: $LandingPath" -Level "ERROR"
    exit 1
}

if (-not (Test-Path $ArchivePath)) {
    Write-SyncLog "Creando carpeta Archive: $ArchivePath"
    New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
}

# Obtener lista de archivos
$files = Get-ChildItem -Path $LandingPath -File -ErrorAction SilentlyContinue

if ($files.Count -eq 0) {
    Write-SyncLog "No hay archivos nuevos para procesar"
    exit 0
}

Write-SyncLog "Encontrados $($files.Count) archivos para procesar"

$successCount = 0
$errorCount = 0
$skippedCount = 0

foreach ($file in $files) {
    $filePath = $file.FullName
    $fileName = $file.Name

    Write-SyncLog "----------------------------------------"
    Write-SyncLog "Procesando: $fileName"
    Write-SyncLog "Tamano: $([math]::Round($file.Length / 1MB, 2)) MB"

    # Verificar que el archivo no está bloqueado
    if (-not (Test-FileNotLocked -FilePath $filePath)) {
        Write-SyncLog "Archivo bloqueado (en uso), omitiendo: $fileName" -Level "WARN"
        $skippedCount++
        continue
    }

    # Verificar que el archivo no está siendo transferido
    if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
        Write-SyncLog "Archivo aun en transferencia (tamano cambiando), omitiendo: $fileName" -Level "WARN"
        $skippedCount++
        continue
    }

    try {
        # Construir la key de S3 con timestamp
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        if ([string]::IsNullOrEmpty($S3Prefix)) {
            $s3Key = "${timestamp}_$fileName"
        } else {
            $s3Key = "$S3Prefix/${timestamp}_$fileName"
        }

        Write-SyncLog "Subiendo a s3://$BucketName/$s3Key"

        # Subir a S3
        Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion

        Write-SyncLog "Archivo subido exitosamente a S3"

        # Mover a Archive
        $archiveFileName = "${timestamp}_$fileName"
        $archiveDest = Join-Path $ArchivePath $archiveFileName
        Move-Item -Path $filePath -Destination $archiveDest -Force

        Write-SyncLog "Archivo movido a Archive: $archiveFileName"
        $successCount++

    } catch {
        Write-SyncLog "ERROR procesando $fileName : $($_.Exception.Message)" -Level "ERROR"
        $errorCount++
    }
}

Write-SyncLog "=========================================="
Write-SyncLog "Sincronizacion completada"
Write-SyncLog "  - Exitosos: $successCount"
Write-SyncLog "  - Errores: $errorCount"
Write-SyncLog "  - Omitidos: $skippedCount"
Write-SyncLog "=========================================="

# -----------------------------------------------------------------------------
# LIMPIEZA DE ARCHIVOS ANTIGUOS (mas de 30 dias)
# -----------------------------------------------------------------------------
$cutoffDate = (Get-Date).AddDays(-30)
$oldFiles = Get-ChildItem -Path $ArchivePath -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }

if ($oldFiles.Count -gt 0) {
    Write-SyncLog "Limpiando $($oldFiles.Count) archivos antiguos del Archive..."
    foreach ($oldFile in $oldFiles) {
        Write-SyncLog "Eliminando archivo antiguo: $($oldFile.Name)"
        Remove-Item $oldFile.FullName -Force
    }
}

Write-SyncLog "Script finalizado"
