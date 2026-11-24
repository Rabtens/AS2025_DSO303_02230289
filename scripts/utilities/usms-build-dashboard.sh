#!/usr/bin/env bash
# Generate templates/lab-13-dashboard.json from configuration, then put it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true

ACCOUNT="${USMS_ACCOUNT_ID:?USMS_ACCOUNT_ID unset - source configs/lab-01.env}"
REGION="${AWS_REGION_COURSE:-${AWS_DEFAULT_REGION:-us-east-1}}"

python3 - "$ACCOUNT" "$REGION" << 'PY' > templates/lab-13-dashboard.json
import json, sys
acct, region = sys.argv[1], sys.argv[2]
ns = "USMS/Application"
alarm = lambda n: "arn:aws:cloudwatch:%s:%s:alarm:%s" % (region, acct, n)
widgets = [
  {"type": "text", "x": 0, "y": 0, "width": 24, "height": 2,
   "properties": {"markdown": "# USMS - transcript delivery\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only."}},
  {"type": "metric", "x": 0, "y": 2, "width": 12, "height": 6,
   "properties": {"title": "Transcripts processed, by faculty", "region": region, "stat": "Sum",
                  "period": 300, "view": "timeSeries", "stacked": False,
                  "metrics": [[ns, "TranscriptsProcessed", "Faculty", "science", "Stage", "notify"],
                              [ns, "TranscriptsProcessed", "Faculty", "engineering", "Stage", "notify"]]}},
  {"type": "metric", "x": 12, "y": 2, "width": 12, "height": 6,
   "properties": {"title": "Notification latency - max and average", "region": region, "period": 60,
                  "view": "timeSeries",
                  "metrics": [[ns, "TranscriptLagSeconds", "Stage", "notify", {"stat": "Maximum", "label": "max"}],
                              [ns, "TranscriptLagSeconds", "Stage", "notify", {"stat": "Average", "label": "avg"}]],
                  "annotations": {"horizontal": [{"label": "alarm threshold", "value": 2}]}}},
  {"type": "metric", "x": 0, "y": 8, "width": 8, "height": 4,
   "properties": {"title": "Notifications in the last 5 minutes", "region": region, "stat": "Sum",
                  "period": 300, "view": "singleValue",
                  "metrics": [[ns, "NotifyCount"], [ns, "CentralErrorCount"]]}},
  {"type": "alarm", "x": 8, "y": 8, "width": 16, "height": 4,
   "properties": {"title": "Pipeline alarms",
                  "alarms": [alarm("usms-transcript-pipeline-down"),
                             alarm("usms-transcript-lag-high"),
                             alarm("usms-notify-silence")]}},
  {"type": "metric", "x": 0, "y": 12, "width": 24, "height": 6,
   "properties": {"title": "Central errors - last 3 hours", "region": region, "stat": "Sum",
                  "period": 300, "view": "timeSeries", "start": "-PT3H", "end": "P0D",
                  "metrics": [[ns, "CentralErrorCount"]],
                  "annotations": {"horizontal": [{"label": "error threshold", "value": 1}]}}},
]
print(json.dumps({"widgets": widgets}, indent=2))
PY

python3 -m json.tool templates/lab-13-dashboard.json > /dev/null && echo "valid JSON"
aws cloudwatch put-dashboard --dashboard-name usms-overview \
  --dashboard-body file://templates/lab-13-dashboard.json \
  --query 'DashboardValidationMessages' --output json
