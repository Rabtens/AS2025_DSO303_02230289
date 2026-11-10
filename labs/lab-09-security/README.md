# DSO303 - Lab 09: Securing the USMS Application with IAM Roles and Security Groups
---

## Table of Contents

1. [Lab Overview](#1-lab-overview)
2. [Learning Objectives](#2-learning-objectives)
3. [Prerequisites](#3-prerequisites)
4. [Step-by-Step Implementation](#4-step-by-step-implementation)
5. [Verification](#5-verification)
6. [Independent Lab Exercises](#6-independent-lab-exercises)
7. [Reflection](#7-reflection)
8. [Review Questions](#8-review-questions)

---

## 1. Lab Overview

This lab performs a security review of the USMS system built across Labs 01-06, asking two independent questions about it:

```
WHO can call WHAT?              the identity axis      IAM roles and policies
WHAT can reach WHAT?            the network axis       security groups and routing
```

**Key principle:** Floci does not enforce IAM policies or security groups. Nothing in this lab can be proven by watching a command fail — everything is proven by **reading configuration** and reasoning about it.

---

## 2. Learning Objectives

- State the two independent axes of access control in AWS.
- Describe AWS's IAM policy evaluation order.
- Read a trust policy vs. an identity policy.
- Explain the confused deputy problem and close it with `aws:SourceAccount` / `aws:SourceArn`.
- Scope `iam:PassRole` with an `iam:PassedToService` condition.
- Create and use a permissions boundary correctly.
- Use a session policy and compute an effective-permissions intersection.
- Rotate an access key with zero downtime (4-step procedure).
- Require IMDSv2 on an EC2 instance.
- Audit security groups for ingress/egress findings.
- Write egress rules, including group-referenced and prefix-list destinations.
- Prove a negative (unreachability) from multiple independent controls.

---

## 3. Prerequisites

- Labs 01, 02, 03, 04, 05, 06 complete with their verification scripts passing.
- `outputs/usms-app-key.pem` present, `chmod 600`, and `usms-dev` AWS CLI profile working.
- Errata 01 applied.
- Floci running under Docker Compose, `FLOCI_STORAGE_MODE=hybrid`.
- `jq`, `python3`, `docker` available.

### Prerequisite Check

```bash
cd ~/aws-floci-course
for t in jq python3 docker; do printf '%-10s ' "$t"; command -v "$t" || echo MISSING; done
aws --version
./scripts/utilities/floci-storage-check.sh | tail -2
aws sts get-caller-identity --profile usms-dev --query 'Arn' --output text
ls -l outputs/usms-app-key.pem
```

![alt text](<../../screenshots/Screenshot from 2026-11-09 11-55-17.png>)
---

## 4. Step-by-Step Implementation

> Run every command from `aws-floci-course/` unless stated otherwise.

### Step 1 - Resume the environment and load seven env files

**Purpose:** Bring Floci up and load everything the previous six labs recorded.

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env
source configs/lab-05.env
source configs/lab-06.env

./scripts/utilities/whoami.sh

printf '%-28s %s\n' \
  "account"              "$USMS_ACCOUNT_ID" \
  "region"               "$AWS_REGION_COURSE" \
  "dev user"             "$USMS_DEV_USER" \
  "admin user"           "$USMS_ADMIN_USER" \
  "developer role"       "$USMS_ROLE_DEVELOPER" \
  "ec2 role"             "$USMS_ROLE_EC2" \
  "lambda role"          "$USMS_ROLE_LAMBDA" \
  "instance profile"     "$USMS_INSTANCE_PROFILE" \
  "bucket name (policy)" "$USMS_BUCKET_NAME" \
  "vpc"                  "$USMS_VPC_ID" \
  "app sg"               "$USMS_APP_SG" \
  "db sg"                "$USMS_DB_SG" \
  "enrolment sg"         "$USMS_ENROLMENT_SG" \
  "alb sg"                "$USMS_ALB_SG" \
  "s3 endpoint"          "$USMS_S3_ENDPOINT" \
  "web instance"         "$USMS_WEB_INSTANCE" \
  "db instance"          "$USMS_DB_INSTANCE"
```

**Verify:** All seventeen values non-empty.

![alt text](<../../screenshots/Screenshot from 2026-11-09 11-57-11.png>)

---

### Step 2 - Record the security baseline before you change anything

**Purpose:** Capture what every earlier verification script says today, so Step 18 can prove nothing broke.

```bash
{
  echo "== baseline recorded $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))') =="
  for s in 02 03 04 05 06; do
    printf '%-10s ' "lab-$s"
    ./scripts/utilities/verify-lab-$s.sh 2>/dev/null | tail -1
  done
} | tee outputs/lab-09-pre-verify.txt
```

```bash
./scripts/utilities/verify-lab-04.sh 2>/dev/null | grep FAIL || echo "no failures in 04"
```

**Verify:** `FAIL=0` from Labs 02, 03, 05, 06; Lab 04 either `FAIL=0` or exactly the one documented failure.

![alt text](<../../screenshots/Screenshot from 2026-11-09 12-00-03.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-09 12-00-41.png>)

**Checkpoint 1**
```
Ready to review
 ├── Floci running under Compose, storage mode hybrid
 ├── seven env files sourced, seventeen values non-empty
 ├── five verification scripts run, all summary lines captured
 └── outputs/lab-09-pre-verify.txt written
```

---

### Step 3 - Probe what this Floci build supports for policy evaluation and rule management

**Purpose:** Find out which parts of IAM/EC2 evaluation surface are implemented before relying on them.

```bash
probe() {
  printf '%-52s ' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "SUPPORTED"; else echo "not available"; fi
}

echo "== IAM: reading what exists =="
probe "iam list-roles"                       "aws iam list-roles --max-items 1"
probe "iam list-policies --scope Local"      "aws iam list-policies --scope Local --max-items 1"
probe "iam get-role"                         "aws iam get-role --role-name $USMS_ROLE_EC2"
probe "iam list-attached-role-policies"      "aws iam list-attached-role-policies --role-name $USMS_ROLE_EC2"
probe "iam get-account-authorization-details" "aws iam get-account-authorization-details --max-items 1"

echo "== IAM: changing what exists =="
probe "iam update-assume-role-policy (skel)" "aws iam update-assume-role-policy --generate-cli-skeleton"
probe "iam create-role --permissions-boundary (skel)" "aws iam create-role --generate-cli-skeleton"
probe "iam put-role-permissions-boundary (skel)" "aws iam put-role-permissions-boundary --generate-cli-skeleton"

echo "== IAM: evaluating what exists =="
probe "iam simulate-principal-policy" \
  "aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::$USMS_ACCOUNT_ID:role/$USMS_ROLE_EC2 --action-names s3:GetObject"
probe "accessanalyzer list-analyzers"        "aws accessanalyzer list-analyzers"
probe "sts assume-role --policy (session policy)" "aws sts assume-role --generate-cli-skeleton"

echo "== IAM: credentials =="
probe "iam list-access-keys"                 "aws iam list-access-keys --user-name $USMS_DEV_USER"
probe "iam get-access-key-last-used"         "aws iam get-access-key-last-used --generate-cli-skeleton"
probe "iam get-credential-report"            "aws iam get-credential-report"

echo "== EC2: security group rules =="
probe "ec2 describe-security-group-rules"    "aws ec2 describe-security-group-rules --max-items 1"
probe "ec2 authorize-security-group-egress (skel)" "aws ec2 authorize-security-group-egress --generate-cli-skeleton"
probe "ec2 revoke-security-group-egress (skel)"    "aws ec2 revoke-security-group-egress --generate-cli-skeleton"
probe "ec2 describe-prefix-lists"            "aws ec2 describe-prefix-lists"
probe "ec2 describe-network-interfaces"      "aws ec2 describe-network-interfaces --max-items 1"

echo "== EC2: instance metadata options =="
probe "ec2 modify-instance-metadata-options (skel)" "aws ec2 modify-instance-metadata-options --generate-cli-skeleton"
probe "ec2 describe-instances MetadataOptions" \
  "aws ec2 describe-instances --instance-ids $USMS_WEB_INSTANCE --query 'Reservations[0].Instances[0].MetadataOptions'"
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-20-29.png>)

**Verify:** Note which path applies - A (full), B (management only), or C (no IAM writes).

**My support path:** **Path B (management only).** Every *management* call this lab needs is supported: `list-roles`/`list-policies`, `create-role`, `update-assume-role-policy`, `put-role-permissions-boundary`, `sts assume-role`, `list-access-keys`, `describe-security-group-rules`, `authorize/revoke-security-group-egress`, `describe-prefix-lists`. (`modify-instance-metadata-options` only *looked* supported: the probe used `--generate-cli-skeleton`, which the CLI answers locally. The real call returns `UnsupportedOperation`, see Step 11.) *Evaluation* is not real: `simulate-principal-policy` answers, but it returns `implicitDeny` for `s3:GetObject` on `usms-ec2-app-role` even though that role carries `USMSStudentDataReadWrite`, which allows it. `accessanalyzer`, `get-credential-report` and `get-account-authorization-details` are not available. (The `iam get-role` probe reports "not available" only because `$USMS_ROLE_EC2` holds a full ARN and `--role-name` expects a name. `aws iam get-role --role-name usms-ec2-app-role` works.) So I can change and read configuration, but every proof must come from reading documents, not from a deny.

---

### Step 4 - Inventory every identity in the account

**Purpose:** Produce the complete identity inventory (read-only).

**Part 1 - human-readable pass**

```bash
echo "== Roles in this account =="
aws iam list-roles \
  --query 'sort_by(Roles, &RoleName)[].{Role:RoleName,Created:CreateDate,MaxSession:MaxSessionDuration}' \
  --output table

echo
echo "== Users, and how many access keys each one has =="
for u in $(aws iam list-users --query 'Users[].UserName' --output text); do
  n=$(aws iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)' --output text)
  printf '  %-18s access keys: %s\n' "$u" "$n"
done

echo
echo "== Customer managed policies =="
aws iam list-policies --scope Local \
  --query 'sort_by(Policies, &PolicyName)[].{Policy:PolicyName,Default:DefaultVersionId,Attached:AttachmentCount}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-22-33.png>)

**Part 2 - machine-readable inventory**

```bash
python3 - << 'PY' > outputs/lab-09-identity-inventory.json
import json, subprocess

def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"],
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        return None
    return json.loads(out.stdout)

roles = (aws("iam", "list-roles") or {}).get("Roles", [])
inventory = []

for r in roles:
    name = r["RoleName"]
    detail = {
        "role": name,
        "arn": r.get("Arn"),
        "maxSessionDuration": r.get("MaxSessionDuration"),
        "permissionsBoundary": (r.get("PermissionsBoundary") or {}).get("PermissionsBoundaryArn"),
        "trustPolicy": r.get("AssumeRolePolicyDocument"),
        "attachedPolicies": [],
        "inlinePolicies": [],
    }
    att = aws("iam", "list-attached-role-policies", "--role-name", name) or {}
    for p in att.get("AttachedPolicies", []):
        pol = aws("iam", "get-policy", "--policy-arn", p["PolicyArn"]) or {}
        ver = (pol.get("Policy") or {}).get("DefaultVersionId")
        doc = None
        if ver:
            v = aws("iam", "get-policy-version",
                    "--policy-arn", p["PolicyArn"], "--version-id", ver) or {}
            doc = (v.get("PolicyVersion") or {}).get("Document")
        detail["attachedPolicies"].append(
            {"name": p["PolicyName"], "arn": p["PolicyArn"], "version": ver, "document": doc})

    inl = aws("iam", "list-role-policies", "--role-name", name) or {}
    for pn in inl.get("PolicyNames", []):
        d = aws("iam", "get-role-policy", "--role-name", name, "--policy-name", pn) or {}
        detail["inlinePolicies"].append({"name": pn, "document": d.get("PolicyDocument")})

    inventory.append(detail)

print(json.dumps(inventory, indent=2, default=str))
PY

python3 -m json.tool outputs/lab-09-identity-inventory.json > /dev/null && echo "valid JSON"
python3 -c "
import json
d = json.load(open('outputs/lab-09-identity-inventory.json'))
print(f'{len(d)} roles inventoried')
for r in d:
    print(f\"  {r['role']:<30} policies={len(r['attachedPolicies'])+len(r['inlinePolicies'])} boundary={r['permissionsBoundary'] or '-'}\")
"
```

**Verify:** Every `boundary` column reads `-` (no role has a permissions boundary yet).

![](<../../screenshots/Screenshot from 2026-11-09 13-28-34.png>)

**My turn:** Compare `usms-ec2-app-role`'s trust policy against `usms-developer-role`'s trust policy - record two sentences on the structural difference (in report notes).

**Notes:** `usms-ec2-app-role` trusts a **service principal** (`"Service": "ec2.amazonaws.com"`), so the credentials are handed to whatever EC2 instance the role is attached to through an instance profile, and no person ever assumes it. `usms-developer-role` trusts an **AWS principal**, the specific IAM user `arn:aws:iam::000000000000:user/usms-dev-01`, so only that human, signed in with their own keys, can call `sts:AssumeRole` on it. Neither trust policy has a `Condition` block. For the EC2 role that means any instance given the profile gets the role, and for the developer role there is no MFA requirement.

---

### Step 5 - Build the IAM audit script

**Purpose:** Turn the inventory into findings (wildcard actions, wildcard resources, unscoped `iam:PassRole`, unconditioned trust). Read-only.

```bash
cat > scripts/utilities/usms-iam-audit.sh << 'EOF'
#!/usr/bin/env bash
# USMS IAM audit. Reports findings; changes nothing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

INVENTORY="${1:-outputs/lab-09-identity-inventory.json}"

if [ ! -f "$INVENTORY" ]; then
  echo "no inventory at $INVENTORY - run Lab 09 Step 4 part 2 first" >&2
  exit 2
fi

python3 - "$INVENTORY" << 'PY'
import json, sys

MUTATING = ("Create", "Delete", "Put", "Update", "Modify", "Attach", "Detach",
            "Write", "Terminate", "Run", "Revoke", "Authorize", "Set", "Remove")

def as_list(x):
    if x is None:
        return []
    return x if isinstance(x, list) else [x]

def statements(doc):
    if not doc:
        return []
    if isinstance(doc, str):
        try:
            doc = json.loads(doc)
        except Exception:
            return []
    return as_list(doc.get("Statement"))

def is_mutating(action):
    if action == "*":
        return True
    verb = action.split(":", 1)[-1]
    return any(verb.startswith(p) for p in MUTATING)

roles = json.load(open(sys.argv[1]))
high = med = 0
lines = []

for r in roles:
    name = r["role"]
    findings = []

    docs = [(p["name"], p.get("document")) for p in r.get("attachedPolicies", [])]
    docs += [(p["name"], p.get("document")) for p in r.get("inlinePolicies", [])]

    for pname, doc in docs:
        for st in statements(doc):
            if st.get("Effect") != "Allow":
                continue
            actions = as_list(st.get("Action"))
            resources = as_list(st.get("Resource"))
            has_cond = bool(st.get("Condition"))

            for a in actions:
                if a == "*":
                    findings.append(("HIGH", f"{pname}: Action \"*\" - unbounded"))
                elif a.endswith(":*"):
                    findings.append(("MED", f"{pname}: service wildcard {a}"))

                if a.lower() == "iam:passrole" or a == "*":
                    if "*" in resources and not has_cond:
                        findings.append(
                            ("HIGH", f"{pname}: iam:PassRole on Resource \"*\" with no Condition"))
                    elif "*" in resources:
                        findings.append(
                            ("MED", f"{pname}: iam:PassRole on Resource \"*\", conditioned"))

                if "*" in resources and is_mutating(a) and a != "*":
                    findings.append(("MED", f"{pname}: {a} on Resource \"*\""))

    for st in statements(r.get("trustPolicy")):
        princ = st.get("Principal") or {}
        svc = as_list(princ.get("Service"))
        aws_p = as_list(princ.get("AWS"))
        if "*" in aws_p:
            findings.append(("HIGH", "trust policy: Principal AWS \"*\" - anyone may assume"))
        if svc and not st.get("Condition"):
            findings.append(
                ("HIGH", f"trust policy: service principal {','.join(svc)} with NO Condition "
                         "(confused deputy)"))

    boundary = r.get("permissionsBoundary")
    lines.append(f"{name}")
    lines.append(f"    permissions boundary : {boundary or 'NONE'}")
    if not boundary:
        findings.append(("MED", "no permissions boundary"))

    if not findings:
        lines.append("    ok   no findings")
    else:
        seen = set()
        for sev, text in findings:
            if (sev, text) in seen:
                continue
            seen.add((sev, text))
            lines.append(f"    {sev:<4} {text}")
            if sev == "HIGH":
                high += 1
            else:
                med += 1
    lines.append("")

print("== USMS IAM audit ==")
print()
print("\n".join(lines))
print(f"HIGH={high}  MED={med}  roles={len(roles)}")
sys.exit(1 if high else 0)
PY
EOF

chmod +x scripts/utilities/usms-iam-audit.sh
bash -n scripts/utilities/usms-iam-audit.sh && echo "syntax OK"
./scripts/utilities/usms-iam-audit.sh | tee outputs/lab-09-iam-findings.txt
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-33-26.png>)

```bash
./scripts/utilities/usms-iam-audit.sh >/dev/null; echo "exit code: $?"
```

**Expected:** Four `HIGH` findings (unconditioned trust policies), exit code `1`.

![alt text](<../../screenshots/Screenshot from 2026-11-09 13-38-18.png>)

**Checkpoint 2**
```
Identity inventory complete
 ├── outputs/lab-09-identity-inventory.json
 ├── outputs/lab-09-iam-findings.txt   HIGH=4  MED=5
 ├── scripts/utilities/usms-iam-audit.sh
 └── finding: no role in this account has a permissions boundary
```

---

### Step 6 - Read the transcripts policy, and find the verb that should not be there

**Purpose:** Investigate `USMSStudentDataReadWrite`, shared by two roles, for over-broad grants.

**Part 1 - read the policy**

```bash
POLICY_ARN="arn:aws:iam::${USMS_ACCOUNT_ID}:policy/USMSStudentDataReadWrite"

DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
  --query 'Policy.DefaultVersionId' --output text)

echo "default version: $DEFAULT_VERSION"

aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$DEFAULT_VERSION" \
  --query 'PolicyVersion.Document' --output json | tee outputs/lab-09-transcripts-rw.json

echo
echo "== who carries it =="
aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" \
  --query '{Roles:PolicyRoles[].RoleName,Users:PolicyUsers[].UserName,Groups:PolicyGroups[].GroupName}' \
  --output json
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-39-24.png>)

**Part 2 - does the bucket exist yet?**

```bash
aws s3api head-bucket --bucket "${USMS_BUCKET_NAME:-usms-student-data}" 2>&1 | head -3
echo "head-bucket exit code: ${PIPESTATUS[0]}"
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-50-10.png>)

**Verify:** Non-zero exit code expected (bucket created in Lab 10).

**Your turn:** Note the exact actions the enrolment API needs vs. what the registry's upload workflow needs, and name the one action that differs.

**Notes:** The **enrolment API** only *reads* transcripts: `s3:ListBucket` (and `s3:GetBucketLocation`) on the bucket plus `s3:GetObject` on `usms-student-data/*`. The **registry's upload workflow** needs those same read actions plus `s3:PutObject` to upload a transcript. The one action that differs is **`s3:PutObject`**. `s3:DeleteObject`, which `USMSStudentDataReadWrite` also grants, is needed by *neither* workflow. That is the verb that should not be there. The policy is shared by `usms-ec2-app-role`, `usms-ecs-task-role` and `usms-eks-node-role`, so all three can delete transcripts.

---

### Step 7 - Create the read-only policy and the role that carries it

**Purpose:** Split the transcripts policy; fix the confused-deputy problem on `usms-ecs-task-role`.

**Part 1 - the read-only policy document**

```bash
cat > policies/usms-student-data-ro-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListTheTranscriptsBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::usms-student-data"
    },
    {
      "Sid": "ReadTranscriptObjectsOnly",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::usms-student-data/*"
    },
    {
      "Sid": "NeverWriteAndNeverDelete",
      "Effect": "Deny",
      "Action": [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:DeleteBucket",
        "s3:PutBucketPolicy"
      ],
      "Resource": [
        "arn:aws:s3:::usms-student-data",
        "arn:aws:s3:::usms-student-data/*"
      ]
    }
  ]
}
EOF

python3 -m json.tool policies/usms-student-data-ro-policy.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-student-data-ro-policy.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-51-54.png>)

**Part 2 - create the policy**

```bash
RO_POLICY_ARN=$(aws iam create-policy \
  --policy-name USMSStudentDataReadOnly \
  --description "Read-only access to the USMS transcripts bucket. Explicitly denies every write." \
  --policy-document file://policies/usms-student-data-ro-policy.json \
  --tags Key=Project,Value=USMS Key=Lab,Value=05 Key=Tier,Value=data \
  --query 'Policy.Arn' --output text)

echo "RO_POLICY_ARN = $RO_POLICY_ARN"
```

![alt text](<../../screenshots/Screenshot from 2026-11-09 13-53-18.png>)

**Part 3 - the scoped trust policy**

```bash
cat > policies/trust-ecs-tasks-scoped.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcsTasksMayAssumeThisRoleForThisAccountOnly",
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${USMS_ACCOUNT_ID}" },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:ecs:${AWS_REGION_COURSE}:${USMS_ACCOUNT_ID}:*"
        }
      }
    }
  ]
}
EOF

python3 -m json.tool policies/trust-ecs-tasks-scoped.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/trust-ecs-tasks-scoped.json
cat policies/trust-ecs-tasks-scoped.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-59-49.png>)

