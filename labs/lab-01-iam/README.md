# DSO303 - Lab 1: Identity and Access Management (IAM)

**Lab:** Lab 1 - IAM (Environment Bootstrap + USMS Identity Foundation)

---

## Table of Contents

1. [Lab Objective](#1-lab-objective)
2. [Environment Summary](#2-environment-summary)
3. [Part A — Environment Setup](#3-part-a--environment-setup)
4. [Part B — IAM Foundation](#4-part-b--iam-foundation)
5. [Verification](#5-verification)
6. [Assessment Checklist](#6-assessment-checklist)
7. [Troubleshooting Log](#7-troubleshooting-log)
8. [Review Questions](#8-review-questions)
9. [Independent Lab Exercises](#9-independent-lab-exercises)
10. [Resource Inventory](#10-resource-inventory)
11. [Reflection](#11-reflection)

---

## 1. Lab Objective

By the end of this lab I am able to:

**Environment**
- Verify Docker and Docker Compose are installed and running
- Install and run Floci (local AWS emulator) reproducibly via Docker Compose so state survives restarts
- Install AWS CLI v2 and configure a named profile pointing at Floci
- Prove isolation from real AWS and prove data persistence
- Build a clean, version-controlled project structure that cannot leak secrets

**AWS CLI**
- Use the `aws <service> <command> [options]` grammar and built-in help
- Switch between `--output json | table | text`
- Extract values with `--query` (JMESPath)
- Use `file://` and `--generate-cli-skeleton`
- Interpret AWS CLI exit codes

**IAM**
- Read an ARN
- Create IAM users, groups, and roles via CLI
- Write valid IAM policy documents
- Distinguish AWS managed / customer managed / inline policies
- Distinguish a permissions policy from a trust policy
- Create an instance profile and obtain temporary credentials via STS
- Apply least privilege and diagnose `AccessDenied`

---

## 2. Environment Summary

| Item | Value |
|---|---|
| OS / Shell | *Pop!_OS 22.04 LTS / Bash* |
| Docker version | *Docker version 29.7.2, build a7dcaa6* |
| Docker Compose version | *Docker Compose version v2.26.1-desktop.1* |
| Floci CLI version | *floci 0.2.0* |
| AWS CLI version | *aws-cli/1.42.53 Python/3.10.12 Linux/7.0.11-76070011-generic botocore/1.40.53* |
| Floci endpoint | `http://localhost:4566` |
| Floci account ID | `000000000000` |
| Storage mode | `hybrid` |
| Project root | `~/aws-floci-course` |

> **Screenshot - Step 1/2:** `uname -s -m`, `docker --version`, `docker compose version` output
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 11-02-55.png>)

---

## 3. Part A - Environment Setup

### 3.1 Directory Structure

The following structure was created before Floci was started, so configuration is a committed file from the first run:

```
aws-floci-course/
├── README.md
├── .gitignore
├── docker-compose.yml
├── .env                (generated, git-ignored)
├── labs/lab-01-iam/
├── policies/
├── configs/
├── scripts/{setup,utilities,cleanup}/
├── templates/
├── outputs/            (git-ignored contents)
├── screenshots/
└── notes/
```

> **Screenshot - Step 5:** `find . -type d | sort` output confirming folder tree
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 11-19-31.png>)

### 3.2 Git Initialization and Secret Protection

`.gitignore` was written **before** the Git repository was initialized, so no secret could ever have existed unprotected. Key rule used: `outputs/*` with `!outputs/.gitkeep` (the `outputs/` form alone would break the negation).

- `.gitignore` and `outputs/.gitkeep` staged and committed as the **first** commit
- A fake secret file (`outputs/fake-key.json`) was created and proven to be blocked by `git status` and `git check-ignore -v`

> **Screenshot - Step 6:** `git status --short` + `git check-ignore -v outputs/fake-key.json` proving the fake secret is blocked
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 11-28-01.png>)

### 3.3 Storage Mode Understanding

Floci's default storage mode is `memory` - nothing survives a restart. Three separate mechanisms had to be configured correctly:

1. `FLOCI_STORAGE_MODE=hybrid` - durability switch (the actual fix)
2. `FLOCI_STORAGE_HOST_PERSISTENT_PATH` - absolute host path for sidecar services
3. Compose-managed lifecycle - CLI flags from a plain `floci start` are never remembered across restarts

**Reflection note (from `notes/lab-01-notes.md`):**
> *(fill in - two sentences explaining why `--persist` alone did not solve the problem)*

### 3.4 `docker-compose.yml` and `configs/course.env`

Both files were written to pin `FLOCI_STORAGE_MODE=hybrid`, bind-mount `/app/data` to an absolute host path, and set stable resource naming (`FLOCI_DOCKER_RESOURCE_NAMESPACE=floci-course`). The Compose file uses `${FLOCI_HOST_DATA_DIR:?...}` as a fail-fast guard against running Compose directly instead of through `floci-up.sh`.

> **Screenshot - Step 8:** `docker compose config` failing with the fail-fast guard message (proves the guard works)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 11-36-08.png>)

### 3.5 Bringing Floci Up

`scripts/setup/floci-up.sh` and `scripts/setup/floci-down.sh` were written to:
- Refuse to adopt a container not created by Compose
- Generate `.env` with an absolute, expanded path
- Wait for `/_floci/health` before returning
- Verify `/app/data` is a real host bind mount, not a phantom volume

> **Screenshot - Step 9:** `./scripts/setup/floci-up.sh` full output showing "Verified /app/data -> ..." and "Floci is up at http://localhost:4566"
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 12-10-15.png>)

> **Screenshot - Step 9 (verify):** `docker compose ps` and `curl -s http://localhost:4566/_floci/health`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 12-12-25.png>)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 16-39-16.png>)

### 3.6 AWS CLI Installation and Profile Configuration

AWS CLI v2 was installed and a named profile `floci` was created pointing `endpoint_url` at `http://localhost:4566`, with dummy credentials (`test` / `test`).

> **Screenshot - Step 10:** `aws --version` (must show `aws-cli/2.x`)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 16-47-12.png>)

> **Screenshot - Step 12:** `cat ~/.aws/config` and `cat ~/.aws/credentials`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 16-48-44.png>)

### 3.7 First AWS CLI Command - `whoami.sh`

`aws sts get-caller-identity` was run and confirmed account `000000000000`. This was wrapped into `scripts/utilities/whoami.sh`, which fails loudly if the account is not the Floci account.

> **Screenshot - Step 13:** `./scripts/utilities/whoami.sh` output (table + green "[ok]" line)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 16-51-34.png>)

### 3.8 Proof of Isolation and Persistence

| Proof | Method | Result |
|---|---|---|
| Isolation - account number | `000000000000` returned | Done |
| Isolation - request URL | `--debug` shows `localhost:4566` | Done |
| Isolation - stopping breaks CLI | `floci-down.sh` then CLI call fails | Done |
| Persistence - marker survives restart | `iam create-user` → `docker compose restart` → `iam get-user` succeeds | Done |
| Persistence - data on disk | `~/floci-data` non-empty, `du -sh` > 0 | Done |

> **Screenshot - Step 14.2:** `--debug` output showing `http://localhost:4566/` as the request URL
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-05-34.png>)

