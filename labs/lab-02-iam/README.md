# AWS Practical Laboratory Report

**Course:** DSO303
**Lab:** Lab 02 - Virtual Private Cloud (VPC) and Networking
**Institution:** College of Science and Technology (CST), Bhutan
**Scenario:** University Student Management System (USMS) - junior cloud engineer building USMS infrastructure on Floci (local AWS emulator) using the AWS CLI

---

## 1. Aim / Objective

To design and build a secure, multi-tier Virtual Private Cloud (VPC) network for the University Student Management System (USMS) using the AWS CLI - including subnets, route tables, an internet gateway, a NAT gateway, security groups, a network ACL, and an S3 gateway endpoint - and to verify that the network is correctly configured and persists across a restart of the environment.

---

## 2. Introduction

Amazon Virtual Private Cloud (VPC) is the foundational networking service in AWS that lets a user provision a logically isolated section of the AWS cloud where resources such as EC2 instances can be launched inside a private, user-defined address space. A VPC gives full control over the virtual networking environment, including IP address ranges (CIDR blocks), subnets, route tables, gateways, and layered firewalls (security groups and network ACLs).

**Key features explored in this practical:**

- Creating a VPC with a custom CIDR block and enabling DNS support/hostnames
- Public and private subnets across multiple Availability Zones
- Internet gateways for public internet access, and NAT gateways for controlled outbound-only access from private subnets
- Route tables and the longest-prefix-match routing model
- Security groups (stateful, instance-level) and Network ACLs (stateless, subnet-level)
- Gateway VPC endpoints to keep traffic to AWS services (e.g., S3) off the public internet
- Tagging conventions and CLI patterns (`--filters`, `--query`, JMESPath) for auditability

**Importance in cloud computing:** VPC is the security and isolation boundary for nearly every other AWS service. Correctly separating public-facing and private (data) tiers, and controlling traffic between them, is the basis of the shared responsibility model for cloud security.

**Typical applications:** Hosting multi-tier web applications (web tier public, database tier private), isolating sensitive data stores, connecting on-premises networks via VPN/Direct Connect, and controlling egress paths to reduce cost and exposure.

---

## 3. Use Case

For the USMS project, the VPC separates the system into two tiers:

- **Web tier (public subnet):** Reachable from the internet, hosts the USMS web server students and staff access.
- **Data tier (private subnet):** Holds student transcripts and enrolment records; must **never** be reachable from the internet, but still needs outbound access to fetch OS security patches via a NAT gateway.

This mirrors common real-world patterns such as:

- Hosting a public-facing student portal on EC2 while keeping the database isolated
- Storing transcripts/assets in S3, reached privately via a VPC gateway endpoint
- Restricting SSH access to only trusted sources instead of the open internet

---

## 4. System Architecture / Design

The diagram below should show: the VPC (`10.0.0.0/16`), the two public subnets (`10.0.1.0/24`, `10.0.2.0/24`) routed to the Internet Gateway, the two private subnets (`10.0.3.0/24`, `10.0.4.0/24`) routed to the NAT Gateway, the security groups (`usms-app-sg`, `usms-db-sg`), the private NACL, and the S3 gateway endpoint.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 22-33-58.png>)

**Address plan:**

| Range | Purpose | Addresses |
|---|---|---|
| 10.0.0.0/16 | The whole VPC | 65,536 |
| 10.0.1.0/24 | usms-public-subnet-a — web tier, AZ a | 256 (251 usable) |
| 10.0.2.0/24 | usms-public-subnet-b — web tier, AZ b | 256 (251 usable) |
| 10.0.3.0/24 | usms-private-subnet-a — data tier, AZ a | 256 (251 usable) |
| 10.0.4.0/24 | usms-private-subnet-b — data tier, AZ b | 256 (251 usable) |
| 10.0.5.0/24 – 10.0.255.0/24 | Unallocated — reserved for later labs | — |

---

## 5. Implementation Procedure

> **Prerequisites:** Lab 1 (IAM) must be complete, with `./scripts/utilities/verify-lab-01.sh` reporting `FAIL=0`. Floci must be running under Docker Compose with `FLOCI_STORAGE_MODE=hybrid`. AWS CLI v2 must be installed with the `floci` profile configured, and `configs/course.env` must be sourced in your shell.

### Step 1 - Resume the environment

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh
./scripts/utilities/floci-storage-check.sh
```

Expected: `PASS=6  FAIL=0` from the storage check.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-37-51.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-38-05.png>)

---

### Step 2 - Load the previous lab's environment and confirm identity

```bash
source configs/course.env
source configs/lab-01.env

./scripts/utilities/whoami.sh

echo "developer role : $USMS_ROLE_DEVELOPER"
echo "developer user : $USMS_DEV_USER"
echo "account        : $USMS_ACCOUNT_ID"
```

Expected identity: `arn:aws:iam::000000000000:root`, account `000000000000`.

> **Checkpoint 1** - Floci running under Compose (storage mode hybrid), `course.env` + `lab-01.env` sourced, identity confirmed as account `000000000000`.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-40-32.png>)

**CIDR notation reference** (used throughout the lab):

| Prefix | Free bits | Addresses | Usable in AWS |
|---|---|---|---|
| /16 | 16 | 65,536 | 65,531 |
| /20 | 12 | 4,096 | 4,091 |
| /24 | 8 | 256 | 251 |
| /28 | 4 | 16 | 11 |

---

### Step 3 - Assume the developer role and create the VPC

**Part 1 - Read the policy before relying on it:**

```bash
POLICY_ARN="arn:aws:iam::${USMS_ACCOUNT_ID}:policy/USMSDeveloperBase"

DEFAULT_VERSION=$(aws iam get-policy \
  --policy-arn "$POLICY_ARN" \
  --query 'Policy.DefaultVersionId' \
  --output text)

echo "default version: $DEFAULT_VERSION"

aws iam get-policy-version \
  --policy-arn "$POLICY_ARN" \
  --version-id "$DEFAULT_VERSION" \
  --query 'PolicyVersion.Document' \
  --output json | tee outputs/lab-02-developer-base.json
