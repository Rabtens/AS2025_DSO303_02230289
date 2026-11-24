## Independent Lab Exercises

Record exercise notes in `labs/lab-13-cloudwatch-xray/exercises.md`.

### Exercise 1 - Basic: extract a value instead of counting events

**Approach chosen:** The `USMS_EVENT ` prefix makes the JSON dialect unavailable, and the text dialect cannot pull a field out of a JSON token. So I changed **what the emitter writes**. It now *also* writes a second, **pure-JSON** line carrying `"source":"usms"`, which the JSON dialect can read. The cost is one extra log line per event, so ingestion volume roughly doubles for these events. The benefit is that no code has to change to add a latency metric.

**1. Test the pattern first:**

```bash
aws logs test-metric-filter \
  --filter-pattern '{ ($.source = "usms") && ($.event = "transcript.processed") }' \
  --log-event-messages \
    '{"source":"usms","event":"transcript.processed","faculty":"science","seconds":0.51}' \
    '{"source":"usms","event":"transcript.failed","faculty":"science"}' \
    'USMS_EVENT {"event":"transcript.processed","faculty":"science","seconds":0.51}' \
    'HEALTHCHECK status ok' \
  --query 'matches[].[eventNumber,extractedValues]' --output json \
  | tee outputs/lab-13-ex1-filter-test.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-47-02.png>)

Expect only event 1 to match.

**2. Deploy the filter:**

```bash
aws logs put-metric-filter \
  --log-group-name /usms/central/application \
  --filter-name usms-transcript-seconds \
  --filter-pattern '{ ($.source = "usms") && ($.event = "transcript.processed") }' \
  --metric-transformations \
      'metricName=TranscriptSecondsFromLogs,metricNamespace=USMS/Application,metricValue=$.seconds,unit=Seconds'
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-47-34.png>)

**3. Update the emitter** to write the extra pure-JSON line. This inserts a block just before the trace-id `printf` line:

```bash
python3 - << 'PY'
p = "scripts/utilities/usms-emit-telemetry.sh"
s = open(p).read()
marker = "printf '%s %s emitter/%s\\n'"
block = r'''# Exercise 1: a pure-JSON line so a JSON-dialect metric filter can extract "seconds"
python3 - "$NOW_MS" "$FACULTY" "$SECONDS_TAKEN" "$TRACE_ID" << 'PYJ' > outputs/lab-13-emit-json-event.json
import json, sys
ms, fac, secs, tid = int(sys.argv[1]) + 1, sys.argv[2], float(sys.argv[3]), sys.argv[4]
msg = json.dumps({"source": "usms", "event": "transcript.processed",
                  "faculty": fac, "seconds": secs, "trace_id": tid}, separators=(",", ":"))
print(json.dumps([{"timestamp": ms, "message": msg}]))
PYJ
aws logs put-log-events --log-group-name "$GROUP" --log-stream-name "$STREAM" \
  --log-events file://outputs/lab-13-emit-json-event.json \
  --query 'rejectedLogEventsInfo' --output json >/dev/null \
  && echo "  jsonlog ok   $GROUP"

'''
if "Exercise 1: a pure-JSON line" not in s:
    s = s.replace(marker, block + marker, 1)
    open(p, "w").write(s)
print("patched")
PY

bash -n scripts/utilities/usms-emit-telemetry.sh && echo "syntax OK"
./scripts/utilities/usms-emit-telemetry.sh science 0.75
./scripts/utilities/usms-emit-telemetry.sh engineering 2.20
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-48-02.png>)

**4. Read back:**

```bash
WINDOW=$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
print((now - datetime.timedelta(minutes=15)).strftime('%Y-%m-%dT%H:%M:%SZ'), now.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
aws cloudwatch get-metric-statistics --namespace USMS/Application \
  --metric-name TranscriptSecondsFromLogs \
  --start-time "${WINDOW% *}" --end-time "${WINDOW#* }" --period 300 \
  --statistics SampleCount Minimum Maximum \
  --query 'Datapoints' --output json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-48-23.png>)

