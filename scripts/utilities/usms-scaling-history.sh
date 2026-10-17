#!/usr/bin/env bash
# Export the enrolment service's complete scaling configuration and history as ONE
# JSON document: outputs/lab-06-scaling-history.json
#   - the scalable target (bounds, suspension state)
#   - every scaling policy with its full configuration
#   - every scheduled action
#   - every alarm involved (managed, and any alarm whose actions name a policy), with state
#   - every scaling activity, including not-scaled ones
# Every identifier is discovered from the API; nothing below names a policy or alarm.
# Prints the output path and its size in bytes. Read-only against AWS.
#
# set -e is NOT used: scheduled actions and scaling activities are unimplemented on some
# builds, and the export must still be written, recording "unsupported" for that section.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
export AWS_PAGER=""
OUT="$REPO_ROOT/outputs/lab-06-scaling-history.json"
mkdir -p "$REPO_ROOT/outputs"

# The one starting point: the usms- cluster's service ARN, discovered (not typed).
CLUSTER_ARN=$(aws ecs list-clusters --query "clusterArns[?contains(@, ':cluster/usms-')] | [0]" --output text 2>/dev/null)
[ -n "$CLUSTER_ARN" ] && [ "$CLUSTER_ARN" != None ] || { echo "no usms- ECS cluster found" >&2; exit 1; }
SERVICE_ARN=$(aws ecs list-services --cluster "$CLUSTER_ARN" --query 'serviceArns[0]' --output text 2>/dev/null)
[ -n "$SERVICE_ARN" ] && [ "$SERVICE_ARN" != None ] || { echo "no service in $CLUSTER_ARN" >&2; exit 1; }

SERVICE_ARN="$SERVICE_ARN" python3 - "$OUT" <<'PY'
import datetime, json, os, subprocess, sys

out = sys.argv[1]
service_arn = os.environ["SERVICE_ARN"]
# arn:aws:ecs:<region>:<acct>:service/<cluster>/<service>  ->  service/<cluster>/<service>
resource_id = service_arn.split(":", 5)[5]

def aws(*args):
    p = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if p.returncode != 0:
        err = (p.stderr.strip().splitlines() or ["error"])[-1]
        return {"unsupported": True, "error": err} if "UnsupportedOperation" in err else {"error": err}
    return json.loads(p.stdout) if p.stdout.strip() else None

ns = ["--service-namespace", "ecs", "--resource-id", resource_id]
target = aws("application-autoscaling", "describe-scalable-targets", "--service-namespace", "ecs",
             "--resource-ids", resource_id)
policies = aws("application-autoscaling", "describe-scaling-policies", *ns)
pol_list = policies.get("ScalingPolicies", []) if isinstance(policies, dict) else []
scheduled = aws("application-autoscaling", "describe-scheduled-actions", *ns)
activities = aws("application-autoscaling", "describe-scaling-activities", *ns, "--include-not-scaled-activities")

# Alarms involved: those each policy lists, plus any alarm whose AlarmActions name a policy ARN.
all_alarms = aws("cloudwatch", "describe-alarms")
all_alarms = all_alarms.get("MetricAlarms", []) if isinstance(all_alarms, dict) else []
listed = {a["AlarmName"] for p in pol_list for a in (p.get("Alarms") or [])}
arns = {p["PolicyARN"] for p in pol_list}
alarms = [a for a in all_alarms
          if a["AlarmName"] in listed or arns.intersection(a.get("AlarmActions") or [])]

doc = {
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "resourceId": resource_id,
    "serviceArn": service_arn,
    "scalableTarget": (target or {}).get("ScalableTargets", [None])[0] if isinstance(target, dict) and "ScalableTargets" in target else target,
    "scalingPolicies": pol_list,
    "scheduledActions": scheduled.get("ScheduledActions", []) if isinstance(scheduled, dict) and "ScheduledActions" in scheduled else scheduled,
    "alarms": alarms,
    "scalingActivities": activities.get("ScalingActivities", []) if isinstance(activities, dict) and "ScalingActivities" in activities else activities,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2, default=str)
PY

python3 -m json.tool "$OUT" > /dev/null || { echo "invalid JSON written to $OUT" >&2; exit 1; }
echo "$OUT $(wc -c < "$OUT") bytes"
