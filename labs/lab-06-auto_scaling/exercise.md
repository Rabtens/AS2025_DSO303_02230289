## Independent Lab Exercises

All commands run from the repository root with the course env files loaded. The scalable target's identifiers are always discovered, never typed:

```bash
cd ~/aws-floci-course
for f in configs/course.env configs/lab-0{1,2,3,4,5,6}.env; do source "$f"; done
export AWS_PAGER=""

RID=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query "ScalableTargets[?starts_with(ResourceId,'service/usms-')].ResourceId | [0]" --output text)
SDIM=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].ScalableDimension' --output text)
echo "$RID  $SDIM"
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 22-56-59.png>)

> **Baseline before the exercises.** Steps 13 and 16 had not been run yet, so they were run first, exactly as written in the README. One fix was needed in Step 16: `awk -F: '{print \$NF}'` inside `$(...)` passes the backslash through to awk, which left `USMS_SCALABLE_RESOURCE_ID` empty, so the README now uses `'{print $NF}'`.
>
> After that, `verify-lab-06.sh` reports **`PASS=39 FAIL=3`**. The three failures are the scheduled-action checks: this Floci build returns `UnsupportedOperation` for `put-scheduled-action` (Step 11, Path B), and no exercise can change that. So wherever an exercise says "Section 8's script must report FAIL=0", the condition used here is **FAIL=3, the same three scheduled-action checks, nothing new**.

---

### Exercise 1 - Basic: a memory policy, and a scale-out-only policy

```bash
echo "managed alarms before: $(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" --query 'length(MetricAlarms)' --output text)"

cat > templates/lab-06-target-tracking-memory.json << 'EOF'
{
  "TargetValue": 70.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ECSServiceAverageMemoryUtilization"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 600,
  "DisableScaleIn": true
}
EOF
python3 -m json.tool templates/lab-06-target-tracking-memory.json > /dev/null && echo "valid JSON"
grep -c '[$]' templates/lab-06-target-tracking-memory.json
```

The heredoc is **quoted** (`<< 'EOF'`) because the file has no variables. Quoting guarantees the shell substitutes nothing, so what is written is exactly what is on the page.

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-57-48.png>)

```bash
MEM_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --policy-name usms-enrolment-memory-target-tracking \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://templates/lab-06-target-tracking-memory.json \
  --query 'PolicyARN' --output text)
echo "MEM_POLICY_ARN = $MEM_POLICY_ARN"

aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query 'ScalingPolicies[].{Name:PolicyName,Type:PolicyType,Metric:TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType,Target:TargetTrackingScalingPolicyConfiguration.TargetValue,NoScaleIn:TargetTrackingScalingPolicyConfiguration.DisableScaleIn}' \
  --output table

echo "managed alarms after: $(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" --query 'length(MetricAlarms)' --output text)"
aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" --query 'MetricAlarms[].MetricName' --output text | tr '\t' '\n' | sort | uniq -c

aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text
./scripts/utilities/verify-lab-06.sh | tail -1
```

**Observed:**
- **Policies:** three target tracking policies (CPU 50, memory 70, requests 1000) and one step policy on the same target. The memory policy shows `NoScaleIn = True`.
- **Bounds:** unchanged at `2 10`.
- **Verify:** `PASS=39 FAIL=3`, as predicted. The script checks the CPU and request policies, the step policy and the bounds, none of which changed, and it does not count policies, so an extra one cannot fail it.
- **Managed alarms: 6, not the expected 5.** **This is a Floci deviation.** It created an `AlarmLow` for the memory policy as well, two memory alarms in total. Real Application Auto Scaling creates only the high alarm for a policy with `DisableScaleIn: true`.

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-58-37.png>)

**Answers (one sentence each):**

- **Why five and not six?** The memory policy's `AlarmLow` is not created, because with `DisableScaleIn: true` nothing would ever act on "memory is below target"; its absence means this policy can only ever add tasks, never remove them (Floci created it anyway, which is why 6 were observed here).
- **Memory 70 vs CPU 50, which scales out first?** Whichever metric reaches its target first as load rises, and the targets alone cannot tell you that: you would need to know how each metric grows per task with request rate (and memory's idle baseline, since a 1 GB task running nginx may sit far below 70 % no matter the load), which only a load test measures.
- **Does a scale-out-only policy change the other two's scale-in?** No: Step 9's rule says the target scales in only when every policy *that can scale in* agrees, and a `DisableScaleIn` policy is not part of that vote, so CPU and requests still scale in on their own. It can only *add* capacity, which the other two then have to agree to remove.

---

### Exercise 2 - Intermediate: the scale-in half of step scaling, and a fight to avoid

**The step configuration**

```bash
cat > templates/lab-06-step-scaling-in.json << 'EOF'
{
  "AdjustmentType": "ChangeInCapacity",
  "MetricAggregationType": "Average",
  "Cooldown": 300,
  "StepAdjustments": [
    {
      "MetricIntervalLowerBound": -10,
      "MetricIntervalUpperBound": 0,
      "ScalingAdjustment": -1
    },
    {
      "MetricIntervalUpperBound": -10,
      "ScalingAdjustment": -2
    }
  ]
}
EOF
python3 -m json.tool templates/lab-06-step-scaling-in.json > /dev/null && echo "valid JSON"
grep -c '[$]' templates/lab-06-step-scaling-in.json
```

**Signs, and why.** Step bounds are measured relative to the alarm threshold (20): *breach = metric − 20*. A scale-in alarm fires **below** its threshold, so every breach is negative and every bound is **non-positive**. Removing capacity means the adjustments are **negative**.

| Step | Lower bound | Upper bound | Metric range | Adjustment | Meaning |
|---|---|---|---|---|---|
| mild | −10 | **0** | 10 ≤ queue < 20 | **−1** | slightly quiet → remove one task |
| stronger | (none = −∞) | −10 | queue < 10 | **−2** | very quiet → remove two tasks |

**`MetricIntervalUpperBound: 0` with `ScalingAdjustment: -1`** means "from the threshold itself down to the lower bound": any breach between −10 and 0 (queue depth from 10 up to just under 20) removes exactly one task. The upper bound of 0 is the threshold, and nothing above it can match a below-threshold alarm.

**Why the cooldown is 300 s, longer than the scale-out policy's 60 s:** removing capacity is the risky direction. After a scale-in, the remaining tasks absorb the load, and the metric needs several minutes to show whether that was safe. A short cooldown would remove a second and third task before the effect of the first was measured. Scale-out should be fast because under-capacity hurts users; scale-in should be slow because over-capacity only costs a little money. This matches the target tracking policies (out 60 / in 300).

**The step the floor makes unreachable:** with `MinCapacity` 2 and the service at its baseline of 2, 2 + (−2) = 0 < 2, so the **−2 step can never take effect from the baseline**. (−1 is clamped too, since 2 − 1 = 1 < 2.) The −2 step only removes two tasks when desired is 4 or more; at 3 it is clamped to −1.

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-59-13.png>)

**The policy and its only alarm**

```bash
STEP_IN_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --policy-name usms-enrolment-queue-step-in --policy-type StepScaling \
  --step-scaling-policy-configuration file://templates/lab-06-step-scaling-in.json \
  --query 'PolicyARN' --output text)
echo "STEP_IN_ARN = $STEP_IN_ARN"

aws cloudwatch put-metric-alarm \
  --alarm-name usms-enrolment-queue-low \
  --alarm-description "USMS enrolment work queue is nearly empty; invokes the step scale-in policy" \
  --namespace "$USMS_METRIC_NAMESPACE" --metric-name "$USMS_METRIC_NAME" --dimensions Name=Service,Value=enrolment \
  --statistic Average --period 60 --evaluation-periods 3 --threshold 20 \
  --comparison-operator LessThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "$STEP_IN_ARN" \
  --tags Key=Name,Value=usms-enrolment-queue-low Key=Project,Value=USMS Key=Lab,Value=06

aws cloudwatch describe-alarms --alarm-names usms-enrolment-queue-low \
  --query 'MetricAlarms[0].{Op:ComparisonOperator,Thr:Threshold,Period:Period,Evals:EvaluationPeriods,Actions:AlarmActions,State:StateValue}' --output json
```

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-59-43.png>)

**Drive it to 5, force it, and record what happened**

```bash
svc() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" --query 'services[0].[desiredCount,runningCount]' --output text; }
echo "before: $(svc)"
for i in 1 2 3; do aws cloudwatch put-metric-data --namespace "$USMS_METRIC_NAMESPACE" --metric-name "$USMS_METRIC_NAME" --dimensions Service=enrolment --value 5; done
aws cloudwatch describe-alarms --alarm-names usms-enrolment-queue-low --query 'MetricAlarms[0].StateValue' --output text
aws cloudwatch set-alarm-state --alarm-name usms-enrolment-queue-low --state-value ALARM --state-reason "Exercise 2: forcing the low alarm"
for i in 1 2 3 4 5 6; do sleep 5; echo "+$((i*5))s alarm=$(aws cloudwatch describe-alarms --alarm-names usms-enrolment-queue-low --query 'MetricAlarms[0].StateValue' --output text) service=$(svc)"; done
aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$RID"
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-01-21.png>)

