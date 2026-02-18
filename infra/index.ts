import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
const environment = config.get("environment") || "dev";
const projectName = `dagster-poc-${environment}`;

// =============================================================================
// VPC - Configuración de VPC y Subnets existentes
// =============================================================================
const vpcId = config.require("vpcId");
const configSubnetIds = config.requireObject<string[]>("subnetIds");

// Security Group para Fargate
const fargateSg = new aws.ec2.SecurityGroup(`${projectName}-fargate-sg`, {
  vpcId: vpcId,
  description: "Security group para Fargate tasks",
  egress: [
    {
      protocol: "-1",
      fromPort: 0,
      toPort: 0,
      cidrBlocks: ["0.0.0.0/0"],
    },
  ],
  tags: { Name: `${projectName}-fargate-sg` },
});

// =============================================================================
// S3 Bucket (internal, Pulumi-managed)
// =============================================================================
const bucket = new aws.s3.BucketV2(`${projectName}-bucket`, {
  forceDestroy: true,
  tags: { Environment: environment },
});

// External S3 bucket used for file ingestion (not Pulumi-managed)
const externalBucketName = "data-do-ent-file-ingestion-test-landing";
const externalBucketArn = `arn:aws:s3:::${externalBucketName}`;

// =============================================================================
// DynamoDB - Ingest State Table
// =============================================================================
const ingestStateTable = new aws.dynamodb.Table(`${projectName}-ingest-state`, {
  name: `${projectName}-ingest-state`,
  billingMode: "PAY_PER_REQUEST",
  hashKey: "pk",
  rangeKey: "sk",
  attributes: [
    { name: "pk", type: "S" },
    { name: "sk", type: "S" },
    { name: "gsi1pk", type: "S" },
    { name: "gsi1sk", type: "S" },
  ],
  globalSecondaryIndexes: [
    {
      name: "gsi1",
      hashKey: "gsi1pk",
      rangeKey: "gsi1sk",
      projectionType: "ALL",
    },
  ],
  ttl: {
    attributeName: "ttl",
    enabled: true,
  },
  tags: { Environment: environment },
});

// =============================================================================
// SQS Queue
// =============================================================================
const dlq = new aws.sqs.Queue(`${projectName}-dlq`, {
  messageRetentionSeconds: 1209600, // 14 días
  tags: { Environment: environment },
});

const queue = new aws.sqs.Queue(`${projectName}-queue`, {
  visibilityTimeoutSeconds: 900, // 15 minutos para tareas largas
  messageRetentionSeconds: 86400, // 1 día
  redrivePolicy: dlq.arn.apply((arn) =>
    JSON.stringify({
      deadLetterTargetArn: arn,
      maxReceiveCount: 3,
    })
  ),
  tags: { Environment: environment },
});

// =============================================================================
// Raw SQS Queue (EventBridge Pipe source - receives raw S3 events)
// =============================================================================
const rawDlq = new aws.sqs.Queue(`${projectName}-raw-dlq`, {
  messageRetentionSeconds: 1209600, // 14 días
  tags: { Environment: environment },
});

const rawQueue = new aws.sqs.Queue(`${projectName}-raw-queue`, {
  visibilityTimeoutSeconds: 30, // Short - Pipe processes quickly
  messageRetentionSeconds: 86400, // 1 día
  redrivePolicy: rawDlq.arn.apply((arn) =>
    JSON.stringify({
      deadLetterTargetArn: arn,
      maxReceiveCount: 3,
    })
  ),
  tags: { Environment: environment },
});

// Policy: Allow S3 to send raw events to the raw queue
const rawQueuePolicy = new aws.sqs.QueuePolicy(
  `${projectName}-raw-queue-policy`,
  {
    queueUrl: rawQueue.id,
    policy: pulumi
      .all([rawQueue.arn, bucket.arn])
      .apply(([rawQueueArn, bucketArn]) =>
        JSON.stringify({
          Version: "2012-10-17",
          Statement: [
            {
              Sid: "AllowS3SendMessage",
              Effect: "Allow",
              Principal: { Service: "s3.amazonaws.com" },
              Action: "sqs:SendMessage",
              Resource: rawQueueArn,
              Condition: {
                ArnEquals: {
                  "aws:SourceArn": [bucketArn, externalBucketArn],
                },
              },
            },
          ],
        })
      ),
  }
);

