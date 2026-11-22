## 11. Independent Lab Exercises

All exercise evidence is also summarised in `labs/lab-11-cicd/exercises.md` (command at the end of this section).

### Exercise 1 — Basic: a second build project for the results service

**Requirement:** project `usms-results-build`, source tree `labs/lab-11-cicd/app-results/`, own `VERSION`, one HTML file and `buildspec.yml`; reuse `usms-codebuild-role`; source at `source/usms-results-src.zip`; source type S3.

**1. Source tree**
```bash
cd "$COURSE_ROOT"
mkdir -p labs/lab-11-cicd/app-results/src

printf 'r1\n' > labs/lab-11-cicd/app-results/VERSION

cat > labs/lab-11-cicd/app-results/src/index.html << 'EOF'
<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><title>USMS - Results</title></head>
  <body>
    <h1>USMS Results Service</h1>
    <p id="release">release: __RELEASE__</p>
    <p id="built">built: __BUILT_AT__</p>
  </body>
</html>
EOF

cat > labs/lab-11-cicd/app-results/buildspec.yml << 'BUILDSPEC'
version: 0.2

env:
  variables:
    SERVICE_NAME: "results"
    ARTIFACT_DIR: "dist"

phases:

  install:
    commands:
      - echo "--- install ---"
      - python3 --version

  pre_build:
    commands:
      - echo "--- pre_build ---"
      - test -f VERSION || { echo "VERSION file is missing"; exit 1; }
      - test -f src/index.html || { echo "src/index.html is missing"; exit 1; }

  build:
    commands:
      - echo "--- build ---"
      - USMS_RELEASE="$(tr -d '[:space:]' < VERSION)"
      - BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      - rm -rf "$ARTIFACT_DIR"
      - mkdir -p "$ARTIFACT_DIR"
      - cp -R src/. "$ARTIFACT_DIR"/
      - sed -i.bak -e "s|__RELEASE__|$USMS_RELEASE|g" -e "s|__BUILT_AT__|$BUILT_AT|g" "$ARTIFACT_DIR/index.html"
      - rm -f "$ARTIFACT_DIR/index.html.bak"
      - |
        cat > "$ARTIFACT_DIR/build-metadata.json" << META
        {
          "service": "$SERVICE_NAME",
          "release": "$USMS_RELEASE",
          "builtAt": "$BUILT_AT",
          "buildId": "${CODEBUILD_BUILD_ID:-local}",
          "sourceVersion": "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}"
        }
        META

  post_build:
    commands:
      - echo "--- post_build ---"
      - "! grep -q '__RELEASE__' dist/index.html"
      - python3 -m json.tool dist/build-metadata.json
      - ls -l "$ARTIFACT_DIR"

artifacts:
  base-directory: dist
  files:
    - '**/*'

cache:
  paths: []
BUILDSPEC

grep -q '^labs/lab-11-cicd/app-results/dist/' .gitignore || \
  printf 'labs/lab-11-cicd/app-results/dist/\n' >> .gitignore

./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app-results
```
(The `! grep` line is YAML-quoted because a plain scalar may not start with `!` — YAML reads that as a tag.)

**2. Project template and project**
```bash
BUILD_ROLE_ARN=$(aws iam get-role --role-name usms-codebuild-role --query 'Role.Arn' --output text)

cat > templates/lab-11-results-build-project.json << EOF
{
  "name": "usms-results-build",
  "description": "Builds the USMS results service artifact from labs/lab-11-cicd/app-results",
  "source": {
    "type": "S3",
    "location": "usms-pipeline-artifacts/source/usms-results-src.zip",
    "buildspec": "buildspec.yml"
  },
  "artifacts": {
    "type": "S3",
    "location": "usms-pipeline-artifacts",
    "path": "build",
    "name": "usms-results-build.zip",
    "packaging": "ZIP",
    "namespaceType": "NONE"
  },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "docker.io/library/python:3.12-slim-bookworm",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": false,
    "environmentVariables": [
      { "name": "USMS_PROJECT", "value": "USMS", "type": "PLAINTEXT" },
      { "name": "USMS_SERVICE", "value": "results", "type": "PLAINTEXT" }
    ]
  },
  "serviceRole": "${BUILD_ROLE_ARN}",
  "timeoutInMinutes": 15,
  "queuedTimeoutInMinutes": 30,
  "logsConfig": {
    "cloudWatchLogs": {
      "status": "ENABLED",
      "groupName": "/aws/codebuild/usms-results-build"
    }
  },
  "tags": [
    { "key": "Project", "value": "USMS" },
    { "key": "Tier", "value": "pipeline" },
    { "key": "Lab", "value": "11" }
  ]
}
EOF

python3 -m json.tool templates/lab-11-results-build-project.json >/dev/null && echo "valid JSON"
grep -c '\$' templates/lab-11-results-build-project.json     # must be 0

./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app-results outputs/usms-results-src.zip
aws s3api put-object --bucket usms-pipeline-artifacts \
  --key source/usms-results-src.zip --body outputs/usms-results-src.zip \
  --query 'VersionId' --output text

aws codebuild create-project \
  --cli-input-json file://templates/lab-11-results-build-project.json \
  --query 'project.{Name:name,Source:source.type,Role:serviceRole}' --output table
```