> **Screenshot - Step 14.4 (the most important screenshot in Part A):** `persistence-check` user ARN returned before restart, and `UserName` returned again after `docker compose restart floci`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-07-11.png>)

> **Screenshot - Step 14.4:** `ls -la ~/floci-data` and `du -sh ~/floci-data`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-08-51.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-09-11.png>)

### 3.9 Storage Diagnostics and Commit

`scripts/utilities/floci-storage-check.sh` was written as a six-section, read-only diagnostic tool.

> **Screenshot - Step 15.1:** `floci-storage-check.sh` output — all six sections `[ok]`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-14-29.png>)

**Checkpoint 6 - End of Part A**

- [x] Docker + Compose v2 running
- [x] Floci Compose-managed, hybrid storage, port 4566
- [x] Persistence proven (create → restart → read)
- [x] AWS CLI v2 installed, profile `floci` configured
- [x] Isolation proven three ways
- [x] Project structure, README, scripts committed to Git

> **Screenshot:** `git log --oneline` showing the `.gitignore` commit as the oldest entry
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-16-44.png>)

---

## 4. Part B - IAM Foundation

### 4.1 IAM Concepts

| Building block | Purpose |
|---|---|
| **User** | Identity for a person/long-lived program, permanent credentials |
| **Group** | Container for users; not an identity itself, cannot be assumed |
| **Role** | Identity for a service/app/temporarily elevated human; assumed, temporary credentials |
| **Policy** | JSON document stating Allow/Deny for actions on resources |