**Part 4 - the new role**

```bash
READER_ROLE_ARN=$(aws iam create-role \
  --role-name usms-transcripts-reader-role \
  --description "Read-only transcripts access for a future USMS reporting task" \
  --assume-role-policy-document file://policies/trust-ecs-tasks-scoped.json \
  --max-session-duration 3600 \
  --tags Key=Project,Value=USMS Key=Lab,Value=05 Key=Tier,Value=data \
  --query 'Role.Arn' --output text)

echo "READER_ROLE_ARN = $READER_ROLE_ARN"

aws iam attach-role-policy \
  --role-name usms-transcripts-reader-role \
  --policy-arn "$RO_POLICY_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 13-59-49.png>)

**Part 5 - fix the trust policy on the existing task role**

```bash
aws iam get-role --role-name "$USMS_ECS_TASK_ROLE" \
  --query 'Role.AssumeRolePolicyDocument' --output json \
  > outputs/lab-09-ecs-task-role-trust-before.json

cat outputs/lab-09-ecs-task-role-trust-before.json

aws iam update-assume-role-policy \
  --role-name "$USMS_ECS_TASK_ROLE" \
  --policy-document file://policies/trust-ecs-tasks-scoped.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 14-00-49.png>)


```bash
USMS_ECS_TASK_ROLE="${USMS_ECS_TASK_ROLE:-usms-ecs-task-role}"
echo "task role: $USMS_ECS_TASK_ROLE"
```

![alt text](<../../screenshots/Screenshot from 2026-11-09 14-01-15.png>)

**Part 6 - verify**