**3. Run it standalone and read back**
```bash
RES_BUILD=$(aws codebuild start-build --project-name usms-results-build --query 'build.id' --output text)
echo "$RES_BUILD"
for i in $(seq 1 40); do
  S=$(aws codebuild batch-get-builds --ids "$RES_BUILD" --query 'builds[0].buildStatus' --output text 2>/dev/null)
  P=$(aws codebuild batch-get-builds --ids "$RES_BUILD" --query 'builds[0].currentPhase' --output text 2>/dev/null)
  printf '  %2d  status=%-12s phase=%s\n' "$i" "${S:-unknown}" "${P:-unknown}"
  case "$S" in SUCCEEDED|FAILED|FAULT|STOPPED|TIMED_OUT) break ;; esac
  sleep 10
done

aws s3api list-objects-v2 --bucket usms-pipeline-artifacts --prefix build/ \
  --query 'Contents[].{Key:Key,Size:Size}' --output table

aws s3api get-object --bucket usms-pipeline-artifacts --key build/usms-results-build.zip \
  outputs/usms-results-build.zip >/dev/null
python3 -c 'import zipfile;print(zipfile.ZipFile("outputs/usms-results-build.zip").read("build-metadata.json").decode())'
```
**Expected:** `"service": "results"` — distinguishable from the enrolment artifact.

**Does `USMSCodeBuildBase` already permit this build?** *Partly.* The S3 statement covers it (same bucket, `usms-pipeline-artifacts/*`), but the logs statement names **only** `/aws/codebuild/usms-enrolment-build`, so on real AWS the results build could not create or write `/aws/codebuild/usms-results-build` — it works here only because Floci does not enforce IAM. The fix (without a second role) is a policy change adding the results log group; I add it as an inline policy so that `USMSCodeBuildBase` v2 stays free for Lab 12:

```bash
cat > policies/usms-codebuild-results-logs.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteResultsBuildLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": [
        "arn:aws:logs:us-east-1:000000000000:log-group:/aws/codebuild/usms-results-build",
        "arn:aws:logs:us-east-1:000000000000:log-group:/aws/codebuild/usms-results-build:*"
      ]
    }
  ]
}
EOF
python3 -m json.tool policies/usms-codebuild-results-logs.json >/dev/null && echo "valid JSON"
aws iam put-role-policy --role-name usms-codebuild-role \
  --policy-name USMSResultsBuildLogs \
  --policy-document file://policies/usms-codebuild-results-logs.json
aws iam list-role-policies --role-name usms-codebuild-role --output table
```

> 📸 **Screenshot 36 — Exercise 1: local run, create-project, standalone build SUCCEEDED, results build-metadata.json**
>
> ![Screenshot 36](../screenshots/36-ex1-results-build.png)

---

### Exercise 2 — Intermediate: a `finally` block and a build report

**Design:** the test's exit code is captured to `/tmp/usms-smoke-rc` and the command still fails the phase if tests fail. The `finally` block (sibling of `commands`) writes `dist/build-summary.txt` with release, tests exit status and timestamp, whether the phase passed or failed. CodeBuild still runs `UPLOAD_ARTIFACTS` after a failed `post_build`, so the summary reaches the artifact. (`finally` does not rescue the build — it only runs.)

```bash
cd "$COURSE_ROOT/labs/lab-11-cicd/app"

cat > buildspec.yml << 'BUILDSPEC'
version: 0.2

env:
  variables:
    SERVICE_NAME: "enrolment"
    ARTIFACT_DIR: "dist"

phases:

  install:
    commands:
      - echo "--- install ---"
      - python3 --version
      - sed --version 2>/dev/null | head -1 || echo "BSD sed"

  pre_build:
    commands:
      - echo "--- pre_build ---"
      - test -f VERSION || { echo "VERSION file is missing"; exit 1; }
      - python3 -m json.tool config/service.json > /dev/null
      - |
        grep -q '"container": "enrolment-api"' config/service.json || {
          echo "config/service.json names the wrong container"
          exit 1
        }
      - |
        grep -Eq '"port": 80([^0-9]|$)' config/service.json || {
          echo "config/service.json: port must be 80 (the ALB target group and container listen on 80). Set \"port\": 80 and rebuild."
          exit 1
        }
      - echo "configuration validated"

  build:
    commands:
      - echo "--- build ---"
      - USMS_RELEASE="$(tr -d '[:space:]' < VERSION)"
      - BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      - echo "release=$USMS_RELEASE builtAt=$BUILT_AT"
      - rm -rf "$ARTIFACT_DIR"
      - mkdir -p "$ARTIFACT_DIR"
      - cp -R src/. "$ARTIFACT_DIR"/
      - sed -i.bak -e "s|__RELEASE__|$USMS_RELEASE|g" -e "s|__BUILT_AT__|$BUILT_AT|g" "$ARTIFACT_DIR/index.html"
      - rm -f "$ARTIFACT_DIR/index.html.bak"
      - |
        cat > "$ARTIFACT_DIR/build-metadata.json" << META
        {
          "service": "$SERVICE_NAME",
          "release": "$USMS_RELEASE",
          "builtAt": "$BUILT_AT",
          "buildId": "${CODEBUILD_BUILD_ID:-local}",
          "sourceVersion": "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}"
        }
        META
      - cp config/service.json "$ARTIFACT_DIR/service.json"

  post_build:
    commands:
      - echo "--- post_build ---"
      - rm -f /tmp/usms-smoke-rc
      - |
        rc=0
        bash tests/smoke.sh || rc=$?
        echo "$rc" > /tmp/usms-smoke-rc
        [ "$rc" -eq 0 ]
      - ls -l "$ARTIFACT_DIR"
      - cat "$ARTIFACT_DIR/build-metadata.json"
    finally:
      - |
        mkdir -p "$ARTIFACT_DIR"
        TESTS_RC="$(cat /tmp/usms-smoke-rc 2>/dev/null || echo not-run)"
        printf 'release=%s tests_exit=%s at=%s\n' "$(tr -d '[:space:]' < VERSION)" "$TESTS_RC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ARTIFACT_DIR/build-summary.txt"
        cat "$ARTIFACT_DIR/build-summary.txt"

artifacts:
  base-directory: dist
  files:
    - '**/*'

cache:
  paths: []
BUILDSPEC

python3 -c 'import yaml; d=yaml.safe_load(open("buildspec.yml")); print("finally commands:", len(d["phases"]["post_build"]["finally"]))'
cd "$COURSE_ROOT"
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app
```

