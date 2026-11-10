# Lab 09 - Independent Exercises

> Run every command from `aws-floci-course/`. Each block reloads the env files it needs, so it also works in a fresh terminal.

```bash
for f in configs/course.env configs/lab-0{1..6}.env configs/lab-09.env; do source "$f"; done
```

---

### Exercise 1 - Basic: finish the egress work on the web tier

**Task:** write `policies/usms-app-sg-egress.json` for `usms-app-sg`. It must cover S3 (gateway endpoint), HTTPS to AWS service endpoints (including STS), HTTP to the load balancer (group reference), PostgreSQL to the db tier, and DNS (UDP and TCP to `10.0.0.2`). Authorise before revoking the default.

**Part 1 - the document** (an unquoted heredoc, so the group IDs and the prefix list are filled in)

```bash
for f in configs/course.env configs/lab-0{2,5}.env; do source "$f"; done

# the S3 gateway endpoint (usms-s3-endpoint) is reached through the S3 managed prefix list
S3_PL=$(aws ec2 describe-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.${AWS_REGION_COURSE}.s3" \
  --query 'PrefixLists[0].PrefixListId' --output text)

echo "s3 pl: ${S3_PL:?}   alb sg: ${USMS_ALB_SG:?}   db sg: ${USMS_DB_SG:?}   app sg: ${USMS_APP_SG:?}"

cat > policies/usms-app-sg-egress.json << EOF
[
  {
    "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
    "PrefixListIds": [
      { "PrefixListId": "${S3_PL}", "Description": "HTTPS to S3 through the usms-s3-endpoint gateway endpoint" }
    ]
  },
  {
    "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
    "IpRanges": [
      { "CidrIp": "0.0.0.0/0", "Description": "HTTPS to AWS service endpoints incl. STS - no interface endpoints exist in usms-vpc" }
    ]
  },
  {
    "IpProtocol": "tcp", "FromPort": 80, "ToPort": 80,
    "UserIdGroupPairs": [
      { "GroupId": "${USMS_ALB_SG}", "Description": "HTTP to the USMS load balancer" }
    ]
  },
  {
    "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
    "UserIdGroupPairs": [
      { "GroupId": "${USMS_DB_SG}", "Description": "PostgreSQL to the data tier" }
    ]
  },
  {
    "IpProtocol": "udp", "FromPort": 53, "ToPort": 53,
    "IpRanges": [ { "CidrIp": "10.0.0.2/32", "Description": "DNS to the VPC resolver (VPC base + 2)" } ]
  },
  {
    "IpProtocol": "tcp", "FromPort": 53, "ToPort": 53,
    "IpRanges": [ { "CidrIp": "10.0.0.2/32", "Description": "DNS over TCP to the VPC resolver (large responses)" } ]
  }
]
EOF

python3 -m json.tool policies/usms-app-sg-egress.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-app-sg-egress.json      # expect 0
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-52-30.png>)

**Part 2 - authorise first, then revoke the default**

```bash
# 1. authorise the replacement FIRST - there is never a moment with no egress
aws ec2 authorize-security-group-egress \
  --group-id "$USMS_APP_SG" \
  --ip-permissions file://policies/usms-app-sg-egress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text

# 2. only then revoke the default allow-all
aws ec2 revoke-security-group-egress \
  --group-id "$USMS_APP_SG" \
  --ip-permissions file://policies/usms-egress-allow-all.json \
  --query 'Return' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-52-50.png>)

**Part 3 - verify**

```bash
aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
  --query 'SecurityGroups[0].IpPermissionsEgress[].{Proto:IpProtocol,Port:FromPort,CIDR:IpRanges[0].CidrIp,Group:UserIdGroupPairs[0].GroupId,PrefixList:PrefixListIds[0].PrefixListId}' \
  --output table

echo "allow-all egress rules left: $(aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
  --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1`])' --output text)"   # expect 0
