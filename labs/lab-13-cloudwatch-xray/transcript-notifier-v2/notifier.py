"""usms-transcript-notifier, version 2 - instrumented.

Adds to the Lab 10 handler, without removing anything it did:
  * a CloudWatch custom metric per processed transcript, in USMS/Application
  * a trace id on every log line, so a log and a trace can be joined
  * an explicit duration measurement, published as TranscriptLagSeconds

Stays inside USMSLambdaBasic + USMSObservabilityWrite (Lab 13 Step 12):
logs write, s3:GetObject, cloudwatch:PutMetricData in one namespace, xray:Put*.
"""

import json
import os
import time
import urllib.parse

BUCKET_HINT = os.environ.get("USMS_BUCKET", "usms-student-data")
CHANNEL = os.environ.get("USMS_NOTIFY_CHANNEL", "stdout")
NAMESPACE = os.environ.get("USMS_METRIC_NAMESPACE", "USMS/Application")
FACULTY_DEFAULT = os.environ.get("USMS_FACULTY_DEFAULT", "unknown")


def trace_id(context):
    """The trace id for this invocation.

    With active tracing, the Lambda runtime puts the header in _X_AMZN_TRACE_ID,
    shaped 'Root=1-...;Parent=...;Sampled=1'. Without it, the variable is absent
    and we fall back to the request id so that a log line is still correlatable.
    """
    header = os.environ.get("_X_AMZN_TRACE_ID", "")
    for part in header.split(";"):
        if part.startswith("Root="):
            return part[len("Root="):]
    return getattr(context, "aws_request_id", "no-trace")


def describe(record):
    """Pull the four fields that matter out of one S3 event record."""
    s3 = record.get("s3", {})
    raw_key = s3.get("object", {}).get("key", "")
    return {
        "event": record.get("eventName"),
        "bucket": s3.get("bucket", {}).get("name"),
        # S3 URL-encodes the key in the event: "stu+00417 final.json".
        "key": urllib.parse.unquote_plus(raw_key),
        "size": s3.get("object", {}).get("size"),
    }


def faculty_of(key):
    """transcripts/<faculty>/<file> -> <faculty>; anything else -> the default.

    Kept deliberately crude. A dimension value must come from a SMALL set, and
    deriving it from a path is how you accidentally get one metric per student.
    """
    parts = key.split("/")
    if len(parts) >= 3 and parts[0] == "transcripts":
        candidate = parts[1]
        if candidate.isalpha() and len(candidate) <= 20:
            return candidate.lower()
    return FACULTY_DEFAULT


def publish(metric, value, unit, dimensions):
    """Publish one data point. Never fail the invocation over telemetry."""
    try:
        import boto3
        boto3.client("cloudwatch").put_metric_data(
            Namespace=NAMESPACE,
            MetricData=[{
                "MetricName": metric,
                "Value": value,
                "Unit": unit,
                "Dimensions": [{"Name": k, "Value": v} for k, v in dimensions.items()],
            }],
        )
        return True
    except Exception as exc:                          # noqa: BLE001
        print("USMS_METRIC_ERROR %s %s" % (metric, type(exc).__name__))
        return False


def notify(payload):
    """Where the results notification will eventually go.

    Today: a structured line on stdout, which CloudWatch Logs captures.
    Later: sns.publish(TopicArn=..., Message=json.dumps(payload)).
    """
    print("USMS_NOTIFY " + json.dumps(payload, sort_keys=True))


def handler(event, context):
    started = time.time()
    tid = trace_id(context)
    records = event.get("Records", [])

    print("usms-transcript-notifier v2: %d record(s), channel=%s, trace=%s"
          % (len(records), CHANNEL, tid))

    processed = []
    for record in records:
        info = describe(record)
        info["trace_id"] = tid

        if not info["key"].startswith("transcripts/"):
            print("skipping non-transcript object: %s" % info["key"])
            continue

        info["readable"] = False
        try:
            import boto3
            boto3.client("s3").head_object(Bucket=info["bucket"], Key=info["key"])
            info["readable"] = True
        except Exception as exc:                      # noqa: BLE001
            info["read_error"] = type(exc).__name__

        faculty = faculty_of(info["key"])
        info["faculty"] = faculty

        info["metric_published"] = publish(
            "TranscriptsProcessed", 1.0, "Count",
            {"Faculty": faculty, "Stage": "notify"})

        notify(info)
        processed.append(info["key"])

    elapsed = time.time() - started
    publish("TranscriptLagSeconds", elapsed, "Seconds", {"Stage": "notify"})

    print("USMS_SUMMARY " + json.dumps(
        {"processed": len(processed), "seconds": round(elapsed, 4), "trace_id": tid},
        sort_keys=True))

    return {"processed": len(processed), "keys": processed,
            "trace_id": tid, "seconds": round(elapsed, 4)}