```

**Part 2 - Assume the role:**

```bash
ROLE_ARN="arn:aws:iam::${USMS_ACCOUNT_ID}:role/${USMS_ROLE_DEVELOPER}"

aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "lab02-vpc-build" \
  --profile usms-dev \
  > outputs/lab-02-assumed-role.json

chmod 600 outputs/lab-02-assumed-role.json

export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId'     outputs/lab-02-assumed-role.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' outputs/lab-02-assumed-role.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken'    outputs/lab-02-assumed-role.json)

aws sts get-caller-identity --no-cli-pager
```

Expected `Arn` contains `assumed-role/usms-developer-role/lab02-vpc-build`.

**Part 3 - Create the VPC:**

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=usms-vpc},{Key=Project,Value=USMS},{Key=Tier,Value=network},{Key=ManagedBy,Value=aws-cli}]' \
  --query 'Vpc.VpcId' \
  --output text)

echo "VPC_ID = $VPC_ID"
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-50-35.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-51-15.png>)

---

### Step 4 - Restore normal identity

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

./scripts/utilities/whoami.sh

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{Id:VpcId,CIDR:CidrBlock,State:State,Default:IsDefault,Tenancy:InstanceTenancy}' \
  --output table
```

Expected: `State = available`, `Default = False`.

> **Checkpoint 2** - `usms-vpc` exists with CIDR `10.0.0.0/16`, state `available`, created while holding `usms-developer-role` credentials, normal identity restored.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-54-57.png>)

---

### Step 5 - Enable DNS support and DNS hostnames

```bash
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support   '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
```

Verify:

```bash
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport   --query 'EnableDnsSupport.Value'   --output text
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text
```

Both must print `True`.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-56-47.png>)

---

### Step 6 - Create and attach the internet gateway

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=usms-igw},{Key=Project,Value=USMS}]' \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

echo "IGW_ID = $IGW_ID"

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"
```

Verify:

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].{Id:InternetGatewayId,Attachments:Attachments}' \
  --output json
```

> **Checkpoint 3** - DNS support enabled, DNS hostnames enabled, `usms-igw` attached.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-59-32.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 10-59-40.png>)

---

### Step 7 - Create the public subnet in us-east-1a

```bash
PUBLIC_SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 \
  --availability-zone "${AWS_REGION_COURSE}a" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-public-subnet-a},{Key=Project,Value=USMS},{Key=Tier,Value=public},{Key=AZ,Value=a}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "PUBLIC_SUBNET_A_ID = $PUBLIC_SUBNET_A_ID"
```

Verify:

```bash
aws ec2 describe-subnets \
  --subnet-ids "$PUBLIC_SUBNET_A_ID" \
  --query 'Subnets[0].{Id:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Free:AvailableIpAddressCount,PublicIP:MapPublicIpOnLaunch,State:State}' \
  --output table
```

Expect `Free = 251`, `PublicIP = False` (fixed in Step 8).

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-01-53.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-02-03.png>)

---

### Step 8 - Turn on auto-assign public IPv4 for the public subnet

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_A_ID" \
  --map-public-ip-on-launch

aws ec2 describe-subnets \
  --subnet-ids "$PUBLIC_SUBNET_A_ID" \
  --query 'Subnets[0].MapPublicIpOnLaunch' \
  --output text
```

Expected: `True`.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-03-25.png>)

---

### Step 9 - Create the private subnet in us-east-1a

```bash
PRIVATE_SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.3.0/24 \
  --availability-zone "${AWS_REGION_COURSE}a" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-private-subnet-a},{Key=Project,Value=USMS},{Key=Tier,Value=private},{Key=AZ,Value=a}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "PRIVATE_SUBNET_A_ID = $PRIVATE_SUBNET_A_ID"
```

Verify (both subnets):

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'sort_by(Subnets, &CidrBlock)[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch}' \
  --output table
```

> **Checkpoint 4** - Two subnets: `usms-public-subnet-a` (auto-public-IP: yes), `usms-private-subnet-a` (auto-public-IP: no).

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-03-25.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-02-03.png>)

---

### Step 10 - Create the public route table and the default route

```bash
PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=usms-public-rt},{Key=Project,Value=USMS},{Key=Tier,Value=public}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

echo "PUBLIC_RT_ID = $PUBLIC_RT_ID"

aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID"
```

Verify:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PUBLIC_RT_ID" \
  --query 'RouteTables[0].Routes[].{Destination:DestinationCidrBlock,Target:GatewayId,State:State}' \
  --output table
```

Expect two routes: `10.0.0.0/16 -> local` and `0.0.0.0/0 -> igw-...`, both `active`.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-09-03.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-09-12.png>)

---

### Step 11 - Associate the public subnet with the public route table

```bash
PUBLIC_ASSOC_A_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_A_ID" \
  --query 'AssociationId' \
  --output text)

echo "PUBLIC_ASSOC_A_ID = $PUBLIC_ASSOC_A_ID"
```

> Independent task 
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-15-54.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-16-09.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-16-20.png>)

```bash
PUBLIC_SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.2.0/24 \
  --availability-zone "${AWS_REGION_COURSE}b" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-public-subnet-b},{Key=Project,Value=USMS},{Key=Tier,Value=public},{Key=AZ,Value=b}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "PUBLIC_SUBNET_B_ID = $PUBLIC_SUBNET_B_ID"

aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_B_ID" \
  --map-public-ip-on-launch

aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_B_ID" \
  --query 'AssociationId' \
  --output text
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-18-07.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-18-18.png>)

---

### Step 12 - Create the private route table and associate the private subnet

```bash
PRIVATE_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=usms-private-rt},{Key=Project,Value=USMS},{Key=Tier,Value=private}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

echo "PRIVATE_RT_ID = $PRIVATE_RT_ID"

PRIVATE_ASSOC_A_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_RT_ID" \
  --subnet-id "$PRIVATE_SUBNET_A_ID" \
  --query 'AssociationId' \
  --output text)

echo "PRIVATE_ASSOC_A_ID = $PRIVATE_ASSOC_A_ID"
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-20-20.png>)

---

### Step 13 - Prove the two subnets are actually different

```bash
for s in "$PUBLIC_SUBNET_A_ID" "$PRIVATE_SUBNET_A_ID"; do
  name=$(aws ec2 describe-subnets --subnet-ids "$s" \
          --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text)

  rt=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$s" \
        --query 'RouteTables[0].RouteTableId' --output text)

  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
        --output text)

  printf '%-24s subnet=%-26s rt=%-24s default-route-target=%s\n' \
         "$name" "$s" "$rt" "$igw"
