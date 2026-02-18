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
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { findSchema, validateCsvColumns, validateJsonFields } from "./column-validator";

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
  validation_status?: "valid" | "invalid" | "skipped";
  validation_error?: string;
}

interface EnrichedOutput {
  original_event: S3Event;
  enrichment_data: EnrichmentData;
}

// --- Globals (reused across invocations in warm Lambda) ---

const tableName = process.env.DYNAMO_TABLE!;
const dynamoClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(dynamoClient);
const s3Client = new S3Client({});

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
 * Validates file structure by reading only the header/first lines.
 * Fast validation without downloading entire file.
 */
async function validateFileStructure(
  bucket: string,
  key: string
): Promise<{ valid: boolean; error?: string }> {
  try {
    const schema = findSchema(key);

    // Skip validation if no schema matched
    if (!schema || schema.requiredColumns.length === 0) {
      return { valid: true };
    }

    const ext = key.substring(key.lastIndexOf(".")).toLowerCase();

    // CSV validation: read first 8KB (header + sample rows)
    if (ext === ".csv") {
      const response = await s3Client.send(
        new GetObjectCommand({
          Bucket: bucket,
          Key: key,
          Range: "bytes=0-8191", // First 8KB
        })
      );

      const content = await response.Body?.transformToString("utf-8");
      if (!content) {
        return { valid: false, error: "Empty file" };
      }

      const lines = content.split("\n").filter((l) => l.trim());
      if (lines.length < 2) {
        return { valid: false, error: "CSV file missing header or data rows" };
      }

      const headers = parseCsvLine(lines[0]);
      const firstRowValues = parseCsvLine(lines[1]);
      const firstRow: Record<string, string> = {};
      for (let i = 0; i < headers.length; i++) {
        firstRow[headers[i]] = firstRowValues[i] || "";
      }

      const validation = validateCsvColumns(headers, firstRow, schema);
      if (!validation.valid) {
        return { valid: false, error: validation.errors.join("; ") };
      }

      return { valid: true };
    }

    // JSON validation: read first 16KB
    if (ext === ".json") {
      const response = await s3Client.send(
        new GetObjectCommand({
          Bucket: bucket,
          Key: key,
          Range: "bytes=0-16383", // First 16KB
        })
      );

      const content = await response.Body?.transformToString("utf-8");
      if (!content) {
        return { valid: false, error: "Empty file" };
      }

      let firstRecord: unknown = null;

      // Try parsing as JSON array
      try {
        const parsed = JSON.parse(content);
        if (Array.isArray(parsed) && parsed.length > 0) {
          firstRecord = parsed[0];
        } else if (!Array.isArray(parsed)) {
          firstRecord = parsed;
        }
      } catch {
        // Try JSONL format (first line)
        const firstLine = content.split("\n").find((l) => l.trim());
        if (firstLine) {
          try {
            firstRecord = JSON.parse(firstLine);
          } catch {
            return { valid: false, error: "Invalid JSON format" };
          }
        }
      }

      if (!firstRecord) {
        return { valid: false, error: "No records found in JSON file" };
      }

      const validation = validateJsonFields(firstRecord, schema);
      if (!validation.valid) {
        return { valid: false, error: validation.errors.join("; ") };
      }

      return { valid: true };
    }

    // Other formats: skip structure validation
    return { valid: true };
  } catch (error) {
    console.error("Error validating file structure:", error);
    // On error, allow file through (fail open) to avoid blocking valid files
    return { valid: true };
  }
}

/**
 * Simple CSV line parser (duplicated from file-processor.ts for independence)
 */
function parseCsvLine(line: string): string[] {
  const result: string[] = [];
  let current = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];

    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === "," && !inQuotes) {
      result.push(current.trim());
      current = "";
    } else {
      current += char;
    }
  }

  result.push(current.trim());
  return result;
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

      // ✅ NEW: Validate file structure (header/columns) before allowing through
      console.log(`Validating file structure for "${s3Key}"...`);
      const structureValidation = await validateFileStructure(
        record.s3.bucket.name,
        s3Key
      );

      if (!structureValidation.valid) {
        console.log(`Structure validation failed for "${s3Key}": ${structureValidation.error}`);
        results.push({
          original_event: s3Event,
          enrichment_data: {
            registered: false,
            validation_status: "invalid",
            validation_error: structureValidation.error,
          },
        });
        continue;
      }

      console.log(`✅ File validated successfully: dataset_id=${config.dataset_id}, compute_target=${config.compute_target}`);

      results.push({
        original_event: s3Event,
        enrichment_data: {
          registered: true,
          dataset_id: config.dataset_id,
          schema_version: config.schema_version,
          compute_target: config.compute_target,
          validation_status: "valid",
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
