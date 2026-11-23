## Independent Lab Exercises

### Exercise 1 - Basic: a second base image, and a smaller one

**Requirement:** rebuild on `public.ecr.aws/nginx/nginx:stable-alpine`, push as `r7-alt`, compare sizes and layers. Do not change `VERSION`; do not deploy.

```bash
cd ~/aws-floci-course/labs/lab-11-cicd/app
test -d dist || IMAGE_REPO_URI="$ECR_URI" ~/aws-floci-course/scripts/utilities/usms-buildspec-run.sh . >/dev/null

sed 's|^FROM .*|FROM public.ecr.aws/nginx/nginx:stable-alpine|' Dockerfile > /tmp/Dockerfile.alt
docker build -f /tmp/Dockerfile.alt -t "$ECR_URI:r7-alt" .
docker push "$ECR_URI:r7-alt"

# make sure the r7 image is local too, for docker history
docker pull "$ECR_URI:r7" >/dev/null
echo "--- r7 layers ---";     docker history "$ECR_URI:r7"
echo "--- r7-alt layers ---"; docker history "$ECR_URI:r7-alt"
echo "layer count r7    : $(docker history -q "$ECR_URI:r7" | wc -l)"
echo "layer count r7-alt: $(docker history -q "$ECR_URI:r7-alt" | wc -l)"
docker images | grep usms-enrolment

cd ~/aws-floci-course
aws ecr describe-images --repository-name usms-enrolment \
  --image-ids imageTag=r7 imageTag=r7-alt \
  --query 'imageDetails[].{Tags:imageTags,SizeBytes:imageSizeInBytes,Digest:imageDigest}' \
  --output table
rm -f /tmp/Dockerfile.alt
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-23 23-59-39.png>)

| Image | Registry size (`describe-images`) | Local size (`docker images`) | Layers |
|---|---|---|---|
| r7 (`nginx:1.27-alpine`) | 20,972,520 bytes | 48.2 MB | 9 filesystem layers (21 history entries) |
| r7-alt (`public.ecr.aws/nginx/nginx:stable-alpine`) | Tag absent from ECR | Image absent locally | Pending measurement |

**Write-up:** ECR reports the **compressed** size of the layers it stores, while `docker images` reports the **uncompressed** size on disk, which is most of the difference between the two numbers. The rest comes from the base images themselves: the two tags track different nginx/alpine releases, so their base layers contain different package versions and file counts. My application layer (`COPY dist/`) is identical in both and is tiny; the size difference is almost entirely the base image. I still need to measure both images before drawing a size conclusion.

---

### Exercise 2 - Intermediate: argue for immutable tags, then implement it

**Part A - switch to IMMUTABLE and try to overwrite r7**

```bash
aws ecr put-image-tag-mutability --repository-name usms-enrolment \
  --image-tag-mutability IMMUTABLE \
  --query '{Repo:repositoryName,Mutability:imageTagMutability}' --output table

# try to move r7 onto a different image (the r6 image)
docker pull "$ECR_URI:r6"
docker tag  "$ECR_URI:r6" "$ECR_URI:r7"
docker push "$ECR_URI:r7" || echo "push REJECTED (expected with IMMUTABLE)"

aws ecr describe-images --repository-name usms-enrolment --image-ids imageTag=r7 \
  --query 'imageDetails[0].imageDigest' --output text
```

**Expected on real AWS:** the push fails with `tag invalid: The image tag 'r7' already exists in the 'usms-enrolment' repository and cannot be overwritten because the repository is immutable.` and the digest of `r7` is unchanged. On Floci, enforcement is build-dependent; record what actually happened.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-02-33.png>)

**Observation:** The overwrite test and both r7 digests are pending the r7 push and the tag immutability change.

**Part B - a buildspec that cannot collide**

Tag every build uniquely as `<release>-<build number>`, with a timestamp fallback for the local runner (which sets no `CODEBUILD_*` variables):

```bash
cd ~/aws-floci-course
cp labs/lab-11-cicd/app/buildspec.yml labs/lab-11-cicd/app/buildspec.yml.pre-ex2