// Policy: Allow EventBridge Pipes to send enriched messages to the existing queue
const queuePolicy = new aws.sqs.QueuePolicy(`${projectName}-queue-policy`, {
  queueUrl: queue.id,
  policy: queue.arn.apply((queueArn) =>
    JSON.stringify({
      Version: "2012-10-17",
      Statement: [
        {
          Sid: "AllowPipeSendMessage",
          Effect: "Allow",
          Principal: { Service: "pipes.amazonaws.com" },
          Action: "sqs:SendMessage",
          Resource: queueArn,
        },
      ],
    })
  ),
});

// S3 → raw SQS notification (internal bucket)
new aws.s3.BucketNotification(
  `${projectName}-bucket-notification`,
  {
    bucket: bucket.id,
    queues: [
      {
        queueArn: rawQueue.arn,
        events: ["s3:ObjectCreated:*"],
      },
    ],
  },
  { dependsOn: [rawQueuePolicy] }
);

// S3 → raw SQS notification (external bucket)
new aws.s3.BucketNotification(
  `${projectName}-external-bucket-notification`,
  {
    bucket: externalBucketName,
    queues: [
      {
        queueArn: rawQueue.arn,
        events: ["s3:ObjectCreated:*"],
      },
    ],
  },
  { dependsOn: [rawQueuePolicy] }
);

// =============================================================================
// ECR Repository para el Worker
// =============================================================================
const workerRepo = new aws.ecr.Repository(`${projectName}-worker`, {
  name: `${projectName}-worker`,
  forceDelete: true,
  imageScanningConfiguration: {
    scanOnPush: true,
  },
  tags: { Environment: environment },
});

// =============================================================================
// ECS Cluster
// =============================================================================
const cluster = new aws.ecs.Cluster(`${projectName}-cluster`, {
  settings: [
    {
      name: "containerInsights",
      value: "enabled",
    },
  ],
  tags: { Environment: environment },
});

// =============================================================================
// IAM Roles
// =============================================================================

// Task Execution Role
const taskExecutionRole = new aws.iam.Role(
  `${projectName}-task-execution-role`,
  {
    assumeRolePolicy: JSON.stringify({
      Version: "2012-10-17",
      Statement: [
        {
          Action: "sts:AssumeRole",
          Principal: { Service: "ecs-tasks.amazonaws.com" },
          Effect: "Allow",
        },
      ],
    }),
  }
);

new aws.iam.RolePolicyAttachment(`${projectName}-task-execution-policy`, {
  role: taskExecutionRole.name,
  policyArn:
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
});

// Task Role con permisos completos
const taskRole = new aws.iam.Role(`${projectName}-task-role`, {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [
      {
        Action: "sts:AssumeRole",
        Principal: { Service: "ecs-tasks.amazonaws.com" },
        Effect: "Allow",
      },
    ],
  }),
});

// Permisos para S3 (both buckets), DynamoDB y Dagster Pipes (CloudWatch)
new aws.iam.RolePolicy(`${projectName}-task-policy`, {
  role: taskRole.id,
  policy: pulumi
    .all([bucket.arn, ingestStateTable.arn])
    .apply(([bucketArn, tableArn]: [string, string]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Action: [
              "s3:GetObject",
              "s3:PutObject",
              "s3:ListBucket",
              "s3:HeadObject",
            ],
            Resource: [
              bucketArn,
              `${bucketArn}/*`,
              externalBucketArn,
              `${externalBucketArn}/*`,
            ],
          },
          {
            Effect: "Allow",
            Action: [
              "dynamodb:GetItem",
              "dynamodb:PutItem",
              "dynamodb:UpdateItem",
              "dynamodb:Query",
            ],
            Resource: [tableArn, `${tableArn}/index/*`],
          },
          {
            // Dagster Pipes - CloudWatch Logs
            Effect: "Allow",
            Action: [
              "logs:CreateLogStream",
              "logs:PutLogEvents",
              "logs:DescribeLogStreams",
            ],
            Resource: "*",
          },
        ],
      })
    ),
});

// =============================================================================
// CloudWatch Log Group
// =============================================================================
const logGroup = new aws.cloudwatch.LogGroup(`${projectName}-logs`, {
  retentionInDays: 14,
  tags: { Environment: environment },
});

// =============================================================================
// ECS Task Definitions - Multiple sizes for dynamic scaling
// =============================================================================
const region = aws.getRegion();

// Configuraciones de recursos por tamaño de archivo
const taskConfigs = {
  small: { cpu: "256", memory: "512" }, // < 50 MB
  medium: { cpu: "512", memory: "1024" }, // 50-200 MB
  large: { cpu: "1024", memory: "2048" }, // 200-500 MB
  xlarge: { cpu: "2048", memory: "4096" }, // > 500 MB
};

