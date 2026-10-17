# DSO303 - Lab 04: Amazon ECS (USMS Enrolment Service on Fargate)

---

## 1. Objective

Containerise the USMS enrolment service onto **Amazon ECS running on Fargate**, inside the private subnets built in Lab 02. This lab builds:

- An ECS **cluster** (`usms-ecs-cluster`)
- A CloudWatch Logs **log group** (`/usms/ecs/enrolment`)
- Two IAM roles: a **task execution role** (`usms-ecs-exec-role`) and a **task role** (`usms-ecs-task-role`)
- A **security group** (`usms-enrolment-sg`) sourced from the web tier's security group
- A **task definition** (`usms-enrolment`, awsvpc, FARGATE, 256 CPU / 512 MiB)
- A **service** (`usms-enrolment-svc`) with `desiredCount = 2`, spread across two Availability Zones

This lab does **not** implement auto scaling - that is Lab 06's job. `desiredCount` is set once, by hand, and stays fixed.

---

## 2. Prerequisites Checklist

- [x] Lab 1 complete (`usms-developer-role`, `USMSStudentDataReadWrite`, IAM foundation)
- [x] Lab 2 complete, including Exercise 5 (both private subnets exist)
- [x] Lab 3 complete (`usms-app-sg` attached to running `usms-web-01`)
- [x] `./scripts/utilities/verify-lab-02.sh` → `FAIL=0`
- [x] `./scripts/utilities/verify-lab-03.sh` → `FAIL=0`
- [x] Floci running under Docker Compose, `FLOCI_STORAGE_MODE=hybrid`
- [x] `jq`, `python3`, `docker` available

### Check tools

```bash
cd ~/aws-floci-course
for t in jq python3 docker; do printf '%-10s ' "$t"; command -v "$t" || echo MISSING; done
aws --version
```
![alt text](<../../screenshots/Screenshot from 2026-10-04 15-07-25.png>)

---

## 3. Directory Structure Added in This Lab

```
aws-floci-course/
├── labs/
│   └── lab-04-ecs/
│       ├── README.md
│       └── exercises.md
├── policies/
│   ├── trust-ecs-tasks.json
│   └── usms-ecs-task-execution-policy.json
├── templates/
│   └── lab-04-taskdef.json
├── configs/
│   └── lab-04.env
├── scripts/
│   ├── utilities/
│   │   └── verify-lab-04.sh
│   └── cleanup/
│       └── lab-04-cleanup.sh
└── outputs/
    └── lab-04-*.json / *.txt   (git-ignored)
```

```bash
cd ~/aws-floci-course
mkdir -p labs/lab-04-ecs
ls -d labs/*
```

---
## Architecture

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-31-34.png>)

## 4. Step-by-Step Implementation

> Run every command below from the repository root: `aws-floci-course/`

### Step 1 - Resume the environment and load three env files

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env

./scripts/utilities/whoami.sh

printf '%-26s %s\n' \
  "private subnet a"    "$USMS_PRIVATE_SUBNET_A" \
  "private subnet b"    "$USMS_PRIVATE_SUBNET_B" \
  "app security group"  "$USMS_APP_SG" \
  "vpc"                 "$USMS_VPC_ID" \
  "nat gateway"         "$USMS_NAT_GW" \
  "web instance"        "$USMS_WEB_INSTANCE" \
  "region"              "$AWS_REGION_COURSE" \
  "account"             "$ACCOUNT_ID"
```

**Verify:** all eight values are non-empty. If "private subnet b" is empty, go back and complete Lab 2 Exercise 5.

![alt text](<../../screenshots/Screenshot from 2026-10-04 15-36-19.png>)

![alt text](<../../screenshots/Screenshot from 2026-10-04 15-36-47.png>)

---

### Step 2 - Confirm Labs 2 and 3 are still intact

```bash
./scripts/utilities/verify-lab-02.sh
./scripts/utilities/verify-lab-03.sh
```

**Expected:** `PASS=33 FAIL=0` and `PASS=48 FAIL=0`.

![alt text](<../../screenshots/Screenshot from 2026-10-04 16-01-27.png>)

![alt text](<../../screenshots/Screenshot from 2026-10-04 16-01-44.png>)

---

### Step 3 - Probe what this Floci build actually supports

```bash
probe() {
  printf '%-46s ' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "SUPPORTED"; else echo "not available"; fi
}

echo "== ECS =="
probe "ecs list-clusters"                "aws ecs list-clusters"
probe "ecs register-task-definition"     "aws ecs register-task-definition --generate-cli-skeleton"
probe "ecs describe-services"            "aws ecs describe-services --cluster probe --services probe"

echo "== Application Auto Scaling =="
probe "describe-scalable-targets"        "aws application-autoscaling describe-scalable-targets --service-namespace ecs"
probe "describe-scaling-policies"        "aws application-autoscaling describe-scaling-policies --service-namespace ecs"
probe "describe-scheduled-actions"       "aws application-autoscaling describe-scheduled-actions --service-namespace ecs"

echo "== CloudWatch =="
probe "cloudwatch put-metric-data"       "aws cloudwatch put-metric-data --namespace USMS/Probe --metric-name Probe --value 1"
probe "cloudwatch describe-alarms"       "aws cloudwatch describe-alarms"
probe "cloudwatch set-alarm-state"       "aws cloudwatch describe-alarms --max-items 1"

