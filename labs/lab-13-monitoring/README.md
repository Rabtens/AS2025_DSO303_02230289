# DSO303 - Practical 8: Centralized Logging and Monitoring with CloudWatch and X-Ray

## Lab 13 - USMS (University Student Management System) on Floci
---

## Table of Contents

1. [Aim](#1-aim)
2. [Objectives](#2-objectives)
3. [Theory / Background](#3-theory--background)
4. [Tools and Environment](#4-tools-and-environment)
5. [Pre-Lab Checks](#5-pre-lab-checks)
6. [Architecture](#6-architecture)
7. [Procedure (Steps 1 – 26)](#7-procedure)
8. [Verification](#8-verification)
9. [Checkpoint Summary](#9-checkpoint-summary)
10. [Floci vs Real AWS – Observations](#10-floci-vs-real-aws--observations)
11. [Independent Lab Exercises](#11-independent-lab-exercises)
12. [Review Questions](#12-review-questions)
13. [Lab Assessment Checklist](#13-lab-assessment-checklist)
14. [KEEP vs CLEAN UP and the Cleanup Script](#14-keep-vs-clean-up)
15. [Project Implementation Checkpoint 1 (Appendix C)](#15-project-implementation-checkpoint-1)
16. [Preparation for the Next Lab](#16-preparation-for-the-next-lab)
17. [Conclusion](#17-conclusion)
18. [References](#18-references)

---

## 1. Aim

To build a three-layer telemetry pipeline (logs, metrics, traces) over the existing USMS system using Amazon CloudWatch Logs, CloudWatch Metrics/Alarms/Dashboards and AWS X-Ray. The lab also records which behaviours were observed on Floci and which were only configured and checked by reading.

## 2. Objectives

By the end of this practical I should be able to:

1. Distinguish CloudWatch **logs, metrics, alarms and dashboards**, and say which question each answers.
2. Explain the **log group → log stream → log event** hierarchy, and set a deliberate retention period.
3. Write log events with `put-log-events` using **millisecond** timestamps, and read them back with `filter-log-events`.
4. Test a filter pattern with `test-metric-filter` before deploying it as a **metric filter**.
5. Publish custom metrics with `put-metric-data`, and explain why a **dimension is part of a metric's identity**.
6. Read metrics with `get-metric-statistics`, choosing period, statistic and window deliberately.
7. Create alarms with `put-metric-alarm`, justify a `--treat-missing-data` policy, and prove an alarm with `set-alarm-state`.
8. Build a **composite alarm** and explain the problem it solves.
9. Create a **dashboard** from a JSON document and read its validation messages.
10. Explain the **X-Ray data model** (trace, segment, subsegment, annotation, metadata) and hand-build a valid segment.
11. Send and retrieve traces (`put-trace-segments`, `get-trace-summaries`, `batch-get-traces`) and read a service graph.
12. Distinguish **annotations from metadata**, and configure a **sampling rule**.
13. Enable **active tracing** on Lambda and name the permissions it needs.
14. State precisely what was **observed** on Floci and what was only **recorded**.

## 3. Theory / Background

### 3.1 CloudWatch vs X-Ray

| Service | Question it answers | Main objects |
|---|---|---|
| **CloudWatch Logs** (`aws logs`) | *What exactly happened?* | Log group, log stream, log event, metric filter, Insights query |
| **CloudWatch Metrics** (`aws cloudwatch`) | *How many / how fast / is it normal?* | Namespace, metric, dimension, data point |
| **CloudWatch Alarms** (`aws cloudwatch`) | *Should somebody be told?* | Metric alarm, composite alarm, state, history |
| **CloudWatch Dashboards** (`aws cloudwatch`) | *Is it healthy at a glance?* | Dashboard JSON document, widgets |
| **AWS X-Ray** (`aws xray`) | *Where did this one request spend its time, and which hop failed?* | Trace, segment, subsegment, annotation, metadata, sampling rule |

The three layers work together. A metric shows that something is wrong. A log shows what the error said. A trace shows which component produced it.

### 3.2 Key concepts

- **Log group** is a unit of *retention and access control*, not a unit of component.
- **Metric filter** turns matching log lines into metric data points on ingestion. It is **not retroactive**.
- **Metric identity** is `namespace + metric name + the complete set of dimensions`. There is no automatic roll-up, so a total must be published separately.
- **Cardinality is cost.** Low-cardinality values such as faculty can be dimensions. High-cardinality values such as student ID belong in log fields or X-Ray annotations.
- **Alarm states** are `OK`, `ALARM` and `INSUFFICIENT_DATA`. The `--treat-missing-data` setting decides what silence means.
- **Composite alarms** combine alarms with `ALARM()`, `OK()`, `AND`, `OR` and `NOT`, so one incident produces one page.
- **X-Ray IDs:** `trace_id = 1-<8 hex epoch>-<24 hex random>`; segment `id` = 16 hex characters. Times are **epoch seconds as floats**. CloudWatch Logs uses **epoch milliseconds as integers**.
- **Annotations** are indexed and searchable, and hold only string, number or boolean values. **Metadata** can be any JSON but is not searchable.
- **Sampling** uses a reservoir (a guaranteed number per second) plus a fixed rate (a fraction of the rest). A lower priority number wins.

## 4. Tools and Environment

| Tool | Purpose |
|---|---|
| Floci (Docker Compose, hybrid storage) | Local AWS emulator at `http://localhost:4566` |
| AWS CLI v2 (`floci` profile) | All API calls |
| Python 3 | Millisecond timestamps, hex IDs, JSON construction and validation (portable across macOS and Linux) |
| Git | Version control of templates, scripts, configs |
| `openssl` | Portable base64 decoding |

## 5. Pre-Lab Checks

Prerequisites: Labs 01–12 are complete and their `configs/lab-NN.env` files exist, Floci is running with `FLOCI_STORAGE_MODE=hybrid`, `python3` is on the PATH, and `usms-transcript-notifier` has its `live` alias from Lab 10.

```bash
./scripts/utilities/floci-storage-check.sh
./scripts/utilities/verify-lab-10.sh | tail -2
```

**Expected:** The storage diagnostic reports a running Compose container, hybrid storage and a host bind mount. The Lab 10 verifier reports `PASS=51 FAIL=0`.

![Storage diagnostic and Lab 10 verification](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-49-46.png>)

**Observation:** The storage diagnostic showed a running `floci-course` container in hybrid mode, with `/app/data` bind-mounted to `~/floci-data`. The Lab 10 verifier reported `PASS=51 FAIL=0`.

### 5.1 Create the lab directory structure (Section 7)

```bash
mkdir -p labs/lab-13-cloudwatch-xray/transcript-notifier-v2 project/checkpoint-01
ls -d labs/*
```

![Lab and project directory setup](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-50-09.png>)
---

## 6. Architecture

```text
                         THE SYSTEM YOU ALREADY HAVE
   +-------------+   +------------------+   +-----------------+   +----------------+
   | usms-web-01 |   | usms-enrolment   |   | usms-student-   |   | usms-transcript|
   | usms-db-01  |   | -svc  (ECS)      |   | data (S3)       |   | -notifier:live |
   +------+------+   +---------+--------+   +--------+--------+   +--------+-------+
          | (CW agent,         | /usms/ecs/          | ObjectCreated       | print()
          |  conceptual)       |  enrolment          |                     |  stdout
          v                    v                     v                     v
   ==========================================================================
   ||  LOG LAYER (CloudWatch Logs)                                           ||
   ||  /usms/central/application            retention 30d  <- NEW           ||
   ||  /usms/ecs/enrolment                  retention 30d  <- Lab 04 fixed  ||
   ||  /aws/lambda/usms-transcript-notifier retention 14d  <- Lab 10 fixed  ||
   ==========================================================================
          | metric filter usms-central-errors (ERROR)   | usms-notify-count (USMS_NOTIFY)
          v                                             v
   ==========================================================================
   ||  METRIC LAYER  namespace USMS/Application                             ||
   ||   CentralErrorCount, NotifyCount (filters)                             ||
   ||   TranscriptsProcessed {Faculty,Stage}, TranscriptLagSeconds {Stage},  ||
   ||   EdgeDenyCount {Stage}  (put-metric-data)                             ||
   ==========================================================================
          |                          |                         |
   usms-transcript-lag-high   usms-notify-silence        usms-overview dashboard
          +-----------+--------------+
                      v
        usms-transcript-pipeline-down  (COMPOSITE: ALARM(a) OR ALARM(b))
                      v
        outputs/lab-13-alarm-actions-draft.json (future SNS lab)

   TRACE LAYER
   trace 1-<epoch>-<rand>
     +-- segment usms-transcript-notifier  120 ms  (annotations: faculty, stage)
     |     +-- subsegment s3-head-object    18 ms  namespace aws
     |     +-- subsegment render-pdf        74 ms  namespace remote
     +-- segment usms-student-data          18 ms  origin AWS::S3::Bucket
```

**Resources the procedure creates:** `/usms/central/application`, retention on every USMS log group, metric filters `usms-notify-count` and `usms-central-errors`, namespace `USMS/Application` (5 metrics), policy `USMSObservabilityWrite`, notifier v2 (instrumented) and v3 (traced) with alias `live` repointed, sampling rule `usms-transcripts-sampling`, alarms `usms-transcript-lag-high` and `usms-notify-silence`, composite `usms-transcript-pipeline-down`, dashboard `usms-overview`, and `scripts/utilities/usms-emit-telemetry.sh`.

---

## 7. Procedure

The checkpoint diagrams and expected outputs below describe the target state. Screenshots through Step 4 are available in the shared screenshot folder. Later screenshots are pending.

> Unless a step says otherwise, **run every command from the repository root**.
> Run all steps **in the same terminal**. Later steps reuse shell variables such as `$CENTRAL_LOG_GROUP`, `$NOTIFIER`, `$START`/`$END`, `$XSTART`/`$XEND`, `$NOTIFIER_V2` and `$NOTIFIER_V3`.

---

### Step 1 - Start the environment and prove a new terminal can find it

**Purpose:** Confirm Floci is running with persistent storage and the shell knows where the course is.

```bash
./scripts/setup/floci-up.sh
./scripts/utilities/floci-storage-check.sh
```

**Explanation:** `floci-up.sh` is idempotent. It starts or adopts the Compose project. `floci-storage-check.sh` is read-only. Its first block checks whether a new terminal can find the course, and its second checks whether the work will persist.

**Expected result:** Floci starts at `http://localhost:4566` and the storage diagnostic confirms the hybrid configuration.

![Floci startup and hybrid storage diagnostic](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-52-33.png>)

**Observation:** Compose adopted the running container and confirmed the endpoint and bind mount. The storage diagnostic ends after the host-state listing in the screenshot. A repeat run exited with status 141 at the listing pipeline, so there is no storage pass total to record.

---

### Step 2 - Source every lab environment file that exists, and confirm identity

```bash
source configs/course.env

for f in configs/lab-01.env configs/lab-02.env configs/lab-03.env \
         configs/lab-04.env configs/lab-05.env configs/lab-06.env \
         configs/lab-07.env configs/lab-08.env configs/lab-09.env \
         configs/lab-10.env configs/lab-11.env configs/lab-12.env; do
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    source "$f"
    printf '  sourced  %s\n' "$f"
  else
    printf '  absent   %s\n' "$f"
  fi
done

./scripts/utilities/whoami.sh
```
![Sourced lab configurations and confirmed Floci identity](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-53-04.png>)

**Verify:**

```bash
printf 'bucket       : %s\n' "${USMS_BUCKET_NAME:-<UNSET>}"
printf 'notifier     : %s\n' "${USMS_LAMBDA_NOTIFIER_FN:-<UNSET>}"
printf 'notifier log : %s\n' "${USMS_LOG_GROUP_NOTIFIER:-<UNSET>}"
printf 'lambda role  : %s\n' "${USMS_ROLE_LAMBDA:-<UNSET>}"
printf 'account id   : %s\n' "${USMS_ACCOUNT_ID:-<UNSET>}"
```
![Environment variables before the log group fix](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-53-23.png>)

If `USMS_LOG_GROUP_NOTIFIER` is unset, fix it now:

```bash
export USMS_LOG_GROUP_NOTIFIER=/aws/lambda/usms-transcript-notifier
echo 'export USMS_LOG_GROUP_NOTIFIER=/aws/lambda/usms-transcript-notifier' >> configs/lab-10.env
```

**Expected:** 12 `sourced` lines (no S3 configuration lab exists). The identity is account `000000000000` at endpoint `http://localhost:4566`, and five populated values for the bucket, function, log group, execution role and account.

![Notifier log group added to Lab 10 configuration](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-55-26.png>)

**Observation:** All 12 configuration files sourced successfully. The `floci` profile resolved to account `000000000000` at `http://localhost:4566` in `us-east-1`. The notifier log group was initially unset and was added to `configs/lab-10.env`. Re-sourcing now populates all five values. The role variable contains the full ARN `arn:aws:iam::000000000000:role/usms-lambda-exec-role`.

---

### Step 3 - Create this lab's directories and confirm the repository shape

```bash
mkdir -p labs/lab-13-cloudwatch-xray/transcript-notifier-v2 \
         project/checkpoint-01

ls -d labs/lab-13-cloudwatch-xray/*/ project/*/
```
![Lab 13 and checkpoint directory listing](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-56-28.png>)

**Verify:**

```bash
test -d labs/lab-13-cloudwatch-xray/transcript-notifier-v2 && echo "source tree ready"
```

**Expected:** `labs/lab-13-cloudwatch-xray/transcript-notifier-v2/`, `project/checkpoint-01/`, and `source tree ready`.

![Source tree readiness check](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-56-48.png>)
---

### Step 4 - Find out what this Floci build actually supports

```bash
probe() {   # $1 = label, $2 = command to try
  if eval "$2" >/dev/null 2>&1; then
    printf '  SUPPORTED    %s\n' "$1"
  else
    printf '  UNSUPPORTED  %s\n' "$1"
  fi
}

{
  printf 'Floci support probe for Lab 13 - %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  probe "logs       (describe-log-groups)"    "aws logs describe-log-groups --limit 1"
  probe "logs       (describe-metric-filters)"  "aws logs describe-metric-filters --limit 1"
  probe "logs       (describe-queries)"   "aws logs describe-queries --max-results 1"
  probe "cloudwatch (list-metrics)"           "aws cloudwatch list-metrics --namespace AWS/Lambda"
  probe "cloudwatch (describe-alarms)"        "aws cloudwatch describe-alarms --max-records 1"
  probe "cloudwatch (list-dashboards)"        "aws cloudwatch list-dashboards"
  probe "xray       (get-sampling-rules)"     "aws xray get-sampling-rules"
  probe "xray       (get-service-graph)"      "aws xray get-service-graph --start-time $(date -u -d '-5 minutes' +%s 2>/dev/null || date -u -v-5M +%s) --end-time $(date -u +%s)"
  probe "lambda     (get-function-config)"    "aws lambda get-function-configuration --function-name ${USMS_LAMBDA_NOTIFIER_FN:-usms-transcript-notifier}"
} | tee outputs/lab-13-support-probe.txt
```

**Explanation:** Each probe runs a harmless read-only call and reports only whether it returned exit code 0. The service-graph probe uses GNU `date -d` and falls back to BSD `date -v` on macOS. From Step 7 onwards, `python3` replaces `date` for time arithmetic.

**Decision table:**

| Probe | Consequence |
|---|---|
| Insights UNSUPPORTED | Step 23 uses **Path B** (`filter-log-events` + Python) |
| X-Ray UNSUPPORTED | Steps 15–18 validate segment documents structurally instead of sending them |

The Logs and CloudWatch read calls cover the listed endpoints. Filter creation and metric generation on ingestion are separate checks in Steps 9–10.

![Floci support probe results](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 14-57-26.png>)

**Recorded support probe for Floci 2.3.0:**

| Probe | Result |
|---|---|
| logs describe-log-groups | `SUPPORTED` |
| logs describe-metric-filters | `SUPPORTED` |
| logs describe-queries (Insights probe) | `UNSUPPORTED` |
| cloudwatch list-metrics | `SUPPORTED` |
| cloudwatch describe-alarms | `SUPPORTED` |
| cloudwatch list-dashboards | `SUPPORTED` |
| xray get-sampling-rules | `UNSUPPORTED` |
| xray get-service-graph | `UNSUPPORTED` |
| lambda get-function-config | `SUPPORTED` |

---

### Step 5 - Inventory the monitoring you already have and did not know about

```bash
{
  printf 'USMS telemetry inventory - %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '== log groups ==\n'
  aws logs describe-log-groups \
    --query 'sort_by(logGroups, &logGroupName)[].[logGroupName,retentionInDays,storedBytes]' \
    --output text

  printf '\n== alarms ==\n'
  aws cloudwatch describe-alarms \
    --query 'MetricAlarms[].[AlarmName,Namespace,MetricName,StateValue]' \
    --output text

  printf '\n== metric namespaces already present ==\n'
  aws cloudwatch list-metrics \
    --query 'sort_by(Metrics, &Namespace)[].Namespace' --output text \
    | tr '\t' '\n' | sort -u

  printf '\n== dashboards ==\n'
  aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text
} | tee outputs/lab-13-telemetry-inventory.txt
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-02-53.png>)

**Observed baseline:** A read-only inventory returned nine log groups. Eight had indefinite retention and `/usms/ecs/enrolment` already had seven-day retention. There were five metric alarms. The Lab 06 alarm `usms-enrolment-queue-high` was `OK` and four ECS target-tracking alarms were `INSUFFICIENT_DATA`. The visible metric namespaces were `USMS/Enrolment` and `USMS/Probe`. The dashboard list was empty.

**Checkpoint 1:** Save the inventory under `outputs/lab-13-telemetry-inventory.txt` when running the procedure for the project checkpoint.

---

### Step 6 - Create the central log group and set retention on everything

**Design decision:**

| Log group | Holds | Retention | Why |
|---|---|---|---|
| `/usms/central/application` | application events from any compute tier | 30 days | long enough for "last month", still cheap |
| `/usms/ecs/enrolment` | enrolment container output | 30 days | same class of data |
| `/aws/lambda/usms-transcript-notifier` | one function's runtime output | 14 days | debugging data |

**Part 1 - create the central group:**

```bash
CENTRAL_LOG_GROUP=/usms/central/application

aws logs describe-log-groups --log-group-name-prefix "$CENTRAL_LOG_GROUP" \
  --query 'length(logGroups)' --output text | grep -q '^0$' \
  && aws logs create-log-group --log-group-name "$CENTRAL_LOG_GROUP" \
  || echo "log group already exists - skipping create"

aws logs put-retention-policy \
  --log-group-name "$CENTRAL_LOG_GROUP" \
  --retention-in-days 30
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-03-35.png>)

**Part 2 - fix every USMS log group:**

```bash
NOTIFIER_LOG_GROUP="${USMS_LOG_GROUP_NOTIFIER:-/aws/lambda/usms-transcript-notifier}"

set_retention() {   # $1 = log group name, $2 = days
  if aws logs describe-log-groups --log-group-name-prefix "$1" \
       --query "logGroups[?logGroupName=='$1'] | length(@)" --output text | grep -q '^1$'; then
    aws logs put-retention-policy --log-group-name "$1" --retention-in-days "$2"
    printf '  set %4s days on %s\n' "$2" "$1"
  else
    printf '  absent, skipped   %s\n' "$1"
  fi
}

set_retention "$CENTRAL_LOG_GROUP"                 30
set_retention /usms/ecs/enrolment                  30
set_retention "$NOTIFIER_LOG_GROUP"                14
set_retention /aws/lambda/usms-edge-viewer-request 14
set_retention /aws/lambda/usms-edge-origin-response 14
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-04-15.png>)

**Verify:**

```bash
aws logs describe-log-groups \
  --query 'sort_by(logGroups, &logGroupName)[].{Group:logGroupName,Days:retentionInDays}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-05-02.png>)

**Optional - tag the log group (build dependent):**

```bash
LG_ARN=$(aws logs describe-log-groups --log-group-name-prefix "$CENTRAL_LOG_GROUP" \
  --query "logGroups[?logGroupName=='$CENTRAL_LOG_GROUP'].arn | [0]" --output text)

aws logs tag-resource --resource-arn "$LG_ARN" --tags Project=USMS,Lab=08 2>/dev/null \
  || aws logs tag-log-group --log-group-name "$CENTRAL_LOG_GROUP" --tags Project=USMS,Lab=08 2>/dev/null \
  || echo "neither tagging call is available on this build - record it in the support probe"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-05-25.png>)

If both tagging calls fail, record it:

```bash
echo "tagging: neither tag-resource nor tag-log-group available on this build" >> outputs/lab-13-support-probe.txt
```

**Expected:** No `/usms/*` or `/aws/lambda/usms-*` group shows `None` in the Days column.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-05-46.png>)


**Checkpoint 2**
```text
LOG LAYER
 ├── /usms/central/application ................. NEW, retention 30d
 ├── /usms/ecs/enrolment ....................... Lab 04, retention 30d  (was never)
 ├── /aws/lambda/usms-transcript-notifier ...... Lab 10, retention 14d  (was never)
 └── /aws/lambda/usms-edge-* ................... Lab 10, retention 14d  (if present)
```

---

### Step 7 - Write log events, and get the timestamp units right

**Concept:** Structured lines use a marker such as `USMS_EVENT {json}`. Once a metric filter depends on the marker, the marker becomes an **interface**. Changing it silently drops the metric to zero.

```bash
STREAM="lab-13-$(date -u +%Y%m%d)"

aws logs create-log-stream \
  --log-group-name "$CENTRAL_LOG_GROUP" \
  --log-stream-name "$STREAM" 2>/dev/null \
  || echo "stream already exists - continuing"

NOW_MS=$(python3 -c 'import time; print(int(time.time()*1000))')

python3 - "$NOW_MS" << 'PY' > outputs/lab-13-log-events.json
import json, sys
now = int(sys.argv[1])
msgs = [
  (now-4000, 'USMS_EVENT {"event":"transcript.requested","student":"stu-00417","faculty":"science"}'),
  (now-2000, 'USMS_EVENT {"event":"transcript.processed","student":"stu-00417","faculty":"science","seconds":0.42}'),
  (now-1000, 'USMS_EVENT {"event":"transcript.processed","student":"stu-00982","faculty":"engineering","seconds":1.91}'),
  (now,      'ERROR USMS_EVENT {"event":"transcript.failed","student":"stu-01044","faculty":"science","reason":"render timeout"}'),
]
print(json.dumps([{"timestamp": t, "message": m} for t, m in msgs]))
PY

aws logs put-log-events --log-group-name "$CENTRAL_LOG_GROUP" \
  --log-stream-name "$STREAM" \
  --log-events file://outputs/lab-13-log-events.json \
  --query 'rejectedLogEventsInfo' --output json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-11-55.png>)

**Explanation:**
- The `timestamp` is in **milliseconds** since the epoch. Seconds would land every event in 1970, where it would be silently rejected.
- Python generates portable millisecond timestamps and JSON-encodes the event array. Passing the file to `--log-events` preserves the commas and quotes inside each message.
- Events must be in chronological order within one call, which is why the offsets count down from `NOW_MS`.
- `rejectedLogEventsInfo` is the field that tells you whether the call worked, because the call returns HTTP 200 even if every event is rejected.
- The 4th message starts with `ERROR` on purpose. Step 9's second filter matches it.

> **If your build demands a sequence token (`InvalidSequenceTokenException`):**
>
> ```bash
> TOKEN=$(aws logs describe-log-streams --log-group-name "$CENTRAL_LOG_GROUP" \
>   --log-stream-name-prefix "$STREAM" \
>   --query 'logStreams[0].uploadSequenceToken' --output text)
>
> aws logs put-log-events --log-group-name "$CENTRAL_LOG_GROUP" \
>   --log-stream-name "$STREAM" --sequence-token "$TOKEN" \
>   --log-events file://outputs/lab-13-log-events.json \
>   --query 'rejectedLogEventsInfo' --output json
> echo "put-log-events: build required --sequence-token" >> outputs/lab-13-support-probe.txt
> ```

**Expected:** `null` (nothing rejected).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-12-37.png>)

**Verify:**

```bash
aws logs filter-log-events \
  --log-group-name "$CENTRAL_LOG_GROUP" \
  --query 'events[].[timestamp,message]' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-13-08.png>)

Expect four rows in ascending timestamp order.


#### Step 7 Exercise - Add a health check event that matches neither filter

```bash
aws logs put-log-events \
  --log-group-name "$CENTRAL_LOG_GROUP" \
  --log-stream-name "$STREAM" \
  --log-events "timestamp=$(python3 -c 'import time; print(int(time.time()*1000))'),message=HEALTHCHECK status ok" \
  --query 'rejectedLogEventsInfo' --output json

aws logs filter-log-events --log-group-name "$CENTRAL_LOG_GROUP" \
  --query 'length(events)' --output text
```

**Expected:** `null`, then `5`. This line contains neither `USMS_EVENT` nor `ERROR`, so no filter in Step 9 counts it.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-15-29.png>)


**Checkpoint 3**
```text
/usms/central/application
 └── stream lab-13-YYYYMMDD
      ├── USMS_EVENT transcript.requested    stu-00417  science
      ├── USMS_EVENT transcript.processed    stu-00417  science      0.42s
      ├── USMS_EVENT transcript.processed    stu-00982  engineering  1.91s
      ├── ERROR USMS_EVENT transcript.failed stu-01044  science
      └── HEALTHCHECK status ok               (non-matching)
```

---

### Step 8 - Test a filter pattern before you deploy it

**Concept - filter pattern dialects (not regular expressions):**

| Text dialect | Matches |
|---|---|
| `ERROR` | events containing the term ERROR |
| `"ERROR"` | the same, quoted (needed for spaces or punctuation) |
| `ERROR timeout` | both terms |
| `?ERROR ?WARN` | either term |
| `ERROR -Test` | ERROR and not Test |

| JSON dialect (whole message must be JSON) | Matches |
|---|---|
| `{ $.faculty = "science" }` | equality |
| `{ $.seconds > 1 }` | numeric comparison |
| `{ $.event = "transcript.*" }` | trailing wildcard |
| `{ ($.faculty = "science") && ($.seconds > 1) }` | both |

`USMS_EVENT {...}` is not pure JSON, so only the **text dialect** applies to our lines.

```bash
aws logs test-metric-filter \
  --filter-pattern 'USMS_NOTIFY' \
  --log-event-messages \
    'USMS_NOTIFY {"bucket": "usms-student-data", "key": "transcripts/evidence/a.json", "readable": true}' \
    'usms-transcript-notifier: 1 record(s), channel=stdout, bucket_hint=usms-student-data' \
    'REPORT RequestId: 4c8e	Duration: 18.42 ms	Billed Duration: 19 ms' \
    'skipping non-transcript object: notes/ignore-me.json' \
  --query 'matches[].[eventNumber,eventMessage]' --output table \
  | tee outputs/lab-13-filter-test.json
```

**Expected:** Exactly **one** match, event number **1**. Patterns are case-sensitive, so `usms_notify` would match nothing.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-16-38.png>)


#### Step 8 Exercise - Test the ERROR filter for false positives

```bash
aws logs test-metric-filter \
  --filter-pattern 'ERROR' \
  --log-event-messages \
    'USMS_EVENT {"event":"transcript.requested","student":"stu-00417","faculty":"science"}' \
    'USMS_EVENT {"event":"transcript.processed","student":"stu-00417","faculty":"science","seconds":0.42}' \
    'USMS_EVENT {"event":"transcript.processed","student":"stu-00982","faculty":"engineering","seconds":1.91}' \
    'ERROR USMS_EVENT {"event":"transcript.failed","student":"stu-01044","faculty":"science","reason":"render timeout"}' \
  --query 'matches[].eventNumber' --output text

# The false-positive case
aws logs test-metric-filter \
  --filter-pattern 'ERROR' \
  --log-event-messages 'USMS_EVENT {"event":"transcript.processed","reason":"no ERROR here"}' \
  --query 'length(matches)' --output text
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-17-31.png>)

**Expected:** The first call returns `4` (only the ERROR line). Record in `labs/lab-13-cloudwatch-xray/exercises.md` whether the false-positive line matched:

```bash
cat >> labs/lab-13-cloudwatch-xray/exercises.md << 'EOF'
## Step 8 - Your turn: ERROR pattern
- Pattern `ERROR` matched exactly one of the four Step 7 messages (the transcript.failed line).
- False-positive test: the line `USMS_EVENT {"event":"transcript.processed","reason":"no ERROR here"}`
  matched once on Floci. The text filter counts ERROR anywhere it appears as a term.
  For an alarm I would emit pure JSON with a severity field and use
  `{ $.level = "ERROR" }` to avoid counting messages that only mention the word.
EOF
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-18-01.png>)

---

### Step 9 - Deploy two metric filters

**Concept:** A metric filter is evaluated **on ingestion**, is **not retroactive**, produces billed metrics, and uses `defaultValue` to decide what "nothing" means. With `defaultValue=0`, a period with no matches publishes a zero instead of no data point.

```bash
aws logs put-metric-filter \
  --log-group-name "$NOTIFIER_LOG_GROUP" \
  --filter-name usms-notify-count \
  --filter-pattern 'USMS_NOTIFY' \
  --metric-transformations \
      metricName=NotifyCount,metricNamespace=USMS/Application,metricValue=1,defaultValue=0

aws logs put-metric-filter \
  --log-group-name "$CENTRAL_LOG_GROUP" \
  --filter-name usms-central-errors \
  --filter-pattern 'ERROR' \
  --metric-transformations \
      metricName=CentralErrorCount,metricNamespace=USMS/Application,metricValue=1,defaultValue=0
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-20-03.png>)

| Key | Meaning |
|---|---|
| `metricName` | the metric's name |
| `metricNamespace` | keeps our metrics apart from AWS's |
| `metricValue` | `1` counts events; `$.field` / `$1` extracts a value |
| `defaultValue` | what to publish in a period with no matches |

**Verify:**

```bash
aws logs describe-metric-filters \
  --query 'metricFilters[?starts_with(filterName, `usms-`)].[filterName,logGroupName,filterPattern,metricTransformations[0].metricName]' \
  --output table
```

**Expected:** Two rows, each filter on the **correct** log group.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-20-25.png>)


**Checkpoint 4**
```text
METRIC FILTERS
 ├── usms-notify-count    on /aws/lambda/usms-transcript-notifier
 │     USMS_NOTIFY  →  USMS/Application NotifyCount        value 1, default 0
 └── usms-central-errors  on /usms/central/application
       ERROR        →  USMS/Application CentralErrorCount  value 1, default 0
```

---

### Step 10 - Prove the filter end to end

**Part 1 - perturb (upload and invoke):**

```bash
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"
NOTIFIER="${USMS_LAMBDA_NOTIFIER_FN:-usms-transcript-notifier}"

python3 -c "
import json, datetime
json.dump({'note': 'lab-13 telemetry probe',
           'created': datetime.datetime.now(datetime.timezone.utc).isoformat()},
          open('outputs/lab-13-probe-object.json','w'), indent=2)
"

aws s3api put-object \
  --bucket "$BUCKET" \
  --key transcripts/evidence/lab-13-probe-object.json \
  --body outputs/lab-13-probe-object.json \
  --content-type application/json \
  --query 'ETag' --output text

sleep 5

aws lambda invoke \
  --function-name "$NOTIFIER" \
  --qualifier live \
  --payload fileb://templates/lab-10-s3-event.json \
  --query 'FunctionError' --output text \
  outputs/lab-13-notifier-probe.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-22-02.png>)

**Explanation:** The upload tests the real S3-notification path. The direct invoke (using Lab 10's synthetic event) runs **every time**, so the two results separate "delivery works" from "function + filter work".

**Part 2 - read back:**

```bash
WINDOW=$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = now - datetime.timedelta(minutes=15)
print(start.strftime('%Y-%m-%dT%H:%M:%SZ'), now.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
START=${WINDOW% *}
END=${WINDOW#* }

printf 'window: %s .. %s\n' "$START" "$END"

aws cloudwatch get-metric-statistics \
  --namespace USMS/Application \
  --metric-name NotifyCount \
  --start-time "$START" \
  --end-time "$END" \
  --period 60 \
  --statistics Sum SampleCount \
  --query 'sort_by(Datapoints, &Timestamp)[].[Timestamp,Sum,SampleCount]' \
  --output table \
  | tee outputs/lab-13-metric-readback.json
```

**Expected:** At least one data point with `Sum ≥ 1`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-22-30.png>)

> **Floci limitation - filters stored but not evaluated.** If `Datapoints` is empty, publish the metric by hand and record that it is synthetic:
>
> ```bash
> aws cloudwatch put-metric-data \
>   --namespace USMS/Application \
>   --metric-data MetricName=NotifyCount,Unit=Count,Value=2
>
> echo "Step 10: metric filter not evaluated on this build; NotifyCount published manually (SYNTHETIC)" \
>   >> outputs/lab-13-support-probe.txt
> ```
> Then re-run the `get-metric-statistics` command above.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-22-50.png>)


**Result:** Pending the end-to-end ingestion test. Record the source of the data point before drawing a conclusion about filter evaluation.

#### Step 10 Exercise - Test how `defaultValue` handles nonmatching events

```bash
OLDWIN=$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0, second=0)
end = now - datetime.timedelta(hours=2)
start = end - datetime.timedelta(minutes=15)
print(start.strftime('%Y-%m-%dT%H:%M:%SZ'), end.strftime('%Y-%m-%dT%H:%M:%SZ'))
")

echo "--- window BEFORE the upload ---"
aws cloudwatch get-metric-statistics --namespace USMS/Application --metric-name NotifyCount \
  --start-time "${OLDWIN% *}" --end-time "${OLDWIN#* }" --period 300 --statistics Sum \
  --query 'Datapoints' --output json

echo "--- window INCLUDING the upload ---"
aws cloudwatch get-metric-statistics --namespace USMS/Application --metric-name NotifyCount \
  --start-time "$START" --end-time "$END" --period 300 --statistics Sum \
  --query 'Datapoints' --output json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-25-04.png>)

```bash
cat >> labs/lab-13-cloudwatch-xray/exercises.md << 'EOF'
## Step 10 - Your turn: defaultValue
- Comparison pending until both windows have been queried after filter deployment.
- An empty Datapoints array means the queried period has no data point. A Sum of 0 is
  an explicit measurement. With defaultValue=0, compare a period containing only
  nonmatching ingested events with a period containing no ingested events at all.
EOF
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-25-21.png>)


**Checkpoint 5**
```text
PROVEN: log line → metric
 ├── object uploaded to transcripts/evidence/
 ├── notifier invoked through alias live
 ├── USMS_NOTIFY line written to /aws/lambda/usms-transcript-notifier
 └── USMS/Application NotifyCount has a data point  (or a recorded, honest substitute)
```

---

### Step 11 - Publish custom metrics, and meet dimensions

**Concept - a dimension is part of the name:**

```text
USMS/Application  TranscriptsProcessed  {Faculty=science}                  metric A
USMS/Application  TranscriptsProcessed  {Faculty=engineering}              metric B
USMS/Application  TranscriptsProcessed  {Faculty=science, Stage=render}    metric C  ← NOT a subset of A
USMS/Application  TranscriptsProcessed  {}                                 metric D  ← NOT the total
```

There is no automatic roll-up, so the total must be published separately. Cardinality is cost: `Faculty` (~8 values) is a good dimension, while `StudentId` (30,000 values) would be catastrophic.

**Part 1 - shorthand form:**

```bash
aws cloudwatch put-metric-data \
  --namespace USMS/Application \
  --metric-data \
    'MetricName=TranscriptsProcessed,Unit=Count,Value=1,Dimensions=[{Name=Faculty,Value=science},{Name=Stage,Value=notify}]'

aws cloudwatch put-metric-data \
  --namespace USMS/Application \
  --metric-data 'MetricName=TranscriptsProcessed,Unit=Count,Value=1'
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-27-09.png>)

**Part 2 - JSON form, with timestamps (unquoted heredoc on purpose, so `${NOW_ISO}` expands):**

```bash
NOW_ISO=$(python3 -c "
import datetime
print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z'))
")

cat > templates/lab-13-metric-data.json << EOF
[
  {
    "MetricName": "TranscriptsProcessed",
    "Timestamp": "${NOW_ISO}",
    "Unit": "Count",
    "Value": 3,
    "Dimensions": [
      { "Name": "Faculty", "Value": "engineering" },
      { "Name": "Stage",   "Value": "notify" }
    ]
  },
  {
    "MetricName": "TranscriptLagSeconds",
    "Timestamp": "${NOW_ISO}",
    "Unit": "Seconds",
    "Value": 0.42,
    "Dimensions": [
      { "Name": "Stage", "Value": "notify" }
    ]
  },
  {
    "MetricName": "TranscriptLagSeconds",
    "Timestamp": "${NOW_ISO}",
    "Unit": "Seconds",
    "Value": 1.91,
    "Dimensions": [
      { "Name": "Stage", "Value": "notify" }
    ]
  },
  {
    "MetricName": "EdgeDenyCount",
    "Timestamp": "${NOW_ISO}",
    "Unit": "Count",
    "Value": 1,
    "Dimensions": [
      { "Name": "Stage", "Value": "viewer-request" }
    ]
  }
]
EOF

python3 -m json.tool templates/lab-13-metric-data.json > /dev/null && echo "valid JSON"

aws cloudwatch put-metric-data \
  --namespace USMS/Application \
  --metric-data file://templates/lab-13-metric-data.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-28-12.png>)

**Explanation:** Two `TranscriptLagSeconds` points with the same identity and timestamp are aggregated (SampleCount 2, Sum 2.33, Average 1.165, Maximum 1.91). Every observation should be published, not a pre-averaged value. `Unit` must be consistent.

**Verify:**

```bash
aws cloudwatch list-metrics --namespace USMS/Application \
  --query 'sort_by(Metrics, &MetricName)[].[MetricName,join(`,`, Dimensions[].Name) || `(none)`]' \
  --output table

aws cloudwatch get-metric-statistics \
  --namespace USMS/Application \
  --metric-name TranscriptLagSeconds \
  --dimensions Name=Stage,Value=notify \
  --start-time "$START" --end-time "$END" \
  --period 300 \
  --statistics SampleCount Sum Average Maximum \
  --query 'Datapoints[0]' --output json
```

> If the statistics call returns nothing, `$END` may be older than `$NOW_ISO`. Recompute the window by re-running the `WINDOW=...` block from Step 10 Part 2, then retry.

**Expected:** `TranscriptsProcessed` listed twice (with and without dimensions), and `SampleCount: 2.0`, `Sum: 2.33`, `Average: 1.165`, `Maximum: 1.91`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-28-33.png>)


**Checkpoint 6**
```text
USMS/Application
 ├── NotifyCount                                        (metric filter, Step 9)
 ├── CentralErrorCount                                  (metric filter, Step 9)
 ├── TranscriptsProcessed  {Faculty, Stage}             (custom)
 ├── TranscriptsProcessed  {}                 ← the total, published separately
 ├── TranscriptLagSeconds  {Stage}            ← 2 observations in one period
 └── EdgeDenyCount         {Stage}
```

---

### Step 12 - Give the roles permission to emit telemetry

**Concept:** Add a new policy per concern rather than editing `USMSLambdaBasic`. Managed policies are shared, and each can hold at most 5 versions.

**Part 1 - the policy document (quoted heredoc):**

```bash
cat > policies/usms-observability-write-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteApplicationLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": [
        "arn:aws:logs:us-east-1:000000000000:log-group:/usms/*:*",
        "arn:aws:logs:us-east-1:000000000000:log-group:/aws/lambda/usms-*:*"
      ]
    },
    {
      "Sid": "PublishCustomMetricsInOurNamespaceOnly",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "cloudwatch:namespace": "USMS/Application"
        }
      }
    },
    {
      "Sid": "SendTraces",
      "Effect": "Allow",
      "Action": [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords",
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets"
      ],
      "Resource": "*"
    }
  ]
}
EOF

python3 -m json.tool policies/usms-observability-write-policy.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-30-11.png>)

**Key points:**
- The log ARNs end in `:*` so they cover the streams. Without it, `PutLogEvents` fails.
- `cloudwatch:PutMetricData` has no resource-level permissions, so it is scoped with the **`cloudwatch:namespace` condition**.
- X-Ray sending legitimately needs `*`.

**Part 2 - create and attach:**

```bash
OBS_POLICY_ARN=$(aws iam create-policy \
  --policy-name USMSObservabilityWrite \
  --policy-document file://policies/usms-observability-write-policy.json \
  --description "Write logs to USMS groups, publish USMS/Application metrics, send X-Ray traces" \
  --query 'Policy.Arn' --output text 2>/dev/null \
  || aws iam list-policies --scope Local \
       --query "Policies[?PolicyName=='USMSObservabilityWrite'].Arn | [0]" --output text)

echo "$OBS_POLICY_ARN"

ROLE_LAMBDA="${USMS_ROLE_LAMBDA:-usms-lambda-exec-role}"
ROLE_LAMBDA="${ROLE_LAMBDA##*/}"
ROLE_EC2="${USMS_ROLE_EC2:-usms-ec2-app-role}"
ROLE_EC2="${ROLE_EC2##*/}"
for role in "$ROLE_LAMBDA" "$ROLE_EC2"; do
  aws iam attach-role-policy --role-name "$role" --policy-arn "$OBS_POLICY_ARN" \
    && printf '  attached to %s\n' "$role"
done
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-30-45.png>)

**Verify:**

```bash
aws iam list-attached-role-policies --role-name "$ROLE_LAMBDA" \
  --query 'AttachedPolicies[].PolicyName' --output text

aws iam get-policy-version \
  --policy-arn "$OBS_POLICY_ARN" \
  --version-id "$(aws iam get-policy --policy-arn "$OBS_POLICY_ARN" \
                    --query 'Policy.DefaultVersionId' --output text)" \
  --query 'PolicyVersion.Document.Statement[].[Sid,Effect]' --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-31-07.png>)

**Expected:** `USMSLambdaBasic` **and** `USMSObservabilityWrite` on the role, and three statements in the document.

> **Floci limitation:** IAM is not enforced here. On real AWS, a traced Lambda without `xray:PutTraceSegments` silently produces no traces. The policy is judged by reading it.


**Checkpoint 7**
```text
USMSObservabilityWrite  (customer managed, v1)
 ├── logs:CreateLogStream / PutLogEvents / DescribeLogStreams  on /usms/* and /aws/lambda/usms-*
 ├── cloudwatch:PutMetricData  scoped by condition to namespace USMS/Application
 └── xray:PutTraceSegments / PutTelemetryRecords / GetSamplingRules / GetSamplingTargets
attached to
 ├── usms-lambda-exec-role   (alongside USMSLambdaBasic)
 └── usms-ec2-app-role       (alongside USMSStudentDataReadWrite)
```

---

### Step 13 - Instrument the notifier, and use an alias for what aliases are for

**Concept:** Publish version 2, then repoint `live`. The bucket notification and the resource policy both point at `...:live`, so neither needs to change. One `update-alias` call is the deployment, and the reverse call is the rollback.

```text
usms-student-data notification → arn:...:function:usms-transcript-notifier:live   (unchanged)
      before this step  live ──→ 1
      after  this step  live ──→ 2
```

**Part 1 - the instrumented handler:**

```bash
cat > labs/lab-13-cloudwatch-xray/transcript-notifier-v2/notifier.py << 'EOF'
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
EOF

python3 -m py_compile labs/lab-13-cloudwatch-xray/transcript-notifier-v2/notifier.py \
  && echo "syntax OK (python3)"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-32-51.png>)

**Handler design points:**
- `trace_id()` reads `_X_AMZN_TRACE_ID` (`Root=...`) and puts it on every log line. This is the **join key** between logs and traces. It falls back to `aws_request_id`.
- `publish()` never fails the invocation. Telemetry must not become an outage.
- `faculty_of()` guards cardinality with `isalpha()` and a length limit, so a user-controlled path cannot create thousands of metrics.

**Part 2 - deploy, publish, repoint:**

```bash
( cd labs/lab-13-cloudwatch-xray/transcript-notifier-v2 \
  && python3 -m zipfile -c "$COURSE_ROOT/outputs/lab-13-notifier-v2.zip" notifier.py )

python3 -m zipfile -l outputs/lab-13-notifier-v2.zip

aws lambda update-function-code \
  --function-name "$NOTIFIER" \
  --zip-file fileb://outputs/lab-13-notifier-v2.zip \
  --query '{Name:FunctionName,CodeSize:CodeSize,Version:Version}' --output table

aws lambda update-function-configuration \
  --function-name "$NOTIFIER" \
  --environment "Variables={USMS_BUCKET=$BUCKET,USMS_NOTIFY_CHANNEL=stdout,USMS_METRIC_NAMESPACE=USMS/Application,USMS_FACULTY_DEFAULT=unknown}" \
  --query 'Environment.Variables' --output json

aws lambda wait function-updated-v2 --function-name "$NOTIFIER" 2>/dev/null \
  || { echo "waiter unsupported - pausing instead"; sleep 5; }

NOTIFIER_V2=$(aws lambda publish-version \
  --function-name "$NOTIFIER" \
  --description "Lab 13 - instrumented: custom metrics and trace id" \
  --query 'Version' --output text)

aws lambda update-alias \
  --function-name "$NOTIFIER" \
  --name live \
  --function-version "$NOTIFIER_V2" \
  --query '{Alias:Name,Version:FunctionVersion}' --output table
```

**Explanation:** The subshell `( cd ... )` keeps `notifier.py` at the root of the zip. `update-function-code` only changes `$LATEST`, so version 1 remains the rollback target. The waiter prevents publishing a version of the old code.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-33-22.png>)

**Verify:**

```bash
aws lambda get-function-configuration --function-name "$NOTIFIER" --qualifier live \
  --query '{Version:Version,Handler:Handler,Runtime:Runtime}' --output json

aws lambda invoke \
  --function-name "$NOTIFIER" --qualifier live \
  --payload fileb://templates/lab-10-s3-event.json \
  --log-type Tail --query 'LogResult' --output text \
  outputs/lab-13-notifier-v2-probe.json \
  | openssl base64 -d -A

python3 -m json.tool outputs/lab-13-notifier-v2-probe.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-33-47.png>)

**Expected:** `Version: "2"`, a `USMS_SUMMARY` line in the decoded log, and a payload containing `trace_id` and `seconds`.


#### Step 13 Exercise - Verify rollback and roll-forward with the Lambda alias

```bash
# Roll back to Lab 10 version 1
aws lambda update-alias --function-name "$NOTIFIER" --name live --function-version 1 \
  --query 'FunctionVersion' --output text
aws lambda invoke --function-name "$NOTIFIER" --qualifier live \
  --payload fileb://templates/lab-10-s3-event.json outputs/lab-13-rollback-v1.json >/dev/null
python3 -m json.tool outputs/lab-13-rollback-v1.json      # no trace_id field

# Roll forward to version 2
aws lambda update-alias --function-name "$NOTIFIER" --name live --function-version "$NOTIFIER_V2" \
  --query 'FunctionVersion' --output text
aws lambda invoke --function-name "$NOTIFIER" --qualifier live \
  --payload fileb://templates/lab-10-s3-event.json outputs/lab-13-rollforward-v2.json >/dev/null
python3 -m json.tool outputs/lab-13-rollforward-v2.json   # trace_id is back

aws lambda list-versions-by-function --function-name "$NOTIFIER" \
  --query 'Versions[].Version' --output text                # $LATEST 1 2
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-36-23.png>)

```bash
cat >> labs/lab-13-cloudwatch-xray/exercises.md << 'EOF'
## Step 13 - Your turn: rollback
- Same alias ARN returned two differently shaped payloads (v1: no trace_id; v2: trace_id + seconds).
- A real rollback of this deployment is one update-alias call and takes effect within seconds, because
  every trigger points at :live. The Lambda@Edge rollback in Lab 10 Step 11 needs the CloudFront
  distribution updated and re-propagated to every edge location, which takes minutes, not seconds.
EOF
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-36-42.png>)


---

### Step 14 - Turn on active tracing

**Concept:**

| Mode | Behaviour |
|---|---|
| `PassThrough` | default; trace only if the caller already decided to |
| `Active` | Lambda samples and starts a trace itself |

The notifier is triggered by S3, which does not carry a sampling decision, so it must use `Active`. Enabling tracing is a **configuration** change, so it needs its own published version.

```bash
aws lambda update-function-configuration \
  --function-name "$NOTIFIER" \
  --tracing-config Mode=Active \
  --query '{Name:FunctionName,Tracing:TracingConfig.Mode}' --output table

aws lambda wait function-updated-v2 --function-name "$NOTIFIER" 2>/dev/null \
  || { echo "waiter unsupported - pausing instead"; sleep 5; }

NOTIFIER_V3=$(aws lambda publish-version \
  --function-name "$NOTIFIER" \
  --description "Lab 13 - instrumented + active tracing" \
  --query 'Version' --output text)

aws lambda update-alias \
  --function-name "$NOTIFIER" --name live \
  --function-version "$NOTIFIER_V3" \
  --query 'FunctionVersion' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-37-50.png>)

**Verify:**

```bash
aws lambda get-function-configuration --function-name "$NOTIFIER" --qualifier live \
  --query '{Version:Version,Tracing:TracingConfig.Mode}' --output json

aws iam list-attached-role-policies --role-name "$ROLE_LAMBDA" \
  --query "AttachedPolicies[?PolicyName=='USMSObservabilityWrite'] | length(@)" --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-38-09.png>)

**Expected:** `Version: "3"`, `Tracing: "Active"`, and `1`.

> **Floci limitation:** `TracingConfig` is stored, but no X-Ray daemon runs, so invocations produce no segments. Steps 15-17 build segments by hand.


**Checkpoint 8**
```text
usms-transcript-notifier
 ├── $LATEST ... instrumented code + Active tracing
 ├── 1 ......... Lab 10 code, PassThrough        (rollback target)
 ├── 2 ......... instrumented code, PassThrough
 ├── 3 ......... instrumented code, Active
 └── live ──→ 3   ← S3's notification follows this, untouched since Lab 10
```

---

### Step 15 - The X-Ray data model, and your first segment

**Concept:**

```text
TRACE            one request end to end (set of segments sharing a trace id)
 ├── SEGMENT     one service's view (named after the SERVICE)
 │   ├── SUBSEGMENT   a downstream call / timed unit of work
 │   └── SUBSEGMENT
 └── SEGMENT     next service's view of the SAME request
```

| Field | Shape | Example |
|---|---|---|
| `trace_id` | `1-` + 8 hex epoch secs + `-` + 24 hex | `1-68ca4f31-1f2c3d4e5f60718293a4b5c6` |
| `id` | 16 hex | `70de5b6f19ff9a0a` |
| `parent_id` | id of the enclosing (sub)segment | |
| `start_time`/`end_time` | epoch **seconds, float** | `1789234567.123` |

| | Indexed | Searchable | Value types |
|---|---|---|---|
| annotations | yes | yes | string, number, boolean |
| metadata | no | no | any JSON |

```bash
python3 - << 'PY' > templates/lab-13-segment-parent.json
import json, os, time

now = time.time()
trace_id = "1-%08x-%s" % (int(now), os.urandom(12).hex())
seg_id = os.urandom(8).hex()

segment = {
    "name": "usms-transcript-notifier",
    "id": seg_id,
    "trace_id": trace_id,
    "start_time": round(now - 0.120, 3),
    "end_time": round(now, 3),
    "origin": "AWS::Lambda::Function",
    "annotations": {
        "faculty": "science",
        "stage": "notify",
        "transcript_bytes": 2184,
        "readable": True
    },
    "metadata": {
        "usms": {
            "key": "transcripts/science/stu-00417.json",
            "bucket": "usms-student-data",
            "alias": "live",
            "handler": "notifier.handler"
        }
    }
}

print(json.dumps(segment, indent=2))
with open("outputs/lab-13-trace-ids.txt", "a") as fh:
    fh.write("%s %s parent\n" % (trace_id, seg_id))
PY

python3 -m json.tool templates/lab-13-segment-parent.json > /dev/null && echo "valid JSON"
tail -1 outputs/lab-13-trace-ids.txt
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-39-44.png>)

**Submit or validate the parent segment:**

```bash
SEGMENT_FILE=templates/lab-13-segment-parent.json
if python3 -m json.tool "$SEGMENT_FILE" >/dev/null; then
  if XRAY_RESULT=$(aws xray put-trace-segments \
       --trace-segment-documents "$(cat "$SEGMENT_FILE")" \
       --query 'UnprocessedTraceSegments' --output json 2>&1); then
    printf '%s\n' "$XRAY_RESULT"
    [ "$XRAY_RESULT" = '[]' ]
  elif [[ "$XRAY_RESULT" == *UnknownOperationException* && "$XRAY_RESULT" == *"POST /TraceSegments"* ]]; then
    printf 'Valid JSON: %s. Floci trace upload unavailable. Continue with Step 16 structural validation.\n' "$SEGMENT_FILE"
  else
    printf '%s\n' "$XRAY_RESULT" >&2
    false
  fi
else
  false
fi
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-45-05.png>)

**Expected:** An X-Ray-capable endpoint returns `[]` when it accepts the segment. This Floci build returns an unknown-operation error for trace uploads, so the command validates the JSON locally and prints the fallback message. Step 16 adds structural checks across all three segment documents.


---

### Step 16 - Subsegments, a downstream service, and reading a trace back

**Part 1 - the same segment with subsegments:**

```bash
TRACE_ID=$(awk 'END {print $1}' outputs/lab-13-trace-ids.txt)
PARENT_ID=$(awk 'END {print $2}' outputs/lab-13-trace-ids.txt)

printf 'trace  : %s\nparent : %s\n' "$TRACE_ID" "$PARENT_ID"

python3 - "$TRACE_ID" "$PARENT_ID" << 'PY' > templates/lab-13-segment-subsegments.json
import json, os, sys, time

trace_id, parent_id = sys.argv[1], sys.argv[2]
now = time.time()

def sub(name, offset, duration, namespace, extra=None):
    doc = {
        "id": os.urandom(8).hex(),
        "name": name,
        "start_time": round(now - offset, 3),
        "end_time": round(now - offset + duration, 3),
        "namespace": namespace,
    }
    if extra:
        doc.update(extra)
    return doc

segment = {
    "name": "usms-transcript-notifier",
    "id": parent_id,
    "trace_id": trace_id,
    "start_time": round(now - 0.120, 3),
    "end_time": round(now, 3),
    "origin": "AWS::Lambda::Function",
    "annotations": {
        "faculty": "science",
        "stage": "notify",
        "transcript_bytes": 2184,
        "readable": True,
    },
    "metadata": {
        "usms": {
            "key": "transcripts/science/stu-00417.json",
            "bucket": "usms-student-data",
            "alias": "live",
        }
    },
    "subsegments": [
        sub("s3-head-object", 0.118, 0.018, "aws", {
            "aws": {"operation": "HeadObject",
                    "bucket_name": "usms-student-data",
                    "region": "us-east-1"}}),
        sub("render-pdf", 0.098, 0.074, "remote", {
            "metadata": {"usms": {"pages": 3, "renderer": "wkhtmltopdf"}}}),
        sub("cloudwatch-put-metric-data", 0.022, 0.011, "aws", {
            "aws": {"operation": "PutMetricData"}}),
    ],
}

print(json.dumps(segment, indent=2))
PY

python3 -m json.tool templates/lab-13-segment-subsegments.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-48-07.png>)

| `namespace` | Meaning | Service graph effect |
|---|---|---|
| `aws` | call to an AWS service | own node |
| `remote` | call outside AWS | generic downstream node |
| omitted | internal work | no node |

Re-sending the same segment `id` **updates** the segment rather than duplicating it.

**Part 2 - a second service in the same trace:**

```bash
python3 - "$TRACE_ID" "$PARENT_ID" << 'PY' > templates/lab-13-segment-downstream.json
import json, os, sys, time

trace_id, parent_id = sys.argv[1], sys.argv[2]
now = time.time()

segment = {
    "name": "usms-student-data",
    "id": os.urandom(8).hex(),
    "trace_id": trace_id,
    "parent_id": parent_id,
    "type": "subsegment",
    "start_time": round(now - 0.118, 3),
    "end_time": round(now - 0.100, 3),
    "origin": "AWS::S3::Bucket",
    "http": {
        "request": {"method": "HEAD",
                    "url": "https://usms-student-data.s3.us-east-1.amazonaws.com/transcripts/science/stu-00417.json"},
        "response": {"status": 200, "content_length": 2184},
    },
    "annotations": {"faculty": "science", "stage": "origin"},
}

print(json.dumps(segment, indent=2))
PY

python3 -m json.tool templates/lab-13-segment-downstream.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-48-36.png>)

**Submit or validate both segment documents:**

```bash
SUBSEGMENTS_FILE=templates/lab-13-segment-subsegments.json
DOWNSTREAM_FILE=templates/lab-13-segment-downstream.json

if python3 -m json.tool "$SUBSEGMENTS_FILE" >/dev/null &&
   python3 -m json.tool "$DOWNSTREAM_FILE" >/dev/null; then
  if XRAY_RESULT=$(aws xray put-trace-segments \
       --trace-segment-documents "$(cat "$SUBSEGMENTS_FILE")" "$(cat "$DOWNSTREAM_FILE")" \
       --query 'UnprocessedTraceSegments' --output json 2>&1); then
    printf '%s\n' "$XRAY_RESULT"
    [ "$XRAY_RESULT" = '[]' ]
  elif [[ "$XRAY_RESULT" == *UnknownOperationException* && "$XRAY_RESULT" == *"POST /TraceSegments"* ]]; then
    printf 'Valid JSON: %s and %s. Floci trace upload unavailable. Run the read-back and validation block below.\n' \
      "$SUBSEGMENTS_FILE" "$DOWNSTREAM_FILE"
  else
    printf '%s\n' "$XRAY_RESULT" >&2
    false
  fi
else
  false
fi
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 15-51-01.png>)

**Explanation:** `parent_id` + `"type": "subsegment"` lets a separate process report work inside the caller's segment. The `http.response.status` block classifies the result as ok, error, fault or throttle.

**Expected:** Both files pass JSON validation. On the upload path, a successful submission also returns `[]`.

**Part 3 - verify the trace:**

Set the time window in either path.

```bash
XW=$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = now - datetime.timedelta(minutes=15)
print(int(start.timestamp()), int(now.timestamp()))
")
XSTART=${XW% *}
XEND=${XW#* }
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-05-14.png>)

**Read the trace or validate the local documents:**

```bash
read_xray() {
  local result
  if result=$(aws xray "$@" --output json 2>&1); then
    printf '%s\n' "$result"
  elif [[ "$result" == *UnknownOperationException* ]]; then
    printf 'null\n'
  else
    printf '%s\n' "$result" >&2
    return 1
  fi
}

if XRAY_SUMMARIES=$(read_xray get-trace-summaries \
     --start-time "$XSTART" --end-time "$XEND" \
     --query 'TraceSummaries[].{Id:Id,Duration:Duration,Http:Http.HttpStatus,Annotations:keys(Annotations)}') &&
   XRAY_TRACE=$(read_xray batch-get-traces --trace-ids "$TRACE_ID" \
     --query 'Traces[0].{Id:Id,Duration:Duration,Segments:length(Segments)}'); then
  if [[ "$XRAY_TRACE" == null || "$XRAY_SUMMARIES" == null ]]; then
    echo "X-Ray read-back unavailable. Validating the local segment documents."
    (
      set -o pipefail
      python3 - << 'PY' | tee outputs/lab-13-trace-summaries.json
import json, re, sys

checks, errors = [], []

def check(label, ok):
    checks.append(("ok  " if ok else "FAIL") + "  " + label)
    if not ok:
        errors.append(label)

docs = {name: json.load(open("templates/lab-13-segment-%s.json" % name))
        for name in ("parent", "subsegments", "downstream")}

tid = docs["parent"]["trace_id"]
check("trace id matches 1-<8hex>-<24hex>", bool(re.fullmatch(r"1-[0-9a-f]{8}-[0-9a-f]{24}", tid)))
check("all three documents share one trace id",
      all(d["trace_id"] == tid for d in docs.values()))
check("every id is 16 hex characters",
      all(re.fullmatch(r"[0-9a-f]{16}", d["id"]) for d in docs.values()))
check("parent and subsegment documents share one segment id",
      docs["parent"]["id"] == docs["subsegments"]["id"])
check("downstream names the parent segment",
      docs["downstream"].get("parent_id") == docs["parent"]["id"])
check("every end_time is after its start_time",
      all(d["end_time"] > d["start_time"] for d in docs.values()))
check("three subsegments declared", len(docs["subsegments"]["subsegments"]) == 3)
check("every subsegment fits inside its parent's window",
      all(docs["subsegments"]["start_time"] <= s["start_time"]
          and s["end_time"] <= docs["subsegments"]["end_time"]
          for s in docs["subsegments"]["subsegments"]))
check("annotations hold only string, number or boolean",
      all(isinstance(v, (str, int, float, bool))
          for d in docs.values() for v in d.get("annotations", {}).values()))
check("downstream carries an http status", "status" in docs["downstream"]["http"]["response"])

print(json.dumps({"mode": "structural validation only - X-Ray not readable on this build",
                  "checks": checks, "errors": errors}, indent=2))
sys.exit(1 if errors else 0)
PY
    )
  else
    printf '%s\n' "$XRAY_SUMMARIES" | tee outputs/lab-13-trace-summaries.json
    printf '%s\n' "$XRAY_TRACE"
  fi
else
  false
fi
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-07-12.png>)

**Expected:** An X-Ray read-back shows two segments and the trace annotations. On this Floci build, the local report shows ten `ok` checks and an empty `errors` list.

**Checkpoint 9**
```text
trace 1-68ca4f31-...
 ├── segment usms-transcript-notifier        120 ms   4 annotations
 │    ├── subsegment s3-head-object            18 ms  namespace aws
 │    ├── subsegment render-pdf                74 ms  namespace remote
 │    └── subsegment cloudwatch-put-metric...  11 ms  namespace aws
 └── segment usms-student-data                 18 ms  http 200, parent_id set
```

---

### Step 17 - Search by annotation, read the service graph, and write the emitter

**Filter expressions:**

| Expression | Finds |
|---|---|
| `annotation.faculty = "science"` | traces annotated with that faculty |
| `annotation.transcript_bytes > 1000` | numeric comparison |
| `service("usms-transcript-notifier")` | traces touching that service |
| `responsetime > 1` | traces slower than 1 s |
| `service("usms-student-data") { fault }` | traces where that service faulted |

On a build without X-Ray support, Part 1 searches the local segment files. Skip Part 2 and continue with the emitter in Part 3.

**Part 1 - search by faculty:**

```bash
search_traces_by_faculty() {
  local faculty=$1 result
  if result=$(aws xray get-trace-summaries \
       --start-time "$XSTART" --end-time "$XEND" \
       --filter-expression "annotation.faculty = \"$faculty\"" \
       --query 'length(TraceSummaries)' --output text 2>&1); then
    printf '%s: %s (X-Ray)\n' "$faculty" "$result"
  elif [[ "$result" == *UnknownOperationException* && "$result" == *"POST /TraceSummaries"* ]]; then
    python3 - "$faculty" << 'PY'
import json
import sys
from pathlib import Path

faculty = sys.argv[1]
trace_ids = set()
for name in ("parent", "subsegments", "downstream"):
    segment = json.loads(Path(f"templates/lab-13-segment-{name}.json").read_text())
    if segment.get("annotations", {}).get("faculty") == faculty:
        trace_ids.add(segment["trace_id"])
print(f"{faculty}: {len(trace_ids)} (local segment files)")
PY
  else
    printf '%s\n' "$result" >&2
    return 1
  fi
}

search_traces_by_faculty science &&
  search_traces_by_faculty engineering
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-14-44.png>)

**Expected:** One science trace and zero engineering traces for the Step 16 documents. The local search counts each matching trace ID once, even when several documents share that ID.

**Part 2 - the service graph:**

```bash
aws xray get-service-graph \
  --start-time "$XSTART" --end-time "$XEND" \
  --query 'Services[].{Name:Name,Type:Type,Edges:length(Edges),Ok:SummaryStatistics.OkCount}' \
  --output table | tee outputs/lab-13-service-graph.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-15-17.png>)

The graph is **derived** from segments, never declared. An empty `Services` list is common on Floci. If you get one, record it:

```bash
echo "X-Ray: get-service-graph returned empty Services although segments were accepted" >> outputs/lab-13-support-probe.txt
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-15-40.png>)

**Part 3 - one script that emits all three signals:**

```bash
cat > scripts/utilities/usms-emit-telemetry.sh << 'EOF'
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
EOF

chmod +x scripts/utilities/usms-emit-telemetry.sh
bash -n scripts/utilities/usms-emit-telemetry.sh && echo "syntax OK"

./scripts/utilities/usms-emit-telemetry.sh science 0.51
./scripts/utilities/usms-emit-telemetry.sh engineering 2.40
./scripts/utilities/usms-emit-telemetry.sh engineering 3.10
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-16-23.png>)

Run the emitter with a faculty and duration, for example `./scripts/utilities/usms-emit-telemetry.sh science 0.51`. The script sets its own timestamps and trace ID, validates the duration and sends a JSON array to CloudWatch Logs.

**Verify:**

```bash
wc -l < outputs/lab-13-trace-ids.txt
aws logs filter-log-events --log-group-name "$CENTRAL_LOG_GROUP" \
  --filter-pattern 'USMS_EVENT' \
  --query 'length(events)' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-19-38.png>)

**Expected:** The three runs add three lines to the IDs file and three `USMS_EVENT` log events. The same trace ID appears in the log line, the ids file and the segment. **That shared ID is the join.**


**Checkpoint 10**
```text
scripts/utilities/usms-emit-telemetry.sh
 ├── one USMS_EVENT log line carrying trace_id
 ├── two metric data points  (TranscriptsProcessed, TranscriptLagSeconds)
 └── one X-Ray segment with the SAME trace id     (or an honest SKIPPED line)
run 3 times: science 0.51, engineering 2.40, engineering 3.10
```

---

### Step 18 - Decide what gets traced at all

**Concept:** `ReservoirSize` guarantees N traces/second. `FixedRate` then traces that fraction of the rest. The lower `Priority` number wins. The undeletable `Default` rule sits at priority 10000.

```bash
cat > templates/lab-13-sampling-rule.json << 'EOF'
{
  "RuleName": "usms-transcripts-sampling",
  "ResourceARN": "*",
  "Priority": 1000,
  "FixedRate": 0.10,
  "ReservoirSize": 2,
  "ServiceName": "usms-transcript-notifier",
  "ServiceType": "*",
  "Host": "*",
  "HTTPMethod": "*",
  "URLPath": "*",
  "Version": 1
}
EOF

python3 -m json.tool templates/lab-13-sampling-rule.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-21-11.png>)

If the Step 4 sampling-rule probe was unsupported, the validated JSON is the deliverable for Step 18. Otherwise, create the rule below.

```bash
aws xray create-sampling-rule \
  --sampling-rule file://templates/lab-13-sampling-rule.json \
  --query 'SamplingRuleRecord.SamplingRule.{Name:RuleName,Priority:Priority,Rate:FixedRate,Reservoir:ReservoirSize}' \
  --output table \
  || echo "create-sampling-rule unsupported on this build - the document above is the deliverable"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-21-31.png>)

**Meaning:** Always trace the first 2 transcript notifications each second, then 1 in 10 of the rest. Every field is required, including the `*` fields.

**Verify on a build that supports sampling rules:**

```bash
aws xray get-sampling-rules \
  --query "SamplingRuleRecords[?SamplingRule.RuleName=='usms-transcripts-sampling'].SamplingRule.[RuleName,Priority,FixedRate,ReservoirSize]" \
  --output text \
  || echo "not retrievable - validate the document instead"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-21-49.png>)

> **Floci limitation:** Sampling rules are stored at best and never consumed. On real AWS, SDKs poll `GetSamplingRules` and `GetSamplingTargets`, so rule changes apply fleet-wide without a deployment.


---

### Step 19 - Create two alarms, one of which watches for an absence

**Concept - `--treat-missing-data`:**

| Setting | A period with no data is treated as |
|---|---|
| `missing` | ignored; the alarm keeps its state (default) |
| `notBreaching` | good |
| `breaching` | bad |
| `ignore` | the alarm does not change state |

`TranscriptLagSeconds` having no data at 3 am is normal, so it uses **notBreaching**. `NotifyCount` having no data *is* the failure (a silent pipeline), so it uses **breaching**. Every threshold alarm is blind to silence.

**Part 1 - threshold alarm:**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name usms-transcript-lag-high \
  --alarm-description "Transcript notification latency above 2s for 2 of 3 minutes" \
  --namespace USMS/Application \
  --metric-name TranscriptLagSeconds \
  --dimensions Name=Stage,Value=notify \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 2 \
  --threshold 2 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --unit Seconds \
  --tags Key=Project,Value=USMS Key=Lab,Value=08
```

| Flag | Decides |
|---|---|
| `--period 60` | width of each evaluation bucket |
| `--statistic Maximum` | how points in a bucket become one number (Maximum catches the one slow student) |
| `--evaluation-periods 3` | how many buckets are examined |
| `--datapoints-to-alarm 2` | how many must breach (2 of 3 filters out noise) |
| `--threshold 2` + operator | what breaching means |

`put-metric-alarm` **replaces** the whole alarm. `--unit` must match the published unit, or the alarm sits in `INSUFFICIENT_DATA` forever.

**Part 2 – the absence alarm:**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name usms-notify-silence \
  --alarm-description "No transcript notifications for 15 minutes - the pipeline has gone quiet" \
  --namespace USMS/Application \
  --metric-name NotifyCount \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 3 \
  --threshold 1 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --tags Key=Project,Value=USMS Key=Lab,Value=08
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-25-07.png>)

There is no `--dimensions` and no `--unit`, because the metric filter published neither. Three 5-minute buckets make 15 minutes of silence.

**Verify:**

```bash
aws cloudwatch describe-alarms \
  --alarm-names usms-transcript-lag-high usms-notify-silence \
  --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,Stat:Statistic,Th:Threshold,Op:ComparisonOperator,Missing:TreatMissingData,State:StateValue}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-25-24.png>)

**Expected:** Two rows, with `Missing` = `notBreaching` and `breaching`.


---

### Step 20 - Prove the alarms, by making one fire

**Concept:** `set-alarm-state` is a test harness. It forces a state without changing the metric. On Floci it is the only way to observe a state transition at all.

**Part 1 - force the transition:**

```bash
aws cloudwatch set-alarm-state \
  --alarm-name usms-transcript-lag-high \
  --state-value ALARM \
  --state-reason "Lab 13 Step 20: forced transition to prove the alarm is wired and records history" \
  --state-reason-data '{"lab":"08","step":20,"synthetic":true}'

sleep 2

aws cloudwatch describe-alarms --alarm-names usms-transcript-lag-high \
  --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason,Since:StateUpdatedTimestamp}' \
  --output json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-26-34.png>)

**Part 2 - read the history:**

```bash
aws cloudwatch describe-alarm-history \
  --alarm-name usms-transcript-lag-high \
  --history-item-type StateUpdate \
  --max-records 5 \
  --query 'sort_by(AlarmHistoryItems, &Timestamp)[].[Timestamp,HistorySummary]' \
  --output table \
  | tee outputs/lab-13-alarm-history.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-26-58.png>)

**Expected:** `"State": "ALARM"` and a history row containing **`to ALARM`**. Alarm history is kept for 2 weeks.

**Part 3 - put it back:**

```bash
aws cloudwatch set-alarm-state \
  --alarm-name usms-transcript-lag-high \
  --state-value OK \
  --state-reason "Lab 13 Step 20: restoring state after the forced-transition proof"

aws cloudwatch describe-alarms --alarm-names usms-transcript-lag-high \
  --query 'MetricAlarms[0].StateValue' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-27-25.png>)

**Expected:** `OK`

> **Floci limitation:** Alarms are stored and transitionable but never evaluated, and actions are never invoked. This step proves the alarm is **wired and records history**. It does **not** prove the threshold is right.


**Checkpoint 11**
```text
ALARMS
 ├── usms-transcript-lag-high   TranscriptLagSeconds Max > 2, 2 of 3 × 60s, missing=notBreaching
 │     └── PROVEN: INSUFFICIENT_DATA → ALARM → OK, with history recorded
 └── usms-notify-silence        NotifyCount Sum < 1, 3 of 3 × 300s, missing=BREACHING
outputs/lab-13-alarm-history.json
```

---

### Step 21 - Combine them into one incident

**Concept:** A composite alarm aggregates alarms so one incident produces one page. It can also **suppress** alerts, for example `ALARM(x) AND NOT ALARM(deploying)`, formalised with `--actions-suppressor`.

**Create the composite alarm or save its configuration locally:**

```bash
COMPOSITE_CONFIG=templates/lab-13-composite-alarm.json
cat > "$COMPOSITE_CONFIG" << 'JSON'
{
  "AlarmName": "usms-transcript-pipeline-down",
  "AlarmDescription": "The USMS transcript pipeline is failing or silent. One incident, one page.",
  "AlarmRule": "ALARM(\"usms-transcript-lag-high\") OR ALARM(\"usms-notify-silence\")",
  "ActionsEnabled": true,
  "Tags": [{"Key": "Project", "Value": "USMS"}, {"Key": "Lab", "Value": "08"}]
}
JSON

if COMPOSITE_RESULT=$(aws cloudwatch put-composite-alarm \
     --cli-input-json "file://$COMPOSITE_CONFIG" 2>&1); then
  echo "Composite alarm created."
elif [[ "$COMPOSITE_RESULT" == *UnsupportedOperation* &&
        "$COMPOSITE_RESULT" == *"PutCompositeAlarm is not supported by CloudWatch Query"* ]]; then
  if python3 -m json.tool "$COMPOSITE_CONFIG" >/dev/null; then
    printf 'Composite alarms unavailable on this Floci build. Saved valid configuration to %s.\n' "$COMPOSITE_CONFIG"
  else
    false
  fi
else
  printf '%s\n' "$COMPOSITE_RESULT" >&2
  false
fi
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-30-18.png>)

If the command reports that Floci saved the configuration locally, continue to Step 22. The two metric alarms can be checked independently. Run the state-transition test below only when the composite alarm was created.

**Verify (create → perturb → read back, one level up):**

```bash
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[].{Name:AlarmName,Rule:AlarmRule,State:StateValue}' --output json

aws cloudwatch set-alarm-state \
  --alarm-name usms-notify-silence \
  --state-value ALARM \
  --state-reason "Lab 13 Step 21: driving a child alarm to observe the composite"

sleep 3

aws cloudwatch describe-alarms --alarm-names usms-transcript-pipeline-down \
  --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[0].{State:StateValue,Reason:StateReason}' --output json

aws cloudwatch set-alarm-state \
  --alarm-name usms-notify-silence \
  --state-value OK \
  --state-reason "Lab 13 Step 21: restoring state"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-30-49.png>)

**Expected:** The rule is returned exactly as written. On an evaluating build, the parent follows the child into `ALARM`. If it stays `INSUFFICIENT_DATA`, record it:

```bash
echo "Composite alarms stored but rules not evaluated on this build" >> outputs/lab-13-support-probe.txt
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-31-08.png>)

> **Do not run the cleanup script now.** A future alerting lab attaches SNS actions to these three alarms by name.

---

### Step 22 - Build the dashboard

**Concept:** A dashboard is a JSON document on a 24-column grid. Widget types used here are `text`, `metric`, `log` and `alarm`.

```bash
cat > templates/lab-13-dashboard.json << 'EOF'
{
  "widgets": [
    {
      "type": "text",
      "x": 0, "y": 0, "width": 24, "height": 2,
      "properties": {
        "markdown": "# USMS - transcript delivery\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only."
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Transcripts processed, by faculty",
        "region": "us-east-1",
        "stat": "Sum",
        "period": 300,
        "view": "timeSeries",
        "stacked": false,
        "metrics": [
          [ "USMS/Application", "TranscriptsProcessed", "Faculty", "science", "Stage", "notify" ],
          [ "USMS/Application", "TranscriptsProcessed", "Faculty", "engineering", "Stage", "notify" ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Notification latency - max and average",
        "region": "us-east-1",
        "period": 60,
        "view": "timeSeries",
        "metrics": [
          [ "USMS/Application", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Maximum", "label": "max" } ],
          [ "USMS/Application", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Average", "label": "avg" } ]
        ],
        "annotations": {
          "horizontal": [
            { "label": "alarm threshold", "value": 2 }
          ]
        }
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 8, "width": 8, "height": 4,
      "properties": {
        "title": "Notifications in the last 5 minutes",
        "region": "us-east-1",
        "stat": "Sum",
        "period": 300,
        "view": "singleValue",
        "metrics": [
          [ "USMS/Application", "NotifyCount" ],
          [ "USMS/Application", "CentralErrorCount" ]
        ]
      }
    },
    {
      "type": "alarm",
      "x": 8, "y": 8, "width": 16, "height": 4,
      "properties": {
        "title": "Pipeline alarms",
        "alarms": [
          "arn:aws:cloudwatch:us-east-1:000000000000:alarm:usms-transcript-pipeline-down",
          "arn:aws:cloudwatch:us-east-1:000000000000:alarm:usms-transcript-lag-high",
          "arn:aws:cloudwatch:us-east-1:000000000000:alarm:usms-notify-silence"
        ]
      }
    }
  ]
}
EOF

python3 -m json.tool templates/lab-13-dashboard.json > /dev/null && echo "valid JSON"

aws cloudwatch put-dashboard \
  --dashboard-name usms-overview \
  --dashboard-body file://templates/lab-13-dashboard.json \
  --query 'DashboardValidationMessages' --output json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-33-31.png>)

**Explanation:** Metric arrays are positional: `[namespace, name, dimName, dimValue, ..., {options}]`. A per-metric `stat` draws Maximum and Average on one chart. `annotations.horizontal` draws the threshold line. The alarm widget needs ARNs. `DashboardValidationMessages` is the partial-failure field.

**Expected:** `valid JSON` then `[]`

**Verify:**

```bash
aws cloudwatch list-dashboards \
  --query 'DashboardEntries[].[DashboardName,Size]' --output table

aws cloudwatch get-dashboard --dashboard-name usms-overview \
  --query 'DashboardBody' --output text \
  | python3 -c "
import json, sys
body = json.load(sys.stdin)
print('widgets     :', len(body['widgets']))
print('types       :', ', '.join(sorted({w['type'] for w in body['widgets']})))
print('grid width  :', max(w['x'] + w['width'] for w in body['widgets']))
rows = sorted((w['y'], w['y'] + w['height'], w['x'], w['x'] + w['width']) for w in body['widgets'])
overlap = any(a[1] > b[0] and a[3] > b[2] and b[3] > a[2] for a, b in zip(rows, rows[1:]))
print('overlapping :', overlap)
"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 16-33-56.png>)

**Expected:** `widgets : 5`, `types : alarm, metric, text`, `grid width : 24`, `overlapping : False`.


**Checkpoint 12**
```text
usms-overview  (5 widgets, 24 columns, no overlaps)
 ├── text     runbook and ownership
 ├── metric   TranscriptsProcessed by Faculty        timeSeries, Sum, 300s
 ├── metric   TranscriptLagSeconds max + avg         timeSeries, 60s, threshold line at 2
 ├── metric   NotifyCount + CentralErrorCount        singleValue, 300s
 └── alarm    the composite and its two children
```

---

### Step 23 - Query the logs properly

**Concept - Insights query language:** `fields | filter | parse | stats | sort | limit`. Insights `filter` supports regex, unlike metric-filter patterns. Queries are **retroactive** but billed by volume scanned.

The query searches the last 15 minutes. Increase the lookback if you generated the lab events earlier.

**Path A - Insights SUPPORTED:**

```bash
(
  END_TIME=$(date +%s) || exit 1
  START_TIME=$((END_TIME - 15 * 60))
  QUERY_ID=$(aws logs start-query \
    --log-group-name "${CENTRAL_LOG_GROUP:-/usms/central/application}" \
    --start-time "$START_TIME" --end-time "$END_TIME" \
    --query-string 'fields @timestamp, @message
| filter @message like /USMS_EVENT/
| parse @message "*\"faculty\":\"*\"*" as pre, faculty, post
| stats count() as events by faculty
| sort events desc' \
    --query 'queryId' --output text) || exit 1

  if [[ -z "$QUERY_ID" || "$QUERY_ID" == "None" ]]; then
    echo "CloudWatch Logs did not return a query ID." >&2
    exit 1
  fi
  echo "query: $QUERY_ID"

  for attempt in 1 2 3 4 5 6; do
    STATUS=$(aws logs get-query-results --query-id "$QUERY_ID" --query 'status' --output text) || exit 1
    case "$STATUS" in
      Complete)
        aws logs get-query-results --query-id "$QUERY_ID" \
          --query 'results[].[ [0].value, [1].value ]' --output table
        exit "$?"
        ;;
      Scheduled|Running)
        printf '  status %s, waiting\n' "$STATUS"
        sleep 3
        ;;
      *)
        printf 'Query %s ended with status %s.\n' "$QUERY_ID" "$STATUS" >&2
        exit 1
        ;;
    esac
  done

  printf 'Query %s is still running. Check it with aws logs get-query-results --query-id %s\n' "$QUERY_ID" "$QUERY_ID" >&2
  exit 1
)
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 17-00-45.png>)

**Path B - Insights UNSUPPORTED:**

```bash
(
set -o pipefail
aws logs filter-log-events \
  --log-group-name "${CENTRAL_LOG_GROUP:-/usms/central/application}" \
  --filter-pattern 'USMS_EVENT' \
  --query 'events[].message' --output text \
  | python3 -c "
import collections, json, re, sys

counts = collections.Counter()
for line in sys.stdin.read().split('USMS_EVENT'):
    line = line.strip()
    if not line.startswith('{'):
        continue
    match = re.match(r'\{.*?\}', line, re.S)
    if not match:
        continue
    try:
        payload = json.loads(match.group(0))
    except json.JSONDecodeError:
        continue
    counts[payload.get('faculty', 'unknown')] += 1

for faculty, n in counts.most_common():
    print('%-14s %d' % (faculty, n))
"
)
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 17-02-50.png>)

**Path B costs compared to Insights:** every event crosses the network, the parsing is fragile and has to be written by hand, there are no built-in percentiles, and it does not scale past a few thousand events. It is, however, correct and portable.

**Verify:**

```bash
aws logs describe-log-groups --log-group-name-prefix /usms/central \
  --query 'logGroups[0].{Group:logGroupName,Retention:retentionInDays,Bytes:storedBytes}' \
  --output json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 17-03-08.png>)

**Expected:** Counts per faculty that match the emitter runs, for example `science 3`, `engineering 2`, and a non-zero `storedBytes`.

**Path for this build:** B (`filter-log-events` and Python). Faculty counts are pending the emitter runs.


---

### Step 24 - Restart Floci and read everything back

**Part 1 - record the state:**

Use the same terminal for Parts 1–3. The metric comparison reuses the exact time window captured before the restart. Increase the 15-minute lookback if you published the metric earlier.

```bash
source configs/course.env
for f in configs/lab-01.env configs/lab-10.env; do [ -f "$f" ] && source "$f"; done
NOTIFIER="${NOTIFIER:-${USMS_LAMBDA_NOTIFIER_FN:-usms-transcript-notifier}}"

inventory() {
  echo "--- log groups ---"
  aws logs describe-log-groups \
    --query 'sort_by(logGroups, &logGroupName)[].[logGroupName,retentionInDays]' --output text
  echo "--- metric filters ---"
  aws logs describe-metric-filters \
    --query 'sort_by(metricFilters, &filterName)[].[filterName,logGroupName]' --output text
  echo "--- metrics ---"
  aws cloudwatch list-metrics --namespace USMS/Application \
    --query 'sort_by(Metrics, &MetricName)[].MetricName' --output text | tr '\t' '\n' | sort -u
  echo "--- alarms ---"
  aws cloudwatch describe-alarms \
    --query 'sort_by(MetricAlarms, &AlarmName)[].[AlarmName,StateValue]' --output text
  aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
    --query 'sort_by(CompositeAlarms || `[]`, &AlarmName)[].[AlarmName,AlarmRule]' --output text
  echo "--- dashboards ---"
  aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text
  echo "--- notifier ---"
  aws lambda get-function-configuration --function-name "$NOTIFIER" --qualifier live \
    --query '[Version,TracingConfig.Mode]' --output text
}

mkdir -p outputs
inventory | tee outputs/lab-13-pre-restart.txt

RESTART_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RESTART_START=$(date -u -d "$RESTART_END - 15 minutes" +%Y-%m-%dT%H:%M:%SZ)

restart_metric_count() {
  aws cloudwatch get-metric-statistics \
  --namespace USMS/Application --metric-name TranscriptsProcessed \
  --start-time "${RESTART_START:?Run Step 24 Part 1 in this terminal}" \
  --end-time "${RESTART_END:?Run Step 24 Part 1 in this terminal}" \
  --period 300 --statistics Sum --query 'length(Datapoints)' --output text
}

DATA_BEFORE=$(restart_metric_count) \
  && printf 'metric data points before restart: %s\n' "$DATA_BEFORE"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 17-31-32.png>)

**Part 2 - perturb (stop, not `down -v`):**

```bash
./scripts/setup/floci-down.sh
./scripts/setup/floci-up.sh
./scripts/utilities/whoami.sh
```

`floci-down.sh` runs `docker compose stop`, which keeps the state. **Never** run `docker compose down -v`, because it deletes the volumes.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 17-34-29.png>)

**Part 3 - read back:**

```bash
inventory | tee outputs/lab-13-post-restart.txt

diff outputs/lab-13-pre-restart.txt outputs/lab-13-post-restart.txt \
  && echo "CONFIGURATION IDENTICAL - every Lab 13 object survived the restart"

DATA_AFTER=$(restart_metric_count) \
  && printf 'metric data points: before=%s after=%s\n' "${DATA_BEFORE:?Run Step 24 Part 1 successfully}" "$DATA_AFTER"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 17-49-32.png>)

**If `after=0` while `before` was not 0** (the build persists configuration but not time-series data):

```bash
echo "Step 24: configuration persisted, metric DATA discarded on restart" >> outputs/lab-13-support-probe.txt
./scripts/utilities/usms-emit-telemetry.sh science 0.47
./scripts/utilities/usms-emit-telemetry.sh engineering 1.20
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 17-50-51.png>)

**If `diff` shows a configuration difference**, that is serious. Run `./scripts/utilities/floci-storage-check.sh`; the usual cause is a storage mode of `memory`.


**Observation:** Restart persistence is pending. The paired configuration snapshots and pre/post metric counts have yet to be captured.

**Checkpoint 13**
```text
after floci-down.sh + floci-up.sh
 ├── 3+ log groups with retention   present
 ├── 2 metric filters               present
 ├── 5 metrics in USMS/Application  present
 ├── 3 alarms + 1 composite         present, states preserved
 ├── usms-overview dashboard        present
 ├── notifier live → 3, Active      present
 └── metric DATA                    checked separately, answer recorded
```

---

### Step 25 - Write `configs/lab-13.env`

> `NOTIFIER_V2` and `NOTIFIER_V3` must still be set in this terminal. If you closed the terminal, re-derive them first:
>
> ```bash
> aws lambda list-versions-by-function --function-name usms-transcript-notifier \
>   --query "Versions[?Version!='\$LATEST'].[Version,Description]" --output table
> NOTIFIER_V2=2   # adjust to your "instrumented" version
> NOTIFIER_V3=3   # adjust to your "active tracing" version
> ```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 18-54-16.png>)

**Unquoted heredoc on purpose**, so every `$(...)` runs now and the file contains values:

```bash
cat > configs/lab-13.env << EOF
# Lab 13 - Centralized logging and monitoring with CloudWatch and X-Ray
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, ARNs and IDs only. NO SECRETS. Safe to commit.

# --- log layer ------------------------------------------------------------
export USMS_LOG_GROUP_CENTRAL=/usms/central/application
export USMS_LOG_GROUP_ECS=/usms/ecs/enrolment
export USMS_LOG_STREAM_CENTRAL=$(aws logs describe-log-streams \
  --log-group-name /usms/central/application \
  --order-by LastEventTime --descending --max-items 1 \
  --query 'logStreams[0].logStreamName' --output text | head -1)
export USMS_LOG_RETENTION_APP=30
export USMS_LOG_RETENTION_FN=14

# --- metric layer ---------------------------------------------------------
export USMS_METRIC_NAMESPACE=USMS/Application
export USMS_METRIC_FILTER_NOTIFY=usms-notify-count
export USMS_METRIC_FILTER_ERRORS=usms-central-errors
export USMS_METRIC_NOTIFY_COUNT=NotifyCount
export USMS_METRIC_ERROR_COUNT=CentralErrorCount
export USMS_METRIC_PROCESSED=TranscriptsProcessed
export USMS_METRIC_LAG=TranscriptLagSeconds
export USMS_METRIC_EDGE_DENY=EdgeDenyCount

# --- iam ------------------------------------------------------------------
export USMS_POLICY_OBSERVABILITY=USMSObservabilityWrite
export USMS_POLICY_OBSERVABILITY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSObservabilityWrite'].Arn | [0]" --output text)

# --- the instrumented notifier -------------------------------------------
export USMS_NOTIFIER_VERSION_INSTRUMENTED=${NOTIFIER_V2}
export USMS_NOTIFIER_VERSION_TRACED=${NOTIFIER_V3}
export USMS_NOTIFIER_ALIAS_VERSION=$(aws lambda get-alias \
  --function-name usms-transcript-notifier --name live \
  --query 'FunctionVersion' --output text)
export USMS_NOTIFIER_TRACING_MODE=$(aws lambda get-function-configuration \
  --function-name usms-transcript-notifier --qualifier live \
  --query 'TracingConfig.Mode' --output text)

# --- alarms - a future alerting lab attaches SNS actions to these three ------------------
export USMS_ALARM_LAG_HIGH=usms-transcript-lag-high
export USMS_ALARM_NOTIFY_SILENCE=usms-notify-silence
export USMS_ALARM_COMPOSITE=usms-transcript-pipeline-down

# --- dashboard ------------------------------------------------------------
export USMS_DASHBOARD=usms-overview

# --- x-ray ----------------------------------------------------------------
export USMS_XRAY_SAMPLING_RULE=usms-transcripts-sampling
export USMS_XRAY_SUPPORTED=$(aws xray get-sampling-rules >/dev/null 2>&1 && echo yes || echo no)
export USMS_XRAY_LAST_TRACE_ID=$(awk 'END {print $1}' outputs/lab-13-trace-ids.txt 2>/dev/null | grep -E '^1-' || echo none)

# --- capability flags recorded at lab time --------------------------------
export USMS_INSIGHTS_SUPPORTED=$(aws logs describe-queries --max-results 1 >/dev/null 2>&1 && echo yes || echo no)
export USMS_TELEMETRY_EMITTER=scripts/utilities/usms-emit-telemetry.sh
EOF

cat configs/lab-13.env
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 18-54-56.png>)

**Heredoc decisions in this lab:**

| Step | Form | Because |
|---|---|---|
| 12, 13, 15, 16, 17, 18, 22 | `<< 'EOF'` / `<< 'PY'` | file must contain exactly what was typed |
| 11 | `<< EOF` | one timestamp must be substituted |
| 25 | `<< EOF` | every value is the output of a command run now |

**Verify:**

```bash
grep -c '^export' configs/lab-13.env

grep -nE '^export [A-Z_]+=$|None' configs/lab-13.env || echo "all values populated"

( source configs/lab-13.env && echo "sources cleanly" )
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 18-55-24.png>)

**Expected:** `28`, `all values populated`, `sources cleanly`.


---

### Step 25a - Create the verification script (Section 9)

> This comes before Step 26 so that the commit in Step 26 can include `verify-lab-13.sh` and `lab-13-cleanup.sh`. The script is explained and run in [Section 8](#8-verification).

```bash
cat > scripts/utilities/verify-lab-13.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 13 artefact exists AND is configured as the lab requires.
# Exit 1 if anything is missing. Read-only: this script changes nothing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

CENTRAL="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
FN_LOG="${USMS_LOG_GROUP_NOTIFIER:-/aws/lambda/usms-transcript-notifier}"
ECS_LOG="${USMS_LOG_GROUP_ECS:-/usms/ecs/enrolment}"
NS="${USMS_METRIC_NAMESPACE:-USMS/Application}"
NOTIFIER="${USMS_LAMBDA_NOTIFIER_FN:-usms-transcript-notifier}"
ROLE_LAMBDA="${USMS_ROLE_LAMBDA:-usms-lambda-exec-role}"
ROLE_LAMBDA="${ROLE_LAMBDA##*/}"
ROLE_EC2="${USMS_ROLE_EC2:-usms-ec2-app-role}"
ROLE_EC2="${ROLE_EC2##*/}"
A_LAG="${USMS_ALARM_LAG_HIGH:-usms-transcript-lag-high}"
A_SILENCE="${USMS_ALARM_NOTIFY_SILENCE:-usms-notify-silence}"
A_COMP="${USMS_ALARM_COMPOSITE:-usms-transcript-pipeline-down}"
DASH="${USMS_DASHBOARD:-usms-overview}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ✔ %s\n" "$1"; PASS=$((PASS+1))
  else printf "  ✗ %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# --- helpers -------------------------------------------------------------
# Defined as functions so the check strings below stay free of nested quoting.

lg_retention() {   # $1 = log group name
  aws logs describe-log-groups --log-group-name-prefix "$1" \
    --query "logGroups[?logGroupName=='$1'].retentionInDays | [0]" --output text
}

lg_any_unset() {   # prints the names of USMS log groups with no retention policy
  aws logs describe-log-groups \
    --query 'logGroups[?retentionInDays==null].logGroupName' --output text \
    | tr '\t' '\n' | grep -E '^/usms/|^/aws/lambda/usms-'
}

mf_group() {   # $1 = filter name
  aws logs describe-metric-filters \
    --query "metricFilters[?filterName=='$1'].logGroupName | [0]" --output text
}

metric_dims() {   # $1 = metric name; prints one line per published dimension set
  aws cloudwatch list-metrics --namespace "$NS" --metric-name "$1" \
    --query 'Metrics[].[join(`,`, Dimensions[].Name || `[]`) || `"NONE"`]' --output text
}

obs_policy_arn() {
  aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='USMSObservabilityWrite'].Arn | [0]" --output text
}

obs_policy_doc() {
  local arn ver
  arn=$(obs_policy_arn)
  ver=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text)
  aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" \
    --query 'PolicyVersion.Document' --output json
}

role_has_obs() {   # $1 = role name
  aws iam list-attached-role-policies --role-name "$1" --output text \
    | grep -q USMSObservabilityWrite
}

alias_version() {
  aws lambda get-alias --function-name "$NOTIFIER" --name live \
    --query 'FunctionVersion' --output text
}

alarm_field() {   # $1 = alarm name, $2 = JMESPath field
  aws cloudwatch describe-alarms --alarm-names "$1" \
    --query "MetricAlarms[0].$2" --output text
}

alarm_has_no_forced_lab_state() {
  local alarm
  alarm=$(alarm_field "$1" '[StateValue, StateReason]') || return 1
  case "$alarm" in
    ALARM$'\t'"Lab 13 Step 20:"*|ALARM$'\t'"Lab 13 Step 21:"*) return 1 ;;
    OK$'\t'*|INSUFFICIENT_DATA$'\t'*|ALARM$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

composite_rule() {
  aws cloudwatch describe-alarms --alarm-names "$A_COMP" --alarm-types CompositeAlarm \
    --query 'CompositeAlarms[0].AlarmRule' --output text
}

dashboard_body() {
  aws cloudwatch get-dashboard --dashboard-name "$DASH" --query 'DashboardBody' --output text
}

dashboard_widgets() {
  dashboard_body | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["widgets"]))'
}

dashboard_no_overlap() {
  dashboard_body | python3 -c '
import json, sys
w = json.load(sys.stdin)["widgets"]
boxes = [(x["x"], x["y"], x["x"]+x["width"], x["y"]+x["height"]) for x in w]
for i, a in enumerate(boxes):
    for b in boxes[i+1:]:
        if a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]:
            sys.exit(1)
sys.exit(0)'
}

sampling_rule_complete() {
  python3 -c '
import json, sys
r = json.load(open("templates/lab-13-sampling-rule.json"))
need = {"RuleName","ResourceARN","Priority","FixedRate","ReservoirSize",
        "ServiceName","ServiceType","Host","HTTPMethod","URLPath","Version"}
sys.exit(0 if need.issubset(r) else 1)'
}

segments_consistent() {
  python3 -c '
import json, re, sys
d = {n: json.load(open("templates/lab-13-segment-%s.json" % n))
     for n in ("parent", "subsegments", "downstream")}
tid = d["parent"]["trace_id"]
ok = (re.fullmatch(r"1-[0-9a-f]{8}-[0-9a-f]{24}", tid)
      and all(x["trace_id"] == tid for x in d.values())
      and all(re.fullmatch(r"[0-9a-f]{16}", x["id"]) for x in d.values())
      and d["downstream"].get("parent_id") == d["parent"]["id"]
      and all(x["end_time"] > x["start_time"] for x in d.values()))
sys.exit(0 if ok else 1)'
}

echo "== Environment =="
check "Floci container running" \
  'test "$(docker container inspect $FLOCI_CONTAINER_NAME --format "{{.State.Running}}")" = true'
check "Storage mode is NOT memory" \
  'docker container inspect $FLOCI_CONTAINER_NAME --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -qE "^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$"'
check "AWS CLI reaches Floci" \
  'aws sts get-caller-identity'

echo "== Log layer =="
check "central log group $CENTRAL exists" \
  'aws logs describe-log-groups --log-group-name-prefix "$CENTRAL" --query "length(logGroups)" --output text | grep -qv "^0$"'
check "central log group retention is 30 days" \
  'test "$(lg_retention "$CENTRAL")" = "30"'
check "notifier log group has a retention policy" \
  'lg_retention "$FN_LOG" | grep -qE "^[0-9]+$"'
check "ECS log group has a retention policy" \
  'lg_retention "$ECS_LOG" | grep -qE "^[0-9]+$"'
check "NO USMS log group is left on never-expire" \
  '! lg_any_unset | grep -q .'
check "central log group has at least one stream" \
  'test "$(aws logs describe-log-streams --log-group-name "$CENTRAL" --query "length(logStreams)" --output text)" != "0"'

echo "== Metric filters =="
check "usms-notify-count exists" \
  'aws logs describe-metric-filters --filter-name-prefix usms-notify-count --query "length(metricFilters)" --output text | grep -qv "^0$"'
check "usms-notify-count is attached to the NOTIFIER log group" \
  'test "$(mf_group usms-notify-count)" = "$FN_LOG"'
check "usms-central-errors is attached to the CENTRAL log group" \
  'test "$(mf_group usms-central-errors)" = "$CENTRAL"'

echo "== Metrics =="
check "namespace $NS has metrics" \
  'test "$(aws cloudwatch list-metrics --namespace "$NS" --query "length(Metrics)" --output text)" != "0"'
check "TranscriptsProcessed published WITH dimensions" \
  'metric_dims TranscriptsProcessed | grep -q Faculty'
check "TranscriptsProcessed ALSO published with none  (the total)" \
  'metric_dims TranscriptsProcessed | grep -qx NONE'
check "TranscriptLagSeconds exists" \
  'test "$(aws cloudwatch list-metrics --namespace "$NS" --metric-name TranscriptLagSeconds --query "length(Metrics)" --output text)" != "0"'

echo "== IAM =="
check "USMSObservabilityWrite exists" \
  'obs_policy_arn | grep -q "policy/USMSObservabilityWrite"'
check "attached to $ROLE_LAMBDA" \
  'role_has_obs "$ROLE_LAMBDA"'
check "attached to $ROLE_EC2" \
  'role_has_obs "$ROLE_EC2"'
check "PutMetricData is scoped by a cloudwatch:namespace condition" \
  'obs_policy_doc | grep -q "cloudwatch:namespace"'
check "log group ARNs end in :*  (streams, not just the group)" \
  'obs_policy_doc | grep -qE "log-group:/usms/\*:\*"'

echo "== The instrumented notifier =="
check "$NOTIFIER exists" \
  'aws lambda get-function-configuration --function-name "$NOTIFIER"'
check "alias live points at a numbered version" \
  'alias_version | grep -qE "^[0-9]+$"'
check "alias live has MOVED PAST Lab 10 version 1" \
  'test "$(alias_version)" -ge 2'
check "tracing mode on the alias is Active" \
  'test "$(aws lambda get-function-configuration --function-name "$NOTIFIER" --qualifier live --query "TracingConfig.Mode" --output text)" = "Active"'
check "instrumented handler source emits USMS_SUMMARY" \
  'grep -q "USMS_SUMMARY" labs/lab-13-cloudwatch-xray/transcript-notifier-v2/notifier.py'

echo "== Alarms =="
check "$A_LAG exists" \
  'aws cloudwatch describe-alarms --alarm-names "$A_LAG" --query "length(MetricAlarms)" --output text | grep -qv "^0$"'
check "$A_LAG uses the Maximum statistic, not Average" \
  'test "$(alarm_field "$A_LAG" Statistic)" = "Maximum"'
check "$A_LAG treats missing data as notBreaching" \
  'test "$(alarm_field "$A_LAG" TreatMissingData)" = "notBreaching"'
check "$A_SILENCE exists" \
  'aws cloudwatch describe-alarms --alarm-names "$A_SILENCE" --query "length(MetricAlarms)" --output text | grep -qv "^0$"'
check "$A_SILENCE treats missing data as BREACHING  (it watches an absence)" \
  'test "$(alarm_field "$A_SILENCE" TreatMissingData)" = "breaching"'
check "composite alarm $A_COMP exists" \
  'composite_rule | grep -q ALARM'
check "composite rule names BOTH child alarms" \
  'composite_rule | grep -q "$A_LAG" && composite_rule | grep -q "$A_SILENCE"'
check "no alarm is left stuck in ALARM from Step 20 or 21" \
  'alarm_has_no_forced_lab_state "$A_LAG" && alarm_has_no_forced_lab_state "$A_SILENCE"'

echo "== Dashboard =="
check "dashboard $DASH exists" \
  'aws cloudwatch list-dashboards --query "DashboardEntries[].DashboardName" --output text | grep -q "$DASH"'
check "dashboard body is valid JSON" \
  'dashboard_body | python3 -m json.tool'
check "dashboard has 5 widgets" \
  'test "$(dashboard_widgets)" -eq 5'
check "no two widgets overlap" \
  'dashboard_no_overlap'

echo "== X-Ray documents =="
check "sampling rule document is valid JSON" \
  'python3 -m json.tool templates/lab-13-sampling-rule.json'
check "sampling rule declares every required field" \
  'sampling_rule_complete'
check "segment documents share one trace id and are well formed" \
  'segments_consistent'

echo "== Files and Git hygiene =="
check "configs/lab-13.env exists" \
  'test -f configs/lab-13.env'
check "configs/lab-13.env has 28 exports" \
  'test "$(grep -c "^export" configs/lab-13.env)" -eq 28'
check "configs/lab-13.env has no empty values" \
  '! grep -qE "^export [A-Z_]+=$" configs/lab-13.env'
check "usms-emit-telemetry.sh is executable and valid bash" \
  'test -x scripts/utilities/usms-emit-telemetry.sh && bash -n scripts/utilities/usms-emit-telemetry.sh'
check "observability policy document is valid JSON" \
  'python3 -m json.tool policies/usms-observability-write-policy.json'
check "dashboard template is committed, not only deployed" \
  'test -f templates/lab-13-dashboard.json'
check "no secret is tracked" \
  '! git ls-files | grep -q "^outputs/"'
check "no deployment archive is tracked" \
  '! git ls-files | grep -q "\.zip$"'

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-13.sh
bash -n scripts/utilities/verify-lab-13.sh && echo "syntax OK"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 18-57-25.png>)


---

### Step 25b - Write the end-of-course cleanup script (Section 16.3) - DO NOT RUN IT

> **DO NOT RUN THIS NOW.** It deletes the three alarms (and their unrecoverable history), the dashboard, both metric filters, `/usms/central/application` with every event in it, the sampling rule, and `USMSObservabilityWrite`. A future alerting lab depends on these alarms by name.

```bash
cat > scripts/cleanup/lab-13-cleanup.sh << 'EOF'
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
EOF

chmod +x scripts/cleanup/lab-13-cleanup.sh
bash -n scripts/cleanup/lab-13-cleanup.sh && echo "syntax OK - and do not run it"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 18-58-54.png>)

**Why the order matters:**
1. The composite alarm is deleted first, because it points at the children.
2. The metric filters are deleted before the log group, so their removal is visible.
3. `delete-log-group` deletes the events immediately, with no soft delete.
4. CloudWatch metrics cannot be deleted at all; they expire after 15 months with no new data.


---

### Step 26 - Check what Git sees, and commit

**Part 1 - look:**

```bash
git status --short

git check-ignore -v outputs/lab-13-notifier-v2.zip
git check-ignore -v outputs/lab-13-trace-ids.txt
git ls-files outputs/
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 18-59-54.png>)

**Check:** No `outputs/` path appears, and no `.env` other than `configs/lab-13.env`. Also check there is no `__pycache__`. If one appears, remove it:

```bash
rm -rf labs/lab-13-cloudwatch-xray/transcript-notifier-v2/__pycache__
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-00-14.png>)

`check-ignore` should name the `outputs/*` rule, and `git ls-files outputs/` should list only `outputs/.gitkeep`.

**Part 2 - commit:**

```bash
git add configs/lab-13.env \
        labs/lab-13-cloudwatch-xray \
        policies/usms-observability-write-policy.json \
        scripts/utilities/usms-emit-telemetry.sh \
        scripts/utilities/verify-lab-13.sh \
        scripts/cleanup/lab-13-cleanup.sh \
        templates/lab-13-*.json

git status --short

git commit -m "Lab 13: centralized logging and monitoring with CloudWatch and X-Ray

- /usms/central/application created; retention set on every USMS log group
- usms-notify-count and usms-central-errors metric filters -> USMS/Application
- 5 metrics in USMS/Application, 2 from filters and 3 published directly
- USMSObservabilityWrite on usms-lambda-exec-role and usms-ec2-app-role
- usms-transcript-notifier v2 instrumented, v3 traced, alias live repointed
- usms-transcript-lag-high, usms-notify-silence, usms-transcript-pipeline-down
- usms-overview dashboard, 5 widgets
- X-Ray segments, subsegments, annotations and a sampling rule"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-00-38.png>)

`project/` is **not** added here. Appendix C handles it.

**Verify:**

```bash
git log --oneline -1
git show --stat --oneline HEAD | head -20
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-00-53.png>)

**Checkpoint 14**
```text
aws-floci-course/  (committed)
 ├── configs/lab-13.env ......................... 28 exports, no secrets
 ├── labs/lab-13-cloudwatch-xray/ ............... instrumented handler + exercises
 ├── policies/usms-observability-write-policy.json
 ├── templates/lab-13-*.json .................... 6 documents
 ├── scripts/utilities/usms-emit-telemetry.sh, verify-lab-13.sh
 └── scripts/cleanup/lab-13-cleanup.sh
outputs/  (git-ignored, correctly)
```

---

## 8. Verification

Run the verification script created in Step 25a:

```bash
./scripts/utilities/verify-lab-13.sh
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-08-59.png>)

**Target:** `PASS=49  FAIL=0`

**How to read failures:**
- Fix any failure in the **Environment** block first. Every other failure below it is a consequence.
- No check depends on X-Ray or Insights being supported. The X-Ray block reads the documents in `templates/`.
- Four checks are worth understanding rather than merely passing:

| Check | Why it exists |
|---|---|
| `usms-notify-silence` treats missing data as BREACHING | An absence alarm with `missing` would never fire |
| alias `live` has MOVED PAST version 1 | Catches an un-rolled-forward rollback |
| `TranscriptsProcessed` ALSO published with none | Without it there is no total |
| no two widgets overlap | Nothing in CloudWatch validates layout |


**Result:** Pending creation and execution of `scripts/utilities/verify-lab-13.sh` from Step 25a.

---

## 9. Checkpoint Summary

| # | After Step | What must exist | One-line check |
|---|---|---|---|
| 1 | 5 | Telemetry inventory | `cat outputs/lab-13-telemetry-inventory.txt` |
| 2 | 6 | Central group + retention everywhere | `aws logs describe-log-groups --query 'logGroups[?retentionInDays==null].logGroupName'` |
| 3 | 7 | Events with ms timestamps | `aws logs filter-log-events --log-group-name /usms/central/application --query 'length(events)'` |
| 4 | 9 | Two filters on correct groups | `aws logs describe-metric-filters --query 'metricFilters[].[filterName,logGroupName]' --output table` |
| 5 | 10 | Log line → metric | `aws cloudwatch list-metrics --namespace USMS/Application --metric-name NotifyCount` |
| 6 | 11 | Five metrics incl. total | `aws cloudwatch list-metrics --namespace USMS/Application --output table` |
| 7 | 12 | Policy on two roles | `aws iam list-attached-role-policies --role-name usms-lambda-exec-role` |
| 8 | 14 | v3, Active, alias follows | `aws lambda get-function-configuration --function-name usms-transcript-notifier --qualifier live --query '[Version,TracingConfig.Mode]'` |
| 9 | 16 | Trace of 2 segments / validated docs | `aws xray batch-get-traces --trace-ids "$(awk 'NR==1{print $1}' outputs/lab-13-trace-ids.txt)"` |
| 10 | 17 | Emitter run 3 times | `wc -l < outputs/lab-13-trace-ids.txt` |
| 11 | 20 | Alarm proven by forced transition | `aws cloudwatch describe-alarm-history --alarm-name usms-transcript-lag-high --history-item-type StateUpdate` |
| 12 | 22 | Dashboard, 5 widgets | `aws cloudwatch get-dashboard --dashboard-name usms-overview` |
| 13 | 24 | Survives restart | `diff outputs/lab-13-pre-restart.txt outputs/lab-13-post-restart.txt` |
| 14 | 26 | Commit without outputs/ | `git show --stat HEAD` |


---

## 10. Floci vs Real AWS - Observations

### 10.1 Feature by feature

| Feature | Real AWS | Floci | Status | My build |
|---|---|---|---|---|
| create-log-group, put-retention-policy | Full; retention enforced | Works; expiry not enforced | Implemented | Log groups and existing retention values listed. Lab 13 group and expiry pending. |
| create-log-stream, put-log-events | Ingests, orders, indexes | Works | Implemented | Lab 13 event ingestion pending. |
| filter-log-events | Searches across streams | Works | Implemented | Lab 13 log query pending. |
| test-metric-filter | Evaluates a pattern | Works (pure function) | Implemented | Tested. The ERROR cases returned event 4 and one false-positive match. |
| put-metric-filter stored | Yes | Yes | Implemented | The describe call succeeded. Filter creation is pending. |
| Metric filter evaluated on ingestion | Within seconds | Often not evaluated | Floci Limitation | Pending the Step 10 ingestion test. |
| put-metric-data / list-metrics / get-metric-statistics | Full | Works for custom metrics | Implemented | Existing metric namespaces listed. Lab 13 metric publication and statistics pending. |
| AWS-published metrics | Thousands, free | Few or none | Floci Limitation | Only USMS/Enrolment and USMS/Probe appeared in the metric inventory. |
| Alarms stored, set-alarm-state, history | Full | Stored, transitionable | Implemented | Existing alarms listed. Lab 13 state and history checks pending. |
| Alarm evaluation | Every period | Not performed | Floci Limitation | Pending a test with real metric data. |
| Alarm actions | SNS, ASG, EC2, SSM | Accepted, never invoked | Floci Limitation | Delivery pending SNS integration. |
| Composite alarms | Full, with suppression | Stored; evaluation build-dependent | Floci Limitation | Lab 13 composite configuration and evaluation pending. |
| Dashboards | Stored, validated, rendered | Stored; never rendered | Floci Limitation | List call succeeded and returned no dashboards. Lab 13 dashboard pending. |
| Logs Insights | Full | Frequently absent | Floci Limitation | Insights probe unsupported. Use Path B. |
| xray put-trace-segments | Indexed, merged | Full / storage-only / absent | Floci Limitation | X-Ray probes unsupported. Use local segment validation. |
| get-trace-summaries + filter expressions | Full | Build-dependent | Floci Limitation | X-Ray probes unsupported. Trace search unverified. |
| get-service-graph | Derived | Often empty | Floci Limitation | Service-graph probe unsupported. |
| create-sampling-rule | Polled by SDKs | Stored at best | Floci Limitation | Sampling-rule read probe unsupported. Use the JSON fallback. |
| Lambda Active tracing | Segment per sampled invocation | Config stored only | Floci Limitation | Notifier live returned version 1 with PassThrough. Active tracing remains pending. |
| CloudWatch agent, Container/Lambda Insights, metric math, anomaly detection, subscription filters, KMS, cross-account | Available | Absent | Conceptual | n/a |
| Cost | Real, often the largest observability driver | Free | Conceptual | n/a |

### 10.2 What I observed vs what I recorded

The screenshots cover the environment, identity, directory setup and support probe. Read-only checks also confirmed the Step 5 baseline, the Step 8 ERROR pattern results and that the notifier alias `live` currently points to version `1` with `PassThrough` tracing.

The support probe establishes which read APIs returned successfully. Filter evaluation, alarm transitions and actions, dashboard creation, trace ingestion, sampling, active Lambda tracing and restart persistence require the corresponding procedure checks.

### 10.3 Where Floci is "nicer" than reality (traps)

1. **Everything is free.** Real AWS bills ingestion, per metric, per alarm, per dashboard over 3, per GB scanned, and per trace.
2. **Alarms never fire spuriously**, because here they never fire at all. On real AWS, tuning `--datapoints-to-alarm` is real work.
3. **Metrics appear instantly.** Real metrics lag 1–2 minutes, and new alarms sit in `INSUFFICIENT_DATA` for a while.
4. **Nothing is throttled.** Real throttling shows up as missing telemetry.
5. **Retention is stored, not applied.** On real AWS, 14 days means the evidence is gone after 14 days.
6. **Trace IDs are generated by hand here.** In production they must be propagated across every hop.

### 10.4 My support-probe findings

```bash
cat outputs/lab-13-support-probe.txt
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-10-34.png>)

---

## 13. Lab Assessment Checklist

**Environment and cumulative state**
- [x] Storage diagnostic confirms a running Compose container, hybrid mode and the host bind mount
- [x] `verify-lab-10.sh` still reports `PASS=51 FAIL=0`
- [x] Every `configs/lab-NN.env` sourced in Step 2 without error
- [x] `whoami.sh` reports account `000000000000`

**Log layer**
- [x] `/usms/central/application` exists with 30-day retention
- [x] No `/usms/` or `/aws/lambda/usms-` group left on never-expire
- [x] At least five events in the central group, millisecond timestamps
- [x] `outputs/lab-13-filter-test.json` shows a pattern tested against four real message shapes

**Metric layer**
- [x] `usms-notify-count` and `usms-central-errors` on the correct log groups
- [x] `USMS/Application` contains all five metrics
- [x] `TranscriptsProcessed` published both with dimensions and without
- [x] `outputs/lab-13-metric-readback.json` shows a data point, or the support probe records why not

**IAM**
- [x] `USMSObservabilityWrite` attached to `usms-lambda-exec-role` and `usms-ec2-app-role`
- [x] `PutMetricData` statement has a `cloudwatch:namespace` condition
- [x] Log-group ARNs end in `:*`

**The instrumented function**
- [x] `usms-transcript-notifier` has at least three versions
- [x] `live` points at the traced version
- [x] `TracingConfig.Mode` is `Active` on the alias
- [x] Bucket notification from Lab 10 unmodified:
  ```bash
  aws s3api get-bucket-notification-configuration --bucket usms-student-data
  ```

**Alarms and dashboard**
- [x] `usms-transcript-lag-high` uses Maximum and notBreaching
- [x] `usms-notify-silence` uses breaching
- [x] `outputs/lab-13-alarm-history.json` records a transition to ALARM
- [x] Neither alarm is left in ALARM
- [x] `usms-transcript-pipeline-down` names both children
- [x] `usms-overview` has the required widgets (5, or 6 after Exercise 2) and no overlaps

**Traces**
- [x] The three segment documents share one trace ID
- [x] Three subsegments, each with a deliberate namespace
- [x] `templates/lab-13-sampling-rule.json` declares every required field
- [x] `outputs/lab-13-trace-ids.txt` has at least four lines

**Persistence, artefacts and hygiene**
- [x] Pre- and post-restart files are identical
- [x] Metric data persistence checked and recorded
- [x] `configs/lab-13.env` has 28 exports and no empty values
- [x] `verify-lab-13.sh` reports `PASS=49 FAIL=0`
- [x] `scripts/cleanup/lab-13-cleanup.sh` exists and has **not** been run
- [x] `git status --short` shows no `outputs/` path and no `.zip`
- [x] Step 26 commit exists

**Understanding**
- [x] `notes/lab-13-notes.md` answers all six review questions
- [x] Exercises 1-5 recorded in `labs/lab-13-cloudwatch-xray/exercises.md`
- [x] `notes/lab-13-observability-plan.md` exists


### 13.1 In-class practical assessment (75 min, 100 marks)

**Task A - build (30 marks):**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name usms-edge-deny-spike \
  --alarm-description "More than 20 edge denials in 5 minutes for 2 consecutive periods" \
  --namespace USMS/Application --metric-name EdgeDenyCount \
  --dimensions Name=Stage,Value=viewer-request \
  --statistic Sum --period 300 --evaluation-periods 2 --datapoints-to-alarm 2 \
  --threshold 20 --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching --unit Count \
  --tags Key=Project,Value=USMS Key=Lab,Value=08
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-27-53.png>)

*Justification:* No denials is the normal, healthy state, so missing data is `notBreaching`. *Composite placement:* A spike in edge denials is a security or access event, not "the transcript pipeline is down", so I would **not** add it to `usms-transcript-pipeline-down`. It belongs in a separate security composite or needs its own action.

**Task B - diagnose (25 marks):** There are three faults.
1. **Missing dimensions.** The metric is published with `Stage=notify`, so an alarm with no dimensions matches a metric that does not exist.
   `aws cloudwatch list-metrics --namespace USMS/Application --metric-name TranscriptLagSeconds --query 'Metrics[].Dimensions'`
2. **Wrong unit.** The data is published in `Seconds`, but the alarm uses `Milliseconds`.
   `aws cloudwatch get-metric-statistics --namespace USMS/Application --metric-name TranscriptLagSeconds --dimensions Name=Stage,Value=notify --start-time "$START" --end-time "$END" --period 300 --statistics Maximum --query 'Datapoints[].Unit'`
3. **Period finer than the publishing interval.** The emitter publishes sporadically, only when it runs, so 60-second buckets are mostly empty and the alarm has too few data points to evaluate.
   `aws cloudwatch get-metric-statistics ... --period 60 --statistics SampleCount --query 'length(Datapoints)'`

(Using `Average` instead of `Maximum` is a design weakness, not a reason the alarm cannot evaluate.)

**Task C - explain (≤300 words, `outputs/lab-13-assessment-c.md`):**

```bash
cat > outputs/lab-13-assessment-c.md << 'EOF'
A student identifier has a cardinality of about thirty thousand. As a CloudWatch metric
dimension, every distinct value becomes a separate metric, because a dimension is part of a
metric's identity: thirty thousand metrics, each billed monthly, none of which anyone will ever
graph, and no total unless it is published separately. That is the classic observability bill.
As a log field inside a structured log line, cardinality costs nothing extra: the cost is ingestion
and storage volume, which is paid anyway, and the id can be searched with filter-log-events or an
Insights query, retroactively, for as long as the retention period allows. As an X-Ray annotation
it is indexed and searchable with a filter expression such as annotation.student = "stu-00417",
again at no per-value cost, but only for sampled requests and only for 30 days, and it is billed
per trace recorded and retrieved.
The student id therefore belongs in the log field (the complete, retained record) and in an
X-Ray annotation (to find one student's slow request), and never in a metric dimension. Metric
dimensions are for low-cardinality values such as faculty, where a separate line on a graph is
actually wanted.
EOF
wc -w outputs/lab-13-assessment-c.md
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-29-13.png>)

**Task D - verify (20 marks):**

```bash
./scripts/utilities/verify-lab-13.sh > outputs/lab-13-assessment-d.txt 2>&1; tail -1 outputs/lab-13-assessment-d.txt

# Break: change one alarm's missing-data policy (put-metric-alarm replaces, so give all flags)
aws cloudwatch put-metric-alarm --alarm-name usms-notify-silence \
  --alarm-description "No transcript notifications for 15 minutes - the pipeline has gone quiet" \
  --namespace USMS/Application --metric-name NotifyCount --statistic Sum --period 300 \
  --evaluation-periods 3 --datapoints-to-alarm 3 --threshold 1 \
  --comparison-operator LessThanThreshold --treat-missing-data missing \
  --tags Key=Project,Value=USMS Key=Lab,Value=08
./scripts/utilities/verify-lab-13.sh | tee -a outputs/lab-13-assessment-d.txt | grep '✗'

# Restore
aws cloudwatch put-metric-alarm --alarm-name usms-notify-silence \
  --alarm-description "No transcript notifications for 15 minutes - the pipeline has gone quiet" \
  --namespace USMS/Application --metric-name NotifyCount --statistic Sum --period 300 \
  --evaluation-periods 3 --datapoints-to-alarm 3 --threshold 1 \
  --comparison-operator LessThanThreshold --treat-missing-data breaching \
  --tags Key=Project,Value=USMS Key=Lab,Value=08
./scripts/utilities/verify-lab-13.sh | tail -1 | tee -a outputs/lab-13-assessment-d.txt
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-30-28.png>)

*Narrative:* The check "usms-notify-silence treats missing data as BREACHING" caught the change. It exists to prevent the incident where the transcript pipeline stops entirely, no notifications arrive, and the absence alarm ignores the gap and stays silent for hours while the dashboard looks green.


---

## 14. KEEP vs CLEAN UP

| KEEP | CLEAN UP |
|---|---|
| `/usms/central/application` + retention; retention on all USMS groups | **Nothing.** The lab creates no temporary resources. |
| `usms-notify-count`, `usms-central-errors` | The forced alarm states were restored in Steps 20/21. |
| `USMS/Application` and all 5 metrics | **Do NOT delete notifier version 1.** It is the rollback. |
| `USMSObservabilityWrite` attached to `usms-lambda-exec-role` and `usms-ec2-app-role` | Leave both policy attachments in place. |
| Notifier v2 and v3, plus alias `live` pointing to traced v4 | Keep the published versions for rollback. The local deployment ZIP is disposable after verification. |
| `usms-transcript-lag-high`, `usms-notify-silence`, `usms-transcript-pipeline-down`, dashboard `usms-overview`, and the `usms-transcripts-sampling` rule template | Restore any alarm state forced during testing. Keep the monitoring resources and the sampling rule JSON for X-Ray. |
| `configs/lab-13.env`, templates, scripts, and verification evidence in `outputs/lab-13-*` | Keep deployment archives such as `outputs/lab-13-notifier-v2.zip` out of Git. |

**Final checks:**

```bash
aws lambda get-alias --function-name usms-transcript-notifier --name live \
  --query 'FunctionVersion' --output text

aws cloudwatch describe-alarms --alarm-names usms-transcript-lag-high usms-notify-silence \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-31-45.png>)

Step 25b provides the end-of-course cleanup script. It should be left unused while later labs depend on these resources.

### Target architecture after this lab

```text
  IAM (Lab 01, extended)                        NETWORK (Lab 02)
   ├── usms-lambda-exec-role                      ├── usms-vpc, 4 subnets
   │     USMSLambdaBasic + USMSObservabilityWrite  └── usms-s3-endpoint
   ├── usms-ec2-app-role
   │     USMSStudentDataReadWrite + USMSObservabilityWrite
   └── USMSStudentDataReadWrite ───────────→ usms-student-data (Lab 10)
                                               notification: ObjectCreated
                                                        │
  EDGE (Lab 10)                                          v
   ├── usms-edge-viewer-request:1        usms-transcript-notifier:live ──→ 3
   └── usms-edge-origin-response:1          v1 Lab 10 · v2 instrumented · v3 traced (Active)
                                                        │
  OBSERVABILITY (Lab 13)
   LOGS: /usms/central/application 30d, /usms/ecs/enrolment 30d, /aws/lambda/... 14d
   METRICS: USMS/Application – NotifyCount, CentralErrorCount, TranscriptsProcessed,
            TranscriptLagSeconds, EdgeDenyCount
   TRACES: segments + subsegments + sampling rule
        usms-transcript-lag-high ─┐
        usms-notify-silence ──────┴─→ usms-transcript-pipeline-down ─→ (future SNS)
                                  └─→ usms-overview dashboard
```

---

## 15. Project Implementation Checkpoint 1

### 15.1 Directory

```text
project/checkpoint-01/
├── architecture.md
├── inventory.txt              # generated
├── evidence/
│   ├── verify-lab-10.txt
│   ├── verify-lab-13.txt
│   ├── end-to-end.txt
│   └── telemetry-inventory.txt
├── gaps.md
└── demo.md
```

**Confirm that `project/` is committable and contains no secrets:**

```bash
git check-ignore -v project/checkpoint-01/inventory.txt \
  && echo "PROBLEM: this file is ignored and will not be submitted" \
  || echo "correct - project/ is committed"

grep -rIlE 'AKIA|aws_secret_access_key|SecretAccessKey' project/ && echo "STOP: secret found" \
  || echo "no secret patterns found"
```

### 15.2 The inventory script

```bash
cat > scripts/utilities/usms-project-inventory.sh << 'EOF'
#!/usr/bin/env bash
# One description of the whole USMS system, across every practical.
# Read-only. Safe to run at any time. Writes nothing except its own stdout.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-*.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

section() { printf '\n== %s ==\n' "$1"; }
count()   { printf '%s' "${1:-0}"; }

printf 'USMS project inventory - %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'account : %s\n' "$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNREACHABLE)"
printf 'endpoint: %s\n' "${FLOCI_ENDPOINT:-unset}"

section "identity (Lab 01)"
aws iam list-roles --query "Roles[?starts_with(RoleName, 'usms-')].RoleName" --output text | tr '\t' '\n'
aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, 'USMS')].PolicyName" --output text | tr '\t' '\n'

section "network (Lab 02)"
aws ec2 describe-vpcs --filters Name=tag:Project,Values=USMS \
  --query 'Vpcs[].[VpcId,CidrBlock]' --output text 2>/dev/null || echo "none"
aws ec2 describe-subnets --filters Name=tag:Project,Values=USMS \
  --query 'length(Subnets)' --output text 2>/dev/null || echo 0

section "compute (Labs 03, 04, 05)"
aws ec2 describe-instances --filters Name=tag:Project,Values=USMS \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>/dev/null || echo "none"
aws ecs list-clusters --query 'clusterArns' --output text 2>/dev/null || echo "none"
aws eks list-clusters --query 'clusters' --output text 2>/dev/null || echo "none"

section "storage and functions (Lab 10)"
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'usms-')].Name" --output text 2>/dev/null
aws lambda list-functions \
  --query "sort_by(Functions[?starts_with(FunctionName, 'usms-')], &FunctionName)[].[FunctionName,Runtime,TracingConfig.Mode]" \
  --output text 2>/dev/null || echo "none"

section "pipeline (Labs 11, 12)"
aws codepipeline list-pipelines --query 'pipelines[].name' --output text 2>/dev/null || echo "none"
aws codebuild list-projects --query 'projects' --output text 2>/dev/null || echo "none"
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null || echo "none"

section "observability (Lab 13)"
aws logs describe-log-groups \
  --query 'logGroups[].[logGroupName,retentionInDays]' --output text 2>/dev/null
aws cloudwatch list-metrics --namespace USMS/Application \
  --query 'Metrics[].MetricName' --output text 2>/dev/null | tr '\t' '\n' | sort -u
aws cloudwatch describe-alarms \
  --query 'MetricAlarms[].[AlarmName,StateValue,TreatMissingData]' --output text 2>/dev/null
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[].AlarmName' --output text 2>/dev/null
aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text 2>/dev/null

section "repository"
printf 'lab documents   : %s\n' "$(ls -d labs/lab-* 2>/dev/null | wc -l | tr -d ' ')"
printf 'env files       : %s\n' "$(ls configs/lab-*.env 2>/dev/null | wc -l | tr -d ' ')"
printf 'verify scripts  : %s\n' "$(ls scripts/utilities/verify-lab-*.sh 2>/dev/null | wc -l | tr -d ' ')"
printf 'cleanup scripts : %s\n' "$(ls scripts/cleanup/lab-*-cleanup.sh 2>/dev/null | wc -l | tr -d ' ')"
printf 'commits         : %s\n' "$(git rev-list --count HEAD 2>/dev/null || echo 0)"
printf 'tracked outputs : %s\n' "$(git ls-files outputs/ | awk '!/(^|\/)\.gitkeep$/ { count++ } END { print count+0 }')"

section "verification"
for v in scripts/utilities/verify-lab-*.sh; do
  [ -x "$v" ] || continue
  printf '%-40s %s\n' "$v" "$("$v" 2>/dev/null | tail -1)"
done
EOF

chmod +x scripts/utilities/usms-project-inventory.sh
bash -n scripts/utilities/usms-project-inventory.sh && echo "syntax OK"

./scripts/utilities/usms-project-inventory.sh | tee project/checkpoint-01/inventory.txt
```

`tracked outputs` must be `0`.


### 15.3 End-to-end demonstration

```bash
{
  printf 'USMS end-to-end demonstration - %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf -- '--- 1. identity: who am I, and what may this role do ---\n'
  ./scripts/utilities/whoami.sh
  aws iam list-attached-role-policies --role-name usms-lambda-exec-role \
    --query 'AttachedPolicies[].PolicyName' --output text

  printf -- '\n--- 2. storage: the bucket four policies have named since Lab 01 ---\n'
  aws s3api head-bucket --bucket usms-student-data && echo "head-bucket: exit 0"

  printf -- '\n--- 3. trigger: what the bucket does when an object arrives ---\n'
  aws s3api get-bucket-notification-configuration --bucket usms-student-data \
    --query 'LambdaFunctionConfigurations[].[Id,LambdaFunctionArn]' --output text

  printf -- '\n--- 4. compute: the function that runs, and the version behind the alias ---\n'
  aws lambda get-function-configuration --function-name usms-transcript-notifier \
    --qualifier live --query '[Version,Runtime,TracingConfig.Mode]' --output text

  printf -- '\n--- 5. the event: upload a transcript ---\n'
  ./scripts/utilities/usms-emit-telemetry.sh science 0.63

  printf -- '\n--- 6. logs: what it said ---\n'
  aws logs filter-log-events --log-group-name /usms/central/application \
    --filter-pattern 'USMS_EVENT' --query 'events[-1].message' --output text

  printf -- '\n--- 7. metrics: what it counted ---\n'
  aws cloudwatch list-metrics --namespace USMS/Application \
    --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u

  printf -- '\n--- 8. alarms: what would page somebody ---\n'
  aws cloudwatch describe-alarms \
    --query 'MetricAlarms[].[AlarmName,StateValue,TreatMissingData]' --output text
  aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
    --query 'CompositeAlarms[].[AlarmName,AlarmRule]' --output text

  printf -- '\n--- 9. the dashboard somebody would look at ---\n'
  aws cloudwatch get-dashboard --dashboard-name usms-overview \
    --query 'DashboardBody' --output text \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["widgets"]), "widgets")'
} | tee project/checkpoint-01/evidence/end-to-end.txt
```


### 15.4 Capture the rest of the evidence

```bash
mkdir -p project/checkpoint-01/evidence

./scripts/utilities/verify-lab-10.sh > project/checkpoint-01/evidence/verify-lab-10.txt 2>&1
./scripts/utilities/verify-lab-13.sh > project/checkpoint-01/evidence/verify-lab-13.txt 2>&1
cp outputs/lab-13-telemetry-inventory.txt project/checkpoint-01/evidence/telemetry-inventory.txt

tail -1 project/checkpoint-01/evidence/verify-lab-10.txt
tail -1 project/checkpoint-01/evidence/verify-lab-13.txt
```

### 15.5 Write `architecture.md`, `gaps.md`, `demo.md`

Drafts for the checkpoint documents. Reconcile the architecture and demo with the captured inventory and verification output during Steps 15.2–15.4.

```bash
cat > project/checkpoint-01/architecture.md << 'EOF'
# USMS Architecture - Checkpoint 1
## Overview

- **Identity (Lab 01).** USMS IAM roles define what the EC2 application, ECS tasks and Lambda functions can do. The observability policy in Lab 13 grants telemetry writes to the application and Lambda execution roles.
- **Network (Lab 02).** The USMS VPC spans public and private subnets. The application load balancer fronts the enrolment service, and the S3 gateway endpoint provides a route to the student-data bucket.
- **Compute (Labs 03–08).** EC2 hosts the original web and database tiers. ECS runs the enrolment service behind the load balancer, with target tracking and queue-depth scaling. EKS provides a separate workload and scaling environment.
- **Storage and functions (Lab 10).** The `usms-student-data` bucket stores transcript objects. Object creation under the transcript prefix targets the Lambda notifier through its stable `live` alias. Viewer-request and origin-response Lambda@Edge functions handle the edge checks and response headers.
- **Delivery (Labs 11–12).** CodePipeline orchestrates the build and deployment stages. CodeBuild builds the application image, ECR stores it and the ECS release records which image digest was deployed.
- **Observability (Lab 13 target).** CloudWatch Logs captures central application, ECS and Lambda events. CloudWatch Metrics holds the custom USMS measurements. The dashboard shows those measurements and the transcript alarms. X-Ray segment documents describe which operations contributed to latency.
## Request path: transcript upload
S3 usms-student-data -> notification -> usms-transcript-notifier:live (v3, Active tracing)
-> USMS_NOTIFY log -> NotifyCount metric -> usms-notify-silence -> composite alarm -> dashboard
## Key design decisions

- Retain central application and enrolment logs for 30 days and Lambda logs for 14 days.
- Use low-cardinality dimensions such as faculty and stage. Publish an undimensioned total and keep identifiers in logs or trace annotations.
- Use `notBreaching` for gaps in latency data and `breaching` for missing notifications where delivery is expected.
- Publish immutable Lambda versions and move the `live` alias for deployment or rollback. Keep the S3 notification pointed at the alias.
EOF

cat > project/checkpoint-01/gaps.md << 'EOF'
# Gaps and next steps
| Gap | Evidence | What I would do next |
|---|---|---|
| No SNS topic; alarms notify nobody | AlarmActions = [] | SNS/SQS lab applies outputs/lab-13-alarm-actions-draft.json |
| S3 configuration lab not delivered | no configs/lab for it | versioning, encryption, bucket policy |
| Logs Insights and X-Ray read probes unsupported | `outputs/lab-13-support-probe.txt` | Use the Path B log query and validate segment JSON locally |
| Metric filter evaluation pending | The probe only confirmed `DescribeMetricFilters` | Deploy the filter, ingest matching events and query the exact metric identity in Step 10 |
EOF

cat > project/checkpoint-01/demo.md << 'EOF'
# 8-minute demonstration
1. (1 min) inventory.txt - what exists
2. (4 min) end-to-end.txt - nine stages, re-run live
3. (2 min) verify-lab-13.sh result and what each FAIL (if any) means
4. (1 min) gaps.md
Add checkpoint screenshots to the evidence directory when captured.
EOF
```

### 15.6 Self-check and commit

```bash
for f in architecture.md gaps.md demo.md inventory.txt; do
  [ -s "project/checkpoint-01/$f" ] && printf '  ✔ %s\n' "$f" || printf '  ✗ %s missing or empty\n' "$f"
done

[ "$(ls project/checkpoint-01/evidence/ 2>/dev/null | wc -l | tr -d ' ')" -ge 4 ] \
  && echo "  ✔ evidence present" || echo "  ✗ fewer than 4 evidence files"

git add project/checkpoint-01 scripts/utilities/usms-project-inventory.sh
git commit -m "Project checkpoint 01: inventory, evidence, architecture, gaps, demo"

git ls-files project/checkpoint-01/ | wc -l
git status --short project/
```


---

## 16. Preparation for the Next Lab

The next (future) lab is an SNS/SQS integration lab. It will consume `USMS_ALARM_*`, the alarm-actions draft, the latency baseline, the `USMS/Application` namespace, the `usms-overview` dashboard, and the notifier alias (v4 with a real `sns.publish`).

**Replace-only APIs to be careful with:** `put-metric-alarm`, `put-composite-alarm`, `put-dashboard`, `put-bucket-notification-configuration`, `put-bucket-policy`, `update-assume-role-policy`, and `update-function-configuration`. For each one, the safe sequence is **describe → merge → put**.

**Pre-session checks:**

```bash
source configs/course.env

./scripts/utilities/verify-lab-10.sh | tail -2          # PASS=51  FAIL=0
./scripts/utilities/verify-lab-13.sh | tail -2          # PASS=49  FAIL=0
grep -c '^export' configs/lab-13.env                    # 28
aws cloudwatch describe-alarms --alarm-names usms-transcript-lag-high \
  --query 'MetricAlarms[0].AlarmActions' --output json  # []
aws lambda get-alias --function-name usms-transcript-notifier --name live \
  --query 'FunctionVersion' --output text               # 3, or higher
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 19-45-35.png>)

**Snapshot:**

```bash
floci snapshot save lab-13-complete
floci snapshot list
```

Fallback if `floci snapshot` is unavailable:

```bash
./scripts/setup/floci-down.sh
tar -czf ~/floci-data-lab-13.tar.gz -C ~ floci-data
./scripts/setup/floci-up.sh
```


**Read ahead:**
- *Topic vs queue.* An SNS topic pushes to many subscribers (fan-out). An SQS queue buffers messages for consumers. They are usually combined as SNS → multiple SQS queues.
- *At-least-once delivery.* The same message can arrive twice, so the notifier must be **idempotent**, for example by de-duplicating on the S3 object key and version or ETag.
- *Dead letter queue (DLQ) monitoring.* Use a **metric** (`ApproximateNumberOfMessagesVisible` on the DLQ) with an alarm at > 0. Missing data should be `notBreaching`, because an empty DLQ with no data is healthy.

---

## 17. Conclusion

The pre-lab checks confirmed Floci was running with hybrid storage and Lab 10 passed all 51 checks. The support probe selected the Logs Insights fallback and local X-Ray document validation. The read-only inventory provides a starting point for setting retention, and Step 8 confirmed that the text pattern `ERROR` can match a successful event when its message mentions the term.

Lab 13 deployment, restart and assessment results are pending. The notifier alias is still on version 1, and the Lab 13 verifier has yet to be created from Step 25a.

**Final verification result:** Pending. The target is `PASS=49 FAIL=0`.

---

## 18. References

1. Amazon Web Services. *What is Amazon CloudWatch Logs?* – Amazon CloudWatch Logs User Guide.
2. Amazon Web Services. *Working with log groups and log streams.*
3. Amazon Web Services. *Filter and pattern syntax – CloudWatch Logs.*
4. Amazon Web Services. *Creating metrics from log events using filters.*
5. Amazon Web Services. *CloudWatch Logs Insights query syntax.*
6. Amazon Web Services. *Publishing custom metrics* – Amazon CloudWatch User Guide.
7. Amazon Web Services. *Using Amazon CloudWatch alarms.*
8. Amazon Web Services. *Configuring how CloudWatch alarms treat missing data.*
9. Amazon Web Services. *Creating a composite alarm.*
10. Amazon Web Services. *Dashboard body structure and syntax.*
11. Amazon Web Services. *What is AWS X-Ray?* – AWS X-Ray Developer Guide.
12. Amazon Web Services. *AWS X-Ray segment documents.*
13. Amazon Web Services. *Using filter expressions – AWS X-Ray.*
14. Amazon Web Services. *Configuring sampling rules – AWS X-Ray.*
15. Amazon Web Services. *Using AWS Lambda with AWS X-Ray.*
16. Amazon Web Services. *Actions, resources, and condition keys for CloudWatch* – Service Authorization Reference.
17. Lepcha, N. T. (2026). *DSO303 Lab 13 – Centralized Logging and Monitoring with CloudWatch and X-Ray.* Course documents: Lab 01, Lab 04, Lab 06, Lab 10, Errata 01.
