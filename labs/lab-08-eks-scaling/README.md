# DSO303 - Lab 08: EKS Scaling and Service Exposure
### Practical 4 (Part 2) - Making the Cluster Grow, and Letting the World In

---

## Table of Contents

- [DSO303 - Lab 08: EKS Scaling and Service Exposure](#dso303---lab-08-eks-scaling-and-service-exposure)
    - [Practical 4 (Part 2) - Making the Cluster Grow, and Letting the World In](#practical-4-part-2---making-the-cluster-grow-and-letting-the-world-in)
  - [Table of Contents](#table-of-contents)
  - [1. Lab Overview](#1-lab-overview)
  - [2. Learning Objectives](#2-learning-objectives)
  - [3. Prerequisites Check](#3-prerequisites-check)
  - [4. Environment Setup](#4-environment-setup)
  - [Step 1 - Start the Environment \& Verify Lab 07 Dependencies](#step-1---start-the-environment--verify-lab-07-dependencies)
  - [Step 2 - Baseline Snapshot](#step-2---baseline-snapshot)
  - [Step 3 - The Four Dimensions of Scaling](#step-3---the-four-dimensions-of-scaling)
    - [My turn – written answer](#my-turn--written-answer)
  - [Step 4 – Scale by Hand](#step-4--scale-by-hand)
  - [Step 5 - Scale Declaratively \& Configuration Drift](#step-5---scale-declaratively--configuration-drift)
  - [Step 6 - Requests, Limits and QoS Classes](#step-6---requests-limits-and-qos-classes)
    - [My turn - Guaranteed QoS experiment](#my-turn---guaranteed-qos-experiment)
  - [Step 7 - The Metrics Pipeline](#step-7---the-metrics-pipeline)
  - [Step 8 - Create the HorizontalPodAutoscaler](#step-8---create-the-horizontalpodautoscaler)
  - [Step 9 - Generate Load and Watch It Respond](#step-9---generate-load-and-watch-it-respond)
  - [Step 10 - Scale the Data Plane from the AWS Side](#step-10---scale-the-data-plane-from-the-aws-side)
  - [Step 11 - Cluster Autoscaler, Karpenter \& nodeSelector](#step-11---cluster-autoscaler-karpenter--nodeselector)
  - [Step 12 - PodDisruptionBudget](#step-12---poddisruptionbudget)
  - [Step 13 - Rung 1: ClusterIP and port-forward](#step-13---rung-1-clusterip-and-port-forward)
  - [Step 14 - Rung 2: NodePort](#step-14---rung-2-nodeport)
  - [Step 15 - Rung 3: LoadBalancer](#step-15---rung-3-loadbalancer)
  - [Step 16 - Rung 4: Ingress](#step-16---rung-4-ingress)
    - [Annotation ↔ Lab 05 `elbv2` mapping](#annotation--lab-05-elbv2-mapping)
  - [Step 17 - Practical 2 vs Practical 4 Comparison](#step-17---practical-2-vs-practical-4-comparison)
      - [Scaling](#scaling)
      - [Exposure](#exposure)
  - [Step 18 - Persistence Check](#step-18---persistence-check)
  - [Step 19 - Write configs/lab-08.env](#step-19---write-configslab-08env)
  - [](#)
  - [Step 20 - Commit Work](#step-20---commit-work)
  - [25. Verification Script](#25-verification-script)
    - [Smoke test](#smoke-test)
  - [26. Independent Exercises](#26-independent-exercises)
  - [27. Review Questions](#27-review-questions)
  - [28. Cleanup](#28-cleanup)
  - [29. Reflection](#29-reflection)
  - [Lab Assessment Checklist](#lab-assessment-checklist)

---

## 1. Lab Overview

This lab picks up where Lab 07 left off. In Lab 07, the USMS application (three
microservices - `usms-gateway`, `usms-enrolment`, `usms-results`) was deployed to
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

- [x] Name the four independent dimensions along which a Kubernetes workload scales, and which object controls each.
- [x] Scale a Deployment imperatively and declaratively, and explain the resulting configuration drift.
- [x] Explain how a HorizontalPodAutoscaler computes utilisation, and why a missing resource request makes it inert.
- [x] Deploy an `autoscaling/v2` HPA with an explicit `behavior` block, mapped to its Lab 06 equivalent.
- [x] Generate load against a service and observe an autoscaler responding — or diagnose why it did not.
- [x] Change a managed node group's scaling configuration from the AWS CLI.
- [x] Distinguish the Cluster Autoscaler and Karpenter from the HorizontalPodAutoscaler.
- [x] Write a PodDisruptionBudget and state what it does and does not protect against.
- [x] Expose a Service four different ways — port-forward, NodePort, LoadBalancer, Ingress.
- [x] Compare Kubernetes Ingress with the Application Load Balancer of Lab 05.
- [x] Prove that scaling and exposure configuration survive a restart of the emulator.

---

## 3. Prerequisites Check

| Prerequisite | Required | Status |
|---|---|---|
| Lab 07 complete, `configs/lab-07.env` populated | ✅ | Done |
| `verify-lab-07.sh` passing (FAIL=0 Path A / FAIL=3 Path B) | ✅ | Done |
| `usms-enrolment` declares CPU request `50m` | ✅ | Done |
| Cluster tagged `_lb_ports_=8081,8082` | ✅ | Done |
| kubectl, AWS CLI v2 installed | ✅ | Done |

**Tool versions:**

```bash
kubectl version --client
aws --version
```

![alt text](<../../screenshots/Screenshot from 2026-11-07 13-42-02.png>)




## 4. Environment Setup

```bash
mkdir -p labs/lab-08-eks-scaling manifests/lab-08
ls -d manifests/*
```

**Expected:**
```
manifests/lab-07  manifests/lab-08
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-43-31.png>)

---

<a name="step-1"></a>
## Step 1 - Start the Environment & Verify Lab 07 Dependencies

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

![alt text](<../../screenshots/Screenshot from 2026-11-07 13-45-07.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-07 13-45-31.png>)

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
## Step 2 - Baseline Snapshot

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

![alt text](<../../screenshots/Screenshot from 2026-11-07 13-47-16.png>)

**Checkpoint 2** — three Deployments at Lab 07 counts, all Services `ClusterIP`
with `<none>` external, at least one node `Ready`.

---

<a name="step-3"></a>
## Step 3 - The Four Dimensions of Scaling

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

### My turn – written answer

> `usms-enrolment` needs to handle ten times its current traffic. Walk through
> the four dimensions and say which you would use, in which order, and what
> you would check between each.

> I would start with **dimension 1 (horizontal, workload)**: raise the replica count of `usms-enrolment` (through the HPA's `maxReplicas`), because it is the fastest change and restarts nothing. After each increase I check `kubectl get pods` for `Pending` pods and the node's "Allocated resources". When pods start going `Pending` because the nodes are full by *requests*, I move to **dimension 3 (horizontal, infrastructure)**: raise the node group's `desiredSize`/`maxSize`, then check that the new nodes are `Ready` and the pending pods get scheduled. Only if a single pod is throttled at its 200m CPU limit or gets OOMKilled would I use **dimension 2 (vertical, workload)**, raising requests/limits and re-checking the HPA percentage, because the denominator has changed. **Dimension 4 (bigger nodes)** comes last because an instance type cannot be changed in place: I would create a new node group, cordon and drain the old one, and check that the PDBs allow the drain.

---

<a name="step-4"></a>
## Step 4 – Scale by Hand

**Purpose:** The simplest rung of the ladder — everything the HPA does in
Step 8, it does by performing this same operation.

**Terminal 2 – watcher (leave running):**

```bash
kubectl get pods -w -l app=usms-enrolment
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-52-42.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-07 13-53-59.png>)

**Terminal 1 – scale up:**

```bash
kubectl scale deployment/usms-enrolment --replicas=5
kubectl rollout status deployment/usms-enrolment --timeout=120s

kubectl get deploy usms-enrolment
kubectl get endpoints usms-enrolment
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-53-17.png>)

**Confirm traffic spreads across five pods:**

```bash
kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  for i in $(seq 1 40); do
    wget -qO- http://usms-gateway.usms.svc.cluster.local/enrolment/
  done
' | grep -o '"pod":"[^"]*"' | sort | uniq -c | sort -rn
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-54-23.png>)

**Scale back down:**

```bash
kubectl scale deployment/usms-enrolment --replicas=2
kubectl rollout status deployment/usms-enrolment --timeout=120s
kubectl get endpoints usms-enrolment
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-54-35.png>)

Stop the watcher with `Ctrl+C`.

---

<a name="step-5"></a>
## Step 5 - Scale Declaratively & Configuration Drift

**Purpose:** Show what it costs when the cluster and the repository disagree.

**Create drift:**

```bash
kubectl scale deployment/usms-enrolment --replicas=6
kubectl get deploy usms-enrolment -o jsonpath='{.spec.replicas}'; echo
grep -n 'replicas:' manifests/lab-07/20-enrolment.yaml
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-57-10.png>)

**Watch apply silently undo it:**

```bash
kubectl apply -f manifests/lab-07/20-enrolment.yaml
sleep 5
kubectl get deploy usms-enrolment -o jsonpath='{.spec.replicas}'; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-57-29.png>)

**The habit that prevents it — `kubectl diff`:**

```bash
sed -i.bak 's/^  replicas: 2$/  replicas: 3/' manifests/lab-07/20-enrolment.yaml

kubectl diff -f manifests/lab-07/20-enrolment.yaml || true

kubectl apply -f manifests/lab-07/20-enrolment.yaml
kubectl get deploy usms-enrolment -o jsonpath='{.spec.replicas}'; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-57-56.png>)

**Restore baseline:**

```bash
sed -i.bak 's/^  replicas: 3$/  replicas: 2/' manifests/lab-07/20-enrolment.yaml
kubectl apply -f manifests/lab-07/20-enrolment.yaml
kubectl rollout status deployment/usms-enrolment --timeout=120s
rm -f manifests/lab-07/*.bak
kubectl get deploy
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 13-58-16.png>)

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
## Step 6 - Requests, Limits and QoS Classes

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-00-51.png>)

**Scheduler's arithmetic:**

```bash
NODE=$(kubectl get pods -l app=usms-enrolment -o jsonpath='{.items[0].spec.nodeName}')
echo "inspecting node: $NODE"
kubectl describe node "$NODE" | sed -n '/Allocated resources/,/Events/p'
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-01-12.png>)

**Denominator arithmetic:**

```bash
REQ=$(kubectl get deploy usms-enrolment \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
echo "request        : $REQ"
echo "HPA target 50% : this means 50% of $REQ per pod, i.e. 25m average across all pods"
echo "NOT 50% of a node, and NOT 50% of the limit"
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-01-34.png>)

### My turn - Guaranteed QoS experiment

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-03-12.png>)

> **When would I want Guaranteed?**
> I would want Guaranteed for a critical pod that must be the last one evicted under node memory pressure and needs predictable CPU, for example the single `usms-gateway` entry point or a database, accepting that it can never burst above its request.

---

<a name="step-7"></a>
## Step 7 - The Metrics Pipeline

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-06-03.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-18-05.png>)

**If no network access to install it:**

```bash
echo "metrics API unavailable - Step 9 will use the manual fallback" >> notes/lab-08-notes.md
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-18-56.png>)

**Verify:**

```bash
kubectl top nodes 2>/dev/null || echo "kubectl top nodes: unavailable"
kubectl top pods 2>/dev/null  || echo "kubectl top pods: unavailable"
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-19-13.png>)

---

<a name="step-8"></a>
## Step 8 - Create the HorizontalPodAutoscaler

**Purpose:** The object the whole scaling half of this lab is built around.

**Manifest - `manifests/lab-08/10-hpa-enrolment.yaml`:**

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-23-11.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-07 14-31-02.png>)

**Expected:**
```
NAME                 REFERENCE                   TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
usms-enrolment-hpa   Deployment/usms-enrolment   cpu: 2%/50%   2         8         2          32s
```

---

<a name="step-9"></a>
## Step 9 - Generate Load and Watch It Respond

**Watcher script - `scripts/utilities/hpa-watch.sh`:**

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-32-20.png>)

**Terminal 2 - run it and leave it running:**

```bash
./scripts/utilities/hpa-watch.sh 60
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-33-14.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-07 14-36-14.png>)

**Load generator - `manifests/lab-08/20-loadgen.yaml`:**

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-34-00.png>)

**Remove the load and watch the stabilisation window:**

```bash
kubectl scale deployment/usms-loadgen --replicas=0
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-34-15.png>)

```bash
kubectl describe hpa usms-enrolment-hpa | grep -A8 'Events:'
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-34-27.png>)

**Fallback (no metrics pipeline available):**

```bash
kubectl describe hpa usms-enrolment-hpa | sed -n '/Conditions/,/Events/p'
kubectl scale deployment/usms-enrolment --replicas=4
./scripts/utilities/hpa-watch.sh 6
kubectl scale deployment/usms-enrolment --replicas=2
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-35-43.png>)

**If pods sit Pending under scale-out:**

```bash
kubectl get pods -l app=usms-enrolment
kubectl describe pod <a pending one> | tail -6
kubectl describe node <any node> | sed -n '/Allocated resources/,/Events/p'
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
## Step 10 - Scale the Data Plane from the AWS Side

**Purpose:** Dimension 3 (more nodes) - the only step in this lab using the
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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-42-37.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-48-42.png>)

**Verify from both sides:**

```bash
aws eks describe-nodegroup \
  --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --query 'nodegroup.scalingConfig' --output json | tee outputs/lab-08-nodegroup-after.json

echo "--- and what Kubernetes actually sees ---"
kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,LABELS:.metadata.labels.workload'
```
![alt text](<../../screenshots/Screenshot from 2026-11-07 14-49-22.png>)

> **Path B note:** `usms-eks-nodes` may not exist as an AWS object on this
> build. If so, record it in `notes/lab-08-notes.md` and answer Section 15
> Question 4 conceptually.

**My result (Path B):** `describe-nodegroup` works and shows `usms-eks-nodes` ACTIVE with
`minSize 2 / maxSize 4 / desiredSize 2`, `t3.small`, labels `workload=usms, tier=app`
(`outputs/lab-08-nodegroup-before.json`). `update-nodegroup-config` fails with
`400 InvalidArgument: POST requires either ?uploads, ?uploadId, ?restore or ?select parameter`.
The CLI sends the correct request (`POST /clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config`),
but Floci 1.7.0 has no route for `UpdateNodegroupConfig` (or `ListUpdates`), so the request falls
through to its S3 handler. The "after" read still shows 2/4/2 (`outputs/lab-08-nodegroup-after.json`),
which confirms nothing changed. On real AWS this call would set the managed node group's ASG to
min 2 / max 6 / desired 3. EKS would launch a third `t3.small`, it would join the cluster
with the `workload=usms, tier=app` labels, and `kubectl get nodes` would show it `Ready`. This
is the step that a Cluster Autoscaler or Karpenter automates (Step 11).

---

<a name="step-11"></a>
## Step 11 - Cluster Autoscaler, Karpenter & nodeSelector

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-21-30.png>)

**Apply labels by hand if needed:**

```bash
for N in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl label node "$N" workload=usms tier=app --overwrite
done

kubectl get nodes -L workload,tier
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-21-30.png>)

**Require the label:**

```bash
kubectl patch deployment usms-enrolment --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"usms"}}}}}'

kubectl rollout status deployment/usms-enrolment --timeout=120s
kubectl get pods -l app=usms-enrolment -o wide
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-23-57.png>)

**Prove the selector is enforced (a bad value):**

```bash
kubectl patch deployment usms-enrolment --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"nonexistent"}}}}}'

sleep 15
kubectl get pods -l app=usms-enrolment
kubectl describe pod -l app=usms-enrolment | grep -A3 'Events:' | tail -4
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-27-57.png>)

**Put it back:**

```bash
kubectl patch deployment usms-enrolment --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"usms"}}}}}'

kubectl rollout status deployment/usms-enrolment --timeout=120s
kubectl get pods -l app=usms-enrolment -o wide
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-28-10.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-31-22.png>)

---

<a name="step-12"></a>
## Step 12 - PodDisruptionBudget

**Concept - voluntary vs involuntary disruption:**

```
VOLUNTARY - has an API, a PDB IS CONSULTED
  kubectl drain / cluster autoscaler removing a node / eviction API

INVOLUNTARY - nobody asked, a PDB IS IGNORED
  kernel panic, OOM eviction, manual instance termination, hardware failure
```

**Manifest - `manifests/lab-08/30-pdb-gateway.yaml`:**

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-45-10.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-46-10.png>)

**Contrast with plain delete:**

```bash
kubectl delete pod "$POD"
kubectl get pods -l app=usms-gateway
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-47-16.png>)

**Dry-run drain of the node:**

```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --dry-run=client 2>&1 | tail -5
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-47-33.png>)

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
## Step 13 - Rung 1: ClusterIP and port-forward

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-50-44.png>)

**Tunnel to it:**

```bash
kubectl port-forward svc/usms-gateway 18080:80
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-51-26.png>)

**Terminal 2:**

```bash
curl -s http://localhost:18080/ ; echo
curl -s http://localhost:18080/enrolment/ ; echo
curl -s http://localhost:18080/results/ ; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-51-42.png>)

Stop the forward with `Ctrl+C`.

---

<a name="step-14"></a>
## Step 14 - Rung 2: NodePort

**Manifest - `manifests/lab-08/40-service-nodeport.yaml`:**

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-53-25.png>)

**Reach it from inside the cluster on a node address:**

```bash
NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "node internal IP: $NODEIP"

kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qO- "http://$NODEIP:30080/"
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-53-45.png>)

**Prove every node answers:**

```bash
for IP in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
  echo "--- via node $IP ---"
  kubectl run usms-debug-$RANDOM --rm -i --restart=Never --image=busybox:1.36 -- \
    wget -qO- --timeout=5 "http://$IP:30080/" 2>/dev/null || echo "  no answer"
done
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-54-19.png>)

**From your machine (fallback if not published):**

```bash
curl -s --max-time 5 http://localhost:30080/ ; echo

# fallback
kubectl port-forward svc/usms-results-np 30080:80
# then, in another terminal:
curl -s http://localhost:30080/ ; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-55-06.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-09 10-55-19.png>)

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
## Step 15 - Rung 3: LoadBalancer

**Manifest - `manifests/lab-08/50-service-loadbalancer.yaml`:**

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 10-58-15.png>)

**Watch for an address (60s then Ctrl+C):**

```bash
kubectl get svc usms-gateway -w
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-00-08.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-09-26.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-09 11-09-48.png>)

**One-line proof of the ladder:**

```bash
kubectl get svc usms-gateway \
  -o jsonpath='{"type="}{.spec.type}{"  clusterIP="}{.spec.clusterIP}{"  nodePort="}{.spec.ports[0].nodePort}{"  external="}{.status.loadBalancer.ingress[0].ip}{"\n"}'
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-10-13.png>)

> **If EXTERNAL-IP stays `<pending>` forever** — legitimate result on a local
> build. Use `kubectl port-forward svc/usms-gateway 8080:80` to prove the
> Service works, and record the `<pending>` state honestly.

---

<a name="step-16"></a>
## Step 16 - Rung 4: Ingress

**Is there a controller?**

```bash
kubectl get ingressclass 2>/dev/null || echo "no IngressClass registered"
kubectl get pods -A | grep -Ei 'traefik|ingress|nginx-controller' || echo "no ingress controller pod found"
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-11-51.png>)

**Manifest - `manifests/lab-08/60-ingress.yaml`:**

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-12-48.png>)

**Exercise the routes:**

```bash
for P in / /enrolment/ /results/ ; do
  echo "--- $P ---"
  curl -s --max-time 5 "http://localhost:8081$P" || echo "  (no answer on 8081)"
  echo
done
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-13-03.png>)

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-13-32.png>)

### Annotation ↔ Lab 05 `elbv2` mapping

| Lab 05, by hand | Lab 08, from one Ingress object |
|---|---|
| `aws elbv2 create-load-balancer` | IngressClass / ingress controller |
| `aws elbv2 create-target-group --target-type ip` | `alb.ingress.kubernetes.io/target-type: ip` |
| `aws elbv2 create-listener` | `alb.ingress.kubernetes.io/listen-ports` |
| `aws elbv2 create-rule --priority 10` | `spec.rules[].http.paths[]` |
| ECS register/deregister targets | controller watches `Endpoints` |

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
## Step 17 - Practical 2 vs Practical 4 Comparison

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-19-09.png>)

**Comparison tables (fill in from the output above), appended to `notes/lab-08-notes.md`:**

#### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
|---|---|---|
| What integer is written? | ECS service `desiredCount` | Deployment `spec.replicas` (through the `scale` subresource) |
| Who writes it? | Application Auto Scaling, triggered by CloudWatch alarms | The HPA controller (in `kube-controller-manager`) |
| Where does that thing run? | Outside the workload, in AWS's regional control plane | Inside the cluster's control plane (managed by EKS, but part of the cluster) |
| Where does the metric come from? | CloudWatch `ECSServiceAverageCPUUtilization`, published by ECS | metrics-server through the `metrics.k8s.io` API (kubelet/cAdvisor) |
| What does "50% CPU" mean — 50% of what? | Average task CPU as a share of the CPU units reserved in the task definition | 50% of each container's CPU **request** (50m, so 25m average), not of the node or the limit |
| How is scale-in slowed down? | `ScaleInCooldown: 300` plus the low alarm needing many datapoints | `behavior.scaleDown.stabilizationWindowSeconds: 300` and a policy of at most 1 pod per 60s |
| What happens with no capacity for the new instance/pod? | Fargate provisions per task (may hit account quota); EC2 launch type fails placement unless a capacity provider grows the ASG | The pod stays `Pending` (`FailedScheduling`) until the Cluster Autoscaler/Karpenter or a manual node group change adds a node |
| What creates the alarms, if anything? | The target-tracking policy creates and owns two CloudWatch alarms (`TargetTracking-…-AlarmHigh/AlarmLow`) | Nothing; there are no alarms, the HPA polls metrics every 15s itself |

#### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
|---|---|---|
| How many AWS objects created by hand? | Four or more: ALB, target group, listener, rule (plus its security group) | Zero; the AWS Load Balancer Controller creates the ALB, target groups, listener and rules from one Ingress |
| Target type, and why? | `ip`: Fargate tasks use `awsvpc` and have their own ENI, so there is no instance to register | `ip` (annotation): VPC CNI gives pods real VPC IPs, so the ALB sends straight to the pod and skips the NodePort hop |
| How are targets registered / deregistered? | The ECS service registers task IPs on start and deregisters on stop (deregistration delay 30s) | The controller watches Endpoints/EndpointSlices and syncs the target group as pods become ready or go away |
| How are competing routing rules disambiguated? | Explicit numeric `--priority` (e.g. 10); lowest number is evaluated first | Path specificity: the longest matching `Prefix` wins (`/enrolment` beats `/`), and `Exact` beats `Prefix`; the controller turns this into ALB priorities |
| What changes to move to another cloud? | Everything; the `elbv2` calls are AWS-only and must be rewritten | `spec.rules` stays; only the `ingressClassName` and the `alb.ingress.kubernetes.io/*` annotations change |
| Cost of exposing ten services? | One ALB with ten target groups and ten hand-written rules (or ten ALBs if done naively) | One Ingress (or an IngressGroup) gives one ALB with ten rules; ten `LoadBalancer` Services would mean ten NLBs |

**Two paragraphs (write in `notes/lab-08-notes.md`):**

1. *If the AWS control plane has a bad afternoon, what happens to each of the
   two scaling arrangements, and which can I still debug?*
   > **ECS + Application Auto Scaling:** every part of the scaling loop lives in the AWS regional control plane: the CloudWatch metric, the two target-tracking alarms, Application Auto Scaling, and the ECS API that writes `desiredCount`. If that has a bad afternoon, the running tasks keep serving (the data plane is separate), but scaling is frozen at the current count. I can only debug through the same AWS APIs and console that are failing, so I have very little visibility.
   >
   > **EKS + HPA:** the HPA runs in the cluster's own control plane and reads from metrics-server inside the cluster, so it does not depend on CloudWatch or Application Auto Scaling. If only those services are degraded, pod scaling keeps working up to the capacity of the existing nodes. Adding nodes (`update-nodegroup-config`, ASG, EC2) still needs AWS, so new pods would sit `Pending`. If the EKS control plane itself is down, the HPA and `kubectl` stop too, but pods and kube-proxy keep serving. Overall the Kubernetes arrangement is the one I can still debug (`kubectl describe hpa`, events, `kubectl top`), as long as the API server is reachable.

2. *For USMS specifically — one small team, one region, quiet for eight
   months and very busy for two — which would I choose, and what is the
   strongest argument against my own choice?*
   > For USMS I would choose **ECS (on Fargate) with Application Auto Scaling**. A small team in one region gains nothing from running a cluster, node groups, metrics-server, a Cluster Autoscaler and an ingress controller. ECS gives target tracking, ALB integration and no nodes to patch. In the eight quiet months it costs only the running tasks, with no EKS control-plane fee. The strongest argument against my choice is reaction speed in the two busy months. Target tracking works on one-minute CloudWatch metrics and needs several alarm datapoints, so scale-out takes minutes. The HPA re-evaluates every 15 seconds, and its `behavior` block lets me double the pods every 15 seconds. That difference matters on enrolment day, when the spike arrives all at once.

---

<a name="step-18"></a>
## Step 18 - Persistence Check

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-20-43.png>)

**Restart the emulator:**

```bash
./scripts/setup/floci-down.sh
sleep 5
./scripts/setup/floci-up.sh
sleep 30
kubectl cluster-info || { echo "re-establishing kubeconfig"; aws eks update-kubeconfig --name "$USMS_EKS_CLUSTER" --alias usms-eks; }
kubectl config set-context --current --namespace=usms
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-23-05.png>)

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

![alt text](<../../screenshots/Screenshot from 2026-11-09 11-23-34.png>)


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
## Step 19 - Write configs/lab-08.env

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
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-25-05.png>)

**Verify:**

```bash
source configs/lab-08.env
echo "hpa: $USMS_HPA_MIN..$USMS_HPA_MAX at ${USMS_HPA_CPU_TARGET}% cpu, scale-in window ${USMS_HPA_SCALEDOWN_WINDOW}s"
echo "nodeport: $USMS_SVC_NODEPORT   gateway: $USMS_SVC_GATEWAY_TYPE"
grep -c '^export' configs/lab-08.env
```

**Expected:** `hpa: 2..8 at 50% cpu, scale-in window 300s`, `nodeport: 30080  gateway: LoadBalancer`, count = `19`.

![alt text](<../../screenshots/Screenshot from 2026-11-09 11-25-22.png>)
---

<a name="step-20"></a>
## Step 20 - Commit Work

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

![alt text](<../../screenshots/Screenshot from 2026-11-09 11-31-43.png>)

### Smoke test

```bash
kubectl run usms-smoke --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  G=http://usms-gateway.usms.svc.cluster.local
  wget -qO- $G/ && wget -qO- $G/enrolment/ && wget -qO- $G/results/
' && echo "SMOKE TEST PASSED"

kubectl get hpa,pdb,svc,ingress
```
![alt text](<../../screenshots/Screenshot from 2026-11-09 11-32-04.png>)

---

## 26. Independent Exercises

The five independent exercises are in [exercise.md](exercise.md).

---

## 27. Review Questions

The review questions and answers are in [notes/lab-08-notes.md](notes/lab-08-notes.md#review-questions).

---

## 28. Cleanup



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

---

## 29. Reflection

The biggest shift for me was seeing that "scaling" is really just one integer. In Lab 06, Application Auto Scaling wrote `desiredCount` from outside ECS; here the HPA writes `replicas` from inside the cluster, and `kubectl scale` writes the same field by hand. Understanding that made HPA behaviour much easier to reason about, especially the fact that "50%" means 50% of the CPU *request* (25m of 50m), not of the node.

The 300-second scale-down stabilisation window was a good lesson in deliberate slowness. Scale-up is meant to be fast and scale-in slow, so that a short dip in traffic does not remove pods that are needed again a minute later. It plays the same role as `ScaleInCooldown: 300` in Lab 06.

The Ingress and `elbv2` mapping showed me what portability does and does not mean. The `spec.rules` paths are portable, but the `alb.ingress.kubernetes.io/*` annotations tie the object to AWS, and without a controller the Ingress is a correct object that nothing acts on. "Declare it in one place" only works if something is installed to make it real.

Next time I would update the manifests in `manifests/` *as* I change the cluster, not afterwards, to avoid the drift from Step 5. I would also scale the gateway to two replicas before adding its PDB, because a `minAvailable: 1` budget on a single pod silently blocks every drain.

---

## Lab Assessment Checklist

- [x] `verify-lab-07.sh` run before starting; result recorded
- [x] CPU request and `_lb_ports_` tag confirmed
- [x] Baseline captured to `outputs/lab-08-baseline.txt`
- [x] Four dimensions of scaling named; "your turn" plan written
- [x] `kubectl scale` used; drift created and resolved
- [x] QoS classes read; Guaranteed experiment done and reverted
- [x] `usms-enrolment-hpa` created, `autoscaling/v2`, with `behavior` block
- [x] Load generated; replicas observed moving (or `<unknown>` diagnosed)
- [x] 300s scale-in window observed
- [x] Node group rescaled from the AWS side (Path A)
- [x] Cluster Autoscaler / Karpenter compared in prose
- [x] `nodeSelector` applied; enforcement proven
- [x] Both PodDisruptionBudgets created; eviction vs delete demonstrated
- [x] `manifests/lab-07/20-enrolment.yaml` updated with the nodeSelector
- [x] ClusterIP shown unroutable; port-forward used
- [x] `usms-results-np` NodePort created and proven reachable on every node
- [x] `usms-gateway` promoted to LoadBalancer with full manifest re-apply
- [x] `usms-portal-ingress` created with three prefix paths
- [x] Annotation-to-`elbv2` mapping written down
- [x] `verify-lab-08.sh` written and run
- [x] PERSISTENCE PROVEN after Floci restart
- [x] `configs/lab-08.env` generated with 19 exports
- [x] `git status --short` inspected before `git add`; nothing under `outputs/` staged
- [x] Work committed
- [x] Section 27 review questions answered in prose
- [x] Step 17 comparison tables filled in
- [x] Five exercises attempted; Exercise 5 outputs present
- [x] `usms-loadgen` deleted at the end

---

