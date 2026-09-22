#!/usr/bin/env bash
# Restore a Lab 03 working shell after a terminal reset.
#
#   source scripts/utilities/lab-03-resume.sh
#
# MUST be sourced, not executed — it exports variables into your shell.
# Deliberately does not use `set -e`: an error here must not kill your shell.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: source this script, do not run it:"
  echo "   source scripts/utilities/lab-03-resume.sh"
  exit 1
fi

_l3_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

source "$_l3_root/configs/course.env"
source "$_l3_root/configs/lab-01.env"
source "$_l3_root/configs/lab-02.env"
[ -f "$_l3_root/configs/lab-03.env" ] && source "$_l3_root/configs/lab-03.env"

# Look up a resource id by its Name tag. Prints nothing if absent.
_l3_by_name() {
  local out
  out=$(aws ec2 "$@" 2>/dev/null) || return 0
  [ "$out" = "None" ] && return 0
  echo "$out"
}

# Base AMI — a plain shell var in Step 3, not stored in any env file.
AMI_ID=$(_l3_by_name describe-images --owners amazon \
  --query 'Images[0].ImageId' --output text)

# Instance ids — set in Steps 8 and 12, lost on any new terminal.
_l3_states="pending,running,stopping,stopped"

WEB_INSTANCE_ID=$(_l3_by_name describe-instances \
  --filters "Name=tag:Name,Values=usms-web-01" \
            "Name=instance-state-name,Values=$_l3_states" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

DB_INSTANCE_ID=$(_l3_by_name describe-instances \
  --filters "Name=tag:Name,Values=usms-db-01" \
            "Name=instance-state-name,Values=$_l3_states" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

WEB2_INSTANCE_ID=$(_l3_by_name describe-instances \
  --filters "Name=tag:Name,Values=usms-web-02" \
            "Name=instance-state-name,Values=$_l3_states" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Elastic IP, data volume, golden AMI — may not exist yet depending on progress.
#
# NOTE: Floci ignores --filters on describe-addresses (it returns every EIP,
# including Lab 02's usms-nat-eip), so the Name match is done in JMESPath here.
# Using --filters would silently pick the NAT EIP instead of the web one.
EIP_ALLOC_ID=$(_l3_by_name describe-addresses \
  --query 'Addresses[?Tags[?Key==`Name`&&Value==`usms-web-eip`]]|[0].AllocationId' \
  --output text)

EIP_PUBLIC_IP=$(_l3_by_name describe-addresses \
  --query 'Addresses[?Tags[?Key==`Name`&&Value==`usms-web-eip`]]|[0].PublicIp' \
  --output text)

DATA_VOLUME_ID=$(_l3_by_name describe-volumes \
  --filters "Name=tag:Name,Values=usms-web-data-vol" \
  --query 'Volumes[0].VolumeId' --output text)

WEB_AMI_ID=$(_l3_by_name describe-images --owners self \
  --filters "Name=tag:Name,Values=usms-web-golden" \
  --query 'Images[0].ImageId' --output text)

export AMI_ID WEB_INSTANCE_ID DB_INSTANCE_ID WEB2_INSTANCE_ID \
       EIP_ALLOC_ID EIP_PUBLIC_IP DATA_VOLUME_ID WEB_AMI_ID

printf '%-20s %s\n' \
  "AWS_PROFILE"      "${AWS_PROFILE:-<unset>}" \
  "AMI_ID"           "${AMI_ID:-<not found>}" \
  "WEB_INSTANCE_ID"  "${WEB_INSTANCE_ID:-<not created yet>}" \
  "DB_INSTANCE_ID"   "${DB_INSTANCE_ID:-<not created yet>}" \
  "WEB2_INSTANCE_ID" "${WEB2_INSTANCE_ID:-<not created yet>}" \
  "EIP_ALLOC_ID"     "${EIP_ALLOC_ID:-<not created yet>}" \
  "EIP_PUBLIC_IP"    "${EIP_PUBLIC_IP:-<not created yet>}" \
  "DATA_VOLUME_ID"   "${DATA_VOLUME_ID:-<not created yet>}" \
  "WEB_AMI_ID"       "${WEB_AMI_ID:-<not created yet>}"

unset _l3_root _l3_states
unset -f _l3_by_name
