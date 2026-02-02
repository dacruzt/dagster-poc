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
// S3 Bucket
// =============================================================================
const bucket = new aws.s3.BucketV2(`${projectName}-bucket`, {
  forceDestroy: true,
  tags: { Environment: environment },
});

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

// Policy para que S3 pueda enviar mensajes a SQS
const queuePolicy = new aws.sqs.QueuePolicy(`${projectName}-queue-policy`, {
  queueUrl: queue.id,
  policy: pulumi
    .all([queue.arn, bucket.arn])
    .apply(([queueArn, bucketArn]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Principal: { Service: "s3.amazonaws.com" },
            Action: "sqs:SendMessage",
            Resource: queueArn,
            Condition: { ArnEquals: { "aws:SourceArn": bucketArn } },
          },
        ],
      })
    ),
});

// S3 → SQS notification
new aws.s3.BucketNotification(
  `${projectName}-bucket-notification`,
  {
    bucket: bucket.id,
    queues: [
      {
        queueArn: queue.arn,
        events: ["s3:ObjectCreated:*"],
      },
    ],
  },
  { dependsOn: [queuePolicy] }
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

// Permisos para S3, DynamoDB y Dagster Pipes (CloudWatch)
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
            Resource: [bucketArn, `${bucketArn}/*`],
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