**Expected:** Values that match 0.75 and 2.20. If the filter is not evaluated on Floci, record that and rely on the `test-metric-filter` output.

**Paragraph for `exercises.md`:** `TranscriptSecondsFromLogs` (derived from logs by a filter) and `TranscriptLagSeconds` (published by `put-metric-data`) measure the same thing by two routes. The filter route needs no code change and works on logs from code I do not own, but it is not retroactive and depends on the log format staying stable. The direct route is explicit and cheaper to ingest, but every new measurement needs a code change. I would keep `TranscriptLagSeconds`, because the handler is ours and the direct metric does not depend on a marker string.


---

### Exercise 2 - Intermediate: make the dashboard portable and add a widget

**Generator script** (reads `USMS_ACCOUNT_ID` and `AWS_REGION_COURSE`; no literals):

```bash
cat > scripts/utilities/usms-build-dashboard.sh << 'EOF'
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
EOF

chmod +x scripts/utilities/usms-build-dashboard.sh
bash -n scripts/utilities/usms-build-dashboard.sh && ./scripts/utilities/usms-build-dashboard.sh

grep -c '000000000000' templates/lab-13-dashboard.json   # the literal is gone from the generator;
                                                          # on Floci the generated value is still the account id
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-49-54.png>)

**Update the verification script from 5 to 6 widgets:**

```bash
sed -i.bak 's/dashboard has 5 widgets/dashboard has 6 widgets/; s/"$(dashboard_widgets)" -eq 5/"$(dashboard_widgets)" -eq 6/' \
  scripts/utilities/verify-lab-13.sh && rm -f scripts/utilities/verify-lab-13.sh.bak
./scripts/utilities/verify-lab-13.sh | tail -1
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-50-43.png>)

**Note for `exercises.md`:** A hard-coded widget count is useful because it catches a widget silently dropped by a bad regeneration. It is annoying because every legitimate change to the dashboard also needs a change to the check. It trades change-friction for detection.


---

### Exercise 3 - Problem solving: are these thresholds defensible?

