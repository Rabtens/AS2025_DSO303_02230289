#!/usr/bin/env bash
# Print the scaling decision table, with a computed verdict, for every scalable
# target in the ecs namespace whose resource ID names a cluster beginning "usms-".
# Also writes the same data to outputs/lab-06-scaling-report.json. Read-only.
#
# Usage: ./scripts/utilities/usms-scaling-report.sh   (no arguments; runs from any directory)
#
# set -e is deliberately NOT used: this is a report. describe-scheduled-actions and
# describe-scaling-activities are not implemented on every build, and one target whose
# ECS service has gone must still be printed - so every call is checked explicitly and
# a failure becomes an explicit row ("unsupported on this build"), never an abort.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
export AWS_PAGER=""
OUT_JSON="$REPO_ROOT/outputs/lab-06-scaling-report.json"
mkdir -p "$REPO_ROOT/outputs"

TARGETS=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
            --query "ScalableTargets[?starts_with(ResourceId, 'service/usms-')]" --output json 2>/dev/null) \
  || { echo "ERROR: cannot describe scalable targets" >&2; exit 1; }

# Everything after the first call is JSON processing, done in python3.
TARGETS_JSON="$TARGETS" python3 - "$OUT_JSON" <<'PY'
import datetime, json, os, subprocess, sys

out_path = sys.argv[1]

def aws(*args):
    """Run an AWS CLI call; return (parsed JSON or None, error text or None)."""
    p = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if p.returncode != 0:
        err = (p.stderr.strip().splitlines() or ["error"])[-1]
        return None, ("unsupported on this build" if "UnsupportedOperation" in err else err)
    return (json.loads(p.stdout) if p.stdout.strip() else None), None

def short_metric(m):
    return {"ECSServiceAverageCPUUtilization": "CPU", "ECSServiceAverageMemoryUtilization": "Memory",
            "ALBRequestCountPerTarget": "ALBReq"}.get(m, m or "custom")

def signed(adjs):
    # Step adjustments as a signed list, in the order they apply to the breach.
    return " / ".join(f"{a['ScalingAdjustment']:+d}" for a in
                      sorted(adjs, key=lambda a: a.get("MetricIntervalLowerBound", -1e18))) or "(no steps)"

def verdict(t, desired, n_policies):
    # Rules are evaluated top to bottom; the first match wins.
    #  PINNED first: if min == max nothing can ever move, whatever else is true.
    #  FROZEN before AT-CEILING/AT-FLOOR: a suspended target is not *reacting* at all, so
    #   "at the ceiling" would wrongly suggest the policies pushed it there and are still
    #   in control. Suspension is a silent, operator-made state that must be seen first;
    #   the position against the bounds is only meaningful while scaling is live.
    #  AT-CEILING before AT-FLOOR: at the ceiling demand may exceed capacity (user-facing
    #   risk); at the floor the worst case is a little idle cost.
    #  AT-FLOOR only with more than one policy: with a single policy sitting at min is the
    #   normal quiet state, with several it means every policy agrees there is no load.
    s = t.get("SuspendedState") or {}
    if t["MinCapacity"] == t["MaxCapacity"]:
        return "PINNED"
    if any(s.get(k) for k in ("DynamicScalingInSuspended", "DynamicScalingOutSuspended", "ScheduledScalingSuspended")):
        return "FROZEN"
    if desired is not None and desired == t["MaxCapacity"]:
        return "AT-CEILING"
    if desired is not None and desired == t["MinCapacity"] and n_policies > 1:
        return "AT-FLOOR"
    return "ELASTIC"

targets = json.loads(os.environ["TARGETS_JSON"])
report = []
all_alarms_cache = None

if not targets:
    print("(no scalable target in the ecs namespace for a usms- cluster)")

