/**
 * Dagster Worker - TypeScript (Fargate entry point)
 * Processes files from S3 in chunks with Dagster Pipes integration
 */

import { pipes } from "./dagster-pipes";
import { FileProcessor, WorkerConfig } from "./file-processor";

/**
 * Main entry point (Fargate container)
 */
async function main(): Promise<void> {
  pipes.log("=== Dagster Worker Starting ===");

  // Get configuration from environment
  const config: WorkerConfig = {
    bucket: process.env.S3_BUCKET || "",
    key: process.env.S3_KEY || "",
    region: process.env.AWS_REGION || "us-east-1",
    dynamoTable: process.env.DYNAMO_TABLE || "",
    chunkSizeMB: parseInt(process.env.CHUNK_SIZE_MB || "10", 10),
    dagsterRunId: process.env.DAGSTER_RUN_ID,
  };

  // Validate configuration
  if (!config.bucket || !config.key) {
    pipes.log("Missing required environment variables: S3_BUCKET, S3_KEY", "error");
    pipes.reportFailure("Missing required environment variables");
    process.exit(1);
  }

  if (!config.dynamoTable) {
    pipes.log("Missing DYNAMO_TABLE environment variable", "error");
    pipes.reportFailure("Missing DYNAMO_TABLE environment variable");
    process.exit(1);
  }

  pipes.log(`Configuration:`, "info");
  pipes.log(`  Bucket: ${config.bucket}`, "info");
  pipes.log(`  Key: ${config.key}`, "info");
  pipes.log(`  Region: ${config.region}`, "info");
  pipes.log(`  Chunk Size: ${config.chunkSizeMB} MB`, "info");
  pipes.log(`  Dagster Run ID: ${config.dagsterRunId || "N/A"}`, "info");

  // Process file
  const processor = new FileProcessor(config);
  const result = await processor.process(config);

  pipes.log("=== Dagster Worker Finished ===");
  pipes.log(`Success: ${result.success}`);
  pipes.log(`Rows processed: ${result.rowCount.toLocaleString()}`);
  pipes.log(`Bytes processed: ${result.bytesProcessed.toLocaleString()}`);
  pipes.log(`Duration: ${result.durationMs}ms`);

  // Exit with appropriate code
  process.exit(result.success ? 0 : 1);
}

// Run
main().catch((error) => {
  pipes.log(`Unhandled error: ${error}`, "error");
  pipes.reportFailure(error);
  process.exit(1);
});
