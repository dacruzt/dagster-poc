from dagster import job

from ..ops.fargate_ops import process_file_with_pipes


@job
def fargate_job():
    """
    Job that processes files using Dagster Pipes with ECS Fargate.

    Features:
    - Auto-scales resources based on file size
    - Bi-directional communication via Dagster Pipes
    - Real-time logs and metadata streaming
    - Clear success/failure semantics

    Configuration example:
    ```yaml
    ops:
      process_file_with_pipes:
        config:
          s3_bucket: "my-bucket"
          s3_key: "data/file.csv"
          task_size: null  # auto-detect
          wait_for_completion: true
    ```
    """
    process_file_with_pipes()