**Observed: nothing happened, and it would not have on real AWS either.**
- **The datapoints:** after publishing three datapoints of 5, the alarm stayed `INSUFFICIENT_DATA`, because Floci does not evaluate alarms.
- **The forced alarm:** `set-alarm-state` put it in `ALARM` for 30 s, and the service stayed at `2 2` (desired, running) throughout. `describe-scaling-activities` returned `UnsupportedOperation`.
- **What real AWS would do:** a metric of 5 is a breach of −15, which selects the −2 step. The service would still stay at 2 because of the floor.


**Delete both objects, in the correct order.** The alarm goes first, because its action references the policy. Deleting the policy first would leave an alarm whose `AlarmActions` points at a policy that no longer exists.

> **DANGER - irreversible:** deletes the CloudWatch alarm `usms-enrolment-queue-low`.
> **Scope:** only this Exercise 2 alarm. `usms-enrolment-queue-high` (the KEEP alarm that drives the scale-out step policy) must not be touched.
> **Check first:** the name printed by the first command below must be `usms-enrolment-queue-low`, and its action must end in `policyName/usms-enrolment-queue-step-in`.
> **Impact:** nothing will invoke the step-in policy any more, which is intended because the policy is deleted next.

```bash
aws cloudwatch describe-alarms --alarm-names usms-enrolment-queue-low --query 'MetricAlarms[0].[AlarmName,AlarmActions[0]]' --output text
aws cloudwatch delete-alarms --alarm-names usms-enrolment-queue-low && echo "alarm deleted"
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-01-43.png>)

> **DANGER - irreversible:** deletes the scaling policy `usms-enrolment-queue-step-in`.
> **Scope:** only the Exercise 2 scale-in policy. `usms-enrolment-queue-step-out` and both target tracking policies are in the KEEP column.
> **Order:** run only after the alarm above is gone, so no alarm is left pointing at a deleted policy.
> **Check first:** the `--policy-name` must be exactly `usms-enrolment-queue-step-in`, not `-step-out`.

```bash
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" \
  --scalable-dimension "$SDIM" --policy-name usms-enrolment-queue-step-in && echo "policy deleted"

aws cloudwatch describe-alarms --alarm-names usms-enrolment-queue-low --query 'length(MetricAlarms)' --output text   # 0
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" --query 'ScalingPolicies[].PolicyName' --output text
./scripts/utilities/verify-lab-06.sh | tail -1
```

Observed: alarm count `0`, the step-in policy gone, and `PASS=39 FAIL=3`, the same three scheduled-action checks.

![alt text](<../../screenshots/Screenshot from 2026-10-17 23-02-24.png>)

**A CPU step policy at 60 % alongside the CPU target tracking policy.** Target tracking works out capacity *proportionally*: it sets desired ≈ current × (actual CPU ÷ 50), aiming to *hold* CPU at 50 %. It assumes it is the only thing changing capacity in response to that metric. A step policy with its own 60 % alarm acts on the same metric with its own fixed amounts, so the two fight:
- Above 60 %, target tracking has already asked for the proportional amount, and the step policy adds `+N` on top. The service overshoots, and CPU falls well below 50 %.
- Target tracking then sees CPU under its target and scales in (after its 15-period AlarmLow), which pushes CPU back up past 60 %, and the step alarm fires again.
- The two policies' cooldowns are independent and do not coordinate, so this repeats: tasks are started and drained over and over, and each cycle pays the start and drain delays.

**I would keep the target tracking policy.** It owns the metric, works out the correct size rather than a guessed step, and scales back in by itself. If the concern is that it reacts too slowly, the fix is a lower target value, or a step policy on a *different*, leading signal such as `EnrolmentQueueDepth`, which is exactly how this lab is set up.

---

### Exercise 3 - Problem solving: a scaling report tool

The script is [`scripts/utilities/usms-scaling-report.sh`](../../scripts/utilities/usms-scaling-report.sh). Design:

- **Discovery:**
  - The first call is `describe-scalable-targets` filtered with `starts_with(ResourceId, 'service/usms-')`. That prefix is the only name in the script.
  - After that, **python3** does everything: `describe-services` for desired and running counts, policies, alarms, scheduled actions and the last activity.
- **Alarm lookups:**
  - Target tracking alarms are fetched in one batched `describe-alarms --alarm-names a b c ...`.
  - A step policy's alarm is found by matching the policy ARN in each alarm's `AlarmActions`, because Floci leaves a step policy's `Alarms` list empty.
- **Step adjustments** are printed as a signed list (`+1 / +3`), sorted by lower bound, from the configuration.
- **No crash and no blank row** for:
  - no policies (`policies none`)
  - no scheduled actions (`scheduled none`)
  - a target tracking policy with an empty `Alarms` list (`alarms (none listed)`)
  - unimplemented calls (`none (unsupported on this build)`)
- **`set -uo pipefail` without `-e`:** two of the calls are unimplemented on this build, and the report must still be printed, so each call is checked instead of aborting.
- **Runs from any directory:** it resolves `configs/` from `${BASH_SOURCE[0]}`.
- **JSON copy:** it writes `outputs/lab-06-scaling-report.json`.

**Verdict order (commented in the script):**
1. **PINNED** first: if min equals max, nothing can move, whatever else is true.
2. **FROZEN** next: a suspended target is not reacting at all, so "AT-CEILING" would wrongly suggest the policies pushed it there and are still in control. Suspension is a silent, manual state that has to be seen first; the position against the bounds only means something while scaling is live.
3. **AT-CEILING** before **AT-FLOOR**: at the ceiling, demand may exceed capacity (a risk to users), while at the floor the worst case is a little idle cost.
4. **AT-FLOOR** only with more than one policy: with a single policy, sitting at the minimum is the normal quiet state; with several, it means all of them agree there is no load.
5. **ELASTIC** otherwise.

```bash
chmod +x scripts/utilities/usms-scaling-report.sh
(cd ~ && ~/aws-floci-course/scripts/utilities/usms-scaling-report.sh) > /tmp/sr-home.txt
(cd ~/aws-floci-course/labs/lab-06-auto_scaling && ../../scripts/utilities/usms-scaling-report.sh) > /tmp/sr-lab.txt
cat /tmp/sr-home.txt; diff /tmp/sr-home.txt /tmp/sr-lab.txt && echo "IDENTICAL"
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-02-43.png>)