```bash
echo "== the new role =="
aws iam get-role --role-name usms-transcripts-reader-role \
  --query 'Role.{Name:RoleName,MaxSession:MaxSessionDuration,Trust:AssumeRolePolicyDocument}' \
  --output json

echo
echo "== its permissions =="
aws iam list-attached-role-policies --role-name usms-transcripts-reader-role \
  --query 'AttachedPolicies[].PolicyName' --output text

echo
echo "== the rewritten trust policy on the existing task role =="
aws iam get-role --role-name "$USMS_ECS_TASK_ROLE" \
  --query 'Role.AssumeRolePolicyDocument' --output json \
  > outputs/lab-09-ecs-task-role-trust-after.json

python3 - << 'PY'
import json
before = json.load(open("outputs/lab-09-ecs-task-role-trust-before.json"))
after  = json.load(open("outputs/lab-09-ecs-task-role-trust-after.json"))

def principals(doc):
    out = []
    sts = doc.get("Statement")
    sts = sts if isinstance(sts, list) else [sts]
    for s in sts:
        out.append((json.dumps(s.get("Principal"), sort_keys=True), bool(s.get("Condition"))))
    return out

print("before:", principals(before))
print("after :", principals(after))

same_principal = [p for p, _ in principals(before)] == [p for p, _ in principals(after)]
gained_cond    = all(c for _, c in principals(after)) and not all(c for _, c in principals(before))

print()
print("SAME PRINCIPAL, NEW CONDITION" if (same_principal and gained_cond)
      else "CHECK THIS BY HAND - the principal changed, or no condition was added")
PY
```

**Verify:** Output reads `SAME PRINCIPAL, NEW CONDITION`.

![alt text](<../../screenshots/Screenshot from 2026-11-09 14-10-24.png>)

**Checkpoint 3**
```
Identity, half fixed
 ├── USMSStudentDataReadOnly           Get + List, explicit Deny on every write
 ├── usms-transcripts-reader-role      scoped ecs-tasks trust, read-only policy
 ├── usms-ecs-task-role                SAME principal, NEW confused-deputy conditions
 ├── usms-ec2-app-role                 STILL unconditioned
 └── outputs/lab-09-ecs-task-role-trust-before.json    the undo
```

---

### Step 8 - Scope iam:PassRole, and put a ceiling on a role for the first time

**Purpose:** Build a deployment identity with scoped `iam:PassRole` and a permissions boundary.

**Part 1 - the boundary document**

```bash
cat > policies/usms-permissions-boundary.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TheCeilingForEverythingUSMSDeploys",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:CreateTags",
        "ecs:*",
        "elasticloadbalancing:*",
        "application-autoscaling:*",
        "logs:*",
        "cloudwatch:*",
        "s3:Get*",
        "s3:List*",
        "s3:PutObject",
        "iam:PassRole",
        "iam:Get*",
        "iam:List*",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NoIdentityChangesUnderAnyCircumstances",
      "Effect": "Deny",
      "Action": [
        "iam:CreateUser",
        "iam:CreateAccessKey",
        "iam:AttachUserPolicy",
        "iam:PutUserPolicy",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePermissionsBoundary",
        "iam:UpdateAssumeRolePolicy",
        "iam:CreatePolicyVersion",
        "iam:SetDefaultPolicyVersion",
        "organizations:*",
        "account:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NeverTouchTheCourseNetwork",
      "Effect": "Deny",
      "Action": [
        "ec2:DeleteVpc",
        "ec2:DeleteSubnet",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteNatGateway"
      ],
      "Resource": "*"
    }
  ]
}
EOF

python3 -m json.tool policies/usms-permissions-boundary.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-25-11.png>)

**Part 2 - create it, do not attach it**

```bash
BOUNDARY_ARN=$(aws iam create-policy \
  --policy-name USMSPermissionsBoundary \
  --description "A CEILING, not a grant. Used only as a --permissions-boundary. Never attach this." \
  --policy-document file://policies/usms-permissions-boundary.json \
  --tags Key=Project,Value=USMS Key=Lab,Value=05 Key=Purpose,Value=boundary \
  --query 'Policy.Arn' --output text)

echo "BOUNDARY_ARN = $BOUNDARY_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-25-34.png>)

**Part 3 - the deploy policy, scoped iam:PassRole**

```bash
# this document embeds USMS_ACCOUNT_ID (lab-01.env) - an empty value would write "arn:aws:iam:::role/..."
source configs/lab-01.env
echo "account: ${USMS_ACCOUNT_ID:?not set}"

cat > policies/usms-deploy-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DeployTheContainerPlatform",
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition",
        "ecs:DeregisterTaskDefinition",
        "ecs:UpdateService",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:ListTasks",
        "ecs:DescribeTasks",
        "elasticloadbalancing:Describe*",
        "application-autoscaling:Describe*",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:GetLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassOnlyTheseThreeRolesAndOnlyToTheseServices",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::${USMS_ACCOUNT_ID}:role/usms-ecs-exec-role",
        "arn:aws:iam::${USMS_ACCOUNT_ID}:role/usms-ecs-task-role",
        "arn:aws:iam::${USMS_ACCOUNT_ID}:role/usms-transcripts-reader-role"
      ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    },
    {
      "Sid": "NeverPassAnythingToEC2",
      "Effect": "Deny",
      "Action": "iam:PassRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    }
  ]
}
EOF

python3 -m json.tool policies/usms-deploy-policy.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-deploy-policy.json

DEPLOY_POLICY_ARN=$(aws iam create-policy \
  --policy-name USMSDeployBase \
  --description "What a USMS deployment pipeline may do. iam:PassRole scoped to three roles." \
  --policy-document file://policies/usms-deploy-policy.json \
  --tags Key=Project,Value=USMS Key=Lab,Value=05 \
  --query 'Policy.Arn' --output text)

echo "DEPLOY_POLICY_ARN = $DEPLOY_POLICY_ARN"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-26-56.png>)

**Part 4 - trust policy and the role**

```bash
# these documents embed USMS_ACCOUNT_ID / USMS_ADMIN_USER (lab-01.env) - empty values would write "arn:aws:iam:::"
source configs/lab-01.env
echo "account: ${USMS_ACCOUNT_ID:?not set}   admin: ${USMS_ADMIN_USER:?not set}"
BOUNDARY_ARN="arn:aws:iam::${USMS_ACCOUNT_ID}:policy/USMSPermissionsBoundary"

cat > policies/trust-deploy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OnlyTheAdminUserMayDeploy",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${USMS_ACCOUNT_ID}:user/${USMS_ADMIN_USER}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

python3 -m json.tool policies/trust-deploy.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/trust-deploy.json

DEPLOY_ROLE_ARN=$(aws iam create-role \
  --role-name usms-deploy-role \
  --description "The identity a USMS deployment runs as. Capped by USMSPermissionsBoundary." \
  --assume-role-policy-document file://policies/trust-deploy.json \
  --permissions-boundary "$BOUNDARY_ARN" \
  --max-session-duration 3600 \
  --tags Key=Project,Value=USMS Key=Lab,Value=05 Key=Tier,Value=pipeline \
  --query 'Role.Arn' --output text)

echo "DEPLOY_ROLE_ARN = $DEPLOY_ROLE_ARN"

aws iam attach-role-policy \
  --role-name usms-deploy-role \
  --policy-arn "$DEPLOY_POLICY_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-25-34.png>)

If `--permissions-boundary` is rejected:

```bash
aws iam get-role --role-name usms-deploy-role \
  --query 'Role.PermissionsBoundary' --output json
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-26-56.png>)

**Part 5 - verify**

```bash
echo "== the deploy role =="
aws iam get-role --role-name usms-deploy-role \
  --query 'Role.{Name:RoleName,Boundary:PermissionsBoundary.PermissionsBoundaryArn,MaxSession:MaxSessionDuration,Principal:AssumeRolePolicyDocument.Statement[0].Principal}' \
  --output json

echo
echo "== what it may pass, and to what =="
aws iam get-policy-version \
  --policy-arn "$DEPLOY_POLICY_ARN" \
  --version-id "$(aws iam get-policy --policy-arn "$DEPLOY_POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)" \
  --query 'PolicyVersion.Document.Statement[?Action==`iam:PassRole`]' \
  --output json

echo
echo "== is the boundary attached to anything as an ordinary policy? (it must NOT be) =="
aws iam list-entities-for-policy --policy-arn "$BOUNDARY_ARN" \
  --query '{Roles:PolicyRoles[].RoleName,Users:PolicyUsers[].UserName,Groups:PolicyGroups[].GroupName}' \
  --output json
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-30-06.png>)

**Checkpoint 4**
```
Identity, fixed
 ├── USMSPermissionsBoundary       a ceiling; attached to NOTHING
 ├── USMSDeployBase                iam:PassRole -> 3 named roles, ecs-tasks only
 ├── usms-deploy-role              trusts user/usms-admin-01, WITH a boundary
 └── escalation path closed at step 1 AND step 3
```

---

### Step 9 - Scope down a session, and compute an intersection

**Purpose:** Use a session policy and compute effective permissions = identity ∩ boundary ∩ session.

**Part 1 - write a session policy**

```bash
cat > outputs/lab-09-session-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ThisSessionMayOnlyLook",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
EOF

python3 -m json.tool outputs/lab-09-session-policy.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-32-37.png>)

**Part 2 - assume the role with it**

```bash
# USMS_ROLE_DEVELOPER (lab-01.env) is already a full role ARN
ROLE_ARN="$USMS_ROLE_DEVELOPER"

aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "lab05-scoped-review" \
  --policy file://outputs/lab-09-session-policy.json \
  --duration-seconds 900 \
  --profile usms-dev \
  > outputs/lab-09-scoped-session.json \
  || echo "assume-role with --policy not supported on this build - see the fallback below"

chmod 600 outputs/lab-09-scoped-session.json 2>/dev/null || true

if [ -s outputs/lab-09-scoped-session.json ]; then
  export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId'     outputs/lab-09-scoped-session.json)
  export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' outputs/lab-09-scoped-session.json)
  export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken'    outputs/lab-09-scoped-session.json)

  aws sts get-caller-identity --no-cli-pager
  aws ec2 describe-vpcs --query 'length(Vpcs)' --output text
fi
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-33-03.png>)

**Part 3 - compute the intersection by hand**

```bash
python3 - << 'PY'
import json, subprocess

def doc_actions(doc):
    out = set()
    sts = doc.get("Statement")
    sts = sts if isinstance(sts, list) else [sts]
    for s in sts:
        if s.get("Effect") != "Allow":
            continue
        acts = s.get("Action")
        acts = acts if isinstance(acts, list) else [acts]
        out.update(acts)
    return out

def denies(doc):
    out = set()
    sts = doc.get("Statement")
    sts = sts if isinstance(sts, list) else [sts]
    for s in sts:
        if s.get("Effect") != "Deny":
            continue
        acts = s.get("Action")
        acts = acts if isinstance(acts, list) else [acts]
        out.update(acts)
    return out

def matches(action, pattern):
    if pattern == "*":
        return True
    if pattern.endswith("*"):
        return action.lower().startswith(pattern[:-1].lower())
    return action.lower() == pattern.lower()

inv = json.load(open("outputs/lab-09-identity-inventory.json"))
role = next((r for r in inv if r["role"].endswith("developer-role")), None)
if role is None:
    raise SystemExit("usms-developer-role not in the inventory - re-run Step 4")

identity_allow = set()
identity_deny  = set()
for p in role["attachedPolicies"]:
    if p.get("document"):
        identity_allow |= doc_actions(p["document"])
        identity_deny  |= denies(p["document"])

session = json.load(open("outputs/lab-09-session-policy.json"))
session_allow = doc_actions(session)

print("identity policy allows (patterns):")
for a in sorted(identity_allow):
    print("   ", a)
print()
print("session policy allows:")
for a in sorted(session_allow):
    print("   ", a)
print()
print("EFFECTIVE - an action needs a match in BOTH and a match in NEITHER deny:")
for a in sorted(session_allow):
    in_identity = any(matches(a, p) for p in identity_allow)
    denied      = any(matches(a, p) for p in identity_deny)
    verdict = "ALLOWED" if (in_identity and not denied) else \
              ("denied by an explicit Deny" if denied else "NOT in the identity policy -> denied")
    print(f"    {a:<32} {verdict}")
PY
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-34-32.png>)

Optional (if supported):

```bash
# Load USMS_ROLE_DEVELOPER (already a full ARN) if this is a fresh shell
source configs/lab-01.env