```
![alt text](<../../screenshots/Screenshot from 2026-11-10 14-53-46.png>)

**My result:** six rule IDs were authorised and the revoke returned `True`. 0 allow-all rules remain.

```
|    CIDR     |         Group          | Port  | PrefixList   |  Proto  |
|  None       |  None                  |  443  |  pl-63a5400a |  tcp    |
|  0.0.0.0/0  |  None                  |  443  |  None        |  tcp    |
|  None       |  sg-4fd856db37444e530  |  80   |  None        |  tcp    |
|  None       |  sg-1b3bee73c661e8abd  |  5432 |  None        |  tcp    |
|  10.0.0.2/32|  None                  |  53   |  None        |  udp    |
|  10.0.0.2/32|  None                  |  53   |  None        |  tcp    |
```

> **Notes.**
> - **DNS needs both protocols.** UDP/53 alone breaks any DNS answer too large for one UDP packet; the resolver then retries over TCP/53.
> - **`10.0.0.2` is the VPC resolver.** It is always the VPC base address plus two (`10.0.0.0/16` → `10.0.0.2`).
> - **The S3 rule is currently redundant.** The `0.0.0.0/0:443` rule already covers S3, because `usms-vpc` has no interface endpoints for STS or the other AWS APIs. The prefix-list rule is still worth keeping: once STS, ECR and Logs interface endpoints exist, the `0.0.0.0/0` rule can be replaced by the endpoint security group, and S3 keeps working through the prefix list.
> - **No return-traffic rules are needed.** Security groups are stateful, so replies to inbound HTTP don't need egress rules.

---

### Exercise 2 - Intermediate: the break-glass role, and the two findings this lab left open

#### Part A - `usms-breakglass-role`

**Requirements:**
- trusts `usms-admin-01` only, and only with MFA plus an external ID
- the shortest session AWS allows (3600 s)
- capped by `USMSPermissionsBoundary`
- may only suspend or resume scaling on the enrolment service, and look at it

**The trust policy and the permissions**

```bash
for f in configs/course.env configs/lab-01.env configs/lab-09.env; do source "$f"; done
echo "account: ${USMS_ACCOUNT_ID:?}  admin: ${USMS_ADMIN_USER:?}  boundary: ${USMS_POLICY_BOUNDARY_ARN:?}"

BREAKGLASS_EXTERNAL_ID="usms-breakglass-$(date +%Y)"

cat > policies/trust-breakglass.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AdminOnlyWithMfaAndTheExternalId",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${USMS_ACCOUNT_ID}:user/${USMS_ADMIN_USER}" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "Bool":          { "aws:MultiFactorAuthPresent": "true" },
        "NumericLessThan": { "aws:MultiFactorAuthAge": "900" },
        "StringEquals":  { "sts:ExternalId": "${BREAKGLASS_EXTERNAL_ID}" }
      }
    }
  ]
}
EOF

cat > policies/usms-breakglass-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SeeTheScalableTargetAndWhatItIsDoing",
      "Effect": "Allow",
      "Action": [
        "application-autoscaling:DescribeScalableTargets",
        "application-autoscaling:DescribeScalingActivities",
        "application-autoscaling:DescribeScalingPolicies",
        "ecs:DescribeServices"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SuspendOrResumeScalingOnTheEnrolmentServiceOnly",
      "Effect": "Allow",
      "Action": "application-autoscaling:RegisterScalableTarget",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "application-autoscaling:service-namespace": "ecs",
          "application-autoscaling:scalable-dimension": "ecs:service:DesiredCount"
        }
      }
    },
    {
      "Sid": "NeverChangeTheScalingRulesThemselves",
      "Effect": "Deny",
      "Action": [
        "application-autoscaling:PutScalingPolicy",
        "application-autoscaling:DeleteScalingPolicy",
        "application-autoscaling:DeregisterScalableTarget",
        "application-autoscaling:PutScheduledAction",
        "application-autoscaling:DeleteScheduledAction"
      ],
      "Resource": "*"
    }
  ]
}
EOF

for d in policies/trust-breakglass.json policies/usms-breakglass-policy.json; do
  python3 -m json.tool "$d" > /dev/null && echo "valid: $d"
done
grep -c '\$' policies/trust-breakglass.json policies/usms-breakglass-policy.json   # expect 0 and 0
```

**Create the policy and the role**

```bash
# safe to re-run: look each one up first and only create what is missing
for f in configs/course.env configs/lab-01.env configs/lab-09.env; do source "$f"; done

BG_POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSBreakGlassScaling'].Arn | [0]" --output text)

if [ -z "$BG_POLICY_ARN" ] || [ "$BG_POLICY_ARN" = "None" ]; then
  BG_POLICY_ARN=$(aws iam create-policy \
    --policy-name USMSBreakGlassScaling \
    --description "Break-glass: suspend/resume enrolment autoscaling only" \
    --policy-document file://policies/usms-breakglass-policy.json \
    --tags Key=Project,Value=USMS Key=Lab,Value=09 \
    --query Policy.Arn --output text)
  echo "created policy"
