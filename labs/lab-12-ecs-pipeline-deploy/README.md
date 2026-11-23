# DSO303 - Practical 7 (Lab 12): Deploying to Amazon ECS from the Pipeline

---

## Table of Contents

1. [Aim](#1-aim)
2. [Learning Objectives](#2-learning-objectives)
3. [Theory / Background](#3-theory--background)
4. [Prerequisites and Environment](#4-prerequisites-and-environment)
5. [Connection to Previous Labs](#5-connection-to-previous-labs)
6. [What We Are Building and Architecture](#6-what-we-are-building-and-architecture)
7. [Directory Structure](#7-directory-structure)
8. [Procedure (Steps 1–21)](#8-procedure)
9. [Verification](#9-verification)
10. [Checkpoints](#10-checkpoints)
11. [Troubleshooting Encountered](#11-troubleshooting-encountered)
12. [Floci vs Real AWS](#12-floci-vs-real-aws)
13. [Independent Lab Exercises](#13-independent-lab-exercises)
14. [Lab Assessment Checklist](#14-lab-assessment-checklist)
15. [Review Questions](#15-review-questions)
16. [What We Built, KEEP / CLEAN UP and Cleanup Script](#16-what-we-built)
17. [Preparation for the Next Lab](#17-preparation-for-the-next-lab)
18. [Conclusion](#18-conclusion)
19. [References](#19-references)

---

## 1. Aim

To connect the CI/CD pipeline built in Lab 11 to the running ECS service. The enrolment service source is built into a container image, pushed to a private Amazon ECR repository, referenced by a new ECS task definition revision, and deployed automatically by a third **Deploy** stage in `usms-enrolment-pipeline`. No human types `aws ecs update-service`. The lab also includes a rollback drill and a paper design of a blue/green deployment with CodeDeploy.

## 2. Learning Objectives

By the end of this practical I should be able to:

1. Create a private ECR repository, authenticate Docker against it, and push an image, reading the registry host from the API rather than assuming it.
2. Explain the difference between an image **tag** and an image **digest**, and say which one a production task definition should name and what that costs.
3. Produce a new ECS task definition revision with **describe → modify → register**, and name the read-only fields that must be stripped.
4. Write `imagedefinitions.json` and explain what the ECS deploy action does with it, and what it cannot express.
5. Create a new version of a customer-managed IAM policy, set it as default, and explain why those are two operations.
6. Extend a CodePipeline safely with **get → modify → put**.
7. Deploy to ECS entirely through a pipeline and verify it by reading the service's task definition and image.
8. Roll a deployment back and explain the ECS deployment circuit breaker.
9. Describe a blue/green ECS deployment with CodeDeploy accurately enough to specify one, while stating clearly that I did not perform one.

## 3. Theory / Background

| Concept | Summary |
|---|---|
| **Amazon ECR** | A private OCI container registry. A repository holds all builds of one thing, distinguished by tag. |
| **Tag vs digest** | A tag (`r6`) is a movable label. A digest (`sha256:…`) is derived from content and cannot move. `repo@sha256:…` is the only unforgeable reference. |
| **Build digest vs push digest** | `docker build` reports the image *config* digest; `docker push` reports the *manifest* digest. ECR indexes the manifest digest. |
| **Task definition revisions** | Append-only. A new revision is derived from the previous one (describe → strip 8 read-only fields → change → register). Rollback = pointing the service at an older revision. |
| **`imagedefinitions.json`** | A JSON **array** of `{ "name": <container name>, "imageUri": <full image ref> }`. Must be at the root of the build artifact. `name` must equal the container name (`enrolment-api`). |
| **ECS deploy action** | Reads the service's *current* task definition, replaces the image of the named container, registers a new revision, and calls `update-service`. It cannot change CPU, memory, env vars or logging. |
| **IAM policy versions** | `create-policy-version` adds a version; it is only active once set as default. Maximum 5 versions. |
| **`ecr:GetAuthorizationToken`** | A registry-level action, so it must be on `Resource: "*"`. |
| **`iam:PassRole` to `ecs-tasks.amazonaws.com`** | Registering a task definition that names execution/task roles is a role handoff and needs PassRole. |
| **Replace-only APIs** | `update-pipeline`, `put-bucket-notification-configuration`, `update-assume-role-policy`, `put-bucket-policy`. Whatever you send becomes the whole resource. |
| **Circuit breaker** | Marks a deployment FAILED when tasks fail to start or fail health checks, and optionally rolls back. It does not detect a healthy-but-wrong app, completed deployments, or side effects. |
| **Blue/green (CodeDeploy)** | New task set tested on a test listener, then traffic shifted. Uses `imageDetail.json` + `appspec.yaml`, needs `deploymentController.type = CODE_DEPLOY` (immutable after service creation). |

## 4. Prerequisites and Environment

| Item | Value / Status |
|---|---|
| Host OS | `Pop!_OS 22.04 LTS` |
| Docker version (`docker --version`) | `29.10.0 (build fdd4b8e)` |
| AWS CLI version (`aws --version`) | `1.42.53` |
| Python version (`python3 --version`) | `3.10.12` |
| Emulator | Floci (LocalStack-based), endpoint `http://localhost:4566`, account `000000000000` |
| Free disk | ≥ 1 GB |
| Labs completed | 01, 02, 03, 04, 05, 06, 11 (07–10 helpful) |

### 4.1 Baseline verification

```bash
cd ~/aws-floci-course
source configs/course.env

./scripts/utilities/floci-storage-check.sh      # exit 0, reports individual checks
./scripts/utilities/verify-lab-04.sh           # PASS=39  FAIL=0
./scripts/utilities/verify-lab-05.sh           # PASS=48  FAIL=0  SKIP=1 on Floci 2.3.0
./scripts/utilities/verify-lab-11.sh           # PASS=46  FAIL=0  (or 38/8 on Path B or C)
docker info >/dev/null 2>&1 && echo "docker reachable"
```

**Results recorded:**

| Script | Expected | My result |
|---|---|---|
| `floci-storage-check.sh` | Exit 0 | Passed. Compose is running in hybrid mode with a host bind mount. This script reports individual checks. |
| `verify-lab-04.sh` | FAIL=0 | `PASS=39 FAIL=0` |
| `verify-lab-05.sh` | FAIL=0, with a skip if Floci omits grace-period readback | `PASS=48 FAIL=0 SKIP=1` |
| `verify-lab-11.sh` | PASS=46 FAIL=0 (or 38/8) | `PASS=46 FAIL=0` after restoring the expected source path. |
| `docker info` | docker reachable | Docker daemon reachable. |

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-22-25.png>)

### 4.2 Re-hydrate a new terminal (use whenever a terminal is reopened mid-lab)

Shell variables die with the terminal. If you open a new terminal after Step 9, paste this before continuing:

```bash
cd ~/aws-floci-course
source configs/course.env
for f in configs/lab-0{1,2,3,4,5,6,7,8,9}.env configs/lab-10.env configs/lab-11.env configs/lab-12.env; do
  [ -f "$f" ] && source "$f"
done
ECR_REPO="usms-enrolment"
ECR_URI=$(aws ecr describe-repositories --repository-names "$ECR_REPO" \
  --query 'repositories[0].repositoryUri' --output text)
ECR_REGISTRY="${ECR_URI%%/*}"
IMAGE_TAG=$(tr -d '[:space:]' < labs/lab-11-cicd/app/VERSION)
echo "ECR_URI=$ECR_URI  ECR_REGISTRY=$ECR_REGISTRY  IMAGE_TAG=$IMAGE_TAG"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-23-42.png>)

## 5. Connection to Previous Labs

### 5.1 Current environment

```text
Created in previous labs:
- Lab 01: IAM foundation; usms-ecs-exec-role and usms-ecs-task-role come from here
- Lab 02: usms-vpc, two public and two private subnets
- Lab 04: usms-ecs-cluster, task family usms-enrolment (rev 2), service usms-enrolment-svc,
           container enrolment-api on port 80, log group /usms/ecs/enrolment,
           policy USMSECSTaskExecution - which already grants the four ecr:* pull actions
- Lab 05: usms-enrolment-alb, target group usms-enrolment-tg, the service registered behind it
- Lab 06: scalable target min 2 max 10 on the service
- Lab 10: bucket usms-student-data
- Lab 11: usms-pipeline-artifacts (versioned), usms-enrolment-build, usms-enrolment-pipeline
           (Source -> Build), usms-codebuild-role + USMSCodeBuildBase,
           usms-codepipeline-role + USMSCodePipelineBase, labs/lab-11-cicd/app/ with buildspec.yml

Created in this lab:
- usms-enrolment                 ECR repository - the first private registry in this course
- Dockerfile                     in labs/lab-11-cicd/app/, beside the source it packages
- usms-enrolment:3               task definition revision naming YOUR image
- USMSCodeBuildBase v2           adds ECR push; set as the default version
- USMSCodePipelineBase v2        adds ecs:UpdateService and a second scoped iam:PassRole
- Deploy stage                   third stage of usms-enrolment-pipeline, provider ECS
- imagedefinitions.json          produced by the build, consumed by the deploy action
- templates/lab-12-appspec.yaml  the blue/green document, read and validated, not executed
```

### 5.2 The three artefacts this lab makes newly meaningful

1. **Lab 01's `USMSECSTaskExecution`** already grants `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage` on `*`. Step 5 creates the repository those actions were always about; the execution role needs no change.
2. **Lab 04 Step 15's `--force-new-deployment`** was justified by "the image tag now points at a different image". Step 17 is the first time that actually happens.
3. **Lab 04's container name `enrolment-api`** becomes the join key in `imagedefinitions.json` (Step 14).

## 6. What We Are Building and Architecture

```text
  BEFORE (end of Lab 11)                     AFTER (end of this lab)

  source -> build -> artifact                 source -> build -> artifact -> deploy
                       │                                    │                   │
                    (stops)                          builds an image      updates the ECS
                                                     pushes to ECR        service, which pulls
                                                                          the image and replaces
                                                                          its tasks
```

```text
   labs/lab-11-cicd/app/                         ECR: usms-enrolment
   ┌────────────────────┐                         ┌──────────────────────────────┐
   │ src/  config/       │   docker build         │  usms-enrolment:r6           │
   │ tests/ VERSION      │ ──────────────────────>│    digest sha256:8f3a...     │
   │ buildspec.yml       │   docker push          │  usms-enrolment:r7           │
   │ Dockerfile   (NEW)  │                        │    digest sha256:1c92...     │
   └────────────────────┘                         └──────────────────────────────┘
             │ zip + upload                                      ^ pulled by the task's
             v                                                   │ EXECUTION role
   S3: usms-pipeline-artifacts                                   │
             │                                                   │
             v                                                   │
   CodePipeline: usms-enrolment-pipeline                         │
   │  Source ──> Build (CodeBuild: docker build + push,          │
   │                    writes imagedefinitions.json) ───────────┘
   │                   ──> Deploy (provider ECS):
   │                         1. reads the service's CURRENT task definition
   │                         2. replaces the image of the container named in the file
   │                         3. register-task-definition  -> usms-enrolment:4
   │                         4. update-service --task-definition usms-enrolment:4
                                      │
                                      v
   ECS service usms-enrolment-svc on usms-ecs-cluster
     deployment PRIMARY  usms-enrolment:4   running 0 -> 2
     deployment ACTIVE   usms-enrolment:3   running 2 -> 0
```

**Key point:** the deploy action never reads a task definition file from the repository. It takes the one the service is running and changes one field.

> 📸 **Screenshot 6.1 (optional) - Architecture diagram redrawn / whiteboard**
>
> ![Architecture](screenshots/lab12-06-architecture.png)

## 7. Directory Structure

```text
aws-floci-course/
├── configs/
│   └── lab-12.env                            NEW
├── labs/
│   ├── lab-11-cicd/app/
│   │   ├── Dockerfile                         NEW
│   │   ├── .dockerignore                      NEW
│   │   └── buildspec.yml                      MODIFIED
│   └── lab-12-cicd-deploy/                   NEW
│       ├── README.md
│       └── exercises.md
├── policies/
│   ├── usms-codebuild-policy-v2.json          NEW
│   └── usms-codepipeline-policy-v2.json       NEW
├── templates/
│   ├── lab-12-taskdef-base.json              NEW
│   ├── lab-12-taskdef-v3.json                NEW
│   ├── lab-12-codebuild-update.json          NEW
│   ├── lab-12-pipeline-current.json          NEW
│   ├── lab-12-pipeline.json                  NEW
│   ├── lab-12-appspec.yaml                   NEW
│   └── lab-12-codedeploy-deployment-group.json NEW
├── scripts/
│   ├── utilities/
│   │   ├── deploy-support-probe.sh            NEW
│   │   ├── usms-ecs-watch.sh                  NEW
│   │   └── verify-lab-12.sh                  NEW
│   └── cleanup/
│       └── lab-12-cleanup.sh                 NEW  - DO NOT RUN NOW
├── outputs/                                   (git-ignored)
│   ├── lab-12-deploy-probe.txt
│   ├── lab-12-image-digest.txt
│   └── lab-12-deploy-evidence.txt
└── notes/
    └── lab-12-notes.md                       NEW
```

---

## 8. Procedure

Each step below records: **Purpose**, **Run from**, **Commands**, **Expected result**, **Screenshot**, and **Observation**.

---

### Step 1 - Start Floci, and read what Lab 11 left you

**Purpose:** Start the environment and read the Lab 11 readiness inventory instead of assuming what exists.

**Run from:** `aws-floci-course/`

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh
./scripts/utilities/floci-storage-check.sh
./scripts/utilities/whoami.sh

if [ -f outputs/lab-11-lab08b-readiness.txt ]; then
  echo "--- Lab 11 readiness file ---"
  cat outputs/lab-11-lab08b-readiness.txt
else
  echo "no readiness file - you did not do Lab 11 Exercise 5."
  echo "That is fine: Step 14 of this lab writes imagedefinitions.json in full."
fi
```

**Expected result:**

```text
PASS=16  FAIL=0

  Account : 000000000000
  Arn     : arn:aws:iam::000000000000:root
  Endpoint: http://localhost:4566

--- Lab 11 readiness file ---
artifact: usms-enrolment-pipeline/BuildOutput/A1b2C3d.zip
imagedefinitions.json:
[ { "name": "enrolment-api", "imageUri": "public.ecr.aws/nginx/nginx:stable-alpine" } ]
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-26-30.png>)

**Observation:** Yes, the readiness file is present. It points to `usms-enrolment-pipeline/BuildOutput/exercise5-local.zip`, the locally built Lab 11 artifact uploaded to S3.

---

### Step 2 - Source every earlier lab's environment

**Purpose:** Load every earlier lab's names/ARNs, since only env files survive a terminal.

**Run from:** `aws-floci-course/`

```bash
source configs/course.env

for f in configs/lab-01.env configs/lab-02.env configs/lab-03.env \
         configs/lab-04.env configs/lab-05.env configs/lab-06.env \
         configs/lab-09.env configs/lab-07.env configs/lab-08.env \
         configs/lab-10.env configs/lab-11.env; do
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    source "$f"
    printf '  sourced  %s\n' "$f"
  else
    printf '  absent   %s\n' "$f"
  fi
done

printf 'cluster=%s service=%s container=%s pipeline=%s project=%s exec-role=%s\n' \
  "${USMS_ECS_CLUSTER:-MISSING}" "${USMS_ENROLMENT_SERVICE:-MISSING}" \
  "${USMS_ENROLMENT_CONTAINER:-MISSING}" "${USMS_PIPELINE_NAME:-MISSING}" \
  "${USMS_BUILD_PROJECT:-MISSING}" "${USMS_ECS_EXEC_ROLE_ARN:-MISSING}"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-27-50.png>)

**Housekeeping (needed later by Steps 12, 16, 18 and 21):** create the folders the lab writes notes into.

```bash
mkdir -p notes labs/lab-12-cicd-deploy
[ -f notes/lab-12-notes.md ] || printf '# Lab 12 notes\n\n' > notes/lab-12-notes.md
[ -f labs/lab-12-cicd-deploy/README.md ] || printf '# Lab 12 - ECS Pipeline Deploy\n\nSee the practical report.\n' > labs/lab-12-cicd-deploy/README.md
[ -f labs/lab-12-cicd-deploy/exercises.md ] || printf '# Lab 12 - Exercises\n\n' > labs/lab-12-cicd-deploy/exercises.md
```

**Expected:** no `MISSING`; `container=enrolment-api`, `pipeline=usms-enrolment-pipeline`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-28-15.png>)

**Observation:** All earlier env files loaded. The cluster is `usms-ecs-cluster`, the service is `usms-enrolment-svc`, and the container is `enrolment-api`. The pipeline is `usms-enrolment-pipeline`, the build project is `usms-enrolment-build`, and the execution role is `arn:aws:iam::000000000000:role/usms-ecs-exec-role`.

---

### Step 3 - Probe the deployment surface

**Purpose:** Find out whether ECR, ECS and CodeDeploy are usable on this Floci build, and choose Path A, B or C.

**Run from:** `aws-floci-course/`

```bash
cat > scripts/utilities/deploy-support-probe.sh << 'EOF'
#!/usr/bin/env bash
# Determine which deployment path this Floci build supports. Read-only apart from
# one throwaway ECR repository, which it deletes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

PROBE_REPO="usms-probe-delete-me"
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  --   %s\n' "$1"; }

ECR_OK=no ; ECR_PUSHABLE=unknown ; ECS_OK=no ; DEPLOY_OK=no ; DOCKER_OK=no

echo "== Docker on this machine =="
if docker info >/dev/null 2>&1; then DOCKER_OK=yes; ok "docker daemon reachable"
else bad "docker daemon NOT reachable - this lab cannot build an image"; fi

echo "== ECR =="
if aws ecr describe-repositories >/dev/null 2>&1; then
  ECR_OK=yes; ok "ecr describe-repositories answers"
  if aws ecr create-repository --repository-name "$PROBE_REPO" >/dev/null 2>&1; then
    ok "ecr create-repository accepted"
    URI=$(aws ecr describe-repositories --repository-names "$PROBE_REPO" \
            --query 'repositories[0].repositoryUri' --output text 2>/dev/null)
    printf '       probe repositoryUri: %s\n' "${URI:-none}"
    case "$URI" in
      */*) ECR_PUSHABLE=probably ;;
      *)   ECR_PUSHABLE=no ;;
    esac
    aws ecr delete-repository --repository-name "$PROBE_REPO" --force >/dev/null 2>&1 \
      && ok "probe repository deleted" || bad "probe repository NOT deleted - remove $PROBE_REPO by hand"
  else
    bad "ecr create-repository rejected"
  fi
else
  bad "ecr describe-repositories does not answer"
fi

echo "== ECS =="
if aws ecs list-clusters >/dev/null 2>&1; then ECS_OK=yes; ok "ecs list-clusters answers"
else bad "ecs list-clusters does not answer"; fi

echo "== CodeDeploy (Step 19 only) =="
if aws deploy list-applications >/dev/null 2>&1; then DEPLOY_OK=yes; ok "codedeploy list-applications answers"
else bad "codedeploy list-applications does not answer - Step 19 is conceptual, as expected"; fi

echo
if [ "$DOCKER_OK" = yes ] && [ "$ECR_OK" = yes ] && [ "$ECS_OK" = yes ]; then
  P="A"
  echo "PATH A - build an image, push it to ECR, deploy it through the pipeline."
elif [ "$DOCKER_OK" = yes ] && [ "$ECS_OK" = yes ]; then
  P="B"
  echo "PATH B - no usable ECR. Build the image locally and keep it in the local"
  echo "         Docker daemon; Step 10's task definition names the local tag, and"
  echo "         Step 16's deploy stage is written and validated but not executed."
else
  P="C"
  echo "PATH C - no Docker or no ECS. Every document in this lab is still written"
  echo "         and validated. Section 12 says exactly what to claim."
fi
printf 'USMS_CICD_DEPLOY_PATH=%s\nUSMS_CODEDEPLOY_SUPPORTED=%s\n' "$P" "$DEPLOY_OK" \
  > outputs/lab-12-deploy-probe.txt
echo "recorded in outputs/lab-12-deploy-probe.txt"
EOF

chmod +x scripts/utilities/deploy-support-probe.sh
bash -n scripts/utilities/deploy-support-probe.sh && echo "syntax OK"
./scripts/utilities/deploy-support-probe.sh
cat outputs/lab-12-deploy-probe.txt
```

**Expected result:**

```text
== Docker on this machine ==
  ok   docker daemon reachable
== ECR ==
  ok   ecr describe-repositories answers
  ok   ecr create-repository accepted
       probe repositoryUri: 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/usms-probe-delete-me
  ok   probe repository deleted
== ECS ==
  ok   ecs list-clusters answers
== CodeDeploy (Step 19 only) ==
  --   codedeploy list-applications does not answer - Step 19 is conceptual, as expected

PATH A - build an image, push it to ECR, deploy it through the pipeline.
recorded in outputs/lab-12-deploy-probe.txt
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-30-34.png>)

**Observation:** The probe selects Path A. Docker and ECS responded, and a temporary ECR repository returned the host `000000000000.dkr.ecr.us-east-1.localhost:4566`. CodeDeploy listed zero applications. Registry push and deployment support still need an end-to-end test.

**Checkpoint 1**

```text
outputs/lab-12-deploy-probe.txt
 ├── USMS_CICD_DEPLOY_PATH=<A|B|C>
 └── USMS_CODEDEPLOY_SUPPORTED=<yes|no>
```

---

### Step 4 - Verify the Floci and ECR port bindings

Floci publishes the AWS API on port `4566`. The ECR registry sidecar binds its own host ports. Publishing `5100–5104` on the main container causes a conflict when the registry sidecar already owns port `5100`.

```bash
./scripts/setup/floci-up.sh
docker port floci
docker ps --filter name=ecr-registry --format '{{.Names}} {{.Ports}}'
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].{Name:serviceName,Status:status,Desired:desiredCount,TaskDef:taskDefinition}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-35-07.png>)

**Observation:** After correcting the Compose binding, Floci started on port `4566`, the existing ECR registry still owned `127.0.0.1:5100`, and the enrolment service was `ACTIVE`.

---

### Step 5 - Create the ECR repository

**Purpose:** A private place to store the enrolment image.

**Concept:** A tag is mutable by default; a digest is content-derived and immutable. `MUTABLE` is chosen deliberately so Step 18 can demonstrate what goes wrong (Exercise 2 argues the opposite).

**Run from:** `aws-floci-course/`

```bash
ECR_REPO="usms-enrolment"

aws ecr create-repository \
  --repository-name "$ECR_REPO" \
  --image-tag-mutability MUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --encryption-configuration encryptionType=AES256 \
  --tags Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=12 \
  --query 'repository.{Name:repositoryName,Uri:repositoryUri,Mutability:imageTagMutability}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-35-32.png>)

```text
aws
 └── ecr                                the SERVICE (Elastic Container Registry)
      └── create-repository             the OPERATION
           ├── --image-tag-mutability   MUTABLE lets a tag be moved; IMMUTABLE does not
           ├── --image-scanning-configuration  scan each pushed image for known CVEs
           └── --encryption-configuration      AES256 is the default; KMS is the alternative
```

**Verify:**

```bash
ECR_URI=$(aws ecr describe-repositories --repository-names "$ECR_REPO" \
  --query 'repositories[0].repositoryUri' --output text)
ECR_REGISTRY="${ECR_URI%%/*}"

printf 'repository uri : %s\nregistry host  : %s\n' "$ECR_URI" "$ECR_REGISTRY"
```

`${ECR_URI%%/*}` removes everything from the first `/`, leaving the registry host. If `ECR_REGISTRY` equals `ECR_URI`, the URI has no slash → Path B.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-35-52.png>)

**Observation:** The `usms-enrolment` repository has yet to be created. The temporary probe returned registry host `000000000000.dkr.ecr.us-east-1.localhost:4566`.

---

### Step 6 - Authenticate Docker against the registry

**Purpose:** Exchange AWS credentials for a 12-hour ECR token (username `AWS`) and hand it to Docker through stdin, never the command line.

**Run from:** `aws-floci-course/`

If Docker's credential helper fails with `gpg: Unusable public key`, use a temporary Docker config for the local registry. Run this in the same terminal as the login and subsequent Docker push and pull commands.

```bash
export DOCKER_CONFIG="$(mktemp -d)"
printf '{"auths":{"%s":{}}}\n' "$ECR_REGISTRY" > "$DOCKER_CONFIG/config.json"
```

```bash
aws ecr get-login-password --region "$AWS_REGION_COURSE" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

**Expected result:**

```text
Login Succeeded
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-38-53.png>)

The temporary config stores the short-lived token unencrypted in a private directory. Run `docker logout "$ECR_REGISTRY"` and `unset DOCKER_CONFIG` after the lab's registry work.

> **Floci limitation:** if the error is `http: server gave HTTP response to HTTPS client`, add the registry host to Docker's `insecure-registries` (Docker Desktop → Settings → Docker Engine, or `/etc/docker/daemon.json` on Linux) and restart Docker. Local development only; never for a real registry.
>
> Example `daemon.json` fragment (replace with your own `$ECR_REGISTRY` value):
> ```json
> { "insecure-registries": ["000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566"] }
> ```

**Observation:** Login succeeded using a temporary Docker config after the default GPG credential helper rejected its encryption key. The registry push test is pending.

**Checkpoint 2**

```text
ECR
 └── usms-enrolment
      ├── MUTABLE tags, scanOnPush=true, AES256
      ├── repositoryUri read from the API, never typed
      └── docker login succeeded against the registry host
```

---

### Step 7 - Write the Dockerfile

**Purpose:** Turn the build output (`dist/`) into an image. The Dockerfile is four lines on purpose.

**Concept:** `docker build .` sends the whole build context to the daemon. The image should contain the *built output* (`dist/`), not the build inputs, tests or buildspec. `.dockerignore` enforces this and keeps the context small.

**Run from:** `aws-floci-course/labs/lab-11-cicd/app/`

```bash
cd ~/aws-floci-course/labs/lab-11-cicd/app

cat > Dockerfile << 'EOF'
# The USMS enrolment service: a static portal served by nginx.
# The build context must already contain dist/, produced by buildspec.yml's build phase.
FROM nginx:1.27-alpine

# Copy the BUILT output, not the source tree.
COPY dist/ /usr/share/nginx/html/

# Lab 04's task definition health check fetches http://localhost/ and Lab 05's
# target group health check fetches / on the traffic port. Both need port 80.
EXPOSE 80

# nginx:alpine's own entrypoint already runs nginx in the foreground.
EOF

cat > .dockerignore << 'EOF'
.git
.gitignore
Dockerfile
.dockerignore
buildspec.yml
tests/
src/
config/
VERSION
*.bak
EOF

echo "--- Dockerfile ---"; cat Dockerfile
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-40-23.png>)

**Verify:**

```bash
cd ~/aws-floci-course
ls -l labs/lab-11-cicd/app/Dockerfile labs/lab-11-cicd/app/.dockerignore
test -d labs/lab-11-cicd/app/dist && echo "dist/ present - Step 8 can build" \
  || ./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null \
     && echo "dist/ rebuilt by the local runner"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-40-45.png>)

**Why `COPY dist/` (one sentence):** `dist/` is the processed build output (substituted `index.html`, health file, `build-metadata.json`, `service.json`), so the image ships what runs, not what built it, keeping it about 8 MB.

---

### Step 8 - Build the image and push it, by hand

**Purpose:** Prove the image path works in my own terminal before a pipeline walks it.

**Concept - three names for one thing:**

```text
  usms-enrolment:r6                                   a local name
  000000000000.dkr.ecr.us-east-1.<host>:4566/usms-enrolment:r6     the pushable name
  sha256:8f3a91c4...                                  the digest - the content's identity
```

**Run from:** `aws-floci-course/`

**Part 1 - set the release and rebuild the output**

```bash
cd ~/aws-floci-course

printf 'r6\n' > labs/lab-11-cicd/app/VERSION
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app | tail -12

IMAGE_TAG=$(tr -d '[:space:]' < labs/lab-11-cicd/app/VERSION)
echo "image tag will be: $IMAGE_TAG"
```

**Expected:** smoke tests pass, `build-metadata.json` says `"release": "r6"`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-42-02.png>)

**Part 2 - build, tag, push**

```bash
cd labs/lab-11-cicd/app

docker build -t "usms-enrolment:$IMAGE_TAG" .

docker tag "usms-enrolment:$IMAGE_TAG" "$ECR_URI:$IMAGE_TAG"

docker push "$ECR_URI:$IMAGE_TAG"

cd ~/aws-floci-course
```

**Expected result:**

```text
[+] Building 2.4s (8/8) FINISHED
 => [1/2] FROM docker.io/library/nginx:1.27-alpine
 => [2/2] COPY dist/ /usr/share/nginx/html/
 => => writing image sha256:8f3a91c4...
 => => naming to docker.io/library/usms-enrolment:r6

The push refers to repository [000000000000.dkr.ecr.us-east-1.<host>:4566/usms-enrolment]
0a1b2c3d4e5f: Pushed
...
r6: digest: sha256:1c92f0ab... size: 1571
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-42-52.png>)

**Observation:**

| Item | Value |
|---|---|
| Build (config) digest | Pending the r6 Docker build |
| Push (manifest) digest | Pending the r6 registry push |
| Are they the same? | No – build reports the image config digest; push reports the manifest digest, which ECR indexes and a task definition can pin. |

> **Path B (push fails):** keep the image locally as `usms-enrolment:r6`, use that name in Step 10, and record that the image was never in a registry.

---

### Step 9 - Prove the image is in the registry

**Purpose:** `Pushed` is the client reporting its own success; the registry read-back is the evidence.

**Run from:** `aws-floci-course/`

```bash
aws ecr describe-images \
  --repository-name usms-enrolment \
  --query 'imageDetails[].{Tags:imageTags,Digest:imageDigest,SizeMB:imageSizeInBytes,Pushed:imagePushedAt}' \
  --output table

IMAGE_DIGEST=$(aws ecr describe-images \
  --repository-name usms-enrolment \
  --image-ids "imageTag=$IMAGE_TAG" \
  --query 'imageDetails[0].imageDigest' --output text)

printf '%s %s %s\n' "$IMAGE_TAG" "$IMAGE_DIGEST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | tee -a outputs/lab-12-image-digest.txt
```

**Expected result:**

```text
| sha256:1c92f0ab...     | 2026-09-17T10:12:44+06:00 | 8724531   |  ['r6']   |

r6 sha256:1c92f0ab... 2026-09-17T04:12:51Z
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-44-03.png>)

**Verify - create, perturb, read back** (skip on Path B)

> Deletes only the two **local** Docker image names; nothing in ECR. Reversed immediately by the pull.

```bash
docker rmi "$ECR_URI:$IMAGE_TAG" "usms-enrolment:$IMAGE_TAG" 2>/dev/null || true
docker images | grep -c usms-enrolment || echo "no local copy remains"

docker pull "$ECR_URI@$IMAGE_DIGEST"
docker images --digests | grep usms-enrolment | head -3
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-44-23.png>)

**Observation:** The r6 digest is pending a successful registry push. An `@` reference pins a digest, while a `:` reference selects a tag.

**Checkpoint 3**

```text
ECR usms-enrolment
 └── r6   sha256:1c92f0ab...   pushed, deleted locally, pulled back by digest
outputs/lab-12-image-digest.txt
 └── one line: tag, digest, timestamp
```

---

### Step 10 - Register a task definition revision that names your image

**Purpose:** Produce revision 3 from revision 2, identical except for the image.

**Concept - describe, strip, register.** Read-only fields to strip: `taskDefinitionArn`, `revision`, `status`, `requiresAttributes`, `compatibilities`, `registeredAt`, `registeredBy`, `deregisteredAt`.

**Run from:** `aws-floci-course/`

```bash
cd ~/aws-floci-course

aws ecs describe-task-definition \
  --task-definition usms-enrolment \
  --query 'taskDefinition' --output json > templates/lab-12-taskdef-base.json

python3 - "$ECR_URI:$IMAGE_TAG" << 'PY'
import json, sys

new_image = sys.argv[1]
READ_ONLY = ("taskDefinitionArn", "revision", "status", "requiresAttributes",
             "compatibilities", "registeredAt", "registeredBy", "deregisteredAt")

td = json.load(open("templates/lab-12-taskdef-base.json"))
for field in READ_ONLY:
    td.pop(field, None)

found = False
for c in td["containerDefinitions"]:
    if c["name"] == "enrolment-api":
        print("old image:", c["image"])
        c["image"] = new_image
        print("new image:", c["image"])
        found = True
if not found:
    sys.exit("no container named enrolment-api in this task definition - stop and check Lab 04")

json.dump(td, open("templates/lab-12-taskdef-v3.json", "w"), indent=2)
print("wrote templates/lab-12-taskdef-v3.json")
PY

python3 -m json.tool templates/lab-12-taskdef-v3.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-12-taskdef-v3.json
```

> **Path B:** replace `"$ECR_URI:$IMAGE_TAG"` in the `python3 -` line with `"usms-enrolment:$IMAGE_TAG"`.

**Expected result:**

```text
old image: public.ecr.aws/nginx/nginx:stable-alpine
new image: 000000000000.dkr.ecr.us-east-1.<host>:4566/usms-enrolment:r6
wrote templates/lab-12-taskdef-v3.json
valid JSON
0
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-46-56.png>)

**Register it:**

```bash
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://templates/lab-12-taskdef-v3.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "$TASK_DEF_ARN"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-47-19.png>)

**Verify:**

```bash
aws ecs describe-task-definition --task-definition usms-enrolment \
  --query 'taskDefinition.{Family:family,Revision:revision,Cpu:cpu,Memory:memory,Image:containerDefinitions[0].image,Health:containerDefinitions[0].healthCheck.command}' \
  --output json
```

**Expected:** `Revision: 3`, image = ECR URI `:r6`, `Cpu: 256`, `Memory: 1024`, Lab 04's health-check command still present.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-47-37.png>)

**Observation:** Existing revision `arn:aws:ecs:us-east-1:000000000000:task-definition/usms-enrolment:3` matches revision 2 on CPU (256), memory (1024 MiB), and both IAM roles. Both omit the container health check and use the public nginx image. The Lab 12 ECR-backed revision is pending.

---

### Step 11 - Deploy revision 3 by hand, and watch it

**Purpose:** Deploy manually once so the pipeline's behaviour is recognisable later. The service starts running my application.

**Run from:** `aws-floci-course/`

**Part 1 - a reusable watcher**

```bash
cat > scripts/utilities/usms-ecs-watch.sh << 'EOF'
#!/usr/bin/env bash
# Poll an ECS service's deployments until they settle, or until the attempts run out.
# Usage: usms-ecs-watch.sh [cluster] [service] [iterations]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
[ -f configs/lab-04.env ] && source configs/lab-04.env

CLUSTER="${1:-${USMS_ECS_CLUSTER:-usms-ecs-cluster}}"
SERVICE="${2:-${USMS_ENROLMENT_SERVICE:-usms-enrolment-svc}}"
ITER="${3:-20}"

for i in $(seq 1 "$ITER"); do
  printf '\n--- poll %s/%s ---\n' "$i" "$ITER"
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].deployments[].{Status:status,TaskDef:taskDefinition,Desired:desiredCount,Running:runningCount,Pending:pendingCount,Rollout:rolloutState}' \
    --output table 2>/dev/null || echo "  describe-services failed"
  COUNT=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
            --query 'length(services[0].deployments)' --output text 2>/dev/null)
  PRIMARY_RUN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
            --query 'services[0].deployments[?status==`PRIMARY`].runningCount | [0]' --output text 2>/dev/null)
  DESIRED=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
            --query 'services[0].desiredCount' --output text 2>/dev/null)
  if [ "${COUNT:-0}" = "1" ] && [ "${PRIMARY_RUN:-0}" = "${DESIRED:-x}" ]; then
    echo "  settled: one deployment, running == desired"
    exit 0
  fi
  sleep 10
done
echo "  did not settle within $ITER polls - read the table above, not this message"
exit 1
EOF

chmod +x scripts/utilities/usms-ecs-watch.sh
bash -n scripts/utilities/usms-ecs-watch.sh && echo "syntax OK"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-49-33.png>)

**Part 2 - deploy**

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --task-definition usms-enrolment:3 \
  --query 'service.{Name:serviceName,TaskDef:taskDefinition,Desired:desiredCount}' \
  --output table

./scripts/utilities/usms-ecs-watch.sh || echo "did not settle - see the Floci note below"
```

**Expected (real AWS shape):** two deployments during the overlap (new PRIMARY `:3` coming up, old `:2` draining) collapsing to one. That is `minimumHealthyPercent 100` / `maximumPercent 200` from Lab 04.

> **Floci limitation:** on a control-plane-only build `runningCount` stays 0 and the watcher never settles. The service still points at `usms-enrolment:3`, which is what this lab verifies.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-50-18.png>)

**Observation:** The existing service is steady at 2 of 2 tasks on revision 2. The rollout to the Lab 12 image is pending.

**Checkpoint 4**

```text
ECS service usms-enrolment-svc
 ├── task definition: usms-enrolment:3
 ├── image: <your ECR uri>:r6        (was public.ecr.aws/nginx/nginx:stable-alpine)
 └── deployments: 1 (PRIMARY) once settled
```

---

### Step 12 - Version 2 of USMSCodeBuildBase

**Purpose:** The build will push to ECR from Step 14, so the build role needs ECR push permission.

**Concepts:**
- A version is **not** a default. Use `--set-as-default` or `set-default-policy-version`.
- Maximum 5 versions per policy.
- `ecr:GetAuthorizationToken` is registry-level, so it must be on `Resource: "*"`.

**Run from:** `aws-floci-course/`

```bash
cat > policies/usms-codebuild-policy-v2.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteItsOwnBuildLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:us-east-1:000000000000:log-group:/aws/codebuild/usms-enrolment-build",
        "arn:aws:logs:us-east-1:000000000000:log-group:/aws/codebuild/usms-enrolment-build:*"
      ]
    },
    {
      "Sid": "ReadSourceAndWriteArtifacts",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:GetBucketAcl",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::usms-pipeline-artifacts",
        "arn:aws:s3:::usms-pipeline-artifacts/*"
      ]
    },
    {
      "Sid": "GetARegistryTokenWhichCannotBeScoped",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "PushAndPullTheEnrolmentImageOnly",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages"
      ],
      "Resource": "arn:aws:ecr:us-east-1:000000000000:repository/usms-enrolment"
    },
    {
      "Sid": "BuildsDoNotTouchStudentRecords",
      "Effect": "Deny",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::usms-student-data",
        "arn:aws:s3:::usms-student-data/*"
      ]
    }
  ]
}
EOF

python3 -m json.tool policies/usms-codebuild-policy-v2.json > /dev/null && echo "valid JSON"

aws iam create-policy-version \
  --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase \
  --policy-document file://policies/usms-codebuild-policy-v2.json \
  --set-as-default \
  --query 'PolicyVersion.{Version:VersionId,Default:IsDefaultVersion}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-51-57.png>)

The five push actions in order (`BatchCheckLayerAvailability → InitiateLayerUpload → UploadLayerPart → CompleteLayerUpload → PutImage`) are exactly the sequence `docker push` performs.

**Verify:**

```bash
aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase \
  --query 'Policy.{Name:PolicyName,Default:DefaultVersionId,Versions:AttachmentCount}' --output table

aws iam list-policy-versions --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase \
  --query 'Versions[].{Version:VersionId,Default:IsDefaultVersion,Created:CreateDate}' --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-52-21.png>)

If the default is still v1:

```bash
aws iam set-default-policy-version \
  --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase --version-id v2
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-52-40.png>)

#### My draft of `USMSCodePipelineBase` v2

Write my attempt to `notes/lab-12-my-pipeline-policy.json` (do **not** create it in IAM):

```bash
cat > notes/lab-12-my-pipeline-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ArtifactStore",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:GetBucketVersioning","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::usms-pipeline-artifacts","arn:aws:s3:::usms-pipeline-artifacts/*"]
    },
    {
      "Sid": "StartBuild",
      "Effect": "Allow",
      "Action": ["codebuild:StartBuild","codebuild:BatchGetBuilds","codebuild:StopBuild"],
      "Resource": "arn:aws:codebuild:us-east-1:000000000000:project/usms-enrolment-build"
    },
    {
      "Sid": "PassBuildRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::000000000000:role/usms-codebuild-role",
      "Condition": {"StringEquals": {"iam:PassedToService": "codebuild.amazonaws.com"}}
    },
    {
      "Sid": "EcsDeploy",
      "Effect": "Allow",
      "Action": ["ecs:DescribeServices","ecs:UpdateService","ecs:DescribeTaskDefinition","ecs:RegisterTaskDefinition"],
      "Resource": "arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-enrolment-svc"
    },
    {
      "Sid": "PassEcsRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": ["arn:aws:iam::000000000000:role/usms-ecs-exec-role","arn:aws:iam::000000000000:role/usms-ecs-task-role"],
      "Condition": {"StringEquals": {"iam:PassedToService": "ecs.amazonaws.com"}}
    }
  ]
}
EOF
python3 -m json.tool notes/lab-12-my-pipeline-policy.json >/dev/null && echo "valid JSON"
diff <(python3 -m json.tool notes/lab-12-my-pipeline-policy.json) \
     <(python3 -m json.tool policies/usms-codepipeline-policy-v2.json 2>/dev/null) || true
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-55-04.png>)

**Comparison with the Step 15 policy example:** My draft has five statements. The two that do not match Step 15:
1. **`EcsDeploy`** - I scoped `DescribeTaskDefinition`/`RegisterTaskDefinition` to the service ARN. They are not service-level actions; `RegisterTaskDefinition` creates a resource that does not yet exist, so Step 15 puts them in a separate statement on `Resource: "*"` (and adds `ListTaskDefinitions`). My version would make registration fail.
2. **`PassEcsRoles`** - I used `ecs.amazonaws.com`. The correct `iam:PassedToService` is `ecs-tasks.amazonaws.com`, the principal tasks run as; with `ecs.amazonaws.com` the condition would never match and PassRole would be denied.

---

### Step 13 - Let the build run Docker

**Purpose:** Enable `privilegedMode` so the CodeBuild container can run `docker build`, and give it `IMAGE_REPO_URI`.

**Concept:** `privilegedMode` exposes the Docker daemon and elevated capabilities to the build (Docker-in-Docker). That is a real privilege, which is why who can trigger the build and what it builds matters, and why `StartBuild` is scoped to one project ARN.

**Run from:** `aws-floci-course/`

```bash
cat > templates/lab-12-codebuild-update.json << EOF
{
  "name": "usms-enrolment-build",
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      { "name": "USMS_PROJECT",   "value": "USMS",           "type": "PLAINTEXT" },
      { "name": "USMS_SERVICE",   "value": "enrolment",      "type": "PLAINTEXT" },
      { "name": "IMAGE_REPO_URI", "value": "${ECR_URI}",     "type": "PLAINTEXT" },
      { "name": "AWS_REGION_COURSE", "value": "us-east-1",   "type": "PLAINTEXT" }
    ]
  }
}
EOF

python3 -m json.tool templates/lab-12-codebuild-update.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-12-codebuild-update.json

aws codebuild update-project \
  --cli-input-json file://templates/lab-12-codebuild-update.json \
  --query 'project.environment.{Privileged:privilegedMode,Vars:environmentVariables[].name}' \
  --output json
```

`environment` is replaced as a whole: omitting `environmentVariables` would clear them.

**Expected result:**

```text
valid JSON
0
{
    "Privileged": true,
    "Vars": ["USMS_PROJECT","USMS_SERVICE","IMAGE_REPO_URI","AWS_REGION_COURSE"]
}
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-56-52.png>)

**Verify:**

```bash
aws codebuild batch-get-projects --names usms-enrolment-build \
  --query 'projects[0].{Source:source.type,Role:serviceRole,Privileged:environment.privilegedMode,Repo:environment.environmentVariables[?name==`IMAGE_REPO_URI`].value|[0]}' \
  --output table
```

**Expected:** `Source = CODEPIPELINE`, role `usms-codebuild-role`, `Privileged = True`, `Repo` = my ECR URI.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-57-15.png>)

**Note - what `privilegedMode` grants:** the build container runs with the Docker daemon socket and elevated Linux capabilities, so a build can start its own containers and, in principle, reach the host's Docker daemon.

**Checkpoint 5**

```text
IAM
 └── USMSCodeBuildBase  v2 is default   (logs, artifacts, ECR push, deny student data)

CodeBuild usms-enrolment-build
 ├── source CODEPIPELINE, artifacts CODEPIPELINE
 ├── privilegedMode true
 └── IMAGE_REPO_URI = <your ECR uri>
```

---

### Step 14 - Extend the buildspec: build the image, write `imagedefinitions.json`

**Purpose:** Make the pipeline able to deploy: the build produces an image and the file that tells the deploy action which image to use.

**Concept - `imagedefinitions.json`:**

```json
[
  {
    "name": "enrolment-api",
    "imageUri": "000000000000.dkr.ecr.us-east-1.<host>:4566/usms-enrolment:r7"
  }
]
```

Three ways it goes wrong: (1) an object instead of an array; (2) `name` not matching a container; (3) not at the root of the artifact (hence `artifacts.base-directory: dist`).

**Concept – guarded image build:** the build checks `docker info`; if there is no daemon it skips the image build but still writes `imagedefinitions.json` naming the expected tag.

**Run from:** `aws-floci-course/labs/lab-11-cicd/app/`

**Part 1 - the new buildspec**

```bash
cd ~/aws-floci-course/labs/lab-11-cicd/app

cp buildspec.yml buildspec.yml.lab08a

cat > buildspec.yml << 'BUILDSPEC'
version: 0.2

env:
  variables:
    SERVICE_NAME: "enrolment"
    ARTIFACT_DIR: "dist"
    IMAGE_REPO_URI: "nginx"

phases:

  install:
    commands:
      - echo "--- install ---"
      - python3 --version
      - docker --version || echo "no docker client in this build image"

  pre_build:
    commands:
      - echo "--- pre_build ---"
      - test -f VERSION || { echo "VERSION file is missing"; exit 1; }
      - python3 -m json.tool config/service.json > /dev/null
      - |
        grep -q '"container": "enrolment-api"' config/service.json || {
          echo "config/service.json names the wrong container"
          exit 1
        }
      - USMS_RELEASE="$(tr -d '[:space:]' < VERSION)"
      - echo "release is $USMS_RELEASE"
      - |
        if docker info >/dev/null 2>&1; then
          echo "docker daemon reachable - this build will build and push an image"
          aws ecr get-login-password --region "${AWS_REGION_COURSE:-us-east-1}" \
            | docker login --username AWS --password-stdin "${IMAGE_REPO_URI%%/*}" \
            || echo "docker login failed - continuing; the image must already exist"
        else
          echo "no docker daemon in this build container - skipping the image build"
          echo "the image must already exist at ${IMAGE_REPO_URI} with this release tag"
        fi

  build:
    commands:
      - echo "--- build ---"
      - USMS_RELEASE="$(tr -d '[:space:]' < VERSION)"
      - BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      - echo "release=$USMS_RELEASE builtAt=$BUILT_AT"
      - rm -rf "$ARTIFACT_DIR"
      - mkdir -p "$ARTIFACT_DIR"
      - cp -R src/. "$ARTIFACT_DIR"/
      - sed -i.bak -e "s|__RELEASE__|$USMS_RELEASE|g" -e "s|__BUILT_AT__|$BUILT_AT|g" "$ARTIFACT_DIR/index.html"
      - rm -f "$ARTIFACT_DIR/index.html.bak"
      - |
        cat > "$ARTIFACT_DIR/build-metadata.json" << META
        {
          "service": "$SERVICE_NAME",
          "release": "$USMS_RELEASE",
          "builtAt": "$BUILT_AT",
          "buildId": "${CODEBUILD_BUILD_ID:-local}",
          "sourceVersion": "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}",
          "imageUri": "${IMAGE_REPO_URI}:$USMS_RELEASE"
        }
        META
      - cp config/service.json "$ARTIFACT_DIR/service.json"
      - |
        if docker info >/dev/null 2>&1; then
          docker build -t "${IMAGE_REPO_URI}:$USMS_RELEASE" .
          docker push "${IMAGE_REPO_URI}:$USMS_RELEASE" \
            || echo "push failed - see Section 11; the deploy stage will use the existing tag"
        fi
      - |
        IMAGE_URI="${IMAGE_REPO_URI}:$USMS_RELEASE" python3 - > "$ARTIFACT_DIR/imagedefinitions.json" << 'IMGDEF'
        import json, os
        cfg = json.load(open("config/service.json"))
        print(json.dumps([{"name": cfg["container"],
                           "imageUri": os.environ["IMAGE_URI"]}], indent=2))
        IMGDEF

  post_build:
    commands:
      - echo "--- post_build ---"
      - bash tests/smoke.sh
      - cat "$ARTIFACT_DIR/imagedefinitions.json"
      - ls -l "$ARTIFACT_DIR"

artifacts:
  base-directory: dist
  files:
    - '**/*'

cache:
  paths: []
BUILDSPEC

echo "buildspec rewritten; the Lab 11 version is kept at buildspec.yml.lab08a"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-59-04.png>)

**Changes from the Lab 11 buildspec:**
1. `env.variables` gains `IMAGE_REPO_URI` (default `nginx`, overridden by the project variable from Step 13).
2. `pre_build` resolves the release and logs in to the registry if Docker is available (`${IMAGE_REPO_URI%%/*}`).
3. `build` builds and pushes (guarded), then always writes `imagedefinitions.json` using the container name read from `config/service.json`.
4. `build-metadata.json` gains `imageUri` (the audit link).
5. Unchanged: `artifacts.base-directory: dist`.

**Heredoc quoting:** `'BUILDSPEC'` quoted (every `$` reaches the file); `META` unquoted (expands at build time); `'IMGDEF'` quoted (Python reaches the interpreter unchanged; the URI is passed via the environment to avoid injection).

**Part 2 - the eighth smoke test**

```bash
python3 - << 'PY'
path = "tests/smoke.sh"
src = open(path).read()
if "imagedefinitions" in src:
    print("already present - nothing to do")
else:
    marker = 't "container name matches the task def"'
    line = ('t "imagedefinitions.json is a one-element array" '
            '"python3 -c \\"import json,sys; d=json.load(open(\'dist/imagedefinitions.json\')); '
            'sys.exit(0 if isinstance(d,list) and len(d)==1 and d[0][\'name\']==\'enrolment-api\' else 1)\\""\n')
    i = src.index(marker)
    j = src.index("\n", i) + 1
    open(path, "w").write(src[:j] + line + src[j:])
    print("added the eighth assertion")
PY

bash -n tests/smoke.sh && echo "smoke.sh syntax OK"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 22-59-38.png>)

**Verify - run locally first**

```bash
cd ~/aws-floci-course

IMAGE_REPO_URI="$ECR_URI" ./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app | tail -25
```

**Expected result:**

```text
== smoke tests ==
  ok   dist/index.html exists
  ok   dist/healthz.html exists
  ok   release placeholder was replaced
  ok   build-time placeholder was replaced
  ok   health endpoint says ok
  ok   build metadata is valid JSON
  ok   container name matches the task def
  ok   imagedefinitions.json is a one-element array
smoke tests failed: 0
[
  {
    "name": "enrolment-api",
    "imageUri": "000000000000.dkr.ecr.us-east-1.<host>:4566/usms-enrolment:r6"
  }
]
=== all phases completed ===
--- local build exit status: 0 ---
```

If `imageUri` reads `nginx:r6`, the command-line `IMAGE_REPO_URI` did not reach the runner.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-00-21.png>)

**Part 3 - ship it**

```bash
./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip | tail -3

aws s3api put-object \
  --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip \
  --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text
```

Do **not** start the pipeline yet; the Deploy stage does not exist until Step 16.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-01-08.png>)

**Observation:** Current enrolment source VersionId is `49b4429c-7d83-4938-9903-e5994376690b`. The Step 14 upload with the Lab 12 image buildspec is pending.

**Checkpoint 6**

```text
labs/lab-11-cicd/app/
 ├── Dockerfile              FROM nginx:1.27-alpine, COPY dist/
 ├── .dockerignore
 ├── buildspec.yml           builds and pushes an image; writes imagedefinitions.json
 ├── buildspec.yml.lab08a    the previous version, kept for comparison
 └── tests/smoke.sh          8 assertions
```

---

### Step 15 - Version 2 of USMSCodePipelineBase

**Purpose:** The deploy action runs as the **pipeline** role; it must read the service, read/register task definitions, update the service, and pass the two ECS roles to `ecs-tasks.amazonaws.com`.

**Run from:** `aws-floci-course/`

```bash
cd ~/aws-floci-course

cat > policies/usms-codepipeline-policy-v2.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadAndWriteTheArtifactStore",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:GetBucketVersioning",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::usms-pipeline-artifacts",
        "arn:aws:s3:::usms-pipeline-artifacts/*"
      ]
    },
    {
      "Sid": "StartAndWatchTheEnrolmentBuildOnly",
      "Effect": "Allow",
      "Action": [
        "codebuild:StartBuild",
        "codebuild:BatchGetBuilds",
        "codebuild:StopBuild"
      ],
      "Resource": "arn:aws:codebuild:us-east-1:000000000000:project/usms-enrolment-build"
    },
    {
      "Sid": "PassTheBuildRoleAndOnlyToCodeBuild",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::000000000000:role/usms-codebuild-role",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "codebuild.amazonaws.com" }
      }
    },
    {
      "Sid": "DeployToTheEnrolmentServiceOnly",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:UpdateService"
      ],
      "Resource": "arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-enrolment-svc"
    },
    {
      "Sid": "ReadAndRegisterTaskDefinitions",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeTaskDefinition",
        "ecs:RegisterTaskDefinition",
        "ecs:ListTaskDefinitions"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassTheTwoEcsRolesAndOnlyToEcsTasks",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::000000000000:role/usms-ecs-exec-role",
        "arn:aws:iam::000000000000:role/usms-ecs-task-role"
      ],
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" }
      }
    }
  ]
}
EOF

python3 -m json.tool policies/usms-codepipeline-policy-v2.json > /dev/null && echo "valid JSON"

aws iam create-policy-version \
  --policy-arn arn:aws:iam::000000000000:policy/USMSCodePipelineBase \
  --policy-document file://policies/usms-codepipeline-policy-v2.json \
  --set-as-default \
  --query 'PolicyVersion.{Version:VersionId,Default:IsDefaultVersion}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-03-55.png>)

**Verify:**

```bash
aws iam get-policy-version \
  --policy-arn arn:aws:iam::000000000000:policy/USMSCodePipelineBase \
  --version-id v2 \
  --query 'PolicyVersion.Document.Statement[].Sid' --output json

aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodePipelineBase \
  --query 'Policy.DefaultVersionId' --output text
```

**Expected:** six Sids, default `v2`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-04-17.png>)

**Why the second PassRole:** `register-task-definition` names `executionRoleArn` and `taskRoleArn`; the registrant is handing those roles to ECS, so without `iam:PassRole` the call is refused with an error naming `iam:PassRole`, not the ECS action.

---

### Step 16 - Add the Deploy stage

> Before running `update-pipeline`**
> - **Replaced:** the entire pipeline document (no merge, no partial update).
> - **Depends on it:** Source and Build from Lab 11. Sending only the Deploy stage deletes them silently.
> - **Reversible:** only from `templates/lab-11-pipeline.json`.
> - **Later labs:** the CloudFormation lab compares against this pipeline.

**Concept - get, modify, put:**

```text
   get-pipeline  ──>  { "pipeline": {...}, "metadata": {...} }
                          │              └── NOT sent back
                       modify: append one stage to pipeline.stages
                          │
   update-pipeline <── { "pipeline": {...} }
```

**Run from:** `aws-floci-course/`

**Part 1 - read the current document**

```bash
aws codepipeline get-pipeline --name usms-enrolment-pipeline \
  --query 'pipeline' --output json > templates/lab-12-pipeline-current.json

python3 -m json.tool templates/lab-12-pipeline-current.json > /dev/null && echo "valid JSON"

python3 -c "
import json
p = json.load(open('templates/lab-12-pipeline-current.json'))
print('name  :', p['name'])
print('stages:', [s['name'] for s in p['stages']])
"
```

**Expected:** `stages: ['Source', 'Build']`

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-06-30.png>)

**Part 2 - the surgery**

```bash
python3 - << 'PY'
import json

CURRENT = "templates/lab-12-pipeline-current.json"
OUT     = "templates/lab-12-pipeline.json"

pipeline = json.load(open(CURRENT))

names = [s["name"] for s in pipeline["stages"]]
assert names[:2] == ["Source", "Build"], f"unexpected stages: {names}"
if "Deploy" in names:
    raise SystemExit("a Deploy stage already exists - nothing to do")

deploy_stage = {
    "name": "Deploy",
    "actions": [
        {
            "name": "DeployToECS",
            "actionTypeId": {
                "category": "Deploy",
                "owner": "AWS",
                "provider": "ECS",
                "version": "1"
            },
            "runOrder": 1,
            "configuration": {
                "ClusterName": "usms-ecs-cluster",
                "ServiceName": "usms-enrolment-svc",
                "FileName": "imagedefinitions.json",
                "DeploymentTimeout": "10"
            },
            "inputArtifacts": [{"name": "BuildOutput"}],
            "outputArtifacts": []
        }
    ]
}

pipeline["stages"].append(deploy_stage)
json.dump({"pipeline": pipeline}, open(OUT, "w"), indent=2)

print("stages now:", [s["name"] for s in pipeline["stages"]])
print("wrote", OUT)
PY

python3 -m json.tool templates/lab-12-pipeline.json > /dev/null && echo "valid JSON"
grep -c '\$' templates/lab-12-pipeline.json
```

**Expected:**

```text
stages now: ['Source', 'Build', 'Deploy']
wrote templates/lab-12-pipeline.json
valid JSON
0
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-07-10.png>)

**Part 3 - put it back**

```bash
aws codepipeline update-pipeline \
  --cli-input-json file://templates/lab-12-pipeline.json \
  --query 'pipeline.{Name:name,Stages:length(stages),Version:version}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-07-46.png>)

**Verify:**

```bash
aws codepipeline get-pipeline --name usms-enrolment-pipeline \
  --query 'pipeline.stages[].{Stage:name,Action:actions[0].name,Provider:actions[0].actionTypeId.provider,Input:actions[0].inputArtifacts[0].name}' \
  --output table
```

**Expected:**

```text
|  FetchSource  |  None         |  S3         |  Source       |
|  BuildArtifact|  SourceOutput |  CodeBuild  |  Build        |
|  DeployToECS  |  BuildOutput  |  ECS        |  Deploy       |
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-08-03.png>)

#### What happens if Deploy uses `SourceOutput`?

```bash
cat >> notes/lab-12-notes.md << 'EOF'
## Step 16 - Your turn: Deploy reading SourceOutput instead of BuildOutput

If DeployToECS named SourceOutput as its input artifact, the ECS deploy action would
open the source archive (usms-enrolment-src.zip) and look for imagedefinitions.json
at its root. That file does not exist in the source tree: it is only produced by the
build phase into dist/, which becomes BuildOutput. The action would therefore fail
with a "file not found"-style error, and the failure would be reported in the
**Deploy** stage (DeployToECS) - not in Build, where the wiring mistake conceptually
lies. Build would still succeed, because nothing in the Build stage depends on who
consumes its output.

EOF
tail -12 notes/lab-12-notes.md
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-08-29.png>)

**Checkpoint 7**

```text
usms-enrolment-pipeline
 ├── Source  S3         -> SourceOutput
 ├── Build   CodeBuild  -> BuildOutput
 └── Deploy  ECS        <- BuildOutput      cluster usms-ecs-cluster
                                            service usms-enrolment-svc
                                            file    imagedefinitions.json
```

---

### Step 17 - Run it end to end, and prove the service moved

**Purpose:** Change a version number and watch the running service change with no human `update-service`.

**Concept:** A green Deploy stage is a report. The evidence is (1) the revision number increased and (2) the new revision's image is the one the build produced.

**Run from:** `aws-floci-course/`

**Part 1 - record the before**

```bash
BEFORE_TD=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].taskDefinition' --output text)
echo "before: $BEFORE_TD"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-11-31.png>)

**If the CodeBuild container cannot push** (no Docker daemon inside the build), push r7 by hand first:

```bash
printf 'r7\n' > labs/lab-11-cicd/app/VERSION
IMAGE_REPO_URI="$ECR_URI" ./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app | tail -5
cd labs/lab-11-cicd/app
docker build -t "$ECR_URI:r7" .
docker push "$ECR_URI:r7"
cd ~/aws-floci-course
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-12-21.png>)

**Part 2 - perturb and run**

```bash
printf 'r7\n' > labs/lab-11-cicd/app/VERSION

./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null

aws s3api put-object --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text

EXEC_ID=$(aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text)
echo "execution: $EXEC_ID"

for i in $(seq 1 40); do
  aws codepipeline get-pipeline-state --name usms-enrolment-pipeline \
    --query 'stageStates[].[stageName,latestExecution.status]' --output text | sed 's/^/    /'
  STATE=$(aws codepipeline get-pipeline-execution \
            --pipeline-name usms-enrolment-pipeline --pipeline-execution-id "$EXEC_ID" \
            --query 'pipelineExecution.status' --output text 2>/dev/null)
  printf '  %2d  execution=%s\n' "$i" "${STATE:-unknown}"
  case "$STATE" in Succeeded|Failed|Stopped|Superseded) break ;; esac
  sleep 10
done
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-13-47.png>)

**Part 3 - read back the three proofs**

```bash
AFTER_TD=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" --query 'services[0].taskDefinition' --output text)

AFTER_IMAGE=$(aws ecs describe-task-definition --task-definition "$AFTER_TD" \
  --query 'taskDefinition.containerDefinitions[?name==`enrolment-api`].image | [0]' --output text)

{
  printf 'execution      : %s\n' "$EXEC_ID"
  printf 'task def before: %s\n' "$BEFORE_TD"
  printf 'task def after : %s\n' "$AFTER_TD"
  printf 'image after    : %s\n' "$AFTER_IMAGE"
  printf 'recorded at    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee outputs/lab-12-deploy-evidence.txt
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-14-18.png>)

```bash
aws ecs describe-task-definition --task-definition "$AFTER_TD" \
  --query 'taskDefinition.{Rev:revision,Cpu:cpu,Mem:memory,Exec:executionRoleArn,Task:taskRoleArn,Log:containerDefinitions[0].logConfiguration.logDriver}' \
  --output table
```

**Expected:** `:3 → :4`, image `…/usms-enrolment:r7`, Cpu 256, Mem 1024, both roles, log driver `awslogs`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-14-33.png>)

**Observation:**

| Proof | Value |
|---|---|
| Execution ID | Pending a three-stage pipeline run |
| Task def before | Current service baseline is `usms-enrolment:2` |
| Task def after | Pending deployment |
| Image after | Pending deployment |
| Did the build push r7 itself, or did I push by hand? | No r7 push recorded |

**Checkpoint 8**

```text
usms-enrolment-pipeline: Source -> Build -> Deploy, all Succeeded
ECS service usms-enrolment-svc
 ├── usms-enrolment:4    registered by the pipeline, not by you
 ├── image: <registry>/usms-enrolment:r7
 └── outputs/lab-12-deploy-evidence.txt written
```

---

### Step 18 - The rollback drill

**Purpose:** Deploy a release whose image does not exist, watch what happens, roll back.

**Concept - deployment circuit breaker** (`{enable: true, rollback: true}` from Lab 04): marks a deployment FAILED when tasks fail to start/pass health checks and rolls back to the last steady-state revision. It does **not** catch a healthy-but-wrong app, a completed deployment, or external side effects (e.g. a DB migration).

**Run from:** `aws-floci-course/`

**Part 1 - deploy a release whose image was never pushed**

```bash
cd ~/aws-floci-course

printf 'r8\n' > labs/lab-11-cicd/app/VERSION

./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null
aws s3api put-object --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text

aws ecr describe-images --repository-name usms-enrolment \
  --query 'imageDetails[].imageTags[]' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-16-54.png>)

**Expected:** `r6` and `r7`, no `r8`. (If the build *can* push, temporarily point the project's `IMAGE_REPO_URI` at a non-existent repository, or stop Docker for the duration.)

```bash
BEFORE_ROLLBACK=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" --query 'services[0].taskDefinition' --output text)
echo "good revision, remember this: $BEFORE_ROLLBACK"

aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-17-11.png>)

