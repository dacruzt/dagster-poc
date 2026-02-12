"""
Fargate Operations - Thin Python wrapper that delegates to TypeScript.
The actual ECS task launching and CloudWatch log streaming lives in dagster_ts/src/fargate-cli.ts
"""

import json
import os
import subprocess
import threading

from dagster import Config, OpExecutionContext, Out, op

# Path to the compiled TypeScript fargate CLI
FARGATE_CLI = os.path.join(
    os.path.dirname(__file__), "..", "..", "dagster_ts", "dist", "fargate-cli.js"
)


class ProcessFileConfig(Config):
    """Configuration for file processing task."""

    s3_bucket: str
    s3_key: str
    task_size: str | None = None  # auto-detect if None


def _stream_stderr(proc, context: OpExecutionContext, error_lines: list):
    """Stream stderr from the TS process to Dagster logs in real-time."""
    for line in iter(proc.stderr.readline, ""):
        line = line.strip()
        if line:
            context.log.info(f"[TS] {line}")
            if "[ERROR]" in line:
                error_lines.append(line)


@op(
    out={"result": Out(dict)},
    tags={"kind": "ecs"},
)
def process_file_with_pipes(
    context: OpExecutionContext,
    config: ProcessFileConfig,
) -> dict:
    """
    Process a file using ECS Fargate via the TypeScript fargate-cli.
    The TS process launches the task, streams CloudWatch logs, and returns the result.
    """

    context.log.info("=" * 50)
    context.log.info("Starting Fargate Processing (TypeScript)")
    context.log.info("=" * 50)
    context.log.info(f"File: s3://{config.s3_bucket}/{config.s3_key}")

    args = ["node", FARGATE_CLI, config.s3_bucket, config.s3_key]
    if config.task_size:
        args.append(config.task_size)
    else:
        args.append("")
    args.append(context.run_id)

    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ},
    )

    # Stream stderr (logs) in a separate thread for real-time output
    error_lines = []
    log_thread = threading.Thread(target=_stream_stderr, args=(proc, context, error_lines))
    log_thread.daemon = True
    log_thread.start()

    # Wait for process to finish (max 15 min)
    try:
        stdout, _ = proc.communicate(timeout=900)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise Exception("fargate-cli timed out after 15 minutes")

    log_thread.join(timeout=5)

    if proc.returncode != 0:
        error_detail = error_lines[-1] if error_lines else "See logs above for details"
        raise Exception(f"fargate-cli failed (exit code {proc.returncode}): {error_detail}")

    # Parse result JSON from stdout
    result = json.loads(stdout.strip())

    context.log.info("=" * 50)
    context.log.info(f"Result: {result['status']}")
    context.log.info("=" * 50)

    return result