**How I tested it locally (the local runner does not implement `finally`):** with PyYAML the runner ignores `finally` entirely; with the minimal parser it would append `finally` to `commands`, so it would only run on success. So I break a test, run the runner (it stops in `post_build`), then execute the `finally` block by hand with the same shell semantics:

```bash
cd "$COURSE_ROOT"
cp labs/lab-11-cicd/app/src/healthz.html /tmp/healthz.backup
printf 'not ok\n' > labs/lab-11-cicd/app/src/healthz.html      # breaks "health endpoint says ok"

./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app; echo "runner exit: $?"

python3 - << 'PY' > /tmp/usms-finally.sh
import yaml
d = yaml.safe_load(open("labs/lab-11-cicd/app/buildspec.yml"))
print("set -uo pipefail")
print('export ARTIFACT_DIR="${ARTIFACT_DIR:-dist}"')
for c in d["phases"]["post_build"].get("finally", []):
    print(c)
PY
( cd labs/lab-11-cicd/app && bash /tmp/usms-finally.sh )
cat labs/lab-11-cicd/app/dist/build-summary.txt
```
**Expected:** `release=r5 tests_exit=1 at=...`

**On CodeBuild (Path A) — the real proof.** The project is now `CODEPIPELINE`, and a failed pipeline build publishes no `BuildOutput`, so I use a one-off standalone build with source and artifact overrides on a separate key:

```bash
./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/exercise2-broken.zip >/dev/null
aws s3api put-object --bucket usms-pipeline-artifacts --key source/exercise2-broken.zip \
  --body outputs/exercise2-broken.zip --query 'VersionId' --output text

EX2_BUILD=$(aws codebuild start-build --project-name usms-enrolment-build \
  --source-type-override S3 \
  --source-location-override usms-pipeline-artifacts/source/exercise2-broken.zip \
  --artifacts-override type=S3,location=usms-pipeline-artifacts,path=build,name=exercise2-summary.zip,packaging=ZIP,namespaceType=NONE \
  --query 'build.id' --output text)
echo "$EX2_BUILD"

for i in $(seq 1 40); do
  S=$(aws codebuild batch-get-builds --ids "$EX2_BUILD" --query 'builds[0].buildStatus' --output text 2>/dev/null)
  printf '  %2d  status=%s\n' "$i" "${S:-unknown}"
  case "$S" in SUCCEEDED|FAILED|FAULT|STOPPED|TIMED_OUT) break ;; esac
  sleep 10
done

aws codebuild batch-get-builds --ids "$EX2_BUILD" \
  --query 'builds[0].phases[].{Phase:phaseType,Status:phaseStatus}' --output table

aws s3api get-object --bucket usms-pipeline-artifacts --key build/exercise2-summary.zip \
  outputs/exercise2-summary.zip >/dev/null \
  && python3 -c 'import zipfile;print(zipfile.ZipFile("outputs/exercise2-summary.zip").read("build-summary.txt").decode())'
```
**Expected:** build `FAILED` at `POST_BUILD`, and the artifact still contains `build-summary.txt` saying `tests_exit=1`.

**Restore the health file and confirm green:**
```bash
cp /tmp/healthz.backup labs/lab-11-cicd/app/src/healthz.html
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1 && echo "green again"
```

**What I can claim:** On Path A — *observed* that the summary is produced on failure and shipped. On Path B/C — only that the `finally` commands produce the right file when run by hand after a failure; the CodeBuild semantics (that `finally` runs and the artifact is still uploaded) are *recorded*, not observed.

> 📸 **Screenshot 37 — Exercise 2: failed build (POST_BUILD FAILED) and build-summary.txt with tests_exit=1 (or local simulation)**
>
> ![Screenshot 37](../screenshots/37-ex2-finally.png)

---

### Exercise 3 — Problem solving: make the configuration check robust

**Part A — parse, don't grep.** Replace both `pre_build` greps with one standard-library Python check that names expected **and** actual values. `smoke.sh` test 7 is updated the same way (otherwise a compact-JSON reformat would fail the smoke test instead).