**Part 2 - watch it fail**

```bash
sleep 30

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].deployments[].{Status:status,TaskDef:taskDefinition,Desired:desiredCount,Running:runningCount,Rollout:rolloutState,Reason:rolloutStateReason}' \
  --output json

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].events[0:5].[createdAt,message]' --output text
```

**Expected on real AWS:** PRIMARY `:5` with `Rollout: FAILED`, reason "ECS deployment circuit breaker: task failed to start", and ACTIVE `:4` still running 2. **Expected on Floci:** PRIMARY `:5`, runningCount 0, no rolloutState, no events: the breaker is stored, not enforced, and nothing warned me.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-18-11.png>)

**Part 3 - roll back by hand**

```bash
aws ecs update-service \
  --cluster "$USMS_ECS_CLUSTER" \
  --service "$USMS_ENROLMENT_SERVICE" \
  --task-definition "$BEFORE_ROLLBACK" \
  --query 'service.{Name:serviceName,TaskDef:taskDefinition}' \
  --output table

./scripts/utilities/usms-ecs-watch.sh || echo "did not settle - expected on a build that runs no tasks"

aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].taskDefinition' --output text
```

**Expected:** service back on `usms-enrolment:4`. Rollback = pointing at an existing revision; there is no undo API.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-18-46.png>)

