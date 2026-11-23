# Lab 12 notes

## Step 16 - Your turn: Deploy reading SourceOutput instead of BuildOutput

If DeployToECS named SourceOutput as its input artifact, the ECS deploy action would
open the source archive (usms-enrolment-src.zip) and look for imagedefinitions.json
at its root. That file does not exist in the source tree: it is only produced by the
build phase into dist/, which becomes BuildOutput. The action would therefore fail
with a "file not found"-style error, and the failure would be reported in the
**Deploy** stage (DeployToECS) - not in Build, where the wiring mistake conceptually
lies. Build would still succeed, because nothing in the Build stage depends on who
consumes its output.

## Step 18 - Your turn: usms-enrolment:5

Decision: deregister a failed revision after rollback to prevent accidental reuse.
The current Floci run has no usms-enrolment:5, so no deregistration was needed.

How it would be noticed later: a scheduled check that lists ACTIVE revisions in the
family and confirms each image tag exists in ECR (script in the report). Any line
reading MISSING is a revision that would fail with CannotPullContainerError. On real
AWS, the same check could run as a Config rule or a pipeline pre-deploy step.

