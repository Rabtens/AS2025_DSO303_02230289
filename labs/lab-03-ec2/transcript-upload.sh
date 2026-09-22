#!/bin/bash
# Uploads a student transcript to S3 using ONLY the instance's IAM
# instance profile. No access key is read, stored, or referenced here.
set -euo pipefail

STUDENT_ID="${1:-}"
FILE_PATH="${2:-}"

if [ -z "$STUDENT_ID" ] || [ -z "$FILE_PATH" ]; then
  echo "Usage: $0 <student-id> <file-path>" >&2
  exit 1
fi

if [ ! -f "$FILE_PATH" ]; then
  echo "File not found: $FILE_PATH" >&2
  exit 1
fi

FILENAME=$(basename "$FILE_PATH")
BUCKET="usms-student-data"
KEY="transcripts/${STUDENT_ID}/${FILENAME}"

aws s3 cp "$FILE_PATH" "s3://${BUCKET}/${KEY}"
echo "Uploaded to s3://${BUCKET}/${KEY}"
