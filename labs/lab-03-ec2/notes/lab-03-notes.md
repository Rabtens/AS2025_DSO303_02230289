# Lab 03 - Review Questions

## 1. What would have happened if each of the five inputs to Step 8 was wrong or missing?

Step 8 depends on five separate inputs, and AWS validates them at two different points: at the moment you call `RunInstances`, and only later, when something tries to actually use the resource. That split is what determines whether a mistake is loud or silent.

The **subnet** is checked for existence immediately - if you pass a subnet ID that doesn't exist (or was deleted, or belongs to a different VPC), the launch call itself fails with an error before an instance is ever created. But if the subnet ID is valid and simply *wrong* - say, a private subnet instead of the intended public one - the launch succeeds without complaint. You only discover the mistake later, when you can't reach the instance from the internet, because the problem lives in the subnet's route table, not in the instance's parameters.

The **security group** behaves the same way. A nonexistent SG ID fails immediately at launch. A valid SG that simply lacks the rule you need (no inbound 22 or 80) fails silently - the instance launches cleanly, and the failure only shows up as a connection timeout when you try to use it.

The **instance profile** is validated for existence at launch time, so a typo'd or deleted profile name produces an immediate error. But if the profile exists and is simply attached to the wrong role, or a role with insufficient permissions, the instance boots without any indication of a problem. The failure is silent and deferred: it only appears when code running on the instance tries to make an AWS API call and gets `AccessDenied`.

The **key pair** is checked for existence at launch - a nonexistent key pair name fails immediately. But specifying the wrong (existing) key pair is silent: the instance launches fine, and you don't find out until you try to SSH in and authentication fails.

The **user data script** is never validated by AWS at all - a missing script, a script with a syntax error, or a script that references something that doesn't exist all produce a successful launch with no error of any kind. The failure is entirely silent and only visible if you go looking in `/var/log/cloud-init-output.log` on the instance itself.

The pattern across all five: AWS's API only validates *structural* correctness - does this ID refer to something that exists. It has no way to validate *semantic* correctness - does this thing that exists actually do what you intended. Structural mistakes fail immediately; semantic mistakes fail silently, downstream, and often much later.

## 2. Why is `USMSStudentDataReadWrite` pointing at a nonexistent bucket valid rather than broken?

IAM policies are declarative statements about what an identity is *permitted* to do against a given ARN - they are evaluated at the moment an API call is made, not at the moment the policy is written or attached. Nothing about IAM requires the resource named in a policy to exist yet. This is a deliberate separation between the permission plane (IAM) and the resource plane (S3, EC2, etc.): you can define access rules ahead of the infrastructure they'll eventually apply to.

For the instance today, this means the role attached to it genuinely has read/write rights to that bucket ARN, but that permission is latent - it has nothing to act on. If code on the instance tried to call `s3:PutObject` against that bucket right now, it would not fail with `AccessDenied` (the permission is real), it would fail with something like `NoSuchBucket`, because the resource simply isn't there. The authorization layer says yes; the resource layer says there's nothing to authorize access to.

The moment Lab 4 runs `create-bucket`, nothing changes in IAM at all - no policy edit, no re-attachment, no instance restart. What changes is that the ARN the policy already refers to becomes real. The previously latent grant is instantly exercisable, because the policy was written against the *name* the bucket would have, not against a live pointer to it. This is the most important connection in the course so far because it demonstrates that access control and infrastructure provisioning are independent processes that only need to agree on a name: you can build the permission boundary first, and the instant the resource is created - by you, by a teammate, by an automated pipeline - the correct access is already in force with zero gap in between. That's what makes IAM policies usable as part of infrastructure-as-code: permissions can be declared before the resources they govern exist.

## 3. Why doesn't putting deployment in user data let a restart redeploy the app?

User data is executed by cloud-init as part of the instance's *first* boot cycle only. Cloud-init tracks this with a semaphore file it writes to the instance's root volume (under `/var/lib/cloud/`), and on every subsequent boot it checks that semaphore and deliberately skips re-running user data. A "restart" is a reboot of the same instance with the same root volume - it is not a fresh launch - so from cloud-init's point of view, user data already ran once and there's no reason to run it again. The colleague's proposal fails because they're treating "restart" as equivalent to "re-provision," when the entire mechanism is built around the opposite assumption: user data is a one-time bootstrap, not a recurring hook.

Two approaches that actually work: first, you can deliberately opt out of the once-only behavior by placing the deployment logic somewhere cloud-init runs on *every* boot rather than only the first - a per-boot script under `/var/lib/cloud/scripts/per-boot/`, for example - which keeps the "shell script does the deploying" pattern but changes when it fires. Second, and more robustly, you can decouple deployment from the instance boot lifecycle entirely: run the application as a systemd service that pulls the current version of the code on start, or trigger deployment through a purpose-built mechanism (SSM Run Command, CodeDeploy, a CI/CD pipeline) that isn't tied to whether the instance happens to be rebooting. The cleanest version of this is immutable infrastructure - bake a new AMI for each release and replace the instance rather than asking a running instance to redeploy itself.

## 4. Auto-assigned public IP vs. Elastic IP

**Who owns it.** The auto-assigned public address is drawn from a pool AWS manages; you're using it, not holding it as an account-level resource. An Elastic IP is allocated directly to your AWS account and exists as a resource independent of any instance, until you explicitly release it.

