#!/usr/bin/env bash
# Print the decision table of every load balancer whose name starts with "usms-":
# each listener, its rules in evaluation order (default last), and for every
# forward target group how many targets it has and how many are healthy.
# Also writes the same data to outputs/lab-05-lb-report.json. Read-only.
#
# Usage: ./scripts/utilities/usms-lb-report.sh   (no arguments; runs from any directory)
#
# set -e is deliberately NOT used: this is a report. A listener deleted mid-run or a
# target group that cannot be described must print an explicit "(unavailable)" row,
# not abort the report for every other load balancer. Each AWS call is checked instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
export AWS_PAGER=""
OUT_JSON="$REPO_ROOT/outputs/lab-05-lb-report.json"
mkdir -p "$REPO_ROOT/outputs"

# Level 1 - load balancers, filtered by prefix (the only name this script knows).
LBS=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?starts_with(LoadBalancerName, 'usms-')]" --output json 2>/dev/null) \
  || { echo "ERROR: cannot list load balancers" >&2; exit 1; }

report='[]'
for lb_arn in $(jq -r '.[].LoadBalancerArn' <<< "$LBS"); do
  lb=$(jq --arg a "$lb_arn" '.[] | select(.LoadBalancerArn == $a)
        | {name: .LoadBalancerName, scheme: .Scheme, type: .Type, state: .State.Code,
           azs: (.AvailabilityZones | length), sgs: ((.SecurityGroups // []) | length)}' <<< "$LBS")

  # Level 2 - listeners (a load balancer may have none).
  listeners=$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" \
                --query 'Listeners' --output json 2>/dev/null) || listeners='[]'

  lst_out='[]'
  for l_arn in $(jq -r '.[].ListenerArn' <<< "$listeners"); do
    l=$(jq --arg a "$l_arn" '.[] | select(.ListenerArn == $a) | {protocol: .Protocol, port: .Port}' <<< "$listeners")

    # Level 3 - rules (the default rule is always present; there may be no others).
    rules=$(aws elbv2 describe-rules --listener-arn "$l_arn" --query 'Rules' --output json 2>/dev/null) || rules='[]'

    # Level 4 - target health, once per distinct forward target group on this listener.
    tg_info='{}'
    for tg_arn in $(jq -r '[.[].Actions[] | select(.Type == "forward")
                           | (.TargetGroupArn // empty), (.ForwardConfig.TargetGroups[]?.TargetGroupArn // empty)]
                          | unique[]' <<< "$rules"); do
      if th=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" \
               --query "{total: length(TargetHealthDescriptions), healthy: length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])}" \
               --output json 2>/dev/null); then
        tg_info=$(jq --arg a "$tg_arn" --argjson h "$th" '. + {($a): $h}' <<< "$tg_info")
      else
        tg_info=$(jq --arg a "$tg_arn" '. + {($a): null}' <<< "$tg_info")
      fi
    done

    lst_out=$(jq --argjson l "$l" --argjson r "$rules" --argjson t "$tg_info" \
                '. + [$l + {rules: $r, targetHealth: $t}]' <<< "$lst_out")
  done

  report=$(jq --argjson lb "$lb" --argjson ls "$lst_out" '. + [$lb + {listeners: $ls}]' <<< "$report")
done

# Formatting, sorting and the JSON file are done in python3: ordering rules and
# summarising several action types is clearer there than in jq or bash.
REPORT_JSON="$report" python3 - "$OUT_JSON" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, sys

out_path, generated = sys.argv[1], sys.argv[2]
lbs = json.loads(os.environ["REPORT_JSON"])

def rule_key(rule):
    # Priority is a STRING: "10", "20", ... and the literal "default" for the default rule.
    # Sort numerically, and put "default" last (it is evaluated only if nothing else matched).
    p = rule.get("Priority", "default")
    return (1, 0) if p == "default" else (0, int(p))

def conditions(rule):
    parts = []
    for c in rule.get("Conditions", []):
        field = c.get("Field", "?")
        cfg_key = {"path-pattern": "PathPatternConfig", "host-header": "HostHeaderConfig",
                   "http-request-method": "HttpRequestMethodConfig"}.get(field)
        vals = (c.get(cfg_key, {}) or {}).get("Values") if cfg_key else None
        vals = vals or c.get("Values") or []
        parts.append((field, ",".join(vals) or "-"))
    return parts or [("-", "-")]

def tg_name(arn):
    return arn.split(":targetgroup/")[1].split("/")[0] if ":targetgroup/" in arn else arn

def action(rule, health):
    a = (rule.get("Actions") or [{}])[0]
    t = a.get("Type", "none")
    if t == "forward":
        arns = [a["TargetGroupArn"]] if a.get("TargetGroupArn") else \
               [g["TargetGroupArn"] for g in a.get("ForwardConfig", {}).get("TargetGroups", [])]
        out = []
        for arn in arns:
            h = health.get(arn)
            counts = "(unavailable)" if h is None else f"({h['total']} targets, {h['healthy']} healthy)"
            out.append(f"{tg_name(arn):<18} {counts}")
        return "-> " + "; ".join(out) if out else "-> forward (no target group)"
    if t == "fixed-response":
        return f"-> fixed-response {a.get('FixedResponseConfig', {}).get('StatusCode', '?')}"
    if t == "redirect":
        r = a.get("RedirectConfig", {})
        return f"-> redirect {r.get('StatusCode', '?')} to {r.get('Protocol', '#{protocol}')}:{r.get('Port', '#{port}')}"
    return f"-> {t}"

if not lbs:
    print("(no load balancer whose name starts with usms-)")
for lb in lbs:
    print(f"{lb['name']:<20} {lb['scheme']:<16} {lb['type']:<12} {lb['state']:<7} AZs={lb['azs']}  SGs={lb['sgs']}")
    if not lb["listeners"]:
        print("  (no listeners)")
    for l in sorted(lb["listeners"], key=lambda x: x["port"]):
        print(f"  {l['protocol']}:{l['port']}")
        rules = sorted(l["rules"], key=rule_key)
        if not any(r.get("Priority") != "default" for r in rules):
            print("    (no non-default rules)")
        for r in rules:
            field, vals = conditions(r)[0]
            print(f"    prio  {r.get('Priority', 'default'):<8} {field:<13} {vals:<27} {action(r, l['targetHealth'])}")

with open(out_path, "w") as f:
    json.dump({"generatedAt": generated, "loadBalancers": lbs}, f, indent=2)
PY