```bash
cd "$COURSE_ROOT/labs/lab-11-cicd/app"

cat > buildspec.yml << 'BUILDSPEC'
version: 0.2

env:
  variables:
    SERVICE_NAME: "enrolment"
    ARTIFACT_DIR: "dist"

phases:

  install:
    commands:
      - echo "--- install ---"
      - python3 --version
      - sed --version 2>/dev/null | head -1 || echo "BSD sed"

  pre_build:
    commands:
      - echo "--- pre_build ---"
      - test -f VERSION || { echo "VERSION file is missing"; exit 1; }
      - |
        python3 - << 'PYCHECK'
        import json, sys
        expected = {"container": "enrolment-api", "port": 80}
        try:
            cfg = json.load(open("config/service.json"))
        except (OSError, ValueError) as exc:
            sys.exit("config/service.json is missing or not valid JSON: %s" % exc)
        bad = ["%s: expected %r, found %r" % (k, v, cfg.get(k)) for k, v in expected.items() if cfg.get(k) != v]
        if bad:
            sys.exit("config/service.json is wrong - " + "; ".join(bad))
        print("config/service.json OK: container=%s port=%s" % (cfg["container"], cfg["port"]))
        PYCHECK
      - echo "configuration validated"

  build:
    commands:
      - echo "--- build ---"
      - USMS_RELEASE="$(tr -d '[:space:]' < VERSION)"
      - BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      - echo "release=$USMS_RELEASE builtAt=$BUILT_AT"
      - rm -rf "$ARTIFACT_DIR"
      - mkdir -p "$ARTIFACT_DIR"
      - cp -R src/. "$ARTIFACT_DIR"/
      - sed -i.bak -e "s|__RELEASE__|$USMS_RELEASE|g" -e "s|__BUILT_AT__|$BUILT_AT|g" "$ARTIFACT_DIR/index.html"
      - rm -f "$ARTIFACT_DIR/index.html.bak"
      - |
        cat > "$ARTIFACT_DIR/build-metadata.json" << META
        {
          "service": "$SERVICE_NAME",
          "release": "$USMS_RELEASE",
          "builtAt": "$BUILT_AT",
          "buildId": "${CODEBUILD_BUILD_ID:-local}",
          "sourceVersion": "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}"
        }
        META
      - cp config/service.json "$ARTIFACT_DIR/service.json"

  post_build:
    commands:
      - echo "--- post_build ---"
      - rm -f /tmp/usms-smoke-rc
      - |
        rc=0
        bash tests/smoke.sh || rc=$?
        echo "$rc" > /tmp/usms-smoke-rc
        [ "$rc" -eq 0 ]
      - ls -l "$ARTIFACT_DIR"
      - cat "$ARTIFACT_DIR/build-metadata.json"
    finally:
      - |
        mkdir -p "$ARTIFACT_DIR"
        TESTS_RC="$(cat /tmp/usms-smoke-rc 2>/dev/null || echo not-run)"
        printf 'release=%s tests_exit=%s at=%s\n' "$(tr -d '[:space:]' < VERSION)" "$TESTS_RC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ARTIFACT_DIR/build-summary.txt"
        cat "$ARTIFACT_DIR/build-summary.txt"

artifacts:
  base-directory: dist
  files:
    - '**/*'

cache:
  paths: []
BUILDSPEC

cat > tests/smoke.sh << 'EOF'
#!/usr/bin/env bash
# Smoke tests for the USMS enrolment service artifact.
# Runs inside the build container, against the built output in ./dist.
set -uo pipefail

FAIL=0
t() {
  if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

echo "== smoke tests =="
t "dist/index.html exists"              "test -f dist/index.html"
t "dist/healthz.html exists"            "test -f dist/healthz.html"
t "release placeholder was replaced"    "! grep -q '__RELEASE__' dist/index.html"
t "build-time placeholder was replaced" "! grep -q '__BUILT_AT__' dist/index.html"
t "health endpoint says ok"             "grep -q '^ok$' dist/healthz.html"
t "build metadata is valid JSON"        "python3 -m json.tool dist/build-metadata.json"
t "container name matches the task def" "python3 -c 'import json,sys; sys.exit(0 if json.load(open(\"config/service.json\")).get(\"container\") == \"enrolment-api\" else 1)'"

echo "smoke tests failed: $FAIL"
[ "$FAIL" -eq 0 ]
EOF
bash -n tests/smoke.sh && echo "smoke.sh syntax OK"
cd "$COURSE_ROOT"
```

**Prove it is indifferent to formatting (4-space indent, then compact):**
```bash
P=labs/lab-11-cicd/app/config/service.json
cp "$P" /tmp/service.json.backup

python3 -c 'import json;p="'"$P"'";d=json.load(open(p));json.dump(d,open(p,"w"),indent=4)'
head -3 "$P"
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1 && echo "PASS with 4-space indent"

python3 -c 'import json;p="'"$P"'";d=json.load(open(p));json.dump(d,open(p,"w"),separators=(",",":"))'
cat "$P"; echo
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1 && echo "PASS with compact JSON (the old grep would have failed here)"
```

**Prove it fails with a specific message:**
```bash
python3 -c 'import json;p="'"$P"'";d=json.load(open(p));d["container"]="enrolment-api-v2";json.dump(d,open(p,"w"),indent=2)'
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app 2>&1 | grep -E 'config/service.json|exit status'

cp /tmp/service.json.backup "$P"
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1 && echo "restored - green"
```
**Expected:** `config/service.json is wrong - container: expected 'enrolment-api', found 'enrolment-api-v2'`.

> 📸 **Screenshot 38 — Exercise 3A: PASS with 4-space and compact JSON; failure message naming both values**
>
> ![Screenshot 38](../screenshots/38-ex3-parse-check.png)

