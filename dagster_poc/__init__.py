import os

from dagster import Definitions

from .jobs.fargate_job import fargate_job
from .resources import ECSResource, S3Resource, SQSResource
from .sensors.sqs_sensor import s3_file_sensor

defs = Definitions(
    jobs=[fargate_job],
    sensors=[s3_file_sensor],
    resources={
        "ecs": ECSResource(
            region_name=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
            cluster_name=os.getenv("ECS_CLUSTER_NAME", ""),
            subnets=os.getenv("ECS_SUBNETS", "").split(",") if os.getenv("ECS_SUBNETS") else [],
            security_groups=os.getenv("ECS_SECURITY_GROUPS", "").split(",") if os.getenv("ECS_SECURITY_GROUPS") else [],
            log_group_name=os.getenv("ECS_LOG_GROUP_NAME", ""),
            task_definition_small=os.getenv("ECS_TASK_DEFINITION_SMALL", ""),
            task_definition_medium=os.getenv("ECS_TASK_DEFINITION_MEDIUM", ""),
            task_definition_large=os.getenv("ECS_TASK_DEFINITION_LARGE", ""),
            task_definition_xlarge=os.getenv("ECS_TASK_DEFINITION_XLARGE", ""),
        ),
        "sqs": SQSResource(
            region_name=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
            queue_url=os.getenv("SQS_QUEUE_URL", ""),
        ),
        "s3": S3Resource(
            region_name=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
        ),
    },
)