else
  # already exists - make the stored document match the file (keeps at most 2 versions)
  for v in $(aws iam list-policy-versions --policy-arn "$BG_POLICY_ARN" \
               --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$BG_POLICY_ARN" --version-id "$v"
  done
  aws iam create-policy-version --policy-arn "$BG_POLICY_ARN" \
    --policy-document file://policies/usms-breakglass-policy.json --set-as-default \
    --query 'PolicyVersion.VersionId' --output text
  echo "policy already existed - document refreshed"
fi
echo "BG_POLICY_ARN = ${BG_POLICY_ARN:?policy lookup failed}"

if aws iam get-role --role-name usms-breakglass-role > /dev/null 2>&1; then
  # already exists - re-apply the trust policy, session cap and boundary
  aws iam update-assume-role-policy --role-name usms-breakglass-role \
    --policy-document file://policies/trust-breakglass.json > /dev/null
  # Floci's update-role response cannot be parsed by the CLI ('UpdateRoleResult', exit 255);
  # the cap was set by create-role, so report what is stored instead of failing
  aws iam update-role --role-name usms-breakglass-role --max-session-duration 3600 > /dev/null 2>&1 \
    || echo "update-role not supported on this Floci build - MaxSessionDuration is $(aws iam get-role \
         --role-name usms-breakglass-role --query 'Role.MaxSessionDuration' --output text)"
  aws iam put-role-permissions-boundary --role-name usms-breakglass-role \
    --permissions-boundary "$USMS_POLICY_BOUNDARY_ARN" > /dev/null
  echo "role already existed - trust, session cap and boundary re-applied"
else
  aws iam create-role \
    --role-name usms-breakglass-role \
    --description "Break-glass: MFA + external ID, 1h max, capped by USMSPermissionsBoundary" \
    --assume-role-policy-document file://policies/trust-breakglass.json \
    --permissions-boundary "$USMS_POLICY_BOUNDARY_ARN" \
    --max-session-duration 3600 \
    --tags Key=Project,Value=USMS Key=Lab,Value=09 Key=Tier,Value=breakglass \
    --query Role.Arn --output text
fi

# attaching an already-attached policy is a no-op, so this is always safe
aws iam attach-role-policy --role-name usms-breakglass-role --policy-arn "$BG_POLICY_ARN" \
  && echo "attached: $(aws iam list-attached-role-policies --role-name usms-breakglass-role \
       --query 'AttachedPolicies[].PolicyName' --output text)"
```

**Verify**

```bash
aws iam get-role --role-name usms-breakglass-role \
  --query 'Role.{Name:RoleName,MaxSession:MaxSessionDuration,Boundary:PermissionsBoundary.PermissionsBoundaryArn,Principal:AssumeRolePolicyDocument.Statement[0].Principal.AWS,Conditions:AssumeRolePolicyDocument.Statement[0].Condition}' \
  --output json
aws iam list-attached-role-policies --role-name usms-breakglass-role --query 'AttachedPolicies[].PolicyName' --output text

# negative test - on real AWS both calls are AccessDenied / ValidationError
aws sts assume-role --role-arn "arn:aws:iam::${USMS_ACCOUNT_ID}:role/usms-breakglass-role" \
  --role-session-name bg-test --query 'AssumedRoleUser.Arn' --output text
aws sts assume-role --role-arn "arn:aws:iam::${USMS_ACCOUNT_ID}:role/usms-breakglass-role" \
  --role-session-name bg-test --external-id "$BREAKGLASS_EXTERNAL_ID" --duration-seconds 7200 \
  --query 'Credentials.Expiration' --output text
```

**The break-glass action itself** (incident only: do **not** run it to test)

```bash
# freeze the enrolment service at its current size: no scale-in, no scale-out
aws application-autoscaling register-scalable-target \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "$USMS_SCALABLE_RESOURCE_ID" \
  --suspended-state DynamicScalingInSuspended=true,DynamicScalingOutSuspended=true,ScheduledScalingSuspended=true
# resume afterwards: the same call with all three set to false
```

**My result:** `MaxSession` is `3600`, the trust has all three conditions, and `USMSBreakGlassScaling` is attached. `Boundary` shows `null`.

> **Notes.**
> - **Why each control is there.**
>   - **MFA, and an MFA age under 15 minutes:** a stolen access key alone is not enough.
>   - **The external ID:** the person must also know an out-of-band secret kept in the runbook, so the role can't be assumed by accident.
>   - **3600 s:** the shortest session AWS allows, so break-glass access expires on its own.
>   - **The boundary:** even if someone attaches a broader policy to the role later, it can't exceed the USMS ceiling.
>   - **The Deny:** break-glass can *pause* scaling but can never rewrite the scaling rules.
> - **Why suspend rather than set the desired count.** "Suspend" is `RegisterScalableTarget --suspended-state` because Lab 06 scales ECS through Application Auto Scaling, not an EC2 Auto Scaling group.
> - **Floci limitations.** Floci does not store the permissions boundary (`Boundary: null`, the same as Step 8). It also does not enforce trust conditions or `MaxSessionDuration`: both negative tests *succeeded*, and a 7200 s session was issued. On real AWS the first call fails `AccessDenied` (no MFA, no external ID), and the second fails `ValidationError` (the duration exceeds the role's maximum).

#### Part B - the remaining unconditioned trust policies

The inventory from Step 4 was taken *before* Step 8, so first refresh it. Then run the audit:

```bash
# re-run Step 4 Part 2 (the inventory generator in README.md) - it overwrites outputs/lab-09-identity-inventory.json
./scripts/utilities/usms-iam-audit.sh | grep -E '^[a-zA-Z]|HIGH'
```

**Before:** `HIGH=6`. These six service-principal trust policies had no `Condition`:

| Role | Service principal | Decision | Why |
|---|---|---|---|
| `usms-ecs-exec-role` | `ecs-tasks.amazonaws.com` | **FIXED** | ECS sends `aws:SourceAccount`/`aws:SourceArn`, the same as the Step 8 task-role fix |
| `usms-ec2-app-role` | `ec2.amazonaws.com` | **ACCEPTED** | EC2 sends no source keys when it assumes an instance-profile role, so a condition would lock the instance out |
| `usms-eks-node-role` | `ec2.amazonaws.com` | **ACCEPTED** | EKS nodes are EC2 instances: same reason |
| `usms-lambda-exec-role` | `lambda.amazonaws.com` | **ACCEPTED** | Lambda does not supply `aws:SourceArn` when it assumes an execution role |
| `usms-eks-cluster-role` | `eks.amazonaws.com` | **ACCEPTED** | No documented confused-deputy keys for the cluster role. Re-check when AWS documents them |
| `AWSServiceRoleForEcsApplicationAutoscaling` | `ecs.application-autoscaling…` | **ACCEPTED** | Service-linked role: AWS owns the trust policy, and it can't be edited or given a boundary |

**Fix the one that can be fixed**

```bash
for f in configs/course.env configs/lab-01.env; do source "$f"; done

cat > policies/trust-ecs-exec-scoped.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcsTasksMayAssumeTheExecutionRoleForThisAccountOnly",
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${USMS_ACCOUNT_ID}" },
        "ArnLike": { "aws:SourceArn": "arn:aws:ecs:${AWS_REGION_COURSE}:${USMS_ACCOUNT_ID}:*" }
      }
    }
  ]
}
EOF
python3 -m json.tool policies/trust-ecs-exec-scoped.json > /dev/null && echo "valid JSON"