**Part B — tighten the trust policy with `aws:SourceArn`.** Both project ARNs are listed because Exercise 1 reuses this role.
```bash
cat > policies/trust-codebuild.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodeBuildAssumesThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "codebuild.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "000000000000" },
        "ArnLike": {
          "aws:SourceArn": [
            "arn:aws:codebuild:us-east-1:000000000000:project/usms-enrolment-build",
            "arn:aws:codebuild:us-east-1:000000000000:project/usms-results-build"
          ]
        }
      }
    }
  ]
}
EOF
python3 -m json.tool policies/trust-codebuild.json >/dev/null && echo "valid JSON"

aws iam update-assume-role-policy --role-name usms-codebuild-role \
  --policy-document file://policies/trust-codebuild.json
aws iam get-role --role-name usms-codebuild-role \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```
(`update-assume-role-policy` is replace-only — the whole trust document is replaced, so the file must contain everything.)

**What `aws:SourceArn` closes that `aws:SourceAccount` alone does not:** `SourceAccount` only proves that the CodeBuild project asking to assume the role lives in *my* account. Any other project in the same account — one created by another team, a forgotten test project, or one created by someone who holds `codebuild:CreateProject` and a loose `iam:PassRole` — could still be configured with `usms-codebuild-role` and CodeBuild would assume it, giving that project's buildspec our artifact-bucket write access. `SourceArn` pins the role to the specific project ARNs, so CodeBuild refuses to assume it on behalf of any other project — a same-account confused-deputy guard.

**Push the new source through the pipeline:**
```bash
./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null
aws s3api put-object --bucket usms-pipeline-artifacts --key source/usms-enrolment-src.zip \
  --body outputs/usms-enrolment-src.zip --query 'VersionId' --output text
aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text
sleep 40
aws codepipeline get-pipeline-state --name usms-enrolment-pipeline \
  --query 'stageStates[].[stageName,latestExecution.status]' --output table
```

> 📸 **Screenshot 39 — Exercise 3B: trust policy with two conditions (get-role output) and pipeline Succeeded**
>
> ![Screenshot 39](../screenshots/39-ex3-trust-policy.png)

---

### Exercise 4 — Challenge: trigger the pipeline without polling

**Design (real AWS):**

```
PutObject source/usms-enrolment-src.zip
     │  (CloudTrail data event, write-only, one object ARN)
     v
CloudTrail trail ──> EventBridge default bus
     │  rule usms-enrolment-source-changed
     │  matches: aws.s3 / "AWS API Call via CloudTrail" / PutObject|CopyObject|CompleteMultipartUpload
     │           bucketName = usms-pipeline-artifacts, key = source/usms-enrolment-src.zip
     v
target: arn:aws:codepipeline:...:usms-enrolment-pipeline
     runs as usms-events-pipeline-role  ->  codepipeline:StartPipelineExecution
```

S3 object events reach EventBridge two ways: (a) the bucket's own **EventBridge notification** (`detail-type: "Object Created"`, no CloudTrail needed), or (b) **CloudTrail data events** (`detail-type: "AWS API Call via CloudTrail"`). The CodePipeline S3-source guidance uses (b); a `PutObject` on a versioned object produces a CloudTrail data event with `eventName: PutObject` whose `requestParameters` carry `bucketName` and `key`. Management events alone are **not** enough — object-level calls are data events and must be explicitly enabled on a trail. The rule matches the one key only, so the pipeline's own writes under `usms-enrolment-pipeline/` never re-trigger it.

**1. Documents**
```bash
cd "$COURSE_ROOT"

cat > templates/lab-11-eventbridge-rule.json << 'EOF'
{
  "source": ["aws.s3"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["s3.amazonaws.com"],
    "eventName": ["PutObject", "CopyObject", "CompleteMultipartUpload"],
    "requestParameters": {
      "bucketName": ["usms-pipeline-artifacts"],
      "key": ["source/usms-enrolment-src.zip"]
    }
  }
}
EOF

cat > templates/lab-11-eventbridge-targets.json << 'EOF'
[
  {
    "Id": "StartUsmsEnrolmentPipeline",
    "Arn": "arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline",
    "RoleArn": "arn:aws:iam::000000000000:role/usms-events-pipeline-role"
  }
]
EOF

cat > templates/lab-11-cloudtrail-data-events.json << 'EOF'
[
  {
    "Name": "USMS pipeline source object writes",
    "FieldSelectors": [
      { "Field": "eventCategory", "Equals": ["Data"] },
      { "Field": "resources.type", "Equals": ["AWS::S3::Object"] },
      { "Field": "resources.ARN", "Equals": ["arn:aws:s3:::usms-pipeline-artifacts/source/usms-enrolment-src.zip"] },
      { "Field": "readOnly", "Equals": ["false"] }
    ]
  }
]
EOF

cat > policies/trust-events.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EventBridgeAssumesThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "events.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "000000000000" }
      }
    }
  ]
}
EOF

cat > policies/usms-events-start-pipeline.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartOnlyTheEnrolmentPipeline",
      "Effect": "Allow",
      "Action": "codepipeline:StartPipelineExecution",
      "Resource": "arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline"
    }
  ]
}
EOF

for f in templates/lab-11-eventbridge-rule.json templates/lab-11-eventbridge-targets.json \
         templates/lab-11-cloudtrail-data-events.json policies/trust-events.json \
         policies/usms-events-start-pipeline.json; do
  python3 -m json.tool "$f" >/dev/null && echo "valid: $f"
done
```

