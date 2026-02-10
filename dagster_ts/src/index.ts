/**
 * Dagster TypeScript Orchestrator
 * Equivalent to dagster_poc/__init__.py + jobs + sensor loop
 *
 * Polls SQS for S3 events and launches ECS Fargate tasks for processing.
 * Dashboard available at http://localhost:3000
 *
 * Environment variables (same as the Python version):
 *   AWS_DEFAULT_REGION        - AWS region (default: us-east-1)
 *   ECS_CLUSTER_NAME          - ECS cluster name
 *   ECS_SUBNETS               - Comma-separated subnet IDs
 *   ECS_SECURITY_GROUPS       - Comma-separated security group IDs
 *   ECS_LOG_GROUP_NAME        - CloudWatch log group
 *   DYNAMO_TABLE_NAME         - DynamoDB state table
 *   ECS_TASK_DEFINITION_SMALL - Task def ARN for small files
 *   ECS_TASK_DEFINITION_MEDIUM
 *   ECS_TASK_DEFINITION_LARGE
 *   ECS_TASK_DEFINITION_XLARGE
 *   SQS_QUEUE_URL             - SQS queue URL
 *   SENSOR_INTERVAL_MS        - Polling interval in ms (default: 30000)
 *   DASHBOARD_PORT            - Dashboard port (default: 3000)
 */

import { ECSResource, SQSResource, S3Resource } from "./resources";
import { runSensorLoop, pollSensor } from "./sensor";
import { processFileWithPipes } from "./fargate-ops";
import { startDashboard, state as dashState, addLog } from "./dashboard";
import type { RunRequest, Logger } from "./sensor";
import type { RunRecord } from "./dashboard";

// ─── Logger (writes to console + dashboard) ─────────────────────

const logger: Logger = {
  info: (msg) => {
    const line = `[INFO] ${new Date().toISOString()} ${msg}`;
    console.log(line);
    addLog(line);
  },
  warning: (msg) => {
    const line = `[WARN] ${new Date().toISOString()} ${msg}`;
    console.warn(line);
    addLog(line);
  },
  error: (msg) => {
    const line = `[ERROR] ${new Date().toISOString()} ${msg}`;
    console.error(line);
    addLog(line);
  },
};

// ─── Env helpers ────────────────────────────────────────────────

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optionalEnv(name: string, defaultValue = ""): string {
  return process.env[name] ?? defaultValue;
}

function csvEnv(name: string): string[] {
  const value = process.env[name];
  return value ? value.split(",").map((s) => s.trim()).filter(Boolean) : [];
}

// ─── Resource creation (equivalent to __init__.py) ──────────────

function createResources() {
  const region = optionalEnv("AWS_DEFAULT_REGION", "us-east-1");

  const ecs = new ECSResource({
    regionName: region,
    clusterName: requireEnv("ECS_CLUSTER_NAME"),
    subnets: csvEnv("ECS_SUBNETS"),
    securityGroups: csvEnv("ECS_SECURITY_GROUPS"),
    logGroupName: requireEnv("ECS_LOG_GROUP_NAME"),
    dynamoTableName: optionalEnv("DYNAMO_TABLE_NAME"),
    taskDefinitionSmall: optionalEnv("ECS_TASK_DEFINITION_SMALL"),
    taskDefinitionMedium: optionalEnv("ECS_TASK_DEFINITION_MEDIUM"),
    taskDefinitionLarge: optionalEnv("ECS_TASK_DEFINITION_LARGE"),
    taskDefinitionXlarge: optionalEnv("ECS_TASK_DEFINITION_XLARGE"),
  });

  const sqs = new SQSResource({
    regionName: region,
    queueUrl: requireEnv("SQS_QUEUE_URL"),
  });

  const s3 = new S3Resource({ regionName: region });

  return { ecs, sqs, s3 };
}

// ─── Dedup tracking ─────────────────────────────────────────────

const processedRunKeys = new Set<string>();

// ─── Main ───────────────────────────────────────────────────────

async function main() {
  const port = Number(optionalEnv("DASHBOARD_PORT", "3000"));
  startDashboard(port);

  logger.info("Dagster TS Orchestrator starting...");
  logger.info(`Dashboard: http://localhost:${port}`);

  const { ecs, sqs, s3 } = createResources();
  const intervalMs = Number(optionalEnv("SENSOR_INTERVAL_MS", "30000"));

  const controller = new AbortController();

  // Graceful shutdown
  process.on("SIGINT", () => {
    logger.info("Received SIGINT, shutting down...");
    controller.abort();
  });
  process.on("SIGTERM", () => {
    logger.info("Received SIGTERM, shutting down...");
    controller.abort();
  });

  await runSensorLoop({
    sqs,
    s3,
    logger,
    intervalMs,
    signal: controller.signal,

    onRunRequest: async (request: RunRequest) => {
      // Track poll count
      dashState.sensorPolls++;
      dashState.lastPollAt = new Date().toISOString();

      // Dedup by runKey (same as Dagster's run_key)
      if (processedRunKeys.has(request.runKey)) {
        logger.info(`Skipping already processed: ${request.runKey}`);
        return;
      }

      logger.info(`Processing run: ${request.runKey}`);
      logger.info(`Tags: ${JSON.stringify(request.tags)}`);

      // Create run record for dashboard
      const run: RunRecord = {
        runKey: request.runKey,
        s3Bucket: request.config.s3Bucket,
        s3Key: request.config.s3Key,
        taskSize: request.tags.task_size,
        fileSizeMb: request.tags.file_size_mb,
        status: "running",
        startedAt: new Date().toISOString(),
      };
      dashState.runs.push(run);

      try {
        const result = await processFileWithPipes(
          request.config,
          ecs,
          s3,
          logger,
        );

        run.status = "success";
        run.taskArn = result.taskArn;
        run.taskId = result.taskArn.split("/").pop();
        run.exitCode = result.exitCode;
        run.finishedAt = new Date().toISOString();

        processedRunKeys.add(request.runKey);
        logger.info(`Completed: ${result.file} (${result.status})`);
      } catch (error) {
        run.status = "failed";
        run.error = String(error);
        run.finishedAt = new Date().toISOString();
        logger.error(`Failed processing ${request.runKey}: ${error}`);
      }
    },
  });

  logger.info("Orchestrator stopped.");
}

main().catch((error) => {
  logger.error(`Fatal error: ${error}`);
  process.exit(1);
});