// Crear task definitions para cada tamaño
const taskDefinitions: Record<string, aws.ecs.TaskDefinition> = {};

for (const [size, resources] of Object.entries(taskConfigs)) {
  taskDefinitions[size] = new aws.ecs.TaskDefinition(
    `${projectName}-task-${size}`,
    {
      family: `${projectName}-task-${size}`,
      networkMode: "awsvpc",
      requiresCompatibilities: ["FARGATE"],
      cpu: resources.cpu,
      memory: resources.memory,
      executionRoleArn: taskExecutionRole.arn,
      taskRoleArn: taskRole.arn,
      containerDefinitions: pulumi
        .all([
          logGroup.name,
          bucket.id,
          ingestStateTable.name,
          region,
          workerRepo.repositoryUrl,
        ])
        .apply(
          ([logGroupName, bucketName, tableName, regionData, repoUrl]: [
            string,
            string,
            string,
            aws.GetRegionResult,
            string,
          ]) =>
            JSON.stringify([
              {
                name: "worker",
                image: `${repoUrl}:latest`,
                essential: true,
                environment: [
                  { name: "BUCKET_NAME", value: bucketName },
                  { name: "DYNAMO_TABLE", value: tableName },
                  { name: "AWS_REGION", value: regionData.name },
                  { name: "TASK_SIZE", value: size },
                  { name: "CHUNK_SIZE_MB", value: size === "small" ? "5" : size === "medium" ? "10" : "20" },
                ],
                logConfiguration: {
                  logDriver: "awslogs",
                  options: {
                    "awslogs-group": logGroupName,
                    "awslogs-region": regionData.name,
                    "awslogs-stream-prefix": `worker-${size}`,
                  },
                },
              },
            ])
        ),
      tags: { Environment: environment, Size: size },
    }
  );
}

// =============================================================================
// SFTP Windows Server - Automatización CE Broker
// =============================================================================

// Secreto para la contraseña del usuario SFTP (BoardUser)
const sftpUserPassword = new aws.secretsmanager.Secret(
  `${projectName}-sftp-password`,
  {
    name: `${projectName}/sftp/board-user-password`,
    description: "Contraseña para el usuario BoardUser del servidor SFTP",
    tags: { Environment: environment },
  }
);

// Generar una contraseña aleatoria y almacenarla en el secreto
const sftpPasswordValue = new aws.secretsmanager.SecretVersion(
  `${projectName}-sftp-password-value`,
  {
    secretId: sftpUserPassword.id,
    secretString: pulumi
      .output(
        JSON.stringify({
          username: "BoardUser",
          password: `SftpP@ss${Math.random().toString(36).slice(2, 10)}!2024`,
        })
      )
      .apply((s) => s),
  }
);

// IAM Role para EC2 con permisos de mínimo privilegio
const sftpEc2Role = new aws.iam.Role(`${projectName}-sftp-ec2-role`, {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [
      {
        Action: "sts:AssumeRole",
        Principal: { Service: "ec2.amazonaws.com" },
        Effect: "Allow",
      },
    ],
  }),
  tags: { Environment: environment },
});

// Política de mínimo privilegio: leer secreto + escribir en S3
new aws.iam.RolePolicy(`${projectName}-sftp-ec2-policy`, {
  role: sftpEc2Role.id,
  policy: pulumi
    .all([sftpUserPassword.arn])
    .apply(([secretArn]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "ReadSftpSecret",
            Effect: "Allow",
            Action: ["secretsmanager:GetSecretValue"],
            Resource: secretArn,
          },
          {
            Sid: "WriteToS3LandingBucket",
            Effect: "Allow",
            Action: ["s3:PutObject", "s3:PutObjectAcl"],
            Resource: "arn:aws:s3:::data-do-ent-file-ingestion-test-landing/*",
          },
          {
            Sid: "ListS3LandingBucket",
            Effect: "Allow",
            Action: ["s3:ListBucket"],
            Resource: "arn:aws:s3:::data-do-ent-file-ingestion-test-landing",
          },
        ],
      })
    ),
});

// Adjuntar política de SSM para Session Manager
new aws.iam.RolePolicyAttachment(`${projectName}-sftp-ssm-policy`, {
  role: sftpEc2Role.name,
  policyArn: "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
});