aws iam simulate-principal-policy \
  --policy-source-arn "$USMS_ROLE_DEVELOPER" \
  --action-names ec2:DescribeVpcs sts:GetCallerIdentity iam:CreateUser \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-38-08.png>)

**Part 4 - restore your normal identity**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
./scripts/utilities/whoami.sh
rm -f outputs/lab-09-scoped-session.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-38-24.png>)

---

### Step 10 - Rotate the access key, with no window in which nothing works

**Purpose:** Rotate `usms-dev-01`'s access key using the 4-step create → move → deactivate → delete sequence.

**Part 1 - look at what you have**

```bash
aws iam list-access-keys --user-name "$USMS_DEV_USER" \
  --query 'AccessKeyMetadata[].{Key:AccessKeyId,Status:Status,Created:CreateDate}' \
  --output table

for k in $(aws iam list-access-keys --user-name "$USMS_DEV_USER" \
             --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  printf '%-24s ' "$k"
  aws iam get-access-key-last-used --access-key-id "$k" \
    --query 'AccessKeyLastUsed.{When:LastUsedDate,Service:ServiceName,Region:Region}' \
    --output text 2>/dev/null || echo "last-used not available on this build"
done
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-39-32.png>)

**Part 2 - create the new key**

```bash
aws iam create-access-key --user-name "$USMS_DEV_USER" \
  > outputs/usms-dev-01-access-key-new.json

chmod 600 outputs/usms-dev-01-access-key-new.json

git check-ignore -v outputs/usms-dev-01-access-key-new.json

NEW_KEY_ID=$(jq -r '.AccessKey.AccessKeyId' outputs/usms-dev-01-access-key-new.json)
echo "new key id: $NEW_KEY_ID"

OLD_KEY_ID=$(aws iam list-access-keys --user-name "$USMS_DEV_USER" \
  --query "AccessKeyMetadata[?AccessKeyId!='$NEW_KEY_ID'].AccessKeyId | [0]" \
  --output text)
echo "old key id: $OLD_KEY_ID"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-40-24.png>)

**Part 3 - move the consumer over**

```bash
aws configure set aws_access_key_id \
  "$(jq -r '.AccessKey.AccessKeyId' outputs/usms-dev-01-access-key-new.json)" --profile usms-dev
aws configure set aws_secret_access_key \
  "$(jq -r '.AccessKey.SecretAccessKey' outputs/usms-dev-01-access-key-new.json)" --profile usms-dev

aws sts get-caller-identity --profile usms-dev --query 'Arn' --output text
aws configure get aws_access_key_id --profile usms-dev
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-40-38.png>)

**Part 4 - deactivate the old key**

```bash
aws iam update-access-key \
  --user-name "$USMS_DEV_USER" \
  --access-key-id "$OLD_KEY_ID" \
  --status Inactive

aws iam list-access-keys --user-name "$USMS_DEV_USER" \
  --query 'AccessKeyMetadata[].{Key:AccessKeyId,Status:Status}' --output table

aws sts get-caller-identity --profile usms-dev --query 'Arn' --output text
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-40-51.png>)

**Part 5 - delete the old key**

```bash
aws iam delete-access-key \
  --user-name "$USMS_DEV_USER" \
  --access-key-id "$OLD_KEY_ID"

aws iam list-access-keys --user-name "$USMS_DEV_USER" \
  --query 'AccessKeyMetadata[].{Key:AccessKeyId,Status:Status,Created:CreateDate}' --output table

aws sts get-caller-identity --profile usms-dev --query 'Arn' --output text

rm -f outputs/usms-dev-01-access-key.json
ls -l outputs/ | grep -i access-key || echo "no other access key files remain"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-41-08.png>)

**Checkpoint 5**
```
Credentials
 ├── usms-dev-01                 exactly one access key, created today
 ├── the usms-dev profile        repointed, verified before the old key was touched
 ├── the old key                 deactivated, verified, THEN deleted
 ├── outputs/                    old key file removed; new one chmod 600 and git-ignored
 └── the four-step order         create -> move -> deactivate -> delete
```

---

### Step 11 - Require IMDSv2 on the web instance

**Purpose:** Prevent SSRF credential theft (Capital One-style) and container-to-host metadata access.

**Part 1 - look before you change**

```bash
# USMS_WEB_INSTANCE is recorded in lab-03.env - reload it if this is a fresh shell
source configs/lab-03.env
echo "web instance: ${USMS_WEB_INSTANCE:?not set - check configs/lab-03.env}"

aws ec2 describe-instances --instance-ids "$USMS_WEB_INSTANCE" \
  --query 'Reservations[0].Instances[0].MetadataOptions' --output json \
  | tee outputs/lab-09-imds-before.json
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-44-22.png>)

**Part 2 - require tokens**

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id "$USMS_WEB_INSTANCE" \
  --http-tokens required \
  --http-endpoint enabled \
  --http-put-response-hop-limit 1 \
  --query '{Instance:InstanceId,State:InstanceMetadataOptions.State,Tokens:InstanceMetadataOptions.HttpTokens,Hops:InstanceMetadataOptions.HttpPutResponseHopLimit}' \
  --output json \
  || echo "modify-instance-metadata-options not supported on this build - record it and continue"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-44-46.png>)

**Part 3 - verify**

```bash
aws ec2 describe-instances --instance-ids "$USMS_WEB_INSTANCE" \
  --query 'Reservations[0].Instances[0].MetadataOptions' --output json \
  | tee outputs/lab-09-imds-after.json

python3 - << 'PY'
import json
before = json.load(open("outputs/lab-09-imds-before.json")) or {}
after  = json.load(open("outputs/lab-09-imds-after.json"))  or {}
print(f"HttpTokens : {before.get('HttpTokens','?')}  ->  {after.get('HttpTokens','?')}")
print(f"HopLimit   : {before.get('HttpPutResponseHopLimit','?')}  ->  {after.get('HttpPutResponseHopLimit','?')}")
ok = after.get("HttpTokens") == "required" and after.get("HttpPutResponseHopLimit") == 1
print()
print("IMDSv2 REQUIRED, HOP LIMIT 1" if ok else
      "NOT APPLIED - record this as a Floci limitation and say what real AWS would have done")
PY
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-45-11.png>)

**My turn:** Apply the appropriate (stronger) metadata setting to `usms-db-01` (which has no instance profile), and explain in one sentence what would break if the same setting were applied to `usms-web-01`.

**Notes:** `usms-db-01` has no instance profile, so it has no credentials to protect and no reason to use the metadata service at all. The stronger setting is to switch the endpoint off completely:
```bash
aws ec2 modify-instance-metadata-options --instance-id "$USMS_DB_INSTANCE" --http-endpoint disabled
```
If the same `--http-endpoint disabled` were applied to `usms-web-01`, the application would lose its only way to fetch the temporary `usms-ec2-app-role` credentials from IMDS, so every AWS SDK call it makes (for example to S3) would fail with no credentials.

**My result:** `usms-db-01` (`i-ac42968cdb0ac8cd9`, instance profile `null`) started with `HttpEndpoint: enabled`, `HttpTokens: optional`. Running the command above on Floci returned `UnsupportedOperation: Operation ModifyInstanceMetadataOptions is not supported`, and the after-read (`outputs/lab-09-imds-db-after.json`) is unchanged. I recorded this as a Floci limitation. On real AWS the call returns `State: pending` then `applied`, and `describe-instances` shows `HttpEndpoint: disabled`, so nothing on the instance can reach `169.254.169.254` at all.

**Checkpoint 6**
```
usms-web-01
 ├── IMDSv2  HttpTokens required
 ├── hop limit 1
 ├── HttpEndpoint enabled
 └── usms-db-01  handled separately, differently (no role at all)
```

---

### Interlude - The Four Questions to Ask a Security Group

```
1. WHO CAN REACH ME?        ingress rules
2. WHAT CAN I REACH?        egress rules
3. IS THE SOURCE A GROUP OR AN ADDRESS?
4. IS THIS GROUP ATTACHED TO ANYTHING?
```

---

### Step 12 - Build the security group audit script

**Purpose:** Turn five security groups into findings computed from rules, not names. Read-only.

```bash
cat > scripts/utilities/usms-sg-audit.sh << 'EOF'
#!/usr/bin/env bash
# USMS security group audit. Reports findings; changes nothing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true

VPC="${1:-${USMS_VPC_ID:-}}"
if [ -z "$VPC" ] || [ "$VPC" = "none" ]; then
  echo "usage: $0 [vpc-id]   (or set USMS_VPC_ID in configs/lab-02.env)" >&2
  exit 2
fi

aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-sg-audit-$$.json || { echo "cannot read security groups" >&2; exit 2; }