done
```

Expected: the public subnet's default-route-target is an `igw-...` ID; the private subnet's is `None`.

> **Checkpoint 5** - Public subnet's effective route table has `0.0.0.0/0 -> igw-...`; private subnet's has no default route at all.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-21-47.png>)

---

### Step 14 - Create the application security group

```bash
APP_SG_ID=$(aws ec2 create-security-group \
  --group-name usms-app-sg \
  --description "USMS application tier: HTTP/HTTPS from the internet, SSH from inside the VPC" \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-app-sg},{Key=Project,Value=USMS},{Key=Tier,Value=app}]' \
  --query 'GroupId' \
  --output text)

echo "APP_SG_ID = $APP_SG_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text

aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SG_ID" \
  --protocol tcp --port 22 --cidr 10.0.0.0/16 \
  --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text
```

> Independent task
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-25-29.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-25-53.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-26-28.png>)

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SG_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS from the internet"}]}]' \
  --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-28-54.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-29-04.png>)

---

### Step 15 - Create the database security group, sourced from the application group

**Part 1 - Create the group:**

```bash
DB_SG_ID=$(aws ec2 create-security-group \
  --group-name usms-db-sg \
  --description "USMS data tier: PostgreSQL from the application tier only" \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-db-sg},{Key=Project,Value=USMS},{Key=Tier,Value=data}]' \
  --query 'GroupId' \
  --output text)

echo "DB_SG_ID = $DB_SG_ID"
```

**Part 2 - Write the rule as JSON:**

```bash
mkdir -p policies

cat > policies/usms-db-sg-ingress.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 5432,
    "ToPort": 5432,
    "UserIdGroupPairs": [
      {
        "GroupId": "$APP_SG_ID",
        "Description": "PostgreSQL from the USMS application tier"
      }
    ]
  }
]
EOF

cat policies/usms-db-sg-ingress.json
```

**Part 3 - Apply it:**

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --ip-permissions file://policies/usms-db-sg-ingress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' \
  --output text
```

Verify:

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,SourceSG:UserIdGroupPairs[0].GroupId,SourceCIDR:IpRanges[0].CidrIp}' \
  --output table
```

Expect `SourceSG` = `$APP_SG_ID`, `SourceCIDR` = `None`.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-31-35.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-31-52.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-32-04.png>)

---

### Step 16 - Read the groups back, and understand "stateful"

```bash
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Id:GroupId,Inbound:length(IpPermissions),Outbound:length(IpPermissionsEgress)}' \
  --output table
```

Expect three groups: `usms-app-sg`, `usms-db-sg`, and the VPC's `default`.

> **Checkpoint 6** - `usms-app-sg` has 80, 443, 22; `usms-db-sg` has 5432 sourced from `usms-app-sg`; three groups total.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-34-39.png>)

---

### Step 17 - Explore the default NACL, then create a private one

**Part 1 - Read the default NACL:**

```bash
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
  --query 'NetworkAcls[0].Entries[].{Rule:RuleNumber,Egress:Egress,Proto:Protocol,Action:RuleAction,CIDR:CidrBlock}' \
  --output table
```

**Part 2 - Create the private NACL:**

```bash
PRIVATE_NACL_ID=$(aws ec2 create-network-acl \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=network-acl,Tags=[{Key=Name,Value=usms-private-nacl},{Key=Project,Value=USMS},{Key=Tier,Value=private}]' \
  --query 'NetworkAcl.NetworkAclId' \
  --output text)

echo "PRIVATE_NACL_ID = $PRIVATE_NACL_ID"
```

**Part 3 - Write the rules:**

```bash
# Inbound 100: PostgreSQL from anywhere inside the VPC.
aws ec2 create-network-acl-entry \
  --network-acl-id "$PRIVATE_NACL_ID" \
  --rule-number 100 --protocol tcp --rule-action allow \
  --ingress --cidr-block 10.0.0.0/16 \
  --port-range From=5432,To=5432

# Inbound 110: return traffic for connections this subnet opened outbound.
aws ec2 create-network-acl-entry \
  --network-acl-id "$PRIVATE_NACL_ID" \
  --rule-number 110 --protocol tcp --rule-action allow \
  --ingress --cidr-block 0.0.0.0/0 \
  --port-range From=1024,To=65535

# Outbound 100: replies to the application tier.
aws ec2 create-network-acl-entry \
  --network-acl-id "$PRIVATE_NACL_ID" \
  --rule-number 100 --protocol tcp --rule-action allow \
  --egress --cidr-block 10.0.0.0/16 \
  --port-range From=1024,To=65535

# Outbound 110: HTTPS out, so the data tier can fetch OS updates through the NAT gateway.
aws ec2 create-network-acl-entry \
  --network-acl-id "$PRIVATE_NACL_ID" \
  --rule-number 110 --protocol tcp --rule-action allow \
  --egress --cidr-block 0.0.0.0/0 \
  --port-range From=443,To=443
```

Verify:

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$PRIVATE_NACL_ID" \
  --query 'NetworkAcls[0].Entries[].{Rule:RuleNumber,Egress:Egress,Action:RuleAction,CIDR:CidrBlock,Ports:PortRange}' \
  --output json
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-39-41.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-39-51.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-40-01.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-40-16.png>)

---

### Step 18 - Associate the private NACL with the private subnet

```bash
NACL_ASSOC_ID=$(aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_A_ID" \
  --query 'NetworkAcls[0].Associations[0].NetworkAclAssociationId' \
  --output text)

echo "current association: $NACL_ASSOC_ID"

aws ec2 replace-network-acl-association \
  --association-id "$NACL_ASSOC_ID" \
  --network-acl-id "$PRIVATE_NACL_ID" \
  --query 'NewAssociationId' \
  --output text
```

Verify:

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_A_ID" \
  --query 'NetworkAcls[0].{Id:NetworkAclId,Default:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

Expect `Id` = `$PRIVATE_NACL_ID`, `Default` = `False`.

> **Checkpoint 7** - `usms-private-nacl` has four explicit entries plus two implicit denies, and is the ACL associated with the private subnet.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-43-39.png>)

---

### Step 19 - Give the private subnet outbound internet access with a NAT gateway

**Part 1 - Allocate an Elastic IP:**

```bash
NAT_EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=usms-nat-eip},{Key=Project,Value=USMS}]' \
  --query 'AllocationId' \
  --output text)

