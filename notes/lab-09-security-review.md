# USMS Security Review: Findings and Actions

**To:** USMS platform owner (`usms-admin-01`)
**From:** Lab 09 security review
**Date:** 2026-11-10
**Scope:** account `000000000000`, `usms-vpc` (`vpc-2d23ccbb`), IAM, security groups, `usms-student-data`

**Bottom line:** the data tier is well protected, but the application has a second way in from the internet that bypasses the load balancer. Student transcripts can also be read by more people than the system needs, including an intern. Both can be fixed without downtime. Actions are listed at the end of each section and summarised in the final table.

> **How this was checked:** Floci does not enforce IAM or security groups, so every finding below comes from reading configuration (rules, routes, policy documents), not from watching an attack succeed or fail. The evidence files are named at the end.

---

## 1. The second front door

**Finding.** USMS is meant to have one internet entry point: `usms-enrolment-alb`. There are two. `usms-web-01` (`i-9019ac0987cff66f5`) is reachable from the internet directly:

| Condition | `usms-web-01` | Source |
|---|---|---|
| Has a public address | yes (`usms-public-subnet-a`, auto-assign on) | instance + subnet |
| Subnet routes `0.0.0.0/0` to an internet gateway | yes, `igw-ee6a0842` | route table |
| Security group admits the internet | yes, `usms-app-sg`: tcp/80 and tcp/443 from `0.0.0.0/0` | ingress rules |

All three must be true for exposure, and all three are. The exposure report classifies this ENI as the **only** `EXPOSED` interface in the VPC. Both database ENIs are `ISOLATED` by all three controls at once.

**Why it matters.** Traffic to `usms-web-01` skips everything the load balancer gives us: one place to attach TLS and a WAF, health-checked targets, and access logs. The instance also holds `usms-ec2-app-role`, which can **read, write and delete** student data. An SSRF or RCE bug in the web app is therefore one hop from the transcripts bucket.

**Also found:** `usms-app-sg` has duplicate rules (two identical tcp/443 internet rules and two identical tcp/22 bastion rules). They are harmless, but they make audits noisy.

**Action:** move the web tier behind the load balancer (paper design in section 5). Until then, keep IMDSv2 required on `usms-web-01` (see the limitation note in section 4) and delete the duplicate rules.

---

## 2. What the egress control bought us

**Change made.** Every application security group lost its allow-all egress rule. Each one now has an explicit list of where it may connect:

| Group | Before | After |
|---|---|---|
| `usms-alb-sg` | all traffic, anywhere | tcp/80 to `usms-enrolment-sg` only (group reference) |
| `usms-enrolment-sg` | all traffic, anywhere | tcp/443 only |
| `usms-db-sg` | all traffic, anywhere | tcp/443 only (OS updates through `usms-nat`) |
| `usms-app-sg` | all traffic, anywhere | S3 prefix list `pl-63a5400a`:443, tcp/443 (AWS APIs incl. STS), tcp/80 to the ALB, tcp/5432 to `usms-db-sg`, DNS udp+tcp/53 to `10.0.0.2` |

**What it blocks.** A compromised container or instance can no longer:
- open a reverse shell on an arbitrary port
- reach internal hosts on ports it has no business using (for example SSH sideways)
- send data out over anything except HTTPS and DNS

The load balancer can now only talk to the enrolment tasks, so a load-balancer compromise has nowhere else to go.

**What it does not block.** All four groups still allow tcp/443 to `0.0.0.0/0`, because there are no interface endpoints in `usms-vpc` for STS, ECR or CloudWatch Logs. So an attacker who controls the code can still:
- send data out over HTTPS to a server they own
- write data into their own S3 bucket, which the S3 prefix list allows
- hide data in DNS queries to `10.0.0.2`

Egress control removed the easy paths. It did not make data exfiltration impossible.

**Action, in order of value:**
1. Add interface endpoints for STS, ECR and Logs, then replace `0.0.0.0/0:443` with the endpoints' security group.
2. Attach an endpoint policy to `usms-s3-endpoint` that only allows `usms-student-data`.
3. Turn on Route 53 Resolver DNS Firewall.

---

## 3. Who can read student transcripts

The transcripts bucket is `usms-student-data`. This is everyone who can reach its objects today, worked out from the attached policy documents:

| Principal | How it gets access | Read | Write/Delete | Needed? |
|---|---|---|---|---|
| `usms-ecs-task-role` | `USMSStudentDataReadWrite` | ✅ | ✅ | **Yes**: the enrolment service |
| `usms-ec2-app-role` (`usms-web-01`) | `USMSStudentDataReadWrite` | ✅ | ✅ | Read only. The web tier never deletes |
| `usms-eks-node-role` (every EKS node) | `USMSStudentDataReadWrite` | ✅ | ✅ | **No**: every pod on every node inherits it |
| `usms-transcripts-reader-role` | `USMSStudentDataReadOnly` (Lab 09) | ✅ | ❌, explicit deny | **Yes**: this is the role built for it |
| `usms-lambda-exec-role` | `USMSLambdaBasic` | ✅ | ❌ | Yes, for notifications. Narrow it to a prefix |
| `usms-audit-01`, `usms-intern-01` (`usms-auditors`) | `ReadOnlyAccess` + `USMSReadOnly`: `s3:Get*` on `"*"` | ✅ | ❌ | **No**. An intern can read every transcript |
| `usms-dev-01`, `usms-admin-01` | `USMSDeveloperBase`: `s3:List*` only | ❌, keys only | ❌ | Listing reveals student IDs in object keys |

The highest-risk entries:
- **`usms-intern-01`**: a person with no need, reading personal data.
- **`usms-eks-node-role`**: write and delete access for every pod on every node.

