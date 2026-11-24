## Review Questions

**Q1. "We have logs, so we do not need metrics."**
First, a metric is cheap to store for a long time and cheap to evaluate continuously. Answering "how many and how fast, every minute" from logs means scanning every event every time, which is slow and billed by volume. Second, alarms evaluate metrics, not raw text. Without a metric, whether published or produced by a filter, there is nothing for an alarm to watch, and absence cannot be detected at all. The colleague is right when the question is rare and needs individual detail. An ad-hoc investigation such as "which student hit this error last Tuesday" is best answered by a retroactive log query, and building a metric for it would be waste.

**Q2. Metric filter vs direct metric.**
- *Retroactivity:* Neither is retroactive. A filter only counts events ingested after it exists, and a direct metric only exists from when the code publishes it. Only an Insights query reaches back in time.
- *Cost:* A filter adds no request cost but depends on paying for log ingestion. A direct metric costs a `PutMetricData` request but needs no log volume.
- *Adding a new measurement:* A filter is a configuration change only. A direct metric needs a code change and a deployment.
- *Code that is not mine:* A filter still works as long as the code logs something recognisable. A direct metric is impossible without changing that code.

For "how many transcript downloads happened" I would use a **filter**, because the download is already logged and counting needs no code change. For "how long the render took" I would use a **direct metric**, because it is a measurement made inside our code at the point of rendering. Publishing it directly avoids depending on a log format and gives correct statistics per observation.

**Q3. Opposite missing-data policies.**
On `usms-transcript-lag-high`, `breaching` would fire every quiet night, because no transcripts means no latency data. On `usms-notify-silence`, `notBreaching` would mean the alarm can never fire when the pipeline stops, because silence is exactly the missing data. Example incident: the S3 notification configuration is overwritten and the notifier is never invoked. `NotifyCount` stops arriving and `usms-notify-silence` fires after 15 minutes. `usms-transcript-lag-high` sees no latency values, treats them as not breaching, and stays OK. During this incident the dashboard would look calm and green: empty graphs, a single-value widget showing 0 or nothing, and no alarm except the absence alarm.

**Q4. Dimension vs annotation.**
A metric dimension is part of the metric's identity. Each distinct value creates a separate billed time series. It is good for graphing and alarming per value, but cost grows linearly with cardinality. An X-Ray annotation is an indexed key on a trace. It is searchable with filter expressions, and many distinct values cost nothing extra per value, but it only describes sampled traces and cannot be graphed or alarmed on directly.
- *Faculty (~8 values):* **dimension** (also fine as an annotation). We want a line per faculty.
- *Student ID (~30,000):* **annotation** (and a log field). As a dimension it would create 30,000 metrics.
- *HTTP status from the origin:* **the `http.response.status` block of the segment**, plus possibly a low-cardinality `StatusClass` dimension (2xx/4xx/5xx) if it needs graphing.
- *Renderer name:* **metadata or an annotation**, with only one or two values. It is only needed when reading a trace, so metadata is enough unless I want to search by renderer.

**Q5. Why a configuration change needs its own version.**
A published version freezes both code **and** configuration. Version 2 was published before `TracingConfig` changed, so version 2 permanently has `PassThrough`. If I had changed the tracing mode and left `live` on version 2, `$LATEST` would trace but the S3 trigger, which invokes `:live`, would still run an untraced configuration. Tracing would silently never happen for real traffic. This is exactly Lab 10 Step 11's claim put into practice: the alias is the deployment, and the deployment includes configuration.

**Q6. What `set-alarm-state` proves.**
It proves that the alarm exists, is addressable by name, can transition, records history, and (for the composite) that the rule references the children. It does **not** prove that the metric, dimensions, unit, statistic and threshold would cause a real transition, because the metric was never evaluated. On real AWS the same test also proves what happens next: the SNS topic has subscribers, the message reaches a phone, the runbook link works, and the auto-scaling action runs. Testing the after-alarm path matters even with a correct threshold, because a correct threshold that notifies nobody is equivalent to no alarm. This is the course's rule applied to monitoring: `put-metric-alarm` succeeding is not evidence that anybody will be told.
