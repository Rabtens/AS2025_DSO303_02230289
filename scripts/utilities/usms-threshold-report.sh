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