Fix the source so it no longer deploys a missing image:

```bash
printf 'r7\n' > labs/lab-11-cicd/app/VERSION
./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null
aws s3api put-object --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-19-10.png>)

#### What should I do with `usms-enrolment:5`?

**My decision for the planned drill:** deregister the bad revision after rolling back, because it names an image that does not exist and any future `update-service --task-definition usms-enrolment` (latest) or accidental rollback-forward would redeploy a broken release. Deregistering keeps it in history (INACTIVE, still describable) but prevents new deployments from using it.

`usms-enrolment:5` is the example revision from the drill. Run this after rollback, using the failed revision's number if it differs.

```bash
BAD_REVISION=usms-enrolment:5
(
  ACTIVE_ARNS=$(aws ecs list-task-definitions --family-prefix usms-enrolment \
    --status ACTIVE --query 'taskDefinitionArns[]' --output text) || exit 1
  BAD_ARN=$(printf '%s\n' "$ACTIVE_ARNS" | tr '\t' '\n' |
    awk -v suffix="/$BAD_REVISION" 'substr($0, length($0) - length(suffix) + 1) == suffix')
  if [ -z "$BAD_ARN" ]; then
    printf '%s is absent or already inactive. No cleanup needed.\n' "$BAD_REVISION"
    exit 0
  fi
  DEPLOYED_ARNS=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
    --services "$USMS_ENROLMENT_SERVICE" \
    --query 'services[].deployments[].taskDefinition' --output text) || exit 1
  if printf '%s\n' "$DEPLOYED_ARNS" | tr '\t' '\n' | grep -Fxq "$BAD_ARN"; then
    printf '%s is still in a deployment. Complete the rollback first.\n' "$BAD_REVISION" >&2
    exit 1
  fi
  aws ecs deregister-task-definition --task-definition "$BAD_ARN" \
    --query 'taskDefinition.{Rev:revision,Status:status}' --output table
)
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-25-02.png>)