**After Exercise 1** (memory policy present):

```
service/usms-ecs-cluster/usms-enrolment-svc   ecs:service:DesiredCount
  bounds       min=2  max=10   desired=2   running=2   AT-FLOOR
  suspended    none
  target-track usms-enrolment-cpu-target-tracking       CPU/50.0        out=60  in=300
                 alarms  AlarmHigh=INSUFFICIENT_DATA  AlarmLow=INSUFFICIENT_DATA
  target-track usms-enrolment-memory-target-tracking    Memory/70.0     out=60  in=600  scale-in DISABLED
                 alarms  AlarmHigh=INSUFFICIENT_DATA  AlarmLow=INSUFFICIENT_DATA
  target-track usms-enrolment-requests-target-tracking  ALBReq/1000.0   out=60  in=300
                 alarms  AlarmHigh=INSUFFICIENT_DATA  AlarmLow=INSUFFICIENT_DATA
  step         usms-enrolment-queue-step-out            +1 / +3         cooldown=60
                 alarm   usms-enrolment-queue-high = OK  (USMS/Enrolment EnrolmentQueueDepth >= 100)
  scheduled    none (unsupported on this build)
  last activity  none recorded (unsupported on this build)
```

Identical from `~` and from the lab folder. **The verdict is `AT-FLOOR`, not the `ELASTIC` in the exercise's sample**, because desired (2) equals min (2) and there is more than one policy, which is AT-FLOOR by the exercise's own rule table.


**While suspended, and with min = max = 3** (the target restored to 2/10 and unsuspended afterwards):

```bash
aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --suspended-state file://templates/lab-06-suspended-state.json >/dev/null
./scripts/utilities/usms-scaling-report.sh | sed -n 2,3p
aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --suspended-state DynamicScalingInSuspended=false,DynamicScalingOutSuspended=false,ScheduledScalingSuspended=false >/dev/null

aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --min-capacity 3 --max-capacity 3 >/dev/null
./scripts/utilities/usms-scaling-report.sh | sed -n 2,3p
aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --min-capacity 2 --max-capacity 10 >/dev/null
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-03-08.png>)

```
  bounds       min=2  max=10   desired=2   running=2   FROZEN
  suspended    DynamicScalingIn
...
  bounds       min=3  max=3    desired=2   running=2   PINNED
  suspended    none
