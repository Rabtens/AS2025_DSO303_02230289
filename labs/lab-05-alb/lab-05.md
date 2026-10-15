# DSO303 – Lab 05: Putting the ECS Service Behind an Application Load Balancer

**Practical 2 – Giving the USMS Enrolment Service a Front Door**

**Student:** Kuenzang
**Institution:** CST (College of Science and Technology), Bhutan
**Course:** DSO303
**Lab:** Lab 05 – ECS + ALB

---

## Table of Contents

1. [Lab Overview](#1-lab-overview)
2. [Learning Objectives](#2-learning-objectives)
3. [Prerequisites Check](#3-prerequisites-check)
4. [Support Path (Section 8, Step 3)](#4-support-path)
5. [Step-by-Step Implementation](#5-step-by-step-implementation)
6. [Verification Script (Section 9)](#6-verification-script-section-9)
7. [Cleanup Script (Section 9.3 — NOT executed)](#7-cleanup-script-section-93--not-executed)
8. [Checkpoints Summary](#8-checkpoints-summary)
9. [Troubleshooting Log](#9-troubleshooting-log)
10. [Review Questions](#10-review-questions)
11. [Reflection](#11-reflection)
12. [Submission Checklist](#12-submission-checklist)

---

## 1. Lab Overview

Lab 04 left the `usms-enrolment-svc` service running two Fargate tasks in private
subnets — correct, but unreachable. This lab fixes that by placing an
**Application Load Balancer (ALB)** in front of a **target group**, with the ECS
service registering and deregistering its own tasks as targets.

The four Elastic Load Balancing objects built in this lab:

| Object | Holds |
|---|---|
| Load balancer | DNS name, subnets (2+ AZs), security groups |
| Listener | One port/protocol, ONE default action |
| Rule | Condition + action, evaluated in priority order |
| Target group | Targets + health check |

> **Word to remember: indirection.** The load balancer is a stable name in front
> of an unstable set of task addresses. The ECS service keeps that list of
> addresses accurate — nobody ever calls `register-targets` by hand.

---

## 2. Learning Objectives

- [ ] Explain why Fargate tasks cannot be addressed directly
- [ ] Name the four ELB objects and what each holds
- [ ] Choose between ALB / NLB / GWLB for a stated requirement
- [ ] Explain why a Fargate target group must be `--target-type ip`
- [ ] Create an internet-facing ALB across two AZs
- [ ] Create a target group with a deliberate health check configuration
- [ ] Distinguish the container health check from the target group health check
- [ ] Create a listener with a default action and a priority-ordered rule
- [ ] Attach an existing ECS service to a target group
- [ ] Explain `--health-check-grace-period-seconds`
- [ ] Read `describe-target-health` states
- [ ] Perform the security cutover from direct to load-balanced access
- [ ] Explain how deregistration delay, `minimumHealthyPercent`, and `stopTimeout` interact
- [ ] Prove every object survives an emulator restart

---

## 3. Prerequisites Check

```bash
cd ~/aws-floci-course
for t in jq python3 docker curl; do printf '%-10s ' "$t"; command -v "$t" || echo MISSING; done
aws --version
./scripts/utilities/floci-storage-check.sh
```

**Expected:** all four tools found, `PASS=16 FAIL=0`.

Prerequisite checklist:

- [ ] Lab 04 complete — `verify-lab-04.sh` reports `FAIL=0` **before** Step 13
- [ ] Lab 2 Step 11 "Your turn" done — `usms-public-subnet-b` exists
- [ ] Lab 2 Exercise 5 done — `usms-private-subnet-b` exists
- [ ] Lab 3 complete — `usms-web-01` running with `usms-app-sg`
- [ ] Errata 01 applied
- [ ] Floci running under Docker Compose, `FLOCI_STORAGE_MODE=hybrid`
- [ ] `jq`, `python3` available

**Screenshot — Prerequisites output:**

```
[ PASTE SCREENSHOT HERE: terminal output of the prerequisite check block ]



```

---

## 4. Support Path

Run the probe below (Section 8, Step 3) to determine which ELBv2 support path this
Floci build is on: **A (full)**, **B (control-plane only)**, or **C (no ELBv2)**.

```bash
probe() {
  printf '%-48s ' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "SUPPORTED"; else echo "not available"; fi
}

echo "== Elastic Load Balancing v2 =="
probe "elbv2 describe-load-balancers"        "aws elbv2 describe-load-balancers"
probe "elbv2 create-load-balancer (skeleton)" "aws elbv2 create-load-balancer --generate-cli-skeleton"
probe "elbv2 describe-target-groups"          "aws elbv2 describe-target-groups"
probe "elbv2 create-target-group (skeleton)"  "aws elbv2 create-target-group --generate-cli-skeleton"
probe "elbv2 describe-listeners (bad arn)"    "aws elbv2 describe-listeners --load-balancer-arn probe"
probe "elbv2 describe-account-limits"         "aws elbv2 describe-account-limits"

echo "== ECS integration =="
probe "ecs update-service (skeleton)"         "aws ecs update-service --generate-cli-skeleton"
probe "ecs describe-services"                 "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE"

echo "== Already used in Labs 1 to 4A =="
probe "ec2 describe-security-groups"          "aws ec2 describe-security-groups --max-items 1"
probe "ec2 describe-subnets"                  "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
```

**Support path recorded:** `[ FILL IN: A / B / C ]`

**Screenshot — Support probe output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

## 5. Step-by-Step Implementation

> All commands are run from `~/aws-floci-course` unless stated otherwise.

### Step 1 — Resume the environment and load five env files

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env

./scripts/utilities/whoami.sh

printf '%-26s %s\n' \
  "vpc"                 "$USMS_VPC_ID" \
  "public subnet a"     "$USMS_PUBLIC_SUBNET_A" \
  "public subnet b"     "$USMS_PUBLIC_SUBNET_B" \
  "private subnet a"    "$USMS_PRIVATE_SUBNET_A" \
  "private subnet b"    "$USMS_PRIVATE_SUBNET_B" \
  "app security group"  "$USMS_APP_SG" \
  "enrolment sg"        "$USMS_ENROLMENT_SG" \
  "web instance"        "$USMS_WEB_INSTANCE" \
  "cluster"             "$USMS_ECS_CLUSTER" \
  "service"             "$USMS_ENROLMENT_SERVICE" \
  "container"           "$USMS_ENROLMENT_CONTAINER" \
  "region"              "$AWS_REGION_COURSE"
```

**Verify:** 12 non-empty values, especially `public subnet b` and `enrolment sg`.

**Screenshot — Step 1 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 2 — Confirm Labs 2, 3 and 04 are still intact

```bash
./scripts/utilities/verify-lab-02.sh | tail -3
./scripts/utilities/verify-lab-03.sh | tail -3
./scripts/utilities/verify-lab-04.sh | tee outputs/lab-05-pre-verify-04.txt | tail -3
```

**Expected:** `FAIL=0` three times.

**Screenshot — Step 2 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 3 — Probe what this Floci build supports for ELB

*(see [Section 4](#4-support-path) above — probe already run)*

**Checkpoint 1**

```
Ready to build
 ├── Floci running under Compose, storage mode hybrid
 ├── course.env + lab-01 + lab-02 + lab-03 + lab-04 sourced
 ├── verify-lab-02.sh, verify-lab-03.sh and verify-lab-04.sh all FAIL=0
 ├── outputs/lab-05-pre-verify-04.txt captured, for comparison after Step 13
 ├── BOTH public subnets present, in TWO different Availability Zones
 └── support path recorded: A (full) / B (control plane only) / C (no ELBv2)
```

---

### Step 4 — Create the load balancer's security group

```bash
ALB_SG=$(aws ec2 create-security-group \
  --group-name usms-alb-sg \
  --description "USMS enrolment load balancer: HTTP from the internet; forwards to usms-enrolment-sg" \
  --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-alb-sg},{Key=Project,Value=USMS},{Key=Tier,Value=edge},{Key=Lab,Value=05}]' \
  --query 'GroupId' \
  --output text)

echo "ALB_SG = $ALB_SG"
```

```bash
cat > policies/usms-alb-sg-ingress.json << 'EOF'
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0",
        "Description": "HTTP from the internet - this is an internet-facing load balancer and this rule is the reason it works"
      }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-alb-sg-ingress.json > /dev/null && echo "valid JSON"

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --ip-permissions file://policies/usms-alb-sg-ingress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' \
  --output text
```

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query 'SecurityGroups[0].{Name:GroupName,VPC:VpcId,Inbound:IpPermissions[].{Port:FromPort,CIDR:IpRanges[0].CidrIp,FromGroup:UserIdGroupPairs[0].GroupId},OutboundRules:length(IpPermissionsEgress)}' \
  --output json
```

**✏️ Your turn (optional, add second rule for tcp/443):** `[ FILL IN if done ]`

**Screenshot — Step 4 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 5 — Create the Application Load Balancer

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name usms-enrolment-alb \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "$USMS_PUBLIC_SUBNET_A" "$USMS_PUBLIC_SUBNET_B" \
  --security-groups "$ALB_SG" \
  --tags Key=Name,Value=usms-enrolment-alb Key=Project,Value=USMS Key=Tier,Value=edge Key=Lab,Value=05 \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

echo "ALB_ARN = $ALB_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB_DNS = $ALB_DNS"
```

```bash
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" \
  && echo "load balancer available" \
  || echo "waiter did not complete - poll manually below (expected on some builds)"

for i in $(seq 1 10); do
  STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].State.Code' --output text)
  printf 'poll %2d  state=%s\n' "$i" "$STATE"
  [ "$STATE" = "active" ] && break
  sleep 10
done
```

**Verify:**

```bash
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,Type:Type,Scheme:Scheme,VPC:VpcId,DNS:DNSName,IPType:IpAddressType,AZs:AvailabilityZones[].{Zone:ZoneName,Subnet:SubnetId},SGs:SecurityGroups}' \
  --output json
```

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --attributes \
      Key=idle_timeout.timeout_seconds,Value=60 \
      Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
  --query 'Attributes[?Key==`idle_timeout.timeout_seconds` || Key==`routing.http.drop_invalid_header_fields.enabled`]' \
  --output table \
  || echo "attribute modification not supported on this build - record it and continue"
```

**Checkpoint 2**

```
usms-enrolment-alb   active
 ├── type            application   (layer 7; cannot be changed after creation)
 ├── scheme          internet-facing  (cannot be changed after creation)
 ├── nodes           usms-public-subnet-a (us-east-1a) + usms-public-subnet-b (us-east-1b)
 ├── security group  usms-alb-sg   in: tcp/80 from 0.0.0.0/0   out: allow all
 ├── DNS name        recorded in your notes
 ├── attributes      idle_timeout 60, drop_invalid_header_fields true
 └── listeners       NONE YET
```

**Screenshot — Step 5 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 6 — Create the target group

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name usms-enrolment-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$USMS_VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path / \
  --health-check-port traffic-port \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --tags Key=Name,Value=usms-enrolment-tg Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "TG_ARN = $TG_ARN"
```

**Verify:**

```bash
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{Name:TargetGroupName,Type:TargetType,Proto:Protocol,Port:Port,VPC:VpcId,HCProto:HealthCheckProtocol,HCPath:HealthCheckPath,HCPort:HealthCheckPort,Interval:HealthCheckIntervalSeconds,Timeout:HealthCheckTimeoutSeconds,Healthy:HealthyThresholdCount,Unhealthy:UnhealthyThresholdCount,Matcher:Matcher.HttpCode,LBs:length(LoadBalancerArns)}' \
  --output json

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions' --output json
```

**✏️ Your turn (widen matcher to 200-399, then restore to 200):** `[ FILL IN ]`

**Screenshot — Step 6 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 7 — Set the target group attribute that governs how a task dies

```bash
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes \
      Key=deregistration_delay.timeout_seconds,Value=30 \
      Key=load_balancing.algorithm.type,Value=least_outstanding_requests \
  --query 'Attributes[?Key==`deregistration_delay.timeout_seconds` || Key==`load_balancing.algorithm.type`].[Key,Value]' \
  --output text

aws elbv2 describe-target-group-attributes --target-group-arn "$TG_ARN" \
  --query 'Attributes[].[Key,Value]' --output table
```

**Screenshot — Step 7 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 8 — Create the listener

```bash
cat > templates/lab-05-listener-default-actions.json << EOF
[
  {
    "Type": "forward",
    "TargetGroupArn": "$TG_ARN"
  }
]
EOF

python3 -m json.tool templates/lab-05-listener-default-actions.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-05-listener-default-actions.json
```

```bash
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions file://templates/lab-05-listener-default-actions.json \
  --tags Key=Name,Value=usms-enrolment-listener Key=Project,Value=USMS Key=Lab,Value=05 \
  --query 'Listeners[0].ListenerArn' \
  --output text)

echo "LISTENER_ARN = $LISTENER_ARN"
```

**Verify:**

```bash
aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Proto:Protocol,DefaultActionType:DefaultActions[0].Type,Forwards:DefaultActions[0].TargetGroupArn,SSL:SslPolicy}' \
  --output json

aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{Name:TargetGroupName,AttachedToLoadBalancers:length(LoadBalancerArns)}' \
  --output json
```

**Checkpoint 3**

```
usms-enrolment-alb   active, internet-facing, application, 2 AZs
 ├── usms-alb-sg                     in: tcp/80 from 0.0.0.0/0
 └── listener  HTTP:80
      └── default action  forward -> usms-enrolment-tg
                                      ├── target-type   ip
                                      ├── HTTP:80, health check GET / every 30s, matcher 200
                                      ├── deregistration delay 30s
                                      ├── algorithm     least_outstanding_requests
                                      ├── attached to   1 load balancer
                                      └── targets       NONE YET  <- Step 10
```

**Screenshot — Step 8 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 9 — Let the load balancer reach the tasks

```bash
cat > policies/usms-enrolment-sg-ingress-alb.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "UserIdGroupPairs": [
      {
        "GroupId": "$ALB_SG",
        "Description": "HTTP from usms-alb-sg - the load balancer is the only client of the enrolment tasks"
      }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-enrolment-sg-ingress-alb.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-enrolment-sg-ingress-alb.json

aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_ENROLMENT_SG" \
  --ip-permissions file://policies/usms-enrolment-sg-ingress-alb.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' \
  --output text
```

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Sources:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}' \
  --output json
```

**Screenshot — Step 9 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 10 — Attach the existing service to the target group

```bash
cat > templates/lab-05-service-load-balancers.json << EOF
[
  {
    "targetGroupArn": "$TG_ARN",
    "containerName": "$USMS_ENROLMENT_CONTAINER",
    "containerPort": 80
  }
]
EOF

python3 -m json.tool templates/lab-05-service-load-balancers.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-05-service-load-balancers.json
cat templates/lab-05-service-load-balancers.json
```

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --load-balancers file://templates/lab-05-service-load-balancers.json \
  --health-check-grace-period-seconds 60 \
  --query 'service.{Name:serviceName,LB:loadBalancers,Grace:healthCheckGracePeriodSeconds,Deployments:length(deployments),TaskDef:taskDefinition}' \
  --output json
```

> If `--load-balancers` is rejected on `update-service`, use the recreate
> fallback documented in the lab (delete and recreate the service with
> `--load-balancers` set at creation time).

**Screenshot — Step 10 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 11 — Watch the targets register, and read target health

```bash
for i in $(seq 1 12); do
  echo "--- poll $i ---"
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
    --output table
  N=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query 'length(TargetHealthDescriptions)' --output text)
  [ "$N" -ge 2 ] && break
  sleep 10
done
```

```bash
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:length(deployments),Rollout:deployments[0].rolloutState,LB:loadBalancers[0].targetGroupArn}' \
  --output json

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].events[0:6].[createdAt,message]' --output text
```

```bash
for t in $(aws ecs list-tasks --cluster "$USMS_ECS_CLUSTER" --service-name "$USMS_ENROLMENT_SERVICE" \
             --query 'taskArns[]' --output text); do
  aws ecs describe-tasks --cluster "$USMS_ECS_CLUSTER" --tasks "$t" \
    --query 'tasks[0].{Task:taskArn,ECSHealth:healthStatus,Last:lastStatus,IP:attachments[].details[?name==`privateIPv4Address`].value|[]|[0]}' \
    --output text
done

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
```

**ECS-health vs Target-health table (fill in from your observations):**

| ECS `healthStatus` | Target health | Diagnosis |
|---|---|---|
| `[ FILL IN ]` | `[ FILL IN ]` | `[ FILL IN ]` |

**✏️ Your turn (desired count 3, then back to 2):** `[ FILL IN ]`

**Checkpoint 4**

```
usms-enrolment-svc   attached to the load balancer
 ├── loadBalancers[0]  targetGroupArn = usms-enrolment-tg
 │                     containerName  = enrolment-api
 │                     containerPort  = 80
 ├── healthCheckGracePeriodSeconds  60
 ├── taskDefinition   usms-enrolment:2  - UNCHANGED
 └── usms-enrolment-tg
      ├── 10.0.3.x:80  us-east-1a   registered by the SERVICE
      ├── 10.0.4.x:80  us-east-1b   registered by the SERVICE
      └── state        healthy / initial / (empty, on builds with no data path)
```

**Screenshot — Step 11 output (target registration & health):**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 12 — Prove the path, and be honest about which proof you got

```bash
echo "ALB DNS name: $ALB_DNS"

getent hosts "$ALB_DNS" 2>/dev/null || python3 -c "
import socket,sys
try:
    print(socket.gethostbyname_ex(sys.argv[1]))
except Exception as e:
    print('does not resolve:', e)
" "$ALB_DNS"

curl -s -o /dev/null -w 'http_code=%{http_code}  time_total=%{time_total}s\n' \
     --max-time 10 "http://$ALB_DNS/" \
  || echo "curl could not connect - expected on many builds; see part 2"
```

```bash
{
  echo "== 1. The listener a client would connect to =="
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[].[Protocol,Port,DefaultActions[0].Type,DefaultActions[0].TargetGroupArn]' \
    --output text

  echo
  echo "== 2. The target group that listener forwards to =="
  aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
    --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,VpcId]' \
    --output text

  echo
  echo "== 3. The targets in it, and which subnet each address belongs to =="
  for ip in $(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
                --query 'TargetHealthDescriptions[].Target.Id' --output text); do
    printf '%-16s ' "$ip"
    case "$ip" in
      10.0.3.*) echo "usms-private-subnet-a  (us-east-1a)" ;;
      10.0.4.*) echo "usms-private-subnet-b  (us-east-1b)" ;;
      *)        echo "NOT in a Lab 02 private subnet - investigate" ;;
    esac
  done

  echo
  echo "== 4. The service that put them there =="
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[serviceName,loadBalancers[0].targetGroupArn,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' \
    --output text

  echo
  echo "== 5. The firewall that lets step 1 reach step 3 =="
  aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
    --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text
  echo "   (usms-alb-sg is $ALB_SG)"
} | tee outputs/lab-05-path-proof.txt
```

**Which proof did you obtain?** `[ FILL IN: data-path 200 / control-plane chain only ]`

**Screenshot — Step 12 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 13 — The cutover: remove the direct path

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$USMS_ENROLMENT_SG" \
  --query 'SecurityGroupRules[].{Id:SecurityGroupRuleId,Egress:IsEgress,Port:FromPort,CIDR:CidrIpv4,FromGroup:ReferencedGroupInfo.GroupId,Desc:Description}' \
  --output table

OLD_RULE_ID=$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$USMS_ENROLMENT_SG" \
  --query "SecurityGroupRules[?IsEgress==\`false\` && ReferencedGroupInfo.GroupId=='$USMS_APP_SG'].SecurityGroupRuleId | [0]" \
  --output text)

echo "rule to remove: $OLD_RULE_ID"
```

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$USMS_ENROLMENT_SG" \
  --security-group-rule-ids "$OLD_RULE_ID" \
  --query 'Return' --output text
```

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Sources:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}' \
  --output json

echo "usms-alb-sg = $ALB_SG"
echo "usms-app-sg = $USMS_APP_SG   (must NOT appear above)"
```

```bash
./scripts/utilities/verify-lab-04.sh | tee outputs/lab-05-post-verify-04.txt | tail -5

echo "== what changed =="
diff outputs/lab-05-pre-verify-04.txt outputs/lab-05-post-verify-04.txt
```

**Expected diff:** exactly one check moves from `ok` to `FAIL` —
`usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)`, counts moving
from `PASS=49 FAIL=0` to `PASS=48 FAIL=1`. This is **expected**, not a bug.

**Screenshot — Step 13 cutover + diff output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 14 — Deploy behind a load balancer, and watch a target drain

```bash
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[taskDefinition,desiredCount,runningCount]' --output text
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'sort(TargetHealthDescriptions[].Target.Id)' --output text
} > outputs/lab-05-pre-deploy.txt

cat outputs/lab-05-pre-deploy.txt
```

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --force-new-deployment \
  --query 'service.{TaskDef:taskDefinition,Deployments:length(deployments)}' \
  --output json
```

```bash
for i in $(seq 1 15); do
  echo "--- poll $i ---"
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].deployments[].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount,Rollout:rolloutState}' \
    --output text
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
  N=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
        --query 'length(deployments)' --output text)
  [ "$N" = "1" ] && break
  sleep 8
