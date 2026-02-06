/**
 * Dagster Worker - TypeScript
 * Processes files from S3 in chunks with Dagster Pipes integration
 */

import { pipes } from "./dagster-pipes";
import { S3ChunkedReader, S3FileInfo, ChunkInfo } from "./s3-chunked-reader";
import { DynamoStateManager, IngestState } from "./dynamo-state";

interface WorkerConfig {
  bucket: string;
  key: string;
  region: string;
  dynamoTable: string;
  chunkSizeMB: number;
  dagsterRunId?: string;
}

interface ProcessingResult {
  success: boolean;
  rowCount: number;
  bytesProcessed: number;
  chunksProcessed: number;
  durationMs: number;
  error?: string;
}

class FileProcessor {
  private readonly s3Reader: S3ChunkedReader;
  private readonly stateManager: DynamoStateManager;
  private rowCount: number = 0;

  constructor(config: WorkerConfig) {
    this.s3Reader = new S3ChunkedReader(config.region, config.chunkSizeMB);
    this.stateManager = new DynamoStateManager(config.region, config.dynamoTable);
  }

  /**
   * Main processing entry point
   */
  async process(config: WorkerConfig): Promise<ProcessingResult> {
    const startTime = Date.now();
    let state: IngestState | null = null;

    try {
      // 1. Get file info
      pipes.log(`Fetching file info: s3://${config.bucket}/${config.key}`);
      const fileInfo = await this.s3Reader.getFileInfo(config.bucket, config.key);

      pipes.log(`File size: ${this.formatBytes(fileInfo.size)}`);
      pipes.log(`Content type: ${fileInfo.contentType || "unknown"}`);

      // 2. Determine task size and validate
      const recommendedSize = this.s3Reader.getRecommendedTaskSize(fileInfo.size);
      const currentSize = process.env.TASK_SIZE || "small";

      if (recommendedSize !== currentSize) {
        pipes.log(
          `Warning: Current task size (${currentSize}) may not be optimal for file size. Recommended: ${recommendedSize}`,
          "warning"
        );
      }

      // 3. Create state record
      state = await this.stateManager.createIngestState(
        config.bucket,
        config.key,
        fileInfo.size,
        config.dagsterRunId,
        currentSize
      );

      // 4. Update status to processing
      await this.stateManager.updateStatus(state.pk, state.sk, "PROCESSING");

      // 5. Process file in chunks
      pipes.log("Starting chunked processing...");
      const result = await this.processFileInChunks(fileInfo, state);

      // 6. Mark as completed
      await this.stateManager.markCompleted(state.pk, state.sk, this.rowCount, {
        bytesProcessed: result.bytesProcessed,
        chunksProcessed: result.chunksProcessed,
        durationMs: Date.now() - startTime,
      });

      // 7. Report success to Dagster
      pipes.reportAssetMaterialization(`${config.bucket}/${config.key}`, {
        row_count: this.rowCount,
        bytes_processed: result.bytesProcessed,
        chunks_processed: result.chunksProcessed,
        file_size: fileInfo.size,
        task_size: currentSize,
      });

      pipes.reportSuccess({
        row_count: this.rowCount,
        bytes_processed: result.bytesProcessed,
        duration_ms: Date.now() - startTime,
      });

      return {
        success: true,
        rowCount: this.rowCount,
        bytesProcessed: result.bytesProcessed,
        chunksProcessed: result.chunksProcessed,
        durationMs: Date.now() - startTime,
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);

      pipes.log(`Processing failed: ${errorMessage}`, "error");

      // Update state to failed
      if (state) {
        await this.stateManager.markFailed(state.pk, state.sk, errorMessage);
      }

      // Report failure to Dagster
      pipes.reportFailure(error instanceof Error ? error : new Error(errorMessage), {
        row_count: this.rowCount,
        duration_ms: Date.now() - startTime,
      });

      return {
        success: false,
        rowCount: this.rowCount,
        bytesProcessed: 0,
        chunksProcessed: 0,
        durationMs: Date.now() - startTime,
        error: errorMessage,
      };
    }
  }

  /**
   * Process file chunks
   */
  private async processFileInChunks(
    fileInfo: S3FileInfo,
    state: IngestState
  ): Promise<{ bytesProcessed: number; chunksProcessed: number }> {
    const contentType = fileInfo.contentType?.toLowerCase() || "";

    // Determine processing strategy based on content type
    if (contentType.includes("csv") || fileInfo.key.endsWith(".csv")) {
      return this.processCsv(fileInfo, state);
    } else if (contentType.includes("json") || fileInfo.key.endsWith(".json")) {
      return this.processJson(fileInfo, state);
    } else {
      // Generic binary processing
      return this.processBinary(fileInfo, state);
    }
  }