```

(With min = max = 3, desired stays 2 because Floci does not clamp it to the new floor, as seen in Step 6.)


**After Exercise 4's tidy-up** the memory policy row is gone, and the rest is unchanged (`AT-FLOOR`, 2 target tracking policies and 1 step policy).

---

### Exercise 4 - Challenge: the enrolment-week capacity plan

*To: the USMS project lead.*

#### 4.1 Is it solved? (three sentences)

Reactive auto scaling is good at following gradual change: the "roughly double for three weeks" part will be absorbed automatically, and capacity will drop back afterwards without anyone remembering to do it. It is bad at sudden steps, because every decision waits for minutes of metric evidence and then for new tasks to start, and it can never go above the ceiling of 10 we set, whatever the demand. The first twenty minutes of a cohort day is exactly that: a sudden step to about forty times normal, which the service would face with 2 tasks for around five minutes and then with at most 10 tasks against a need of about 80, so on its own it is **not** solved.

#### 4.2 Why forty times traffic is not a scaling problem

**Time from 2 tasks to 10, reactive.** At 40× load the request-count policy sees about 20 times its target per task. Target tracking works out capacity proportionally (2 × 20 = 40), so it asks for the maximum of 10 in a single action:

| Term | Value | Source |
|---|---|---|
| AlarmHigh: period × evaluations | 60 s × 3 = 180 s | Step 8's managed alarm |
| Policy invocation, write to `desiredCount` | ~0 s | the 60 s scale-out cooldown only delays a *second* step |
| Fargate task start | 45 s | AWS re:Post: 30–45 s or longer is normal (the measured figure is unavailable; see Exercise 5) |
| Health checks / grace period | 60 s | 2 healthy checks × 30 s; `healthCheckGracePeriodSeconds` 60 (Lab 05) |
| **Total** | **≈ 285 s ≈ 4¾ min** | |

For those ~5 minutes, 2 tasks carry 40× their normal load. Last year's failure was within the first twenty minutes, so this is that same failure.

**What the ceiling of 10 means at Step 9's target.** Capacity (number of tasks) and throughput (requests served) are different things:
- **Throughput at the ceiling:** 10 tasks × 1,000 requests per target per minute = **10,000 requests/minute ≈ 167 requests/second**.
- **Assumed normal traffic:** 2,000 requests/minute, i.e. today's 2 tasks running at Step 9's target. *This is an assumption to replace with analytics' real figure.*
- **At forty times normal:** 80,000 requests/minute (≈ 1,333/s).
- **The gap:** the ceiling caps the service at 1/8 of the demand, so even after scaling finishes it stays overloaded for the whole first hour.

The problem is the **planned capacity**, not how fast scaling reacts. No policy change fixes that; only a higher, scheduled floor and a higher ceiling do.

#### 4.3 The ceiling, checked against Lab 02

AWS reserves **5 addresses in every subnet**: the first four and the last one ([Amazon VPC User Guide, *Subnet CIDR blocks*](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html)).

| Subnet | Size | After AWS reservation | Existing occupants | Usable for tasks |
|---|---|---|---|---|
| `usms-private-subnet-a` 10.0.3.0/24 (us-east-1a) | 256 | 251 | `usms-db-01`, 1 enrolment task | **249** |
| `usms-private-subnet-b` 10.0.4.0/24 (us-east-1b) | 256 | 251 | `usms-db-02` (stopped, but its network interface keeps the address), 1 enrolment task | **249** |

`describe-subnets` shows `AvailableIpAddressCount 251` for both, which confirms the 5-address reservation. Floci does not subtract occupied addresses.

Every task uses one IP address (one network interface each, in `awsvpc` mode). Tasks are spread evenly over the two AZs, and a rolling deployment runs up to **200 %** of the desired count while old and new tasks overlap. N tasks therefore need N addresses *per subnet* at deployment time (2N spread over two subnets):

**The largest supportable ceiling is 249 tasks.** Above that, a deployment at the ceiling runs out of addresses in one of the subnets. The planned ceiling of 100 below is well inside it.

#### 4.4 The capacity plan

**Assumptions for the dates:**
- Enrolment opens **Saturday 14 November 2026**, and the three cohort days are the **14th, 21st and 28th**. *These are assumed; see 4.6.*
- Doors open at **08:00 Asia/Thimphu** (UTC+6, no daylight saving).

| Scheduled action | Schedule | Time zone | Sets | Why |
|---|---|---|---|---|
| `usms-enrolment-window-open` | `at(2026-11-14T00:00:00)` | Asia/Thimphu | min **4**, max **100** | "Double normal" for three weeks = 4 tasks at target. The ceiling is raised for the cohort mornings |
| `usms-enrolment-cohort-morning` | `cron(30 7 14,21,28 11 ? 2026)` | Asia/Thimphu | min **88**, max **100** | 40× normal = 80,000 req/min ÷ 1,000 per task = 80 tasks, + 10 % for task failures and spread = 88. Set at 07:30 so the ~5-minute start-up finishes well before 08:00 |
| `usms-enrolment-cohort-settle` | `cron(30 9 14,21,28 11 ? 2026)` | Asia/Thimphu | min **4**, max **100** | Back to the window floor after the first hour. Target tracking scales in gradually (300 s cooldown) |
| `usms-enrolment-window-close` | `at(2026-12-05T00:00:00)` | Asia/Thimphu | min **2**, max **10** | Three weeks after the 14th, restore the normal bounds |

**Other changes:**
- **Target value:** during the window, lower the request-count target from 1000 to **800** with `put-scaling-policy`, for 20 % headroom against a burst arriving while new tasks start. Restore it to 1000 at `window-close`.
- **The ceiling:** raise max from 10 to **100** only while the window is open, which is well inside the 249-address limit (4.3). Also check the account's Fargate vCPU quota in Service Quotas: 100 tasks × 0.25 vCPU = 25 vCPU.

**Reversible in one command:**
- Each scheduled action: `delete-scheduled-action`.
- The bounds: one `register-scalable-target --min-capacity 2 --max-capacity 10`.
- The target value: one `put-scaling-policy` with the original JSON.

A Fargate quota increase is *not* reversible in one command, but it does not need to be: an unused quota costs nothing.

*This Floci build rejects `put-scheduled-action` (Path B), so these actions are the plan for real AWS, not something created here.*

#### 4.5 Monthly cost estimate

**Prices** (US East, N. Virginia):
- **Fargate:** $0.0404784 per vCPU-hour and $0.004446 per GB-hour (<https://aws.amazon.com/fargate/pricing/>).
- **CloudWatch:** $0.10 per standard alarm per month and $0.30 per custom metric per month, with 10 alarms, 10 custom metrics and 1 million API requests free each month (<https://aws.amazon.com/cloudwatch/pricing/>).

**Task size from `configs/lab-04.env`:** `USMS_ECS_TASK_CPU=256` (0.25 vCPU) and `USMS_ECS_TASK_MEMORY=512` (0.5 GB):
0.25 × $0.0404784 + 0.5 × $0.004446 = **$0.0123426 per task-hour**.

| Item | Derivation | Cost |
|---|---|---|
| Baseline (for reference) | 2 tasks × 730 h × $0.0123426 | $18.02 / month |
| Window floor: 2 extra tasks for 3 weeks | 2 × 21 days × 24 h = 1,008 task-h × $0.0123426 | **$12.44** |
| Cohort mornings: 84 extra tasks (88 − 4) | 84 × 2 h (07:30–09:30) × 3 days = 504 task-h × $0.0123426 | **$6.22** |
| **Additional Fargate for the enrolment month** | | **$18.66** |
| CloudWatch alarms: 4 managed + `usms-enrolment-queue-high` | 5 × $0.10 at list price; $0 within the free 10 | $0.50 (or $0) |
| Custom metric `EnrolmentQueueDepth` | 1 × $0.30 at list price; $0 within the free 10 | $0.30 (or $0) |
| `PutMetricData`, once a minute | 60 × 24 × 30.4 ≈ 43,800 requests, within the free 1 million | $0 |
| **Total additional** | | **≈ $18.66–$19.46 for the month** |

**Assumptions:**
- **Prices:** list prices, no Savings Plans.
- **Peak timing:** cohort peaks last one hour, covered by a 2-hour floor.
- **Normal traffic:** 2,000 requests/minute.
- **The service runs `usms-enrolment:2` at 1 GB** (Lab 04 Exercise 2), not the 0.5 GB in `configs/lab-04.env`. At 1 GB the rate is $0.0145656 per task-hour, and the additional cost is 1,512 task-h × $0.0145656 = **$22.02**.

**For comparison:** running 88 tasks all month to be safe would cost 88 × 730 × $0.0123426 = **$792.89**. The scheduled plan buys the same peak capacity for about 2 % of that.

#### 4.6 What I need from you

1. **The real calendar and traffic numbers:** the three cohort dates and opening time, and analytics' normal requests per minute (not "forty times", but forty times *what*). Every number in 4.4 scales from that one figure.
2. **A measurement nobody has taken:** how many requests per minute one task sustains at an acceptable response time. That requires a load test against one task. The 1,000-per-target value, the 88-task floor and the 249-task address limit only mean something if one task really can serve 1,000 requests a minute.
3. **The database:** confirmation that `usms-db-01` can take 88 tasks' worth of connections and queries. Scaling the API 44× moves the bottleneck to the database, which does not scale with the service. Also, sign-off on the ≈ $19–22 a month and on raising the Fargate vCPU quota if needed.

#### 4.7 The tidy-up

Dependency order:
- The memory policy is a target tracking policy, so its managed alarms are deleted *with* it. Delete the policy and the alarms go too; do not delete them by hand first.
- Exercise 2's objects were already removed (alarm first, then policy, see Exercise 2). The first command below confirms nothing is left.

```bash
echo "leftover from Exercise 2: policy=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" --query "length(ScalingPolicies[?PolicyName=='usms-enrolment-queue-step-in'])" --output text) alarm=$(aws cloudwatch describe-alarms --alarm-names usms-enrolment-queue-low --query 'length(MetricAlarms)' --output text)"
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query "ScalingPolicies[?PolicyName=='usms-enrolment-memory-target-tracking'].[PolicyName,PolicyType,TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType]" --output text
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-03-35.png>)

