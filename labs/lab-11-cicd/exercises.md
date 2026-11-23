# Lab 11 - Exercises

## Exercise 1 - results build
usms-results-build created from templates/lab-11-results-build-project.json (source S3,
role usms-codebuild-role). Artifact build/usms-results-build.zip has service "results".
USMSCodeBuildBase covers the S3 access but not the /aws/codebuild/usms-results-build log
group; added inline policy USMSResultsBuildLogs (Floci does not enforce IAM, real AWS would).

## Exercise 2 - finally + build-summary.txt
post_build captures the smoke exit code and a finally block writes dist/build-summary.txt.
The local runner ignores finally, so locally I ran the finally commands by hand after a
failed runner; on CodeBuild a one-off override build failed in POST_BUILD and the artifact
still contained the summary with tests_exit=1 (Path A) / recorded only (Path B/C).

## Exercise 3 - robust config check + SourceArn
pre_build and smoke test 7 parse JSON with python3; build passes with 4-space and compact
JSON; fails naming expected and actual container. Trust policy now has aws:SourceAccount
and aws:SourceArn (both project ARNs).

## Exercise 4 - EventBridge trigger
templates/lab-11-eventbridge-rule.json, -targets.json, -cloudtrail-data-events.json,
policies/trust-events.json, policies/usms-events-start-pipeline.json. CloudTrail data
events -> EventBridge is Conceptual / Real AWS on Floci. See the README for what ran.

## Exercise 5 - imagedefinitions.json
Build writes dist/imagedefinitions.json (array, name from config/service.json, image from
IMAGE_URI with a default). Smoke test 8 validates it. Readiness file:
outputs/lab-11-lab08b-readiness.txt.