for g in $(python3 -c "
import json;print(' '.join(s['GroupId'] for s in json.load(open('/tmp/usms-sg-audit-$$.json'))['SecurityGroups']))
"); do
  n=$(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=$g" \
        --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
  echo "$g $n"
done > /tmp/usms-sg-enis-$$.txt

python3 - "/tmp/usms-sg-audit-$$.json" "/tmp/usms-sg-enis-$$.txt" << 'PY'
import json, sys

groups = json.load(open(sys.argv[1]))["SecurityGroups"]
enis = {}
for line in open(sys.argv[2]):
    parts = line.split()
    if len(parts) == 2:
        try:
            enis[parts[0]] = int(parts[1])
        except ValueError:
            enis[parts[0]] = 0

by_id = {g["GroupId"]: g.get("GroupName", g["GroupId"]) for g in groups}

def render(perms):
    out = []
    for p in perms:
        proto = p.get("IpProtocol", "-1")
        proto = "all" if proto == "-1" else proto
        lo, hi = p.get("FromPort"), p.get("ToPort")
        port = "all" if lo is None else (str(lo) if lo == hi else f"{lo}-{hi}")
        dests = []
        for r in p.get("IpRanges", []):
            dests.append(r.get("CidrIp"))
        for r in p.get("Ipv6Ranges", []):
            dests.append(r.get("CidrIpv6"))
        for r in p.get("UserIdGroupPairs", []):
            gid = r.get("GroupId")
            dests.append(f"sg:{by_id.get(gid, gid)}")
        for r in p.get("PrefixListIds", []):
            dests.append(f"pl:{r.get('PrefixListId')}")
        out.append((proto, port, dests or ["<none>"]))
    return out

high = med = low = 0
print("== USMS security group audit ==")
print()

for g in sorted(groups, key=lambda x: x.get("GroupName", "")):
    name = g.get("GroupName", g["GroupId"])
    gid = g["GroupId"]
    n = enis.get(gid, 0)
    findings = []

    print(f"{name}  ({gid})   interfaces: {n}")

    print("    ingress:")
    ing = render(g.get("IpPermissions", []))
    if not ing:
        print("        (none - nothing may reach anything wearing this group)")
    for proto, port, dests in ing:
        print(f"        {proto}/{port:<9} from {', '.join(dests)}")
        for d in dests:
            if d in ("0.0.0.0/0", "::/0"):
                findings.append(("HIGH", f"ingress {proto}/{port} from {d}"))
            elif d and d.startswith("10.") and d.endswith("/16"):
                findings.append(("MED", f"ingress {proto}/{port} from a whole VPC range ({d}) "
                                        "- could this be a group reference?"))

    print("    egress:")
    egr = g.get("IpPermissionsEgress", [])
    eg = render(egr)
    if not eg:
        print("        (none - nothing wearing this group may initiate anything)")
    for proto, port, dests in eg:
        print(f"        {proto}/{port:<9} to   {', '.join(dests)}")
    default_egress = any(
        p.get("IpProtocol") == "-1"
        and any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", []))
        for p in egr)
    if default_egress:
        findings.append(("MED", "egress is the DEFAULT allow-all rule - nobody wrote this"))

    if n == 0:
        findings.append(("LOW", "attached to no network interface"))

    for sev, text in findings:
        print(f"    {sev:<4} {text}")
        if sev == "HIGH":
            high += 1
        elif sev == "MED":
            med += 1
        else:
            low += 1
    print()

print(f"HIGH={high}  MED={med}  LOW={low}  groups={len(groups)}")
sys.exit(1 if high else 0)
PY

rm -f /tmp/usms-sg-audit-$$.json /tmp/usms-sg-enis-$$.txt
EOF

chmod +x scripts/utilities/usms-sg-audit.sh
bash -n scripts/utilities/usms-sg-audit.sh && echo "syntax OK"
./scripts/utilities/usms-sg-audit.sh | tee outputs/lab-09-sg-findings-before.txt
```

**Verify:** Sort findings into: accepted risk / open finding / to be fixed.

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-48-25.png>)

**Checkpoint 7**
```
Network inventory complete
 ├── outputs/lab-09-sg-findings-before.txt   HIGH=3  MED=6  LOW=1
 ├── scripts/utilities/usms-sg-audit.sh
 ├── finding: FIVE groups carry the default allow-all egress rule
 └── finding: usms-app-sg admits SSH from the whole VPC
```

---

### Step 13 - Write the egress rules for the enrolment tasks

**Purpose:** Replace allow-all egress on `usms-enrolment-sg` with a scoped rule.

**Part 1 - find the S3 prefix list**

```bash
S3_PREFIX_LIST=$(aws ec2 describe-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.${AWS_REGION_COURSE}.s3" \
  --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null)

echo "from describe-prefix-lists: $S3_PREFIX_LIST"

if [ -z "$S3_PREFIX_LIST" ] || [ "$S3_PREFIX_LIST" = "None" ]; then
  S3_PREFIX_LIST=$(aws ec2 describe-route-tables --route-table-ids "$USMS_PRIVATE_RT" \
    --query 'RouteTables[0].Routes[?DestinationPrefixListId!=`null`].DestinationPrefixListId | [0]' \
    --output text 2>/dev/null)
  echo "from the private route table:  $S3_PREFIX_LIST"
fi

echo "S3_PREFIX_LIST = ${S3_PREFIX_LIST:-<none>}"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-49-26.png>)

**Part 2 - write the egress document**

```bash
if [ -n "$S3_PREFIX_LIST" ] && [ "$S3_PREFIX_LIST" != "None" ]; then
cat > policies/usms-enrolment-sg-egress.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "PrefixListIds": [
      {
        "PrefixListId": "${S3_PREFIX_LIST}",
        "Description": "S3 via the Lab 02 gateway endpoint - transcripts, and nothing leaves the AWS network"
      }
    ]
  },
  {
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0",
        "Description": "HTTPS out for the container image pull and the awslogs driver - narrow this to interface endpoints on real AWS"
      }
    ]
  }
]
EOF
else
cat > policies/usms-enrolment-sg-egress.json << 'EOF'
[
  {
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0",
        "Description": "HTTPS out for the image pull, the awslogs driver and S3 - no prefix list on this build"
      }
    ]
  }
]
EOF
fi

python3 -m json.tool policies/usms-enrolment-sg-egress.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-enrolment-sg-egress.json
cat policies/usms-enrolment-sg-egress.json
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-50-09.png>)

**Part 3 - keep the undo, then make the change**

```bash
cat > policies/usms-egress-allow-all.json << 'EOF'
[
  {
    "IpProtocol": "-1",
    "IpRanges": [
      { "CidrIp": "0.0.0.0/0", "Description": "The AWS default egress rule. Kept here as the undo." }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-egress-allow-all.json > /dev/null && echo "undo document written"

# USMS_ENROLMENT_SG is recorded in lab-04.env - reload it if this is a fresh shell
source configs/lab-04.env
echo "enrolment sg: ${USMS_ENROLMENT_SG:?not set - check configs/lab-04.env}"

# 1. authorise the replacement FIRST
aws ec2 authorize-security-group-egress \
  --group-id "$USMS_ENROLMENT_SG" \
  --ip-permissions file://policies/usms-enrolment-sg-egress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text

# 2. only then revoke the default
aws ec2 revoke-security-group-egress \
  --group-id "$USMS_ENROLMENT_SG" \
  --ip-permissions file://policies/usms-egress-allow-all.json \
  --query 'Return' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-52-31.png>)

**Verify:**

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$USMS_ENROLMENT_SG" \
  --query 'SecurityGroupRules[?IsEgress==`true`].{Rule:SecurityGroupRuleId,Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,PrefixList:PrefixListId,Desc:Description}' \
  --output table

aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Source:UserIdGroupPairs[0].GroupId}' \
  --output table
echo "usms-alb-sg = $USMS_ALB_SG"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 13-52-53.png>)

---

### Step 14 - Write the load balancer's egress rule, whose destination is a security group

**Purpose:** Restrict the ALB's outbound to only the enrolment tasks, using a group reference (not a CIDR).

**Part 1 - the document**

```bash
# the document embeds USMS_ENROLMENT_SG (lab-04.env) - an empty value would write "GroupId": ""
source configs/lab-04.env
echo "enrolment sg: ${USMS_ENROLMENT_SG:?not set - check configs/lab-04.env}"

cat > policies/usms-alb-sg-egress.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "UserIdGroupPairs": [
      {
        "GroupId": "${USMS_ENROLMENT_SG}",
        "Description": "HTTP to the enrolment tasks - the ONLY thing this load balancer may initiate"
      }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-alb-sg-egress.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-alb-sg-egress.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-54-04.png>)

**Part 2 - authorise then revoke**

```bash
# USMS_ALB_SG is recorded in lab-05.env - reload it if this is a fresh shell
source configs/lab-05.env
echo "alb sg: ${USMS_ALB_SG:?not set - check configs/lab-05.env}"

aws ec2 authorize-security-group-egress \
  --group-id "$USMS_ALB_SG" \
  --ip-permissions file://policies/usms-alb-sg-egress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text

aws ec2 revoke-security-group-egress \
  --group-id "$USMS_ALB_SG" \
  --ip-permissions file://policies/usms-egress-allow-all.json \
  --query 'Return' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-56-12.png>)

**Verify:**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_ALB_SG" \
  --query 'SecurityGroups[0].{In:IpPermissions[].{Port:FromPort,CIDR:IpRanges[0].CidrIp},Out:IpPermissionsEgress[].{Port:FromPort,ToGroup:UserIdGroupPairs[0].GroupId,CIDR:IpRanges[0].CidrIp}}' \
  --output json

echo "usms-enrolment-sg = $USMS_ENROLMENT_SG"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-56-30.png>)
---

### Step 15 - Write the data tier's egress rule

**Purpose:** Restrict `usms-db-sg` egress to HTTPS only (OS updates).

**Part 1 - the document**

```bash
cat > policies/usms-db-sg-egress.json << 'EOF'
[
  {
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0",
        "Description": "HTTPS out through usms-nat for operating system updates - the ONLY reason Lab 02 gave this tier outbound access"
      }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-db-sg-egress.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 13-58-44.png>)

**Part 2 - authorise then revoke**

```bash
# USMS_DB_SG is recorded in lab-02.env - reload it if this is a fresh shell
source configs/lab-02.env
echo "db sg: ${USMS_DB_SG:?not set - check configs/lab-02.env}"

aws ec2 authorize-security-group-egress \
  --group-id "$USMS_DB_SG" \
  --ip-permissions file://policies/usms-db-sg-egress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text

aws ec2 revoke-security-group-egress \
  --group-id "$USMS_DB_SG" \
  --ip-permissions file://policies/usms-egress-allow-all.json \
  --query 'Return' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-00-55.png>)

**Verify - all three groups:**

```bash
# reload the three group IDs (lab-02/04/05.env) if this is a fresh shell
for f in configs/lab-0{2,4,5}.env; do source "$f"; done

for g in "$USMS_ENROLMENT_SG" "$USMS_ALB_SG" "$USMS_DB_SG"; do
  name=$(aws ec2 describe-security-groups --group-ids "$g" \
          --query 'SecurityGroups[0].GroupName' --output text)
  n=$(aws ec2 describe-security-groups --group-ids "$g" \
        --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1`])' --output text)
  printf '%-22s allow-all egress rules remaining: %s\n' "$name" "$n"
done
```

**Expected:** Three zeros.

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-01-14.png>)

**Checkpoint 8**
```
Egress, written
 ├── usms-enrolment-sg   tcp/443 -> pl:<s3>, 0.0.0.0/0
 ├── usms-alb-sg         tcp/80  -> sg:usms-enrolment-sg
 ├── usms-db-sg          tcp/443 -> 0.0.0.0/0
 ├── usms-app-sg         still the default          <- Exercise 1
 ├── policies/usms-egress-allow-all.json            the undo
 └── every ingress rule in the VPC                  UNCHANGED
```

---

### Step 16 - Narrow the SSH rule to a bastion group

**Purpose:** Replace `usms-app-sg`'s SSH-from-10.0.0.0/16 rule with a bastion-group reference.

**Part 1 - find or create the bastion group**

```bash
# USMS_VPC_ID and USMS_APP_SG are recorded in lab-02.env - reload if this is a fresh shell
source configs/lab-02.env
echo "vpc: ${USMS_VPC_ID:?not set}   app sg: ${USMS_APP_SG:?not set}"

BASTION_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$USMS_VPC_ID" "Name=group-name,Values=usms-bastion-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [ -z "$BASTION_SG" ] || [ "$BASTION_SG" = "None" ]; then
  echo "usms-bastion-sg does not exist - creating it (Lab 02 Exercise 2 was not done)"
  BASTION_SG=$(aws ec2 create-security-group \
    --group-name usms-bastion-sg \
    --description "USMS administrative jump host tier: SSH in from one address, SSH out to the VPC" \
    --vpc-id "$USMS_VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-bastion-sg},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=05}]' \
    --query 'GroupId' --output text)

  aws ec2 authorize-security-group-ingress \
    --group-id "$BASTION_SG" \
    --protocol tcp --port 22 --cidr 203.0.113.10/32 \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text
else
  echo "reusing usms-bastion-sg from Lab 02 Exercise 2"
fi

echo "BASTION_SG = $BASTION_SG"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-04-55.png>)

**Part 2 - the new rule on usms-app-sg**

```bash
cat > policies/usms-app-sg-ssh-bastion.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 22,
    "ToPort": 22,
    "UserIdGroupPairs": [
      {
        "GroupId": "${BASTION_SG}",
        "Description": "SSH from the USMS jump host tier only - replaces the 10.0.0.0/16 rule from Lab 02 Step 14"
      }
    ]
  }
]
EOF

python3 -m json.tool policies/usms-app-sg-ssh-bastion.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-app-sg-ssh-bastion.json

aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_APP_SG" \
  --ip-permissions file://policies/usms-app-sg-ssh-bastion.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-05-49.png>)

**Part 3 - remove the old rule**

```bash
OLD_SSH_RULE=$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$USMS_APP_SG" \
  --query "SecurityGroupRules[?IsEgress==\`false\` && FromPort==\`22\` && CidrIpv4=='10.0.0.0/16'].SecurityGroupRuleId | [0]" \
  --output text)

echo "rule to remove: $OLD_SSH_RULE"

if [ -n "$OLD_SSH_RULE" ] && [ "$OLD_SSH_RULE" != "None" ]; then
  # revoke by the rule's content: Floci answers True to --security-group-rule-ids but keeps the rule
  aws ec2 revoke-security-group-ingress \
    --group-id "$USMS_APP_SG" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"10.0.0.0/16"}]}]' \
    --query 'Return' --output text
else
  echo "no 10.0.0.0/16 SSH rule found - Lab 02 Exercise 2 already removed it"
fi
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-06-10.png>)

**Verify:**

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$USMS_APP_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false`].{Rule:SecurityGroupRuleId,Port:FromPort,CIDR:CidrIpv4,FromGroup:ReferencedGroupInfo.GroupId,Desc:Description}' \
  --output table