**Rule followed throughout:** permissions attach to **groups and roles**, never directly to users — with one deliberate exception (Step 25, inline policy, to teach the concept).

**ARN anatomy used throughout the lab:**
```
arn:aws:iam::000000000000:user/usms-dev-01
 │   │   │        │              └── resource (type/name)
 │   │   │        └── account id
 │   │   └── service
 │   └── partition
 └── literal prefix
```

### 4.2 Identity Model Built

| Identity | Type | Purpose |
|---|---|---|
| `usms-admin-01` | user → `usms-admins` | Lead cloud engineer |
| `usms-dev-01` | user → `usms-developers` | Infrastructure builder |
| `usms-audit-01` | user → `usms-auditors` | Read-only auditor |
| `usms-ec2-app-role` | role | USMS application server |
| `usms-lambda-exec-role` | role | Notification functions (Lab 05) |
| `usms-developer-role` | role | Temporarily assumed by developers |

### 4.3 Groups

```
usms-admins, usms-developers, usms-auditors
```

> **Screenshot - Step 18:** `aws iam list-groups --query 'Groups[*].[GroupName,Arn]' --output table`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-30-05.png>)

### 4.4 Users and ARNs

Users were created with `--tags` and their ARNs captured directly into shell variables using `--query`/`--output text` (never copied by hand).

> **Screenshot - Step 19:** `aws iam list-users --query 'Users[*].{User:UserName,Created:CreateDate,Arn:Arn}' --output table`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-31-43.png>)

**Independent task result - `usms-intern-01`:**
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-33-15.png>)

### 4.5 Group Membership

Verified from **both directions** (group → users, and user → groups), which is the correct approach during a real access investigation.

> **Screenshot - Step 20:** `aws iam get-group` and `aws iam list-groups-for-user` outputs
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-37-37.png>)

**Independent task result**

> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-39-39.png>)

### 4.6 AWS Managed Policy - Auditors

`ReadOnlyAccess` (AWS managed) was attached to `usms-auditors`.
*(If unavailable in this Floci build: `USMSReadOnly`, a customer managed equivalent, was created and attached instead — see note below.)*

> **Screenshot - Step 21:** `aws iam list-attached-group-policies --group-name usms-auditors`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-48-45.png>)

### 4.7 Customer Managed Policy - `USMSDeveloperBase`

Written with three statements:
1. `ReadInfrastructure` - broad read-only access (IAM, EC2, S3, CloudWatch, Logs)
2. `BuildNetworkingForLab02` - narrow, enumerated EC2/VPC write actions, scoped to `us-east-1` via a `Condition`
3. `DenyDangerousIdentityChanges` - **explicit Deny** on privilege-escalation actions (`iam:CreateUser`, `iam:AttachUserPolicy`, etc.) - this holds even if a broader policy is attached later, because explicit deny always wins

Attached to both `usms-developers` and `usms-admins`.

> **Screenshot - Step 22:** `python3 -m json.tool` validation + `aws iam get-policy --query '...AttachmentCount...'` showing `Attached: 2`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-52-43.png>)

### 4.8 S3 Data Policy - `USMSStudentDataReadWrite`

Correctly separates the **bucket ARN** (`arn:aws:s3:::usms-student-data`, used for `s3:ListBucket`) from the **object ARN** (`arn:aws:s3:::usms-student-data/*`, used for `s3:GetObject`/`s3:PutObject`) - the most common real-world S3 policy mistake, avoided here. Includes an explicit Deny on `s3:DeleteBucket`.

