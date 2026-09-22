#!/usr/bin/env bash
# Verify every Lab 03 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Safe to run at any time; read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true

: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_DB_SG:=none}"
: "${USMS_INSTANCE_PROFILE:=usms-ec2-app-profile}"

# Resolve this lab's resources from live state rather than trusting the env
# file — verification must not depend on the thing it is verifying.
STATES="pending,running,stopping,stopped"
by_tag() {  # by_tag <name-tag> -> instance id, or empty
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=$STATES" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null \
    | grep -v '^None$'
}
WEB=$(by_tag usms-web-01); : "${WEB:=none}"
DB=$(by_tag usms-db-01);   : "${DB:=none}"

# Floci ignores --filters on describe-addresses, so match in JMESPath.
EIP_IP=$(aws ec2 describe-addresses \
  --query 'Addresses[?Tags[?Key==`Name`&&Value==`usms-web-eip`]]|[0].PublicIp' \
  --output text 2>/dev/null | grep -v '^None$'); : "${EIP_IP:=none}"
EIP_ALLOC=$(aws ec2 describe-addresses \
  --query 'Addresses[?Tags[?Key==`Name`&&Value==`usms-web-eip`]]|[0].AllocationId' \
  --output text 2>/dev/null | grep -v '^None$'); : "${EIP_ALLOC:=none}"

VOL=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values=usms-web-data-vol" \
  --query 'Volumes[0].VolumeId' --output text 2>/dev/null | grep -v '^None$')
: "${VOL:=none}"

GOLDEN=$(aws ec2 describe-images --owners self \
  --query 'Images[?starts_with(Name, `usms-web-golden`)]|[0].ImageId' \
  --output text 2>/dev/null | grep -v '^None$'); : "${GOLDEN:=none}"

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

echo "== Lab 01 / 02 dependencies still present =="
check "instance profile usms-ec2-app-profile" \
  "aws iam get-instance-profile --instance-profile-name $USMS_INSTANCE_PROFILE"
check "usms-app-sg exists"  "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "usms-db-sg exists"   "aws ec2 describe-security-groups --group-ids $USMS_DB_SG"
check "public subnet a exists"  "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "private subnet a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"

echo "== Key pair =="
check "key pair usms-app-key exists" \
  "aws ec2 describe-key-pairs --key-names usms-app-key"
check "private key is NOT tracked by git" \
  "! git ls-files --error-unmatch outputs/usms-app-key.pem"

echo "== Web tier: usms-web-01 =="
check "usms-web-01 exists"  "test $WEB != none"
check "usms-web-01 is running" \
  "test \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].State.Name' --output text)\" = running"
check "usms-web-01 is t3.micro" \
  "test \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].InstanceType' --output text)\" = t3.micro"
check "usms-web-01 is in the PUBLIC subnet" \
  "test \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].SubnetId' --output text)\" = $USMS_PUBLIC_SUBNET_A"
check "usms-web-01 carries usms-app-sg" \
  "aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text | grep -qw $USMS_APP_SG"
check "usms-web-01 carries the IAM instance profile" \
  "aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | grep -q 'instance-profile/$USMS_INSTANCE_PROFILE'"
check "usms-web-01 uses key pair usms-app-key" \
  "test \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].KeyName' --output text)\" = usms-app-key"
check "usms-web-01 is in AZ a" \
  "aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text | grep -q 'a$'"
check "usms-web-01 HAS a public address" \
  "aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].PublicIpAddress' --output text | grep -qv '^None$'"
check "usms-web-01 tagged Tier=web" \
  "test \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].Tags[?Key==\`Tier\`]|[0].Value' --output text)\" = web"
check "usms-web-01 tagged Project=USMS" \
  "test \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].Tags[?Key==\`Project\`]|[0].Value' --output text)\" = USMS"
check "usms-web-01 tagged Lab=03" \
  "test \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].Tags[?Key==\`Lab\`]|[0].Value' --output text)\" = 03"

echo "== Data tier: usms-db-01 =="
check "usms-db-01 exists"   "test $DB != none"
check "usms-db-01 is running" \
  "test \"\$(aws ec2 describe-instances --instance-ids $DB --query 'Reservations[0].Instances[0].State.Name' --output text)\" = running"
check "usms-db-01 is in the PRIVATE subnet" \
  "test \"\$(aws ec2 describe-instances --instance-ids $DB --query 'Reservations[0].Instances[0].SubnetId' --output text)\" = $USMS_PRIVATE_SUBNET_A"
check "usms-db-01 carries usms-db-sg" \
  "aws ec2 describe-instances --instance-ids $DB --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text | grep -qw $USMS_DB_SG"
check "usms-db-01 has NO public address" \
  "test \"\$(aws ec2 describe-instances --instance-ids $DB --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)\" = None"
check "usms-db-01 has NO IAM instance profile" \
  "test \"\$(aws ec2 describe-instances --instance-ids $DB --query 'Reservations[0].Instances[0].IamInstanceProfile' --output text)\" = None"
check "usms-db-01 tagged Tier=data" \
  "test \"\$(aws ec2 describe-instances --instance-ids $DB --query 'Reservations[0].Instances[0].Tags[?Key==\`Tier\`]|[0].Value' --output text)\" = data"
check "usms-db-sg is sourced from usms-app-sg, not a CIDR" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_DB_SG --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)\" = $USMS_APP_SG"

echo "== Elastic IP =="
check "usms-web-eip exists"  "test $EIP_ALLOC != none"
check "usms-web-eip is ASSOCIATED with usms-web-01" \
  "test \"\$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOC --query 'Addresses[0].InstanceId' --output text)\" = $WEB"
check "usms-web-eip is not the NAT eip" \
  "test \"\$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOC --query 'Addresses[0].Tags[?Key==\`Name\`]|[0].Value' --output text)\" = usms-web-eip"

echo "== EBS data volume =="
check "usms-web-data-vol exists" "test $VOL != none"
check "usms-web-data-vol is 8 GiB" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $VOL --query 'Volumes[0].Size' --output text)\" = 8"
check "usms-web-data-vol is ATTACHED to usms-web-01" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $VOL --query 'Volumes[0].Attachments[0].InstanceId' --output text)\" = $WEB"
check "usms-web-data-vol is attached at /dev/sdf" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $VOL --query 'Volumes[0].Attachments[0].Device' --output text)\" = /dev/sdf"
check "usms-web-data-vol is in the same AZ as usms-web-01" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $VOL --query 'Volumes[0].AvailabilityZone' --output text)\" = \"\$(aws ec2 describe-instances --instance-ids $WEB --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)\""

echo "== Golden AMI =="
check "golden AMI exists"   "test $GOLDEN != none"
check "golden AMI is available" \
  "test \"\$(aws ec2 describe-images --image-ids $GOLDEN --query 'Images[0].State' --output text)\" = available"
check "golden AMI is owned by this account, not amazon" \
  "test \"\$(aws ec2 describe-images --image-ids $GOLDEN --query 'Images[0].OwnerId' --output text)\" = 000000000000"

echo "== Files and Git hygiene =="
check "templates/lab-03-run-instances.json is valid JSON" \
  "python3 -m json.tool templates/lab-03-run-instances.json"
check "run-instances template has no unsubstituted \$VARS" \
  "! grep -q '\\\$[A-Z_]' templates/lab-03-run-instances.json"
check "labs/lab-03-ec2/user-data.sh exists" "test -f labs/lab-03-ec2/user-data.sh"
check "configs/lab-03.env exists"           "test -f configs/lab-03.env"
check "configs/lab-03.env has no empty or None values" \
  "test -f configs/lab-03.env && ! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-03.env"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