echo "== CloudWatch Logs =="
probe "logs describe-log-groups"         "aws logs describe-log-groups"
```

**Record your support path** (write it in `notes/lab-04-notes.md`):

| Path | If | What changes |
|---|---|---|
| A - full | ECS and Application Auto Scaling both supported | Do every step as written |
| B - ECS only | ECS supported, Application Auto Scaling not | Unaffected until Lab 06 |
| C - neither | ECS not supported | Stop; tell instructor; do Exercise 4's paper design only |

![alt text](<../../screenshots/Screenshot from 2026-10-04 16-05-16.png>)

#### Checkpoint 1

```
Ready to build
 ├── Floci running under Compose, storage mode hybrid
 ├── course.env + lab-01.env + lab-02.env + lab-03.env sourced
 ├── verify-lab-02.sh FAIL=0 and verify-lab-03.sh FAIL=0
 └── support path recorded: A (full) / B (ECS only) / C (neither)
```

---

### Step 4 - Create the ECS cluster, as the developer role

**Part 1 - assume the developer role**

```bash
# Load course variables (ACCOUNT_ID, USMS_ROLE_DEVELOPER, ...) into this shell
for f in configs/course.env configs/lab-0{1,2,3}.env; do [ -f "$f" ] && source "$f"; done

# USMS_ROLE_DEVELOPER (lab-01.env) is already a full role ARN
ROLE_ARN="$USMS_ROLE_DEVELOPER"
echo "Assuming: $ROLE_ARN"

# Clear any old assumed-role credentials so --profile usms-dev is used
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "lab04-ecs-build" \
  --profile usms-dev \
  > outputs/lab-04-assumed-role.json

chmod 600 outputs/lab-04-assumed-role.json

export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId'     outputs/lab-04-assumed-role.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' outputs/lab-04-assumed-role.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken'    outputs/lab-04-assumed-role.json)

# AWS CLI v1 has no --no-cli-pager flag; AWS_PAGER="" does the same on v2
AWS_PAGER="" aws sts get-caller-identity
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-45-34.png>)




**Part 2 – create the cluster**

```bash
CLUSTER_NAME="usms-ecs-cluster"

CLUSTER_ARN=$(aws ecs create-cluster \
  --cluster-name "$CLUSTER_NAME" \
  --settings name=containerInsights,value=enabled \
  --tags key=Name,value=usms-ecs-cluster key=Project,value=USMS key=Tier,value=app \
  --query 'cluster.clusterArn' \
  --output text)

echo "CLUSTER_ARN = $CLUSTER_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-46-33.png>)


**Part 3 - restore your normal identity**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
./scripts/utilities/whoami.sh
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-50-06.png>)

**Verify**

```bash
aws ecs describe-clusters \
  --clusters "$CLUSTER_NAME" \
  --include SETTINGS \
  --query 'clusters[0].{Name:clusterName,Status:status,Services:activeServicesCount,Tasks:runningTasksCount,Settings:settings}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-50-14.png>)

---

### Step 5 - Create the log group the tasks will write to

```bash
LOG_GROUP="/usms/ecs/enrolment"

aws logs create-log-group \
  --log-group-name "$LOG_GROUP" \
  --tags Project=USMS,Name=usms-enrolment-logs,Tier=app

aws logs put-retention-policy \
  --log-group-name "$LOG_GROUP" \
  --retention-in-days 7

aws logs describe-log-groups \
  --log-group-name-prefix /usms \
  --query 'logGroups[].{Name:logGroupName,Retention:retentionInDays,Bytes:storedBytes}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-51-38.png>)

**Verify:** one row, `Retention` exactly `7`.

---

### Interlude - Task execution role vs. task role

| | Task execution role | Task role |
|---|---|---|
| Assumed by | ECS agent / Fargate infrastructure | Application code inside the container |
| Used for | Pulling the image, writing logs, reading secrets | Whatever the app does (S3, DynamoDB, SQS…) |
| Trust principal | `ecs-tasks.amazonaws.com` | `ecs-tasks.amazonaws.com` |
| Field in task def | `executionRoleArn` | `taskRoleArn` |
| Failure symptom | Task never starts | Task starts, code gets `AccessDenied` |

---

### Step 6 - Create the task execution role

**Part 1 - trust policy**

```bash
cat > policies/trust-ecs-tasks.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEcsTasksToAssumeThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

python3 -m json.tool policies/trust-ecs-tasks.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-53-13.png>)

**Part 2 - create the role**

```bash
EXEC_ROLE_NAME="usms-ecs-exec-role"

EXEC_ROLE_ARN=$(aws iam create-role \
  --role-name "$EXEC_ROLE_NAME" \
  --assume-role-policy-document file://policies/trust-ecs-tasks.json \
  --description "ECS task execution role: pulls images and writes log streams for USMS tasks" \
  --tags Key=Name,Value=usms-ecs-exec-role Key=Project,Value=USMS Key=Tier,Value=app \
  --query 'Role.Arn' \
  --output text)

echo "EXEC_ROLE_ARN = $EXEC_ROLE_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-53-27.png>)

**Part 3 - least-privilege permissions**

```bash
cat > policies/usms-ecs-task-execution-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PullContainerImages",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WriteTaskLogsToItsOwnGroupOnly",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:us-east-1:000000000000:log-group:/usms/ecs/enrolment:*"
    }
  ]
}
EOF

python3 -m json.tool policies/usms-ecs-task-execution-policy.json > /dev/null && echo "valid JSON"

EXEC_POLICY_ARN=$(aws iam create-policy \
  --policy-name USMSECSTaskExecution \
  --policy-document file://policies/usms-ecs-task-execution-policy.json \
  --description "Least-privilege ECS execution role permissions for the USMS enrolment service" \
  --query 'Policy.Arn' \
  --output text)

aws iam attach-role-policy \
  --role-name "$EXEC_ROLE_NAME" \
  --policy-arn "$EXEC_POLICY_ARN"

echo "EXEC_POLICY_ARN = $EXEC_POLICY_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-54-02.png>)

**Verify**

