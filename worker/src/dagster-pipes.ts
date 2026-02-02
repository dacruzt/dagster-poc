/**
 * Dagster Pipes Protocol Implementation for TypeScript
 * Streams logs and metadata to Dagster UI via stdout
 *
 * The protocol uses special prefixes that Dagster recognizes:
 * - Regular logs go to CloudWatch and are picked up by PipesCloudWatchMessageReader
 * - Structured messages use __DAGSTER_PIPES_MESSAGES prefix
 */

export interface PipesContext {
  runId: string;
  jobName: string;
  extras: Record<string, unknown>;
}

export interface PipesMessage {
  __dagster_pipes_version: string;
  method: string;
  params: Record<string, unknown>;
}

export class DagsterPipes {
  private context: PipesContext | null = null;
  private readonly pipesVersion = "0.1";
  private startTime: number;

  constructor() {
    this.startTime = Date.now();
    this.initContext();
  }

  private initContext(): void {
    const contextEnv = process.env.DAGSTER_PIPES_CONTEXT;
    if (contextEnv) {
      try {
        const decoded = Buffer.from(contextEnv, "base64").toString("utf-8");
        this.context = JSON.parse(decoded);
        this.log("Dagster Pipes context initialized", "info");
        this.log(`Run ID: ${this.context?.runId}`, "info");
      } catch (e) {
        this.log(`Failed to parse Dagster Pipes context: ${e}`, "warning");
      }
    } else {
      this.log("Running in standalone mode (no Dagster Pipes context)", "info");
    }
  }

  /**
   * Check if running within Dagster Pipes context
   */
  isRunningInPipes(): boolean {
    return this.context !== null;
  }

  /**
   * Get extra parameters passed from Dagster
   */
  getExtras(): Record<string, unknown> {
    return this.context?.extras || {};
  }

  /**
   * Get elapsed time in seconds
   */
  getElapsedSeconds(): number {
    return Math.round((Date.now() - this.startTime) / 1000);
  }

  /**
   * Log a message - appears in CloudWatch and Dagster UI
   */
  log(message: string, level: "info" | "warning" | "error" | "debug" = "info"): void {
    const timestamp = new Date().toISOString();
    const elapsed = this.getElapsedSeconds();
    const levelUpper = level.toUpperCase().padEnd(7);

    // Format: [timestamp] [LEVEL] [elapsed] message
    // This format is picked up by CloudWatch and shown in Dagster
    const formattedMessage = `[${timestamp}] [${levelUpper}] [${elapsed}s] ${message}`;

    if (level === "error") {
      console.error(formattedMessage);
    } else {
      console.log(formattedMessage);
    }
  }

  /**
   * Log a section header for better visibility
   */
  logSection(title: string): void {
    const separator = "=".repeat(50);
    console.log(`\n${separator}`);
    console.log(`  ${title}`);
    console.log(`${separator}\n`);
  }

  /**
   * Report progress with a progress bar
   */
  reportProgress(current: number, total: number, label?: string): void {
    const percentage = Math.round((current / total) * 100);
    const barLength = 30;
    const filled = Math.round((percentage / 100) * barLength);
    const bar = "█".repeat(filled) + "░".repeat(barLength - filled);

    const progressLabel = label || `Progress`;
    this.log(`${progressLabel}: [${bar}] ${percentage}% (${current}/${total})`);
  }

  /**
   * Report an asset materialization with metadata
   */
  reportAssetMaterialization(
    assetKey: string,
    metadata: Record<string, unknown>
  ): void {
    this.log(`Asset materialized: ${assetKey}`);
    this.sendMessage("report_asset_materialization", {
      asset_key: assetKey,
      metadata: this.formatMetadata(metadata),
    });
  }

  /**
   * Report custom metadata (row counts, file sizes, etc.)
   */
  reportMetadata(metadata: Record<string, unknown>): void {
    this.logSection("Processing Metadata");
    for (const [key, value] of Object.entries(metadata)) {
      this.log(`  ${key}: ${value}`);
    }

    this.sendMessage("report_custom_message", {
      payload: this.formatMetadata(metadata),
    });
  }

  /**
   * Report successful completion
   */
  reportSuccess(metadata?: Record<string, unknown>): void {
    this.logSection("PROCESSING COMPLETED SUCCESSFULLY");

    if (metadata) {
      for (const [key, value] of Object.entries(metadata)) {
        this.log(`  ${key}: ${value}`);
      }
    }

    this.log(`Total elapsed time: ${this.getElapsedSeconds()} seconds`);

    this.sendMessage("report_custom_message", {
      payload: {
        status: "success",
        elapsed_seconds: this.getElapsedSeconds(),
        ...this.formatMetadata(metadata || {}),
      },
    });
  }

  /**
   * Report failure
   */
  reportFailure(error: Error | string, metadata?: Record<string, unknown>): void {
    const errorMessage = error instanceof Error ? error.message : error;
    const errorStack = error instanceof Error ? error.stack : undefined;

    this.logSection("PROCESSING FAILED");
    this.log(`Error: ${errorMessage}`, "error");
    if (errorStack) {
      this.log(`Stack trace:\n${errorStack}`, "error");
    }
    this.log(`Total elapsed time: ${this.getElapsedSeconds()} seconds`);

    this.sendMessage("report_custom_message", {
      payload: {
        status: "failure",
        error: errorMessage,
        stack: errorStack,
        elapsed_seconds: this.getElapsedSeconds(),
        ...this.formatMetadata(metadata || {}),
      },
    });
  }

  private formatMetadata(
    metadata: Record<string, unknown>
  ): Record<string, { raw_value: unknown; type: string }> {
    const formatted: Record<string, { raw_value: unknown; type: string }> = {};

    for (const [key, value] of Object.entries(metadata)) {
      let type = "text";
      if (typeof value === "number") {
        type = Number.isInteger(value) ? "int" : "float";
      } else if (typeof value === "boolean") {
        type = "bool";
      } else if (value instanceof Date) {
        type = "timestamp";
      }

      formatted[key] = { raw_value: value, type };
    }

    return formatted;
  }

  private sendMessage(method: string, params: Record<string, unknown>): void {
    const message: PipesMessage = {
      __dagster_pipes_version: this.pipesVersion,
      method,
      params,
    };

    // Dagster Pipes protocol: messages are sent to stdout with special prefix
    console.log(`__DAGSTER_PIPES_MESSAGES_${JSON.stringify(message)}`);
  }
}

// Singleton instance
export const pipes = new DagsterPipes();
