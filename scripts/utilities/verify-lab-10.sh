#!/usr/bin/env bash
# Verify every Lab 10 artefact exists AND is configured for the edge.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-10.env" || exit 1

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"
ROLE_NAME="${USMS_ROLE_LAMBDA:-usms-lambda-exec-role}"
ROLE_NAME="${ROLE_NAME##*/}"
VIEWER=usms-edge-viewer-request
ORIGIN=usms-edge-origin-response
NOTIFIER=usms-transcript-notifier
DIST_CFG=templates/lab-10-distribution-config.json

PASS=0
FAIL=0
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✔ %s\n' "$label"
    ((PASS += 1))
  else
    printf '  ✗ %s\n' "$label"
    ((FAIL += 1))
  fi
}

aws_local() {
  AWS_PAGER="" aws --endpoint-url "$FLOCI_ENDPOINT" --region "$AWS_REGION_COURSE" \
    --output json "$@"
}

matches() {
  local data="$1"
  shift
  [[ -n "$data" ]] && jq -e "$@" <<< "$data"
}

command -v jq >/dev/null || { echo 'jq is required for this verifier.' >&2; exit 1; }

bucket_arn="arn:aws:s3:::$BUCKET"
role_arn="$USMS_EDGE_ROLE_ARN"
alias_arn="$USMS_LAMBDA_NOTIFIER_ALIAS_ARN"
account="${USMS_ACCOUNT_ID:-$ACCOUNT_ID}"

printf '\nEnvironment, origin and execution role\n'
check 'Local Floci endpoint responds' aws_local sts get-caller-identity
check 'Origin bucket exists' aws_local s3api head-bucket --bucket "$BUCKET"
tags=$(aws_local s3api get-bucket-tagging --bucket "$BUCKET")
check 'Origin bucket has the course tags' matches "$tags" \
  '(.TagSet | map({key: .Key, value: .Value}) | from_entries) | .Project == "USMS" and .Tier == "data" and .Lab == "06"'
role=$(aws_local iam get-role --role-name "$ROLE_NAME")
check 'Execution role matches the recorded ARN' matches "$role" --arg arn "$role_arn" '.Role.Arn == $arn'
check 'Execution role trusts Lambda and Lambda@Edge' matches "$role" \
  '[.Role.AssumeRolePolicyDocument.Statement[] | select(.Effect == "Allow") | .Principal.Service | if type == "array" then .[] else . end] | contains(["lambda.amazonaws.com", "edgelambda.amazonaws.com"])'
policies=$(aws_local iam list-attached-role-policies --role-name "$ROLE_NAME")
check 'Execution role has the USMSLambdaBasic policy' matches "$policies" \
  'any(.AttachedPolicies[]; .PolicyName == "USMSLambdaBasic")'

check_edge() {
  local name="$1" version="$2" arn="$3" versions config
  printf '\n%s\n' "$name"
  versions=$(aws_local lambda list-versions-by-function --function-name "$name")
  config=$(jq -c --arg version "$version" '.Versions[] | select(.Version == $version)' <<< "$versions")
  check 'Published function version is available' matches "$config" \
    '.Version | test("^[1-9][0-9]*$")'
  check 'Version-qualified ARN matches the lab config' matches "$config" --arg arn "$arn" '.FunctionArn == $arn'
  check 'Runtime matches the lab' matches "$config" --arg runtime "$USMS_EDGE_RUNTIME" '.Runtime == $runtime'
  check 'Execution role matches the lab' matches "$config" --arg arn "$role_arn" '.Role == $arn'
  check 'Memory is 128 MB' matches "$config" '.MemorySize == 128'
  check 'Timeout is 5 seconds' matches "$config" '.Timeout == 5'
  check 'No custom environment variables' matches "$config" '(.Environment.Variables // {} | length) == 0'
  check 'No VPC attachment' matches "$config" '(.VpcConfig.SubnetIds // [] | length) == 0'
}
check_edge "$VIEWER" "$USMS_EDGE_VIEWER_VERSION" "$USMS_EDGE_VIEWER_VERSION_ARN"
check_edge "$ORIGIN" "$USMS_EDGE_ORIGIN_VERSION" "$USMS_EDGE_ORIGIN_VERSION_ARN"

