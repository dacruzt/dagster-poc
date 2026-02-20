# =============================================================================
# Sync-LegacySFTP-ToS3.ps1
# =============================================================================
# Script para el servidor legacy-sftp-02
# Ruta: C:\CEB_FTP_Data\SFTP\
#   ├── Boards\Board_*\   -> s3://BUCKET/Boards/Board_*/timestamp_file.csv
#   └── Providers\         -> s3://BUCKET/Providers/timestamp_file.csv
#
# - Escanea recursivamente Boards/ y Providers/ buscando archivos nuevos
# - Sube a S3 preservando la ruta relativa completa
# - Mueve el archivo a processed/ en su misma carpeta
# - Ignora cualquier carpeta llamada "processed"
# - Limpia archivos en processed/ con mas de 30 dias
# =============================================================================

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# CONFIGURACION  <-- CAMBIAR AQUI
# -----------------------------------------------------------------------------
$BasePath       = "C:\CEB_FTP_Data\SFTP"
$LogPath        = "C:\CEB_FTP_Data\Logs\sync.log"
$BucketName     = "CAMBIAR-NOMBRE-DEL-BUCKET"          # <-- CAMBIAR al bucket destino
$AwsRegion      = "us-east-1"
$SyncAfterDate  = [DateTime]"2026-02-19"                # Ignorar archivos anteriores a esta fecha

# -----------------------------------------------------------------------------
# FUNCIONES
# -----------------------------------------------------------------------------

function Write-SyncLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $logMessage -Force

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

# -----------------------------------------------------------------------------
# PROCESO PRINCIPAL - Escaneo recursivo
# -----------------------------------------------------------------------------

Write-SyncLog "=========================================="
Write-SyncLog "Iniciando sincronizacion recursiva..."
Write-SyncLog "Base: $BasePath"
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0

# Buscar TODOS los archivos recursivamente, excluyendo carpetas "processed"
$allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CreationTime -ge $SyncAfterDate -and
        $_.DirectoryName -notmatch '\\processed(\\|$)'
    }

if ($allFiles.Count -eq 0) {
    Write-SyncLog "No hay archivos nuevos para sincronizar"
} else {
    Write-SyncLog "Encontrados $($allFiles.Count) archivos nuevos (desde $SyncAfterDate)"

    foreach ($file in $allFiles) {
        $filePath = $file.FullName
        $fileName = $file.Name
        $fileDir = $file.DirectoryName

        # Calcular ruta relativa desde BasePath para el S3 key
        $relativePath = $fileDir.Substring($BasePath.Length).TrimStart('\') -replace '\\', '/'
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $s3Key = "$relativePath/${timestamp}_$fileName"

        Write-SyncLog "[$relativePath] Procesando: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$relativePath] Archivo bloqueado, omitiendo: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$relativePath] Archivo en transferencia, omitiendo: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        try {
            Write-SyncLog "[$relativePath] Subiendo a s3://$BucketName/$s3Key"
            Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion

            # Mover a processed/ en la misma carpeta
            $processedPath = Join-Path $fileDir "processed"
            if (-not (Test-Path $processedPath)) {
                New-Item -ItemType Directory -Path $processedPath -Force | Out-Null
            }
            Move-Item -Path $filePath -Destination (Join-Path $processedPath $fileName) -Force

            Write-SyncLog "[$relativePath] OK: $fileName -> $s3Key"
            $totalSuccess++
        } catch {
            Write-SyncLog "[$relativePath] ERROR: $fileName - $($_.Exception.Message)" -Level "ERROR"
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
# LIMPIEZA: Eliminar archivos en processed/ con mas de 30 dias
# -----------------------------------------------------------------------------
$cutoffDate = (Get-Date).AddDays(-30)
$oldFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DirectoryName -match '\\processed(\\|$)' -and
        $_.LastWriteTime -lt $cutoffDate
    }

if ($oldFiles.Count -gt 0) {
    Write-SyncLog "Limpiando $($oldFiles.Count) archivos antiguos de processed/..."
    foreach ($old in $oldFiles) {
        Remove-Item $old.FullName -Force
        Write-SyncLog "Eliminado: $($old.FullName.Substring($BasePath.Length))"
    }
}

Write-SyncLog "Script finalizado"
