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

export interface SensorOutput {
  runRequests: RunRequest[];
  receiptHandles: string[];
}

export interface SensorOptions {
  sqs: SQSResource;
  s3: S3Resource;
  logger: Logger;
  /** Interval in milliseconds between polls (default: 30000) */
  intervalMs?: number;
}

interface EnrichmentData {
  registered: boolean;
  dataset_id?: string;
  schema_version?: string;
  compute_target?: "LAMBDA" | "FARGATE" | "AUTO";
}

interface ParsedRecord {
  bucket: string;
  key: string;
  size: number;
  etag: string;
  enrichment_data?: EnrichmentData;
}

/**
 * Parse S3 event records from an SQS message body.
 * Supports both raw S3 events and enriched events from EventBridge Pipe.
 */
function parseS3Records(body: string): ParsedRecord[] {
  const parsed = JSON.parse(body);
  const records: ParsedRecord[] = [];

  // Enriched event from EventBridge Pipe
  if (parsed.original_event && parsed.enrichment_data) {
    const enrichment_data = parsed.enrichment_data as EnrichmentData;
    const s3Event = parsed.original_event;

    for (const record of s3Event.Records ?? []) {
      const s3Info = record.s3 ?? {};
      const bucket = s3Info.bucket?.name;
      const key = s3Info.object?.key;
      const size = s3Info.object?.size ?? 0;
      const etag = s3Info.object?.eTag ?? "";

      if (bucket && key) {
        records.push({ bucket, key, size, etag, enrichment_data });
      }
    }

    return records;
  }

  // Raw S3 event format (backward compatibility)
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
 * Returns run requests and receipt handles. Messages are NOT deleted here —
 * the Python sensor deletes them after successfully yielding RunRequests to Dagster.
 */
export async function pollSensor(options: SensorOptions): Promise<SensorOutput> {
  const { sqs, s3, logger } = options;
  const runRequests: RunRequest[] = [];
  const receiptHandles: string[] = [];

  const messages = await sqs.receiveMessages(10);

  for (const message of messages) {
    try {
      if (!message.Body) {
        logger.warning(`Message missing body: ${message.MessageId}`);
        continue;
      }

      const s3Records = parseS3Records(message.Body);

      for (const record of s3Records) {
        // Skip unregistered files from enrichment
        if (record.enrichment_data && !record.enrichment_data.registered) {
          logger.info(`Skipping unregistered file: s3://${record.bucket}/${record.key}`);
          continue;
        }

        logger.info(`File detected: s3://${record.bucket}/${record.key}`);
        logger.info(`File size: ${(record.size / (1024 * 1024)).toFixed(2)} MB`);

        // Routing: LAMBDA = always Lambda, AUTO/absent = size-based routing
        let taskSize: string;
        if (record.enrichment_data?.compute_target === "LAMBDA") {
          taskSize = "lambda";
          logger.info(`Compute target forced: LAMBDA`);
        } else {
          taskSize = s3.getRecommendedTaskSize(record.size);
          logger.info(`Compute target: AUTO (size-based) → ${taskSize}`);
        }
        logger.info(`Recommended task size: ${taskSize}`);

        if (record.enrichment_data) {
          logger.info(`Dataset: ${record.enrichment_data.dataset_id} (schema v${record.enrichment_data.schema_version})`);
        }

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
            ...(record.enrichment_data?.dataset_id && {
              dataset_id: record.enrichment_data.dataset_id,
            }),
            ...(record.enrichment_data?.schema_version && {
              schema_version: record.enrichment_data.schema_version,
            }),
          },
        });
      }

      // Collect receipt handle for deletion by Python after successful run creation
      if (message.ReceiptHandle) {
        receiptHandles.push(message.ReceiptHandle);
      }
    } catch (error) {
      if (error instanceof SyntaxError) {
        logger.error(`Invalid JSON in message: ${message.Body}`);
      } else {
        logger.error(`Error processing message: ${error}`);
      }
    }
  }

  return { runRequests, receiptHandles };
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
      const { runRequests } = await pollSensor(options);

      for (const request of runRequests) {
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
