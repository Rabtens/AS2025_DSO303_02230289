# DSO303 - Lab 10: Edge Functions with AWS Lambda

---

## Table of Contents

- [DSO303 - Lab 10: Edge Functions with AWS Lambda](#dso303---lab-10-edge-functions-with-aws-lambda)
  - [Table of Contents](#table-of-contents)
  - [1. Lab Overview](#1-lab-overview)
  - [2. Prerequisites](#2-prerequisites)
  - [3. Step-by-Step Implementation](#3-step-by-step-implementation)
    - [Step 1 - Start the environment and prove a new terminal can find it](#step-1---start-the-environment-and-prove-a-new-terminal-can-find-it)
    - [Step 2 - Source every lab environment file that exists, and confirm your identity](#step-2---source-every-lab-environment-file-that-exists-and-confirm-your-identity)
    - [Step 3 - Create this lab's directories](#step-3---create-this-labs-directories)
  - [](#)
    - [Step 4 - Find out what this Floci build actually supports](#step-4---find-out-what-this-floci-build-actually-supports)
    - [Step 5 - Create the origin bucket, and watch a policy stop being hypothetical](#step-5---create-the-origin-bucket-and-watch-a-policy-stop-being-hypothetical)
    - [Step 6 - Read the execution role back, and give it the edge principal](#step-6---read-the-execution-role-back-and-give-it-the-edge-principal)
    - [Step 7 - Write the viewer-request handler](#step-7---write-the-viewer-request-handler)
    - [Step 8 - Package the function and create it](#step-8---package-the-function-and-create-it)
    - [Step 9 - Invoke the function with a real CloudFront event](#step-9---invoke-the-function-with-a-real-cloudfront-event)
    - [Step 10 - Read the function's logs](#step-10---read-the-functions-logs)
    - [Step 11 - Publish a version, and find out why the edge insists on one](#step-11---publish-a-version-and-find-out-why-the-edge-insists-on-one)
    - [Step 12 - Write and deploy the origin-response function](#step-12---write-and-deploy-the-origin-response-function)
    - [Step 13 - Invoke the origin-response function and publish its version](#step-13---invoke-the-origin-response-function-and-publish-its-version)
    - [Step 14 - Check both functions against the Lambda@Edge restrictions](#step-14---check-both-functions-against-the-lambdaedge-restrictions)
    - [Step 15 - Associate both functions with a CloudFront distribution](#step-15---associate-both-functions-with-a-cloudfront-distribution)
    - [Step 16 - Run the edge chain end to end, without CloudFront](#step-16---run-the-edge-chain-end-to-end-without-cloudfront)
    - [Step 17 - Write the regional notifier](#step-17---write-the-regional-notifier)
    - [Step 18 - Create the notifier, publish it, and give it an alias](#step-18---create-the-notifier-publish-it-and-give-it-an-alias)
    - [Step 19 - Let S3 invoke the function, and see the other kind of policy](#step-19---let-s3-invoke-the-function-and-see-the-other-kind-of-policy)
    - [Step 20 - Wire the bucket notification and fire it for real](#step-20---wire-the-bucket-notification-and-fire-it-for-real)
    - [Step 21 - Prove the notifier actually ran](#step-21---prove-the-notifier-actually-ran)
    - [Step 22 - Restart Floci and read everything back](#step-22---restart-floci-and-read-everything-back)
    - [Step 23 - Write configs/lab-10.env](#step-23---write-configslab-10env)
    - [Step 24 - Check what Git sees, and commit](#step-24---check-what-git-sees-and-commit)
  - [4. Verification Script](#4-verification-script)
  - [5. Checkpoints Summary](#5-checkpoints-summary)
  - [6. Troubleshooting Encountered](#6-troubleshooting-encountered)
  - [7. Reflection](#7-reflection)
  - [8. Final Verification Checklist](#8-final-verification-checklist)

---

## 1. Lab Overview

This lab builds a transcript delivery pipeline for the USMS system using AWS Lambda@Edge and CloudFront:

- **`usms-edge-viewer-request`** — Lambda@Edge function that authenticates requests and normalises URIs before the cache is consulted.
- **`usms-edge-origin-response`** — Lambda@Edge function that attaches security headers and a cache policy after the origin replies.
- **`usms-transcript-notifier`** — a regional Lambda function triggered by S3 `ObjectCreated` events.
- **`usms-student-data`** — the S3 origin bucket, created for the first time in this lab (named by IAM policies since Lab 01).
- **`usms-transcript-cdn`** — the CloudFront distribution tying the two edge functions to the origin bucket.

> 📸 **[Screenshot: Architecture diagram from the lab reproduced/hand-drawn, optional]**
>
> &nbsp;
> &nbsp;
> &nbsp;

---

## 2. Prerequisites

- Labs 1 through 9 completed, with `configs/lab-NN.env` present for each.
- Floci running under Docker Compose with `FLOCI_STORAGE_MODE=hybrid`.
- A terminal with `AWS_PROFILE` and `COURSE_ROOT` already set.
- `python3` available on PATH.
- ~1 GB free disk space.

```bash
cd ~/aws-floci-course
./scripts/utilities/floci-storage-check.sh
```

**Expected:** `PASS=16 FAIL=0`

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-35-28.png>)


---

## 3. Step-by-Step Implementation

### Step 1 - Start the environment and prove a new terminal can find it

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh
./scripts/utilities/floci-storage-check.sh
```

**Expected result:**
```
PASS=16  FAIL=0
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-37-15.png>)

---

### Step 2 - Source every lab environment file that exists, and confirm your identity

```bash
source configs/course.env

for f in configs/lab-01.env configs/lab-02.env configs/lab-03.env \
         configs/lab-04.env configs/lab-05.env configs/lab-06.env \
         configs/lab-09.env configs/lab-07.env configs/lab-08.env; do
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    source "$f"
    printf '  sourced  %s\n' "$f"
  else
    printf '  absent   %s\n' "$f"
  fi
done

./scripts/utilities/whoami.sh
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-39-37.png>)

**Verify:**
```bash
printf 'bucket name  : %s\n' "${USMS_BUCKET_NAME:-<UNSET>}"
printf 'lambda role  : %s\n' "${USMS_ROLE_LAMBDA:-<UNSET>}"
printf 'account id   : %s\n' "${USMS_ACCOUNT_ID:-<UNSET>}"
```

**Expected:** All lines read `sourced`, account `000000000000`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-41-19.png>)

---

### Step 3 - Create this lab's directories

```bash
mkdir -p labs/lab-10-lambda-edge/edge-viewer-request \
         labs/lab-10-lambda-edge/edge-origin-response \
         labs/lab-10-lambda-edge/transcript-notifier

ls -d labs/lab-10-lambda-edge/*/
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-42-11.png>)

**Verify:**
```bash
test -d labs/lab-10-lambda-edge/edge-viewer-request && echo "source tree ready"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-42-24.png>)
---

### Step 4 - Find out what this Floci build actually supports

```bash
probe() {   # $1 = label, $2 = command to try
  if eval "$2" >/dev/null 2>&1; then
    printf '  SUPPORTED    %s\n' "$1"
  else
    printf '  UNSUPPORTED  %s\n' "$1"
  fi
}

ROLE_NAME="${USMS_ROLE_LAMBDA:-usms-lambda-exec-role}"
ROLE_NAME="${ROLE_NAME##*/}"

{
  printf 'Floci support probe for Lab 10 - %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  probe "lambda  (list-functions)"      "aws lambda list-functions --max-items 1"
  probe "lambda  (list-layers)"         "aws lambda list-layers"
  probe "s3      (list-buckets)"        "aws s3api list-buckets"
  probe "logs    (describe-log-groups)" "aws logs describe-log-groups --limit 1"
  probe "cloudfront (list-distributions)" "aws cloudfront list-distributions"
  probe "iam     (get-role)"            "aws iam get-role --role-name '$ROLE_NAME'"
} | tee outputs/lab-10-support-probe.txt
```

**Expected:** first four lines `SUPPORTED`; CloudFront line may be either.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-43-45.png>)

**My build result:** CloudFront was **SUPPORTED**. My `list-distributions` probe succeeded, so I’ll follow **Path A** in Step 15.

---

### Step 5 - Create the origin bucket, and watch a policy stop being hypothetical

```bash
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null \
  && echo "bucket already exists - skipping create" \
  || aws s3api create-bucket --bucket "$BUCKET"

aws s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=Project,Value=USMS},{Key=Tier,Value=data},{Key=Lab,Value=06}]'

echo "$BUCKET"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-47-00.png>)

**Verify:**
```bash
aws s3api head-bucket --bucket "$BUCKET" && echo "head-bucket: exit $?"

aws s3api get-bucket-tagging --bucket "$BUCKET" \
  --query 'TagSet[].[Key,Value]' --output table

POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)

aws iam get-policy-version \
  --policy-arn "$POLICY_ARN" \
  --version-id "$(aws iam get-policy --policy-arn "$POLICY_ARN" \
                    --query 'Policy.DefaultVersionId' --output text)" \
  --query 'PolicyVersion.Document.Statement[].Resource' --output json
```

**Expected:** bucket ARNs `arn:aws:s3:::usms-student-data` and `.../*` now resolve to a real bucket.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-47-28.png>)

**Checkpoint 1:**
```
usms-student-data                       ← EXISTS, at last
 ├── tags: Project=USMS, Tier=data, Lab=06
 └── named by:
      ├── USMSStudentDataReadWrite  (Lab 01)  → usms-ec2-app-role, usms-ecs-task-role, usms-eks-node-role
      └── USMSStudentDataReadOnly   (Lab 09) → usms-transcripts-reader-role
```

---

### Step 6 - Read the execution role back, and give it the edge principal

**Part 1 - read the role:**
```bash
ROLE_NAME="${USMS_ROLE_LAMBDA:-usms-lambda-exec-role}"
ROLE_NAME="${ROLE_NAME##*/}"

aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.{Name:RoleName,Created:CreateDate,MaxSession:MaxSessionDuration}' \
  --output table

aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument.Statement[].Principal.Service' --output json

aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
  --query 'AttachedPolicies[].[PolicyName,PolicyArn]' --output table
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-50-24.png>)

**Part 2 - write the two-principal trust policy (⚠️ quoted heredoc `<< 'EOF'`):**
```bash
cat > policies/trust-lambda-edge.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLambdaAndCloudFrontEdgeToAssume",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "lambda.amazonaws.com",
          "edgelambda.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

python3 -m json.tool policies/trust-lambda-edge.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-50-53.png>)

**Part 3 - replace the trust policy:**
```bash
aws iam update-assume-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-document file://policies/trust-lambda-edge.json

EDGE_ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.Arn' --output text)

echo "$EDGE_ROLE_ARN"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-51-15.png>)

**Verify:**
```bash
aws iam get-role --role-name "$ROLE_NAME" \
  --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Principal.Service)' --output text

aws iam get-role --role-name "$ROLE_NAME" \
  --query "Role.AssumeRolePolicyDocument.Statement[0].Principal.Service[?contains(@, 'edgelambda')] | [0]" \
  --output text
```

**Expected:** `2` then `edgelambda.amazonaws.com`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-51-29.png>)

**Checkpoint 2:**
```
usms-lambda-exec-role
 ├── trust: lambda.amazonaws.com
 │          edgelambda.amazonaws.com        ← added in this step
 ├── attached: USMSLambdaBasic  (logs:* on /aws/lambda/*, s3:GetObject)
 └── ARN captured as EDGE_ROLE_ARN
```

---

### Step 7 - Write the viewer-request handler

Heredoc must be **quoted** (`<< 'EOF'`) - the file contains a template literal `${studentId.toLowerCase()}` that must NOT be expanded by bash.

```bash
cat > labs/lab-10-lambda-edge/edge-viewer-request/index.mjs << 'EOF'
// usms-edge-viewer-request
//
// CloudFront trigger point: viewer-request.
// Runs on EVERY request, before the edge cache is consulted. Therefore:
//   - it must be fast (5 second hard timeout, 128 MB hard memory cap)
//   - it can reject a request without the origin ever being contacted
//   - anything it changes about the request becomes part of the cache key
//
// Returns the request object to continue, or a response object to stop.

const AUTH_HEADER = 'x-usms-student';
const PROTECTED_PREFIX = '/transcripts/';

export const handler = async (event) => {
  const request = event.Records[0].cf.request;
  const headers = request.headers;

  // 1. Normalise the URI.
  request.uri = request.uri.toLowerCase();

  // 2. Anything outside /transcripts/ is not this function's business.
  if (!request.uri.startsWith(PROTECTED_PREFIX)) {
    return request;
  }

  // 3. The USMS portal attaches this header to an authenticated request.
  const studentHeader = headers[AUTH_HEADER];
  const studentId = studentHeader && studentHeader[0] && studentHeader[0].value;

  if (!studentId) {
    return {
      status: '403',
      statusDescription: 'Forbidden',
      headers: {
        'content-type': [{ key: 'Content-Type', value: 'application/json' }],
        'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
        'x-usms-edge': [{ key: 'X-USMS-Edge', value: 'viewer-request-deny' }]
      },
      body: JSON.stringify({
        message: 'transcript access requires an authenticated session'
      })
    };
  }

  // 4. Stamp the request so the origin-response function can see that we ran.
  request.headers['x-usms-edge'] = [
    { key: 'X-USMS-Edge', value: `viewer-request-allow;student=${studentId.toLowerCase()}` }
  ];

  return request;
};
EOF

node --check labs/lab-10-lambda-edge/edge-viewer-request/index.mjs 2>/dev/null \
  && echo "syntax OK (node)" \
  || echo "node not installed locally - syntax will be checked by the first invoke"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-53-31.png>)

**Verify:**
```bash
wc -l labs/lab-10-lambda-edge/edge-viewer-request/index.mjs
grep -c 'studentId' labs/lab-10-lambda-edge/edge-viewer-request/index.mjs
grep -n 'toLowerCase()}' labs/lab-10-lambda-edge/edge-viewer-request/index.mjs
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-53-50.png>)

**Expected:** ~50 lines; `studentId` appears 3 times; grep for `${studentId.toLowerCase()}` must print a line with the `$` and `{}` intact.

---

### Step 8 - Package the function and create it

**Part 1 - build the archive:**
```bash
( cd labs/lab-10-lambda-edge/edge-viewer-request \
  && python3 -m zipfile -c "$COURSE_ROOT/outputs/usms-edge-viewer-request.zip" index.mjs )

python3 -m zipfile -l outputs/usms-edge-viewer-request.zip
```

**Expected:** exactly one entry, `index.mjs`, no directory prefix.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-56-41.png>)

**Part 2 - create the function:**
```bash
VIEWER_FN=usms-edge-viewer-request

VIEWER_FN_ARN=$(aws lambda create-function \
  --function-name "$VIEWER_FN" \
  --runtime nodejs20.x \
  --role "$EDGE_ROLE_ARN" \
  --handler index.handler \
  --zip-file fileb://outputs/usms-edge-viewer-request.zip \
  --timeout 5 \
  --memory-size 128 \
  --architectures x86_64 \
  --description "USMS Lambda@Edge viewer-request: auth gate and URI normalisation" \
  --tags Project=USMS,Tier=edge,Lab=06 \
  --query 'FunctionArn' --output text)

echo "$VIEWER_FN_ARN"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-58-16.png>)

**Verify:**
```bash
aws lambda wait function-active-v2 --function-name "$VIEWER_FN" 2>/dev/null \
  || echo "waiter unsupported on this build - checking state directly"

aws lambda get-function-configuration --function-name "$VIEWER_FN" \
  --query '{Name:FunctionName,Runtime:Runtime,Handler:Handler,Mem:MemorySize,Timeout:Timeout,State:State,Version:Version,Role:Role}' \
  --output table
```

**Expected:** `State: Active`, `Runtime: nodejs20.x`, `Handler: index.handler`, `Mem: 128`, `Timeout: 5`, `Version: $LATEST`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 16-58-30.png>)

---

### Step 9 - Invoke the function with a real CloudFront event

**Part 1 - write the event:**
```bash
cat > templates/lab-10-viewer-request-event.json << 'EOF'
{
  "Records": [
    {
      "cf": {
        "config": {
          "distributionDomainName": "d3examplecdn01.cloudfront.net",
          "distributionId": "EDFDVBD6EXAMPLE",
          "eventType": "viewer-request",
          "requestId": "lab06-allow-0001"
        },
        "request": {
          "clientIp": "203.0.113.178",
          "method": "GET",
          "uri": "/transcripts/2026/STU-00417.json",
          "querystring": "",
          "headers": {
            "host": [
              { "key": "Host", "value": "transcripts.usms.example.edu" }
            ],
            "user-agent": [
              { "key": "User-Agent", "value": "curl/8.4.0" }
            ],
            "x-usms-student": [
              { "key": "X-USMS-Student", "value": "STU-00417" }
            ]
          }
        }
      }
    }
  ]
}
EOF

python3 -m json.tool templates/lab-10-viewer-request-event.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-01-12.png>)

**Part 2 - invoke:**
```bash
aws lambda invoke \
  --function-name "$VIEWER_FN" \
  --payload fileb://templates/lab-10-viewer-request-event.json \
  --query '{Status:StatusCode,Error:FunctionError,Executed:ExecutedVersion}' \
  --output table \
  outputs/lab-10-viewer-allow.json

python3 -m json.tool outputs/lab-10-viewer-allow.json
```

**Expected:** `Status: 200`, `Error: None`, `uri` lowercased, `x-usms-edge` header stamped ending in `stu-00417`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-04-39.png>)

**Verify:**
```bash
python3 -c "
import json
r = json.load(open('outputs/lab-10-viewer-allow.json'))
assert r['uri'] == '/transcripts/2026/stu-00417.json', 'uri not normalised'
assert r['headers']['x-usms-edge'][0]['value'].endswith('stu-00417'), 'student id not stamped'
print('viewer-request allow path: correct')
"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-07-44.png>)

**Viewer request deny-path test**

For the deny-path test, I copied the viewer-request event, removed the `x-usms-student` header, and set `requestId` to `lab06-deny-0001`. I used that event to invoke the function and save the response to `outputs/lab-10-viewer-deny.json`.

```bash
python3 - <<'PYTHON'
import json
from pathlib import Path

event = json.loads(Path("templates/lab-10-viewer-request-event.json").read_text())
viewer_event = event["Records"][0]["cf"]
viewer_event["config"]["requestId"] = "lab06-deny-0001"
viewer_event["request"]["headers"].pop("x-usms-student", None)
Path("templates/lab-10-viewer-request-denied.json").write_text(
    json.dumps(event, indent=2) + "\n"
)
PYTHON
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-11-32.png>)

```bash
aws lambda invoke \
  --function-name "$VIEWER_FN" \
  --payload fileb://templates/lab-10-viewer-request-denied.json \
  --query '{Status:StatusCode,Error:FunctionError}' \
  --output table \
  outputs/lab-10-viewer-deny.json &&
python3 -m json.tool outputs/lab-10-viewer-deny.json
```

**Expected:** `status: "403"`, `x-usms-edge: viewer-request-deny`, no `uri` key.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-12-09.png>)

**Checkpoint 3:**
```
usms-student-data                              (Step 5)
usms-lambda-exec-role  + edgelambda principal  (Step 6)
usms-edge-viewer-request
 ├── nodejs20.x, index.handler, 128 MB, 5 s
 ├── $LATEST
 ├── invoked with allow event  → request returned, uri normalised, header stamped
 └── invoked with deny event   → 403 response returned, origin never reached
```

---

### Step 10 - Read the function's logs

```bash
aws lambda invoke \
  --function-name "$VIEWER_FN" \
  --payload fileb://templates/lab-10-viewer-request-event.json \
  --log-type Tail \
  --query 'LogResult' --output text \
  outputs/lab-10-viewer-allow.json \
  | openssl base64 -d -A
```

**Expected:** `START` / `END` / `REPORT` lines with matching RequestId.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-13-41.png>)

**Verify (durable route):**
```bash
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/$VIEWER_FN" \
  --query 'logGroups[].[logGroupName,storedBytes]' --output table
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-13-54.png>)

> **Note:** If `LogResult` is empty on my build, I recorded this in `outputs/lab-10-support-probe.txt` as a Floci limitation.

---

### Step 11 - Publish a version, and find out why the edge insists on one

```bash
VIEWER_VERSION=$(aws lambda publish-version \
  --function-name "$VIEWER_FN" \
  --description "Lab 10 - initial edge release" \
  --query 'Version' --output text)

VIEWER_VERSION_ARN="${VIEWER_FN_ARN}:${VIEWER_VERSION}"

printf 'version      : %s\n' "$VIEWER_VERSION"
printf 'qualified ARN: %s\n' "$VIEWER_VERSION_ARN"
```

**Expected:**
```
version      : 1
qualified ARN: arn:aws:lambda:us-east-1:000000000000:function:usms-edge-viewer-request:1
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-15-00.png>)
**Verify:**
```bash
aws lambda list-versions-by-function --function-name "$VIEWER_FN" \
  --query 'Versions[].[Version,Description,CodeSize,LastModified]' --output table

printf '%s' "$VIEWER_VERSION_ARN" | grep -qE ':[0-9]+$' \
  && echo "ARN is version-qualified - the edge would accept this" \
  || echo "ARN is NOT version-qualified - the edge would refuse this"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-15-33.png>)

**Checkpoint 4:**
```
usms-edge-viewer-request
 ├── $LATEST ................. mutable, what you edit
 └── 1 ....................... immutable, what the edge can use
      └── arn:...:function:usms-edge-viewer-request:1     ← VIEWER_VERSION_ARN
```

---

### Step 12 - Write and deploy the origin-response function

Heredoc must be **quoted** (`<< 'EOF'`) - contains a template literal.

**Part 1 - the handler:**
```bash
cat > labs/lab-10-lambda-edge/edge-origin-response/index.mjs << 'EOF'
// usms-edge-origin-response
//
// CloudFront trigger point: origin-response.
// Runs after the origin replies and BEFORE the object is cached.

const SECURITY_HEADERS = {
  'strict-transport-security': { key: 'Strict-Transport-Security', value: 'max-age=31536000; includeSubDomains' },
  'x-content-type-options':    { key: 'X-Content-Type-Options',    value: 'nosniff' },
  'x-frame-options':           { key: 'X-Frame-Options',           value: 'DENY' },
  'referrer-policy':           { key: 'Referrer-Policy',           value: 'strict-origin-when-cross-origin' }
};

const TRANSCRIPT_CACHE_CONTROL = 'public, max-age=300, s-maxage=3600';

export const handler = async (event) => {
  const cf = event.Records[0].cf;
  const request = cf.request;
  const response = cf.response;

  // 1. Attach the security headers.
  for (const name of Object.keys(SECURITY_HEADERS)) {
    response.headers[name] = [SECURITY_HEADERS[name]];
  }

  // 2. Transcripts get a deliberate cache policy.
  if (request.uri.startsWith('/transcripts/')) {
    response.headers['cache-control'] = [
      { key: 'Cache-Control', value: TRANSCRIPT_CACHE_CONTROL }
    ];
  }

  // 3. Record whether the viewer-request function ran.
  const upstream = request.headers['x-usms-edge'];
  response.headers['x-usms-edge-chain'] = [
    {
      key: 'X-USMS-Edge-Chain',
      value: upstream && upstream[0] ? `${upstream[0].value};origin-response` : 'origin-response-only'
    }
  ];

  return response;
};
EOF

node --check labs/lab-10-lambda-edge/edge-origin-response/index.mjs 2>/dev/null \
  && echo "syntax OK (node)" \
  || echo "node not installed locally - syntax will be checked by the first invoke"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-17-17.png>)

**Part 2 - package and create:**
```bash
ORIGIN_FN=usms-edge-origin-response

( cd labs/lab-10-lambda-edge/edge-origin-response \
  && python3 -m zipfile -c "$COURSE_ROOT/outputs/usms-edge-origin-response.zip" index.mjs )

ORIGIN_FN_ARN=$(aws lambda create-function \
  --function-name "$ORIGIN_FN" \
  --runtime nodejs20.x \
  --role "$EDGE_ROLE_ARN" \
  --handler index.handler \
  --zip-file fileb://outputs/usms-edge-origin-response.zip \
  --timeout 5 \
  --memory-size 128 \
  --architectures x86_64 \
  --description "USMS Lambda@Edge origin-response: security headers and cache policy" \
  --tags Project=USMS,Tier=edge,Lab=06 \
  --query 'FunctionArn' --output text)

echo "$ORIGIN_FN_ARN"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-17-40.png>)

**Verify:**
```bash
aws lambda get-function-configuration --function-name "$ORIGIN_FN" \
  --query '{Name:FunctionName,Runtime:Runtime,Handler:Handler,Mem:MemorySize,Timeout:Timeout,State:State}' \
  --output table
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-17-53.png>)

---

### Step 13 - Invoke the origin-response function and publish its version

**Part 1 - origin-response event:**
```bash
cat > templates/lab-10-origin-response-event.json << 'EOF'
{
  "Records": [
    {
      "cf": {
        "config": {
          "distributionDomainName": "d3examplecdn01.cloudfront.net",
          "distributionId": "EDFDVBD6EXAMPLE",
          "eventType": "origin-response",
          "requestId": "lab06-origin-0001"
        },
        "request": {
          "clientIp": "203.0.113.178",
          "method": "GET",
          "uri": "/transcripts/2026/stu-00417.json",
          "querystring": "",
          "headers": {
            "host": [
              { "key": "Host", "value": "usms-student-data.s3.us-east-1.amazonaws.com" }
            ],
            "x-usms-edge": [
              { "key": "X-USMS-Edge", "value": "viewer-request-allow;student=stu-00417" }
            ]
          }
        },
        "response": {
          "status": "200",
          "statusDescription": "OK",
          "headers": {
            "content-type": [
              { "key": "Content-Type", "value": "application/json" }
            ],
            "etag": [
              { "key": "ETag", "value": "\"9f86d081884c7d659a2feaa0c55ad015\"" }
            ],
            "server": [
              { "key": "Server", "value": "AmazonS3" }
            ]
          }
        }
      }
    }
  ]
}
EOF

python3 -m json.tool templates/lab-10-origin-response-event.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-19-40.png>)

**Part 2 - invoke and publish:**
```bash
aws lambda invoke \
  --function-name "$ORIGIN_FN" \
  --payload fileb://templates/lab-10-origin-response-event.json \
  --query '{Status:StatusCode,Error:FunctionError}' \
  --output table \
  outputs/lab-10-origin-response.json

python3 -m json.tool outputs/lab-10-origin-response.json

ORIGIN_VERSION=$(aws lambda publish-version \
  --function-name "$ORIGIN_FN" \
  --description "Lab 10 - initial edge release" \
  --query 'Version' --output text)

ORIGIN_VERSION_ARN="${ORIGIN_FN_ARN}:${ORIGIN_VERSION}"
printf 'qualified ARN: %s\n' "$ORIGIN_VERSION_ARN"
```

**Expected:** response includes 4 security headers, `cache-control`, and `x-usms-edge-chain` ending `;origin-response`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-20-17.png>)

**Verify:**
```bash
python3 -c "
import json
r = json.load(open('outputs/lab-10-origin-response.json'))
h = r['headers']
for required in ['strict-transport-security','x-content-type-options','x-frame-options','referrer-policy']:
    assert required in h, 'missing ' + required
assert h['cache-control'][0]['value'].startswith('public'), 'cache-control not set'
assert h['x-usms-edge-chain'][0]['value'].endswith(';origin-response'), 'chain header wrong'
print('origin-response: 4 security headers + cache-control + chain marker')
"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-20-42.png>)

---

### Step 14 - Check both functions against the Lambda@Edge restrictions

**Part 1 - make the mistake (add env vars):**
```bash
aws lambda update-function-configuration \
  --function-name "$VIEWER_FN" \
  --environment 'Variables={USMS_STAGE=lab06,USMS_AUTH_HEADER=x-usms-student}' \
  --query '{Name:FunctionName,Env:Environment.Variables}' --output json
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-22-21.png>)

**Part 2 - undo it and check both functions:**
```bash
aws lambda update-function-configuration \
  --function-name "$VIEWER_FN" \
  --environment 'Variables={}' \
  --query 'Environment' --output json

edge_eligibility() {
  local fn="$1" cap="$2" cfg envcount mem timeout runtime vpc versions
  cfg=$(aws lambda get-function-configuration --function-name "$fn" --output json)
  envcount=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Environment",{}).get("Variables",{}) or {}))')
  mem=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["MemorySize"])')
  timeout=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Timeout"])')
  runtime=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Runtime"])')
  vpc=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("VpcConfig",{}).get("SubnetIds",[]) or []))')
  versions=$(aws lambda list-versions-by-function --function-name "$fn" \
               --query "length(Versions[?Version!='\$LATEST'])" --output text)

  printf '\n%s\n' "$fn"
  [ "$envcount" -eq 0 ]            && printf '  ok   no environment variables\n'      || printf '  NO   %s environment variables set\n' "$envcount"
  [ "$mem" -le "$cap" ]            && printf '  ok   memory %s MB (cap %s)\n' "$mem" "$cap" || printf '  NO   memory %s MB exceeds cap %s\n' "$mem" "$cap"
  [ "$timeout" -le 5 ]             && printf '  ok   timeout %s s\n' "$timeout"        || printf '  NO   timeout %s s exceeds viewer cap 5\n' "$timeout"
  case "$runtime" in nodejs*|python*) printf '  ok   runtime %s\n' "$runtime" ;; *) printf '  NO   runtime %s not supported at the edge\n' "$runtime" ;; esac
  [ "$vpc" -eq 0 ]                 && printf '  ok   no VPC configuration\n'           || printf '  NO   attached to %s subnets\n' "$vpc"
  [ "$versions" -ge 1 ]            && printf '  ok   %s published version(s)\n' "$versions" || printf '  NO   no published version to associate\n'
}

{
  echo "Lambda@Edge eligibility - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  edge_eligibility usms-edge-viewer-request 128
  edge_eligibility usms-edge-origin-response 128
} | tee outputs/lab-10-function-inventory.json
```

**Expected:** all `ok` lines for both functions.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-23-01.png>)

**Verify:**
```bash
grep -c '  NO   ' outputs/lab-10-function-inventory.json || echo "0 failures - both functions are edge-eligible"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-23-30.png>)

**Checkpoint 5:**
```
usms-edge-viewer-request     nodejs20.x  128 MB  5 s   version 1   edge-eligible
usms-edge-origin-response    nodejs20.x  128 MB  5 s   version 1   edge-eligible
 └── environment variables set on $LATEST and removed again - deliberately
```

---

### Step 15 - Associate both functions with a CloudFront distribution

Heredoc must be **unquoted** (`<< EOF`) - `${VIEWER_VERSION_ARN}`, `${ORIGIN_VERSION_ARN}` and `$(date +%s)` must be expanded.

**Part 1 - write the configuration:**
```bash
cat > templates/lab-10-distribution-config.json << EOF
{
  "CallerReference": "usms-transcript-cdn-$(date +%s)",
  "Comment": "usms-transcript-cdn - USMS transcript delivery with edge functions",
  "Enabled": true,
  "PriceClass": "PriceClass_All",
  "DefaultRootObject": "",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "usms-student-data-origin",
        "DomainName": "${USMS_BUCKET_NAME:-usms-student-data}.s3.us-east-1.amazonaws.com",
        "OriginPath": "",
        "CustomHeaders": { "Quantity": 0 },
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "usms-student-data-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "Compress": true,
    "MinTTL": 0,
    "DefaultTTL": 300,
    "MaxTTL": 3600,
    "SmoothStreaming": false,
    "FieldLevelEncryptionId": "",
    "TrustedSigners": { "Enabled": false, "Quantity": 0 },
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": { "Forward": "none" },
      "Headers": { "Quantity": 1, "Items": ["x-usms-student"] },
      "QueryStringCacheKeys": { "Quantity": 0 }
    },
    "LambdaFunctionAssociations": {
      "Quantity": 2,
      "Items": [
        {
          "EventType": "viewer-request",
          "LambdaFunctionARN": "${VIEWER_VERSION_ARN}",
          "IncludeBody": false
        },
        {
          "EventType": "origin-response",
          "LambdaFunctionARN": "${ORIGIN_VERSION_ARN}"
        }
      ]
    }
  }
}
EOF

python3 -m json.tool templates/lab-10-distribution-config.json > /dev/null && echo "valid JSON"
grep -n 'function:usms-edge' templates/lab-10-distribution-config.json
```

**Expected:** both ARN lines end with `:1`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-25-34.png>)

**Part 2 - PATH A (if CloudFront SUPPORTED):**
```bash
aws cloudfront create-distribution \
  --distribution-config file://templates/lab-10-distribution-config.json \
  > outputs/lab-10-distribution.json

DIST_ID=$(python3 -c "import json;print(json.load(open('outputs/lab-10-distribution.json'))['Distribution']['Id'])")
DIST_DOMAIN=$(python3 -c "import json;print(json.load(open('outputs/lab-10-distribution.json'))['Distribution']['DomainName'])")

printf 'distribution : %s\n' "$DIST_ID"
printf 'domain       : %s\n' "$DIST_DOMAIN"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-26-03.png>)

**Verify - Path A:**
```bash
aws cloudfront get-distribution --id "$DIST_ID" \
  --query 'Distribution.DistributionConfig.DefaultCacheBehavior.LambdaFunctionAssociations.Items[].[EventType,LambdaFunctionARN]' \
  --output table

aws cloudfront get-distribution --id "$DIST_ID" \
  --query 'Distribution.{Id:Id,Status:Status,Domain:DomainName,Enabled:DistributionConfig.Enabled}' \
  --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-26-26.png>)

**Part 2 - PATH B (if CloudFront UNSUPPORTED):**
```bash
python3 - << 'PY' | tee outputs/lab-10-distribution.json
import json, sys

cfg = json.load(open('templates/lab-10-distribution-config.json'))
errors, checks = [], []

def check(label, ok):
    checks.append(('ok  ' if ok else 'FAIL') + '  ' + label)
    if not ok:
        errors.append(label)

beh = cfg['DefaultCacheBehavior']
assoc = beh['LambdaFunctionAssociations']
items = assoc['Items']
origin = cfg['Origins']['Items'][0]

check('one origin declared', cfg['Origins']['Quantity'] == 1)
check('origin id matches the behaviour target', origin['Id'] == beh['TargetOriginId'])
check('origin is the USMS bucket', origin['DomainName'].startswith('usms-student-data'))
check('association quantity matches item count', assoc['Quantity'] == len(items))
check('two trigger points associated', len(items) == 2)
check('trigger points are viewer-request and origin-response',
      sorted(i['EventType'] for i in items) == ['origin-response', 'viewer-request'])
check('every ARN is version-qualified',
      all(i['LambdaFunctionARN'].rsplit(':', 1)[-1].isdigit() for i in items))
check('IncludeBody only on a request trigger',
      all('IncludeBody' not in i for i in items if i['EventType'].endswith('response')))
check('viewer protocol policy is not allow-all',
      beh['ViewerProtocolPolicy'] != 'allow-all')
check('cache key forwards no cookies', beh['ForwardedValues']['Cookies']['Forward'] == 'none')
check('cache key forwards exactly one header',
      beh['ForwardedValues']['Headers']['Quantity'] == 1)

print(json.dumps({'mode': 'PATH B - structural validation only',
                  'checks': checks,
                  'errors': errors}, indent=2))
sys.exit(1 if errors else 0)
PY
```

**Expected (Path B):** eleven `ok` entries, empty `errors` list.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-27-02.png>)

**Checkpoint 6:**
```
usms-transcript-cdn  (record, or validated configuration)
 ├── origin: usms-student-data.s3.us-east-1.amazonaws.com
 ├── cache key: uri + header x-usms-student, no cookies, no query string
 └── LambdaFunctionAssociations
      ├── viewer-request   → usms-edge-viewer-request:1
      └── origin-response  → usms-edge-origin-response:1
```

---

### Step 16 - Run the edge chain end to end, without CloudFront

**Part 1 - write the script (outer heredoc quoted `<< 'EOF'`, inner Python heredocs quoted `<< 'PY'`):**
```bash
cat > scripts/utilities/usms-edge-simulate.sh << 'EOF'
#!/usr/bin/env bash
# Run the USMS edge chain the way CloudFront would, using direct Lambda
# invocations in place of a request path Floci does not have.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true

VIEWER_FN="${USMS_EDGE_VIEWER_FN:-usms-edge-viewer-request}"
ORIGIN_FN="${USMS_EDGE_ORIGIN_FN:-usms-edge-origin-response}"
EVENT="${1:-templates/lab-10-viewer-request-event.json}"
TRACE="outputs/lab-10-edge-trace.json"

[ -f "$EVENT" ] || { echo "no such event file: $EVENT" >&2; exit 1; }

echo "== 1. viewer-request =="
aws lambda invoke --function-name "$VIEWER_FN" \
  --payload "fileb://$EVENT" \
  --query 'FunctionError' --output text \
  outputs/.edge-step1.json >/dev/null || { echo "invoke failed" >&2; exit 1; }

DECISION=$(python3 -c "
import json
d = json.load(open('outputs/.edge-step1.json'))
print('deny' if 'status' in d else 'allow')
")

if [ "$DECISION" = "deny" ]; then
  echo "   decision: DENY - the origin is never contacted"
  python3 - << 'PY' | tee "$TRACE"
import json
r = json.load(open('outputs/.edge-step1.json'))
print(json.dumps({
    'chain': ['viewer-request'],
    'decision': 'deny',
    'status': r.get('status'),
    'headers': {k: v[0]['value'] for k, v in r.get('headers', {}).items()},
}, indent=2))
PY
  exit 0
fi

echo "   decision: ALLOW - uri is now $(python3 -c "import json;print(json.load(open('outputs/.edge-step1.json'))['uri'])")"

echo "== 2. origin (simulated: what the bucket would have returned) =="
python3 - << 'PY'
import json
req = json.load(open('outputs/.edge-step1.json'))
event = {'Records': [{'cf': {
    'config': {'distributionId': 'SIMULATED', 'eventType': 'origin-response',
               'requestId': 'edge-simulate'},
    'request': req,
    'response': {
        'status': '200',
        'statusDescription': 'OK',
        'headers': {
            'content-type': [{'key': 'Content-Type', 'value': 'application/json'}],
            'server':       [{'key': 'Server',       'value': 'AmazonS3'}],
        },
    },
}}]}
json.dump(event, open('outputs/.edge-step2-event.json', 'w'))
print('   built an origin-response event carrying the modified request')
PY

echo "== 3. origin-response =="
aws lambda invoke --function-name "$ORIGIN_FN" \
  --payload fileb://outputs/.edge-step2-event.json \
  --query 'FunctionError' --output text \
  outputs/.edge-step3.json >/dev/null || { echo "invoke failed" >&2; exit 1; }

python3 - << 'PY' | tee "$TRACE"
import json
req = json.load(open('outputs/.edge-step1.json'))
res = json.load(open('outputs/.edge-step3.json'))
print(json.dumps({
    'chain': ['viewer-request', 'origin', 'origin-response'],
    'decision': 'allow',
    'request_uri_after_normalisation': req['uri'],
    'status': res['status'],
    'headers': {k: v[0]['value'] for k, v in res['headers'].items()},
}, indent=2))
PY

rm -f outputs/.edge-step1.json outputs/.edge-step2-event.json outputs/.edge-step3.json
echo
echo "trace written to $TRACE"
EOF

chmod +x scripts/utilities/usms-edge-simulate.sh
bash -n scripts/utilities/usms-edge-simulate.sh && echo "syntax OK"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-29-23.png>)

**Part 2 - run it both ways:**
```bash
./scripts/utilities/usms-edge-simulate.sh

echo "-----------------------------------------------------------"

./scripts/utilities/usms-edge-simulate.sh templates/lab-10-viewer-request-denied.json
```

**Expected:** allow chain of 3 stages with `x-usms-edge-chain` header proving composition; deny chain of 1 stage, status 403.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-29-55.png>)

**Verify:**
```bash
python3 -c "
import json
t = json.load(open('outputs/lab-10-edge-trace.json'))
print('chain    :', ' -> '.join(t['chain']))
print('decision :', t['decision'])
"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-30-40.png>)

**Restore allow trace (Exercise 5 needs it):**
```bash
./scripts/utilities/usms-edge-simulate.sh > /dev/null && echo "allow trace restored"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-30-54.png>)

**Checkpoint 7:**
```
scripts/utilities/usms-edge-simulate.sh
 ├── allow event → viewer-request → origin → origin-response → 200 + 5 added headers
 │                                              x-usms-edge-chain proves composition
 └── deny  event → viewer-request → 403, origin never contacted
outputs/lab-10-edge-trace.json                 ← Exercise 5 uploads this
```

---

### Step 17 - Write the regional notifier

Heredoc quoted (`<< 'EOF'`) even though the file has no `$` requiring protection — this is the safe default.

```bash
cat > labs/lab-10-lambda-edge/transcript-notifier/notifier.py << 'EOF'
"""usms-transcript-notifier

Regional Lambda, triggered by S3 ObjectCreated on usms-student-data.
"""

import json
import os
import urllib.parse

BUCKET_HINT = os.environ.get("USMS_BUCKET", "usms-student-data")
CHANNEL = os.environ.get("USMS_NOTIFY_CHANNEL", "stdout")


def describe(record):
    s3 = record.get("s3", {})
    raw_key = s3.get("object", {}).get("key", "")
    return {
        "event": record.get("eventName"),
        "bucket": s3.get("bucket", {}).get("name"),
        "key": urllib.parse.unquote_plus(raw_key),
        "size": s3.get("object", {}).get("size"),
    }


def notify(payload):
    print("USMS_NOTIFY " + json.dumps(payload, sort_keys=True))


def handler(event, context):
    records = event.get("Records", [])
    print("usms-transcript-notifier: %d record(s), channel=%s, bucket_hint=%s"
          % (len(records), CHANNEL, BUCKET_HINT))

    processed = []
    for record in records:
        info = describe(record)

        if not info["key"].startswith("transcripts/"):
            print("skipping non-transcript object: %s" % info["key"])
            continue

        info["readable"] = False
        try:
            import boto3
            boto3.client("s3").head_object(Bucket=info["bucket"], Key=info["key"])
            info["readable"] = True
        except Exception as exc:                      # noqa: BLE001
            info["read_error"] = type(exc).__name__

        notify(info)
        processed.append(info["key"])

    return {"processed": len(processed), "keys": processed}
EOF

python3 -m py_compile labs/lab-10-lambda-edge/transcript-notifier/notifier.py \
  && echo "syntax OK (python3)"
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-32-47.png>)

**Verify:**
```bash
grep -n 'os.environ.get' labs/lab-10-lambda-edge/transcript-notifier/notifier.py
```

**Expected:** two lines showing `USMS_BUCKET` and `USMS_NOTIFY_CHANNEL`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-33-07.png>)

---

### Step 18 - Create the notifier, publish it, and give it an alias

**Part 1 - create:**
```bash
NOTIFIER_FN=usms-transcript-notifier
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

( cd labs/lab-10-lambda-edge/transcript-notifier \
  && python3 -m zipfile -c "$COURSE_ROOT/outputs/usms-transcript-notifier.zip" notifier.py )

NOTIFIER_FN_ARN=$(aws lambda create-function \
  --function-name "$NOTIFIER_FN" \
  --runtime python3.12 \
  --role "$EDGE_ROLE_ARN" \
  --handler notifier.handler \
  --zip-file fileb://outputs/usms-transcript-notifier.zip \
  --timeout 30 \
  --memory-size 256 \
  --architectures x86_64 \
  --environment "Variables={USMS_BUCKET=$BUCKET,USMS_NOTIFY_CHANNEL=stdout}" \
  --description "USMS regional function: reacts to transcript uploads" \
  --tags Project=USMS,Tier=app,Lab=06 \
  --query 'FunctionArn' --output text)

echo "$NOTIFIER_FN_ARN"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-34-14.png>)

> **If the runtime is rejected:**
> ```bash
> aws lambda list-functions --query 'Functions[].Runtime' --output text
> ```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-34-32.png>)

> Substitute the nearest accepted Python runtime (e.g. `python3.11`) and record it in `outputs/lab-10-support-probe.txt`.

**Part 2 - publish and alias:**
```bash
aws lambda wait function-active-v2 --function-name "$NOTIFIER_FN" 2>/dev/null \
  || echo "waiter unsupported - continuing"

NOTIFIER_VERSION=$(aws lambda publish-version \
  --function-name "$NOTIFIER_FN" \
  --description "Lab 10 - initial release" \
  --query 'Version' --output text)

NOTIFIER_ALIAS_ARN=$(aws lambda create-alias \
  --function-name "$NOTIFIER_FN" \
  --name live \
  --function-version "$NOTIFIER_VERSION" \
  --description "The version S3 notifications invoke" \
  --query 'AliasArn' --output text)

printf 'version   : %s\n' "$NOTIFIER_VERSION"
printf 'alias ARN : %s\n' "$NOTIFIER_ALIAS_ARN"
```

**Expected:**
```
version   : 1
alias ARN : arn:aws:lambda:us-east-1:000000000000:function:usms-transcript-notifier:live
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-34-53.png>)

**Verify:**
```bash
aws lambda list-aliases --function-name "$NOTIFIER_FN" \
  --query 'Aliases[].[Name,FunctionVersion,Description]' --output table

aws lambda get-function-configuration --function-name "$NOTIFIER_FN" --qualifier live \
  --query '{Version:Version,Runtime:Runtime,Handler:Handler,Env:Environment.Variables}' \
  --output json
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-35-08.png>)

**Notifier alias rollout and rollback**
```bash
# Publish version 2
NOTIFIER_VERSION_2=$(aws lambda publish-version \
  --function-name "$NOTIFIER_FN" \
  --description "Lab 10 - version 2 (no code change)" \
  --query 'Version' --output text)
echo "new version: $NOTIFIER_VERSION_2"

# Repoint alias to version 2
aws lambda update-alias --function-name "$NOTIFIER_FN" --name live --function-version "$NOTIFIER_VERSION_2"
aws lambda get-alias --function-name "$NOTIFIER_FN" --name live --query 'FunctionVersion' --output text

# Roll back to version 1
aws lambda update-alias --function-name "$NOTIFIER_FN" --name live --function-version 1
aws lambda get-alias --function-name "$NOTIFIER_FN" --name live --query 'FunctionVersion' --output text

# Confirm both versions still exist
aws lambda list-versions-by-function --function-name "$NOTIFIER_FN" --query 'Versions[].Version' --output text
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-35-41.png>)

**Checkpoint 8:**
```
usms-transcript-notifier
 ├── python3.12, notifier.handler, 256 MB, 30 s
 ├── environment: USMS_BUCKET, USMS_NOTIFY_CHANNEL     ← legal here, illegal at the edge
 ├── $LATEST
 ├── 1
 └── live ──→ 1                                        ← the pointer S3 will target
```

---

### Step 19 - Let S3 invoke the function, and see the other kind of policy

```bash
aws lambda add-permission \
  --function-name "$NOTIFIER_FN" \
  --qualifier live \
  --statement-id usms-s3-transcript-upload \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$BUCKET" \
  --source-account "${USMS_ACCOUNT_ID:-000000000000}" \
  --query 'Statement' --output text | python3 -m json.tool
```

**Expected:** statement with `Principal.Service: s3.amazonaws.com`, `Condition.ArnLike.AWS:SourceArn` = your bucket ARN.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-37-51.png>)
**Verify:**
```bash
aws lambda get-policy --function-name "$NOTIFIER_FN" --qualifier live \
  --query 'Policy' --output text | python3 -m json.tool

aws lambda get-policy --function-name "$NOTIFIER_FN" --qualifier live \
  --query 'Policy' --output text \
  | python3 -c "
import json,sys
p = json.load(sys.stdin)
st = p['Statement'][0]
assert st['Principal']['Service'] == 's3.amazonaws.com'
cond = json.dumps(st.get('Condition', {}))
assert 'usms-student-data' in cond, 'source ARN condition missing - the deputy is still confused'
print('resource policy: scoped to one bucket in one account')
"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-38-20.png>)

---

### Step 20 - Wire the bucket notification and fire it for real

Heredoc unquoted (`<< EOF`) - `${NOTIFIER_ALIAS_ARN}` must expand.

**Part 1 - the configuration:**
```bash
cat > templates/lab-10-bucket-notification.json << EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "usms-transcript-upload",
      "LambdaFunctionArn": "${NOTIFIER_ALIAS_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            { "Name": "prefix", "Value": "transcripts/" },
            { "Name": "suffix", "Value": ".json" }
          ]
        }
      }
    }
  ]
}
EOF

python3 -m json.tool templates/lab-10-bucket-notification.json > /dev/null && echo "valid JSON"

aws s3api put-bucket-notification-configuration \
  --bucket "$BUCKET" \
  --notification-configuration file://templates/lab-10-bucket-notification.json
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-40-03.png>)

**Part 2 - fire it:**
```bash
SOURCE=""
for candidate in outputs/lab-08-scaling-evidence.json \
                 outputs/lab-06-scaling-history.json \
                 outputs/lab-10-edge-trace.json; do
  [ -f "$candidate" ] && { SOURCE="$candidate"; break; }
done

if [ -z "$SOURCE" ]; then
  SOURCE=outputs/lab-10-first-object.json
  python3 -c "
import json, datetime
json.dump({'note': 'placeholder first object for usms-student-data',
           'created': datetime.datetime.utcnow().isoformat() + 'Z'},
          open('$SOURCE','w'), indent=2)
"
fi

printf 'uploading %s\n' "$SOURCE"

aws s3api put-object \
  --bucket "$BUCKET" \
  --key "transcripts/evidence/$(basename "$SOURCE")" \
  --body "$SOURCE" \
  --content-type application/json \
  --query '{ETag:ETag}' --output text
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-40-24.png>)

**Verify:**
```bash
aws s3api get-bucket-notification-configuration --bucket "$BUCKET" \
  --query 'LambdaFunctionConfigurations[].[Id,LambdaFunctionArn,Events[0]]' --output table

aws s3api list-objects-v2 --bucket "$BUCKET" --prefix transcripts/ \
  --query 'Contents[].[Key,Size]' --output table
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-40-39.png>)

**Checkpoint 9:**
```
usms-student-data
 ├── transcripts/evidence/lab-08-scaling-evidence.json      ← first object in this course
 └── notification: s3:ObjectCreated:*  prefix=transcripts/  suffix=.json
      └──→ usms-transcript-notifier:live
            ├── resource policy: s3.amazonaws.com, scoped to this bucket + account
            └── execution role: usms-lambda-exec-role (logs + s3:GetObject)
```

---

### Step 21 - Prove the notifier actually ran

**Part 1 - look for the log:**
```bash
LOG_GROUP="/aws/lambda/$NOTIFIER_FN"

aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query 'logGroups[].[logGroupName,storedBytes]' --output table

aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "USMS_NOTIFY" \
  --query 'events[].message' --output text 2>/dev/null \
  | tee outputs/lab-10-notifier-logs.txt
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-45-14.png>)

**Part 2 - fallback: invoke with a synthetic S3 event (unquoted heredoc):**
```bash
cat > templates/lab-10-s3-event.json << EOF
{
  "Records": [
    {
      "eventVersion": "2.1",
      "eventSource": "aws:s3",
      "awsRegion": "us-east-1",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "s3SchemaVersion": "1.0",
        "bucket": {
          "name": "${BUCKET}",
          "arn": "arn:aws:s3:::${BUCKET}"
        },
        "object": {
          "key": "transcripts/evidence/synthetic-probe.json",
          "size": 1024,
          "eTag": "0123456789abcdef0123456789abcdef"
        }
      }
    }
  ]
}
EOF

python3 -m json.tool templates/lab-10-s3-event.json > /dev/null && echo "valid JSON"

aws lambda invoke \
  --function-name "$NOTIFIER_FN" \
  --qualifier live \
  --payload fileb://templates/lab-10-s3-event.json \
  --log-type Tail \
  --query 'LogResult' --output text \
  outputs/lab-10-notifier-direct.json \
  | openssl base64 -d -A | tee -a outputs/lab-10-notifier-logs.txt

python3 -m json.tool outputs/lab-10-notifier-direct.json
```

**Expected:** `"processed": 1`, a `USMS_NOTIFY` line, `Version: 1` in the START line.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-46-13.png>)

**S3 notification filter test**
```bash
# Wrong prefix
echo '{"note":"ignore me - wrong prefix"}' > /tmp/ignore-me-prefix.json
aws s3api put-object --bucket "$BUCKET" --key "notes/ignore-me.json" \
  --body /tmp/ignore-me-prefix.json --content-type application/json

# Wrong suffix
echo '{"note":"ignore me - wrong suffix"}' > /tmp/ignore-me-suffix.txt
aws s3api put-object --bucket "$BUCKET" --key "transcripts/evidence/ignore-me.txt" \
  --body /tmp/ignore-me-suffix.txt --content-type text/plain

# Check logs again
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "USMS_NOTIFY" \
  --query 'events[].message' --output text

# Confirm all three objects exist
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output table
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-46-46.png>)

---

### Step 22 - Restart Floci and read everything back

**Part 1 - record state before:**
```bash
inventory() {
  aws lambda list-functions \
    --query 'sort_by(Functions[?starts_with(FunctionName, `usms-`)], &FunctionName)[].[FunctionName,Runtime,MemorySize]' \
    --output text
  aws lambda list-versions-by-function --function-name usms-edge-viewer-request \
    --query "sort_by(Versions[?Version!='\$LATEST'], &Version)[].Version" --output text
  aws lambda list-aliases --function-name usms-transcript-notifier \
    --query 'Aliases[].[Name,FunctionVersion]' --output text
  aws s3api list-objects-v2 --bucket "${USMS_BUCKET_NAME:-usms-student-data}" \
    --query 'sort_by(Contents, &Key)[].Key' --output text
  aws s3api get-bucket-notification-configuration --bucket "${USMS_BUCKET_NAME:-usms-student-data}" \
    --query 'LambdaFunctionConfigurations[].Id' --output text
}

inventory | tee outputs/lab-10-pre-restart.txt
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-48-29.png>)

**Part 2 - perturb:**
```bash
./scripts/setup/floci-down.sh
./scripts/setup/floci-up.sh
./scripts/utilities/whoami.sh
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-49-17.png>)
**Part 3 - read back:**
```bash
inventory | tee outputs/lab-10-post-restart.txt

diff outputs/lab-10-pre-restart.txt outputs/lab-10-post-restart.txt \
  && echo "IDENTICAL - every Lab 10 artefact survived the restart"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-49-45.png>)

**Verify - stronger check:**
```bash
./scripts/utilities/usms-edge-simulate.sh | tail -20
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-50-12.png>)

**Checkpoint 10:**
```
after floci-down.sh + floci-up.sh
 ├── 3 functions        present, same runtimes, same memory
 ├── versions           present
 ├── alias live → 1     present
 ├── bucket + object    present
 ├── notification       present
 └── edge chain         still executes and still composes
```

---

### Step 23 - Write configs/lab-10.env

Heredoc unquoted (`<< EOF`) - every value must be resolved from a command now.

```bash
cat > configs/lab-10.env << EOF
# Lab 10 - Edge functions with AWS Lambda
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, ARNs and IDs only. NO SECRETS. Safe to commit.

# --- origin ---------------------------------------------------------------
export USMS_BUCKET_ARN=arn:aws:s3:::${USMS_BUCKET_NAME:-usms-student-data}

# --- edge function 1: viewer-request --------------------------------------
export USMS_EDGE_VIEWER_FN=usms-edge-viewer-request
export USMS_EDGE_VIEWER_FN_ARN=$(aws lambda get-function-configuration \
  --function-name usms-edge-viewer-request --query 'FunctionArn' --output text)
export USMS_EDGE_VIEWER_VERSION=$(aws lambda list-versions-by-function \
  --function-name usms-edge-viewer-request \
  --query "max_by(Versions[?Version!='\$LATEST'], &to_number(Version)).Version" --output text)
export USMS_EDGE_VIEWER_VERSION_ARN=${VIEWER_VERSION_ARN}

# --- edge function 2: origin-response -------------------------------------
export USMS_EDGE_ORIGIN_FN=usms-edge-origin-response
export USMS_EDGE_ORIGIN_FN_ARN=$(aws lambda get-function-configuration \
  --function-name usms-edge-origin-response --query 'FunctionArn' --output text)
export USMS_EDGE_ORIGIN_VERSION=$(aws lambda list-versions-by-function \
  --function-name usms-edge-origin-response \
  --query "max_by(Versions[?Version!='\$LATEST'], &to_number(Version)).Version" --output text)
export USMS_EDGE_ORIGIN_VERSION_ARN=${ORIGIN_VERSION_ARN}

export USMS_EDGE_RUNTIME=nodejs20.x
export USMS_EDGE_ROLE_ARN=${EDGE_ROLE_ARN}
export USMS_EDGE_TRACE_FILE=outputs/lab-10-edge-trace.json

# --- regional function: transcript notifier -------------------------------
export USMS_LAMBDA_NOTIFIER_FN=usms-transcript-notifier
export USMS_LAMBDA_NOTIFIER_FN_ARN=$(aws lambda get-function-configuration \
  --function-name usms-transcript-notifier --query 'FunctionArn' --output text)
export USMS_LAMBDA_NOTIFIER_RUNTIME=$(aws lambda get-function-configuration \
  --function-name usms-transcript-notifier --query 'Runtime' --output text)
export USMS_LAMBDA_NOTIFIER_ALIAS=live
export USMS_LAMBDA_NOTIFIER_ALIAS_ARN=$(aws lambda get-alias \
  --function-name usms-transcript-notifier --name live \
  --query 'AliasArn' --output text)
export USMS_LAMBDA_NOTIFIER_VERSION=$(aws lambda get-alias \
  --function-name usms-transcript-notifier --name live \
  --query 'FunctionVersion' --output text)
export USMS_LOG_GROUP_NOTIFIER=/aws/lambda/usms-transcript-notifier

# --- s3 notification ------------------------------------------------------
export USMS_NOTIFICATION_ID=usms-transcript-upload
export USMS_NOTIFICATION_PREFIX=transcripts/
export USMS_NOTIFICATION_SUFFIX=.json

# --- cloudfront (may be unsupported on this build) ------------------------
export USMS_CLOUDFRONT_SUPPORTED=$(aws cloudfront list-distributions >/dev/null 2>&1 && echo yes || echo no)
export USMS_CLOUDFRONT_DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Comment, 'usms-transcript-cdn')].Id | [0]" \
  --output text 2>/dev/null | grep -E '^[A-Z0-9]+$' || echo not-created)
export USMS_CLOUDFRONT_DOMAIN=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Comment, 'usms-transcript-cdn')].DomainName | [0]" \
  --output text 2>/dev/null | grep -E '\.' || echo not-created)
EOF

cat configs/lab-10.env
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-52-04.png>)

**Verify:**
```bash
grep -c '^export' configs/lab-10.env

grep -n 'export .*=$\|None' configs/lab-10.env || echo "all values populated"

source configs/lab-10.env && echo "sources cleanly"
```

**Expected:** `25` exports, `all values populated`, `sources cleanly`.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-52-26.png>)

---

### Step 24 - Check what Git sees, and commit

**Part 1 - look:**
```bash
git status --short
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-54-08.png>)

**Verify ignore rules:**
```bash
git check-ignore -v outputs/usms-edge-viewer-request.zip
git check-ignore -v outputs/lab-10-edge-trace.json
git ls-files outputs/
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-54-21.png>)

**Part 2 - commit:**
```bash
git add configs/lab-10.env \
        labs/lab-10-lambda-edge \
        policies/trust-lambda-edge.json \
        scripts/utilities/usms-edge-simulate.sh \
        scripts/utilities/verify-lab-10.sh \
        scripts/cleanup/lab-10-cleanup.sh \
        templates/lab-10-*.json

git status --short

git commit -m "Lab 10: edge functions with Lambda, origin bucket, S3-triggered notifier

- create usms-student-data, the bucket four policies have named since Lab 01
- usms-edge-viewer-request  (nodejs20.x) auth gate + URI normalisation, version 1
- usms-edge-origin-response (nodejs20.x) security headers + cache policy, version 1
- usms-transcript-notifier  (python3.12) S3 ObjectCreated -> alias live
- trust policy on usms-lambda-exec-role now names edgelambda.amazonaws.com
- usms-edge-simulate.sh runs the edge chain without a CloudFront request path"
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-54-56.png>)

**Verify:**
```bash
git log --oneline -1
git show --stat --oneline HEAD | head -20
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 17-55-15.png>)

**Checkpoint 11:**
```
aws-floci-course/  (committed)
 ├── configs/lab-10.env ................ 25 exports, no secrets
 ├── labs/lab-10-lambda-edge/ .......... 3 handlers
 ├── policies/trust-lambda-edge.json ... 2 service principals
 ├── templates/lab-10-*.json ........... 6 request bodies and events
 └── scripts/utilities/usms-edge-simulate.sh

outputs/  (git-ignored, correctly)
 ├── 3 × .zip
 ├── lab-10-edge-trace.json
 ├── lab-10-support-probe.txt
 ├── lab-10-function-inventory.json
 ├── lab-10-pre-restart.txt / lab-10-post-restart.txt
 └── lab-10-notifier-logs.txt
```

---

## 4. Verification Script

The [verification script](../../scripts/utilities/verify-lab-10.sh) uses the AWS CLI and `jq` to check the local Floci configuration and the saved lab evidence. Run it from the repository root after completing the lab.

```bash
./scripts/utilities/verify-lab-10.sh
```

**Expected final line:** `PASS=51  FAIL=0`

**My verification result** — `PASS=51  FAIL=0`. Floci 1.7.0 dropped the notifier's source account condition and both CloudFront Lambda associations. After upgrading to Floci 2.3.0, I reapplied the permission and associations. The verifier confirmed all three settings in the live configuration.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 18-10-39.png>)

---

## 5. Checkpoints Summary

| # | After Step | What must exist | Verification command |
|---|---|---|---|
| 1 | 5 | `usms-student-data`, tagged, policy resolving | `aws s3api head-bucket --bucket usms-student-data` |
| 2 | 6 | Role trusting both `lambda` and `edgelambda` | `aws iam get-role --role-name usms-lambda-exec-role --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Principal.Service)'` |
| 3 | 9 | `usms-edge-viewer-request` invoked allow/deny | `python3 -m json.tool outputs/lab-10-viewer-allow.json` |
| 4 | 11 | Version 1, version-qualified ARN | `aws lambda list-versions-by-function --function-name usms-edge-viewer-request` |
| 5 | 14 | Both edge functions edge-eligible | `grep -c ' NO ' outputs/lab-10-function-inventory.json` |
| 6 | 15 | Distribution / validated config, 2 associations | `python3 -m json.tool templates/lab-10-distribution-config.json` |
| 7 | 16 | Chain runs end to end, allow and deny | `./scripts/utilities/usms-edge-simulate.sh` |
| 8 | 18 | `usms-transcript-notifier`, version 1, alias `live` | `aws lambda list-aliases --function-name usms-transcript-notifier` |
| 9 | 20 | Notification wired, object uploaded | `aws s3api get-bucket-notification-configuration --bucket usms-student-data` |
| 10 | 22 | All artefacts survive restart | `diff outputs/lab-10-pre-restart.txt outputs/lab-10-post-restart.txt` |
| 11 | 24 | Commit with source, no `outputs/` path | `git show --stat HEAD` |

---

## 6. Troubleshooting Encountered

| Issue | Symptom | Resolution |
|---|---|---|
| Floci started outside Docker Compose | The storage check found a stopped container with no Compose label, an unset storage mode, and a Docker volume at `/app/data`. | I preserved the old container and started Floci with `floci-up.sh`. The storage check then confirmed hybrid mode and a bind mount to my existing state directory. |
| IAM role lookup used a full ARN | `get-role` and `list-attached-role-policies` returned `NoSuchEntity`. | I extracted `usms-lambda-exec-role` from the ARN before passing it to `--role-name`. Both commands then found the role. |
| Lambda ZIP pointed to the wrong checkout | Python raised `FileNotFoundError` when it tried to write the ZIP under `~/aws-floci-course/outputs`. | I changed `course.env` to resolve `COURSE_ROOT` from the config file’s location and rebuilt the ZIP. I verified that `index.mjs` was at the archive root. |
| Viewer deny test was missing its event file | The Lambda invocation could not load the payload file, so no response file was created. | I copied the allow event, removed the `x-usms-student` header, and reran the test. The function returned `403` with the `viewer-request-deny` header value. |
| Verifier ran zero checks | The script printed `PASS=0 FAIL=0` because it defined the check function without calling it. | I replaced the placeholder with 51 checks and ran the verifier against Floci and the saved lab evidence. |
| Floci 1.7.0 dropped three settings | The verifier reported `PASS=48 FAIL=3`. The notifier policy lacked the source account condition, and CloudFront reported zero Lambda associations. | I backed up the lab state, upgraded to Floci 2.3.0, and reapplied the permission and both associations. The verifier then reported `PASS=51 FAIL=0`. |

Common issues from the lab document for reference:

- **`aws lambda list-functions` returns connection error, exit 255** → Floci not running; `./scripts/setup/floci-up.sh`.
- **`create-function` fails: role cannot be assumed** → trust policy missing `lambda.amazonaws.com` (Step 6 overwritten incorrectly).
- **`Cannot find module 'index'`** → zip built from wrong directory; rebuild from inside the function folder.
- **Student id empty in `x-usms-edge`** → Step 7 heredoc was unquoted; template literal was expanded to empty string.
- **`invoke` writes empty file** → missing positional output-file argument, or used `file://` instead of `fileb://`.
- **`LogResult` is `None`** → build-dependent log capture; rely on invocation payload instead.
- **S3 upload produces no invocation** → check key matches filter, notification config present, and try direct invoke with synthetic event.
- **`create-distribution` fails / operation not found** → build does not support CloudFront; use Path B.
- **`configs/lab-10.env` reports wrong export count** → a variable from an earlier step was empty because the terminal was closed; re-source and redo Step 23.

---

## 7. Reflection

This lab showed me how where a function runs affects how I configure and deploy it. CloudFront needs the ARN of a published, numbered Lambda@Edge version. That version has tighter memory and timeout limits for viewer events, and I have to package its settings with the code because Lambda@Edge does not support custom environment variables. The regional transcript notifier can use environment variables, has more room for memory and timeout settings, and can use a `live` alias. I can point that alias to a new version without changing the S3 notification target.

I also learned that an IAM policy can name a resource before it exists. For five labs, `USMSStudentDataReadWrite` pointed to the right bucket and object ARNs, but there was no `usms-student-data` bucket to use. Once I created the bucket, the roles with that policy could use the permissions it already granted without any change to the policy.

Step 14 showed me why static verification matters. The regional Lambda API accepted the environment variables I added to `$LATEST`, but real AWS would reject a published version with those variables when I tried to associate it with CloudFront. A manual invocation in Floci can show that the handler works with a test event. Static checks in `verify-lab-10.sh` serve a different purpose by checking deployment settings against the lab's requirements, including settings the emulator may accept even when AWS would reject them.

---

## 8. Final Verification Checklist

- [x] `floci-storage-check.sh` → `PASS=16 FAIL=0`
- [x] All `configs/lab-01.env` … `lab-09.env` sourced without error
- [x] `usms-student-data` created and tagged
- [x] `usms-lambda-exec-role` trusts both `lambda` and `edgelambda`
- [x] `usms-edge-viewer-request` — 128 MB, 5 s, no env vars, version 1 published
- [x] `usms-edge-origin-response` — no env vars, version 1 published
- [x] `usms-transcript-notifier` — has env vars, alias `live`
- [x] Resource policy on `...:live` scoped by source ARN
- [x] Bucket notification filtered to `transcripts/` and `.json`
- [x] `outputs/lab-10-edge-trace.json` shows 3-stage chain
- [x] `outputs/lab-10-function-inventory.json` has no `NO` lines
- [x] Pre/post restart inventories identical
- [x] `configs/lab-10.env` has 25 exports, no empty values
- [x] `verify-lab-10.sh` → `PASS=51 FAIL=0`
- [x] `git status --short` shows no `outputs/` path, no `.zip`
- [x] Commit created
- [x] Review questions answered in prose
- [x] [Exercises 1–5 recorded](exercise.md)

---
