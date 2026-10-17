# Lab 06 – Auto Scaling for an ECS-Based Application: Review Questions

> Support path: **B (control plane only)**. Every scaling object was created and read back, but Floci never acted on it, so the scaling behaviour below is reasoned from the configuration, not observed.

## 1. The nine-line chain, which three are this lab's, and why the other six needed no change

1. A student clicks Register.
2. The request reaches `usms-enrolment-alb`, which forwards it to a healthy task in `usms-enrolment-tg`. Thousands of students doing the same push CPU and requests per target up. *(Lab 05)*
3. CloudWatch sees `ECSServiceAverageCPUUtilization` above 50 % for 3 one-minute periods, and the managed `TargetTracking-…-AlarmHigh` alarm goes to ALARM. ***(Lab 06)***
4. The alarm invokes `usms-enrolment-cpu-target-tracking`, which works out how many tasks would bring CPU back to 50 %. ***(Lab 06)***
5. Application Auto Scaling writes that number to the scalable target `service/usms-ecs-cluster/usms-enrolment-svc` (`ecs:service:DesiredCount`), kept within min 2 / max 10, by calling `ecs:UpdateService` through its service-linked role: `desiredCount` 2 → 3. ***(Lab 06)***
6. The ECS service sees desired 3 vs running 2 and launches a task from `usms-enrolment:2`. *(Lab 04)*
7. The task gets its own network interface in a private subnet, with `usms-enrolment-sg`, no public IP, and image pulls through the NAT gateway. *(Labs 02/04)*
8. The ECS service registers its IP in `usms-enrolment-tg`. After 2 health checks and the 60 s grace period it is healthy, and the ALB sends it traffic. *(Lab 05)*
9. Nothing about the blueprint, the service or the load balancer changed.

**This lab's three are lines 3, 4 and 5:** the alarm, the policy and the scalable target. The other six needed no modification because every layer below line 5 only reacts to one number. The ECS service has always reconciled `runningCount` to `desiredCount` without caring *who* set it. Before this lab it was me with `update-service`, and Lab 04 Step 11 already exercised that path. Placement into private subnets, the security group and the target-group registration are properties of the service and task definition, applied to *every* task the service starts, so a task started because of an alarm is placed and registered exactly like one started by hand. The ALB never knew how many tasks to expect; it just follows the target group's membership, which the ECS service maintains. Auto scaling plugs into the one input the existing machinery already had.

**What does auto scaling change about my application?** Nothing in the application itself. It only changes *who* writes one integer, `desiredCount`, and *when*: a metric-driven loop instead of a person.

## 2. What a scalable target's resource ID is, and the other constructed identifiers

A scalable target's resource ID is a **constructed string that names a resource *within* a service namespace**. It is not a globally unique ARN. Ours is `service/usms-ecs-cluster/usms-enrolment-svc`: the resource type, then the cluster, then the service name. Combined with `--service-namespace ecs` and the scalable dimension `ecs:service:DesiredCount`, it identifies *which number on which resource* Application Auto Scaling may change.

**Why it is not an ARN:** Application Auto Scaling is one API in front of many unrelated services (ECS, DynamoDB, Lambda, Aurora, EMR, SageMaker…), and what it scales is often not a whole resource but **a dimension of one**: a table's read capacity vs its write capacity, a table vs one of its indexes, a function alias's provisioned concurrency. Those things have no ARN of their own. A namespace-scoped, path-like ID can name them all in one consistent way, and the account and region are implied by the call.

**How its shape differs:**

| Namespace | Resource ID shape | Example dimension |
|---|---|---|
| `ecs` | `service/<cluster>/<service>` | `ecs:service:DesiredCount` |
| `dynamodb` | `table/<table>` or `table/<table>/index/<index>` | `dynamodb:table:ReadCapacityUnits` |
| `lambda` | `function:<function-name>:<alias-or-version>` | `lambda:function:ProvisionedConcurrency` |

Note that Lambda uses `:` separators rather than `/`, so the shape cannot be guessed from one service and reused for another.

**The other three constructed identifiers in this architecture:**
1. **The `ResourceLabel`** for `ALBRequestCountPerTarget`: `app/usms-enrolment-alb/<alb-id>/targetgroup/usms-enrolment-tg/<tg-id>`. It is built from the *suffixes* of two ARNs, and Step 9 validated it at exactly 6 segments.
2. **The managed alarm names:** `TargetTracking-service/usms-ecs-cluster/usms-enrolment-svc-AlarmHigh-<uuid>` (and `-AlarmLow-`). They are derived from the resource ID, which is how Step 8 found them with `--alarm-name-prefix "TargetTracking-${RID}"`.
3. **The scalable dimension** `ecs:service:DesiredCount`, written as `namespace:resource-type:property`.

The service-linked role name `AWSServiceRoleForApplicationAutoScaling_ECSService` is a fourth fixed, constructed name.

## 3. Registering min=2 against a service running one task

