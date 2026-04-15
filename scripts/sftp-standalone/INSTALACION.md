# Guía de Instalación: SFTP to S3 Sync Scripts

Esta guía explica cómo instalar los scripts de sincronización SFTP → S3 en la máquina Windows de producción.

## Scripts Disponibles

| Script | Descripción | Bucket destino |
|--------|-------------|----------------|
| `Sync-BoardFilesToS3.ps1` | Mirror recursivo de `C:\CEB_FTP_Data\SFTP` → S3. No mueve ni renombra archivos. | `cebroker-sftp-raw-test-backup` |
| `Sync-AllSFTPToS3.ps1` | Sync completo con auditoría, reportes CSV y backfill de metadata. | (ver config interna) |

Ambos scripts usan **modo mixto**: DELTA cada 5 min + FULL cada 60 min, mirror delete con grace period, y lock files para evitar ejecución concurrente.

---

## Requisitos Previos

- Windows Server 2016+ o Windows 10/11
- PowerShell 5.1 o superior
- Acceso a Internet
- Permisos de Administrador
- Credenciales de AWS con permisos `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket`

---

## Paso 1: Conectarse a la Máquina

Conéctate a la máquina Windows usando:
- **RDP** (Remote Desktop)
- **SSM Session Manager** (si es EC2 en AWS): `aws ssm start-session --target <instance-id>`
- **Acceso físico/consola**

---

## Paso 2: Abrir PowerShell como Administrador

1. Presiona `Win + X`
2. Selecciona **"Windows PowerShell (Admin)"** o **"Terminal (Admin)"**
3. Confirma el prompt de UAC si aparece

---

## Paso 3: Instalar el Módulo de AWS PowerShell

```powershell
# Instalar el proveedor NuGet (requerido para instalar módulos)
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

# Instalar el módulo de AWS PowerShell
Install-Module -Name AWSPowerShell -Force -AllowClobber

# Verificar la instalación
Get-Module -ListAvailable -Name AWSPowerShell
```

---

## Paso 4: Configurar Credenciales de AWS

### Opción A: Máquina EC2 con IAM Role (Recomendado)

Si la máquina es una instancia EC2 con un IAM Role que tiene permisos de S3, no necesitas configurar nada. El módulo de AWS usará las credenciales del role automáticamente.

### Opción B: Credenciales Manuales (Access Key)

```powershell
Set-AWSCredential -AccessKey "TU_ACCESS_KEY_ID" -SecretKey "TU_SECRET_ACCESS_KEY" -StoreAs default

# Verificar que funcionan
Get-S3Bucket
```

### Opción C: Archivo de Credenciales

Crea el archivo `C:\Users\TU_USUARIO\.aws\credentials`:

```ini
[default]
aws_access_key_id = TU_ACCESS_KEY_ID
aws_secret_access_key = TU_SECRET_ACCESS_KEY
region = us-east-1
```

---

## Paso 5: Crear la Estructura de Carpetas

```powershell
# Crear carpetas base
$folders = @(
    "C:\CEB_FTP_Data\Scripts",
    "C:\CEB_FTP_Data\Logs",
    "C:\CEB_FTP_Data\SFTP\Boards",
    "C:\CEB_FTP_Data\SFTP\Providers",
    "C:\CEB_FTP_Data\SFTP\Pharmacy"
)

foreach ($folder in $folders) {
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
}

# Verificar
Get-ChildItem "C:\CEB_FTP_Data" -Recurse -Directory | Select-Object FullName
```

---

## Paso 6: Copiar los Scripts

Copia los scripts desde este repositorio a la máquina:

```powershell
# Destino de los scripts
$destDir = "C:\CEB_FTP_Data\Scripts"

# Copiar manualmente o via SCP/SSM los siguientes archivos:
#   Sync-BoardFilesToS3.ps1  ->  C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1
#   Sync-AllSFTPToS3.ps1     ->  C:\CEB_FTP_Data\Scripts\Sync-AllSFTPToS3.ps1

# Verificar
Test-Path "$destDir\Sync-BoardFilesToS3.ps1"
Test-Path "$destDir\Sync-AllSFTPToS3.ps1"
```

### Deploy automático via SSM (desde tu máquina local)

