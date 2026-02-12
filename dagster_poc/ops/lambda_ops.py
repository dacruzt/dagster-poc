"""
Lambda Operations - Thin Python wrapper that delegates to TypeScript.
The actual Lambda invocation and CloudWatch log streaming lives in dagster_ts/src/lambda-cli.ts
"""

import json
import os
import subprocess
import threading

from dagster import Config, OpExecutionContext, Out, op

# Path to the compiled TypeScript lambda CLI
LAMBDA_CLI = os.path.join(
    os.path.dirname(__file__), "..", "..", "dagster_ts", "dist", "lambda-cli.js"
)


class LambdaProcessFileConfig(Config):
    """Configuration for Lambda file processing task."""

    s3_bucket: str
    s3_key: str


def _stream_stderr(proc, context: OpExecutionContext):
    """Stream stderr from the TS process to Dagster logs in real-time."""
    for line in iter(proc.stderr.readline, ""):
        line = line.strip()
        if line:
            context.log.info(f"[TS] {line}")


@op(
    out={"result": Out(dict)},
    tags={"kind": "lambda"},
)
def process_file_with_lambda(
    context: OpExecutionContext,
    config: LambdaProcessFileConfig,
) -> dict:
    """
    Process a small file (< 50 MB) using AWS Lambda via the TypeScript lambda-cli.
    The TS process invokes the Lambda, streams CloudWatch logs, and returns the result.
    """

    context.log.info("=" * 50)
    context.log.info("Starting Lambda Processing (TypeScript)")
    context.log.info("=" * 50)
    context.log.info(f"File: s3://{config.s3_bucket}/{config.s3_key}")

    args = ["node", LAMBDA_CLI, config.s3_bucket, config.s3_key, context.run_id]

    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ},
    )

    # Stream stderr (logs) in a separate thread for real-time output
    log_thread = threading.Thread(target=_stream_stderr, args=(proc, context))
    log_thread.daemon = True
    log_thread.start()

    # Wait for process to finish (max 5 min for Lambda)
    try:
        stdout, _ = proc.communicate(timeout=300)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise Exception("lambda-cli timed out after 5 minutes")

    log_thread.join(timeout=5)

    if proc.returncode != 0:
        raise Exception(f"lambda-cli failed with exit code {proc.returncode}")

    # Parse result JSON from stdout
    result = json.loads(stdout.strip())

    context.log.info("=" * 50)
    context.log.info(f"Result: {result['status']}")
    context.log.info("=" * 50)

    return result
