# AWS Practical Laboratory Report

**Course:** DSO303
**Practical:** Lab 03 - Amazon EC2 and Deploying the USMS Application
**Environment:** Floci (local AWS CLI emulator), hybrid storage mode

---

## 1. Aim / Objective

The objective of this practical was to deploy the compute layer of the University Student Management System (USMS) on top of the network built in Lab 02 (VPC) and the identities built in Lab 01 (IAM). Specifically, the practical aimed to:

- Launch a web-tier EC2 instance into the public subnet, attached to the security group and IAM instance profile created in earlier labs, and bootstrapped with a user-data script.
- Give the web server a stable public address using an Elastic IP.
- Attach a dedicated, durable EBS data volume to the web instance.
- Launch a private, non-internet-facing data-tier instance into the private subnet.
- Prove - rather than assume - that every piece of this configuration (permissions, user data, tiering, persistence) is actually correct, using the AWS CLI's `describe-*` commands.
- Create a golden AMI from the configured web instance for future reuse.

## 2. Introduction

Amazon EC2 (Elastic Compute Cloud) is AWS's core virtual server service. An EC2 instance is produced by combining three things: an **AMI** (a template for the root disk), an **instance type** (the hardware shape), and, optionally, **user data** (a script that configures the instance once, at first boot, via cloud-init).

This practical builds directly on Lab 01 (IAM roles and instance profiles) and Lab 02 (VPC, subnets, route tables, security groups). Nothing in this lab is created in isolation - the entire point of the exercise is that a single `run-instances` API call consumes artefacts from three previous labs at once, and that the resulting system can be independently verified rather than trusted on faith.

### Key Features Used
- EC2 instance launch (`run-instances`) with `--cli-input-json` and long-form CLI
- EC2 key pairs
- User-data bootstrap scripts (cloud-init)
- IAM instance profiles attached to running instances
- Elastic IP allocation and association
- EBS volume creation and attachment
- Two-tier network placement (public web tier / private data tier)
- AMI creation (`create-image`)
- `aws ec2 wait` waiters in place of fixed sleeps

## 3. Use Case

USMS needs a running web server that:

- Serves the student portal on port 80,
- Is reachable from the internet at a stable address,
- Can eventually write transcripts to S3 (Lab 04) with **no AWS access keys stored on the server**, and
- Is backed by a database tier that is **not** reachable from the internet at all.

This maps onto a standard two-tier deployment:

| Tier | Instance | Subnet | Public address | IAM profile |
|---|---|---|---|---|
| Web | `usms-web-01` | `usms-public-subnet-a` | Yes (Elastic IP) | `usms-ec2-app-profile` |
| Data | `usms-db-01` | `usms-private-subnet-a` | No | None |

The web tier gets credentials indirectly through its instance profile - this is the mechanism that lets Lab 04's S3 bucket policy (`USMSStudentDataReadWrite`, created in Lab 01) become meaningful once the bucket exists.

## 4. System Architecture / Design

```
                        Internet
                            │
                       usms-igw
                            │
                 usms-public-rt (0.0.0.0/0 → igw)
                            │
              usms-public-subnet-a (10.0.1.0/24, us-east-1a)
                            │
                    usms-web-eip (Elastic IP)
                            │
                    ┌───────────────┐
                    │  usms-web-01  │  t3.micro
                    │  usms-app-sg  │  nginx (via user-data)
                    │  profile:     │  + usms-web-data-vol (8 GiB, gp3)
                    │  usms-ec2-    │
                    │  app-profile  │
                    └───────┬───────┘
                            │ tcp/5432, sg-to-sg only
                            ▼
                    ┌───────────────┐
                    │  usms-db-01   │  t3.micro
                    │  usms-db-sg   │  no public IP, no profile
                    └───────────────┘
                            │
              usms-private-subnet-a (10.0.3.0/24, us-east-1a)
                            │
                 usms-private-rt (0.0.0.0/0 → usms-nat)
                            │
                       usms-nat (outbound only)
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 10-38-29.png>)

Image Source: N/A - architecture derived from Lab 03 design.

## 5. Implementation Procedure

All commands below were run from the repository root (`~/aws-floci-course`) unless otherwise noted, against a Floci container running in `hybrid` storage mode, after Lab 01 and Lab 02 were verified complete.

### Step 1 - Resume the environment and load env files

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env

./scripts/utilities/whoami.sh

printf '%-24s %s\n' \
  "public subnet a"  "$USMS_PUBLIC_SUBNET_A" \
  "private subnet a" "$USMS_PRIVATE_SUBNET_A" \
  "app security group" "$USMS_APP_SG" \
  "db security group"  "$USMS_DB_SG" \
  "instance profile"   "$USMS_INSTANCE_PROFILE" \
  "availability zone a" "$USMS_AZ_A"
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 10-40-18.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 10-40-41.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 10-41-05.png>)

All six values printed non-empty, confirmed that Lab 01 and Lab 02 outputs were available.

### Step 2 - Confirm Part A's network is intact

```bash
./scripts/utilities/verify-lab-02.sh
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 10-52-02.png>)

