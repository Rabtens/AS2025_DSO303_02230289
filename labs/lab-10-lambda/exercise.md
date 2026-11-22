# Lab 10 Independent Exercises
## Exercise 1 - Add Content-Security-Policy

I added `Content-Security-Policy: default-src 'self'` to the origin-response handler's `SECURITY_HEADERS` object.

```bash
source configs/course.env
source configs/lab-10.env
a() { aws --endpoint-url "$FLOCI_ENDPOINT" --region "$AWS_REGION_COURSE" "$@"; }

origin=$USMS_EDGE_ORIGIN_FN
(
  cd labs/lab-10-lambda-edge/edge-origin-response &&
  python3 -m zipfile -c "$COURSE_ROOT/outputs/usms-edge-origin-response.zip" index.mjs
)
a lambda update-function-code --function-name "$origin" \
  --zip-file fileb://outputs/usms-edge-origin-response.zip
a lambda wait function-updated-v2 --function-name "$origin"
a lambda publish-version --function-name "$origin" \
  --description "Exercise 1 CSP header" --query Version --output text

for version in 1 '$LATEST'; do
  result="outputs/lab-10-ex1-origin-$version.json"
  a lambda invoke --function-name "$origin" --qualifier "$version" \
    --payload fileb://templates/lab-10-origin-response-event.json "$result"
  jq '.headers | with_entries(select(.key | IN(
    "strict-transport-security", "x-content-type-options", "x-frame-options",
    "referrer-policy", "content-security-policy"
  ))) | {count: length, csp: .["content-security-policy"][0].value}' "$result"
done
jq -r '.DefaultCacheBehavior.LambdaFunctionAssociations.Items[] |
  select(.EventType == "origin-response") | .LambdaFunctionARN' \
  templates/lab-10-distribution-config.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 18-19-36.png>)

| Target | Security headers | Content-Security-Policy |
|---|---:|---|
| Version 1 | 4 | Absent |
| `$LATEST` | 5 | `default-src 'self'` |

The publish returned version `2`. I updated the distribution template's origin-response ARN to `arn:aws:lambda:us-east-1:000000000000:function:usms-edge-origin-response:2`. The live distribution retained its Lab 10 baseline associations.

## Exercise 2 - Use a dedicated edge execution role

I created `usms-edge-exec-role` using the existing Lambda and Lambda@Edge trust policy. Its only attached policy is `USMSEdgeBasic`, which grants CloudWatch Logs writes under `/aws/lambda/usms-edge-*`. The notifier still uses `usms-lambda-exec-role`.

```bash
role=$(a iam create-role --role-name usms-edge-exec-role \
  --assume-role-policy-document file://policies/trust-lambda-edge.json \
  --query Role.Arn --output text)
policy=$(a iam create-policy --policy-name USMSEdgeBasic \
  --policy-document file://policies/usms-edge-basic-policy.json \
  --query Policy.Arn --output text)
a iam attach-role-policy --role-name usms-edge-exec-role --policy-arn "$policy"

for fn in "$USMS_EDGE_VIEWER_FN" "$USMS_EDGE_ORIGIN_FN"; do
  a lambda update-function-configuration --function-name "$fn" --role "$role"
  a lambda wait function-updated-v2 --function-name "$fn"
  a lambda publish-version --function-name "$fn" \
    --description "Exercise 2 dedicated edge role" --query '[Version,Role]' --output text
  a lambda list-versions-by-function --function-name "$fn" \
    --query 'Versions[].[Version,Role]' --output table
done
a iam list-attached-role-policies --role-name usms-edge-exec-role \
  --query 'AttachedPolicies[].PolicyName' --output text
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 18-20-52.png>)

| Function | Version 1 role | `$LATEST` role | Published version with the new role |
|---|---|---|---:|
| Viewer request | `usms-lambda-exec-role` | `usms-edge-exec-role` | 2 |
| Origin response | `usms-lambda-exec-role` | `usms-edge-exec-role` | 3 |