python3 - << 'PY'
p = "labs/lab-11-cicd/app/buildspec.yml"
s = open(p).read()
anchor = '      - BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"\n'
assert s.count(anchor) == 1, "anchor not found exactly once"
add = ('      - IMAGE_TAG="$USMS_RELEASE-${CODEBUILD_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"\n'
       '      - echo "image tag is $IMAGE_TAG"\n')
s = s.replace(anchor, anchor + add)
n = s.count('${IMAGE_REPO_URI}:$USMS_RELEASE')
s = s.replace('${IMAGE_REPO_URI}:$USMS_RELEASE', '${IMAGE_REPO_URI}:$IMAGE_TAG')
open(p, "w").write(s)
print("inserted IMAGE_TAG; replaced", n, "image references")
PY

grep -n 'IMAGE_TAG' labs/lab-11-cicd/app/buildspec.yml
IMAGE_REPO_URI="$ECR_URI" ./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app | tail -12
```

**Expected:** 4 references replaced (metadata, `docker build`, `docker push`, `IMAGE_URI`), smoke tests 8/8, and `imagedefinitions.json` naming e.g. `…/usms-enrolment:r7-20260924101500`. Because the deploy action reads whatever URI is in `imagedefinitions.json`, the file stays deployable.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-03-17.png>)

**Part C - set it back**

I set the repository back to **MUTABLE**, because Exercise 5 deliberately retags `r7`, which an immutable repository would refuse, and Section 9 does not check this field.

```bash
aws ecr put-image-tag-mutability --repository-name usms-enrolment \
  --image-tag-mutability MUTABLE \
  --query '{Repo:repositoryName,Mutability:imageTagMutability}' --output table
docker pull "$ECR_URI:r7"   # restore my local r7 name to the registry's r7
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-04-06.png>)

**What immutable tags buy and cost:** They buy a guarantee that a tag, once published, always means the same bytes, so a task definition naming `usms-enrolment:r7` is as trustworthy as a digest, rollback targets cannot be silently replaced, and an accidental or malicious re-push is refused. They cost convenience: a failed or rebuilt release cannot reuse its tag, floating tags like `latest` or `stable` stop working, and the build must generate a unique tag every time, which is why the buildspec now appends a build number.

---

### Exercise 3 - Problem solving: build the blue/green scaffolding