printf '\nRegional notifier and invocation permission\n'
alias=$(aws_local lambda get-alias --function-name "$NOTIFIER" --name live)
notifier=$(aws_local lambda get-function-configuration --function-name "$NOTIFIER" --qualifier live)
check 'Live alias has the recorded ARN' matches "$alias" --arg arn "$alias_arn" '.AliasArn == $arn'
check 'Live alias points to the recorded version' matches "$alias" \
  --arg version "$USMS_LAMBDA_NOTIFIER_VERSION" '.FunctionVersion == $version'
check 'Notifier runtime matches the lab' matches "$notifier" \
  --arg runtime "$USMS_LAMBDA_NOTIFIER_RUNTIME" '.Runtime == $runtime and (.Runtime | startswith("python"))'
check 'Notifier uses the course execution role' matches "$notifier" --arg arn "$role_arn" '.Role == $arn'
check 'Notifier has the regional memory and timeout settings' matches "$notifier" '.MemorySize == 256 and .Timeout == 30'
check 'Notifier environment identifies the origin bucket' matches "$notifier" --arg bucket "$BUCKET" \
  '.Environment.Variables.USMS_BUCKET == $bucket'
check 'Notifier environment selects stdout' matches "$notifier" '.Environment.Variables.USMS_NOTIFY_CHANNEL == "stdout"'

policy=$(aws_local lambda get-policy --function-name "$NOTIFIER" --qualifier live)
statement=$(jq -c '.Policy | fromjson | .Statement[] | select(.Sid == "usms-s3-transcript-upload")' <<< "$policy")
check 'S3 may invoke the live alias' matches "$statement" --arg arn "$alias_arn" \
  '.Effect == "Allow" and .Principal.Service == "s3.amazonaws.com" and .Action == "lambda:InvokeFunction" and .Resource == $arn'
check 'Invocation is restricted to the origin bucket ARN' matches "$statement" --arg arn "$bucket_arn" \
  'any(.Condition.ArnLike | to_entries[]; (.key | ascii_downcase) == "aws:sourcearn" and .value == $arn)'
check 'Invocation is restricted to the bucket owner account' matches "$statement" --arg account "$account" \
  'any(.Condition.StringEquals | to_entries[]; (.key | ascii_downcase) == "aws:sourceaccount" and .value == $account)'
logs=$(aws_local logs describe-log-groups --log-group-name-prefix "$USMS_LOG_GROUP_NOTIFIER")
check 'Notifier log group exists' matches "$logs" --arg name "$USMS_LOG_GROUP_NOTIFIER" \
  'any(.logGroups[]; .logGroupName == $name)'

printf '\nS3 notification\n'
notifications=$(aws_local s3api get-bucket-notification-configuration --bucket "$BUCKET")
notification=$(jq -c --arg id "$USMS_NOTIFICATION_ID" \
  '.LambdaFunctionConfigurations[] | select(.Id == $id)' <<< "$notifications")
check 'Exactly one Lab 10 notification is configured' matches "$notifications" --arg id "$USMS_NOTIFICATION_ID" \
  '[.LambdaFunctionConfigurations[] | select(.Id == $id)] | length == 1'
check 'Notification targets the live alias' matches "$notification" --arg arn "$alias_arn" '.LambdaFunctionArn == $arn'
check 'Notification listens for object creation' matches "$notification" '.Events == ["s3:ObjectCreated:*"]'
check 'Notification filters by transcript prefix' matches "$notification" --arg value "$USMS_NOTIFICATION_PREFIX" \
  'any(.Filter.Key.FilterRules[]; .Name == "prefix" and .Value == $value)'
