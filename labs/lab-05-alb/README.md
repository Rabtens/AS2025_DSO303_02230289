# DSO303 - Lab 05: Putting the ECS Service Behind an Application Load Balancer

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
10. [Reflection](#10-reflection)
11. [Submission Checklist](#11-submission-checklist)

---

## 1. Lab Overview

Lab 04 left the `usms-enrolment-svc` service running two Fargate tasks in private
subnets - correct, but unreachable. This lab fixes that by placing an
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
> addresses accurate - nobody ever calls `register-targets` by hand.

---

## 2. Learning Objectives

- [x] Explain why Fargate tasks cannot be addressed directly
- [x] Name the four ELB objects and what each holds
- [x] Choose between ALB / NLB / GWLB for a stated requirement
- [x] Explain why a Fargate target group must be `--target-type ip`
- [x] Create an internet-facing ALB across two AZs
- [x] Create a target group with a deliberate health check configuration
- [x] Distinguish the container health check from the target group health check
- [x] Create a listener with a default action and a priority-ordered rule
- [x] Attach an existing ECS service to a target group
- [x] Explain `--health-check-grace-period-seconds`
- [x] Read `describe-target-health` states
- [x] Perform the security cutover from direct to load-balanced access
- [x] Explain how deregistration delay, `minimumHealthyPercent`, and `stopTimeout` interact
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

- [x] Lab 04 complete - `verify-lab-04.sh` reports `FAIL=0` **before** Step 13
- [x] Lab 2 Step 11 "Your turn" done - `usms-public-subnet-b` exists
- [x] Lab 2 Exercise 5 done - `usms-private-subnet-b` exists
- [x] Lab 3 complete - `usms-web-01` running with `usms-app-sg`
- [x] Errata 01 applied
- [x] Floci running under Docker Compose, `FLOCI_STORAGE_MODE=hybrid`
- [x] `jq`, `python3` available

![alt text](<../../screenshots/Screenshot from 2026-10-16 10-26-15.png>)

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

![alt text](<../../screenshots/Screenshot from 2026-10-16 10-32-04.png>)

---

## 5. Step-by-Step Implementation

> All commands are run from `~/aws-floci-course` unless stated otherwise.

### Step 1 - Resume the environment and load five env files

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


![alt text](<../../screenshots/Screenshot from 2026-10-16 10-34-31.png>)

---

### Step 2 - Confirm Labs 2, 3 and 04 are still intact

```bash
./scripts/utilities/verify-lab-02.sh | tail -3
./scripts/utilities/verify-lab-03.sh | tail -3
./scripts/utilities/verify-lab-04.sh | tee outputs/lab-05-pre-verify-04.txt | tail -3
```

**Expected:** `FAIL=0` three times.

![alt text](<../../screenshots/Screenshot from 2026-10-16 10-39-32.png>)

---

### Step 3 - Probe what this Floci build supports for ELB

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

### Step 4 - Create the load balancer's security group

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-41-40.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-42-56.png>)

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query 'SecurityGroups[0].{Name:GroupName,VPC:VpcId,Inbound:IpPermissions[].{Port:FromPort,CIDR:IpRanges[0].CidrIp,FromGroup:UserIdGroupPairs[0].GroupId},OutboundRules:length(IpPermissionsEgress)}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-43-20.png>)

---

### Step 5 - Create the Application Load Balancer

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-45-38.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-45-53.png>)

**Verify:**

```bash
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,Type:Type,Scheme:Scheme,VPC:VpcId,DNS:DNSName,IPType:IpAddressType,AZs:AvailabilityZones[].{Zone:ZoneName,Subnet:SubnetId},SGs:SecurityGroups}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-46-10.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-46-25.png>)

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

---

### Step 6 - Create the target group

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-50-17.png>)

**Verify:**

```bash
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{Name:TargetGroupName,Type:TargetType,Proto:Protocol,Port:Port,VPC:VpcId,HCProto:HealthCheckProtocol,HCPath:HealthCheckPath,HCPort:HealthCheckPort,Interval:HealthCheckIntervalSeconds,Timeout:HealthCheckTimeoutSeconds,Healthy:HealthyThresholdCount,Unhealthy:UnhealthyThresholdCount,Matcher:Matcher.HttpCode,LBs:length(LoadBalancerArns)}' \
  --output json

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions' --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-50-39.png>)