**Requirement:** create `usms-enrolment-tg-green` (same settings as Lab 05's target group) and a test listener on port 8080, then substitute real ARNs into the deployment group document. Do not change the service's deployment controller.

```bash
cd ~/aws-floci-course

# read Lab 05's settings rather than copying them
aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].{Vpc:VpcId,Proto:Protocol,Port:Port,Type:TargetType,HcPath:HealthCheckPath,HcProto:HealthCheckProtocol,Matcher:Matcher.HttpCode}' \
  --output table

VPC_ID=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].VpcId' --output text)
ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

GREEN_TG_ARN=$(aws elbv2 create-target-group \
  --name usms-enrolment-tg-green \
  --protocol HTTP --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-port traffic-port \
  --health-check-path / \
  --matcher HttpCode=200 \
  --tags Key=Project,Value=USMS Key=Lab,Value=12 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "green TG: $GREEN_TG_ARN"

PROD_LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)

TEST_LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 8080 \
  --default-actions Type=forward,TargetGroupArn="$GREEN_TG_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)

printf 'prod listener: %s\ntest listener: %s\n' "$PROD_LISTENER_ARN" "$TEST_LISTENER_ARN"

aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Proto:Protocol,TG:DefaultActions[0].TargetGroupArn}' --output table
```
![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-04-48.png>)

> On real AWS the ALB's security group must also allow inbound 8080 (from your own IP only, since it is a test route).

Substitute the placeholders (in place):

```bash
python3 - "$PROD_LISTENER_ARN" "$TEST_LISTENER_ARN" << 'PY'
import json, sys
path = "templates/lab-12-codedeploy-deployment-group.json"
prod, test = sys.argv[1], sys.argv[2]
assert prod.startswith("arn:") and test.startswith("arn:"), "listener ARNs missing"
d = json.load(open(path))
pair = d["loadBalancerInfo"]["targetGroupPairInfoList"][0]
pair["prodTrafficRoute"]["listenerArns"] = [prod]
pair["testTrafficRoute"]["listenerArns"] = [test]
json.dump(d, open(path, "w"), indent=2)
print("substituted both listener ARNs")
PY

python3 -m json.tool templates/lab-12-codedeploy-deployment-group.json > /dev/null && echo "valid JSON"
grep -c '<' templates/lab-12-codedeploy-deployment-group.json   # must be 0
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-05-20.png>)

**Outcome:** two target groups, two listeners, and a deployment group document with no placeholders that an account with CodeDeploy would accept (after also creating `usms-codedeploy-role` and the application).

---

### Exercise 4 - Challenge: close the hole in the pipeline policy

**The most damaging thing a compromised pipeline role could do with v2:**
The role may call `ecs:RegisterTaskDefinition` on `*` and pass `usms-ecs-task-role` to `ecs-tasks.amazonaws.com`. An attacker holding it can describe the current enrolment revision, register a new one that keeps the same roles but swaps the image for one they control (any public registry) or overrides `command`/`environment`, then call `ecs:UpdateService` on `usms-enrolment-svc`, which the policy explicitly allows. The service then runs attacker code **as `usms-ecs-task-role`**, which carries `USMSStudentDataReadWrite`, so the attacker can read, alter or delete every object in `usms-student-data` and exfiltrate it through the task's network. The PassRole statement limits *which* roles can be handed over, but not *what the task does* with them.

**Can IAM close it?** Largely no. The dangerous content is inside the task-definition document (image, command, environment), and I am not aware of an IAM condition key for `RegisterTaskDefinition` that constrains the image registry or command. The AWS reference lists the condition keys available for the action. [Amazon ECS Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html) Tightening the resource ARN or removing `ListTaskDefinitions` does not change the attack.

**Where the control belongs instead:**
1. **Least privilege on the task role**: the enrolment service should not need write access to student records; a read-only or narrower role limits the blast radius. This is an IAM change, but to the *task role*, not the pipeline policy.
2. **Protect the pipeline's inputs**: the attack needs the pipeline role; restrict who can modify the buildspec, the source bucket and the pipeline definition, and require review.
3. **Image provenance**: only deploy images from `usms-enrolment` that are signed and scanned (ECR signing + an admission check, or a pre-deploy step that rejects non-ECR `imageUri`s in `imagedefinitions.json`).
4. **Manual approval before Deploy** plus **detection**: CloudTrail alerts / an AWS Config rule on `RegisterTaskDefinition` events whose image is outside the approved repository.

**Optional v3 (only if I can prove it):** if I find a documented condition key that constrains the action, add it, respecting the 5-version limit:

```bash
POL=arn:aws:iam::000000000000:policy/USMSCodePipelineBase
aws iam list-policy-versions --policy-arn "$POL" \
  --query 'Versions[].{V:VersionId,Default:IsDefaultVersion}' --output table
# if 5 versions exist, delete the oldest NON-default one first, e.g.:
# aws iam delete-policy-version --policy-arn "$POL" --version-id v1

# after writing policies/usms-codepipeline-policy-v3.json:
python3 -m json.tool policies/usms-codepipeline-policy-v3.json >/dev/null && echo "valid JSON"
aws iam create-policy-version --policy-arn "$POL" \
  --policy-document file://policies/usms-codepipeline-policy-v3.json --set-as-default
# prove the pipeline still works
aws codepipeline start-pipeline-execution --name usms-enrolment-pipeline \
  --query 'pipelineExecutionId' --output text
```

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-06-08.png>)

**My conclusion:** I would validate the task definition before deployment and require an approved ECR image pinned by digest. The ECS authorization reference lists condition keys for settings such as CPU, memory, and privileged mode. Image registry and container command restrictions need a separate validation step. I have no tested v3 policy to report.

---

### Exercise 5 - Integration: prove a release end to end, for an auditor

Generate `outputs/lab-12-release-evidence.md` where every value comes from a command shown beside its output:

~~~bash
cd ~/aws-floci-course
PIPE=usms-enrolment-pipeline
EXEC=$(sed -n 's/^execution *: //p' outputs/lab-12-deploy-evidence.txt)
TD_AFTER=$(sed -n 's/^task def after *: //p' outputs/lab-12-deploy-evidence.txt)
OUT=outputs/lab-12-release-evidence.md

run() {   # print the command, then its real output, as a markdown block
  printf '\n```bash\n$ %s\n' "$*" >> "$OUT"
  eval "$@" >> "$OUT" 2>&1
  printf '```\n' >> "$OUT"
}