**Why a separate target role:** EventBridge (principal `events.amazonaws.com`) needs exactly one permission — `codepipeline:StartPipelineExecution` on one pipeline. The pipeline role trusts `codepipeline.amazonaws.com` (EventBridge could not assume it anyway) and holds artifact read/write, `StartBuild` and `iam:PassRole`; giving those to an event trigger would widen what a spoofed or mis-matched event could do.

**2. Build as much as the emulator supports (each call guarded)**
```bash
aws iam create-role --role-name usms-events-pipeline-role \
  --assume-role-policy-document file://policies/trust-events.json \
  --tags Key=Project,Value=USMS Key=Tier,Value=pipeline Key=Lab,Value=11 \
  --query 'Role.Arn' --output text || echo "RECORD: iam create-role failed"
aws iam put-role-policy --role-name usms-events-pipeline-role \
  --policy-name USMSEventsStartPipeline \
  --policy-document file://policies/usms-events-start-pipeline.json || echo "RECORD: put-role-policy failed"

aws events put-rule --name usms-enrolment-source-changed \
  --event-pattern file://templates/lab-11-eventbridge-rule.json \
  --state ENABLED --description "Start usms-enrolment-pipeline when the source zip changes" \
  --query 'RuleArn' --output text || echo "RECORD: events put-rule not supported"

aws events put-targets --rule usms-enrolment-source-changed \
  --targets file://templates/lab-11-eventbridge-targets.json || echo "RECORD: events put-targets not supported"

aws events describe-rule --name usms-enrolment-source-changed --output table 2>/dev/null || echo "RECORD: describe-rule not supported"
aws events list-targets-by-rule --rule usms-enrolment-source-changed --output table 2>/dev/null || echo "RECORD: list-targets-by-rule not supported"

aws cloudtrail describe-trails --output table 2>/dev/null \
  && echo "CloudTrail API answers (trail + data events still Conceptual here)" \
  || echo "RECORD: cloudtrail not available"
```
On real AWS the trail step would be:
```bash
# Conceptual / Real AWS - needs a trail and a log bucket with a CloudTrail bucket policy
# aws cloudtrail create-trail --name usms-pipeline-source-trail --s3-bucket-name <trail-log-bucket>
# aws cloudtrail put-event-selectors --trail-name usms-pipeline-source-trail \
#   --advanced-event-selectors file://templates/lab-11-cloudtrail-data-events.json
# aws cloudtrail start-logging --name usms-pipeline-source-trail
```

**3. Honest test**
```bash
BEFORE=$(aws codepipeline list-pipeline-executions --pipeline-name usms-enrolment-pipeline \
  --query 'length(pipelineExecutions)' --output text 2>/dev/null)
aws s3api put-object --bucket usms-pipeline-artifacts --key source/usms-enrolment-src.zip \
  --body outputs/usms-enrolment-src.zip --query 'VersionId' --output text
sleep 60
AFTER=$(aws codepipeline list-pipeline-executions --pipeline-name usms-enrolment-pipeline \
  --query 'length(pipelineExecutions)' --output text 2>/dev/null)
echo "executions before=$BEFORE after=$AFTER"
```

**Record:** If `after = before`, the rule/target exist as documents (and possibly as stored objects) but the chain did not fire, because Floci does not model CloudTrail data events feeding EventBridge end to end — that link is **Conceptual / Real AWS**. What ran: `__________`. What did not: `__________`.

> 📸 **Screenshot 40 — Exercise 4: documents valid, put-rule/put-targets results (or RECORD lines), before/after execution count**
>
> ![Screenshot 40](../screenshots/40-ex4-eventbridge.png)

---

### Exercise 5 — Integration: prepare the deployment contract for Lab 12

**Final buildspec** — adds `imagedefinitions.json` (container name read from `config/service.json`, image from `${IMAGE_URI:-...}`, always a JSON **array**):

