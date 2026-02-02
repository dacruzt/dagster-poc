import boto3
from dagster import ConfigurableResource


class ECSResource(ConfigurableResource):
    """Resource para interactuar con AWS ECS/Fargate."""

    region_name: str = "us-east-1"
    cluster_name: str = "default"
    subnets: list[str] = []
    security_groups: list[str] = []
    log_group_name: str = ""

    # Task definitions por tamaño
    task_definition_small: str = ""
    task_definition_medium: str = ""
    task_definition_large: str = ""
    task_definition_xlarge: str = ""

    def get_client(self):
        return boto3.client("ecs", region_name=self.region_name)

    def get_task_definition(self, task_size: str) -> str:
        """Get task definition ARN based on size."""
        mapping = {
            "small": self.task_definition_small,
            "medium": self.task_definition_medium,
            "large": self.task_definition_large,
            "xlarge": self.task_definition_xlarge,
        }
        return mapping.get(task_size, self.task_definition_small)

    def get_network_config(self, assign_public_ip: bool = True) -> dict:
        """Get network configuration for Fargate task."""
        return {
            "awsvpcConfiguration": {
                "subnets": self.subnets,
                "securityGroups": self.security_groups,
                "assignPublicIp": "ENABLED" if assign_public_ip else "DISABLED",
            }
        }


class SQSResource(ConfigurableResource):
    """Resource para interactuar con AWS SQS."""

    region_name: str = "us-east-1"
    queue_url: str = ""

    def get_client(self):
        return boto3.client("sqs", region_name=self.region_name)

    def receive_messages(self, max_messages: int = 10, wait_time: int = 5) -> list[dict]:
        """Recibe mensajes de la cola."""
        client = self.get_client()
        response = client.receive_message(
            QueueUrl=self.queue_url,
            MaxNumberOfMessages=max_messages,
            WaitTimeSeconds=wait_time,
        )
        return response.get("Messages", [])

    def delete_message(self, receipt_handle: str) -> None:
        """Elimina un mensaje de la cola."""
        client = self.get_client()
        client.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt_handle)


class S3Resource(ConfigurableResource):
    """Resource para interactuar con AWS S3."""

    region_name: str = "us-east-1"

    def get_client(self):
        return boto3.client("s3", region_name=self.region_name)

    def get_file_size(self, bucket: str, key: str) -> int:
        """Get file size in bytes."""
        client = self.get_client()
        response = client.head_object(Bucket=bucket, Key=key)
        return response.get("ContentLength", 0)

    def get_recommended_task_size(self, file_size_bytes: int) -> str:
        """Determine optimal task size based on file size."""
        size_mb = file_size_bytes / (1024 * 1024)

        if size_mb < 50:
            return "small"
        elif size_mb < 200:
            return "medium"
        elif size_mb < 500:
            return "large"
        else:
            return "xlarge"
