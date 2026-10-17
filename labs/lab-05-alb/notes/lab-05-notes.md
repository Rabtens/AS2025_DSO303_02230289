# Lab 05  ECS Service Behind an Application Load Balancer: Review Questions

## 1. Group-referenced security rules vs. the load balancer: what do they have in common?

Both replace a list of addresses with a stable name that something else keeps up to date. A group-referenced rule such as "tcp/80 from `usms-alb-sg`" does not say *which* IPs may connect. It says "anything carrying this group", and EC2 works out the current members every time a packet arrives. The load balancer does the same for callers: clients only ever talk to `usms-enrolment-alb`'s DNS name, and the target group works out which task IPs are behind it right now, because the ECS service registers and deregisters each task as it starts and stops. In both cases the caller and the callee are decoupled from individual addresses, and the membership is maintained by an owner (EC2 for the group, the ECS service for the target group) rather than by a person editing a list. That is why both keep working unchanged when Lab 06 starts creating and destroying tasks with new private IPs.

## 2. Why is "target unhealthy" ≠ "application broken"?

A target's health state is only the load balancer's *opinion*, based on one narrow test: can the ALB, from its own nodes, reach `GET /` on the task's IP and port 80, get a `200` within 5 seconds, twice in a row (every 30 seconds)? A target can fail that test while the application is perfectly fine. Examples:
- `usms-enrolment-sg` does not admit `usms-alb-sg`, so the probe is dropped by the network.
- The health-check path or port is wrong, or the app answers `/` with a `301` or `302` instead of `200`.
- The task is still starting and has not passed the healthy threshold yet (`initial`).
- The target is `draining` because it is being stopped deliberately.

The reverse is also true: a target can be `healthy` while the application is broken in a way `/` does not exercise, e.g. its S3 calls fail with `AccessDenied` because of the task role. The health check tests the path from the ALB to the target, not the application's correctness. So "unhealthy" is a prompt to check the network, the health-check configuration and the task's state before blaming the code.

## 3. Why is there no `update-target-group-target-type`? What does that say about configuration vs. identity?

The target type (`instance`, `ip`, `lambda`, `alb`) decides what a *target* even is in that group: an instance ID, an IP address, a function. Every registered target, every health-check result and every listener or ECS service pointing at the group depends on that meaning. Changing it in place would turn every existing registration into something meaningless, e.g. an instance ID in an IP-type group. So AWS treats it as part of the target group's **identity**, fixed at `create-target-group`, like a VPC's CIDR or a task definition revision. Things like the health-check path, interval, thresholds, matcher and deregistration delay are **configuration**: they change *how* the group behaves without changing *what* it holds, so they can be modified (`modify-target-group`, `modify-target-group-attributes`). The lesson: if you need a different identity, you create a new resource and cut over to it, rather than mutating the old one. That is also why `usms-enrolment-tg` had to be type `ip` from the start: `awsvpc` tasks have their own IPs, not instance IDs.

## 4. Walk through a request in flight when its task is stopped: name every timer

1. **Deployment settings (`minimumHealthyPercent` 100 / `maximumPercent` 200).** During a deployment, ECS starts the replacement task *first*, so the desired count of 2 is never undercut, and only then picks the old task to stop.
2. **Health-check timers, for the new task.** The replacement must pass the target group's health check (`interval` 30 s, `timeout` 5 s, `healthy-threshold` 2, so about 60 s) before it is `healthy` and receives traffic. The service's **`healthCheckGracePeriodSeconds` (60 s)** stops ECS killing the new task for failing ALB health checks while it is still warming up.
3. **Deregistration delay (30 s).** ECS deregisters the old task's IP from `usms-enrolment-tg`, and the target goes `draining`. The ALB immediately stops sending it *new* requests, but lets requests already in flight finish for up to 30 s (`deregistration_delay.timeout_seconds`).
4. **`stopTimeout` (default 30 s).** After draining, ECS sends the container `SIGTERM`, so the app should finish its current work and exit. If it is still running after `stopTimeout`, ECS sends `SIGKILL`.
5. **ALB idle timeout (60 s).** This is the separate limit on how long the ALB keeps an idle client connection open. A request that is still running when the deregistration delay or `stopTimeout` runs out is cut off, so long requests need the delay to be longer than the slowest normal request.

