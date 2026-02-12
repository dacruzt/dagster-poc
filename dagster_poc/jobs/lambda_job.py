from dagster import job

from ..ops.lambda_ops import process_file_with_lambda


@job
def lambda_job():
    """
    Job that processes small files (< 50 MB) using AWS Lambda.
    Faster cold start and lower cost compared to Fargate for small files.
    """
    process_file_with_lambda()