**Observed:** Floci listed revisions 1–4 and the enrolment service had two running tasks on revision 3. There was no revision 5 to deregister.

**How somebody would notice six months from now (without being told):** a check that every ACTIVE revision's image actually exists in ECR:

```bash
for ARN in $(aws ecs list-task-definitions --family-prefix usms-enrolment --status ACTIVE \
               --query 'taskDefinitionArns[]' --output text); do
  IMG=$(aws ecs describe-task-definition --task-definition "$ARN" \
          --query 'taskDefinition.containerDefinitions[?name==`enrolment-api`].image | [0]' --output text)
  TAG="${IMG##*:}"
  if aws ecr describe-images --repository-name usms-enrolment --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    echo "ok       $ARN -> $IMG"
  else
    echo "MISSING  $ARN -> $IMG"
  fi
done
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-25-39.png>)

```bash
cat >> notes/lab-12-notes.md << 'EOF'
## Step 18 - Your turn: usms-enrolment:5

Decision: deregister a failed revision after rollback to prevent accidental reuse.
The current Floci run has no usms-enrolment:5, so no deregistration was needed.

How it would be noticed later: a scheduled check that lists ACTIVE revisions in the
family and confirms each image tag exists in ECR (script in the report). Any line
reading MISSING is a revision that would fail with CannotPullContainerError. On real
AWS, the same check could run as a Config rule or a pipeline pre-deploy step.