```bash
cd "$COURSE_ROOT/labs/lab-11-cicd/app"

cat > buildspec.yml << 'BUILDSPEC'
version: 0.2

env:
  variables:
    SERVICE_NAME: "enrolment"
    ARTIFACT_DIR: "dist"

phases:

  install:
    commands:
      - echo "--- install ---"
      - python3 --version
      - sed --version 2>/dev/null | head -1 || echo "BSD sed"

  pre_build:
    commands:
      - echo "--- pre_build ---"
      - test -f VERSION || { echo "VERSION file is missing"; exit 1; }
      - |
        python3 - << 'PYCHECK'
        import json, sys
        expected = {"container": "enrolment-api", "port": 80}
        try:
            cfg = json.load(open("config/service.json"))
        except (OSError, ValueError) as exc:
            sys.exit("config/service.json is missing or not valid JSON: %s" % exc)
        bad = ["%s: expected %r, found %r" % (k, v, cfg.get(k)) for k, v in expected.items() if cfg.get(k) != v]
        if bad:
            sys.exit("config/service.json is wrong - " + "; ".join(bad))
        print("config/service.json OK: container=%s port=%s" % (cfg["container"], cfg["port"]))
        PYCHECK
      - echo "configuration validated"

  build:
    commands:
      - echo "--- build ---"
      - USMS_RELEASE="$(tr -d '[:space:]' < VERSION)"
      - BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      - echo "release=$USMS_RELEASE builtAt=$BUILT_AT"
      - rm -rf "$ARTIFACT_DIR"
      - mkdir -p "$ARTIFACT_DIR"
      - cp -R src/. "$ARTIFACT_DIR"/
      - sed -i.bak -e "s|__RELEASE__|$USMS_RELEASE|g" -e "s|__BUILT_AT__|$BUILT_AT|g" "$ARTIFACT_DIR/index.html"
      - rm -f "$ARTIFACT_DIR/index.html.bak"
      - |
        cat > "$ARTIFACT_DIR/build-metadata.json" << META
        {
          "service": "$SERVICE_NAME",
          "release": "$USMS_RELEASE",
          "builtAt": "$BUILT_AT",
          "buildId": "${CODEBUILD_BUILD_ID:-local}",
          "sourceVersion": "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}"
        }
        META
      - cp config/service.json "$ARTIFACT_DIR/service.json"
      - |
        IMAGE_URI="${IMAGE_URI:-public.ecr.aws/nginx/nginx:stable-alpine}"
        export IMAGE_URI
        python3 - << 'PYIMG'
        import json, os
        cfg = json.load(open("config/service.json"))
        defs = [{"name": cfg["container"], "imageUri": os.environ["IMAGE_URI"]}]
        with open(os.path.join(os.environ.get("ARTIFACT_DIR", "dist"), "imagedefinitions.json"), "w") as fh:
            json.dump(defs, fh)
        print("wrote imagedefinitions.json", json.dumps(defs))
        PYIMG

  post_build:
    commands:
      - echo "--- post_build ---"
      - rm -f /tmp/usms-smoke-rc
      - |
        rc=0
        bash tests/smoke.sh || rc=$?
        echo "$rc" > /tmp/usms-smoke-rc
        [ "$rc" -eq 0 ]
      - ls -l "$ARTIFACT_DIR"
      - cat "$ARTIFACT_DIR/build-metadata.json"
    finally:
      - |
        mkdir -p "$ARTIFACT_DIR"
        TESTS_RC="$(cat /tmp/usms-smoke-rc 2>/dev/null || echo not-run)"
        printf 'release=%s tests_exit=%s at=%s\n' "$(tr -d '[:space:]' < VERSION)" "$TESTS_RC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ARTIFACT_DIR/build-summary.txt"
        cat "$ARTIFACT_DIR/build-summary.txt"

artifacts:
  base-directory: dist
  files:
    - '**/*'

cache:
  paths: []
BUILDSPEC
```

**Eighth smoke assertion:**
```bash
cat > tests/smoke.sh << 'EOF'
#!/usr/bin/env bash
# Smoke tests for the USMS enrolment service artifact.
# Runs inside the build container, against the built output in ./dist.
set -uo pipefail

FAIL=0
t() {
  if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

echo "== smoke tests =="
t "dist/index.html exists"              "test -f dist/index.html"
t "dist/healthz.html exists"            "test -f dist/healthz.html"
t "release placeholder was replaced"    "! grep -q '__RELEASE__' dist/index.html"
t "build-time placeholder was replaced" "! grep -q '__BUILT_AT__' dist/index.html"
t "health endpoint says ok"             "grep -q '^ok$' dist/healthz.html"
t "build metadata is valid JSON"        "python3 -m json.tool dist/build-metadata.json"
t "container name matches the task def" "python3 -c 'import json,sys; sys.exit(0 if json.load(open(\"config/service.json\")).get(\"container\") == \"enrolment-api\" else 1)'"
t "imagedefinitions.json is a one-entry array for enrolment-api" "python3 -c 'import json,sys; d=json.load(open(\"dist/imagedefinitions.json\")); sys.exit(0 if isinstance(d, list) and len(d) == 1 and d[0].get(\"name\") == \"enrolment-api\" and d[0].get(\"imageUri\") else 1)'"

echo "smoke tests failed: $FAIL"
[ "$FAIL" -eq 0 ]
EOF
bash -n tests/smoke.sh && echo "smoke.sh syntax OK"

cd "$COURSE_ROOT"
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app
cat labs/lab-11-cicd/app/dist/imagedefinitions.json; echo

# the environment override works too:
IMAGE_URI=example.invalid/usms/enrolment:test ./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1
cat labs/lab-11-cicd/app/dist/imagedefinitions.json; echo
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app >/dev/null 2>&1   # back to default
```
**Expected:** 8 `ok` lines; `[{"name": "enrolment-api", "imageUri": "public.ecr.aws/nginx/nginx:stable-alpine"}]`.

