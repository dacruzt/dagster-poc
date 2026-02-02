from dagster import Config, OpExecutionContext, op

from ..resources import ECSResource


class FargateTaskConfig(Config):
    """Configuración para ejecutar una tarea en Fargate."""

    task_definition: str
    subnets: list[str]
    security_groups: list[str]
    container_name: str | None = None
    command: list[str] | None = None
    environment: dict[str, str] | None = None
    wait_for_completion: bool = True


@op
def run_fargate_task(
    context: OpExecutionContext,
    config: FargateTaskConfig,
    ecs: ECSResource,
) -> dict:
    """Ejecuta una tarea en AWS Fargate y opcionalmente espera a que termine."""

    context.log.info(f"Iniciando tarea Fargate: {config.task_definition}")

    # Preparar overrides del contenedor si hay configuración
    container_overrides = None
    if config.container_name and (config.command or config.environment):
        container_overrides = {"name": config.container_name}
        if config.command:
            container_overrides["command"] = config.command
        if config.environment:
            container_overrides["environment"] = [
                {"name": k, "value": v} for k, v in config.environment.items()
            ]

    # Ejecutar la tarea
    response = ecs.run_task(
        task_definition=config.task_definition,
        subnets=config.subnets,
        security_groups=config.security_groups,
        container_overrides=container_overrides,
    )

    if not response.get("tasks"):
        failures = response.get("failures", [])
        raise Exception(f"Error al iniciar tarea Fargate: {failures}")

    task = response["tasks"][0]
    task_arn = task["taskArn"]
    context.log.info(f"Tarea iniciada: {task_arn}")

    # Esperar si está configurado
    if config.wait_for_completion:
        context.log.info("Esperando a que la tarea termine...")
        final_task = ecs.wait_for_task(task_arn)

        exit_code = None
        if final_task.get("containers"):
            exit_code = final_task["containers"][0].get("exitCode")

        context.log.info(f"Tarea terminada. Exit code: {exit_code}")

        if exit_code != 0:
            raise Exception(f"La tarea Fargate falló con exit code: {exit_code}")

        return {
            "task_arn": task_arn,
            "status": final_task.get("lastStatus"),
            "exit_code": exit_code,
        }

    return {
        "task_arn": task_arn,
        "status": "PENDING",
    }
