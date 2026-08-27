# Review Questions - lab-01
 
## 1. Trust vs Permissions
 
A role needs two separate things: a trust policy and a permissions policy. The trust policy defines who or what is allowed to assume the role, while the permissions policy defines what the role is allowed to do after it has been assumed.
 
If the permissions policy is correct but nobody can use the role, the trust policy is most likely missing or does not trust the intended principal. IAM separates these documents because authentication/role assumption and authorization are different security decisions. This separation allows an administrator to control both who can obtain temporary credentials and what those credentials can access.
 
## 2. Explicit vs Implicit Deny
 
The two `AccessDenied` errors may look identical to the user, but they can have different causes.
 
- If `usms-dev-01` tries `iam:CreateUser` and an **explicit Deny** statement applies, the action is blocked even if another policy grants the permission.
- For `dynamodb:PutItem`, an **implicit deny** could simply mean that no applicable policy grants that action.
These can be distinguished by inspecting all applicable identity policies, resource policies, permission boundaries, and other IAM controls, or by using an IAM policy simulator in real AWS. The fixes are different: an explicit deny must be removed or changed, while an implicit deny normally requires an appropriate Allow statement.
 
## 3. Roles Over Keys
 
Attaching `usms-ec2-app-role` to the server is more secure than putting `usms-dev-01`'s access key in the application's configuration file for two main reasons:
 
1. **Temporary credentials** — IAM roles provide temporary credentials, reducing the risk of long-lived credentials being exposed or accidentally committed to source code.
2. **Least privilege** — The role can be given least-privilege permissions specifically for the application's needs, such as read-only access to a particular S3 bucket.
If a developer's access key were used, the application could potentially inherit permissions that are intended for the developer rather than the application itself. Roles also make credential rotation and management easier because the application does not need a permanent secret stored in its configuration.
 
## 4. The S3 ARN Trap
 
The problem occurs because S3 uses different ARN formats for the bucket itself and the objects inside the bucket.
 
`s3:ListBucket` operates on the bucket resource, so the bucket ARN is correct:
 
```
arn:aws:s3:::usms-student-data
```
 
However, `s3:GetObject` operates on objects inside the bucket. Therefore, it needs an object ARN with `/*` at the end:
 
```
arn:aws:s3:::usms-student-data/*
```
 
The corrected policy therefore needs the bucket ARN for `s3:ListBucket` and the object ARN for `s3:GetObject`.
 
## 5. The Floci Illusion
 
A successful command in Floci does not necessarily prove that an IAM policy is correct because Floci may accept API operations without reproducing every authorization behaviour of real AWS IAM. Therefore, successful resource creation or API calls can sometimes demonstrate only that the request was accepted by the emulator, not that the same request would be authorized correctly in AWS.
 
Two useful techniques for gaining confidence before deploying a policy are:
 
- Using the **IAM Policy Simulator** to test specific actions and resources
- Reviewing the policy manually against least-privilege requirements, checking the `Effect`, `Action`, `Resource`, and applicable conditions
Testing both actions that should succeed and actions that should be denied is especially useful.
 
## 6. The Persistence Trap
 
Creating the directory with `--persist` does not by itself prove that IAM state is actually being persisted. The users could disappear for at least three independent reasons:
 
- Floci may not have been started with the correct persistent data directory
- The persistent directory may not have been correctly mounted or used by the container
- The IAM state may not actually be included in the persisted data used by that Floci setup
The quickest test would have been to create an IAM user, stop/restart Floci, and then query for the same user. If the user still existed after the restart, persistence was working. If the user disappeared, the persistence configuration was not functioning as expected. This test checks the actual resource state rather than simply checking whether a directory exists.
 
## 7. Configuration as Evidence
 
A committed `docker-compose.yml` is both a security and reproducibility property because it records how the environment is intended to be started, including services, ports, volumes, networks, and persistence configuration.
 
An instructor or colleague can inspect the repository and verify that the same configuration can be reproduced rather than relying on an undocumented command that was typed manually. They can also identify important configuration decisions, such as whether persistent storage was mounted correctly and whether services were connected to the expected networks.
 
This makes the environment auditable and repeatable and provides evidence of how the lab was actually configured, rather than only showing that it happened to work on one machine.
 