echo "NAT_EIP_ALLOC_ID = $NAT_EIP_ALLOC_ID"

aws ec2 describe-addresses \
  --allocation-ids "$NAT_EIP_ALLOC_ID" \
  --query 'Addresses[0].{Alloc:AllocationId,IP:PublicIp,Domain:Domain}' \
  --output table
```

**Part 2 - Create the NAT gateway (in the PUBLIC subnet):**

```bash
NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_A_ID" \
  --allocation-id "$NAT_EIP_ALLOC_ID" \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=usms-nat},{Key=Project,Value=USMS}]' \
  --query 'NatGateway.NatGatewayId' \
  --output text)

echo "NAT_GW_ID = $NAT_GW_ID"
```

**Part 3 - Wait for it:**

```bash
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" && echo "NAT gateway available"
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-48-27.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-48-38.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-48-46.png>)

---

### Step 20 - Point the private route table at the NAT gateway

```bash
aws ec2 create-route \
  --route-table-id "$PRIVATE_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_GW_ID"

aws ec2 describe-route-tables \
  --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].Routes[].{Destination:DestinationCidrBlock,Gateway:GatewayId,NAT:NatGatewayId,State:State}' \
  --output table
```

Expect the default route's target to be the `nat-...` ID, **never** an `igw-...` ID.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-50-18.png>)

---

### Step 21 - Create the S3 gateway endpoint

```bash
S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.${AWS_REGION_COURSE}.s3" \
  --vpc-endpoint-type Gateway \
  --route-table-ids "$PRIVATE_RT_ID" \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=usms-s3-endpoint},{Key=Project,Value=USMS}]' \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text)

echo "S3_ENDPOINT_ID = $S3_ENDPOINT_ID"
```

Verify:

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$S3_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{Id:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType,State:State,RouteTables:RouteTableIds}' \
  --output json

aws ec2 describe-route-tables \
  --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].Routes[].{Destination:DestinationCidrBlock,PrefixList:DestinationPrefixListId,Target:GatewayId,NAT:NatGatewayId}' \
  --output table
```

> **Checkpoint 8** - `usms-nat` available in the public subnet with an Elastic IP; private route table's default route points at it; `usms-s3-endpoint` exists.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-51-52.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-52-04.png>)

---

### Step 22 - Audit tags

```bash
echo "== Resources tagged Project=USMS in this VPC =="
aws ec2 describe-tags \
  --filters "Name=tag:Project,Values=USMS" \
  --query 'sort_by(Tags[?Key==`Name`], &Value)[].{Type:ResourceType,Name:Value,Id:ResourceId}' \
  --output table
```

> Independent task
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-54-52.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-55-05.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-55-15.png>)

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'sort_by(Subnets, &Tags[?Key==`Tier`]|[0].Value)[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,Tier:Tags[?Key==`Tier`]|[0].Value}' \
  --output table | tee outputs/lab-02-subnet-inventory.txt
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-57-06.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-57-27.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-57-37.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 11-57-45.png>)

---

### Step 23 - Prove the network survives a restart

**Part 1 - Record the truth before restart:**

```bash
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].VpcId' --output text > outputs/lab-02-pre-restart.txt

aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'length(Subnets)' --output text >> outputs/lab-02-pre-restart.txt

aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'length(SecurityGroups)' --output text >> outputs/lab-02-pre-restart.txt

cat outputs/lab-02-pre-restart.txt
```

**Part 2 - Perturb:**

```bash
./scripts/setup/floci-down.sh
sleep 3
./scripts/setup/floci-up.sh
sleep 5
```

**Part 3 - Read it back:**

```bash
source configs/course.env

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=usms-vpc" \
  --query 'Vpcs[0].VpcId' --output text)

{
  echo "$VPC_ID"
  aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'length(Subnets)' --output text
  aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'length(SecurityGroups)' --output text
} > outputs/lab-02-post-restart.txt

diff outputs/lab-02-pre-restart.txt outputs/lab-02-post-restart.txt \
  && echo "PERSISTENCE PROVEN: VPC id, subnet count and security group count all unchanged" \
  || echo "PERSISTENCE FAILED: run ./scripts/utilities/floci-storage-check.sh"
```

> **Checkpoint 9** - `usms-vpc` found by tag after a stop/start cycle, subnet count unchanged, security group count unchanged.

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 12-00-40.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 12-00-51.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 12-01-02.png>)

---

### Step 24 - Write `configs/lab-02.env`

```bash
cat > configs/lab-02.env << EOF
# Lab 02 VPC and networking outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains IDs only. NO SECRETS. Safe to commit.

export USMS_VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=usms-vpc" \
  --query 'Vpcs[0].VpcId' --output text)
export USMS_VPC_CIDR=10.0.0.0/16

export USMS_IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=usms-igw" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)

export USMS_PUBLIC_SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=usms-public-subnet-a" \
  --query 'Subnets[0].SubnetId' --output text)
export USMS_PUBLIC_SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=usms-public-subnet-b" \
  --query 'Subnets[0].SubnetId' --output text)
export USMS_PRIVATE_SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=usms-private-subnet-a" \
  --query 'Subnets[0].SubnetId' --output text)
export USMS_PRIVATE_SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=usms-private-subnet-b" \
  --query 'Subnets[0].SubnetId' --output text)