```bash
# Desde la raíz del repositorio
./scripts/sftp-standalone/deploy-sync-script.sh <instance-id>

# O auto-detectar instance ID desde Pulumi
./scripts/sftp-standalone/deploy-sync-script.sh
```

> **Nota:** El script `deploy-sync-script.sh` contiene una versión embebida antigua del sync script. Para desplegar la versión actual, copia los archivos `.ps1` directamente.

---

## Paso 7: Configurar los Scripts

Edita las variables de configuración en cada script según el entorno:

```powershell
notepad "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"
```

### Variables principales en `Sync-BoardFilesToS3.ps1`

| Variable | Default | Descripción |
|----------|---------|-------------|
| `$BasePath` | `C:\CEB_FTP_Data\SFTP` | Carpeta raíz del SFTP |
| `$LogPath` | `C:\CEB_FTP_Data\Logs\sync.log` | Archivo de log |
| `$BucketName` | `cebroker-sftp-raw-test-backup` | Bucket S3 destino |
| `$AwsRegion` | `us-east-1` | Región de AWS |
| `$SyncAfterDate` | `2026-03-20` | Solo sincronizar archivos creados/modificados después de esta fecha |
| `$DeltaLookbackMinutes` | `20` | Ventana de lookback en scans delta |
| `$FullReconcileIntervalMinutes` | `60` | Intervalo entre full scans |
| `$EnableMirrorDelete` | `$true` | Habilitar borrado de orphans en S3 |
| `$DeleteOrphanAfterDays` | `7` | Días de gracia antes de borrar orphans |

---

## Paso 8: Probar el Script Manualmente

```powershell
# Crear un archivo de prueba
"Archivo de prueba" | Out-File "C:\CEB_FTP_Data\SFTP\test-file.txt"

# Ejecutar el script
& "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"

# Verificar el log
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Tail 30

# Verificar que el archivo llegó a S3
Get-S3Object -BucketName "cebroker-sftp-raw-test-backup" -Key "test-file.txt"

# Probar dry-run delete (valida orphans sin borrar)
& "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1" -DryRunDelete
```

---

## Paso 9: Crear las Tareas Programadas

> **Importante:** El script usa estrategia mixta:
> - **DELTA** cada 5 minutos (solo archivos recientes)
> - **FULL** cada 60 minutos (reconciliación completa + mirror delete)
>
> La tarea programada corre cada 5 min; el script decide internamente si toca DELTA o FULL.

### Tarea para `Sync-BoardFilesToS3.ps1`

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
    -Description "Mirror sync de SFTP a S3 cada 5 minutos (delta/full mixto)"

# Verificar
Get-ScheduledTask -TaskName $taskName
```

### Tarea para `Sync-AllSFTPToS3.ps1` (opcional)

```powershell
$taskName   = "AllSFTP-S3-Sync"
$scriptPath = "C:\CEB_FTP_Data\Scripts\Sync-AllSFTPToS3.ps1"
$workDir    = "C:\CEB_FTP_Data\Scripts"

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
    -WorkingDirectory $workDir

$trigger = New-ScheduledTaskTrigger `
    -Once -At (Get-Date).AddMinutes(3) `
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
    -Description "Full SFTP sync a S3 con auditoría cada 5 minutos"

Get-ScheduledTask -TaskName $taskName
```

> **Nota:** Ambos scripts comparten un **global lock** (`Sync-S3-Mirror.global.lock`) que impide ejecución simultánea entre ellos. Puedes programar ambas tareas sin riesgo de colisión.

---

## Paso 10: Verificar que Todo Funciona

```powershell
# Ver estado de las tareas
Get-ScheduledTask -TaskName "BoardFiles-S3-Sync" | Select-Object TaskName, State

# Ejecutar manualmente
Start-ScheduledTask -TaskName "BoardFiles-S3-Sync"

# Ver últimos logs
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Tail 30

# Ver historial de ejecución
Get-ScheduledTaskInfo -TaskName "BoardFiles-S3-Sync"

# Ver estado del sync (último delta/full scan)
Get-Content "C:\CEB_FTP_Data\Logs\.sync_state_boardfiles.json"

