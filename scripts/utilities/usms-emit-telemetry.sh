#!/usr/bin/env bash
# Emit one of each USMS telemetry signal - a log event, a metric data point and
# a trace - describing the same fictional transcript, so that the three can be
# joined afterwards by trace id.
#
# Usage:  usms-emit-telemetry.sh [faculty] [seconds]
# Writes: appends to outputs/lab-13-trace-ids.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

FACULTY="${1:-science}"
SECONDS_TAKEN="${2:-0.42}"
GROUP="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
NAMESPACE="${USMS_METRIC_NAMESPACE:-USMS/Application}"
STREAM="emitter-$(date -u +%Y%m%d)"

IDS=$(python3 -c "
import os, time
now = time.time()
print('1-%08x-%s' % (int(now), os.urandom(12).hex()), os.urandom(8).hex(), int(now*1000), now)
")
TRACE_ID=$(printf '%s' "$IDS" | awk '{print $1}')
SEG_ID=$(printf '%s'  "$IDS" | awk '{print $2}')
NOW_MS=$(printf '%s' "$IDS" | awk '{print $3}')
NOW_S=$(printf '%s'  "$IDS" | awk '{print $4}')

LOG_EVENTS=$(python3 - "$NOW_MS" "$FACULTY" "$SECONDS_TAKEN" "$TRACE_ID" << 'PY'
import json, math, sys

timestamp, faculty, duration, trace_id = sys.argv[1:]
try:
    seconds = float(duration)
    if not math.isfinite(seconds) or seconds < 0:
        raise ValueError
except ValueError:
    sys.exit(f"Invalid duration {duration!r}. Pass a finite, nonnegative number of seconds.")

message = "USMS_EVENT " + json.dumps({
    "event": "transcript.processed",
    "faculty": faculty,
    "seconds": seconds,
    "trace_id": trace_id,
}, separators=(",", ":"))
print(json.dumps([{"timestamp": int(timestamp), "message": message}]))
PY
) || exit 1

aws logs create-log-stream --log-group-name "$GROUP" --log-stream-name "$STREAM" 2>/dev/null || true

TOKEN=$(aws logs describe-log-streams --log-group-name "$GROUP" \
  --log-stream-name-prefix "$STREAM" \
  --query "logStreams[?logStreamName=='$STREAM'].uploadSequenceToken | [0]" \
  --output text) || exit 1
TOKEN_ARGS=()
if [[ -n "$TOKEN" && "$TOKEN" != None ]]; then
  TOKEN_ARGS=(--sequence-token "$TOKEN")
fi

REJECTED=$(aws logs put-log-events \
  --log-group-name "$GROUP" --log-stream-name "$STREAM" \
  "${TOKEN_ARGS[@]}" --log-events "$LOG_EVENTS" \
  --query 'rejectedLogEventsInfo' --output json) || exit 1
if [[ "$REJECTED" != null ]]; then
  printf 'Log event rejected: %s\n' "$REJECTED" >&2
  exit 1
fi
echo "  log     ok   $GROUP"

aws cloudwatch put-metric-data \
  --namespace "$NAMESPACE" \
  --metric-data "MetricName=TranscriptsProcessed,Unit=Count,Value=1,Dimensions=[{Name=Faculty,Value=$FACULTY},{Name=Stage,Value=notify}]" \
                "MetricName=TranscriptLagSeconds,Unit=Seconds,Value=$SECONDS_TAKEN,Dimensions=[{Name=Stage,Value=notify}]" \
  && echo "  metric  ok   $NAMESPACE"

SEGMENT=$(python3 - "$TRACE_ID" "$SEG_ID" "$NOW_S" "$FACULTY" "$SECONDS_TAKEN" << 'PY'
import json, sys
trace_id, seg_id, now, faculty, secs = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], float(sys.argv[5])
print(json.dumps({
    "name": "usms-transcript-notifier",
    "id": seg_id,
    "trace_id": trace_id,
    "start_time": round(now - secs, 3),
    "end_time": round(now, 3),
    "origin": "AWS::Lambda::Function",
    "annotations": {"faculty": faculty, "stage": "notify", "emitted_by": "usms-emit-telemetry"},
}))
PY
)

if aws xray put-trace-segments --trace-segment-documents "$SEGMENT" \
     --query 'UnprocessedTraceSegments' --output text >/dev/null 2>&1; then
  echo "  trace   ok   $TRACE_ID"
else
  echo "  trace   SKIPPED (X-Ray unavailable on this build) $TRACE_ID"
fi

printf '%s %s emitter/%s\n' "$TRACE_ID" "$SEG_ID" "$FACULTY" >> outputs/lab-13-trace-ids.txt
echo
echo "trace id: $TRACE_ID"
