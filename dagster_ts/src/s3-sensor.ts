/**
 * S3 Sensor - Polls S3 directly and uses DynamoDB for deduplication.
 * Alternative to SQS-based sensor when S3 event notifications are unavailable.
 */

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { S3Resource } from "./resources";
import type { Logger, RunRequest } from "./sensor";

export interface S3SensorOptions {
  s3: S3Resource;
  dynamoTableName: string;
  bucketName: string;
  region: string;
  logger: Logger;
}

/**
 * Check if a file has already been processed or is in progress.
 * Queries DynamoDB for the latest state of the file.
 */
async function isAlreadyProcessed(
  docClient: DynamoDBDocumentClient,
  tableName: string,
  bucket: string,
  key: string
): Promise<boolean> {
  const result = await docClient.send(
    new QueryCommand({
      TableName: tableName,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: {
        ":pk": `FILE#${bucket}#${key}`,
      },
      ScanIndexForward: false,
      Limit: 1,
    })
  );

  if (!result.Items || result.Items.length === 0) {
    return false; // Never processed
  }

  const status = result.Items[0].status as string;

  // Skip if completed or currently in progress
  return ["COMPLETED", "PROCESSING", "VALIDATING", "PENDING"].includes(status);
}

/**
 * Poll S3 bucket for files and return RunRequests for unprocessed ones.
 */
export async function pollS3Sensor(
  options: S3SensorOptions
): Promise<RunRequest[]> {
  const { s3, dynamoTableName, bucketName, region, logger } = options;
  const runRequests: RunRequest[] = [];

  const dynamoClient = new DynamoDBClient({ region });
  const docClient = DynamoDBDocumentClient.from(dynamoClient);

  logger.info(`Listing objects in s3://${bucketName}`);
  const objects = await s3.listObjects(bucketName);
  logger.info(`Found ${objects.length} objects in bucket`);

  for (const obj of objects) {
    try {
      const alreadyProcessed = await isAlreadyProcessed(
        docClient,
        dynamoTableName,
        bucketName,
        obj.key
      );

      if (alreadyProcessed) {
        continue;
      }

      logger.info(`New file detected: s3://${bucketName}/${obj.key}`);
      logger.info(
        `File size: ${(obj.size / (1024 * 1024)).toFixed(2)} MB`
      );

      const taskSize = s3.getRecommendedTaskSize(obj.size);
      logger.info(`Recommended task size: ${taskSize}`);

      runRequests.push({
        runKey: `${bucketName}/${obj.key}/${obj.etag}`,
        config: {
          s3Bucket: bucketName,
          s3Key: obj.key,
          taskSize,
        },
        tags: {
          s3_bucket: bucketName,
          s3_key: obj.key,
          file_size_mb: String(
            Math.round((obj.size / (1024 * 1024)) * 100) / 100
          ),
          task_size: taskSize,
        },
      });
    } catch (error) {
      logger.error(`Error checking file ${obj.key}: ${error}`);
    }
  }

  logger.info(
    `S3 poll complete: ${runRequests.length} new files to process`
  );

  dynamoClient.destroy();
  return runRequests;
}