export USMS_PUBLIC_RT=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=usms-public-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)
export USMS_PRIVATE_RT=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=usms-private-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)

export USMS_APP_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-app-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)
export USMS_DB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-db-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_PRIVATE_NACL=$(aws ec2 describe-network-acls \
  --filters "Name=tag:Name,Values=usms-private-nacl" \
  --query 'NetworkAcls[0].NetworkAclId' --output text)

export USMS_NAT_GW=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=usms-nat" \
  --query 'NatGateways[0].NatGatewayId' --output text)
export USMS_NAT_EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=usms-nat-eip" \
  --query 'Addresses[0].AllocationId' --output text)

export USMS_S3_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Name,Values=usms-s3-endpoint" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text)

export USMS_AZ_A=${AWS_REGION_COURSE}a
export USMS_AZ_B=${AWS_REGION_COURSE}b
EOF
```

Verify:

```bash
grep -n 'export .*=$\|None' configs/lab-02.env || echo "all values populated"

source configs/lab-02.env
echo "vpc=$USMS_VPC_ID  public-a=$USMS_PUBLIC_SUBNET_A  app-sg=$USMS_APP_SG"
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 12-03-17.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 12-03-28.png>)

---

### Step 25 - Commit work

```bash
git status --short

# Confirm secrets stay ignored
git check-ignore -v outputs/lab-02-assumed-role.json

git add labs/lab-02-vpc/ configs/lab-02.env policies/usms-db-sg-ingress.json \
        scripts/utilities/verify-lab-02.sh scripts/cleanup/lab-02-cleanup.sh

git status --short

git commit -m "Lab 02: USMS VPC, subnets, routing, security groups, NACL, NAT and S3 endpoint"

git log --oneline -3
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 12-05-27.png>)

---

### Verification script - `scripts/utilities/verify-lab-02.sh`

```bash
cat > scripts/utilities/verify-lab-02.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 02 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Safe to run at any time; read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

: "${USMS_VPC_ID:=none}"
: "${USMS_IGW_ID:=none}"
: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PUBLIC_RT:=none}"
: "${USMS_PRIVATE_RT:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_DB_SG:=none}"
: "${USMS_PRIVATE_NACL:=none}"
: "${USMS_S3_ENDPOINT:=none}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 01 dependencies still present =="
check "role usms-developer-role"      "aws iam get-role --role-name usms-developer-role"
check "instance profile usms-ec2-app-profile" \
  "aws iam get-instance-profile --instance-profile-name usms-ec2-app-profile"

echo "== Lab 02 resources =="
check "usms-vpc exists"               "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "vpc CIDR is 10.0.0.0/16" \
  "test \"\$(aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID --query 'Vpcs[0].CidrBlock' --output text)\" = 10.0.0.0/16"
check "vpc DNS hostnames enabled" \
  "test \"\$(aws ec2 describe-vpc-attribute --vpc-id $USMS_VPC_ID --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text)\" = True"

check "usms-igw exists"               "aws ec2 describe-internet-gateways --internet-gateway-ids $USMS_IGW_ID"
check "usms-igw ATTACHED to usms-vpc" \
  "test \"\$(aws ec2 describe-internet-gateways --internet-gateway-ids $USMS_IGW_ID --query 'InternetGateways[0].Attachments[0].VpcId' --output text)\" = $USMS_VPC_ID"

check "public subnet a exists"        "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "public subnet a auto-assigns public IP" \
  "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = True"
check "private subnet a exists"       "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"
check "private subnet a does NOT auto-assign public IP" \
  "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = False"

check "public rt has a default route to an igw" \
  "aws ec2 describe-route-tables --route-table-ids $USMS_PUBLIC_RT --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q '^igw-\|	igw-'"
check "public subnet a is associated with usms-public-rt" \
  "test \"\$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$USMS_PUBLIC_SUBNET_A --query 'RouteTables[0].RouteTableId' --output text)\" = $USMS_PUBLIC_RT"
check "private subnet a is associated with usms-private-rt" \
  "test \"\$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A --query 'RouteTables[0].RouteTableId' --output text)\" = $USMS_PRIVATE_RT"
check "private rt has NO route to an internet gateway" \
  "! aws ec2 describe-route-tables --route-table-ids $USMS_PRIVATE_RT --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"

check "usms-app-sg exists"            "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "usms-app-sg allows tcp 80"     \
  "aws ec2 describe-security-groups --group-ids $USMS_APP_SG --query 'SecurityGroups[0].IpPermissions[].FromPort' --output text | grep -qw 80"
check "usms-db-sg exists"             "aws ec2 describe-security-groups --group-ids $USMS_DB_SG"
check "usms-db-sg is sourced from usms-app-sg (not a CIDR)" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_DB_SG --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)\" = $USMS_APP_SG"

check "usms-private-nacl exists"      "aws ec2 describe-network-acls --network-acl-ids $USMS_PRIVATE_NACL"
check "usms-private-nacl is attached to the private subnet" \
  "test \"\$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A --query 'NetworkAcls[0].NetworkAclId' --output text)\" = $USMS_PRIVATE_NACL"
check "usms-private-nacl is not the default ACL" \
  "test \"\$(aws ec2 describe-network-acls --network-acl-ids $USMS_PRIVATE_NACL --query 'NetworkAcls[0].IsDefault' --output text)\" = False"

check "usms-s3-endpoint exists"       "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $USMS_S3_ENDPOINT"

echo "== Tagging =="
check "every Lab 02 resource carries Project=USMS" \
  "test \"\$(aws ec2 describe-tags --filters Name=tag:Project,Values=USMS Name=key,Values=Name --query 'length(Tags)' --output text)\" -ge 10"

echo "== Files and Git hygiene =="
check "configs/lab-02.env exists"     "test -f configs/lab-02.env"
check "configs/lab-02.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-02.env"
check "policies/usms-db-sg-ingress.json is valid JSON" \
  "python3 -m json.tool policies/usms-db-sg-ingress.json"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"
