#!/usr/bin/env bash
# Record the current local Floci resources for the next lab.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source configs/course.env

aws_local() {
  aws --endpoint-url "$FLOCI_ENDPOINT" --region "$AWS_REGION_COURSE" "$@"
}

# Check the connection before collecting values, including optional resources.
aws_local sts get-caller-identity >/dev/null
draft=$(mktemp configs/.lab-11.env.XXXXXX)
trap 'rm -f -- "$draft"' EXIT

cat > "$draft" << EOF
# Lab 11 - CI/CD: source, build, and the pipeline that joins them
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, ARNs and IDs only. NO SECRETS. Safe to commit.

# --- artifact store and source ---
export USMS_PIPELINE_BUCKET=usms-pipeline-artifacts
export USMS_PIPELINE_BUCKET_VERSIONING=$(aws_local s3api get-bucket-versioning \
    --bucket usms-pipeline-artifacts --query 'Status' --output text 2>/dev/null \
    | grep -E '^(Enabled|Suspended)$' || echo Unknown)
export USMS_SOURCE_KEY=source/usms-enrolment-src.zip
export USMS_SOURCE_VERSION_ID=$(aws_local s3api head-object \
    --bucket usms-pipeline-artifacts --key source/usms-enrolment-src.zip \
    --query 'VersionId' --output text 2>/dev/null || echo not-created)
export USMS_BUILD_ARTIFACT_PREFIX=usms-enrolment-pipeline/BuildOutput/

# --- build project ---
export USMS_BUILD_PROJECT=usms-enrolment-build
export USMS_BUILD_PROJECT_ARN=$(aws_local codebuild batch-get-projects --names usms-enrolment-build \
    --query 'projects[0].arn' --output text 2>/dev/null | grep -E '^arn:' || echo not-created)
export USMS_BUILD_SOURCE_TYPE=$(aws_local codebuild batch-get-projects --names usms-enrolment-build \
    --query 'projects[0].source.type' --output text 2>/dev/null | grep -E '^[A-Z_]+$' || echo not-created)
export USMS_BUILD_IMAGE=docker.io/library/python:3.12-slim-bookworm
export USMS_BUILD_COMPUTE_TYPE=BUILD_GENERAL1_SMALL
export USMS_BUILD_TIMEOUT_MINUTES=15
export USMS_BUILD_LOG_GROUP=/aws/codebuild/usms-enrolment-build

# --- build identity ---
export USMS_BUILD_ROLE=usms-codebuild-role
export USMS_BUILD_ROLE_ARN=$(aws_local iam get-role --role-name usms-codebuild-role \
    --query 'Role.Arn' --output text)
export USMS_POLICY_CODEBUILD=USMSCodeBuildBase
export USMS_POLICY_CODEBUILD_ARN=arn:aws:iam::000000000000:policy/USMSCodeBuildBase

# --- pipeline ---
export USMS_PIPELINE_NAME=usms-enrolment-pipeline
export USMS_PIPELINE_STAGE_COUNT=$(aws_local codepipeline get-pipeline --name usms-enrolment-pipeline \
    --query 'length(pipeline.stages)' --output text 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
export USMS_PIPELINE_ROLE=usms-codepipeline-role
export USMS_PIPELINE_ROLE_ARN=$(aws_local iam get-role --role-name usms-codepipeline-role \
    --query 'Role.Arn' --output text)
export USMS_POLICY_CODEPIPELINE=USMSCodePipelineBase
export USMS_POLICY_CODEPIPELINE_ARN=arn:aws:iam::000000000000:policy/USMSCodePipelineBase

# --- source tree ---
export USMS_APP_SRC_DIR=labs/lab-11-cicd/app
export USMS_BUILDSPEC=labs/lab-11-cicd/app/buildspec.yml
export USMS_RELEASE_TAG=$(tr -d '[:space:]' < labs/lab-11-cicd/app/VERSION)
export USMS_CICD_SUPPORT_PATH=$(sed -n 's/^USMS_CICD_SUPPORT_PATH=//p' \
    outputs/lab-11-support-probe.txt 2>/dev/null || echo unknown)
EOF

bash -n "$draft"
if grep -nE '^export [A-Z_]+=(None)?$|[$][(]' "$draft"; then
  echo 'Lab 11 environment contains an empty or unresolved value.' >&2
  exit 1
fi
count=$(grep -c '^export ' "$draft")
if [[ "$count" -ne 26 ]]; then
  printf 'Expected 26 exports, found %s.\n' "$count" >&2
  exit 1
fi

mv -- "$draft" configs/lab-11.env
printf 'all values populated\n%s\n0\n' "$count"