Publishing a version freezes its execution-role ARN along with its other configuration. Updating `$LATEST` left version 1 on the original role. Rolling back the association to version 1 would also restore that function's use of the original role. Origin-response version 2 still uses the original role because I published it before changing roles.

## Exercise 3 - Report edge readiness

I ran the [edge report script](../../scripts/utilities/usms-edge-report.sh) from outside the repository and saved the result.

```bash
( cd /tmp && "$COURSE_ROOT/scripts/utilities/usms-edge-report.sh" ) \
  | tee outputs/lab-10-edge-report.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 18-21-26.png>)

| Function | Runtime | Memory | Timeout | Published versions | Aliases | Env vars | Eligible |
|---|---|---:|---:|---:|---:|---|---|
| `usms-edge-origin-response` | `nodejs20.x` | 128 MB | 5 s | 3 | 0 | No | Yes |
| `usms-edge-viewer-request` | `nodejs20.x` | 128 MB | 5 s | 2 | 0 | No | Yes |
| `usms-transcript-notifier` | `python3.12` | 256 MB | 30 s | 2 | 1 | Yes | No |

The notifier fails the environment-variable rule. Under the specified non-viewer limits, 256 MB and 30 seconds are within bounds, so the live notifier fails only one of the listed eligibility checks. Its `live` alias is independently unsuitable for association because CloudFront requires a numbered version ARN.

## Exercise 4 - Design transcript delivery

I wrote the [transcript delivery design](notes/lab-10-edge-design.md) covering session validation, revision-aware caching, the correction window, refusal reporting and origin failover.

## Exercise 5 - Prepare the S3 lab handoff

I kept the Lab 09 policy draft and verified that both bucket resource ARNs matched the existing bucket and all five explicit role principals resolved. The wildcard principals are part of the draft's deny statements. I also confirmed that `usms-admin-01` exists as the IAM user named in the deny condition. The draft stayed unapplied, and `get-bucket-policy` returned `NoSuchBucketPolicy`.

```bash
key=transcripts/evidence/lab-10-edge-trace.json
a s3api put-object --bucket "${USMS_BUCKET_ARN#arn:aws:s3:::}" \
  --key "$key" --body "$USMS_EDGE_TRACE_FILE" --content-type application/json
a logs filter-log-events --log-group-name "$USMS_LOG_GROUP_NOTIFIER" \
  --query 'events[].message' --output text > outputs/lab-10-ex5-notifier.log

# Direct verification when the log query did not show the uploaded key.
jq --arg key "$key" '.Records[0].s3.object.key = $key' \
  templates/lab-10-s3-event.json > outputs/lab-10-ex5-event.json
a lambda invoke --function-name "$USMS_LAMBDA_NOTIFIER_FN" --qualifier live \
  --payload fileb://outputs/lab-10-ex5-event.json outputs/lab-10-ex5-invoke.json
jq -e --arg key "$key" '.processed == 1 and .keys == [$key]' \
  outputs/lab-10-ex5-invoke.json
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 18-22-05.png>)

The direct invocation returned `{"processed":1,"keys":["transcripts/evidence/lab-10-edge-trace.json"]}`. The upload log query did not show that key, so the evidence confirms the direct invocation path.

### Reproduce the readiness report