check ".gitignore uses outputs/* not outputs/" "grep -q '^outputs/\*' .gitignore"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-02.sh
./scripts/utilities/verify-lab-02.sh
```

Expected: `PASS=33  FAIL=0` (33 only after both "Your turn" tasks / Exercise 5 are complete; otherwise `USMS_PUBLIC_SUBNET_B` / `USMS_PRIVATE_SUBNET_B` show as `None` and the empty-value check fails as expected until those are done).

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 13-24-47.png>)

---

### Cleanup script (build only — DO NOT RUN)

```bash
cat > scripts/cleanup/lab-02-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Deletes the entire Lab 02 network, dependencies first.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

cat <<'WARN'
============================================================
  This deletes the ENTIRE USMS VPC and everything in it.
  Labs 03, 04, 05 and 06 all depend on it.
  Terminate all EC2 instances (Lab 03) BEFORE running this.
============================================================
WARN

read -r -p 'Type exactly: DELETE USMS NETWORK  > ' answer
[ "$answer" = "DELETE USMS NETWORK" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "NAT gateway"
if [ "${USMS_NAT_GW:-None}" != "None" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$USMS_NAT_GW" || true
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$USMS_NAT_GW" || sleep 20
fi

say "Elastic IP"
[ "${USMS_NAT_EIP_ALLOC:-None}" != "None" ] && \
  aws ec2 release-address --allocation-id "$USMS_NAT_EIP_ALLOC" || true

say "VPC endpoint"
[ "${USMS_S3_ENDPOINT:-None}" != "None" ] && \
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$USMS_S3_ENDPOINT" || true

say "route table associations"
for rt in "$USMS_PUBLIC_RT" "$USMS_PRIVATE_RT"; do
  [ "$rt" = "None" ] && continue
  for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" \
                   --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
                   --output text); do
    aws ec2 disassociate-route-table --association-id "$assoc" || true
  done
  aws ec2 delete-route-table --route-table-id "$rt" || true
done

say "network ACL"
[ "${USMS_PRIVATE_NACL:-None}" != "None" ] && \
  aws ec2 delete-network-acl --network-acl-id "$USMS_PRIVATE_NACL" || true

say "security groups (db first: app is referenced by it)"
[ "${USMS_DB_SG:-None}"  != "None" ] && aws ec2 delete-security-group --group-id "$USMS_DB_SG"  || true
[ "${USMS_APP_SG:-None}" != "None" ] && aws ec2 delete-security-group --group-id "$USMS_APP_SG" || true

say "subnets"
for s in "$USMS_PUBLIC_SUBNET_A" "$USMS_PUBLIC_SUBNET_B" \
         "$USMS_PRIVATE_SUBNET_A" "$USMS_PRIVATE_SUBNET_B"; do
  [ "$s" = "None" ] && continue
  aws ec2 delete-subnet --subnet-id "$s" || true
done

say "internet gateway"
if [ "${USMS_IGW_ID:-None}" != "None" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$USMS_IGW_ID" --vpc-id "$USMS_VPC_ID" || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$USMS_IGW_ID" || true
fi

say "VPC"
aws ec2 delete-vpc --vpc-id "$USMS_VPC_ID" || true

echo; echo "Lab 02 teardown complete."
EOF

chmod +x scripts/cleanup/lab-02-cleanup.sh
bash -n scripts/cleanup/lab-02-cleanup.sh && echo "syntax OK do NOT run it"
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-06-14.png>)

---

### Independent Lab Exercises

#### Exercise 1 - Basic: a third public subnet

```bash
PUBLIC_SUBNET_C_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.5.0/24 \
  --availability-zone "${AWS_REGION_COURSE}c" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-public-subnet-c},{Key=Project,Value=USMS},{Key=Tier,Value=public},{Key=AZ,Value=c}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "PUBLIC_SUBNET_C_ID = $PUBLIC_SUBNET_C_ID"

aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_C_ID" \
  --map-public-ip-on-launch

aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_C_ID" \
  --query 'AssociationId' \
  --output text
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-41-16.png>)

#### Exercise 2 - Intermediate: a bastion security group

```bash
BASTION_SG_ID=$(aws ec2 create-security-group \
  --group-name usms-bastion-sg \
  --description "USMS bastion host: SSH from a single trusted admin address" \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-bastion-sg},{Key=Project,Value=USMS},{Key=Tier,Value=bastion}]' \
  --query 'GroupId' \
  --output text)

echo "BASTION_SG_ID = $BASTION_SG_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$BASTION_SG_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"203.0.113.10/32","Description":"SSH from the admin workstation"}]}]'

# Add the new SSH rule sourced from the bastion group
aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SG_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$BASTION_SG_ID\",\"Description\":\"SSH from the bastion host only\"}]}]"

# Find and revoke the old CIDR-based SSH rule
OLD_SSH_RULE_ID=$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$APP_SG_ID" \
  --query "SecurityGroupRules[?FromPort==\`22\` && CidrIpv4==\`10.0.0.0/16\`].SecurityGroupRuleId | [0]" \
  --output text)

aws ec2 revoke-security-group-ingress \
  --group-id "$APP_SG_ID" \
  --security-group-rule-ids "$OLD_SSH_RULE_ID"
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-42-39.png>)

#### Exercise 3 - Problem solving: network report script

```bash
mkdir -p scripts/utilities

cat > scripts/utilities/lab-02-network-report.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$USMS_VPC_ID" \
  --query 'Subnets[].SubnetId' --output text)

for s in $SUBNETS; do
  name=$(aws ec2 describe-subnets --subnet-ids "$s" \
    --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text)
  cidr=$(aws ec2 describe-subnets --subnet-ids "$s" \
    --query 'Subnets[0].CidrBlock' --output text)
  az=$(aws ec2 describe-subnets --subnet-ids "$s" \
    --query 'Subnets[0].AvailabilityZone' --output text)

  rt=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$s" \
    --query 'RouteTables[0].RouteTableId' --output text)

  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
    --output text 2>/dev/null)
  nat=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' \
    --output text 2>/dev/null)

  if [ "$igw" != "None" ] && [ -n "$igw" ]; then
    printf '%-24s%-14s%-12s%-9svia %s\n' "$name" "$cidr" "$az" "PUBLIC" "$igw"
  elif [ "$nat" != "None" ] && [ -n "$nat" ]; then
    printf '%-24s%-14s%-12s%-9svia %s\n' "$name" "$cidr" "$az" "PRIVATE" "$nat"
  else
    printf '%-24s%-14s%-12s%-9sno default route\n' "$name" "$cidr" "$az" "ISOLATED"
  fi
