#!/usr/bin/env bash
# USMS bucket policy DRAFT. Writes outputs/lab-09-bucket-policy-draft.json. Applies NOTHING.
#
# Nothing is typed in by hand - everything is derived from documents that already exist:
#   bucket name : the s3 Resource ARNs in policies/usms-student-data-*-policy.json
#   principals  : every role whose attached policy document grants s3 actions on that bucket,
#                 split into READ-WRITE (may PutObject) and READ-ONLY (may only GetObject).
#                 The draft never grants a role more than its own identity policy already does.
#   admin       : USMS_ADMIN_USER from configs/lab-01.env, so the policy cannot lock out management
#
# The S3 configuration lab applies it with:
#   aws s3api put-bucket-policy --bucket <name> --policy file://outputs/lab-09-bucket-policy-draft.json
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true

OUT="${1:-outputs/lab-09-bucket-policy-draft.json}"
mkdir -p "$(dirname "$OUT")"

python3 - "$OUT" "${USMS_ACCOUNT_ID:-}" "${USMS_ADMIN_USER:-}" << 'PY'
import glob, json, subprocess, sys

out_path, account, admin = sys.argv[1], sys.argv[2], sys.argv[3]

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {}

def as_list(x):
    return [] if x is None else (x if isinstance(x, list) else [x])

def statements(doc):
    if isinstance(doc, str):
        doc = json.loads(doc)
    return as_list((doc or {}).get("Statement"))

# 1. the bucket name, from the student-data documents in the repository
buckets = set()
for f in sorted(glob.glob("policies/usms-student-data-*-policy.json")):
    for st in statements(json.load(open(f))):
        for res in as_list(st.get("Resource")):
            if res.startswith("arn:aws:s3:::"):
                buckets.add(res[len("arn:aws:s3:::"):].split("/", 1)[0])
if len(buckets) != 1:
    sys.exit(f"expected exactly one bucket in policies/usms-student-data-*-policy.json, found {sorted(buckets)}")
bucket = buckets.pop()
bucket_arn, objects_arn = f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"

# 2. the principals, from every local policy document that grants s3 on that bucket
rw, ro, listers = set(), set(), set()
for pol in aws("iam", "list-policies", "--scope", "Local").get("Policies", []):
    ver = aws("iam", "get-policy-version", "--policy-arn", pol["Arn"],
              "--version-id", pol["DefaultVersionId"]).get("PolicyVersion", {})
    allowed = set()
    for st in statements(ver.get("Document")):
        if st.get("Effect") == "Allow" and any(
                r in (bucket_arn, objects_arn) for r in as_list(st.get("Resource"))):
            allowed |= {a for a in as_list(st.get("Action")) if a.startswith("s3:")}
    if not allowed:
        continue
    roles = aws("iam", "list-entities-for-policy", "--policy-arn", pol["Arn"]).get("PolicyRoles", [])
    arns = {aws("iam", "get-role", "--role-name", r["RoleName"])["Role"]["Arn"] for r in roles}
    (rw if "s3:PutObject" in allowed else ro).update(arns)
    if "s3:ListBucket" in allowed:
        listers.update(arns)
ro -= rw  # a role with both is read-write

if not (rw or ro):
    sys.exit("no role carries a policy that grants s3 on the bucket - nothing to draft")

admin_arn = f"arn:aws:iam::{account}:user/{admin}" if account and admin else None
everyone_allowed = sorted(rw | ro | ({admin_arn} if admin_arn else set()))

policy = {
    "Version": "2012-10-17",
    "Id": f"{bucket}-policy-draft",
    "Statement": [
        {
            "Sid": "DenyAnyRequestNotOverTLS",
            "Effect": "Deny", "Principal": "*", "Action": "s3:*",
            "Resource": [bucket_arn, objects_arn],
            "Condition": {"Bool": {"aws:SecureTransport": "false"}},
        },
        {
            "Sid": "DenyEveryPrincipalNotDerivedFromTheRolePolicies",
            "Effect": "Deny", "Principal": "*", "Action": "s3:*",
            "Resource": [bucket_arn, objects_arn],
            "Condition": {"ArnNotEquals": {"aws:PrincipalArn": everyone_allowed}},
        },
        {
            # only roles whose OWN policy lists the bucket: in the same account a bucket-policy
            # Allow is enough on its own, so granting more here would widen their access
            "Sid": "RolesThatAlreadyListMayListTheBucket",
            "Effect": "Allow", "Principal": {"AWS": sorted(listers)},
            "Action": ["s3:ListBucket", "s3:GetBucketLocation"], "Resource": bucket_arn,
        },
        {
            "Sid": "ReadWriteRolesMayReadAndWriteObjects",
            "Effect": "Allow", "Principal": {"AWS": sorted(rw)},
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": objects_arn,
        },
        {
            "Sid": "ReadOnlyRolesMayOnlyReadObjects",
            "Effect": "Allow", "Principal": {"AWS": sorted(ro)},
            "Action": "s3:GetObject", "Resource": objects_arn,
        },
        {
            "Sid": "NobodyDeletesTheBucketOrItsPolicy",
            "Effect": "Deny", "Principal": "*",
            "Action": ["s3:DeleteBucket", "s3:DeleteBucketPolicy"], "Resource": bucket_arn,
        },
    ],
}
# drop an Allow whose principal list came out empty (e.g. no read-only role yet)
policy["Statement"] = [s for s in policy["Statement"]
                       if s["Effect"] == "Deny" or s["Principal"]["AWS"]]

json.dump(policy, open(out_path, "w"), indent=2)
open(out_path, "a").write("\n")

print(f"bucket      : {bucket}")
print(f"read-write  : {', '.join(sorted(r.split('/')[-1] for r in rw)) or '-'}")
print(f"read-only   : {', '.join(sorted(r.split('/')[-1] for r in ro)) or '-'}")
print(f"management  : {admin_arn or 'NONE - set USMS_ADMIN_USER or the admin is locked out'}")
print(f"statements  : {len(policy['Statement'])}")
print(f"written     : {out_path}  (DRAFT - not applied)")
PY