> **DANGER - irreversible:** deletes the scaling policy `usms-enrolment-memory-target-tracking` **and** its managed `TargetTracking-…` alarms.
> **Scope:** only the Exercise 1 memory policy. `usms-enrolment-cpu-target-tracking`, `usms-enrolment-requests-target-tracking` and `usms-enrolment-queue-step-out` are in the KEEP column.
> **Check first:** the line above must read `usms-enrolment-memory-target-tracking  TargetTrackingScaling  ECSServiceAverageMemoryUtilization`.
> **Impact:** memory no longer triggers scale-out; the CPU and request policies are unaffected.

```bash
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" \
  --scalable-dimension "$SDIM" --policy-name usms-enrolment-memory-target-tracking && echo "memory policy deleted"
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-03-48.png>)

**Confirm**

```bash
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query 'ScalingPolicies[].[PolicyName,PolicyType]' --output text
echo "managed alarms now: $(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" --query 'length(MetricAlarms)' --output text)"
./scripts/utilities/usms-scaling-report.sh
./scripts/utilities/verify-lab-06.sh
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-04-57.png>)

Observed:
- **Policies:** the CPU and request target tracking policies and the step-out policy remain.
- **Managed alarms:** back to **4** (2 CPU, 2 request count).
- **Report:** back to the Lab 06 state.
- **Verify:** `PASS=39 FAIL=3`, only the three scheduled-action checks Floci cannot satisfy.



