## Independent Lab Exercises

All commands run from the repository root, with the course env files loaded first:

```bash
cd ~/aws-floci-course   # repository root
for f in configs/course.env configs/lab-0{1,2,3,4}.env; do source "$f"; done
export AWS_PAGER=""
```

---

### Exercise 1 - Basic: a second service, deployed

Every value is looked up with `$(...)` and `--query`. The two subnets are read from `usms-enrolment-svc` itself, because this Floci account holds two subnets tagged `usms-private-subnet-b` (Lab 02 was run twice), and a Name-tag lookup would pick the wrong one.

```bash
CLUSTER_NAME=$(aws ecs describe-clusters --clusters "$USMS_ECS_CLUSTER" \
  --query 'clusters[0].clusterName' --output text)

TASK_FAMILY=$(aws ecs describe-task-definition --task-definition "$USMS_ENROLMENT_TASK_FAMILY" \
  --query 'taskDefinition.family' --output text)

SUBNET_A=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets[0]' --output text)
SUBNET_B=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets[1]' --output text)

ENROLMENT_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=usms-enrolment-sg Name=vpc-id,Values="$USMS_VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)

echo "CLUSTER=$CLUSTER_NAME FAMILY=$TASK_FAMILY SUBNETS=$SUBNET_A,$SUBNET_B SG=$ENROLMENT_SG"

RESULTS_SERVICE_ARN=$(aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name usms-results-svc \
  --task-definition "$TASK_FAMILY" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$ENROLMENT_SG],assignPublicIp=DISABLED}" \
  --enable-ecs-managed-tags \
  --propagate-tags SERVICE \
  --tags key=Name,value=usms-results-svc key=Project,value=USMS key=Tier,value=app key=Lab,value=04 key=Service,value=results \
  --query 'service.serviceArn' --output text)

echo "RESULTS_SERVICE_ARN = $RESULTS_SERVICE_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-51-59.png>)

&nbsp;

**Wait for it to stabilise, then verify**

```bash
for i in $(seq 1 12); do
  read -r d r p <<< "$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services usms-results-svc \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text)"
  echo "attempt $i: desired=$d running=$r pending=$p"
  [ "$d" = "$r" ] && break
  sleep 5
done

aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc usms-results-svc \
  --query 'services[].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount,TaskDef:taskDefinition}' \
  --output table

aws ecs list-tags-for-resource --resource-arn "$RESULTS_SERVICE_ARN" \
  --query 'tags[].[key,value]' --output text
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-53-05.png>)

&nbsp;

`usms-results-svc` is deliberately **not** recorded in `configs/lab-04.env`; Exercise 4 removes it.

---

### Exercise 2 - Intermediate: a new revision, and a deployment that does not drop traffic

**Part 1 - keep revision 1's template, derive revision 2 from a copy**

```bash
cp templates/lab-04-taskdef.json templates/lab-04-taskdef-rev1.json

jq '.memory = "1024"
    | .containerDefinitions[0].environment += [{"name":"USMS_LOG_LEVEL","value":"info"}]' \
  templates/lab-04-taskdef-rev1.json > templates/lab-04-taskdef-rev2.json

python3 -m json.tool templates/lab-04-taskdef-rev2.json > /dev/null && echo "valid JSON"
grep -c '[$]' templates/lab-04-taskdef-rev2.json
diff <(jq -S . templates/lab-04-taskdef-rev1.json) <(jq -S . templates/lab-04-taskdef-rev2.json)
```

The diff shows exactly two changes: `memory` 512 → 1024 (still a valid Fargate pair with `cpu: 256`) and the new `USMS_LOG_LEVEL=info` variable.

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-55-54.png>)

&nbsp;

**Part 2 - register revision 2**

```bash
TASK_DEF_V2_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://templates/lab-04-taskdef-rev2.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "TASK_DEF_V2_ARN = $TASK_DEF_V2_ARN"
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-56-11.png>)

&nbsp;

**Part 3 - point the service at revision 2 and wait (no fixed sleep)**

```bash
aws ecs update-service --cluster usms-ecs-cluster --service usms-enrolment-svc \
  --task-definition usms-enrolment:2 \
  --query 'service.{Name:serviceName,TaskDef:taskDefinition,Desired:desiredCount}' --output json

