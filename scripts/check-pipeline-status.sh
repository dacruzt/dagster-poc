#!/bin/bash
# Script para diagnosticar el estado del pipeline
# Usage: ./scripts/check-pipeline-status.sh <filename>

set -e

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
TABLE_NAME="${DYNAMO_TABLE_NAME:-dagster-poc-sand-ingest-state}"
RAW_QUEUE_URL="${RAW_QUEUE_URL}"
QUEUE_URL="${SQS_QUEUE_URL}"
ENRICHMENT_LOG_GROUP="/aws/lambda/dagster-poc-sand-enrichment-lambda"

echo "=========================================="
echo "Pipeline Status Check"
echo "=========================================="
echo ""

# 1. Check DynamoDB Config
echo "1️⃣  Checking DynamoDB Configuration..."
aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --key '{"pk": {"S": "DATASET#__default__"}, "sk": {"S": "CONFIG"}}' \
  --query 'Item.{dataset_id:dataset_id.S,compute_target:compute_target.S,allowed_extensions:allowed_extensions.L}' \
  --output json 2>&1 | head -20

echo ""

# 2. Check SQS Queues
echo "2️⃣  Checking SQS Queue Status..."
if [ -n "$RAW_QUEUE_URL" ]; then
  echo "Raw Queue:"
  aws sqs get-queue-attributes \
    --queue-url "$RAW_QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --region "$REGION" \
    --output json 2>&1 | grep -E 'ApproximateNumberOfMessages|error' || echo "  No messages"
fi

if [ -n "$QUEUE_URL" ]; then
  echo "Main Queue:"
  aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --region "$REGION" \
    --output json 2>&1 | grep -E 'ApproximateNumberOfMessages|error' || echo "  No messages"
fi

echo ""

# 3. Check recent Enrichment Lambda logs
echo "3️⃣  Checking Enrichment Lambda Logs (last 10 minutes)..."
aws logs filter-log-events \
  --log-group-name "$ENRICHMENT_LOG_GROUP" \
  --region "$REGION" \
  --start-time $(($(date +%s) * 1000 - 600000)) \
  --query 'events[*].[timestamp,message]' \
  --output text 2>&1 | tail -20 || echo "  No recent logs or access denied"

echo ""

# 4. If filename provided, search for it
if [ -n "$1" ]; then
  echo "4️⃣  Searching for file: $1"
  echo ""

  echo "In Enrichment logs:"
  aws logs filter-log-events \
    --log-group-name "$ENRICHMENT_LOG_GROUP" \
    --region "$REGION" \
    --filter-pattern "$1" \
    --start-time $(($(date +%s) * 1000 - 3600000)) \
    --query 'events[*].message' \
    --output text 2>&1 | tail -10 || echo "  Not found"

  echo ""

  echo "In DynamoDB (ingest history):"
  aws dynamodb query \
    --table-name "$TABLE_NAME" \
    --region "$REGION" \
    --index-name gsi1 \
    --key-condition-expression "gsi1pk = :pk" \
    --expression-attribute-values '{":pk":{"S":"FILES"}}' \
    --query "Items[?contains(sk.S, '$1')].{file:sk.S,status:ingest_status.S,created:created_at.S}" \
    --output table 2>&1 || echo "  Not found in ingest history"
fi

echo ""
echo "=========================================="
echo "Status check complete!"
echo "=========================================="
