/**
 * Lambda Handler - Entry point for AWS Lambda execution.
 * Reuses the same FileProcessor as the Fargate container.
 *
 * Invoked by dagster_ts/src/lambda-cli.ts via AWS SDK InvokeCommand.
 * Logs go to CloudWatch automatically via console.log/console.error.
 */

import { pipes } from "./dagster-pipes";
import { FileProcessor, WorkerConfig, ProcessingResult } from "./file-processor";

export interface LambdaEvent {
  s3Bucket: string;
  s3Key: string;
  region?: string;
  dynamoTable: string;
  dagsterRunId?: string;
  chunkSizeMB?: number;
}

export interface LambdaResponse {
  statusCode: number;
  body: ProcessingResult;
}

export async function handler(event: LambdaEvent): Promise<LambdaResponse> {
  pipes.log("=== Lambda Worker Starting ===");

  // Validate required fields
  if (!event.s3Bucket || !event.s3Key) {
    const error = "Missing required fields: s3Bucket, s3Key";
    pipes.log(error, "error");
    return {
      statusCode: 400,
      body: {
        success: false,
        rowCount: 0,
        bytesProcessed: 0,
        chunksProcessed: 0,
        durationMs: 0,
        error,
      },
    };
  }

  // Use event payload or fall back to Lambda env var
  const dynamoTable = event.dynamoTable || process.env.DYNAMO_TABLE;
  if (!dynamoTable) {
    const error = "Missing required field: dynamoTable (not in event or DYNAMO_TABLE env)";
    pipes.log(error, "error");
    return {
      statusCode: 400,
      body: {
        success: false,
        rowCount: 0,
        bytesProcessed: 0,
        chunksProcessed: 0,
        durationMs: 0,
        error,
      },
    };
  }

  const config: WorkerConfig = {
    bucket: event.s3Bucket,
    key: event.s3Key,
    region: event.region || process.env.AWS_REGION || "us-east-1",
    dynamoTable: dynamoTable,
    chunkSizeMB: event.chunkSizeMB || 10,
    dagsterRunId: event.dagsterRunId,
  };

  pipes.log(`Configuration:`, "info");
  pipes.log(`  Bucket: ${config.bucket}`, "info");
  pipes.log(`  Key: ${config.key}`, "info");
  pipes.log(`  Region: ${config.region}`, "info");
  pipes.log(`  Chunk Size: ${config.chunkSizeMB} MB`, "info");
  pipes.log(`  Dagster Run ID: ${config.dagsterRunId || "N/A"}`, "info");
  pipes.log(`  Execution Type: Lambda`, "info");

  // Set TASK_SIZE env var so FileProcessor logs the correct value
  process.env.TASK_SIZE = "lambda";

  const processor = new FileProcessor(config);
  const result = await processor.process(config);

  pipes.log("=== Lambda Worker Finished ===");
  pipes.log(`Success: ${result.success}`);
  pipes.log(`Rows processed: ${result.rowCount.toLocaleString()}`);
  pipes.log(`Bytes processed: ${result.bytesProcessed.toLocaleString()}`);
  pipes.log(`Duration: ${result.durationMs}ms`);

  return {
    statusCode: result.success ? 200 : 500,
    body: result,
  };
}
