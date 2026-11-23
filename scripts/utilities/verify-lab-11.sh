#!/usr/bin/env bash
# Verify every Lab 11 artefact. Exit 1 if anything is missing.
# EXPECTED: PASS=46  FAIL=0        (Path A)
#           PASS=38  FAIL=8        (Path B or C - the CodeBuild/CodePipeline block)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-01.env configs/lab-04.env configs/lab-05.env \
         configs/lab-10.env configs/lab-11.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

: "${FLOCI_CONTAINER_NAME:=floci}"
: "${USMS_PIPELINE_BUCKET:=usms-pipeline-artifacts}"
: "${USMS_BUILD_PROJECT:=usms-enrolment-build}"
: "${USMS_BUILD_IMAGE:=docker.io/library/python:3.12-slim-bookworm}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"
: "${USMS_BUILD_ROLE:=usms-codebuild-role}"
: "${USMS_PIPELINE_ROLE:=usms-codepipeline-role}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_CONTAINER:=enrolment-api}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
proj() { aws codebuild batch-get-projects --names "$USMS_BUILD_PROJECT" --query "projects[0].$1" --output text; }
pipe() { aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" --query "pipeline.$1" --output text; }
spec="labs/lab-11-cicd/app/buildspec.yml"

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Earlier-lab dependencies =="
check "configs/lab-04.env present" "test -f configs/lab-04.env"
check "configs/lab-10.env present"  "test -f configs/lab-10.env"
check "ECS cluster $USMS_ECS_CLUSTER exists" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "ECS service $USMS_ENROLMENT_SERVICE exists" \
  "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].serviceName' --output text | grep -q ."
check "container name is enrolment-api" "test \"$USMS_ENROLMENT_CONTAINER\" = enrolment-api"

echo "== Artifact store =="
check "bucket $USMS_PIPELINE_BUCKET exists" "aws s3api head-bucket --bucket $USMS_PIPELINE_BUCKET"
check "versioning is Enabled" \
  "test \"\$(aws s3api get-bucket-versioning --bucket $USMS_PIPELINE_BUCKET --query Status --output text)\" = Enabled"
check "public access is blocked" \
  "aws s3api get-public-access-block --bucket $USMS_PIPELINE_BUCKET --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text | grep -qi true"
check "source object present" \
  "aws s3api head-object --bucket $USMS_PIPELINE_BUCKET --key source/usms-enrolment-src.zip"
check "source has at least two versions" \
  "test \"\$(aws s3api list-object-versions --bucket $USMS_PIPELINE_BUCKET --prefix source/usms-enrolment-src.zip --query 'length(Versions || \`[]\`)' --output text)\" -ge 2"

echo "== Pipeline identities =="
check "role $USMS_BUILD_ROLE exists" "aws iam get-role --role-name $USMS_BUILD_ROLE"
check "build role trusts codebuild.amazonaws.com" \
  "aws iam get-role --role-name $USMS_BUILD_ROLE --query 'Role.AssumeRolePolicyDocument' --output json | grep -q codebuild.amazonaws.com"
check "policy USMSCodeBuildBase exists" \
  "aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase"
check "USMSCodeBuildBase attached to the build role" \
  "aws iam list-attached-role-policies --role-name $USMS_BUILD_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSCodeBuildBase"
check "role $USMS_PIPELINE_ROLE exists" "aws iam get-role --role-name $USMS_PIPELINE_ROLE"
check "pipeline role trusts codepipeline.amazonaws.com" \
  "aws iam get-role --role-name $USMS_PIPELINE_ROLE --query 'Role.AssumeRolePolicyDocument' --output json | grep -q codepipeline.amazonaws.com"
check "policy USMSCodePipelineBase exists" \
  "aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodePipelineBase"
check "USMSCodePipelineBase attached to the pipeline role" \
  "aws iam list-attached-role-policies --role-name $USMS_PIPELINE_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSCodePipelineBase"
check "pipeline policy scopes iam:PassRole" \
  "grep -q 'iam:PassedToService' policies/usms-codepipeline-policy.json"

echo "== CodeBuild =="
check "project $USMS_BUILD_PROJECT exists"        "proj name | grep -q $USMS_BUILD_PROJECT"
check "project source type is CODEPIPELINE"       "proj source.type | grep -q CODEPIPELINE"
check "project runs as $USMS_BUILD_ROLE"          "proj serviceRole | grep -q $USMS_BUILD_ROLE"
check "project image matches the Lab 11 configuration" \
  'proj environment.image | grep -Fxq -- "$USMS_BUILD_IMAGE"'

echo "== CodePipeline =="
check "pipeline $USMS_PIPELINE_NAME exists"       "pipe name | grep -q $USMS_PIPELINE_NAME"
check "pipeline has 2 stages"                     "test \"\$(pipe 'length(stages)')\" = 2"
check "stage 1 provider is S3"                    "pipe 'stages[0].actions[0].actionTypeId.provider' | grep -q '^S3$'"
check "stage 2 builds $USMS_BUILD_PROJECT"        "pipe 'stages[1].actions[0].configuration.ProjectName' | grep -q $USMS_BUILD_PROJECT"

echo "== Source tree and scripts =="
check "buildspec.yml present"                     "test -f $spec"
check "buildspec declares version 0.2"            "grep -qE '^version: 0\.2' $spec"
check "buildspec has all four phases"             "test \"\$(grep -cE '^  (install|pre_build|build|post_build):' $spec)\" = 4"
check "artifacts base-directory is dist"          "grep -qE '^  base-directory: dist' $spec"
check "smoke test is valid bash"                  "bash -n labs/lab-11-cicd/app/tests/smoke.sh"
check "usms-pack-source.sh executable and valid"  "test -x scripts/utilities/usms-pack-source.sh && bash -n scripts/utilities/usms-pack-source.sh"
check "usms-buildspec-run.sh executable and valid" "test -x scripts/utilities/usms-buildspec-run.sh && bash -n scripts/utilities/usms-buildspec-run.sh"

echo "== Files and Git hygiene =="
check "configs/lab-11.env present"               "test -f configs/lab-11.env"
check "no empty or None values in lab-11.env"    "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-11.env"
check "codebuild project template is valid JSON"  "python3 -m json.tool templates/lab-11-codebuild-project.json"
check "pipeline template is valid JSON"           "python3 -m json.tool templates/lab-11-pipeline.json"
check "templates contain no unexpanded variables" "! grep -q '[\$]' templates/lab-11-codebuild-project.json templates/lab-11-pipeline.json"
check "all four policy documents are valid JSON" \
  "python3 -m json.tool policies/trust-codebuild.json && python3 -m json.tool policies/trust-codepipeline.json && python3 -m json.tool policies/usms-codebuild-policy.json && python3 -m json.tool policies/usms-codepipeline-policy.json"
check "no secret is tracked"                      "! git ls-files | grep -q '^outputs/'"
check "build output dist/ is git-ignored"         'git check-ignore -q "$(realpath --relative-to=. labs/lab-11-cicd/app)/dist/build-metadata.json"'

echo; echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

Read the failures top-down, not bottom-up.

  Environment block failing        -> Floci is not running, or is in memory mode.
                                      Fix this first; everything below is a consequence.
  Earlier-lab dependencies failing -> re-run verify-lab-04.sh / verify-lab-10.sh.
  Artifact store failing           -> Step 5 and Step 6.
  CodeBuild / CodePipeline block   -> if the support probe said Path B or C, eight
                                      failures here are EXPECTED. Record the path.
  Source tree failing              -> Step 7, Step 8, Step 11, Step 14.
  Hygiene failing                  -> Step 21, and .gitignore.
REMEDY
fi
[ "$FAIL" -eq 0 ]
