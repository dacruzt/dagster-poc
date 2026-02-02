import boto3
from dagster import ConfigurableResource


class ECSResource(ConfigurableResource):
    """Resource para interactuar con AWS ECS/Fargate."""

    region_name: str = "us-east-1"
    cluster_name: str = "default"

    def get_client(self):
        return boto3.client("ecs", region_name=self.region_name)

    def run_task(
        self,
        task_definition: str,
        subnets: list[str],
        security_groups: list[str],
        container_overrides: dict | None = None,
        assign_public_ip: bool = True,
    ) -> dict:
        """Ejecuta una tarea en Fargate."""
        client = self.get_client()

        network_config = {
            "awsvpcConfiguration": {
                "subnets": subnets,
                "securityGroups": security_groups,
                "assignPublicIp": "ENABLED" if assign_public_ip else "DISABLED",
            }
        }

        run_params = {
            "cluster": self.cluster_name,
            "taskDefinition": task_definition,
            "launchType": "FARGATE",
            "networkConfiguration": network_config,
        }

        if container_overrides:
            run_params["overrides"] = {"containerOverrides": [container_overrides]}

        response = client.run_task(**run_params)
        return response

    def wait_for_task(self, task_arn: str) -> dict:
        """Espera a que una tarea termine."""
        client = self.get_client()
        waiter = client.get_waiter("tasks_stopped")
        waiter.wait(cluster=self.cluster_name, tasks=[task_arn])

        response = client.describe_tasks(cluster=self.cluster_name, tasks=[task_arn])
        return response["tasks"][0] if response["tasks"] else {}


# Instancia del resource para usar en Definitions
ecs_resource = ECSResource(
    region_name="us-east-1",
    cluster_name="default",
)
