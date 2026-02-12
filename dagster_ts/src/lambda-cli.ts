/**
 * Lambda CLI - Invokes an AWS Lambda function and streams CloudWatch logs.
 * Called by the Python Dagster op as a subprocess.
 *
 * Usage: node dist/lambda-cli.js <s3_bucket> <s3_key> [run_id]
 * Env: LAMBDA_FUNCTION_NAME, LAMBDA_LOG_GROUP_NAME, DYNAMO_TABLE_NAME
 *
 * Output: Logs to stderr, final JSON result to stdout.
 */

import { LambdaResource } from "./resources";
import { processFileWithLambda } from "./lambda-ops";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function optionalEnv(name: string, defaultValue = ""): string {
  return process.env[name] ?? defaultValue;
}

async function main() {
  const [s3Bucket, s3Key, runId] = process.argv.slice(2);

  if (!s3Bucket || !s3Key) {
    console.error("Usage: lambda-cli <s3_bucket> <s3_key> [run_id]");
    process.exit(1);
  }

  const region = optionalEnv("AWS_DEFAULT_REGION", "us-east-1");

  const lambda = new LambdaResource({
    regionName: region,
    functionName: requireEnv("LAMBDA_FUNCTION_NAME"),
    logGroupName: requireEnv("LAMBDA_LOG_GROUP_NAME"),
    dynamoTableName: optionalEnv("DYNAMO_TABLE_NAME"),
  });

  // Logs go to stderr so Python can stream them to Dagster UI
  const logger = {
    info: (msg: string) => console.error(`[INFO] ${msg}`),
    warning: (msg: string) => console.error(`[WARN] ${msg}`),
    error: (msg: string) => console.error(`[ERROR] ${msg}`),
  };

  const result = await processFileWithLambda(
    { s3Bucket, s3Key },
    lambda,
    logger,
    runId,
  );

  // Final result as clean JSON to stdout
  console.log(JSON.stringify(result));
}

main().catch((err) => {
  console.error(`Fatal: ${err}`);
  process.exit(1);
});