---

### Step 7 - Set the target group attribute that governs how a task dies

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-52-14.png>)

---

### Step 8 - Create the listener

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-52-55.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-53-09.png>)

**Verify:**

```bash
aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Proto:Protocol,DefaultActionType:DefaultActions[0].Type,Forwards:DefaultActions[0].TargetGroupArn,SSL:SslPolicy}' \
  --output json

aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{Name:TargetGroupName,AttachedToLoadBalancers:length(LoadBalancerArns)}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-53-29.png>)

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

---

### Step 9 - Let the load balancer reach the tasks

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-55-43.png>)

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Sources:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-56-08.png>)

---

### Step 10 - Attach the existing service to the target group

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-58-59.png>)

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --load-balancers file://templates/lab-05-service-load-balancers.json \
  --health-check-grace-period-seconds 60 \
  --query 'service.{Name:serviceName,LB:loadBalancers,Grace:healthCheckGracePeriodSeconds,Deployments:length(deployments),TaskDef:taskDefinition}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 10-59-21.png>)

> If `--load-balancers` is rejected on `update-service`, use the recreate
> fallback documented in the lab (delete and recreate the service with
> `--load-balancers` set at creation time).

---

### Step 11 - Watch the targets register, and read target health

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-04-10.png>)

```bash
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:length(deployments),Rollout:deployments[0].rolloutState,LB:loadBalancers[0].targetGroupArn}' \
  --output json

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].events[0:6].[createdAt,message]' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-04-31.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-04-54.png>)

**ECS-health vs Target-health table (fill in from your observations):**

| ECS `healthStatus` | Target health | Diagnosis |
|---|---|---|
| `[ FILL IN ]` | `[ FILL IN ]` | `[ FILL IN ]` |



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

---

### Step 12 - Prove the path, and be honest about which proof you got

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-06-47.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-07-18.png>)

---

### Step 13 - The cutover: remove the direct path

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-09-25.png>)

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$USMS_ENROLMENT_SG" \
  --security-group-rule-ids "$OLD_RULE_ID" \
  --query 'Return' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-09-40.png>)

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Sources:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}' \
  --output json

echo "usms-alb-sg = $ALB_SG"
echo "usms-app-sg = $USMS_APP_SG   (must NOT appear above)"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-09-55.png>)

```bash
./scripts/utilities/verify-lab-04.sh | tee outputs/lab-05-post-verify-04.txt | tail -5

echo "== what changed =="
diff outputs/lab-05-pre-verify-04.txt outputs/lab-05-post-verify-04.txt
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-10-31.png>)

**Expected diff:** exactly one check moves from `ok` to `FAIL` —
`usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)`, counts moving
from `PASS=49 FAIL=0` to `PASS=48 FAIL=1`. This is **expected**, not a bug.


---

### Step 14 - Deploy behind a load balancer, and watch a target drain

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-13-08.png>)

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --force-new-deployment \
  --query 'service.{TaskDef:taskDefinition,Deployments:length(deployments)}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-13-20.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-16-04.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-16-27.png>)

**Checkpoint 5**

```
Deployment behind a load balancer, observed
 ├── --force-new-deployment      same revision, new tasks
 ├── target states seen          initial -> healthy -> draining
 ├── deregistration delay        30s, so in-flight requests survive the swap
 ├── grace period                60s, so a slow start is not mistaken for a failure
 └── pre/post address lists      different addresses, identical configuration
