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
