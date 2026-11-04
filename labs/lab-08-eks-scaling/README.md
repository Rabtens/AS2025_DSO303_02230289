# DSO303 – Lab 08: EKS Scaling and Service Exposure
### Practical 4 (Part 2) – Making the Cluster Grow, and Letting the World In

**Name:** Kuenzang
**Institution:** College of Science and Technology (CST), Bhutan
**Module:** DSO303 – Scaling, Orchestration, Monitoring & Observability
**Lab:** Lab 08 – EKS Scaling and Service Exposure
**Date:** _fill in submission date_

---

## Table of Contents

1. [Lab Overview](#1-lab-overview)
2. [Learning Objectives](#2-learning-objectives)
3. [Prerequisites Check](#3-prerequisites-check)
4. [Environment Setup](#4-environment-setup)
5. [Step 1 – Start the Environment & Verify Lab 07 Dependencies](#step-1)
6. [Step 2 – Baseline Snapshot](#step-2)
7. [Step 3 – The Four Dimensions of Scaling](#step-3)
8. [Step 4 – Scale by Hand](#step-4)
9. [Step 5 – Scale Declaratively & Configuration Drift](#step-5)
10. [Step 6 – Requests, Limits and QoS Classes](#step-6)
11. [Step 7 – The Metrics Pipeline](#step-7)
12. [Step 8 – Create the HorizontalPodAutoscaler](#step-8)
13. [Step 9 – Generate Load and Watch It Respond](#step-9)
14. [Step 10 – Scale the Data Plane from the AWS Side](#step-10)
15. [Step 11 – Cluster Autoscaler, Karpenter & nodeSelector](#step-11)
16. [Step 12 – PodDisruptionBudget](#step-12)
17. [Step 13 – Rung 1: ClusterIP and port-forward](#step-13)
18. [Step 14 – Rung 2: NodePort](#step-14)
19. [Step 15 – Rung 3: LoadBalancer](#step-15)
20. [Step 16 – Rung 4: Ingress](#step-16)
21. [Step 17 – Practical 2 vs Practical 4 Comparison](#step-17)
22. [Step 18 – Persistence Check](#step-18)
23. [Step 19 – Write configs/lab-08.env](#step-19)
24. [Step 20 – Commit Work](#step-20)
25. [Verification Script](#25-verification-script)
26. [Independent Exercises](#26-independent-exercises)
27. [Review Questions](#27-review-questions)
28. [Cleanup](#28-cleanup)
29. [Reflection](#29-reflection)

---

## 1. Lab Overview

This lab picks up where Lab 07 left off. In Lab 07, the USMS application (three
microservices — `usms-gateway`, `usms-enrolment`, `usms-results`) was deployed to
EKS and made discoverable *inside* the cluster, but nothing was reachable from
outside it. Lab 08 answers two questions:

```
HOW DOES IT GROW?          replicas -> HorizontalPodAutoscaler -> node group -> cluster autoscaler
HOW DOES ANYONE REACH IT?  ClusterIP -> port-forward -> NodePort -> LoadBalancer -> Ingress
```

Both are ladders — each rung is built on the rung below it and adds exactly one
capability. The central idea of this lab is that **scaling is one integer**:
`Lab 06` had Application Auto Scaling write `desiredCount` from *outside* the
workload; here the HorizontalPodAutoscaler writes `replicas` from *inside* the
cluster.

> **Note on numbering:** the module descriptor numbers this practical 3; the
> course delivers it as Practical 4 (second document). Lab 07 → EKS setup,
> Lab 08 → EKS scaling and exposure (this lab).

---

## 2. Learning Objectives

By the end of this lab I will be able to:

- [ ] Name the four independent dimensions along which a Kubernetes workload scales, and which object controls each.
- [ ] Scale a Deployment imperatively and declaratively, and explain the resulting configuration drift.
- [ ] Explain how a HorizontalPodAutoscaler computes utilisation, and why a missing resource request makes it inert.
- [ ] Deploy an `autoscaling/v2` HPA with an explicit `behavior` block, mapped to its Lab 06 equivalent.
- [ ] Generate load against a service and observe an autoscaler responding — or diagnose why it did not.
- [ ] Change a managed node group's scaling configuration from the AWS CLI.
- [ ] Distinguish the Cluster Autoscaler and Karpenter from the HorizontalPodAutoscaler.
- [ ] Write a PodDisruptionBudget and state what it does and does not protect against.
- [ ] Expose a Service four different ways — port-forward, NodePort, LoadBalancer, Ingress.
- [ ] Compare Kubernetes Ingress with the Application Load Balancer of Lab 05.
- [ ] Prove that scaling and exposure configuration survive a restart of the emulator.

---

## 3. Prerequisites Check

| Prerequisite | Required | Status |
|---|---|---|
| Lab 07 complete, `configs/lab-07.env` populated | ✅ | ☐ |
| `verify-lab-07.sh` passing (FAIL=0 Path A / FAIL=3 Path B) | ✅ | ☐ |
| `usms-enrolment` declares CPU request `50m` | ✅ | ☐ |
| Cluster tagged `_lb_ports_=8081,8082` | ✅ | ☐ |
| kubectl, AWS CLI v2 installed | ✅ | ☐ |

**Tool versions:**

```bash
kubectl version --client
aws --version
```

📸 **Screenshot 3.1** – *tool version output*
```
[ SPACE FOR SCREENSHOT ]
```

---

## 4. Environment Setup

```bash
mkdir -p labs/lab-08-eks-scaling manifests/lab-08
ls -d manifests/*
```

**Expected:**
```
manifests/lab-07  manifests/lab-08
```

📸 **Screenshot 4.1** – *directory structure created*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-1"></a>
## Step 1 – Start the Environment & Verify Lab 07 Dependencies

**Purpose:** Two values from Lab 07 determine whether this lab can be done at
all — the enrolment service's CPU request (the HPA's denominator) and the
`_lb_ports_` cluster tag.

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-04.env
source configs/lab-07.env

./scripts/utilities/whoami.sh
kubectl config current-context
kubectl config set-context --current --namespace=usms
```

```bash
echo "--- 1. does usms-enrolment declare a CPU request? ---"
kubectl get deploy usms-enrolment \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'; echo

echo "--- 2. is the _lb_ports_ tag on the cluster? ---"
echo "from configs/lab-07.env : ${USMS_EKS_LB_PORTS:-EMPTY}"
aws eks describe-cluster --name "$USMS_EKS_CLUSTER" \
  --query 'cluster.tags._lb_ports_' --output text 2>/dev/null || echo "eks API unavailable (Path B)"
```

**Expected:**
```
--- 1. does usms-enrolment declare a CPU request? ---
{"cpu":"50m","memory":"32Mi"}
--- 2. is the _lb_ports_ tag on the cluster? ---
from configs/lab-07.env : 8081,8082
8081,8082
```

**If the CPU request is missing, fix it:**

```bash
kubectl set resources deployment/usms-enrolment \
  --requests=cpu=50m,memory=32Mi --limits=cpu=200m,memory=128Mi
kubectl rollout status deployment/usms-enrolment --timeout=120s
```

**Verify:**

```bash
./scripts/utilities/verify-lab-07.sh | tail -3
kubectl get deploy,svc,cm,secret
```

📸 **Screenshot Step 1.1** – *the two-checks output (CPU request + tag)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 1.2** – *verify-lab-07.sh tail + get deploy,svc,cm,secret*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 1**
```
Baseline recorded in outputs/lab-08-baseline.txt
 ├── usms-enrolment  2/2   cpu request 50m   <- the HPA's denominator exists
 ├── usms-results    2/2
 ├── usms-gateway    1/1
 ├── all three Services ClusterIP, no external address
 └── cluster tag _lb_ports_ = 8081,8082  (or its absence recorded)
```

---

<a name="step-2"></a>
## Step 2 – Baseline Snapshot

**Purpose:** Capture a "before" snapshot so later numbers have something to
compare against.

```bash
mkdir -p notes outputs

echo "--- Lab 07 Exercise 5 artefacts ---"
ls -l outputs/lab-07-cpu-baseline.txt outputs/lab-07-lab06-readiness.txt 2>/dev/null \
  || echo "Exercise 5 not done - do it before Lab 10"

echo
echo "--- fresh baseline ---"
{
  echo "=== LAB 08 BASELINE $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  kubectl get deploy -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas'
  echo "--- endpoints ---"
  kubectl get endpoints
  echo "--- service types ---"
  kubectl get svc -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,CLUSTERIP:.spec.clusterIP,EXTERNAL:.status.loadBalancer.ingress[0].ip'
  echo "--- nodes ---"
  kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,CPU:.status.capacity.cpu,MEM:.status.capacity.memory'
} | tee outputs/lab-08-baseline.txt
```

📸 **Screenshot Step 2.1** – *baseline output (`outputs/lab-08-baseline.txt`)*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 2** — three Deployments at Lab 07 counts, all Services `ClusterIP`
with `<none>` external, at least one node `Ready`.

---

<a name="step-3"></a>
## Step 3 – The Four Dimensions of Scaling

**Purpose:** Before moving any number, know which of four independent things
is being moved.

```
1. HORIZONTAL, workload        more PODS of the same size
   object: Deployment.spec.replicas
   moved by: you, or a HorizontalPodAutoscaler
   limit: how much room the nodes have

2. VERTICAL, workload          BIGGER pods
   object: container.resources.requests / .limits
   moved by: you, or a VerticalPodAutoscaler (not installed here)
   limit: the largest node — a pod cannot be bigger than a node
   note: changing it restarts the pod

3. HORIZONTAL, infrastructure   more NODES
   object: node group's scalingConfig.desiredSize
   moved by: you (Step 10), or a Cluster Autoscaler / Karpenter (Step 11)
   limit: maxSize, quota, budget

4. VERTICAL, infrastructure     BIGGER nodes
   object: node group's instanceTypes
   moved by: you, by creating a NEW node group and draining the old one
   limit: not changeable in place
```

### ✏️ My turn – written answer

> `usms-enrolment` needs to handle ten times its current traffic. Walk through
> the four dimensions and say which you would use, in which order, and what
> you would check between each.

```
[ WRITE YOUR 3–4 SENTENCE ANSWER HERE IN notes/lab-08-notes.md ]
```

---

<a name="step-4"></a>
## Step 4 – Scale by Hand

**Purpose:** The simplest rung of the ladder — everything the HPA does in
Step 8, it does by performing this same operation.

**Terminal 2 – watcher (leave running):**

```bash
kubectl get pods -w -l app=usms-enrolment
```

**Terminal 1 – scale up:**

```bash
kubectl scale deployment/usms-enrolment --replicas=5
kubectl rollout status deployment/usms-enrolment --timeout=120s

kubectl get deploy usms-enrolment
kubectl get endpoints usms-enrolment
```

**Confirm traffic spreads across five pods:**

```bash
kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  for i in $(seq 1 40); do
    wget -qO- http://usms-gateway.usms.svc.cluster.local/enrolment/
  done
' | grep -o '"pod":"[^"]*"' | sort | uniq -c | sort -rn
```

**Scale back down:**

```bash
kubectl scale deployment/usms-enrolment --replicas=2
kubectl rollout status deployment/usms-enrolment --timeout=120s
kubectl get endpoints usms-enrolment
```

Stop the watcher with `Ctrl+C`.

📸 **Screenshot Step 4.1** – *pod watcher showing scale-up to 5*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 4.2** – *unique pod count from the 40-request loop*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 4.3** – *scale-down / pods Terminating in watcher*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-5"></a>
## Step 5 – Scale Declaratively & Configuration Drift

**Purpose:** Show what it costs when the cluster and the repository disagree.

**Create drift:**

```bash
kubectl scale deployment/usms-enrolment --replicas=6
kubectl get deploy usms-enrolment -o jsonpath='{.spec.replicas}'; echo
grep -n 'replicas:' manifests/lab-07/20-enrolment.yaml
```

**Watch apply silently undo it:**

```bash
kubectl apply -f manifests/lab-07/20-enrolment.yaml
sleep 5
kubectl get deploy usms-enrolment -o jsonpath='{.spec.replicas}'; echo
```

**The habit that prevents it — `kubectl diff`:**

```bash
sed -i.bak 's/^  replicas: 2$/  replicas: 3/' manifests/lab-07/20-enrolment.yaml

kubectl diff -f manifests/lab-07/20-enrolment.yaml || true

kubectl apply -f manifests/lab-07/20-enrolment.yaml
kubectl get deploy usms-enrolment -o jsonpath='{.spec.replicas}'; echo
```

**Restore baseline:**

```bash
sed -i.bak 's/^  replicas: 3$/  replicas: 2/' manifests/lab-07/20-enrolment.yaml
kubectl apply -f manifests/lab-07/20-enrolment.yaml
kubectl rollout status deployment/usms-enrolment --timeout=120s
rm -f manifests/lab-07/*.bak
kubectl get deploy
```

📸 **Screenshot Step 5.1** – *drift: cluster=6, file=2*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 5.2** – *apply silently reverting to 2*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 5.3** – *`kubectl diff` output (exit code 1)*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 2**
```
Scaling, by hand and by file
 ├── kubectl scale writes ONE field; no new ReplicaSet
 ├── endpoints grow only when pods become READY, not when they start
 ├── scale-in removes from endpoints BEFORE SIGTERM
 ├── drift demonstrated: cluster 6, file 2, apply wins
 └── kubectl diff exits 1 on a difference - a feature, not a failure
 usms-enrolment back at 2/2
```

---

<a name="step-6"></a>
## Step 6 – Requests, Limits and QoS Classes

**Purpose:** Step 8's autoscaler divides by the number set here.

**Concept:**

```
requests   what the SCHEDULER reserves
limits     what the KUBELET enforces at runtime
             CPU over limit    -> THROTTLED
             MEMORY over limit -> OOMKilled
```

| Class | When | Under pressure |
|---|---|---|
| Guaranteed | requests == limits (CPU & memory) | Evicted last |
| Burstable | requests set, < limits | Evicted after BestEffort |
| BestEffort | nothing set | Evicted first, invisible to the HPA |

**Read the classes off the cluster:**

```bash
kubectl get pods -o custom-columns=\
'NAME:.metadata.name,QOS:.status.qosClass,CPUREQ:.spec.containers[0].resources.requests.cpu,CPULIM:.spec.containers[0].resources.limits.cpu'
```

**Scheduler's arithmetic:**

```bash
NODE=$(kubectl get pods -l app=usms-enrolment -o jsonpath='{.items[0].spec.nodeName}')
echo "inspecting node: $NODE"
kubectl describe node "$NODE" | sed -n '/Allocated resources/,/Events/p'
```

**Denominator arithmetic:**

```bash
REQ=$(kubectl get deploy usms-enrolment \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
echo "request        : $REQ"
echo "HPA target 50% : this means 50% of $REQ per pod, i.e. 25m average across all pods"
echo "NOT 50% of a node, and NOT 50% of the limit"
```

### ✏️ My turn – Guaranteed QoS experiment

> Make `usms-gateway` a Guaranteed pod without changing what it can do, then
> put it back. Record the QoS class before and after.

```bash
kubectl get pod -l app=usms-gateway -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'

kubectl set resources deployment/usms-gateway --requests=cpu=100m,memory=64Mi --limits=cpu=100m,memory=64Mi
kubectl rollout status deployment/usms-gateway --timeout=120s
kubectl get pod -l app=usms-gateway -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'

# revert
kubectl set resources deployment/usms-gateway --requests=cpu=50m,memory=32Mi --limits=cpu=200m,memory=128Mi
kubectl rollout status deployment/usms-gateway --timeout=120s
kubectl get pod -l app=usms-gateway -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
```

📸 **Screenshot Step 6.1** – *QoS classes for all pods (Burstable)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 6.2** – *node "Allocated resources" table*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 6.3** – *gateway QoS: Burstable → Guaranteed → Burstable*
```
[ SPACE FOR SCREENSHOT ]
```

> **When would I want Guaranteed?**
> ```
> [ WRITE YOUR ONE-SENTENCE ANSWER HERE ]
> ```

---

<a name="step-7"></a>
## Step 7 – The Metrics Pipeline

**Purpose:** The HPA reads a metric that comes from an add-on API, not core
Kubernetes.

```
kubelet on each node
  |  exposes /metrics/resource
  v
metrics-server (kube-system)
  |  scrapes every kubelet, registers metrics.k8s.io/v1beta1
  v
API server /apis/metrics.k8s.io/v1beta1/...
  +--> kubectl top pods
  +--> HorizontalPodAutoscaler
```

**Is the API registered?**

```bash
kubectl get apiservices | grep metrics || echo "no metrics APIService registered"
kubectl get deploy -n kube-system | grep -i metrics || echo "no metrics-server deployment"
kubectl get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null 2>&1 \
  && echo "metrics API: AVAILABLE" \
  || echo "metrics API: NOT AVAILABLE"
```

**If NOT AVAILABLE, install it:**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s
```

**If certificate errors on a local cluster (lab-only fix):**

```bash
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s
```

**If no network access to install it:**

```bash
echo "metrics API unavailable - Step 9 will use the manual fallback" >> notes/lab-08-notes.md
```

**Verify:**

```bash
kubectl top nodes 2>/dev/null || echo "kubectl top nodes: unavailable"
kubectl top pods 2>/dev/null  || echo "kubectl top pods: unavailable"
```

📸 **Screenshot Step 7.1** – *metrics API registration check*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 7.2** – *`kubectl top nodes` / `kubectl top pods` output*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-8"></a>
## Step 8 – Create the HorizontalPodAutoscaler

**Purpose:** The object the whole scaling half of this lab is built around.

**Manifest — `manifests/lab-08/10-hpa-enrolment.yaml`:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: usms-enrolment-hpa
  namespace: usms
  labels:
    app: usms-enrolment
    project: usms
    lab: "05b"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: usms-enrolment
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
        - type: Pods
          value: 2
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300
      selectPolicy: Min
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
```

**Apply and verify:**

```bash
kubectl apply -f manifests/lab-08/10-hpa-enrolment.yaml

kubectl get hpa
sleep 30
kubectl get hpa
kubectl describe hpa usms-enrolment-hpa | tail -20
```

**Expected:**
```
NAME                 REFERENCE                   TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
usms-enrolment-hpa   Deployment/usms-enrolment   cpu: 2%/50%   2         8         2          32s
```

📸 **Screenshot Step 8.1** – *`kubectl apply` output for the HPA manifest*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 8.2** – *`kubectl get hpa` showing TARGETS = `<percentage>/50%`*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 8.3** – *`kubectl describe hpa` Conditions & Events block*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-9"></a>
## Step 9 – Generate Load and Watch It Respond

**Watcher script — `scripts/utilities/hpa-watch.sh`:**

```bash
cat > scripts/utilities/hpa-watch.sh << 'EOF'
#!/usr/bin/env bash
# Print the HPA and its target Deployment once every 10 seconds. Read-only.
# Usage: ./scripts/utilities/hpa-watch.sh [iterations]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
NS=usms
N="${1:-60}"

printf "%-9s %-14s %-10s %-8s %-8s\n" "TIME" "CPU/TARGET" "REPLICAS" "READY" "PODS"
for i in $(seq 1 "$N"); do
  T=$(date -u +%H:%M:%S)
  H=$(kubectl get hpa usms-enrolment-hpa -n "$NS" \
        -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
  TGT=$(kubectl get hpa usms-enrolment-hpa -n "$NS" \
        -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)
  D=$(kubectl get deploy usms-enrolment -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  R=$(kubectl get deploy usms-enrolment -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  P=$(kubectl get pods -n "$NS" -l app=usms-enrolment --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf "%-9s %-14s %-10s %-8s %-8s\n" "$T" "${H:-unknown}%/${TGT:-?}%" "${D:-?}" "${R:-0}" "$P"
  sleep 10
done
EOF

chmod +x scripts/utilities/hpa-watch.sh
bash -n scripts/utilities/hpa-watch.sh && echo "hpa-watch.sh: valid bash syntax"
```

**Terminal 2 – run it and leave it running:**

```bash
./scripts/utilities/hpa-watch.sh 60
```

**Load generator — `manifests/lab-08/20-loadgen.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-loadgen
  namespace: usms
  labels:
    app: usms-loadgen
    project: usms
    tier: tooling
    lab: "05b"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: usms-loadgen
  template:
    metadata:
      labels:
        app: usms-loadgen
        project: usms
        tier: tooling
    spec:
      containers:
        - name: loadgen
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - >
              while true; do
                wget -q -O /dev/null http://usms-gateway.usms.svc.cluster.local/enrolment/ || true;
              done
          resources:
            requests:
              cpu: "50m"
              memory: "16Mi"
            limits:
              cpu: "300m"
              memory: "64Mi"
```

```bash
kubectl apply -f manifests/lab-08/20-loadgen.yaml
kubectl rollout status deployment/usms-loadgen --timeout=120s
```

**Remove the load and watch the stabilisation window:**

```bash
kubectl scale deployment/usms-loadgen --replicas=0
```

```bash
kubectl describe hpa usms-enrolment-hpa | grep -A8 'Events:'
```

**Fallback (no metrics pipeline available):**

```bash
kubectl describe hpa usms-enrolment-hpa | sed -n '/Conditions/,/Events/p'
kubectl scale deployment/usms-enrolment --replicas=4
./scripts/utilities/hpa-watch.sh 6
kubectl scale deployment/usms-enrolment --replicas=2
```

**If pods sit Pending under scale-out:**

```bash
kubectl get pods -l app=usms-enrolment
kubectl describe pod <a pending one> | tail -6
kubectl describe node <any node> | sed -n '/Allocated resources/,/Events/p'
```

📸 **Screenshot Step 9.1** – *`hpa-watch.sh` output while load is applied (replicas climbing)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 9.2** – *`hpa-watch.sh` output after load removed (5-minute stabilisation window holding)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 9.3** – *`kubectl describe hpa` Events showing SuccessfulRescale entries*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 3**
```
Scaling, by controller
 ├── metrics API           available / installed / recorded as unavailable
 ├── usms-enrolment-hpa    autoscaling/v2, min 2 max 8, cpu 50% of the 50m request
 ├── behavior              scaleUp instant + rate-limited; scaleDown 300s window, 1 pod/min
 ├── observed              replicas moved 2 -> 4 under load, and back to 2 after the window
 └── usms-loadgen          scaled to 0, still present for Step 12
```

---

<a name="step-10"></a>
## Step 10 – Scale the Data Plane from the AWS Side

**Purpose:** Dimension 3 (more nodes) — the only step in this lab using the
AWS CLI directly.

**Read current configuration:**

```bash
aws eks describe-nodegroup \
  --cluster-name "$USMS_EKS_CLUSTER" \
  --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --query 'nodegroup.{Name:nodegroupName,Status:status,Scaling:scalingConfig,
                      Types:instanceTypes,Subnets:subnets,Labels:labels}' \
  --output json | tee outputs/lab-08-nodegroup-before.json
```

**Change it:**

```bash
aws eks update-nodegroup-config \
  --cluster-name "$USMS_EKS_CLUSTER" \
  --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --scaling-config minSize=2,maxSize=6,desiredSize=3 \
  --query 'update.{Id:id,Status:status,Type:type}' \
  --output table
```

**Poll the async update (optional):**

```bash
UPDATE_ID=$(aws eks list-updates \
  --name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --query 'updateIds | [0]' --output text 2>/dev/null)

aws eks describe-update \
  --name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --update-id "$UPDATE_ID" \
  --query 'update.{Status:status,Type:type,Params:params}' --output json 2>/dev/null \
  || echo "describe-update unsupported on this build - read the node group directly instead"
```

**Verify from both sides:**

```bash
aws eks describe-nodegroup \
  --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --query 'nodegroup.scalingConfig' --output json | tee outputs/lab-08-nodegroup-after.json

echo "--- and what Kubernetes actually sees ---"
kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,LABELS:.metadata.labels.workload'
```

> **Path B note:** `usms-eks-nodes` may not exist as an AWS object on this
> build. If so, record it in `notes/lab-08-notes.md` and answer Section 15
> Question 4 conceptually.

📸 **Screenshot Step 10.1** – *node group scaling config BEFORE*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 10.2** – *`update-nodegroup-config` response*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 10.3** – *node group scaling config AFTER (min 2 / max 6 / desired 3)*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-11"></a>
## Step 11 – Cluster Autoscaler, Karpenter & nodeSelector

**Concept comparison:**

| | Cluster Autoscaler | Karpenter |
|---|---|---|
| What it watches | Pending pods with no fitting node | Same |
| What it does | Raises an ASG's desired capacity | Launches EC2 instances directly, sized to fit |
| Pre-declare | Node groups, one per instance shape | A NodePool describing acceptable families |
| Typical scale-out time | Minutes | Under a minute |
| Bin-packing | Whatever the node groups happen to be | Chooses a size that fits |
| Maturity | Long-standing upstream project | Newer AWS project |

> Neither is installed in this lab (both need IRSA, which is not available on
> this build). Recorded as **Conceptual / Real AWS**.

**Do the labels exist on the nodes?**

```bash
kubectl get nodes --show-labels | tr ',' '\n' | grep -E 'workload|tier' \
  || echo "node group labels did not reach the nodes"
```

**Apply labels by hand if needed:**

```bash
for N in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl label node "$N" workload=usms tier=app --overwrite
done

kubectl get nodes -L workload,tier
```

**Require the label:**

```bash
kubectl patch deployment usms-enrolment --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"usms"}}}}}'

kubectl rollout status deployment/usms-enrolment --timeout=120s
kubectl get pods -l app=usms-enrolment -o wide
```

**Prove the selector is enforced (a bad value):**

```bash
kubectl patch deployment usms-enrolment --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"nonexistent"}}}}}'

sleep 15
kubectl get pods -l app=usms-enrolment
kubectl describe pod -l app=usms-enrolment | grep -A3 'Events:' | tail -4
```

**Put it back:**

```bash
kubectl patch deployment usms-enrolment --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"usms"}}}}}'

kubectl rollout status deployment/usms-enrolment --timeout=120s
kubectl get pods -l app=usms-enrolment -o wide
```

**Update the repository manifest (drift prevention):**

```bash
python3 - << 'PY'
import re
p = 'manifests/lab-07/20-enrolment.yaml'
s = open(p).read()
if 'nodeSelector' not in s:
    s = s.replace("    spec:\n      containers:\n        - name: enrolment",
                  "    spec:\n      nodeSelector:\n        workload: usms\n      containers:\n        - name: enrolment", 1)
    open(p,'w').write(s)
    print('nodeSelector added to', p)
else:
    print('nodeSelector already present in', p)
PY

kubectl diff -f manifests/lab-07/20-enrolment.yaml || true
```

📸 **Screenshot Step 11.1** – *node labels (`workload`, `tier`)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 11.2** – *pod Pending with `FailedScheduling` event (bad nodeSelector)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 11.3** – *pods Running again after nodeSelector restored*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-12"></a>
## Step 12 – PodDisruptionBudget

**Concept — voluntary vs involuntary disruption:**

```
VOLUNTARY - has an API, a PDB IS CONSULTED
  kubectl drain / cluster autoscaler removing a node / eviction API

INVOLUNTARY - nobody asked, a PDB IS IGNORED
  kernel panic, OOM eviction, manual instance termination, hardware failure
```

**Manifest — `manifests/lab-08/30-pdb-gateway.yaml`:**

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: usms-gateway-pdb
  namespace: usms
  labels:
    app: usms-gateway
    project: usms
    lab: "05b"
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: usms-gateway
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: usms-enrolment-pdb
  namespace: usms
  labels:
    app: usms-enrolment
    project: usms
    lab: "05b"
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: usms-enrolment
```

```bash
kubectl apply -f manifests/lab-08/30-pdb-gateway.yaml
kubectl get pdb
```

**Prove the eviction API is consulted, then prove `delete` is not:**

```bash
NODE=$(kubectl get pods -l app=usms-gateway -o jsonpath='{.items[0].spec.nodeName}')
echo "gateway is on node: $NODE"

POD=$(kubectl get pods -l app=usms-gateway -o jsonpath='{.items[0].metadata.name}')

cat > outputs/lab-08-eviction.json << EOF
{
  "apiVersion": "policy/v1",
  "kind": "Eviction",
  "metadata": { "name": "$POD", "namespace": "usms" }
}
EOF

kubectl create --raw "/api/v1/namespaces/usms/pods/$POD/eviction" \
  -f outputs/lab-08-eviction.json 2>&1 | tail -3
```

**Expected:**
```
Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.
```

**Contrast with plain delete:**

```bash
kubectl delete pod "$POD"
kubectl get pods -l app=usms-gateway
```

**Dry-run drain of the node:**

```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --dry-run=client 2>&1 | tail -5
```

📸 **Screenshot Step 12.1** – *`kubectl get pdb` (ALLOWED DISRUPTIONS column)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 12.2** – *eviction API refused with `TooManyRequests`*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 12.3** – *`kubectl delete pod` succeeding despite the PDB*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 4**
```
Infrastructure scaling and safety
 ├── usms-eks-nodes         min 2 / max 6 / desired 3 on the AWS side
 ├── Cluster Autoscaler / Karpenter   named, compared, NOT installed, and why
 ├── nodeSelector workload=usms       applied, ENFORCEMENT PROVEN
 ├── usms-gateway-pdb       minAvailable 1  -> ALLOWED DISRUPTIONS 0
 ├── usms-enrolment-pdb     maxUnavailable 1 -> ALLOWED DISRUPTIONS 1
 └── proven: eviction API respects a PDB; kubectl delete does not
```

---

<a name="step-13"></a>
## Step 13 – Rung 1: ClusterIP and port-forward

**Service types reference:**

| Type | Reachable from | Use for |
|---|---|---|
| ClusterIP (default) | Inside the cluster only | Internal services |
| NodePort | Any node IP, port 30000–32767 | Building block for LB |
| LoadBalancer | External address | Standard cloud exposure |
| ExternalName | n/a | CNAME to something external |
| port-forward | Your terminal only | Debugging only |

**Confirm ClusterIP is unroutable from the host:**

```bash
kubectl get svc -o wide

CIP=$(kubectl get svc usms-gateway -o jsonpath='{.spec.clusterIP}')
echo "gateway ClusterIP: $CIP"

curl -s --max-time 5 "http://$CIP/" || echo "as expected: a ClusterIP is not routable from your machine"
```

**Tunnel to it:**

```bash
kubectl port-forward svc/usms-gateway 18080:80
```

**Terminal 2:**

```bash
curl -s http://localhost:18080/ ; echo
curl -s http://localhost:18080/enrolment/ ; echo
curl -s http://localhost:18080/results/ ; echo
```

Stop the forward with `Ctrl+C`.

📸 **Screenshot Step 13.1** – *curl to ClusterIP failing*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 13.2** – *`kubectl port-forward` output*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 13.3** – *curl to `localhost:18080` for `/`, `/enrolment/`, `/results/`*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-14"></a>
## Step 14 – Rung 2: NodePort

**Manifest — `manifests/lab-08/40-service-nodeport.yaml`:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: usms-results-np
  namespace: usms
  labels:
    app: usms-results
    project: usms
    lab: "05b"
spec:
  type: NodePort
  selector:
    app: usms-results
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
```

```bash
kubectl apply -f manifests/lab-08/40-service-nodeport.yaml
kubectl get svc usms-results-np -o wide
```

**Reach it from inside the cluster on a node address:**

```bash
NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "node internal IP: $NODEIP"

kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qO- "http://$NODEIP:30080/"
```

**Prove every node answers:**

```bash
for IP in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
  echo "--- via node $IP ---"
  kubectl run usms-debug-$RANDOM --rm -i --restart=Never --image=busybox:1.36 -- \
    wget -qO- --timeout=5 "http://$IP:30080/" 2>/dev/null || echo "  no answer"
done
```

**From your machine (fallback if not published):**

```bash
curl -s --max-time 5 http://localhost:30080/ ; echo

# fallback
kubectl port-forward svc/usms-results-np 30080:80
# then, in another terminal:
curl -s http://localhost:30080/ ; echo
```

📸 **Screenshot Step 14.1** – *`kubectl get svc usms-results-np` showing `80:30080/TCP`*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 14.2** – *response reachable via node internal IP*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 14.3** – *loop showing every node answering, pod field varying*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 5**
```
Exposure ladder, rungs 1 and 2
 ├── ClusterIP        internal only, proven
 ├── port-forward     tunnel through the API server, debugging only
 └── NodePort         usms-results-np  80:30080/TCP
       ├── the SAME pods as usms-results, via a SECOND Service
       ├── every node answers on 30080, including nodes with no pods
       └── still has a ClusterIP
```

---

<a name="step-15"></a>
## Step 15 – Rung 3: LoadBalancer

**Manifest — `manifests/lab-08/50-service-loadbalancer.yaml`:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: usms-gateway
  namespace: usms
  labels:
    app: usms-gateway
    project: usms
    lab: "05b"
  annotations:
    # Real AWS only. Ignored locally, and harmless.
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  selector:
    app: usms-gateway
  ports:
    - name: http
      port: 80
      targetPort: http
```

```bash
kubectl apply -f manifests/lab-08/50-service-loadbalancer.yaml
kubectl get svc usms-gateway -o wide
```

**Watch for an address (60s then Ctrl+C):**

```bash
kubectl get svc usms-gateway -w
```

**Reach it:**

```bash
echo "--- via the published host port from Lab 07's _lb_ports_ tag ---"
curl -s --max-time 5 http://localhost:8081/ ; echo

echo "--- via the second published port ---"
curl -s --max-time 5 http://localhost:8082/ ; echo

echo "--- via the assigned EXTERNAL-IP, if there is one ---"
EXT=$(kubectl get svc usms-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "EXTERNAL-IP = ${EXT:-none}"
[ -n "$EXT" ] && kubectl run usms-debug --rm -i --restart=Never --image=busybox:1.36 -- \
  wget -qO- --timeout=5 "http://$EXT/" 2>/dev/null
```

**One-line proof of the ladder:**

```bash
kubectl get svc usms-gateway \
  -o jsonpath='{"type="}{.spec.type}{"  clusterIP="}{.spec.clusterIP}{"  nodePort="}{.spec.ports[0].nodePort}{"  external="}{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

> **If EXTERNAL-IP stays `<pending>` forever** — legitimate result on a local
> build. Use `kubectl port-forward svc/usms-gateway 8080:80` to prove the
> Service works, and record the `<pending>` state honestly.

📸 **Screenshot Step 15.1** – *`kubectl apply` + `kubectl get svc usms-gateway -o wide`*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 15.2** – *watch output: `<pending>` → address (or stayed `<pending>`)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 15.3** – *the one-line `type/clusterIP/nodePort/external` proof*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-16"></a>
## Step 16 – Rung 4: Ingress

**Is there a controller?**

```bash
kubectl get ingressclass 2>/dev/null || echo "no IngressClass registered"
kubectl get pods -A | grep -Ei 'traefik|ingress|nginx-controller' || echo "no ingress controller pod found"
```

**Manifest — `manifests/lab-08/60-ingress.yaml`:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: usms-portal-ingress
  namespace: usms
  labels:
    project: usms
    lab: "05b"
  annotations:
    # Real EKS, with the AWS Load Balancer Controller. Inert locally.
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/tags: Project=USMS,Tier=web,Lab=08
spec:
  rules:
    - http:
        paths:
          - path: /enrolment
            pathType: Prefix
            backend:
              service:
                name: usms-enrolment
                port:
                  number: 80
          - path: /results
            pathType: Prefix
            backend:
              service:
                name: usms-results
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: usms-gateway
                port:
                  number: 80
```

```bash
kubectl apply -f manifests/lab-08/60-ingress.yaml
kubectl get ingress
kubectl describe ingress usms-portal-ingress | tail -20
```

**Exercise the routes:**

```bash
for P in / /enrolment/ /results/ ; do
  echo "--- $P ---"
  curl -s --max-time 5 "http://localhost:8081$P" || echo "  (no answer on 8081)"
  echo
done
```

**In-cluster fallback:**

```bash
ADDR=$(kubectl get ingress usms-portal-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "ingress address: ${ADDR:-none}"

if [ -n "$ADDR" ]; then
  kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- sh -c "
    for P in / /enrolment/ /results/; do echo \"--- \$P ---\"; wget -qO- --timeout=5 http://$ADDR\$P; echo; done
  "
else
  echo "No ingress address: no controller is implementing this object."
  echo "Record it. The Ingress is a valid, stored, correct object with nothing acting on it."
fi
```

### Annotation ↔ Lab 05 `elbv2` mapping

| Lab 05, by hand | Lab 08, from one Ingress object |
|---|---|
| `aws elbv2 create-load-balancer` | IngressClass / ingress controller |
| `aws elbv2 create-target-group --target-type ip` | `alb.ingress.kubernetes.io/target-type: ip` |
| `aws elbv2 create-listener` | `alb.ingress.kubernetes.io/listen-ports` |
| `aws elbv2 create-rule --priority 10` | `spec.rules[].http.paths[]` |
| ECS register/deregister targets | controller watches `Endpoints` |

📸 **Screenshot Step 16.1** – *IngressClass / controller check*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 16.2** – *`kubectl get ingress` + `describe ingress` output*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 16.3** – *curl to `/`, `/enrolment/`, `/results/` through the Ingress*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 6**
```
Exposure ladder, complete
 ├── ClusterIP     internal only
 ├── port-forward  tunnel through the API server, one pod
 ├── NodePort      usms-results-np  80:30080 on EVERY node
 ├── LoadBalancer  usms-gateway  80:3xxxx  + external (or <pending>)
 └── Ingress       usms-portal-ingress   / -> gateway
                                         /enrolment -> enrolment
                                         /results   -> results
```

---

<a name="step-17"></a>
## Step 17 – Practical 2 vs Practical 4 Comparison

**Look at both stacks:**

```bash
echo "=============== ECS / ALB / Application Auto Scaling ==============="
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services usms-enrolment-svc \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,TaskDef:taskDefinition,
                        LB:loadBalancers[0].targetGroupArn,Grace:healthCheckGracePeriodSeconds}' \
  --output json 2>/dev/null

aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query 'ScalableTargets[0].{Id:ResourceId,Min:MinCapacity,Max:MaxCapacity}' --output json 2>/dev/null

aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --query 'ScalingPolicies[].{Name:PolicyName,Type:PolicyType}' --output table 2>/dev/null

echo
echo "=============== EKS / Ingress / HorizontalPodAutoscaler ==============="
kubectl get deploy,hpa,svc,ingress,pdb
```

**Comparison tables (fill in from the output above), appended to `notes/lab-08-notes.md`:**

#### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
|---|---|---|
| What integer is written? | | |
| Who writes it? | | |
| Where does that thing run? | | |
| Where does the metric come from? | | |
| What does "50% CPU" mean — 50% of what? | | |
| How is scale-in slowed down? | | |
| What happens with no capacity for the new instance/pod? | | |
| What creates the alarms, if anything? | | |

#### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
|---|---|---|
| How many AWS objects created by hand? | | |
| Target type, and why? | | |
| How are targets registered / deregistered? | | |
| How are competing routing rules disambiguated? | | |
| What changes to move to another cloud? | | |
| Cost of exposing ten services? | | |

**Two paragraphs (write in `notes/lab-08-notes.md`):**

1. *If the AWS control plane has a bad afternoon, what happens to each of the
   two scaling arrangements, and which can I still debug?*
   ```
   [ WRITE YOUR PARAGRAPH HERE ]
   ```

2. *For USMS specifically — one small team, one region, quiet for eight
   months and very busy for two — which would I choose, and what is the
   strongest argument against my own choice?*
   ```
   [ WRITE YOUR PARAGRAPH HERE ]
   ```

📸 **Screenshot Step 17.1** – *ECS side output (describe-services, scalable-targets, scaling-policies)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 17.2** – *EKS side output (`kubectl get deploy,hpa,svc,ingress,pdb`)*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-18"></a>
## Step 18 – Persistence Check

**Record the truth before restart:**

```bash
{
  echo "=== BEFORE RESTART $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  kubectl get hpa -o custom-columns='NAME:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,TARGET:.spec.metrics[0].resource.target.averageUtilization'
  kubectl get pdb -o custom-columns='NAME:.metadata.name,MINAVAIL:.spec.minAvailable,MAXUNAVAIL:.spec.maxUnavailable'
  kubectl get svc -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,NODEPORT:.spec.ports[0].nodePort'
  kubectl get ingress -o custom-columns='NAME:.metadata.name,PATHS:.spec.rules[0].http.paths[*].path'
  aws eks describe-nodegroup --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
    --query 'nodegroup.scalingConfig' --output text 2>/dev/null || echo "nodegroup: Path B"
} | tee outputs/lab-08-before-restart.txt
```

**Restart the emulator:**

```bash
./scripts/setup/floci-down.sh
sleep 5
./scripts/setup/floci-up.sh
sleep 30
kubectl cluster-info || { echo "re-establishing kubeconfig"; aws eks update-kubeconfig --name "$USMS_EKS_CLUSTER" --alias usms-eks; }
kubectl config set-context --current --namespace=usms
```

**Read it back and diff:**

```bash
{
  echo "=== AFTER RESTART $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  kubectl get hpa -o custom-columns='NAME:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,TARGET:.spec.metrics[0].resource.target.averageUtilization'
  kubectl get pdb -o custom-columns='NAME:.metadata.name,MINAVAIL:.spec.minAvailable,MAXUNAVAIL:.spec.maxUnavailable'
  kubectl get svc -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,NODEPORT:.spec.ports[0].nodePort'
  kubectl get ingress -o custom-columns='NAME:.metadata.name,PATHS:.spec.rules[0].http.paths[*].path'
  aws eks describe-nodegroup --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
    --query 'nodegroup.scalingConfig' --output text 2>/dev/null || echo "nodegroup: Path B"
} | tee outputs/lab-08-after-restart.txt

echo
diff <(grep -v '^===' outputs/lab-08-before-restart.txt) \
     <(grep -v '^===' outputs/lab-08-after-restart.txt) \
  && echo "PERSISTENCE PROVEN - scaling and exposure configuration identical" \
  || echo "differences above - read them before deciding whether they matter"
```

📸 **Screenshot Step 18.1** – *`outputs/lab-08-before-restart.txt` content*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 18.2** – *`outputs/lab-08-after-restart.txt` content*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 18.3** – *`diff` result — "PERSISTENCE PROVEN" (or explained differences)*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 7**
```
PERSISTENCE PROVEN
 ├── usms-enrolment-hpa    min 2 max 8 target 50
 ├── usms-enrolment-pdb    maxUnavailable 1
 ├── usms-gateway-pdb      minAvailable 1
 ├── usms-results-np       NodePort 30080  (pinned - unchanged)
 ├── usms-gateway          LoadBalancer    (nodePort may differ - allocated, not pinned)
 ├── usms-portal-ingress   /enrolment /results /
 └── usms-eks-nodes        min 2 max 6 desired 3   (or Path B)
```

---

<a name="step-19"></a>
## Step 19 – Write configs/lab-08.env

```bash
cat > configs/lab-08.env << EOF
# Lab 08 - EKS scaling and service exposure
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, ports and numbers only. NO SECRETS. Safe to commit.

export USMS_HPA_NAME=usms-enrolment-hpa
export USMS_HPA_MIN=$(kubectl get hpa usms-enrolment-hpa -n usms \
  -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
export USMS_HPA_MAX=$(kubectl get hpa usms-enrolment-hpa -n usms \
  -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
export USMS_HPA_CPU_TARGET=$(kubectl get hpa usms-enrolment-hpa -n usms \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)
export USMS_HPA_SCALEDOWN_WINDOW=$(kubectl get hpa usms-enrolment-hpa -n usms \
  -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}' 2>/dev/null)

export USMS_PDB_GATEWAY=usms-gateway-pdb
export USMS_PDB_ENROLMENT=usms-enrolment-pdb

export USMS_SVC_NODEPORT_NAME=usms-results-np
export USMS_SVC_NODEPORT=$(kubectl get svc usms-results-np -n usms \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
export USMS_SVC_GATEWAY_TYPE=$(kubectl get svc usms-gateway -n usms \
  -o jsonpath='{.spec.type}' 2>/dev/null)
export USMS_SVC_GATEWAY_NODEPORT=$(kubectl get svc usms-gateway -n usms \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)

export USMS_INGRESS_NAME=usms-portal-ingress
export USMS_INGRESS_CLASS=$(kubectl get ingress usms-portal-ingress -n usms \
  -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)

export USMS_NODEGROUP_MIN=$(aws eks describe-nodegroup --cluster-name usms-eks-cluster \
  --nodegroup-name usms-eks-nodes --query 'nodegroup.scalingConfig.minSize' --output text 2>/dev/null)
export USMS_NODEGROUP_MAX=$(aws eks describe-nodegroup --cluster-name usms-eks-cluster \
  --nodegroup-name usms-eks-nodes --query 'nodegroup.scalingConfig.maxSize' --output text 2>/dev/null)
export USMS_NODEGROUP_DESIRED=$(aws eks describe-nodegroup --cluster-name usms-eks-cluster \
  --nodegroup-name usms-eks-nodes --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null)

export USMS_NODE_LABEL_SELECTOR=workload=usms
export USMS_LOADGEN_DEPLOY=usms-loadgen
export USMS_K8S_MANIFEST_DIR_05B=manifests/lab-08
EOF

grep -n 'export .*=$\|None' configs/lab-08.env || echo "all values populated"
```

**Verify:**

```bash
source configs/lab-08.env
echo "hpa: $USMS_HPA_MIN..$USMS_HPA_MAX at ${USMS_HPA_CPU_TARGET}% cpu, scale-in window ${USMS_HPA_SCALEDOWN_WINDOW}s"
echo "nodeport: $USMS_SVC_NODEPORT   gateway: $USMS_SVC_GATEWAY_TYPE"
grep -c '^export' configs/lab-08.env
```

**Expected:** `hpa: 2..8 at 50% cpu, scale-in window 300s`, `nodeport: 30080  gateway: LoadBalancer`, count = `19`.

📸 **Screenshot Step 19.1** – *`configs/lab-08.env` populated (values check)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 19.2** – *verify output (hpa/nodeport summary + export count = 19)*
```
[ SPACE FOR SCREENSHOT ]
```

---

<a name="step-20"></a>
## Step 20 – Commit Work

```bash
git status --short
```

```bash
git check-ignore -v outputs/lab-08-baseline.txt
```

```bash
git add labs/lab-08-eks-scaling manifests/lab-08 manifests/lab-07/20-enrolment.yaml \
        configs/lab-08.env scripts/utilities/verify-lab-08.sh \
        scripts/utilities/hpa-watch.sh scripts/cleanup/lab-08-cleanup.sh \
        notes/lab-08-notes.md

git status --short

git commit -m "Lab 08: EKS scaling and service exposure

- usms-enrolment-hpa, autoscaling/v2, min 2 max 8, cpu 50% of the 50m request,
  scale-up instant and rate-limited, scale-in behind a 300s stabilisation window
- usms-loadgen used to drive the autoscaler; observed 2 -> 4 -> 2
- usms-eks-nodes rescaled min 2 / max 6 / desired 3 from the AWS side
- nodeSelector workload=usms on usms-enrolment, enforcement proven
- PodDisruptionBudgets on gateway and enrolment; eviction API vs delete demonstrated
- exposure ladder climbed: port-forward, NodePort 30080, LoadBalancer, Ingress
- Ingress annotations mapped one-to-one onto Lab 05's elbv2 calls
- persistence proven for HPA, PDBs, Services and Ingress across a Floci restart"
```

**Verify:**

```bash
git log --oneline -2
git show --stat --oneline HEAD | head -20
git ls-files | grep -c '^outputs/'
```

📸 **Screenshot Step 20.1** – *`git status --short` before add (nothing under `outputs/` listed)*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 20.2** – *`git commit` output*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot Step 20.3** – *`git log --oneline -2` + `git show --stat` showing the commit*
```
[ SPACE FOR SCREENSHOT ]
```

**Checkpoint 8**
```
committed
 ├── manifests/lab-08/    10-hpa-enrolment, 20-loadgen, 30-pdb-gateway,
 │                         40-service-nodeport, 50-service-loadbalancer, 60-ingress
 ├── manifests/lab-07/20-enrolment.yaml   updated with the nodeSelector
 ├── configs/lab-08.env   19 exports
 ├── scripts/utilities/    verify-lab-08.sh, hpa-watch.sh
 ├── scripts/cleanup/      lab-08-cleanup.sh  (written, NOT run)
 └── git ls-files outputs/ -> only .gitkeep
```

---

## 25. Verification Script

**`scripts/utilities/verify-lab-08.sh`:**

```bash
cat > scripts/utilities/verify-lab-08.sh << 'EOF'
#!/usr/bin/env bash
# Verify every Lab 08 artefact. Exit 1 if anything is missing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-07.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-08.env" 2>/dev/null || true
NS=usms

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
kget() { kubectl get "$1" "$2" -n "$NS" -o jsonpath="$3" 2>/dev/null; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "kubectl reaches an API server" "kubectl version --request-timeout=10s"

echo "== Lab 07 dependencies =="
check "namespace usms exists" "kubectl get namespace $NS"
check "usms-enrolment has at least 2 ready replicas" \
  "test \"\$(kget deploy usms-enrolment '{.status.readyReplicas}')\" -ge 2"
check "usms-enrolment declares a cpu request (the HPA's denominator)" \
  "kget deploy usms-enrolment '{.spec.template.spec.containers[0].resources.requests.cpu}' | grep -q 'm'"
check "cluster carries the _lb_ports_ tag (expect FAIL on Path B)" \
  "aws eks describe-cluster --name usms-eks-cluster --query 'cluster.tags._lb_ports_' --output text | grep -q 8081"

echo "== Lab 08: autoscaling =="
check "HorizontalPodAutoscaler usms-enrolment-hpa exists" "kubectl get hpa usms-enrolment-hpa -n $NS"
check "HPA is autoscaling/v2 with a behavior block" \
  "test -n \"\$(kget hpa usms-enrolment-hpa '{.spec.behavior.scaleDown.stabilizationWindowSeconds}')\""
check "HPA targets Deployment usms-enrolment" \
  "test \"\$(kget hpa usms-enrolment-hpa '{.spec.scaleTargetRef.name}')\" = usms-enrolment"
check "HPA minReplicas is 2" "test \"\$(kget hpa usms-enrolment-hpa '{.spec.minReplicas}')\" = 2"
check "HPA maxReplicas is 8" "test \"\$(kget hpa usms-enrolment-hpa '{.spec.maxReplicas}')\" = 8"
check "HPA cpu target is 50" \
  "test \"\$(kget hpa usms-enrolment-hpa '{.spec.metrics[0].resource.target.averageUtilization}')\" = 50"
check "HPA scale-in stabilisation window is 300s" \
  "test \"\$(kget hpa usms-enrolment-hpa '{.spec.behavior.scaleDown.stabilizationWindowSeconds}')\" = 300"

echo "== Lab 08: disruption budgets =="
check "PodDisruptionBudget usms-gateway-pdb exists" "kubectl get pdb usms-gateway-pdb -n $NS"
check "usms-gateway-pdb uses minAvailable 1" \
  "test \"\$(kget pdb usms-gateway-pdb '{.spec.minAvailable}')\" = 1"
check "usms-enrolment-pdb uses maxUnavailable 1" \
  "test \"\$(kget pdb usms-enrolment-pdb '{.spec.maxUnavailable}')\" = 1"

echo "== Lab 08: exposure ladder =="
check "usms-results-np is a NodePort Service" \
  "test \"\$(kget svc usms-results-np '{.spec.type}')\" = NodePort"
check "usms-results-np is pinned to node port 30080" \
  "test \"\$(kget svc usms-results-np '{.spec.ports[0].nodePort}')\" = 30080"
check "usms-results-np selects the same pods as usms-results" \
  "test \"\$(kget svc usms-results-np '{.spec.selector.app}')\" = usms-results"
check "usms-gateway is now type LoadBalancer" \
  "test \"\$(kget svc usms-gateway '{.spec.type}')\" = LoadBalancer"
check "usms-gateway kept a nodePort (each rung keeps the one below)" \
  "test -n \"\$(kget svc usms-gateway '{.spec.ports[0].nodePort}')\""
check "Ingress usms-portal-ingress exists" "kubectl get ingress usms-portal-ingress -n $NS"
check "Ingress declares three paths" \
  "test \"\$(kget ingress usms-portal-ingress '{.spec.rules[0].http.paths[*].path}' | wc -w)\" -eq 3"
check "Ingress carries the ALB target-type annotation" \
  "kget ingress usms-portal-ingress '{.metadata.annotations}' | grep -q 'target-type'"

echo "== Lab 08: data plane (expect FAIL on Path B) =="
check "node group maxSize was raised to 6" \
  "test \"\$(aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes --query 'nodegroup.scalingConfig.maxSize' --output text)\" = 6"

echo "== Files and Git hygiene =="
check "configs/lab-08.env exists" "test -f configs/lab-08.env"
check "configs/lab-08.env records the HPA bounds" \
  "grep -qE '^export USMS_HPA_MIN=[0-9]+' configs/lab-08.env"
check "six or more Lab 08 manifests present" \
  "test \"\$(ls manifests/lab-08/*.yaml 2>/dev/null | wc -l)\" -ge 6"
check "every Lab 08 manifest passes a client-side dry run" \
  "kubectl apply --dry-run=client -f manifests/lab-08/"
check "hpa-watch.sh is executable" "test -x scripts/utilities/hpa-watch.sh"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"
check ".gitignore uses outputs/* not outputs/" "grep -q '^outputs/\*' .gitignore"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-08.sh
./scripts/utilities/verify-lab-08.sh
```

**Expected:** `PASS=34  FAIL=0` on Path A, or `PASS=32  FAIL=2` on Path B
(the `_lb_ports_` tag and node group `maxSize` checks are expected to fail
on Path B).

📸 **Screenshot 25.1** – *`verify-lab-08.sh` full output with final PASS/FAIL line*
```
[ SPACE FOR SCREENSHOT ]
```

### Smoke test

```bash
kubectl run usms-smoke --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  G=http://usms-gateway.usms.svc.cluster.local
  wget -qO- $G/ && wget -qO- $G/enrolment/ && wget -qO- $G/results/
' && echo "SMOKE TEST PASSED"

kubectl get hpa,pdb,svc,ingress
```

📸 **Screenshot 25.2** – *smoke test output*
```
[ SPACE FOR SCREENSHOT ]
```

---

## 26. Independent Exercises

> Full write-ups belong in `labs/lab-08-eks-scaling/exercises.md`. Summaries
> and evidence pointers go here.

### Exercise 1 – Basic: a second autoscaler for `usms-results`

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
> ```
> [ WRITE YOUR ONE-SENTENCE ANSWER HERE ]
> ```

📸 **Screenshot 26.1.1** – *`kubectl get hpa` showing both HPAs*
```
[ SPACE FOR SCREENSHOT ]
```

---

### Exercise 2 – Intermediate: make the gateway drainable

**Requirements:** `usms-gateway-pdb` (`minAvailable: 1`, unchanged) must allow
at least 1 disruption; do this by spreading/scaling the gateway, not by
weakening the PDB.

```bash
kubectl scale deployment/usms-gateway --replicas=2
kubectl rollout status deployment/usms-gateway --timeout=120s
kubectl get pdb usms-gateway-pdb
kubectl get pods -l app=usms-gateway -o wide
```

**Update the manifest so the repository matches the cluster, then confirm
no drift:**

```bash
sed -i.bak 's/^  replicas: 1$/  replicas: 2/' manifests/lab-07/40-gateway.yaml
kubectl diff -f manifests/lab-07/40-gateway.yaml || true
rm -f manifests/lab-07/*.bak
```

📸 **Screenshot 26.2.1** – *`kubectl get pdb` showing ALLOWED DISRUPTIONS ≥ 1*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot 26.2.2** – *`kubectl get pods -o wide` showing gateway pod node placement*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot 26.2.3** – *`kubectl diff` showing no difference*
```
[ SPACE FOR SCREENSHOT ]
```

> **If the cluster has only one node:**
> ```
> [ STATE WHAT YOU WOULD HAVE DONE INSTEAD ]
> ```

---

### Exercise 3 – Problem solving: the autoscaler that will not act

**Given manifest (apply exactly as-is):**

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
kubectl apply -f - << 'EOF'
# (paste the manifest above)
EOF

kubectl get hpa usms-reports-hpa
kubectl describe hpa usms-reports-hpa | sed -n '/Conditions/,/Events/p'
kubectl get deploy usms-reports -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'; echo
```

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

**Cleanup:**

```bash
kubectl delete deployment,hpa usms-reports usms-reports-hpa --ignore-not-found
```

📸 **Screenshot 26.3.1** – *`describe hpa` Conditions block showing both faults*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot 26.3.2** – *HPA reporting a percentage after both fixes*
```
[ SPACE FOR SCREENSHOT ]
```

---

### Exercise 4 – Challenge: expose the results service properly

**Brief:** Reachable at a stable address, normal HTTP port, its own path, no
second `LoadBalancer` Service, no second load balancer cost.

**Design (prose, ~half a page) — write in `labs/lab-08-eks-scaling/exercises.md`:**

```
[ WRITE YOUR DESIGN HERE — address each of: which rung of the ladder each
  part sits on; why no second LoadBalancer; the cost implication; the
  failure mode if the cluster is unavailable; and whether the existing
  usms-portal-ingress /results rule is the answer, a starting point, or
  the wrong shape entirely. ]
```

📸 **Screenshot 26.4.1** – *any manifest/output you could demonstrate for this design*
```
[ SPACE FOR SCREENSHOT ]
```

---

### Exercise 5 – Integration: artefacts for Lab 10

**Part 1 — `outputs/lab-08-scaling-evidence.json`:**

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

**Part 2 — `outputs/lab-08-lab06-readiness.txt`:**

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

**Part 3 — "ECS or Kubernetes for USMS" (≤400 words, appended to `notes/lab-08-notes.md`, citing ≥3 specific observations):**

```
[ WRITE YOUR ARGUMENT HERE, IN notes/lab-08-notes.md ]
```

📸 **Screenshot 26.5.1** – *`python3 -m json.tool` validating the evidence JSON*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot 26.5.2** – *`outputs/lab-08-lab06-readiness.txt` content*
```
[ SPACE FOR SCREENSHOT ]
```

---

## 27. Review Questions

Answered in prose in `notes/lab-08-notes.md`.

1. **Correct the "50% node CPU" misconception**, and explain the effect of
   halving the CPU request without changing the HPA.
   ```
   [ ANSWER ]
   ```

2. **10× traffic plan** using the four dimensions from Step 3, with checks
   between each step and the one dimension that cannot change in place.
   ```
   [ ANSWER ]
   ```

3. **Two consequences** of Application Auto Scaling running outside the
   workload vs the HPA running inside the cluster (at least one about
   failure).
   ```
   [ ANSWER ]
   ```

4. **Pending pods after an HPA scale-out** — explain with the two-control-loop
   picture, name the resolving component, and say why lowering the CPU
   request is the wrong fix.
   ```
   [ ANSWER ]
   ```

5. **NodePort vs LoadBalancer, or Service vs Ingress** — pick one pair,
   explain the distinction, and give a requirement the wrong choice would
   fail.
   ```
   [ ANSWER ]
   ```

6. **`/enrolment` reachable both via the gateway and directly via Ingress** —
   argue for one design and say what you would delete.
   ```
   [ ANSWER ]
   ```

7. **`kubectl delete pod` bypassing a PDB** — why this is correct, voluntary
   vs involuntary disruption, and a scenario where the PDB would matter.
   ```
   [ ANSWER ]
   ```

---

## 28. Cleanup

> ⚠️ Run only the *temporary-instrument* cleanup now. Do **not** run
> `lab-08-cleanup.sh` or any earlier lab's cleanup script — those are for
> end of course only.

```bash
kubectl delete deployment usms-loadgen --ignore-not-found
kubectl delete deployment,hpa usms-reports usms-reports-hpa --ignore-not-found 2>/dev/null
kubectl delete pod -l run=usms-debug --ignore-not-found 2>/dev/null
rm -f manifests/lab-07/*.bak manifests/lab-08/*.bak

kubectl get nodes | grep -i cordon && echo "a node is cordoned - uncordon it" || echo "no cordoned nodes"
kubectl get all
```

**`scripts/cleanup/lab-08-cleanup.sh` (write and syntax-check only — do not run):**

```bash
cat > scripts/cleanup/lab-08-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Removes every Lab 08 object. Run BEFORE lab-07-cleanup.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
NS=usms

cat <<'WARN'
This removes:
  - Ingress usms-portal-ingress
  - Service usms-results-np (NodePort)
  - usms-gateway reverts from LoadBalancer to ClusterIP
  - HorizontalPodAutoscaler usms-enrolment-hpa
  - PodDisruptionBudgets usms-gateway-pdb and usms-enrolment-pdb
  - Deployment usms-loadgen
  - node group scaling config returns to min 2 / max 4 / desired 2
It does NOT remove the cluster, the namespace, or the three microservices.
WARN

printf 'Type exactly DELETE-LAB-08 to proceed: '
read -r CONFIRM
[ "$CONFIRM" = "DELETE-LAB-08" ] || { echo "aborted"; exit 1; }

kubectl delete ingress usms-portal-ingress -n "$NS" --ignore-not-found
kubectl patch svc usms-gateway -n "$NS" --type=merge -p '{"spec":{"type":"ClusterIP"}}' 2>/dev/null
kubectl delete svc usms-results-np -n "$NS" --ignore-not-found
kubectl delete hpa usms-enrolment-hpa -n "$NS" --ignore-not-found
kubectl delete pdb usms-gateway-pdb usms-enrolment-pdb -n "$NS" --ignore-not-found
kubectl delete deployment usms-loadgen -n "$NS" --ignore-not-found

aws eks update-nodegroup-config \
  --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 >/dev/null 2>&1 \
  || echo "node group unchanged (Path B, or the eks API is unavailable)"

echo "Lab 08 objects removed. The Lab 07 cluster and application are untouched."
EOF

chmod +x scripts/cleanup/lab-08-cleanup.sh
bash -n scripts/cleanup/lab-08-cleanup.sh && echo "cleanup script: valid bash syntax"
```

📸 **Screenshot 28.1** – *`kubectl get all` after temporary-instrument cleanup*
```
[ SPACE FOR SCREENSHOT ]
```

📸 **Screenshot 28.2** – *cleanup script syntax check passing*
```
[ SPACE FOR SCREENSHOT ]
```

---

## 29. Reflection

```
[ WRITE YOUR OWN REFLECTION HERE — e.g. what surprised you about the
  scale-in stabilisation window, what the Ingress/ALB annotation mapping
  taught you about portability, and anything you'd do differently. ]
```

---

## Lab Assessment Checklist

- [ ] `verify-lab-07.sh` run before starting; result recorded
- [ ] CPU request and `_lb_ports_` tag confirmed
- [ ] Baseline captured to `outputs/lab-08-baseline.txt`
- [ ] Four dimensions of scaling named; "your turn" plan written
- [ ] `kubectl scale` used; drift created and resolved
- [ ] QoS classes read; Guaranteed experiment done and reverted
- [ ] `usms-enrolment-hpa` created, `autoscaling/v2`, with `behavior` block
- [ ] Load generated; replicas observed moving (or `<unknown>` diagnosed)
- [ ] 300s scale-in window observed
- [ ] Node group rescaled from the AWS side (Path A)
- [ ] Cluster Autoscaler / Karpenter compared in prose
- [ ] `nodeSelector` applied; enforcement proven
- [ ] Both PodDisruptionBudgets created; eviction vs delete demonstrated
- [ ] `manifests/lab-07/20-enrolment.yaml` updated with the nodeSelector
- [ ] ClusterIP shown unroutable; port-forward used
- [ ] `usms-results-np` NodePort created and proven reachable on every node
- [ ] `usms-gateway` promoted to LoadBalancer with full manifest re-apply
- [ ] `usms-portal-ingress` created with three prefix paths
- [ ] Annotation-to-`elbv2` mapping written down
- [ ] `verify-lab-08.sh` written and run
- [ ] PERSISTENCE PROVEN after Floci restart
- [ ] `configs/lab-08.env` generated with 19 exports
- [ ] `git status --short` inspected before `git add`; nothing under `outputs/` staged
- [ ] Work committed
- [ ] Section 27 review questions answered in prose
- [ ] Step 17 comparison tables filled in
- [ ] Five exercises attempted; Exercise 5 outputs present
- [ ] `usms-loadgen` deleted at the end

---

*End of report.*