---

### Exercise 5 - Integration: the hand-off to Lab 10

**The export script** is [`scripts/utilities/usms-scaling-history.sh`](../../scripts/utilities/usms-scaling-history.sh):
- **Discovery:** it finds the `usms-` cluster with `list-clusters`, then its service ARN, and derives `resourceId` from that ARN. It names no policy, alarm or resource ID.
- **Contents:** one JSON document with:
  - the scalable target (bounds and suspension state)
  - every policy with its full configuration
  - every scheduled action
  - every alarm involved (those the policies list, plus any whose `AlarmActions` names a policy ARN)
  - every scaling activity, using `--include-not-scaled-activities`
  - top-level `generated` (a UTC timestamp from python3) and `resourceId` fields
- **Unsupported sections:** an unsupported call is recorded as `{"unsupported": true, "error": ...}` in its section instead of aborting the export.
- **Output:** it validates the file with `python3 -m json.tool` and prints its path and size.

```bash
chmod +x scripts/utilities/usms-scaling-history.sh
(cd ~ && ~/aws-floci-course/scripts/utilities/usms-scaling-history.sh)
./scripts/utilities/usms-scaling-history.sh
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-05-24.png>)

Observed: `outputs/lab-06-scaling-history.json`, **17,045 bytes**, valid JSON, from both directories. It contains `resourceId` `service/usms-ecs-cluster/usms-enrolment-svc`, bounds 2/10, the four policies present at the time (including Exercise 1's memory policy), 7 alarms, and `unsupported` for scheduled actions and scaling activities.

**Scale-out latency** (timestamps from python3):

```bash
ts() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))'; }
cap() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" --query 'services[0].[desiredCount,runningCount]' --output text; }
BEFORE=$(cap); T0=$(ts)
aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --min-capacity 4 --max-capacity 10 >/dev/null
for i in $(seq 1 12); do read -r d r <<< "$(cap)"; echo "poll $i: desired=$d running=$r"; [ "$d" = "$r" ] && [ "$d" -ge 4 ] && break; sleep 5; done
T1=$(ts); AFTER=$(cap)
aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --min-capacity 2 --max-capacity 10 >/dev/null      # floor restored - Section 8 asserts min 2
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-07-01.png>)

**Observed: tasks never started.** Floci stored `MinCapacity 4`, but `desiredCount` stayed 2 for all 12 polls (59.3 s), so there was nothing to time. The floor is restored to 2.