The bucket policy drafted in Exercise 5 (`outputs/lab-09-bucket-policy-draft.json`) denies every principal that isn't derived from the role policies. Applying it removes the auditor and intern rows in one step, without editing the AWS-managed `ReadOnlyAccess` policy.

**Action:**
1. Apply the bucket policy in the S3 lab.
2. Detach `USMSStudentDataReadWrite` from `usms-eks-node-role` and use IRSA or Pod Identity for the one workload that needs it.
3. Give `usms-ec2-app-role` `USMSStudentDataReadOnly` instead of read-write.

---

## 4. Detection roadmap

**What exists today:** nothing. No CloudTrail trail, no GuardDuty detector, and no VPC flow logs are configured. If the second front door were used tonight, we would not know.

| Phase | Turn on | Detects | Cost/effort |
|---|---|---|---|
| **Week 1** | CloudTrail, multi-region, to a locked bucket with log-file validation | Who did what in IAM/EC2/S3; any use of `usms-breakglass-role` | Low |
| **Week 1** | Alarm on any `AssumeRole` of `usms-breakglass-role`, and on `PutBucketPolicy`, `UpdateAssumeRolePolicy`, `AuthorizeSecurityGroupIngress` with `0.0.0.0/0` | The changes this review just made being undone | Low |
| **Week 2** | GuardDuty, including S3 protection | Credential misuse from unusual locations, EC2 credentials used outside EC2, crypto-mining | Low |
| **Week 2** | S3 data events on `usms-student-data` | Every transcript read, by principal | Medium (volume) |
| **Month 1** | VPC flow logs on `usms-public-subnet-a` and the private subnets | Connections to `usms-web-01` that bypass the ALB; unexpected egress | Medium |
| **Month 1** | IAM Access Analyzer (external + unused access) | New cross-account trust; the unused `s3:DeleteObject` grants found in this review | Low |
| **Quarter** | Re-run `usms-iam-audit.sh`, `usms-sg-audit.sh` and `usms-exposure-report.sh`, and review `configs/usms-accepted-findings.txt` (review-by `2027-05-10`) | Drift back to the old state; accepted risks that have expired | Low |

**Known limitation:** Floci accepts but does not enforce or store IMDSv2 (`UnsupportedOperation`), permissions boundaries, trust-policy conditions, or `MaxSessionDuration`. On real AWS, verify each of these with a real deny before closing this review.

---

## 5. Paper design: moving the web tier behind the load balancer

**Goal:** make `usms-enrolment-alb` the only internet entry point, so the exposure report shows `EXPOSED=0` for everything except the load balancer.

```
TODAY                                         TARGET
internet ──► usms-enrolment-alb ──► enrolment  internet ──► usms-enrolment-alb ─┬─► enrolment tasks
internet ──► usms-web-01 (public IP)           (only door)   path/host rules    └─► usms-web-tg ──► usms-web-01
                                                                                   (private subnet, no public IP)
```

**Steps.** Each one is reversible, and nothing gets cut over before its replacement is proven healthy.

1. **Create** target group `usms-web-tg` (instance type, HTTP:80, health check `/health`) and register `usms-web-01`.
2. **Allow** tcp/80 into `usms-app-sg` from `usms-alb-sg` (a group reference), and add a matching egress rule on `usms-alb-sg`: tcp/80 to `usms-app-sg`.
3. **Add** a listener rule on `usms-enrolment-alb` for the web paths/host, forwarding to `usms-web-tg`. **Prove** it: targets `healthy`, and requests through the ALB DNS name succeed.
4. **Cut over.** Point DNS at the ALB, wait one TTL, then **revoke** `0.0.0.0/0` tcp/80 and tcp/443 from `usms-app-sg`.
5. **Remove the address.** Launch the replacement instance in a private subnet with `--no-associate-public-ip-address` (an instance's public IP can't be detached in place). Its outbound traffic goes through `usms-nat`.
6. **Verify.** Run `usms-exposure-report.sh` and expect `EXPOSED=0` among the instance ENIs. Run `usms-reachability-matrix.sh` and expect `usms-app-sg` to show no `<-- THE INTERNET` lines.

**Rollback:** re-authorise the two `0.0.0.0/0` rules on `usms-app-sg` and point DNS back at the old address. The ALB rule can stay in place, because it does no harm.

**Risk:** in step 5 the instance changes IP. Anything that addresses `usms-web-01` by IP, rather than through the ALB or DNS, will break. Search the configs for `172.19.0.3` and the public address first.

---

## Actions summary

| # | Action | Owner | Priority |
|---|---|---|---|
| 1 | Move `usms-web-01` behind the ALB (section 5) | platform | **High** |
| 2 | Apply `outputs/lab-09-bucket-policy-draft.json` (removes auditor/intern read) | platform | **High** |
| 3 | Remove `USMSStudentDataReadWrite` from `usms-eks-node-role` | platform | **High** |
| 4 | CloudTrail + break-glass alarm | security | **High** |
| 5 | GuardDuty, S3 data events, flow logs | security | Medium |
| 6 | Interface endpoints for STS/ECR/Logs, then narrow the 443 egress | platform | Medium |
| 7 | Downgrade `usms-ec2-app-role` to read-only; narrow the Lambda read to a prefix | platform | Medium |
| 8 | Delete duplicate rules on `usms-app-sg` | platform | Low |

**Evidence:**
- `outputs/lab-09-exposure-report.txt`
- `outputs/lab-09-reachability.txt`
- `outputs/lab-09-negative-proof.txt`
- `outputs/lab-09-identity-inventory.json`
- `scripts/utilities/usms-iam-audit.sh` (`HIGH=0 ACCEPTED=6`)
- `scripts/utilities/verify-lab-09.sh` (`PASS=51 FAIL=0`)
