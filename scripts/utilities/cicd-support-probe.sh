#!/usr/bin/env bash
# Determine which CI/CD path this Floci build supports.
# Read-only except for one throwaway CodeBuild project, which it deletes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

PROBE_PROJECT="usms-probe-delete-me"
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  --   %s\n' "$1"; }

CB_LIST=no ; CB_CREATE=no ; CP_LIST=no ; ECS_ACTION=unknown

echo "== CodeBuild =="
if aws codebuild list-projects >/dev/null 2>&1; then
  CB_LIST=yes; ok "codebuild list-projects answers"
else
  bad "codebuild list-projects does not answer"
fi

if [ "$CB_LIST" = yes ]; then
  if aws codebuild create-project \
        --name "$PROBE_PROJECT" \
        --source type=NO_SOURCE,buildspec='version: 0.2' \
        --artifacts type=NO_ARTIFACTS \
        --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL \
        --service-role "arn:aws:iam::000000000000:role/does-not-matter-for-a-probe" \
        >/dev/null 2>&1; then
    CB_CREATE=yes; ok "codebuild create-project accepted"
    aws codebuild delete-project --name "$PROBE_PROJECT" >/dev/null 2>&1 \
      && ok "probe project deleted" || bad "probe project NOT deleted - remove $PROBE_PROJECT by hand"
  else
    bad "codebuild create-project rejected"
  fi
fi

echo "== CodePipeline =="
if aws codepipeline list-pipelines >/dev/null 2>&1; then
  CP_LIST=yes; ok "codepipeline list-pipelines answers"
else
  bad "codepipeline list-pipelines does not answer"
fi

echo "== Deploy targets (informational, used by Lab 12) =="
aws ecr describe-repositories >/dev/null 2>&1 \
  && ok "ecr describe-repositories answers" || bad "ecr describe-repositories does not answer"
aws deploy list-applications >/dev/null 2>&1 \
  && ok "codedeploy list-applications answers" || bad "codedeploy list-applications does not answer"

echo
if [ "$CB_CREATE" = yes ] && [ "$CP_LIST" = yes ]; then
  PATHNAME="A"
  echo "PATH A - CodeBuild and CodePipeline both present."
  echo "         Follow every step as written."
elif [ "$CB_CREATE" = yes ] || [ "$CP_LIST" = yes ]; then
  PATHNAME="B"
  echo "PATH B - one of the two services is present, the other is not."
  echo "         Follow every step. Where the missing service is called, record the"
  echo "         document you wrote and run Step 14's local runner instead."
else
  PATHNAME="C"
  echo "PATH C - neither service is present on this build."
  echo "         Every document in this lab is still written and validated; the"
  echo "         execution happens in Step 14's local runner. Section 12 tells you"
  echo "         exactly what to claim and what not to claim."
fi
printf 'USMS_CICD_SUPPORT_PATH=%s\n' "$PATHNAME" > outputs/lab-11-support-probe.txt
echo "recorded in outputs/lab-11-support-probe.txt"
