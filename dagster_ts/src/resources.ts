/**
 * AWS Resources - TypeScript equivalent of dagster_poc/resources.py
 */

import { ECSClient } from "@aws-sdk/client-ecs";
import {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from "@aws-sdk/client-sqs";
import { S3Client, HeadObjectCommand } from "@aws-sdk/client-s3";

// ─── ECS Resource ───────────────────────────────────────────────

export interface ECSResourceConfig {
  regionName?: string;
  clusterName: string;
  subnets: string[];
  securityGroups: string[];
  logGroupName: string;
  dynamoTableName: string;
  taskDefinitionSmall: string;
  taskDefinitionMedium: string;
  taskDefinitionLarge: string;
  taskDefinitionXlarge: string;
}

export class ECSResource {
  readonly regionName: string;
  readonly clusterName: string;
  readonly subnets: string[];
  readonly securityGroups: string[];
  readonly logGroupName: string;
  readonly dynamoTableName: string;
  readonly taskDefinitionSmall: string;
  readonly taskDefinitionMedium: string;
  readonly taskDefinitionLarge: string;
  readonly taskDefinitionXlarge: string;

  private client: ECSClient;

  constructor(config: ECSResourceConfig) {
    this.regionName = config.regionName ?? "us-east-1";
    this.clusterName = config.clusterName;
    this.subnets = config.subnets;
    this.securityGroups = config.securityGroups;
    this.logGroupName = config.logGroupName;
    this.dynamoTableName = config.dynamoTableName;
    this.taskDefinitionSmall = config.taskDefinitionSmall;
    this.taskDefinitionMedium = config.taskDefinitionMedium;
    this.taskDefinitionLarge = config.taskDefinitionLarge;
    this.taskDefinitionXlarge = config.taskDefinitionXlarge;
    this.client = new ECSClient({ region: this.regionName });
  }

  getClient(): ECSClient {
    return this.client;
  }

  getTaskDefinition(taskSize: string): string {
    const mapping: Record<string, string> = {
      small: this.taskDefinitionSmall,
      medium: this.taskDefinitionMedium,
      large: this.taskDefinitionLarge,
      xlarge: this.taskDefinitionXlarge,
    };
    return mapping[taskSize] ?? this.taskDefinitionSmall;
  }

  getNetworkConfig(assignPublicIp = true) {
    return {
      awsvpcConfiguration: {
        subnets: this.subnets,
        securityGroups: this.securityGroups,
        assignPublicIp: assignPublicIp ? ("ENABLED" as const) : ("DISABLED" as const),
      },
    };
  }
}

// ─── SQS Resource ───────────────────────────────────────────────

export interface SQSResourceConfig {
  regionName?: string;
  queueUrl: string;
}

export interface SQSMessage {
  MessageId?: string;
  ReceiptHandle?: string;
  Body?: string;
}

export class SQSResource {
  readonly regionName: string;
  readonly queueUrl: string;
  private client: SQSClient;

  constructor(config: SQSResourceConfig) {
    this.regionName = config.regionName ?? "us-east-1";
    this.queueUrl = config.queueUrl;
    this.client = new SQSClient({ region: this.regionName });
  }

  getClient(): SQSClient {
    return this.client;
  }

  async receiveMessages(maxMessages = 10, waitTime = 5): Promise<SQSMessage[]> {
    const command = new ReceiveMessageCommand({
      QueueUrl: this.queueUrl,
      MaxNumberOfMessages: maxMessages,
      WaitTimeSeconds: waitTime,
    });
    const response = await this.client.send(command);
    return (response.Messages ?? []) as SQSMessage[];
  }

  async deleteMessage(receiptHandle: string): Promise<void> {
    const command = new DeleteMessageCommand({
      QueueUrl: this.queueUrl,
      ReceiptHandle: receiptHandle,
    });
    await this.client.send(command);
  }
}

// ─── Lambda Resource ────────────────────────────────────────────

export interface LambdaResourceConfig {
  regionName?: string;
  functionName: string;
  logGroupName: string;
  dynamoTableName: string;
}

export class LambdaResource {
  readonly regionName: string;
  readonly functionName: string;
  readonly logGroupName: string;
  readonly dynamoTableName: string;

  constructor(config: LambdaResourceConfig) {
    this.regionName = config.regionName ?? "us-east-1";
    this.functionName = config.functionName;
    this.logGroupName = config.logGroupName;
    this.dynamoTableName = config.dynamoTableName;
  }
}

// ─── S3 Resource ────────────────────────────────────────────────

export interface S3ResourceConfig {
  regionName?: string;
}

export class S3Resource {
  readonly regionName: string;
  private client: S3Client;

  constructor(config: S3ResourceConfig = {}) {
    this.regionName = config.regionName ?? "us-east-1";
    this.client = new S3Client({ region: this.regionName });
  }

  getClient(): S3Client {
    return this.client;
  }

  async getFileSize(bucket: string, key: string): Promise<number> {
    const command = new HeadObjectCommand({ Bucket: bucket, Key: key });
    const response = await this.client.send(command);
    return response.ContentLength ?? 0;
  }

  getRecommendedTaskSize(fileSizeBytes: number): string {
    const sizeMb = fileSizeBytes / (1024 * 1024);

    if (sizeMb < 50) return "lambda";
    if (sizeMb < 200) return "medium";
    if (sizeMb < 500) return "large";
    return "xlarge";
  }
}
