FROM python:3.11-slim

WORKDIR /app

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copiar archivos del proyecto
COPY pyproject.toml .
COPY dagster_poc/ dagster_poc/
COPY workspace.yaml .

# Instalar dependencias
RUN pip install --no-cache-dir -e .

# Puerto de Dagster webserver
EXPOSE 3000

# Comando por defecto
CMD ["dagster", "dev", "-h", "0.0.0.0", "-p", "3000", "-w", "workspace.yaml"]
