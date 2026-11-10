#!/usr/bin/env bash
# USMS exposure report. Read-only. Always exits 0.
#
# Classifies every network interface (ENI) in usms-vpc as EXPOSED or ISOLATED.
# An ENI is EXPOSED only when ALL THREE independent conditions hold:
#   1. ADDRESS - it has a public address (on the ENI, or on the instance it is attached to)
#   2. ROUTE   - its subnet's route table sends 0.0.0.0/0 to an internet gateway (igw-)
#   3. RULE    - one of its security groups admits a public CIDR (0.0.0.0/0 or ::/0)
# If any one is missing, the internet cannot open a connection to it: ISOLATED,
# and the report names every control that is doing the isolating.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC_ID="${1:-${USMS_VPC_ID:-}}"
if [ -z "$VPC_ID" ]; then
  echo "no VPC id - pass one as \$1 or source configs/lab-02.env" >&2
  exit 0
fi

python3 - "$VPC_ID" << 'PY'
import json, subprocess, sys

vpc = sys.argv[1]

def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        return {}
    return json.loads(out.stdout)

vpc_filter = ["--filters", f"Name=vpc-id,Values={vpc}"]
enis    = aws("ec2", "describe-network-interfaces", *vpc_filter).get("NetworkInterfaces", [])
rtables = aws("ec2", "describe-route-tables", *vpc_filter).get("RouteTables", [])
groups  = {g["GroupId"]: g for g in aws("ec2", "describe-security-groups", *vpc_filter).get("SecurityGroups", [])}
subnets = {s["SubnetId"]: s for s in aws("ec2", "describe-subnets", *vpc_filter).get("Subnets", [])}

instances = {}
for res in aws("ec2", "describe-instances", *vpc_filter).get("Reservations", []):
    for i in res.get("Instances", []):
        instances[i["InstanceId"]] = i

def tag(obj, key="Name"):
    for t in obj.get("Tags", []) or []:
        if t.get("Key") == key:
            return t.get("Value")
    return None

# subnet -> route table (explicit association first, else the VPC's main table)
main_rt, rt_for = None, {}
for rt in rtables:
    for a in rt.get("Associations", []):
        if a.get("Main"):
            main_rt = rt
        if a.get("SubnetId"):
            rt_for[a["SubnetId"]] = rt

def igw_route(subnet_id):
    rt = rt_for.get(subnet_id, main_rt)
    if not rt:
        return None, "no route table"
    for r in rt.get("Routes", []):
        if r.get("DestinationCidrBlock") == "0.0.0.0/0" and str(r.get("GatewayId", "")).startswith("igw-"):
            return rt["RouteTableId"], r["GatewayId"]
    return rt["RouteTableId"], None

def public_rules(group_ids):
    found = []
    for gid in group_ids:
        g = groups.get(gid, {})
        for p in g.get("IpPermissions", []):
            cidrs = [x.get("CidrIp") for x in p.get("IpRanges", [])] + \
                    [x.get("CidrIpv6") for x in p.get("Ipv6Ranges", [])]
            if any(c in ("0.0.0.0/0", "::/0") for c in cidrs):
                proto = p.get("IpProtocol")
                port = "all" if proto == "-1" else f"{proto}/{p.get('FromPort')}"
                found.append(f"{g.get('GroupName', gid)}:{port}")
    return sorted(set(found))

rows, exposed = [], 0
for e in sorted(enis, key=lambda x: x.get("SubnetId", "")):
    att = (e.get("Attachment") or {}).get("InstanceId")
    inst = instances.get(att, {})
    name = tag(inst) or e.get("Description") or att or "-"
    public = (e.get("Association") or {}).get("PublicIp") or inst.get("PublicIpAddress")
    rt_id, igw = igw_route(e.get("SubnetId"))
    gids = [g["GroupId"] for g in e.get("Groups", [])]
    rules = public_rules(gids)

    blockers = []
    if not public: blockers.append("no public address")
    if not igw:    blockers.append(f"no igw route ({rt_id})")
    if not rules:  blockers.append("no public-CIDR ingress")
    verdict = "ISOLATED" if blockers else "EXPOSED"
    exposed += verdict == "EXPOSED"

    rows.append({
        "eni": e["NetworkInterfaceId"], "name": name,
        "subnet": tag(subnets.get(e.get("SubnetId"), {})) or e.get("SubnetId"),
        "private": e.get("PrivateIpAddress"), "public": public or "NONE",
        "verdict": verdict,
        "why": ("internet -> " + public + " via " + igw + ", admitted by " + ", ".join(rules))
               if verdict == "EXPOSED" else "; ".join(blockers),
    })

print(f"== USMS exposure report: {vpc} ==")
print()
print(f"{'ENI':<23} {'ATTACHED TO':<14} {'SUBNET':<24} {'PRIVATE':<12} {'PUBLIC':<10} VERDICT")
for r in rows:
    print(f"{r['eni']:<23} {r['name']:<14} {r['subnet']:<24} {r['private']:<12} {r['public']:<10} {r['verdict']}")
    print(f"{'':<23}   why: {r['why']}")
print()
print(f"ENIs={len(rows)}  EXPOSED={exposed}  ISOLATED={len(rows) - exposed}")
if exposed:
    print("Every EXPOSED line is a front door. Each should be the load balancer, and nothing else.")
PY

exit 0
