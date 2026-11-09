# Lab 08 Notes - EKS Scaling and Service Exposure

## Step 3 - Ten times the traffic (four dimensions)

> I would start with **dimension 1 (horizontal, workload)**: raise the replica count of `usms-enrolment` (through the HPA's `maxReplicas`), because it is the fastest change and restarts nothing. After each increase I check `kubectl get pods` for `Pending` pods and the node's "Allocated resources". When pods start going `Pending` because the nodes are full by *requests*, I move to **dimension 3 (horizontal, infrastructure)**: raise the node group's `desiredSize`/`maxSize`, then check that the new nodes are `Ready` and the pending pods get scheduled. Only if a single pod is throttled at its 200m CPU limit or gets OOMKilled would I use **dimension 2 (vertical, workload)**, raising requests/limits and re-checking the HPA percentage, because the denominator has changed. **Dimension 4 (bigger nodes)** comes last because an instance type cannot be changed in place: I would create a new node group, cordon and drain the old one, and check that the PDBs allow the drain.

## Step 6 – When would I want Guaranteed QoS?

> I would want Guaranteed for a critical pod that must be the last one evicted under node memory pressure and needs predictable CPU, for example the single `usms-gateway` entry point or a database, accepting that it can never burst above its request.

## Step 10 – Node group scaling from the AWS side (Path B)

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

## Step 17 – Practical 2 vs Practical 4

**1. If the AWS control plane has a bad afternoon:**

> **ECS + Application Auto Scaling:** every part of the scaling loop lives in the AWS regional control plane: the CloudWatch metric, the two target-tracking alarms, Application Auto Scaling, and the ECS API that writes `desiredCount`. If that has a bad afternoon, the running tasks keep serving (the data plane is separate), but scaling is frozen at the current count. I can only debug through the same AWS APIs and console that are failing, so I have very little visibility.
>
> **EKS + HPA:** the HPA runs in the cluster's own control plane and reads from metrics-server inside the cluster, so it does not depend on CloudWatch or Application Auto Scaling. If only those services are degraded, pod scaling keeps working up to the capacity of the existing nodes. Adding nodes (`update-nodegroup-config`, ASG, EC2) still needs AWS, so new pods would sit `Pending`. If the EKS control plane itself is down, the HPA and `kubectl` stop too, but pods and kube-proxy keep serving. Overall the Kubernetes arrangement is the one I can still debug (`kubectl describe hpa`, events, `kubectl top`), as long as the API server is reachable.

**2. Which would I choose for USMS, and the strongest argument against it:**

> For USMS I would choose **ECS (on Fargate) with Application Auto Scaling**. A small team in one region gains nothing from running a cluster, node groups, metrics-server, a Cluster Autoscaler and an ingress controller. ECS gives target tracking, ALB integration and no nodes to patch. In the eight quiet months it costs only the running tasks, with no EKS control-plane fee. The strongest argument against my choice is reaction speed in the two busy months. Target tracking works on one-minute CloudWatch metrics and needs several alarm datapoints, so scale-out takes minutes. The HPA re-evaluates every 15 seconds, and its `behavior` block lets me double the pods every 15 seconds. That difference matters on enrolment day, when the spike arrives all at once.

## Exercise 5 Part 3 – ECS or Kubernetes for USMS

**ECS or Kubernetes for USMS? ECS.**

Three observations from Labs 05–08 decide it for me.

1. **Scaling needed more moving parts on EKS.** In Lab 06 one `put-scaling-policy` call (target 50%, `ScaleInCooldown` 300) created its own CloudWatch alarms and needed nothing else. Here the HPA only works if metrics-server is running *and* every container declares a CPU request. Exercise 3's `usms-reports` shows that one missing `requests.cpu` leaves the HPA at `<unknown>` and inert. On top of that, the HPA can only add pods: when the nodes fill up, pods sit `Pending` until someone runs `update-nodegroup-config` (Step 10) or installs a Cluster Autoscaler/Karpenter, which needs IRSA and was not possible on this build. ECS on Fargate has no nodes to run out of.

2. **Exposure is tidier in Kubernetes but depends on a controller.** Lab 05 took separate `elbv2` calls for the ALB, target group (`--target-type ip`), listener and a rule at priority 10. The Step 16 Ingress declares the same thing in one object with path-based precedence, which is clearly nicer. But it only does anything if an ingress controller is installed. On this local build the `alb.ingress.kubernetes.io/*` annotations were inert, so that is one more component for a small team to install, upgrade and debug.

3. **More objects to keep in sync.** This lab alone added an HPA, two PDBs, a NodePort, a LoadBalancer Service, an Ingress and a `nodeSelector`. Each one had to be copied back into `manifests/` to avoid the drift shown in Step 5. Exercise 2 showed that a PDB on a single-replica gateway quietly blocks a node drain.

For a small team in one region, with load that is quiet for eight months and busy for two, those costs buy little. Kubernetes' real advantages are the 15-second HPA loop with a `behavior` block, portable manifests, and one ALB for many services through Ingress. They would matter for a bigger platform team or a multi-cloud requirement. For USMS today, ECS with target tracking does the job with fewer ways to fail.

## Review Questions

*(Moved from Section 27 of [README.md](../README.md).)*

1. **Correct the "50% node CPU" misconception**, and explain the effect of
   halving the CPU request without changing the HPA.
   > `averageUtilization: 50` does **not** mean 50% of a node's CPU, and not 50% of the limit. It means 50% of the pod's CPU **request**, averaged across all pods of the Deployment. `usms-enrolment` requests 50m, so the target is about 25m of real CPU per pod; on a 2-vCPU node that is roughly 1.25% of the node. The HPA computes `desired = ceil(currentReplicas × currentUtil / targetUtil)`.
   >
   > If I halve the request to 25m without touching the HPA, the same real usage reads as **twice** the percentage (for example 20m used becomes 80% instead of 40%). The HPA therefore scales out earlier and to roughly twice as many replicas for the same load. At the same time the scheduler thinks each pod needs half as much, so it packs more pods per node, and those pods then compete for real CPU.

2. **10× traffic plan** using the four dimensions from Step 3, with checks
   between each step and the one dimension that cannot change in place.
   > 1. **Horizontal workload first:** raise the HPA's `maxReplicas` (for example 8 → 20) and let the HPA add pods. *Check:* `kubectl get hpa` shows a real percentage, and `kubectl get pods` shows no `Pending` pods.
   > 2. **Horizontal infrastructure** when pods go `Pending` with `Insufficient cpu`: raise the node group's `maxSize`/`desiredSize` (or let the Cluster Autoscaler/Karpenter do it). *Check:* the new nodes are `Ready`, the pending pods are scheduled, and "Allocated resources" has headroom.
   > 3. **Vertical workload** only if individual pods are throttled at the 200m limit or OOMKilled: raise requests/limits. *Check:* the rollout completes, and the HPA percentage is re-read because the denominator changed.
   > 4. **Vertical infrastructure** if pods outgrow the node size or bin-packing is poor. This is the dimension that **cannot change in place**: `instanceTypes` on a node group is fixed, so I would create a new node group with bigger instances, then cordon and drain the old one. *Check:* the PDBs allow the drain, and everything is Running on the new nodes before deleting the old group.

3. **Two consequences** of Application Auto Scaling running outside the
   workload vs the HPA running inside the cluster (at least one about
   failure).
   > **(a) Failure / shared fate.** Application Auto Scaling, CloudWatch alarms and the ECS API are separate AWS regional services *outside* the workload. If they degrade, scaling freezes even though the tasks are healthy, and I can only debug through those same services. The HPA lives *inside* the cluster's control plane and reads metrics-server, so it does not depend on CloudWatch. It does share fate with the cluster, though: if the API server or metrics-server is down, the HPA stops (it shows `<unknown>`).
   >
   > **(b) Speed and inputs.** ECS target tracking reacts to one-minute CloudWatch metrics through alarms that need several datapoints, so scale-out takes minutes, but it needs nothing installed. The HPA polls every 15 seconds and can be tuned with a `behavior` block, but only if metrics-server is installed and every container declares a CPU request. The outside service is slower but self-contained; the inside one is faster but has more prerequisites.

4. **Pending pods after an HPA scale-out** — explain with the two-control-loop
   picture, name the resolving component, and say why lowering the CPU
   request is the wrong fix.
   > There are two separate control loops. The **HPA loop** decides *how many* pods there should be and writes `replicas`; it knows nothing about node capacity. The **scheduler** decides *where* each pod goes, using the free **requested** capacity on each node. After a scale-out, if no node has 50m of unrequested CPU left, the new pods stay `Pending` with `FailedScheduling: Insufficient cpu`. The HPA has done its job; the cluster has simply run out of room.
   >
   > The component that resolves this is a **node-level autoscaler**: the **Cluster Autoscaler** (which raises the node group/ASG desired size) or **Karpenter** (which launches a right-sized EC2 instance). Both watch for `Pending` pods and add nodes. On this build, the equivalent is doing it by hand with `update-nodegroup-config`.
   >
   > Lowering the CPU request is the wrong fix because it lies to the scheduler. Pods fit on paper but still use the same real CPU, so they compete for it and get throttled. It also shrinks the HPA's denominator, so utilisation looks higher and the HPA asks for *even more* pods. It hides the capacity problem instead of solving it.

5. **NodePort vs LoadBalancer, or Service vs Ingress** — pick one pair,
   explain the distinction, and give a requirement the wrong choice would
   fail.
   > **NodePort vs LoadBalancer.** A NodePort Service opens the same port (30000–32767, here 30080) on **every** node and forwards it to the pods. A client must know a node IP. Nodes come and go, nothing health-checks the nodes on the client's behalf, and the port is non-standard. A LoadBalancer Service is built *on top of* NodePort (it still allocates a `nodePort`) and asks the cloud to provision an external load balancer (an NLB on AWS). That gives one stable DNS name on a normal port, with health checks spreading traffic across healthy targets.
   >
   > **A requirement the wrong choice fails:** "Students must reach the portal at a stable address on port 80/443 that keeps working when a node is replaced." NodePort fails this: the node IP changes and the port is 30080. In the other direction, "an internal debugging endpoint with no extra AWS cost" would be failed by LoadBalancer, which provisions and bills a whole NLB for it.

6. **`/enrolment` reachable both via the gateway and directly via Ingress** —
   argue for one design and say what you would delete.
   > I would make the **gateway the only public entry point**: the Ingress keeps just the `/` rule pointing at `usms-gateway`, and I would **delete the `/enrolment` and `/results` rules** from `usms-portal-ingress`. Both backends stay ClusterIP and are reached only through the gateway.
   >
   > With two paths to the same service, `/enrolment` behaves differently depending on which route a request takes. Anything the gateway enforces (authentication, rate limiting, logging, request validation) is bypassed by the direct Ingress route, which is a security and consistency hole. The argument for direct routing is one less network hop and no dependency on a single gateway. I would answer that by scaling the gateway to 2+ replicas (Exercise 2), not by opening a side door.

7. **`kubectl delete pod` bypassing a PDB** — why this is correct, voluntary
   vs involuntary disruption, and a scenario where the PDB would matter.
   > A PodDisruptionBudget only constrains the **Eviction API**, which is how *automated, polite* tools ask to remove a pod: `kubectl drain`, Cluster Autoscaler scale-in, managed node group upgrades. `kubectl delete pod` is a direct delete by someone with the RBAC rights to do it, and Kubernetes assumes they meant it. That is correct design: a PDB is a contract with automation, not access control. If deletes must be prevented, that is RBAC's job.
   >
   > **Voluntary** disruptions are ones someone chose through the API (drain, eviction, upgrade, scale-in), and the PDB is consulted for them. **Involuntary** disruptions nobody asked for (hardware failure, kernel panic, a lost node, a terminated instance, OOM eviction), and a PDB cannot stop them, although they still count against the budget.
   >
   > **Where the PDB matters:** during an EKS managed node group upgrade, the nodes are drained one by one. With `usms-enrolment-pdb` (`maxUnavailable: 1`) only one enrolment pod is evicted at a time, so enrolment stays up through the upgrade. With `usms-gateway-pdb` (`minAvailable: 1`) and only one gateway replica, the drain is blocked. That is why Exercise 2 scales the gateway to 2.
