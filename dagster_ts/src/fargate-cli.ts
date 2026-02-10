/**
 * Fargate CLI - Launches an ECS Fargate task and streams CloudWatch logs.
 * Called by the Python Dagster op as a subprocess.
 *
 * Usage: node dist/fargate-cli.js <s3_bucket> <s3_key> [task_size] [run_id]
 * Env: ECS_CLUSTER_NAME, ECS_SUBNETS, ECS_SECURITY_GROUPS, ECS_LOG_GROUP_NAME,
 *      DYNAMO_TABLE_NAME, ECS_TASK_DEFINITION_SMALL/MEDIUM/LARGE/XLARGE
 *
 * Output: Logs to stderr, final JSON result to stdout.
 */

import { ECSResource, S3Resource } from "./resources";
import { processFileWithPipes } from "./fargate-ops";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function optionalEnv(name: string, defaultValue = ""): string {
  return process.env[name] ?? defaultValue;
}

function csvEnv(name: string): string[] {
  const value = process.env[name];
  return value ? value.split(",").map((s) => s.trim()).filter(Boolean) : [];
}

async function main() {
  const [s3Bucket, s3Key, taskSize, runId] = process.argv.slice(2);

  if (!s3Bucket || !s3Key) {
    console.error("Usage: fargate-cli <s3_bucket> <s3_key> [task_size] [run_id]");
    process.exit(1);
  }

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

  const s3 = new S3Resource({ regionName: region });

  // Logs go to stderr so Python can stream them to Dagster UI
  const logger = {
    info: (msg: string) => console.error(`[INFO] ${msg}`),
    warning: (msg: string) => console.error(`[WARN] ${msg}`),
    error: (msg: string) => console.error(`[ERROR] ${msg}`),
  };

  const result = await processFileWithPipes(
    { s3Bucket, s3Key, taskSize: taskSize || undefined },
    ecs,
    s3,
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
