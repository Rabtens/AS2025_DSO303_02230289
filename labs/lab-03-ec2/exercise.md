## Independent Lab Exercises
 
### Exercise 1 - Basic: a maintenance instance
 
```bash
ADMIN_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name usms-app-key \
  --subnet-id "$USMS_PUBLIC_SUBNET_B" \
  --security-group-ids "$USMS_APP_SG" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-admin-01-host},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=03},{Key=Ephemeral,Value=true}]' \
  --query 'Instances[0].InstanceId' --output text)
 
echo "ADMIN_INSTANCE_ID = $ADMIN_INSTANCE_ID"
 
aws ec2 wait instance-running --instance-ids "$ADMIN_INSTANCE_ID"
 
aws ec2 describe-instances \
  --filters "Name=tag:Tier,Values=admin" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,AZ:Placement.AvailabilityZone,Subnet:SubnetId}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-17 11-04-23.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-17 11-12-50.png>)
 
### Exercise 2 - Intermediate: a self-describing, idempotent bootstrap
 
```bash
cat > labs/lab-03-ec2/user-data-db.sh << 'EOF'
#!/bin/bash
# USMS db tier bootstrap. Idempotent: refuses to run twice.
set -x
exec > /var/log/usms-db-bootstrap.log 2>&1
 
MARKER=/var/log/usms-db-bootstrap.done
if [ -f "$MARKER" ]; then
  echo "Bootstrap already completed at $(cat "$MARKER"); exiting."
  exit 0
fi
 
dnf -y update
dnf -y install postgresql15-server postgresql15
 
postgresql-setup --initdb
systemctl enable --now postgresql
sudo -u postgres createdb usms
 
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id")
 
printf '%s %s\n' "$INSTANCE_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
echo "USMS db bootstrap complete"
EOF
 
bash -n labs/lab-03-ec2/user-data-db.sh && echo "user-data-db.sh syntax OK"
wc -c labs/lab-03-ec2/user-data-db.sh
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-19-14.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-19-29.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-29-26.png>)
 
The outer heredoc was quoted (`<< 'EOF'`) for the same reason as Step 6: `$MARKER`, `$(cat "$MARKER")`, `$TOKEN` and `$INSTANCE_ID` must all be evaluated on the target instance at boot time, not by the local shell while the file is being written.
 
```bash
DB2_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name usms-app-key \
  --subnet-id "$USMS_PRIVATE_SUBNET_B" \
  --security-group-ids "$USMS_DB_SG" \
  --user-data file://labs/lab-03-ec2/user-data-db.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-db-02},{Key=Project,Value=USMS},{Key=Tier,Value=data},{Key=Lab,Value=03}]' \
  --query 'Instances[0].InstanceId' --output text)
 
echo "DB2_INSTANCE_ID = $DB2_INSTANCE_ID"
aws ec2 wait instance-running --instance-ids "$DB2_INSTANCE_ID"
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-30-26.png>)

Byte-identical proof, using Step 12's technique:
 
```bash
aws ec2 describe-instance-attribute \
  --instance-id "$DB2_INSTANCE_ID" \
  --attribute userData \
  --query 'UserData.Value' --output text > outputs/lab-03-db2-userdata.b64
 
openssl base64 -d -A -in outputs/lab-03-db2-userdata.b64 -out outputs/lab-03-db2-userdata.sh
 
diff labs/lab-03-ec2/user-data-db.sh outputs/lab-03-db2-userdata.sh \
  && echo "USER DATA PROVEN (db2): byte-identical" \
  || echo "MISMATCH — see the diff above"
```

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-31-15.png>)
 
**Idempotence explanation:** user data normally runs only once, at first boot, so a re-run would only actually happen if something outside the normal lifecycle re-invoked cloud-init - for example, a golden AMI built from this instance being launched again with the same script, or an operator manually re-executing `/var/lib/cloud/...` after a `cloud-init clean`. In either case, the marker file at `/var/log/usms-db-bootstrap.done` is checked first, so the script exits at line 2 of its logic without touching `dnf`, `postgresql-setup --initdb` (which would fail or wipe existing data on a second run), or the database.
 
### Exercise 3 - Problem solving: a reachability report
 
```bash
cat > scripts/utilities/lab-03-reachability.sh << 'EOF'
#!/usr/bin/env bash
# Prints a reachability verdict for every running USMS instance.
# Verdict is derived only from route-table and security-group state,
# never from the instance's name or tags.
set -uo pipefail
# -e is deliberately NOT set: a single instance with a missing/None field
# (e.g. no public IP) must not abort the report for every other instance.
 
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env 2>/dev/null || true
 
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,SubnetId,PrivateIpAddress,PublicIpAddress,SecurityGroups[0].GroupId]' \
  --output text)
 
printf '%-18s %-14s %-15s %-12s %s\n' "NAME" "PRIVATE-IP" "PUBLIC-IP" "VERDICT" "REASON"
 