The moment `register-scalable-target --min-capacity 2` is accepted while `desiredCount` is 1, the current value is below the new floor, so **Application Auto Scaling itself immediately raises `desiredCount` to 2** through its service-linked role. The ECS service then does what it always does and starts the missing task. **The object that made the change is the scalable target**, not a policy and not ECS.

That differs from a scaling policy in four ways:
- **No metric, alarm or cooldown is involved.** The clamp happens because of a *configuration* change, not a measurement.
- **It cannot be outvoted.** Policies can only move `desiredCount` within [min, max]; scale-in will never take it below 2 again.
- **It is permanent until someone changes the min**, whereas a policy's decision is re-evaluated every period.
- **It does not look like scaling to anyone reading the ECS service.** `describe-services` just shows a new desired count and a task start. The evidence is in `describe-scalable-targets` (and `describe-scaling-activities` on real AWS).

On Floci (Path B), the min of 5 in Step 6 was stored, but `desiredCount` stayed at 2, so the clamp is control plane only here.

**A 3 am incident:** a bad image is deployed and the tasks crash-loop, flooding the database with failed connection retries. The on-call engineer does the obvious thing, `aws ecs update-service --desired-count 0`, to stop the damage while they roll back. Within seconds the count is back at 2, because the minimum is 2 and Application Auto Scaling restores the floor, relaunching the broken tasks. The engineer's command reports success, the service events show tasks starting, and it looks like ECS is ignoring them. The fix is to either lower the target's min, or suspend scaling (`register-scalable-target --suspended-state` with `DynamicScalingInSuspended` true, as in Step 13), *then* scale to 0. A runbook that only says "set desired count to 0" is wrong once a scalable target exists.

## 4. Managed alarms vs. the alarm I wrote

| | Managed alarms (`TargetTracking-…-AlarmHigh/Low`) | My alarm (`usms-enrolment-queue-high`) |
|---|---|---|
| **Owner** | Application Auto Scaling. Created when the target tracking policy was created | Me. Created with `put-metric-alarm` |
| **If I edit it** | Overwritten the next time the policy is updated | Stays as I set it |
| **Policy changed** | Re-created/updated to match the new target value automatically | Unaffected. Its threshold and period stay whatever I chose, even if no longer sensible |
| **Policy deleted** | Deleted with the policy | **Left behind**, still pointing its `AlarmActions` at a policy ARN that no longer exists (an orphan) |

**What the managed pair can do that mine can't:** they come as a *matched pair*: AlarmHigh (3 × 60 s > 50 %) for scale-out and AlarmLow (15 × 60 s < 50 %) for scale-in. The policy works out the *size* of each change from how far the metric is from the target, so I never pick step sizes or thresholds, and scale-in is built in and deliberately slow.

**What mine can do that theirs can't:** use any metric, including a custom one like `USMS/Enrolment EnrolmentQueueDepth` that no predefined metric covers. I also choose the period, the number of evaluations (1, to react fast) and `treat-missing-data`, and can add extra actions (e.g. an SNS notification to on-call) alongside the step policy.

**Argument for `breaching` over `notBreaching` for the queue alarm.** The lab created it with `--treat-missing-data notBreaching`. The queue-depth metric is published by our own code. If it goes missing, the most likely reasons are that the publisher has crashed or is too overloaded to report, which is exactly the situation where the queue is *growing*. `notBreaching` treats silence as "queue is fine", so the alarm stays OK during the worst moment and the service never scales. `breaching` treats silence as "assume the worst", so missing data adds capacity.
- **The cost is bounded:** at worst the step policy adds +1 or +3 tasks, capped at max 10. That is a few cents an hour ($0.0145656 per task-hour).
- **The alarm also becomes a loud signal** that the metric pipeline is broken, instead of failing quietly.
- **The counter-argument:** extra tasks will not fix a broken publisher, and a metric that is *meant* to be sparse (published only when there is work) would cause false scale-outs.

For a metric that should be reported every minute, failing toward capacity is the safer default.

## 5. Why reactive scaling cannot absorb the first minutes of a spike

The arithmetic, for one new task to start serving traffic:

| Term | Value | Where it is configured |
|---|---|---|
| Alarm period × evaluation periods | 60 s × 3 = **180 s** | Managed AlarmHigh, derived from the target tracking policy. Not editable |
| Policy invocation and `UpdateService` | **~0 s** | Application Auto Scaling. The `ScaleOutCooldown` of 60 s only delays the *next* step |
| Task start (`PENDING` → `RUNNING`) | **20–60 s** on Fargate (~10 s observed on Floci) | Fargate. Depends on image size, pulled via the NAT gateway |
| Health checks / grace period | **60 s** (2 checks × 30 s; grace 60 s) | Target group health check and `healthCheckGracePeriodSeconds` (Lab 05) |
| **Total** | **≈ 260–300 s (4½–5 min)** | |

During those ~5 minutes the **existing tasks carry the whole spike alone**. Enrolment opens at 08:00 and most of the week's traffic arrives in the first 20 minutes, so a purely reactive system is still adding its *first* task at ~08:05, after the period when the service fell over last year (08:03).