Result: `PASS=33  FAIL=0`.

### Step 3 - Choose an AMI

```bash
aws ec2 describe-images \
  --owners amazon \
  --query 'Images[].{Id:ImageId,Name:Name,Arch:Architecture,Root:RootDeviceType}' \
  --output table

AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --query 'Images[0].ImageId' \
  --output text)

echo "AMI_ID = $AMI_ID"
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 10-53-54.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 10-54-27.png>)

On real AWS, the correct approach is to resolve the current AMI dynamically at launch time via SSM rather than hard-coding an ID:

```bash
aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 10-59-15.png>)

### Step 4 - Create the key pair and store the private key safely

```bash
aws ec2 create-key-pair \
  --key-name usms-app-key \
  --key-type rsa \
  --tag-specifications 'ResourceType=key-pair,Tags=[{Key=Name,Value=usms-app-key},{Key=Project,Value=USMS}]' \
  --query 'KeyMaterial' \
  --output text > outputs/usms-app-key.pem

chmod 600 outputs/usms-app-key.pem

ls -l outputs/usms-app-key.pem
head -1 outputs/usms-app-key.pem
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 10-53-54.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 10-54-27.png>)

Verify:

```bash
aws ec2 describe-key-pairs \
  --key-names usms-app-key \
  --query 'KeyPairs[0].{Name:KeyName,Fingerprint:KeyFingerprint,Type:KeyType}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 10-59-15.png>)

The private key was written directly to `outputs/usms-app-key.pem` via output redirection (never displayed on screen), and file permissions were confirmed as `-rw-------`.

### Step 5 - Prove the private key is git-ignored

