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
LAMBDA_ROLE_ARN="arn:aws:iam::114009992586:role/dagster-poc-sand-lambda-role-1f754a1"
FARGATE_ROLE_ARN="arn:aws:iam::114009992586:role/dagster-poc-sand-task-role-52cbb29"
SQS_QUEUE_ARN="arn:aws:sqs:us-east-1:114009992586:dagster-poc-sand-queue-ea9a5e1"

echo "============================================="
echo "Setting up cross-account access for: $BUCKET_NAME"
echo "============================================="

# Step 1: Apply bucket policy for cross-account S3 read access
echo ""
echo "Step 1: Applying bucket policy..."

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "AllowDagsterLambdaRead",
        "Effect": "Allow",
        "Principal": {
          "AWS": "'"$LAMBDA_ROLE_ARN"'"
        },
        "Action": [
          "s3:GetObject",
          "s3:HeadObject"
        ],
        "Resource": "arn:aws:s3:::'"$BUCKET_NAME"'/*"
      },
      {
        "Sid": "AllowDagsterLambdaListBucket",
        "Effect": "Allow",
        "Principal": {
          "AWS": "'"$LAMBDA_ROLE_ARN"'"
        },
        "Action": "s3:ListBucket",
        "Resource": "arn:aws:s3:::'"$BUCKET_NAME"'"
      },
      {
        "Sid": "AllowDagsterFargateRead",
        "Effect": "Allow",
        "Principal": {
          "AWS": "'"$FARGATE_ROLE_ARN"'"
        },
        "Action": [
          "s3:GetObject",
          "s3:HeadObject"
        ],
        "Resource": "arn:aws:s3:::'"$BUCKET_NAME"'/*"
      },
      {
        "Sid": "AllowDagsterFargateListBucket",
        "Effect": "Allow",
        "Principal": {
          "AWS": "'"$FARGATE_ROLE_ARN"'"
        },
        "Action": "s3:ListBucket",
        "Resource": "arn:aws:s3:::'"$BUCKET_NAME"'"
      },
      {
        "Sid": "AllowS3NotificationsToSQS",
        "Effect": "Allow",
        "Principal": {
          "Service": "s3.amazonaws.com"
        },
        "Action": "s3:PutBucketNotificationConfiguration",
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
