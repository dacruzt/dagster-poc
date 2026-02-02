"""
Fargate Operations for TypeScript Worker
Launches ECS Fargate tasks and streams CloudWatch logs to Dagster UI
"""

import time

import boto3
from dagster import Config, OpExecutionContext, Out, op

from ..resources import ECSResource, S3Resource


class ProcessFileConfig(Config):
    """Configuration for file processing task."""

    s3_bucket: str
    s3_key: str
    task_size: str | None = None  # auto-detect if None


@op(
    out={"result": Out(dict)},
    tags={"kind": "ecs"},
)
def process_file_with_pipes(
    context: OpExecutionContext,
    config: ProcessFileConfig,
    ecs: ECSResource,
    s3: S3Resource,
) -> dict:
    """
    Process a file using ECS Fargate with TypeScript worker.

    Features:
    - Auto-scales resources based on file size
    - Streams Fargate logs to Dagster UI via CloudWatch
    - Automatically stops container when processing completes
    - Reports success/failure with metadata
    """

    context.log.info("=" * 50)
    context.log.info("Starting Fargate Processing")
    context.log.info("=" * 50)
    context.log.info(f"File: s3://{config.s3_bucket}/{config.s3_key}")

    # 1. Get file size and determine task size
    file_size = s3.get_file_size(config.s3_bucket, config.s3_key)
    file_size_mb = file_size / (1024 * 1024)
    task_size = config.task_size or s3.get_recommended_task_size(file_size)

    context.log.info(f"File size: {file_size_mb:.2f} MB")
    context.log.info(f"Task size: {task_size}")

    # 2. Get task definition for this size
    task_definition = ecs.get_task_definition(task_size)
    if not task_definition:
        raise ValueError(f"No task definition found for size: {task_size}")

    context.log.info(f"Task definition: {task_definition}")

    # 3. Launch Fargate task
    context.log.info("Launching Fargate task...")

    ecs_client = ecs.get_client()
    logs_client = boto3.client("logs", region_name=ecs.region_name)

    response = ecs_client.run_task(
        cluster=ecs.cluster_name,
        taskDefinition=task_definition,
        launchType="FARGATE",
        networkConfiguration=ecs.get_network_config(),
        overrides={
            "containerOverrides": [
                {
                    "name": "worker",
                    "environment": [
                        {"name": "S3_BUCKET", "value": config.s3_bucket},
                        {"name": "S3_KEY", "value": config.s3_key},
                        {"name": "DAGSTER_RUN_ID", "value": context.run_id},
                    ],
                }
            ]
        },
    )

    if not response.get("tasks"):
        failures = response.get("failures", [])
        raise Exception(f"Failed to start Fargate task: {failures}")

    task = response["tasks"][0]
    task_arn = task["taskArn"]
    task_id = task_arn.split("/")[-1]

    context.log.info(f"Task started: {task_id}")

    # 4. Wait for task to complete while streaming logs
    log_group = ecs.log_group_name
    log_stream_prefix = f"worker-{task_size}/worker/{task_id}"

    context.log.info(f"Log group: {log_group}")
    context.log.info(f"Log stream: {log_stream_prefix}")
    context.log.info("-" * 50)
    context.log.info("FARGATE WORKER LOGS:")
    context.log.info("-" * 50)

    last_log_token = None
    task_running = True
    start_time = time.time()
    max_wait_time = 900  # 15 minutes max

    while task_running and (time.time() - start_time) < max_wait_time:
        # Check task status
        task_response = ecs_client.describe_tasks(
            cluster=ecs.cluster_name, tasks=[task_arn]
        )

        if task_response["tasks"]:
            task_status = task_response["tasks"][0]["lastStatus"]

            if task_status == "STOPPED":
                task_running = False
                stop_reason = task_response["tasks"][0].get("stoppedReason", "")
                containers = task_response["tasks"][0].get("containers", [])

                # Get exit code
                exit_code = None
                if containers:
                    exit_code = containers[0].get("exitCode")

                context.log.info("-" * 50)
                context.log.info(f"Task stopped. Exit code: {exit_code}")
                if stop_reason:
                    context.log.info(f"Stop reason: {stop_reason}")

        # Stream logs from CloudWatch
        try:
            log_params = {
                "logGroupName": log_group,
                "logStreamNamePrefix": log_stream_prefix,
                "interleaved": True,
            }
            if last_log_token:
                log_params["nextToken"] = last_log_token

            log_response = logs_client.filter_log_events(**log_params)

            for event in log_response.get("events", []):
                message = event.get("message", "").strip()
                if message:
                    context.log.info(f"[WORKER] {message}")

            if log_response.get("nextToken"):
                last_log_token = log_response["nextToken"]

        except logs_client.exceptions.ResourceNotFoundException:
            # Log stream not yet created
            pass
        except Exception as e:
            context.log.warning(f"Error reading logs: {e}")

        if task_running:
            time.sleep(2)

    # 5. Final log fetch
    time.sleep(2)
    try:
        log_response = logs_client.filter_log_events(
            logGroupName=log_group,
            logStreamNamePrefix=log_stream_prefix,
            interleaved=True,
        )
        for event in log_response.get("events", []):
            message = event.get("message", "").strip()
            if message and last_log_token is None:
                context.log.info(f"[WORKER] {message}")
    except Exception:
        pass

    # 6. Check final status
    task_response = ecs_client.describe_tasks(
        cluster=ecs.cluster_name, tasks=[task_arn]
    )

    if task_response["tasks"]:
        containers = task_response["tasks"][0].get("containers", [])
        exit_code = containers[0].get("exitCode") if containers else None

        context.log.info("=" * 50)

        if exit_code == 0:
            context.log.info("FARGATE TASK COMPLETED SUCCESSFULLY")
            context.log.info("=" * 50)

            return {
                "status": "success",
                "file": f"s3://{config.s3_bucket}/{config.s3_key}",
                "file_size_mb": file_size_mb,
                "task_size": task_size,
                "task_arn": task_arn,
                "exit_code": exit_code,
            }
        else:
            context.log.error(f"FARGATE TASK FAILED (exit code: {exit_code})")
            context.log.info("=" * 50)
            raise Exception(f"Fargate task failed with exit code: {exit_code}")

    raise Exception("Unable to determine task status")