// Instance Profile para EC2
const sftpInstanceProfile = new aws.iam.InstanceProfile(
  `${projectName}-sftp-instance-profile`,
  {
    role: sftpEc2Role.name,
  }
);

// Security Group para el servidor SFTP
const sftpSg = new aws.ec2.SecurityGroup(`${projectName}-sftp-sg`, {
  vpcId: vpcId,
  description: "Security group para servidor SFTP Windows",
  ingress: [
    {
      description: "SFTP/SSH",
      protocol: "tcp",
      fromPort: 22,
      toPort: 22,
      cidrBlocks: ["0.0.0.0/0"], // TODO: Restringir a IPs conocidas en producción
    },
    {
      description: "RDP for administration",
      protocol: "tcp",
      fromPort: 3389,
      toPort: 3389,
      cidrBlocks: ["0.0.0.0/0"], // TODO: Restringir a IPs conocidas en producción
    },
  ],
  egress: [
    {
      protocol: "-1",
      fromPort: 0,
      toPort: 0,
      cidrBlocks: ["0.0.0.0/0"],
    },
  ],
  tags: { Name: `${projectName}-sftp-sg` },
});

// AMI de Windows Server 2022
const windowsAmi = aws.ec2.getAmi({
  mostRecent: true,
  owners: ["amazon"],
  filters: [
    {
      name: "name",
      values: ["Windows_Server-2022-English-Full-Base-*"],
    },
    {
      name: "virtualization-type",
      values: ["hvm"],
    },
  ],
});