aws iam update-assume-role-policy --role-name usms-ecs-exec-role \
  --policy-document file://policies/trust-ecs-exec-scoped.json

# the service must still be healthy after the change
aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount}' --output json
```

**Formally accept the rest:** [configs/usms-accepted-findings.txt](../../configs/usms-accepted-findings.txt)

Each acceptance names an **owner**, a **review-by date** and a **reason with its mitigation**. An acceptance with no expiry is just a finding someone stopped looking at.

```
# role | text the finding starts with | owner | review-by | reason
usms-ec2-app-role | trust policy: service principal ec2.amazonaws.com | usms-admin-01 | 2027-05-10 | EC2 does not send aws:SourceArn/aws:SourceAccount ... Mitigated: no user, group or role is granted iam:PassRole on it ...
...
```

**Update the audit script:** `scripts/utilities/usms-iam-audit.sh` now takes an optional second argument, the accepted-findings file (default `configs/usms-accepted-findings.txt`). When a finding matches a line in that file:
- it prints as `ACCEPTED` together with its owner, date and reason
- it is counted in `ACCEPTED=`, not in `HIGH`/`MED`, and no longer fails the exit code
- once its review-by date has passed, it comes back as `HIGH ... (acceptance EXPIRED <date>)`

The core of the change:

```python
def acceptance(role, text):
    for prefix, owner, review_by, reason in accepted.get(role, []):
        if text.startswith(prefix):
            return owner, review_by, reason
    return None
