# Guía de Instalación: SFTP to S3 Sync

Esta guía explica cómo instalar el script de sincronización de archivos SFTP a S3 en cualquier máquina Windows existente.

## Requisitos Previos

- Windows Server 2016+ o Windows 10/11
- PowerShell 5.1 o superior
- Acceso a Internet
- Permisos de Administrador
- Credenciales de AWS con permisos para escribir en S3

---

## Paso 1: Conectarse a la Máquina

Conéctate a la máquina Windows usando:
- **RDP** (Remote Desktop)
- **SSM Session Manager** (si es EC2 en AWS)
- **Acceso físico/consola**

---

## Paso 2: Abrir PowerShell como Administrador

1. Presiona `Win + X`
2. Selecciona **"Windows PowerShell (Admin)"** o **"Terminal (Admin)"**
3. Confirma el prompt de UAC si aparece

---

## Paso 3: Instalar el Módulo de AWS PowerShell

```powershell
# Primero instalar el proveedor NuGet (requerido para instalar módulos)
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
# Configurar credenciales permanentes
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
# Crear todas las carpetas necesarias
New-Item -Path "C:\SFTP\BoardFiles\Landing" -ItemType Directory -Force
New-Item -Path "C:\SFTP\BoardFiles\Archive" -ItemType Directory -Force
New-Item -Path "C:\SFTP\Scripts" -ItemType Directory -Force
New-Item -Path "C:\SFTP\Logs" -ItemType Directory -Force

# Verificar que se crearon
Get-ChildItem "C:\SFTP" -Recurse | Select-Object FullName
```

---

## Paso 6: Copiar el Script de Sincronización

### Opción A: Copiar desde este repositorio

Copia el archivo `Sync-BoardFilesToS3.ps1` a `C:\SFTP\Scripts\`

### Opción B: Crear manualmente

```powershell
# Descargar el script desde el repositorio (si está disponible)
# O copiarlo manualmente desde este repositorio

# Verificar que existe
Test-Path "C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"
```

---

## Paso 7: Configurar el Script

Edita el script `C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1` y modifica estas variables:

```powershell
# Línea ~15: Cambiar por tu bucket
$BucketName = "TU-BUCKET-NAME"

# Línea ~16: Cambiar el prefijo si es necesario
$S3Prefix = "inbound/cebroker"

# Línea ~17: Cambiar la región si es diferente
$AwsRegion = "us-east-1"
```

Para editar:
```powershell
notepad "C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"
```

---

## Paso 8: Probar el Script Manualmente

```powershell
# Crear un archivo de prueba
"Archivo de prueba" | Out-File "C:\SFTP\BoardFiles\Landing\test-file.txt"

# Ejecutar el script
& "C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"

# Verificar el log
Get-Content "C:\SFTP\Logs\sync.log" -Tail 20

# Verificar que el archivo se movió a Archive
Get-ChildItem "C:\SFTP\BoardFiles\Archive"

# Verificar que el archivo llegó a S3
Get-S3Object -BucketName "TU-BUCKET-NAME" -KeyPrefix "inbound/cebroker"
```

---

## Paso 9: Crear la Tarea Programada

```powershell
# Crear la acción (ejecutar PowerShell con el script)
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\SFTP\Scripts\Sync-BoardFilesToS3.ps1"

# Crear el trigger (cada 5 minutos, indefinidamente)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

# Configuración de la tarea
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

# Registrar la tarea (ejecutar como SYSTEM)
Register-ScheduledTask `
    -TaskName "SyncBoardFilesToS3" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -User "SYSTEM" `
    -RunLevel Highest `
    -Force

# Verificar que se creó
Get-ScheduledTask -TaskName "SyncBoardFilesToS3"
```

---

## Paso 10: Verificar que Todo Funciona

```powershell
# Ver el estado de la tarea
Get-ScheduledTask -TaskName "SyncBoardFilesToS3" | Select-Object TaskName, State

# Ejecutar la tarea manualmente
Start-ScheduledTask -TaskName "SyncBoardFilesToS3"

# Ver los últimos logs
Get-Content "C:\SFTP\Logs\sync.log" -Tail 30

# Ver el historial de ejecución de la tarea
Get-ScheduledTaskInfo -TaskName "SyncBoardFilesToS3"
```

---

## Comandos Útiles para Troubleshooting

### Ver logs en tiempo real
```powershell
Get-Content "C:\SFTP\Logs\sync.log" -Wait -Tail 10
```

### Verificar archivos en Landing
```powershell
Get-ChildItem "C:\SFTP\BoardFiles\Landing"
```

### Verificar archivos en Archive
```powershell
Get-ChildItem "C:\SFTP\BoardFiles\Archive" | Sort-Object LastWriteTime -Descending | Select-Object -First 10
```

### Ver objetos en S3
```powershell
Get-S3Object -BucketName "TU-BUCKET-NAME" -KeyPrefix "inbound/cebroker" |
    Sort-Object LastModified -Descending |
    Select-Object -First 10 Key, Size, LastModified
```

### Detener la tarea programada
```powershell
Stop-ScheduledTask -TaskName "SyncBoardFilesToS3"
```

### Eliminar la tarea programada
```powershell
Unregister-ScheduledTask -TaskName "SyncBoardFilesToS3" -Confirm:$false
```

### Ver Event Logs relacionados
```powershell
Get-EventLog -LogName Application -Source "BoardFileSync" -Newest 20
```

---

## Estructura Final

Después de la instalación, deberías tener:

```
C:\SFTP\
├── BoardFiles\
│   ├── Landing\      ← Los archivos SFTP llegan aquí
│   └── Archive\      ← Los archivos procesados se mueven aquí
├── Scripts\
│   └── Sync-BoardFilesToS3.ps1
└── Logs\
    └── sync.log      ← Log de ejecución
```

---

## Notas Importantes

1. **Permisos de S3**: El usuario/role de AWS debe tener permisos `s3:PutObject` en el bucket destino.

2. **Archivos en transferencia**: El script detecta automáticamente si un archivo está siendo transferido (comparando tamaño) y lo omite hasta la siguiente ejecución.

3. **Archivos bloqueados**: Los archivos abiertos por otras aplicaciones se omiten automáticamente.

4. **Limpieza automática**: Los archivos en Archive con más de 30 días se eliminan automáticamente.

5. **Logs**: Revisa `C:\SFTP\Logs\sync.log` para diagnóstico de problemas.

6. **Frecuencia**: La tarea se ejecuta cada 5 minutos. Puedes modificar el intervalo en la tarea programada.