while read -r id name subnet priv pub sg; do
  [ -z "$id" ] && continue
 
  igw_route=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$subnet" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
    --output text 2>/dev/null)
 
  sg_allows_80=$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`80`].IpRanges[0].CidrIp | [0]' \
    --output text 2>/dev/null)
 
  has_public=true
  { [ "$pub" = "None" ] || [ -z "$pub" ]; } && has_public=false
 
  has_igw=false
  [[ "$igw_route" == igw-* ]] && has_igw=true
 
  if [ "$has_igw" = true ] && [ "$has_public" = true ] && [ "$sg_allows_80" != "None" ] && [ -n "$sg_allows_80" ]; then
    verdict="REACHABLE";   reason="igw route + sg allows 80/tcp from 0.0.0.0/0"
  elif [ "$has_igw" = true ] && [ "$has_public" = false ]; then
    verdict="NO-ADDRESS";  reason="igw route present but no public address"
  else
    verdict="UNREACHABLE"; reason="no igw route on subnet"
  fi
 
  printf '%-18s %-14s %-15s %-12s %s\n' "$name" "$priv" "${pub:--}" "$verdict" "$reason"
done <<< "$INSTANCES"
EOF
 
chmod +x scripts/utilities/lab-03-reachability.sh
./scripts/utilities/lab-03-reachability.sh
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-37-17.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-38-14.png>)

Run from a different directory to confirm portability:
 
```bash
cd ~
~/aws-floci-course/scripts/utilities/lab-03-reachability.sh
cd ~/aws-floci-course
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-38-34.png>)
 
Result (identical from both invocations):
 
```
NAME               PRIVATE-IP     PUBLIC-IP       VERDICT      REASON
usms-web-01        10.0.1.87      52.9.144.17     REACHABLE    igw route + sg allows 80/tcp from 0.0.0.0/0
usms-web-02        10.0.2.34      54.88.10.5      REACHABLE    igw route + sg allows 80/tcp from 0.0.0.0/0
usms-db-01         10.0.3.42      -               UNREACHABLE  no igw route on subnet
usms-db-02         10.0.4.19      -               UNREACHABLE  no igw route on subnet
usms-admin-01-host 10.0.2.201     34.201.9.14     REACHABLE    igw route + sg allows 80/tcp from 0.0.0.0/0
```
 
`REPO_ROOT` is resolved from `BASH_SOURCE[0]` rather than the caller's working directory, and `source configs/course.env 2>/dev/null || true` prevents the script from aborting if it is ever run before the environment file exists - both are why the output was identical regardless of the calling directory.
 
### Exercise 4 - Challenge: right-size and clean up
 
**Written analysis** (`labs/lab-03-ec2/exercises.md`):
 
*Scale up vs. scale out:* Given 400 concurrent, mostly-read users at peak and near-idle overnight, scaling **out** (multiple small instances behind a load balancer with Auto Scaling, covered in Labs 05–06) was recommended over scaling **up** (a single larger instance). A bigger instance would be sized for the midday peak and billed at that size around the clock, including the idle overnight hours where the current `t3.micro` is doing almost nothing. A small Auto Scaling group (e.g. `min=1, max=3` on `t3.micro`/`t3.small`) can shrink to its minimum overnight and grow only during the peak window, which a single larger instance cannot do.
 
*Burstable credits:* `t3.micro` earns CPU credits while below its baseline utilisation (roughly 10% for this size) and spends credits above it. Sustained 85% CPU is well above baseline, so credits are being drawn down continuously rather than replenished. In **standard** credit mode, once the credit balance is exhausted the instance is throttled back to baseline performance — the worst possible time for that to happen, since it is already at peak load. In **unlimited** mode the instance is never throttled but is billed for CPU used above the baseline. Which mode is active was checked directly rather than assumed:
 
```bash
aws ec2 describe-instance-credit-specifications \
  --instance-ids "$USMS_WEB_INSTANCE" \
  --query 'InstanceCreditSpecifications[0].{Instance:InstanceId,CpuCredits:CpuCredits}' \
  --output table
```

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-42-32.png>)

 
*Cost comparison* (list prices, US East (N. Virginia), sourced from the AWS EC2 On-Demand pricing page —-figures are illustrative and should be re-checked against current published rates before any real budgeting decision):
 
| Option | Approx. monthly cost (730 hrs) | Notes |
|---|---|---|
| Single `t3.micro`, unlimited credit mode | ~US$7.50 base + variable CPU-surplus charges | Simplest, but surplus charges scale with sustained load and there is no headroom for growth |
| Auto Scaling group, `t3.micro` × (1–3), behind an ALB | ~US$7.50–22.50 compute (scales with demand) + ALB (~US$16–20/month base + LCU usage) | Higher floor cost due to the ALB, but capacity tracks the actual 400-user peak instead of guessing a fixed size |
 
*What to delete today:* the Exercise 1 admin host, any orphaned test volumes, and any unassociated Elastic IPs — none of which appear in the KEEP column of Section 16.2 of the lab.
 
**Deletions executed:**
 
Read before running any delete command
What will be deleted: `usms-admin-01-host` only.
What depends on it: nothing — it is not referenced in `configs/lab-03.env` or by any later lab.
Reversible? No — termination is irreversible and deletes its root volume.
Effect on later labs: none.
 
```bash
aws ec2 terminate-instances --instance-ids "$ADMIN_INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$ADMIN_INSTANCE_ID"
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-43-58.png>)

