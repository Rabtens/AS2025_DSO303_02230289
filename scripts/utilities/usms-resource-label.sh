#!/usr/bin/env bash
# Derive the ResourceLabel that ALBRequestCountPerTarget needs, from the API:
#
#   <load-balancer-arn-suffix>/<target-group-arn-suffix>
#   app/usms-enrolment-alb/<lb-id>/targetgroup/usms-enrolment-tg/<tg-id>
#
# Usage: usms-resource-label.sh [load-balancer-name] [target-group-name]
#        defaults: usms-enrolment-alb usms-enrolment-tg
# Prints the label on stdout and exits 0, or prints why on stderr and exits 1.
# Never reads configs/lab-05.env for the ARNs: they are looked up by name every time.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"   # endpoint/profile only - no ARNs come from here
export AWS_PAGER=""

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
           --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
           --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)

[ -n "$LB_ARN" ] && [ "$LB_ARN" != None ] || { echo "load balancer '$LB_NAME' not found" >&2; exit 1; }
[ -n "$TG_ARN" ] && [ "$TG_ARN" != None ] || { echo "target group '$TG_NAME' not found" >&2; exit 1; }

# The two suffixes need different cuts because the resource types differ in the ARN:
#   ...:loadbalancer/app/<name>/<id>    the label wants what comes AFTER "loadbalancer/",
#                                       so the "loadbalancer/" prefix itself is dropped;
#   ...:targetgroup/<name>/<id>         the label wants "targetgroup/..." INCLUDING that word,
#                                       i.e. everything after the last ":".
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"   # shortest prefix match up to and including "loadbalancer/"
TG_SUFFIX="${TG_ARN##*:}"               # longest prefix match up to the last ":"

LABEL="${LB_SUFFIX}/${TG_SUFFIX}"

# Plausibility: six "/"-separated segments: app, LB name, LB id, targetgroup, TG name, TG id.
IFS=/ read -r s1 s2 s3 s4 s5 s6 extra <<< "$LABEL"
if [ "$s1" != app ] || [ "$s2" != "$LB_NAME" ] || [ -z "$s3" ] || [ "$s4" != targetgroup ] \
   || [ "$s5" != "$TG_NAME" ] || [ -z "$s6" ] || [ -n "${extra:-}" ]; then
  echo "implausible ResourceLabel '$LABEL' (expected app/$LB_NAME/<id>/targetgroup/$TG_NAME/<id>)" >&2
  exit 1
fi

echo "$LABEL"
