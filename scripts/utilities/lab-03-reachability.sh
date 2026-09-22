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