```bash
aws iam get-role --role-name "$EXEC_ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal' --output json

aws iam list-attached-role-policies --role-name "$EXEC_ROLE_NAME" \
  --query 'AttachedPolicies[].PolicyName' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-54-27.png>)

Check: principal is `{"Service": "ecs-tasks.amazonaws.com"}` (not `ecs.amazonaws.com`); attached policy list contains `USMSECSTaskExecution`.

---

### Step 7 - Create the task role, and reuse Lab 1's policy on it

```bash
TASK_ROLE_NAME="usms-ecs-task-role"

TASK_ROLE_ARN=$(aws iam create-role \
  --role-name "$TASK_ROLE_NAME" \
  --assume-role-policy-document file://policies/trust-ecs-tasks.json \
  --description "USMS enrolment container identity: reads and writes student transcripts in S3" \
  --tags Key=Name,Value=usms-ecs-task-role Key=Project,Value=USMS Key=Tier,Value=app \
  --query 'Role.Arn' \
  --output text)

echo "TASK_ROLE_ARN = $TASK_ROLE_ARN"

aws iam attach-role-policy \
  --role-name "$TASK_ROLE_NAME" \
  --policy-arn "$USMS_POLICY_S3_RW"   # already a full ARN (lab-01.env)

aws iam list-attached-role-policies --role-name "$TASK_ROLE_NAME" \
  --query 'AttachedPolicies[].{Policy:PolicyName,Arn:PolicyArn}' --output table
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 00-56-28.png>)

**Verify - and read the policy back**

```bash
POLICY_ARN="$USMS_POLICY_S3_RW"   # already a full ARN (lab-01.env)
DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
  --query 'Policy.DefaultVersionId' --output text)

aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$DEFAULT_VERSION" \
  --query 'PolicyVersion.Document' --output json | tee outputs/lab-04-task-role-policy.json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-00-04.png>)

Confirm this is the same `USMSStudentDataReadWrite` document Lab 3 Step 11 printed - reused unchanged, now on two different compute mechanisms (instance profile vs. task role).

#### Checkpoint 2

```
usms-ecs-cluster  (ACTIVE, 0 services, 0 tasks)
 ├── /usms/ecs/enrolment           log group, 7-day retention
 ├── usms-ecs-exec-role            trusts ecs-tasks.amazonaws.com
 │    └── USMSECSTaskExecution     ecr pull + logs write to ONE group
 └── usms-ecs-task-role            trusts ecs-tasks.amazonaws.com
      └── USMSStudentDataReadWrite  <- Lab 01's policy, unchanged, reused
```

---

### Step 8 - Create the enrolment security group (sourced from the web tier's group)

```bash
ENROLMENT_SG=$(aws ec2 create-security-group \
  --group-name usms-enrolment-sg \
  --description "USMS enrolment service tasks: HTTP from the web tier security group only" \
  --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-enrolment-sg},{Key=Project,Value=USMS},{Key=Tier,Value=app}]' \
  --query 'GroupId' \
  --output text)

echo "ENROLMENT_SG = $ENROLMENT_SG"

cat > policies/usms-enrolment-sg-ingress.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "UserIdGroupPairs": [
      {
        "GroupId": "$USMS_APP_SG",
        "Description": "HTTP from the USMS web tier (usms-app-sg) - the only caller of the enrolment API"
      }
    ]
  }
]
EOF

aws ec2 authorize-security-group-ingress \
  --group-id "$ENROLMENT_SG" \
  --ip-permissions file://policies/usms-enrolment-sg-ingress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' \
  --output text
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-01-42.png>)

> This heredoc is **unquoted** (`<< EOF`) because `$USMS_APP_SG` must be substituted at write time.

**Verify**

```bash
aws ec2 describe-security-groups --group-ids "$ENROLMENT_SG" \
  --query 'SecurityGroups[0].{Name:GroupName,Inbound:IpPermissions[].{Port:FromPort,FromGroup:UserIdGroupPairs[0].GroupId,FromCIDR:IpRanges[0].CidrIp},OutboundRules:length(IpPermissionsEgress)}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-02-08.png>)

Look for: one inbound rule on port 80, `FromGroup` = your `$USMS_APP_SG`, `FromCIDR` = null, `OutboundRules` = 1.

---

### Step 9 - Write and register the task definition

**Part 1 - write the document**

```bash
cat > templates/lab-04-taskdef.json << EOF
{
  "family": "usms-enrolment",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "containerDefinitions": [
    {
      "name": "enrolment-api",
      "image": "public.ecr.aws/nginx/nginx:stable-alpine",
      "essential": true,
      "portMappings": [
        { "containerPort": 80, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "USMS_SERVICE",  "value": "enrolment" },
        { "name": "USMS_BUCKET",   "value": "usms-student-data" },
        { "name": "AWS_REGION",    "value": "$AWS_REGION_COURSE" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$AWS_REGION_COURSE",
          "awslogs-stream-prefix": "enrolment"
        }
      }
    }
  ],
  "tags": [
    { "key": "Name",    "value": "usms-enrolment" },
    { "key": "Project", "value": "USMS" },
    { "key": "Tier",    "value": "app" },
    { "key": "Lab",     "value": "04" }
  ]
}
EOF

python3 -m json.tool templates/lab-04-taskdef.json > /dev/null \
  && echo "valid JSON" || echo "INVALID JSON - fix it before registering"

grep -c '\$' templates/lab-04-taskdef.json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-07-09.png>)

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-07-52.png>)

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-08-03.png>)

> The `grep -c '\$'` count **must print `0`** — any other number means a variable was empty or the heredoc quoting was wrong.

**Part 2 – register it**