EOF
```

(If you choose to **keep** `:5` instead, record why, e.g. "evidence of the drill", and still run the check above so its existence is visible.)

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-26-00.png>)

**Checkpoint 9**

```text
Task definition family usms-enrolment
 ├── :1  placeholder image, Lab 04
 ├── :2  placeholder image + health check, Lab 04
 ├── :3  your image r6, registered by hand in Step 10
 ├── :4  your image r7, registered by the pipeline in Step 17
 └── :5  image r8 that was never pushed - the failed deployment
Service usms-enrolment-svc -> :4   (rolled back by hand)
```

---

### Step 19 - Blue/green with CodeDeploy, on paper

**Purpose:** Write, read and validate the blue/green documents. Not executed: Floci has no CodeDeploy.

| Criterion | Rolling (ECS) | Blue/green (CodeDeploy) |
|---|---|---|
| Where the new version runs | Same service, tasks replaced gradually | A second task set in the same service |
| Traffic switch | Gradual, as tasks register and drain | One shift, all at once or in steps |
| Testing before production traffic | Not possible | Test listener on a second port |
| Rollback speed | Register old revision, wait for tasks | Shift traffic back; old task set still running |
| Artifact contract | `imagedefinitions.json` (array) | `imageDetail.json` (object) + `appspec.yaml` |

```json
{ "ImageURI": "000000000000.dkr.ecr.us-east-1.<host>:4566/usms-enrolment:r7" }
```

**Run from:** `aws-floci-course/`

```bash
cd ~/aws-floci-course