...
acc = acceptance(name, text)
if acc and acc[1] >= today:                       # accepted and not expired
    lines.append(f"    ACCEPTED {text}")
    lines.append(f"             owner={owner} review-by={review_by}: {reason}")
    accepted_n += 1
    continue
if acc:                                           # accepted, but the review date passed
    sev, text = "HIGH", f"{text}  (acceptance EXPIRED {acc[1]})"
```

```bash
./scripts/utilities/usms-iam-audit.sh | grep -E '^[a-zA-Z]|HIGH|ACCEPTED|owner='; echo "exit=${PIPESTATUS[0]}"
```

**My result:** `HIGH=0  MED=33  ACCEPTED=6  roles=11`, exit code `0` (it was `1` before). `usms-ecs-exec-role` now shows no trust finding, and `usms-enrolment-svc` is still `ACTIVE` with 2/2 tasks running.

> **Note:** I checked the mitigation in each acceptance against the inventory. No user, group or role in the account is granted `iam:PassRole` on these roles. The only PassRole grant is `USMSDeployBase` on `usms-deploy-role`, scoped to three ECS roles and to `ecs-tasks.amazonaws.com`, and it explicitly denies passing anything to `ec2.amazonaws.com`. So nobody can hand these roles to a new resource, which is what a confused-deputy attack would need.

**[ Screenshot: Exercise 2 – break-glass role and updated audit script ]**

&nbsp;
&nbsp;
&nbsp;

---

### Exercise 3 - Problem solving: the exposure report

**Task:** classify every ENI in the VPC as `EXPOSED` or `ISOLATED`, using route tables, public addresses and security group ingress.

**Rule:** an ENI is `EXPOSED` only when **all three** independent conditions hold. If any one is missing it is `ISOLATED`, and the report names every control that is doing the isolating.

| # | Condition | Read from |
|---|---|---|
| 1 | It has a public address | `Association.PublicIp` on the ENI, **or** `PublicIpAddress` on the attached instance |
| 2 | Its subnet routes `0.0.0.0/0` to an `igw-` | the subnet's explicitly associated route table, else the VPC's main table |
| 3 | One of its groups admits `0.0.0.0/0` or `::/0` | `IpPermissions` of every group on the ENI |

**The script:** [scripts/utilities/usms-exposure-report.sh](../../scripts/utilities/usms-exposure-report.sh). It's read-only, always exits 0, and takes the VPC ID from `$1` or `lab-02.env`.

```bash
chmod +x scripts/utilities/usms-exposure-report.sh
bash -n scripts/utilities/usms-exposure-report.sh && echo "syntax OK"
./scripts/utilities/usms-exposure-report.sh | tee outputs/lab-09-exposure-report.txt
```

**My result:**

```
== USMS exposure report: vpc-2d23ccbb ==

ENI                     ATTACHED TO    SUBNET                   PRIVATE      PUBLIC     VERDICT
eni-ab0f3b5587af18397   usms-db-02     usms-private-subnet-b    172.19.0.3   NONE       ISOLATED
                          why: no public address; no igw route (rtb-cc8c571e); no public-CIDR ingress
eni-92196bc01fa8b3e3c   usms-web-01    usms-public-subnet-a     172.19.0.3   127.0.0.1  EXPOSED
                          why: internet -> 127.0.0.1 via igw-ee6a0842, admitted by usms-app-sg:tcp/443, usms-app-sg:tcp/80
eni-d6b8aa7713322c0d5   usms-db-01     usms-private-subnet-a    172.19.0.5   NONE       ISOLATED
                          why: no public address; no igw route (rtb-cc8c571e); no public-CIDR ingress

