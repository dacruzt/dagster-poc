from dagster import Definitions

from .jobs.fargate_job import fargate_job
from .resources import ecs_resource

defs = Definitions(
    jobs=[fargate_job],
    resources={
        "ecs": ecs_resource,
    },
)
