from dagster import job

from ..ops.fargate_ops import run_fargate_task


@job
def fargate_job():
    """Job que ejecuta una tarea en AWS Fargate.

    Configuración requerida al ejecutar:
    ```yaml
    ops:
      run_fargate_task:
        config:
          task_definition: "mi-task-definition"
          subnets:
            - "subnet-xxxxx"
          security_groups:
            - "sg-xxxxx"
          container_name: "mi-container"  # opcional
          command: ["python", "script.py"]  # opcional
          wait_for_completion: true
    ```
    """
    run_fargate_task()