```bash
cat > scripts/utilities/usms-threshold-report.sh << 'EOF'
#!/usr/bin/env bash
# Report every usms-* alarm's configuration next to the last 24h of its metric.
# Valid JSON on stdout only; diagnostics on stderr. Runs from any directory.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" >&2

python3 - << 'PY'
import datetime, json, subprocess, sys

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        print("aws %s failed: %s" % (" ".join(args[:2]), r.stderr.strip()), file=sys.stderr)
        return {}
    return json.loads(r.stdout or "{}")

alarms = aws("cloudwatch", "describe-alarms", "--alarm-name-prefix", "usms-",
             "--alarm-types", "MetricAlarm", "CompositeAlarm")
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = (now - datetime.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
end = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def breached(op, th, mx, mn):
    if mx is None:
        return False
    return {"GreaterThanThreshold": mx > th, "GreaterThanOrEqualToThreshold": mx >= th,
            "LessThanThreshold": mn < th, "LessThanOrEqualToThreshold": mn <= th}.get(op, False)

out = []
for a in alarms.get("MetricAlarms", []):
    args = ["cloudwatch", "get-metric-statistics", "--namespace", a["Namespace"],
            "--metric-name", a["MetricName"], "--start-time", start, "--end-time", end,
            "--period", "86400", "--statistics", "Minimum", "Average", "Maximum", "SampleCount"]
    dims = a.get("Dimensions") or []
    if dims:
        args += ["--dimensions"] + ["Name=%s,Value=%s" % (d["Name"], d["Value"]) for d in dims]
    pts = aws(*args).get("Datapoints", [])
    if pts:
        obs = {"min": min(p["Minimum"] for p in pts),
               "avg": round(sum(p["Average"] * p["SampleCount"] for p in pts) /
                            max(sum(p["SampleCount"] for p in pts), 1), 4),
               "max": max(p["Maximum"] for p in pts),
               "samples": sum(p["SampleCount"] for p in pts)}
    else:
        obs = {"min": None, "avg": None, "max": None, "samples": 0}
    out.append({"alarm": a["AlarmName"], "namespace": a["Namespace"], "metric": a["MetricName"],
                "statistic": a.get("Statistic"), "period": a.get("Period"),
                "evaluation_periods": a.get("EvaluationPeriods"),
                "datapoints_to_alarm": a.get("DatapointsToAlarm"),
                "threshold": a.get("Threshold"), "operator": a.get("ComparisonOperator"),
                "missing_data": a.get("TreatMissingData"), "observed": obs,
                "threshold_ever_breached": breached(a.get("ComparisonOperator"), a.get("Threshold"),
                                                    obs["max"], obs["min"])})
for c in alarms.get("CompositeAlarms", []):
    out.append({"alarm": c["AlarmName"], "namespace": None, "metric": None, "statistic": None,
                "period": None, "evaluation_periods": None, "datapoints_to_alarm": None,
                "threshold": None, "operator": None, "missing_data": None,
                "rule": c.get("AlarmRule"),
                "observed": {"min": None, "avg": None, "max": None, "samples": 0},
                "threshold_ever_breached": None})
print(json.dumps(out, indent=2))
PY
EOF

chmod +x scripts/utilities/usms-threshold-report.sh
bash -n scripts/utilities/usms-threshold-report.sh && echo "syntax OK"
( cd /tmp && ~/aws-floci-course/scripts/utilities/usms-threshold-report.sh ) \
  | tee outputs/lab-13-threshold-report.json | python3 -m json.tool > /dev/null && echo "valid JSON from /tmp"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-52-48.png>)

**Note:** `usms-enrolment-queue-high` (Lab 06) is also included, because it matches the `usms-` prefix. Its sample count of 0 and `threshold_ever_breached: false` is the finding: a threshold never checked against data. I record which alarms have thresholds never approached and argue whether each one is defensible.


---

### Exercise 4 - Challenge: design the USMS observability plan

Create `notes/lab-13-observability-plan.md` (design document, no commands inside it):

```bash
mkdir -p notes
cat > notes/lab-13-observability-plan.md << 'EOF'
# USMS Observability Plan (Lab 13, Exercise 4)

## 1. The four complaints, and which layer answers each
| Complaint | Right layer | Why not the other two |
|---|---|---|
| Nobody noticed for six hours; dashboard was green because graphs were empty | **Metrics + an alarm on absence** (NotifyCount, treat-missing-data=breaching) | Logs are only read after someone suspects a problem; a trace of a request that never happened does not exist |
| Could not tell whether upload, function or bucket failed | **Traces** (X-Ray, one trace id across S3 → notifier → bucket read) | Metrics are aggregated and lose the individual request; logs are per-component and have to be joined by hand |
| Who downloaded transcript X in March? | **Logs** – a dedicated audit log group with long retention | Metrics discard identity; traces are sampled and kept only 30 days |
| Monitoring bill larger than the monitored system | **Metrics/log design (cardinality + retention)** | Not a single-layer issue: fix dimensions and retention, not add more telemetry |

## 2. Log group taxonomy
| Log group | Contents | Retention | Readers |
|---|---|---|---|
| /usms/central/application | application events | 30 days | developers, ops |
| /usms/ecs/enrolment | container output | 30 days | developers, ops |
| /aws/lambda/usms-* | function runtime output | 14 days (shortest - pure debugging data; nobody reads it after two weeks) | developers |
| /usms/audit/transcript-access | who read which transcript, when, from where | 2557 days / 7 years (longest - driven by records-retention policy; to be confirmed with the registrar) | audit office + security only, separate IAM policy; developers denied |
Numbers: 30 and 14 days came from "how far back do we actually look when debugging"; 7 years is an assumption to verify against the university's records policy.

