"""
SQS Sensor - Thin Python wrapper that delegates to TypeScript.
The actual SQS polling and S3 event parsing logic lives in dagster_ts/src/sensor-cli.ts

Routes files to Lambda (< 50 MB) or Fargate (>= 50 MB) based on taskSize.
Messages are deleted from SQS only after RunRequests are successfully yielded.
"""

import json
import os
import subprocess

import boto3
from dagster import DefaultSensorStatus, RunConfig, RunRequest, SensorEvaluationContext, sensor

from ..jobs.fargate_job import fargate_job
from ..jobs.lambda_job import lambda_job
from ..ops.fargate_ops import ProcessFileConfig
from ..ops.lambda_ops import LambdaProcessFileConfig

# Path to the compiled TypeScript sensor CLI
SENSOR_CLI = os.path.join(
    os.path.dirname(__file__), "..", "..", "dagster_ts", "dist", "sensor-cli.js"
)


@sensor(jobs=[fargate_job, lambda_job], minimum_interval_seconds=30, default_status=DefaultSensorStatus.RUNNING)
def s3_file_sensor(context: SensorEvaluationContext):
    """
    Sensor that calls the TypeScript sensor-cli to poll SQS for S3 file events.
    The TS process does all the work; Python just bridges the results to Dagster.

    Messages are NOT deleted by the TS sensor-cli. Instead, this Python sensor
    deletes them after successfully yielding all RunRequests. If this sensor
    fails, messages stay in SQS and get retried (or go to DLQ after 3 attempts).

    Routing:
      - taskSize == "lambda" (< 50 MB)  -> lambda_job
      - taskSize == medium/large/xlarge  -> fargate_job
    """

    try:
        result = subprocess.run(
            ["node", SENSOR_CLI],
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ},
        )

        # TS logs go to stderr - forward them to Dagster
        for line in result.stderr.strip().splitlines():
            if line:
                context.log.info(f"[TS] {line}")

        if result.returncode != 0:
            context.log.error(f"sensor-cli failed (exit {result.returncode})")
            return

        if not result.stdout.strip():
            return

        # Parse JSON output from TS: { runRequests: [...], receiptHandles: [...] }
        output = json.loads(result.stdout)
        requests = output.get("runRequests", [])
        receipt_handles = output.get("receiptHandles", [])

        if not requests:
            # No run requests but we still have receipt handles to clean up
            # (e.g. messages with only unregistered files)
            _delete_sqs_messages(context, receipt_handles)
            return

        for req in requests:
            s3_bucket = req["config"]["s3Bucket"]
            s3_key = req["config"]["s3Key"]
            task_size = req["config"].get("taskSize", "")

            context.log.info(f"File detected: s3://{s3_bucket}/{s3_key} (taskSize={task_size})")

            if task_size == "lambda":
                # Small files (< 50 MB) -> Lambda
                context.log.info(f"Routing to Lambda: {s3_key}")
                yield RunRequest(
                    run_key=req["runKey"],
                    job_name="lambda_job",
                    run_config=RunConfig(
                        ops={
                            "process_file_with_lambda": LambdaProcessFileConfig(
                                s3_bucket=s3_bucket,
                                s3_key=s3_key,
                            )
                        }
                    ),
                    tags={**req.get("tags", {}), "execution_type": "lambda"},
                )
            else:
                # Larger files (>= 50 MB) -> Fargate
                context.log.info(f"Routing to Fargate ({task_size}): {s3_key}")
                yield RunRequest(
                    run_key=req["runKey"],
                    job_name="fargate_job",
                    run_config=RunConfig(
                        ops={
                            "process_file_with_pipes": ProcessFileConfig(
                                s3_bucket=s3_bucket,
                                s3_key=s3_key,
                                task_size=task_size,
                            )
                        }
                    ),
                    tags={**req.get("tags", {}), "execution_type": "fargate"},
                )

        # All RunRequests yielded successfully — now delete messages from SQS
        _delete_sqs_messages(context, receipt_handles)

    except subprocess.TimeoutExpired:
        context.log.error("sensor-cli timed out")
    except json.JSONDecodeError as e:
        context.log.error(f"Invalid JSON from sensor-cli: {e}")
    except Exception as e:
        context.log.error(f"Error running sensor-cli: {e}")


def _delete_sqs_messages(context: SensorEvaluationContext, receipt_handles: list[str]):
    """Delete SQS messages by receipt handle after successful processing."""
    if not receipt_handles:
        return

    queue_url = os.environ.get("SQS_QUEUE_URL")
    if not queue_url:
        context.log.warning("SQS_QUEUE_URL not set, cannot delete messages")
        return

    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    sqs_client = boto3.client("sqs", region_name=region)

    for handle in receipt_handles:
        try:
            sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=handle)
        except Exception as e:
            context.log.warning(f"Failed to delete SQS message: {e}")

    context.log.info(f"Deleted {len(receipt_handles)} SQS message(s)")