Read before running any delete command
What will be deleted: the Availability-Zone-mismatch test volume created during Step 15's "Your turn" task.
What depends on it: nothing — it was created solely to test the AZ constraint.
Reversible? No.
Effect on later labs: none.
 
```bash
aws ec2 describe-volumes \
  --filters "Name=tag:Project,Values=USMS" "Name=status,Values=available" \
  --query 'Volumes[].{Id:VolumeId,Size:Size,AZ:AvailabilityZone}' --output table
 
aws ec2 delete-volume --volume-id "$TEST_VOLUME_ID"
```

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-46-20.png>)
 
```bash
aws ec2 describe-addresses --filters "Name=tag:Project,Values=USMS" \
  --query 'Addresses[?InstanceId==`null`]' --output table
```

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-46-33.png>)
 
Result: no unassociated Elastic IPs were found (`usms-nat-eip` and `usms-web-eip` were both associated), so no `release-address` call was needed.
 
**Verification after cleanup:**
 
```bash
./scripts/utilities/verify-lab-03.sh
```

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-47-35.png>)
 
Result: `PASS=48  FAIL=0` - unchanged, confirming none of the deleted resources were tracked by `configs/lab-03.env`.
 
### Exercise 5 - Integration: prepare the S3 hand-off for Lab 4
 
```bash
cat > labs/lab-03-ec2/transcript-upload.sh << 'EOF'
#!/bin/bash
# Uploads a student transcript to S3 using ONLY the instance's IAM
# instance profile. No access key is read, stored, or referenced here.
set -euo pipefail
 
STUDENT_ID="${1:-}"
FILE_PATH="${2:-}"
 
if [ -z "$STUDENT_ID" ] || [ -z "$FILE_PATH" ]; then
  echo "Usage: $0 <student-id> <file-path>" >&2
  exit 1
fi
 
if [ ! -f "$FILE_PATH" ]; then
  echo "File not found: $FILE_PATH" >&2
  exit 1
fi
 
FILENAME=$(basename "$FILE_PATH")
BUCKET="usms-student-data"
KEY="transcripts/${STUDENT_ID}/${FILENAME}"
 
aws s3 cp "$FILE_PATH" "s3://${BUCKET}/${KEY}"
echo "Uploaded to s3://${BUCKET}/${KEY}"
EOF
 
chmod +x labs/lab-03-ec2/transcript-upload.sh
bash -n labs/lab-03-ec2/transcript-upload.sh && echo "transcript-upload.sh syntax OK"
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-54-04.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-54-23.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-54-47.png>)
 
The script never references an access key or secret — `aws s3 cp` resolves credentials automatically from the instance's attached role via the metadata service on real AWS.
 
Confirming the outbound rule:
 
```bash
aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
  --query 'SecurityGroups[0].IpPermissionsEgress' --output json
```

![alt text](<../../screenshots/Screenshot from 2026-09-22 11-55-03.png>)

No additional outbound rule was added. `usms-app-sg`'s default egress rule (all traffic, `0.0.0.0/0`) already permits outbound HTTPS, and security groups are stateful — the one sentence answer required by the exercise is that it is this pre-existing default-allow egress rule, not anything written in this lab, that makes the instance's outbound call to the S3 API (`tcp/443`) possible at all.
 
Readiness file:
 
```bash
{
  echo "Instance: $USMS_WEB_INSTANCE"
  echo "Instance Profile ARN: $PROFILE_ARN"
  echo "Role: $ROLE_NAME"
  echo "Attached Policy: USMSStudentDataReadWrite"
  echo "Bucket ARN in policy: arn:aws:s3:::usms-student-data"
  echo "head-bucket result:"
  aws s3api head-bucket --bucket usms-student-data 2>&1 || true
  echo "exit code: $?"
} > outputs/lab-03-s3-readiness.txt
 
cat outputs/lab-03-s3-readiness.txt
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-55-19.png>)
 
Expected/actual result: `head-bucket` failed (the bucket does not exist yet — the failure was captured in the file rather than suppressed), with a non-zero exit code and a `404`/`NoSuchBucket`-style message. This is the deliberate point of the exercise: Lab 04 re-runs the same `head-bucket` check immediately after creating the bucket, and the difference between this result and that one is the entire lesson of that step.
 
```bash
grep -q '^export USMS_BUCKET_NAME=' configs/lab-01.env 2>/dev/null \
  || echo 'export USMS_BUCKET_NAME=usms-student-data' >> configs/lab-03.env
 
grep 'USMS_BUCKET_NAME' configs/lab-01.env configs/lab-03.env 2>/dev/null
```
![alt text](<../../screenshots/Screenshot from 2026-09-22 11-55-32.png>)
 
`USMS_BUCKET_NAME` was not already present in `configs/lab-01.env`, so it was appended to `configs/lab-03.env`, giving Lab 04 a single sourced name to create the bucket against rather than re-deriving it.
 