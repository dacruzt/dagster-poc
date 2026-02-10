"""
SQS Sensor - Thin Python wrapper that delegates to TypeScript.
The actual SQS polling and S3 event parsing logic lives in dagster_ts/src/sensor-cli.ts
"""

import json
import os
import subprocess

from dagster import RunConfig, RunRequest, SensorEvaluationContext, sensor

from ..jobs.fargate_job import fargate_job
from ..ops.fargate_ops import ProcessFileConfig

# Path to the compiled TypeScript sensor CLI
SENSOR_CLI = os.path.join(
    os.path.dirname(__file__), "..", "..", "dagster_ts", "dist", "sensor-cli.js"
)


@sensor(job=fargate_job, minimum_interval_seconds=30)
def s3_file_sensor(context: SensorEvaluationContext):
    """
    Sensor that calls the TypeScript sensor-cli to poll SQS for S3 file events.
    The TS process does all the work; Python just bridges the results to Dagster.
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

        # Parse JSON run requests from TS stdout
        requests = json.loads(result.stdout)

        for req in requests:
            context.log.info(f"File detected: s3://{req['config']['s3Bucket']}/{req['config']['s3Key']}")

            yield RunRequest(
                run_key=req["runKey"],
                run_config=RunConfig(
                    ops={
                        "process_file_with_pipes": ProcessFileConfig(
                            s3_bucket=req["config"]["s3Bucket"],
                            s3_key=req["config"]["s3Key"],
                            task_size=req["config"].get("taskSize"),
                        )
                    }
                ),
                tags=req.get("tags", {}),
            )

    except subprocess.TimeoutExpired:
        context.log.error("sensor-cli timed out")
    except json.JSONDecodeError as e:
        context.log.error(f"Invalid JSON from sensor-cli: {e}")
    except Exception as e:
        context.log.error(f"Error running sensor-cli: {e}")