check 'Notification filters by JSON suffix' matches "$notification" --arg value "$USMS_NOTIFICATION_SUFFIX" \
  'any(.Filter.Key.FilterRules[]; .Name == "suffix" and .Value == $value)'

printf '\nCloudFront\n'
distribution=''
if [[ "$USMS_CLOUDFRONT_SUPPORTED" == yes ]]; then
  remote=$(aws_local cloudfront get-distribution --id "$USMS_CLOUDFRONT_DIST_ID")
  check 'CloudFront distribution matches the recorded ID and domain' matches "$remote" \
    --arg id "$USMS_CLOUDFRONT_DIST_ID" --arg domain "$USMS_CLOUDFRONT_DOMAIN" \
    '.Distribution | .Id == $id and .DomainName == $domain'
  distribution=$(jq -c '.Distribution.DistributionConfig' <<< "$remote")
else
  check 'Offline CloudFront distribution template is valid JSON' jq -e 'type == "object"' "$DIST_CFG"
  distribution=$(cat "$DIST_CFG")
fi
check 'Distribution is enabled and redirects HTTP to HTTPS' matches "$distribution" \
  '.Enabled == true and .DefaultCacheBehavior.ViewerProtocolPolicy == "redirect-to-https"'
check 'Default behavior targets the origin bucket' matches "$distribution" \
  --arg host "$BUCKET.s3.$AWS_REGION_COURSE.amazonaws.com" \
  '.DefaultCacheBehavior.TargetOriginId as $id | any(.Origins.Items[]; .Id == $id and .DomainName == $host)'
check 'Viewer request uses the published viewer version' matches "$distribution" \
  --arg arn "$USMS_EDGE_VIEWER_VERSION_ARN" \
  'any(.DefaultCacheBehavior.LambdaFunctionAssociations.Items[]; .EventType == "viewer-request" and .LambdaFunctionARN == $arn)'
check 'Origin response uses the published origin version' matches "$distribution" \
  --arg arn "$USMS_EDGE_ORIGIN_VERSION_ARN" \
  'any(.DefaultCacheBehavior.LambdaFunctionAssociations.Items[]; .EventType == "origin-response" and .LambdaFunctionARN == $arn)'

printf '\nLab evidence\n'
check 'Viewer allow response carries the allow marker' jq -e \
  '.headers["x-usms-edge"][0].value | startswith("viewer-request-allow")' outputs/lab-10-viewer-allow.json
check 'Viewer deny response is a marked 403' jq -e \
  '.status == "403" and .headers["x-usms-edge"][0].value == "viewer-request-deny"' outputs/lab-10-viewer-deny.json
check 'Origin response includes the security headers' jq -e \
  '.headers | has("strict-transport-security") and has("x-content-type-options") and has("x-frame-options") and has("referrer-policy")' \
  outputs/lab-10-origin-response.json
check 'Edge trace contains the three-stage allow chain' jq -e \
  '.chain == ["viewer-request", "origin", "origin-response"] and .decision == "allow"' "$USMS_EDGE_TRACE_FILE"
check 'Notifier direct test processed the synthetic event' jq -e '.processed == 1' outputs/lab-10-notifier-direct.json
check 'Notifier log evidence contains USMS_NOTIFY' grep -q 'USMS_NOTIFY' outputs/lab-10-notifier-logs.txt
check 'Eligibility inventory records both functions without failures' awk -v viewer="$VIEWER" -v origin="$ORIGIN" \
  '$1 == viewer { v=1 } $1 == origin { o=1 } $1 == "NO" { fail=1 } END { exit !(v && o && !fail) }' \
  outputs/lab-10-function-inventory.json
check 'Pre- and post-restart inventories match' cmp -s outputs/lab-10-pre-restart.txt outputs/lab-10-post-restart.txt

printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 && "$PASS" -eq 51 ]]