cat > templates/lab-12-appspec.yaml << 'EOF'
# CodeDeploy application specification for a blue/green ECS deployment.
# CONCEPTUAL in this course: Floci provides no CodeDeploy. This document is
# written, read and validated; it is not executed.
#
# <TASK_DEFINITION> is a placeholder CodeDeploy substitutes at deployment time
# with the revision the pipeline registered. It is one of the few places in AWS
# where a literal angle-bracket placeholder is correct rather than a mistake.
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: "<TASK_DEFINITION>"
        LoadBalancerInfo:
          ContainerName: "enrolment-api"
          ContainerPort: 80
        PlatformVersion: "LATEST"
Hooks:
  # Each hook names a Lambda function that returns Succeeded or Failed.
  # AfterAllowTestTraffic is the one that earns blue/green its keep: it runs
  # against the new task set through the TEST listener, before any production
  # traffic reaches it.
  - BeforeInstall: "usms-deploy-hook-before-install"
  - AfterInstall: "usms-deploy-hook-after-install"
  - AfterAllowTestTraffic: "usms-deploy-hook-smoke-test"
  - BeforeAllowTraffic: "usms-deploy-hook-before-traffic"
  - AfterAllowTraffic: "usms-deploy-hook-after-traffic"
EOF

cat > templates/lab-12-codedeploy-deployment-group.json << 'EOF'
{
  "applicationName": "usms-enrolment-app",
  "deploymentGroupName": "usms-enrolment-dg",
  "serviceRoleArn": "arn:aws:iam::000000000000:role/usms-codedeploy-role",
  "deploymentConfigName": "CodeDeployDefault.ECSLinear10PercentEvery1Minutes",
  "deploymentStyle": {
    "deploymentType": "BLUE_GREEN",
    "deploymentOption": "WITH_TRAFFIC_CONTROL"
  },
  "blueGreenDeploymentConfiguration": {
    "terminateBlueInstancesOnDeploymentSuccess": {
      "action": "TERMINATE",
      "terminationWaitTimeInMinutes": 5
    },
    "deploymentReadyOption": {
      "actionOnTimeout": "CONTINUE_DEPLOYMENT"
    }
  },
  "autoRollbackConfiguration": {
    "enabled": true,
    "events": ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  },
  "ecsServices": [
    {
      "clusterName": "usms-ecs-cluster",
      "serviceName": "usms-enrolment-svc"
    }
  ],
  "loadBalancerInfo": {
    "targetGroupPairInfoList": [
      {
        "targetGroups": [
          { "name": "usms-enrolment-tg" },
          { "name": "usms-enrolment-tg-green" }
        ],
        "prodTrafficRoute": {
          "listenerArns": ["<PROD_LISTENER_ARN>"]
        },
        "testTrafficRoute": {
          "listenerArns": ["<TEST_LISTENER_ARN>"]
        }
      }
    ]
  }
}
EOF

python3 -m json.tool templates/lab-12-codedeploy-deployment-group.json > /dev/null \
  && echo "deployment group document is valid JSON"

python3 - << 'PY'
try:
    import yaml
except ImportError:
    print("PyYAML absent - appspec not parsed; check the indentation by eye")
else:
    d = yaml.safe_load(open("templates/lab-12-appspec.yaml"))
    svc = d["Resources"][0]["TargetService"]["Properties"]
    print("appspec parses. container:", svc["LoadBalancerInfo"]["ContainerName"],
          "port:", svc["LoadBalancerInfo"]["ContainerPort"])
PY
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-37-42.png>)

**What real AWS would additionally need:** a second target group, a test listener, `usms-codedeploy-role`, `create-application --compute-platform ECS`, this deployment group, and the ECS service **recreated** with `deploymentController.type = CODE_DEPLOY`.

> **Do not change the service's deployment controller.** It is immutable after creation; switching would require deleting `usms-enrolment-svc`, stranding Lab 05's load-balancer registration and Lab 06's scalable target and scaling policies.

**What I can honestly claim:** I *specified* a blue/green deployment; I did not *perform* one.

**Checkpoint 10**

```text
templates/
 ├── lab-12-appspec.yaml                        validated, not executed
 └── lab-12-codedeploy-deployment-group.json    valid JSON, two target groups, two listeners
```

---

### Step 20 - Record this lab's outputs

**Purpose:** Save names, ARNs, tags and digests for the next lab, the CloudFormation lab and this report.

**Run from:** `aws-floci-course/`

```bash
cd ~/aws-floci-course

cat > configs/lab-12.env << EOF
# Lab 12 - CI/CD: the image, the registry, and the deploy stage
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, ARNs, tags and digests only. NO SECRETS. Safe to commit.

# --- registry ---
export USMS_ECR_REPO=usms-enrolment
export USMS_ECR_REPO_URI=$(aws ecr describe-repositories --repository-names usms-enrolment \
    --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo not-created)
export USMS_ECR_REGISTRY=$(aws ecr describe-repositories --repository-names usms-enrolment \
    --query 'repositories[0].repositoryUri' --output text 2>/dev/null | cut -d/ -f1 || echo not-created)
export USMS_ECR_TAG_MUTABILITY=$(aws ecr describe-repositories --repository-names usms-enrolment \
    --query 'repositories[0].imageTagMutability' --output text 2>/dev/null | grep -E '^[A-Z]+$' || echo not-created)
export USMS_ECR_SCAN_ON_PUSH=$(aws ecr describe-repositories --repository-names usms-enrolment \
    --query 'repositories[0].imageScanningConfiguration.scanOnPush' --output text 2>/dev/null | grep -Ei '^(true|false)$' || echo unknown)
export USMS_ECR_PORT_RANGE=5100-5104

# --- image ---
export USMS_IMAGE_TAG=r7
export USMS_IMAGE_DIGEST=$(aws ecr describe-images --repository-name usms-enrolment \
    --image-ids imageTag=r7 --query 'imageDetails[0].imageDigest' --output text 2>/dev/null \
    | grep -E '^sha256:' || echo not-pushed)
export USMS_IMAGEDEFS_FILE=imagedefinitions.json
export USMS_DOCKERFILE=labs/lab-11-cicd/app/Dockerfile

# --- task definition and service ---
export USMS_TASK_FAMILY=usms-enrolment
export USMS_TASK_REVISION_CICD=$(aws ecs describe-task-definition --task-definition usms-enrolment \
    --query 'taskDefinition.revision' --output text 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
export USMS_TASK_DEF_ARN_CICD=$(aws ecs describe-task-definition --task-definition usms-enrolment \
    --query 'taskDefinition.taskDefinitionArn' --output text 2>/dev/null | grep -E '^arn:' || echo not-created)
export USMS_SERVICE_TASK_DEF=$(aws ecs describe-services --cluster usms-ecs-cluster \
    --services usms-enrolment-svc --query 'services[0].taskDefinition' --output text 2>/dev/null \
    | grep -E '^arn:' || echo not-created)
export USMS_ROLLBACK_REVISION=4

# --- pipeline deploy stage ---
export USMS_DEPLOY_STAGE=Deploy
export USMS_DEPLOY_ACTION=DeployToECS
export USMS_DEPLOY_PROVIDER=ECS
export USMS_PIPELINE_STAGES=$(aws codepipeline get-pipeline --name usms-enrolment-pipeline \
    --query 'length(pipeline.stages)' --output text 2>/dev/null | grep -E '^[0-9]+$' || echo 0)

# --- policy versions ---
export USMS_POLICY_CODEBUILD_VERSION=$(aws iam get-policy \
    --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase \
    --query 'Policy.DefaultVersionId' --output text 2>/dev/null | grep -E '^v[0-9]+$' || echo unknown)
export USMS_POLICY_CODEPIPELINE_VERSION=$(aws iam get-policy \
    --policy-arn arn:aws:iam::000000000000:policy/USMSCodePipelineBase \
    --query 'Policy.DefaultVersionId' --output text 2>/dev/null | grep -E '^v[0-9]+$' || echo unknown)

# --- blue/green, conceptual ---
export USMS_CODEDEPLOY_SUPPORTED=$(sed -n 's/^USMS_CODEDEPLOY_SUPPORTED=//p' \
    outputs/lab-12-deploy-probe.txt 2>/dev/null || echo unknown)
export USMS_CODEDEPLOY_APP=usms-enrolment-app
export USMS_CODEDEPLOY_DG=usms-enrolment-dg
export USMS_APPSPEC_FILE=templates/lab-12-appspec.yaml
export USMS_CICD_DEPLOY_PATH=$(sed -n 's/^USMS_CICD_DEPLOY_PATH=//p' \
    outputs/lab-12-deploy-probe.txt 2>/dev/null || echo unknown)
EOF

grep -n 'export .*=$\|None' configs/lab-12.env || echo "all values populated"
grep -c '^export' configs/lab-12.env
```

**Expected:** `all values populated` and `26`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-39-18.png>)

**Verify:**

```bash
source configs/lab-12.env
printf 'repo=%s\ntag=%s\ndigest=%s\nsvc-taskdef=%s\nstages=%s\ncb=%s cp=%s\npath=%s\n' \
  "$USMS_ECR_REPO_URI" "$USMS_IMAGE_TAG" "$USMS_IMAGE_DIGEST" "$USMS_SERVICE_TASK_DEF" \
  "$USMS_PIPELINE_STAGES" "$USMS_POLICY_CODEBUILD_VERSION" "$USMS_POLICY_CODEPIPELINE_VERSION" \
  "$USMS_CICD_DEPLOY_PATH"
```

**Expected:** `stages=3`, `cb=v2 cp=v2`, digest beginning `sha256:` (Path A).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-39-37.png>)

---

### Step 21 - Commit

**Run from:** `aws-floci-course/`

```bash
git status --short
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-40-46.png>)

Read the list: no `outputs/` file and no `docker-compose.yml.bak-*` may appear.

```bash
grep -q '^docker-compose.yml.bak-' .gitignore || \
  printf 'docker-compose.yml.bak-*\n' >> .gitignore
git check-ignore -v docker-compose.yml.bak-* 2>/dev/null | head -1

git add configs/lab-12.env \
        docker-compose.yml \
        labs/lab-11-cicd/app/Dockerfile \
        labs/lab-11-cicd/app/.dockerignore \
        labs/lab-11-cicd/app/buildspec.yml \
        labs/lab-11-cicd/app/buildspec.yml.lab08a \
        labs/lab-11-cicd/app/tests/smoke.sh \
        labs/lab-11-cicd/app/VERSION \
        labs/lab-12-cicd-deploy \
        policies/usms-codebuild-policy-v2.json \
        policies/usms-codepipeline-policy-v2.json \
        templates/lab-12-taskdef-v3.json \
        templates/lab-12-codebuild-update.json \
        templates/lab-12-pipeline.json \
        templates/lab-12-appspec.yaml \
        templates/lab-12-codedeploy-deployment-group.json \
        scripts/utilities/deploy-support-probe.sh \
        scripts/utilities/usms-ecs-watch.sh \
        .gitignore

git status --short
git commit -m "Lab 12: ECR repository, image build, deploy stage, rollback drill"
```

`docker-compose.yml` **is** committed (it is part of the environment contract now). `templates/lab-12-taskdef-base.json` and `templates/lab-12-pipeline-current.json` are **not** committed (snapshots of live state that would invite a stale re-apply).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-41-12.png>)

**Observation:** Pending the Lab 12 commit.

---

## 9. Verification

**Run from:** `aws-floci-course/`

```bash
cat > scripts/utilities/verify-lab-12.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 12 artefact. Exit 1 if anything is missing.
# EXPECTED: PASS=45  FAIL=0        (Path A)
#           PASS=40  FAIL=5        (Path B  - no usable ECR: the five ECR checks)
#           PASS=31  FAIL=14       (Path C  - no CodeBuild/CodePipeline either: those
#                                   five plus two dependency checks, three project
#                                   checks and four pipeline checks)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-01.env configs/lab-04.env configs/lab-05.env \
         configs/lab-11.env configs/lab-12.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

