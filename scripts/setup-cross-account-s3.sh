#!/bin/bash
# =============================================================================
# Cross-Account S3 Bucket Policy Setup
# =============================================================================
# Run this script from an account/role with admin access to account 297100021705
# (or with s3:PutBucketPolicy + s3:PutBucketNotificationConfiguration permissions)
#
# This grants:
#   1. Lambda + Fargate roles (account 114009992586) read access to the bucket
#   2. S3 event notifications → SQS queue in account 114009992586
# =============================================================================

BUCKET_NAME="data-do-ent-file-ingestion-test-landing"
DAGSTER_ACCOUNT_ID="114009992586"
SQS_QUEUE_ARN="arn:aws:sqs:us-east-1:${DAGSTER_ACCOUNT_ID}:dagster-poc-sand-queue-ea9a5e1"

echo "============================================="
echo "Setting up cross-account access for: $BUCKET_NAME"
echo "============================================="

# Step 1: Apply bucket policy for cross-account S3 read access
# Grants the entire Dagster account (114009992586) access so that
# Lambda roles, Fargate roles, SSO users, and the sensor all work.
echo ""
echo "Step 1: Applying bucket policy..."

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "AllowDagsterAccountRead",
        "Effect": "Allow",
        "Principal": {
          "AWS": "arn:aws:iam::'"$DAGSTER_ACCOUNT_ID"':root"
        },
        "Action": [
          "s3:GetObject",
          "s3:HeadObject"
        ],
        "Resource": "arn:aws:s3:::'"$BUCKET_NAME"'/*"
      },
      {
        "Sid": "AllowDagsterAccountListBucket",
        "Effect": "Allow",
        "Principal": {
          "AWS": "arn:aws:iam::'"$DAGSTER_ACCOUNT_ID"':root"
        },
        "Action": "s3:ListBucket",
        "Resource": "arn:aws:s3:::'"$BUCKET_NAME"'"
      }
    ]
  }'

if [ $? -eq 0 ]; then
  echo "  Bucket policy applied successfully."
else
  echo "  ERROR: Failed to apply bucket policy. Check permissions."
  exit 1
fi

# Step 2: Configure S3 event notifications → SQS (cross-account)
echo ""
echo "Step 2: Configuring S3 event notifications → SQS..."

aws s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --notification-configuration '{
    "QueueConfigurations": [
      {
        "QueueArn": "'"$SQS_QUEUE_ARN"'",
        "Events": ["s3:ObjectCreated:*"]
      }
    ]
  }'

if [ $? -eq 0 ]; then
  echo "  S3 notifications configured successfully."
else
  echo "  ERROR: Failed to configure S3 notifications."
  echo "  This might require updating the SQS queue policy first."
  exit 1
fi

echo ""
echo "============================================="
echo "Cross-account setup complete!"
echo "============================================="
echo ""
echo "Bucket: $BUCKET_NAME (account 297100021705)"
echo "Lambda role: $LAMBDA_ROLE_ARN"
echo "Fargate role: $FARGATE_ROLE_ARN"
echo "SQS queue: $SQS_QUEUE_ARN"
echo ""
echo "Test: upload a small file to s3://$BUCKET_NAME/ and check Dagster sensor"