**When it changes.** The auto-assigned address changes every time the instance stops and starts again - a fresh address is drawn from the pool on each start, so it is only stable across reboots, not across a stop/start cycle. An Elastic IP does not change on stop, start, or reboot; it stays exactly the same until you deliberately disassociate or release it.

**What it costs.** The auto-assigned public IP is free for as long as it's attached to a running instance. An Elastic IP is also free while actively associated with a running instance, but AWS charges an hourly fee for an Elastic IP that's allocated to your account but sitting idle, unassociated with a running instance - specifically to discourage people from hoarding addresses they aren't using.

**What happens when the instance stops.** The auto-assigned address is released back into AWS's general pool entirely; nothing about it is preserved for you. The Elastic IP simply becomes disassociated - it remains reserved to your account and is yours to reattach whenever you want.

**Failover this makes possible.** Because an Elastic IP is a persistent, account-owned object that can be moved between network interfaces, you can pre-allocate one, point it at a primary instance, and - if that instance fails - disassociate the EIP and re-associate it with a standby instance within seconds. Traffic aimed at that address now reaches the replacement instance immediately, with no DNS change and no propagation delay, because the address itself never moved, only which instance answers on it. This is impossible with an auto-assigned public IP, since that address is tied to the specific instance and network interface it was issued to and disappears the moment that instance stops - there's no persistent handle to redirect.

## 5. What EBS-volume-vs-snapshot AZ behavior tells you about where each is stored

An EBS volume can only attach to an instance in its own Availability Zone because the volume itself physically lives within that AZ - it's network-attached block storage, and the low-latency link between compute and storage only exists within the AZ's own network fabric. A snapshot, by contrast, is stored in S3, which is a regional service replicated across multiple AZs by design. That's why a snapshot can be restored into a new volume in *any* AZ in the region - restoring isn't moving the original volume across AZ boundaries, it's materializing a brand-new AZ-local volume out of region-level object data.

The implication for surviving the loss of an AZ is that a live EBS volume can never be the thing that protects you - it is by construction a single-AZ resource, and if that AZ goes down, the volume goes with it. Durability across AZ loss has to be built at the snapshot layer (or through application/database-level cross-AZ replication, like RDS Multi-AZ). Concretely, that means taking snapshots regularly - since they land in S3, they are already durable across AZs - so that if the AZ hosting your live volume is lost, you can restore the latest snapshot into a new volume in a surviving AZ and bring up a replacement instance there. The volume is your working copy; the snapshot is your AZ-independent insurance policy.

## 6. Is checking six configuration properties an adequate substitute for confirming reachability?

It is not an adequate substitute, though it is a useful and necessary first pass. Verifying things like security group rules, route table entries, public IP assignment, and IAM role attachment confirms that the *path* to the application is correctly built — but none of those checks look at what, if anything, is actually listening and responding at the other end of that path. Every one of those six properties can be perfectly correct while the application itself is completely non-functional.

The specific class of fault this approach cannot detect is application-level failure - the process crashed on startup, threw an unhandled exception, is listening on the wrong port, hung during initialization, or was never started at all. These are Layer 7 faults, and configuration verification operates entirely at Layers 3 and 4 (network reachability and routing). A system that passes all six configuration checks and is still completely broken at the application layer would show green across the board on this kind of audit, which is exactly the gap that only an actual reachability check - an HTTP request that expects a real response - would catch. Configuration checks are necessary but not sufficient; they rule out infrastructure misconfiguration but are blind to whether the software on top of that infrastructure actually works.

## 7. Every difference between `usms-web-01` and `usms-db-01`, and which layer each belongs to

Both instances are `t3.micro`, launched from the same AMI, so at the software/OS level they start out identical. Everything that distinguishes them comes from how each was placed and configured on top of that shared baseline:

| Difference | Belongs to |
|---|---|
| Which subnet each instance is attached to (web in the public subnet, db in the private subnet) | Instance (this is a per-instance placement choice) |
| Whether that subnet's route table sends traffic to an Internet Gateway (making the public subnet actually public) | Subnet |
| Whether the instance has a reachable public IP as a result | Subnet (auto-assign setting) combined with instance launch choice |
| Availability Zone each instance sits in | Subnet (subnets are AZ-scoped; the instance simply inherits its subnet's AZ) |
| Security group rules attached (web's SG open to 80/443 from anywhere; db's SG open to 3306 only from web's SG) | Instance (security groups attach to the instance's network interface, not the subnet) |
| IAM instance profile/role attached to each (if web has S3 access and db doesn't, for example) | Instance |
| Network ACL rules, if the two subnets use different NACLs | Subnet |
| Name/tags | Instance |
| VPC CIDR block, DNS resolution settings, DHCP options set, tenancy | Same for both - VPC (these surround both instances identically and are not a point of difference) |

The point of the question is that most of what makes these two instances behave differently isn't a property of the instances themselves at all-it's a property of *where* each was placed. The instances share an AMI and instance type; what diverges is the subnet each lives in (and everything that subnet's route table and NACL imply) and the security group and IAM role each was individually given at launch. The VPC itself contributes nothing to the difference - it's the one layer both instances have identically in common.