```bash
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://templates/lab-04-taskdef.json \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

TASK_DEF_REVISION=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment \
  --query 'taskDefinition.revision' \
  --output text)

echo "TASK_DEF_ARN      = $TASK_DEF_ARN"
echo "TASK_DEF_REVISION = $TASK_DEF_REVISION"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-09-15.png>)

**Verify**

```bash
aws ecs describe-task-definition --task-definition usms-enrolment \
  --query 'taskDefinition.{Family:family,Revision:revision,Status:status,Network:networkMode,CPU:cpu,Memory:memory,Compat:requiresCompatibilities,Exec:executionRoleArn,Task:taskRoleArn,Container:containerDefinitions[0].name,Image:containerDefinitions[0].image,LogGroup:containerDefinitions[0].logConfiguration.options."awslogs-group"}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-09-28.png>)

Check: `Status = ACTIVE`, `Network = awsvpc`, `Exec` and `Task` are **two different** ARNs.



#### Checkpoint 3

```
usms-enrolment:1   ACTIVE
 ├── FARGATE, awsvpc, 256 CPU / 512 MiB
 ├── container enrolment-api  ->  public.ecr.aws/nginx/nginx:stable-alpine  :80
 ├── executionRoleArn  usms-ecs-exec-role
 ├── taskRoleArn       usms-ecs-task-role
 └── logs -> /usms/ecs/enrolment, stream prefix "enrolment"
```
---

### Step 10 - Create the service in Lab 2's private subnets

```bash
SERVICE_NAME="usms-enrolment-svc"

SERVICE_ARN=$(aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --task-definition usms-enrolment \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A,$USMS_PRIVATE_SUBNET_B],securityGroups=[$ENROLMENT_SG],assignPublicIp=DISABLED}" \
  --enable-ecs-managed-tags \
  --propagate-tags SERVICE \
  --tags key=Name,value=usms-enrolment-svc key=Project,value=USMS key=Tier,value=app key=Lab,value=04 \
  --query 'service.serviceArn' \
  --output text)

echo "SERVICE_ARN = $SERVICE_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-10-59.png>)

> If `--network-configuration` shorthand rejects the syntax, generate the skeleton and use a JSON document instead:
> ```bash
> aws ecs create-service --generate-cli-skeleton > outputs/lab-04-create-service-skeleton.json
> ```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-11-20.png>)

**Wait for it to stabilise**

```bash
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  && echo "service stable" \
  || echo "waiter did not complete - check the state manually below (expected on some builds)"
```

If the waiter hangs, `Ctrl+C` and poll manually:

```bash
for i in $(seq 1 12); do
  read -r d r p <<< "$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text)"
  echo "attempt $i: desired=$d running=$r pending=$p"
  [ "$d" = "$r" ] && break
  sleep 5
done
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-12-54.png>)

---

### Step 11 - Read the service back, and learn the four numbers

```bash
aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --query 'services[0].{
      Name:serviceName,
      Status:status,
      Desired:desiredCount,
      Running:runningCount,
      Pending:pendingCount,
      TaskDef:taskDefinition,
      Launch:launchType,
      Subnets:networkConfiguration.awsvpcConfiguration.subnets,
      SG:networkConfiguration.awsvpcConfiguration.securityGroups,
      PublicIP:networkConfiguration.awsvpcConfiguration.assignPublicIp
    }' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-14-27.png>)

| Field | Meaning | If wrong |
|---|---|---|
| `desiredCount` | What you (or auto scaling) asked for | Not moving → policy not firing (Lab 06) |
| `runningCount` | Tasks actually up | Low → check `stoppedReason` |
| `pendingCount` | Tasks starting now | Stuck >0 → networking/capacity trouble |
| `status` | ACTIVE / DRAINING / INACTIVE | INACTIVE → service deleted |

**Verify**

```bash
aws ecs list-tasks --cluster "$CLUSTER_NAME" --service-name "$SERVICE_NAME" \
  --query 'length(taskArns)' --output text

aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[0].events[0:3].[createdAt,message]' --output text
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-15-14.png>)

#### Your turn - scale by hand

```bash
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count 3
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME"

aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count 2
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-17-00.png>)

**Expected:** `desiredCount` moves to 3, then back to 2; the service's `events` list gains new entries.

#### Checkpoint 4

```
usms-ecs-cluster
 └── usms-enrolment-svc          ACTIVE   FARGATE
      ├── task definition        usms-enrolment:1
      ├── desired 2 / running 2 / pending 0
      ├── subnets                usms-private-subnet-a, usms-private-subnet-b
      ├── security group         usms-enrolment-sg  (in: 80 from usms-app-sg)
      ├── assignPublicIp         DISABLED
      └── image pulled via       usms-private-rt -> usms-nat -> usms-igw
```
---

### Step 12 - Write `configs/lab-04.env`

```bash
cat > configs/lab-04.env << EOF
# Lab 04 - ECS cluster, task definition, roles and service outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# Lab 05 attaches a load balancer to the service recorded here. Lab 06 registers
# this service as a scalable target, using the baseline desired count as its floor.

export USMS_ECS_CLUSTER=usms-ecs-cluster
export USMS_ECS_CLUSTER_ARN=$(aws ecs describe-clusters --clusters usms-ecs-cluster \
  --query 'clusters[0].clusterArn' --output text)

export USMS_ENROLMENT_SERVICE=usms-enrolment-svc
export USMS_ENROLMENT_SERVICE_ARN=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].serviceArn' --output text)
export USMS_ECS_DESIRED_BASELINE=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].desiredCount' --output text)

export USMS_ENROLMENT_TASK_FAMILY=usms-enrolment
export USMS_ENROLMENT_TASK_REVISION=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.revision' --output text)
export USMS_ENROLMENT_CONTAINER=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment \
  --query 'taskDefinition.containerDefinitions[0].name' --output text)
export USMS_ECS_TASK_CPU=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.cpu' --output text)
export USMS_ECS_TASK_MEMORY=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.memory' --output text)

