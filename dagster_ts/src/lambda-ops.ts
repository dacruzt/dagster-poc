/**
 * Lambda Operations - Invokes AWS Lambda and streams CloudWatch logs.
 * Parallel to fargate-ops.ts but for small files (< 50 MB).
 */

import {
  LambdaClient,
  InvokeCommand,
} from "@aws-sdk/client-lambda";
import {
  CloudWatchLogsClient,
  FilterLogEventsCommand,
} from "@aws-sdk/client-cloudwatch-logs";
import type { LambdaResource } from "./resources";
import type { Logger } from "./sensor";

// ─── Types ──────────────────────────────────────────────────────

export interface LambdaProcessConfig {
  s3Bucket: string;
  s3Key: string;
}

export interface LambdaResult {
  status: "success" | "failed";
  file: string;
  fileSizeMb: number;
  executionType: "lambda";
  rowCount: number;
  bytesProcessed: number;
  durationMs: number;
  error?: string;
}

// ─── Helpers ────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ─── Main Operation ─────────────────────────────────────────────

export async function processFileWithLambda(
  config: LambdaProcessConfig,
  lambda: LambdaResource,
  logger: Logger,
  runId?: string,
): Promise<LambdaResult> {
  const separator = "=".repeat(50);
  const dash = "-".repeat(50);

  logger.info(separator);
  logger.info("Starting Lambda Processing");
  logger.info(separator);
  logger.info(`File: s3://${config.s3Bucket}/${config.s3Key}`);
  logger.info(`Function: ${lambda.functionName}`);

  // 1. Invoke Lambda synchronously
  logger.info("Invoking Lambda function...");

  const lambdaClient = new LambdaClient({ region: lambda.regionName });
  const logsClient = new CloudWatchLogsClient({ region: lambda.regionName });

  const payload = {
    s3Bucket: config.s3Bucket,
    s3Key: config.s3Key,
    region: lambda.regionName,
    dynamoTable: lambda.dynamoTableName,
    dagsterRunId: runId || "",
  };

  const invokeStart = Date.now();

  const response = await lambdaClient.send(
    new InvokeCommand({
      FunctionName: lambda.functionName,
      InvocationType: "RequestResponse",
      LogType: "Tail",
      Payload: Buffer.from(JSON.stringify(payload)),
    }),
  );

  const invokeDuration = Date.now() - invokeStart;
  logger.info(`Lambda invocation completed in ${invokeDuration}ms`);

  // 2. Stream the log tail from the invocation response (last 4 KB)
  if (response.LogResult) {
    const logTail = Buffer.from(response.LogResult, "base64").toString("utf-8");
    logger.info(dash);
    logger.info("LAMBDA WORKER LOGS:");
    logger.info(dash);

    for (const line of logTail.split("\n")) {
      const trimmed = line.trim();
      if (trimmed) {
        logger.info(`[LAMBDA] ${trimmed}`);
      }
    }
  }

  // 3. Fetch full CloudWatch logs (in case output exceeds 4 KB tail)
  try {
    // Small delay for CloudWatch log propagation
    await sleep(2000);

    const logResponse = await logsClient.send(
      new FilterLogEventsCommand({
        logGroupName: lambda.logGroupName,
        // Filter to recent events from this invocation
        startTime: invokeStart - 1000,
        interleaved: true,
      }),
    );

    const tailEvents = logResponse.events ?? [];
    if (tailEvents.length > 0) {
      logger.info(dash);
      logger.info("CLOUDWATCH FULL LOGS:");
      logger.info(dash);

      for (const event of tailEvents) {
        const message = (event.message ?? "").trim();
        if (message) {
          logger.info(`[LAMBDA] ${message}`);
        }
      }
    }
  } catch (error: any) {
    if (error.name !== "ResourceNotFoundException") {
      logger.warning(`Error reading CloudWatch logs: ${error}`);
    }
  }

  // 4. Parse the response payload
  const responsePayload = response.Payload
    ? JSON.parse(new TextDecoder().decode(response.Payload))
    : null;

  // 5. Check for Lambda-level errors
  if (response.FunctionError) {
    logger.error(`Lambda function error: ${response.FunctionError}`);
    logger.error(JSON.stringify(responsePayload, null, 2));
    throw new Error(
      `Lambda function error: ${responsePayload?.errorMessage || response.FunctionError}`,
    );
  }

  if (!responsePayload?.body) {
    throw new Error("Lambda returned empty response");
  }

  const body = responsePayload.body;

  // 6. Return result
  logger.info(separator);

  if (body.success) {
    logger.info("LAMBDA PROCESSING COMPLETED SUCCESSFULLY");
    logger.info(`  Rows: ${body.rowCount}`);
    logger.info(`  Bytes: ${body.bytesProcessed}`);
    logger.info(`  Duration: ${body.durationMs}ms`);
    logger.info(separator);

    return {
      status: "success",
      file: `s3://${config.s3Bucket}/${config.s3Key}`,
      fileSizeMb: body.bytesProcessed / (1024 * 1024),
      executionType: "lambda",
      rowCount: body.rowCount,
      bytesProcessed: body.bytesProcessed,
      durationMs: body.durationMs,
    };
  } else {
    logger.error(`LAMBDA PROCESSING FAILED: ${body.error}`);
    logger.info(separator);
    throw new Error(`Lambda processing failed: ${body.error}`);
  }
}
