# Setup: SFTP to S3 Sync - ceb-sftp-01

## Resumen

Guia paso a paso para configurar el script de sincronizacion de archivos desde la EC2 Windows `ceb-sftp-01` hacia el bucket S3 `dagster-poc-sand-bucket-7a45862` en una cuenta AWS diferente (cross-account).

**Flujo:**
```
EC2 (ceb-sftp-01)                                    S3 (cross-account)
C:\CEB_FTP_Data\SFTP\                                dagster-poc-sand-bucket-7a45862
  Boards\Board_183\archivo.csv          -->           Boards/Board_183/20260303_102624_archivo.csv
  Boards\Board_NDSBOTP\archivo.csv      -->           Boards/Board_NDSBOTP/20260303_102624_archivo.csv
  Providers\archivo.csv                 -->           Providers/20260303_102624_archivo.csv
```

Despues de subir cada archivo a S3, lo mueve a una subcarpeta `processed/` en su misma ubicacion.

---

## Cuentas AWS

| Concepto | Account ID | Recurso |
|----------|------------|---------|
| **Origen** (EC2 SFTP) | `118233265530` | EC2 `ceb-sftp-01` (`i-0bee21a6887ea9aa1`) |
| **Destino** (S3 Bucket) | `114009992586` | Bucket `dagster-poc-sand-bucket-7a45862` |

## Datos de la instancia EC2

| Campo | Valor |
|-------|-------|
| Hostname | ceb-sftp-01 |
| Instance ID | i-0bee21a6887ea9aa1 |
| Instance type | t3.small |
| Private IP | 10.116.193.132 |
| Public IP | 98.81.10.43 |
| Availability Zone | us-east-1a |
| Platform | Windows |
| AMI | sftp-legacy-temp-s3-project |
| VPC | vpc-0317245c8a97b7ae8 (ceb-prod-vpc-ue1) |

---

## Paso 1: Crear IAM Role para la EC2 (cuenta 118233265530)

La instancia EC2 no tenia un IAM Role asignado. Se creo uno nuevo.

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
            "Sid": "AllowWriteToCrossAccountBucket",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:PutObjectAcl"
            ],
            "Resource": "arn:aws:s3:::dagster-poc-sand-bucket-7a45862/*"
        },
        {
            "Sid": "AllowListBucket",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::dagster-poc-sand-bucket-7a45862"
        }
    ]
}
```

5. Click **Next**
6. **Policy name:** `s3-cross-account-write`
7. Click **Create policy**

### 1.3 Asignar el Role a la instancia EC2

1. Ir a **EC2 > Instances**
2. Seleccionar `i-0bee21a6887ea9aa1`
3. **Actions > Security > Modify IAM role**
4. Seleccionar `ceb-sftp-s3-sync-role`
5. Click **Update IAM role**

---

## Paso 2: Bucket Policy (cuenta 114009992586)

En la cuenta donde esta el bucket S3, agregar estos statements a la bucket policy.

1. Ir a **S3 > dagster-poc-sand-bucket-7a45862 > Permissions > Bucket policy**
2. Agregar los siguientes statements (si ya existe una policy, agregar al array `Statement` existente):

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCrossAccountWriteFromSFTP",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::118233265530:role/ceb-sftp-s3-sync-role"
            },
            "Action": [
                "s3:PutObject",
                "s3:PutObjectAcl"
            ],
            "Resource": "arn:aws:s3:::dagster-poc-sand-bucket-7a45862/*"
        },
        {
            "Sid": "AllowCrossAccountListFromSFTP",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::118233265530:role/ceb-sftp-s3-sync-role"
            },
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::dagster-poc-sand-bucket-7a45862"
        }
    ]
}
```

> **Nota:** Se usa el ARN del role especifico en lugar de `root` para mayor seguridad. Solo la EC2 con este role puede escribir al bucket.

---

## Paso 3: Instalar AWS PowerShell en la EC2

Conectarse a la instancia via RDP y abrir **PowerShell como Administrador**:

```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name AWSPowerShell -Force -AllowClobber
```

### Verificar conectividad cross-account

```powershell
Write-S3Object -BucketName "dagster-poc-sand-bucket-7a45862" -Key "test/connection-test.txt" -Content "test" -Region "us-east-1"
```

Si no da error, la conexion cross-account funciona correctamente.

> **Nota:** El role no tiene permiso `s3:DeleteObject`, por lo que `Remove-S3Object` fallara. Esto es por diseno - el archivo de test se puede eliminar desde la cuenta del bucket (114009992586).

---

## Paso 4: Crear estructura de carpetas

La estructura `C:\CEB_FTP_Data\SFTP\` ya existia en esta instancia (viene del AMI). Se crearon las carpetas adicionales para scripts y logs:

```powershell
New-Item -Path "C:\CEB_FTP_Data\Scripts" -ItemType Directory -Force
New-Item -Path "C:\CEB_FTP_Data\Logs" -ItemType Directory -Force
```

### Estructura existente en C:\CEB_FTP_Data\SFTP\

```
C:\CEB_FTP_Data\
├── Logs\
│   └── sync.log
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

## Paso 5: Crear el script de sincronizacion

En PowerShell como Administrador, ejecutar:

