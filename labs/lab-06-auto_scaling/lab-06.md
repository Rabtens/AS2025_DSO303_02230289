# DSO303 — Lab 06: Implementing Auto Scaling for an ECS-Based Application

**Practical 3 — Handing the enrolment service's capacity to Application Auto Scaling**

| | |
|---|---|
| **Student Name** | Kuenzang |
| **Institution** | College of Science and Technology (CST), Bhutan |
| **Course** | DSO303 |
| **Lab** | Lab 06 — Auto Scaling |
| **Date** | *(fill in date)* |
| **Support Path** | Path A / B / C *(circle one — see Step 3)* |

---

## Table of Contents

1. [Lab Overview](#1-lab-overview)
2. [Learning Objectives](#2-learning-objectives)
3. [Prerequisites](#3-prerequisites)
4. [Step 1 — Resume the environment and load six env files](#step-1)
5. [Step 2 — Confirm Labs 02, 03, 04 and 05 are still intact](#step-2)
6. [Step 3 — Probe what this Floci build supports](#step-3)
7. [Step 4 — Create the service-linked role](#step-4)
8. [Step 5 — Register the scalable target](#step-5)
9. [Step 6 — Change the bounds / re-registration](#step-6)
10. [Step 7 — Create the CPU target tracking policy](#step-7)
11. [Step 8 — Read the two managed alarms](#step-8)
12. [Step 9 — Create the request-count policy](#step-9)
13. [Step 10 — Create a step scaling policy + alarm](#step-10)
14. [Step 11 — Create two scheduled actions](#step-11)
15. [Step 12 — Fire the alarm and prove it](#step-12)
16. [Step 13 — Suspend and resume scaling](#step-13)
17. [Step 14 — Prove persistence across a restart](#step-14)
18. [Step 15 — Trace the full request-to-task chain](#step-15)
19. [Step 16 — Write configs/lab-06.env](#step-16)
20. [Step 17 — Commit, and repair two stale strings](#step-17)
21. [Section 9 — Build and run verify-lab-06.sh](#section-9)
22. [Section 9.3 — Build (do NOT run) lab-06-cleanup.sh](#section-93)
23. [Checkpoints Summary](#checkpoints-summary)
24. [Troubleshooting Log](#troubleshooting-log)
25. [Floci vs Real AWS — Observations](#floci-vs-real-aws)
26. [Review Questions](#review-questions)
27. [Conclusion](#conclusion)

---

## 1. Lab Overview

This lab replaces manual capacity management (`aws ecs update-service --desired-count`) with **Application Auto Scaling**, which watches a metric, decides how many tasks `usms-enrolment-svc` needs, and writes `desiredCount` automatically.

> **Key idea:** Application Auto Scaling writes **ONE INTEGER** (`desiredCount`). It does not start tasks, talk to containers, or know anything about the application. Everything after that is machinery already built in Labs 02–05:
>
> ```
> ECS starts a task -> ENI in a Lab 02 subnet
>                   -> registers in Lab 05's target group
>                   -> load balancer health-checks it
>                   -> it receives traffic
> ```

**Time spent:** *(fill in actual hours)*

---

## 2. Learning Objectives

- [ ] Explain what Application Auto Scaling is and the one thing it changes on an ECS service.
- [ ] Distinguish ECS service auto scaling from ECS cluster auto scaling and EC2 Auto Scaling.
- [ ] Construct the three-part address of a scalable target.
- [ ] Register a scalable target with min/max capacity.
- [ ] Explain the service-linked role `AWSServiceRoleForApplicationAutoScaling_ECSService`.
- [ ] Create a target tracking policy and explain `ScaleOutCooldown` / `ScaleInCooldown`.
- [ ] Find and read the two CloudWatch alarms a target tracking policy creates.
- [ ] Explain why `ALBRequestCountPerTarget` beats CPU for a web API, and build its `ResourceLabel`.
- [ ] Create a step scaling policy with multiple step adjustments.
- [ ] Attach a CloudWatch alarm to a scaling policy.
- [ ] Create scheduled scaling actions with a cron expression and time zone.
- [ ] Fire an alarm deliberately and read `describe-scaling-activities`.
- [ ] Suspend/resume dynamic and scheduled scaling independently.
- [ ] Explain why reactive scaling cannot fully absorb a spike.
- [ ] Prove every object survives an emulator restart.

---

## 3. Prerequisites

- [ ] Lab 04 complete — `usms-ecs-cluster`, `usms-enrolment` family, `usms-enrolment-svc`.
- [ ] Lab 05 complete — `verify-lab-05.sh` reports `FAIL=0`.
- [ ] `verify-lab-04.sh` reports `FAIL=0` or exactly the one documented `usms-app-sg` failure.
- [ ] Service at baseline: `desiredCount` 2, one deployment.
- [ ] Errata 01 applied (`echo "$AWS_PROFILE"` prints a value).
- [ ] Floci running under Docker Compose, `FLOCI_STORAGE_MODE=hybrid`.
- [ ] `jq`, `python3`, `docker` available.

### Environment check

```bash
cd ~/aws-floci-course
for t in jq python3 docker; do printf '%-10s ' "$t"; command -v "$t" || echo MISSING; done
aws --version
./scripts/utilities/floci-storage-check.sh
```

> 📸 **Screenshot — Environment check output**
>
> ```
> [paste tool versions + PASS/FAIL output here]
> ```

### Prior-lab measurements

```bash
cat outputs/lab-04-scale-latency.txt 2>/dev/null || echo "not measured - use the cited figure"
cat outputs/lab-05-lab06-readiness.txt 2>/dev/null | grep -i elapsed || true
```

> 📸 **Screenshot — prior measurements**

---

<a name="step-1"></a>
## Step 1 — Resume the environment and load six env files

**Purpose:** Bring Floci up and load configuration from all previous labs.

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env
source configs/lab-05.env

./scripts/utilities/whoami.sh

printf '%-28s %s\n' \
  "cluster"              "$USMS_ECS_CLUSTER" \
  "service"              "$USMS_ENROLMENT_SERVICE" \
  "baseline desired"     "$USMS_ECS_DESIRED_BASELINE" \
  "container"            "$USMS_ENROLMENT_CONTAINER" \
  "task cpu / memory"    "$USMS_ECS_TASK_CPU / $USMS_ECS_TASK_MEMORY" \
  "private subnet a"     "$USMS_PRIVATE_SUBNET_A" \
  "private subnet b"     "$USMS_PRIVATE_SUBNET_B" \
  "load balancer"        "$USMS_ALB_NAME" \
  "load balancer arn"    "$USMS_ALB_ARN" \
  "target group"         "$USMS_TG_NAME" \
  "target group arn"     "$USMS_TG_ARN" \
  "grace period"         "$USMS_SVC_GRACE_PERIOD" \
  "region"               "$AWS_REGION_COURSE" \
  "account"              "$ACCOUNT_ID"
```

**Verify:** Fourteen non-empty values, especially `baseline desired` = 2, `target group arn` non-empty, `grace period` = 60.

> 📸 **Screenshot — Step 1 output (all fourteen values)**

---

<a name="step-2"></a>
## Step 2 — Confirm Labs 02, 03, 04 and 05 are still intact

**Purpose:** Verify the foundation before attaching scaling to it.

```bash
./scripts/utilities/verify-lab-02.sh  | tail -3
./scripts/utilities/verify-lab-03.sh  | tail -3
./scripts/utilities/verify-lab-04.sh | tail -3
./scripts/utilities/verify-lab-05.sh | tee outputs/lab-06-pre-verify-05.txt | tail -3

echo "== the one failure that is allowed, and only this one =="
./scripts/utilities/verify-lab-04.sh | grep FAIL || echo "no failures in 04"
```

> 📸 **Screenshot — verify-lab-02/03/04/05 results**

**Confirm service baseline:**

```bash
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:length(deployments),LBs:length(loadBalancers)}' \
  --output json
```

> 📸 **Screenshot — service baseline JSON (Desired=2, Deployments=1, LBs=1)**

> **Note:** If Desired is not 2, run:
> ```bash
> aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --desired-count 2
> ```

---

<a name="step-3"></a>
## Step 3 — Probe what this Floci build supports

**Purpose:** Determine which Application Auto Scaling / CloudWatch operations are supported before building on top of them.

```bash
probe() {
  printf '%-52s ' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "SUPPORTED"; else echo "not available"; fi
}

echo "== Application Auto Scaling =="
probe "describe-scalable-targets"                 "aws application-autoscaling describe-scalable-targets --service-namespace ecs"
probe "register-scalable-target (skeleton)"       "aws application-autoscaling register-scalable-target --generate-cli-skeleton"
probe "describe-scaling-policies"                 "aws application-autoscaling describe-scaling-policies --service-namespace ecs"
probe "put-scaling-policy (skeleton)"             "aws application-autoscaling put-scaling-policy --generate-cli-skeleton"
probe "describe-scheduled-actions"                "aws application-autoscaling describe-scheduled-actions --service-namespace ecs"
probe "describe-scaling-activities"               "aws application-autoscaling describe-scaling-activities --service-namespace ecs"

echo "== CloudWatch, which is where every decision comes from =="
probe "cloudwatch describe-alarms"                "aws cloudwatch describe-alarms --max-items 1"
probe "cloudwatch put-metric-alarm (skeleton)"    "aws cloudwatch put-metric-alarm --generate-cli-skeleton"
probe "cloudwatch put-metric-data (skeleton)"     "aws cloudwatch put-metric-data --generate-cli-skeleton"
probe "cloudwatch set-alarm-state (skeleton)"     "aws cloudwatch set-alarm-state --generate-cli-skeleton"
probe "cloudwatch list-metrics"                   "aws cloudwatch list-metrics --max-items 1"

echo "== IAM and ECS, already used in Labs 1 to 4B =="
probe "iam create-service-linked-role (skeleton)" "aws iam create-service-linked-role --generate-cli-skeleton"
probe "ecs describe-services"                     "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE"
probe "elbv2 describe-target-groups"              "aws elbv2 describe-target-groups --names $USMS_TG_NAME"
```

> 📸 **Screenshot — probe results**

**Support path determined:** ☐ A (full) ☐ B (control plane only) ☐ C (no Application Auto Scaling)

*(Record which path applies and why in the notes below.)*

```
Notes on support path:
_____________________________________________________________
_____________________________________________________________
```

### Checkpoint 1

- [ ] Floci running under Compose, storage mode hybrid
- [ ] course.env + lab-01..05 sourced
- [ ] verify-lab-02/03/05 all FAIL=0; verify-lab-04 FAIL=0 or the ONE documented failure
- [ ] outputs/lab-06-pre-verify-05.txt captured
- [ ] service at baseline: desired 2, one deployment, one load balancer
- [ ] support path recorded

---

<a name="step-4"></a>
## Step 4 — Create the service-linked role that writes desiredCount

**Purpose:** Application Auto Scaling calls `ecs:UpdateService` on your behalf via a service-linked role.

**Part 1 — create it**

```bash
ASA_SLR="AWSServiceRoleForApplicationAutoScaling_ECSService"

aws iam create-service-linked-role \
  --aws-service-name ecs.application-autoscaling.amazonaws.com \
  --description "Allows Application Auto Scaling to change the desired count of USMS ECS services" \
  --query 'Role.[RoleName,Arn]' \
  --output text \
  || echo "not created - see the note below; this is often already present, and sometimes unsupported"
```

**Part 2 — read it back**

```bash
aws iam get-role --role-name "$ASA_SLR" \
  --query 'Role.{Name:RoleName,Arn:Arn,Path:Path,Trust:AssumeRolePolicyDocument.Statement[0].Principal.Service}' \
  --output json \
  || echo "role not present on this build - record it as a limitation and continue"

aws iam list-attached-role-policies --role-name "$ASA_SLR" \
  --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true
```

> 📸 **Screenshot — service-linked role creation and get-role output**

**What to look for:** Path is `/aws-service-role/ecs.application-autoscaling.amazonaws.com/`, distinct from any role created in Lab 01/04.

---

<a name="step-5"></a>
## Step 5 — Register the scalable target

**Purpose:** Register the object every policy and scheduled action attaches to (floor 2, ceiling 10).

**Part 1 — build the resource ID**

```bash
SVC_ARN=$(aws ecs describe-services \
  --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].serviceArn' --output text)

echo "service arn : $SVC_ARN"

RID="${SVC_ARN##*:}"
echo "resource id : $RID"

SEGMENTS=$(printf '%s' "$RID" | awk -F/ '{print NF}')
FIRST=$(printf '%s' "$RID" | cut -d/ -f1)

if [ "$SEGMENTS" = "3" ] && [ "$FIRST" = "service" ]; then
  echo "OK: 3 segments, first segment 'service'"
else
  echo "UNEXPECTED SHAPE ($SEGMENTS segments, first '$FIRST') - falling back to constructing it"
  RID="service/${USMS_ECS_CLUSTER}/${USMS_ENROLMENT_SERVICE}"
  echo "resource id : $RID"
fi

SDIM="ecs:service:DesiredCount"
```

**Cross-check against Lab 04 (if recorded):**

```bash
echo "derived here  : $RID"
echo "from lab-04  : ${USMS_SCALABLE_RESOURCE_ID:-<not recorded>}"
```

> 📸 **Screenshot — resource ID derivation**

**Part 2 — register it**

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --min-capacity "$USMS_ECS_DESIRED_BASELINE" \
  --max-capacity 10 \
  --tags Project=USMS,Name=usms-enrolment-scalable-target,Tier=app,Lab=06 \
  --query 'ScalableTargetARN' \
  --output text \
  || aws application-autoscaling register-scalable-target \
       --service-namespace ecs \
       --resource-id "$RID" \
       --scalable-dimension "$SDIM" \
       --min-capacity "$USMS_ECS_DESIRED_BASELINE" \
       --max-capacity 10
```

> 📸 **Screenshot — register-scalable-target output (ARN)**

**Verify:**

```bash
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --resource-ids "$RID" \
  --query 'ScalableTargets[0].{Namespace:ServiceNamespace,Resource:ResourceId,Dimension:ScalableDimension,Min:MinCapacity,Max:MaxCapacity,Role:RoleARN,Created:CreationTime,Suspended:SuspendedState}' \
  --output json
```

> 📸 **Screenshot — describe-scalable-targets JSON (Min=2, Max=10, Role filled in)**

**Part 3 — confirm the service wasn't disturbed:**

```bash
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:length(deployments)}' \
  --output json
```

> 📸 **Screenshot — service still at Desired=2**

---

<a name="step-6"></a>
## Step 6 — Change the bounds, and learn what a re-registration is

**Purpose:** There is no `update-scalable-target`; you re-register with new numbers.

**Part 1 — raise the ceiling, then read it back**

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --max-capacity 12 \
  >/dev/null

aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text
```

> 📸 **Screenshot — bounds now 2 / 12 (min unchanged)**

**Part 2 — put it back**

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --min-capacity 2 \
  --max-capacity 10 \
  >/dev/null

aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[].{Resource:ResourceId,Min:MinCapacity,Max:MaxCapacity}' \
  --output table
```

> 📸 **Screenshot — bounds table, exactly one row, Min=2 Max=10**

**Sanity check for duplicate targets:**

```bash
aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query 'length(ScalableTargets)' --output text
```

> 📸 **Screenshot — result is `1`**

### ✏️ Your turn

Predict, then test: re-register with `--min-capacity 5` while running, observe, then restore to 2.

```bash
# prediction (write BEFORE running):
# _______________________________________________

aws application-autoscaling register-scalable-target \
  --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --min-capacity 5 --max-capacity 10 >/dev/null

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text

# restore
aws application-autoscaling register-scalable-target \
  --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --min-capacity 2 --max-capacity 10 >/dev/null
```

> 📸 **Screenshot — desiredCount jump when min raised to 5**

**Notes — answer in your own words:**

```
(a) Which object made the change (scalable target / scaling policy / ECS)?
    _____________________________________________________________

(b) Colleague raises MinCapacity to 5 overnight without telling anyone —
    what is the cost, and which single API call reveals it?
    _____________________________________________________________
```

### Checkpoint 2

- [ ] Scalable target `service/usms-ecs-cluster/usms-enrolment-svc`, dimension `ecs:service:DesiredCount`
- [ ] min 2 / max 10 (raised to 12 and restored)
- [ ] Role filled in automatically
- [ ] Suspended state: all three false
- [ ] No policies attached yet

---

<a name="step-7"></a>
## Step 7 — Create the CPU target tracking policy

**Purpose:** First scaling policy, using `ECSServiceAverageCPUUtilization`.

**Part 1 — write the policy configuration**

```bash
cat > templates/lab-06-target-tracking-cpu.json << 'EOF'
{
  "TargetValue": 50.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300,
  "DisableScaleIn": false
}
EOF

python3 -m json.tool templates/lab-06-target-tracking-cpu.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-06-target-tracking-cpu.json
```

> 📸 **Screenshot — valid JSON, grep count = 0**

**Part 2 — create the policy**

```bash
CPU_POLICY="usms-enrolment-cpu-target-tracking"

CPU_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --policy-name "$CPU_POLICY" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://templates/lab-06-target-tracking-cpu.json \
  --query 'PolicyARN' \
  --output text)

echo "CPU_POLICY_ARN = $CPU_POLICY_ARN"
```

> 📸 **Screenshot — CPU_POLICY_ARN output**

**Verify:**

```bash
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id "$RID" \
  --policy-names "$CPU_POLICY" \
  --query 'ScalingPolicies[0].{Name:PolicyName,Type:PolicyType,Metric:TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType,Target:TargetTrackingScalingPolicyConfiguration.TargetValue,Out:TargetTrackingScalingPolicyConfiguration.ScaleOutCooldown,In:TargetTrackingScalingPolicyConfiguration.ScaleInCooldown,NoScaleIn:TargetTrackingScalingPolicyConfiguration.DisableScaleIn,Alarms:Alarms[].AlarmName}' \
  --output json
```

> 📸 **Screenshot — describe-scaling-policies JSON showing the two managed Alarms**

---

<a name="step-8"></a>
## Step 8 — Read the two alarms that target tracking created for you

**Purpose:** Locate and understand the AWS-managed alarms so you never delete them by accident.

**Part 1 — find them**

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "TargetTracking-${RID}" \
  --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,Namespace:Namespace,Stat:Statistic,Period:Period,Evals:EvaluationPeriods,Op:ComparisonOperator,Threshold:Threshold,Actions:length(AlarmActions),State:StateValue}' \
  --output json
```

> 📸 **Screenshot — two managed alarms (AlarmHigh / AlarmLow)**

**Confirm alarm actions point to the policy:**

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "TargetTracking-${RID}" \
  --query 'MetricAlarms[].AlarmActions[]' --output text | tr '\t' '\n'
```

> 📸 **Screenshot — both actions match $CPU_POLICY_ARN**

**Part 2 — prove the naming is derivable**

```bash
echo "resource id            : $RID"
echo "managed alarm prefix   : TargetTracking-$RID"
aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" \
  --query 'length(MetricAlarms)' --output text
```

> 📸 **Screenshot — count = 2**

### ✏️ Your turn

Work out, from the alarm output above, how long the service would run at 100% CPU before a third task started serving traffic (four delay terms).

```
Term 1 (alarm period × evaluations): _______
Term 2 (policy invocation, ~0s):     _______
Term 3 (Lab 04 Exercise 5 measurement): _______
Term 4 (Lab 05 grace period):        _______
TOTAL:                               _______

Which ONE term would you change first, and what would it cost?
_____________________________________________________________
```

---

<a name="step-9"></a>
## Step 9 — Create the request-count policy

**Purpose:** Build the `ALBRequestCountPerTarget` policy that Lab 05 unlocked.

**Part 1 — get / derive the ResourceLabel**

```bash
if [ -n "${USMS_ALB_RESOURCE_LABEL:-}" ]; then
  RESOURCE_LABEL="$USMS_ALB_RESOURCE_LABEL"
  echo "using the label Lab 05 Exercise 5 recorded"
else
  echo "no recorded label - deriving it from the API"
  ALB_ARN_NOW=$(aws elbv2 describe-load-balancers --names "$USMS_ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  TG_ARN_NOW=$(aws elbv2 describe-target-groups --names "$USMS_TG_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)

  ALB_SUFFIX="${ALB_ARN_NOW#*:loadbalancer/}"
  TG_SUFFIX="${TG_ARN_NOW##*:}"

  RESOURCE_LABEL="${ALB_SUFFIX}/${TG_SUFFIX}"
fi

echo "RESOURCE_LABEL = $RESOURCE_LABEL"

printf '%s' "$RESOURCE_LABEL" | awk -F/ '{
  printf "segments=%d first=%s fourth=%s\n", NF, $1, $4
  if (NF==6 && $1=="app" && $4=="targetgroup") print "OK"; else print "UNEXPECTED SHAPE"
}'
```

> 📸 **Screenshot — RESOURCE_LABEL derivation and validation (OK)**

**Part 2 — the policy configuration**

```bash
cat > templates/lab-06-target-tracking-requests.json << EOF
{
  "TargetValue": 1000.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ALBRequestCountPerTarget",
    "ResourceLabel": "$RESOURCE_LABEL"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300,
  "DisableScaleIn": false
}
EOF

python3 -m json.tool templates/lab-06-target-tracking-requests.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-06-target-tracking-requests.json
grep ResourceLabel templates/lab-06-target-tracking-requests.json
```

> 📸 **Screenshot — valid JSON, grep count = 0, ResourceLabel line printed**

**Part 3 — create it**

```bash
REQ_POLICY="usms-enrolment-requests-target-tracking"

REQ_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --policy-name "$REQ_POLICY" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://templates/lab-06-target-tracking-requests.json \
  --query 'PolicyARN' \
  --output text) \
  && echo "REQ_POLICY_ARN = $REQ_POLICY_ARN" \
  || echo "ALBRequestCountPerTarget not supported on this build - record it and continue; Step 10 does not depend on it"
```

> 📸 **Screenshot — REQ_POLICY_ARN output (or documented limitation)**

**Verify:**

```bash
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs --resource-id "$RID" \
  --query 'ScalingPolicies[].{Name:PolicyName,Type:PolicyType,Metric:TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType,Target:TargetTrackingScalingPolicyConfiguration.TargetValue,Alarms:length(Alarms)}' \
  --output table
```

> 📸 **Screenshot — table with both target tracking policies**

### Checkpoint 3

- [ ] Two target tracking policies (CPU @ 50.0, requests @ 1000.0)
- [ ] Each reports 2 managed alarms (4 total)
- [ ] ResourceLabel validated at 6 segments

---

<a name="step-10"></a>
## Step 10 — Create a step scaling policy, and the alarm that drives it

**Purpose:** Build the piecewise response target tracking cannot express, using a custom queue-depth metric.

**Part 1 — publish the metric**

```bash
METRIC_NS="USMS/Enrolment"
METRIC_NAME="EnrolmentQueueDepth"
METRIC_DIM="Service=enrolment"

for v in 3 5 4; do
  aws cloudwatch put-metric-data \
    --namespace "$METRIC_NS" \
    --metric-name "$METRIC_NAME" \
    --value "$v" \
    --unit Count \
    --dimensions "$METRIC_DIM"
done

aws cloudwatch list-metrics --namespace "$METRIC_NS" \
  --query 'Metrics[].{Name:MetricName,Dimensions:Dimensions[].[Name,Value]}' \
  --output json
```

> 📸 **Screenshot — custom metric published and listed**

**Part 2 — the step configuration**

```bash
cat > templates/lab-06-step-scaling-out.json << 'EOF'
{
  "AdjustmentType": "ChangeInCapacity",
  "MetricAggregationType": "Average",
  "Cooldown": 60,
  "StepAdjustments": [
    {
      "MetricIntervalLowerBound": 0,
      "MetricIntervalUpperBound": 100,
      "ScalingAdjustment": 1
    },
    {
      "MetricIntervalLowerBound": 100,
      "ScalingAdjustment": 3
    }
  ]
}
EOF

python3 -m json.tool templates/lab-06-step-scaling-out.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-06-step-scaling-out.json
```

> 📸 **Screenshot — valid JSON, grep count = 0**

**Part 3 — create the policy, then the alarm**

```bash
STEP_POLICY="usms-enrolment-queue-step-out"

STEP_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --policy-name "$STEP_POLICY" \
  --policy-type StepScaling \
  --step-scaling-policy-configuration file://templates/lab-06-step-scaling-out.json \
  --query 'PolicyARN' \
  --output text)

echo "STEP_POLICY_ARN = $STEP_POLICY_ARN"

QUEUE_ALARM="usms-enrolment-queue-high"

aws cloudwatch put-metric-alarm \
  --alarm-name "$QUEUE_ALARM" \
  --alarm-description "USMS enrolment work queue is backing up; invokes the step scaling policy" \
  --namespace "$METRIC_NS" \
  --metric-name "$METRIC_NAME" \
  --dimensions Name=Service,Value=enrolment \
  --statistic Average \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 100 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$STEP_POLICY_ARN" \
  --tags Key=Name,Value=usms-enrolment-queue-high Key=Project,Value=USMS Key=Lab,Value=06

aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
  --query 'MetricAlarms[0].{Name:AlarmName,Namespace:Namespace,Metric:MetricName,Stat:Statistic,Period:Period,Evals:EvaluationPeriods,Op:ComparisonOperator,Threshold:Threshold,Missing:TreatMissingData,Actions:AlarmActions,State:StateValue}' \
  --output json
```

> 📸 **Screenshot — STEP_POLICY_ARN + alarm details JSON**

**Verify:**

```bash
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs --resource-id "$RID" --policy-names "$STEP_POLICY" \
  --query 'ScalingPolicies[0].{Name:PolicyName,Type:PolicyType,Adjust:StepScalingPolicyConfiguration.AdjustmentType,Agg:StepScalingPolicyConfiguration.MetricAggregationType,Cooldown:StepScalingPolicyConfiguration.Cooldown,Steps:StepScalingPolicyConfiguration.StepAdjustments,Alarms:Alarms[].AlarmName}' \
  --output json
```

> 📸 **Screenshot — step policy JSON, Alarms shows usms-enrolment-queue-high**

---

<a name="step-11"></a>
## Step 11 — Create two scheduled actions

**Purpose:** Add anticipatory capacity for enrolment mornings (Asia/Thimphu time zone).

**Part 1 — morning scale-out**

```bash
SCHED_OUT="usms-enrolment-morning-scale-out"

aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --scheduled-action-name "$SCHED_OUT" \
  --schedule "cron(45 7 ? * MON-FRI *)" \
  --timezone "Asia/Thimphu" \
  --scalable-target-action MinCapacity=4,MaxCapacity=10 \
  && echo "created $SCHED_OUT" \
  || echo "--timezone may be unsupported on this build; retrying in UTC below"
```

**UTC fallback (only if the above failed):**

```bash
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --scheduled-action-name "$SCHED_OUT" \
  --schedule "cron(45 1 ? * MON-FRI *)" \
  --scalable-target-action MinCapacity=4,MaxCapacity=10 \
  && echo "created $SCHED_OUT in UTC - record that you did the conversion by hand"
```

> 📸 **Screenshot — morning scheduled action created**

**Part 2 — evening scale-in**

```bash
SCHED_IN="usms-enrolment-evening-scale-in"

aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --scheduled-action-name "$SCHED_IN" \
  --schedule "cron(0 20 ? * MON-FRI *)" \
  --timezone "Asia/Thimphu" \
  --scalable-target-action MinCapacity=2,MaxCapacity=10 \
  || aws application-autoscaling put-scheduled-action \
       --service-namespace ecs \
       --resource-id "$RID" \
       --scalable-dimension "$SDIM" \
       --scheduled-action-name "$SCHED_IN" \
       --schedule "cron(0 14 ? * MON-FRI *)" \
       --scalable-target-action MinCapacity=2,MaxCapacity=10
```

> 📸 **Screenshot — evening scheduled action created**

**Verify:**

```bash
aws application-autoscaling describe-scheduled-actions \
  --service-namespace ecs \
  --resource-id "$RID" \
  --query 'ScheduledActions[].{Name:ScheduledActionName,Schedule:Schedule,TZ:Timezone,Min:ScalableTargetAction.MinCapacity,Max:ScalableTargetAction.MaxCapacity,Created:CreationTime}' \
  --output table
```

> 📸 **Screenshot — table with both scheduled actions**

### ✏️ Your turn — one-off scheduled action

```bash
python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%S'))"
```

```bash
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --scheduled-action-name usms-enrolment-results-night \
  --schedule "at(PASTE_TIMESTAMP_HERE)" \
  --timezone "Asia/Thimphu" \
  --scalable-target-action MinCapacity=6,MaxCapacity=10
```

> 📸 **Screenshot — three scheduled actions listed**

**Clean up the one-off action (read the danger note in the lab doc first):**

```bash
aws application-autoscaling delete-scheduled-action \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --scheduled-action-name usms-enrolment-results-night

aws application-autoscaling register-scalable-target \
  --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" \
  --min-capacity 2 --max-capacity 10 >/dev/null

aws application-autoscaling describe-scheduled-actions --service-namespace ecs --resource-id "$RID" \
  --query 'length(ScheduledActions)' --output text
aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text
```

> 📸 **Screenshot — back to 2 scheduled actions, bounds 2/10**

**Notes:**

```
An at() action does not remove itself after firing. What is left behind, why does
it matter six months later, and which command belongs in the same runbook page?
_____________________________________________________________
```

### Checkpoint 4

- [ ] Scale-out step policy with 2 adjustments, open-ended top interval
- [ ] Queue-high alarm invokes the step policy
- [ ] Two scheduled actions with correct min values and Asia/Thimphu time zone

---

<a name="step-12"></a>
## Step 12 — Fire the alarm, and prove that something other than you moved the number

**Purpose:** Prove the control loop actually changes `desiredCount`.

**Part 1 — record the truth before**

```bash
python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" \
  > outputs/lab-06-pre-scale.txt

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text \
  >> outputs/lab-06-pre-scale.txt

aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs --resource-id "$RID" \
  --query 'length(ScalingActivities)' --output text \
  >> outputs/lab-06-pre-scale.txt

cat outputs/lab-06-pre-scale.txt
```

> 📸 **Screenshot — pre-scale.txt content**

**Part 2 — push the metric past the threshold**

```bash
for i in 1 2 3; do
  aws cloudwatch put-metric-data \
    --namespace "$METRIC_NS" \
    --metric-name "$METRIC_NAME" \
    --value 260 \
    --unit Count \
    --dimensions "$METRIC_DIM"
  sleep 5
done

START=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
END=$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")

aws cloudwatch get-metric-statistics \
  --namespace "$METRIC_NS" \
  --metric-name "$METRIC_NAME" \
  --dimensions Name=Service,Value=enrolment \
  --start-time "$START" --end-time "$END" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table
```

**Poll the alarm:**

```bash
for i in $(seq 1 8); do
  read -r state reason <<< "$(aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
    --query 'MetricAlarms[0].[StateValue,StateReason]' --output text)"
  printf 'poll %d  state=%-18s %s\n' "$i" "$state" "$reason"
  [ "$state" = "ALARM" ] && break
  sleep 15
done
```

> 📸 **Screenshot — metric datapoints table + alarm state polling**

**Part 3 — force the alarm if it doesn't fire naturally**

```bash
aws cloudwatch set-alarm-state \
  --alarm-name "$QUEUE_ALARM" \
  --state-value ALARM \
  --state-reason "Lab 06 Step 12: forcing the alarm state to prove the alarm-to-policy link" \
  && echo "alarm state forced to ALARM" \
  || echo "set-alarm-state not supported on this build - go to part 5"
```

> 📸 **Screenshot — alarm forced to ALARM**

**Part 4 — read back the number and the record**

```bash
for i in $(seq 1 10); do
  read -r d r p <<< "$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
    --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text)"
  printf 'poll %2d  desired=%s running=%s pending=%s\n' "$i" "$d" "$r" "$p"
  [ "$d" != "2" ] && break
  sleep 10
done

echo
echo "== who moved it? =="
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id "$RID" \
  --max-items 5 \
  --query 'ScalingActivities[].{Start:StartTime,Status:StatusCode,Cause:Cause,Detail:StatusMessage,Description:Description}' \
  --output json
```

> 📸 **Screenshot — desiredCount change poll + Cause string (THE key evidence)**

**Part 5 — fallback proof (if desiredCount did not move)**

```bash
{
  echo "== 1. The alarm, and what it watches =="
  aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
    --query 'MetricAlarms[0].[AlarmName,Namespace,MetricName,ComparisonOperator,Threshold,StateValue]' \
    --output text

  echo
  echo "== 2. What the alarm invokes =="
  aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
    --query 'MetricAlarms[0].AlarmActions[]' --output text

  echo
  echo "== 3. That ARN belongs to this policy, on this target =="
  aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs --resource-id "$RID" --policy-names "$STEP_POLICY" \
    --query 'ScalingPolicies[0].[PolicyName,PolicyARN,ResourceId,ScalableDimension]' --output text

  echo
  echo "== 4. The step the breach of 160 would select =="
  python3 - << 'PY'
import json
cfg = json.load(open('templates/lab-06-step-scaling-out.json'))
breach = 260 - 100
for s in cfg['StepAdjustments']:
    lo = s.get('MetricIntervalLowerBound')
    hi = s.get('MetricIntervalUpperBound')
    lo_ok = lo is None or breach >= lo
    hi_ok = hi is None or breach < hi
    if lo_ok and hi_ok:
        print(f"breach {breach} selects ScalingAdjustment {s['ScalingAdjustment']:+d}")
PY

  echo
  echo "== 5. The bounds that would clamp the result =="
  aws application-autoscaling describe-scalable-targets \
    --service-namespace ecs --resource-ids "$RID" \
    --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text

  echo
  echo "== 6. The current desired count =="
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].desiredCount' --output text
} | tee outputs/lab-06-scaling-proof.txt
```

> 📸 **Screenshot — six-block fallback proof chain (if applicable)**

**Part 6 — return to the baseline**

```bash
aws cloudwatch set-alarm-state --alarm-name "$QUEUE_ALARM" --state-value OK \
  --state-reason "Lab 06 Step 12 complete" 2>/dev/null || true

for v in 4 3 2; do
  aws cloudwatch put-metric-data --namespace "$METRIC_NS" --metric-name "$METRIC_NAME" \
    --value "$v" --unit Count --dimensions "$METRIC_DIM"
done

aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 2 \
  --query 'service.desiredCount' --output text

python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" \
  > outputs/lab-06-post-scale.txt
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text \
  >> outputs/lab-06-post-scale.txt

paste outputs/lab-06-pre-scale.txt outputs/lab-06-post-scale.txt
```

> 📸 **Screenshot — back to baseline, pre/post comparison**

### Checkpoint 5

- [ ] Breach of 160 selects the +3 step (or fallback chain fully documented)
- [ ] Cause string names both alarm and policy (or six-block proof recorded)
- [ ] desiredCount restored to 2, metric pushed down first

---

<a name="step-13"></a>
## Step 13 — Suspend and resume scaling

**Purpose:** Exercise the three independent suspension switches.

**Part 1 — suspend scale-in only**

```bash
cat > templates/lab-06-suspended-state.json << 'EOF'
{
  "DynamicScalingInSuspended": true,
  "DynamicScalingOutSuspended": false,
  "ScheduledScalingSuspended": false
}
EOF

python3 -m json.tool templates/lab-06-suspended-state.json > /dev/null && echo "valid JSON"

aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --suspended-state file://templates/lab-06-suspended-state.json \
  >/dev/null

aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].{Min:MinCapacity,Max:MaxCapacity,Suspended:SuspendedState}' \
  --output json
```

> 📸 **Screenshot — SuspendedState with DynamicScalingInSuspended=true**

**Part 2 — observe policies are untouched**

```bash
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs --resource-id "$RID" \
  --query 'ScalingPolicies[].[PolicyName,PolicyType]' --output text

aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" \
  --query 'length(MetricAlarms)' --output text
```

> 📸 **Screenshot — all policies and alarms still present**

**Part 3 — resume, and prove it**

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --suspended-state DynamicScalingInSuspended=false,DynamicScalingOutSuspended=false,ScheduledScalingSuspended=false \
  >/dev/null

aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].SuspendedState' --output json

aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].SuspendedState.*' --output text | grep -ci true
```

> 📸 **Screenshot — SuspendedState all false, grep -ci true returns 0**

### Checkpoint 6

- [ ] Suspension exercised via `register-scalable-target --suspended-state`
- [ ] All policies/alarms unchanged while suspended
- [ ] Resumed, `grep -ci true` returns 0

---

<a name="step-14"></a>
## Step 14 — Prove the whole scaling configuration survives a restart

**Purpose:** Confirm every object (scalable target, 3 policies, 2 scheduled actions, 1 custom alarm) persists across a Floci restart.

**Part 1 — record the truth**

```bash
{
  aws application-autoscaling describe-scalable-targets \
    --service-namespace ecs --resource-ids "$RID" \
    --query 'ScalableTargets[0].[ServiceNamespace,ResourceId,ScalableDimension,MinCapacity,MaxCapacity]' \
    --output text
  aws application-autoscaling describe-scalable-targets \
    --service-namespace ecs --resource-ids "$RID" \
    --query 'ScalableTargets[0].SuspendedState.*' --output text
  aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs --resource-id "$RID" \
    --query 'sort_by(ScalingPolicies,&PolicyName)[].[PolicyName,PolicyType]' --output text
  aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs --resource-id "$RID" --policy-names "$CPU_POLICY" \
    --query 'ScalingPolicies[0].TargetTrackingScalingPolicyConfiguration.[TargetValue,ScaleOutCooldown,ScaleInCooldown,DisableScaleIn,PredefinedMetricSpecification.PredefinedMetricType]' \
    --output text
  aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs --resource-id "$RID" --policy-names "$STEP_POLICY" \
    --query 'ScalingPolicies[0].StepScalingPolicyConfiguration.[AdjustmentType,MetricAggregationType,Cooldown,length(StepAdjustments)]' \
    --output text
  aws application-autoscaling describe-scheduled-actions \
    --service-namespace ecs --resource-id "$RID" \
    --query 'sort_by(ScheduledActions,&ScheduledActionName)[].[ScheduledActionName,Schedule,ScalableTargetAction.MinCapacity,ScalableTargetAction.MaxCapacity]' \
    --output text
  aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
    --query 'MetricAlarms[0].[AlarmName,Namespace,MetricName,Threshold,ComparisonOperator,EvaluationPeriods,TreatMissingData,length(AlarmActions)]' \
    --output text
} > outputs/lab-06-pre-restart.txt

cat outputs/lab-06-pre-restart.txt
```

> 📸 **Screenshot — pre-restart.txt content**

**Part 2 — perturb**

```bash
./scripts/setup/floci-down.sh
sleep 3
./scripts/setup/floci-up.sh
sleep 5
source configs/course.env
source configs/lab-04.env
source configs/lab-05.env
```

> 📸 **Screenshot — restart sequence output**

**Part 3 — read it back, deriving everything again**

```bash
SVC_ARN=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].serviceArn' --output text)
RID=$(printf '%s' "${SVC_ARN##*:}")
SDIM=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query "ScalableTargets[?ResourceId=='$RID'].ScalableDimension | [0]" --output text)
CPU_POLICY=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --query "ScalingPolicies[?contains(PolicyName, 'cpu-target-tracking')].PolicyName | [0]" --output text)
STEP_POLICY=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --query "ScalingPolicies[?PolicyType=='StepScaling'].PolicyName | [0]" --output text)
QUEUE_ALARM=$(aws cloudwatch describe-alarms --alarm-name-prefix usms-enrolment-queue \
  --query 'MetricAlarms[0].AlarmName' --output text)

echo "re-derived:"
printf '  %-16s %s\n' \
  "resource id" "$RID" \
  "dimension"   "$SDIM" \
  "cpu policy"  "$CPU_POLICY" \
  "step policy" "$STEP_POLICY" \
  "queue alarm" "$QUEUE_ALARM"

{
  aws application-autoscaling describe-scalable-targets \
    --service-namespace ecs --resource-ids "$RID" \
    --query 'ScalableTargets[0].[ServiceNamespace,ResourceId,ScalableDimension,MinCapacity,MaxCapacity]' \
    --output text
  aws application-autoscaling describe-scalable-targets \
    --service-namespace ecs --resource-ids "$RID" \
    --query 'ScalableTargets[0].SuspendedState.*' --output text
  aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs --resource-id "$RID" \
    --query 'sort_by(ScalingPolicies,&PolicyName)[].[PolicyName,PolicyType]' --output text
  aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs --resource-id "$RID" --policy-names "$CPU_POLICY" \
    --query 'ScalingPolicies[0].TargetTrackingScalingPolicyConfiguration.[TargetValue,ScaleOutCooldown,ScaleInCooldown,DisableScaleIn,PredefinedMetricSpecification.PredefinedMetricType]' \
    --output text
  aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs --resource-id "$RID" --policy-names "$STEP_POLICY" \
    --query 'ScalingPolicies[0].StepScalingPolicyConfiguration.[AdjustmentType,MetricAggregationType,Cooldown,length(StepAdjustments)]' \
    --output text
  aws application-autoscaling describe-scheduled-actions \
    --service-namespace ecs --resource-id "$RID" \
    --query 'sort_by(ScheduledActions,&ScheduledActionName)[].[ScheduledActionName,Schedule,ScalableTargetAction.MinCapacity,ScalableTargetAction.MaxCapacity]' \
    --output text
  aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
    --query 'MetricAlarms[0].[AlarmName,Namespace,MetricName,Threshold,ComparisonOperator,EvaluationPeriods,TreatMissingData,length(AlarmActions)]' \
    --output text
} > outputs/lab-06-post-restart.txt

diff outputs/lab-06-pre-restart.txt outputs/lab-06-post-restart.txt \
  && echo "PERSISTENCE PROVEN: the scalable target with its bounds and its three suspension switches, all three scaling policies with their full configurations, both scheduled actions with their schedules and bounds, and the custom alarm with its threshold, its missing-data treatment and its one action are all unchanged" \
  || echo "PERSISTENCE FAILED: read the diff above, then run ./scripts/utilities/floci-storage-check.sh"
```

> 📸 **Screenshot — re-derived identifiers + "PERSISTENCE PROVEN" line**

### Checkpoint 7

- [ ] Every identifier re-derived from the API (not from shell variables)
- [ ] `diff` empty — PERSISTENCE PROVEN

---

<a name="step-15"></a>
## Step 15 — Close the loop: from one request to one new task

**Purpose:** Trace the complete chain and confirm this lab changed only the control loop.

```bash
echo "== 1. The metric that would start it =="
aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" \
  --query 'MetricAlarms[?contains(AlarmName, `AlarmHigh`)].[Namespace,MetricName,Threshold,ComparisonOperator]' \
  --output text
aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
  --query 'MetricAlarms[0].[Namespace,MetricName,Threshold,ComparisonOperator]' --output text

echo
echo "== 2. The policies those alarms invoke =="
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query 'ScalingPolicies[].[PolicyName,PolicyType]' --output text

echo
echo "== 3. The one integer they write, and its bounds =="
aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].[ResourceId,ScalableDimension,MinCapacity,MaxCapacity]' --output text

echo
echo "== 4. The service that reads it, and how long a new task takes to count =="
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[serviceName,desiredCount,runningCount,taskDefinition,healthCheckGracePeriodSeconds]' \
  --output text

echo
echo "== 5. Where a new task appears =="
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.[subnets,securityGroups,assignPublicIp]' \
  --output text

echo
echo "== 6. Who registers it as a target, and where =="
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].loadBalancers[0].[targetGroupArn,containerName,containerPort]' --output text
aws elbv2 describe-target-health --target-group-arn "$USMS_TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State]' --output text

echo
echo "== 7. And what this lab actually changed about any of that =="
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[taskDefinition,length(loadBalancers),length(deployments)]' --output text
```

> 📸 **Screenshot — all seven blocks**

**Nine-line chain (write in your own words):**

```
1. A student clicks Register.
2. _____________________________________________________________
3. _____________________________________________________________
4. _____________________________________________________________
5. _____________________________________________________________
6. _____________________________________________________________
7. _____________________________________________________________
8. _____________________________________________________________
9. Nothing about the blueprint, the service or the load balancer changed.
```

---

<a name="step-16"></a>
## Step 16 — Write configs/lab-06.env

**Purpose:** Persist every derived identifier for future labs.

```bash
cat > configs/lab-06.env << EOF
# Lab 06 - ECS service auto scaling outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs, ARNs and numbers only. NO SECRETS. Safe to commit.

export USMS_SCALABLE_NAMESPACE=ecs
export USMS_SCALABLE_RESOURCE_ID=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].serviceArn' --output text | awk -F: '{print \$NF}')
export USMS_SCALABLE_DIMENSION=ecs:service:DesiredCount
export USMS_SCALE_MIN=$(aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --query 'ScalableTargets[0].MinCapacity' --output text)
export USMS_SCALE_MAX=$(aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --query 'ScalableTargets[0].MaxCapacity' --output text)

export USMS_POLICY_CPU_TT=usms-enrolment-cpu-target-tracking
export USMS_POLICY_CPU_TT_ARN=$(aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs --policy-names usms-enrolment-cpu-target-tracking \
  --query 'ScalingPolicies[0].PolicyARN' --output text | grep -E '^arn:' || echo not-created)
export USMS_SCALE_TARGET_CPU=50
export USMS_POLICY_REQ_TT=usms-enrolment-requests-target-tracking
export USMS_POLICY_REQ_TT_ARN=$(aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs --policy-names usms-enrolment-requests-target-tracking \
  --query 'ScalingPolicies[0].PolicyARN' --output text | grep -E '^arn:' || echo not-created)
export USMS_SCALE_TARGET_REQUESTS=1000
export USMS_POLICY_STEP_OUT=usms-enrolment-queue-step-out
export USMS_POLICY_STEP_OUT_ARN=$(aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs --policy-names usms-enrolment-queue-step-out \
  --query 'ScalingPolicies[0].PolicyARN' --output text | grep -E '^arn:' || echo not-created)

export USMS_SCALE_OUT_COOLDOWN=60
export USMS_SCALE_IN_COOLDOWN=300

export USMS_ALARM_QUEUE_HIGH=usms-enrolment-queue-high
export USMS_METRIC_NAMESPACE=USMS/Enrolment
export USMS_METRIC_NAME=EnrolmentQueueDepth
export USMS_METRIC_DIMENSION=Service=enrolment

export USMS_SCHEDULED_OUT=usms-enrolment-morning-scale-out
export USMS_SCHEDULED_IN=usms-enrolment-evening-scale-in

export USMS_ASA_SLR=AWSServiceRoleForApplicationAutoScaling_ECSService
EOF

grep -n 'export .*=$\|=None$' configs/lab-06.env || echo "all values populated"
```

> 📸 **Screenshot — "all values populated"**

**Verify:**

```bash
source configs/lab-06.env

printf '%-30s %s\n' \
  "resource id"        "$USMS_SCALABLE_RESOURCE_ID" \
  "dimension"          "$USMS_SCALABLE_DIMENSION" \
  "bounds"             "$USMS_SCALE_MIN .. $USMS_SCALE_MAX" \
  "cpu policy"         "$USMS_POLICY_CPU_TT" \
  "cpu policy arn"     "$USMS_POLICY_CPU_TT_ARN" \
  "requests policy"    "$USMS_POLICY_REQ_TT" \
  "requests policy arn" "$USMS_POLICY_REQ_TT_ARN" \
  "step policy"        "$USMS_POLICY_STEP_OUT" \
  "alarm"              "$USMS_ALARM_QUEUE_HIGH" \
  "custom metric"      "$USMS_METRIC_NAMESPACE / $USMS_METRIC_NAME" \
  "scheduled out / in" "$USMS_SCHEDULED_OUT / $USMS_SCHEDULED_IN" \
  "service-linked role" "$USMS_ASA_SLR"

grep -c '^export' configs/lab-06.env

echo "-- the resource id must match what the API says, right now --"
aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query 'ScalableTargets[0].ResourceId' --output text
```

> 📸 **Screenshot — twelve populated lines, export count = 22, matching resource ID**

---

<a name="step-17"></a>
## Step 17 — Commit, and repair two stale strings

**Purpose:** Fix the Lab 04/05 cleanup-script hints, then commit everything.

**Part 1 — repair the hint strings**

```bash
grep -n 'lab-04-cleanup.sh' scripts/cleanup/lab-04-cleanup.sh scripts/cleanup/lab-05-cleanup.sh \
  || echo "nothing to repair - your copies already say lab-06-cleanup.sh"
```

```bash
for f in scripts/cleanup/lab-04-cleanup.sh scripts/cleanup/lab-05-cleanup.sh; do
  cp "$f" "$f.bak-$(date +%Y%m%d%H%M%S)"
  python3 - "$f" << 'PY'
import sys
p = sys.argv[1]
s = open(p).read()
n = s.count('lab-04-cleanup.sh')
s = s.replace('lab-04-cleanup.sh', 'lab-06-cleanup.sh')
open(p, 'w').write(s)
print(f"{p}: {n} occurrence(s) updated")
PY
  bash -n "$f" && echo "  $f still parses"
done

grep -n 'lab-06-cleanup.sh' scripts/cleanup/lab-04-cleanup.sh scripts/cleanup/lab-05-cleanup.sh
```

> 📸 **Screenshot — repair output**

**Part 2 — look before you add**

```bash
git status --short

git check-ignore -v outputs/lab-06-scaling-proof.txt
git ls-files outputs/
```

> 📸 **Screenshot — git status, check-ignore rule and line number**

**Part 3 — commit**

```bash
git add labs/lab-06-ecs-autoscaling/ \
        configs/lab-06.env \
        templates/lab-06-target-tracking-cpu.json \
        templates/lab-06-target-tracking-requests.json \
        templates/lab-06-step-scaling-out.json \
        templates/lab-06-suspended-state.json \
        scripts/utilities/verify-lab-06.sh \
        scripts/cleanup/lab-06-cleanup.sh \
        scripts/cleanup/lab-04-cleanup.sh \
        scripts/cleanup/lab-05-cleanup.sh

git status --short

git commit -m "Lab 06: auto scaling for usms-enrolment-svc - scalable target, two target tracking policies, a step policy with its alarm, and two scheduled actions

Also corrects the cleanup-order hint in the Lab 04 and 05 cleanup scripts, which
named lab-04-cleanup.sh; this lab ships lab-06-cleanup.sh."

git log --oneline -7
```

> 📸 **Screenshot — commit output and git log**

### Checkpoint 8

- [ ] `configs/lab-06.env` committed, 22 exports, fully populated
- [ ] Templates committed
- [ ] Cleanup-script hints repaired, backed up, still parse
- [ ] Nothing under `outputs/` staged
- [ ] git log shows Labs 01–06 commits

---

<a name="section-9"></a>
## Section 9 — Build and run verify-lab-06.sh

**Purpose:** A read-only script that asserts all 42 checks pass.

```bash
cat > scripts/utilities/verify-lab-06.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 06 artefact exists and is configured correctly.
# Read-only: this script inspects and changes nothing. Safe to run at any time.
# Exit 0 if every check passes, 1 otherwise.
#
# EXPECTED: PASS=42  FAIL=0
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-06.env" 2>/dev/null || true

: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECS_DESIRED_BASELINE:=2}"
: "${USMS_TG_NAME:=usms-enrolment-tg}"
: "${USMS_SCALABLE_DIMENSION:=ecs:service:DesiredCount}"
: "${USMS_POLICY_CPU_TT:=usms-enrolment-cpu-target-tracking}"
: "${USMS_POLICY_REQ_TT:=usms-enrolment-requests-target-tracking}"
: "${USMS_POLICY_STEP_OUT:=usms-enrolment-queue-step-out}"
: "${USMS_ALARM_QUEUE_HIGH:=usms-enrolment-queue-high}"
: "${USMS_METRIC_NAMESPACE:=USMS/Enrolment}"
: "${USMS_METRIC_NAME:=EnrolmentQueueDepth}"
: "${USMS_SCHEDULED_OUT:=usms-enrolment-morning-scale-out}"
: "${USMS_SCHEDULED_IN:=usms-enrolment-evening-scale-in}"
: "${USMS_SCALE_MIN:=2}"
: "${USMS_SCALE_MAX:=10}"

RID="${USMS_SCALABLE_RESOURCE_ID:-}"
if [ -z "$RID" ] || [ "$RID" = "None" ]; then
  SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
              --services "$USMS_ENROLMENT_SERVICE" \
              --query 'services[0].serviceArn' --output text 2>/dev/null || echo "")
  RID="${SVC_ARN##*:}"
fi
[ -n "$RID" ] || RID="service/${USMS_ECS_CLUSTER}/${USMS_ENROLMENT_SERVICE}"
EXPECTED_RID="service/${USMS_ECS_CLUSTER}/${USMS_ENROLMENT_SERVICE}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

tgt()  { aws application-autoscaling describe-scalable-targets --service-namespace ecs \
           --resource-ids "$RID" --query "ScalableTargets[0].$1" --output text; }
pol()  { aws application-autoscaling describe-scaling-policies --service-namespace ecs \
           --resource-id "$RID" --policy-names "$1" --query "ScalingPolicies[0].$2" --output text; }
sch()  { aws application-autoscaling describe-scheduled-actions --service-namespace ecs \
           --resource-id "$RID" --scheduled-action-names "$1" \
           --query "ScheduledActions[0].$2" --output text; }
svcq() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
           --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }
alm()  { aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" \
           --query "MetricAlarms[0].$1" --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 02 to 05 dependencies =="
check "usms-private-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"
check "usms-private-subnet-b exists" "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_B"
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svcq status)\" = ACTIVE"
check "service still has exactly ONE loadBalancers entry" \
  "test \"\$(svcq 'length(loadBalancers)')\" = 1"
check "target group $USMS_TG_NAME still has target type ip" \
  "test \"\$(aws elbv2 describe-target-groups --names $USMS_TG_NAME --query 'TargetGroups[0].TargetType' --output text)\" = ip"

echo "== Lab 06 scalable target =="
check "exactly ONE scalable target in the ecs namespace" \
  "test \"\$(aws application-autoscaling describe-scalable-targets --service-namespace ecs --query 'length(ScalableTargets)' --output text)\" = 1"
check "the resource ID is $EXPECTED_RID" "test \"\$(tgt ResourceId)\" = \"$EXPECTED_RID\""
check "the scalable dimension is ecs:service:DesiredCount" \
  "test \"\$(tgt ScalableDimension)\" = ecs:service:DesiredCount"
check "MinCapacity is the Lab 04 baseline of $USMS_ECS_DESIRED_BASELINE" \
  "test \"\$(tgt MinCapacity)\" = $USMS_ECS_DESIRED_BASELINE"
check "MaxCapacity is 10" "test \"\$(tgt MaxCapacity)\" = 10"
check "NO suspension switch was left true" \
  "test \"\$(tgt 'SuspendedState.*' | grep -ci true)\" = 0"

echo "== Lab 06 scaling policies =="
check "CPU target tracking policy $USMS_POLICY_CPU_TT exists" \
  "pol $USMS_POLICY_CPU_TT PolicyName | grep -qx $USMS_POLICY_CPU_TT"
check "its policy type is TargetTrackingScaling" \
  "test \"\$(pol $USMS_POLICY_CPU_TT PolicyType)\" = TargetTrackingScaling"
check "its predefined metric is ECSServiceAverageCPUUtilization" \
  "test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType')\" = ECSServiceAverageCPUUtilization"
check "its target value is 50" \
  "test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.TargetValue' | cut -d. -f1)\" = 50"
check "scale-out cooldown 60 and scale-in cooldown 300 (deliberately asymmetric)" \
  "test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.ScaleOutCooldown')\" = 60 && test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.ScaleInCooldown')\" = 300"
check "step scaling policy $USMS_POLICY_STEP_OUT exists with type StepScaling" \
  "test \"\$(pol $USMS_POLICY_STEP_OUT PolicyType)\" = StepScaling"
check "the step policy has 2+ adjustments and an OPEN-ENDED top interval" \
  "test \"\$(pol $USMS_POLICY_STEP_OUT 'length(StepScalingPolicyConfiguration.StepAdjustments)')\" -ge 2 && test \"\$(pol $USMS_POLICY_STEP_OUT 'StepScalingPolicyConfiguration.StepAdjustments[-1].MetricIntervalUpperBound')\" = None"

echo "== Lab 06 alarms =="
check "custom alarm $USMS_ALARM_QUEUE_HIGH exists" "alm AlarmName | grep -qx $USMS_ALARM_QUEUE_HIGH"
check "it watches $USMS_METRIC_NAMESPACE $USMS_METRIC_NAME" \
  "test \"\$(alm Namespace)\" = '$USMS_METRIC_NAMESPACE' && test \"\$(alm MetricName)\" = '$USMS_METRIC_NAME'"
check "it INVOKES the step policy (the link you made yourself)" \
  "alm 'AlarmActions[]' | grep -q 'policyName/$USMS_POLICY_STEP_OUT'"
check "target tracking created 2+ managed alarms for you" \
  "test \"\$(aws cloudwatch describe-alarms --alarm-name-prefix 'TargetTracking-$RID' --query 'length(MetricAlarms)' --output text)\" -ge 2"

echo "== Lab 06 scheduled actions =="
check "morning action $USMS_SCHEDULED_OUT exists" \
  "sch $USMS_SCHEDULED_OUT ScheduledActionName | grep -qx $USMS_SCHEDULED_OUT"
check "evening action $USMS_SCHEDULED_IN exists" \
  "sch $USMS_SCHEDULED_IN ScheduledActionName | grep -qx $USMS_SCHEDULED_IN"
check "the morning action raises the floor ABOVE the evening action's" \
  "test \"\$(sch $USMS_SCHEDULED_OUT 'ScalableTargetAction.MinCapacity')\" -gt \"\$(sch $USMS_SCHEDULED_IN 'ScalableTargetAction.MinCapacity')\""

echo "== Lab 06 service state =="
check "desiredCount is INSIDE the scalable target's bounds" \
  "test \"\$(svcq desiredCount)\" -ge \"\$(tgt MinCapacity)\" && test \"\$(svcq desiredCount)\" -le \"\$(tgt MaxCapacity)\""
check "desiredCount is back at the baseline of $USMS_ECS_DESIRED_BASELINE" \
  "test \"\$(svcq desiredCount)\" = $USMS_ECS_DESIRED_BASELINE"
check "exactly ONE deployment (nothing stuck mid-roll)" \
  "test \"\$(svcq 'length(deployments)')\" = 1"

echo "== Lab 06 custom metric =="
check "the $USMS_METRIC_NAMESPACE namespace has at least one metric" \
  "test \"\$(aws cloudwatch list-metrics --namespace '$USMS_METRIC_NAMESPACE' --query 'length(Metrics)' --output text)\" -ge 1"

echo "== Files and Git hygiene =="
check "configs/lab-06.env exists" "test -f configs/lab-06.env"
check "configs/lab-06.env has no empty values and no None" \
  "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-06.env"
check "target tracking (cpu) document is valid JSON" \
  "python3 -m json.tool templates/lab-06-target-tracking-cpu.json"
check "target tracking (requests) document is valid JSON, or absent" \
  "! test -f templates/lab-06-target-tracking-requests.json || python3 -m json.tool templates/lab-06-target-tracking-requests.json"
check "step scaling document is valid JSON" \
  "python3 -m json.tool templates/lab-06-step-scaling-out.json"
check "suspended-state document is valid JSON and does NOT suspend scale-out" \
  "python3 -c \"import json,sys;d=json.load(open('templates/lab-06-suspended-state.json'));sys.exit(0 if d.get('DynamicScalingOutSuspended') is False else 1)\""
check "no Lab 06 document contains an unexpanded variable" \
  "! grep -l '[\$]' templates/lab-06-*.json"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"

if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:
  ./scripts/utilities/floci-storage-check.sh

A failure under "== Lab 02 to 05 dependencies ==" means an earlier lab's resource is
gone or has been changed. Run verify-lab-04.sh and verify-lab-05.sh before re-reading
anything here.

Two failures are worth reading twice because they are silent in production:
  "NO suspension switch was left true"  -- a suspended target does not scale and does
                                           not say so. Step 13 part 3 clears it.
  "desiredCount is back at the baseline" -- a Step 11 or Step 12 experiment was not
                                           undone. Push the metric down FIRST, then set
                                           the count; see Step 12 part 6.
REMEDY
fi

[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-06.sh
bash -n scripts/utilities/verify-lab-06.sh && echo "syntax OK"
./scripts/utilities/verify-lab-06.sh
```

> 📸 **Screenshot — full verify-lab-06.sh run, ending in `PASS=42  FAIL=0`**

**Result:** `PASS=____  FAIL=____`

**Benign failures observed (if any) and their explanation:**

```
_____________________________________________________________
_____________________________________________________________
```

---

<a name="section-93"></a>
## Section 9.3 — Build (do NOT run) lab-06-cleanup.sh

> ⚠️ **DO NOT RUN THIS SCRIPT DURING THE LAB.** It is built and syntax-checked only, for use at the end of the course, in the order: `lab-06-cleanup.sh` → `lab-05-cleanup.sh` → `lab-04-cleanup.sh` → `lab-03-cleanup.sh` → `lab-02-cleanup.sh`.

```bash
cat > scripts/cleanup/lab-06-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes Lab 06, dependencies first.
# Order: scheduled actions -> scaling policies -> the custom alarm -> deregister the target.
# Run FIRST of the 04 cleanups: lab-05-cleanup.sh and lab-04-cleanup.sh both REFUSE
# while a scalable target still exists for this service.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"
source "$REPO_ROOT/configs/lab-06.env"

cat <<'WARN'
============================================================
  This deletes the USMS enrolment service's SCALING only:
    - both scheduled actions
    - all three scaling policies, and with them the four
      CloudWatch alarms target tracking created for you
    - the custom alarm usms-enrolment-queue-high
    - the scalable target registration

  It does NOT touch the ECS service, the task definition,
  the cluster, the load balancer or the target group.

  Run FIRST of the 04 cleanups, then lab-05, then lab-04.
============================================================
WARN

read -r -p 'Type exactly: DELETE USMS SCALING  > ' answer
[ "$answer" = "DELETE USMS SCALING" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

NS="$USMS_SCALABLE_NAMESPACE"
RID="$USMS_SCALABLE_RESOURCE_ID"
DIM="$USMS_SCALABLE_DIMENSION"

say "scheduled actions first"
for a in "$USMS_SCHEDULED_OUT" "$USMS_SCHEDULED_IN"; do
  aws application-autoscaling delete-scheduled-action \
    --service-namespace "$NS" --resource-id "$RID" --scalable-dimension "$DIM" \
    --scheduled-action-name "$a" >/dev/null 2>&1 \
    && echo "   deleted $a" || echo "   $a already gone"
done

say "any OTHER scheduled action left behind"
for a in $(aws application-autoscaling describe-scheduled-actions \
             --service-namespace "$NS" --resource-id "$RID" \
             --query 'ScheduledActions[].ScheduledActionName' --output text 2>/dev/null || true); do
  aws application-autoscaling delete-scheduled-action \
    --service-namespace "$NS" --resource-id "$RID" --scalable-dimension "$DIM" \
    --scheduled-action-name "$a" >/dev/null 2>&1 && echo "   deleted $a" || true
done

say "scaling policies"
for p in $(aws application-autoscaling describe-scaling-policies \
             --service-namespace "$NS" --resource-id "$RID" \
             --query 'ScalingPolicies[].PolicyName' --output text 2>/dev/null || true); do
  aws application-autoscaling delete-scaling-policy \
    --service-namespace "$NS" --resource-id "$RID" --scalable-dimension "$DIM" \
    --policy-name "$p" >/dev/null 2>&1 \
    && echo "   deleted $p" || echo "   $p already gone"
done

say "the alarm YOU wrote"
aws cloudwatch delete-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" >/dev/null 2>&1 \
  && echo "   deleted $USMS_ALARM_QUEUE_HIGH" || echo "   already gone"

say "any managed alarm left behind"
LEFT=$(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-$RID" \
         --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null || true)
if [ -n "$LEFT" ] && [ "$LEFT" != "None" ]; then
  aws cloudwatch delete-alarms --alarm-names $LEFT >/dev/null 2>&1 \
    && echo "   deleted orphaned managed alarms" || true
else
  echo "   none left"
fi

say "deregister the scalable target LAST"
aws application-autoscaling deregister-scalable-target \
  --service-namespace "$NS" --resource-id "$RID" --scalable-dimension "$DIM" >/dev/null 2>&1 \
  && echo "   deregistered $RID" || echo "   already deregistered"

echo
echo "Lab 06 teardown complete. scripts/cleanup/lab-05-cleanup.sh may now run."
EOF

chmod +x scripts/cleanup/lab-06-cleanup.sh
bash -n scripts/cleanup/lab-06-cleanup.sh && echo "syntax OK - do NOT run it"
```

> 📸 **Screenshot — "syntax OK - do NOT run it"**

---

## Checkpoints Summary

| # | After Step | Status |
|---|---|---|
| 1 | Step 3 | ☐ |
| 2 | Step 6 | ☐ |
| 3 | Step 9 | ☐ |
| 4 | Step 11 | ☐ |
| 5 | Step 12 | ☐ |
| 6 | Step 13 | ☐ |
| 7 | Step 14 | ☐ |
| 8 | Step 17 | ☐ |

---

## Troubleshooting Log

*(Record any errors encountered and how you fixed them, e.g. `ValidationException`, `ObjectNotFoundException`, credential issues, etc.)*

| Issue | Cause | Fix |
|---|---|---|
| | | |
| | | |

---

## Floci vs Real AWS — Observations

*(Note which parts of the lab worked end-to-end (Path A), which were control-plane only (Path B), and which Floci limitations you personally hit — e.g. managed alarms not created, `describe-scaling-activities` empty, `set-alarm-state` unsupported, `--timezone` rejected, etc.)*

```
_____________________________________________________________
_____________________________________________________________
_____________________________________________________________
```

---

## Review Questions

**1.** Write out the nine-line chain from Step 15, name which three are this lab's, and explain why the other six needed no modification. Finish with one sentence answering "what does auto scaling change about my application?"

```
_____________________________________________________________
```

**2.** Explain what a scalable target's resource ID actually is, why it's a constructed string rather than an ARN, and how its shape differs across `ecs`, `dynamodb`, and `lambda`. Name the other three constructed identifiers in this architecture.

```
_____________________________________________________________
```

**3.** Explain what happens when registering a target with min=2 against a service running one task. Which object made the change, and how does that differ from a scaling policy doing it? Describe a 3am incident where this matters.

```
_____________________________________________________________
```

**4.** Compare the two managed alarms vs. the one you wrote yourself — ownership, what happens on policy change/deletion, and what one type can do that the other can't. Argue for `breaching` over `notBreaching` for the queue alarm.

```
_____________________________________________________________
```

**5.** Reconstruct the §4.3 arithmetic for why reactive scaling cannot absorb the first minutes of a spike. Name every delay term and where it's configured, then connect the three consequences to this lab's five configuration decisions.

```
_____________________________________________________________
```

**6.** Explain what happens when the CPU and request-count target tracking policies disagree, in both directions, and why the rule is asymmetric. Explain why two target tracking policies on the same metric — or a step + target tracking pair on one metric — is a fault.

```
_____________________________________________________________
```

**7.** State the three reasons `ALBRequestCountPerTarget` beats CPU as a scaling signal. Name the one workload type where CPU is better. Describe what would have to be true about the enrolment app for request count to scale it badly, and which metric would reveal that in advance.

```
_____________________________________________________________
```

---

## Conclusion

*(Summarise, in your own words, what was built: the scalable target, two target tracking policies, one step policy with a custom-metric alarm, two scheduled actions, and the persistence/suspension proofs. Reflect on the separation-of-concerns idea from §16.1 — that Application Auto Scaling writes one integer and nothing else in the architecture had to change.)*

```
_____________________________________________________________
_____________________________________________________________
_____________________________________________________________
```

---

*End of Lab 06 Practical Report.*