ENIs=3  EXPOSED=1  ISOLATED=2
```

> **Notes.**
> - **The second front door.** `usms-web-01` is the only `EXPOSED` ENI. That is the Step 17 "second front door" finding, now produced by a script instead of by reasoning. Both database ENIs are isolated by **all three** controls, so any two of them could fail and they would still be unreachable.
> - **Why the instance's public IP is read too.** Floci puts the public IP on the *instance* (`PublicIpAddress`), not on the ENI's `Association`. A script that read only the ENI would wrongly call `usms-web-01` isolated.
> - **The ALB is missing.** `usms-enrolment-alb` is not listed because Floci doesn't create ENIs for load balancers. On real AWS it would appear as `EXPOSED`, which is correct: it's the one front door that is meant to exist.

**[ Screenshot: Exercise 3 – exposure report output ]**

&nbsp;
&nbsp;
&nbsp;

---

### Exercise 4 - Challenge: the security review, written for someone else to act on

**The memo:** [notes/lab-09-security-review.md](../../notes/lab-09-security-review.md)

It's written for the USMS platform owner (`usms-admin-01`): someone who has to *act* on it, not grade it. So it leads with the bottom line, and every section ends with an **Action** line. It covers:

1. **The second front door:** `usms-web-01` meets all three exposure conditions and holds a role that can delete student data.
2. **What egress control bought:** the before/after per group, what it now blocks (reverse shells, sideways movement, odd ports), and what it doesn't (HTTPS out to `0.0.0.0/0`, exfiltration through S3 or DNS).
3. **The transcripts access table:** seven principals that can reach `usms-student-data`.
4. **The detection roadmap:** CloudTrail, GuardDuty and flow logs are **all off today** (`trailList: []`, `DetectorIds: []`, `FlowLogs: []`). The roadmap is phased from week 1 to quarterly.
5. **Paper design:** moving the web tier behind the load balancer, in six reversible steps with a rollback.

**How the facts were gathered**

```bash
for f in configs/course.env configs/lab-0{1..6}.env; do source "$f"; done
./scripts/utilities/usms-exposure-report.sh                                   # section 1
for g in "$USMS_ALB_SG" "$USMS_ENROLMENT_SG" "$USMS_DB_SG" "$USMS_APP_SG"; do  # section 2
  aws ec2 describe-security-groups --group-ids "$g" \
    --query 'SecurityGroups[0].[GroupName,IpPermissionsEgress[].[IpProtocol,FromPort]]' --output json
done
for p in USMSStudentDataReadWrite USMSStudentDataReadOnly; do                  # section 3
  aws iam list-entities-for-policy --policy-arn "arn:aws:iam::${USMS_ACCOUNT_ID}:policy/$p" \
    --query 'PolicyRoles[].RoleName' --output text
done
for g in usms-auditors usms-admins usms-qa usms-developers; do
  aws iam list-attached-group-policies --group-name "$g" --query 'AttachedPolicies[].PolicyName' --output text
done
aws cloudtrail describe-trails; aws guardduty list-detectors; aws ec2 describe-flow-logs   # section 4
```

**Excerpt: the transcripts access table**

| Principal | How it gets access | Read | Write/Delete | Needed? |
|---|---|---|---|---|
| `usms-ecs-task-role` | `USMSStudentDataReadWrite` | ✅ | ✅ | **Yes**: the enrolment service |
| `usms-ec2-app-role` (`usms-web-01`) | `USMSStudentDataReadWrite` | ✅ | ✅ | Read only. The web tier never deletes |
| `usms-eks-node-role` (every EKS node) | `USMSStudentDataReadWrite` | ✅ | ✅ | **No**: every pod on every node inherits it |
| `usms-transcripts-reader-role` | `USMSStudentDataReadOnly` | ✅ | ❌, explicit deny | **Yes** |
| `usms-lambda-exec-role` | `USMSLambdaBasic` | ✅ | ❌ | Yes. Narrow it to a prefix |
| `usms-audit-01`, `usms-intern-01` | `USMSReadOnly`: `s3:Get*` on `"*"` | ✅ | ❌ | **No**. An intern can read every transcript |
| `usms-dev-01`, `usms-admin-01` | `USMSDeveloperBase`: `s3:List*` | ❌, keys only | ❌ | Keys reveal student IDs |

> **Note:** the intern finding was not in the lab steps. It turned up only because the table asks *who*, not *which role*. `ReadOnlyAccess` and `USMSReadOnly` look harmless by name, but "read-only" on `Resource "*"` includes `s3:GetObject` on personal data. The Exercise 5 bucket policy fixes it without touching the AWS-managed policy.

**[ Screenshot: Exercise 4 – review memo excerpt ]**

&nbsp;
&nbsp;
&nbsp;

---

### Exercise 5 - Integration: the bucket policy the S3 configuration lab will apply

**Task:** write `scripts/utilities/usms-bucket-policy-draft.sh`. It must derive the bucket name and the principal list from existing policy documents, and emit `outputs/lab-09-bucket-policy-draft.json`.

**Where each value comes from** (nothing is typed in by hand)

| Value | Derived from |
|---|---|
| Bucket name | the `arn:aws:s3:::` Resources in `policies/usms-student-data-*-policy.json`. The script fails if they name more than one bucket |
| Read-write roles | every role whose attached policy **document** allows `s3:PutObject` on the bucket |
| Read-only roles | every role whose attached document allows only reads on the bucket |
| List permission | only the roles whose own document already allows `s3:ListBucket` |
| Management principal | `USMS_ADMIN_USER` from `lab-01.env`, so the deny can't lock out the admin |

**The script:** [scripts/utilities/usms-bucket-policy-draft.sh](../../scripts/utilities/usms-bucket-policy-draft.sh). It writes the draft and **applies nothing**.

```bash
chmod +x scripts/utilities/usms-bucket-policy-draft.sh
bash -n scripts/utilities/usms-bucket-policy-draft.sh && echo "syntax OK"
./scripts/utilities/usms-bucket-policy-draft.sh