// Función helper para generar el script PowerShell de User Data
function generateUserData(
  secretName: string,
  regionName: string
): string {
  // Script de sincronización (se guarda como archivo separado en la instancia)
  const syncScriptContent = `
# =============================================================================
# Sync-BoardFilesToS3.ps1 - CE Broker Board Files Sync Script
# =============================================================================

\\$ErrorActionPreference = "Continue"
\\$LandingPath = "C:\\\\SFTP\\\\BoardFiles\\\\Landing"
\\$ArchivePath = "C:\\\\SFTP\\\\BoardFiles\\\\Archive"
\\$LogPath = "C:\\\\SFTP\\\\Logs\\\\sync.log"
\\$BucketName = "data-do-ent-file-ingestion-test-landing"
\\$S3Prefix = ""
\\$AwsRegion = "${regionName}"

function Write-SyncLog {
    param([string]\\$Message, [string]\\$Level = "INFO")
    \\$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    \\$logMessage = "[\\$timestamp] [\\$Level] \\$Message"
    Add-Content -Path \\$LogPath -Value \\$logMessage -Force
    \\$source = "BoardFileSync"
    if (-not [System.Diagnostics.EventLog]::SourceExists(\\$source)) {
        New-EventLog -LogName Application -Source \\$source -ErrorAction SilentlyContinue
    }
    \\$eventType = switch (\\$Level) {
        "ERROR" { "Error" }
        "WARN"  { "Warning" }
        default { "Information" }
    }
    Write-EventLog -LogName Application -Source \\$source -EventId 1000 -EntryType \\$eventType -Message \\$Message -ErrorAction SilentlyContinue
}

function Test-FileNotLocked {
    param([string]\\$FilePath)
    try {
        \\$fileStream = [System.IO.File]::Open(\\$FilePath, 'Open', 'Read', 'None')
        \\$fileStream.Close()
        \\$fileStream.Dispose()
        return \\$true
    } catch {
        return \\$false
    }
}

function Get-FileStableSize {
    param([string]\\$FilePath, [int]\\$WaitSeconds = 5)
    \\$size1 = (Get-Item \\$FilePath).Length
    Start-Sleep -Seconds \\$WaitSeconds
    \\$size2 = (Get-Item \\$FilePath).Length
    return \\$size1 -eq \\$size2
}

Write-SyncLog "Iniciando sincronizacion de archivos..."
\\$files = Get-ChildItem -Path \\$LandingPath -File -ErrorAction SilentlyContinue

if (\\$files.Count -eq 0) {
    Write-SyncLog "No hay archivos nuevos para procesar"
    exit 0
}

Write-SyncLog "Encontrados \\$(\\$files.Count) archivos para procesar"
\\$successCount = 0
\\$errorCount = 0

foreach (\\$file in \\$files) {
    \\$filePath = \\$file.FullName
    \\$fileName = \\$file.Name
    Write-SyncLog "Procesando: \\$fileName"

    if (-not (Test-FileNotLocked -FilePath \\$filePath)) {
        Write-SyncLog "Archivo bloqueado, omitiendo: \\$fileName" -Level "WARN"
        continue
    }

    if (-not (Get-FileStableSize -FilePath \\$filePath -WaitSeconds 3)) {
        Write-SyncLog "Archivo aun en transferencia, omitiendo: \\$fileName" -Level "WARN"
        continue
    }

    try {
        \\$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        if ([string]::IsNullOrEmpty(\\$S3Prefix)) {
            \\$s3Key = "\\$timestamp" + "_" + "\\$fileName"
        } else {
            \\$s3Key = "\\$S3Prefix/" + "\\$timestamp" + "_" + "\\$fileName"
        }
        Write-SyncLog "Subiendo a s3://\\$BucketName/\\$s3Key"
        Write-S3Object -BucketName \\$BucketName -File \\$filePath -Key \\$s3Key -Region \\$AwsRegion
        \\$archiveFileName = (Get-Date -Format 'yyyyMMdd_HHmmss') + "_" + \\$fileName
        \\$archiveDest = Join-Path \\$ArchivePath \\$archiveFileName
        Move-Item -Path \\$filePath -Destination \\$archiveDest -Force
        Write-SyncLog "Archivo procesado exitosamente: \\$fileName -> \\$s3Key"
        \\$successCount++
    } catch {
        Write-SyncLog "Error procesando \\$fileName : \\$(\\$_.Exception.Message)" -Level "ERROR"
        \\$errorCount++
    }
}

Write-SyncLog "Sincronizacion completada. Exitosos: \\$successCount, Errores: \\$errorCount"

\\$cutoffDate = (Get-Date).AddDays(-30)
Get-ChildItem -Path \\$ArchivePath -File | Where-Object { \\$_.LastWriteTime -lt \\$cutoffDate } | ForEach-Object {
    Write-SyncLog "Eliminando archivo antiguo de archive: \\$(\\$_.Name)"
    Remove-Item \\$_.FullName -Force
}
`.trim();

  return `<powershell>
# =============================================================================
# SFTP Windows Server Setup Script - CE Broker Board Files
# =============================================================================

\\$ErrorActionPreference = "Stop"
\\$LogFile = "C:\\\\SFTP\\\\Logs\\\\setup.log"

function Write-Log {
    param([string]\\$Message)
    \\$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    \\$logMessage = "[\\$timestamp] \\$Message"
    Add-Content -Path \\$LogFile -Value \\$logMessage -Force
    Write-Host \\$logMessage
}

# Crear estructura de carpetas
New-Item -ItemType Directory -Path "C:\\\\SFTP\\\\BoardFiles\\\\Landing" -Force
New-Item -ItemType Directory -Path "C:\\\\SFTP\\\\BoardFiles\\\\Archive" -Force
New-Item -ItemType Directory -Path "C:\\\\SFTP\\\\Scripts" -Force
New-Item -ItemType Directory -Path "C:\\\\SFTP\\\\Logs" -Force

Write-Log "Estructura de carpetas creada"

# -----------------------------------------------------------------------------
# Instalar y configurar OpenSSH Server
# -----------------------------------------------------------------------------
Write-Log "Instalando OpenSSH Server..."

Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue

Write-Log "OpenSSH Server instalado y configurado"

# -----------------------------------------------------------------------------
# Recuperar contrasena desde Secrets Manager
# -----------------------------------------------------------------------------
Write-Log "Recuperando credenciales desde Secrets Manager..."

\\$secretValue = Get-SECSecretValue -SecretId "${secretName}" -Region "${regionName}"
\\$secretJson = \\$secretValue.SecretString | ConvertFrom-Json
\\$sftpPassword = \\$secretJson.password

Write-Log "Credenciales recuperadas exitosamente"

# -----------------------------------------------------------------------------
# Crear usuario SFTP (BoardUser)
# -----------------------------------------------------------------------------
Write-Log "Creando usuario BoardUser..."

\\$securePassword = ConvertTo-SecureString \\$sftpPassword -AsPlainText -Force
New-LocalUser -Name "BoardUser" -Password \\$securePassword -FullName "Board Files User" -Description "Usuario SFTP para archivos de juntas" -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Users" -Member "BoardUser" -ErrorAction SilentlyContinue

Write-Log "Usuario BoardUser creado"

# -----------------------------------------------------------------------------
# Configurar SFTP chroot para BoardUser
# -----------------------------------------------------------------------------
Write-Log "Configurando SFTP chroot..."

\\$sshdConfig = @"

# SFTP Configuration for BoardUser
Match User BoardUser
    ChrootDirectory C:\\\\SFTP\\\\BoardFiles
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
"@

Add-Content -Path "C:\\\\ProgramData\\\\ssh\\\\sshd_config" -Value \\$sshdConfig

# Configurar permisos de carpeta
\\$acl = Get-Acl "C:\\\\SFTP\\\\BoardFiles"
\\$acl.SetAccessRuleProtection(\\$true, \\$false)

\\$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\\\\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
\\$acl.AddAccessRule(\\$adminRule)

\\$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\\\\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
\\$acl.AddAccessRule(\\$systemRule)

\\$userRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BoardUser", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
\\$acl.AddAccessRule(\\$userRule)

Set-Acl -Path "C:\\\\SFTP\\\\BoardFiles" \\$acl
Restart-Service sshd

Write-Log "SFTP chroot configurado"

# -----------------------------------------------------------------------------
# Script de Sincronizacion a S3
# -----------------------------------------------------------------------------
Write-Log "Creando script de sincronizacion..."

\\$syncScriptContent = @'
${syncScriptContent}
'@

Set-Content -Path "C:\\\\SFTP\\\\Scripts\\\\Sync-BoardFilesToS3.ps1" -Value \\$syncScriptContent -Force

Write-Log "Script de sincronizacion creado"

# -----------------------------------------------------------------------------
# Crear Tarea Programada de Windows (cada 5 minutos)
# -----------------------------------------------------------------------------
Write-Log "Creando tarea programada..."

\\$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\\\\SFTP\\\\Scripts\\\\Sync-BoardFilesToS3.ps1"
\\$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 9999)
\\$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
\\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable

Register-ScheduledTask -TaskName "BoardFiles-S3-Sync" -Action \\$action -Trigger \\$trigger -Principal \\$principal -Settings \\$settings -Description "Sincroniza archivos de Board Files a S3 cada 5 minutos" -Force

Write-Log "Tarea programada creada: BoardFiles-S3-Sync"

# Registrar Event Source para logs
if (-not [System.Diagnostics.EventLog]::SourceExists("BoardFileSync")) {
    New-EventLog -LogName Application -Source "BoardFileSync"
}

Write-Log "============================================="
Write-Log "Setup completado exitosamente!"
Write-Log "- Usuario SFTP: BoardUser"
Write-Log "- Carpeta Landing: C:\\\\SFTP\\\\BoardFiles\\\\Landing"
Write-Log "- Carpeta Archive: C:\\\\SFTP\\\\BoardFiles\\\\Archive"
Write-Log "- Script de sync: C:\\\\SFTP\\\\Scripts\\\\Sync-BoardFilesToS3.ps1"
Write-Log "- Tarea programada: BoardFiles-S3-Sync (cada 5 min)"
Write-Log "- Bucket S3: data-do-ent-file-ingestion-test-curated/inbound/cebroker/"
Write-Log "============================================="

</powershell>
<persist>true</persist>`;
}