for t in targets:
    rid, dim = t["ResourceId"], t["ScalableDimension"]
    _, cluster, service = rid.split("/", 2)

    svc, _ = aws("ecs", "describe-services", "--cluster", cluster, "--services", service,
                 "--query", "services[0].{d:desiredCount,r:runningCount}")
    desired = svc.get("d") if svc else None
    running = svc.get("r") if svc else None

    pols, perr = aws("application-autoscaling", "describe-scaling-policies", "--service-namespace", "ecs",
                     "--resource-id", rid, "--query", "ScalingPolicies")
    pols = pols or []

    # Alarms: target tracking policies list theirs; for step policies some builds leave
    # Alarms empty, so also find any alarm whose actions name the policy ARN.
    names = {a["AlarmName"] for p in pols for a in (p.get("Alarms") or [])}
    if any(p["PolicyType"] == "StepScaling" for p in pols):
        if all_alarms_cache is None:
            all_alarms_cache, _ = aws("cloudwatch", "describe-alarms", "--query", "MetricAlarms")
            all_alarms_cache = all_alarms_cache or []
    alarms = {}
    if names:
        found, _ = aws("cloudwatch", "describe-alarms", "--alarm-names", *sorted(names), "--query", "MetricAlarms")
        alarms = {a["AlarmName"]: a for a in (found or [])}

    sched, serr = aws("application-autoscaling", "describe-scheduled-actions", "--service-namespace", "ecs",
                      "--resource-id", rid, "--query", "ScheduledActions")
    acts, aerr = aws("application-autoscaling", "describe-scaling-activities", "--service-namespace", "ecs",
                     "--resource-id", rid, "--query", "ScalingActivities[0]")

    v = verdict(t, desired, len(pols))
    print(f"{rid:<45} {dim}")
    print(f"  bounds       min={t['MinCapacity']}  max={t['MaxCapacity']:<4} desired={desired if desired is not None else 'UNKNOWN'}"
          f"   running={running if running is not None else 'UNKNOWN'}   {v}")
    s = t.get("SuspendedState") or {}
    on = [k.replace("Suspended", "") for k, val in s.items() if val]
    print(f"  suspended    {', '.join(on) if on else 'none'}")

    pol_rows = []
    if perr:
        print(f"  policies     ({perr})")
    elif not pols:
        print("  policies     none")
    for p in sorted(pols, key=lambda p: (p["PolicyType"] != "TargetTrackingScaling", p["PolicyName"])):
        if p["PolicyType"] == "TargetTrackingScaling":
            c = p["TargetTrackingScalingPolicyConfiguration"]
            m = short_metric((c.get("PredefinedMetricSpecification") or {}).get("PredefinedMetricType"))
            extra = "  scale-in DISABLED" if c.get("DisableScaleIn") else ""
            print(f"  target-track {p['PolicyName']:<40} {m + '/' + str(c.get('TargetValue')):<15}"
                  f" out={c.get('ScaleOutCooldown', '-')}  in={c.get('ScaleInCooldown', '-')}{extra}")
            own = [a["AlarmName"] for a in (p.get("Alarms") or [])]
            if not own:
                print("                 alarms  (none listed)")
            else:
                parts = []
                for n in own:
                    kind = "AlarmHigh" if "AlarmHigh" in n else "AlarmLow" if "AlarmLow" in n else n
                    parts.append(f"{kind}={alarms.get(n, {}).get('StateValue', 'MISSING')}")
                print("                 alarms  " + "  ".join(parts))
        else:
            c = p.get("StepScalingPolicyConfiguration", {})
            print(f"  step         {p['PolicyName']:<40} {signed(c.get('StepAdjustments', [])):<15} cooldown={c.get('Cooldown', '-')}")
            linked = [a for a in (all_alarms_cache or []) if p["PolicyARN"] in (a.get("AlarmActions") or [])]
            if not linked:
                print("                 alarm   (none invokes this policy)")
            op = {"GreaterThanOrEqualToThreshold": ">=", "GreaterThanThreshold": ">",
                  "LessThanThreshold": "<", "LessThanOrEqualToThreshold": "<="}
            for a in linked:
                print(f"                 alarm   {a['AlarmName']} = {a['StateValue']}  "
                      f"({a.get('Namespace')} {a.get('MetricName')} {op.get(a.get('ComparisonOperator'), a.get('ComparisonOperator'))} {a.get('Threshold'):g})")
        pol_rows.append(p)

    if serr:
        print(f"  scheduled    none ({serr})")
    elif not sched:
        print("  scheduled    none")
    for a in (sched or []):
        print(f"  scheduled    {a['ScheduledActionName']:<34} {a.get('Schedule', '-'):<26} {a.get('Timezone', 'UTC'):<13}"
              f" min={(a.get('ScalableTargetAction') or {}).get('MinCapacity', '-')}")

    if aerr:
        print(f"  last activity  none recorded ({aerr})")
    elif not acts:
        print("  last activity  none recorded")
    else:
        print(f"  last activity  {acts.get('StartTime', '?')}  {acts.get('StatusCode', '?')}  {acts.get('Description', '')}")

    report.append({"resourceId": rid, "scalableDimension": dim, "minCapacity": t["MinCapacity"],
                   "maxCapacity": t["MaxCapacity"], "desired": desired, "running": running, "verdict": v,
                   "suspendedState": s, "policies": pol_rows, "alarms": list(alarms.values()),
                   "scheduledActions": sched if not serr else serr, "lastActivity": acts if not aerr else aerr})

with open(out_path, "w") as f:
    json.dump({"generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "targets": report}, f, indent=2, default=str)
PY
