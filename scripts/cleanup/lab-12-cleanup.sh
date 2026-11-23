#!/usr/bin/env bash
# END OF COURSE ONLY. Removes everything Lab 12 created, dependencies inside-out.
# Run BEFORE scripts/cleanup/lab-11-cleanup.sh.
# DO NOT RUN NOW.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
[ -f configs/lab-04.env ] && source configs/lab-04.env
# shellcheck disable=SC1091
[ -f configs/lab-12.env ] && source configs/lab-12.env

: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECR_REPO:=usms-enrolment}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"

cat <<'WARN'
This removes the Deploy stage, deregisters the task definition revisions this lab
created, DELETES the ECR repository and every image in it, and reverts both IAM
policies to version 1. The ECS service is returned to usms-enrolment:2.

The CloudFormation lab compares its template against these resources. Do not run
this before that lab.
WARN

printf 'Type exactly: DELETE USMS DEPLOY STAGE\n> '
read -r CONFIRM
[ "$CONFIRM" = "DELETE USMS DEPLOY STAGE" ] || { echo "aborted"; exit 1; }

say() { printf '\n== %s ==\n' "$1"; }

say "return the service to Lab 04's revision 2"
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --task-definition usms-enrolment:2 >/dev/null 2>&1 || true

say "remove the Deploy stage, keeping Source and Build"
if aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" >/dev/null 2>&1; then
  aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" --query 'pipeline' --output json \
    > /tmp/usms-pipeline-cleanup.json
  python3 - << 'PY'
import json
p = json.load(open("/tmp/usms-pipeline-cleanup.json"))
p["stages"] = [s for s in p["stages"] if s["name"] != "Deploy"]
json.dump({"pipeline": p}, open("/tmp/usms-pipeline-cleanup-out.json", "w"), indent=2)
print("stages left:", [s["name"] for s in p["stages"]])
PY
  aws codepipeline update-pipeline --cli-input-json file:///tmp/usms-pipeline-cleanup-out.json \
    >/dev/null 2>&1 || true
  rm -f /tmp/usms-pipeline-cleanup.json /tmp/usms-pipeline-cleanup-out.json
fi

say "deregister the task definition revisions this lab created"
for REV in 3 4 5; do
  aws ecs deregister-task-definition --task-definition "usms-enrolment:$REV" >/dev/null 2>&1 \
    && echo "  deregistered usms-enrolment:$REV" || echo "  usms-enrolment:$REV absent"
done

say "delete the ECR repository and every image in it"
aws ecr delete-repository --repository-name "$USMS_ECR_REPO" --force >/dev/null 2>&1 \
  && echo "  deleted $USMS_ECR_REPO" || echo "  $USMS_ECR_REPO absent"

say "revert both policies to version 1"
for POL in USMSCodeBuildBase USMSCodePipelineBase; do
  ARN="arn:aws:iam::000000000000:policy/$POL"
  aws iam set-default-policy-version --policy-arn "$ARN" --version-id v1 >/dev/null 2>&1 || true
  aws iam delete-policy-version --policy-arn "$ARN" --version-id v2 >/dev/null 2>&1 \
    && echo "  $POL back to v1" || echo "  $POL unchanged"
done

say "turn privilegedMode back off"
aws codebuild update-project --name usms-enrolment-build \
  --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=false \
  >/dev/null 2>&1 || true

say "done"
echo "Lab 12 removed. Lab 11's two-stage pipeline is intact."
echo "The ECR registry sidecar manages its own host bindings."
echo "and re-run floci-up.sh if you want those ports back."
