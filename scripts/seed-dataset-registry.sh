#!/bin/bash
# Seed the Ingestion Registry with dataset configs for each S3 folder.
# Usage: ./scripts/seed-dataset-registry.sh

TABLE_NAME="${CONFIG_TABLE_NAME:-dagster-poc-sand-dataset-config}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "Seeding dataset registry in table: $TABLE_NAME"

# --- board-files ---
aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item '{
    "pk": {"S": "DATASET#board-files"},
    "sk": {"S": "CONFIG"},
    "dataset_id": {"S": "board-files"},
    "schema_version": {"S": "1.0"},
    "compute_target": {"S": "LAMBDA"},
    "allowed_extensions": {"L": [{"S": ".csv"}, {"S": ".json"}, {"S": ".xls"}]},
    "required_columns": {"L": [
      {"M": {"name": {"S": "date"}, "type": {"S": "date"}}},
      {"M": {"name": {"S": "license_number"}, "type": {"S": "string"}}},
      {"M": {"name": {"S": "board_code"}, "type": {"S": "string"}}}
    ]},
    "description": {"S": "Board license files - csv, json, xls only"}
  }'
echo "Seeded board-files config."

# --- nursing-files ---
aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item '{
    "pk": {"S": "DATASET#nursing-files"},
    "sk": {"S": "CONFIG"},
    "dataset_id": {"S": "nursing-files"},
    "schema_version": {"S": "1.0"},
    "compute_target": {"S": "LAMBDA"},
    "allowed_extensions": {"L": [{"S": ".csv"}, {"S": ".json"}, {"S": ".xlsx"}]},
    "required_columns": {"L": [
      {"M": {"name": {"S": "date"}, "type": {"S": "date"}}},
      {"M": {"name": {"S": "license_number"}, "type": {"S": "string"}}},
      {"M": {"name": {"S": "board_code"}, "type": {"S": "string"}}}
    ]},
    "description": {"S": "Nursing license files - csv, json, xlsx only"}
  }'
echo "Seeded nursing-files config."

# --- pharmacy ---
aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item '{
    "pk": {"S": "DATASET#pharmacy"},
    "sk": {"S": "CONFIG"},
    "dataset_id": {"S": "pharmacy"},
    "schema_version": {"S": "1.0"},
    "compute_target": {"S": "LAMBDA"},
    "allowed_extensions": {"L": [{"S": ".csv"}, {"S": ".json"}]},
    "required_columns": {"L": [
      {"M": {"name": {"S": "date"}, "type": {"S": "date"}}},
      {"M": {"name": {"S": "pharmacy_license"}, "type": {"S": "string"}}},
      {"M": {"name": {"S": "state"}, "type": {"S": "string"}}},
      {"M": {"name": {"S": "pharmacist_name"}, "type": {"S": "string"}}},
      {"M": {"name": {"S": "dea_number"}, "type": {"S": "string"}}},
      {"M": {"name": {"S": "status"}, "type": {"S": "string"}}}
    ]},
    "description": {"S": "Pharmacy license and DEA files - csv, json only"}
  }'
echo "Seeded pharmacy config."

echo "Done. All 3 dataset configs seeded."