done
```

```bash
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[taskDefinition,desiredCount,runningCount]' --output text
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'sort(TargetHealthDescriptions[].Target.Id)' --output text
} > outputs/lab-05-post-deploy.txt

paste outputs/lab-05-pre-deploy.txt outputs/lab-05-post-deploy.txt
```

**Checkpoint 5**

```
Deployment behind a load balancer, observed
 ├── --force-new-deployment      same revision, new tasks
 ├── target states seen          initial -> healthy -> draining
 ├── deregistration delay        30s, so in-flight requests survive the swap
 ├── grace period                60s, so a slow start is not mistaken for a failure
 └── pre/post address lists      different addresses, identical configuration
```

**Screenshot — Step 14 pre/post deploy comparison:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 15 — Add a listener rule

```bash
cat > templates/lab-05-rule-conditions.json << 'EOF'
[
  {
    "Field": "path-pattern",
    "PathPatternConfig": {
      "Values": ["/alb-health", "/alb-health/*"]
    }
  }
]
EOF

cat > templates/lab-05-rule-actions.json << 'EOF'
[
  {
    "Type": "fixed-response",
    "FixedResponseConfig": {
      "StatusCode": "200",
      "ContentType": "text/plain",
      "MessageBody": "usms-enrolment-alb ok\n"
    }
  }
]
EOF

