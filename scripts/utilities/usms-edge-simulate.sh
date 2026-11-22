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
