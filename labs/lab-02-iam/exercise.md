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