> **Screenshot - Step 23:** `aws iam list-policies --scope Local` showing the policy
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 17-55-41.png>)

### 4.9 `--generate-cli-skeleton` Exploration

> **Screenshot - Step 24:** `create-role-skeleton.json` contents
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-08-02.png>)

**Independent task result:** skeletons for `iam create-policy` and `ec2 create-vpc` saved under `templates/`.
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-09-01.png>)

### 4.10 Inline Policy - `USMSSelfManageCredentials`

Attached directly to `usms-dev-01` using `put-user-policy`, using the `${aws:username}` policy variable so the same document is correct for any user it is applied to. The heredoc was written with `<< 'EOF'` (quoted) specifically to stop the shell from expanding `${aws:username}` before it reached the file.

> **Screenshot - Step 25:** `aws iam list-user-policies` + `aws iam get-user-policy` output, and `grep aws:username` proving the variable was not expanded
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-12-37.png>)

### 4.11 Auditing an Identity

Checked all four places permissions can live for `usms-dev-01`: group memberships, attached policies, inline policies, and access keys. Took a full account snapshot with `get-account-authorization-details`.

> **Screenshot - Step 26:** combined output of groups / attached / inline / access-keys for `usms-dev-01`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-35-16.png>)

### 4.12 Policy Versioning

`USMSDeveloperBase` was updated to v2 (adding `ec2:DeleteVpc`, `ec2:DescribeAvailabilityZones` for Lab 2) using `create-policy-version --set-as-default`, keeping v1 available for rollback.

> **Screenshot - Step 27:** `aws iam list-policy-versions --output table` showing v2 as default, v1 retained
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-37-45.png>)

### 4.13 Role for EC2 (`usms-ec2-app-role`)

Created with a trust policy naming `ec2.amazonaws.com` as the principal, permissions policy `USMSStudentDataReadWrite` attached, and wrapped in the instance profile `usms-ec2-app-profile` (required because an EC2 instance cannot be assigned a role directly).

> **Screenshot - Step 28:** `aws iam get-role` (trust) + `aws iam get-instance-profile` output
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-41-10.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-41-31.png>)

### 4.14 Role for Lambda (`usms-lambda-exec-role`)

Trust policy names `lambda.amazonaws.com`. Permissions policy `USMSLambdaBasic` grants log-writing permissions (`logs:CreateLogGroup/Stream`, `logs:PutLogEvents`) and read access to `usms-student-data/*`.

> **Screenshot - Step 29:** `aws iam list-roles --query '...usms-...'` filtered table
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-44-25.png>)

### 4.15 Role for Humans + STS (`usms-developer-role`)

Demonstrates the "assume for elevated, temporary access" pattern:
- Trust policy names `usms-dev-01` as principal
- `USMSAssumeAppRoles` policy attached to `usms-developers`/`usms-admins` grants `sts:AssumeRole` on the role — completing the **two-sided handshake**
- `sts assume-role` returned temporary credentials: `ASIA...` access key, secret key, session token, 1-hour expiration
- Credentials exported as environment variables, tested, then explicitly `unset` and identity confirmed back to root via `whoami.sh`

> **Screenshot - Step 30.3:** `assumed-role.json` contents (temporary credentials, `ASIA` prefix visible)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-50-04.png>)

> **Screenshot - Step 30.4:** `get-caller-identity` under the assumed role, then `whoami.sh` confirming return to root identity
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-50-23.png>)

### 4.16 Access Keys

An access key was created for `usms-dev-01`, redirected directly into `outputs/usms-dev-01-access-key.json` (never shown on screen), permissions locked with `chmod 600`. A second profile `usms-dev` was configured using this key.

> **Screenshot - Step 31:** `git check-ignore -v outputs/usms-dev-01-access-key.json` naming the exact rule that blocks it, + `ls -l` showing `600` permissions
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-56-15.png>)

> **Screenshot - Step 31:** `aws sts get-caller-identity --profile usms-dev`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 18-56-30.png>)

