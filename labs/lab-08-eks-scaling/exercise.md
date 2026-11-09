# Lab 08 - Independent Exercises

### Exercise 1 - Basic: a second autoscaler for `usms-results`

**Requirements:** min 2, max 6, target 60% CPU, scale-in window 180s,
scale-up policy adding at most 2 pods per 30s.

**`manifests/lab-08/11-hpa-results.yaml`:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: usms-results-hpa
  namespace: usms
  labels:
    app: usms-results
    project: usms
    lab: "05b"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: usms-results
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
        - type: Pods
          value: 2
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 180
      selectPolicy: Min
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
```

```bash
kubectl get deploy usms-results -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'; echo
kubectl apply --dry-run=client -f manifests/lab-08/11-hpa-results.yaml
kubectl apply -f manifests/lab-08/11-hpa-results.yaml
kubectl get hpa
```

> **Why 60% for a read-mostly service, vs 50% for enrolment?**
> `usms-results` is read-mostly: its requests are short, cheap and steady, so each pod can safely run hotter (60%) before another replica is added. `usms-enrolment` is write-heavy and spikes hard in registration week, so 50% leaves more headroom to absorb a burst while new pods are still starting.

![alt text](<../../screenshots/Screenshot from 2026-11-09 11-40-00.png>)

---

### Exercise 2 - Intermediate: make the gateway drainable

**Requirements:** `usms-gateway-pdb` (`minAvailable: 1`, unchanged) must allow
at least 1 disruption; do this by spreading/scaling the gateway, not by
weakening the PDB.

```bash
kubectl scale deployment/usms-gateway --replicas=2
kubectl rollout status deployment/usms-gateway --timeout=120s
kubectl get pdb usms-gateway-pdb
kubectl get pods -l app=usms-gateway -o wide
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-40-57.png>)

**Update the manifest so the repository matches the cluster, then confirm
no drift:**

```bash
sed -i.bak 's/^  replicas: 1$/  replicas: 2/' manifests/lab-07/40-gateway.yaml
kubectl diff -f manifests/lab-07/40-gateway.yaml || true
rm -f manifests/lab-07/*.bak
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-41-31.png>)

> **If the cluster has only one node:**
> With one node, both gateway replicas sit on the same node, so spreading them is impossible. A drain would evict one pod, its replacement would stay `Pending` on the cordoned node, and the drain would then block on the PDB. I would first add a second node (raise the node group's `desiredSize` to 2 as in Step 10), then add a `topologySpreadConstraint` (or pod anti-affinity) on `kubernetes.io/hostname` so the two replicas land on different nodes. I would not weaken the PDB.

---

### Exercise 3 - Problem solving: the autoscaler that will not act

**Given manifest (apply exactly as-is) — `manifests/lab-08/70-reports-broken.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-reports
  namespace: usms
spec:
  replicas: 2
  selector:
    matchLabels:
      app: usms-reports
  template:
    metadata:
      labels:
        app: usms-reports
    spec:
      containers:
        - name: reports
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
          resources:
            limits:
              cpu: "200m"
              memory: "128Mi"
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: usms-reports-hpa
  namespace: usms
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: usms-reports
  minReplicas: 4
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

```bash
# manifest above saved as manifests/lab-08/70-reports-broken.yaml
kubectl apply -f manifests/lab-08/70-reports-broken.yaml

kubectl get hpa usms-reports-hpa
kubectl describe hpa usms-reports-hpa | sed -n '/Conditions/,/Events/p'
kubectl get deploy usms-reports -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-45-17.png>)

**Diagnosis:**

| Fault | Evidence command | Effect | Fix (single field) |
|---|---|---|---|
| No CPU **request** declared (only a limit) | `describe hpa` → `FailedGetResourceMetric` / `missing request for cpu` | HPA reports `<unknown>`, never computes | Add `resources.requests.cpu` to the container |
| `minReplicas == maxReplicas == 4` | `get hpa` → `MINPODS`/`MAXPODS` both 4 | HPA has no room to move even with metrics | Raise `maxReplicas` above `minReplicas` |

```bash
kubectl set resources deployment/usms-reports --requests=cpu=50m
kubectl patch hpa usms-reports-hpa --type=merge -p '{"spec":{"maxReplicas":8}}'
kubectl get hpa usms-reports-hpa
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-46-01.png>)

**Cleanup:**

```bash
kubectl delete deployment,hpa usms-reports usms-reports-hpa --ignore-not-found
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-46-13.png>)

---

### Exercise 4 Challenge: expose the results service properly

**Brief:** Reachable at a stable address, normal HTTP port, its own path, no
second `LoadBalancer` Service, no second load balancer cost.

**Design (prose, ~half a page) - write in `labs/lab-08-eks-scaling/exercises.md`:**

**Rungs.** `usms-results` itself stays a plain **ClusterIP** Service (rung 1); nothing about the backend needs to be public. It is exposed at **rung 4, Ingress**: a `/results` path on the *existing* `usms-portal-ingress`. On real EKS the AWS Load Balancer Controller turns that into a listener rule on the **same ALB** the portal already uses. The stable address is that ALB's DNS name (with a Route 53 alias such as `portal.usms.example/results`) on port 80, or 443 with an ACM certificate via `alb.ingress.kubernetes.io/certificate-arn`. The `usms-results-np` NodePort from Step 14 should be deleted: port 30080 is not a normal HTTP port, and node IPs change whenever nodes are replaced, so it is not a stable address.

**Why no second LoadBalancer.** Every `type: LoadBalancer` Service gets its *own* NLB, with its own DNS name and hourly + LCU charges. It cannot route by path either, so it would just be a second front door beside the gateway's.

**Cost.** One more rule on an existing ALB costs nothing extra beyond the traffic (LCUs). An ALB allows up to 100 rules, and with `alb.ingress.kubernetes.io/group.name` even separate Ingress objects can share the one ALB. Ten services cost one ALB, not ten load balancers.

**Failure mode if the cluster is unavailable.** The ALB is an AWS object outside the cluster, so it keeps forwarding to the pod IPs already registered, and traffic continues while those pods run. The controller can no longer update the target group, though. If pods are rescheduled or the nodes are lost, the ALB holds stale targets, health checks fail, and users see 502/503 until the cluster is back.

**Is the existing `/results` rule the answer?** It is a **starting point**, the right shape but not finished. `pathType: Prefix` forwards `/results/...` *unchanged* and an ALB cannot rewrite paths, so the results app must serve under `/results`. The `healthcheck-path: /healthz` annotation is Ingress-wide, so it needs a per-Service override if results uses a different path. A "proper" version also needs a host rule and TLS on 443. Finally, I need to decide whether the gateway should *also* route `/results`; review question 6 argues there should be only one path.

---

### Exercise 5 - Integration: artefacts for Lab 10

**Part 1 - `outputs/lab-08-scaling-evidence.json`:**

```bash
python3 - << 'PY'
import json, subprocess, datetime

