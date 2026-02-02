import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
const environment = config.get("environment") || "dev";
const projectName = `dagster-poc-${environment}`;

// =============================================================================
// VPC - Usar default VPC para el POC
// =============================================================================
const defaultVpc = aws.ec2.getVpc({ default: true });
const defaultSubnets = defaultVpc.then((vpc) =>
  aws.ec2.getSubnets({
    filters: [{ name: "vpc-id", values: [vpc.id] }],
  })
);

// Security Group para Fargate
const fargateSg = new aws.ec2.SecurityGroup(`${projectName}-fargate-sg`, {
  vpcId: defaultVpc.then((vpc) => vpc.id),
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
// SQS Queue
// =============================================================================
const dlq = new aws.sqs.Queue(`${projectName}-dlq`, {
  messageRetentionSeconds: 1209600, // 14 días
  tags: { Environment: environment },
});

const queue = new aws.sqs.Queue(`${projectName}-queue`, {
  visibilityTimeoutSeconds: 300, // 5 minutos
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
const bucketNotification = new aws.s3.BucketNotification(
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
// ECS Cluster
// =============================================================================
const cluster = new aws.ecs.Cluster(`${projectName}-cluster`, {
  tags: { Environment: environment },
});

// =============================================================================
// IAM Roles
// =============================================================================

// Task Execution Role (para que ECS pueda pull images, logs, etc)
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

// Task Role (permisos para el contenedor)
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

// Permisos para acceder a S3 y SQS desde el contenedor
new aws.iam.RolePolicy(`${projectName}-task-policy`, {
  role: taskRole.id,
  policy: pulumi
    .all([bucket.arn, queue.arn])
    .apply(([bucketArn, queueArn]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Action: ["s3:GetObject", "s3:ListBucket"],
            Resource: [bucketArn, `${bucketArn}/*`],
          },
          {
            Effect: "Allow",
            Action: [
              "sqs:ReceiveMessage",
              "sqs:DeleteMessage",
              "sqs:GetQueueAttributes",
            ],
            Resource: queueArn,
          },
        ],
      })
    ),
});

// =============================================================================
// CloudWatch Log Group
// =============================================================================
const logGroup = new aws.cloudwatch.LogGroup(`${projectName}-logs`, {
  retentionInDays: 7,
  tags: { Environment: environment },
});

// =============================================================================
// ECS Task Definition
// =============================================================================
const region = aws.getRegion();

const taskDefinition = new aws.ecs.TaskDefinition(`${projectName}-task`, {
  family: `${projectName}-task`,
  networkMode: "awsvpc",
  requiresCompatibilities: ["FARGATE"],
  cpu: "256",
  memory: "512",
  executionRoleArn: taskExecutionRole.arn,
  taskRoleArn: taskRole.arn,
  containerDefinitions: pulumi
    .all([logGroup.name, bucket.id, queue.url, region])
    .apply(([logGroupName, bucketName, queueUrl, regionData]) =>
      JSON.stringify([
        {
          name: "processor",
          image: "amazon/aws-cli:latest", // Cambiar por tu imagen
          essential: true,
          command: [
            "sh",
            "-c",
            "echo 'Processing file from S3...' && echo $S3_EVENT && sleep 10 && echo 'Done!'",
          ],
          environment: [
            { name: "BUCKET_NAME", value: bucketName },
            { name: "QUEUE_URL", value: queueUrl },
          ],
          logConfiguration: {
            logDriver: "awslogs",
            options: {
              "awslogs-group": logGroupName,
              "awslogs-region": regionData.name,
              "awslogs-stream-prefix": "processor",
            },
          },
        },
      ])
    ),
  tags: { Environment: environment },
});

// =============================================================================
// EventBridge Pipes: SQS → Fargate
// =============================================================================

// IAM Role para EventBridge Pipes
const pipesRole = new aws.iam.Role(`${projectName}-pipes-role`, {
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
});

const pipesPolicy = new aws.iam.RolePolicy(`${projectName}-pipes-policy`, {
  role: pipesRole.id,
  policy: pulumi
    .all([
      queue.arn,
      cluster.arn,
      taskDefinition.arn,
      taskExecutionRole.arn,
      taskRole.arn,
    ])
    .apply(([queueArn, clusterArn, taskDefArn, execRoleArn, taskRoleArn]) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Action: [
              "sqs:ReceiveMessage",
              "sqs:DeleteMessage",
              "sqs:GetQueueAttributes",
            ],
            Resource: queueArn,
          },
          {
            Effect: "Allow",
            Action: ["ecs:RunTask"],
            Resource: taskDefArn,
          },
          {
            Effect: "Allow",
            Action: ["iam:PassRole"],
            Resource: [execRoleArn, taskRoleArn],
          },
        ],
      })
    ),
});

// EventBridge Pipe
const pipe = new aws.pipes.Pipe(
  `${projectName}-pipe`,
  {
    roleArn: pipesRole.arn,
    source: queue.arn,
    target: cluster.arn,
    sourceParameters: {
      sqsQueueParameters: {
        batchSize: 1,
      },
    },
    targetParameters: {
      ecsTaskParameters: {
        taskDefinitionArn: taskDefinition.arn,
        launchType: "FARGATE",
        networkConfiguration: {
          awsvpcConfiguration: {
            subnets: defaultSubnets.then((s) => s.ids),
            securityGroups: [fargateSg.id],
            assignPublicIp: "ENABLED",
          },
        },
        overrides: {
          containerOverrides: [
            {
              name: "processor",
              environments: [
                {
                  name: "S3_EVENT",
                  value: "$.body",
                },
              ],
            },
          ],
        },
      },
    },
    tags: { Environment: environment },
  },
  { dependsOn: [pipesPolicy] }
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
export const taskDefinitionArn = taskDefinition.arn;
export const fargateSecurityGroupId = fargateSg.id;
export const subnetIds = defaultSubnets.then((s) => s.ids);
