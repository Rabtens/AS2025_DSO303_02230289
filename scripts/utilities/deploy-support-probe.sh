#!/usr/bin/env bash
# Determine which deployment path this Floci build supports. Read-only apart from
# one throwaway ECR repository, which it deletes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

PROBE_REPO="usms-probe-delete-me"
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  --   %s\n' "$1"; }

ECR_OK=no ; ECR_PUSHABLE=unknown ; ECS_OK=no ; DEPLOY_OK=no ; DOCKER_OK=no

echo "== Docker on this machine =="
if docker info >/dev/null 2>&1; then DOCKER_OK=yes; ok "docker daemon reachable"
else bad "docker daemon NOT reachable - this lab cannot build an image"; fi

echo "== ECR =="
if aws ecr describe-repositories >/dev/null 2>&1; then
  ECR_OK=yes; ok "ecr describe-repositories answers"
  if aws ecr create-repository --repository-name "$PROBE_REPO" >/dev/null 2>&1; then
    ok "ecr create-repository accepted"
    URI=$(aws ecr describe-repositories --repository-names "$PROBE_REPO" \
            --query 'repositories[0].repositoryUri' --output text 2>/dev/null)
    printf '       probe repositoryUri: %s\n' "${URI:-none}"
    case "$URI" in
      */*) ECR_PUSHABLE=probably ;;
      *)   ECR_PUSHABLE=no ;;
    esac
    aws ecr delete-repository --repository-name "$PROBE_REPO" --force >/dev/null 2>&1 \
      && ok "probe repository deleted" || bad "probe repository NOT deleted - remove $PROBE_REPO by hand"
  else
    bad "ecr create-repository rejected"
  fi
else
  bad "ecr describe-repositories does not answer"
fi

echo "== ECS =="
if aws ecs list-clusters >/dev/null 2>&1; then ECS_OK=yes; ok "ecs list-clusters answers"
else bad "ecs list-clusters does not answer"; fi

echo "== CodeDeploy (Step 19 only) =="
if aws deploy list-applications >/dev/null 2>&1; then DEPLOY_OK=yes; ok "codedeploy list-applications answers"
else bad "codedeploy list-applications does not answer - Step 19 is conceptual, as expected"; fi

echo
if [ "$DOCKER_OK" = yes ] && [ "$ECR_OK" = yes ] && [ "$ECS_OK" = yes ]; then
  P="A"
  echo "PATH A - build an image, push it to ECR, deploy it through the pipeline."
elif [ "$DOCKER_OK" = yes ] && [ "$ECS_OK" = yes ]; then
  P="B"
  echo "PATH B - no usable ECR. Build the image locally and keep it in the local"
  echo "         Docker daemon; Step 10's task definition names the local tag, and"
  echo "         Step 16's deploy stage is written and validated but not executed."
else
  P="C"
  echo "PATH C - no Docker or no ECS. Every document in this lab is still written"
  echo "         and validated. Section 12 says exactly what to claim."
fi
printf 'USMS_CICD_DEPLOY_PATH=%s\nUSMS_CODEDEPLOY_SUPPORTED=%s\n' "$P" "$DEPLOY_OK" \
  > outputs/lab-12-deploy-probe.txt
echo "recorded in outputs/lab-12-deploy-probe.txt"