## 3. Service level indicators
| SLI | Target | Alarm or graph |
|---|---|---|
| Transcript notifications delivered within 5 s of upload | 99% per day | **Alarm** (student-visible) |
| Notification pipeline producing at least one event per 15 min in working hours | 100% of working hours | **Alarm** (absence) |
| Transcript request error rate (failed / requested) | < 1% per day | **Graph** only - slow-burn indicator reviewed weekly; paging on it would page for single bad uploads |
Targets are initial guesses; I would measure one month of baseline latency (Exercise 5 file) before committing.

## 4. Alarms
| Alarm | Missing data |
|---|---|
| usms-transcript-lag-high (Max TranscriptLagSeconds > 2 s, 2 of 3 min) | notBreaching |
| usms-notify-silence (Sum NotifyCount < 1 for 3 x 5 min, working hours) | **breaching** |
| usms-central-errors-high (Sum CentralErrorCount > 5 in 5 min) | notBreaching |
| usms-transcript-pipeline-down (composite of the above; the only one that pages) | n/a |
**usms-notify-silence** would have caught the six-hour outage in 15 minutes. A threshold alarm on a value cannot: when the pipeline stops, no values arrive, so "value too high" is never evaluated as true.

## 5. Where the bill goes (order of magnitude)
- Log ingestion and storage with never-expire retention - largest; grows forever.
- Custom metrics multiplied by dimension cardinality - second largest if an ID leaked into a dimension.
- Insights queries scanning months of logs; traces at 100% sampling.
Two biggest changes: (1) retention on every group, (2) remove any high-cardinality dimension.
Dimension cardinality: Faculty ~8, Stage ~4 (notify, render, origin, viewer-request). No StudentId dimension - student id lives in log fields and X-Ray annotations.

## 6. Not building yet
Anomaly-detection alarms. Observation that would change my mind: after 3 months of baseline, static thresholds still produce more than one false page per week.

## Things to measure before committing
- Real latency distribution (p50/p99) per faculty over a month.
- Quietest legitimate gap in notifications during working hours.
- Log volume per group per day.
EOF
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-54-28.png>)

---

### Exercise 5 - Integration: leave an alarm the next alerting lab can attach to

**1. Draft (uses the real account ID, no literal):**

```bash
source configs/lab-01.env
python3 - "${USMS_ACCOUNT_ID:?}" << 'PY' > outputs/lab-13-alarm-actions-draft.json
import json, sys
acct = sys.argv[1]
arn = lambda t: "arn:aws:sns:us-east-1:%s:usms-%s" % (acct, t)
print(json.dumps([
  {"alarm": "usms-transcript-pipeline-down", "meaning": "Transcript pipeline failing or silent",
   "urgency": "page", "action_arn": arn("oncall-page")},
  {"alarm": "usms-transcript-lag-high", "meaning": "Transcript notifications slower than 2 s",
   "urgency": "ticket", "action_arn": arn("ops-tickets")},
  {"alarm": "usms-notify-silence", "meaning": "No transcript notifications for 15 minutes",
   "urgency": "ticket", "action_arn": arn("ops-tickets")},
], indent=2))
PY
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-55-56.png>)

**2. Validate (report mismatches, do not fix silently):**

```bash
python3 - << 'PY' | tee outputs/lab-13-alarm-actions-validation.txt
import json, re, subprocess
draft = json.load(open("outputs/lab-13-alarm-actions-draft.json"))
names = [d["alarm"] for d in draft]
r = subprocess.run(["aws", "cloudwatch", "describe-alarms", "--alarm-names", *names,
                    "--alarm-types", "MetricAlarm", "CompositeAlarm",
                    "--query", "[MetricAlarms[].AlarmName, CompositeAlarms[].AlarmName][]",
                    "--output", "json"], capture_output=True, text=True)