for i in $(seq 1 12); do
  read -r d r p <<< "$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text)"
  echo "attempt $i: desired=$d running=$r pending=$p"
  [ "$d" = "$r" ] && break
  sleep 5
done
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-56-28.png>)

&nbsp;

**Verify**

```bash
aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].{TaskDef:taskDefinition,Desired:desiredCount,Running:runningCount,Deployments:deployments[].{Status:status,TaskDef:taskDefinition,Running:runningCount}}' \
  --output json

aws ecs describe-task-definition --task-definition usms-enrolment:1 \
  --query 'taskDefinition.{Rev:revision,Status:status,Memory:memory}' --output json

aws ecs describe-task-definition --task-definition usms-enrolment:2 \
  --query 'taskDefinition.{Rev:revision,Status:status,Memory:memory,Env:containerDefinitions[0].environment[?name==`USMS_LOG_LEVEL`]}' \
  --output json
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-56-43.png>)

&nbsp;

**What changes and what does not:** the service's `taskDefinition` pointer changes from `usms-enrolment:1` to `usms-enrolment:2`, while the revision 1 document itself does not change at all (revisions are immutable) and remains `ACTIVE` and describable until someone explicitly deregisters it.

**Why this does not drop traffic:** the update is a rolling deployment. With the service's default deployment configuration (minimum healthy 100 %, maximum 200 %), ECS starts the new revision 2 tasks first and only stops the revision 1 tasks once the new ones are running, so the running count never falls below the desired count of 2.

---

### Exercise 3 - Problem solving: an ECS configuration drift report

The script is [`scripts/utilities/lab-04-ecs-inventory.sh`](../../scripts/utilities/lab-04-ecs-inventory.sh). Design decisions:

- **Runs from any directory:** `REPO_ROOT` is resolved from `${BASH_SOURCE[0]}`, exactly like `verify-lab-04.sh`, and every path (configs, JSON output) is built from it.
- **No hard-coded service name:** it iterates `aws ecs list-services --query 'serviceArns[]'` and describes each one.
- **Verdicts are computed:** `roles` compares the task definition's `executionRoleArn` with its `taskRoleArn`; `publicip` reads `networkConfiguration.awsvpcConfiguration.assignPublicIp`.
- **No crash without `networkConfiguration`:** the `jq` lookup uses `// empty`, so a missing block becomes `publicip=N/A`.
- **Never an empty field:** a failed lookup prints `UNKNOWN`, and a task definition with one role missing prints `roles=MISSING`.
- **Task definition is always resolved:** the service's `taskDefinition` value is passed to `describe-task-definition`, because Floci sometimes returns a bare family name instead of an ARN. The report always prints `family:revision`.
- **`set -uo pipefail` without `-e`:** this is a report. One service whose describe call fails (deleted mid-run, task definition deregistered) must show as `UNKNOWN`, not abort the report for every other service, so each AWS call is checked explicitly instead.
- **JSON copy:** the same data is written to `outputs/lab-04-ecs-inventory.json`.

```bash
chmod +x scripts/utilities/lab-04-ecs-inventory.sh
bash -n scripts/utilities/lab-04-ecs-inventory.sh && echo "syntax OK"

# run from two different directories and compare
(cd ~ && ~/aws-floci-course/scripts/utilities/lab-04-ecs-inventory.sh)            > /tmp/inv-home.txt
(cd ~/aws-floci-course/labs/lab-04-ecs && ../../scripts/utilities/lab-04-ecs-inventory.sh) > /tmp/inv-lab.txt
cat /tmp/inv-home.txt
diff /tmp/inv-home.txt /tmp/inv-lab.txt && echo "IDENTICAL"

jq . outputs/lab-04-ecs-inventory.json
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-58-14.png>)

&nbsp;

**Proving every verdict, not just the happy path.** Both real services are `SEPARATE` / `OK`, so two short-lived test services were created to exercise `SAME`, `RISK` and `N/A`, then removed:

```bash
# usms-legacy: same role in both fields, public IP enabled
jq '.family="usms-legacy" | .taskRoleArn=.executionRoleArn | .tags=[{"key":"Project","value":"USMS"},{"key":"Ephemeral","value":"true"}]' \
  templates/lab-04-taskdef-rev1.json > /tmp/legacy.json