So the request in flight survives as long as it finishes within the 30 s deregistration delay. The order (start new → healthy → drain old → `SIGTERM` → `SIGKILL`) is what makes the deployment drop no traffic.

## 5. Should `verify-lab-04.sh`'s failing check be fixed immediately or left documented? Both sides

**Fix it now.** A verification script that is "expected" to fail trains people to ignore red output. The next real failure in Lab 04's checks will be hidden behind the one everyone has learned to skip, and `FAIL=1` no longer means anything at a glance. The check also now encodes a false statement about the intended design: after the Step 13 cutover, the correct state is "sourced from `usms-alb-sg`", so the check should be updated to assert that.

**Leave it documented.** `verify-lab-04.sh` describes *Lab 04's* end state, and that end state was correct when Lab 04 finished. Rewriting it in Lab 05 erases the evidence of what changed and why. The one failing check is precisely the proof that the cutover happened: the Step 13 diff (`PASS=49 FAIL=0` → `PASS=48 FAIL=1`) shows exactly one intended change and nothing else. Each lab's script should stay a faithful record of its lab.

**My view:** leave Lab 04's script as it is, but do not leave the failure unexplained. Document it in the Lab 05 report, and let `verify-lab-05.sh` own the new truth (its "cutover done: `usms-enrolment-sg` no longer admits `usms-app-sg`" check). The history is kept, and a script that does pass describes the current design.

## 6. How can the ALB be internet-facing while the tasks have no public address?

The load balancer is a reverse proxy: it terminates the client's connection and opens a **new** connection to the target. `usms-enrolment-alb` is `internet-facing` with its nodes in the **public** subnets (`usms-public-subnet-a` and `-b`, whose route table has `0.0.0.0/0 → usms-igw`), so those nodes have public addresses and accept traffic from the internet on tcp/80 (`usms-alb-sg` allows `0.0.0.0/0`). Each node also has a private IP inside `usms-vpc`. When it forwards a request, it connects from that private IP to the task's private IP in `usms-private-subnet-a` and `-b` over the VPC's local route. `usms-enrolment-sg` admits that connection because the source carries `usms-alb-sg`. The tasks run with `assignPublicIp=DISABLED` and their route table has no route to the internet gateway, so nothing on the internet can reach them directly. They only *receive* traffic from the ALB, and their own outbound traffic (image pulls) leaves through the NAT gateway. "Internet-facing" describes the load balancer's front side only.

## 7. Why is request-count a better scaling signal than CPU for a web API?

`ALBRequestCountPerTarget` measures **demand** directly: how many requests each task is being asked to serve. CPU measures a **side effect** of that demand, and only indirectly:
- A web API like the enrolment service mostly spends its time waiting on I/O (S3, the database, the network), so it can be overloaded on latency, connections or worker threads while CPU still looks low, and a CPU policy never fires.
- CPU also reacts late. It only rises once requests are already queuing on the existing tasks, while request count rises the moment traffic arrives at the ALB, which matters for a spike like 08:00 on enrolment Monday.
- It is also easier to reason about: if one task can serve about 25 requests per second, a target of, say, 20 requests per target leaves headroom, and the number of tasks needed is simply total requests ÷ target. A CPU percentage does not translate into "how many students can enrol" in a way anyone can plan with.
- Finally, it measures only the traffic coming through the load balancer, so background work on a task does not cause scaling.

CPU is still worth keeping as a safety net for CPU-heavy requests, but the main signal should be the one that measures what users are doing.
