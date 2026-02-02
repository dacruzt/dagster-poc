/**
 * DynamoDB State Manager
 * Manages ingest state for tracking file processing
 */

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  UpdateCommand,
  QueryCommand,
} from "@aws-sdk/lib-dynamodb";
import { pipes } from "./dagster-pipes";

export type IngestStatus =
  | "PENDING"
  | "VALIDATING"
  | "PROCESSING"
  | "COMPLETED"
  | "FAILED";

export interface IngestState {
  pk: string; // FILE#{bucket}#{key}
  sk: string; // STATE#{timestamp}
  bucket: string;
  key: string;
  status: IngestStatus;
  fileSize: number;
  rowCount?: number;
  chunksProcessed?: number;
  totalChunks?: number;
  errorMessage?: string;
  startedAt: string;
  completedAt?: string;
  dagsterRunId?: string;
  taskSize?: string;
  metadata?: Record<string, unknown>;
  ttl?: number;
}

export class DynamoStateManager {
  private readonly docClient: DynamoDBDocumentClient;
  private readonly tableName: string;

  constructor(region: string, tableName: string) {
    const client = new DynamoDBClient({ region });
    this.docClient = DynamoDBDocumentClient.from(client);
    this.tableName = tableName;
  }

  /**
   * Create a new ingest state record
   */
  async createIngestState(
    bucket: string,
    key: string,
    fileSize: number,
    dagsterRunId?: string,
    taskSize?: string
  ): Promise<IngestState> {
    const now = new Date().toISOString();
    const ttl = Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60; // 30 days

    const state: IngestState = {
      pk: `FILE#${bucket}#${key}`,
      sk: `STATE#${now}`,
      bucket,
      key,
      status: "PENDING",
      fileSize,
      startedAt: now,
      dagsterRunId,
      taskSize,
      ttl,
    };

    await this.docClient.send(
      new PutCommand({
        TableName: this.tableName,
        Item: state,
      })
    );

    pipes.log(`Created ingest state for ${bucket}/${key}`);
    return state;
  }

  /**
   * Update the status of an ingest
   */
  async updateStatus(
    pk: string,
    sk: string,
    status: IngestStatus,
    updates?: Partial<IngestState>
  ): Promise<void> {
    const updateExpressions: string[] = ["#status = :status"];
    const expressionNames: Record<string, string> = { "#status": "status" };
    const expressionValues: Record<string, unknown> = { ":status": status };

    if (updates) {
      for (const [key, value] of Object.entries(updates)) {
        if (key !== "pk" && key !== "sk" && key !== "status") {
          updateExpressions.push(`#${key} = :${key}`);
          expressionNames[`#${key}`] = key;
          expressionValues[`:${key}`] = value;
        }
      }
    }

    if (status === "COMPLETED" || status === "FAILED") {
      updateExpressions.push("#completedAt = :completedAt");
      expressionNames["#completedAt"] = "completedAt";
      expressionValues[":completedAt"] = new Date().toISOString();
    }

    await this.docClient.send(
      new UpdateCommand({
        TableName: this.tableName,
        Key: { pk, sk },
        UpdateExpression: `SET ${updateExpressions.join(", ")}`,
        ExpressionAttributeNames: expressionNames,
        ExpressionAttributeValues: expressionValues,
      })
    );

    pipes.log(`Updated status to ${status} for ${pk}`);
  }

  /**
   * Update processing progress
   */
  async updateProgress(
    pk: string,
    sk: string,
    chunksProcessed: number,
    totalChunks: number,
    rowCount?: number
  ): Promise<void> {
    const updates: Partial<IngestState> = {
      chunksProcessed,
      totalChunks,
    };

    if (rowCount !== undefined) {
      updates.rowCount = rowCount;
    }

    await this.updateStatus(pk, sk, "PROCESSING", updates);
  }

  /**
   * Mark ingest as completed
   */
  async markCompleted(
    pk: string,
    sk: string,
    rowCount: number,
    metadata?: Record<string, unknown>
  ): Promise<void> {
    await this.updateStatus(pk, sk, "COMPLETED", {
      rowCount,
      metadata,
    });
  }

  /**
   * Mark ingest as failed
   */
  async markFailed(pk: string, sk: string, errorMessage: string): Promise<void> {
    await this.updateStatus(pk, sk, "FAILED", { errorMessage });
  }

  /**
   * Get the latest state for a file
   */
  async getLatestState(bucket: string, key: string): Promise<IngestState | null> {
    const result = await this.docClient.send(
      new QueryCommand({
        TableName: this.tableName,
        KeyConditionExpression: "pk = :pk",
        ExpressionAttributeValues: {
          ":pk": `FILE#${bucket}#${key}`,
        },
        ScanIndexForward: false, // Latest first
        Limit: 1,
      })
    );

    return (result.Items?.[0] as IngestState) || null;
  }

  /**
   * Get all states for a file (history)
   */
  async getStateHistory(bucket: string, key: string): Promise<IngestState[]> {
    const result = await this.docClient.send(
      new QueryCommand({
        TableName: this.tableName,
        KeyConditionExpression: "pk = :pk",
        ExpressionAttributeValues: {
          ":pk": `FILE#${bucket}#${key}`,
        },
        ScanIndexForward: false,
      })
    );

    return (result.Items as IngestState[]) || [];
  }
}