export USMS_ENROLMENT_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-enrolment-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_ECS_EXEC_ROLE=usms-ecs-exec-role
export USMS_ECS_EXEC_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-exec-role \
  --query 'Role.Arn' --output text)
export USMS_ECS_TASK_ROLE=usms-ecs-task-role
export USMS_ECS_TASK_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-task-role \
  --query 'Role.Arn' --output text)
export USMS_POLICY_ECS_EXEC=USMSECSTaskExecution

export USMS_LOG_GROUP_ENROLMENT=/usms/ecs/enrolment
EOF

grep -n 'export .*=$\|None' configs/lab-04.env || echo "all values populated"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-18-39.png>)

> Unquoted heredoc (`<< EOF`, not `<< 'EOF'`) — every `$(...)` must run **now**, not when the file is later sourced.

**Verify**

```bash
source configs/lab-04.env

printf '%-26s %s\n' \
  "cluster"           "$USMS_ECS_CLUSTER" \
  "service"           "$USMS_ENROLMENT_SERVICE" \
  "baseline desired"  "$USMS_ECS_DESIRED_BASELINE" \
  "task revision"     "$USMS_ENROLMENT_TASK_REVISION" \
  "container"         "$USMS_ENROLMENT_CONTAINER" \
  "task cpu / memory" "$USMS_ECS_TASK_CPU / $USMS_ECS_TASK_MEMORY" \
  "enrolment sg"      "$USMS_ENROLMENT_SG" \
  "task role"         "$USMS_ECS_TASK_ROLE_ARN"

grep -c '^export' configs/lab-04.env
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-19-00.png>)

Expect: all values populated, and a count of **17** exported variables. `baseline desired` must read `2`.

---

### Step 13 - Commit

**Part 1 - look before you add**

```bash
git status --short

git check-ignore -v outputs/lab-04-assumed-role.json
git ls-files outputs/
```

Checklist before committing:
- [x] No path under `outputs/` appears in `git status --short`
- [x] No `.env` at the repository root appears
- [x] `configs/lab-04.env` does appear (names/ARNs only, no secrets)
- [x] `git check-ignore -v` names the file, rule, and line number
- [x] `git ls-files outputs/` lists only `outputs/.gitkeep`

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-20-33.png>)

**Part 2 - commit**

```bash
git add labs/lab-04-ecs/ \
        configs/lab-04.env \
        policies/trust-ecs-tasks.json \
        policies/usms-ecs-task-execution-policy.json \
        policies/usms-enrolment-sg-ingress.json \
        templates/lab-04-taskdef.json \
        scripts/utilities/verify-lab-04.sh \
        scripts/cleanup/lab-04-cleanup.sh

git status --short

git commit -m "Lab 04: USMS enrolment service deployed on ECS Fargate - cluster, task definition, both IAM roles, security group and service"

git log --oneline -5
```

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-21-31.png>)

#### Checkpoint 5

```
Lab 04 recorded
 ├── configs/lab-04.env         committed, 17 exports, fully populated
 ├── policies/                  trust document + least-privilege execution policy + sg ingress
 ├── templates/                 task definition under version control
 ├── outputs/                   nothing staged, and check-ignore proves the rule
 └── git log shows Lab 01, 02, 03 and 04 commits
```

---

## 5. Verification Script

### 5.1 Build `scripts/utilities/verify-lab-04.sh`

```bash
cat > scripts/utilities/verify-lab-04.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 04 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Read-only; safe to run at any time.
# Expected result: PASS=39 FAIL=0 after Lab 05 (configs/lab-05.env present);
#                  PASS=38 FAIL=0 after Lab 04 only. Any other count means a check
#                  was added, removed or skipped - find out which before trusting a FAIL=0.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true   # USMS_ALB_SG, if Lab 05 is done

: "${USMS_APP_SG:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_TASK_FAMILY:=usms-enrolment}"
: "${USMS_ECS_DESIRED_BASELINE:=2}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ECS_EXEC_ROLE:=usms-ecs-exec-role}"
: "${USMS_ECS_TASK_ROLE:=usms-ecs-task-role}"
: "${USMS_LOG_GROUP_ENROLMENT:=/usms/ecs/enrolment}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

svc() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
          --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 01 to 03 dependencies =="
check "usms-app-sg still exists"        "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "usms-private-subnet-a exists"    "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"
check "usms-private-subnet-b exists"    "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_B"
check "private rt still has NO igw route" \
  "! aws ec2 describe-route-tables --route-table-ids ${USMS_PRIVATE_RT:-none} --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"
check "USMSStudentDataReadWrite policy exists" \
  "aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/USMSStudentDataReadWrite"

echo "== Lab 04 IAM =="
check "usms-ecs-exec-role exists"       "aws iam get-role --role-name $USMS_ECS_EXEC_ROLE"
check "usms-ecs-task-role exists"       "aws iam get-role --role-name $USMS_ECS_TASK_ROLE"
check "exec role trusts ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_EXEC_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q '^ecs-tasks.amazonaws.com$'"
check "task role trusts ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q '^ecs-tasks.amazonaws.com$'"
check "exec role carries USMSECSTaskExecution" \
  "aws iam list-attached-role-policies --role-name $USMS_ECS_EXEC_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSECSTaskExecution"
check "task role REUSES Lab 01's USMSStudentDataReadWrite" \
  "aws iam list-attached-role-policies --role-name $USMS_ECS_TASK_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSStudentDataReadWrite"

echo "== Lab 04 logging =="
check "log group $USMS_LOG_GROUP_ENROLMENT exists" \
  "aws logs describe-log-groups --log-group-name-prefix $USMS_LOG_GROUP_ENROLMENT --query 'length(logGroups)' --output text | grep -q '^1$'"