echo "usms-bastion-sg = $BASTION_SG"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-06-26.png>)

**Checkpoint 9**
```
usms-app-sg
 ├── in  tcp/80   from 0.0.0.0/0        unchanged
 ├── in  tcp/443  from 0.0.0.0/0        unchanged
 ├── in  tcp/22   from sg:usms-bastion-sg   <- NARROWED
 └── the 10.0.0.0/16 SSH rule           GONE
```

---

### Step 17 - Compute the reachability matrix, and prove two negatives

**Purpose:** Build a tool to answer "who can reach what" and prove `usms-db-01` is unreachable via multiple independent controls.

**Part 1 - build the matrix tool**

```bash
cat > scripts/utilities/usms-reachability-matrix.sh << 'EOF'
#!/usr/bin/env bash
# USMS reachability matrix. Read-only. Always exits 0.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true

VPC="${1:-${USMS_VPC_ID:-}}"
[ -n "$VPC" ] && [ "$VPC" != "none" ] || { echo "usage: $0 [vpc-id]" >&2; exit 2; }

aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-matrix-sg-$$.json
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-matrix-ec2-$$.json

python3 - "/tmp/usms-matrix-sg-$$.json" "/tmp/usms-matrix-ec2-$$.json" << 'PY'
import json, sys

groups = json.load(open(sys.argv[1]))["SecurityGroups"]
res    = json.load(open(sys.argv[2]))["Reservations"]

name = {g["GroupId"]: g.get("GroupName", g["GroupId"]) for g in groups}

def port_str(p):
    lo, hi = p.get("FromPort"), p.get("ToPort")
    if lo is None:
        return "all"
    return str(lo) if lo == hi else f"{lo}-{hi}"

def proto_str(p):
    v = p.get("IpProtocol", "-1")
    return "all" if v == "-1" else v

print("== USMS reachability matrix ==")
print()
print("WHO MAY OPEN A CONNECTION TO WHAT  (ingress, computed from rules only)")
print()

lonely = []
for g in sorted(groups, key=lambda x: x.get("GroupName", "")):
    gid, gname = g["GroupId"], g.get("GroupName", g["GroupId"])
    perms = g.get("IpPermissions", [])
    if not perms:
        print(f"  -> {gname}")
        print("       (nothing. no ingress rule exists)")
        print()
        continue

    controls = 0
    print(f"  -> {gname}")
    for p in perms:
        for r in p.get("UserIdGroupPairs", []):
            src = name.get(r.get("GroupId"), r.get("GroupId"))
            print(f"       {proto_str(p)}/{port_str(p):<9} <- group {src}")
            controls += 1
        for r in p.get("IpRanges", []):
            c = r.get("CidrIp")
            flag = "   <-- THE INTERNET" if c == "0.0.0.0/0" else ""
            print(f"       {proto_str(p)}/{port_str(p):<9} <- cidr  {c}{flag}")
            controls += 1
        for r in p.get("PrefixListIds", []):
            print(f"       {proto_str(p)}/{port_str(p):<9} <- prefix list {r.get('PrefixListId')}")
            controls += 1
    if controls == 1:
        lonely.append(gname)
    print()

print("WHAT EACH GROUP MAY INITIATE  (egress)")
print()
for g in sorted(groups, key=lambda x: x.get("GroupName", "")):
    gname = g.get("GroupName", g["GroupId"])
    egr = g.get("IpPermissionsEgress", [])
    if not egr:
        print(f"  {gname:<22} nothing")
        continue
    parts = []
    for p in egr:
        dests = [name.get(r.get("GroupId"), r.get("GroupId")) for r in p.get("UserIdGroupPairs", [])]
        dests += [r.get("CidrIp") for r in p.get("IpRanges", [])]
        dests += [r.get("PrefixListId") for r in p.get("PrefixListIds", [])]
        parts.append(f"{proto_str(p)}/{port_str(p)} -> {', '.join(d for d in dests if d)}")
    print(f"  {gname:<22} {' ; '.join(parts)}")

print()
print("INSTANCES, AND WHETHER THE INTERNET HAS AN ADDRESS TO SEND TO")
print()
for r in res:
    for i in r.get("Instances", []):
        if i.get("State", {}).get("Name") == "terminated":
            continue
        tags = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
        pub = i.get("PublicIpAddress")
        sgs = ",".join(name.get(s["GroupId"], s["GroupId"]) for s in i.get("SecurityGroups", []))
        print(f"  {tags.get('Name', i['InstanceId']):<16} "
              f"private={i.get('PrivateIpAddress','-'):<12} "
              f"public={pub or 'NONE':<16} groups={sgs}")

print()
if lonely:
    print("SINGLE POINT OF CONTROL - these groups are protected by exactly ONE ingress rule:")
    for g in lonely:
        print(f"    {g}")
    print("    One mistake in one rule is the whole of the protection. Say so in your report.")
else:
    print("no group is protected by exactly one ingress rule")
PY

rm -f /tmp/usms-matrix-sg-$$.json /tmp/usms-matrix-ec2-$$.json
EOF

chmod +x scripts/utilities/usms-reachability-matrix.sh
bash -n scripts/utilities/usms-reachability-matrix.sh && echo "syntax OK"
./scripts/utilities/usms-reachability-matrix.sh | tee outputs/lab-09-reachability.txt
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-08-34.png>)

**Part 2 - prove the negative on the data tier**

```bash
# USMS_DB_SG, USMS_PRIVATE_SUBNET_A (lab-02.env) and USMS_DB_INSTANCE (lab-03.env)
for f in configs/lab-0{2,3}.env; do source "$f"; done

{
  echo "== Claim: usms-db-01 is not reachable from the internet =="
  echo "   Each control below would have to fail INDEPENDENTLY for the claim to be false."
  echo

  echo "-- control 1: no public address --"
  aws ec2 describe-instances --instance-ids "$USMS_DB_INSTANCE" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

  echo "-- control 2: its subnet does not auto-assign one --"
  aws ec2 describe-subnets --subnet-ids "$USMS_PRIVATE_SUBNET_A" \
    --query 'Subnets[0].MapPublicIpOnLaunch' --output text

  echo "-- control 3: its route table has no internet gateway route --"
  aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId]' \
    --output text

  echo "-- control 4: its security group admits ONE group, no CIDR --"
  aws ec2 describe-security-groups --group-ids "$USMS_DB_SG" \
    --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Group:UserIdGroupPairs[0].GroupId,CIDR:IpRanges[0].CidrIp}' \
    --output text

  echo "-- control 5: the subnet's network ACL is not the default one --"
  aws ec2 describe-network-acls \
    --filters "Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A" \
    --query 'NetworkAcls[0].{Acl:NetworkAclId,IsDefault:IsDefault}' --output text
} | tee outputs/lab-09-negative-proof.txt
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-10-45.png>)

**Notes:** What would still stop an attacker if control 3 failed? What if control 4 failed?

If **control 3** failed (someone added a `0.0.0.0/0` route to an internet gateway on the private route table), `usms-db-01` would still be unreachable. It has no public IP (control 1), its subnet does not auto-assign one (control 2), so there is no address the internet could route to. Its security group would also still admit only the one source group and no CIDR (control 4).

If **control 4** failed (someone added a `0.0.0.0/0` ingress rule to `usms-db-sg`), the packets would still have no path. There is no public address (controls 1–2), no internet gateway route (control 3), and the subnet's non-default network ACL (control 5) is a further stateless filter. The rule would be a serious finding, but not an exposure on its own. Each failure is survivable because the other controls are *independent*: they are configured in different places and by different API calls.

**Checkpoint 10**
```
Reachability computed, negatives proven
 ├── scripts/utilities/usms-reachability-matrix.sh
 ├── outputs/lab-09-reachability.txt
 ├── outputs/lab-09-negative-proof.txt
 ├── finding: usms-app-sg is a SECOND internet-facing entry point
 └── finding: usms-enrolment-sg is a single point of control
```

---

### Step 18 - Prove the whole posture survives a restart, and that nothing else broke

**Purpose:** Prove persistence of controls across a restart, and prove no regression in earlier labs.

**Part 1 - record the truth**

```bash
{
  aws iam get-role --role-name "$USMS_ECS_TASK_ROLE" \
    --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Condition)' --output text
  aws iam get-role --role-name usms-deploy-role \
    --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text
  aws iam get-role --role-name usms-transcripts-reader-role \
    --query 'Role.RoleName' --output text
  aws iam list-attached-role-policies --role-name usms-transcripts-reader-role \
    --query 'AttachedPolicies[0].PolicyName' --output text
  aws iam list-access-keys --user-name "$USMS_DEV_USER" \
    --query 'length(AccessKeyMetadata)' --output text
  for g in "$USMS_ALB_SG" "$USMS_ENROLMENT_SG" "$USMS_DB_SG"; do
    aws ec2 describe-security-groups --group-ids "$g" \
      --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1`])' --output text
  done
  aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
    --query 'length(SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[])' --output text
  aws ec2 describe-instances --instance-ids "$USMS_WEB_INSTANCE" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text
} > outputs/lab-09-pre-restart.txt

cat outputs/lab-09-pre-restart.txt
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-12-32.png>)

**Part 2 - perturb**

```bash
./scripts/setup/floci-down.sh
sleep 3
./scripts/setup/floci-up.sh
sleep 5

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env
source configs/lab-05.env
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-13-12.png>)

**Part 3 - re-derive every identifier and read it back**

```bash
USMS_ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-alb-sg" --query 'SecurityGroups[0].GroupId' --output text)
USMS_ENROLMENT_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=usms-enrolment-sg" --query 'SecurityGroups[0].GroupId' --output text)
USMS_DB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-db-sg" --query 'SecurityGroups[0].GroupId' --output text)
USMS_APP_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-app-sg" --query 'SecurityGroups[0].GroupId' --output text)
USMS_WEB_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=usms-web-01" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
USMS_ECS_TASK_ROLE="${USMS_ECS_TASK_ROLE:-usms-ecs-task-role}"

echo "re-derived:"
printf '  %s\n' "$USMS_ALB_SG" "$USMS_ENROLMENT_SG" "$USMS_DB_SG" "$USMS_APP_SG" "$USMS_WEB_INSTANCE"

{
  aws iam get-role --role-name "$USMS_ECS_TASK_ROLE" \
    --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Condition)' --output text
  aws iam get-role --role-name usms-deploy-role \
    --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text
  aws iam get-role --role-name usms-transcripts-reader-role \
    --query 'Role.RoleName' --output text
  aws iam list-attached-role-policies --role-name usms-transcripts-reader-role \
    --query 'AttachedPolicies[0].PolicyName' --output text
  aws iam list-access-keys --user-name "$USMS_DEV_USER" \
    --query 'length(AccessKeyMetadata)' --output text
  for g in "$USMS_ALB_SG" "$USMS_ENROLMENT_SG" "$USMS_DB_SG"; do
    aws ec2 describe-security-groups --group-ids "$g" \
      --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1`])' --output text
  done
  aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
    --query 'length(SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[])' --output text
  aws ec2 describe-instances --instance-ids "$USMS_WEB_INSTANCE" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text
} > outputs/lab-09-post-restart.txt

diff outputs/lab-09-pre-restart.txt outputs/lab-09-post-restart.txt \
  && echo "PERSISTENCE PROVEN: the trust condition, the permissions boundary, the read-only role and its policy, the single access key, three written egress rules, the absence of a CIDR SSH source, and the IMDSv2 requirement are all unchanged" \
  || echo "PERSISTENCE FAILED: read the diff above, then run ./scripts/utilities/floci-storage-check.sh"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-14-18.png>)

**Part 4 - prove you broke nothing**

```bash
{
  echo "== after the security review $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))') =="
  for s in 02 03 04 05 06; do
    printf '%-10s ' "lab-$s"
    ./scripts/utilities/verify-lab-$s.sh 2>/dev/null | tail -1
  done
} | tee outputs/lab-09-post-verify.txt

