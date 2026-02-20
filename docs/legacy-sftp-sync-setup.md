# Sync Script - Legacy SFTP Server to S3

## Resumen

Script PowerShell que sincroniza archivos desde el servidor legacy SFTP (`legacy-sftp-02`) hacia un bucket S3 en otra cuenta AWS. Se ejecuta cada 5 minutos como tarea programada de Windows.

**Flujo:**
```
C:\CEB_FTP_Data\SFTP\
  ├── Boards\Board_NDSBOTP\archivo.csv        ──►  s3://BUCKET/Boards/Board_NDSBOTP/20260219_143000_archivo.csv
  ├── Boards\Board_NDSWE\archivo.csv          ──►  s3://BUCKET/Boards/Board_NDSWE/20260219_143000_archivo.csv
  ├── Providers\Providers_XXX\archivo.csv     ──►  s3://BUCKET/Providers/Providers_XXX/20260219_143000_archivo.csv
  └── (otras carpetas...)                     ──►  s3://BUCKET/{ruta_relativa}/20260219_143000_archivo.csv
```

Despues de subir cada archivo a S3, lo mueve a una subcarpeta `processed/` en su misma ubicacion.

---

## Cuentas AWS

| Concepto | Account ID | Descripcion |
|----------|------------|-------------|
| **Origen** (SFTP Server) | `521293766279` | Cuenta donde esta la instancia EC2 `legacy-sftp-02` |
| **Destino** (S3 Bucket) | `281273450653` | Cuenta donde esta el bucket S3 destino |

---

## Paso 1: Crear permisos IAM en la cuenta origen (521293766279)

La instancia EC2 `legacy-sftp-02` necesita un IAM Role con permisos para escribir en el bucket S3 de la otra cuenta.

### 1.1 Verificar el IAM Role de la instancia

Conectarse a la instancia y verificar que tiene un Instance Profile asignado:

```powershell
# Desde la instancia (PowerShell)
Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/iam/info
```

Si no tiene Instance Profile, crear uno en IAM y asignarlo a la instancia.

### 1.2 Agregar politica al IAM Role de la instancia

Crear una politica IAM en la cuenta `521293766279` y adjuntarla al role de la instancia:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowWriteToCrossAccountBucket",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:PutObjectAcl"
            ],
            "Resource": "arn:aws:s3:::CAMBIAR-NOMBRE-DEL-BUCKET/*"
        },
        {
            "Sid": "AllowListBucket",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::CAMBIAR-NOMBRE-DEL-BUCKET"
        }
    ]
}
```

> **IMPORTANTE:** Reemplazar `CAMBIAR-NOMBRE-DEL-BUCKET` por el nombre real del bucket S3.

---

## Paso 2: Crear bucket policy en la cuenta destino (281273450653)

En la cuenta donde esta el bucket S3, agregar esta politica al bucket para permitir acceso cross-account:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCrossAccountWrite",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::521293766279:root"
            },
            "Action": [
                "s3:PutObject",
                "s3:PutObjectAcl"
            ],
            "Resource": "arn:aws:s3:::CAMBIAR-NOMBRE-DEL-BUCKET/*"
        },
        {
            "Sid": "AllowCrossAccountList",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::521293766279:root"
            },
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::CAMBIAR-NOMBRE-DEL-BUCKET"
        }
    ]
}
```

> **Nota:** Para mayor seguridad, en lugar de `arn:aws:iam::521293766279:root` se puede restringir al ARN especifico del role de la instancia: `arn:aws:iam::521293766279:role/NOMBRE-DEL-ROLE`.

---

## Paso 3: Instalar AWS PowerShell en la instancia

Conectarse a la instancia via RDP o SSM y ejecutar:

```powershell
# Verificar si ya esta instalado
Get-Module -ListAvailable -Name AWSPowerShell

# Si no esta instalado:
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name AWSPowerShell -Force -AllowClobber
```

### Verificar acceso al bucket

```powershell
# Probar que la instancia puede escribir al bucket
Write-S3Object -BucketName "CAMBIAR-NOMBRE-DEL-BUCKET" -Key "test/connection-test.txt" -Content "test" -Region "us-east-1"

# Verificar
Get-S3Object -BucketName "CAMBIAR-NOMBRE-DEL-BUCKET" -KeyPrefix "test/" -Region "us-east-1"

# Limpiar
Remove-S3Object -BucketName "CAMBIAR-NOMBRE-DEL-BUCKET" -Key "test/connection-test.txt" -Region "us-east-1" -Force
```

Si este paso falla, revisar los permisos IAM (Paso 1) y la bucket policy (Paso 2).

---

## Paso 4: Crear el script de sincronizacion

### 4.1 Crear carpeta de logs

