#!/bin/bash
# Seed the Ingestion Registry with dataset configs for each S3 folder.
# Usage: ./scripts/seed-dataset-registry.sh

TABLE_NAME="${CONFIG_TABLE_NAME:-dagster-poc-sand-dataset-config}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "Seeding dataset registry in table: $TABLE_NAME"

# --- Boards (covers all Board_* subfolders) ---
aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item '{
    "pk": {"S": "DATASET#Boards"},
    "sk": {"S": "CONFIG"},
    "dataset_id": {"S": "Boards"},
    "schema_version": {"S": "1.0"},
    "compute_target": {"S": "AUTO"},
    "allowed_extensions": {"L": [{"S": ".csv"}, {"S": ".json"}, {"S": ".xls"}, {"S": ".xlsx"}]},
    "required_columns": {"L": [
      {"M": {"name": {"S": "date"}, "type": {"S": "date"}}},
      {"M": {"name": {"S": "license_number"}, "type": {"S": "string"}}},
      {"M": {"name": {"S": "board_code"}, "type": {"S": "string"}}}
    ]},
    "description": {"S": "Board license files from all Board_* subfolders"}
  }'
echo "Seeded Boards config."

# --- Providers ---
aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item '{
    "pk": {"S": "DATASET#Providers"},
    "sk": {"S": "CONFIG"},
    "dataset_id": {"S": "Providers"},
    "schema_version": {"S": "1.0"},
    "compute_target": {"S": "AUTO"},
    "allowed_extensions": {"L": [{"S": ".csv"}, {"S": ".json"}, {"S": ".xls"}, {"S": ".xlsx"}]},
    "required_columns": {"L": []},
    "description": {"S": "Provider data files"}
  }'
echo "Seeded Providers config."

# --- Pharmacy ---
aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item '{
    "pk": {"S": "DATASET#Pharmacy"},
    "sk": {"S": "CONFIG"},
    "dataset_id": {"S": "Pharmacy"},
    "schema_version": {"S": "1.0"},
    "compute_target": {"S": "AUTO"},
    "allowed_extensions": {"L": [{"S": ".csv"}, {"S": ".json"}, {"S": ".xls"}, {"S": ".xlsx"}]},
    "required_columns": {"L": []},
    "description": {"S": "Pharmacy data files"}
  }'
echo "Seeded Pharmacy config."

echo "Done. All 3 dataset configs seeded (Boards, Providers, Pharmacy)."
