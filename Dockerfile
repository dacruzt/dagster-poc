FROM python:3.11-slim

WORKDIR /app

# Instalar dependencias del sistema + Node.js
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Copiar e instalar dagster_ts (TypeScript CLI)
COPY dagster_ts/package*.json dagster_ts/tsconfig.json dagster_ts/
COPY dagster_ts/src/ dagster_ts/src/
RUN cd dagster_ts && npm ci && npm run build

# Copiar archivos del proyecto Python
COPY pyproject.toml .
COPY dagster_poc/ dagster_poc/
COPY workspace.yaml .

# Instalar dependencias Python
RUN pip install --no-cache-dir -e .

# Puerto de Dagster webserver
EXPOSE 3000

# Comando por defecto
CMD ["dagster", "dev", "-h", "0.0.0.0", "-p", "3000", "-w", "workspace.yaml"]
