/**
 * Sensor CLI - Polls SQS once and outputs JSON run requests to stdout.
 * Called by the Python Dagster sensor as a subprocess.
 *
 * Usage: node dist/sensor-cli.js
 * Env: SQS_QUEUE_URL, AWS_DEFAULT_REGION
 *
 * Output: JSON array of run requests, one per line on stdout.
 */

import { SQSResource, S3Resource } from "./resources";
import { pollSensor } from "./sensor";

async function main() {
  const region = process.env.AWS_DEFAULT_REGION ?? "us-east-1";
  const queueUrl = process.env.SQS_QUEUE_URL;

  if (!queueUrl) {
    console.error("Missing SQS_QUEUE_URL");
    process.exit(1);
  }

  const sqs = new SQSResource({ regionName: region, queueUrl });
  const s3 = new S3Resource({ regionName: region });

  const logger = {
    info: (msg: string) => console.error(`[INFO] ${msg}`),
    warning: (msg: string) => console.error(`[WARN] ${msg}`),
    error: (msg: string) => console.error(`[ERROR] ${msg}`),
  };

  const requests = await pollSensor({ sqs, s3, logger });

  // Output clean JSON to stdout (Python reads this)
  console.log(JSON.stringify(requests));
}

main().catch((err) => {
  console.error(`Fatal: ${err}`);
  process.exit(1);
});