**Three consequences:**
1. **The capacity already running must absorb the first minutes**, so headroom has to exist *before* the spike.
2. **A predictable spike has to be scheduled, not detected.**
3. **Capacity must not be removed too eagerly between waves**, or the service has to pay the 5-minute delay again.

**How this lab's five configuration decisions answer them:**
1. **`TargetValue` 50 % CPU, not 80 %** *(consequence 1)*: the 2 running tasks can absorb roughly double their target load while the 5-minute delay runs.
2. **`MinCapacity` 2** *(consequence 1)*: one task per AZ is always running, so there is never a cold start from zero, and the loss of an AZ still leaves capacity.
3. **The step policy on queue depth with 1 evaluation period and a +3 step at ≥ 200** *(consequence 1)*: this cuts the alarm term from 180 s to 60 s and adds three tasks at once for a big backlog instead of one at a time.
4. **The scheduled morning scale-out, `MinCapacity` 4 at 07:45 Asia/Thimphu** *(consequence 2)*: capacity is in place 15 minutes before the doors open. Reacting is too slow by design. This could not be created on Floci.
5. **Asymmetric cooldowns: `ScaleOutCooldown` 60 s vs `ScaleInCooldown` 300 s, plus AlarmLow needing 15 periods** *(consequence 3)*: scale out fast, scale in slowly, so a brief lull between waves does not throw away capacity that would take 5 minutes to get back.

## 6. When the CPU and request-count policies disagree

Both target tracking policies act on the same scalable target, and Application Auto Scaling combines them with one rule:
- **Scale-out:** if *either* policy wants more capacity, the target scales out to the **largest** capacity any policy asks for. If CPU is at 80 % (wants 4 tasks) but requests per target are under 1000 (wants 2), the service goes to 4.
- **Scale-in:** it scales in only if **all** policies agree that scale-in is safe, and only as far as the most conservative one allows. If requests have dropped (wants 2) but CPU is still at 60 % (wants 3), the service stays at 3.

**Why the rule is asymmetric:** the two mistakes do not cost the same. Too few tasks means the 08:03 outage: failed enrolments, the Registrar noticing, and a 5-minute recovery delay. Too many tasks costs a few cents per task-hour for a few extra minutes. So the combined policy is "out on any vote, in only on a unanimous one", erring towards availability. Each policy is effectively a safety net for the other's blind spot: request count catches load that does not show up in CPU, and CPU catches requests that are unusually expensive.

**Two target tracking policies on the same metric are a fault.** With different targets (say CPU 50 % and CPU 70 %), the lower target always wins on scale-out and always blocks scale-in, so the 70 % policy never decides anything. It is dead configuration that misleads whoever reads it, and it adds a duplicate pair of managed alarms. With the *same* target, it is pure duplication.

**A step policy plus a target tracking policy on one metric is worse, because they fight.** The step policy adds capacity based on its own thresholds. The target tracking policy then sees the metric fall below *its* target and scales back in, which raises the metric, which fires the step policy again. The two policies have separate cooldowns that do not coordinate, so the result is oscillation: tasks repeatedly started and drained, each paying the start and drain delays. That is why this lab gives each signal one owner: CPU and request count to target tracking, and the custom queue depth to the step policy.

## 7. `ALBRequestCountPerTarget` vs. CPU

**Three reasons request count is the better signal for a web API:**
1. **It measures demand, not a side effect of it.** Request count rises the moment traffic arrives at the ALB, before tasks are saturated. CPU only rises once work is already queuing on the existing tasks, which makes it a lagging signal for a spike.
2. **It is linear and easy to plan with.** Tasks needed = total requests ÷ target per task (1000 per target in Step 9). CPU percentage has no simple relationship to "how many students can enrol".
3. **It is not affected by the app's own behaviour.** The enrolment API mostly waits on S3, the database and the network (I/O-bound), so it can be overloaded on connections, threads or latency while CPU looks low. CPU is also inflated by things unrelated to users: garbage collection, background jobs, a noisy deployment. The ALB counts only real requests, measured from outside the task.

**The one workload type where CPU is better:** CPU-bound work whose cost per request varies a lot, or that has no load balancer in front of it at all, e.g. a worker that processes report or transcript generation jobs, image or PDF rendering, or batch computation. There, the work done is the CPU used, and request count does not exist or does not reflect load.

**When request count would scale the enrolment app badly:**
- **Requests that are not all equal in cost:** if the traffic mix shifts so that a small number of requests are very expensive (for example "confirm enrolment" running a heavy database transaction or generating a PDF) while most are cheap (module lookups served from cache), a target of 1000 requests per task would be reached with too *few* heavy requests. Tasks would saturate while the policy saw nothing.
- **Inflated counts:** retries or long-polling would push the count up without real load behind it, and the service would scale out for nothing.

**The metric that would reveal this in advance is the ALB's `TargetResponseTime`**, read alongside request count and CPU. If response time and CPU per task climb while requests per target stay flat, the cost per request is changing and request count is no longer a good stand-in for load. That shows up in a load test or a normal busy day long before the next enrolment Monday.