done
EOF

chmod +x scripts/utilities/lab-02-network-report.sh
./scripts/utilities/lab-02-network-report.sh
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-45-08.png>)

#### Exercise 4 - Challenge: design and defend

Write the design (subnet placement, security group rules, NACL reasoning, NAT gateway HA/cost trade-off, and a teardown plan for `usms-public-subnet-c`) in `labs/lab-02-vpc/exercises.md`. Then implement the security group portion only:

```bash
EXAM_SG_ID=$(aws ec2 create-security-group \
  --group-name usms-exam-sg \
  --description "USMS exam-results service: PostgreSQL read access from the campus VPN CIDR only, no internet inbound" \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-exam-sg},{Key=Project,Value=USMS},{Key=Tier,Value=app}]' \
  --query 'GroupId' \
  --output text)

echo "EXAM_SG_ID = $EXAM_SG_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$EXAM_SG_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"10.10.0.0/16","Description":"HTTPS from the campus VPN range only"}]}]'

# Allow the exam service to reach the database tier
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"UserIdGroupPairs\":[{\"GroupId\":\"$EXAM_SG_ID\",\"Description\":\"PostgreSQL from the exam-results service\"}]}]"
```

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-46-30.png>)

#### Exercise 5 - Integration: complete the second Availability Zone

```bash
# Assume the developer role again
aws sts get-caller-identity   # before

ROLE_ARN="arn:aws:iam::${USMS_ACCOUNT_ID}:role/${USMS_ROLE_DEVELOPER}"

aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "lab02-ex5-second-az" \
  --profile usms-dev \
  > outputs/lab-02-ex5-assumed-role.json

chmod 600 outputs/lab-02-ex5-assumed-role.json

export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId'     outputs/lab-02-ex5-assumed-role.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' outputs/lab-02-ex5-assumed-role.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken'    outputs/lab-02-ex5-assumed-role.json)

aws sts get-caller-identity   # after — must show assumed-role

PRIVATE_SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.4.0/24 \
  --availability-zone "${AWS_REGION_COURSE}b" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-private-subnet-b},{Key=Project,Value=USMS},{Key=Tier,Value=private},{Key=AZ,Value=b}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "PRIVATE_SUBNET_B_ID = $PRIVATE_SUBNET_B_ID"

aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_RT_ID" \
  --subnet-id "$PRIVATE_SUBNET_B_ID"

# Apply the private NACL to the new subnet too
NACL_ASSOC_B_ID=$(aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_B_ID" \
  --query 'NetworkAcls[0].Associations[0].NetworkAclAssociationId' \
  --output text)

aws ec2 replace-network-acl-association \
  --association-id "$NACL_ASSOC_B_ID" \
  --network-acl-id "$PRIVATE_NACL_ID"

# Restore normal identity immediately
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
./scripts/utilities/whoami.sh
```

Then regenerate `configs/lab-02.env` (Step 24) and re-run the verification script (expect `PASS=33  FAIL=0`).

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-47-51.png>)

---

## 6. Results and Evidence

### 6.1 CLI / SDK Output

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-58-14.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-58-20.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-59-45.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 14-59-57.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-00-13.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-00-20.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-00-30.png>)

### 6.2 AWS Management Console / Floci Verification

Providing screenshots confirming successful resource creation, with a one-line explanation each.

| Resource | One-line explanation |
|---|---|
| `usms-vpc` | VPC created with CIDR 10.0.0.0/16, DNS support and hostnames enabled | 
| `usms-igw` | Internet gateway attached, giving the public subnets a path outward | 
| `usms-public-subnet-a` / `-b` | Public subnets routed to the internet gateway, auto-assign public IP on | 
| `usms-private-subnet-a` / `-b` | Private subnets routed to the NAT gateway, no direct internet route | 
| `usms-app-sg` / `usms-db-sg` | Application and database security groups, db sourced from app by group reference |
| `usms-private-nacl` | Subnet-level firewall on the private subnet with explicit allow rules | 
| `usms-nat` | NAT gateway giving the private tier outbound-only internet access | 
| `usms-s3-endpoint` | Gateway endpoint keeping S3 traffic off the public internet | 

### Screenshots

> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-08-15.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-08-24.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-08-32.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-08-40.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-08-46.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-08-54.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-27 15-09-02.png>)

---

## 7. Analysis and Discussion

## What Was Achieved
 
A complete two-tier VPC network for the USMS application was successfully created. The architecture consisted of a public web tier and a private data tier distributed across two Availability Zones.
 
The configuration included:
 
- Public and private subnets
- An Internet Gateway
- Route tables
- Application and database security groups
- A private Network ACL
- A NAT Gateway
- An S3 gateway endpoint, providing a private path for S3 traffic without requiring the traffic to use the public internet
## Did the Results Match the Expected Outcome?
 
Yes. The results matched the expected outcome for all required checkpoints (1–9). The final verification script also completed successfully with:
 
```
PASS=33
FAIL=0
```
 
This confirmed that all 33 automated verification checks passed and that the required VPC resources and configurations were present as expected.
 
## Errors Encountered
 
During the implementation, some commands could produce errors such as `InvalidParameterValue`, `DependencyViolation`, or `ExpiredToken`, depending on the state of the Floci environment and the order in which resources were created or removed.
 
These issues were handled as follows, referring to the Troubleshooting section of the lab:
 
- **Parameter-related errors** — checked the relevant command parameters and resource IDs
- **Dependency errors** — resolved by ensuring dependent resources were removed or detached before attempting deletion
- **Authentication errors (`ExpiredToken`)** — addressed by refreshing the AWS/Floci credentials or environment variables before rerunning the command
After troubleshooting, the affected commands were rerun and the required resources were successfully created and verified.
 
## Observations
 
