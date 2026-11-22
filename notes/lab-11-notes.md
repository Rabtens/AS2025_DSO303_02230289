Lab 11 CI/CD support path: A

Step 12: build stuck in PROVISIONING for 4 minutes, stopped (Path B/C behaviour).
## Step 15 - PassRole with Resource "*"
The condition iam:PassedToService only pins the receiving service. With Resource "*",
any role trusted by codebuild.amazonaws.com (e.g. an admin role someone made assumable
by CodeBuild) could be passed to a project I control and used to run arbitrary commands
with its permissions. Only the Resource list limits which role can be handed over.

Step 12: build stuck in PROVISIONING for 4 minutes, stopped (Path B/C behaviour).

## Exercise 3 — CodeBuild role trust

`aws:SourceAccount` allows CodeBuild to assume the role on behalf of any
project in the account. An actor who can associate this role with another
same-account project could otherwise use that project to run builds with the
role's artifact-bucket permissions. The `aws:SourceArn` allowlist limits the
trust to the enrolment and results projects, which both need the shared role.
The trust update was accepted by Floci. IAM enforcement was not exercised.