existing = set(json.loads(r.stdout or "[]"))
ok = True
for d in draft:
    if d["alarm"] not in existing:
        ok = False; print("MISSING ALARM :", d["alarm"])
    if not re.fullmatch(r"arn:aws:sns:[a-z0-9-]+:\d{12}:[A-Za-z0-9_-]+", d["action_arn"]):
        ok = False; print("BAD ARN       :", d["action_arn"])
print("validation:", "PASS" if ok else "FAIL")
PY
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-56-17.png>)

**3. Confirm it has not been applied:**

```bash
aws cloudwatch describe-alarms --alarm-names usms-transcript-lag-high \
  --query 'MetricAlarms[0].AlarmActions' --output json     # must be []
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-56-17.png>)

**4. Latency baseline (at least 5 emitter runs, mixed):**

```bash
for run in "science 0.44" "engineering 1.72" "science 0.91" "engineering 2.65" "science 0.38" "engineering 1.15"; do
  ./scripts/utilities/usms-emit-telemetry.sh $run
done

BW=$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
print((now - datetime.timedelta(hours=6)).strftime('%Y-%m-%dT%H:%M:%SZ'), now.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
aws cloudwatch get-metric-statistics --namespace USMS/Application \
  --metric-name TranscriptLagSeconds --dimensions Name=Stage,Value=notify \
  --start-time "${BW% *}" --end-time "${BW#* }" --period 21600 \
  --statistics SampleCount Minimum Average Maximum \
  --output json | tee outputs/lab-13-latency-baseline.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-57-15.png>)

**5. Readiness report (re-runnable):**

```bash
source configs/lab-13.env
{
  echo "Lab 13 alerting readiness - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "--- alarms and missing-data policies ---"
  aws cloudwatch describe-alarms --alarm-names usms-transcript-lag-high usms-notify-silence \
    --query 'MetricAlarms[].[AlarmName,TreatMissingData]' --output text
  echo "--- composite rule ---"
  aws cloudwatch describe-alarms --alarm-names usms-transcript-pipeline-down --alarm-types CompositeAlarm \
    --query 'CompositeAlarms[0].AlarmRule' --output text
  echo "--- namespace and metrics ---"
  echo "$USMS_METRIC_NAMESPACE"
  aws cloudwatch list-metrics --namespace USMS/Application --query 'Metrics[].MetricName' --output text \
    | tr '\t' '\n' | sort -u
  echo "--- notifier ---"
  aws lambda get-function-configuration --function-name usms-transcript-notifier --qualifier live \
    --query '[Version,TracingConfig.Mode]' --output text
  echo "--- capabilities ---"
  echo "xray=$USMS_XRAY_SUPPORTED insights=$USMS_INSIGHTS_SUPPORTED"
  echo "--- draft validation ---"
  tail -1 outputs/lab-13-alarm-actions-validation.txt
  echo "--- observed maximum latency ---"
  python3 -c "import json; d=json.load(open('outputs/lab-13-latency-baseline.json'))['Datapoints']; print(max((p['Maximum'] for p in d), default='no data'))"
} | tee outputs/lab-13-alerting-readiness.txt

git check-ignore -v outputs/lab-13-alerting-readiness.txt
./scripts/utilities/verify-lab-13.sh | tail -1
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-57-49.png>)

---

### Commit the exercises

```bash
git add labs/lab-13-cloudwatch-xray/exercises.md notes/lab-13-observability-plan.md \
        scripts/utilities/usms-build-dashboard.sh scripts/utilities/usms-threshold-report.sh \
        scripts/utilities/usms-emit-telemetry.sh scripts/utilities/verify-lab-13.sh \
        templates/lab-13-dashboard.json
git commit -m "Lab 13: independent exercises 1-5"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-58-10.png>)