// User Data - PowerShell Script completo
const userData = pulumi
  .all([sftpUserPassword.name, region])
  .apply(
    ([secretName, regionData]: [
      string,
      aws.GetRegionResult,
    ]) => generateUserData(secretName, regionData.name)
  );

// Instancia EC2 Windows Server 2022
const sftpInstance = new aws.ec2.Instance(`${projectName}-sftp-server`, {
  ami: windowsAmi.then((ami) => ami.id),
  instanceType: "t3.medium",
  subnetId: configSubnetIds[0],
  vpcSecurityGroupIds: [sftpSg.id],
  iamInstanceProfile: sftpInstanceProfile.name,
  userData: userData,
  userDataReplaceOnChange: true,
  rootBlockDevice: {
    volumeSize: 50,
    volumeType: "gp3",
    encrypted: true,
  },
  metadataOptions: {
    httpEndpoint: "enabled",
    httpTokens: "required", // IMDSv2 obligatorio
  },
  tags: {
    Name: `${projectName}-sftp-server`,
    Environment: environment,
    Purpose: "SFTP-to-S3-Gateway",
  },
});

// =============================================================================
// Lambda - Worker for small files (< 50 MB)
// =============================================================================

// Lambda Execution Role
const lambdaRole = new aws.iam.Role(`${projectName}-lambda-role`, {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [
      {
        Action: "sts:AssumeRole",
        Principal: { Service: "lambda.amazonaws.com" },
        Effect: "Allow",
      },
    ],
  }),
  tags: { Environment: environment },
});

