#!/bin/bash
# =============================================================================
# deploy-sync-script.sh
# Despliega el script Sync-BoardFilesToS3.ps1 en la instancia EC2 via SSM
# =============================================================================
# Uso:
#   ./deploy-sync-script.sh                          # auto-detecta instance ID desde Pulumi
#   ./deploy-sync-script.sh i-0abc123def456789       # con instance ID explícito
#   INSTANCE_ID=i-0abc123 ./deploy-sync-script.sh    # via variable de entorno
# =============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

# Resolver Instance ID
if [[ -n "${1:-}" ]]; then
  INSTANCE_ID="$1"
elif [[ -n "${INSTANCE_ID:-}" ]]; then
  INSTANCE_ID="$INSTANCE_ID"
else
  echo "Buscando Instance ID desde Pulumi outputs..."
  INSTANCE_ID=$(cd "$(dirname "$0")/../../infra" && pulumi stack output sftpServerInstanceId 2>/dev/null) || true

  if [[ -z "$INSTANCE_ID" ]]; then
    echo "ERROR: No se pudo obtener el Instance ID."
    echo "Uso: $0 <instance-id>"
    echo "  o: INSTANCE_ID=i-xxx $0"
    exit 1
  fi
fi

echo "============================================="
echo " Desplegando Sync Script en EC2"
echo " Instance ID: $INSTANCE_ID"
echo " Region:      $AWS_REGION"
echo "============================================="

# El script PowerShell que se ejecutará en la máquina remota:
# 1. Crea la estructura de carpetas (Boards + Providers)
# 2. Copia el script de sync
# 3. Crea la tarea programada (si no existe)
read -r -d '' PS_COMMAND << 'POWERSHELL_EOF' || true
$ErrorActionPreference = "Stop"

# --- Crear estructura de carpetas (replica exacta de legacy SFTP) ---
$baseFolders = @(
    "C:\CEB_FTP_Data\Scripts",
    "C:\CEB_FTP_Data\Logs",
    "C:\CEB_FTP_Data\SFTP\Providers\processed"
)

foreach ($folder in $baseFolders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-Output "Carpeta creada: $folder"
    } else {
        Write-Output "Carpeta ya existe: $folder"
    }
}

# Board_* subfolders (replica de legacy-sftp-02)
$boardFolders = @(
    "Board_NDSBOTP", "Board_NDSWE", "Board_NHMS", "Board_NHOPLC",
    "Board_NMM", "Board_NMMMedical", "Board_NMN", "Board_NMRealEstate",
    "Board_NVBOM", "Board_NVPT", "Board_OBMLS", "Board_OKBCE",
    "Board_OKDENT", "Board_OKREC", "Board_OSBOE", "Board_SCAG",
    "Board_SCRQSA", "Board_SDBMT", "Board_TFSC", "Board_TMB",
    "Board_TNDCI", "Board_TSBPE", "Board_TXBHEC", "Board_TXOPT",
    "Board_VADental", "Board_VAPT"
)

foreach ($board in $boardFolders) {
    $path = "C:\CEB_FTP_Data\SFTP\Boards\$board\processed"
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}
Write-Output "Creados $($boardFolders.Count) Board_* subfolders + Providers"

# --- Instalar AWS PowerShell si no esta disponible ---
if (-not (Get-Module -ListAvailable -Name AWSPowerShell)) {
    Write-Output "Instalando modulo AWSPowerShell..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module -Name AWSPowerShell -Force -AllowClobber
    Write-Output "AWSPowerShell instalado"
} else {
    Write-Output "AWSPowerShell ya esta instalado"
}

# --- Crear script de sincronizacion (escaneo recursivo) ---
$syncScript = @'
# =============================================================================
# Sync-BoardFilesToS3.ps1 - Recursive SFTP Sync Script
# =============================================================================
# Escanea recursivamente toda la estructura bajo BoardFiles/ y sube archivos
# nuevos a S3 preservando la ruta completa.
# Ejemplo: Boards/Board_NDSBOTP/subfolder/file.csv
#       -> s3://bucket/Boards/Board_NDSBOTP/subfolder/20260219_file.csv
# Despues de subir, mueve el archivo a processed/ en su misma carpeta.
# Ignora cualquier carpeta llamada "processed".
# =============================================================================

$ErrorActionPreference = "Continue"

$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync.log"
$BucketName = "data-do-ent-file-ingestion-test-landing"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-02-19"

function Write-SyncLog {
    param([string]$Message, [string]$Level = "INFO")
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

# Limpieza: Eliminar archivos en processed/ con mas de 30 dias
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
'@

Set-Content -Path "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1" -Value $syncScript -Force
Write-Output "Script de sync creado en C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"

# --- Crear tarea programada (cada 5 minutos) ---
$taskName = "BoardFiles-S3-Sync"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask) {
    Write-Output "Tarea programada '$taskName' ya existe - actualizando..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 9999)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Sincroniza archivos de todos los folders a S3 cada 5 minutos" `
    -Force

Write-Output "Tarea programada '$taskName' creada (cada 5 minutos)"

# --- Registrar Event Source ---
if (-not [System.Diagnostics.EventLog]::SourceExists("BoardFileSync")) {
    New-EventLog -LogName Application -Source "BoardFileSync"
    Write-Output "Event source 'BoardFileSync' registrado"
}

Write-Output ""
Write-Output "============================================="
Write-Output " Despliegue completado!"
Write-Output " - Script:  C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"
Write-Output " - Tarea:   $taskName (cada 5 min)"
Write-Output " - Boards: C:\CEB_FTP_Data\SFTP\Boards\Board_*"
Write-Output " - Providers: C:\CEB_FTP_Data\SFTP\Providers"
Write-Output " - Processed: {folder}\processed\"
Write-Output " - Logs:    C:\CEB_FTP_Data\Logs\sync.log"
Write-Output "============================================="
POWERSHELL_EOF

echo ""
echo "Enviando comando via SSM..."
echo ""

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunPowerShellScript" \
  --parameters "commands=[$(echo "$PS_COMMAND" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')]" \
  --timeout-seconds 300 \
  --region "$AWS_REGION" \
  --output text \
  --query "Command.CommandId")

echo "Comando enviado. Command ID: $COMMAND_ID"
echo "Esperando resultado..."
echo ""

# Esperar a que termine
aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" 2>/dev/null || true

# Obtener output
OUTPUT=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --output json 2>/dev/null)

STATUS=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Status'])")
STDOUT=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['StandardOutputContent'])")
STDERR=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('StandardErrorContent',''))")

if [[ "$STATUS" == "Success" ]]; then
  echo "SUCCESS - Script desplegado correctamente"
  echo ""
  echo "$STDOUT"
else
  echo "ERROR - Status: $STATUS"
  echo ""
  echo "STDOUT:"
  echo "$STDOUT"
  echo ""
  echo "STDERR:"
  echo "$STDERR"
  exit 1
fi