`outputs/lab-06-scale-latency.txt` records both timestamps, both capacities (`2 2` → `2 2`) and the 59.3 s with a note that it is *not* a scale-out time. It then cites the documented figure instead:
- [AWS re:Post](https://repost.aws/questions/QUjZAzJd27SZWxXM7MgyxOZw): a new Fargate task normally takes 30–45 s or longer.
- The [ECS task recommendations](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-recommendations.html): `awsvpc` mode adds ENI attachment latency.

The file uses **45 s**, the top of that range.

**Append to `configs/lab-06.env`, derived rather than typed**

```bash
LAT=$(grep '^latency_seconds_used' outputs/lab-06-scale-latency.txt | awk -F': *' '{print $2}')
OUTLINE=$(./scripts/utilities/usms-scaling-history.sh); HIST="${OUTLINE% * bytes}"; HIST="${HIST#"$PWD"/}"
printf '\n# Lab 06 Exercise 5 - derived, not typed\nexport USMS_SCALING_HISTORY_FILE=%s\nexport USMS_SCALE_LATENCY_SECONDS=%s\n' "$HIST" "$LAT" >> configs/lab-06.env

grep -n 'export .*=$\|=None$' configs/lab-06.env || echo "all values populated"
grep -c '^export' configs/lab-06.env
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-07-21.png>)

Observed: `USMS_SCALING_HISTORY_FILE=outputs/lab-06-scaling-history.json` and `USMS_SCALE_LATENCY_SECONDS=45`, `all values populated`, and export count **24** (Step 16's 22 plus 2).

The path is stored relative to the repository root. The first attempt split the absolute path at the space in the course folder name (`B.E Software…`), which is why it was re-derived with parameter expansion.

**The Lab 10 readiness file** `outputs/lab-06-lab10-readiness.txt`

```bash
POL_ARN=$(aws iam list-attached-role-policies --role-name "$USMS_ECS_TASK_ROLE" \
  --query "AttachedPolicies[?PolicyName=='USMSStudentDataReadWrite'].PolicyArn | [0]" --output text)
VER=$(aws iam get-policy --policy-arn "$POL_ARN" --query 'Policy.DefaultVersionId' --output text)
DOC=$(aws iam get-policy-version --policy-arn "$POL_ARN" --version-id "$VER" --query 'PolicyVersion.Document' --output json)
BUCKET_ARN=$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print([s["Resource"] for s in d["Statement"] if s["Effect"]=="Allow" and not str(s["Resource"]).endswith("/*")][0])' "$DOC")

HB_OUT=$(aws s3api head-bucket --bucket usms-student-data 2>&1) || true
aws s3api head-bucket --bucket usms-student-data > /dev/null 2>&1; HB_RC=$?
# ... each value written to its own labelled line (see the file)
cat outputs/lab-06-lab10-readiness.txt
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 23-07-40.png>)
Contents (abridged):

```
history file          : outputs/lab-06-scaling-history.json (17045 bytes, valid JSON)
scale-out latency     : 45 s (cited Fargate start-up figure; Floci did not start tasks)
task role ARN         : arn:aws:iam::000000000000:role/usms-ecs-task-role
bucket ARN            : arn:aws:s3:::usms-student-data   (the bucket-level Resource; the object-level one is arn:aws:s3:::usms-student-data/*)
permissions           : USMSStudentDataReadWrite lets usms-ecs-task-role list the bucket and read its location (s3:ListBucket,
                        s3:GetBucketLocation on the bucket), read, write and delete objects in it (s3:GetObject, s3:PutObject,
                        s3:DeleteObject on bucket/*), and explicitly denies s3:DeleteBucket.
head-bucket output    : An error occurred (404) when calling the HeadBucket operation: Not Found
head-bucket exit code : 255
after Lab 10 Step 1   : once create-bucket makes usms-student-data exist, head-bucket returns exit code 0, and at that same instant
                        usms-ecs-task-role's unchanged permissions start granting real access - NoSuchBucket becomes success,
                        with no IAM change at all.
```

**Which `Resource` was recorded:** the policy has two, the bucket (`arn:aws:s3:::usms-student-data`, for `ListBucket` and `GetBucketLocation`) and its objects (`arn:aws:s3:::usms-student-data/*`, for `Get`/`Put`/`DeleteObject`). The **bucket-level ARN** is recorded as "the bucket ARN", because that is what `head-bucket` and `create-bucket` act on; the object ARN is listed next to it.

The `head-bucket` failure is captured with `|| true` and its exit code is recorded (**255**), so the script is not aborted.

