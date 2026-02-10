/**
 * SQS Sensor - TypeScript equivalent of dagster_poc/sensors/sqs_sensor.py
 *
 * Polls SQS for S3 event notifications and triggers Fargate processing.
 */

import type { SQSResource, S3Resource, SQSMessage } from "./resources";
import type { ProcessFileConfig } from "./fargate-ops";

export interface Logger {
  info(message: string): void;
  warning(message: string): void;
  error(message: string): void;
}

export interface RunRequest {
  runKey: string;
  config: ProcessFileConfig;
  tags: Record<string, string>;
}

export interface SensorOptions {
  sqs: SQSResource;
  s3: S3Resource;
  logger: Logger;
  /** Interval in milliseconds between polls (default: 30000) */
  intervalMs?: number;
}

/**
 * Parse S3 event records from an SQS message body.
 */
function parseS3Records(body: string): Array<{
  bucket: string;
  key: string;
  size: number;
  etag: string;
}> {
  const parsed = JSON.parse(body);
  const records: Array<{ bucket: string; key: string; size: number; etag: string }> = [];

  for (const record of parsed.Records ?? []) {
    const s3Info = record.s3 ?? {};
    const bucket = s3Info.bucket?.name;
    const key = s3Info.object?.key;
    const size = s3Info.object?.size ?? 0;
    const etag = s3Info.object?.eTag ?? "";

    if (bucket && key) {
      records.push({ bucket, key, size, etag });
    }
  }

  return records;
}

/**
 * Process a single SQS polling cycle.
 * Returns an array of RunRequests for files that need processing.
 */
export async function pollSensor(options: SensorOptions): Promise<RunRequest[]> {
  const { sqs, s3, logger } = options;
  const runRequests: RunRequest[] = [];

  const messages = await sqs.receiveMessages(10);

  for (const message of messages) {
    try {
      if (!message.Body) {
        logger.warning(`Message missing body: ${message.MessageId}`);
        continue;
      }

      const s3Records = parseS3Records(message.Body);

      for (const record of s3Records) {
        logger.info(`File detected: s3://${record.bucket}/${record.key}`);
        logger.info(`File size: ${(record.size / (1024 * 1024)).toFixed(2)} MB`);

        const taskSize = s3.getRecommendedTaskSize(record.size);
        logger.info(`Recommended task size: ${taskSize}`);

        runRequests.push({
          runKey: `${record.bucket}/${record.key}/${record.etag}`,
          config: {
            s3Bucket: record.bucket,
            s3Key: record.key,
            taskSize,
          },
          tags: {
            s3_bucket: record.bucket,
            s3_key: record.key,
            file_size_mb: String(Math.round((record.size / (1024 * 1024)) * 100) / 100),
            task_size: taskSize,
          },
        });
      }

      // Delete message from queue after processing
      if (message.ReceiptHandle) {
        await sqs.deleteMessage(message.ReceiptHandle);
      }
    } catch (error) {
      if (error instanceof SyntaxError) {
        logger.error(`Invalid JSON in message: ${message.Body}`);
      } else {
        logger.error(`Error processing message: ${error}`);
      }
    }
  }

  return runRequests;
}

/**
 * Run the sensor in a continuous polling loop.
 * Calls the onRunRequest callback for each detected file.
 */
export async function runSensorLoop(
  options: SensorOptions & {
    onRunRequest: (request: RunRequest) => Promise<void>;
    signal?: AbortSignal;
  },
): Promise<void> {
  const intervalMs = options.intervalMs ?? 30_000;
  const { logger, onRunRequest, signal } = options;

  logger.info(`Sensor started. Polling every ${intervalMs / 1000}s`);

  while (!signal?.aborted) {
    try {
      const requests = await pollSensor(options);

      for (const request of requests) {
        await onRunRequest(request);
      }
    } catch (error) {
      logger.error(`Sensor poll error: ${error}`);
    }

    // Wait for next interval (interruptible)
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, intervalMs);
      signal?.addEventListener("abort", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
    });
  }

  logger.info("Sensor stopped.");
}