echo
echo "== what changed =="
diff <(grep -v '^==' outputs/lab-09-pre-verify.txt) \
     <(grep -v '^==' outputs/lab-09-post-verify.txt) \
  && echo "NOTHING BROKE: all five verification scripts report exactly what they reported before this lab" \
  || echo "SOMETHING CHANGED - read the diff above and find out which check and why"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-15-57.png>)

**Checkpoint 11**
```
Persistence and regression, both proven
 ├── nine controls re-read after a stop/start, every identifier re-derived from the API
 ├── outputs/lab-09-pre-restart.txt  vs  post-restart.txt      identical
 ├── five earlier verification scripts re-run, summary lines identical to Step 2's
 └── outputs/lab-09-pre-verify.txt   vs  post-verify.txt       identical
```

---

### Step 19 - Write configs/lab-09.env

**Purpose:** Persist all identifiers created in this lab, by lookup, not from shell variables.

```bash
cat > configs/lab-09.env << EOF
# Lab 09 - security review outputs
# Generated on $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# DELIBERATELY ABSENT: the access key ID for usms-dev-01.
#
# Sourced alongside lab-01/02/03/04/05/06.

export USMS_POLICY_S3_RO=USMSStudentDataReadOnly
export USMS_POLICY_S3_RO_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadOnly'].Arn | [0]" --output text)
export USMS_POLICY_DEPLOY=USMSDeployBase
export USMS_POLICY_DEPLOY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSDeployBase'].Arn | [0]" --output text)
export USMS_POLICY_BOUNDARY=USMSPermissionsBoundary
export USMS_POLICY_BOUNDARY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSPermissionsBoundary'].Arn | [0]" --output text)

export USMS_ROLE_TRANSCRIPTS_READER=usms-transcripts-reader-role
export USMS_ROLE_TRANSCRIPTS_READER_ARN=$(aws iam get-role \
  --role-name usms-transcripts-reader-role --query 'Role.Arn' --output text)
export USMS_ROLE_DEPLOY=usms-deploy-role
export USMS_ROLE_DEPLOY_ARN=$(aws iam get-role \
  --role-name usms-deploy-role --query 'Role.Arn' --output text)

export USMS_BASTION_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=usms-bastion-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_S3_PREFIX_LIST=${S3_PREFIX_LIST:-none}

export USMS_IMDS_TOKENS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=usms-web-01" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)

export USMS_DEV_KEY_ROTATED=$(aws iam list-access-keys --user-name usms-dev-01 \
  --query 'AccessKeyMetadata[0].CreateDate' --output text)

export USMS_EGRESS_ALLOW_ALL_REMAINING=$(
  total=0
  for g in usms-alb-sg usms-enrolment-sg usms-db-sg; do
    n=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$g" \
          --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1`])' --output text 2>/dev/null || echo 0)
    total=$((total + n))
  done
  echo "$total")

export USMS_SEC_REVIEW_DATE=$(python3 -c 'import datetime;print(datetime.date.today().isoformat())')
EOF

grep -n 'export .*=$\|=None$' configs/lab-09.env || echo "all values populated"
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-18-03.png>)

**Verify:**

```bash
source configs/lab-09.env

printf '%-36s %s\n' \
  "read-only policy"        "$USMS_POLICY_S3_RO_ARN" \
  "deploy policy"           "$USMS_POLICY_DEPLOY_ARN" \
  "permissions boundary"    "$USMS_POLICY_BOUNDARY_ARN" \
  "transcripts reader role" "$USMS_ROLE_TRANSCRIPTS_READER_ARN" \
  "deploy role"             "$USMS_ROLE_DEPLOY_ARN" \
  "bastion security group"  "$USMS_BASTION_SG" \
  "s3 prefix list"          "$USMS_S3_PREFIX_LIST" \
  "imds tokens"             "$USMS_IMDS_TOKENS" \
  "dev key created"         "$USMS_DEV_KEY_ROTATED" \
  "allow-all egress left"   "$USMS_EGRESS_ALLOW_ALL_REMAINING" \
  "review date"             "$USMS_SEC_REVIEW_DATE"

grep -c '^export' configs/lab-09.env
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-18-23.png>)

---

### Step 20 - Commit

**Purpose:** Stage and commit the lab's work, verifying no secrets are exposed.

**Part 1 - look before you add**

```bash
git status --short

git check-ignore -v outputs/usms-dev-01-access-key-new.json
git check-ignore -v outputs/lab-09-identity-inventory.json
git ls-files outputs/