python3 -m json.tool outputs/lab-09-bucket-policy-draft.json > /dev/null && echo "valid JSON"
grep -c '\$' outputs/lab-09-bucket-policy-draft.json     # expect 0

python3 -c "
import json; d = json.load(open('outputs/lab-09-bucket-policy-draft.json'))
for s in d['Statement']:
    who = s['Principal'] if s['Principal'] == '*' else [p.split('/')[-1] for p in s['Principal']['AWS']]
    print(f\"{s['Effect']:<5} {s['Sid']:<48} {who}\")"
```

**My result:**

```
bucket      : usms-student-data
read-write  : usms-ec2-app-role, usms-ecs-task-role, usms-eks-node-role
read-only   : usms-lambda-exec-role, usms-transcripts-reader-role
management  : arn:aws:iam::000000000000:user/usms-admin-01
statements  : 6
written     : outputs/lab-09-bucket-policy-draft.json  (DRAFT - not applied)

Deny  DenyAnyRequestNotOverTLS                         *
Deny  DenyEveryPrincipalNotDerivedFromTheRolePolicies  *
Allow RolesThatAlreadyListMayListTheBucket             ['usms-ec2-app-role', 'usms-ecs-task-role', 'usms-eks-node-role', 'usms-transcripts-reader-role']
Allow ReadWriteRolesMayReadAndWriteObjects             ['usms-ec2-app-role', 'usms-ecs-task-role', 'usms-eks-node-role']
Allow ReadOnlyRolesMayOnlyReadObjects                  ['usms-lambda-exec-role', 'usms-transcripts-reader-role']
Deny  NobodyDeletesTheBucketOrItsPolicy                *
```

The S3 lab applies it with:

```bash
aws s3api put-bucket-policy --bucket usms-student-data \
  --policy file://outputs/lab-09-bucket-policy-draft.json
```

> **Notes.**
> - **The bucket doesn't exist yet** (`NoSuchBucket`), which is why this is a draft.
> - **The draft never grants a role more than its own identity policy does.** In the same account, a bucket-policy `Allow` is enough *on its own*, so a careless bucket policy widens access. My first version gave `usms-lambda-exec-role` `s3:ListBucket`, which its own `USMSLambdaBasic` doesn't allow. The list statement now goes only to roles that already had it.
> - **The real protection is the `DenyEveryPrincipalNotDerivedFromTheRolePolicies` statement.** An explicit deny beats any allow, so it removes `usms-audit-01` and `usms-intern-01` (`s3:Get*` on `"*"`) from the transcripts. That's the Exercise 4 finding, closed from the bucket side.
> - **Rerun the script whenever IAM changes.** The principal list comes from IAM: if `usms-eks-node-role` loses `USMSStudentDataReadWrite` (memo action 3), the next run drops it from the policy automatically.

**[ Screenshot: Exercise 5 – bucket policy draft generated ]**

&nbsp;
&nbsp;
&nbsp;
