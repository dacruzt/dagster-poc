/**
 * S3 Chunked Reader
 * Reads large files from S3 in chunks to avoid OOM errors
 */

import {
  S3Client,
  GetObjectCommand,
  HeadObjectCommand,
} from "@aws-sdk/client-s3";
import { Readable } from "stream";
import { pipes } from "./dagster-pipes";

export interface S3FileInfo {
  bucket: string;
  key: string;
  size: number;
  contentType?: string;
  lastModified?: Date;
}

export interface ChunkInfo {
  chunkIndex: number;
  totalChunks: number;
  startByte: number;
  endByte: number;
  size: number;
}

export type ChunkProcessor = (
  data: Buffer,
  chunkInfo: ChunkInfo
) => Promise<void>;

export class S3ChunkedReader {
  private readonly s3Client: S3Client;
  private readonly chunkSizeMB: number;

  constructor(region: string, chunkSizeMB: number = 10) {
    this.s3Client = new S3Client({ region });
    this.chunkSizeMB = chunkSizeMB;
  }

  /**
   * Get file metadata from S3
   */
  async getFileInfo(bucket: string, key: string): Promise<S3FileInfo> {
    const command = new HeadObjectCommand({ Bucket: bucket, Key: key });
    const response = await this.s3Client.send(command);

    return {
      bucket,
      key,
      size: response.ContentLength || 0,
      contentType: response.ContentType,
      lastModified: response.LastModified,
    };
  }

  /**
   * Determine optimal task size based on file size
   */
  getRecommendedTaskSize(fileSizeBytes: number): string {
    const sizeMB = fileSizeBytes / (1024 * 1024);

    if (sizeMB < 50) return "small";
    if (sizeMB < 200) return "medium";
    if (sizeMB < 500) return "large";
    return "xlarge";
  }

  /**
   * Process file in chunks using Range requests
   */
  async processInChunks(
    fileInfo: S3FileInfo,
    processor: ChunkProcessor
  ): Promise<{ chunksProcessed: number; bytesProcessed: number }> {
    const chunkSize = this.chunkSizeMB * 1024 * 1024;
    const totalChunks = Math.ceil(fileInfo.size / chunkSize);

    pipes.log(
      `Processing file in ${totalChunks} chunks (${this.chunkSizeMB}MB each)`
    );

    let bytesProcessed = 0;

    for (let i = 0; i < totalChunks; i++) {
      const startByte = i * chunkSize;
      const endByte = Math.min(startByte + chunkSize - 1, fileInfo.size - 1);

      const chunkInfo: ChunkInfo = {
        chunkIndex: i,
        totalChunks,
        startByte,
        endByte,
        size: endByte - startByte + 1,
      };

      pipes.reportProgress(i + 1, totalChunks, `Processing chunk ${i + 1}/${totalChunks}`);

      try {
        const data = await this.fetchChunk(
          fileInfo.bucket,
          fileInfo.key,
          startByte,
          endByte
        );

        await processor(data, chunkInfo);
        bytesProcessed += data.length;
      } catch (error) {
        pipes.log(`Error processing chunk ${i + 1}: ${error}`, "error");
        throw error;
      }
    }

    return { chunksProcessed: totalChunks, bytesProcessed };
  }

  /**
   * Fetch a specific byte range from S3
   */
  private async fetchChunk(
    bucket: string,
    key: string,
    startByte: number,
    endByte: number
  ): Promise<Buffer> {
    const command = new GetObjectCommand({
      Bucket: bucket,
      Key: key,
      Range: `bytes=${startByte}-${endByte}`,
    });

    const response = await this.s3Client.send(command);

    if (!response.Body) {
      throw new Error("Empty response body from S3");
    }

    // Convert stream to buffer
    const stream = response.Body as Readable;
    const chunks: Buffer[] = [];

    for await (const chunk of stream) {
      chunks.push(Buffer.from(chunk));
    }

    return Buffer.concat(chunks);
  }

  /**
   * Stream file for line-by-line processing (for CSV/JSON lines)
   */
  async *streamLines(
    bucket: string,
    key: string
  ): AsyncGenerator<{ line: string; lineNumber: number }> {
    const command = new GetObjectCommand({ Bucket: bucket, Key: key });
    const response = await this.s3Client.send(command);

    if (!response.Body) {
      throw new Error("Empty response body from S3");
    }

    const stream = response.Body as Readable;
    let buffer = "";
    let lineNumber = 0;

    for await (const chunk of stream) {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        lineNumber++;
        if (line.trim()) {
          yield { line, lineNumber };
        }
      }
    }

    // Handle last line if no trailing newline
    if (buffer.trim()) {
      lineNumber++;
      yield { line: buffer, lineNumber };
    }
  }
}