# usms-ec2test: EC2 launch type, bridge mode -> service has no networkConfiguration
jq '.family="usms-ec2test" | .networkMode="bridge" | .requiresCompatibilities=["EC2"] | .tags=[{"key":"Ephemeral","value":"true"}]' \
  templates/lab-04-taskdef-rev1.json > /tmp/ec2test.json

aws ecs register-task-definition --cli-input-json file:///tmp/legacy.json  --query taskDefinition.taskDefinitionArn --output text
aws ecs register-task-definition --cli-input-json file:///tmp/ec2test.json --query taskDefinition.taskDefinitionArn --output text

aws ecs create-service --cluster usms-ecs-cluster --service-name usms-legacy-svc \
  --task-definition usms-legacy:1 --desired-count 3 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A],securityGroups=[$USMS_ENROLMENT_SG],assignPublicIp=ENABLED}" \
  --query service.serviceName --output text
aws ecs create-service --cluster usms-ecs-cluster --service-name usms-ec2test-svc \
  --task-definition usms-ec2test:1 --desired-count 0 --launch-type EC2 \
  --query service.serviceName --output text

./scripts/utilities/lab-04-ecs-inventory.sh
```

Output:

```
usms-enrolment-svc   desired=2  running=2  taskdef=usms-enrolment:2   roles=SEPARATE publicip=OK
usms-results-svc     desired=1  running=1  taskdef=usms-enrolment:2   roles=SEPARATE publicip=OK
usms-legacy-svc      desired=3  running=3  taskdef=usms-legacy:1      roles=SAME     publicip=RISK
usms-ec2test-svc     desired=0  running=0  taskdef=usms-ec2test:1     roles=SEPARATE publicip=N/A
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-59-26.png>)

&nbsp;

Remove the test resources:

```bash
for s in usms-legacy-svc usms-ec2test-svc; do
  aws ecs update-service --cluster usms-ecs-cluster --service "$s" --desired-count 0 --query service.desiredCount --output text
  aws ecs delete-service --cluster usms-ecs-cluster --service "$s" --query service.status --output text
done
aws ecs deregister-task-definition --task-definition usms-legacy:1  --query taskDefinition.status --output text
aws ecs deregister-task-definition --task-definition usms-ec2test:1 --query taskDefinition.status --output text
./scripts/utilities/lab-04-ecs-inventory.sh
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 02-00-17.png>)

&nbsp;

> **Floci observation:** `usms-results-svc` reports `usms-enrolment:2` even though it was created before revision 2 existed. Floci stored the bare family name `usms-enrolment` instead of pinning a revision, so it follows the latest one. Real ECS resolves a family name to the latest ACTIVE revision **at creation time** and would keep the results service on `:1` until someone updates it.

---

### Exercise 4 - Challenge: the enrolment week capacity plan

#### 4.1 Why a fixed `desiredCount` of 2 cannot answer the 08:03 problem

`usms-enrolment-svc` has exactly one capacity input: the number `desiredCount = 2`. The service scheduler reads no metric (CPU, request count, latency) and no clock; its only job is to keep `runningCount` equal to that number. When enrolment opens at 08:00 and traffic jumps to about 10× what two tasks can serve (derived below), nothing in ECS notices. The two tasks saturate, health checks start failing, and they are replaced by two more tasks that saturate in the same way. Capacity only changes when a human sees the outage and runs `aws ecs update-service --desired-count N`. That human has to notice, decide on a number and run the command, and the new tasks then need 20–60 s each to start on Fargate, so a manual response takes several minutes. That fits last year's 11-minute outage starting at 08:03. The same fixed number is also why Finance sees identical capacity at 03:00 on a Sunday in July: the service cannot scale *down* either.

#### 4.2 Proposed plan (handed to Lab 06, not implemented here)

**Demand derivation.** Every input is either an assumption, stated so it can be replaced with a measured figure, or derived from one.

| # | Quantity | Value | Source / derivation |
|---|---|---|---|
| 1 | Students enrolling | 10,000 | **Assumption** — replace with the Registrar's headcount |
| 2 | API requests per student per enrolment session | 30 | **Assumption** — login, programme lookup, ~20 module list/select calls, confirm, receipt |
| 3 | Requests in enrolment week | 300,000 | (1) × (2) |
| 4 | Requests in the first 20 minutes | 270,000 | 90 % of (3), from the project lead's brief |
| 5 | Average rate over the 20-minute window | 225 req/s | 270,000 ÷ 1,200 s |
| 6 | Peak rate in the first minutes | 450 req/s | 2 × (5): the service fell over at 08:03, so the opening minutes run well above the window average. A 2× burst factor is an **assumption** to replace with last year's access logs |
| 7 | Capacity of one 0.25 vCPU / 1 GB task | 25 req/s | **Assumption** — to be measured with a load test in Lab 06 |
| 8 | Tasks needed at peak | 18 | (6) ÷ (7) = 450 ÷ 25 |
| 9 | Peak capacity | **20 tasks** | (8) + 2 headroom: one spare task per Availability Zone, so losing a task in either AZ still leaves 18 |

**Capacity settings for Lab 06**

| Setting | Value | Why | Cost of setting it too high | Cost of setting it too low |
|---|---|---|---|---|
| Minimum | **2** | One task per AZ (Lab 04 baseline), so one AZ failure never takes the service to zero | Paying for idle tasks every hour of the year, including Sunday 03:00 in July | Below 2, the service is single-AZ and a single task failure is an outage |
| Scheduled floor | **20, Monday 07:45 → 08:30** | Peak capacity from row 9. Start 15 minutes early because reactive scaling needs about 3 one-minute metric periods to trigger, plus 20–60 s per task start. That is about 4 minutes, which is exactly the 08:00–08:03 gap that failed last year. End at 08:30 because 90 % of the week's traffic is over by 08:20 | Each extra floor task costs ~$0.011 per 45-minute window (0.75 h × $0.0145656). Cheap, but a floor left on by mistake costs $10.63 per task-month | A floor below the opening burst repeats the 08:03 failure, because reactive scaling arrives after the damage |
| Maximum | **24** | 20 × 1.2: a 20 % margin over the peak estimate, because rows 1, 2, 6 and 7 are not yet measured | Only costs money if reached. The risk is a runaway policy, e.g. a bug causing CPU spin, so the cap also limits that | If real demand exceeds the cap, the service saturates while the policy is pinned at its maximum |
| Target tracking | **Average CPU 60 %** | Leaves 40 % headroom to absorb growth while new tasks start (20–60 s each) | A lower target runs more tasks than needed all week | A higher target leaves no buffer for a sudden spike while scale-out is still in progress |

**What to tell the team building the policies:** combine the two methods. A **scheduled action** handles the predictable 08:00 Monday spike, because reacting to it is too slow by design. **Target tracking** handles everything nobody predicted. Scale-out should be fast (cooldown 60 s) and scale-in slow (cooldown 300 s), so capacity is not removed during a burst. After the 08:30 schedule ends, the scheduled action should lower *the minimum* back to 2 rather than set the desired count, so target tracking can bring capacity down gradually.

#### 4.3 Monthly cost comparison

**Prices:** AWS Fargate pricing page (<https://aws.amazon.com/fargate/pricing/>), US East (N. Virginia), Linux/x86, on-demand, checked 2026-10-16:
- $0.000011244 per vCPU-second = **$0.0404784 per vCPU-hour**
- $0.000001235 per GB-second = **$0.004446 per GB-hour**
- Ephemeral storage up to 20 GB is included, which covers this task.

**Task size:** `usms-enrolment:2` uses 0.25 vCPU (`cpu: 256`) and 1 GB (`memory: 1024`, from Exercise 2).

| Derivation | Value |
|---|---|
| vCPU cost per task-hour | 0.25 × $0.0404784 = $0.0101196 |
| Memory cost per task-hour | 1 × $0.004446 = $0.0044460 |
| **Cost per task-hour** | **$0.0145656** |
| Hours per month (AWS billing convention) | 730 |
| **Cost per task-month** | 730 × $0.0145656 = **$10.63** |

| Option | Task-hours per month | Monthly cost | Annual |
|---|---|---|---|
| A — fixed at proposed peak (20 tasks) | 20 × 730 = 14,600 | **$212.66** | $2,551.89 |
| B — fixed at today's 2 tasks | 2 × 730 = 1,460 | **$21.27** | $255.19 |
| C — proposed plan, enrolment month | 1,460 base + 13.5 scheduled (18 extra tasks × 0.75 h) + 17 target-tracking tail (2 extra tasks × 8.5 h, Monday 08:30–17:00, **assumption**) = 1,490.5 | **$21.71** | — |
| C — proposed plan, any other month | 1,460 (minimum of 2) | **$21.27** | ≈ $255.63 (one enrolment month + 11 others) |

**Reading the table:**
- Option A survives 08:03 but costs 10× option B all year, to cover a window of under an hour a week.
- Option B is what failed last year.
- Option C survives the spike (20 tasks in place before 08:00) for **$0.44 more than B** in the enrolment month, and the same as B otherwise.

On Finance's Sunday 03:00 point: the minimum of 2 is an availability floor, not wasted capacity. Dropping to 1 task overnight would save about 1 task × 8 h × 30 nights × $0.0145656 ≈ $3.50 per month, at the cost of having no AZ redundancy overnight. Not recommended.

*Excluded because they are the same in every option:* NAT gateway hours and data processing (Lab 02), CloudWatch Logs ingestion, data transfer, and the Lab 05 load balancer.

#### 4.4 What to switch off: the Exercise 1 results service

Dependency order: look up the ARN (read-only) → scale to 0 and wait for running tasks to drain → delete the service. The `usms-enrolment` task definition family, the cluster, `usms-enrolment-sg` and both roles are in the **KEEP** column and are not touched.

**Step 1 - identify exactly what will be deleted (read-only)**

```bash
RESULTS_SERVICE_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services usms-results-svc \
  --query 'services[?status==`ACTIVE`].serviceArn | [0]' --output text)