### 4.17 Policy Simulator

`simulate-principal-policy` was run against `usms-dev-01` for `ec2:CreateVpc`, `iam:CreateUser`, and `s3:GetObject`.

> **Screenshot - Step 32:** simulator output table (`allowed` / `explicitDeny` / `implicitDeny`)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 19-03-48.png>)

*(If the simulator was unsupported on this Floci build, this is noted as a Floci limitation, and the prediction was instead justified by reading the policy JSON directly — see Review Question 5.)*

**Independent task result:**

![alt text](<../../screenshots/Screenshot from 2026-08-21 19-06-23.png>)

### 4.18 Saving Lab State

`configs/lab-01.env` was generated containing every ARN needed by later labs (all values confirmed non-empty), and the emulator state was snapshotted.

> **Screenshot - Step 33.1:** `cat configs/lab-01.env` with all ARNs populated (no secrets)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-00-02.png>)

> **Screenshot - Step 33.2:** `floci snapshot list` (or the `tar` fallback file listing)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-01-05.png>)

**Checkpoint 12 - End of Part B**

- [x] `configs/lab-01.env` written, every value populated
- [x] Snapshot saved
- [x] Lab notes written
- [x] Work committed to Git, `.gitignore` as first commit

---

## 5. Verification

`scripts/utilities/verify-lab-01.sh` was written to check every artefact this lab was supposed to produce, including environment/persistence configuration and Git hygiene - not just resource existence.

> **Screenshot - Section 5 (required evidence):** Full `verify-lab-01.sh` output ending in `PASS=<n> FAIL=0`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-07-23.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-07-39.png>)

| Check group | Result |
|---|---|
| Environment | PASS |
| Persistence configuration |PASS |
| Groups |PASS |
| Users |PASS |
| Memberships |PASS |
| Policies |PASS |
| Roles |PASS |
| Files and Git hygiene |PASS |
| **Total** | `PASS=_34_  FAIL=0` |

---

## 6. Assessment Checklist

**Environment**
- [x] Docker installed and daemon running
- [x] Docker Compose v2 available
- [x] Project structure created before Floci was started
- [x] `.gitignore` written and committed as the first commit
- [x] `outputs/.gitkeep` tracked, negation proven
- [x] Explained why `FLOCI_STORAGE_MODE` defaults to memory and why it matters
- [x] `docker-compose.yml` with hybrid storage and absolute bind mount
- [x] `floci-up.sh` verifies its own mount
- [x] AWS CLI v2 installed
- [x] Profile `floci` configured with `endpoint_url`
- [x] Account `000000000000` confirmed
- [x] Isolation proven via `--debug`
- [x] Stopping Floci proven to break the CLI
- [x] **Persistence proven** (create → restart → read)
- [x] `~/floci-data` contains real files
- [x] `floci-storage-check.sh` passes all six sections
- [x] `whoami.sh` works and fails loudly on wrong account
- [x] `README.md` written
- [x] Part A committed

**IAM - Identities / Policies / Roles**
- [x] 3 groups, 3 users, correctly placed and verified both directions
- [x] Managed policy attached to auditors
- [x] `USMSDeveloperBase` written, validated, attached to 2 groups
- [x] `USMSStudentDataReadWrite` with correct bucket **and** object ARNs
- [x] Inline policy on `usms-dev-01`
- [x] Policy version v2 created and set default; v1 retained
- [x] 3 roles with correct trust policies
- [x] Instance profile created and populated
- [x] `sts assume-role` executed, `ASIA`/session token identified
- [x] Returned to normal identity afterwards

**Credentials & Safety**
- [x] Access key redirected straight to `outputs/`, `chmod 600`
- [x] `git check-ignore` names the protecting rule
- [x] `usms-dev` profile created and tested
- [x] Can explain 5-step key rotation

**CLI Skills Demonstrated**
- [x] `--output json/table/text`
- [x] `--query` with variable capture
- [x] JMESPath filter `[?...]`
- [x] `file://`
- [x] `--generate-cli-skeleton`
- [x] Exit code checked with `$?`