check "log group has a retention policy set" \
  "test \"\$(aws logs describe-log-groups --log-group-name-prefix $USMS_LOG_GROUP_ENROLMENT --query 'logGroups[0].retentionInDays' --output text)\" != None"

echo "== Lab 04 ECS =="
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "task definition family $USMS_ENROLMENT_TASK_FAMILY is registered" \
  "aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY"
check "task definition uses awsvpc network mode" \
  "test \"\$(aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.networkMode' --output text)\" = awsvpc"
check "task definition is FARGATE compatible" \
  "aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.requiresCompatibilities' --output text | grep -q FARGATE"
check "exec role and task role are DIFFERENT" \
  "test \"\$(aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.executionRoleArn' --output text)\" != \"\$(aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.taskRoleArn' --output text)\""
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svc status)\" = ACTIVE"
check "service launch type is FARGATE"            "test \"\$(svc launchType)\" = FARGATE"
check "service spans TWO subnets" \
  "test \"\$(aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'length(services[0].networkConfiguration.awsvpcConfiguration.subnets)' --output text)\" = 2"
check "service does NOT assign a public IP" \
  "test \"\$(svc 'networkConfiguration.awsvpcConfiguration.assignPublicIp')\" = DISABLED"
check "service carries usms-enrolment-sg" \
  "svc 'networkConfiguration.awsvpcConfiguration.securityGroups[0]' | grep -q $USMS_ENROLMENT_SG"
check "service desiredCount is 2 (one task per Availability Zone)" \
  "test \"\$(svc desiredCount)\" = $USMS_ECS_DESIRED_BASELINE"

echo "== Lab 04 networking =="
check "usms-enrolment-sg exists"  "aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG"
# Property asserted (Lab 04 Step 8, kept after Lab 05 Step 13):
#   "usms-enrolment-sg accepts traffic only from a named security group, never a CIDR,
#    and that group is the one caller the current architecture intends."
# Lab 04 that caller is usms-app-sg (the web tier). Lab 05's cutover makes it usms-alb-sg,
# so once configs/lab-05.env exists the same property is checked against usms-alb-sg.
# USMS_ALB_SG is read from configs/lab-05.env, never hard-coded. If the file does not exist
# (Lab 04 done, Lab 05 not yet) the Lab 04 form is checked, so this script still runs.
SG_SOURCES() {   # every inbound source of usms-enrolment-sg: group IDs, then any CIDRs
  aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
    --query 'SecurityGroups[0].IpPermissions[].[UserIdGroupPairs[].GroupId, IpRanges[].CidrIp]' \
    --output text | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -u | paste -sd' ' -
}
if [ -f "$REPO_ROOT/configs/lab-05.env" ]; then
  : "${USMS_ALB_SG:=}"   # set -u safe: missing in lab-05.env -> empty -> readable FAIL below
  check "usms-enrolment-sg accepts traffic only from a named group, and that group is usms-alb-sg (${USMS_ALB_SG:-USMS_ALB_SG MISSING from configs/lab-05.env})" \
    "test -n \"$USMS_ALB_SG\" && test \"\$(SG_SOURCES)\" = \"$USMS_ALB_SG\""
  # A check that only asked "is usms-alb-sg a source?" would still pass with BOTH rules in
  # place (cutover never done, or the old rule re-added). The check above already demands
  # the ALB group ALONE; this one names that regression so a failure says what came back.
  check "usms-app-sg is no longer a source of usms-enrolment-sg (Lab 05 cutover held)" \
    "! SG_SOURCES | tr ' ' '\n' | grep -qx \"$USMS_APP_SG\""
else
  check "usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)" \
    "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)\" = $USMS_APP_SG"
fi
check "usms-enrolment-sg admits NOTHING from 0.0.0.0/0" \
  "! aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"

echo "== Files and Git hygiene =="
check "configs/lab-04.env exists"        "test -f configs/lab-04.env"
check "configs/lab-04.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-04.env"
check "task definition document is valid JSON" \
  "python3 -m json.tool templates/lab-04-taskdef.json"
check "trust policy is valid JSON" \
  "python3 -m json.tool policies/trust-ecs-tasks.json"
check "execution policy is valid JSON" \
  "python3 -m json.tool policies/usms-ecs-task-execution-policy.json"
check "no task definition document contains an unexpanded variable" \
  "! grep -q '[$]' templates/lab-04-taskdef.json"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-04.sh
bash -n scripts/utilities/verify-lab-04.sh && echo "syntax OK"
./scripts/utilities/verify-lab-04.sh
```

**Expected:** `PASS=38  FAIL=0` (some environments show benign failures — see table below).

| Check | Benign cause |
|---|---|
| Service ACTIVE / `runningCount` checks | Some Floci builds never start a real container; `runningCount` stays 0 while `desiredCount` is correct |
| Log group retention policy set | Some builds ignore `put-retention-policy` |
| Service spans TWO subnets | Real failure — go back and complete Lab 2 Exercise 5 |

![alt text](<../../screenshots/Screenshot from 2026-10-16 01-22-50.png>)

### 5.2 Build the end-of-course cleanup script

```bash
cat > scripts/cleanup/lab-04-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes Lab 04, dependencies first.
# Order: service (scaled to 0) -> task definitions -> cluster -> security group -> IAM -> log group.
# Run this AFTER scripts/cleanup/lab-06-cleanup.sh and scripts/cleanup/lab-05-cleanup.sh,
# and BEFORE scripts/cleanup/lab-02-cleanup.sh.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"

cat <<'WARN'
============================================================
  This deletes the USMS enrolment service, its ECS cluster,
  its security group, both ECS IAM roles and its log group.

  Lab 05, Lab 06 and a later storage lab all depend on parts
  of it. None of this is reversible.
  Run this AFTER lab-06-cleanup.sh and lab-05-cleanup.sh,
  and BEFORE lab-02-cleanup.sh.
