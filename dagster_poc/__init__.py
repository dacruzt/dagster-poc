from dagster import Definitions

from .jobs.fargate_job import fargate_job
from .jobs.lambda_job import lambda_job
from .sensors.sqs_sensor import s3_file_sensor

# Python is only the UI layer. All logic runs in TypeScript (dagster_ts/).
# AWS credentials and config are passed via environment variables.
# Sensor routes: < 50 MB -> lambda_job, >= 50 MB -> fargate_job
defs = Definitions(
    jobs=[fargate_job, lambda_job],
    sensors=[s3_file_sensor],
)
