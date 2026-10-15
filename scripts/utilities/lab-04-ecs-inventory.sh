#!/usr/bin/env bash
# ECS configuration drift report for every service in the USMS cluster.
# Prints one line per service and writes the same data to
# outputs/lab-04-ecs-inventory.json. Read-only; safe to run at any time.
#
# Verdicts are computed from the live service and task definition,
# never from a service name or a tag:
#   roles    SAME     executionRoleArn equals taskRoleArn
#            SEPARATE they differ
#   publicip RISK     assignPublicIp is ENABLED
#            OK       assignPublicIp is DISABLED
#            N/A      the service has no awsvpc networkConfiguration
#
# set -e is deliberately NOT used: this is a report, and one service whose
# describe call fails (deleted mid-run, task definition deregistered) must be
# printed as UNKNOWN rather than abort the report for every other service.
# Each AWS call is checked explicitly instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
export AWS_PAGER=""

: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
OUT_JSON="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"
mkdir -p "$REPO_ROOT/outputs"

if ! SERVICE_ARNS=$(aws ecs list-services --cluster "$USMS_ECS_CLUSTER" \
      --query 'serviceArns[]' --output text 2>/dev/null); then
  echo "ERROR: cannot list services in cluster $USMS_ECS_CLUSTER" >&2
  exit 1
fi

records=()
for arn in $SERVICE_ARNS; do
  [ "$arn" = "None" ] && continue

  svc_json=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$arn" \
               --query 'services[0]' --output json 2>/dev/null) || svc_json="null"

  name=$(jq -r '.serviceName // empty' <<< "$svc_json")
  [ -z "$name" ] && name="${arn##*/}"
  desired=$(jq -r '.desiredCount // "UNKNOWN"' <<< "$svc_json")
  running=$(jq -r '.runningCount // "UNKNOWN"' <<< "$svc_json")
  td_ref=$(jq -r '.taskDefinition // empty' <<< "$svc_json")

  # publicip: absent networkConfiguration (e.g. EC2 launch type, bridge mode) -> N/A
  assign=$(jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // empty' <<< "$svc_json")
  case "$assign" in
    ENABLED)  publicip=RISK ;;
    DISABLED) publicip=OK ;;
    *)        publicip=N/A ;;
  esac

  # Resolve the task definition to family:revision and read both role ARNs.
  # Some builds return a bare family name rather than an ARN, so always ask.
  taskdef=UNKNOWN; roles=UNKNOWN; exec_arn=""; task_arn=""
  if [ -n "$td_ref" ] && td_json=$(aws ecs describe-task-definition --task-definition "$td_ref" \
        --query 'taskDefinition.{f:family,r:revision,e:executionRoleArn,t:taskRoleArn}' \
        --output json 2>/dev/null); then
    taskdef="$(jq -r '.f' <<< "$td_json"):$(jq -r '.r' <<< "$td_json")"
    exec_arn=$(jq -r '.e // empty' <<< "$td_json")
    task_arn=$(jq -r '.t // empty' <<< "$td_json")
    if [ -z "$exec_arn" ] || [ -z "$task_arn" ]; then
      roles=MISSING            # one of the two roles is not set at all
    elif [ "$exec_arn" = "$task_arn" ]; then
      roles=SAME
    else
      roles=SEPARATE
    fi
  fi

  printf '%-20s desired=%-2s running=%-2s taskdef=%-18s roles=%-8s publicip=%s\n' \
    "$name" "$desired" "$running" "$taskdef" "$roles" "$publicip"

  records+=("$(jq -n --arg service "$name" --arg arn "$arn" \
      --arg desired "$desired" --arg running "$running" --arg taskdef "$taskdef" \
      --arg executionRoleArn "$exec_arn" --arg taskRoleArn "$task_arn" \
      --arg roles "$roles" --arg assignPublicIp "${assign:-N/A}" --arg publicip "$publicip" \
      '{service:$service, serviceArn:$arn, desired:$desired, running:$running,
        taskdef:$taskdef, executionRoleArn:$executionRoleArn, taskRoleArn:$taskRoleArn,
        roles:$roles, assignPublicIp:$assignPublicIp, publicip:$publicip}')")
done

if [ "${#records[@]}" -eq 0 ]; then
  echo "(no services in cluster $USMS_ECS_CLUSTER)"
  printf '%s\n' '[]' | jq --arg c "$USMS_ECS_CLUSTER" '{cluster:$c, services:.}' > "$OUT_JSON"
else
  printf '%s\n' "${records[@]}" | jq -s --arg c "$USMS_ECS_CLUSTER" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{cluster:$c, generatedAt:$at, services:.}' > "$OUT_JSON"
fi