echo
echo "== no policy document may contain an unexpanded variable =="
grep -l '\$' policies/*.json || echo "no unexpanded variables in any policy document"
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-20-32.png>)

**Part 2 - commit**

```bash
git add labs/lab-09-security/ \
        configs/lab-09.env \
        policies/usms-student-data-ro-policy.json \
        policies/usms-deploy-policy.json \
        policies/usms-permissions-boundary.json \
        policies/trust-ecs-tasks-scoped.json \
        policies/trust-deploy.json \
        policies/usms-alb-sg-egress.json \
        policies/usms-enrolment-sg-egress.json \
        policies/usms-db-sg-egress.json \
        policies/usms-egress-allow-all.json \
        policies/usms-app-sg-ssh-bastion.json \
        scripts/utilities/usms-iam-audit.sh \
        scripts/utilities/usms-sg-audit.sh \
        scripts/utilities/usms-reachability-matrix.sh \
        scripts/utilities/verify-lab-09.sh \
        scripts/cleanup/lab-09-cleanup.sh

git status --short

git commit -m "Lab 09: security review - scoped trust policies, a permissions boundary, a scoped iam:PassRole, key rotation, IMDSv2, and written egress on three security groups"

git log --oneline -7
```

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-20-50.png>)

**Checkpoint 12**
```
Lab 09 recorded
 ├── configs/lab-09.env        committed, 16 exports, fully populated, NO key ID
 ├── policies/                 ten new documents
 ├── scripts/utilities/        three audit tools plus the verification script
 ├── outputs/                  nothing staged
 └── git log shows Labs 01 through 05
```

---

## 5. Verification

### Build scripts/utilities/verify-lab-09.sh

```bash
cat > scripts/utilities/verify-lab-09.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 09 control exists and is configured correctly.
# EXPECTED: PASS=51  FAIL=0
# A line marked "ok~" is a Floci limitation that passes only on Floci, never on real AWS.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-09.env"  2>/dev/null || true

: "${USMS_ACCOUNT_ID:=000000000000}"
: "${USMS_VPC_ID:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_DB_SG:=none}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ALB_SG:=none}"
: "${USMS_BASTION_SG:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_RT:=none}"
: "${USMS_DEV_USER:=usms-dev-01}"
: "${USMS_INSTANCE_PROFILE:=usms-ec2-app-profile}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECS_TASK_ROLE:=usms-ecs-task-role}"
: "${USMS_WEB_INSTANCE:=none}"
: "${USMS_DB_INSTANCE:=none}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

ON_FLOCI=0
docker container inspect "$FLOCI_CONTAINER_NAME" >/dev/null 2>&1 && ON_FLOCI=1

# limit LABEL REAL_CHECK FLOCI_PROOF REASON
# Passes if REAL_CHECK passes. Otherwise passes as "ok~" ONLY on Floci AND only if
# FLOCI_PROOF shows the emulator itself cannot hold the setting. On real AWS it is a FAIL.
limit() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  elif [ "$ON_FLOCI" = 1 ] && eval "$3" >/dev/null 2>&1; then
    printf "  ok~  %s (Floci limitation: %s)\n" "$1" "$4"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

poldoc() {
  arn=$(aws iam list-policies --scope Local \
          --query "Policies[?PolicyName=='$1'].Arn | [0]" --output text 2>/dev/null)
  [ -n "$arn" ] && [ "$arn" != "None" ] || return 1
  ver=$(aws iam get-policy --policy-arn "$arn" \
          --query 'Policy.DefaultVersionId' --output text 2>/dev/null)
  aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" \
    --query 'PolicyVersion.Document' --output json 2>/dev/null
}

allowall() {
  aws ec2 describe-security-groups --group-ids "$1" \
    --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1`])' --output text 2>/dev/null
}

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Labs 01 to 06 dependencies still present =="
check "usms-vpc exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "$USMS_ECS_TASK_ROLE exists" "aws iam get-role --role-name $USMS_ECS_TASK_ROLE"
check "$USMS_INSTANCE_PROFILE exists" \
  "aws iam get-instance-profile --instance-profile-name $USMS_INSTANCE_PROFILE"
check "$USMS_ENROLMENT_SERVICE is ACTIVE" \
  "test \"\$(aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].status' --output text)\" = ACTIVE"
check "USMSStudentDataReadWrite is still on TWO roles (Lab 10 needs both)" \
  "test \"\$(aws iam list-entities-for-policy --policy-arn arn:aws:iam::$USMS_ACCOUNT_ID:policy/USMSStudentDataReadWrite --query 'length(PolicyRoles)' --output text)\" -ge 2"

echo "== Lab 09 identity: the read-only split =="
check "USMSStudentDataReadOnly exists" \
  "aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSStudentDataReadOnly'].Arn | [0]\" --output text | grep -q '^arn:'"
check "it ALLOWS s3:GetObject" \
  "poldoc USMSStudentDataReadOnly | grep -q 's3:GetObject'"
check "it does NOT allow s3:PutObject" \
  "! poldoc USMSStudentDataReadOnly | python3 -c \"import json,sys;d=json.load(sys.stdin);sts=d['Statement'] if isinstance(d['Statement'],list) else [d['Statement']];a=[x for s in sts if s['Effect']=='Allow' for x in (s['Action'] if isinstance(s['Action'],list) else [s['Action']])];sys.exit(0 if 's3:PutObject' in a else 1)\""
check "it explicitly DENIES s3:PutObject" \
  "poldoc USMSStudentDataReadOnly | python3 -c \"import json,sys;d=json.load(sys.stdin);sts=d['Statement'] if isinstance(d['Statement'],list) else [d['Statement']];a=[x for s in sts if s['Effect']=='Deny' for x in (s['Action'] if isinstance(s['Action'],list) else [s['Action']])];sys.exit(0 if 's3:PutObject' in a else 1)\""
check "usms-transcripts-reader-role exists" \
  "aws iam get-role --role-name usms-transcripts-reader-role"
check "it carries USMSStudentDataReadOnly" \
  "aws iam list-attached-role-policies --role-name usms-transcripts-reader-role --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSStudentDataReadOnly"

echo "== Lab 09 identity: the confused-deputy fix =="
check "$USMS_ECS_TASK_ROLE trust policy has a Condition" \
  "test \"\$(aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Condition)' --output text)\" -ge 1"
check "its principal is STILL ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q 'ecs-tasks.amazonaws.com'"
check "the condition pins aws:SourceAccount to this account" \
  "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument' --output json | grep -q '$USMS_ACCOUNT_ID'"

echo "== Lab 09 identity: PassRole and the boundary =="
check "USMSDeployBase exists" \
  "aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSDeployBase'].Arn | [0]\" --output text | grep -q '^arn:'"
check "its iam:PassRole names role ARNs, not Resource \"*\"" \
  "poldoc USMSDeployBase | python3 -c \"import json,sys;d=json.load(sys.stdin);sts=d['Statement'];bad=[s for s in sts if s['Effect']=='Allow' and 'iam:PassRole' in (s['Action'] if isinstance(s['Action'],list) else [s['Action']]) and '*' in (s['Resource'] if isinstance(s['Resource'],list) else [s['Resource']])];sys.exit(1 if bad else 0)\""
check "its iam:PassRole carries an iam:PassedToService condition" \
  "poldoc USMSDeployBase | grep -q 'iam:PassedToService'"
check "USMSPermissionsBoundary exists" \
  "aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSPermissionsBoundary'].Arn | [0]\" --output text | grep -q '^arn:'"
check "the boundary is attached to NOTHING as an ordinary policy" \
  "test \"\$(aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSPermissionsBoundary'].AttachmentCount | [0]\" --output text)\" = 0"
check "usms-deploy-role exists" "aws iam get-role --role-name usms-deploy-role"
limit "usms-deploy-role HAS a permissions boundary" \
  "aws iam get-role --role-name usms-deploy-role --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text | grep -q 'USMSPermissionsBoundary'" \
  "aws iam get-role --role-name usms-deploy-role --query 'Role.Description' --output text | grep -q 'USMSPermissionsBoundary'" \
  "Floci accepts --permissions-boundary but never stores it"
check "usms-deploy-role trusts a USER, not a service" \
  "aws iam get-role --role-name usms-deploy-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.AWS' --output text | grep -q ':user/'"

echo "== Lab 09 credentials and metadata =="
check "$USMS_DEV_USER has EXACTLY ONE access key" \
  "test \"\$(aws iam list-access-keys --user-name $USMS_DEV_USER --query 'length(AccessKeyMetadata)' --output text)\" = 1"
check "that key is Active" \
  "test \"\$(aws iam list-access-keys --user-name $USMS_DEV_USER --query 'AccessKeyMetadata[0].Status' --output text)\" = Active"
limit "usms-web-01 requires IMDSv2" \
  "test \"\$(aws ec2 describe-instances --instance-ids $USMS_WEB_INSTANCE --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)\" = required" \
  "{ aws ec2 modify-instance-metadata-options --instance-id $USMS_WEB_INSTANCE --http-tokens required --dry-run 2>&1 || true; } | grep -q UnsupportedOperation" \
  "ModifyInstanceMetadataOptions returns UnsupportedOperation"

echo "== Lab 09 network: ingress unchanged =="
check "usms-alb-sg still admits tcp/80 from 0.0.0.0/0" \
  "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"
check "usms-enrolment-sg still admits tcp/80 from usms-alb-sg" \
  "aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text | grep -qw $USMS_ALB_SG"
check "usms-db-sg still admits tcp/5432 from usms-app-sg" \
  "aws ec2 describe-security-groups --group-ids $USMS_DB_SG --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text | grep -qw $USMS_APP_SG"

echo "== Lab 09 network: egress written =="
check "usms-alb-sg has NO allow-all egress rule" "test \"\$(allowall $USMS_ALB_SG)\" = 0"
check "usms-alb-sg egress destination is a GROUP, not a CIDR" \
  "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG --query 'SecurityGroups[0].IpPermissionsEgress[].UserIdGroupPairs[].GroupId' --output text | grep -qw $USMS_ENROLMENT_SG"
check "usms-enrolment-sg has NO allow-all egress rule" "test \"\$(allowall $USMS_ENROLMENT_SG)\" = 0"
check "usms-enrolment-sg egress is tcp/443 only" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'length(SecurityGroups[0].IpPermissionsEgress[?FromPort!=\`443\`])' --output text)\" = 0"
check "usms-db-sg has NO allow-all egress rule" "test \"\$(allowall $USMS_DB_SG)\" = 0"
check "usms-db-sg egress is tcp/443 only" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_DB_SG --query 'length(SecurityGroups[0].IpPermissionsEgress[?FromPort!=\`443\`])' --output text)\" = 0"

echo "== Lab 09 network: the SSH cutover =="
check "usms-bastion-sg exists" \
  "aws ec2 describe-security-groups --filters Name=group-name,Values=usms-bastion-sg Name=vpc-id,Values=$USMS_VPC_ID --query 'SecurityGroups[0].GroupId' --output text | grep -q '^sg-'"
check "usms-app-sg admits tcp/22 from a GROUP" \
  "aws ec2 describe-security-groups --group-ids $USMS_APP_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`22\`].UserIdGroupPairs[].GroupId' --output text | grep -q '^sg-'"
check "usms-app-sg has NO CIDR source on tcp/22" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_APP_SG --query 'length(SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[])' --output text)\" = 0"

echo "== The negatives that must stay true =="
check "usms-db-01 has NO public address" \
  "test \"\$(aws ec2 describe-instances --instance-ids $USMS_DB_INSTANCE --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)\" = None"
check "the private subnet does NOT auto-assign public addresses" \
  "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = False"
check "the private route table has NO internet gateway route" \
  "! aws ec2 describe-route-tables --route-table-ids $USMS_PRIVATE_RT --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"

echo "== Files, documents and Git hygiene =="
check "configs/lab-09.env exists" "test -f configs/lab-09.env"
check "configs/lab-09.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-09.env"
check "every policies/ document is valid JSON" \
  "( for f in policies/*.json; do python3 -m json.tool \"\$f\" >/dev/null || exit 1; done )"
check "no policies/ document contains an unexpanded variable" \
  "! grep -lE '\\\$\\{?[A-Z_]' policies/*.json"
check "no policies/ document has an ARN built from an empty variable" \
  "! grep -lE 'arn:aws:iam:::|:(role|user|policy)/\"' policies/*.json"
check "the three audit scripts exist and are executable" \
  "test -x scripts/utilities/usms-iam-audit.sh && test -x scripts/utilities/usms-sg-audit.sh && test -x scripts/utilities/usms-reachability-matrix.sh"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"

if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:
  ./scripts/utilities/floci-storage-check.sh

A failure under "== Labs 01 to 06 dependencies ==" means an earlier lab's resource is
gone. Run verify-lab-02.sh, verify-lab-03.sh, verify-lab-04.sh, verify-lab-05.sh and
verify-lab-06.sh before re-reading anything here.

A failure under "== The negatives that must stay true ==" is the most serious kind in
this script: something that was unreachable has become reachable. Stop and find out
what changed before doing anything else.
REMEDY
fi

[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-09.sh
bash -n scripts/utilities/verify-lab-09.sh && echo "syntax OK"
./scripts/utilities/verify-lab-09.sh
```

**Expected:** `PASS=51  FAIL=0`

![alt text](<../../screenshots/Screenshot from 2026-11-10 14-33-39.png>)

### Build the end-of-course cleanup script (DO NOT RUN)

```bash
cat > scripts/cleanup/lab-09-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Reverses Lab 09, dependencies first.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-09.env"

cat <<'WARN'
============================================================
  This DELETES the Lab 09 roles and policies, and RESTORES
  the allow-all egress rule on three security groups plus
  the 10.0.0.0/16 SSH rule on usms-app-sg.
  Run this FIRST, before lab-06-cleanup.sh.
============================================================
WARN

read -r -p 'Type exactly: UNDO USMS SECURITY REVIEW  > ' answer
[ "$answer" = "UNDO USMS SECURITY REVIEW" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "detach policies from the Lab 09 roles"
for r in usms-deploy-role usms-transcripts-reader-role; do
  for p in $(aws iam list-attached-role-policies --role-name "$r" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p" || true
  done
done

say "remove the permissions boundary before deleting the role that wears it"
aws iam delete-role-permissions-boundary --role-name usms-deploy-role || true

say "delete the Lab 09 roles"
aws iam delete-role --role-name usms-deploy-role || true
aws iam delete-role --role-name usms-transcripts-reader-role || true

say "delete the Lab 09 policies"
for p in USMSStudentDataReadOnly USMSDeployBase USMSPermissionsBoundary; do
  arn=$(aws iam list-policies --scope Local \
          --query "Policies[?PolicyName=='$p'].Arn | [0]" --output text 2>/dev/null || echo None)
  [ "$arn" = "None" ] && continue
  for v in $(aws iam list-policy-versions --policy-arn "$arn" \
               --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" || true
  done
  aws iam delete-policy --policy-arn "$arn" || true
done

say "restore allow-all egress"
for g in "${USMS_ALB_SG:-None}" "${USMS_ENROLMENT_SG:-None}" "${USMS_DB_SG:-None}"; do
  [ "$g" = "None" ] && continue
  aws ec2 authorize-security-group-egress \
    --group-id "$g" \
    --ip-permissions file://policies/usms-egress-allow-all.json >/dev/null 2>&1 || true
done

say "restore the Lab 02 SSH rule on usms-app-sg"
aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_APP_SG" --protocol tcp --port 22 --cidr 10.0.0.0/16 >/dev/null 2>&1 || true

say "delete usms-bastion-sg (only if nothing references it)"
aws ec2 delete-security-group --group-id "${USMS_BASTION_SG:-none}" || \
  echo "  still referenced - revoke the usms-app-sg rule that names it, then retry"

echo
echo "Lab 09 teardown complete. scripts/cleanup/lab-06-cleanup.sh may now run."
EOF

chmod +x scripts/cleanup/lab-09-cleanup.sh
bash -n scripts/cleanup/lab-09-cleanup.sh && echo "syntax OK - do NOT run it"
```
---

## 6. Independent Lab Exercises

The five exercises, with the code and results, are in [exercise.md](exercise.md).

---

## 7. Reflection

_Write a short reflection here covering:_
- The two independent axes of access control and the error-message-vs-timeout heuristic.
- The "controls nobody wrote" theme (default egress, the /16 SSH rule, unconditioned trust).
- Why proof in this lab was about documents, not enforcement.
- The cutover discipline (authorise-before-revoke / create-move-deactivate-delete).
- The USMSStudentDataReadWrite least-privilege decay example.

The most useful idea in this lab was that access in AWS has **two independent axes**. IAM answers *who may call what*, and security groups and routing answer *what can reach what*. A broken IAM permission usually announces itself with an explicit `AccessDenied` error message, while a broken network path just **times out**. Telling those two symptoms apart is the quickest way to know which axis to look at.

A recurring theme was **controls nobody wrote**. The default allow-all egress rule on five security groups, the `10.0.0.0/16` SSH rule on `usms-app-sg`, and trust policies with no `aws:SourceAccount`/`aws:SourceArn` condition were never deliberate decisions. They were defaults and convenience rules that stayed. Writing them down explicitly (egress to a prefix list or a security group, SSH only from `usms-bastion-sg`, scoped trust) is what turned them into decisions.

Because Floci does not enforce IAM or security groups, nothing here could be proven by watching a call fail. Every claim was proven by **reading configuration** and reasoning about it, for example the five independent controls behind "`usms-db-01` is unreachable". That felt weaker at first, but it is how a real review works: you cannot attack production to check it.

I also learned **cutover discipline**: authorise the new egress rule *before* revoking the old one, and rotate keys as create → move → deactivate → delete, so there is never a moment when nothing works and there is always a way back. Finally, `USMSStudentDataReadWrite` showed how least privilege **decays**. One convenient shared policy ended up giving `s3:DeleteObject` to three roles that never needed it, and the fix was to split it into a read-only policy rather than keep adding to it.

---

## 8. Review Questions

The answers to the review questions are in [notes/lab-09-notes.md](notes/lab-09-notes.md).

---

## Summary - KEEP vs CLEAN UP

| KEEP | CLEAN UP (after submission only) |
|---|---|
| USMSStudentDataReadOnly, USMSDeployBase, USMSPermissionsBoundary | usms-breakglass-role (Exercise 2 practice) |
| usms-transcripts-reader-role, usms-deploy-role | outputs/lab-09-scoped-session.json |
| usms-ecs-task-role (scoped trust) | outputs/lab-09-pre/post-*.txt |
| usms-bastion-sg, written egress rules | outputs/usms-dev-01-access-key.json (old key file) |
| IMDSv2 on usms-web-01, single access key | outputs/lab-09-imds-before.json |
| policies/, scripts/utilities/, configs/lab-09.env | |

**Do not run `scripts/cleanup/lab-09-cleanup.sh`** until the entire course is complete.

---