// Basic Lambda execution policy (CloudWatch Logs)
new aws.iam.RolePolicyAttachment(`${projectName}-lambda-basic-policy`, {
  role: lambdaRole.name,
  policyArn:
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
});

// Lambda permissions: S3 (both buckets) + DynamoDB
new aws.iam.RolePolicy(`${projectName}-lambda-policy`, {
  role: lambdaRole.id,
  policy: pulumi
    .all([bucket.arn, ingestStateTable.arn])
    .apply(([bucketArn, tableArn]: [string, string]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Action: [
              "s3:GetObject",
              "s3:PutObject",
              "s3:ListBucket",
              "s3:HeadObject",
            ],
            Resource: [
              bucketArn,
              `${bucketArn}/*`,
              externalBucketArn,
              `${externalBucketArn}/*`,
            ],
          },
          {
            Effect: "Allow",
            Action: [
              "dynamodb:GetItem",
              "dynamodb:PutItem",
              "dynamodb:UpdateItem",
              "dynamodb:Query",
            ],
            Resource: [tableArn, `${tableArn}/index/*`],
          },
        ],
      })
    ),
});

// Lambda Function for small file processing
const workerLambda = new aws.lambda.Function(`${projectName}-worker-lambda`, {
  runtime: "nodejs20.x",
  handler: "lambda-handler.handler",
  role: lambdaRole.arn,
  timeout: 300, // 5 minutes
  memorySize: 512, // 512 MB for files up to 50 MB
  code: new pulumi.asset.AssetArchive({
    ".": new pulumi.asset.FileArchive("../worker/dist"),
  }),
  environment: {
    variables: ingestStateTable.name.apply((tableName) => ({
      DYNAMO_TABLE: tableName,
      TASK_SIZE: "lambda",
    })),
  },
  tags: { Environment: environment },
});

// CloudWatch Log Group for Lambda (explicit for retention control)
const lambdaLogGroup = new aws.cloudwatch.LogGroup(
  `${projectName}-lambda-logs`,
  {
    name: pulumi.interpolate`/aws/lambda/${workerLambda.name}`,
    retentionInDays: 14,
    tags: { Environment: environment },
  }
);

// =============================================================================
// Enrichment Lambda - EventBridge Pipe enrichment step
// =============================================================================
const enrichmentLambdaRole = new aws.iam.Role(
  `${projectName}-enrichment-lambda-role`,
  {
    assumeRolePolicy: JSON.stringify({
      Version: "2012-10-17",
      Statement: [
        {
          Action: "sts:AssumeRole",
          Principal: { Service: "lambda.amazonaws.com" },
          Effect: "Allow",
        },
      ],
    }),
    tags: { Environment: environment },
  }
);

new aws.iam.RolePolicyAttachment(
  `${projectName}-enrichment-lambda-basic-policy`,
  {
    role: enrichmentLambdaRole.name,
    policyArn:
      "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
  }
);

new aws.iam.RolePolicy(`${projectName}-enrichment-lambda-policy`, {
  role: enrichmentLambdaRole.id,
  policy: pulumi
    .all([ingestStateTable.arn, bucket.arn])
    .apply(([tableArn, bucketArn]: [string, string]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Action: ["dynamodb:GetItem", "dynamodb:Query"],
            Resource: [tableArn, `${tableArn}/index/*`],
          },
          {
            Effect: "Allow",
            Action: ["s3:GetObject", "s3:HeadObject"],
            Resource: [
              `${bucketArn}/*`,
              `${externalBucketArn}/*`,
            ],
          },
        ],
      })
    ),
});

const enrichmentLambda = new aws.lambda.Function(
  `${projectName}-enrichment-lambda`,
  {
    runtime: "nodejs20.x",
    handler: "enrichment-handler.handler",
    role: enrichmentLambdaRole.arn,
    timeout: 60, // Increased for S3 validation
    memorySize: 256, // Increased for file parsing
    code: new pulumi.asset.AssetArchive({
      ".": new pulumi.asset.FileArchive("../worker/dist"),
    }),
    environment: {
      variables: ingestStateTable.name.apply((tableName) => ({
        DYNAMO_TABLE: tableName,
      })),
    },
    tags: { Environment: environment },
  }
);

const enrichmentLambdaLogGroup = new aws.cloudwatch.LogGroup(
  `${projectName}-enrichment-lambda-logs`,
  {
    name: pulumi.interpolate`/aws/lambda/${enrichmentLambda.name}`,
    retentionInDays: 14,
    tags: { Environment: environment },
  }
);