python3 -m json.tool templates/lab-05-rule-conditions.json > /dev/null && echo "conditions valid"
python3 -m json.tool templates/lab-05-rule-actions.json    > /dev/null && echo "actions valid"
```

```bash
RULE_ARN=$(aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions file://templates/lab-05-rule-conditions.json \
  --actions file://templates/lab-05-rule-actions.json \
  --tags Key=Name,Value=usms-enrolment-health-rule Key=Project,Value=USMS Key=Lab,Value=05 \
  --query 'Rules[0].RuleArn' \
  --output text)

echo "RULE_ARN = $RULE_ARN"
```

**Verify:**

```bash
aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,Default:IsDefault,Condition:Conditions[0].Field,Values:Conditions[0].Values,Action:Actions[0].Type,Status:Actions[0].FixedResponseConfig.StatusCode,TargetGroup:Actions[0].TargetGroupArn}' \
  --output json
```

```bash
curl -s -o /dev/null -w '/            -> %{http_code}\n' --max-time 10 "http://$ALB_DNS/" || true
curl -s -w '/alb-health  -> %{http_code}  body: %{size_download} bytes\n' --max-time 10 \
     "http://$ALB_DNS/alb-health" || true
```

**Checkpoint 6**

```
usms-enrolment-alb
 └── listener  HTTP:80
      ├── rule priority 10   path-pattern /alb-health, /alb-health/*
      │                       -> fixed-response 200 text/plain, no target involved
      └── default action      -> forward to usms-enrolment-tg
                                  └── 2 targets, registered by usms-enrolment-svc
```

**Screenshot — Step 15 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 16 — Prove the whole thing survives a restart

```bash
{
  aws elbv2 describe-load-balancers --names usms-enrolment-alb \
    --query 'LoadBalancers[0].[LoadBalancerName,Scheme,Type,State.Code,length(AvailabilityZones),length(SecurityGroups)]' --output text
  aws elbv2 describe-target-groups --names usms-enrolment-tg \
    --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,Matcher.HttpCode,HealthCheckIntervalSeconds,UnhealthyThresholdCount]' --output text
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'sort_by(Listeners,&Port)[].[Port,Protocol,DefaultActions[0].Type]' --output text
  aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
    --query 'sort_by(Rules,&Priority)[].[Priority,Actions[0].Type]' --output text
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[serviceName,status,desiredCount,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' --output text
  aws ec2 describe-security-groups --group-ids "$ALB_SG" \
    --query 'SecurityGroups[0].[GroupName,IpPermissions[0].FromPort,IpPermissions[0].IpRanges[0].CidrIp]' --output text
  aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
    --query 'SecurityGroups[0].[GroupName,length(IpPermissions[0].UserIdGroupPairs)]' --output text
} > outputs/lab-05-pre-restart.txt

cat outputs/lab-05-pre-restart.txt
```

```bash
./scripts/setup/floci-down.sh
sleep 3
./scripts/setup/floci-up.sh
sleep 5
source configs/course.env
source configs/lab-02.env
source configs/lab-04.env
```

```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)
ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-alb-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

echo "re-derived:"
printf '  %s\n' "$ALB_ARN" "$TG_ARN" "$LISTENER_ARN" "$ALB_SG"

{
  aws elbv2 describe-load-balancers --names usms-enrolment-alb \
    --query 'LoadBalancers[0].[LoadBalancerName,Scheme,Type,State.Code,length(AvailabilityZones),length(SecurityGroups)]' --output text
  aws elbv2 describe-target-groups --names usms-enrolment-tg \
    --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,Matcher.HttpCode,HealthCheckIntervalSeconds,UnhealthyThresholdCount]' --output text
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'sort_by(Listeners,&Port)[].[Port,Protocol,DefaultActions[0].Type]' --output text
  aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
    --query 'sort_by(Rules,&Priority)[].[Priority,Actions[0].Type]' --output text
  aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[0].[serviceName,status,desiredCount,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' --output text
  aws ec2 describe-security-groups --group-ids "$ALB_SG" \
    --query 'SecurityGroups[0].[GroupName,IpPermissions[0].FromPort,IpPermissions[0].IpRanges[0].CidrIp]' --output text
  aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
    --query 'SecurityGroups[0].[GroupName,length(IpPermissions[0].UserIdGroupPairs)]' --output text
} > outputs/lab-05-post-restart.txt

diff outputs/lab-05-pre-restart.txt outputs/lab-05-post-restart.txt \
  && echo "PERSISTENCE PROVEN: the load balancer, its two Availability Zones, its security group, the target group with its full health check configuration, the listener, the rule, the service's loadBalancers entry and the grace period are all unchanged" \
  || echo "PERSISTENCE FAILED: read the diff above, then run ./scripts/utilities/floci-storage-check.sh"
```

**Checkpoint 7**

```
Persistence proven for Lab 05
 ├── every ARN re-derived from the API by name or by walking down from a parent
 ├── load balancer: scheme, type, 2 AZs, 1 security group - unchanged
 ├── target group: type ip, health check path, matcher, interval, threshold - unchanged
 ├── listener and its rule - unchanged, in priority order
 ├── service loadBalancers entry and grace period - unchanged
 └── both security groups - unchanged, including the Step 13 cutover
```

**Screenshot — Step 16 PERSISTENCE PROVEN output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 17 — Close the loop, and audit what this lab created

```bash
source configs/lab-03.env

echo "== 1. Who can reach the load balancer? =="
aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,FromCIDR:IpRanges[].CidrIp,FromGroup:UserIdGroupPairs[].GroupId}' \
  --output json

echo
echo "== 2. Who can reach the tasks? =="
TASK_SOURCE=$(aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)
echo "source group: $TASK_SOURCE"

if [ "$TASK_SOURCE" = "$ALB_SG" ]; then
  echo "CUTOVER CONFIRMED: the ONLY thing that may open a connection to an enrolment task is usms-alb-sg"
else
  echo "MISMATCH: expected $ALB_SG (usms-alb-sg), found $TASK_SOURCE - re-read Steps 9 and 13"
fi

echo
echo "== 3. And who is the client of the load balancer, in the story? =="
aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$USMS_APP_SG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,Subnet:SubnetId}' \
  --output table

CARRIER=$(aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$USMS_APP_SG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [ "$CARRIER" = "$USMS_WEB_INSTANCE" ]; then
  echo "LOOP CLOSED: usms-web-01 ($CARRIER) still carries usms-app-sg, but now calls $ALB_DNS instead of a task address"
else
  echo "NOTE: usms-app-sg is carried by $CARRIER; lab-03.env records $USMS_WEB_INSTANCE"
fi

echo
echo "== 4. Audit: everything this lab tagged Lab=05 =="
aws ec2 describe-security-groups --filters "Name=tag:Lab,Values=05" \
  --query 'SecurityGroups[].[GroupName,GroupId]' --output text
aws elbv2 describe-tags --resource-arns "$ALB_ARN" "$TG_ARN" \
  --query 'TagDescriptions[].{Resource:ResourceArn,Tags:Tags[?Key==`Lab`].Value|[0]}' \
  --output table \
  || echo "elbv2 describe-tags not supported on this build - record it and continue"
```

**Screenshot — Step 17 CUTOVER CONFIRMED / LOOP CLOSED output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 18 — Write `configs/lab-05.env`

```bash
cat > configs/lab-05.env << EOF
# Lab 05 - ECS service behind an Application Load Balancer
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# Sourced alongside lab-01/02/03/04. Lab 06 sources this
# file for the target group its ALBRequestCountPerTarget policy names.

export USMS_ALB_NAME=usms-enrolment-alb
export USMS_ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
export USMS_ALB_DNS=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
export USMS_ALB_SCHEME=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].Scheme' --output text)
export USMS_ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-alb-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_TG_NAME=usms-enrolment-tg
export USMS_TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
export USMS_TG_TARGET_TYPE=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetType' --output text)
export USMS_TG_HEALTH_PATH=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].HealthCheckPath' --output text)

export USMS_ALB_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
     --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query 'Listeners[?Port==\`80\`].ListenerArn | [0]' --output text)

export USMS_ALB_LISTENER_PORT=80
export USMS_ALB_HEALTH_RULE_PATH=/alb-health

export USMS_SVC_LB_CONTAINER=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].loadBalancers[0].containerName' --output text)
export USMS_SVC_LB_PORT=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].loadBalancers[0].containerPort' --output text)
export USMS_SVC_GRACE_PERIOD=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].healthCheckGracePeriodSeconds' --output text)
EOF

grep -n 'export .*=$\|None' configs/lab-05.env || echo "all values populated"
```

**Verify:**

```bash
source configs/lab-05.env

printf '%-26s %s\n' \
  "alb name"        "$USMS_ALB_NAME" \
  "alb scheme"      "$USMS_ALB_SCHEME" \
  "alb dns"         "$USMS_ALB_DNS" \
  "alb sg"          "$USMS_ALB_SG" \
  "target group"    "$USMS_TG_NAME" \
  "target type"     "$USMS_TG_TARGET_TYPE" \
  "health path"     "$USMS_TG_HEALTH_PATH" \
  "listener"        "$USMS_ALB_LISTENER_ARN" \
  "lb container"    "$USMS_SVC_LB_CONTAINER" \
  "lb port"         "$USMS_SVC_LB_PORT" \
  "grace period"    "$USMS_SVC_GRACE_PERIOD"

grep -c '^export' configs/lab-05.env
```

**Expected:** all values populated, `grep -c '^export'` = **15**.

**Screenshot — Step 18 output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

### Step 19 — Commit

```bash
git status --short

git check-ignore -v outputs/lab-05-path-proof.txt
git ls-files outputs/
```

```bash
git add labs/lab-05-ecs-alb/ \
        configs/lab-05.env \
        policies/usms-alb-sg-ingress.json \
        policies/usms-enrolment-sg-ingress-alb.json \
        templates/lab-05-listener-default-actions.json \
        templates/lab-05-rule-conditions.json \
        templates/lab-05-rule-actions.json \
        templates/lab-05-service-load-balancers.json \
        scripts/utilities/verify-lab-05.sh \
        scripts/cleanup/lab-05-cleanup.sh

git status --short

git commit -m "Lab 05: USMS enrolment service behind an Application Load Balancer - ALB, target group, listener, rule, service attachment and the security cutover"

git log --oneline -6
```

**Checkpoint 8**

```
Lab 05 recorded
 ├── configs/lab-05.env       committed, 15 exports, fully populated
 ├── policies/                 two security group documents, opposite heredoc quoting
 ├── templates/                listener default action, rule conditions, rule actions,
 │                             service load balancers
 ├── scripts/                  verify-lab-05.sh and lab-05-cleanup.sh
 ├── outputs/                  nothing staged; check-ignore names the rule that protected you
 └── git log shows Lab 01, 02, 03, 04 and 05 commits
```

**Screenshot — Step 19 git commit + log output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

## 6. Verification Script (Section 9)

```bash
cat > scripts/utilities/verify-lab-05.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 05 artefact exists and is configured correctly.
# Read-only: this script inspects and changes nothing. Safe to run at any time.
# Exit 0 if every check passes, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true

: "${USMS_VPC_ID:=none}"
: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PUBLIC_SUBNET_B:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_CONTAINER:=enrolment-api}"
: "${USMS_ALB_NAME:=usms-enrolment-alb}"
: "${USMS_ALB_SG:=none}"
: "${USMS_TG_NAME:=usms-enrolment-tg}"
: "${USMS_TG_ARN:=none}"
: "${USMS_ALB_LISTENER_ARN:=}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

lbq()    { aws elbv2 describe-load-balancers --names "$USMS_ALB_NAME" \
             --query "LoadBalancers[0].$1" --output text; }
tgq()    { aws elbv2 describe-target-groups --names "$USMS_TG_NAME" \
             --query "TargetGroups[0].$1" --output text; }
tgattr() { aws elbv2 describe-target-group-attributes --target-group-arn "$(tgq TargetGroupArn)" \
             --query "Attributes[?Key=='$1'].Value | [0]" --output text; }
svcq()   { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
             --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }
sgsrc()  { aws ec2 describe-security-groups --group-ids "$1" \
             --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text; }
az()     { aws ec2 describe-subnets --subnet-ids "$1" \
             --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null; }

LARN="${USMS_ALB_LISTENER_ARN}"
if [ -z "$LARN" ] || [ "$LARN" = "None" ]; then
  LARN=$(aws elbv2 describe-listeners --load-balancer-arn "$(lbq LoadBalancerArn)" \
           --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null || echo none)
fi

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 02 to 04 dependencies =="
check "usms-vpc exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "usms-public-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "usms-public-subnet-b exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_B"
check "the two public subnets are in TWO different AZs" \
  "test -n \"\$(az $USMS_PUBLIC_SUBNET_A)\" && test \"\$(az $USMS_PUBLIC_SUBNET_A)\" != \"\$(az $USMS_PUBLIC_SUBNET_B)\""
check "usms-app-sg still exists" "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svcq status)\" = ACTIVE"

echo "== Lab 05 security groups =="
check "usms-alb-sg exists" "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG"
check "usms-alb-sg admits tcp/80 from 0.0.0.0/0" \
  "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"
check "usms-enrolment-sg admits tcp/80 from usms-alb-sg" \
  "sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_ALB_SG"
check "cutover done: usms-enrolment-sg no longer admits usms-app-sg" \
  "! sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_APP_SG"

echo "== Lab 05 load balancer =="
check "load balancer $USMS_ALB_NAME exists" "aws elbv2 describe-load-balancers --names $USMS_ALB_NAME"
check "load balancer state is active"        "test \"\$(lbq 'State.Code')\" = active"
check "scheme is internet-facing"            "test \"\$(lbq Scheme)\" = internet-facing"
check "type is application"                  "test \"\$(lbq Type)\" = application"
check "spans TWO availability zones"         "test \"\$(lbq 'length(AvailabilityZones)')\" = 2"
check "carries usms-alb-sg" \
  "aws elbv2 describe-load-balancers --names $USMS_ALB_NAME --query 'LoadBalancers[0].SecurityGroups' --output text | grep -qw $USMS_ALB_SG"

echo "== Lab 05 target group =="
check "target group $USMS_TG_NAME exists" "aws elbv2 describe-target-groups --names $USMS_TG_NAME"
check "target type is ip (mandatory for awsvpc)" "test \"\$(tgq TargetType)\" = ip"
check "protocol HTTP on port 80" \
  "test \"\$(tgq Protocol)\" = HTTP && test \"\$(tgq Port)\" = 80"
check "target group lives in usms-vpc" "test \"\$(tgq VpcId)\" = $USMS_VPC_ID"
check "health check is GET / with matcher 200" \
  "test \"\$(tgq HealthCheckPath)\" = / && test \"\$(tgq 'Matcher.HttpCode')\" = 200"
check "deregistration delay is 30 seconds" \
  "test \"\$(tgattr deregistration_delay.timeout_seconds)\" = 30"

echo "== Lab 05 listener and rule =="
check "a listener exists on port 80" "test \"\$LARN\" != none && test -n \"\$LARN\""
check "listener default action forwards to $USMS_TG_NAME" \
  "aws elbv2 describe-listeners --listener-arns \"\$LARN\" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text | grep -q ':targetgroup/$USMS_TG_NAME/'"
check "at least one non-default rule exists" \
  "test \"\$(aws elbv2 describe-rules --listener-arn \"\$LARN\" --query 'length(Rules[?IsDefault==\`false\`])' --output text)\" -ge 1"
check "the non-default rule returns a fixed-response 200" \
  "aws elbv2 describe-rules --listener-arn \"\$LARN\" --query 'Rules[?IsDefault==\`false\`].Actions[0].FixedResponseConfig.StatusCode' --output text | grep -q 200"

echo "== Lab 05 service wiring =="
check "service has exactly ONE loadBalancers entry" "test \"\$(svcq 'length(loadBalancers)')\" = 1"
check "it names $USMS_TG_NAME" \
  "svcq 'loadBalancers[0].targetGroupArn' | grep -q ':targetgroup/$USMS_TG_NAME/'"
check "containerName is $USMS_ENROLMENT_CONTAINER" \
  "test \"\$(svcq 'loadBalancers[0].containerName')\" = $USMS_ENROLMENT_CONTAINER"
check "containerPort is 80" "test \"\$(svcq 'loadBalancers[0].containerPort')\" = 80"
check "healthCheckGracePeriodSeconds is set (not None, not 0)" \
  "test \"\$(svcq healthCheckGracePeriodSeconds)\" != None && test \"\$(svcq healthCheckGracePeriodSeconds)\" -gt 0"
check "service still spans two private subnets" \
  "test \"\$(svcq 'length(networkConfiguration.awsvpcConfiguration.subnets)')\" = 2"
check "service still assigns NO public IP" \
  "test \"\$(svcq 'networkConfiguration.awsvpcConfiguration.assignPublicIp')\" = DISABLED"
check "exactly ONE deployment (nothing stuck mid-roll)" \
  "test \"\$(svcq 'length(deployments)')\" = 1"

echo "== Files and Git hygiene =="
check "configs/lab-05.env exists" "test -f configs/lab-05.env"
check "configs/lab-05.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-05.env"
check "policies/usms-alb-sg-ingress.json is valid JSON" \
  "python3 -m json.tool policies/usms-alb-sg-ingress.json"
check "policies/usms-enrolment-sg-ingress-alb.json is valid JSON" \
  "python3 -m json.tool policies/usms-enrolment-sg-ingress-alb.json"
check "templates/lab-05-listener-default-actions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-listener-default-actions.json"
check "templates/lab-05-rule-conditions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-rule-conditions.json"
check "templates/lab-05-rule-actions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-rule-actions.json"
check "templates/lab-05-service-load-balancers.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-service-load-balancers.json"
check "no Lab 05 document contains an unexpanded variable" \
  "! grep -q '[\$]' templates/lab-05-listener-default-actions.json templates/lab-05-service-load-balancers.json policies/usms-enrolment-sg-ingress-alb.json"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"

if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:
  ./scripts/utilities/floci-storage-check.sh

A failure under "== Lab 02 to 04 dependencies ==" means an earlier lab's resource is
gone. Run verify-lab-02.sh, verify-lab-03.sh and verify-lab-04.sh before re-reading
anything here. Remember that verify-lab-04.sh is EXPECTED to report exactly one
failure after Step 13, on the usms-app-sg source check.
REMEDY
fi

[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-05.sh
bash -n scripts/utilities/verify-lab-05.sh && echo "syntax OK"
./scripts/utilities/verify-lab-05.sh
```

**Expected:** `PASS=49  FAIL=0` (or documented benign failures — see table below).

**Known benign failures:**

| Check | Benign cause |
|---|---|
| deregistration delay is 30 seconds | `modify-target-group-attributes` not implemented on this build |
| load balancer state is active | Some builds stay at `provisioning` |
| non-default rule returns fixed-response 200 | `create-rule` not implemented |
| healthCheckGracePeriodSeconds is set | Flag accepted but not stored |
| the two public subnets are in TWO different AZs | **Not benign** — go back and fix Lab 2 |
| cutover done: no longer admits usms-app-sg | **Not benign** — Step 13 was skipped |
| exactly ONE deployment | Some builds report zero rather than one |

**Screenshot — verify-lab-05.sh full output:**

```
[ PASTE SCREENSHOT HERE ]



```

---

## 7. Cleanup Script (Section 9.3 — NOT executed)

> ⚠️ **This script was built and syntax-checked only. It was NOT run**, per the
> lab's instruction — cleanup is end-of-course only, and it deletes the
> service, load balancer, target group and security group irreversibly.

```bash
cat > scripts/cleanup/lab-05-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes Lab 05, dependencies first.
# Order: service -> rules -> listener -> load balancer -> target group -> security group.
# Run AFTER scripts/cleanup/lab-04-cleanup.sh and BEFORE scripts/cleanup/lab-04-cleanup.sh.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"
source "$REPO_ROOT/configs/lab-05.env"

cat <<'WARN'
============================================================
  This deletes the USMS enrolment SERVICE, the Application
  Load Balancer usms-enrolment-alb, its listener and rule,
  the target group usms-enrolment-tg and the security group
  usms-alb-sg.

  Lab 06, Lab 09 and the CloudFormation lab depend on parts
  of it. None of this is reversible.

  Run AFTER  lab-04-cleanup.sh
  Run BEFORE lab-04-cleanup.sh
============================================================
WARN

RID="service/${USMS_ECS_CLUSTER}/${USMS_ENROLMENT_SERVICE}"
TARGETS=$(aws application-autoscaling describe-scalable-targets \
            --service-namespace ecs --resource-ids "$RID" \
            --query 'length(ScalableTargets)' --output text 2>/dev/null || echo 0)
if [ "$TARGETS" != "0" ] && [ "$TARGETS" != "None" ]; then
  echo "REFUSING: a scalable target still exists for $RID"
  echo "Run scripts/cleanup/lab-04-cleanup.sh first."
  exit 1
fi

read -r -p 'Type exactly: DELETE USMS LOAD BALANCER  > ' answer
[ "$answer" = "DELETE USMS LOAD BALANCER" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "service: scale to zero, wait, then delete (this frees the targets)"
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 0 >/dev/null || true
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" || sleep 20
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --force >/dev/null || true

say "listener rules (deleting the listener would take them anyway; explicit is clearer)"
LARN=$(aws elbv2 describe-listeners --load-balancer-arn "$USMS_ALB_ARN" \
         --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || echo None)
if [ "$LARN" != "None" ] && [ -n "$LARN" ]; then
  for r in $(aws elbv2 describe-rules --listener-arn "$LARN" \
               --query 'Rules[?IsDefault==`false`].RuleArn' --output text); do
    aws elbv2 delete-rule --rule-arn "$r" >/dev/null || true
  done
  say "listener"
  aws elbv2 delete-listener --listener-arn "$LARN" >/dev/null || true
fi

say "load balancer (must go before the target group it forwarded to)"
aws elbv2 delete-load-balancer --load-balancer-arn "$USMS_ALB_ARN" >/dev/null || true
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$USMS_ALB_ARN" 2>/dev/null || sleep 20

say "target group"
aws elbv2 delete-target-group --target-group-arn "$USMS_TG_ARN" >/dev/null || true

say "security group (only after the load balancer's interfaces are gone)"
aws ec2 delete-security-group --group-id "$USMS_ALB_SG" || \
  echo "  still in use - wait for the load balancer's ENIs to be released, then retry"

echo
echo "Lab 05 teardown complete. scripts/cleanup/lab-04-cleanup.sh may now run."
EOF

chmod +x scripts/cleanup/lab-05-cleanup.sh
bash -n scripts/cleanup/lab-05-cleanup.sh && echo "syntax OK - do NOT run it"
```

**Screenshot — `bash -n` syntax check output only:**

```
[ PASTE SCREENSHOT HERE ]



```

---

## 8. Checkpoints Summary

| # | After step | Status |
|---|---|---|
| 1 | Step 3 | `[ ]` |
| 2 | Step 5 | `[ ]` |
| 3 | Step 8 | `[ ]` |
| 4 | Step 11 | `[ ]` |
| 5 | Step 14 | `[ ]` |
| 6 | Step 15 | `[ ]` |
| 7 | Step 16 | `[ ]` |
| 8 | Step 19 | `[ ]` |

---

## 9. Troubleshooting Log

Record any of the following you hit, and how it was resolved:

| Symptom | Cause | Fix |
|---|---|---|
| `ValidationError: At least two subnets in two different Availability Zones must be specified` | `[ FILL IN if hit ]` | `[ FILL IN ]` |
| `InvalidParameterException: The container enrolment-api does not exist` | `[ FILL IN if hit ]` | `[ FILL IN ]` |
| Targets stay `initial` forever | `[ FILL IN if hit ]` | `[ FILL IN ]` |
| Service will not stabilise (start/stop loop) | `[ FILL IN if hit ]` | `[ FILL IN ]` |
| `curl` returns `503 Service Temporarily Unavailable` | `[ FILL IN if hit ]` | `[ FILL IN ]` |

---

## 10. Review Questions

Answer in your own words (Section 15 of the lab):

1. **Group-referenced security rules vs. the load balancer — what do they have in common?**
   `[ FILL IN ]`

2. **Why is "target unhealthy" ≠ "application broken"?**
   `[ FILL IN ]`

3. **Why is there no `update-target-group-target-type`? What does that say about configuration vs. identity?**
   `[ FILL IN ]`

4. **Walk through a request in flight when its task is stopped — name every timer.**
   `[ FILL IN ]`

5. **Should `verify-lab-04.sh`'s failing check be fixed immediately or left documented? Both sides.**
   `[ FILL IN ]`

6. **How can the ALB be internet-facing while the tasks have no public address?**
   `[ FILL IN ]`

7. **Why is request-count a better scaling signal than CPU for a web API?**
   `[ FILL IN ]`

---

## 11. Reflection

`[ FILL IN: 1–2 paragraphs — indirection with an owner (the ECS service maintains
target group membership), health as a distributed opinion (container health check
vs. target group health check), and the cutover discipline (add → prove → remove). ]`

---

## 12. Submission Checklist

**Environment**
- [ ] Floci runs under Docker Compose, `floci-storage-check.sh` reports `PASS=16 FAIL=0`
- [ ] `whoami.sh` reports account `000000000000`
- [ ] Support path (A/B/C) stated at the top of this report

**Resources**
- [ ] `usms-alb-sg` admits tcp/80 from `0.0.0.0/0`
- [ ] `usms-enrolment-alb` internet-facing, application, 2 AZs, 1 SG
- [ ] `usms-enrolment-tg` target-type `ip`, HTTP/80, matcher 200, deregistration delay 30
- [ ] Listener HTTP:80, default action forwards to `usms-enrolment-tg`
- [ ] Rule at priority 10 matching `/alb-health` with fixed-response 200
- [ ] Service has exactly one `loadBalancers` entry, `enrolment-api`/80
- [ ] `healthCheckGracePeriodSeconds` = 60
- [ ] `usms-enrolment-sg` admits tcp/80 from `usms-alb-sg` only (cutover done)
- [ ] Task definition unchanged at `usms-enrolment:2`

**Evidence**
- [ ] All 19 step screenshots pasted above
- [ ] `outputs/lab-05-pre-deploy.txt` / `post-deploy.txt` captured
- [ ] `PERSISTENCE PROVEN` line captured
- [ ] `CUTOVER CONFIRMED` / `LOOP CLOSED` lines captured

**Hygiene**
- [ ] `configs/lab-05.env` committed, 15 exports, no empty/`None` values
- [ ] `verify-lab-05.sh` reports `PASS=49 FAIL=0` (or documented benign failures)
- [ ] `verify-lab-04.sh` reports `PASS=48 FAIL=1` (expected) or `FAIL=0` (if Exercise 2 done)
- [ ] `scripts/cleanup/lab-05-cleanup.sh` passes `bash -n` and was **not** run
- [ ] `git status --short` shows nothing under `outputs/`
- [ ] Review Questions answered in Section 10 above

---

*End of Lab 05 Practical Report.*
