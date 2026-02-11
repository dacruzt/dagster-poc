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
# 1. Crea la estructura de carpetas
# 2. Copia el script de sync
# 3. Crea la tarea programada (si no existe)
read -r -d '' PS_COMMAND << 'POWERSHELL_EOF' || true
$ErrorActionPreference = "Stop"

# --- Crear estructura de carpetas ---
$folders = @(
    "C:\SFTP\BoardFiles\Landing",
    "C:\SFTP\BoardFiles\Archive",
    "C:\SFTP\Scripts",
    "C:\SFTP\Logs"
)
foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-Output "Carpeta creada: $folder"
    } else {
        Write-Output "Carpeta ya existe: $folder"
    }
}

# --- Instalar AWS PowerShell si no esta disponible ---
if (-not (Get-Module -ListAvailable -Name AWSPowerShell)) {
    Write-Output "Instalando modulo AWSPowerShell..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module -Name AWSPowerShell -Force -AllowClobber
    Write-Output "AWSPowerShell instalado"
} else {
    Write-Output "AWSPowerShell ya esta instalado"
}

# --- Crear script de sincronizacion ---
$syncScript = @'
# =============================================================================
# Sync-BoardFilesToS3.ps1 - CE Broker Board Files Sync Script
# =============================================================================

$ErrorActionPreference = "Continue"
$LandingPath = "C:\SFTP\BoardFiles\Landing"
$ArchivePath = "C:\SFTP\BoardFiles\Archive"
$LogPath = "C:\SFTP\Logs\sync.log"
$BucketName = "data-do-ent-file-ingestion-test-landing"
$S3Prefix = ""
$AwsRegion = "us-east-1"

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
Write-SyncLog "Iniciando sincronizacion de archivos..."
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

if (-not (Test-Path $LandingPath)) {
    Write-SyncLog "ERROR: Carpeta Landing no existe: $LandingPath" -Level "ERROR"
    exit 1
}

if (-not (Test-Path $ArchivePath)) {
    New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
}

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
    Write-SyncLog "Procesando: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

    if (-not (Test-FileNotLocked -FilePath $filePath)) {
        Write-SyncLog "Archivo bloqueado, omitiendo: $fileName" -Level "WARN"
        $skippedCount++
        continue
    }

    if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
        Write-SyncLog "Archivo en transferencia, omitiendo: $fileName" -Level "WARN"
        $skippedCount++
        continue
    }

    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        if ([string]::IsNullOrEmpty($S3Prefix)) {
            $s3Key = "${timestamp}_$fileName"
        } else {
            $s3Key = "$S3Prefix/${timestamp}_$fileName"
        }

        Write-SyncLog "Subiendo a s3://$BucketName/$s3Key"
        Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion
        Write-SyncLog "Archivo subido exitosamente a S3"

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
Write-SyncLog "  Exitosos: $successCount | Errores: $errorCount | Omitidos: $skippedCount"
Write-SyncLog "=========================================="

# Limpieza de archivos antiguos (mas de 30 dias)
$cutoffDate = (Get-Date).AddDays(-30)
$oldFiles = Get-ChildItem -Path $ArchivePath -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }
if ($oldFiles.Count -gt 0) {
    Write-SyncLog "Limpiando $($oldFiles.Count) archivos antiguos del Archive..."
    $oldFiles | ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-SyncLog "Eliminado: $($_.Name)"
    }
}

Write-SyncLog "Script finalizado"
'@

Set-Content -Path "C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1" -Value $syncScript -Force
Write-Output "Script de sync creado en C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"

# --- Crear tarea programada (cada 5 minutos) ---
$taskName = "BoardFiles-S3-Sync"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask) {
    Write-Output "Tarea programada '$taskName' ya existe - actualizando..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"
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
    -Description "Sincroniza archivos de Board Files a S3 cada 5 minutos" `
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
Write-Output " - Script:  C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"
Write-Output " - Tarea:   $taskName (cada 5 min)"
Write-Output " - Landing: C:\SFTP\BoardFiles\Landing"
Write-Output " - Archive: C:\SFTP\BoardFiles\Archive"
Write-Output " - Logs:    C:\SFTP\Logs\sync.log"
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
