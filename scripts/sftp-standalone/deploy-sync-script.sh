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
# 1. Crea la estructura de carpetas (multi-folder)
# 2. Copia el script de sync
# 3. Crea la tarea programada (si no existe)
read -r -d '' PS_COMMAND << 'POWERSHELL_EOF' || true
$ErrorActionPreference = "Stop"

# --- Crear estructura de carpetas (multi-folder) ---
$datasetFolders = @("board-files", "nursing-files", "pharmacy")
$baseFolders = @(
    "C:\SFTP\Scripts",
    "C:\SFTP\Logs"
)

foreach ($folder in $baseFolders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-Output "Carpeta creada: $folder"
    } else {
        Write-Output "Carpeta ya existe: $folder"
    }
}

foreach ($dataset in $datasetFolders) {
    $landing = "C:\SFTP\BoardFiles\Landing\$dataset"
    $archive = "C:\SFTP\BoardFiles\Archive\$dataset"
    foreach ($path in @($landing, $archive)) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-Output "Carpeta creada: $path"
        } else {
            Write-Output "Carpeta ya existe: $path"
        }
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

# --- Crear script de sincronizacion (multi-folder) ---
$syncScript = @'
# =============================================================================
# Sync-BoardFilesToS3.ps1 - Multi-Folder Board Files Sync Script
# =============================================================================

$ErrorActionPreference = "Continue"
$BaseLandingPath = "C:\SFTP\BoardFiles\Landing"
$BaseArchivePath = "C:\SFTP\BoardFiles\Archive"
$LogPath = "C:\SFTP\Logs\sync.log"
$BucketName = "data-do-ent-file-ingestion-test-landing"
$AwsRegion = "us-east-1"
$DatasetFolders = @("board-files", "nursing-files", "pharmacy")

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
Write-SyncLog "Iniciando sincronizacion multi-folder..."
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0

foreach ($datasetFolder in $DatasetFolders) {
    $landingPath = Join-Path $BaseLandingPath $datasetFolder
    $archivePath = Join-Path $BaseArchivePath $datasetFolder

    if (-not (Test-Path $landingPath)) {
        New-Item -ItemType Directory -Path $landingPath -Force | Out-Null
    }
    if (-not (Test-Path $archivePath)) {
        New-Item -ItemType Directory -Path $archivePath -Force | Out-Null
    }

    $files = Get-ChildItem -Path $landingPath -File -ErrorAction SilentlyContinue
    if ($files.Count -eq 0) { continue }

    Write-SyncLog "[$datasetFolder] Encontrados $($files.Count) archivos"

    foreach ($file in $files) {
        $filePath = $file.FullName
        $fileName = $file.Name
        Write-SyncLog "[$datasetFolder] Procesando: $fileName ($([math]::Round($file.Length / 1MB, 2)) MB)"

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$datasetFolder] Archivo bloqueado, omitiendo: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$datasetFolder] Archivo en transferencia, omitiendo: $fileName" -Level "WARN"
            $totalSkipped++
            continue
        }

        try {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $s3Key = "$datasetFolder/${timestamp}_$fileName"

            Write-SyncLog "[$datasetFolder] Subiendo a s3://$BucketName/$s3Key"
            Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion

            $archiveFileName = "${timestamp}_$fileName"
            $archiveDest = Join-Path $archivePath $archiveFileName
            Move-Item -Path $filePath -Destination $archiveDest -Force
            Write-SyncLog "[$datasetFolder] OK: $fileName -> $s3Key"
            $totalSuccess++
        } catch {
            Write-SyncLog "[$datasetFolder] ERROR: $fileName - $($_.Exception.Message)" -Level "ERROR"
            $totalErrors++
        }
    }
}

Write-SyncLog "Completado: Exitosos=$totalSuccess | Errores=$totalErrors | Omitidos=$totalSkipped"

# Limpieza de archivos antiguos (mas de 30 dias)
$cutoffDate = (Get-Date).AddDays(-30)
foreach ($datasetFolder in $DatasetFolders) {
    $archivePath = Join-Path $BaseArchivePath $datasetFolder
    if (Test-Path $archivePath) {
        Get-ChildItem -Path $archivePath -File | Where-Object { $_.LastWriteTime -lt $cutoffDate } | ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-SyncLog "[$datasetFolder] Eliminado antiguo: $($_.Name)"
        }
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
Write-Output " - Script:  C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"
Write-Output " - Tarea:   $taskName (cada 5 min)"
Write-Output " - Folders: board-files, nursing-files, pharmacy"
Write-Output " - Landing: C:\SFTP\BoardFiles\Landing\{folder}"
Write-Output " - Archive: C:\SFTP\BoardFiles\Archive\{folder}"
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