```powershell
New-Item -ItemType Directory -Path "C:\CEB_FTP_Data\Logs" -Force
```

### 4.2 Crear el archivo del script

Crear el archivo `C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1` con el siguiente contenido:

```powershell
# =============================================================================
# Sync-BoardFilesToS3.ps1 - Recursive SFTP Sync Script
# =============================================================================
# Ruta: C:\CEB_FTP_Data\SFTP\
#   ├── Boards\Board_*\   -> s3://BUCKET/Boards/Board_*/timestamp_file.csv
#   └── Providers\         -> s3://BUCKET/Providers/timestamp_file.csv
#
# - Escanea recursivamente buscando archivos nuevos
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
$BucketName     = "CAMBIAR-NOMBRE-DEL-BUCKET"          # <-- CAMBIAR
$AwsRegion      = "us-east-1"
$SyncAfterDate  = [DateTime]"2026-02-19"                # Ignorar archivos anteriores

# -----------------------------------------------------------------------------
# FUNCIONES
# -----------------------------------------------------------------------------

function Write-SyncLog {
    param([string]$Message, [string]$Level = "INFO")
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "[$timestamp] [$Level] $Message" -Force
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
        Write-EventLog -LogName Application -Source $source -EventId 1000 `
            -EntryType $eventType -Message $Message -ErrorAction SilentlyContinue
    } catch {}
}

function Test-FileNotLocked {
    param([string]$FilePath)
    try {
        $s = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
        $s.Close(); $s.Dispose()
        return $true
    } catch { return $false }
}

function Get-FileStableSize {
    param([string]$FilePath, [int]$WaitSeconds = 5)
    $s1 = (Get-Item $FilePath).Length
    Start-Sleep -Seconds $WaitSeconds
    $s2 = (Get-Item $FilePath).Length
    return $s1 -eq $s2
}

# -----------------------------------------------------------------------------
# PROCESO PRINCIPAL
# -----------------------------------------------------------------------------

Write-SyncLog "Iniciando sincronizacion recursiva..."
$totalSuccess = 0; $totalErrors = 0; $totalSkipped = 0

$allFiles = Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CreationTime -ge $SyncAfterDate -and
        $_.DirectoryName -notmatch '\\processed(\\|$)'
    }

if ($allFiles.Count -eq 0) {
    Write-SyncLog "No hay archivos nuevos para sincronizar"
} else {
    Write-SyncLog "Encontrados $($allFiles.Count) archivos nuevos"
    foreach ($file in $allFiles) {
        $filePath = $file.FullName
        $fileName = $file.Name
        $fileDir  = $file.DirectoryName

        $relativePath = $fileDir.Substring($BasePath.Length).TrimStart('\') -replace '\\', '/'
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $s3Key = "$relativePath/${timestamp}_$fileName"

        Write-SyncLog "[$relativePath] Procesando: $fileName ($([math]::Round($file.Length/1MB,2)) MB)"

        if (-not (Test-FileNotLocked -FilePath $filePath)) {
            Write-SyncLog "[$relativePath] Bloqueado: $fileName" -Level "WARN"
            $totalSkipped++; continue
        }
        if (-not (Get-FileStableSize -FilePath $filePath -WaitSeconds 3)) {
            Write-SyncLog "[$relativePath] En transferencia: $fileName" -Level "WARN"
            $totalSkipped++; continue
        }

        try {
            Write-SyncLog "[$relativePath] Subiendo a s3://$BucketName/$s3Key"
            Write-S3Object -BucketName $BucketName -File $filePath -Key $s3Key -Region $AwsRegion

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

Write-SyncLog "Completado: Exitosos=$totalSuccess | Errores=$totalErrors | Omitidos=$totalSkipped"

# Limpieza: archivos en processed/ con mas de 30 dias
$cutoffDate = (Get-Date).AddDays(-30)
Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match '\\processed(\\|$)' -and $_.LastWriteTime -lt $cutoffDate } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-SyncLog "Limpieza: $($_.FullName.Substring($BasePath.Length))"
    }

Write-SyncLog "Script finalizado"
```

> **IMPORTANTE:** Cambiar `CAMBIAR-NOMBRE-DEL-BUCKET` en la linea de `$BucketName` por el nombre real del bucket.
>
> **IMPORTANTE:** Cambiar `$SyncAfterDate` a la fecha a partir de la cual se quieren sincronizar archivos. Los archivos creados antes de esa fecha seran ignorados.

---

## Paso 5: Crear la tarea programada

Ejecutar en PowerShell como Administrador:

```powershell
$taskName = "BoardFiles-S3-Sync"

# Eliminar tarea existente si hay una
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Output "Tarea anterior eliminada"
}

# Crear nueva tarea
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 9999)

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
    -LogonType ServiceAccount -RunLevel Highest

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
    -Description "Sincroniza archivos de SFTP a S3 cada 5 minutos" `
    -Force

Write-Output "Tarea '$taskName' creada exitosamente"
```

