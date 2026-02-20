/**
 * Sensor CLI - Polls for new files and outputs JSON run requests to stdout.
 * Called by the Python Dagster sensor as a subprocess.
 *
 * Supports two modes:
 *   - SQS mode (default): Polls SQS for S3 event notifications
 *   - S3 mode: Polls S3 directly + DynamoDB dedup (when S3_POLLING_ENABLED=true)
 *
 * Usage: node dist/sensor-cli.js
 * Env: AWS_DEFAULT_REGION, and either SQS_QUEUE_URL or S3_POLLING_ENABLED + S3_BUCKET_NAME + DYNAMO_TABLE_NAME
 *
 * Output: JSON object with runRequests and receiptHandles on stdout.
 * Messages are NOT deleted here — Python deletes after successful run creation.
 */

import { SQSResource, S3Resource } from "./resources";
import { pollSensor } from "./sensor";
import { pollS3Sensor } from "./s3-sensor";

async function main() {
  const region = process.env.AWS_DEFAULT_REGION ?? "us-east-1";
  const useS3Polling = process.env.S3_POLLING_ENABLED === "true";

  const s3 = new S3Resource({ regionName: region });

  const logger = {
    info: (msg: string) => console.error(`[INFO] ${msg}`),
    warning: (msg: string) => console.error(`[WARN] ${msg}`),
    error: (msg: string) => console.error(`[ERROR] ${msg}`),
  };

  let output: { runRequests: unknown[]; receiptHandles: string[] };

  if (useS3Polling) {
    const bucketName = process.env.S3_BUCKET_NAME;
    const dynamoTableName = process.env.DYNAMO_TABLE_NAME;

    if (!bucketName || !dynamoTableName) {
      console.error("Missing S3_BUCKET_NAME or DYNAMO_TABLE_NAME for S3 polling mode");
      process.exit(1);
    }

    logger.info("Using S3 polling mode");
    const requests = await pollS3Sensor({
      s3,
      bucketName,
      dynamoTableName,
      region,
      logger,
    });
    // S3 polling mode has no SQS receipt handles
    output = { runRequests: requests, receiptHandles: [] };
  } else {
    const queueUrl = process.env.SQS_QUEUE_URL;

    if (!queueUrl) {
      console.error("Missing SQS_QUEUE_URL");
      process.exit(1);
    }

    logger.info("Using SQS polling mode");
    const sqs = new SQSResource({ regionName: region, queueUrl });
    output = await pollSensor({ sqs, s3, logger });
  }

  // Output clean JSON to stdout (Python reads this)
  console.log(JSON.stringify(output));
}

main().catch((err) => {
  console.error(`Fatal: ${err}`);
  process.exit(1);
});