```powershell
Set-Content -Path "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1" -Value @'
$ErrorActionPreference = "Continue"

$BasePath = "C:\CEB_FTP_Data\SFTP"
$LogPath = "C:\CEB_FTP_Data\Logs\sync.log"
$BucketName = "dagster-poc-sand-bucket-7a45862"
$AwsRegion = "us-east-1"
$SyncAfterDate = [DateTime]"2026-03-03"

function Write-SyncLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    $line | Out-File -FilePath $LogPath -Append -Encoding utf8
    Write-Host $line
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

Write-SyncLog "=========================================="
Write-SyncLog "Iniciando sincronizacion recursiva..."
Write-SyncLog "Base: $BasePath"
Write-SyncLog "Bucket: $BucketName"
Write-SyncLog "=========================================="

$totalSuccess = 0
$totalErrors = 0
$totalSkipped = 0

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

$cutoffDate = (Get-Date).AddDays(-30)
Get-ChildItem -Path $BasePath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match '\\processed(\\|$)' -and $_.LastWriteTime -lt $cutoffDate } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-SyncLog "Limpieza: $($_.FullName.Substring($BasePath.Length))"
    }

Write-SyncLog "Script finalizado"
'@ -Encoding UTF8
```

### Configuracion del script

| Variable | Valor | Descripcion |
|----------|-------|-------------|
| `$BasePath` | `C:\CEB_FTP_Data\SFTP` | Carpeta raiz que se escanea |
| `$BucketName` | `dagster-poc-sand-bucket-7a45862` | Bucket S3 destino |
| `$AwsRegion` | `us-east-1` | Region AWS |
| `$SyncAfterDate` | `2026-03-03` | Solo sincroniza archivos creados desde esta fecha |

### Que hace el script

1. Escanea recursivamente `C:\CEB_FTP_Data\SFTP\` buscando archivos nuevos
2. Ignora carpetas `processed/`
3. Ignora archivos creados antes de `$SyncAfterDate`
4. Verifica que el archivo no este bloqueado ni en transferencia
5. Sube a S3 preservando la ruta relativa con timestamp: `Boards/Board_183/20260303_102624_archivo.csv`
6. Mueve el archivo original a `processed/` en su misma carpeta
7. Limpia archivos en `processed/` con mas de 30 dias
8. Registra todo en `C:\CEB_FTP_Data\Logs\sync.log`

---

## Paso 6: Crear tarea programada (cada 5 minutos)

En PowerShell como Administrador:

```powershell
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
    -TaskName "BoardFiles-S3-Sync" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Sincroniza archivos de SFTP a S3 cada 5 minutos" `
    -Force
```

Resultado esperado:
```
TaskPath   TaskName            State
--------   --------            -----
\          BoardFiles-S3-Sync  Ready
```

---

## Paso 7: Verificacion

### Ejecutar el script manualmente

```powershell
& "C:\CEB_FTP_Data\Scripts\Sync-BoardFilesToS3.ps1"
```

### Resultado exitoso (2026-03-03)

```
[2026-03-03 10:26:14] [INFO] ==========================================
[2026-03-03 10:26:14] [INFO] Iniciando sincronizacion recursiva...
[2026-03-03 10:26:14] [INFO] Base: C:\CEB_FTP_Data\SFTP
[2026-03-03 10:26:14] [INFO] Bucket: dagster-poc-sand-bucket-7a45862
[2026-03-03 10:26:14] [INFO] ==========================================
[2026-03-03 10:26:24] [INFO] Encontrados 1 archivos nuevos (desde 03/03/2026 00:00:00)
[2026-03-03 10:26:24] [INFO] [Boards/Board_183] Procesando: test - Copy.txt (0 MB)
[2026-03-03 10:26:27] [INFO] [Boards/Board_183] Subiendo a s3://dagster-poc-sand-bucket-7a45862/Boards/Board_183/20260303_102624_test - Copy.txt
[2026-03-03 10:26:28] [INFO] [Boards/Board_183] OK: test - Copy.txt -> Boards/Board_183/20260303_102624_test - Copy.txt
[2026-03-03 10:26:28] [INFO] Completado: Exitosos=1 | Errores=0 | Omitidos=0
[2026-03-03 10:26:28] [INFO] Limpieza: \Boards\Board_183\processed\test - Copy.txt
[2026-03-03 10:26:38] [INFO] Script finalizado
```

### Revisar logs

```powershell
Get-Content "C:\CEB_FTP_Data\Logs\sync.log" -Tail 20
```

### Verificar la tarea programada

```powershell
Get-ScheduledTask -TaskName "BoardFiles-S3-Sync" | Format-List TaskName, State, Description
```

### Ver archivos en S3 (desde la EC2)

```powershell
Get-S3Object -BucketName "dagster-poc-sand-bucket-7a45862" -KeyPrefix "Boards/" -Region "us-east-1" | Select-Object Key, Size, LastModified
```

---

## Troubleshooting

| Problema | Solucion |
|----------|----------|
| `Access Denied` en Write-S3Object | Verificar IAM Role asignado a la EC2 y bucket policy |
| `Stream was not readable` en logs | Recrear el archivo log: `Remove-Item sync.log; New-Item sync.log` y usar `Out-File -Encoding utf8` en el script |
| `Write-S3Object is not recognized` | Instalar AWS PowerShell: `Install-Module -Name AWSPowerShell -Force` |
| No aparecen archivos nuevos | Verificar `$SyncAfterDate` - archivos creados antes de esa fecha son ignorados |
| Archivos no se mueven a processed/ | Verificar permisos de SYSTEM en la carpeta |
| Script no se ejecuta automaticamente | Verificar tarea: `Get-ScheduledTask -TaskName "BoardFiles-S3-Sync"` |
| `DeleteObject Access Denied` | Normal - el role solo tiene permisos de escritura, no de borrado (por diseno) |
| Necesita instalar como Admin | Abrir PowerShell con click derecho > Run as Administrator |

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

- **Fecha:** 2026-03-03
- **Implementado por:** Diego Cruz
- **Estado:** Funcionando correctamente