// =============================================================================
// EventBridge Pipe - Intelligent Gatekeeper
// =============================================================================
const pipeRole = new aws.iam.Role(`${projectName}-pipe-role`, {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [
      {
        Action: "sts:AssumeRole",
        Principal: { Service: "pipes.amazonaws.com" },
        Effect: "Allow",
      },
    ],
  }),
  tags: { Environment: environment },
});

new aws.iam.RolePolicy(`${projectName}-pipe-policy`, {
  role: pipeRole.id,
  policy: pulumi
    .all([rawQueue.arn, queue.arn, enrichmentLambda.arn])
    .apply(([rawQueueArn, queueArn, enrichmentLambdaArn]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "SourceSQSPermissions",
            Effect: "Allow",
            Action: [
              "sqs:ReceiveMessage",
              "sqs:DeleteMessage",
              "sqs:GetQueueAttributes",
            ],
            Resource: rawQueueArn,
          },
          {
            Sid: "EnrichmentLambdaPermissions",
            Effect: "Allow",
            Action: "lambda:InvokeFunction",
            Resource: enrichmentLambdaArn,
          },
          {
            Sid: "TargetSQSPermissions",
            Effect: "Allow",
            Action: "sqs:SendMessage",
            Resource: queueArn,
          },
        ],
      })
    ),
});

const gatekeeperPipe = new aws.pipes.Pipe(
  `${projectName}-gatekeeper-pipe`,
  {
    name: `${projectName}-gatekeeper-pipe`,
    roleArn: pipeRole.arn,
    source: rawQueue.arn,
    target: queue.arn,
    description:
      "Intelligent Gatekeeper: filters and enriches S3 events before Dagster processing",
    desiredState: "RUNNING",

    sourceParameters: {
      sqsQueueParameters: {
        batchSize: 10,
        maximumBatchingWindowInSeconds: 5,
      },
    },

    enrichment: enrichmentLambda.arn,
    enrichmentParameters: {
      inputTemplate: '{"s3_event": <$.body>}',
    },

    tags: { Environment: environment },
  },
  { dependsOn: [rawQueuePolicy, queuePolicy] }
);

// =============================================================================
// Outputs
// =============================================================================
export const bucketName = bucket.id;
export const bucketArn = bucket.arn;
export const queueUrl = queue.url;
export const queueArn = queue.arn;
export const clusterName = cluster.name;
export const clusterArn = cluster.arn;
export const fargateSecurityGroupId = fargateSg.id;
export const subnetIds = configSubnetIds;
export const dynamoTableName = ingestStateTable.name;
export const dynamoTableArn = ingestStateTable.arn;
export const workerRepoUrl = workerRepo.repositoryUrl;
export const workerRepoArn = workerRepo.arn;
export const logGroupName = logGroup.name;

// Task Definition ARNs por tamaño
export const taskDefinitionArns = {
  small: taskDefinitions.small.arn,
  medium: taskDefinitions.medium.arn,
  large: taskDefinitions.large.arn,
  xlarge: taskDefinitions.xlarge.arn,
};

// Task Definition families por tamaño (para Dagster Pipes)
export const taskDefinitionFamilies = {
  small: `${projectName}-task-small`,
  medium: `${projectName}-task-medium`,
  large: `${projectName}-task-large`,
  xlarge: `${projectName}-task-xlarge`,
};

// Lambda Outputs
export const lambdaFunctionName = workerLambda.name;
export const lambdaFunctionArn = workerLambda.arn;
export const lambdaLogGroupName = lambdaLogGroup.name;

// SFTP Server Outputs
export const sftpServerInstanceId = sftpInstance.id;
export const sftpServerPublicIp = sftpInstance.publicIp;
export const sftpServerPrivateIp = sftpInstance.privateIp;
export const sftpSecurityGroupId = sftpSg.id;
export const sftpPasswordSecretArn = sftpUserPassword.arn;
export const sftpPasswordSecretName = sftpUserPassword.name;

// Gatekeeper Pipe Outputs
export const rawQueueUrl = rawQueue.url;
export const rawQueueArn = rawQueue.arn;
export const enrichmentLambdaFunctionName = enrichmentLambda.name;
export const enrichmentLambdaFunctionArn = enrichmentLambda.arn;
export const gatekeeperPipeArn = gatekeeperPipe.arn;
