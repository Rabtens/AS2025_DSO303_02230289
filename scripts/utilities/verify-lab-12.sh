#!/usr/bin/env bash
# Verify every Lab 12 artefact. Exit 1 if anything is missing.
# EXPECTED: PASS=45  FAIL=0        (Path A)
#           PASS=40  FAIL=5        (Path B  - no usable ECR: the five ECR checks)
#           PASS=31  FAIL=14       (Path C  - no CodeBuild/CodePipeline either: those
#                                   five plus two dependency checks, three project
#                                   checks and four pipeline checks)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-01.env configs/lab-04.env configs/lab-05.env \
         configs/lab-11.env configs/lab-12.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

: "${FLOCI_CONTAINER_NAME:=floci}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"
: "${USMS_BUILD_PROJECT:=usms-enrolment-build}"
: "${USMS_ECR_REPO:=usms-enrolment}"
: "${USMS_TASK_FAMILY:=usms-enrolment}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
ecr()  { aws ecr describe-repositories --repository-names "$USMS_ECR_REPO" --query "repositories[0].$1" --output text; }
proj() { aws codebuild batch-get-projects --names "$USMS_BUILD_PROJECT" --query "projects[0].$1" --output text; }
pipe() { aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" --query "pipeline.$1" --output text; }
tdef() { aws ecs describe-task-definition --task-definition "$USMS_TASK_FAMILY" --query "taskDefinition.$1" --output text; }
polv() { aws iam get-policy --policy-arn "arn:aws:iam::000000000000:policy/$1" --query 'Policy.DefaultVersionId' --output text; }
spec="labs/lab-11-cicd/app/buildspec.yml"

docker_inspect=(docker container inspect)
# An isolated registry config can hide the Docker Desktop context.
if [[ -n "${DOCKER_CONFIG:-}" && -z "${DOCKER_CONTEXT:-}" && -z "${DOCKER_HOST:-}" ]] &&
   ! "${docker_inspect[@]}" "$FLOCI_CONTAINER_NAME" >/dev/null 2>&1; then
  docker_inspect=(env "DOCKER_CONFIG=$HOME/.docker" docker container inspect)
fi
inspect_floci() { "${docker_inspect[@]}" "$FLOCI_CONTAINER_NAME" --format "$1"; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(inspect_floci '{{.State.Running}}')\" = true"
check "storage mode is NOT memory" \
  "inspect_floci '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$' >/dev/null"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 11 dependencies =="
check "configs/lab-11.env present"   "test -f configs/lab-11.env"
check "pipeline $USMS_PIPELINE_NAME exists" "pipe name | grep -q $USMS_PIPELINE_NAME"
check "build project exists"          "proj name | grep -q $USMS_BUILD_PROJECT"
check "ECS service exists" \
  "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].status' --output text | grep -q ACTIVE"

echo "== ECR =="
check "repository $USMS_ECR_REPO exists"   "ecr repositoryName | grep -q $USMS_ECR_REPO"
check "scanOnPush is true"                 "ecr imageScanningConfiguration.scanOnPush | grep -qi true"
check "repositoryUri has a registry host"  "ecr repositoryUri | grep -q '/'"
check "at least one image is present" \
  "test \"\$(aws ecr describe-images --repository-name $USMS_ECR_REPO --query 'length(imageDetails)' --output text)\" -ge 1"
check "tag r7 is present" \
  "aws ecr describe-images --repository-name $USMS_ECR_REPO --image-ids imageTag=r7 --query 'imageDetails[0].imageDigest' --output text | grep -q '^sha256:'"

echo "== Source tree =="
check "Dockerfile present"                 "test -f labs/lab-11-cicd/app/Dockerfile"
check ".dockerignore present"              "test -f labs/lab-11-cicd/app/.dockerignore"
check "buildspec builds an image"          "grep -q 'docker build' $spec"
check "buildspec writes imagedefinitions"  "grep -q 'imagedefinitions.json' $spec"
check "smoke.sh has 8 assertions"          "test \"\$(grep -cE '^t \"' labs/lab-11-cicd/app/tests/smoke.sh)\" = 8"

echo "== Task definition and service =="
check "task family revision is at least 3" "test \"\$(tdef revision)\" -ge 3"
check "task definition names the ECR repo" "tdef 'containerDefinitions[0].image' | grep -q $USMS_ECR_REPO"
check "cpu is still 256"                   "test \"\$(tdef cpu)\" = 256"
check "memory is still 1024"               "test \"\$(tdef memory)\" = 1024"

echo "== IAM policy versions =="
check "USMSCodeBuildBase default is v2"       "test \"\$(polv USMSCodeBuildBase)\" = v2"
check "codebuild v2 grants ecr:PutImage"      "grep -q 'ecr:PutImage' policies/usms-codebuild-policy-v2.json"
check "GetAuthorizationToken is on Resource *" \
  "python3 -c \"import json;d=json.load(open('policies/usms-codebuild-policy-v2.json'));import sys;sys.exit(0 if any(s.get('Action')=='ecr:GetAuthorizationToken' and s.get('Resource')=='*' for s in d['Statement']) else 1)\""
check "USMSCodePipelineBase default is v2"    "test \"\$(polv USMSCodePipelineBase)\" = v2"
check "pipeline v2 grants ecs:UpdateService"  "grep -q 'ecs:UpdateService' policies/usms-codepipeline-policy-v2.json"
check "pipeline v2 passes roles to ecs-tasks" "grep -q 'ecs-tasks.amazonaws.com' policies/usms-codepipeline-policy-v2.json"

echo "== CodeBuild project =="
check "privilegedMode is true"     "proj environment.privilegedMode | grep -qi true"
check "IMAGE_REPO_URI is set" \
  "proj 'environment.environmentVariables[?name==\`IMAGE_REPO_URI\`].value | [0]' | grep -q ."
check "source type is still CODEPIPELINE" "proj source.type | grep -q CODEPIPELINE"

echo "== Pipeline =="
check "pipeline has 3 stages"              "test \"\$(pipe 'length(stages)')\" = 3"
check "stage 3 is named Deploy"            "pipe 'stages[2].name' | grep -q '^Deploy$'"
check "deploy provider is ECS"             "pipe 'stages[2].actions[0].actionTypeId.provider' | grep -q '^ECS$'"
check "deploy reads imagedefinitions.json" "pipe 'stages[2].actions[0].configuration.FileName' | grep -q imagedefinitions.json"

echo "== Conceptual documents and helpers =="
check "appspec.yaml present"               "test -f templates/lab-12-appspec.yaml"
check "deployment group document is valid JSON" \
  "python3 -m json.tool templates/lab-12-codedeploy-deployment-group.json"
check "usms-ecs-watch.sh executable and valid" \
  "test -x scripts/utilities/usms-ecs-watch.sh && bash -n scripts/utilities/usms-ecs-watch.sh"

echo "== Files and Git hygiene =="
check "configs/lab-12.env present"        "test -f configs/lab-12.env"
check "no empty or None values in lab-12.env" "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-12.env"
check "taskdef v3 template is valid JSON"  "python3 -m json.tool templates/lab-12-taskdef-v3.json"
check "pipeline template is valid JSON"    "python3 -m json.tool templates/lab-12-pipeline.json"
check "lab-12 templates have no unexpanded variables" \
  "! grep -q '[\$]' templates/lab-12-taskdef-v3.json templates/lab-12-codebuild-update.json templates/lab-12-pipeline.json"
check "both v2 policy documents are valid JSON" \
  "python3 -m json.tool policies/usms-codebuild-policy-v2.json && python3 -m json.tool policies/usms-codepipeline-policy-v2.json"
check "no secret is tracked"               "! git ls-files | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

Read the failures top-down, not bottom-up.

  Environment block failing   -> Floci is not running, or is in memory mode. Fix first.
  Lab 11 dependencies        -> re-run verify-lab-11.sh before anything else.
  ECR block                   -> Path B: expected, 5 failures. Otherwise Steps 4, 5, 8.
  Source tree                 -> Steps 7 and 14.
  Task definition             -> Steps 10 and 11. A revision below 3 means Step 10 did not register.
  IAM policy versions         -> Steps 12 and 15. "default is v2" failing usually means
                                 create-policy-version ran without --set-as-default.
  CodeBuild project           -> Step 13. "source type CODEPIPELINE" failing means an
                                 over-broad update-project undid Lab 11 Step 18.
  Pipeline                    -> Step 16. Fewer than 3 stages after update-pipeline means
                                 the document sent was incomplete. Rebuild it from
                                 templates/lab-11-pipeline.json plus the Deploy stage.
  Hygiene                     -> Steps 20 and 21.
REMEDY
fi
[ "$FAIL" -eq 0 ]