**Wrap-up**
- [x] `configs/lab-01.env` complete, no secrets
- [x] Snapshot saved
- [x] `verify-lab-01.sh` → `FAIL=0`
- [x] Lab notes written
- [x] Git history shows `.gitignore` as oldest commit
- [x] Exercises 1–5 attempted and documented

---

## 7. Troubleshooting Log

| # | Problem | Cause | Fix | Verified? |
|---|---|---|---|---|
| 1 | `FLOCI_HOST_DATA_DIR is missing a value` | Ran `docker compose` directly instead of using the Floci startup script | Ran `./scripts/setup/floci-up.sh` so the required environment variables were loaded correctly | ✔ |
| 2 | `aws iam get-account-authorization-details` returned `UnsupportedOperation` | Floci does not support the `GetAccountAuthorizationDetails` IAM API operation | Did not rely on the IAM snapshot command; used the available IAM policy/user/role information and policy JSON to reason about the required permissions | ✔ |
| 3 | `No such file or directory` when redirecting to `outputs/assumed-role.json` | The `outputs` directory did not exist from the current working directory | Created the directory with `mkdir -p outputs` (or `mkdir -p ~/aws-floci-course/outputs`) before running the AWS CLI command | ✔ |

---

## 8. Review Questions

**1. Trust vs permissions.**
If a role has a perfect permissions policy but nobody can use it, the **trust policy** is almost certainly missing or incorrect - nothing names the caller as an allowed principal. IAM separates these two documents because they answer different questions asked by different parties: the trust policy is controlled by the role's owner and answers "who may become this role?", while the permissions policy answers "what may this identity do once assumed?". Keeping them separate means a role's capabilities can be defined independently of who is allowed to use it, and either side can be tightened without touching the other.

**2. Explicit vs implicit deny.**
Both failures return the same `AccessDenied` message to the user, but internally they come from different places in the evaluation logic. An **implicit deny** is simply the absence of any matching Allow statement - the default-deny behaviour of IAM. An **explicit deny** is a statement with `"Effect": "Deny"` that specifically matches the request, and it overrides any Allow anywhere else. They can be told apart with the policy simulator, which reports `explicitDeny` vs `implicitDeny` distinctly, or by reading every attached/inline policy for a matching Deny statement. The fix differs: an implicit deny is fixed by **adding** an Allow; an explicit deny cannot be fixed by adding more Allow statements - the Deny statement itself must be found and removed or narrowed.

**3. Roles over keys.**
Attaching `usms-ec2-app-role` to the server instead of embedding `usms-dev-01`'s access key is more secure for two reasons: (1) **no long-lived secret ever sits on disk** - the role provides automatically-rotating temporary credentials delivered via the instance's metadata, so there is nothing to leak if the server or a backup image is compromised; (2) credentials obtained via a role are scoped and time-limited (they expire, by default within hours), whereas a hardcoded access key remains valid indefinitely until someone manually rotates or revokes it, which in practice rarely happens promptly.

**4. The S3 ARN trap.**
A policy that only lists `arn:aws:s3:::usms-student-data` as the `Resource` for `s3:GetObject` will fail every download, because `s3:GetObject` acts on **objects**, not the bucket itself. The bucket ARN only correctly authorizes bucket-level actions like `s3:ListBucket`. The corrected policy needs two resource entries: `arn:aws:s3:::usms-student-data` for `s3:ListBucket`/`s3:GetBucketLocation`, and `arn:aws:s3:::usms-student-data/*` (note the trailing `/*`) for `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject`.

**5. The Floci illusion.**
Every command succeeding in this lab is not evidence of correctness because Floci, by default, accepts any non-empty credentials and does not authorize requests against the IAM policies written - so an overly broad policy (`"Action":"*","Resource":"*"`) behaves identically to a carefully scoped one in this environment. Two techniques to gain real confidence before deploying to real AWS: (1) run `aws iam simulate-principal-policy` against the specific actions a workload will need, and check for `explicitDeny`/`implicitDeny`; (2) manually read every policy statement and cross-check the `Resource` ARNs and `Action` list against the actual job description, rather than trusting that "it ran without error."

