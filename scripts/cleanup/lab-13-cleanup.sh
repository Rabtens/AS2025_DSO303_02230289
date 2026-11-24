#!/usr/bin/env bash
# END-OF-COURSE CLEANUP for Lab 13. Deletes dependencies inside-out.
# DO NOT RUN while Lab 09 or anything after it still needs these alarms.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

CENTRAL="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
FN_LOG="${USMS_LOG_GROUP_NOTIFIER:-/aws/lambda/usms-transcript-notifier}"

cat << 'WARN'
This will permanently delete:
  - usms-transcript-pipeline-down (composite), and its two child alarms
  - ALL alarm history for them, which is not recoverable
  - the usms-overview dashboard
  - the usms-notify-count and usms-central-errors metric filters
  - /usms/central/application AND EVERY LOG EVENT IN IT
  - the usms-transcripts-sampling X-Ray rule
  - USMSObservabilityWrite, after detaching it from two roles

A future alerting lab (not yet written) attaches SNS actions to those alarms by name.
Metric DATA already published into USMS/Application is not deleted by this
script and cannot be deleted at all - CloudWatch metrics expire, they are
never removed. That is worth knowing and is not a bug.
WARN

printf 'Type exactly: DELETE USMS OBSERVABILITY\n> '
read -r CONFIRM
[ "$CONFIRM" = "DELETE USMS OBSERVABILITY" ] || { echo "aborted"; exit 1; }

echo "1/7 deleting the composite alarm first (it references the others)"
aws cloudwatch delete-alarms --alarm-names usms-transcript-pipeline-down 2>/dev/null \
  && echo "    deleted usms-transcript-pipeline-down" \
  || echo "    already absent"

echo "2/7 deleting the child alarms"
aws cloudwatch delete-alarms \
  --alarm-names usms-transcript-lag-high usms-notify-silence 2>/dev/null \
  && echo "    deleted both metric alarms" \
  || echo "    already absent"

echo "3/7 deleting the dashboard"
aws cloudwatch delete-dashboards --dashboard-names usms-overview 2>/dev/null \
  && echo "    deleted usms-overview" \
  || echo "    already absent"

echo "4/7 deleting the metric filters (stops new data first)"
aws logs delete-metric-filter --log-group-name "$FN_LOG" \
  --filter-name usms-notify-count 2>/dev/null || true
aws logs delete-metric-filter --log-group-name "$CENTRAL" \
  --filter-name usms-central-errors 2>/dev/null || true

echo "5/7 deleting the central log group and its events"
aws logs delete-log-group --log-group-name "$CENTRAL" 2>/dev/null \
  && echo "    deleted $CENTRAL" \
  || echo "    already absent"

echo "6/7 deleting the X-Ray sampling rule"
aws xray delete-sampling-rule --rule-name usms-transcripts-sampling 2>/dev/null \
  && echo "    deleted usms-transcripts-sampling" \
  || echo "    already absent or unsupported"

echo "7/7 detaching and deleting USMSObservabilityWrite"
OBS_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSObservabilityWrite'].Arn | [0]" --output text 2>/dev/null)
if [ -n "$OBS_ARN" ] && [ "$OBS_ARN" != "None" ]; then
  for role in usms-lambda-exec-role usms-ec2-app-role; do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$OBS_ARN" 2>/dev/null \
      && echo "    detached from $role" || true
  done
  aws iam delete-policy --policy-arn "$OBS_ARN" 2>/dev/null \
    && echo "    deleted USMSObservabilityWrite" \
    || echo "    could not delete - check for remaining attachments"
fi

echo
echo "NOT deleted, deliberately:"
echo "  - the notifier's versions and alias (Lab 10 owns them)"
echo "  - /aws/lambda/usms-transcript-notifier (Lambda recreates it anyway)"
echo "  - retention policies on groups this lab did not create"
echo "  - metric data in USMS/Application (CloudWatch metrics cannot be deleted)"
