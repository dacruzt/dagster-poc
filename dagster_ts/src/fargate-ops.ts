/**
 * Fargate Operations - TypeScript equivalent of dagster_poc/ops/fargate_ops.py
 *
 * Launches ECS Fargate tasks and streams CloudWatch logs.
 */

import {
  RunTaskCommand,
  DescribeTasksCommand,
} from "@aws-sdk/client-ecs";
import {
  CloudWatchLogsClient,
  FilterLogEventsCommand,
} from "@aws-sdk/client-cloudwatch-logs";
import type { ECSResource, S3Resource } from "./resources";
import type { Logger } from "./sensor";

// ─── Config ─────────────────────────────────────────────────────

export interface ProcessFileConfig {
  s3Bucket: string;
  s3Key: string;
  taskSize?: string; // auto-detect if undefined
}

export interface FargateResult {
  status: "success" | "failed";
  file: string;
  fileSizeMb: number;
  taskSize: string;
  taskArn: string;
  exitCode: number | null;
}

// ─── Helpers ────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ─── Main Operation ─────────────────────────────────────────────

export async function processFileWithPipes(
  config: ProcessFileConfig,
  ecs: ECSResource,
  s3: S3Resource,
  logger: Logger,
  runId?: string,
): Promise<FargateResult> {
  const separator = "=".repeat(50);
  const dash = "-".repeat(50);

  logger.info(separator);
  logger.info("Starting Fargate Processing");
  logger.info(separator);
  logger.info(`File: s3://${config.s3Bucket}/${config.s3Key}`);

  // 1. Get file size and determine task size
  const fileSize = await s3.getFileSize(config.s3Bucket, config.s3Key);
  const fileSizeMb = fileSize / (1024 * 1024);
  const taskSize = config.taskSize ?? s3.getRecommendedTaskSize(fileSize);

  logger.info(`File size: ${fileSizeMb.toFixed(2)} MB`);
  logger.info(`Task size: ${taskSize}`);

  // 2. Get task definition for this size
  const taskDefinition = ecs.getTaskDefinition(taskSize);
  if (!taskDefinition) {
    throw new Error(`No task definition found for size: ${taskSize}`);
  }

  logger.info(`Task definition: ${taskDefinition}`);

  // 3. Launch Fargate task
  logger.info("Launching Fargate task...");

  const ecsClient = ecs.getClient();
  const logsClient = new CloudWatchLogsClient({ region: ecs.regionName });

  const runTaskResponse = await ecsClient.send(
    new RunTaskCommand({
      cluster: ecs.clusterName,
      taskDefinition,
      launchType: "FARGATE",
      networkConfiguration: ecs.getNetworkConfig(),
      overrides: {
        containerOverrides: [
          {
            name: "worker",
            environment: [
              { name: "S3_BUCKET", value: config.s3Bucket },
              { name: "S3_KEY", value: config.s3Key },
              { name: "DAGSTER_RUN_ID", value: runId ?? "" },
              { name: "DYNAMO_TABLE", value: ecs.dynamoTableName },
            ],
          },
        ],
      },
    }),
  );

  const tasks = runTaskResponse.tasks ?? [];
  if (tasks.length === 0) {
    const failures = runTaskResponse.failures ?? [];
    throw new Error(`Failed to start Fargate task: ${JSON.stringify(failures)}`);
  }

  const taskArn = tasks[0].taskArn!;
  const taskId = taskArn.split("/").pop()!;

  logger.info(`Task started: ${taskId}`);

  // 4. Wait for task to complete while streaming logs
  const logGroup = ecs.logGroupName;
  const logStreamPrefix = `worker-${taskSize}/worker/${taskId}`;

  logger.info(`Log group: ${logGroup}`);
  logger.info(`Log stream: ${logStreamPrefix}`);
  logger.info(dash);
  logger.info("FARGATE WORKER LOGS:");
  logger.info(dash);

  let lastLogToken: string | undefined;
  let taskRunning = true;
  const startTime = Date.now();
  const maxWaitMs = 900_000; // 15 minutes

  let exitCode: number | null = null;
  const workerErrors: string[] = [];

  while (taskRunning && Date.now() - startTime < maxWaitMs) {
    // Check task status
    const describeResponse = await ecsClient.send(
      new DescribeTasksCommand({
        cluster: ecs.clusterName,
        tasks: [taskArn],
      }),
    );

    const describedTasks = describeResponse.tasks ?? [];
    if (describedTasks.length > 0) {
      const taskStatus = describedTasks[0].lastStatus;

      if (taskStatus === "STOPPED") {
        taskRunning = false;
        const stopReason = describedTasks[0].stoppedReason ?? "";
        const containers = describedTasks[0].containers ?? [];

        const workerContainer = containers.find(c => c.name === "worker") ?? containers[0];
        if (workerContainer) {
          exitCode = workerContainer.exitCode ?? null;
        }

        logger.info(dash);
        logger.info(`Task stopped. Exit code: ${exitCode}`);
        if (stopReason) {
          logger.info(`Stop reason: ${stopReason}`);
        }
      }
    }

    // Stream logs from CloudWatch
    try {
      const logParams: {
        logGroupName: string;
        logStreamNamePrefix: string;
        interleaved: boolean;
        nextToken?: string;
      } = {
        logGroupName: logGroup,
        logStreamNamePrefix: logStreamPrefix,
        interleaved: true,
      };
      if (lastLogToken) {
        logParams.nextToken = lastLogToken;
      }

      const logResponse = await logsClient.send(
        new FilterLogEventsCommand(logParams),
      );

      for (const event of logResponse.events ?? []) {
        const message = (event.message ?? "").trim();
        if (message) {
          logger.info(`[WORKER] ${message}`);
          if (message.includes("[ERROR")) {
            workerErrors.push(message);
          }
        }
      }

      if (logResponse.nextToken) {
        lastLogToken = logResponse.nextToken;
      }
    } catch (error: any) {
      if (error.name === "ResourceNotFoundException") {
        // Log stream not yet created
      } else {
        logger.warning(`Error reading logs: ${error}`);
      }
    }

    if (taskRunning) {
      await sleep(2000);
    }
  }

  // 5. Final log fetch (re-fetch all to catch any missed error lines)
  await sleep(2000);
  try {
    const logResponse = await logsClient.send(
      new FilterLogEventsCommand({
        logGroupName: logGroup,
        logStreamNamePrefix: logStreamPrefix,
        interleaved: true,
      }),
    );
    for (const event of logResponse.events ?? []) {
      const message = (event.message ?? "").trim();
      if (message && message.includes("[ERROR") && !workerErrors.includes(message)) {
        workerErrors.push(message);
        logger.info(`[WORKER] ${message}`);
      }
    }
  } catch {
    // ignore
  }

  // 6. Check final status
  const finalResponse = await ecsClient.send(
    new DescribeTasksCommand({
      cluster: ecs.clusterName,
      tasks: [taskArn],
    }),
  );

  const finalTasks = finalResponse.tasks ?? [];
  if (finalTasks.length > 0) {
    const containers = finalTasks[0].containers ?? [];
    const finalWorkerContainer = containers.find(c => c.name === "worker") ?? containers[0];
    exitCode = finalWorkerContainer ? (finalWorkerContainer.exitCode ?? null) : null;

    logger.info(separator);

    if (exitCode === 0) {
      logger.info("FARGATE TASK COMPLETED SUCCESSFULLY");
      logger.info(separator);

      return {
        status: "success",
        file: `s3://${config.s3Bucket}/${config.s3Key}`,
        fileSizeMb,
        taskSize,
        taskArn,
        exitCode,
      };
    } else {
      const errorDetail = workerErrors.length > 0
        ? workerErrors[workerErrors.length - 1]
        : "See CloudWatch logs for details";
      logger.error(`FARGATE TASK FAILED (exit code: ${exitCode}): ${errorDetail}`);
      logger.info(separator);
      throw new Error(`Fargate task failed (exit code ${exitCode}): ${errorDetail}`);
    }
  }

  throw new Error("Unable to determine task status");
}
