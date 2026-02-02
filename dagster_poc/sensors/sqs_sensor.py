import json

from dagster import RunConfig, RunRequest, SensorEvaluationContext, sensor

from ..jobs.fargate_job import fargate_job
from ..ops.fargate_ops import ProcessFileConfig
from ..resources import S3Resource, SQSResource


@sensor(job=fargate_job, minimum_interval_seconds=30)
def s3_file_sensor(
    context: SensorEvaluationContext,
    sqs: SQSResource,
    s3: S3Resource,
):
    """
    Sensor that listens to SQS for S3 file events and triggers Fargate processing.

    Features:
    - Auto-detects optimal task size based on file size
    - Deduplicates based on S3 object key and ETag
    - Reports file metadata in run tags
    """

    messages = sqs.receive_messages(max_messages=10)

    for message in messages:
        try:
            body = json.loads(message["Body"])

            # S3 event notification structure
            for record in body.get("Records", []):
                s3_info = record.get("s3", {})
                bucket_name = s3_info.get("bucket", {}).get("name")
                object_key = s3_info.get("object", {}).get("key")
                object_size = s3_info.get("object", {}).get("size", 0)
                etag = s3_info.get("object", {}).get("eTag", "")

                if not bucket_name or not object_key:
                    context.log.warning(f"Message missing S3 info: {message}")
                    continue

                context.log.info(f"File detected: s3://{bucket_name}/{object_key}")
                context.log.info(f"File size: {object_size / (1024*1024):.2f} MB")

                # Determine task size based on file size
                task_size = s3.get_recommended_task_size(object_size)
                context.log.info(f"Recommended task size: {task_size}")

                # Create run request
                yield RunRequest(
                    run_key=f"{bucket_name}/{object_key}/{etag}",
                    run_config=RunConfig(
                        ops={
                            "process_file_with_pipes": ProcessFileConfig(
                                s3_bucket=bucket_name,
                                s3_key=object_key,
                                task_size=task_size,
                            )
                        }
                    ),
                    tags={
                        "s3_bucket": bucket_name,
                        "s3_key": object_key,
                        "file_size_mb": str(round(object_size / (1024 * 1024), 2)),
                        "task_size": task_size,
                    },
                )

            # Delete message from queue after processing
            sqs.delete_message(message["ReceiptHandle"])

        except json.JSONDecodeError:
            context.log.error(f"Invalid JSON in message: {message['Body']}")
        except Exception as e:
            context.log.error(f"Error processing message: {e}")