def kj(args):
    out = subprocess.run(["kubectl"] + args + ["-o", "json"], capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None

def aj(args):
    out = subprocess.run(["aws"] + args + ["--output", "json"], capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None

hpa = kj(["get", "hpa", "usms-enrolment-hpa", "-n", "usms"])
deploy = kj(["get", "deploy", "usms-enrolment", "-n", "usms"])
nodegroup = aj(["eks", "describe-nodegroup", "--cluster-name", "usms-eks-cluster",
                "--nodegroup-name", "usms-eks-nodes"])

evidence = {
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "hpa_spec": hpa["spec"] if hpa else "UNAVAILABLE",
    "hpa_status": hpa["status"] if hpa else "UNAVAILABLE",
    "deployment_replicas": deploy["status"].get("replicas") if deploy else "UNAVAILABLE",
    "nodegroup_scaling_config": nodegroup["nodegroup"]["scalingConfig"] if nodegroup else "UNAVAILABLE (Path B)",
}

with open("outputs/lab-08-scaling-evidence.json", "w") as f:
    json.dump(evidence, f, indent=2)

print("written outputs/lab-08-scaling-evidence.json")
PY

python3 -m json.tool outputs/lab-08-scaling-evidence.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-50-14.png>)

**Part 2 - `outputs/lab-08-lab06-readiness.txt`:**

```bash
POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)

{
  echo "=== Lab 10 readiness, generated $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "Policy ARN: $POLICY_ARN"
  echo "--- Roles carrying it ---"
  aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyRoles[].RoleName' --output text
  echo "--- Bucket named in the Resource field ---"
  aws iam get-policy-version \
    --policy-arn "$POLICY_ARN" \
    --version-id "$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)" \
    --query 'PolicyVersion.Document.Statement[0].Resource' --output text
  echo "--- Does the bucket exist yet? ---"
  aws s3api head-bucket --bucket usms-student-data 2>&1 || echo "not yet created (expected before Lab 10)"
  echo "--- ServiceAccount that would carry the IRSA annotation ---"
  kubectl get sa usms-enrolment-sa -n usms -o yaml 2>/dev/null | grep -A2 annotations || echo "no IRSA annotation present yet"
  echo "would be: eks.amazonaws.com/role-arn: <ARN of a role trusting the EKS OIDC provider>"
} | tee outputs/lab-08-lab06-readiness.txt
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-51-15.png>)

**Part 3 - "ECS or Kubernetes for USMS" (≤400 words, appended to `notes/lab-08-notes.md`, citing ≥3 specific observations):**

**ECS or Kubernetes for USMS? ECS.**

Three observations from Labs 05-08 decide it for me.

1. **Scaling needed more moving parts on EKS.** In Lab 06 one `put-scaling-policy` call (target 50%, `ScaleInCooldown` 300) created its own CloudWatch alarms and needed nothing else. Here the HPA only works if metrics-server is running *and* every container declares a CPU request. Exercise 3's `usms-reports` shows that one missing `requests.cpu` leaves the HPA at `<unknown>` and inert. On top of that, the HPA can only add pods: when the nodes fill up, pods sit `Pending` until someone runs `update-nodegroup-config` (Step 10) or installs a Cluster Autoscaler/Karpenter, which needs IRSA and was not possible on this build. ECS on Fargate has no nodes to run out of.

2. **Exposure is tidier in Kubernetes but depends on a controller.** Lab 05 took separate `elbv2` calls for the ALB, target group (`--target-type ip`), listener and a rule at priority 10. The Step 16 Ingress declares the same thing in one object with path-based precedence, which is clearly nicer. But it only does anything if an ingress controller is installed. On this local build the `alb.ingress.kubernetes.io/*` annotations were inert, so that is one more component for a small team to install, upgrade and debug.

3. **More objects to keep in sync.** This lab alone added an HPA, two PDBs, a NodePort, a LoadBalancer Service, an Ingress and a `nodeSelector`. Each one had to be copied back into `manifests/` to avoid the drift shown in Step 5. Exercise 2 showed that a PDB on a single-replica gateway quietly blocks a node drain.

For a small team in one region, with load that is quiet for eight months and busy for two, those costs buy little. Kubernetes' real advantages are the 15-second HPA loop with a `behavior` block, portable manifests, and one ALB for many services through Ingress. They would matter for a bigger platform team or a multi-cloud requirement. For USMS today, ECS with target tracking does the job with fewer ways to fail.