echo "RESULTS_SERVICE_ARN = $RESULTS_SERVICE_ARN"
```

**Step 2 - scale the results service to zero**

> **DANGER - destructive:** stops every running task of `usms-results-svc`.
> **Scope:** only the Exercise 1 practice service. `usms-enrolment-svc` and everything in the KEEP column are untouched.
> **Impact:** the exam results service stops serving immediately; nothing else depends on it.
> **Check first:** the ARN printed in Step 1 must end in `/usms-results-svc`.

```bash
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service usms-results-svc --desired-count 0 \
  --query 'service.{Name:serviceName,Desired:desiredCount}' --output json

for i in $(seq 1 12); do
  r=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services usms-results-svc \
    --query 'services[0].runningCount' --output text)
  echo "attempt $i: running=$r"
  [ "$r" = "0" ] && break
  sleep 5
done
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 02-01-40.png>)

**Step 3 - delete the results service**

> **DANGER - irreversible:** deletes the ECS service `usms-results-svc`; it cannot be restored, only recreated with `create-service`.
> **Scope:** only this one service. The `usms-enrolment` task definition family it used is in the KEEP column and is NOT deregistered.
> **Order:** run only after Step 2 shows `running=0`, otherwise the delete fails with `InvalidParameterException`.
> **Check first:** `usms-enrolment-svc` must be absent from this command.

```bash
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service usms-results-svc \
  --query 'service.{Name:serviceName,Status:status}' --output json
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 02-02-04.png>)

&nbsp;

**Confirm**

```bash
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services usms-enrolment-svc usms-results-svc \
  --query 'services[].{Name:serviceName,Status:status,Desired:desiredCount}' --output table
aws ecs list-services --cluster "$USMS_ECS_CLUSTER" --query 'serviceArns[]' --output text
./scripts/utilities/verify-lab-04.sh
```

Result: `usms-results-svc` is `INACTIVE`, only `usms-enrolment-svc` is listed, and the verification script reports **`PASS=38  FAIL=0`**.

![alt text](<../../screenshots/Screenshot from 2026-10-16 02-02-29.png>)

&nbsp;

---

### Exercise 5 - Integration: close the loop back to Lab 3, and hand Lab 05 what it needs

**Part 1 - resolve the source group back to an instance**

```bash
SOURCE_SG=$(aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)
echo "SOURCE_SG = $SOURCE_SG   (USMS_APP_SG = $USMS_APP_SG)"

aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$SOURCE_SG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,State:State.Name}' \
  --output table
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 02-03-41.png>)

&nbsp;

**The first result was a MISMATCH, so I checked it rather than accepting it.** The filter returned three instances: `usms-web-01`, `usms-db-01` and `usms-db-02`. Reading each instance's actual groups shows the db instances carry `usms-db-sg`, not `usms-app-sg`. A made-up group ID (`sg-00000000000000000`) also returns all three. So **Floci ignores the `instance.group-id` filter**; this is not a second instance carrying the group. The lookup below filters on each instance's own `SecurityGroups[].GroupId` instead:

```bash
aws ec2 describe-instances --instance-ids $(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text) \
  --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,SGs:join(`,`,SecurityGroups[].GroupId)}' \
  --output table

aws ec2 describe-instances --filters "Name=instance.group-id,Values=sg-00000000000000000" \
  "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text

RESOLVED=$(aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$SOURCE_SG" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[?SecurityGroups[?GroupId=='$SOURCE_SG']].InstanceId[]" --output text)
echo "RESOLVED = $RESOLVED   USMS_WEB_INSTANCE = $USMS_WEB_INSTANCE"
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 02-03-54.png>)

&nbsp;

**Part 2 - write the linkage file and the tag audit**

```bash
OUT=outputs/lab-04-lab03-linkage.txt
RAW=$(aws ec2 describe-instances --filters "Name=instance.group-id,Values=$SOURCE_SG" \
  "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text)
COUNT=$(wc -w <<< "$RESOLVED")
if [ "$COUNT" -eq 1 ] && [ "$RESOLVED" = "$USMS_WEB_INSTANCE" ]; then VERDICT="LOOP CLOSED"; else VERDICT="MISMATCH"; fi

{
echo "# Lab 04 -> Lab 03 linkage (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo "enrolment security group      : $USMS_ENROLMENT_SG (usms-enrolment-sg)"
echo "source group (only inbound)   : $SOURCE_SG (usms-app-sg)"
echo "resolves to running instance  : $RESOLVED"
echo "USMS_WEB_INSTANCE (lab-03.env): $USMS_WEB_INSTANCE"
echo "verdict                       : $VERDICT"
echo
echo "Note: Floci ignores the instance.group-id filter (it returned: $(echo $RAW)),"
echo "so the result above is filtered client-side on each instance's SecurityGroups[].GroupId."
echo "On real AWS the --filters call alone returns only the instance carrying the group."
echo
echo "This rule is temporary: Lab 05 removes the usms-app-sg -> usms-enrolment-sg tcp/80 rule once the load balancer becomes the only caller of the enrolment service."
echo
echo "== Tag audit (aws ecs list-tags-for-resource) =="
for a in "$USMS_ECS_CLUSTER_ARN" "$USMS_ENROLMENT_SERVICE_ARN"; do
  echo "-- $a"
  T=$(aws ecs list-tags-for-resource --resource-arn "$a" --query 'tags[].[key,value]' --output text)
  if [ -z "$T" ]; then echo "   NO TAGS stored"; else sed 's/^/   /' <<< "$T"; fi
  if aws ecs list-tags-for-resource --resource-arn "$a" --query 'tags[?key==`Project`].value' --output text | grep -qx USMS
  then echo "   Project=USMS: present"; else echo "   Project=USMS: MISSING"; fi
done
echo "Result: both ECS resources carry Project=USMS; no tag-resource fix was needed. The cluster has no Lab tag because Step 4 did not set one."
} > "$OUT"

cat "$OUT"
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 02-04-08.png>)

&nbsp;

**Results**
- **Linkage:** verdict **LOOP CLOSED**. `usms-enrolment-sg`'s only inbound source is `usms-app-sg` (`sg-aa761a2258edfea6e`), carried by exactly one running instance, `usms-web-01` (`i-9019ac0987cff66f5`). That is the same instance as `$USMS_WEB_INSTANCE` in `configs/lab-03.env`.
- **Tag audit:** both the cluster and the enrolment service store `Project=USMS`, so no `aws ecs tag-resource` fix was needed.
  - The cluster carries `Project`, `Tier` and `Name` but no `Lab` tag, because Step 4's `create-cluster` never set one.
  - `list-tags-for-resource` takes the **ARN** (`$USMS_ECS_CLUSTER_ARN`, `$USMS_ENROLMENT_SERVICE_ARN` from `configs/lab-04.env`), not the name.

**Why this file matters for Lab 05:** Lab 05's cutover removes the `usms-app-sg → usms-enrolment-sg` tcp/80 rule. This file shows the rule's only caller is `usms-web-01`, so a reader knows what will lose access when it is removed. It is safe once the load balancer is in place as the enrolment service's only caller.