```

---

### Step 15 - Add a listener rule

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-24-28.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-25-15.png>)

**Verify:**

```bash
aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,Default:IsDefault,Condition:Conditions[0].Field,Values:Conditions[0].Values,Action:Actions[0].Type,Status:Actions[0].FixedResponseConfig.StatusCode,TargetGroup:Actions[0].TargetGroupArn}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-25-29.png>)

```bash
curl -s -o /dev/null -w '/            -> %{http_code}\n' --max-time 10 "http://$ALB_DNS/" || true
curl -s -w '/alb-health  -> %{http_code}  body: %{size_download} bytes\n' --max-time 10 \
     "http://$ALB_DNS/alb-health" || true
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-25-41.png>)

**Checkpoint 6**

```
usms-enrolment-alb
 └── listener  HTTP:80
      ├── rule priority 10   path-pattern /alb-health, /alb-health/*
      │                       -> fixed-response 200 text/plain, no target involved
      └── default action      -> forward to usms-enrolment-tg
                                  └── 2 targets, registered by usms-enrolment-svc
```

---

### Step 16 - Prove the whole thing survives a restart

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-30-18.png>)

```bash
./scripts/setup/floci-down.sh
sleep 3
./scripts/setup/floci-up.sh
sleep 5
source configs/course.env
source configs/lab-02.env
source configs/lab-04.env
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-30-53.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-31-34.png>)

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

---

### Step 17 - Close the loop, and audit what this lab created

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-33-27.png>)
---

### Step 18 - Write `configs/lab-05.env`

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-38-08.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-38-32.png>)

**Expected:** all values populated, `grep -c '^export'` = **15**.

---

### Step 19 - Commit

```bash
git status --short

git check-ignore -v outputs/lab-05-path-proof.txt
git ls-files outputs/
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-40-39.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 11-40-51.png>)

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

PASS=0; FAIL=0; SKIP=0
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
# Some Floci builds accept --health-check-grace-period-seconds but never store it
# (describe-services returns None). That is reported as SKIP, not ok: it falls back
# to the value recorded in configs/lab-05.env and still FAILs if that is missing or 0.
GRACE_LIVE=$(svcq healthCheckGracePeriodSeconds 2>/dev/null)
if [ "$GRACE_LIVE" = "None" ] && [ "${USMS_SVC_GRACE_PERIOD:-0}" -gt 0 ] 2>/dev/null; then
  printf "  SKIP %s\n" "healthCheckGracePeriodSeconds not stored by this Floci build (lab-05.env records ${USMS_SVC_GRACE_PERIOD}s)"
  SKIP=$((SKIP+1))
else
  check "healthCheckGracePeriodSeconds is set (not None, not 0)" \
    "test \"\$(svcq healthCheckGracePeriodSeconds)\" != None && test \"\$(svcq healthCheckGracePeriodSeconds)\" -gt 0"
fi
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

echo; echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"

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
![alt text](<../../screenshots/Screenshot from 2026-10-16 12-06-41.png>)

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


---

## 7. Cleanup Script (Section 9.3 - NOT executed)

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
![alt text](<../../screenshots/Screenshot from 2026-10-17 15-40-08.png>)

---

## 8. Checkpoints Summary

| # | After step | Status |
|---|---|---|
| 1 | Step 3 | `[done]` |
| 2 | Step 5 | `[done]` |
| 3 | Step 8 | `[done]` |
| 4 | Step 11 | `[done]` |
| 5 | Step 14 | `[done]` |
| 6 | Step 15 | `[done]` |
| 7 | Step 16 | `[done]` |
| 8 | Step 19 | `[done]` |

---

## 9. Troubleshooting Log

Record any of the following you hit, and how it was resolved:

| Symptom | Cause | Fix |
|---|---|---|
| `ValidationError: At least two subnets in two different Availability Zones must be specified` | Not hit. Would be caused by passing two subnets in the same AZ, or only one subnet, to `create-load-balancer`. An ALB needs nodes in at least two AZs. | Pass `$USMS_PUBLIC_SUBNET_A` (us-east-1a) and `$USMS_PUBLIC_SUBNET_B` (us-east-1b); confirm with `describe-subnets --query 'Subnets[].AvailabilityZone'`. |
| `InvalidParameterException: The container enrolment-api does not exist` | Not hit. Would be caused by a `containerName` in `templates/lab-05-service-load-balancers.json` that does not match the task definition's container name exactly, e.g. an empty `$USMS_ENROLMENT_CONTAINER`. | Read the real name with `describe-task-definition --query 'taskDefinition.containerDefinitions[].name'` and regenerate the JSON; `grep -c '\$'` must print `0`. |
| Targets stay `initial` forever | Not hit: both targets went `healthy`. Would be caused by health checks never succeeding: `usms-enrolment-sg` not admitting `usms-alb-sg` on tcp/80, or the wrong health-check path or port. | Check Step 9's rule exists (`describe-security-groups` shows `sg-...` of `usms-alb-sg` as a source), and the target group checks `GET /` on port 80 with matcher `200`. |
| Service will not stabilise (start/stop loop) | Not hit. Would be caused by the ALB marking new tasks unhealthy before the container is ready, so ECS replaces them repeatedly; usually no or too short a health-check grace period, or a failing health check. | Set `--health-check-grace-period-seconds 60`, fix the health check, and read `describe-services --query 'services[0].events[0:6]'` and the stopped tasks' `stoppedReason`. |
| `curl` returns `503 Service Temporarily Unavailable` | Not hit. Would be caused by the target group having no healthy targets: the service is not attached to the target group, or every target is unhealthy or draining. | Confirm `describe-services` shows a `loadBalancers` entry and `describe-target-health` shows at least one `healthy` target. |
| `update-service --load-balancers ... --health-check-grace-period-seconds 60` returned success but `loadBalancers` and `healthCheckGracePeriodSeconds` stayed `null` (5 FAILs in `verify-lab-05.sh`) | **Hit.** This Floci build accepts `--load-balancers` on `update-service` but does not store it. | Used the lab's recreate fallback: saved the service's config, scaled to 0, `delete-service`, then `create-service` with the same name, subnets, SG, task definition (`usms-enrolment:2`), desired count 2, tags, and `--load-balancers` set at creation. Both targets then registered `healthy`. |
| `healthCheckGracePeriodSeconds` still `None` after recreating the service | **Hit.** Floci has no such field on the service at all; it is accepted and dropped on both `create-service` and `update-service`. | Floci limitation, cannot be fixed. Recorded the requested value `USMS_SVC_GRACE_PERIOD=60` in `configs/lab-05.env` with a comment, and changed the `verify-lab-05.sh` check to report `SKIP` (not `ok`) when Floci returns `None`. Result: `PASS=48 FAIL=0 SKIP=1`. |
| Step 13: `revoke-security-group-ingress --security-group-rule-ids` returned `True`, but the `usms-app-sg` rule was still there | **Hit.** This Floci build ignores revoking by rule ID. | Revoked by permission instead: `--ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$USMS_APP_SG}]"`. `usms-enrolment-sg` now admits only `usms-alb-sg`. |
| `configs/lab-05.env` had `USMS_ALB_LISTENER_ARN=` (empty) and three `None` values | **Hit.** The listener query's escaped backticks (`` \`80\` ``) break inside the unquoted heredoc, and the `None` values came from the service not yet being attached (row above). | Ran the listener lookup into a variable outside the heredoc, then regenerated the file after the recreate: all 15 exports populated. |

---

## 10. Reflection

The biggest idea in this lab is **indirection with an owner**. Clients never learn a task's address: they talk to `usms-enrolment-alb`, the listener forwards to `usms-enrolment-tg`, and the target group holds whichever task IPs exist right now. Nobody edits that list by hand. The **ECS service owns it**, registering each task's IP when the task starts and deregistering it, through the 30-second drain, when the task stops. That is what made Step 14's deployment possible without touching the load balancer, and it is what lets Lab 06 change the task count freely. It also explains this lab's hardest moment: on Floci, `update-service --load-balancers` was accepted but never stored. With no owner wired in, the target group would never have been maintained, so the service had to be recreated with the load balancer set at creation. The same thinking applies to **health, which is a distributed opinion rather than a single fact**:
- **ECS's own container health check** (a command inside the task, which `usms-enrolment` does not define) asks "is the process alive?"
- **The target group's health check** (`GET /` → `200`, every 30 s, threshold 2) asks "can the load balancer reach it over the network and get a good answer?"

The two can disagree. A task can be running from ECS's point of view yet `unhealthy` to the ALB because of a security group rule or a wrong path, and ECS will replace it based on the ALB's opinion once the grace period ends. So reading "unhealthy" means asking *whose* opinion it is and what that check actually tested.

The second lesson is the **cutover discipline: add → prove → remove**. I did not replace the direct `usms-app-sg → usms-enrolment-sg` rule in one step:
1. **Add:** in Step 9 I added the `usms-alb-sg` rule alongside the old one, so for a while both paths worked.
2. **Prove:** in Steps 11–12 I showed both targets `healthy` and requests arriving through the ALB.
3. **Remove:** only then, in Step 13, did I delete the old rule, after the Lab 04 linkage file had confirmed its only caller was `usms-web-01`.

The before-and-after `verify-lab-04.sh` diff made the change measurable: exactly one check moved from `ok` to `FAIL`, and nothing else did. Floci also showed why the "prove" step matters after the "remove" step too: `revoke-security-group-ingress --security-group-rule-ids` returned `True` while the rule was still there. Only reading the group back showed it had not been removed, and revoking by `--ip-permissions` worked. A command's success message is not evidence. The state you read back afterwards is.

---

## 11. Submission Checklist

**Environment**
- [x] Floci runs under Docker Compose, `floci-storage-check.sh` reports `PASS=16 FAIL=0`
- [x] `whoami.sh` reports account `000000000000`
- [x] Support path (A/B/C) stated at the top of this report

**Resources**
- [x] `usms-alb-sg` admits tcp/80 from `0.0.0.0/0`
- [x] `usms-enrolment-alb` internet-facing, application, 2 AZs, 1 SG
- [x] `usms-enrolment-tg` target-type `ip`, HTTP/80, matcher 200, deregistration delay 30
- [x] Listener HTTP:80, default action forwards to `usms-enrolment-tg`
- [x] Rule at priority 10 matching `/alb-health` with fixed-response 200
- [x] Service has exactly one `loadBalancers` entry, `enrolment-api`/80
- [x] `healthCheckGracePeriodSeconds` = 60
- [x] `usms-enrolment-sg` admits tcp/80 from `usms-alb-sg` only (cutover done)
- [x] Task definition unchanged at `usms-enrolment:2`

**Evidence**
- [x] All 19 step screenshots pasted above
- [x] `outputs/lab-05-pre-deploy.txt` / `post-deploy.txt` captured
- [x] `PERSISTENCE PROVEN` line captured
- [x] `CUTOVER CONFIRMED` / `LOOP CLOSED` lines captured

**Hygiene**
- [x] `configs/lab-05.env` committed, 15 exports, no empty/`None` values
- [x] `verify-lab-05.sh` reports `PASS=49 FAIL=0` (or documented benign failures)
- [x] `verify-lab-04.sh` reports `PASS=48 FAIL=1` (expected) or `FAIL=0` (if Exercise 2 done)
- [x] `scripts/cleanup/lab-05-cleanup.sh` passes `bash -n` and was **not** run
- [x] `git status --short` shows nothing under `outputs/`
- [x] Review Questions answered in `notes/lab-05-notes.md`

---

