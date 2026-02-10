from dagster import Definitions

from .jobs.fargate_job import fargate_job
from .sensors.sqs_sensor import s3_file_sensor

# Python is only the UI layer. All logic runs in TypeScript (dagster_ts/).
# AWS credentials and config are passed via environment variables.
defs = Definitions(
    jobs=[fargate_job],
    sensors=[s3_file_sensor],
)