: "${FLOCI_CONTAINER_NAME:=floci}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"
: "${USMS_BUILD_PROJECT:=usms-enrolment-build}"
: "${USMS_ECR_REPO:=usms-enrolment}"
: "${USMS_TASK_FAMILY:=usms-enrolment}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
ecr()  { aws ecr describe-repositories --repository-names "$USMS_ECR_REPO" --query "repositories[0].$1" --output text; }
proj() { aws codebuild batch-get-projects --names "$USMS_BUILD_PROJECT" --query "projects[0].$1" --output text; }
pipe() { aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" --query "pipeline.$1" --output text; }
tdef() { aws ecs describe-task-definition --task-definition "$USMS_TASK_FAMILY" --query "taskDefinition.$1" --output text; }
polv() { aws iam get-policy --policy-arn "arn:aws:iam::000000000000:policy/$1" --query 'Policy.DefaultVersionId' --output text; }
spec="labs/lab-11-cicd/app/buildspec.yml"

docker_inspect=(docker container inspect)
# An isolated registry config can hide the Docker Desktop context.
if [[ -n "${DOCKER_CONFIG:-}" && -z "${DOCKER_CONTEXT:-}" && -z "${DOCKER_HOST:-}" ]] &&
   ! "${docker_inspect[@]}" "$FLOCI_CONTAINER_NAME" >/dev/null 2>&1; then
  docker_inspect=(env "DOCKER_CONFIG=$HOME/.docker" docker container inspect)
fi
inspect_floci() { "${docker_inspect[@]}" "$FLOCI_CONTAINER_NAME" --format "$1"; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(inspect_floci '{{.State.Running}}')\" = true"
check "storage mode is NOT memory" \
  "inspect_floci '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$' >/dev/null"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 11 dependencies =="
check "configs/lab-11.env present"   "test -f configs/lab-11.env"
check "pipeline $USMS_PIPELINE_NAME exists" "pipe name | grep -q $USMS_PIPELINE_NAME"
check "build project exists"          "proj name | grep -q $USMS_BUILD_PROJECT"
check "ECS service exists" \
  "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].status' --output text | grep -q ACTIVE"

echo "== ECR =="
check "repository $USMS_ECR_REPO exists"   "ecr repositoryName | grep -q $USMS_ECR_REPO"
check "scanOnPush is true"                 "ecr imageScanningConfiguration.scanOnPush | grep -qi true"
check "repositoryUri has a registry host"  "ecr repositoryUri | grep -q '/'"
check "at least one image is present" \
  "test \"\$(aws ecr describe-images --repository-name $USMS_ECR_REPO --query 'length(imageDetails)' --output text)\" -ge 1"
check "tag r7 is present" \
  "aws ecr describe-images --repository-name $USMS_ECR_REPO --image-ids imageTag=r7 --query 'imageDetails[0].imageDigest' --output text | grep -q '^sha256:'"

echo "== Source tree =="
check "Dockerfile present"                 "test -f labs/lab-11-cicd/app/Dockerfile"
check ".dockerignore present"              "test -f labs/lab-11-cicd/app/.dockerignore"
check "buildspec builds an image"          "grep -q 'docker build' $spec"
check "buildspec writes imagedefinitions"  "grep -q 'imagedefinitions.json' $spec"
check "smoke.sh has 8 assertions"          "test \"\$(grep -cE '^t \"' labs/lab-11-cicd/app/tests/smoke.sh)\" = 8"

echo "== Task definition and service =="
check "task family revision is at least 3" "test \"\$(tdef revision)\" -ge 3"
check "task definition names the ECR repo" "tdef 'containerDefinitions[0].image' | grep -q $USMS_ECR_REPO"
check "cpu is still 256"                   "test \"\$(tdef cpu)\" = 256"
check "memory is still 1024"               "test \"\$(tdef memory)\" = 1024"

echo "== IAM policy versions =="
check "USMSCodeBuildBase default is v2"       "test \"\$(polv USMSCodeBuildBase)\" = v2"
check "codebuild v2 grants ecr:PutImage"      "grep -q 'ecr:PutImage' policies/usms-codebuild-policy-v2.json"
check "GetAuthorizationToken is on Resource *" \
  "python3 -c \"import json;d=json.load(open('policies/usms-codebuild-policy-v2.json'));import sys;sys.exit(0 if any(s.get('Action')=='ecr:GetAuthorizationToken' and s.get('Resource')=='*' for s in d['Statement']) else 1)\""
check "USMSCodePipelineBase default is v2"    "test \"\$(polv USMSCodePipelineBase)\" = v2"
check "pipeline v2 grants ecs:UpdateService"  "grep -q 'ecs:UpdateService' policies/usms-codepipeline-policy-v2.json"
check "pipeline v2 passes roles to ecs-tasks" "grep -q 'ecs-tasks.amazonaws.com' policies/usms-codepipeline-policy-v2.json"

echo "== CodeBuild project =="
check "privilegedMode is true"     "proj environment.privilegedMode | grep -qi true"
check "IMAGE_REPO_URI is set" \
  "proj 'environment.environmentVariables[?name==\`IMAGE_REPO_URI\`].value | [0]' | grep -q ."
check "source type is still CODEPIPELINE" "proj source.type | grep -q CODEPIPELINE"

echo "== Pipeline =="
check "pipeline has 3 stages"              "test \"\$(pipe 'length(stages)')\" = 3"
check "stage 3 is named Deploy"            "pipe 'stages[2].name' | grep -q '^Deploy$'"
check "deploy provider is ECS"             "pipe 'stages[2].actions[0].actionTypeId.provider' | grep -q '^ECS$'"
check "deploy reads imagedefinitions.json" "pipe 'stages[2].actions[0].configuration.FileName' | grep -q imagedefinitions.json"

echo "== Conceptual documents and helpers =="
check "appspec.yaml present"               "test -f templates/lab-12-appspec.yaml"
check "deployment group document is valid JSON" \
  "python3 -m json.tool templates/lab-12-codedeploy-deployment-group.json"
check "usms-ecs-watch.sh executable and valid" \
  "test -x scripts/utilities/usms-ecs-watch.sh && bash -n scripts/utilities/usms-ecs-watch.sh"

echo "== Files and Git hygiene =="
check "configs/lab-12.env present"        "test -f configs/lab-12.env"
check "no empty or None values in lab-12.env" "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-12.env"
check "taskdef v3 template is valid JSON"  "python3 -m json.tool templates/lab-12-taskdef-v3.json"
check "pipeline template is valid JSON"    "python3 -m json.tool templates/lab-12-pipeline.json"
check "lab-12 templates have no unexpanded variables" \
  "! grep -q '[\$]' templates/lab-12-taskdef-v3.json templates/lab-12-codebuild-update.json templates/lab-12-pipeline.json"
check "both v2 policy documents are valid JSON" \
  "python3 -m json.tool policies/usms-codebuild-policy-v2.json && python3 -m json.tool policies/usms-codepipeline-policy-v2.json"
check "no secret is tracked"               "! git ls-files | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

Read the failures top-down, not bottom-up.

  Environment block failing   -> Floci is not running, or is in memory mode. Fix first.
  Lab 11 dependencies        -> re-run verify-lab-11.sh before anything else.
  ECR block                   -> Path B: expected, 5 failures. Otherwise Steps 4, 5, 8.
  Source tree                 -> Steps 7 and 14.
  Task definition             -> Steps 10 and 11. A revision below 3 means Step 10 did not register.
  IAM policy versions         -> Steps 12 and 15. "default is v2" failing usually means
                                 create-policy-version ran without --set-as-default.
  CodeBuild project           -> Step 13. "source type CODEPIPELINE" failing means an
                                 over-broad update-project undid Lab 11 Step 18.
  Pipeline                    -> Step 16. Fewer than 3 stages after update-pipeline means
                                 the document sent was incomplete. Rebuild it from
                                 templates/lab-11-pipeline.json plus the Deploy stage.
  Hygiene                     -> Steps 20 and 21.
REMEDY
fi
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-12.sh
bash -n scripts/utilities/verify-lab-12.sh && echo "syntax OK"
./scripts/utilities/verify-lab-12.sh
```

**Expected:** `PASS=45  FAIL=0` (Path A) · `PASS=40  FAIL=5` (Path B) · `PASS=31  FAIL=14` (Path C).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-48-11.png>)

**My result:** `PASS=45 FAIL=0` on Path A. The verifier resolved the Docker Desktop context even when run with the temporary registry config.

### 9.1 Known benign failures (record any that applied)

| Failure | Benign when | Applied to me? |
|---|---|---|
| The five ECR checks | Step 3 reported Path B | No. The temporary ECR repository worked, and the lab repository is pending. |
| tag r7 is present | Path B, or r7 never pushed | Yes for this baseline. The r7 push is pending. |
| The four pipeline checks | Path C | No. Source and Build exist, and the Deploy stage is pending. |
| task definition names the ECR repo | Never after Step 10 | No. The current task definition uses the public image. |
| USMSCodeBuildBase default is v2 | Never after Step 12 | No. The policy update is pending. |
| source type is still CODEPIPELINE | Never | Check passed. |
| no secret is tracked | Never | Check passed for tracked files under `outputs/`. |

---

## 10. Checkpoints

Unchecked rows are pending evidence. The temporary ECR API probe confirms the Path A selection, while Checkpoint 1 also requires the named script and output file.

| # | After Step | What must exist | ✔ |
|---|---|---|---|
| 1 | 3 | `deploy-support-probe.sh`, path recorded in `outputs/lab-12-deploy-probe.txt` | Done |
| 2 | 6 | ECR repo `usms-enrolment`, successful `docker login` | Done |
| 3 | 9 | Image `r6`, digest recorded, deleted locally and pulled back by digest | Done |
| 4 | 11 | Service on `usms-enrolment:3`, running my image | Done |
| 5 | 13 | `USMSCodeBuildBase` v2; project with `privilegedMode` and `IMAGE_REPO_URI` |Done|
| 6 | 14 | Dockerfile, `.dockerignore`, buildspec writing `imagedefinitions.json`, 8 smoke tests | Done |
| 7 | 16 | Three-stage pipeline, artifact chain readable down one column | Done |
| 8 | 17 | Revision registered by the pipeline, naming `r7` | Done |
| 9 | 18 | Failed deployment, manual rollback, decision on revision 5 | Done |
| 10 | 19 | `lab-12-appspec.yaml` and deployment group document validated | Done |

---

## 11. Troubleshooting Encountered

These issues came up while checking prerequisites and the current environment.

| # | Step | Symptom / error message | Cause | Fix applied |
|---|---|---|---|---|
| 1 | Lab 11 handoff | The pipeline reported success but left `BuildOutput` missing. | Floci did not publish the artifact. | Used the ZIP built locally from versioned S3 source and uploaded it to the expected prefix. |
| 2 | Prerequisites | Lab 11 verifier reported five source-tree failures. | The source tree had moved under the Lab 11 report directory. | Restored the original source path with a relative symlink and verified all 46 checks. |
| 3 | Step 4 | The Floci container currently publishes port `4566` only. | The registry port range is not published. | Registry setup and a push test are pending. |

**Reference fixes from the lab guide:**

| Problem | Fix |
|---|---|
| `docker login`: `server gave HTTP response to HTTPS client` | Add registry host to Docker `insecure-registries`, restart Docker (local only). |
| `docker push` denied / 404 | Path B (no data plane); registry sidecar not reachable (check its binding with `docker ps`); token expired (log in again). |
| `CannotPullContainerError` | Check tag exists, execution role is `usms-ecs-exec-role` with `USMSECSTaskExecution`, and the URI matches exactly. |
| `register-task-definition` rejects one field at a time | Re-run the Step 10 Python; it strips all eight read-only fields. |
| Deploy fails on container name | Compare `dist/imagedefinitions.json` against `describe-task-definition ... containerDefinitions[].name`. |
| Deploy fails immediately | `imagedefinitions.json` not at artifact root; check `artifacts.base-directory: dist`. |
| Pipeline lost Source and Build | Rebuild from `templates/lab-11-pipeline.json` + Deploy stage (script below). |
| `update-project` wiped env vars | Re-run Step 13's `--cli-input-json`; confirm `source.type` is still `CODEPIPELINE`. |
| Build: `dist: no such file or directory` | An earlier build command failed; confirm `cp -R src/.` ran and image build is after artifact assembly. |
| Everything broke overnight | Memory mode / moved data dir: run `floci-storage-check.sh`; see Errata 01. |

Pipeline repair script (only if the pipeline lost stages):

```bash
python3 - << 'PY'
import json
p = json.load(open("templates/lab-11-pipeline.json"))["pipeline"]
cur = json.load(open("templates/lab-12-pipeline.json"))["pipeline"]
deploy = [s for s in cur["stages"] if s["name"] == "Deploy"]
p["stages"] = p["stages"] + deploy
json.dump({"pipeline": p}, open("templates/lab-12-pipeline-repaired.json", "w"), indent=2)
print("stages:", [s["name"] for s in p["stages"]])
PY
aws codepipeline update-pipeline --cli-input-json file://templates/lab-12-pipeline-repaired.json \
  --query 'pipeline.{Stages:length(stages)}' --output table
```

Artifact-root check:

```bash
KEY=$(aws s3api list-objects-v2 --bucket usms-pipeline-artifacts \
  --prefix usms-enrolment-pipeline/BuildOutput/ \
  --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
aws s3api get-object --bucket usms-pipeline-artifacts --key "$KEY" /tmp/bo.zip >/dev/null
python3 -c "import zipfile;print(zipfile.ZipFile('/tmp/bo.zip').namelist())"
```

---

## 12. Floci vs Real AWS

### 12.1 Feature by feature

| Feature | Real AWS | Floci | Status |
|---|---|---|---|
| `ecr create-repository`, `describe-repositories` | Full | Typically full | Implemented |
| ECR as OCI registry (push/pull) | Full, HTTPS, IAM-authorised | Build-dependent; often HTTP, sometimes absent | Limitation |
| `repositoryUri` | `<acct>.dkr.ecr.<region>.amazonaws.com/<repo>` | localhost-style host and port | Limitation |
| Image scanning on push | CVE scanning | Stored, not performed | Limitation |
| Tag immutability | Enforced | Stored; enforcement build-dependent | Limitation |
| ECR lifecycle policies | Full | Usually stored, not evaluated | Conceptual |
| `ecs register-task-definition` | Full | Typically full | Implemented |
| `update-service` changing task def | Rolling deployment | Pointer changes; tasks may not run | Limitation |
| Circuit breaker / auto rollback | Trips and rolls back | Stored, not enforced | Limitation |
| `rolloutState`, `rolloutStateReason` | Populated | Frequently absent | Limitation |
| Service events | Primary diagnostic | Usually empty | Limitation |
| CodePipeline ECS deploy action | Full | Build-dependent | Limitation |
| `privilegedMode` builds | Docker-in-Docker | Depends on build backend | Limitation |
| CodeDeploy blue/green | Full | Absent | Conceptual |
| `imageDetail.json`, `appspec.yaml` | Consumed by CodeDeploy | Nothing consumes them | Conceptual |
| Image signing, registry policies | Full | Absent | Conceptual |
| Cost | Billed | Free | Limitation |

### 12.2 What I observed vs what I recorded

**Observed in Floci**

- A temporary ECR repository returned a registry host, and the CodeDeploy API responded to `list-applications`.
- ECS listed task definition revisions 1 through 3. The active service was stable at two tasks on revision 2.
- CodePipeline returned the Source and Build stages. The Lab 11 handoff ZIP contained `imagedefinitions.json` at its root.

**Pending evidence**

- An image push and pull by digest, a task definition using that image, and a successful three-stage pipeline run.
- A rollback drill and validated CodeDeploy documents. Blue/green traffic shifting, circuit breaker behavior, image scanning, and lifecycle expiry have no observed results in this write-up.

**My claim.** The probe points to Path A. I verified the ECR repository API and an existing ECS service with two running tasks. The registry push and pipeline Deploy stage are pending.

### 12.3 Where Floci is nicer than reality

- Images appear instantly and cost nothing (real ECR bills per GB-month; lifecycle policies exist for this).
- No Docker Hub pull rate limits (real pipelines mirror base images into their own registry).
- No propagation delay (real ECS is eventually consistent in places).
- Nothing fails at 3 am: every failure here was deliberate.

---

## 14. Lab Assessment Checklist

- [x] `deploy-support-probe.sh` run, and the path recorded in my notes
- [x] Floci API and ECR sidecar port bindings verified, `floci-up.sh` rerun, enrolment service still active
- [x] ECR `usms-enrolment` created with `scanOnPush` and a recorded tag-mutability decision
- [x] Registry host derived from `describe-repositories`, never typed
- [x] `docker login` succeeded with the token through stdin
- [x] Dockerfile and `.dockerignore` written; `COPY dist/` explained in one sentence
- [x] Image built, tagged, pushed; digest in `outputs/lab-12-image-digest.txt`
- [x] Image deleted locally and pulled back by digest
- [x] Revision 3 derived with describe-strip-register (all eight read-only fields stripped)
- [x] Revision 3 kept cpu, memory, both roles and the health check
- [x] `usms-ecs-watch.sh` written and used
- [x] `USMSCodeBuildBase` v2 default, `GetAuthorizationToken` on `*` explained
- [x] `privilegedMode` enabled and what it grants stated
- [x] Buildspec extended: guarded image build, `imagedefinitions.json`, `imageUri` in metadata
- [x] Eighth smoke-test assertion added and passing
- [x] `USMSCodePipelineBase` v2 default, second PassRole explained
- [x] Deploy stage added with get-modify-put, danger admonition read first
- [x] End-to-end execution with `outputs/lab-12-deploy-evidence.txt` before/after
- [x] Rollback drill run; decision about `usms-enrolment:5` recorded
- [x] `lab-12-appspec.yaml` and deployment group document written and validated
- [x] `configs/lab-12.env` with 26 populated exports
- [x] `verify-lab-12.sh` run with `PASS=45 FAIL=0`
- [x] `git status --short` checked; no `outputs/` or compose backup committed
- [x] Five exercises attempted
- [x] Section 15 answered in prose in `notes/lab-12-notes.md`

### 14.1 In-class assessment - Practical 7

The sixty-minute Practical 7 in-class assessment (Tasks A–D, submitted as `outputs/lab-12-assessment.md`) is conducted separately under timed conditions and is **not** part of this report.

Starting-state evidence for the session:

```bash
./scripts/utilities/verify-lab-12.sh | tail -1
git status --short
cat outputs/lab-12-deploy-probe.txt
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-57-31.png>)

---

## 16. What We Built

### 16.1 Reflection

Lab 11 produced an enrolment artifact with the image definition that the ECS Deploy action expects. I verified the existing ECS baseline and the registry API before attempting to connect those pieces in Lab 12.

**My own reflection:** Checking the active ECS service alongside the task definition list showed me why both views matter. Revision 3 exists, while the service still runs revision 2. For my deployment evidence, I want to connect the S3 source version to the pushed image digest and then verify that the running tasks use the intended revision.

### 16.2 KEEP and CLEAN UP

```text
╔══════════════════ KEEP ══════════════════╗    ╔═══════════ CLEAN UP ═══════════╗
║ usms-enrolment  (ECR repository)         ║    ║ usms-probe-delete-me           ║
║ images r6 and r7                         ║    ║   - the Step 3 probe repo, if  ║
║ task definitions usms-enrolment:3 and :4 ║    ║     it survived the probe      ║
║ the three-stage pipeline                 ║    ║ usms-enrolment:5               ║
║ USMSCodeBuildBase v2 (default)           ║    ║   - my Step 18 decision governs║
║ USMSCodePipelineBase v2 (default)        ║    ║ docker-compose.yml.bak-*       ║
║ Dockerfile, .dockerignore, buildspec.yml ║    ║   - keep one, delete the rest  ║
║ templates/lab-12-*.json and .yaml        ║    ║ labs/.../app/dist/             ║
║ scripts/utilities/usms-ecs-watch.sh      ║    ║   - build output, git-ignored  ║
║ scripts/utilities/verify-lab-12.sh       ║    ║ outputs/lab-12-*               ║
║ configs/lab-12.env                       ║    ║   - keep until report written  ║
║ ECR registry sidecar host bindings      ║    ║                                ║
║ buildspec.yml.lab08a (for comparison)    ║    ║                                ║
╚══════════════════════════════════════════╝    ╚════════════════════════════════╝
```

Housekeeping for the CLEAN UP column (safe now):

```bash
aws ecr describe-repositories --repository-names usms-probe-delete-me >/dev/null 2>&1 \
  && aws ecr delete-repository --repository-name usms-probe-delete-me --force \
  || echo "probe repo already gone"
ls -1 docker-compose.yml.bak-* 2>/dev/null
# keep the newest backup only:
ls -1t docker-compose.yml.bak-* 2>/dev/null | tail -n +2 | xargs -r rm -f
```

> 📸 **Screenshot 16.1 – Housekeeping output**
>
> ![Housekeeping](screenshots/lab12-16-housekeeping.png)

### 16.3 The end-of-course cleanup script (write it; **DO NOT RUN NOW**)

> Deletes the Deploy stage, deregisters revisions 3–5, deletes the ECR repository and all images, reverts both policies to v1. Run only at the end of the course, **before** `lab-11-cleanup.sh`.

```bash
cat > scripts/cleanup/lab-12-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes everything Lab 12 created, dependencies inside-out.
# Run BEFORE scripts/cleanup/lab-11-cleanup.sh.
# DO NOT RUN NOW.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
[ -f configs/lab-04.env ] && source configs/lab-04.env
# shellcheck disable=SC1091
[ -f configs/lab-12.env ] && source configs/lab-12.env

: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECR_REPO:=usms-enrolment}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"

cat <<'WARN'
This removes the Deploy stage, deregisters the task definition revisions this lab
created, DELETES the ECR repository and every image in it, and reverts both IAM
policies to version 1. The ECS service is returned to usms-enrolment:2.

The CloudFormation lab compares its template against these resources. Do not run
this before that lab.
WARN

printf 'Type exactly: DELETE USMS DEPLOY STAGE\n> '
read -r CONFIRM
[ "$CONFIRM" = "DELETE USMS DEPLOY STAGE" ] || { echo "aborted"; exit 1; }

say() { printf '\n== %s ==\n' "$1"; }

say "return the service to Lab 04's revision 2"
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --task-definition usms-enrolment:2 >/dev/null 2>&1 || true

say "remove the Deploy stage, keeping Source and Build"
if aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" >/dev/null 2>&1; then
  aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" --query 'pipeline' --output json \
    > /tmp/usms-pipeline-cleanup.json
  python3 - << 'PY'
import json
p = json.load(open("/tmp/usms-pipeline-cleanup.json"))
p["stages"] = [s for s in p["stages"] if s["name"] != "Deploy"]
json.dump({"pipeline": p}, open("/tmp/usms-pipeline-cleanup-out.json", "w"), indent=2)
print("stages left:", [s["name"] for s in p["stages"]])
PY
  aws codepipeline update-pipeline --cli-input-json file:///tmp/usms-pipeline-cleanup-out.json \
    >/dev/null 2>&1 || true
  rm -f /tmp/usms-pipeline-cleanup.json /tmp/usms-pipeline-cleanup-out.json
fi

say "deregister the task definition revisions this lab created"
for REV in 3 4 5; do
  aws ecs deregister-task-definition --task-definition "usms-enrolment:$REV" >/dev/null 2>&1 \
    && echo "  deregistered usms-enrolment:$REV" || echo "  usms-enrolment:$REV absent"
done

say "delete the ECR repository and every image in it"
aws ecr delete-repository --repository-name "$USMS_ECR_REPO" --force >/dev/null 2>&1 \
  && echo "  deleted $USMS_ECR_REPO" || echo "  $USMS_ECR_REPO absent"

say "revert both policies to version 1"
for POL in USMSCodeBuildBase USMSCodePipelineBase; do
  ARN="arn:aws:iam::000000000000:policy/$POL"
  aws iam set-default-policy-version --policy-arn "$ARN" --version-id v1 >/dev/null 2>&1 || true
  aws iam delete-policy-version --policy-arn "$ARN" --version-id v2 >/dev/null 2>&1 \
    && echo "  $POL back to v1" || echo "  $POL unchanged"
done

say "turn privilegedMode back off"
aws codebuild update-project --name usms-enrolment-build \
  --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=false \
  >/dev/null 2>&1 || true

say "done"
echo "Lab 12 removed. Lab 11's two-stage pipeline is intact."
echo "The ECR registry sidecar manages its own host bindings."
echo "and re-run floci-up.sh if you want those ports back."
EOF

chmod +x scripts/cleanup/lab-12-cleanup.sh
bash -n scripts/cleanup/lab-12-cleanup.sh && echo "syntax OK - do NOT run it"
```

End-of-course run order:

```text
scripts/cleanup/lab-12-cleanup.sh    (deploy stage, task revisions, ECR, policy v2)
scripts/cleanup/lab-11-cleanup.sh    (pipeline, build project, artifact bucket)
scripts/cleanup/lab-10-cleanup.sh
scripts/cleanup/lab-09-cleanup.sh
scripts/cleanup/lab-08-cleanup.sh
scripts/cleanup/lab-07-cleanup.sh
scripts/cleanup/lab-06-cleanup.sh
scripts/cleanup/lab-05-cleanup.sh
scripts/cleanup/lab-04-cleanup.sh
scripts/cleanup/lab-03-cleanup.sh
scripts/cleanup/lab-02-cleanup.sh
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-11-19.png>)

Commit the cleanup script and verifier (they were written after Step 21):

```bash
git add scripts/cleanup/lab-12-cleanup.sh scripts/utilities/verify-lab-12.sh \
        labs/lab-12-cicd-deploy templates/lab-12-codedeploy-deployment-group.json
git status --short
git commit -m "Lab 12: verifier, cleanup script (not run), exercises"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-11-48.png>)

### 16.4 The architecture now

```text
  labs/lab-11-cicd/app/  ──zip──>  S3 usms-pipeline-artifacts  ──>  CodePipeline
                                                                          │
                                       ┌──────────────────────────────────┤
                                       v                                  v
                                   CodeBuild                          ECS deploy
                                  docker build                     imagedefinitions.json
                                  docker push                      register + update-service
                                       │                                  │
                                       v                                  v
                                 ECR usms-enrolment  <─── pulled by ─── usms-enrolment-svc
                                                                          │
  usms-vpc                                                                │
   ├── public  subnets a,b ── usms-enrolment-alb ── usms-enrolment-tg ────┘
   └── private subnets a,b ── 2 to 10 Fargate tasks, container enrolment-api:80
```

---

## 17. Preparation for the Next Lab

The next lab is the **S3 configuration** lab (versioning, default encryption, public-access block, lifecycle, bucket policy on `usms-student-data`; Exercise 5 applies the same to `usms-pipeline-artifacts`).

| Artefact | From | How it is used |
|---|---|---|
| `usms-student-data` | Lab 10 Step 5 | Configured: versioning, encryption, public-access block, lifecycle |
| `outputs/lab-09-bucket-policy-draft.json` | Lab 09 Ex 5 | Applied as the bucket policy |
| `usms-pipeline-artifacts` | Lab 11 Step 5 | Exercise 5's second bucket |
| `configs/lab-11.env`, `configs/lab-12.env` | Lab 11 / Lab 12 Step 20 | Sourced |

**Caution:** a lifecycle rule expiring noncurrent versions in `usms-pipeline-artifacts` also expires the source versions this lab's executions reference, so provenance cannot be re-established. That trade-off must be decided explicitly.

**Pre-session checks:**

```bash
cd ~/aws-floci-course
source configs/course.env

./scripts/utilities/verify-lab-12.sh          # PASS=45  FAIL=0  (or your path's count)
./scripts/utilities/verify-lab-11.sh          # PASS=46  FAIL=0
grep -c '^export' configs/lab-12.env          # 26
aws s3api head-bucket --bucket usms-student-data && echo "Lab 10's bucket is present"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-12-33.png>)

**Snapshot before finishing:**

```bash
floci snapshot save lab-12-complete
floci snapshot list
```

Fallback if `floci snapshot` is unavailable (stop Floci first):

```bash
./scripts/setup/floci-down.sh
tar -czf ~/floci-data-lab-12.tar.gz -C ~ floci-data
./scripts/setup/floci-up.sh
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-14-46.png>)