printf '# Release evidence: r7\n\nGenerated %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT"

printf '\n## 1. S3 version of the source archive\n' >> "$OUT"
run "aws s3api list-object-versions --bucket usms-pipeline-artifacts --prefix source/usms-enrolment-src.zip --query 'Versions[].{VersionId:VersionId,Latest:IsLatest,Modified:LastModified}' --output table"

printf '\n## 2. Pipeline execution and the source revision it consumed\n' >> "$OUT"
run "aws codepipeline get-pipeline-execution --pipeline-name $PIPE --pipeline-execution-id $EXEC --query 'pipelineExecution.{Id:pipelineExecutionId,Status:status,Revisions:artifactRevisions}' --output json"

printf '\n## 3. Build ID\n' >> "$OUT"
run "aws codepipeline list-action-executions --pipeline-name $PIPE --filter pipelineExecutionId=$EXEC --query 'actionExecutionDetails[].{Stage:stageName,Action:actionName,Status:status,ExternalId:output.executionResult.externalExecutionId}' --output table"

printf '\n## 4. Image digest for r7\n' >> "$OUT"
run "aws ecr describe-images --repository-name usms-enrolment --image-ids imageTag=r7 --query 'imageDetails[0].{Tags:imageTags,Digest:imageDigest,Pushed:imagePushedAt}' --output json"

printf '\n## 5. Task definition revision registered by that execution\n' >> "$OUT"
run "aws ecs describe-task-definition --task-definition $TD_AFTER --query 'taskDefinition.{Arn:taskDefinitionArn,Image:containerDefinitions[0].image,Registered:registeredAt}' --output json"

printf '\n## 6. Service current task definition\n' >> "$OUT"
run "aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].taskDefinition' --output text"

sed -n '1,200p' "$OUT"
~~~

> If the build stage output is empty on Floci, record that the build ID could not be recovered from the execution and state this as a gap.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-06-39.png>)

**Break one link - retag r7 to a different image (do not deploy):**

~~~bash
docker pull "$ECR_URI:r6"
docker tag  "$ECR_URI:r6" "$ECR_URI:r7"
docker push "$ECR_URI:r7"

NEW_DIGEST=$(aws ecr describe-images --repository-name usms-enrolment --image-ids imageTag=r7 \
  --query 'imageDetails[0].imageDigest' --output text)
printf '%s %s %s\n' r7 "$NEW_DIGEST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a outputs/lab-12-image-digest.txt
cat outputs/lab-12-image-digest.txt

aws ecr describe-images --repository-name usms-enrolment \
  --query 'imageDetails[].{Tags:imageTags,Digest:imageDigest}' --output table

printf '\n## 7. After retagging r7\n' >> outputs/lab-12-release-evidence.md
run "aws ecr describe-images --repository-name usms-enrolment --query 'imageDetails[].{Tags:imageTags,Digest:imageDigest}' --output table"
~~~

> Note: `run` and `OUT` must still be defined (same terminal as above). Afterwards, restore r7 if needed by rebuilding it from `VERSION=r7`, and do not deploy the retagged image.

![alt text](<../../screenshots_lab-10_to_lab-13/Screenshot from 2026-11-24 00-07-02.png>)

**What the document can and cannot still prove:** It still proves which source version the execution consumed, which build ran, and that revision `:4` names `usms-enrolment:r7`. It can no longer prove **which bytes ran**: the task definition names a tag, and the tag now resolves to a different digest than the one recorded at build time. Any task started after the retag (a scale-out or a restart) would pull the r6 bytes while every record still says "r7". Only the digest ledger, written at push time, preserves the original mapping, which is why a task definition that pins `repo@sha256:…` (or an immutable repository) is needed for the chain to hold.