**Run the pipeline and confirm the file is at the artifact root:**
```bash
./scripts/utilities/usms-pack-source.sh labs/lab-11-cicd/app outputs/usms-enrolment-src.zip >/dev/null
aws s3api put-object --bucket usms-pipeline-artifacts --key source/usms-enrolment-src.zip \
  --body outputs/usms-enrolment-src.zip --query 'VersionId' --output text

EX5_EXEC=$(aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text)
for i in $(seq 1 30); do
  S=$(aws codepipeline get-pipeline-execution --pipeline-name usms-enrolment-pipeline \
        --pipeline-execution-id "$EX5_EXEC" --query 'pipelineExecution.status' --output text 2>/dev/null)
  printf '  %2d  execution=%s\n' "$i" "${S:-unknown}"
  case "$S" in Succeeded|Failed|Stopped|Superseded) break ;; esac
  sleep 10
done

BUILD_ART_KEY=$(aws s3api list-objects-v2 --bucket usms-pipeline-artifacts \
  --prefix usms-enrolment-pipeline/BuildOutput/ \
  --query 'sort_by(Contents || `[]`, &LastModified)[-1].Key' --output text) || BUILD_ART_KEY=
(
if [[ -z "${BUILD_ART_KEY}" || "${BUILD_ART_KEY}" == None ]]; then
  echo "No BuildOutput artifact exists in S3. Check the pipeline execution and its build logs." >&2
  exit 1
fi

aws s3api get-object --bucket usms-pipeline-artifacts --key "$BUILD_ART_KEY" \
  outputs/lab-11-buildoutput.zip >/dev/null || exit 1

python3 - << 'PY'
import json, zipfile
z = zipfile.ZipFile("outputs/lab-11-buildoutput.zip")
print("artifact contents:", sorted(z.namelist()))
assert "imagedefinitions.json" in z.namelist(), "imagedefinitions.json is NOT at the artifact root"
d = json.loads(z.read("imagedefinitions.json"))
assert isinstance(d, list), "imagedefinitions.json must be an array"
print("imagedefinitions.json:", d)
PY
)
```

**Readiness file for Lab 12 Step 1:**
```bash
if [ -f outputs/lab-11-buildoutput.zip ] && [ -n "${BUILD_ART_KEY:-}" ] && [ "$BUILD_ART_KEY" != "None" ]; then
  SRC_DESC="pipeline BuildOutput"
  IMGDEF=$(python3 -c 'import zipfile;print(zipfile.ZipFile("outputs/lab-11-buildoutput.zip").read("imagedefinitions.json").decode())')
else
  SRC_DESC="local runner (Path B/C) - not produced by CodeBuild"
  BUILD_ART_KEY="not-created"
  IMGDEF=$(cat labs/lab-11-cicd/app/dist/imagedefinitions.json)
fi

cat > outputs/lab-11-lab08b-readiness.txt << EOF
# Lab 11 -> Lab 12 readiness
generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
support_path=$(sed -n 's/^USMS_CICD_SUPPORT_PATH=//p' outputs/lab-11-support-probe.txt)
artifact_source=$SRC_DESC
artifact_bucket=usms-pipeline-artifacts
artifact_key=$BUILD_ART_KEY
release=$(tr -d '[:space:]' < labs/lab-11-cicd/app/VERSION)
imagedefinitions_json=$IMGDEF
EOF
cat outputs/lab-11-lab08b-readiness.txt
```

> 📸 **Screenshot 41 — Exercise 5: local run with 8 ok, pipeline Succeeded, artifact root contains imagedefinitions.json, readiness file**
>
> ![Screenshot 41](../screenshots/41-ex5-imagedefinitions.png)

### Exercises record and commit

```bash
cd "$COURSE_ROOT"
cat > labs/lab-11-cicd/exercises.md << 'EOF'
# Lab 11 - Exercises

## Exercise 1 - results build
usms-results-build created from templates/lab-11-results-build-project.json (source S3,
role usms-codebuild-role). Artifact build/usms-results-build.zip has service "results".
USMSCodeBuildBase covers the S3 access but not the /aws/codebuild/usms-results-build log
group; added inline policy USMSResultsBuildLogs (Floci does not enforce IAM, real AWS would).

## Exercise 2 - finally + build-summary.txt
post_build captures the smoke exit code and a finally block writes dist/build-summary.txt.
The local runner ignores finally, so locally I ran the finally commands by hand after a
failed runner; on CodeBuild a one-off override build failed in POST_BUILD and the artifact
still contained the summary with tests_exit=1 (Path A) / recorded only (Path B/C).

## Exercise 3 - robust config check + SourceArn
pre_build and smoke test 7 parse JSON with python3; build passes with 4-space and compact
JSON; fails naming expected and actual container. Trust policy now has aws:SourceAccount
and aws:SourceArn (both project ARNs).

## Exercise 4 - EventBridge trigger
templates/lab-11-eventbridge-rule.json, -targets.json, -cloudtrail-data-events.json,
policies/trust-events.json, policies/usms-events-start-pipeline.json. CloudTrail data
events -> EventBridge is Conceptual / Real AWS on Floci. See the README for what ran.

## Exercise 5 - imagedefinitions.json
Build writes dist/imagedefinitions.json (array, name from config/service.json, image from
IMAGE_URI with a default). Smoke test 8 validates it. Readiness file:
outputs/lab-11-lab08b-readiness.txt.
EOF

git status --short
git add labs/lab-11-cicd templates/lab-11-results-build-project.json \
        templates/lab-11-eventbridge-rule.json templates/lab-11-eventbridge-targets.json \
        templates/lab-11-cloudtrail-data-events.json \
        policies/trust-codebuild.json policies/trust-events.json \
        policies/usms-events-start-pipeline.json policies/usms-codebuild-results-logs.json \
        .gitignore
git commit -m "Lab 11: exercises 1-5"

./scripts/utilities/verify-lab-11.sh
```

> 📸 **Screenshot 42 — Exercises committed and verify-lab-11.sh still passing**
>
> ![Screenshot 42](../screenshots/42-exercises-commit-verify.png)
