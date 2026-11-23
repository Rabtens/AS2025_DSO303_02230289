# DSO303 - Practical 7 (Lab 11): Building a CI/CD Pipeline with AWS CodePipeline and CodeBuild

---

## Table of Contents

1. [Aim](#1-aim)
2. [Objectives](#2-objectives)
3. [Tools and Environment](#3-tools-and-environment)
4. [Theory / Background](#4-theory--background)
5. [Architecture](#5-architecture)
6. [Directory Structure](#6-directory-structure)
7. [Procedure (Steps 1–21)](#7-procedure)
8. [Verification](#8-verification)
9. [Checkpoints Summary](#9-checkpoints-summary)
10. [Floci vs Real AWS — Observed vs Recorded](#10-floci-vs-real-aws--observed-vs-recorded)
11. [Independent Lab Exercises (1–5)](#11-independent-lab-exercises)
12. [Lab Assessment Checklist](#12-lab-assessment-checklist)
13. [Review Questions and Answers](#13-review-questions-and-answers)
14. [Clean-up Script, Snapshot and Preparation for Lab 12](#14-clean-up-script-snapshot-and-preparation-for-lab-12)
15. [Reflection and Conclusion](#15-reflection-and-conclusion)
16. [References](#16-references)

---

## 1. Aim

To build the first two stages of a CI/CD pipeline for the USMS enrolment service - a **Source** stage that fetches a versioned source archive from Amazon S3 and a **Build** stage that runs the build in AWS CodeBuild using a `buildspec.yml` stored inside the source tree - and to prove, using the contents of the build artifact, that a change to the source travelled through the pipeline.

## 2. Objectives

By the end of this practical I will be able to:

1. Explain a CI/CD pipeline in terms of stages, actions and the artifacts passed between them, and where each artifact physically lives.
2. Create and configure an S3 artifact store and explain why CodePipeline **requires** versioning on an S3 source bucket.
3. Write a `buildspec.yml` from scratch and explain `version`, `env`, `phases`, `artifacts`, `cache` and `reports`.
4. Create a CodeBuild service role with a policy scoped to exactly the log group and bucket the build needs.
5. Create a CodeBuild project, start a build and read `batch-get-builds` to find which phase failed and why.
6. Create a two-stage CodePipeline from a JSON document and read `get-pipeline-state`.
7. Explain `iam:PassRole` and identify which principal passes which role to which service.
8. Diagnose a failed execution: **stage → build → phase → command**.
9. Distinguish what my build actually *proved* from what it merely *reported*.

## 3. Tools and Environment

| Tool | Purpose |
|---|---|
| Floci (AWS emulator) under Docker Compose, `FLOCI_STORAGE_MODE=hybrid` | Local AWS endpoint at `http://localhost:4566`, account `000000000000` |
| AWS CLI v2 with the `floci` profile | All AWS API calls |
| Docker | CodeBuild on Floci runs builds in containers |
| `python3` | JSON validation, YAML parsing, JSON surgery |
| `zip` / `unzip` | Packaging the source archive |
| `git` | Version control of the course repository |
| Region | `us-east-1` |

**Prerequisites confirmed:** Labs 01, 02, 03, 04, 05 and 06 complete. Labs 07–08 and 09 optional.

> **Never run `aws login`.** If `NoCredentials` appears, the fix is always `source configs/course.env` (or a missing `floci` profile), never a sign-in to real AWS.

### 3.1 Baseline verification (before creating anything)

```bash
command -v zip unzip
# If missing on Debian/Ubuntu:
# sudo apt-get install -y zip unzip

# Run from the repository root.
source configs/course.env

./scripts/utilities/floci-storage-check.sh      # PASS=16  FAIL=0
./scripts/utilities/verify-lab-04.sh            # PASS=48  FAIL=1  (or 49/0 after Lab 05 Exercise 2)
./scripts/utilities/verify-lab-05.sh            # PASS=49  FAIL=0
./scripts/utilities/verify-lab-10.sh            # PASS=51  FAIL=0
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-10-09.png>)

---

## 4. Theory / Background

### 4.1 Why a pipeline?
Until this lab, every resource was created by typing commands. That works but is **not reproducible** - nobody can say with certainty which commands, in which order, from which version of which file, produced the running system. A pipeline is a machine that watches where source lives and, when the source changes, runs a **fixed, written-down sequence of stages** (fetch → build → test → deploy). It runs the same way every time and leaves a record.

### 4.2 What is genuinely new in this lab

| New thing | Why it matters |
|---|---|
| `buildspec.yml` | Build instructions live in the repository, versioned with the code, not in a console setting |
| CodeBuild service role | The build container is a principal; what it can reach is a policy decision |
| The artifact store | Every stage hands the next a zip file in S3 - this makes CodePipeline stop being magic |
| S3 source versioning | CodePipeline refuses an unversioned S3 source bucket |
| Pipeline JSON | A pipeline is a document: `get-pipeline` gives it, `update-pipeline` takes it back |
| `iam:PassRole` | The pipeline does not build; it asks CodeBuild to build *as a role* - a permission of its own |

### 4.3 The five buildspec keys used

| Key | Purpose |
|---|---|
| `version` | Buildspec format version - use `0.2` (0.1 ran every command in its own shell and is deprecated) |
| `env` | Variables available to every phase |
| `phases` | `install` → `pre_build` → `build` → `post_build`, in fixed order |
| `artifacts` | Which files are kept and handed to the next stage |
| `cache` | Directories preserved between builds (empty here) |

Conventions: **install** = tools only; **pre_build** = checks that must pass before building is worth it; **build** = produce the thing; **post_build** = test it and write what the next stage needs. `finally` can be attached to any phase and runs whether the phase succeeded or failed.

### 4.4 Why the S3 source (and not CodeCommit)
AWS CodeCommit stopped accepting new customers in July 2024. S3 sources remain fully supported, are used by real pipelines for release archives, and make the artifact mechanism visible instead of hiding it behind `git clone`.

---

## 5. Architecture

```
                        THE PIPELINE, AND WHERE EVERY BYTE PHYSICALLY LIVES

  you                     S3: usms-pipeline-artifacts
  ┌──────────────┐        ┌────────────────────────────────────────────────┐
  │ labs/        │  zip   │  source/usms-enrolment-src.zip   (versioned)   │
  │  lab-11-     │ ─────> │      ^                                         │
  │  cicd/app/   │  put   │      │ versionId changes on every upload       │
  └──────────────┘        │      │                                         │
                          │  usms-enrolment-pipeline/SourceOutput/xxxxx.zip│ <─┐
                          │  usms-enrolment-pipeline/BuildOutput/yyyyy.zip │ <┐│
                          └────────────────────────────────────────────────┘  ││
  CodePipeline: usms-enrolment-pipeline                                       ││
  ┌────────────────────────────────────────────────────────────────────────┐  ││
  │  STAGE 1: Source                        STAGE 2: Build                 │  ││
  │  ┌──────────────────────┐               ┌──────────────────────────┐   │  ││
  │  │ provider: S3         │  SourceOutput │ provider: CodeBuild       │  │  ││
  │  │ reads the zip        │ ────────────> │ project: usms-enrolment-  │  │  ││
  │  │ writes SourceOutput  │               │ build                     │──┼──┘│
  │  └──────────────────────┘               └──────────────────────────┘   │   │
  │        runs as usms-codepipeline-role                                  │   │
  └────────────────────────────────────────────────────────────────────────┘   │
                                    │ iam:PassRole                             │
                                    v                                          │
  CodeBuild: usms-enrolment-build  (image docker.io/library/python:3.12-slim-bookworm)          │
  ┌────────────────────────────────────────────────────────────────────────┐   │
  │  unpack SourceOutput -> read buildspec.yml -> install -> pre_build ->  │   │
  │  build -> post_build -> collect artifacts -> zip -> BuildOutput ───────┼───┘
  │        runs as usms-codebuild-role                                     │
  │        writes to log group /aws/codebuild/usms-enrolment-build         │
  └────────────────────────────────────────────────────────────────────────┘
  Lab 12 adds STAGE 3: Deploy -> ECS service usms-enrolment-svc on usms-ecs-cluster
```

Key points:
- **Every arrow between stages is a zip file in S3.** Nothing streams between actions.
- **The pipeline does not build.** It calls `codebuild:StartBuild`; the build runs as `usms-codebuild-role`. Two roles, two blast radii.
- **The buildspec is inside the source zip.** Change the build by changing a file and uploading a new version.

---

## 6. Directory Structure

```
aws-floci-course/
├── configs/lab-11.env                          NEW  - this lab's outputs
├── labs/lab-11-cicd/                           NEW
│   ├── README.md
│   ├── exercises.md
│   └── app/                                    NEW  - enrolment service source tree
│       ├── buildspec.yml
│       ├── VERSION
│       ├── src/index.html
│       ├── src/healthz.html
│       ├── config/service.json
│       └── tests/smoke.sh
├── policies/
│   ├── trust-codebuild.json                    NEW
│   ├── trust-codepipeline.json                 NEW
│   ├── usms-codebuild-policy.json              NEW
│   └── usms-codepipeline-policy.json           NEW
├── templates/
│   ├── lab-11-codebuild-project.json           NEW
│   └── lab-11-pipeline.json                    NEW
├── scripts/utilities/
│   ├── cicd-support-probe.sh                   NEW
│   ├── usms-pack-source.sh                     NEW
│   ├── usms-buildspec-run.sh                   NEW
│   └── verify-lab-11.sh                        NEW
├── scripts/cleanup/lab-11-cleanup.sh           NEW  - DO NOT RUN NOW
├── outputs/                                    (git-ignored)
│   ├── lab-11-support-probe.txt
│   ├── lab-11-build-<id>.json
│   └── lab-11-pipeline-state.json
└── notes/lab-11-notes.md                       NEW  - answers to Section 15
```

---

## 7. Procedure

### Step 1 - Start Floci and confirm where you are

**Purpose:** Everything lives inside the emulator. If it is not in hybrid storage mode, tonight's pipeline is gone tomorrow - while every command still reports success.

**Run from:** `aws-floci-course/`

```bash
./scripts/setup/floci-up.sh
./scripts/utilities/floci-storage-check.sh
./scripts/utilities/whoami.sh
```

**What it does:** `floci-up.sh` starts (or adopts) the Compose project; `floci-storage-check.sh` runs sixteen read-only checks; `whoami.sh` prints identity and endpoint and exits 1 if the account is not `000000000000`.

**Expected result:**
```
PASS=16  FAIL=0

  Account : 000000000000
  Arn     : arn:aws:iam::000000000000:root
  Endpoint: http://localhost:4566
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-17-48.png>)

**Observation:** I confirmed that Floci was running under Docker Compose in hybrid mode and storing its state in a host directory. The storage check reported no failures, and whoami.sh confirmed that my AWS CLI was using the local Floci account 000000000000 at http://localhost:4566.

---

### Step 2 - Source every earlier lab's environment

**Purpose:** Shell variables die with the terminal; every lab writes its IDs to `configs/lab-NN.env`, and every lab reads them back.

```bash
source configs/course.env

for f in configs/lab-01.env configs/lab-02.env configs/lab-03.env \
         configs/lab-04.env configs/lab-05.env configs/lab-06.env \
         configs/lab-09.env configs/lab-07.env configs/lab-08.env \
         configs/lab-10.env; do
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    source "$f"
    printf '  sourced  %s\n' "$f"
  else
    printf '  absent   %s\n' "$f"
  fi
done

./scripts/utilities/whoami.sh
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-22-05.png>)

**Why an explicit list, not a glob:** a glob could silently source an editor backup or half-written file; the explicit list prints what it did.

**Verify:**
```bash
printf 'cluster   : %s\nservice   : %s\ncontainer : %s\ntarget grp: %s\nexec role : %s\n' \
  "${USMS_ECS_CLUSTER:-MISSING}" \
  "${USMS_ENROLMENT_SERVICE:-MISSING}" \
  "${USMS_ENROLMENT_CONTAINER:-MISSING}" \
  "${USMS_TG_ARN:-MISSING}" \
  "${USMS_ECS_EXEC_ROLE_ARN:-MISSING}"
```

**Look for:** no line says `MISSING`; `container` must read `enrolment-api`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-22-33.png>)

---

### Step 3 - Probe CI/CD support and choose your path

**Purpose:** Find out in ninety seconds whether this Floci build supports CodeBuild/CodePipeline, rather than in Step 19.

An emulator can (1) implement and do the work, (2) store the object but never do the work, or (3) not implement it at all. The probe checks that created objects can be read back and labels the path.

```bash
mkdir -p scripts/utilities outputs

cat > scripts/utilities/cicd-support-probe.sh << 'EOF'
#!/usr/bin/env bash
# Determine which CI/CD path this Floci build supports.
# Read-only except for one throwaway CodeBuild project, which it deletes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

PROBE_PROJECT="usms-probe-delete-me"
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  --   %s\n' "$1"; }

CB_LIST=no ; CB_CREATE=no ; CP_LIST=no ; ECS_ACTION=unknown

echo "== CodeBuild =="
if aws codebuild list-projects >/dev/null 2>&1; then
  CB_LIST=yes; ok "codebuild list-projects answers"
else
  bad "codebuild list-projects does not answer"
fi

if [ "$CB_LIST" = yes ]; then
  if aws codebuild create-project \
        --name "$PROBE_PROJECT" \
        --source type=NO_SOURCE,buildspec='version: 0.2' \
        --artifacts type=NO_ARTIFACTS \
        --environment type=LINUX_CONTAINER,image=docker.io/library/python:3.12-slim-bookworm,computeType=BUILD_GENERAL1_SMALL \
        --service-role "arn:aws:iam::000000000000:role/does-not-matter-for-a-probe" \
        >/dev/null 2>&1; then
    CB_CREATE=yes; ok "codebuild create-project accepted"
    aws codebuild delete-project --name "$PROBE_PROJECT" >/dev/null 2>&1 \
      && ok "probe project deleted" || bad "probe project NOT deleted - remove $PROBE_PROJECT by hand"
  else
    bad "codebuild create-project rejected"
  fi
fi

echo "== CodePipeline =="
if aws codepipeline list-pipelines >/dev/null 2>&1; then
  CP_LIST=yes; ok "codepipeline list-pipelines answers"
else
  bad "codepipeline list-pipelines does not answer"
fi

echo "== Deploy targets (informational, used by Lab 12) =="
aws ecr describe-repositories >/dev/null 2>&1 \
  && ok "ecr describe-repositories answers" || bad "ecr describe-repositories does not answer"
aws deploy list-applications >/dev/null 2>&1 \
  && ok "codedeploy list-applications answers" || bad "codedeploy list-applications does not answer"

echo
if [ "$CB_CREATE" = yes ] && [ "$CP_LIST" = yes ]; then
  PATHNAME="A"
  echo "PATH A - CodeBuild and CodePipeline both present."
  echo "         Follow every step as written."
elif [ "$CB_CREATE" = yes ] || [ "$CP_LIST" = yes ]; then
  PATHNAME="B"
  echo "PATH B - one of the two services is present, the other is not."
  echo "         Follow every step. Where the missing service is called, record the"
  echo "         document you wrote and run Step 14's local runner instead."
else
  PATHNAME="C"
  echo "PATH C - neither service is present on this build."
  echo "         Every document in this lab is still written and validated; the"
  echo "         execution happens in Step 14's local runner. Section 12 tells you"
  echo "         exactly what to claim and what not to claim."
fi
printf 'USMS_CICD_SUPPORT_PATH=%s\n' "$PATHNAME" > outputs/lab-11-support-probe.txt
echo "recorded in outputs/lab-11-support-probe.txt"
EOF

chmod +x scripts/utilities/cicd-support-probe.sh
bash -n scripts/utilities/cicd-support-probe.sh && echo "syntax OK"
./scripts/utilities/cicd-support-probe.sh
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-23-54.png>)

**Record the path as the first line of the notes file (required by the lab):**
```bash
mkdir -p notes
printf 'Lab 11 CI/CD support path: %s\n\n' \
  "$(sed -n 's/^USMS_CICD_SUPPORT_PATH=//p' outputs/lab-11-support-probe.txt)" > notes/lab-11-notes.md
cat notes/lab-11-notes.md
```

**Expected result (example):**
```
== CodeBuild ==
  ok   codebuild list-projects answers
  ok   codebuild create-project accepted
  ok   probe project deleted
== CodePipeline ==
  ok   codepipeline list-pipelines answers
== Deploy targets (informational, used by Lab 12) ==
  ok   ecr describe-repositories answers
  --   codedeploy list-applications does not answer

PATH A - CodeBuild and CodePipeline both present.
         Follow every step as written.
recorded in outputs/lab-11-support-probe.txt
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-24-15.png>)

**My path:** `PATH A` **Checkpoint 1** - `cicd-support-probe.sh` is executable, and `outputs/lab-11-support-probe.txt` contains `USMS_CICD_SUPPORT_PATH=A`.

---

### Step 4 - Create this lab's directories

```bash
mkdir -p labs/lab-11-cicd/app/src \
         labs/lab-11-cicd/app/config \
         labs/lab-11-cicd/app/tests \
         policies templates scripts/utilities scripts/cleanup outputs notes

ls -d labs/lab-11-cicd/app/*
```

**Expected result:**
```
labs/lab-11-cicd/app/config
labs/lab-11-cicd/app/src
labs/lab-11-cicd/app/tests
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-33-05.png>)

---

### Step 5 - Create the pipeline artifact bucket

**Concept:** CodePipeline does not "connect" stages. Stage 1 writes a zip to S3; stage 2 downloads it. Consequences: the bucket must be in the pipeline's region; anything in it is readable by anyone with `s3:GetObject` on it; unfamiliar object keys in errors are artifact keys (`<pipeline-name>/<OutputArtifactName>/<random>.zip`).

```bash
PIPELINE_BUCKET="usms-pipeline-artifacts"

aws s3api create-bucket --bucket "$PIPELINE_BUCKET"

aws s3api put-bucket-tagging \
  --bucket "$PIPELINE_BUCKET" \
  --tagging 'TagSet=[{Key=Project,Value=USMS},{Key=Tier,Value=pipeline},{Key=Lab,Value=11}]'

aws s3api put-bucket-versioning \
  --bucket "$PIPELINE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket "$PIPELINE_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**Notes:** In `us-east-1`, `create-bucket` takes no `--create-bucket-configuration` (every other region needs `LocationConstraint`). Public access block is not required by CodePipeline but an artifact bucket is the worst bucket to leave public.

**Expected result:**
```json
{
    "Location": "/usms-pipeline-artifacts"
}
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-34-22.png>)

**Verify:**
```bash
aws s3api get-bucket-versioning --bucket "$PIPELINE_BUCKET" --output table
aws s3api get-bucket-tagging    --bucket "$PIPELINE_BUCKET" \
  --query 'TagSet[].[Key,Value]' --output table
```

**Look for:** `Status` = `Enabled` (an empty response means *never enabled*).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-34-51.png>)

---

### Step 6 - Prove versioning is on

**Concept - create, perturb, read back:** put an object, put a different object at the same key, list versions. Two rows = versioning is real.

```bash
printf 'first\n'  > /tmp/usms-version-probe.txt
aws s3api put-object --bucket "$PIPELINE_BUCKET" \
  --key probe/versioning.txt --body /tmp/usms-version-probe.txt >/dev/null

printf 'second\n' > /tmp/usms-version-probe.txt
aws s3api put-object --bucket "$PIPELINE_BUCKET" \
  --key probe/versioning.txt --body /tmp/usms-version-probe.txt >/dev/null

aws s3api list-object-versions \
  --bucket "$PIPELINE_BUCKET" \
  --prefix probe/versioning.txt \
  --query 'Versions[].{Version:VersionId,Latest:IsLatest,Size:Size}' \
  --output table
```

**Expected result:**
```
-------------------------------------------
|           ListObjectVersions            |
+---------+----------+--------------------+
| Latest  |  Size    |      Version       |
+---------+----------+--------------------+
|  True   |  7       |  3vHc...           |
|  False  |  6       |  9kQa...           |
+---------+----------+--------------------+
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-37-52.png>)

**Clean up the probe object.**

> **Read before running any delete command** - *Deletes:* the two versions of `probe/versioning.txt` only. *Depends on it:* nothing. *Reversible:* No (version deletes are permanent). *Effect on later labs:* none.

```bash
aws s3api list-object-versions --bucket "$PIPELINE_BUCKET" --prefix probe/ \
  --query 'Versions[].[Key,VersionId]' --output text |
while read -r key vid; do
  [ -n "$key" ] && aws s3api delete-object --bucket "$PIPELINE_BUCKET" \
    --key "$key" --version-id "$vid" >/dev/null
done

aws s3api list-object-versions --bucket "$PIPELINE_BUCKET" --prefix probe/ \
  --query 'length(Versions || `[]`)' --output text
```

**Look for:** final number `0`. `Versions || [] ` supplies a default because `length(null)` is an error.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-38-13.png>)

**Checkpoint 2** - versioning Enabled (proved), public access blocked, tags `Project=USMS, Tier=pipeline, Lab=11`.

---

### Step 7 - Write the enrolment service source tree

**Part 1 - the application**

Run this block from the repository root. It leaves the shell in the app directory for Parts 2 and 3.

```bash
source configs/course.env && cd "$COURSE_ROOT/labs/lab-11-cicd/app" && {

printf 'r3\n' > VERSION

cat > src/index.html << 'EOF'
<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><title>USMS - Enrolment</title></head>
  <body>
    <h1>USMS Enrolment Service</h1>
    <p>University Student Management System</p>
    <p id="release">release: __RELEASE__</p>
    <p id="built">built: __BUILT_AT__</p>
  </body>
</html>
EOF

cat > src/healthz.html << 'EOF'
ok
EOF
}
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-42-20.png>)

`__RELEASE__` and `__BUILT_AT__` are placeholders the build replaces - proof that a build actually ran.

**Part 2 - the configuration the build validates**
```bash
cat > config/service.json << 'EOF'
{
  "service": "enrolment",
  "project": "USMS",
  "container": "enrolment-api",
  "port": 80,
  "healthPath": "/healthz.html",
  "cluster": "usms-ecs-cluster",
  "ecsService": "usms-enrolment-svc"
}
EOF

python3 -m json.tool config/service.json > /dev/null && echo "service.json is valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-43-08.png>)

**Part 3 - the test**
```bash
cat > tests/smoke.sh << 'EOF'
#!/usr/bin/env bash
# Smoke tests for the USMS enrolment service artifact.
# Runs inside the build container, against the built output in ./dist.
set -uo pipefail

FAIL=0
t() {
  if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

echo "== smoke tests =="
t "dist/index.html exists"              "test -f dist/index.html"
t "dist/healthz.html exists"            "test -f dist/healthz.html"
t "release placeholder was replaced"    "! grep -q '__RELEASE__' dist/index.html"
t "build-time placeholder was replaced" "! grep -q '__BUILT_AT__' dist/index.html"
t "health endpoint says ok"             "grep -q '^ok$' dist/healthz.html"
t "build metadata is valid JSON"        "python3 -m json.tool dist/build-metadata.json"
t "container name matches the task def" "grep -q '\"container\": \"enrolment-api\"' config/service.json"

echo "smoke tests failed: $FAIL"
[ "$FAIL" -eq 0 ]
EOF

chmod +x tests/smoke.sh
bash -n tests/smoke.sh && echo "syntax OK"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-43-53.png>)

**Verify:**
```bash
cd "$COURSE_ROOT"
find labs/lab-11-cicd/app -type f | sort
```

**Expected result:**
```
labs/lab-11-cicd/app/VERSION
labs/lab-11-cicd/app/config/service.json
labs/lab-11-cicd/app/src/healthz.html
labs/lab-11-cicd/app/src/index.html
labs/lab-11-cicd/app/tests/smoke.sh
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-44-05.png>)

---

### Step 8 - Write `buildspec.yml`

```bash
cd "$COURSE_ROOT/labs/lab-11-cicd/app"

cat > buildspec.yml << 'BUILDSPEC'
version: 0.2

env:
  variables:
    SERVICE_NAME: "enrolment"
    ARTIFACT_DIR: "dist"

phases:

  install:
    commands:
      - echo "--- install ---"
      - python3 --version
      - sed --version 2>/dev/null | head -1 || echo "BSD sed"

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
      - echo "configuration validated"

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
          "sourceVersion": "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}"
        }
        META
      - cp config/service.json "$ARTIFACT_DIR/service.json"

  post_build:
    commands:
      - echo "--- post_build ---"
      - bash tests/smoke.sh
      - ls -l "$ARTIFACT_DIR"
      - cat "$ARTIFACT_DIR/build-metadata.json"

artifacts:
  base-directory: dist
  files:
    - '**/*'

cache:
  paths: []
BUILDSPEC

python3 - << 'PY'
import sys
try:
    import yaml
except ImportError:
    print("PyYAML not installed - skipping the YAML parse check.")
    print("Indentation errors will surface as a FAILED install phase instead.")
    sys.exit(0)
with open("buildspec.yml") as fh:
    doc = yaml.safe_load(fh)
assert doc["version"] == 0.2, "version must be 0.2"
for phase in ("install", "pre_build", "build", "post_build"):
    assert phase in doc["phases"], f"missing phase: {phase}"
print("buildspec.yml parses, and all four phases are present.")
PY
```

**Key explanations:**
- `USMS_RELEASE` is recomputed in `build` so the buildspec also works in the local runner.
- `sed -i.bak` works on both GNU and BSD sed; the `.bak` is removed afterwards.
- `${CODEBUILD_BUILD_ID:-local}` — CodeBuild sets these; `:-local` fires when run locally.
- `- |` is a YAML **literal block scalar** — required for heredocs and for any command containing `": "` (e.g. the `grep` in `pre_build`), otherwise YAML parses it as a mapping key.
- `artifacts.base-directory: dist` + `files: ['**/*']` makes `dist` the root of the artifact (no `dist/` prefix).
- **Nested heredocs:** outer `<< 'BUILDSPEC'` is quoted → text is written literally (the `$` survive). Inner `<< META` is unquoted → expanded at build time. **Quoted heredoc writes the text, unquoted heredoc writes the result.**

**Expected result:**
```
buildspec.yml parses, and all four phases are present.
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-46-36.png>)

**Verify:**
```bash
cd "$COURSE_ROOT"
grep -c '' labs/lab-11-cicd/app/buildspec.yml
grep -n 'base-directory\|^version\|^phases\|^artifacts' labs/lab-11-cicd/app/buildspec.yml
```
**Look for:** `version`, `phases`, `artifacts`, `base-directory` each exactly once.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-47-06.png>)

#### Step 8 - Port validation in `pre_build`

I added a port check to `pre_build`. I put the command in a YAML block scalar because it contains a colon followed by a space. The regular expression requires a non-digit or the end of the line after `80`, so `"port": 8080` fails the check.

I recorded the updated buildspec and the command I used to check it below.

```bash
cd "$COURSE_ROOT/labs/lab-11-cicd/app"

cat > buildspec.yml << 'BUILDSPEC'
version: 0.2

env:
  variables:
    SERVICE_NAME: "enrolment"
    ARTIFACT_DIR: "dist"

phases:

  install:
    commands:
      - echo "--- install ---"
      - python3 --version
      - sed --version 2>/dev/null | head -1 || echo "BSD sed"

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
      - |
        grep -Eq '"port": 80([^0-9]|$)' config/service.json || {
          echo "config/service.json: port must be 80 (the ALB target group and container listen on 80). Set \"port\": 80 and rebuild."
          exit 1
        }
      - echo "configuration validated"

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
          "sourceVersion": "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}"
        }
        META
      - cp config/service.json "$ARTIFACT_DIR/service.json"

  post_build:
    commands:
      - echo "--- post_build ---"
      - bash tests/smoke.sh
      - ls -l "$ARTIFACT_DIR"
      - cat "$ARTIFACT_DIR/build-metadata.json"

artifacts:
  base-directory: dist
  files:
    - '**/*'

cache:
  paths: []
BUILDSPEC

python3 -c 'import yaml; d=yaml.safe_load(open("buildspec.yml")); print("pre_build commands:", len(d["phases"]["pre_build"]["commands"]))' \
  2>/dev/null || echo "PyYAML not installed - parse check skipped"
cd "$COURSE_ROOT"
```

**Result:** The updated buildspec parsed with six `pre_build` commands. I verified that the phase accepted port `80` and rejected port `8080`. Step 14 includes the full local build test.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-54-51.png>)

**Checkpoint 3** - `VERSION r3`, `buildspec.yml` (v0.2, four phases, artifacts from `dist/`), `config/service.json`, `src/index.html` (placeholders), `src/healthz.html`, `tests/smoke.sh` (7 assertions).

---
### Step 9 - Create the CodeBuild service role and its policy

**Concept:** A build container is a principal. Working from the buildspec, the build needs only: (1) to write its own logs (`logs:CreateLogGroup`, `CreateLogStream`, `PutLogEvents`), and (2) to read the source zip and write the artifact zip (`s3:GetObject`, `GetObjectVersion`, `PutObject`, `GetBucketAcl`, `GetBucketLocation`). An explicit **Deny** documents that builds never touch `usms-student-data`.

**Part 1 - trust policy**
```bash
cd "$COURSE_ROOT"

cat > policies/trust-codebuild.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodeBuildAssumesThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "codebuild.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "000000000000" }
      }
    }
  ]
}
EOF

python3 -m json.tool policies/trust-codebuild.json > /dev/null && echo "trust-codebuild.json is valid JSON"
```
`aws:SourceAccount` is the confused-deputy guard (tightened with `aws:SourceArn` in Exercise 3).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-57-01.png>)

**Part 2 - permissions policy**
```bash
cat > policies/usms-codebuild-policy.json << 'EOF'
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

python3 -m json.tool policies/usms-codebuild-policy.json > /dev/null && echo "usms-codebuild-policy.json is valid JSON"
```
Two log ARNs: the group (for `CreateLogGroup`) and `:*` (for streams inside it). Bucket ARN vs `bucket/*` for bucket-level vs object-level actions.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-57-38.png>)

**Part 3 - create the role and attach**
```bash
BUILD_ROLE="usms-codebuild-role"
BUILD_POLICY="USMSCodeBuildBase"

aws iam create-role \
  --role-name "$BUILD_ROLE" \
  --assume-role-policy-document file://policies/trust-codebuild.json \
  --description "Role assumed by CodeBuild when it builds the USMS enrolment service" \
  --tags Key=Project,Value=USMS Key=Tier,Value=pipeline Key=Lab,Value=11 \
  --query 'Role.Arn' --output text

BUILD_POLICY_ARN=$(aws iam create-policy \
  --policy-name "$BUILD_POLICY" \
  --policy-document file://policies/usms-codebuild-policy.json \
  --description "What a USMS build may do: its own logs, the artifact bucket, nothing else" \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy \
  --role-name "$BUILD_ROLE" \
  --policy-arn "$BUILD_POLICY_ARN"

BUILD_ROLE_ARN=$(aws iam get-role --role-name "$BUILD_ROLE" --query 'Role.Arn' --output text)
echo "$BUILD_ROLE_ARN"
```

**Expected result:** `arn:aws:iam::000000000000:role/usms-codebuild-role`

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-58-12.png>)

**Verify:**
```bash
aws iam list-attached-role-policies --role-name "$BUILD_ROLE" --output table
aws iam get-role --role-name "$BUILD_ROLE" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal' --output json
```
**Look for:** one policy `USMSCodeBuildBase`; principal `{"Service": "codebuild.amazonaws.com"}` (global, not regional).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 19-58-31.png>)

**The explicit Deny in one sentence:** it states in the document itself that no build may read or write student records, and on real AWS it overrides any future Allow that might accidentally grant access to `usms-student-data`.

---

### Step 10 - Create the CodeBuild project

**Concept - the trap:** a project with `source.type = CODEPIPELINE` cannot be started on its own. So the project is created with an **S3** source first (Step 12 runs it standalone), and is converted to `CODEPIPELINE` only in Step 18.

```bash
cat > templates/lab-11-codebuild-project.json << EOF
{
  "name": "usms-enrolment-build",
  "description": "Builds the USMS enrolment service artifact from labs/lab-11-cicd/app",
  "source": {
    "type": "S3",
    "location": "usms-pipeline-artifacts/source/usms-enrolment-src.zip",
    "buildspec": "buildspec.yml"
  },
  "artifacts": {
    "type": "S3",
    "location": "usms-pipeline-artifacts",
    "path": "build",
    "name": "usms-enrolment-build.zip",
    "packaging": "ZIP",
    "namespaceType": "NONE"
  },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "docker.io/library/python:3.12-slim-bookworm",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": false,
    "environmentVariables": [
      { "name": "USMS_PROJECT", "value": "USMS", "type": "PLAINTEXT" },
      { "name": "USMS_SERVICE", "value": "enrolment", "type": "PLAINTEXT" }
    ]
  },
  "serviceRole": "${BUILD_ROLE_ARN}",
  "timeoutInMinutes": 15,
  "queuedTimeoutInMinutes": 30,
  "logsConfig": {
    "cloudWatchLogs": {
      "status": "ENABLED",
      "groupName": "/aws/codebuild/usms-enrolment-build"
    }
  },
  "tags": [
    { "key": "Project", "value": "USMS" },
    { "key": "Tier", "value": "pipeline" },
    { "key": "Lab", "value": "11" }
  ]
}
EOF

python3 -m json.tool templates/lab-11-codebuild-project.json > /dev/null \
  && echo "project template is valid JSON"
grep -c '\$' templates/lab-11-codebuild-project.json
```

Unquoted heredoc so `${BUILD_ROLE_ARN}` is substituted at write time; `grep -c '\$'` must print **0**. CodeBuild tags use lowercase `key`/`value` (IAM/ELBv2 use `Key`/`Value`).

**Expected result:**
```
project template is valid JSON
0
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-05-10.png>)

**Create it:**
```bash
aws codebuild create-project \
  --cli-input-json file://templates/lab-11-codebuild-project.json \
  --query 'project.{Name:name,Role:serviceRole,Image:environment.image,Source:source.type}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-05-39.png>)

**Verify:**
```bash
aws codebuild batch-get-projects --names usms-enrolment-build \
  --query 'projects[0].{Name:name,Source:source.type,Location:source.location,Artifacts:artifacts.type,Timeout:timeoutInMinutes}' \
  --output table
```
**Look for:** `Source` = `S3`, `Location` = `usms-pipeline-artifacts/source/usms-enrolment-src.zip`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-05-50.png>)

**Checkpoint 4** - `usms-codebuild-role` + `USMSCodeBuildBase`; project `usms-enrolment-build` (source S3, `standard:7.0`, small, 15-min timeout).

---

### Step 11 - Package and upload the source

**Concept - the layout that works:** `buildspec.yml` must be at the **root** of the zip. `zip -r ../x.zip .` from inside the directory is correct; `zip -r x.zip app/` from the parent is wrong (→ `YAML_FILE_ERROR`).

**Part 1 - the packer**
```bash
cd "$COURSE_ROOT"

cat > scripts/utilities/usms-pack-source.sh << 'EOF'
#!/usr/bin/env bash
# Package a source directory into a zip whose ROOT is that directory's contents.
# Usage: usms-pack-source.sh <source-dir> <output-zip>
set -uo pipefail

SRC="${1:-}"
OUT="${2:-}"
if [ -z "$SRC" ] || [ -z "$OUT" ]; then
  echo "usage: $0 <source-dir> <output-zip>" >&2
  exit 2
fi
if [ ! -d "$SRC" ]; then
  echo "not a directory: $SRC" >&2
  exit 2
fi

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"

if command -v zip >/dev/null 2>&1; then
  ( cd "$SRC" && zip -r -q "$OUT_ABS" . -x '*.bak' -x 'dist/*' )
  echo "packed with zip"
else
  python3 - "$SRC" "$OUT_ABS" << 'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in sorted(dirs) if d != "dist"]
        for f in sorted(files):
            if f.endswith(".bak"):
                continue
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, src))
PY
  echo "packed with python3 zipfile"
fi

echo "--- archive contents ---"
if command -v unzip >/dev/null 2>&1; then
  unzip -l "$OUT_ABS"
else
  python3 -c 'import sys,zipfile;[print(n) for n in zipfile.ZipFile(sys.argv[1]).namelist()]' "$OUT_ABS"
fi
EOF

chmod +x scripts/utilities/usms-pack-source.sh
bash -n scripts/utilities/usms-pack-source.sh && echo "syntax OK"
```
Excludes `dist/` (so a build cannot "pass" using the previous build's output). `OUT_ABS` is computed before the subshell `cd`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-09-21.png>)

**Part 2 - pack and upload**
```bash
./scripts/utilities/usms-pack-source.sh \
  labs/lab-11-cicd/app \
  outputs/usms-enrolment-src.zip

aws s3api put-object \
  --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip \
  --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text
```

**Expected result (example):**
```
packed with zip
--- archive contents ---
  Length      Date    Time    Name
---------  ---------- -----   ----
        0  2026-09-17 09:14   src/
        3  2026-09-17 09:14   src/healthz.html
      254  2026-09-17 09:14   src/index.html
        0  2026-09-17 09:14   config/
      200  2026-09-17 09:14   config/service.json
     1759  2026-09-17 09:14   buildspec.yml
        0  2026-09-17 09:14   tests/
      813  2026-09-17 09:14   tests/smoke.sh
        3  2026-09-17 09:14   VERSION
---------                     -------
     3032                     9 files

3HL9pQ...
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-11-22.png>)

**Look for:** `buildspec.yml` and `VERSION` at top level; nothing starts with `app/`. Last line = S3 version ID.

**First source version ID (r3):** `40925890-02ff-4527-b8be-25274a3da6be`

**Confirm the zip is git-ignored:**
```bash
git check-ignore -v outputs/usms-enrolment-src.zip
```
**Look for:** `.gitignore`, line number and pattern `outputs/*`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-11-43.png>)

---

### Step 12 - Run the build on its own

```bash
BUILD_ID=$(aws codebuild start-build \
  --project-name usms-enrolment-build \
  --query 'build.id' --output text)

echo "$BUILD_ID"
```

**Expected:** `usms-enrolment-build:9f0c1a3e-...` (async; returns immediately).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-13-51.png>)

**Poll until finished:**
```bash
for i in $(seq 1 40); do
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
             --query 'builds[0].buildStatus' --output text 2>/dev/null)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
            --query 'builds[0].currentPhase' --output text 2>/dev/null)
  printf '  %2d  status=%-12s phase=%s\n' "$i" "${STATUS:-unknown}" "${PHASE:-unknown}"
  case "$STATUS" in
    SUCCEEDED|FAILED|FAULT|STOPPED|TIMED_OUT) break ;;
  esac
  sleep 10
done
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-14-14.png>)

**Look for:** phases advancing QUEUED → PROVISIONING → INSTALL → PRE_BUILD → BUILD → POST_BUILD → UPLOAD_ARTIFACTS → COMPLETED, ending `SUCCEEDED`. A hand-written loop is used instead of a waiter so every observation is printed.

> **Floci Limitation - stuck in PROVISIONING:** give it four minutes. If the phase has not moved:
> ```bash
> aws codebuild stop-build --id "$BUILD_ID"
> printf 'Step 12: build stuck in PROVISIONING for 4 minutes, stopped (Path B/C behaviour).\n' >> notes/lab-11-notes.md
> ```
> Then continue with Step 14 (local runner).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-14-53.png>)

---

### Step 13 - Read the build output and the logs

```bash
aws codebuild batch-get-builds --ids "$BUILD_ID" \
  --query 'builds[0].phases[].{Phase:phaseType,Status:phaseStatus,Seconds:durationInSeconds}' \
  --output table

aws codebuild batch-get-builds --ids "$BUILD_ID" > "outputs/lab-11-build-$(date +%s).json"
```

**Expected result (example):**
```
|  SUBMITTED        |  0         |  SUCCEEDED   |
|  QUEUED           |  1         |  SUCCEEDED   |
|  PROVISIONING     |  22        |  SUCCEEDED   |
|  DOWNLOAD_SOURCE  |  2         |  SUCCEEDED   |
|  INSTALL          |  1         |  SUCCEEDED   |
|  PRE_BUILD        |  1         |  SUCCEEDED   |
|  BUILD            |  1         |  SUCCEEDED   |
|  POST_BUILD       |  1         |  SUCCEEDED   |
|  UPLOAD_ARTIFACTS |  2         |  SUCCEEDED   |
|  FINALIZING       |  1         |  SUCCEEDED   |
|  COMPLETED        |            |              |
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-22-33.png>)

**My result:** The first build stopped after `DOWNLOAD_SOURCE` because Docker could not pull the AWS-managed `aws/codebuild/standard:7.0` image. I switched the Floci project to the public Python image in Step 10 and reran the build. `usms-enrolment-build:2` completed with all 11 phases marked `SUCCEEDED`.

The S3 listing after this run showed the source ZIP only. The successful phase statuses establish that the build completed, and Step 13 checks separately for the uploaded artifact.

**Look for:** mine are `INSTALL/PRE_BUILD/BUILD/POST_BUILD`; the rest are the service's. `DOWNLOAD_SOURCE` failure = source/permissions; `PRE_BUILD` = my code; `PROVISIONING` = capacity or image.

**The log:**
```bash
LOG_GROUP=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
  --query 'builds[0].logs.groupName' --output text)
LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
  --query 'builds[0].logs.streamName' --output text)

echo "group=$LOG_GROUP stream=$LOG_STREAM"

aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name "$LOG_STREAM" \
  --limit 60 \
  --query 'events[].message' --output text
```
**Look for:** the `--- install ---` … `--- post_build ---` markers and seven `ok` lines.

> **Floci Limitation — empty logs:** streams are often empty even when the build ran. Do not conclude the build did nothing — check phases and the artifact.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-22-59.png>)

**Read the artifact back:**
```bash
aws s3api list-objects-v2 --bucket usms-pipeline-artifacts --prefix build/ \
  --query 'Contents[].{Key:Key,Size:Size}' --output table
```
**Look for:** one object under `build/`. `SUCCEEDED` with no artifact means `base-directory` does not match.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-23-16.png>)

**Checkpoint 5** - `source/usms-enrolment-src.zip` (1 version), `build/usms-enrolment-build.zip`; one build SUCCEEDED with ten recorded phases.

---

### Step 14 - The local buildspec runner

**Purpose:** (1) run the build if CodeBuild never left PROVISIONING; (2) debug a buildspec in two seconds instead of ninety.

| Same | Different |
|---|---|
| The commands, from the same file | Runs on my machine, not `docker.io/library/python:3.12-slim-bookworm` |
| The phase order | `set -e`: stops at first failure (CodeBuild still runs `post_build` after a failed build) |
| `env.variables`, overridable by the environment | No `CODEBUILD_*` variables - `:-local` defaults fire |
| The artifacts directory it produces | Does not zip or upload anything |

```bash
cd "$COURSE_ROOT"

cat > scripts/utilities/usms-buildspec-run.sh << 'EOF'
#!/usr/bin/env bash
# Run a buildspec's phases locally, in order, in one shell.
# Usage: usms-buildspec-run.sh <app-dir> [buildspec-file]
set -uo pipefail

APP_DIR="${1:-}"
SPEC="${2:-buildspec.yml}"
if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
  echo "usage: $0 <app-dir> [buildspec-file]" >&2
  exit 2
fi
APP_ABS="$(cd "$APP_DIR" && pwd)"
if [ ! -f "$APP_ABS/$SPEC" ]; then
  echo "no $SPEC in $APP_ABS" >&2
  exit 2
fi

GEN="${TMPDIR:-/tmp}/usms-buildspec-$$.sh"

python3 - "$APP_ABS/$SPEC" "$GEN" << 'PY'
import sys

spec_path, out_path = sys.argv[1], sys.argv[2]
ORDER = ("install", "pre_build", "build", "post_build")


def with_pyyaml(path):
    import yaml
    doc = yaml.safe_load(open(path))
    env = ((doc.get("env") or {}).get("variables") or {})
    phases = {}
    for name, body in (doc.get("phases") or {}).items():
        phases[name] = list((body or {}).get("commands") or [])
    return env, phases


def minimal(path):
    """Handles exactly the buildspec subset this course writes:
    env: -> variables: -> KEY: value ; phases: -> <phase>: -> commands: -> '- cmd'
    or '- |' followed by a more-indented literal block."""
    env, phases = {}, {}
    in_env = in_env_vars = in_phases = in_commands = False
    phase = None
    cmds = None
    block = None
    block_indent = 0

    def close_block():
        nonlocal block
        if block is not None:
            cmds.append("\n".join(block).rstrip())
            block = None

    for raw in open(path).read().splitlines():
        if block is not None:
            if raw.strip() == "":
                block.append("")
                continue
            if (len(raw) - len(raw.lstrip())) >= block_indent:
                block.append(raw[block_indent:])
                continue
            close_block()
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent == 0:
            in_env = stripped.startswith("env:")
            in_phases = stripped.startswith("phases:")
            in_env_vars = in_commands = False
            phase = None
            continue
        if in_env and indent == 2:
            in_env_vars = (stripped == "variables:")
            continue
        if in_env_vars and indent == 4 and ":" in stripped:
            k, v = stripped.split(":", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
            continue
        if in_phases and indent == 2 and stripped.endswith(":"):
            phase = stripped[:-1]
            phases[phase] = []
            cmds = phases[phase]
            in_commands = False
            continue
        if in_phases and phase and indent == 4 and stripped == "commands:":
            in_commands = True
            continue
        if in_commands and stripped.startswith("- "):
            body = stripped[2:]
            if body.strip() == "|":
                block = []
                block_indent = indent + 2
            else:
                cmds.append(body)
            continue
    close_block()
    return env, phases


try:
    env, phases = with_pyyaml(spec_path)
    parser = "PyYAML"
except ImportError:
    env, phases = minimal(spec_path)
    parser = "built-in minimal parser"

lines = ["#!/usr/bin/env bash", "set -Eeuo pipefail", ""]
for k, v in env.items():
    # A value already in the environment wins, the way a CodeBuild project-level
    # environment variable overrides a buildspec env.variables default.
    lines.append('export %s="${%s:-%s}"' % (k, k, v))
lines.append("")
for name in ORDER:
    if name not in phases:
        continue
    lines.append('echo "=== phase: %s ==="' % name)
    lines.extend(phases[name])
    lines.append("")
lines.append('echo "=== all phases completed ==="')

open(out_path, "w").write("\n".join(lines) + "\n")
print("buildspec parsed with %s; %d phases" % (parser, len([p for p in ORDER if p in phases])))
PY

RC=$?
[ "$RC" -ne 0 ] && { echo "could not parse the buildspec" >&2; exit "$RC"; }

echo "--- generated script: $GEN ---"
bash -n "$GEN" && echo "generated script is valid bash"
echo "--- running in $APP_ABS ---"
( cd "$APP_ABS" && bash "$GEN" )
STATUS=$?
echo "--- local build exit status: $STATUS ---"
rm -f "$GEN"
exit "$STATUS"
EOF

chmod +x scripts/utilities/usms-buildspec-run.sh
bash -n scripts/utilities/usms-buildspec-run.sh && echo "syntax OK"

./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app
```

**Expected result (example):**
```
buildspec parsed with PyYAML; 4 phases
--- generated script: /tmp/usms-buildspec-4821.sh ---
generated script is valid bash
--- running in /home/you/aws-floci-course/labs/lab-11-cicd/app ---
=== phase: install ===
Python 3.12.3
sed (GNU sed) 4.9
=== phase: pre_build ===
configuration validated
=== phase: build ===
release=r3 builtAt=2026-09-17T09:31:04Z
=== phase: post_build ===
== smoke tests ==
  ok   dist/index.html exists
  ok   dist/healthz.html exists
  ok   release placeholder was replaced
  ok   build-time placeholder was replaced
  ok   health endpoint says ok
  ok   build metadata is valid JSON
  ok   container name matches the task def
smoke tests failed: 0
...
=== all phases completed ===
--- local build exit status: 0 ---
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-29-24.png>)

**Verify:**
```bash
cat labs/lab-11-cicd/app/dist/build-metadata.json
grep -n 'release:' labs/lab-11-cicd/app/dist/index.html
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-29-56.png>)

**Look for:** `"release": "r3"`, `"buildId": "local"`; `release: r3` with no `__RELEASE__`.

**Git-ignore `dist/`:**
```bash
grep -q '^labs/lab-11-cicd/app/dist/' .gitignore || \
  printf 'labs/lab-11-cicd/app/dist/\n' >> .gitignore

git check-ignore -v labs/lab-11-cicd/app/dist/build-metadata.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-30-07.png>)

#### Port validation test in `pre_build`

```bash
cd "$COURSE_ROOT/labs/lab-11-cicd/app"

# 1. break the port
sed -i.bak 's/"port": 80,/"port": 8080,/' config/service.json && rm -f config/service.json.bak
grep '"port"' config/service.json

# 2. run the local build - it must stop in pre_build with my message
cd "$COURSE_ROOT"
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app; echo "runner exit: $?"

# 3. restore and prove it passes again
sed -i.bak 's/"port": 8080,/"port": 80,/' labs/lab-11-cicd/app/config/service.json \
  && rm -f labs/lab-11-cicd/app/config/service.json.bak
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1 \
  && echo "local build passes again with port 80"
```

**Expected:** after `=== phase: pre_build ===` the message `config/service.json: port must be 80 ...` and a non-zero exit; then `local build passes again with port 80`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-34-27.png>)

**Checkpoint 6** - `cicd-support-probe.sh`, `usms-pack-source.sh`, `usms-buildspec-run.sh` (4 phases, 7 smoke tests, exit 0).

---
### Step 15 - Create the CodePipeline service role and its policy

**Concept - `iam:PassRole`:** the pipeline calls `codebuild:StartBuild`; CodeBuild then runs *as* `usms-codebuild-role`. Handing a role to a service is its own permission. Without it, anyone able to create a CodeBuild project could name an admin role as its service role and run arbitrary commands as it.

```
usms-codepipeline-role  ──iam:PassRole──>  usms-codebuild-role  ──used by──>  codebuild.amazonaws.com
```

**Comparison (Lab 09 `USMSDeployBase`, if completed):**
```bash
[ -f policies/usms-deploy-policy.json ] \
  && python3 -m json.tool policies/usms-deploy-policy.json | grep -n -A12 'iam:PassRole' \
  || echo "Lab 09 not completed - using the EKS (Labs 07-08) statement from the lab sheet"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-37-51.png>)

EKS deployment (Labs 07–08) pass-role statement, for side-by-side comparison:
```json
{
  "Sid": "PassOnlyTheseRolesAndOnlyToTheseServices",
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": [
    "arn:aws:iam::000000000000:role/usms-ec2-app-role",
    "arn:aws:iam::000000000000:role/usms-ecs-exec-role",
    "arn:aws:iam::000000000000:role/usms-ecs-task-role"
  ],
  "Condition": {
    "StringEquals": {
      "iam:PassedToService": ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com"]
    }
  }
}
```

**Notes question - what goes wrong if `Resource` were `"*"` but the condition were kept?**
> The condition only restricts *which service* receives the role, not *which role* is passed. With `Resource: "*"`, the pipeline role (or anyone who compromises it) could pass **any role in the account whose trust policy allows `codebuild.amazonaws.com`** - for example an administrator or break-glass role that some other team made assumable by CodeBuild - to a CodeBuild project, and then run arbitrary build commands with that role's permissions. In the EKS/Lab 09 statement the same mistake would let the attacker pass any role trusted by EC2 or ECS tasks (e.g. an admin instance-profile role) to an instance or task they launch. The condition limits the *door*; only the resource list limits the *keys*.

```bash
cat >> notes/lab-11-notes.md << 'EOF'
## Step 15 - PassRole with Resource "*"
The condition iam:PassedToService only pins the receiving service. With Resource "*",
any role trusted by codebuild.amazonaws.com (e.g. an admin role someone made assumable
by CodeBuild) could be passed to a project I control and used to run arbitrary commands
with its permissions. Only the Resource list limits which role can be handed over.

EOF
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-39-08.png>)

**Part 1 - the documents**
```bash
cd "$COURSE_ROOT"

cat > policies/trust-codepipeline.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodePipelineAssumesThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "codepipeline.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "000000000000" }
      }
    }
  ]
}
EOF

cat > policies/usms-codepipeline-policy.json << 'EOF'
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
    }
  ]
}
EOF

for f in policies/trust-codepipeline.json policies/usms-codepipeline-policy.json; do
  python3 -m json.tool "$f" > /dev/null && echo "$f is valid JSON"
done
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-39-41.png>)

One project ARN (not `project/*`); `s3:GetBucketVersioning` because CodePipeline checks the S3 source bucket is versioned.

**Part 2 - create and attach**
```bash
PIPELINE_ROLE="usms-codepipeline-role"
PIPELINE_POLICY="USMSCodePipelineBase"

aws iam create-role \
  --role-name "$PIPELINE_ROLE" \
  --assume-role-policy-document file://policies/trust-codepipeline.json \
  --description "Role assumed by CodePipeline when it runs usms-enrolment-pipeline" \
  --tags Key=Project,Value=USMS Key=Tier,Value=pipeline Key=Lab,Value=11 \
  --query 'Role.Arn' --output text

PIPELINE_POLICY_ARN=$(aws iam create-policy \
  --policy-name "$PIPELINE_POLICY" \
  --policy-document file://policies/usms-codepipeline-policy.json \
  --description "What the USMS pipeline may do: its artifact store, one build project, one PassRole" \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy --role-name "$PIPELINE_ROLE" --policy-arn "$PIPELINE_POLICY_ARN"

PIPELINE_ROLE_ARN=$(aws iam get-role --role-name "$PIPELINE_ROLE" --query 'Role.Arn' --output text)
echo "$PIPELINE_ROLE_ARN"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-40-11.png>)

**Verify:**
```bash
aws iam get-policy --policy-arn "$PIPELINE_POLICY_ARN" \
  --query 'Policy.{Name:PolicyName,Default:DefaultVersionId,Attached:AttachmentCount}' --output table
```
**Look for:** `Default` = `v1`, `Attached` = `1`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-40-30.png>)

---

### Step 16 - Write the pipeline definition

**Concept:**
```
pipeline
 ├── name, roleArn, artifactStore
 └── stages[]                      ordered
      └── actions[]                same runOrder = parallel
           ├── actionTypeId        category + owner + provider + version ("1", a STRING)
           ├── configuration       every value is a STRING
           ├── inputArtifacts[]
           └── outputArtifacts[]
```
Artifact names (`SourceOutput`, `BuildOutput`) are local to the pipeline — not S3 keys.

```bash
cat > templates/lab-11-pipeline.json << EOF
{
  "pipeline": {
    "name": "usms-enrolment-pipeline",
    "roleArn": "${PIPELINE_ROLE_ARN}",
    "artifactStore": {
      "type": "S3",
      "location": "usms-pipeline-artifacts"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [
          {
            "name": "FetchSource",
            "actionTypeId": {
              "category": "Source",
              "owner": "AWS",
              "provider": "S3",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "S3Bucket": "usms-pipeline-artifacts",
              "S3ObjectKey": "source/usms-enrolment-src.zip",
              "PollForSourceChanges": "false"
            },
            "inputArtifacts": [],
            "outputArtifacts": [ { "name": "SourceOutput" } ]
          }
        ]
      },
      {
        "name": "Build",
        "actions": [
          {
            "name": "BuildArtifact",
            "actionTypeId": {
              "category": "Build",
              "owner": "AWS",
              "provider": "CodeBuild",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ProjectName": "usms-enrolment-build"
            },
            "inputArtifacts": [ { "name": "SourceOutput" } ],
            "outputArtifacts": [ { "name": "BuildOutput" } ]
          }
        ]
      }
    ]
  }
}
EOF

python3 -m json.tool templates/lab-11-pipeline.json > /dev/null && echo "pipeline template is valid JSON"
grep -c '\$' templates/lab-11-pipeline.json
```
`"PollForSourceChanges": "false"` — executions are started by hand (Exercise 4 designs the EventBridge trigger).

**Expected result:**
```
pipeline template is valid JSON
0
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-44-13.png>)

---

### Step 17 - Create the pipeline

```bash
aws codepipeline create-pipeline \
  --cli-input-json file://templates/lab-11-pipeline.json \
  --query 'pipeline.{Name:name,Role:roleArn,Stages:length(stages)}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-45-38.png>)

> **Creating a pipeline starts an execution immediately.** That first execution uses the project as currently configured (its own S3 source). Let it run and note the result - Step 18 explains why it is ambiguous.

**Verify:**
```bash
aws codepipeline get-pipeline-state --name usms-enrolment-pipeline \
  --query 'stageStates[].{Stage:stageName,Status:latestExecution.status,Action:actionStates[0].actionName,ActionStatus:actionStates[0].latestExecution.status}' \
  --output table
```

**Expected result (example):**
```
|  FetchSource  |  Succeeded  |  Source  |  Succeeded   |
|  BuildArtifact|  InProgress |  Build   |  InProgress  |
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-46-01.png>)

**Look for:** Source = `Succeeded` → bucket is versioned, object exists at the key, pipeline role can read it.

> **Floci Limitation:** some builds store pipelines but never execute them (`stageStates` with no `latestExecution`). That is Path B/C - record the document and use the local runner.

**Result of the automatic first execution:** I created the two-stage pipeline successfully. When I checked its state after creation, both `FetchSource` and `BuildArtifact` showed `None` for execution status. No automatic execution was recorded at that point.

**Checkpoint 7** - pipeline with role `usms-codepipeline-role`, artifact store `s3://usms-pipeline-artifacts`, Source → Build.

---

### Step 18 - Hand the project to the pipeline

**Trade-off:** after `source.type = CODEPIPELINE` the Build stage unambiguously builds the Source stage's artifact, but `start-build --project-name` stops working.

```bash
aws codebuild update-project \
  --name usms-enrolment-build \
  --source type=CODEPIPELINE,buildspec=buildspec.yml \
  --artifacts type=CODEPIPELINE \
  --query 'project.{Source:source.type,Artifacts:artifacts.type}' \
  --output table
```

**Expected:**
```
|   Artifacts   |   Source   |
|  CODEPIPELINE |CODEPIPELINE|
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-50-00.png>)

**Verify - the cost:**
```bash
aws codebuild start-build --project-name usms-enrolment-build 2>&1 | head -3
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-50-20.png>)

**Look for:** an error (`InvalidInputException` on real AWS). If it *succeeds*, record it under "recorded, not observed".

**The escape hatch — one-off build of a CODEPIPELINE project:**
```bash
aws codebuild start-build \
  --project-name usms-enrolment-build \
  --source-type-override S3 \
  --source-location-override usms-pipeline-artifacts/source/usms-enrolment-src.zip \
  --query 'build.id' --output text
```
**Look for:** a build ID (or record that Floci rejects the override flags).

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-50-37.png>)

---

### Step 19 - Run the pipeline end to end, and prove it consumed your source

**Proof: create → perturb → read back.** The artifact says `r3`; change `VERSION` to `r4`, upload, execute, then look *inside* the output artifact. **A green pipeline is not evidence. The contents of the artifact are evidence.**

**Part 1 - perturb**
```bash
cd "$COURSE_ROOT"

printf 'r4\n' > labs/lab-11-cicd/app/VERSION

./scripts/utilities/usms-pack-source.sh \
  labs/lab-11-cicd/app \
  outputs/usms-enrolment-src.zip

NEW_VERSION_ID=$(aws s3api put-object \
  --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip \
  --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text)

echo "uploaded source version: $NEW_VERSION_ID"

aws s3api list-object-versions --bucket usms-pipeline-artifacts \
  --prefix source/usms-enrolment-src.zip \
  --query 'Versions[].{Version:VersionId,Latest:IsLatest,Modified:LastModified}' \
  --output table
```
**Result:** I found two source versions, with `r4` marked as the latest. **r4 version ID:** `316c483a-43c2-4661-bc80-55dd9dd96106`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-54-08.png>)

**Part 2 - run**
```bash
EXEC_ID=$(aws codepipeline start-pipeline-execution \
  --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text)

echo "execution: $EXEC_ID"

for i in $(seq 1 30); do
  aws codepipeline get-pipeline-state --name usms-enrolment-pipeline \
    --query 'stageStates[].[stageName,latestExecution.status]' --output text |
    sed 's/^/    /'
  STATE=$(aws codepipeline get-pipeline-execution \
            --pipeline-name usms-enrolment-pipeline \
            --pipeline-execution-id "$EXEC_ID" \
            --query 'pipelineExecution.status' --output text 2>/dev/null)
  printf '  %2d  execution=%s\n' "$i" "${STATE:-unknown}"
  case "$STATE" in
    Succeeded|Failed|Stopped|Superseded) break ;;
  esac
  sleep 10
done
```

**Expected (example):**
```
execution: 7c1f0a92-3b5d-4a11-9e0c-5d3a8f2b6e40
    Source	Succeeded
    Build	InProgress
   1  execution=InProgress
    Source	Succeeded
    Build	Succeeded
   2  execution=Succeeded
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 20-56-41.png>)

**Part 3 - read back**
```bash
(
BUILD_ART_KEY=$(aws s3api list-objects-v2 \
  --bucket usms-pipeline-artifacts \
  --prefix usms-enrolment-pipeline/BuildOutput/ \
  --query 'sort_by(Contents || `[]`, &LastModified)[-1].Key' --output text) || exit 1

if [[ -z "${BUILD_ART_KEY}" || "${BUILD_ART_KEY}" == None ]]; then
  echo "No BuildOutput artifact exists in S3. Check the pipeline execution and its build logs." >&2
  exit 1
fi

echo "newest build artifact: $BUILD_ART_KEY"

aws s3api get-object \
  --bucket usms-pipeline-artifacts \
  --key "$BUILD_ART_KEY" \
  outputs/lab-11-buildoutput.zip > /dev/null || exit 1

python3 - << 'PY'
import json, zipfile
with zipfile.ZipFile("outputs/lab-11-buildoutput.zip") as z:
    names = sorted(z.namelist())
    print("artifact contents:")
    for n in names:
        print("   ", n)
    meta = json.loads(z.read("build-metadata.json"))
print("release  :", meta["release"])
print("builtAt  :", meta["builtAt"])
print("buildId  :", meta["buildId"])
print("srcVersion:", meta["sourceVersion"])
PY

echo "uploaded version was: ${NEW_VERSION_ID:-see the r4 version ID above}"
)
```
The query treats an absent object list as empty. The readback stops if no artifact key is available or if the download fails.

**My result:** Floci marked the r4 Source and Build actions as `Succeeded` for execution `77e61c68-0ea7-4d90-9eba-113b7772ec6d`, but the artifact bucket contained only the source ZIP. I downloaded the exact r4 source version and ran the Step 14 local buildspec runner. All seven smoke tests passed. I saved the local artifact as `outputs/lab-11-r4-local-buildoutput.zip` and confirmed that its metadata identifies release `r4`, the uploaded source version, and build ID `local`.

**Expected (example):**
```
newest build artifact: usms-enrolment-pipeline/BuildOutput/A1b2C3d.zip
artifact contents:
    build-metadata.json
    healthz.html
    index.html
    service.json
release  : r4
builtAt  : 2026-09-17T09:58:11Z
buildId  : usms-enrolment-build:1d0a...
srcVersion: 3HL9pQ...
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-00-34.png>)

**Look for, in order:** (1) `release` is `r4`; (2) `buildId` is **not** `local`; (3) no `dist/` prefix in the artifact; (4) `srcVersion` matches `$NEW_VERSION_ID` (if populated).

> **Path B/C:** if no BuildOutput exists, produce the artifact with the local runner and report it as "built locally" (`buildId: local`):
> ```bash
> ./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app
> cat labs/lab-11-cicd/app/dist/build-metadata.json
> ```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-01-16.png>)


#### Step 19 - Pipeline run for release r5.

```bash
cd "$COURSE_ROOT"
printf 'r5\n' > labs/lab-11-cicd/app/VERSION
./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null
R5_VERSION_ID=$(aws s3api put-object --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text)
echo "r5 source version: $R5_VERSION_ID"

R5_EXEC=$(aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text)
echo "execution: $R5_EXEC"

for i in $(seq 1 30); do
  S=$(aws codepipeline get-pipeline-execution --pipeline-name usms-enrolment-pipeline \
        --pipeline-execution-id "$R5_EXEC" --query 'pipelineExecution.status' --output text 2>/dev/null)
  printf '  %2d  execution=%s\n' "$i" "${S:-unknown}"
  case "$S" in Succeeded|Failed|Stopped|Superseded) break ;; esac
  sleep 10
done

```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-26-17.png>)

**Read back the existing r5 execution**

I uploaded source version `10367e2b-2cc5-4090-ade0-7c0b357895a4`. Execution `3ddc8efc-0e8c-4d4f-b26c-86f4539d375c` reported success for both actions and named CodeBuild run `usms-enrolment-build:7`. S3 listed four source versions and zero objects under `BuildOutput/`. I used the exact uploaded source version to generate local build evidence.

Run this block from the repository root to reproduce the local r5 artifact without uploading or starting another execution.

```bash
(
  set -euo pipefail
  source configs/course.env
  version=10367e2b-2cc5-4090-ade0-7c0b357895a4
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT

  aws --endpoint-url "$FLOCI_ENDPOINT" s3api get-object \
    --bucket usms-pipeline-artifacts --key source/usms-enrolment-src.zip \
    --version-id "$version" "$work/source.zip" >/dev/null
  unzip -q "$work/source.zip" -d "$work/source"
  test "$(cat "$work/source/VERSION")" = r5

  CODEBUILD_BUILD_ID=local CODEBUILD_RESOLVED_SOURCE_VERSION="$version" \
    ./scripts/utilities/usms-buildspec-run.sh "$work/source"
  (
    cd "$work/source/dist"
    python3 -m zipfile -c "$COURSE_ROOT/outputs/lab-11-r5-local-buildoutput.zip" ./*
  )
  unzip -p outputs/lab-11-r5-local-buildoutput.zip build-metadata.json
)
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-26-57.png>)

**Checkpoint 8** - The r5 pipeline execution succeeded, and the local build verified the exact source version. The pipeline-generated S3 artifact is still missing.

---

### Step 20 - Make the build fail on purpose, then fix it

**Part 1 - break it**
```bash
cd "$COURSE_ROOT"

python3 - << 'PY'
import json
p = "labs/lab-11-cicd/app/config/service.json"
doc = json.load(open(p))
doc["container"] = "enrolment-api-v2"      # deliberately wrong
json.dump(doc, open(p, "w"), indent=2)
print("container is now:", doc["container"])
PY

./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null
aws s3api put-object --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text

BAD_EXEC=$(aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text)
echo "execution: $BAD_EXEC"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-30-44.png>)

**Part 2 - diagnose it (stage → build → phase → command)**
```bash
sleep 20

aws codepipeline get-pipeline-state --name usms-enrolment-pipeline \
  --query 'stageStates[].{Stage:stageName,Status:latestExecution.status,Summary:actionStates[0].latestExecution.summary,Error:actionStates[0].latestExecution.errorDetails.message}' \
  --output json | tee outputs/lab-11-pipeline-state.json
```

**Expected (example):**
```json
[
    { "Stage": "Source", "Status": "Succeeded", "Summary": "Amazon S3 version id: 8Kd1...", "Error": null },
    { "Stage": "Build",  "Status": "Failed",    "Summary": "Build terminated with state: FAILED",
      "Error": "Error while executing command: grep -q ..." }
]
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-31-35.png>)

```bash
LAST_BUILD=$(aws codebuild list-builds-for-project --project-name usms-enrolment-build \
  --sort-order DESCENDING --query 'ids[0]' --output text 2>/dev/null)

aws codebuild batch-get-builds --ids "$LAST_BUILD" \
  --query 'builds[0].phases[?phaseStatus==`FAILED`].{Phase:phaseType,Status:phaseStatus,Context:contexts[0].message}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-31-58.png>)

**Look for:** one row, `Phase` = `PRE_BUILD`; `Context` names the failing command.

> **Floci Limitation:** if `list-builds-for-project` or `contexts` are unavailable, reproduce locally — the runner prints the failing command directly:
> ```bash
> ./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app; echo "exit: $?"
> ```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-32-24.png>)

**Part 3 - fix it (validate locally first, then push)**
```bash
python3 - << 'PY'
import json
p = "labs/lab-11-cicd/app/config/service.json"
doc = json.load(open(p))
doc["container"] = "enrolment-api"
json.dump(doc, open(p, "w"), indent=2)
print("container is now:", doc["container"])
PY

./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1 \
  && echo "local build passes again" || echo "local build STILL fails - fix it before repacking"

./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null
aws s3api put-object --bucket usms-pipeline-artifacts \
  --key source/usms-enrolment-src.zip --body outputs/usms-enrolment-src.zip \
  --query 'VersionId' --output text

aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-33-34.png>)

**Confirm the fixed execution succeeded:**
```bash
sleep 30
aws codepipeline get-pipeline-state --name usms-enrolment-pipeline \
  --query 'stageStates[].[stageName,latestExecution.status]' --output table
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-36-33.png>)

**Checkpoint 9**

| Execution | Trigger | Result |
|---|---|---|
| 1 | automatic, at creation | No execution recorded. Both stages showed None. |
| 2 | r4 | Succeeded |
| 3 | r5 | Succeeded |
| 4 | broken container name | Failed at Build / PRE_BUILD |
| 5 | fixed | Succeeded |

---

### Step 21 - Record this lab's outputs, and commit

```bash
cd "$COURSE_ROOT"

cat > configs/lab-11.env << EOF
# Lab 11 - CI/CD: source, build, and the pipeline that joins them
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, ARNs and IDs only. NO SECRETS. Safe to commit.

# --- artifact store and source ---
export USMS_PIPELINE_BUCKET=usms-pipeline-artifacts
export USMS_PIPELINE_BUCKET_VERSIONING=$(aws s3api get-bucket-versioning \
    --bucket usms-pipeline-artifacts --query 'Status' --output text 2>/dev/null \
    | grep -E '^(Enabled|Suspended)$' || echo Unknown)
export USMS_SOURCE_KEY=source/usms-enrolment-src.zip
export USMS_SOURCE_VERSION_ID=$(aws s3api head-object \
    --bucket usms-pipeline-artifacts --key source/usms-enrolment-src.zip \
    --query 'VersionId' --output text 2>/dev/null || echo not-created)
export USMS_BUILD_ARTIFACT_PREFIX=usms-enrolment-pipeline/BuildOutput/

# --- build project ---
export USMS_BUILD_PROJECT=usms-enrolment-build
export USMS_BUILD_PROJECT_ARN=$(aws codebuild batch-get-projects --names usms-enrolment-build \
    --query 'projects[0].arn' --output text 2>/dev/null | grep -E '^arn:' || echo not-created)
export USMS_BUILD_SOURCE_TYPE=$(aws codebuild batch-get-projects --names usms-enrolment-build \
    --query 'projects[0].source.type' --output text 2>/dev/null | grep -E '^[A-Z_]+$' || echo not-created)
export USMS_BUILD_IMAGE=docker.io/library/python:3.12-slim-bookworm
export USMS_BUILD_COMPUTE_TYPE=BUILD_GENERAL1_SMALL
export USMS_BUILD_TIMEOUT_MINUTES=15
export USMS_BUILD_LOG_GROUP=/aws/codebuild/usms-enrolment-build

# --- build identity ---
export USMS_BUILD_ROLE=usms-codebuild-role
export USMS_BUILD_ROLE_ARN=$(aws iam get-role --role-name usms-codebuild-role \
    --query 'Role.Arn' --output text)
export USMS_POLICY_CODEBUILD=USMSCodeBuildBase
export USMS_POLICY_CODEBUILD_ARN=arn:aws:iam::000000000000:policy/USMSCodeBuildBase

# --- pipeline ---
export USMS_PIPELINE_NAME=usms-enrolment-pipeline
export USMS_PIPELINE_STAGE_COUNT=$(aws codepipeline get-pipeline --name usms-enrolment-pipeline \
    --query 'length(pipeline.stages)' --output text 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
export USMS_PIPELINE_ROLE=usms-codepipeline-role
export USMS_PIPELINE_ROLE_ARN=$(aws iam get-role --role-name usms-codepipeline-role \
    --query 'Role.Arn' --output text)
export USMS_POLICY_CODEPIPELINE=USMSCodePipelineBase
export USMS_POLICY_CODEPIPELINE_ARN=arn:aws:iam::000000000000:policy/USMSCodePipelineBase

# --- source tree ---
export USMS_APP_SRC_DIR=labs/lab-11-cicd/app
export USMS_BUILDSPEC=labs/lab-11-cicd/app/buildspec.yml
export USMS_RELEASE_TAG=$(tr -d '[:space:]' < labs/lab-11-cicd/app/VERSION)
export USMS_CICD_SUPPORT_PATH=$(sed -n 's/^USMS_CICD_SUPPORT_PATH=//p' \
    outputs/lab-11-support-probe.txt 2>/dev/null || echo unknown)
EOF

grep -n 'export .*=$\|None' configs/lab-11.env || echo "all values populated"
grep -c '^export' configs/lab-11.env
grep -c '\$(' configs/lab-11.env      # 0 - every $(...) ran at write time
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-49-21.png>)
Unquoted heredoc here: every `$(...)` runs **now**. `| grep -E ... || echo not-created` turns absent resources into a populated value instead of `None`.

**Expected:** `all values populated`, `26`.

**Verify:**
```bash
source configs/lab-11.env
printf 'bucket=%s versioning=%s project=%s stages=%s release=%s path=%s\n' \
  "$USMS_PIPELINE_BUCKET" "$USMS_PIPELINE_BUCKET_VERSIONING" \
  "$USMS_BUILD_PROJECT" "$USMS_PIPELINE_STAGE_COUNT" \
  "$USMS_RELEASE_TAG" "$USMS_CICD_SUPPORT_PATH"
```
**Look for:** `versioning=Enabled`, `stages=2` (Path A), `release=r5`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-49-53.png>)

**Commit:**
```bash
git status --short
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-50-07.png>)
**Look for:** nothing under `outputs/`, and no `.env` except `configs/lab-11.env`.

```bash
git add configs/lab-11.env \
        labs/lab-11-cicd \
        policies/trust-codebuild.json policies/trust-codepipeline.json \
        policies/usms-codebuild-policy.json policies/usms-codepipeline-policy.json \
        templates/lab-11-codebuild-project.json templates/lab-11-pipeline.json \
        scripts/utilities/cicd-support-probe.sh \
        scripts/utilities/usms-pack-source.sh \
        scripts/utilities/usms-buildspec-run.sh \
        .gitignore

git status --short
git commit -m "Lab 11: source tree, buildspec, CodeBuild project and two-stage pipeline"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 21-50-31.png>)

**Checkpoint 10** - `configs/lab-11.env` (26 populated exports) committed; nothing from `outputs/` staged.

---

## 8. Verification

```bash
cd "$COURSE_ROOT"

cat > scripts/utilities/verify-lab-11.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 11 artefact. Exit 1 if anything is missing.
# EXPECTED: PASS=46  FAIL=0        (Path A)
#           PASS=38  FAIL=8        (Path B or C - the CodeBuild/CodePipeline block)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-01.env configs/lab-04.env configs/lab-05.env \
         configs/lab-10.env configs/lab-11.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

: "${FLOCI_CONTAINER_NAME:=floci}"
: "${USMS_PIPELINE_BUCKET:=usms-pipeline-artifacts}"
: "${USMS_BUILD_PROJECT:=usms-enrolment-build}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"
: "${USMS_BUILD_ROLE:=usms-codebuild-role}"
: "${USMS_PIPELINE_ROLE:=usms-codepipeline-role}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_CONTAINER:=enrolment-api}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
proj() { aws codebuild batch-get-projects --names "$USMS_BUILD_PROJECT" --query "projects[0].$1" --output text; }
pipe() { aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" --query "pipeline.$1" --output text; }
spec="labs/lab-11-cicd/app/buildspec.yml"

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Earlier-lab dependencies =="
check "configs/lab-04.env present" "test -f configs/lab-04.env"
check "configs/lab-10.env present"  "test -f configs/lab-10.env"
check "ECS cluster $USMS_ECS_CLUSTER exists" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "ECS service $USMS_ENROLMENT_SERVICE exists" \
  "aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].serviceName' --output text | grep -q ."
check "container name is enrolment-api" "test \"$USMS_ENROLMENT_CONTAINER\" = enrolment-api"

echo "== Artifact store =="
check "bucket $USMS_PIPELINE_BUCKET exists" "aws s3api head-bucket --bucket $USMS_PIPELINE_BUCKET"
check "versioning is Enabled" \
  "test \"\$(aws s3api get-bucket-versioning --bucket $USMS_PIPELINE_BUCKET --query Status --output text)\" = Enabled"
check "public access is blocked" \
  "aws s3api get-public-access-block --bucket $USMS_PIPELINE_BUCKET --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text | grep -qi true"
check "source object present" \
  "aws s3api head-object --bucket $USMS_PIPELINE_BUCKET --key source/usms-enrolment-src.zip"
check "source has at least two versions" \
  "test \"\$(aws s3api list-object-versions --bucket $USMS_PIPELINE_BUCKET --prefix source/usms-enrolment-src.zip --query 'length(Versions || \`[]\`)' --output text)\" -ge 2"

echo "== Pipeline identities =="
check "role $USMS_BUILD_ROLE exists" "aws iam get-role --role-name $USMS_BUILD_ROLE"
check "build role trusts codebuild.amazonaws.com" \
  "aws iam get-role --role-name $USMS_BUILD_ROLE --query 'Role.AssumeRolePolicyDocument' --output json | grep -q codebuild.amazonaws.com"
check "policy USMSCodeBuildBase exists" \
  "aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase"
check "USMSCodeBuildBase attached to the build role" \
  "aws iam list-attached-role-policies --role-name $USMS_BUILD_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSCodeBuildBase"
check "role $USMS_PIPELINE_ROLE exists" "aws iam get-role --role-name $USMS_PIPELINE_ROLE"
check "pipeline role trusts codepipeline.amazonaws.com" \
  "aws iam get-role --role-name $USMS_PIPELINE_ROLE --query 'Role.AssumeRolePolicyDocument' --output json | grep -q codepipeline.amazonaws.com"
check "policy USMSCodePipelineBase exists" \
  "aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodePipelineBase"
check "USMSCodePipelineBase attached to the pipeline role" \
  "aws iam list-attached-role-policies --role-name $USMS_PIPELINE_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSCodePipelineBase"
check "pipeline policy scopes iam:PassRole" \
  "grep -q 'iam:PassedToService' policies/usms-codepipeline-policy.json"

echo "== CodeBuild =="
check "project $USMS_BUILD_PROJECT exists"        "proj name | grep -q $USMS_BUILD_PROJECT"
check "project source type is CODEPIPELINE"       "proj source.type | grep -q CODEPIPELINE"
check "project runs as $USMS_BUILD_ROLE"          "proj serviceRole | grep -q $USMS_BUILD_ROLE"
check "project image is standard:7.0"             "proj environment.image | grep -q 'standard:7.0'"

echo "== CodePipeline =="
check "pipeline $USMS_PIPELINE_NAME exists"       "pipe name | grep -q $USMS_PIPELINE_NAME"
check "pipeline has 2 stages"                     "test \"\$(pipe 'length(stages)')\" = 2"
check "stage 1 provider is S3"                    "pipe 'stages[0].actions[0].actionTypeId.provider' | grep -q '^S3$'"
check "stage 2 builds $USMS_BUILD_PROJECT"        "pipe 'stages[1].actions[0].configuration.ProjectName' | grep -q $USMS_BUILD_PROJECT"

echo "== Source tree and scripts =="
check "buildspec.yml present"                     "test -f $spec"
check "buildspec declares version 0.2"            "grep -qE '^version: 0\.2' $spec"
check "buildspec has all four phases"             "test \"\$(grep -cE '^  (install|pre_build|build|post_build):' $spec)\" = 4"
check "artifacts base-directory is dist"          "grep -qE '^  base-directory: dist' $spec"
check "smoke test is valid bash"                  "bash -n labs/lab-11-cicd/app/tests/smoke.sh"
check "usms-pack-source.sh executable and valid"  "test -x scripts/utilities/usms-pack-source.sh && bash -n scripts/utilities/usms-pack-source.sh"
check "usms-buildspec-run.sh executable and valid" "test -x scripts/utilities/usms-buildspec-run.sh && bash -n scripts/utilities/usms-buildspec-run.sh"

echo "== Files and Git hygiene =="
check "configs/lab-11.env present"               "test -f configs/lab-11.env"
check "no empty or None values in lab-11.env"    "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-11.env"
check "codebuild project template is valid JSON"  "python3 -m json.tool templates/lab-11-codebuild-project.json"
check "pipeline template is valid JSON"           "python3 -m json.tool templates/lab-11-pipeline.json"
check "templates contain no unexpanded variables" "! grep -q '[\$]' templates/lab-11-codebuild-project.json templates/lab-11-pipeline.json"
check "all four policy documents are valid JSON" \
  "python3 -m json.tool policies/trust-codebuild.json && python3 -m json.tool policies/trust-codepipeline.json && python3 -m json.tool policies/usms-codebuild-policy.json && python3 -m json.tool policies/usms-codepipeline-policy.json"
check "no secret is tracked"                      "! git ls-files | grep -q '^outputs/'"
check "build output dist/ is git-ignored"         "git check-ignore -q labs/lab-11-cicd/app/dist/build-metadata.json"

echo; echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

Read the failures top-down, not bottom-up.

  Environment block failing        -> Floci is not running, or is in memory mode.
                                      Fix this first; everything below is a consequence.
  Earlier-lab dependencies failing -> re-run verify-lab-04.sh / verify-lab-10.sh.
  Artifact store failing           -> Step 5 and Step 6.
  CodeBuild / CodePipeline block   -> if the support probe said Path B or C, eight
                                      failures here are EXPECTED. Record the path.
  Source tree failing              -> Step 7, Step 8, Step 11, Step 14.
  Hygiene failing                  -> Step 21, and .gitignore.
REMEDY
fi
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-11.sh
bash -n scripts/utilities/verify-lab-11.sh && echo "syntax OK"
./scripts/utilities/verify-lab-11.sh
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 22-00-58.png>)

**Expected:** `PASS=46  FAIL=0` (Path A) - or `PASS=38 FAIL=8` (Path B/C).

**My result:** `PASS=_46_  FAIL=__0__`

```bash
git add scripts/utilities/verify-lab-11.sh
git commit -m "Lab 11: verification script"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 22-03-48.png>)

### 8.1 Known benign failures

| Failure | Benign when | What it means |
|---|---|---|
| The four CodeBuild checks | Step 3 reported Path B or C | Service absent; documents still correct |
| The four CodePipeline checks | Step 3 reported Path B or C | Same |
| source has at least two versions | Step 19 Your turn skipped | Upload once more; do not edit the check |
| project source type is CODEPIPELINE | Step 18 not yet run | Not benign after Step 18 |
| no secret is tracked | Never | Fix `.gitignore`, then `git rm --cached` |
| versioning is Enabled | Never | Return to Step 5 |


---

## 9. Checkpoints Summary

| # | After Step | What must exist | Done |
|---|---|---|---|
| 1 | 3 | `cicd-support-probe.sh`; path in `outputs/lab-11-support-probe.txt` | yes |
| 2 | 6 | `usms-pipeline-artifacts`, versioning proved then cleaned | yes |
| 3 | 8 | `labs/lab-11-cicd/app/` with buildspec, VERSION, src, config, tests | yes |
| 4 | 10 | `usms-codebuild-role` + `USMSCodeBuildBase`; project (source S3) | yes |
| 5 | 13 | One standalone build, ten phases; object under `build/` | yes |
| 6 | 14 | Packer + local runner; local build producing `dist/` | yes |
| 7 | 17 | Two-stage pipeline, Source `Succeeded` | yes |
| 8 | 19 | Artifact whose `build-metadata.json` names the uploaded release | yes |
| 9 | 20 | One deliberate failure diagnosed to a phase, then fixed | yes |
| 10 | 21 | `configs/lab-11.env` with 26 exports, committed | yes |

---

## 10. Floci vs Real AWS - Observed vs Recorded

| Feature | Real AWS | Floci | Status |
|---|---|---|---|
| `create-project` / `batch-get-projects` | Full | Typically full | Implemented |
| Running a build in a container | Managed fleet, cached images | Local Docker; pulls the configured Python image | Floci Limitation |
| Build phase reporting | Every phase timed, `contexts` on failure | Phases usually present; `contexts` often empty | Floci Limitation |
| Build logs to CloudWatch | Complete | Frequently empty | Floci Limitation |
| `create-pipeline` / `get-pipeline` | Full | Document round-trips | Implemented |
| Pipeline execution | Transitions; 1-year history | Build-dependent; may never advance | Floci Limitation |
| S3 source versioning requirement | Enforced | Usually enforced | Floci Limitation |
| Artifact store encryption | KMS | Plain objects | Floci Limitation |
| `PollForSourceChanges` | Polls (deprecated) | Unreliable | Floci Limitation |
| EventBridge trigger on S3 change | Works (CloudTrail data events) | Not modelled end to end | Conceptual / Real AWS |
| IAM enforcement | Enforced | Not enforced | Floci Limitation |
| Build reports / badges | Full | Absent | Conceptual / Real AWS |
| Cross-region artifact stores, manual approval, V2 pipelines | Full | Absent / not modelled | Conceptual / Real AWS |
| CodeCommit source | Closed to new customers (July 2024) | — | Conceptual / Real AWS |
| Build cost | Per build-minute | Free | Floci Limitation |

### 10.1 My evidence (move lines from OBSERVED to RECORDED if on Path B/C)

**OBSERVED**  I saw this happen on my machine:
- [x] the source tree packaged into a zip whose root is the tree's contents
- [x] the buildspec parsed, and its four phases executed in order
- [x] seven smoke tests passing, and failing when a placeholder was not replaced
- [x] a build artifact whose `build-metadata.json` named the release I had just set
- [x] a deliberately broken config failing in `pre_build` and not in `build`
- [x] two versions of one S3 key, the older still retrievable

**RECORDED** - correct and checkable by reading, not enforced here:
- the CodeBuild role's scoping to one log group and one bucket
- the explicit Deny on `usms-student-data`
- the pipeline role's `iam:PassRole`, scoped to one role and one receiving service
- the single project ARN in `codebuild:StartBuild`

**NOT AVAILABLE AT ALL:** automatic triggering from S3 changes, manual approval stages, build reports/test report groups, artifact-store encryption with a customer-managed key.

**My claim, stated honestly:** I built and ran a two-stage pipeline (S3 Source → CodeBuild Build) on Path A in Floci. Both stages reported success for release `r5`. S3 contained no `BuildOutput` object, so I used the local buildspec runner on the exact S3 source version and verified that the resulting artifact’s `build-metadata.json` recorded release `r5` and the matching source version ID.

---

## 11. Lab Assessment Checklist

Tick only with evidence (screenshot number in brackets).

- [x] `cicd-support-probe.sh` run; path recorded in notes (Screenshot 4)
- [x] `usms-pipeline-artifacts` created, versioned, versioning proved by two versions at one key (6, 7)
- [x] Probe objects deleted after reading the danger admonition (8)
- [x] `labs/lab-11-cicd/app/` complete: VERSION, src/, config/, tests/, buildspec.yml (9, 10)
- [x] `buildspec.yml` has `version: 0.2`, four phases, `artifacts.base-directory: dist` (10)
- [x] Nested-heredoc rule stated in notes: *quoted writes text, unquoted writes result* (Section 13, Q5)
- [x] `usms-codebuild-role` + `USMSCodeBuildBase`; explicit Deny explained in one sentence (12)
- [x] `usms-enrolment-build` created from a template with zero unexpanded `$` (13)
- [x] Standalone build run; ten phases read from `batch-get-builds` (15, 16)
- [x] `usms-pack-source.sh` and `usms-buildspec-run.sh` written, `bash -n` clean, used (14, 19)
- [x] Local build producing `dist/` with `buildId: local` (20)
- [x] `usms-codepipeline-role` + `USMSCodePipelineBase`; `iam:PassRole` explained (22)
- [x] Two-stage pipeline from a validated JSON document (23, 24)
- [x] Project converted to `CODEPIPELINE`; resulting `start-build` failure observed (25)
- [x] Execution whose artifact proves the uploaded release — create → perturb → read back (28, 29)
- [x] One deliberate failure diagnosed stage → build → phase → command, then fixed (30–32)
- [x] `configs/lab-11.env` with 26 populated exports (33)
- [x] `verify-lab-11.sh` run; count and benign failures recorded (35)
- [x] `git status --short` checked before staging; nothing from `outputs/` committed (34)
- [x] Five exercises attempted; Exercise 5 readiness file written (36–42)
- [x] Section 15 questions answered in prose in `notes/lab-11-notes.md` (below)
---

## 12. Clean-up Script, Snapshot and Preparation for Lab 12

### 12.1 KEEP and CLEAN UP

| KEEP (consumed by Lab 12) | CLEAN UP |
|---|---|
| `usms-pipeline-artifacts` (and versions) | `probe/versioning.txt` — already deleted in Step 6 |
| `source/usms-enrolment-src.zip` | `usms-probe-delete-me` — deleted by the probe (delete by hand if it survived) |
| `usms-codebuild-role` + `USMSCodeBuildBase` | `labs/.../app/dist/` — git-ignored, regenerated every build |
| `usms-codepipeline-role` + `USMSCodePipelineBase` | `outputs/lab-11-*` — keep until the report is written |
| `usms-enrolment-build`, `usms-enrolment-pipeline` | None. Both resources are used in Lab 12. |
| `labs/lab-11-cicd/app/`, packer, runner, verify script, `configs/lab-11.env` | None. Keep the source, scripts, and config for Lab 12. |

Check the probe project did not survive:
```bash
aws codebuild list-projects --output text | tr '\t' '\n' | grep -x usms-probe-delete-me \
  && aws codebuild delete-project --name usms-probe-delete-me \
  || echo "probe project not present - nothing to clean"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 13-14-33.png>)

### 12.2 End-of-course cleanup script - create it, **DO NOT RUN IT NOW**

> **Read before running any delete command** - *Deletes:* the pipeline, build project, both roles, both policies, every object version in `usms-pipeline-artifacts`, then the bucket. *Depends on it:* all of Lab 12. *Reversible:* No. *Run only at the end of the course.*

```bash
cat > scripts/cleanup/lab-11-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes everything Lab 11 created, dependencies inside-out.
# DO NOT RUN NOW.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
[ -f configs/lab-11.env ] && source configs/lab-11.env

: "${USMS_PIPELINE_BUCKET:=usms-pipeline-artifacts}"
: "${USMS_PIPELINE_NAME:=usms-enrolment-pipeline}"
: "${USMS_BUILD_PROJECT:=usms-enrolment-build}"

cat <<'WARN'
This deletes the Lab 11 pipeline, build project, roles, policies and the ENTIRE
artifact bucket including every object version. Lab 12 depends on all of it.

If Lab 12 has been completed, run scripts/cleanup/lab-12-cleanup.sh FIRST.
WARN

if aws codepipeline get-pipeline --name "$USMS_PIPELINE_NAME" \
     --query 'length(pipeline.stages)' --output text 2>/dev/null | grep -qx '3'; then
  echo "REFUSING: the pipeline still has three stages, so Lab 12 has not been cleaned up." >&2
  exit 1
fi

printf 'Type exactly: DELETE USMS PIPELINE\n> '
read -r CONFIRM
[ "$CONFIRM" = "DELETE USMS PIPELINE" ] || { echo "aborted"; exit 1; }

say() { printf '\n== %s ==\n' "$1"; }

say "pipeline"
aws codepipeline delete-pipeline --name "$USMS_PIPELINE_NAME" 2>/dev/null || true

say "build project"
aws codebuild delete-project --name "$USMS_BUILD_PROJECT" 2>/dev/null || true

say "roles and policies"
for pair in "usms-codepipeline-role:USMSCodePipelineBase" "usms-codebuild-role:USMSCodeBuildBase"; do
  ROLE="${pair%%:*}"; POL="${pair##*:}"
  ARN="arn:aws:iam::000000000000:policy/$POL"
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  for V in $(aws iam list-policy-versions --policy-arn "$ARN" \
               --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version --policy-arn "$ARN" --version-id "$V" 2>/dev/null || true
  done
  aws iam delete-policy --policy-arn "$ARN" 2>/dev/null || true
done

say "artifact bucket: every version, then the bucket"
aws s3api list-object-versions --bucket "$USMS_PIPELINE_BUCKET" \
  --query '[Versions[].[Key,VersionId], DeleteMarkers[].[Key,VersionId]][]' \
  --output text 2>/dev/null |
while read -r KEY VID; do
  [ -n "${KEY:-}" ] && aws s3api delete-object --bucket "$USMS_PIPELINE_BUCKET" \
      --key "$KEY" --version-id "$VID" >/dev/null 2>&1 || true
done
aws s3api delete-bucket --bucket "$USMS_PIPELINE_BUCKET" 2>/dev/null || true

say "done"
echo "Lab 11 resources removed. The ECS platform from Lab 04/05 is untouched."
EOF

chmod +x scripts/cleanup/lab-11-cleanup.sh
bash -n scripts/cleanup/lab-11-cleanup.sh && echo "syntax OK - do NOT run it"
git add scripts/cleanup/lab-11-cleanup.sh && git commit -m "Lab 11: end-of-course cleanup script (not run)"
```

> **Note for end of course:** the exercise resources (`usms-results-build`, the inline policy `USMSResultsBuildLogs`, `usms-events-pipeline-role`, rule `usms-enrolment-source-changed`) are not in this script; `delete-role` on `usms-codebuild-role` will fail while the inline policy exists. Before running it at the end of the course:
> ```bash
> # END OF COURSE ONLY
> # aws events remove-targets --rule usms-enrolment-source-changed --ids StartUsmsEnrolmentPipeline
> # aws events delete-rule --name usms-enrolment-source-changed
> # aws iam delete-role-policy --role-name usms-events-pipeline-role --policy-name USMSEventsStartPipeline
> # aws iam delete-role --role-name usms-events-pipeline-role
> # aws codebuild delete-project --name usms-results-build
> # aws iam delete-role-policy --role-name usms-codebuild-role --policy-name USMSResultsBuildLogs
> ```

End-of-course run order: `lab-12` → **`lab-11`** → `lab-10` → `lab-09` → `lab-08` → `lab-07` → `lab-06` → `lab-05` → `lab-04` → `lab-03` → `lab-02`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 13-15-41.png>)

### 12.3 Architecture now

```
  source tree ──> S3 (versioned) ──> CodePipeline ──> CodeBuild ──> artifact in S3
                                                                         │
                                                          Lab 12 picks up here ──> ECS
  usms-vpc
   ├── public  subnets a,b ── usms-enrolment-alb ── usms-enrolment-tg
   └── private subnets a,b ── usms-enrolment-svc (2-10 tasks, Fargate)
                                   └── container enrolment-api:80
                                         image: still the placeholder, until Lab 12
```

### 12.4 What Lab 12 will consume

| Artefact | From | How Lab 12 uses it |
|---|---|---|
| `usms-enrolment-pipeline` | Step 17 | Adds a third stage with `update-pipeline` |
| `usms-enrolment-build` | Step 10 | Turns on `privilegedMode` for `docker build` |
| `USMSCodeBuildBase` | Step 9 | Version 2 with ECR push, set as default |
| `USMSCodePipelineBase` | Step 15 | Version 2 with `ecs:UpdateService` and a second PassRole |
| `labs/lab-11-cicd/app/` | Step 7 | Adds a Dockerfile |
| `buildspec.yml` | Step 8 | ECR login, build, tag, push, `imagedefinitions.json` |
| `usms-pipeline-artifacts` | Step 5 | Deploy stage reads `BuildOutput` |
| `outputs/lab-11-lab08b-readiness.txt` | Exercise 5 | Read in Lab 12 Step 1 |
| `configs/lab-11.env` | Step 21 | Sourced in Lab 12 Step 2 |

**The thing to be careful about:** `update-pipeline` **replaces the whole document**. Always get → modify → put; putting only the new stage silently deletes the Source and Build stages. Same family as `put-bucket-notification-configuration`, `update-assume-role-policy`, `put-bucket-policy`, `put-bucket-tagging`.

### 12.5 Pre-session checks

```bash
cd "$COURSE_ROOT"
source configs/course.env

./scripts/utilities/verify-lab-11.sh              # PASS=46  FAIL=0  (or 38/8 on Path B or C)
./scripts/utilities/verify-lab-05.sh              # PASS=49  FAIL=0
grep -c '^export' configs/lab-11.env              # 26
docker info >/dev/null 2>&1 && echo "docker reachable"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 13-17-09.png>)

### 12.6 Snapshot before finishing

Floci 2.3.0 lacks the snapshot API. Archive the persisted data while the container is stopped, then start it again.

```bash
(
  docker compose stop floci || exit 1
  trap 'docker compose start floci' EXIT
  umask 077
  tar -czf ~/floci-data-lab-11.tar.gz -C ~ floci-data || exit 1
  tar -tzf ~/floci-data-lab-11.tar.gz >/dev/null || exit 1
  ls -lh ~/floci-data-lab-11.tar.gz
)
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 13-19-38.png>)

### 12.7 Read-ahead notes (five minutes each)

- **Tag vs digest:** a tag (`:stable-alpine`) can be moved to different bytes; a digest (`@sha256:…`) cannot. A production task definition should name a **digest** so a deployment is exactly reproducible and rollback means the same bytes; the cost is readability and that "just pull the latest patch" no longer happens automatically — every change needs a new task definition revision.
- **ECS deploy action:** it takes the service's *current* task definition, swaps only the `image` of the container named in `imagedefinitions.json`, registers a new revision and updates the service. It can express **image changes only**; CPU/memory, environment variables, ports, roles, log config or adding containers need a task-definition change by other means (or a CodeDeploy/`taskdef.json` workflow).
- **`privilegedMode`:** runs the build container privileged so the Docker daemon can run inside it (`docker build`). A privileged container has near-host-level capabilities, so whoever can change the buildspec or trigger the build can do far more than build - control who can push source and start builds.

---

## 13. Reflection and Conclusion

### 13.1 Reflection
At the start of this practical, changing the enrolment service meant typing a command, and the record of what changed was my shell history. At the end, changing it means editing a file, packaging it and uploading it - and the record is an **S3 version ID**, a **build ID**, a **pipeline execution ID** and an **artifact** whose `build-metadata.json` links all three. That chain is the deliverable; the pipeline is just the machine that maintains it.

Two moments stood out. **Step 18**, where handing the project to the pipeline broke the ability to run it directly - a real trade-off made visible rather than a setting flipped unnoticed. **Step 19**, where the proof that the pipeline worked was not a green status but the contents of a zip file: *status is reporting; contents are evidence.* The deliberate failure in Step 20 taught the diagnostic path I will keep using - **stage → build → phase → command** - and the habit of validating locally before pushing.

**Challenges faced.** Rerunning the setup failed because the results build project already existed. Floci also reported successful builds even when the expected ZIPs were missing from S3. During the deliberate smoke-test failure, Floci reported success, so I had to verify the failure locally. The snapshot commands also failed on my Floci version.

**How I resolved them.** I changed the setup to update the existing project on reruns. I downloaded the exact S3 source versions, ran the buildspecs locally, and uploaded the verified ZIPs for the lab checks. For the deliberate failure, I confirmed that the health check failed and ran the `finally` commands with the captured exit code. To back up the lab, I stopped Floci, archived its persisted data, restarted it, and confirmed the enrolment pipeline was still available.


### 13.2 Conclusion
I built a two-stage CI/CD pipeline (S3 Source → CodeBuild Build) for the USMS enrolment service on Floci (Path `A`): a versioned artifact bucket (proved, not assumed), a `buildspec.yml` living in the source tree, least-privilege CodeBuild and CodePipeline roles with a scoped `iam:PassRole`, a CodeBuild project converted to a `CODEPIPELINE` source, a local buildspec runner, and a verification script. I proved end to end that a change to `VERSION` (r3 → r4 → r5) travelled through the pipeline into the build artifact, diagnosed a deliberate `PRE_BUILD` failure, and completed the five exercises, including the `imagedefinitions.json` contract that Lab 12's Deploy stage will consume.

---

## 14. References

1. AWS CodePipeline User Guide — pipeline structure reference; Amazon S3 source action; CodeBuild build action; input and output artifacts; the CodePipeline service role; change-detection methods for an S3 source.
2. AWS CodeBuild User Guide — build specification reference; environment variables in build environments; build phase transitions; Docker images provided by CodeBuild; create a service role; use CodePipeline with CodeBuild.
3. Amazon S3 User Guide — using versioning in S3 buckets; blocking public access.
4. IAM User Guide — granting permission to pass a role to a service; cross-service confused deputy prevention; versioning IAM policies.
5. AWS CodeCommit — availability change, July 2024.
6. AWS CLI Command Reference — `aws codebuild`, `aws codepipeline`, `aws s3api`, `aws events`, `aws cloudtrail`.
7. LocalStack documentation — CodeBuild and CodePipeline providers (emulator behaviour referred to as Floci).
8. YAML 1.2 specification — block scalars; JMESPath specification.
9. DSO303 course documents — Lab 01, Lab 04 Step 15, Lab 05, Lab 09 Step 8, Lab 10 Step 2, Errata 01, Lab 11 practical sheet (© 2026 Norbu Tshering Lepcha).

### Appendix — New JMESPath / CLI patterns used

| Pattern | Meaning | Where |
|---|---|---|
| ``length(Versions \|\| `[]`)`` | Default an absent list to empty before `length` | Step 6, 19, verify |
| ``sort_by(Contents \|\| `[]`, &LastModified)[-1].Key`` | Sort available objects by modification time and select the newest | Step 19, Ex 5 |
| ``phases[?phaseStatus==`FAILED`]`` | Filter a list by exact value | Step 20 |
| `--cli-input-json file://T` | Whole request body from a document | Steps 10, 17, Ex 1 |
| `--query 'projects[0].{A:a,B:b}'` | Reshape into a named table | Steps 10, 13 |
| `\| grep -E '^arn:' \|\| echo not-created` | Absent resource → populated env value | Step 21 |
| `- \|` in YAML | Literal block scalar (heredocs, commands with `": "`) | Step 8 |
| `--source-type-override` / `--artifacts-override` | One-off build of a CODEPIPELINE project | Step 18, Ex 2 |