```bash
set -eo pipefail
source configs/course.env
source configs/lab-10.env
a() { aws --endpoint-url "$FLOCI_ENDPOINT" --region "$AWS_REGION_COURSE" "$@"; }
bucket=${USMS_BUCKET_ARN#arn:aws:s3:::}
draft=outputs/lab-09-bucket-policy-draft.json
a s3api head-bucket --bucket "$bucket"
if [[ ! -s "$draft" ]]; then
  policy=$(a iam list-policies --scope Local --query 'Policies[?PolicyName==`USMSStudentDataReadWrite`].Arn | [0]' --output text)
  roles=$(a iam list-entities-for-policy --policy-arn "$policy" --entity-filter Role --query 'PolicyRoles[].RoleName' --output text)
  arns=$(for role in $roles; do a iam get-role --role-name "$role" --query Role.Arn --output text || exit 1; done)
  jq -n --arg resource "$USMS_BUCKET_ARN/*" --arg arns "$arns" '
    ($arns | split("\n") | map(select(length > 0))) as $roles |
    if ($roles | length) != 3 then error("expected three ReadWrite roles") else
    {Version:"2012-10-17", Statement:[{Effect:"Allow", Principal:{AWS:$roles}, Action:"s3:GetObject", Resource:$resource}]}
    end' > "$draft"
fi
validation=$(
  ok=yes
  resources=$(jq -er '[.Statement[].Resource | if type == "array" then .[] else . end] | unique[]' "$draft")
  for resource in $resources; do
    if [[ "$resource" == "$USMS_BUCKET_ARN" || "$resource" == "$USMS_BUCKET_ARN/"* ]]; then
      printf 'Bucket resource matches: %s\n' "$resource"
    else
      printf 'Bucket resource mismatch: %s\n' "$resource"
      ok=no
    fi
  done
  principals=$(jq -r '[.Statement[].Principal | objects | .AWS? | if type == "array" then .[] else . end | strings] | unique[]' "$draft")
  if [[ -z "$principals" ]]; then echo 'No explicit role principals found'; ok=no; fi
  for arn in $principals; do
    if [[ "$arn" == arn:aws:iam::*:role/* ]] &&
       actual=$(a iam get-role --role-name "${arn##*/}" --query Role.Arn --output text) &&
       [[ "$actual" == "$arn" ]]; then
      printf 'Principal resolves: %s\n' "$arn"
    else
      printf 'Principal mismatch: %s\n' "$arn"
      ok=no
    fi
  done
  printf 'Draft validation passed: %s\n' "$ok"
)
printf '%s\n' "$validation"
if policy_status=$(a s3api get-bucket-policy --bucket "$bucket" 2>&1); then
  echo 'Unexpected live bucket policy' >&2
  exit 1
elif [[ "$policy_status" != *NoSuchBucketPolicy* ]]; then
  printf '%s\n' "$policy_status" >&2
  exit 1
fi
{
  printf 'Bucket: %s\nARN: %s\n' "$bucket" "$USMS_BUCKET_ARN"
  printf 'Transcript objects: '
  a s3api list-objects-v2 --bucket "$bucket" --prefix transcripts/ --query 'length(Contents || `[]`)' --output text
  printf 'Notification configuration:\n'
  a s3api get-bucket-notification-configuration --bucket "$bucket" --output json
  printf 'Published versions:\n'
  for fn in "$USMS_EDGE_VIEWER_FN" "$USMS_EDGE_ORIGIN_FN" "$USMS_LAMBDA_NOTIFIER_FN"; do
    printf '%s: ' "$fn"
    a lambda list-versions-by-function --function-name "$fn" --query 'Versions[?Version!=`$LATEST`].Version' --output text
  done
  printf 'CloudFront list-distributions supported: '
  if a cloudfront list-distributions >/dev/null; then echo yes; else echo no; fi
  printf 'Live bucket policy: NoSuchBucketPolicy (draft unapplied)\n%s\n' "$validation"
} > outputs/lab-10-s3-readiness.txt
git check-ignore -v outputs/lab-10-s3-readiness.txt
[[ "$validation" == *'Draft validation passed: yes' ]]
```

```text
Bucket: usms-student-data
ARN: arn:aws:s3:::usms-student-data
Transcript objects: 3
Notification: usms-transcript-upload
Target: arn:aws:lambda:us-east-1:000000000000:function:usms-transcript-notifier:live
Event: s3:ObjectCreated:*
Filter: prefix transcripts/, suffix .json
Published versions: viewer 1, 2 | origin 1, 2, 3 | notifier 1, 2
CloudFront list-distributions supported: yes
Live bucket policy: NoSuchBucketPolicy (draft unapplied)
Draft validation passed: yes
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-22 18-22-44.png>)


