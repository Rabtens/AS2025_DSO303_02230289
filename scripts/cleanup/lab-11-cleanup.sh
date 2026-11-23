#!/usr/bin/env bash
# END OF COURSE ONLY. Removes everything Lab 11 created, dependencies inside-out.
# DO NOT RUN NOW.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
[ -f configs/lab-11.env ] && source configs/lab-11.env

: "${USMS_PIPELINE_BUCKET:=usms-pipeline-artifacts}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"
: "${USMS_BUILD_PROJECT:=usms-enrolment-build}"

cat <<'WARN'
This deletes the Lab 11 pipeline, build project, roles, policies and the ENTIRE
artifact bucket including every object version. Lab 12 depends on all of it.

If Lab 12 has been completed, run scripts/cleanup/lab-12-cleanup.sh FIRST.
WARN

if aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" \
     --query 'length(pipeline.stages)' --output text 2>/dev/null | grep -qx '3'; then
  echo "REFUSING: the pipeline still has three stages, so Lab 12 has not been cleaned up." >&2
  exit 1
fi

printf 'Type exactly: DELETE USMS PIPELINE\n> '
read -r CONFIRM
[ "$CONFIRM" = "DELETE USMS PIPELINE" ] || { echo "aborted"; exit 1; }

say() { printf '\n== %s ==\n' "$1"; }

say "pipeline"
aws codepipeline delete-pipeline --name "$USMS_PIPELINE_NAME" 2>/dev/null || true

say "build project"
aws codebuild delete-project --name "$USMS_BUILD_PROJECT" 2>/dev/null || true

say "roles and policies"
for pair in "usms-codepipeline-role:USMSCodePipelineBase" "usms-codebuild-role:USMSCodeBuildBase"; do
  ROLE="${pair%%:*}"; POL="${pair##*:}"
  ARN="arn:aws:iam::000000000000:policy/$POL"
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  for V in $(aws iam list-policy-versions --policy-arn "$ARN" \
               --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version --policy-arn "$ARN" --version-id "$V" 2>/dev/null || true
  done
  aws iam delete-policy --policy-arn "$ARN" 2>/dev/null || true
done

say "artifact bucket: every version, then the bucket"
aws s3api list-object-versions --bucket "$USMS_PIPELINE_BUCKET" \
  --query '[Versions[].[Key,VersionId], DeleteMarkers[].[Key,VersionId]][]' \
  --output text 2>/dev/null |
while read -r KEY VID; do
  [ -n "${KEY:-}" ] && aws s3api delete-object --bucket "$USMS_PIPELINE_BUCKET" \
      --key "$KEY" --version-id "$VID" >/dev/null 2>&1 || true
done
aws s3api delete-bucket --bucket "$USMS_PIPELINE_BUCKET" 2>/dev/null || true

say "done"
echo "Lab 11 resources removed. The ECS platform from Lab 04/05 is untouched."