============================================================
WARN

read -r -p 'Type exactly: DELETE USMS ECS  > ' answer
[ "$answer" = "DELETE USMS ECS" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "service: scale to zero first, then delete"
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 0 >/dev/null || true
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" || sleep 20
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --force >/dev/null || true

say "task definition revisions"
for arn in $(aws ecs list-task-definitions --family-prefix "$USMS_ENROLMENT_TASK_FAMILY" \
               --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$arn" >/dev/null || true
done

say "cluster"
aws ecs delete-cluster --cluster "$USMS_ECS_CLUSTER" >/dev/null || true

say "security group (nothing may still reference it)"
[ -n "${USMS_ENROLMENT_SG:-}" ] && \
  aws ec2 delete-security-group --group-id "$USMS_ENROLMENT_SG" || true

say "IAM: detach before delete"
aws iam detach-role-policy --role-name "$USMS_ECS_EXEC_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_ECS_EXEC}" || true
aws iam detach-role-policy --role-name "$USMS_ECS_TASK_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/USMSStudentDataReadWrite" || true
aws iam delete-role --role-name "$USMS_ECS_EXEC_ROLE" || true
aws iam delete-role --role-name "$USMS_ECS_TASK_ROLE" || true
aws iam delete-policy \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_ECS_EXEC}" || true

say "log group"
[ -n "${USMS_LOG_GROUP_ENROLMENT:-}" ] && \
  aws logs delete-log-group --log-group-name "$USMS_LOG_GROUP_ENROLMENT" || true

echo; echo "Lab 04 teardown complete. lab-03-cleanup.sh and lab-02-cleanup.sh may now run, in that order."
EOF

chmod +x scripts/cleanup/lab-04-cleanup.sh
bash -n scripts/cleanup/lab-04-cleanup.sh && echo "syntax OK - do NOT run it"
```
![alt text](<../../screenshots/Screenshot from 2026-10-16 01-25-00.png>)
---

## 6. Troubleshooting Notes

| Symptom | Likely cause / fix |
|---|---|
| `ClusterNotFoundException` on a cluster you can see | Wrong region/profile, or cluster created under assumed-role credentials not yet unset |
| `InvalidParameterException: Task definition does not support launch type FARGATE` | `requiresCompatibilities` missing `FARGATE`, or `networkMode` not `awsvpc` |
| `ClientException: Invalid 'cpu' setting for task` | `cpu`/`memory` not a valid Fargate pair, or passed as unquoted numbers instead of strings |
| Service created but `runningCount` stays 0 | Floci build limitation — container never actually starts; confirm via `describe-services --output json` and record it |
| `ResourceInUseException` deleting service/cluster | Scale service to 0 and wait before deleting; delete service before cluster |
| `DeleteConflict` deleting an ECS role | Detach all policies before `delete-role` |
| `Could not connect to the endpoint URL` / exit code 255 | Floci container not running — `./scripts/setup/floci-up.sh` |
| Everything is gone after a restart | Floci was not running in `hybrid`/`persistent`/`wal` storage mode |

---

## 7. Floci vs Real AWS - Observed vs Conceptual

**OBSERVABLE (I actually saw this happen):**
- A cluster, a task definition family with an immutable revision, and a service
- A service placed in two private subnets with a security group and no public IP
- Two ECS roles with the same trust policy and different attached permissions
- Lab 01's `USMSStudentDataReadWrite` attached to a second, different kind of compute
- A group-referenced security group rule
- `desiredCount` changed by h                                Internet
                                    |
                          +---------+---------+
                          |     usms-igw      |
                          +---------+---------+
                                    |
  ==================================|=========================================
  ||  usms-vpc  10.0.0.0/16         |                                       ||
  ||   usms-public-rt  0.0.0.0/0 ---+                                        ||
  ||        |                                                               ||
  ||   +----+--------------------------------------------------------+       ||
  ||   | usms-public-subnet-a  10.0.1.0/24  us-east-1a               |       ||
  ||   |   [ usms-web-01 ]  usms-app-sg    <- Lab 03                 |       ||
  ||   |   [ usms-nat    ]  Elastic IP     <- Lab 02                 |       ||
  ||   +----+---------------------------------------------------+----+       ||
  ||        |  tcp/80, source = usms-app-sg                     |            ||
  ||        v                                                   |  outbound  ||
  ||   +------------------------------------------------+       |  image     ||
  ||   |  usms-enrolment-sg   in: tcp/80 from usms-app-sg |       |  pull      ||
  ||   +------------------------------------------------+       |            ||
  ||        |                          |                        v            ||
  ||   +----+-----------------+   +----+-----------------+  usms-private-rt  ||
  ||   | usms-private-        |   | usms-private-        |  0.0.0.0/0        ||
  ||   |   subnet-a           |   |   subnet-b           |    -> usms-nat    ||
  ||   | 10.0.3.0/24  AZ a    |   | 10.0.4.0/24  AZ b    |  pl-... -> S3     ||
  ||   |                      |   |                      |     endpoint      ||
  ||   |  [ task 1 ]          |   |  [ task 2 ]          |                   ||
  ||   |  [ usms-db-01 ]      |   |                      |                   ||
  ||   +----------------------+   +----------------------+                   ||
  ||                                                                        ||
  ||   ECS control plane                                                    ||
  ||     usms-ecs-cluster                                                   ||
  ||       usms-enrolment-svc      desiredCount  <---- fixed by hand here   ||
  ||         task definition usms-enrolment:1                               ||
  ||           execution role usms-ecs-exec-role  -> pull image, write logs ||
  ||           task role      usms-ecs-task-role  -> USMSStudentDataReadWrite||
  ==========================================================================and with `update-service`, narrated in the service's events

**CONCEPTUAL (reasoned about, not directly observed):**
- A container actually running, serving, or logging
- Container Insights CPU utilisation existing as a real number
- The 20–60 second task start latency real Fargate exhibits
- The ongoing cost of running this service continuously

My support path from Step 3: **______** (state which items moved from the second list to the first, if any).

---

## 8. Lab Assessment Checklist

**Environment**
- [x] Floci runs under Docker Compose; storage check reports `FAIL=0`
- [x] `whoami.sh` reports account `000000000000`
- [x] Step 3 support path (A/B/C) recorded in `notes/lab-04-notes.md`

**Resources**
- [x] `usms-ecs-cluster` is `ACTIVE`
- [x] `/usms/ecs/enrolment` exists with a retention policy set
- [x] `usms-ecs-exec-role` and `usms-ecs-task-role` both exist and trust `ecs-tasks.amazonaws.com`
- [x] `usms-ecs-task-role` carries Lab 1's `USMSStudentDataReadWrite`, not a new copy
- [x] `usms-enrolment:1` registered, `awsvpc`, `FARGATE`, two different role ARNs
- [x] `usms-enrolment-svc` `ACTIVE`, spans two private subnets, `assignPublicIp DISABLED`, desired count 2
- [x] `usms-enrolment-sg` admits `tcp/80` from `usms-app-sg` by group reference, nothing from `0.0.0.0/0`

**Evidence**
- [x] Step 11 "Your turn" recorded (desiredCount 2 → 3 → 2, with events)
- [x] Exercise 5's `outputs/lab-04-lab03-linkage.txt` with `LOOP CLOSED` verdict or explained mismatch
- [x] Screenshots captured for Checkpoints 2, 3, and 4

**Hygiene & written work**
- [x] `configs/lab-04.env` exists, committed, 17 exports, no empty values or `None`
- [x] `scripts/utilities/verify-lab-04.sh` reports `FAIL=0` (or documented benign failures)
- [x] `scripts/cleanup/lab-04-cleanup.sh` exists, passes `bash -n`, has **not** been run
- [x] `git status --short` shows nothing under `outputs/`
- [x] `git check-ignore -v outputs/lab-04-assumed-role.json` names the rule and line
- [x] `notes/lab-04-notes.md` answers all review questions
- [x] `labs/lab-04-ecs/exercises.md` contains all five exercises
- [x] Every Floci limitation hit is recorded, with what real AWS would have done
---

## 10. What Was Built - Summary

```
Lab 04  COMPUTE - deployed, standing still
  usms-ecs-cluster
    usms-enrolment-svc   desired 2, both private subnets, usms-enrolment-sg
      usms-enrolment:1   exec role + task role
```

**Key takeaways:**
- ECS's four objects - cluster (namespace), task definition (immutable blueprint), task (one running instance), service (controller keeping `runningCount = desiredCount`) - stay cleanly separated.
- `USMSStudentDataReadWrite` from Lab 1 now backs two completely different compute mechanisms (EC2 instance profile and ECS task role) with zero changes and no key on disk.
- Lab 2's NAT gateway, private route table, and S3 endpoint are what let a task in a private subnet pull its container image at all.
- `desiredCount` is the only number this lab (or, later, auto scaling) ever touches - everything else is the service reconciling toward it.

### KEEP vs CLEAN UP

| KEEP | CLEAN UP |
|---|---|
| `usms-ecs-cluster` | `outputs/lab-04-assumed-role.json` (expired credentials) |
| `usms-enrolment` task definition family | `usms-results-svc` (Exercise 1 practice resource — remove in Exercise 4) |
| `usms-enrolment-svc` | `AWS_ACCESS_KEY_ID` and friends (unset after Step 4) |
| `usms-enrolment-sg` | |
| `usms-ecs-exec-role` / `usms-ecs-task-role` | |
| `/usms/ecs/enrolment` log group | |
| `configs/lab-04.env` | |
| `templates/lab-04-taskdef.json` | |
| `scripts/utilities/verify-lab-04.sh` | |

```bash
rm -f outputs/lab-04-assumed-role.json
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
./scripts/utilities/whoami.sh
git status --short
```

> Do **not** run `scripts/cleanup/lab-04-cleanup.sh`, `lab-03-cleanup.sh`, or `lab-02-cleanup.sh` now — end-of-course only, in reverse dependency order.

---

## 11. Preparation for the Next Lab (Lab 05 - ALB)

```bash
cd ~/aws-floci-course
./scripts/utilities/verify-lab-04.sh
grep -c '^export' configs/lab-04.env
aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].{Desired:desiredCount,Running:runningCount}' --output json
```

Target state before moving on: `FAIL=0`, export count `17`, `Desired == Running` (or the container-start limitation recorded).

**Snapshot before Lab 05:**

```bash
floci snapshot save lab-04-complete
```

Filesystem fallback if `floci snapshot` is unavailable:

```bash
./scripts/setup/floci-down.sh
tar -czf ~/floci-data-lab-04.tar.gz -C ~ floci-data
./scripts/setup/floci-up.sh
ls -lh ~/floci-data-lab-04.tar.gz
```


---

## 12. Conclusion

Lab 04 successfully containerised the USMS enrolment service onto Amazon ECS on Fargate, running inside the private subnets built in Lab 02, protected by IAM roles built in this lab, and permissioned through a policy reused unchanged from Lab 01. The service (`usms-enrolment-svc`) was verified `ACTIVE`, spans both Availability Zones, and stands at a fixed `desiredCount` of 2, ready to be placed behind a load balancer in Lab 05 and handed over to Application Auto Scaling in Lab 06.


