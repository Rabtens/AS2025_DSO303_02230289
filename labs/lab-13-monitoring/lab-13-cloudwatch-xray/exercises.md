## Step 8 - Your turn: ERROR pattern
- Pattern `ERROR` matched exactly one of the four Step 7 messages (the transcript.failed line).
- False-positive test: the line `USMS_EVENT {"event":"transcript.processed","reason":"no ERROR here"}`
  matched once on Floci. The text filter counts ERROR anywhere it appears as a term.
  For an alarm I would emit pure JSON with a severity field and use
  `{ $.level = "ERROR" }` to avoid counting messages that only mention the word.
## Step 10 - Your turn: defaultValue
- Comparison pending until both windows have been queried after filter deployment.
- An empty Datapoints array means the queried period has no data point. A Sum of 0 is
  an explicit measurement. With defaultValue=0, compare a period containing only
  nonmatching ingested events with a period containing no ingested events at all.
## Step 13 - Your turn: rollback
- Same alias ARN returned two differently shaped payloads (v1: no trace_id; v2: trace_id + seconds).
- A real rollback of this deployment is one update-alias call and takes effect within seconds, because
  every trigger points at :live. The Lambda@Edge rollback in Lab 10 Step 11 needs the CloudFront
  distribution updated and re-propagated to every edge location, which takes minutes, not seconds.
