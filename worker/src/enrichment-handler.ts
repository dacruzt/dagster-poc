/**
 * Enrichment Handler - EventBridge Pipe enrichment step.
 *
 * Receives batched S3 event records from the Pipe.
 * For each event:
 *   1. Queries DynamoDB for DATASET#__default__ CONFIG record
 *   2. Appends enrichment_data to the event
 *   3. Returns the enriched event
 */

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand } from "@aws-sdk/lib-dynamodb";

// --- Types ---

interface S3EventRecord {
  s3: {
    bucket: { name: string };
    object: { key: string; size: number; eTag: string };
  };
}

interface S3Event {
  Records: S3EventRecord[];
}

interface PipeEnrichmentInput {
  s3_event: S3Event;
}

interface DatasetConfig {
  pk: string;
  sk: string;
  dataset_id: string;
  schema_version: string;
  compute_target: "LAMBDA" | "FARGATE";
  allowed_extensions: string[];
  description?: string;
}

interface EnrichmentData {
  registered: boolean;
  dataset_id?: string;
  schema_version?: string;
  compute_target?: "LAMBDA" | "FARGATE";
}

interface EnrichedOutput {
  original_event: S3Event;
  enrichment_data: EnrichmentData;
}

// --- Globals (reused across invocations in warm Lambda) ---

const tableName = process.env.DYNAMO_TABLE!;
const dynamoClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(dynamoClient);

let cachedConfig: DatasetConfig | undefined;

async function getDefaultConfig(): Promise<DatasetConfig | null> {
  if (cachedConfig) {
    return cachedConfig;
  }

  try {
    const result = await docClient.send(
      new GetCommand({
        TableName: tableName,
        Key: { pk: "DATASET#__default__", sk: "CONFIG" },
      })
    );
    const config = result.Item as DatasetConfig | undefined;
    if (config) {
      cachedConfig = config;
    }
    return config || null;
  } catch (error) {
    console.error("Error querying dataset config:", error);
    return null;
  }
}

const JUNK_EXTENSIONS = [".tmp", ".crdownload"];

function isJunkFile(s3Key: string): boolean {
  const lower = s3Key.toLowerCase();
  return JUNK_EXTENSIONS.some((ext) => lower.endsWith(ext));
}

function isExtensionAllowed(s3Key: string, allowedExtensions: string[]): boolean {
  if (!allowedExtensions || allowedExtensions.length === 0) return true;
  const ext = s3Key.substring(s3Key.lastIndexOf(".")).toLowerCase();
  return allowedExtensions.includes(ext);
}

/**
 * Main handler - receives array of events, returns array of enriched events.
 * EventBridge Pipes expects output array to have same length and order as input.
 */
export async function handler(events: PipeEnrichmentInput[]): Promise<EnrichedOutput[]> {
  console.log(`Enrichment handler invoked with ${events.length} events`);

  const config = await getDefaultConfig();
  const results: EnrichedOutput[] = [];

  for (const event of events) {
    try {
      const s3Event = event.s3_event;

      if (!s3Event?.Records?.length) {
        results.push({
          original_event: s3Event,
          enrichment_data: { registered: false },
        });
        continue;
      }

      const record = s3Event.Records[0];
      const s3Key = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

      console.log(`Processing: s3://${record.s3.bucket.name}/${s3Key}`);

      // Filter junk files (.tmp, .crdownload)
      if (isJunkFile(s3Key)) {
        console.log(`Filtered junk file: "${s3Key}"`);
        results.push({
          original_event: s3Event,
          enrichment_data: { registered: false },
        });
        continue;
      }

      if (!config) {
        console.log("No default dataset config found");
        results.push({
          original_event: s3Event,
          enrichment_data: { registered: false },
        });
        continue;
      }

      if (!isExtensionAllowed(s3Key, config.allowed_extensions)) {
        console.log(`Extension not allowed for "${s3Key}"`);
        results.push({
          original_event: s3Event,
          enrichment_data: { registered: false },
        });
        continue;
      }

      console.log(`Enriched: dataset_id=${config.dataset_id}, compute_target=${config.compute_target}`);

      results.push({
        original_event: s3Event,
        enrichment_data: {
          registered: true,
          dataset_id: config.dataset_id,
          schema_version: config.schema_version,
          compute_target: config.compute_target,
        },
      });
    } catch (error) {
      console.error("Error enriching event:", error);
      results.push({
        original_event: event.s3_event,
        enrichment_data: { registered: false },
      });
    }
  }

  console.log(`Enrichment complete: ${results.filter(r => r.enrichment_data.registered).length}/${results.length} registered`);
  return results;
}
