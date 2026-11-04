# DSO303 — Lab 07: Deploying a Microservices Application on Amazon EKS

**Practical 4 — the same USMS workload, a different control plane**

---

## Table of Contents

1. [Lab Overview](#1-lab-overview)
2. [Learning Objectives](#2-learning-objectives)
3. [Prerequisites Check](#3-prerequisites-check)
4. [Directory Structure Setup](#4-directory-structure-setup)
5. [Step-by-Step Implementation](#5-step-by-step-implementation)
   - [Step 1 — Start the environment and confirm the ground you are standing on](#step-1--start-the-environment-and-confirm-the-ground-you-are-standing-on)
   - [Step 2 — Probe what your build actually supports, and record the answer](#step-2--probe-what-your-build-actually-supports-and-record-the-answer)
   - [Step 3 — Understand the control plane / data plane split before you create either](#step-3--understand-the-control-plane--data-plane-split-before-you-create-either)
   - [Step 4 — Write the two trust policies](#step-4--write-the-two-trust-policies)
   - [Step 5 — Write the two permissions policies](#step-5--write-the-two-permissions-policies)
   - [Step 6 — Create the cluster role and the cluster security group](#step-6--create-the-cluster-role-and-the-cluster-security-group)
   - [Step 7 — Create the node role, and attach Lab 1's policy to it](#step-7--create-the-node-role-and-attach-lab-1s-policy-to-it)
   - [Step 8 — Create the cluster](#step-8--create-the-cluster)
   - [Step 9 — Wait for the cluster, and read what it tells you](#step-9--wait-for-the-cluster-and-read-what-it-tells-you)
   - [Step 10 — Create the managed node group](#step-10--create-the-managed-node-group)
   - [Step 11 — Point kubectl at the cluster](#step-11--point-kubectl-at-the-cluster)
   - [Step 12 — Create the namespace, and make it the default for your context](#step-12--create-the-namespace-and-make-it-the-default-for-your-context)
   - [Step 13 — Deploy the first microservice: usms-enrolment](#step-13--deploy-the-first-microservice-usms-enrolment)
   - [Step 14 — Deploy the second microservice: usms-results](#step-14--deploy-the-second-microservice-usms-results)
   - [Step 15 — Deploy the gateway, and meet cluster DNS](#step-15--deploy-the-gateway-and-meet-cluster-dns)
   - [Step 16 — Prove service discovery from inside the cluster](#step-16--prove-service-discovery-from-inside-the-cluster)
   - [Step 17 — ConfigMaps and Secrets, and an honest account of what a Secret is](#step-17--configmaps-and-secrets-and-an-honest-account-of-what-a-secret-is)
   - [Step 18 — Roll out a change, then roll it back](#step-18--roll-out-a-change-then-roll-it-back)
   - [Step 19 — Break a pod deliberately, and diagnose it](#step-19--break-a-pod-deliberately-and-diagnose-it)
   - [Step 20 — Write down the ECS comparison while both are in front of you](#step-20--write-down-the-ecs-comparison-while-both-are-in-front-of-you)
   - [Step 21 — IRSA: the right way to give a pod AWS permissions](#step-21--irsa-the-right-way-to-give-a-pod-aws-permissions)
   - [Step 22 — Prove that all of this survives a restart](#step-22--prove-that-all-of-this-survives-a-restart)
   - [Step 23 — Write configs/lab-07.env](#step-23--write-configslab-07env)
   - [Step 24 — Commit your work](#step-24--commit-your-work)
6. [Verification — verify-lab-07.sh](#6-verification--verify-lab-07sh)
7. [Cleanup Script (build only — DO NOT RUN)](#7-cleanup-script-build-only--do-not-run)
8. [Floci vs Real AWS — Summary](#8-floci-vs-real-aws--summary)
9. [Lab Assessment Checklist](#9-lab-assessment-checklist)
10. [Reflection](#10-reflection)
11. [What I Built (Architecture Summary)](#11-what-i-built-architecture-summary)

---

## 1. Lab Overview

This lab rebuilds the USMS (University Student Management System) application — previously deployed on Amazon ECS in Practical 2 (Labs 04–06) — on **Amazon EKS (Elastic Kubernetes Service)**. Three interdependent microservices are deployed into a Kubernetes namespace, and service discovery, rolling updates, rollback, failure diagnosis, and persistence are all proven hands-on.

**Objects deployed in this lab:**
- `usms-eks-cluster-role`, `usms-eks-node-role` (IAM)
- `USMSEKSClusterPolicy`, `USMSEKSNodePolicy` (IAM, local stand-ins)
- `usms-eks-cluster-sg` (EC2 security group)
- `usms-eks-cluster` (EKS cluster)
- `usms-eks-nodes` (managed node group)
- Namespace `usms` with `usms-gateway`, `usms-enrolment`, `usms-results` (Deployments + Services + ConfigMaps)
- `usms-enrolment-secret` (Secret)

---

## 2. Learning Objectives

- [x] Explain the EKS control plane / data plane split
- [x] Create an EKS cluster and managed node group via CLI
- [x] Explain why EKS needs two distinct IAM roles
- [x] Configure `kubectl` against a cluster
- [x] Write Deployment, Service and ConfigMap manifests
- [x] Deploy three interdependent microservices and prove DNS-based discovery
- [x] Perform a rolling update and a rollback
- [x] Diagnose failing pods with `describe`, `logs`, and events
- [x] Distinguish a ConfigMap from a Secret
- [x] Compare the Kubernetes object model with the ECS object model
- [x] Prove persistence across a restart

---

## 3. Prerequisites Check

Labs 01 (IAM), 02 (VPC), 03 (EC2), 04 (ECS) must be complete. `USMS_PRIVATE_SUBNET_B` and `USMS_PUBLIC_SUBNET_B` must exist in `configs/lab-02.env`.

**Tools required:** Docker, AWS CLI v2, `kubectl`, `k3d` (fallback), `python3`, `jq` (optional)

```bash
docker version
aws --version
kubectl version --client --output=yaml
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 19-36-02.png>)

---

## 4. Directory Structure Setup

```bash
cd ~/aws-floci-course
mkdir -p labs/lab-07-eks manifests/lab-07
ls -d labs/* manifests/*
```

---

## 5. Step-by-Step Implementation

### Step 1 — Start the environment and confirm the ground you are standing on

```bash
cd ~/aws-floci-course
./scripts/setup/floci-up.sh

source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env

./scripts/utilities/whoami.sh
./scripts/utilities/floci-storage-check.sh
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 19-40-36.png>)

**Verify:**

```bash
./scripts/utilities/verify-lab-02.sh | tail -2
./scripts/utilities/verify-lab-04.sh | tail -2

echo "public-a=$USMS_PUBLIC_SUBNET_A"
echo "public-b=$USMS_PUBLIC_SUBNET_B"
echo "private-a=$USMS_PRIVATE_SUBNET_A"
echo "private-b=$USMS_PRIVATE_SUBNET_B"
```

**Expected:** `FAIL=0` from verify-lab-02.sh; four `subnet-` IDs, none empty/None.

![alt text](<../../screenshots/Screenshot from 2026-11-04 20-09-52.png>)

---

### Step 2 — Probe what your build actually supports, and record the answer

```bash
cat > scripts/utilities/eks-support-probe.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

echo "== Floci =="
docker container inspect "$FLOCI_CONTAINER_NAME" \
  --format 'running={{.State.Running}}' 2>/dev/null || echo "running=NO-SUCH-CONTAINER"

echo
echo "== Does the eks API answer at all? =="
if aws eks list-clusters --output text >/dev/null 2>&1; then
  echo "eks list-clusters      : OK"
  EKS_API=yes
else
  echo "eks list-clusters      : FAILED"
  EKS_API=no
fi

echo
echo "== Local tooling =="
for t in kubectl k3d docker python3; do
  if command -v "$t" >/dev/null 2>&1; then
    printf "  %-8s : %s\n" "$t" "$(command -v "$t")"
  else
    printf "  %-8s : MISSING\n" "$t"
  fi
done

echo
echo "== Verdict =="
if [ "$EKS_API" = yes ] && command -v kubectl >/dev/null 2>&1; then
  echo "PATH A  - use aws eks throughout"
elif command -v k3d >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  echo "PATH B  - create the cluster with k3d (Step 8B); IAM steps still apply"
else
  echo "PATH C  - manifests and reasoning only (Section 8.4)"
fi
EOF

chmod +x scripts/utilities/eks-support-probe.sh
./scripts/utilities/eks-support-probe.sh | tee outputs/lab-07-support-probe.txt
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-11-59.png>)

**Record the verdict:**

```bash
mkdir -p notes
{
  echo "## Lab 07 support path"
  echo "Probed on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  grep -A1 '== Verdict ==' outputs/lab-07-support-probe.txt | tail -1
} >> notes/lab-07-notes.md

tail -3 notes/lab-07-notes.md
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 20-13-02.png>)

**Checkpoint 1:** Floci running under Compose; five env files sourced; verify-lab-02.sh FAIL=0; four subnet IDs; kubectl installed; support path recorded.

---

### Step 3 — Understand the control plane / data plane split before you create either

| CONTROL PLANE (AWS runs it) | DATA PLANE (you run it) |
|---|---|
| kube-apiserver | EC2 instances in your account |
| etcd | kubelet |
| kube-scheduler | container runtime |
| kube-controller-manager | your pods |
| cloud-controller-manager | CNI plugin |
| billed per cluster/hour | billed per instance |
| patched by AWS | patched by you |
| cluster role | node role |

---

### Step 4 — Write the two trust policies

```bash
cat > policies/trust-eks-cluster.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSControlPlaneAssumesThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "eks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

cat > policies/trust-eks-node.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2InstancesAssumeThisRole",
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

python3 -m json.tool policies/trust-eks-cluster.json > /dev/null && echo "cluster trust: valid JSON"
python3 -m json.tool policies/trust-eks-node.json    > /dev/null && echo "node trust   : valid JSON"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-15-09.png>)

**Verify:**

```bash
python3 -c "
import json
for f in ('policies/trust-eks-cluster.json','policies/trust-eks-node.json'):
    d = json.load(open(f))
    s = d['Statement'][0]
    print(f, '->', s['Principal']['Service'], s['Action'])
"
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 20-16-14.png>)

---

### Step 5 — Write the two permissions policies

```bash
cat > policies/usms-eks-cluster-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageNetworkInterfacesForTheClusterEndpoint",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageLoadBalancersForServicesOfTypeLoadBalancer",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:Describe*",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:AddTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyEverythingOutsideTheCourseRegion",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    }
  ]
}
EOF

cat > policies/usms-eks-node-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KubeletDescribesTheClusterAndRegisters",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:DescribeNodegroup",
        "eks:ListClusters"
      ],
      "Resource": "*"
    },
    {
      "Sid": "VpcCniAttachesInterfacesAndAssignsPodAddresses",
      "Effect": "Allow",
      "Action": [
        "ec2:AssignPrivateIpAddresses",
        "ec2:UnassignPrivateIpAddresses",
        "ec2:AttachNetworkInterface",
        "ec2:DetachNetworkInterface",
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeInstances",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PullImagesFromEcr",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WriteContainerLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:us-east-1:000000000000:log-group:/usms/eks/*"
    },
    {
      "Sid": "DenyEverythingOutsideTheCourseRegion",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    }
  ]
}
EOF

for f in policies/usms-eks-cluster-policy.json policies/usms-eks-node-policy.json; do
  python3 -m json.tool "$f" > /dev/null && echo "$f : valid JSON"
done
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-17-23.png>)

**Verify:**

```bash
python3 -c "
import json
for f in ('policies/usms-eks-cluster-policy.json','policies/usms-eks-node-policy.json'):
    d = json.load(open(f))
    print(f)
    for s in d['Statement']:
        n = len(s['Action']) if isinstance(s['Action'], list) else 1
        print('   %-9s %-2d action(s)  %s' % (s['Effect'], n, s['Sid']))
"
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 20-19-12.png>)
---

### Step 6 — Create the cluster role and the cluster security group

```bash
EKS_CLUSTER_ROLE=usms-eks-cluster-role

aws iam create-role \
  --role-name "$EKS_CLUSTER_ROLE" \
  --assume-role-policy-document file://policies/trust-eks-cluster.json \
  --description "Assumed by the EKS control plane to manage network resources for usms-eks-cluster" \
  --tags Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=07 \
  --query 'Role.Arn' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-20-32.png>)

```bash
EKS_CLUSTER_POLICY_ARN=$(aws iam create-policy \
  --policy-name USMSEKSClusterPolicy \
  --policy-document file://policies/usms-eks-cluster-policy.json \
  --description "Local stand-in for AmazonEKSClusterPolicy" \
  --query 'Policy.Arn' --output text 2>/dev/null \
  || aws iam list-policies --scope Local \
       --query "Policies[?PolicyName=='USMSEKSClusterPolicy'].Arn | [0]" --output text)

echo "EKS_CLUSTER_POLICY_ARN = $EKS_CLUSTER_POLICY_ARN"

aws iam attach-role-policy \
  --role-name "$EKS_CLUSTER_ROLE" \
  --policy-arn "$EKS_CLUSTER_POLICY_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-20-48.png>)

```bash
EKS_CLUSTER_SG=$(aws ec2 create-security-group \
  --group-name usms-eks-cluster-sg \
  --description "Control-plane endpoint for usms-eks-cluster" \
  --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-eks-cluster-sg},{Key=Project,Value=USMS},{Key=Tier,Value=app},{Key=Lab,Value=07}]' \
  --query 'GroupId' --output text 2>/dev/null \
  || aws ec2 describe-security-groups \
       --filters "Name=group-name,Values=usms-eks-cluster-sg" "Name=vpc-id,Values=$USMS_VPC_ID" \
       --query 'SecurityGroups[0].GroupId' --output text)

echo "EKS_CLUSTER_SG = $EKS_CLUSTER_SG"

aws ec2 authorize-security-group-ingress \
  --group-id "$EKS_CLUSTER_SG" \
  --protocol tcp --port 443 --cidr "$USMS_VPC_CIDR" \
  --query 'Return' --output text 2>/dev/null || echo "ingress rule already present"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-21-08.png>)

**Verify:**

```bash
aws iam list-attached-role-policies --role-name usms-eks-cluster-role \
  --query 'AttachedPolicies[].PolicyName' --output text

aws iam get-role --role-name usms-eks-cluster-role \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text

aws ec2 describe-security-groups --group-ids "$EKS_CLUSTER_SG" \
  --query 'SecurityGroups[0].{Id:GroupId,Vpc:VpcId,Ports:IpPermissions[].FromPort}' --output json
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 20-21-24.png>)

---

### Step 7 — Create the node role, and attach Lab 1's policy to it

```bash
EKS_NODE_ROLE=usms-eks-node-role

aws iam create-role \
  --role-name "$EKS_NODE_ROLE" \
  --assume-role-policy-document file://policies/trust-eks-node.json \
  --description "Assumed by EC2 instances in usms-eks-nodes so they can join the cluster" \
  --tags Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=07 \
  --query 'Role.Arn' --output text

EKS_NODE_POLICY_ARN=$(aws iam create-policy \
  --policy-name USMSEKSNodePolicy \
  --policy-document file://policies/usms-eks-node-policy.json \
  --description "Local stand-in for AmazonEKSWorkerNodePolicy + AmazonEKS_CNI_Policy + ECR read-only" \
  --query 'Policy.Arn' --output text 2>/dev/null \
  || aws iam list-policies --scope Local \
       --query "Policies[?PolicyName=='USMSEKSNodePolicy'].Arn | [0]" --output text)

aws iam attach-role-policy --role-name "$EKS_NODE_ROLE" --policy-arn "$EKS_NODE_POLICY_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-22-46.png>)

```bash
S3_RW_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)

echo "USMSStudentDataReadWrite = $S3_RW_ARN"

aws iam attach-role-policy --role-name "$EKS_NODE_ROLE" --policy-arn "$S3_RW_ARN"

aws iam list-entities-for-policy --policy-arn "$S3_RW_ARN" \
  --query 'PolicyRoles[].RoleName' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-23-05.png>)

**Verify:**

```bash
aws iam list-attached-role-policies --role-name usms-eks-node-role \
  --query 'AttachedPolicies[].PolicyName' --output text

aws iam get-role --role-name usms-eks-node-role \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 20-23-23.png>)

**Checkpoint 2:**
```
usms-eks-cluster-role  trusts eks.amazonaws.com -> USMSEKSClusterPolicy
usms-eks-node-role     trusts ec2.amazonaws.com -> USMSEKSNodePolicy, USMSStudentDataReadWrite
usms-eks-cluster-sg    in usms-vpc, tcp/443 from 10.0.0.0/16
```

---

### Step 8 — Create the cluster

```bash
cat > templates/lab-07-create-cluster.json << EOF
{
  "name": "usms-eks-cluster",
  "version": "1.30",
  "roleArn": "$(aws iam get-role --role-name usms-eks-cluster-role --query 'Role.Arn' --output text)",
  "resourcesVpcConfig": {
    "subnetIds": [
      "$USMS_PRIVATE_SUBNET_A",
      "$USMS_PRIVATE_SUBNET_B",
      "$USMS_PUBLIC_SUBNET_A",
      "$USMS_PUBLIC_SUBNET_B"
    ],
    "securityGroupIds": [ "$EKS_CLUSTER_SG" ],
    "endpointPublicAccess": true,
    "endpointPrivateAccess": true
  },
  "tags": {
    "Name": "usms-eks-cluster",
    "Project": "USMS",
    "Tier": "app",
    "Lab": "07",
    "_lb_ports_": "8081,8082"
  }
}
EOF

python3 -m json.tool templates/lab-07-create-cluster.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-25-07.png>)

**Assume the developer role and create the cluster:**

```bash
CREDS=$(aws sts assume-role \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/usms-developer-role" \
  --role-session-name lab05a-eks-build \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)

aws sts get-caller-identity
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-25-31.png>)

**Path A — create the cluster:**

```bash
aws eks create-cluster \
  --cli-input-json file://templates/lab-07-create-cluster.json \
  --query 'cluster.{Name:name,Status:status,Version:version,Arn:arn}' \
  --output table
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-27-52.png>)

**Path B — create with k3d instead** *(only if Step 2 gave Path B)*:

```bash
k3d cluster create usms-eks-cluster \
  --servers 1 --agents 2 \
  --api-port 6443 \
  --port "8081:80@loadbalancer" \
  --port "8082:443@loadbalancer" \
  --wait

k3d cluster list
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-43-59.png>)

**Restore normal identity:**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
./scripts/utilities/whoami.sh
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 20-44-22.png>)

---

### Step 9 — Wait for the cluster, and read what it tells you

```bash
aws eks wait cluster-active --name usms-eks-cluster 2>/dev/null \
  || {
    echo "waiter unavailable - polling describe-cluster instead"
    for i in $(seq 1 60); do
      STATUS=$(aws eks describe-cluster --name usms-eks-cluster \
                 --query 'cluster.status' --output text 2>/dev/null || echo UNKNOWN)
      printf "  attempt %2d  status=%s\n" "$i" "$STATUS"
      [ "$STATUS" = ACTIVE ] && break
      sleep 10
    done
  }

aws eks describe-cluster --name usms-eks-cluster --query 'cluster.status' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-46-40.png>)

**Verify:**

```bash
aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint,
                    RoleArn:roleArn,Subnets:resourcesVpcConfig.subnetIds,
                    Sgs:resourcesVpcConfig.securityGroupIds,Vpc:resourcesVpcConfig.vpcId,
                    Tags:tags}' \
  --output json | tee outputs/lab-07-cluster.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-47-12.png>)

Check the `_lb_ports_` tag:

```bash
aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.tags._lb_ports_' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-48-10.png>)

---

### Step 10 — Create the managed node group

```bash
cat > templates/lab-07-create-nodegroup.json << EOF
{
  "clusterName": "usms-eks-cluster",
  "nodegroupName": "usms-eks-nodes",
  "scalingConfig": { "minSize": 2, "maxSize": 4, "desiredSize": 2 },
  "subnets": [ "$USMS_PRIVATE_SUBNET_A", "$USMS_PRIVATE_SUBNET_B" ],
  "instanceTypes": [ "t3.small" ],
  "amiType": "AL2023_x86_64_STANDARD",
  "nodeRole": "$(aws iam get-role --role-name usms-eks-node-role --query 'Role.Arn' --output text)",
  "labels": { "workload": "usms", "tier": "app" },
  "tags": { "Name": "usms-eks-nodes", "Project": "USMS", "Tier": "app", "Lab": "07" }
}
EOF

python3 -m json.tool templates/lab-07-create-nodegroup.json > /dev/null && echo "valid JSON"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-50-21.png>)

**Path A:**

```bash
aws eks create-nodegroup \
  --cli-input-json file://templates/lab-07-create-nodegroup.json \
  --query 'nodegroup.{Name:nodegroupName,Status:status,Desired:scalingConfig.desiredSize}' \
  --output table

aws eks wait nodegroup-active \
  --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null \
  || {
    for i in $(seq 1 60); do
      S=$(aws eks describe-nodegroup --cluster-name usms-eks-cluster \
            --nodegroup-name usms-eks-nodes --query 'nodegroup.status' --output text 2>/dev/null || echo UNKNOWN)
      printf "  attempt %2d  status=%s\n" "$i" "$S"
      [ "$S" = ACTIVE ] && break
      sleep 10
    done
  }
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-50-38.png>)

**Path B:** Agents already created via `k3d cluster create --agents 2` in Step 8. Record in notes that `usms-eks-nodes` does not exist as an AWS object.

**Verify:**

```bash
aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes \
  --query 'nodegroup.{Name:nodegroupName,Status:status,Scaling:scalingConfig,
                      Subnets:subnets,Role:nodeRole,Labels:labels,Ami:amiType}' \
  --output json | tee outputs/lab-07-nodegroup.json
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-50-52.png>)

**Checkpoint 3:**
```
usms-eks-cluster   ACTIVE, k8s 1.30, vpc usms-vpc, 4 subnets, sg usms-eks-cluster-sg
  tags: _lb_ports_=8081,8082
  └── usms-eks-nodes   ACTIVE, private-a + private-b, min 2 / max 4 / desired 2
```

---

### Step 11 — Point kubectl at the cluster

**Path A:**

```bash
aws eks update-kubeconfig --name usms-eks-cluster --alias usms-eks

kubectl config current-context
kubectl config get-contexts
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-52-57.png>)

**Path B:**

```bash
k3d kubeconfig merge usms-eks-cluster --kubeconfig-merge-default
kubectl config use-context k3d-usms-eks-cluster
kubectl config current-context
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-53-14.png>)

**Prove connectivity:**

```bash
kubectl cluster-info
kubectl get nodes -o wide
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-53-40.png>)

**Fallback if exec-plugin fails:**

```bash
k3d kubeconfig get "$(k3d cluster list --no-headers | awk '{print $1}' | head -1)" > outputs/lab-07-kubeconfig.yaml
chmod 600 outputs/lab-07-kubeconfig.yaml
export KUBECONFIG="$PWD/outputs/lab-07-kubeconfig.yaml"
kubectl cluster-info
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-53-56.png>)

```bash
git check-ignore -v outputs/lab-07-kubeconfig.yaml
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-54-10.png>)

**Verify:**

```bash
kubectl get nodes --no-headers | wc -l
kubectl auth can-i create deployments --all-namespaces
kubectl api-resources --namespaced=true -o name | head -12
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-54-25.png>)

---

### Step 12 — Create the namespace, and make it the default for your context

```bash
cat > manifests/lab-07/00-namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: usms
  labels:
    project: usms
    tier: app
    lab: "05a"
EOF

kubectl apply -f manifests/lab-07/00-namespace.yaml
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-59-31.png>)

```bash
kubectl config set-context --current --namespace=usms
kubectl config view --minify --output 'jsonpath={..namespace}'; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 20-59-49.png>)

**Verify:**

```bash
kubectl get namespace usms --show-labels
kubectl get all -n usms
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-00-03.png>)

---

### Step 13 — Deploy the first microservice: usms-enrolment

```bash
cat > manifests/lab-07/10-configmap-app.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: usms-app-config
  namespace: usms
  labels:
    project: usms
data:
  APP_ENVIRONMENT: "laboratory"
  APP_CAMPUS: "rtc"
  APP_VERSION: "1.0.0"
  APP_REGION: "us-east-1"
EOF

kubectl apply -f manifests/lab-07/10-configmap-app.yaml
kubectl get configmap usms-app-config -o jsonpath='{.data}'; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-02-02.png>)

```bash
cat > manifests/lab-07/20-enrolment.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: usms-enrolment-conf
  namespace: usms
  labels:
    app: usms-enrolment
data:
  default.conf.template: |
    server {
      listen 80;
      server_name _;

      location = /healthz {
        add_header Content-Type text/plain;
        return 200 "ok\n";
      }

      location / {
        add_header Content-Type application/json;
        return 200 '{"service":"usms-enrolment","pod":"${POD_NAME}","node":"${NODE_NAME}","env":"${APP_ENVIRONMENT}","version":"${APP_VERSION}"}\n';
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-enrolment
  namespace: usms
  labels:
    app: usms-enrolment
    project: usms
    tier: app
spec:
  replicas: 2
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: usms-enrolment
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: usms-enrolment
        project: usms
        tier: app
    spec:
      containers:
        - name: enrolment
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          envFrom:
            - configMapRef:
                name: usms-app-config
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/templates
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
      volumes:
        - name: conf
          configMap:
            name: usms-enrolment-conf
---
apiVersion: v1
kind: Service
metadata:
  name: usms-enrolment
  namespace: usms
  labels:
    app: usms-enrolment
spec:
  type: ClusterIP
  selector:
    app: usms-enrolment
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

kubectl apply -f manifests/lab-07/20-enrolment.yaml
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-02-32.png>)

**Verify:**

```bash
kubectl rollout status deployment/usms-enrolment --timeout=120s
kubectl get deploy,rs,pods,svc -l app=usms-enrolment -o wide
kubectl get endpoints usms-enrolment
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-03-13.png>)

**Prove it serves:**

```bash
kubectl run usms-curl --rm -it --restart=Never \
  --image=busybox:1.36 -- \
  wget -qO- http://usms-enrolment.usms.svc.cluster.local/
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-03-54.png>)

**Checkpoint 4:**
```
namespace usms
 ├── ConfigMap usms-app-config
 ├── ConfigMap usms-enrolment-conf
 ├── Deployment usms-enrolment    2/2 ready
 └── Service usms-enrolment       ClusterIP, 2 endpoints
```

---

### Step 14 — Deploy the second microservice: usms-results

```bash
cat > manifests/lab-07/30-results.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: usms-results-conf
  namespace: usms
  labels:
    app: usms-results
data:
  default.conf.template: |
    server {
      listen 80;
      server_name _;

      location = /healthz {
        add_header Content-Type text/plain;
        return 200 "ok\n";
      }

      location / {
        add_header Content-Type application/json;
        return 200 '{"service":"usms-results","pod":"${POD_NAME}","campus":"${APP_CAMPUS}","version":"${APP_VERSION}"}\n';
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-results
  namespace: usms
  labels:
    app: usms-results
    project: usms
    tier: app
spec:
  replicas: 2
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: usms-results
  template:
    metadata:
      labels:
        app: usms-results
        project: usms
        tier: app
    spec:
      containers:
        - name: results
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          envFrom:
            - configMapRef:
                name: usms-app-config
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/templates
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: conf
          configMap:
            name: usms-results-conf
---
apiVersion: v1
kind: Service
metadata:
  name: usms-results
  namespace: usms
  labels:
    app: usms-results
spec:
  type: ClusterIP
  selector:
    app: usms-results
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

kubectl apply -f manifests/lab-07/30-results.yaml
kubectl rollout status deployment/usms-results --timeout=120s
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-06-30.png>)

**Verify:**

```bash
kubectl get deploy -n usms -o custom-columns=\
'NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,STRATEGY:.spec.strategy.type,MAXUNAVAIL:.spec.strategy.rollingUpdate.maxUnavailable'

kubectl get endpoints -n usms
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-06-55.png>)
---

### Step 15 — Deploy the gateway, and meet cluster DNS

```bash
cat > manifests/lab-07/40-gateway.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: usms-gateway-conf
  namespace: usms
  labels:
    app: usms-gateway
data:
  default.conf.template: |
    server {
      listen 80;
      server_name _;

      location = /healthz {
        add_header Content-Type text/plain;
        return 200 "ok\n";
      }

      location = / {
        add_header Content-Type application/json;
        return 200 '{"service":"usms-gateway","pod":"${POD_NAME}","routes":["/enrolment/","/results/"]}\n';
      }

      location /enrolment/ {
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://usms-enrolment.usms.svc.cluster.local/;
      }

      location /results/ {
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://usms-results.usms.svc.cluster.local/;
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-gateway
  namespace: usms
  labels:
    app: usms-gateway
    project: usms
    tier: web
spec:
  replicas: 1
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: usms-gateway
  template:
    metadata:
      labels:
        app: usms-gateway
        project: usms
        tier: web
    spec:
      containers:
        - name: gateway
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          envFrom:
            - configMapRef:
                name: usms-app-config
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/templates
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: conf
          configMap:
            name: usms-gateway-conf
---
apiVersion: v1
kind: Service
metadata:
  name: usms-gateway
  namespace: usms
  labels:
    app: usms-gateway
spec:
  type: ClusterIP
  selector:
    app: usms-gateway
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

kubectl apply -f manifests/lab-07/40-gateway.yaml
kubectl rollout status deployment/usms-gateway --timeout=120s
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-08-29.png>)

**Verify:**

```bash
kubectl get pods -n usms -o wide
kubectl logs deploy/usms-gateway --tail=5
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-08-57.png>)

---

### Step 16 — Prove service discovery from inside the cluster

**Resolve names:**

```bash
kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  echo "--- resolving service names ---"
  nslookup usms-enrolment.usms.svc.cluster.local
  nslookup usms-results.usms.svc.cluster.local
'
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-09-28.png>)

**Go through the gateway:**

```bash
kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  G=http://usms-gateway.usms.svc.cluster.local
  echo "--- gateway root ---";      wget -qO- $G/
  echo "--- via /enrolment/ ---";   wget -qO- $G/enrolment/
  echo "--- via /results/ ---";     wget -qO- $G/results/
'
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-10-00.png>)

**Show traffic spread:**

```bash
kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  for i in $(seq 1 12); do
    wget -qO- http://usms-gateway.usms.svc.cluster.local/enrolment/
  done
' | grep -o '"pod":"[^"]*"' | sort | uniq -c
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-10-16.png>)

**Checkpoint 5:**
```
usms-gateway    1/1   ClusterIP   -> proxies BY NAME
usms-enrolment  2/2   ClusterIP   2 endpoints
usms-results    2/2   ClusterIP   2 endpoints
Proven: DNS resolves to ClusterIPs, requests spread, pod deletion is self-healing
Not yet true: nothing outside the cluster can reach any of this
```

---

### Step 17 — ConfigMaps and Secrets, and an honest account of what a Secret is

```bash
kubectl create secret generic usms-enrolment-secret \
  --namespace usms \
  --from-literal=ENROLMENT_API_TOKEN='floci-dummy-token-not-a-real-secret' \
  --from-literal=ENROLMENT_DB_PASSWORD='floci-dummy-password' \
  --dry-run=client -o yaml > manifests/lab-07/50-secret.yaml

kubectl apply -f manifests/lab-07/50-secret.yaml
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-11-39.png>)

*(Optional — keep the secret manifest out of Git):*

```bash
mv manifests/lab-07/50-secret.yaml outputs/lab-07-secret.yaml
chmod 600 outputs/lab-07-secret.yaml
git check-ignore -v outputs/lab-07-secret.yaml
```

**Demonstrate base64 is not encryption:**

```bash
kubectl get secret usms-enrolment-secret -o jsonpath='{.data.ENROLMENT_API_TOKEN}'; echo
kubectl get secret usms-enrolment-secret -o jsonpath='{.data.ENROLMENT_API_TOKEN}' | base64 -d; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-11-55.png>)

**Consume it in the Deployment:**

```bash
kubectl set env deployment/usms-enrolment \
  --from=secret/usms-enrolment-secret \
  --namespace usms

kubectl rollout status deployment/usms-enrolment --timeout=120s

kubectl get deploy usms-enrolment -o jsonpath='{.spec.template.spec.containers[0].envFrom}'; echo
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-12-35.png>)

**Verify:**

```bash
kubectl describe deployment usms-enrolment | sed -n '/Environment Variables from/,/Mounts/p'
kubectl exec deploy/usms-enrolment -- printenv | grep -E '^(APP_|ENROLMENT_)' | sort
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-12-50.png>)

---

### Step 18 — Roll out a change, then roll it back

**Make a change:**

```bash
sed -i.bak 's/APP_VERSION: "1.0.0"/APP_VERSION: "1.1.0"/' manifests/lab-07/10-configmap-app.yaml
grep APP_VERSION manifests/lab-07/10-configmap-app.yaml

kubectl apply -f manifests/lab-07/10-configmap-app.yaml
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-16-31.png>)

**Observe nothing happened yet:**

```bash
kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qO- http://usms-enrolment.usms.svc.cluster.local/
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-16-54.png>)

**Trigger the rollout:**

```bash
kubectl annotate deployment/usms-enrolment \
  usms.rtc.bt/config-revision="$(date -u +%Y%m%d%H%M%S)" \
  --overwrite

kubectl rollout status deployment/usms-enrolment --timeout=120s
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-17-06.png>)

**If that didn't roll pods, use the direct instrument:**

```bash
kubectl rollout restart deployment/usms-enrolment
kubectl rollout status deployment/usms-enrolment --timeout=120s
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-17-49.png>)

**Confirm the new configuration reached the pods:**

```bash
kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qO- http://usms-enrolment.usms.svc.cluster.local/
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-18-02.png>)

**Read history and roll back:**

```bash
kubectl rollout history deployment/usms-enrolment

kubectl get rs -n usms -l app=usms-enrolment \
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision'
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-18-15.png>)

```bash
kubectl rollout undo deployment/usms-enrolment
kubectl rollout status deployment/usms-enrolment --timeout=120s

kubectl run usms-debug --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qO- http://usms-enrolment.usms.svc.cluster.local/
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-18-51.png>)

**Restore the ConfigMap to a known state:**

```bash
sed -i.bak 's/APP_VERSION: "1.1.0"/APP_VERSION: "1.0.0"/' manifests/lab-07/10-configmap-app.yaml
kubectl apply -f manifests/lab-07/10-configmap-app.yaml
kubectl rollout restart deployment/usms-enrolment
kubectl rollout status deployment/usms-enrolment --timeout=120s
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-19-18.png>)

**Checkpoint 6:** rollout history readable; rollout undo exercised; ConfigMap restored to 1.0.0; Deployment back at 2/2.

---

### Step 19 — Break a pod deliberately, and diagnose it

**Failure 1 — bad image tag:**

```bash
kubectl set image deployment/usms-results results=nginx:this-tag-does-not-exist
sleep 20
kubectl get pods -n usms -l app=usms-results
kubectl describe pod -l app=usms-results | tail -15
```

Fix:

```bash
kubectl rollout undo deployment/usms-results
kubectl rollout status deployment/usms-results --timeout=120s
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-22-22.png>)

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-22-39.png>)

**Failure 2 — unschedulable pod:**

```bash
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: usms-toobig
  namespace: usms
  labels:
    app: usms-toobig
spec:
  containers:
    - name: toobig
      image: nginx:1.27-alpine
      resources:
        requests:
          cpu: "64"
          memory: "256Gi"
EOF

sleep 10
kubectl get pod usms-toobig
kubectl describe pod usms-toobig | tail -8
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-25-22.png>)

Clean up:

```bash
kubectl delete pod usms-toobig
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-26-37-1.png>)

**Failure 3 — crashing container:**

```bash
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: usms-crasher
  namespace: usms
  labels:
    app: usms-crasher
spec:
  containers:
    - name: crasher
      image: busybox:1.36
      command: ["sh", "-c", "echo 'usms-crasher starting'; echo 'fatal: no database configured' >&2; exit 1"]
EOF

sleep 25
kubectl get pod usms-crasher
kubectl logs usms-crasher
kubectl describe pod usms-crasher | grep -A4 'Last State'
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-26-37.png>)

```bash
kubectl logs usms-crasher --previous
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-28-21.png>)

Clean up:

```bash
kubectl delete pod usms-crasher
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-28-36.png>)

**Events overview:**

```bash
kubectl get events -n usms --sort-by=.lastTimestamp | tail -20
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-28-52.png>)

**Checkpoint 7:** ImagePullBackOff, Pending/FailedScheduling, CrashLoopBackOff each produced and diagnosed; all temporary objects deleted; usms-results back to 2/2.

---

### Step 20 — Write down the ECS comparison while both are in front of you

```bash
echo "=== ECS (Lab 04 / 05 / 06) ==="
aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,TaskDef:taskDefinition,
                        LB:length(loadBalancers),Deployments:length(deployments)}' --output table

echo "=== EKS (this lab) ==="
kubectl get deploy,svc -n usms -o wide
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-33-07.png>)

**Comparison table** *(fill in from commands above and your own understanding):*

| Question | ECS answer | Kubernetes answer |
|---|---|---|
| What holds the container spec? | Task definition (versioned revision, e.g. `usms-enrolment:N`) | Pod template inside the Deployment manifest |
| What keeps N copies alive? | ECS service scheduler, driven by `desiredCount` | Deployment → ReplicaSet controller, driven by `spec.replicas` |
| What gives it a stable name? | The ECS service name, plus the ALB DNS name / target group (Lab 05) | The Kubernetes Service (ClusterIP + DNS name `usms-enrolment.usms.svc.cluster.local`) |
| How does another service find it? | Through the ALB listener and path rules (or Cloud Map, if configured) | Cluster DNS (CoreDNS) — call the Service by name, e.g. `http://usms-enrolment` |
| What does a rolling update create? | A new deployment in the service using a new task definition revision; new tasks replace old ones | A new ReplicaSet; pods shift from the old ReplicaSet to the new one |
| Where does rollback state live? | Old task definition revisions — roll back by updating the service to a previous revision | Old ReplicaSets kept in the Deployment's revision history (`kubectl rollout undo`) |
| Which IAM role does the app code use? | The task role (`usms-ecs-task-role`) | The node role (`usms-eks-node-role`) here; on real EKS, an IRSA service-account role (`usms-enrolment-sa`) |
| What would I have to change to move to another cloud? | Almost everything — task definitions, services, ALB and IAM are all AWS-specific | Mostly the edges — node/IAM wiring, load balancer and storage classes; the manifests themselves stay the same |

**My choice for USMS, and why (2 sentences):**

> I would choose ECS for USMS, because it is a small team in one region with a workload that is quiet most of the year, and ECS gave me the same result with fewer objects, no cluster to upgrade and tighter AWS integration. Kubernetes would only be worth its extra complexity if USMS needed to be portable across clouds or grew into many more services.

---

### Step 21 — IRSA: the right way to give a pod AWS permissions

```bash
OIDC_ISSUER=$(aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || echo None)

echo "OIDC issuer: $OIDC_ISSUER"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-33-58.png>)

```bash
if [ "$OIDC_ISSUER" != "None" ] && [ -n "$OIDC_ISSUER" ]; then
  aws iam create-open-id-connect-provider \
    --url "$OIDC_ISSUER" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
    --query 'OpenIDConnectProviderArn' --output text
else
  echo "No OIDC issuer on this build - IRSA is Conceptual / Real AWS here. Record it."
fi
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-34-14.png>)

```bash
kubectl create serviceaccount usms-enrolment-sa -n usms \
  --dry-run=client -o yaml > manifests/lab-07/60-serviceaccount.yaml

kubectl apply -f manifests/lab-07/60-serviceaccount.yaml
kubectl get sa -n usms
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-34-28.png>)

**Verify:**

```bash
kubectl get sa usms-enrolment-sa -n usms -o yaml | grep -A3 'metadata:'
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null \
  || echo "list-open-id-connect-providers unsupported on this build"
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-34-40.png>)

**Notes — which of the six IRSA steps could my build complete, and which not:**

> _[write your notes here]_

---

### Step 22 — Prove that all of this survives a restart

**Record truth before restart:**

```bash
{
  echo "=== BEFORE RESTART $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  aws eks describe-cluster --name usms-eks-cluster --query 'cluster.[name,status,version]' --output text 2>/dev/null
  aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes \
    --query 'nodegroup.[nodegroupName,status,scalingConfig.desiredSize]' --output text 2>/dev/null
  kubectl get deploy -n usms -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas' --no-headers
  kubectl get svc -n usms --no-headers | awk '{print $1, $3}'
} | tee outputs/lab-07-before-restart.txt
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-38-24.png>)

**Perturb:**

```bash
./scripts/setup/floci-down.sh
sleep 5
./scripts/setup/floci-up.sh
sleep 20
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-39-21.png>)

**Read back, re-deriving everything:**

```bash
{
  echo "=== AFTER RESTART $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  CL=$(aws eks list-clusters --query 'clusters[?@==`usms-eks-cluster`] | [0]' --output text 2>/dev/null)
  echo "cluster re-derived from list-clusters: ${CL:-MISSING}"

  aws eks describe-cluster --name usms-eks-cluster --query 'cluster.[name,status,version]' --output text 2>/dev/null

  NG=$(aws eks list-nodegroups --cluster-name usms-eks-cluster --query 'nodegroups | [0]' --output text 2>/dev/null)
  echo "nodegroup re-derived from list-nodegroups: ${NG:-MISSING}"

  echo "--- kubernetes ---"
  kubectl get ns usms --no-headers 2>/dev/null | awk '{print "namespace", $1, $2}'
  kubectl get deploy -n usms -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas' --no-headers 2>/dev/null
  kubectl get cm -n usms --no-headers 2>/dev/null | awk '{print "configmap", $1}'
} | tee outputs/lab-07-after-restart.txt

echo
diff <(grep -v '^===' outputs/lab-07-before-restart.txt) \
     <(grep -v '^===\|re-derived\|^--- ' outputs/lab-07-after-restart.txt) \
  && echo "PERSISTENCE PROVEN - identical before and after" \
  || echo "differences above - read them before deciding whether they matter"
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-40-13.png>)

**Checkpoint 8:** cluster and node group re-derived from list-clusters/list-nodegroups; namespace Active; 3 Deployments ready; ConfigMaps and Secret present.

---

### Step 23 — Write configs/lab-07.env

```bash
cat > configs/lab-07.env << EOF
# Lab 07 - EKS cluster, node group and microservices
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains IDs, ARNs and names only. NO SECRETS. Safe to commit.

export USMS_EKS_CLUSTER=usms-eks-cluster
export USMS_EKS_NODEGROUP=usms-eks-nodes
export USMS_EKS_NAMESPACE=usms

export USMS_EKS_CLUSTER_ARN=$(aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.arn' --output text 2>/dev/null)
export USMS_EKS_CLUSTER_STATUS=$(aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.status' --output text 2>/dev/null)
export USMS_EKS_VERSION=$(aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.version' --output text 2>/dev/null)
export USMS_EKS_ENDPOINT=$(aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.endpoint' --output text 2>/dev/null)
export USMS_EKS_LB_PORTS=$(aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.tags._lb_ports_' --output text 2>/dev/null)

export USMS_EKS_CLUSTER_ROLE_ARN=$(aws iam get-role --role-name usms-eks-cluster-role \
  --query 'Role.Arn' --output text 2>/dev/null)
export USMS_EKS_NODE_ROLE_ARN=$(aws iam get-role --role-name usms-eks-node-role \
  --query 'Role.Arn' --output text 2>/dev/null)
export USMS_POLICY_EKS_CLUSTER=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSEKSClusterPolicy'].Arn | [0]" --output text 2>/dev/null)
export USMS_POLICY_EKS_NODE=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSEKSNodePolicy'].Arn | [0]" --output text 2>/dev/null)

export USMS_EKS_CLUSTER_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=usms-eks-cluster-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

export USMS_K8S_DEPLOY_GATEWAY=usms-gateway
export USMS_K8S_DEPLOY_ENROLMENT=usms-enrolment
export USMS_K8S_DEPLOY_RESULTS=usms-results
export USMS_K8S_SVC_GATEWAY=usms-gateway
export USMS_K8S_SVC_ENROLMENT=usms-enrolment
export USMS_K8S_SVC_RESULTS=usms-results
export USMS_K8S_CPU_REQUEST=50m
export USMS_K8S_MANIFEST_DIR=manifests/lab-07
EOF

grep -n 'export .*=$\|None' configs/lab-07.env || echo "all values populated"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-42-51.png>)

**Verify:**

```bash
source configs/lab-07.env
echo "cluster=$USMS_EKS_CLUSTER  ns=$USMS_EKS_NAMESPACE  lb_ports=$USMS_EKS_LB_PORTS"
grep -c '^export' configs/lab-07.env
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-43-07.png>)

---

### Step 24 — Commit your work

```bash
git status --short
```

```bash
git check-ignore -v outputs/lab-07-support-probe.txt
```

```bash
git add labs/lab-07-eks manifests/lab-07 policies/trust-eks-*.json \
        policies/usms-eks-*.json templates/lab-07-*.json \
        configs/lab-07.env scripts/utilities/verify-lab-07.sh \
        scripts/utilities/eks-support-probe.sh scripts/cleanup/lab-07-cleanup.sh \
        notes/lab-07-notes.md

git status --short

git commit -m "Lab 07: EKS cluster, node group and three USMS microservices

- usms-eks-cluster-role and usms-eks-node-role, with local stand-ins for the
  AWS managed policies, plus Lab 01's USMSStudentDataReadWrite on the node role
- usms-eks-cluster across all four Lab 02 subnets, usms-eks-nodes in the private pair
- namespace usms with gateway, enrolment and results Deployments and ClusterIP Services
- service discovery proven by DNS from inside the cluster
- rolling update and rollback exercised; three failure modes diagnosed
- persistence proven by re-deriving every identifier after a Floci restart"
```

**Verify:**

```bash
git log --oneline -1
git show --stat --oneline HEAD | head -25
git ls-files | grep -c '^outputs/'
```

**Checkpoint 9:** all manifests, policies, templates and `configs/lab-07.env` committed; nothing under `outputs/` staged.

---

## 6. Verification — verify-lab-07.sh

```bash
cat > scripts/utilities/verify-lab-07.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-07.env" 2>/dev/null || true

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Earlier-lab dependencies still present =="
check "Lab 01 role usms-developer-role" "aws iam get-role --role-name usms-developer-role"
check "Lab 01 policy USMSStudentDataReadWrite" \
  "test -n \"\$(aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]\" --output text)\""
check "Lab 02 usms-vpc" "aws ec2 describe-vpcs --vpc-ids ${USMS_VPC_ID:-vpc-none}"
check "Lab 02 private subnet b exists (two AZs needed)" \
  "aws ec2 describe-subnets --subnet-ids ${USMS_PRIVATE_SUBNET_B:-subnet-none}"

echo "== Lab 07 IAM and EC2 =="
check "role usms-eks-cluster-role" "aws iam get-role --role-name usms-eks-cluster-role"
check "cluster role trusts eks.amazonaws.com" \
  "test \"\$(aws iam get-role --role-name usms-eks-cluster-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)\" = eks.amazonaws.com"
check "role usms-eks-node-role" "aws iam get-role --role-name usms-eks-node-role"
check "node role trusts ec2.amazonaws.com" \
  "test \"\$(aws iam get-role --role-name usms-eks-node-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)\" = ec2.amazonaws.com"
check "node role carries Lab 01's USMSStudentDataReadWrite" \
  "aws iam list-attached-role-policies --role-name usms-eks-node-role --query 'AttachedPolicies[].PolicyName' --output text | grep -qw USMSStudentDataReadWrite"
check "usms-eks-cluster-sg is in usms-vpc" \
  "test \"\$(aws ec2 describe-security-groups --filters Name=group-name,Values=usms-eks-cluster-sg --query 'SecurityGroups[0].VpcId' --output text)\" = ${USMS_VPC_ID:-vpc-none}"

echo "== Lab 07 EKS (expect 3 failures on support Path B) =="
check "cluster usms-eks-cluster is ACTIVE" \
  "test \"\$(aws eks describe-cluster --name usms-eks-cluster --query 'cluster.status' --output text)\" = ACTIVE"
check "cluster carries the _lb_ports_ tag" \
  "aws eks describe-cluster --name usms-eks-cluster --query 'cluster.tags._lb_ports_' --output text | grep -q '8081'"
check "nodegroup usms-eks-nodes is ACTIVE" \
  "test \"\$(aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes --query 'nodegroup.status' --output text)\" = ACTIVE"

echo "== Kubernetes =="
check "kubectl reaches an API server" "kubectl version --request-timeout=10s"
check "namespace usms exists" "kubectl get namespace usms"
check "usms-enrolment has 2 ready replicas" \
  "test \"\$(kubectl get deploy usms-enrolment -n usms -o jsonpath='{.status.readyReplicas}')\" = 2"
check "usms-results has 2 ready replicas" \
  "test \"\$(kubectl get deploy usms-results -n usms -o jsonpath='{.status.readyReplicas}')\" = 2"
check "usms-gateway has 1 ready replica" \
  "test \"\$(kubectl get deploy usms-gateway -n usms -o jsonpath='{.status.readyReplicas}')\" = 1"
check "service usms-enrolment has at least 2 endpoints" \
  "test \"\$(kubectl get endpoints usms-enrolment -n usms -o jsonpath='{.subsets[0].addresses}' | grep -o 'ip' | wc -l)\" -ge 2"
check "usms-enrolment declares a cpu request (Lab 08 needs it)" \
  "kubectl get deploy usms-enrolment -n usms -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' | grep -q 'm'"

echo "== Files and Git hygiene =="
check "configs/lab-07.env exists" "test -f configs/lab-07.env"
check "configs/lab-07.env has no empty values" \
  "! grep -qE 'export [A-Z_0-9]+=$' configs/lab-07.env"
check "five or more manifests present" \
  "test \"\$(ls manifests/lab-07/*.yaml 2>/dev/null | wc -l)\" -ge 5"
check "all four Lab 07 policy documents are valid JSON" \
  "for f in policies/trust-eks-cluster.json policies/trust-eks-node.json policies/usms-eks-cluster-policy.json policies/usms-eks-node-policy.json; do python3 -m json.tool \$f >/dev/null || exit 1; done"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"
check ".gitignore uses outputs/* not outputs/" "grep -q '^outputs/\*' .gitignore"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
EOF

chmod +x scripts/utilities/verify-lab-07.sh
./scripts/utilities/verify-lab-07.sh
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-45-10.png>)

**Quick end-to-end smoke test:**

```bash
kubectl run usms-smoke --rm -it --restart=Never --image=busybox:1.36 -- sh -c '
  G=http://usms-gateway.usms.svc.cluster.local
  wget -qO- $G/ && wget -qO- $G/enrolment/ && wget -qO- $G/results/
' && echo "SMOKE TEST PASSED"
```
![alt text](<../../screenshots/Screenshot from 2026-11-04 21-45-49.png>)

---

## 7. Cleanup Script (build only — DO NOT RUN)

```bash
cat > scripts/cleanup/lab-07-cleanup.sh << 'EOF'
#!/usr/bin/env bash
# END OF COURSE ONLY. Deletes every Lab 07 resource, dependencies inside-out.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

cat <<'WARN'
This deletes:
  - Kubernetes namespace usms and everything inside it
  - EKS node group usms-eks-nodes
  - EKS cluster usms-eks-cluster
  - IAM roles usms-eks-cluster-role and usms-eks-node-role
  - IAM policies USMSEKSClusterPolicy and USMSEKSNodePolicy
  - Security group usms-eks-cluster-sg
It does NOT delete USMSStudentDataReadWrite, which Lab 03 and Lab 04 still use.
WARN

printf 'Type exactly DELETE-LAB-07 to proceed: '
read -r CONFIRM
[ "$CONFIRM" = "DELETE-LAB-07" ] || { echo "aborted"; exit 1; }

kubectl delete namespace usms --ignore-not-found --timeout=180s

aws eks delete-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null
aws eks wait nodegroup-deleted --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null || sleep 30

aws eks delete-cluster --name usms-eks-cluster 2>/dev/null
aws eks wait cluster-deleted --name usms-eks-cluster 2>/dev/null || sleep 30

for R in usms-eks-cluster-role usms-eks-node-role; do
  for P in $(aws iam list-attached-role-policies --role-name "$R" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$R" --policy-arn "$P"
  done
  aws iam delete-role --role-name "$R" 2>/dev/null
done

for N in USMSEKSClusterPolicy USMSEKSNodePolicy; do
  A=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$N'].Arn | [0]" --output text 2>/dev/null)
  [ -n "$A" ] && [ "$A" != "None" ] && aws iam delete-policy --policy-arn "$A"
done

SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=usms-eks-cluster-sg \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG"

echo "Lab 07 resources removed."
EOF

chmod +x scripts/cleanup/lab-07-cleanup.sh
bash -n scripts/cleanup/lab-07-cleanup.sh && echo "cleanup script: valid bash syntax"
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-46-36.png>)

**Final cleanup of temporary lab objects (run now):**

```bash
kubectl delete pod usms-toobig usms-crasher --ignore-not-found -n usms
kubectl delete deployment,service usms-broken --ignore-not-found -n usms
kubectl get pods -n usms
rm -f manifests/lab-07/*.bak
```

![alt text](<../../screenshots/Screenshot from 2026-11-04 21-47-06.png>)

---

## 8. Floci vs Real AWS — Summary

| Feature | Real AWS | Floci (this lab) |
|---|---|---|
| EKS control plane | Provisioned in AWS-owned account, 10–15 min | Local k3s cluster, 1–4 min |
| Kubernetes API itself | Upstream conformant | Genuinely upstream conformant |
| Managed node group | Real EC2 in your subnets | Recorded object; nodes are local containers |
| VPC CNI (real pod IPs) | Pods get real VPC IPs | Pods get k3s cluster-network addresses |
| IAM role enforcement | Enforced | Stored, not evaluated |
| IRSA / OIDC | Fully supported | Usually absent |
| KMS envelope encryption of Secrets | Configurable | Not available |
| Cost | Billed per cluster-hour + nodes | Free |

---

## 9. Lab Assessment Checklist

- [ ] Floci started, storage mode hybrid; verify-lab-02/04 passed before building
- [ ] Support path (A/B/C) probed and recorded
- [ ] Both trust policies + both permissions policies written and validated
- [ ] Cluster role / node role created with correct trust and attached policies
- [ ] `usms-eks-cluster-sg` created in Lab 02's VPC, tcp/443 from VPC CIDR
- [ ] Cluster created via `--cli-input-json`, assumed-role credentials used and restored
- [ ] Cluster ACTIVE, 4 subnets, correct VPC, `_lb_ports_` tag present
- [ ] Node group ACTIVE, private subnets only, min 2 / max 4 / desired 2
- [ ] `kubectl` connected; nodes Ready
- [ ] Namespace `usms` created and set as default context
- [ ] Three Deployments applied declaratively, all ready, CPU/memory requests set
- [ ] Readiness vs liveness distinguished in own words
- [ ] DNS-based service discovery proven; load spreading proven across ≥2 pods
- [ ] ConfigMap and Secret both used; base64 decode demonstrated
- [ ] Rolling update observed creating new ReplicaSet; rollback exercised
- [ ] ImagePullBackOff, FailedScheduling, CrashLoopBackOff each produced & diagnosed
- [ ] `verify-lab-07.sh` written and run; result recorded
- [ ] Persistence proven after Floci restart, re-derived from API
- [ ] `configs/lab-07.env` generated — 21 exports, no empty values
- [ ] `git status --short` checked before add; nothing under `outputs/` staged
- [ ] `git check-ignore -v` run and rule recorded
- [ ] Cleanup script written, syntax-checked, **not run**
- [ ] Review questions answered in prose
- [ ] Step 20 comparison table filled in
- [ ] All five exercises attempted

---

## 10. Reflection

The idea that tied this lab together for me was the spec/status controller loop. Every object I applied was a statement of desired state, and a controller kept comparing it with reality. When I deleted an enrolment pod, nobody recreated it by hand; the ReplicaSet saw two desired, one actual, and closed the gap. The same loop explained the failures in Step 19: ImagePullBackOff, FailedScheduling and CrashLoopBackOff were all the controller retrying towards a spec it could not reach, and `kubectl describe` plus events showed exactly where it was stuck.

Comparing this with Labs 04–06, ECS and Kubernetes solve the same problem with different trade-offs. ECS gave me fewer objects and tighter AWS integration; a service, a task definition and a target group were enough. Kubernetes needed more YAML and a separate CLI, but it gave me DNS-based discovery, readable rollout history and a one-command rollback, and those manifests would run on any conformant cluster.

The "one policy, three compute models" theme from Step 7 stood out most. The same `USMSStudentDataReadWrite` policy I wrote in Lab 01 has now been attached to an EC2 instance role, an ECS task role and an EKS node role. The permission never changed; only the identity carrying it did. That also showed me why IRSA matters: on a node role, every pod on the node inherits the permission, not just the one that needs it.

---

## 11. What I Built (Architecture Summary)

```
usms-eks-cluster        ACTIVE, k8s 1.30, 4 subnets, sg usms-eks-cluster-sg
  └── usms-eks-nodes    private-a + private-b, min 2 / max 4 / desired 2

namespace usms
  Deployment usms-gateway     1 replica   -> Service ClusterIP
  Deployment usms-enrolment   2 replicas  -> Service ClusterIP, 2 endpoints
  Deployment usms-results     2 replicas  -> Service ClusterIP, 2 endpoints
  ConfigMaps: usms-app-config, usms-enrolment-conf, usms-results-conf, usms-gateway-conf
  Secret: usms-enrolment-secret
  ServiceAccount: usms-enrolment-sa
```

---