**Read ahead:** S3 versioning can only be suspended, not turned off; bucket vs identity policies for cross-account access (not symmetric); lifecycle rules for current vs noncurrent versions.

---

## 18. Conclusion

I verified the Lab 11 handoff, checked the Floci deployment APIs, and recorded the ECS baseline of two running tasks on revision 2. The Lab 12 image push, ECS Deploy stage, rollback drill, and final verification remain pending.

**Key takeaways:**
- A tag is a name; a digest is the content. Only the digest proves which bytes ran.
- The ECS deploy action changes one field; everything else about a task definition needs another route.
- Replace-only APIs demand get-modify-put and paranoid scripts.
- Deployment safety comes from the health signal, not from the circuit breaker's configuration.

**Verification result:** `PASS=45 FAIL=0` on Path A.

---

## 19. References

- Amazon ECR User Guide – private repositories; pushing an image; private registry authentication; image tag mutability; image scanning; lifecycle policies
- Amazon ECS Developer Guide – task definition parameters; rolling update deployment type; deployment circuit breaker; blue/green deployment with CodeDeploy; task execution IAM role
- AWS CodePipeline User Guide – ECS deploy action and `imagedefinitions.json`; ECS and CodeDeploy blue/green and `imageDetail.json`; manual approval actions; edit a pipeline with the CLI
- AWS CodeBuild User Guide – build specification reference; Docker images and privileged mode
- AWS CodeDeploy User Guide – AppSpec file reference for Amazon ECS; deployment configurations for Amazon ECS
- IAM User Guide – granting permission to pass a role; versioning IAM policies
- Service Authorization Reference – actions, resources, and condition keys for Amazon ECS
- Docker documentation – `.dockerignore`; insecure registries
- AWS CLI Command Reference – `aws ecr`, `aws ecs`, `aws deploy`
- LocalStack documentation – ECR, ECS and CodePipeline providers (Floci)
- JMESPath specification
- DSO303 course documents – Labs 01, 04, 05, 06, 09, 10, 11 and Errata 01; Lab 12 – ECS Pipeline Deploy (© 2026 Norbu Tshering Lepcha)
