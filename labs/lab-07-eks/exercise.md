## Independent Lab Exercises

### Exercise 1 — Basic: a fourth microservice

Deploy `usms-timetable`: one replica, `nginx:1.27-alpine`, its own ConfigMap, readiness probe on `/healthz`, ClusterIP Service on port 80. Single file: `manifests/lab-07/70-timetable.yaml`. Labels: `app`, `project`, `tier`. CPU/memory requests declared.

```bash
# manifest command goes here — copy the structure of 30-results.yaml
kubectl apply --dry-run=client -f manifests/lab-07/70-timetable.yaml
kubectl apply -f manifests/lab-07/70-timetable.yaml
kubectl get deploy,svc -n usms
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 22-16-30.png>)

---

### Exercise 2 — Intermediate: route to it, and prove the route

Add a `/timetable/` route to `usms-gateway`, re-apply, and prove all three routes still work with one command.

```bash
# edit manifests/lab-07/40-gateway.yaml to add the /timetable/ location block
kubectl apply -f manifests/lab-07/40-gateway.yaml
kubectl rollout restart deployment/usms-gateway
kubectl rollout status deployment/usms-gateway --timeout=120s

kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  G=http://usms-gateway.usms.svc.cluster.local
  wget -qO- $G/enrolment/; wget -qO- $G/results/; wget -qO- $G/timetable/
'

kubectl rollout history deployment/usms-gateway
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 22-17-14.png>)

---

### Exercise 3 — Problem solving: find the misconfiguration

```bash
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-broken
  namespace: usms
spec:
  replicas: 2
  selector:
    matchLabels:
      app: usms-broken
  template:
    metadata:
      labels:
        app: usms-broken
        version: v1
    spec:
      containers:
        - name: broken
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: usms-broken
  namespace: usms
spec:
  selector:
    app: usms-broken
    version: v2
  ports:
    - port: 80
      targetPort: http
EOF
```

**Diagnostic commands used (in order):**

```bash
kubectl get endpoints usms-broken -n usms
kubectl describe pod -l app=usms-broken -n usms | tail -20
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 22-18-35.png>)

**Diagnosis (two independent faults):**

> 1. _[Service selector `version: v2` does not match pod label `version: v1` → no endpoints]_
> 2. _[base nginx image has no `/healthz` path → readiness probe fails → 0/1 Ready]_

**Fix (minimal, one line each):**

```bash
kubectl -n usms patch deployment usms-broken --type=json \
  -p '[{"op":"replace","path":"/spec/template/metadata/labels/version","value":"v2"}]'
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 22-19-01.png>)

```bash
kubectl -n usms patch deployment usms-broken --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 22-41-22.png>)

**Verify fix:**

```bash
kubectl get endpoints usms-broken -n usms
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 22-41-33.png>)

**Cleanup:**

```bash
kubectl delete deployment,service usms-broken -n usms
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 22-59-35.png>)

---

### Exercise 4 — Challenge: survive a node going away

Update `usms-enrolment` so it tolerates a node loss: never all pods on one node, never below one healthy pod during a voluntary disruption, and pod→node mapping always readable from the cluster.

**Objects to add:** `topologySpreadConstraints` and/or `podAntiAffinity`, and a `PodDisruptionBudget`.

```yaml
# added to manifests/lab-07/20-enrolment.yaml spec.template.spec
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: usms-enrolment
```

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: usms-enrolment-pdb
  namespace: usms
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: usms-enrolment
```

**Apply and demonstrate:**

```bash
kubectl apply -f manifests/lab-07/20-enrolment.yaml
kubectl get pods -n usms -l app=usms-enrolment -o wide

kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 23-01-21.png>)

---

### Exercise 5 — Integration: prepare what Lab 08 needs

**Part 1 — baseline CPU:**

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1 2>&1 | head -5
kubectl top pods -n usms 2>&1 | tee outputs/lab-07-cpu-baseline.txt
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 23-02-31.png>)

**Part 2 — trace Lab 01's policy:**

```bash
S3_RW_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)

VERSION_ID=$(aws iam get-policy --policy-arn "$S3_RW_ARN" --query 'Policy.DefaultVersionId' --output text)

{
  echo "Policy ARN: $S3_RW_ARN"
  echo "Holders:"
  aws iam list-entities-for-policy --policy-arn "$S3_RW_ARN" --query 'PolicyRoles[].RoleName' --output text
  echo "Resource (bucket ARN) from policy document:"
  aws iam get-policy-version --policy-arn "$S3_RW_ARN" --version-id "$VERSION_ID" \
    --query 'PolicyVersion.Document.Statement[].Resource' --output text
} | tee outputs/lab-07-lab06-readiness.txt

BUCKET=$(aws iam get-policy-version --policy-arn "$S3_RW_ARN" --version-id "$VERSION_ID" \
  --query 'PolicyVersion.Document.Statement[0].Resource' --output text | cut -d: -f6 | cut -d/ -f1)
aws s3api head-bucket --bucket "$BUCKET" 2>&1 || echo "bucket does not exist yet (expected — Lab 10 creates it)"
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 23-02-55.png>)

**Part 3 — readiness note (append to notes/lab-07-notes.md):**

```bash
cat >> notes/lab-07-notes.md << 'EOF'

## Exercise 5 Part 3 - Lab 08 readiness

Variables from configs/lab-07.env that Lab 08 will need:
- USMS_EKS_CLUSTER: every aws eks call
- USMS_EKS_LB_PORTS: LoadBalancer Service exposure
- USMS_K8S_DEPLOY_ENROLMENT: HPA target
- USMS_K8S_CPU_REQUEST: checking HPA arithmetic
EOF
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 23-03-14.png>)