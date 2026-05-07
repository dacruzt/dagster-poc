# Setup: SFTP to S3 Sync - ceb-sftp-01

## Resumen

Guia paso a paso para configurar el script de sincronizacion (modo append/update) de archivos desde la EC2 Windows `ceb-sftp-01` hacia el bucket S3 `cebroker-sftp-raw-prod-backup`.

El script preserva la ruta y el nombre original, y **no** mueve, renombra ni borra archivos en SFTP. Tampoco borra objetos de S3: solo sube archivos nuevos o actualizados.

**Flujo:**
```
EC2 (ceb-sftp-01)                              S3 (append/update)
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
                "s3:PutObjectAcl"
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
6. **Policy name:** `s3-sftp-sync-write`
7. Click **Create policy**

> **Nota:** El script funciona en modo append/update — solo sube archivos nuevos o actualizados, nunca borra de S3. Por eso no requiere `s3:DeleteObject`.

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
│   └── .sync_state_boardfiles.json               (estado FULL/DELTA)
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
$scriptUrl  = "https://raw.githubusercontent.com/dacruzt/dagster-poc/main/scripts/sftp-standalone/Sync-BoardFilesToS3.ps1"
$scriptPath = "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"

Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing
```

> **Importante:** Despues de descargar, abrir el archivo y verificar que `$BucketName = "cebroker-sftp-raw-prod-backup"`. Si el repo tiene otro valor por defecto (test), ajustarlo manualmente.

### Configuracion del script

| Variable | Valor por defecto | Descripcion |
|----------|-------------------|-------------|
| `$BasePath` | `C:\CEB_FTP_Data\SFTP` | Carpeta raiz que se escanea |
| `$BucketName` | `cebroker-sftp-raw-prod-backup` | Bucket S3 destino |
| `$AwsRegion` | `us-east-1` | Region AWS |
| `$SyncAfterDate` | `2026-03-20` | Solo sincroniza archivos modificados/creados desde esta fecha |
| `$DeltaLookbackMinutes` | `20` | Ventana extra hacia atras en cada DELTA scan |
| `$FullReconcileIntervalMinutes` | `60` | Cada cuanto hacer un FULL scan |

### Que hace el script

1. **Locks**: Adquiere un lock local (`Sync-BoardFilesToS3.lock`) y un lock global compartido (`Sync-S3-Mirror.global.lock`) para evitar ejecuciones concurrentes con otros scripts hermanos. Si el lock global esta tomado, reintenta hasta 15 veces cada 2 minutos (~30 min max).
2. **Indexa S3** una sola vez con `Get-S3Object` para lookups rapidos (key + size).
3. **Modo mixto FULL/DELTA**:

   - **DELTA** (corridas frecuentes): solo archivos con `LastWriteTimeUtc` desde la ultima ventana (con lookback de 20 min).
   - **FULL** (cada 60 min): escanea TODOS los archivos del SFTP filtrando por `SyncAfterDate` para reconciliar lo que DELTA pueda haber perdido.

4. **Sube a S3** preservando ruta y nombre original (`Boards/Board_183/archivo.csv`). Adjunta metadata `source-last-write-time-utc` y `source-creation-time-utc`.
5. **Skip si S3 ya esta al dia**: si key + size + metadata coinciden, no resube.
6. **Verifica** que el archivo no este bloqueado ni en transferencia (tamano estable por 3s).
7. **Logging triple**: archivo (`sync.log`), consola con colores y Windows Event Log (source `BoardFileSync`, log `Application`).
8. **Cleanup garantizado**: bloque `finally` libera los lock files aunque haya excepciones.
9. **Aborta** si recibe `Access Denied` por `s3:PutObject` (evita repetir errores).

**Modo append/update only:** el script nunca borra de S3. Si un archivo desaparece del SFTP, el objeto correspondiente queda intacto en S3.

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

### Revisar logs

```powershell
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Tail 30
```

### Validar modo DELTA/FULL

En `sync.log` deberias ver alternar:

- `SFTP DELTA scan mode since UTC ...` en corridas normales
- `SFTP FULL scan mode` aproximadamente cada 60 minutos

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
| `Write-S3Object is not recognized` | Instalar AWS PowerShell: `Install-Module -Name AWSPowerShell -Force` |
| No aparecen archivos nuevos | Verificar `$SyncAfterDate` - archivos antes de esa fecha son ignorados |
| Script no se ejecuta automaticamente | Verificar tarea: `Get-ScheduledTask -TaskName "BoardFiles-S3-Sync"` |
| Necesita instalar como Admin | Abrir PowerShell con click derecho > Run as Administrator |
| `Another instance is already running (PID: XXXX)` | Una instancia real esta corriendo. Esperar que termine o matar: `Stop-Process -Id XXXX -Force` |
| `Could not acquire global lock after 15 retries` | Otro script hermano esta corriendo > 30 min. Revisar `Sync-S3-Mirror.global.lock` |
| `Orphan lock file detected` | El proceso anterior termino inesperadamente. El script lo detecta y continua automaticamente |
| Lock file permanece despues de ejecucion | Eliminar manualmente: `Remove-Item C:\CEB_FTP_Data\Logs\Sync-BoardFilesToS3.lock -Force` |
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
- **Última actualización:** 2026-05-07
- **Implementado por:** Diego Cruz
- **Estado:** Funcionando correctamente (modo append/update)

### Cambios 2026-05-07

- **Modo append/update only**: removido el mirror delete y todo el tracking de huerfanos. El script nunca borra de S3.
- `s3:DeleteObject` removido de la inline policy del role (ya no es necesario).
- Eliminado el parametro `-DryRunDelete` y los archivos `.sync_orphans_boardfiles.json`.
- Script reducido ~115 lineas; doc embebido reemplazado por descarga via `Invoke-WebRequest` desde GitHub.

### Cambios 2026-05-05

- Bucket destino: `cebroker-sftp-raw-prod-backup` (same-account, no cross-account)
- La S3 key preserva la ruta y nombre original (sin prefijo timestamp)
- Archivos ya **no** se mueven a `processed/` despues de subir
- **Skip dedup por metadata**: si key + size + metadata `source-last-write-time-utc`/`source-creation-time-utc` coinciden, no resube
- **Lock global compartido** (`Sync-S3-Mirror.global.lock`) con retry (15 × 2 min) para serializar con scripts hermanos
- Logging adicional a Windows Event Log (source `BoardFileSync`)
- Bloque `try/finally` garantiza liberar locks ante excepciones

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
