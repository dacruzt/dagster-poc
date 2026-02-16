#!/bin/bash
# Seed the Ingestion Registry with a default dataset config.
# Usage: ./scripts/seed-dataset-registry.sh

TABLE_NAME="${DYNAMO_TABLE_NAME:-dagster-poc-sand-ingest-state}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "Seeding dataset registry in table: $TABLE_NAME"

aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item '{
    "pk": {"S": "DATASET#__default__"},
    "sk": {"S": "CONFIG"},
    "dataset_id": {"S": "default"},
    "schema_version": {"S": "1.0"},
    "compute_target": {"S": "LAMBDA"},
    "allowed_extensions": {"L": [{"S": ".csv"}, {"S": ".json"}, {"S": ".xlsx"}]},
    "description": {"S": "Default dataset configuration"},
    "gsi1pk": {"S": "DATASETS"},
    "gsi1sk": {"S": "__default__"}
  }'

echo "Done. Seeded default dataset config."