### Registrar Event Source (opcional, para Windows Event Log)

```powershell
if (-not [System.Diagnostics.EventLog]::SourceExists("BoardFileSync")) {
    New-EventLog -LogName Application -Source "BoardFileSync"
    Write-Output "Event source registrado"
}
```

---

## Paso 6: Verificacion

### Ejecutar el script manualmente

```powershell
& "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"
```

### Revisar el log

```powershell
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Tail 20
```

### Verificar la tarea programada

```powershell
Get-ScheduledTask -TaskName "BoardFiles-S3-Sync" | Format-List TaskName, State, Description
```

### Verificar archivos en S3

```powershell
Get-S3Object -BucketName "CAMBIAR-NOMBRE-DEL-BUCKET" -KeyPrefix "Boards/" -Region "us-east-1" | Select-Object Key, Size, LastModified
```

---

## Estructura de carpetas en el servidor

Segun el servidor `legacy-sftp-02`, la estructura bajo `C:\CEB_FTP_Data\SFTP\` es:

```
C:\CEB_FTP_Data\
├── Logs\                    ← Logs del sync script
│   └── sync.log
├── Scripts\                 ← Script de sincronizacion
│   └── Sync-BoardFilesToS3.ps1
└── SFTP\                    ← Raiz del SFTP
    ├── Boards\
    │   ├── Board_NDSBOTP\
    │   ├── Board_NDSWE\
    │   ├── Board_NHMS\
    │   ├── Board_NHOPLC\
    │   ├── Board_NMM\
    │   ├── Board_NMMMedical\
    │   ├── Board_NMN\
    │   ├── Board_NMRealEstate\
    │   ├── Board_NVBOM\
    │   ├── Board_NVPT\
    │   ├── Board_OBMLS\
    │   ├── Board_OKBCE\
    │   ├── Board_OKDENT\
    │   ├── Board_OKREC\
    │   ├── Board_OSBOE\
    │   ├── Board_SCAG\
    │   ├── Board_SCRQSA\
    │   ├── Board_SDBMT\
    │   ├── Board_TFSC\
    │   ├── Board_TMB\
    │   ├── Board_TNDCI\
    │   ├── Board_TSBPE\
    │   ├── Board_TXBHEC\
    │   ├── Board_TXOPT\
    │   ├── Board_VADental\
    │   └── Board_VAPT\
    ├── CEB_FTP_TESTER\
    ├── CEBroker\
    ├── dagster_user\
    ├── Employers\
    ├── LicenseVerification\
    ├── OtherUsers\
    ├── Prehire\
    ├── Providers\
    │   ├── Providers_XXX\
    │   ├── Providers_YYY\
    │   └── ... (subcarpetas Providers_*)
    ├── sre_synthetic\
    └── States\
```

El script escanea **todas** las carpetas bajo `C:\CEB_FTP_Data\SFTP\` recursivamente, incluyendo subcarpetas de `Boards\Board_*\` y `Providers\Providers_*\`. Cualquier archivo nuevo en cualquier nivel de profundidad sera detectado y subido a S3 preservando la ruta relativa.

---

## Troubleshooting

| Problema | Solucion |
|----------|----------|
| `Write-S3Object: Access Denied` | Verificar IAM policy (Paso 1) y bucket policy (Paso 2) |
| `The term 'Write-S3Object' is not recognized` | Instalar AWS PowerShell: `Install-Module -Name AWSPowerShell -Force` |
| No aparecen archivos nuevos en el log | Verificar `$SyncAfterDate` - archivos creados antes de esa fecha son ignorados |
| Archivos no se mueven a processed/ | Verificar permisos de escritura del usuario SYSTEM en la carpeta |
| Script no se ejecuta automaticamente | Verificar tarea programada: `Get-ScheduledTask -TaskName "BoardFiles-S3-Sync"` |
| Error `file is locked` | El archivo esta siendo escrito por otro proceso. El script lo reintentara en la siguiente ejecucion (5 min) |

---

## Resumen de permisos necesarios

### Cuenta 521293766279 (origen - SFTP server)
- IAM Role de la instancia EC2 con permisos `s3:PutObject`, `s3:PutObjectAcl`, `s3:ListBucket` sobre el bucket destino

### Cuenta 281273450653 (destino - S3 bucket)
- Bucket policy que permita `s3:PutObject`, `s3:PutObjectAcl`, `s3:ListBucket` desde la cuenta `521293766279`