  /**
   * Process CSV file line by line
   */
  private async processCsv(
    fileInfo: S3FileInfo,
    state: IngestState
  ): Promise<{ bytesProcessed: number; chunksProcessed: number }> {
    pipes.log("Processing as CSV file");

    let bytesProcessed = 0;
    let isHeader = true;
    let headers: string[] = [];
    const batchSize = 1000;
    let batch: Record<string, string>[] = [];

    for await (const { line, lineNumber } of this.s3Reader.streamLines(
      fileInfo.bucket,
      fileInfo.key
    )) {
      bytesProcessed += Buffer.byteLength(line, "utf-8");

      if (isHeader) {
        headers = this.parseCsvLine(line);
        isHeader = false;
        continue;
      }

      const values = this.parseCsvLine(line);
      const row: Record<string, string> = {};

      for (let i = 0; i < headers.length; i++) {
        row[headers[i]] = values[i] || "";
      }

      batch.push(row);
      this.rowCount++;

      // Process batch
      if (batch.length >= batchSize) {
        await this.processBatch(batch);
        batch = [];

        // Update progress
        if (this.rowCount % 10000 === 0) {
          pipes.reportProgress(
            bytesProcessed,
            fileInfo.size,
            `Processed ${this.rowCount.toLocaleString()} rows`
          );

          await this.stateManager.updateProgress(
            state.pk,
            state.sk,
            Math.floor(bytesProcessed / (1024 * 1024)),
            Math.ceil(fileInfo.size / (1024 * 1024)),
            this.rowCount
          );
        }
      }
    }

    // Process remaining batch
    if (batch.length > 0) {
      await this.processBatch(batch);
    }

    return { bytesProcessed, chunksProcessed: 1 };
  }

  /**
   * Process JSON file (JSON lines or array)
   */
  private async processJson(
    fileInfo: S3FileInfo,
    state: IngestState
  ): Promise<{ bytesProcessed: number; chunksProcessed: number }> {
    pipes.log("Processing as JSON file");

    let bytesProcessed = 0;
    const batchSize = 1000;
    let batch: unknown[] = [];
    let entireContent = "";
    let isJsonArray = false;

    // First, try to determine if this is a JSON array or JSONL
    for await (const { line } of this.s3Reader.streamLines(
      fileInfo.bucket,
      fileInfo.key
    )) {
      entireContent += line + "\n";
    }

    bytesProcessed = Buffer.byteLength(entireContent, "utf-8");

    // Try parsing as JSON array first
    try {
      const parsed = JSON.parse(entireContent);
      if (Array.isArray(parsed)) {
        pipes.log(`Detected JSON array format with ${parsed.length} items`);
        isJsonArray = true;

        // Process array items
        for (const record of parsed) {
          batch.push(record);
          this.rowCount++;

          if (batch.length >= batchSize) {
            await this.processBatch(batch);
            batch = [];

            if (this.rowCount % 10000 === 0) {
              pipes.reportProgress(
                this.rowCount,
                parsed.length,
                `Processed ${this.rowCount.toLocaleString()} records`
              );

              await this.stateManager.updateProgress(
                state.pk,
                state.sk,
                this.rowCount,
                parsed.length,
                this.rowCount
              );
            }
          }
        }
      } else {
        // Single JSON object
        pipes.log("Detected single JSON object");
        batch.push(parsed);
        this.rowCount++;
      }
    } catch {
      // Not a JSON array, try JSONL format
      pipes.log("Processing as JSON Lines format");
      const lines = entireContent.split("\n");

      for (const line of lines) {
        const trimmedLine = line.trim();
        if (!trimmedLine) continue;

        try {
          const record = JSON.parse(trimmedLine);
          batch.push(record);
          this.rowCount++;

          if (batch.length >= batchSize) {
            await this.processBatch(batch);
            batch = [];

            if (this.rowCount % 10000 === 0) {
              pipes.reportProgress(
                this.rowCount,
                lines.length,
                `Processed ${this.rowCount.toLocaleString()} records`
              );

              await this.stateManager.updateProgress(
                state.pk,
                state.sk,
                this.rowCount,
                lines.length,
                this.rowCount
              );
            }
          }
        } catch {
          // Skip invalid JSON lines silently for JSONL format
        }
      }
    }

    if (batch.length > 0) {
      await this.processBatch(batch);
    }

    return { bytesProcessed, chunksProcessed: 1 };
  }

  /**
   * Process binary file in chunks
   */
  private async processBinary(
    fileInfo: S3FileInfo,
    state: IngestState
  ): Promise<{ bytesProcessed: number; chunksProcessed: number }> {
    pipes.log("Processing as binary file");

    const result = await this.s3Reader.processInChunks(
      fileInfo,
      async (data: Buffer, chunkInfo: ChunkInfo) => {
        // Example: compute checksum, transform data, etc.
        this.rowCount += data.length;

        await this.stateManager.updateProgress(
          state.pk,
          state.sk,
          chunkInfo.chunkIndex + 1,
          chunkInfo.totalChunks,
          this.rowCount
        );

        // Simulate some processing
        await this.processChunk(data, chunkInfo);
      }
    );

    return result;
  }

  /**
   * Process a batch of records
   */
  private async processBatch(batch: unknown[]): Promise<void> {
    // Implement your transformation logic here
    // Example: validate, transform, write to another location
    pipes.log(`Processing batch of ${batch.length} records`);

    // Simulate processing time
    await new Promise((resolve) => setTimeout(resolve, 10));
  }

  /**
   * Process a binary chunk
   */
  private async processChunk(data: Buffer, chunkInfo: ChunkInfo): Promise<void> {
    // Implement your chunk processing logic here
    pipes.log(
      `Processing chunk ${chunkInfo.chunkIndex + 1}/${chunkInfo.totalChunks} (${this.formatBytes(data.length)})`
    );

    // Simulate processing time
    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  /**
   * Simple CSV line parser
   */
  private parseCsvLine(line: string): string[] {
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
   * Format bytes to human readable
   */
  private formatBytes(bytes: number): string {
    if (bytes === 0) return "0 Bytes";
    const k = 1024;
    const sizes = ["Bytes", "KB", "MB", "GB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  }
}

/**
 * Main entry point
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