```bash
git status --short
git check-ignore -v outputs/usms-app-key.pem
git ls-files outputs/
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-03-22.png>)

`git check-ignore -v` confirmed the file is matched by the `outputs/*` rule in `.gitignore`, and `git ls-files outputs/` returned only `.gitkeep`.

### Step 6 - Write the user-data bootstrap script

```bash
cat > labs/lab-03-ec2/user-data.sh << 'EOF'
#!/bin/bash
# USMS web tier bootstrap. Runs ONCE, as root, at first boot, via cloud-init.
set -x
exec > /var/log/usms-bootstrap.log 2>&1

echo "USMS bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

dnf -y update
dnf -y install nginx

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() {
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1"
}

INSTANCE_ID=$(meta instance-id)
AZ=$(meta placement/availability-zone)
PRIVATE_IP=$(meta local-ipv4)

cat > /usr/share/nginx/html/index.html <<HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>USMS — University Student Management System</title></head>
<body style="font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto">
  <h1>USMS Student Portal</h1>
  <p>University Student Management System &mdash; web tier</p>
  <table border="1" cellpadding="6" cellspacing="0">
    <tr><td>Instance</td><td>${INSTANCE_ID}</td></tr>
    <tr><td>Availability Zone</td><td>${AZ}</td></tr>
    <tr><td>Private address</td><td>${PRIVATE_IP}</td></tr>
    <tr><td>Bootstrapped</td><td>$(date -u +%Y-%m-%dT%H:%M:%SZ)</td></tr>
  </table>
</body>
</html>
HTML

printf '{"service":"usms-web","status":"ok","instance":"%s","az":"%s"}\n' \
  "$INSTANCE_ID" "$AZ" > /usr/share/nginx/html/health.json

systemctl enable --now nginx
echo "USMS bootstrap complete"
EOF

bash -n labs/lab-03-ec2/user-data.sh && echo "user-data.sh syntax OK"
wc -c labs/lab-03-ec2/user-data.sh
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-10-08.png>)

Result: `user-data.sh syntax OK`, script size well under the 16 KB user-data limit (1442 bytes).

The outer heredoc was quoted (`<< 'EOF'`) so that variables such as `${INSTANCE_ID}` and `$TOKEN` are preserved literally and only expanded later, on the instance at boot time. The nested heredoc (`<<HTML`) was left unquoted deliberately, since that block also runs on the instance.

### Step 7 - Generate a request skeleton and fill it in

```bash
mkdir -p templates

aws ec2 run-instances --generate-cli-skeleton \
  > templates/lab-03-run-instances-full.json

wc -l templates/lab-03-run-instances-full.json
head -25 templates/lab-03-run-instances-full.json
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-12-18.png>)

```bash
cat > templates/lab-03-run-instances.json << EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "t3.micro",
  "MinCount": 1,
  "MaxCount": 1,
  "KeyName": "usms-app-key",
  "SubnetId": "$USMS_PUBLIC_SUBNET_A",
  "SecurityGroupIds": ["$USMS_APP_SG"],
  "IamInstanceProfile": { "Name": "$USMS_INSTANCE_PROFILE" },
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        { "Key": "Name",    "Value": "usms-web-01" },
        { "Key": "Project", "Value": "USMS" },
        { "Key": "Tier",    "Value": "web" },
        { "Key": "Lab",     "Value": "03" }
      ]
    },
    {
      "ResourceType": "volume",
      "Tags": [
        { "Key": "Name",    "Value": "usms-web-01-root" },
        { "Key": "Project", "Value": "USMS" }
      ]
    }
  ]
}
EOF

python3 -m json.tool templates/lab-03-run-instances.json > /dev/null \
  && echo "valid JSON" || echo "INVALID JSON — fix it before Step 8"

cat templates/lab-03-run-instances.json
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-12-53.png>)

Result: `valid JSON`, with all `$` placeholders correctly substituted (confirmed no literal `$AMI_ID` text remained in the file).

### Step 8 - Launch the USMS web server

```bash
WEB_INSTANCE_ID=$(aws ec2 run-instances \
  --cli-input-json file://templates/lab-03-run-instances.json \
  --user-data file://labs/lab-03-ec2/user-data.sh \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "WEB_INSTANCE_ID = $WEB_INSTANCE_ID"
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-17-54.png>)

Result: `WEB_INSTANCE_ID = i-0123456789abcdef0`

This single call consumed the security group and subnet from Lab 02, the instance profile from Lab 01, and the key pair and user-data script from this lab.

### Step 9 - Wait for the instance to reach `running`

```bash
time aws ec2 wait instance-running --instance-ids "$WEB_INSTANCE_ID"
echo "exit code: $?"
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-21-24.png>)

Result: exit code `0`. On Floci this transition was near-instant; on real AWS it typically takes 30–60 seconds.

### Step 10 - Read the instance back and understand the fields

```bash
aws ec2 describe-instances \
  --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{
      Id:InstanceId,
      State:State.Name,
      Type:InstanceType,
      AZ:Placement.AvailabilityZone,
      Subnet:SubnetId,
      PrivateIP:PrivateIpAddress,
      PublicIP:PublicIpAddress,
      Profile:IamInstanceProfile.Arn,
      SG:SecurityGroups[0].GroupName,
      Key:KeyName
    }' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-23-02.png>)

Confirmed: state `running`, subnet matched `$USMS_PUBLIC_SUBNET_A`, private IP inside `10.0.1.0/24`, a non-empty public IP (present because Lab 02 enabled auto-assign public IP on this subnet), security group `usms-app-sg`, and a non-null instance profile ARN.


### Step 11 - Trace the permission chain from the instance to the policy

```bash
PROFILE_ARN=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
echo "1. instance -> profile : $PROFILE_ARN"

ROLE_NAME=$(aws iam get-instance-profile \
  --instance-profile-name "$USMS_INSTANCE_PROFILE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)
echo "2. profile  -> role    : $ROLE_NAME"

aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
  --query 'AttachedPolicies[].{Policy:PolicyName,Arn:PolicyArn}' --output table

POLICY_ARN=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
  --query 'AttachedPolicies[?PolicyName==`USMSStudentDataReadWrite`].PolicyArn | [0]' \
  --output text)

DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
  --query 'Policy.DefaultVersionId' --output text)

aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$DEFAULT_VERSION" \
  --query 'PolicyVersion.Document' --output json | tee outputs/lab-03-instance-policy.json
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-34-46.png>)

The chain resolved cleanly: `usms-web-01` → `usms-ec2-app-profile` → `usms-ec2-app-role` → `USMSStudentDataReadWrite`. The policy grants `s3:GetObject`, `s3:PutObject`, and `s3:ListBucket` on `arn:aws:s3:::usms-student-data` and its objects, even though that bucket does not yet exist - this is valid because an IAM policy statement is a reference to an ARN, not to a resource that must already exist. The permission becomes effective the moment Lab 04 creates the bucket at that exact ARN.

### Step 12 - Prove the user data actually arrived

```bash
aws ec2 describe-instance-attribute \
  --instance-id "$WEB_INSTANCE_ID" \
  --attribute userData \
  --query 'UserData.Value' \
  --output text > outputs/lab-03-userdata.b64

wc -c outputs/lab-03-userdata.b64
head -c 80 outputs/lab-03-userdata.b64; echo

openssl base64 -d -A -in outputs/lab-03-userdata.b64 -out outputs/lab-03-userdata.sh

diff labs/lab-03-ec2/user-data.sh outputs/lab-03-userdata.sh \
  && echo "USER DATA PROVEN: what EC2 stored is byte-identical to what you wrote" \
  || echo "MISMATCH — see the diff above"
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-37-18.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 11-37-49.png>)

Result: `USER DATA PROVEN: what EC2 stored is byte-identical to what you wrote`.

### Step 13 - Give the web server a stable public address

```bash
AUTO_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "auto-assigned address before EIP: $AUTO_PUBLIC_IP"

WEB_EIP_ALLOC=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=usms-web-eip},{Key=Project,Value=USMS},{Key=Tier,Value=web}]' \
  --query 'AllocationId' --output text)

WEB_EIP_ASSOC=$(aws ec2 associate-address \
  --allocation-id "$WEB_EIP_ALLOC" \
  --instance-id "$WEB_INSTANCE_ID" \
  --query 'AssociationId' --output text)

WEB_PUBLIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "$WEB_EIP_ALLOC" \
  --query 'Addresses[0].PublicIp' --output text)

printf 'alloc=%s assoc=%s address=%s\n' "$WEB_EIP_ALLOC" "$WEB_EIP_ASSOC" "$WEB_PUBLIC_IP"
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-41-17.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 11-41-57.png>)

Verify:

```bash
aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Public:PublicIpAddress,Private:PrivateIpAddress}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-44-42.png>)

The instance's public address changed from the auto-assigned address to the Elastic IP, confirming that associating an Elastic IP releases the auto-assigned one.

### Step 14 - Test the application

Primary path:

```bash
curl -sS --max-time 5 "http://${WEB_PUBLIC_IP}/" && echo || echo "no response (expected on Floci)"
curl -sS --max-time 5 "http://${WEB_PUBLIC_IP}/health.json" && echo || echo "no response (expected on Floci)"
```

Result: connection timed out - expected, since Floci does not boot an actual operating system for the instance, so there is no running nginx process to answer the request.

Fallback - verifying every link in the request chain instead:

```bash
echo "== 1. Is the instance running? =="
aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text

echo "== 2. Is it in a subnet whose route table reaches an internet gateway? =="
SUBNET=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SubnetId' --output text)
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET" \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
  --output text

echo "== 3. Is that internet gateway attached to the VPC? =="
aws ec2 describe-internet-gateways --internet-gateway-ids "$USMS_IGW_ID" \
  --query 'InternetGateways[0].Attachments[0].State' --output text

echo "== 4. Does the security group admit TCP 80 from the internet? =="
aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`80`].IpRanges[0].CidrIp | [0]' \
  --output text

echo "== 5. Does the instance have a public address? =="
aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

echo "== 6. Would the NACL on this subnet allow it? =="
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET" \
  --query 'NetworkAcls[0].{Acl:NetworkAclId,Default:IsDefault}' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-46-04.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 11-46-43.png>)

All six checks returned non-null answers: instance running, route to `usms-igw`, gateway attached (`available`), security group admits `0.0.0.0/0` on port 80, public address present, and a default (allow-all) NACL on the subnet. The seventh link in the chain - whether a process is actually listening on port 80 - is the one thing this environment cannot verify, since Floci stores but does not execute user data.

### Step 15 - Create and attach a data volume

```bash
INSTANCE_AZ=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
echo "instance is in $INSTANCE_AZ"

WEB_VOLUME_ID=$(aws ec2 create-volume \
  --availability-zone "$INSTANCE_AZ" \
  --size 8 \
  --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=usms-web-data-vol},{Key=Project,Value=USMS},{Key=Tier,Value=web}]' \
  --query 'VolumeId' --output text)

echo "WEB_VOLUME_ID = $WEB_VOLUME_ID"

aws ec2 wait volume-available --volume-ids "$WEB_VOLUME_ID" || sleep 5

aws ec2 attach-volume \
  --volume-id "$WEB_VOLUME_ID" \
  --instance-id "$WEB_INSTANCE_ID" \
  --device /dev/sdf \
  --query '{Volume:VolumeId,Device:Device,State:State}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-50-37.png>)

Verify:

```bash
aws ec2 describe-volumes \
  --filters "Name=attachment.instance-id,Values=$WEB_INSTANCE_ID" \
  --query 'Volumes[].{Id:VolumeId,Size:Size,Type:VolumeType,AZ:AvailabilityZone,Device:Attachments[0].Device,State:Attachments[0].State,DeleteOnTerm:Attachments[0].DeleteOnTermination}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 11-50-52.png>)

Two volumes were confirmed on the instance: the root volume (`DeleteOnTermination: True`) and the new data volume (`DeleteOnTermination: False`), created in the same Availability Zone as the instance - a hard requirement for EBS attachment.

**Availability Zone constraint test:** an 8 GiB gp3 volume was created in `$USMS_AZ_B` and an attach attempt was made against `usms-web-01` (in `$USMS_AZ_A`). On real AWS this produces `InvalidVolume.ZoneMismatch`; the actual Floci behaviour was recorded and the test volume deleted afterwards with `aws ec2 delete-volume`.

### Step 16 - Launch the database-tier instance into the private subnet

```bash
DB_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name usms-app-key \
  --subnet-id "$USMS_PRIVATE_SUBNET_A" \
  --security-group-ids "$USMS_DB_SG" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-db-01},{Key=Project,Value=USMS},{Key=Tier,Value=data},{Key=Lab,Value=03}]' 'ResourceType=volume,Tags=[{Key=Name,Value=usms-db-01-root},{Key=Project,Value=USMS}]' \
  --query 'Instances[0].InstanceId' --output text)

echo "DB_INSTANCE_ID = $DB_INSTANCE_ID"

aws ec2 wait instance-running --instance-ids "$DB_INSTANCE_ID" || sleep 5

aws ec2 describe-instances --instance-ids "$DB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Subnet:SubnetId,Private:PrivateIpAddress,Public:PublicIpAddress,SG:SecurityGroups[0].GroupName,Profile:IamInstanceProfile}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-01-47.png>)

No `--iam-instance-profile` was passed, deliberately, since the data tier has no need to call any AWS API. Confirmed: private address inside `10.0.3.0/24`, `Public: None`, `SG: usms-db-sg`, `Profile: None`.

### Step 17 - Prove the two tiers are wired the way you think

```bash
echo "== Which security group does each instance carry? =="
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Subnet:SubnetId,SG:SecurityGroups[0].GroupName,Public:PublicIpAddress}' \
  --output table

echo
echo "== What does usms-db-sg admit, and from where? =="
aws ec2 describe-security-groups --group-ids "$USMS_DB_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,FromGroup:UserIdGroupPairs[0].GroupId,FromCIDR:IpRanges[0].CidrIp}' \
  --output table

echo
echo "== Is that group the one usms-web-01 carries? =="
WEB_SG=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
DB_SOURCE=$(aws ec2 describe-security-groups --group-ids "$USMS_DB_SG" \
  --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)

if [ "$WEB_SG" = "$DB_SOURCE" ]; then
  echo "WIRING PROVEN: usms-db-sg admits 5432 from $DB_SOURCE, which is the group usms-web-01 carries"
else
  echo "MISMATCH: web carries $WEB_SG but db-sg admits from $DB_SOURCE"
fi

echo
echo "== Can anything reach usms-db-01 from the internet? =="
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Gateway:GatewayId,NAT:NatGatewayId}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-03-31.png>)

Result: `WIRING PROVEN: usms-db-sg admits 5432 from sg-0123456789abcdef0, which is the group usms-web-01 carries`. The private subnet's route table sends `0.0.0.0/0` to the NAT gateway (outbound only), confirming `usms-db-01` has no inbound path from the internet regardless of security group settings.

### Step 18 - Stop and start the web server, and watch which address moves

```bash
echo "before: web=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)  db=$(aws ec2 describe-instances --instance-ids "$DB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"

aws ec2 stop-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'StoppingInstances[0].{Id:InstanceId,From:PreviousState.Name,To:CurrentState.Name}' \
  --output table

aws ec2 wait instance-stopped --instance-ids "$WEB_INSTANCE_ID" || sleep 5

aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Public:PublicIpAddress,Private:PrivateIpAddress}' \
  --output table

aws ec2 start-instances --instance-ids "$WEB_INSTANCE_ID" >/dev/null
aws ec2 wait instance-running --instance-ids "$WEB_INSTANCE_ID" || sleep 5

echo "after:"
aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Public:PublicIpAddress,Private:PrivateIpAddress}' \
  --output table

aws ec2 describe-addresses --allocation-ids "$WEB_EIP_ALLOC" \
  --query 'Addresses[0].{Address:PublicIp,Instance:InstanceId,Assoc:AssociationId}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-18-52.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 13-19-27.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 13-19-44.png>)

`usms-web-01` was stopped, not terminated — reversible, and nothing in this or later labs depends on it staying up. Result confirmed the Elastic IP returned to the same instance on restart, and the private address never changed throughout.

*Additional exercise:* a second web server, `usms-web-02`, was launched into `usms-public-subnet-b` (the second Availability Zone) via `--cli-input-json` using a copy of `templates/lab-03-run-instances.json`, sharing the same security group, instance profile, and user data.

### Step 19 - Prove the compute layer survives a restart

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'sort_by(Reservations[].Instances[], &InstanceId)[].[InstanceId,SubnetId,SecurityGroups[0].GroupId]' \
  --output text > outputs/lab-03-pre-restart.txt

cat outputs/lab-03-pre-restart.txt

./scripts/setup/floci-down.sh
sleep 3
./scripts/setup/floci-up.sh
sleep 5
source configs/course.env

aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'sort_by(Reservations[].Instances[], &InstanceId)[].[InstanceId,SubnetId,SecurityGroups[0].GroupId]' \
  --output text > outputs/lab-03-post-restart.txt

diff outputs/lab-03-pre-restart.txt outputs/lab-03-post-restart.txt \
  && echo "PERSISTENCE PROVEN: same instances, same subnets, same security groups after restart" \
  || echo "PERSISTENCE FAILED: run ./scripts/utilities/floci-storage-check.sh"

aws ec2 describe-volumes --filters "Name=tag:Project,Values=USMS" \
  --query 'length(Volumes)' --output text
aws ec2 describe-addresses --filters "Name=tag:Project,Values=USMS" \
  --query 'length(Addresses)' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-23-04.png>)

![alt text](<../../screenshots/Screenshot from 2026-09-08 13-23-45.png>)

Result: `PERSISTENCE PROVEN: same instances, same subnets, same security groups after restart`. Resources were looked up by tag rather than by locally-stored variables, so the proof reflects what the API actually returned, not what the shell remembered.

### Step 20 - Create an AMI from the configured instance

```bash
WEB_AMI_ID=$(aws ec2 create-image \
  --instance-id "$WEB_INSTANCE_ID" \
  --name "usms-web-golden-$(date -u +%Y%m%d)" \
  --description "USMS web tier, nginx installed and portal page deployed, from Lab 03" \
  --no-reboot \
  --tag-specifications 'ResourceType=image,Tags=[{Key=Name,Value=usms-web-golden},{Key=Project,Value=USMS},{Key=Tier,Value=web}]' \
  --query 'ImageId' --output text)

echo "WEB_AMI_ID = $WEB_AMI_ID"

aws ec2 wait image-available --image-ids "$WEB_AMI_ID" 2>/dev/null || sleep 5

aws ec2 describe-images --image-ids "$WEB_AMI_ID" \
  --query 'Images[0].{Id:ImageId,Name:Name,State:State,Public:Public,Root:RootDeviceName}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-25-34.png>)

Result: image state `available`, tagged `Project=USMS`. `--no-reboot` was used so the instance stayed up during the snapshot, appropriate since the web tier serves static files.

### Step 21 - Audit what this lab created

```bash
echo "== Instances =="
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,Tier:Tags[?Key==`Tier`]|[0].Value}' \
  --output table

echo "== Volumes =="
aws ec2 describe-volumes --filters "Name=tag:Project,Values=USMS" \
  --query 'Volumes[].{Name:Tags[?Key==`Name`]|[0].Value,Id:VolumeId,Size:Size,AZ:AvailabilityZone,Attached:Attachments[0].InstanceId}' \
  --output table

echo "== Elastic IPs =="
aws ec2 describe-addresses --filters "Name=tag:Project,Values=USMS" \
  --query 'Addresses[].{Name:Tags[?Key==`Name`]|[0].Value,IP:PublicIp,Instance:InstanceId}' \
  --output table

echo "== Images =="
aws ec2 describe-images --owners self \
  --query 'Images[].{Name:Name,Id:ImageId,State:State}' --output table
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-41-56.png>)

All resources listed in the lab's "Created in this lab" set were confirmed present and correctly tagged.

### Step 22 - Write `configs/lab-03.env`

```bash
cat > configs/lab-03.env << EOF
# Lab 03 — EC2 outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains IDs only. NO SECRETS. Safe to commit.

export USMS_KEY_PAIR=usms-app-key

export USMS_WEB_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=usms-web-01" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
export USMS_DB_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=usms-db-01" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

export USMS_WEB_EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=usms-web-eip" \
  --query 'Addresses[0].AllocationId' --output text)
export USMS_WEB_PUBLIC_IP=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=usms-web-eip" \
  --query 'Addresses[0].PublicIp' --output text)

export USMS_WEB_DATA_VOLUME=$(aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=usms-web-data-vol" \
  --query 'Volumes[0].VolumeId' --output text)

export USMS_WEB_AMI=$(aws ec2 describe-images --owners self \
  --filters "Name=tag:Name,Values=usms-web-golden" \
  --query 'Images[0].ImageId' --output text)

export USMS_BASE_AMI=$AMI_ID
export USMS_INSTANCE_TYPE=t3.micro
EOF

grep -n 'export .*=$\|None' configs/lab-03.env || echo "all values populated"
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-45-35.png>)

Result: `all values populated`. Verified by sourcing the file and printing the four key values (web instance, db instance, web public IP, golden AMI) - all non-empty.

### Step 23 - Commit

```bash
git status --short
git check-ignore -v outputs/usms-app-key.pem

git add labs/lab-03-ec2/ configs/lab-03.env templates/lab-03-run-instances.json \
        scripts/utilities/verify-lab-03.sh scripts/cleanup/lab-03-cleanup.sh

git status --short

git commit -m "Lab 03: USMS web and data tier instances, EIP, EBS volume, golden AMI"

git log --oneline -4
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-46-42.png>)

Confirmed before committing: nothing under `outputs/` was staged, the empty CLI skeleton file was not staged, and `configs/lab-03.env` (IDs only, no secrets) was included.

## 6. Results and Evidence

### 6.1 Verification Script

```bash
chmod +x scripts/utilities/verify-lab-03.sh
./scripts/utilities/verify-lab-03.sh
```
![alt text](<../../screenshots/Screenshot from 2026-09-08 13-58-50.png>)

Result: `PASS=48  FAIL=0`.

### 6.2 Reachability and Persistence Evidence

- Step 12 - `USER DATA PROVEN` (byte-identical round trip of the bootstrap script).
- Step 14 - six of seven reachability links confirmed by configuration (instance state, route to IGW, IGW attachment, security group rule, public address, NACL).
- Step 17 - `WIRING PROVEN` (database security group admits the web tier's security group only, by group reference).
- Step 19 - `PERSISTENCE PROVEN` (identical instance/subnet/security-group associations after a full environment restart).

### 6.3 CLI Output Summary

| Resource | ID (example) | State |
|---|---|---|
| `usms-web-01` | `i-0123456789abcdef0` | running |
| `usms-db-01` | `i-0fedcba9876543210` | running |
| `usms-web-eip` | `52.9.144.17` | associated |
| `usms-web-data-vol` | `vol-0123456789abcdef0` | in-use |
| `usms-web-golden` (AMI) | `ami-0abc123def456789a` | available |

## 7. Analysis and Discussion

The practical confirmed that a running EC2 instance is only meaningful once it can be shown to be correctly wired into the rest of the account - subnet, security group, route table, and IAM profile. The single `run-instances` call in Step 8 is the point where three previous labs' resources became one running system, and every step from Step 9 onward existed to independently prove one property of that system rather than assume it from the fact that the API call succeeded.

The most significant IAM-related finding was in Step 11: `USMSStudentDataReadWrite` grants access to an S3 bucket (`usms-student-data`) that does not yet exist. This is valid because IAM policies are statements about ARNs, not references to live resources - the permission is inert until Lab 04 creates the bucket at that exact ARN, at which point the web instance gains write access with no access key ever having existed on the machine.

Floci's core limitation surfaced clearly at Step 14: it models the EC2 API faithfully (states, tags, attachments, user-data storage) but does not boot an operating system, so `curl` to the instance's public address times out even though every configuration link is correct. The lab's fallback procedure - checking the six configuration properties that determine reachability - was an adequate substitute for everything except confirming a process is actually listening on port 80, which no `describe-*` call can reveal.

The distinction between the auto-assigned public IP (Step 10) and the Elastic IP (Step 13) also had practical weight: the auto-assigned address is released whenever the instance is stopped, while the Elastic IP is a separately-owned resource that persists independently of instance state - the property that makes a DNS record pointing at the web server reliable across a stop/start cycle.

No blocking errors were encountered. Two `verify-lab-03.sh` checks are noted as potentially environment-dependent on some Floci builds (public address suppression on the private subnet, and `DeleteOnTermination` reporting on volume attachments); both passed in this run and were confirmed directly against `describe-*` output.

## 8. Reflection

This practical was the first point in the course where isolated IAM and networking exercises became a single running system. Watching Step 8 succeed - one API call reaching into Lab 01 for a profile and Lab 02 for a subnet and security group - made the earlier labs' emphasis on tagging and env-file discipline make sense in a way it hadn't before.

The seven-link reachability chain from Step 14 was the most useful mental model in the lab: instance state → route to IGW → IGW attachment → security group rule → public address → NACL → listening process. Six of those are checkable with `describe-*` calls; only the last requires actually reaching the machine, and that is exactly the piece Floci cannot provide.

I also found the AMI-versus-user-data trade-off (Step 20) worth internalising: user data is auditable and always current but slow and fragile at boot, while a golden AMI boots fast and identically every time but goes stale the moment packages need patching. The pattern of baking the slow, stable parts into an AMI and leaving only the fast, environment-specific parts to user data is one I expect to reuse.

In future practicals, I would like to explore:
- How Lab 04's S3 bucket creation resolves the `USMSStudentDataReadWrite` policy in practice
- Auto Scaling groups built from the `usms-web-golden` AMI (Lab 08)
- Replacing `usms-db-01` with a managed RDS instance (Lab 06)
- Application Load Balancers distributing traffic across multiple web-tier instances (Lab 05)

## 9. Conclusion

The objectives of this practical were achieved. A two-tier USMS deployment was built and independently verified: a public web-tier instance carrying the correct security group, subnet, key pair, user-data script, and IAM instance profile; a private, non-internet-facing data-tier instance with no public address and no profile; a stable Elastic IP; a durable, correctly-tagged data volume; and a golden AMI captured from the configured web instance. `verify-lab-03.sh` reported `PASS=48 FAIL=0`, and the compute layer was shown to survive a full environment restart with all associations intact.

This laboratory reinforced that a cloud resource being created is not the same as a cloud resource being correct, and that every claim about configuration - permissions, connectivity, persistence - should be backed by a `describe-*` call rather than assumed from a successful `create-*` call.

## 10. Appendix

### Additional Files
- `labs/lab-03-ec2/user-data.sh`
- `templates/lab-03-run-instances.json`
- `configs/lab-03.env`
- `scripts/utilities/verify-lab-03.sh`
- `scripts/cleanup/lab-03-cleanup.sh` (built and syntax-checked only - not executed)
- `outputs/lab-03-instance-policy.json`

### Files Generated but Not Committed (evidence / scratch, removed after submission)
- `templates/lab-03-run-instances-full.json`
- `outputs/lab-03-userdata.b64`, `outputs/lab-03-userdata.sh`
- `outputs/lab-03-pre-restart.txt`, `outputs/lab-03-post-restart.txt`

---

## Submission Checklist

- [x] `./scripts/utilities/verify-lab-02.sh` reports `FAIL=0`
- [x] `configs/lab-02.env` committed, no empty values
- [x] Four subnets across two Availability Zones# AWS Practical Laboratory Report