One important observation was the difference between what could be directly observed and verified in Floci and what remained conceptual.
 
**Directly observable via AWS CLI:**
 
The existence and configuration of API objects could be observed directly through AWS CLI commands. This included VPCs, subnets, route tables, Internet Gateways, security groups, Network ACLs, NAT Gateways, and the S3 gateway endpoint. Resource IDs, CIDR blocks, associations, routes, and reserved IP addresses could also be inspected. The persistence of resources across a Floci restart could be checked to confirm whether the configured state was retained.
 
**Remained largely conceptual:**
 
Some real AWS networking behaviour was not fully observable in the Floci environment, including:
 
- Actual packet forwarding
- Security-group and NACL enforcement
- NAT address translation
- Complete DNS resolution behaviour
- Real AWS networking costs
Although the API configuration represented the intended two-tier architecture, it should not be interpreted as proof that all underlying AWS network traffic would behave exactly the same way as it would in a real AWS environment.
 
Overall, the lab successfully demonstrated the design and configuration of a secure two-tier VPC architecture, while also highlighting the difference between API-level resource configuration and actual cloud networking behaviour.
 

---

## 8. Reflection

#### 1. What Did You Learn About This AWS Service?
 
This practical helped develop a clear understanding of Amazon VPC (Virtual Private Cloud) and how it is used to create an isolated network environment in AWS. The practical demonstrated how VPCs can be divided into public and private subnets across multiple Availability Zones. It also showed how Internet Gateways, NAT Gateways, route tables, Security Groups, Network ACLs, and S3 gateway endpoints work together to control network access and improve security. Another important learning was the difference between configuring networking resources through the AWS CLI and understanding how the actual network traffic would behave in a real AWS environment.
 
#### 2. What Challenges Did You Encounter?
 
The main challenges involved creating and configuring the networking resources in the correct order and ensuring that the resources were properly associated with the correct VPC, subnets, and route tables. Some commands could also produce errors related to invalid parameters, resource dependencies, or expired credentials. Troubleshooting these issues required checking resource IDs, reviewing the lab's Troubleshooting section, and rerunning commands after correcting the configuration. Another challenge was understanding which networking features could be directly verified in Floci and which behaviours were only represented conceptually.
 
#### 3. How Would You Apply This Service in a Real-World Cloud Environment?
 
In a real-world environment, Amazon VPC could be used to create a secure network for applications by separating resources into public and private subnets. Public subnets could host resources that need controlled internet access, while databases and other sensitive services could remain in private subnets. Security Groups and Network ACLs could provide multiple layers of network protection, while NAT Gateways could allow private resources to make outbound connections without exposing them directly to the internet. S3 gateway endpoints could also be used to allow private communication with S3. This type of architecture would be useful for web applications, APIs, enterprise systems, and other cloud-based applications that require security and network isolation.
 
#### 4. What Additional Concepts or Features Would You Like to Explore?
 
The next concepts I would like to explore are:
 
- **VPC Peering** - to understand how two VPCs can communicate with each other
- **AWS Transit Gateway** - to gain experience connecting multiple VPCs and networks through a central networking service
- **VPC Flow Logs** - to monitor and troubleshoot network traffic
- **Interface VPC Endpoints** - to better understand private connectivity to AWS services and how they differ from gateway endpoints such as the S3 endpoint used in this practical

---

## 9. Conclusion

The objective of the practical was successfully achieved by creating a working, verifiable, and persistent USMS VPC with properly separated public and private tiers across two Availability Zones.
 
The practical provided a clear understanding of important VPC concepts, including:
 
- CIDR sizing
- Public versus private subnet mechanics
- Security Groups versus Network ACLs
- NAT Gateways
- S3 gateway endpoints
- Least-privilege role usage
The practical also helped develop practical skills in using the AWS CLI, JMESPath queries, infrastructure-as-scripts, and consistent resource tagging. Troubleshooting the configuration and verifying the final resources improved understanding of how cloud networking components work together and how they can be managed through command-line tools.

Overall, this practical demonstrated that a VPC is the networking and security foundation of AWS cloud environments. The knowledge gained from this lab will be important for the upcoming labs:
 
| Lab | Service |
|-----|---------|
| Lab 3 | EC2 |
| Lab 4 | S3 |
| Lab 5 | Lambda |
| Lab 6 | RDS |
 
These upcoming services will depend on appropriate networking, security, and access configurations established in this practical.

---

## 10. Appendix

### 10.1 Review Questions (answer in `notes/lab-02-notes.md`)

### 10.2 Command Reference

See the full AWS CLI command reference table and JMESPath pattern reference in the original Lab 02 material (Appendix A and Appendix B), covering `create-vpc`, `create-subnet`, `create-route-table`, `create-security-group`, `create-network-acl`, `create-nat-gateway`, `create-vpc-endpoint`, and the JMESPath patterns `sort_by()`, `length()`, `contains()`, tag-value extraction, and `--filters` vs `--query`.

### 10.3 Additional Files

- `configs/lab-02.env` - all resource IDs produced by this lab
- `policies/usms-db-sg-ingress.json` - group-referenced security group rule document
- `scripts/utilities/verify-lab-02.sh` - read-only verification script
- `scripts/cleanup/lab-02-cleanup.sh` - end-of-course teardown script (not run)
- `scripts/utilities/lab-02-network-report.sh` - Exercise 3 network classification script
- `labs/lab-02-vpc/exercises.md` - Exercise 1–5 write-ups and command output
- `notes/lab-02-notes.md` - Review question answers

---

## Submission Checklist

- [x] Aim/Objectives clearly stated
- [x] Introduction provided
- [x] Real-world use case described
- [x] System architecture diagram included
- [x] All 25 implementation steps documented with commands and output
- [x] All "Your turn" tasks and Exercises 1–5 completed
- [x] CLI/SDK screenshots included for every step
- [x] Console/Floci verification screenshots included
- [x] Verification script run with `PASS=33 FAIL=0`
- [x] Analysis and discussion completed
- [x] Reflection completed
- [x] Conclusion written
- [x] Review questions answered in `notes/lab-02-notes.md`
- [x] Appendix attached