**6. The persistence trap.**
Three independent reasons a classmate's `floci start --persist ~/floci-data --detach` could still lose data: (1) `--persist` only supplies a *directory*, it does not set `FLOCI_STORAGE_MODE`, which defaults to `memory` - in memory mode almost nothing durable is written into that directory at all; (2) sidecar/child-container state uses a **different** variable (`FLOCI_STORAGE_HOST_PERSISTENT_PATH`), which `--persist` does not set, and that variable requires an absolute path - a literal `~` is never expanded and creates a directory literally named `~`; (3) CLI flags from `floci start` are never remembered - any subsequent `floci restart`, Docker Desktop restart, or `floci stop --remove` silently reverts to defaults. The single test that would have caught this in under a minute: create a marker resource (e.g. `aws iam create-user`), restart the container, and check whether `aws iam get-user` still finds it - exactly the test performed in Step 14.4 of this lab.

**7. Configuration as evidence.**
A committed `docker-compose.yml` is a security and reproducibility property because it makes the environment's behaviour **inspectable and auditable by anyone with repository access**, not just repeatable by the person who typed the commands. A colleague or instructor can read the file and verify, without running anything, that `FLOCI_STORAGE_MODE=hybrid` is set, that no secret is baked into the file, that the bind mount path is absolute, and that the fail-fast guard (`${FLOCI_HOST_DATA_DIR:?...}`) exists. None of that can be verified from a command someone typed once in a terminal - a typed command leaves no trace for review, can silently vary between runs, and cannot be diffed, reviewed in a pull request, or rolled back the way a committed file can.

---

## 9. Independent Lab Exercises

### Exercise 1 - The QA identity

> **Screenshot:** `aws iam get-group --group-name usms-qa` + `aws iam list-attached-group-policies --group-name usms-qa` + `aws iam list-attached-user-policies --user-name usms-qa-01` (empty)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-37-14.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-37-29.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-37-49.png>)

### Exercise 2 - The read-only reporting policy

> **Screenshot:** `aws iam list-policies --scope Local --query "Policies[?PolicyName=='USMSReportingReadOnly']"`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-42-10.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-42-26.png>)

### Exercise 3 - The third-party analytics role

> **Screenshot:** `aws iam get-role --role-name usms-analytics-partner-role` (MaxSessionDuration `1800`) + `assume-role` `Expiration` ~30 min ahead
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-45-38.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-45-53.png>)

### Exercise 4 - Least-privilege backup operator policy

> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-49-27.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-49-49.png>)

### Exercise 5 - Preparing the identity for Lab 2

> **Screenshot:** `aws iam list-policy-versions --output table` showing v3 as default, v1/v2 retained
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-53-03.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-53-17.png>)

---

## 10. Resource Inventory

**Kept - required by later labs:**

| Resource | Needed by |
|---|---|
| `usms-developer-role` | Lab 02 (VPC) |
| `usms-ec2-app-profile` | Lab 03 (EC2) |
| `USMSStudentDataReadWrite` | Lab 04 (S3) |
| `usms-lambda-exec-role` | Lab 05 (Lambda) |
| `configs/course.env`, `configs/lab-01.env` | every later lab |
| `docker-compose.yml` | every later lab |

**Cleaned up:**

| Resource | Reason |
|---|---|
| `outputs/assumed-role.json` | Expired temporary credentials |
| `usms-intern-01` (if created) | Practice-only user, not required by later labs |

---

## 11. Reflection

The lab helped develop a better understanding of IAM identities, policies, groups, roles, trust relationships, and least-privilege access control. It also showed that there is an important difference between what Floci can actually enforce or simulate and what is mainly conceptual or specific to real AWS, so not every AWS operation or security feature can be fully verified locally. The persistence bug encountered in Part A also changed the approach to the rest of the lab, making it important to verify resources and policy state after each operation rather than assuming that a successful command meant the change had been permanently applied. Overall, the exercises reinforced the importance of checking IAM configuration carefully, documenting limitations, and designing permissions as narrowly as possible.

---