# Ver orphans pendientes de borrado
Get-Content "C:\CEB_FTP_Data\Logs\.sync_orphans_boardfiles.json"
```

---

## Troubleshooting

### Ver logs en tiempo real
```powershell
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Wait -Tail 10
```

### Ver objetos en S3
```powershell
Get-S3Object -BucketName "cebroker-sftp-raw-test-backup" |
    Sort-Object LastModified -Descending |
    Select-Object -First 20 Key, Size, LastModified
```

### Verificar lock files (si el script no arranca)
```powershell
# Ver locks activos
Get-ChildItem "C:\CEB_FTP_Data\Logs\*.lock"

# Ver contenido del lock (PID y timestamp)
Get-Content "C:\CEB_FTP_Data\Logs\Sync-BoardFilesToS3.lock"
Get-Content "C:\CEB_FTP_Data\Logs\Sync-S3-Mirror.global.lock"

# Eliminar lock huérfano manualmente (solo si el proceso ya no corre)
Remove-Item "C:\CEB_FTP_Data\Logs\Sync-BoardFilesToS3.lock" -Force
```

### Forzar un full scan
```powershell
# Borrar el state file para que el próximo run sea FULL
Remove-Item "C:\CEB_FTP_Data\Logs\.sync_state_boardfiles.json" -Force
```

### Detener/eliminar tareas programadas
```powershell
Stop-ScheduledTask -TaskName "BoardFiles-S3-Sync"
Unregister-ScheduledTask -TaskName "BoardFiles-S3-Sync" -Confirm:$false
```

### Ver Event Logs
```powershell
Get-EventLog -LogName Application -Source "BoardFileSync" -Newest 20
```

### Validar orphans sin borrar (dry-run)
```powershell
& "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1" -DryRunDelete
```

---

## Estructura Final en Producción

```
C:\CEB_FTP_Data\
├── Scripts\
│   ├── Sync-BoardFilesToS3.ps1       ← Script principal (mirror sync)
│   └── Sync-AllSFTPToS3.ps1          ← Script completo con auditoría
├── Logs\
│   ├── sync.log                       ← Log de ejecución
│   ├── .sync_state_boardfiles.json    ← Estado delta/full (BoardFiles)
│   ├── .sync_orphans_boardfiles.json  ← Orphans pendientes de delete
│   ├── sync-all-report.csv            ← Reporte CSV (AllSFTP)
│   ├── Sync-BoardFilesToS3.lock       ← Lock file (auto-limpiado)
│   └── Sync-S3-Mirror.global.lock     ← Lock global compartido
└── SFTP\                              ← Carpeta raíz sincronizada
    ├── Boards\
    │   ├── Board_NDSBOTP\
    │   ├── Board_NDSWE\
    │   └── ...
    ├── Providers\
    ├── Pharmacy\
    └── ...
```

---

## Notas Importantes

1. **Mirror sync**: Los scripts mantienen S3 como espejo exacto del SFTP. No mueven ni renombran archivos locales.

2. **Metadata en S3**: Cada objeto se sube con metadata `source-last-write-time-utc` y `source-creation-time-utc` para detectar cambios sin re-subir.

3. **Skip inteligente**: Si key + size + metadata coinciden en S3, el archivo se omite (ahorra ancho de banda).

4. **Mirror delete con grace period**: Los archivos que desaparecen del SFTP se marcan como orphans y solo se borran de S3 después de `$DeleteOrphanAfterDays` días (default: 7).

5. **Control de concurrencia**: Cada script tiene un lock file propio + un lock global compartido (`Sync-S3-Mirror.global.lock`) que impide ejecución simultánea entre scripts.

6. **Lock stale detection**: Si el proceso que tomó el lock ya no corre (PID muerto) o el lock tiene más de 2h, se trata como huérfano y se elimina automáticamente.

7. **Permisos IAM requeridos**: `s3:PutObject`, `s3:GetObject`, `s3:GetObjectMetadata`, `s3:DeleteObject`, `s3:ListBucket` sobre el bucket destino.

8. **Frecuencia**: La tarea corre cada 5 min. Internamente el script decide DELTA (rápido, solo archivos recientes) o FULL (reconciliación completa + mirror delete) según `$FullReconcileIntervalMinutes`.
