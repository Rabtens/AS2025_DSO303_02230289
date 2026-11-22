# Lab 10 - Lambda Notes

## Review Questions

**1. Why shouldn't the whole USMS enrolment API move to Lambda@Edge?**

I would keep the USMS enrolment API in the Region where its data lives. Enrolment involves authenticated requests and writes to student records. Running that code at the edge would still require calls back to the regional data store, adding a network hop. Lambda@Edge also has tighter limits and lacks VPC access and custom environment variables. I would use the edge for small tasks such as rewriting URLs or checking requests before they reach the API. [AWS Lambda@Edge restrictions](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/lambda-at-edge-function-restrictions.html)

**2. Distinguish CloudFront Functions from Lambda@Edge (runtime, trigger points, capabilities, cost). Which would you use for: URI rewrite to add `/index.html`; JWT signature check; DynamoDB lookup for a redirect?**

CloudFront Functions uses a lightweight JavaScript runtime and runs on viewer requests and viewer responses. It can handle quick URL and header changes, access CloudFront KeyValueStore with runtime 2.0, and has no outbound network access. Lambda@Edge supports Node.js and Python, runs on both viewer and origin requests and responses, and can make network calls or use external libraries. CloudFront Functions is generally cheaper and is priced per invocation. Lambda@Edge charges for invocations and execution duration. [AWS comparison](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/edge-functions-choosing.html) · [CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/) · [Lambda pricing](https://aws.amazon.com/lambda/pricing/)

- **Rewrite the URI to add `/index.html`.** I would use a CloudFront Function on viewer request because the rewrite only needs the URI.
- **Check a JWT signature.** I would use Lambda@Edge on viewer request for an RSA-signed token such as RS256, so I can verify it before CloudFront serves a cache hit. A CloudFront Function could check an HS256 token if it already has the shared key, since its runtime supports HMAC-SHA256. [CloudFront Functions runtime 2.0](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/functions-javascript-runtime-20.html)
- **Look up a redirect in DynamoDB.** I would use Lambda@Edge because it can call DynamoDB over the network with the appropriate IAM permissions. I would use origin request if the redirect can be cached safely for that cache key, or viewer request if every request needs a fresh lookup.

**3. Why did Step 12 place security headers at `origin-response` rather than `viewer-response`? What requirement would force `viewer-response` instead?**

In Step 12, I used `origin-response` because the security headers were the same for everyone. CloudFront adds them before caching the response, so later cache hits already include them without another Lambda invocation. I would use `viewer-response` if a header needed to vary by request even on a cache hit, for example if I needed to set `Access-Control-Allow-Origin` based on each viewer's allowed `Origin` while serving the same cached object. [AWS guidance on choosing a trigger](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/lambda-how-to-choose-event.html)

**4. Why are the execution role (`s3:GetObject`) and the resource policy (`s3.amazonaws.com` may invoke) not redundant? What breaks if each is removed separately?**

I see these as two separate permissions. The function's resource policy lets S3 invoke the notifier's `live` alias when an upload matches the notification rule. If I remove that permission, S3 can no longer trigger the notifier. The execution role gives the running notifier permission to inspect the uploaded object. If I remove `s3:GetObject`, S3 can still invoke the notifier, but its `HeadObject` check fails and it reports the object as unreadable. [AWS guidance on service invocation permissions](https://docs.aws.amazon.com/lambda/latest/dg/permissions-function-services.html)

**5. Explain the confused-deputy attack that `--source-arn`/`--source-account` prevent. What is the equivalent mechanism from Lab 09?**

If I let `s3.amazonaws.com` invoke my notifier without limiting the source, another account could configure its own bucket to make S3 invoke my function. S3 has the permission in this case, so it acts as the confused deputy. `--source-arn` restricts the permission to my bucket, and `--source-account` checks who owns it. That second check matters because an S3 bucket ARN has no account ID, and someone could reuse the name if I delete the bucket. In Lab 09, I used `aws:SourceArn` and `aws:SourceAccount` in the ECS task role's trust policy to limit which ECS resources could cause ECS to assume the role. [AWS guidance on source conditions](https://docs.aws.amazon.com/lambda/latest/dg/permissions-function-services.html) · [Lab 09](../../lab-09-security/README.md)

**6. Step 14 set environment variables on an edge function and the call succeeded. Why is the configuration still invalid, and where does the real validation happen?**

The command succeeded because it updated `$LATEST` through the regional Lambda API, where custom environment variables are allowed. Lambda@Edge forbids custom environment variables and requires a published, numbered version. The existing published version was unaffected by the change to `$LATEST`. If I published a version with those variables and tried to associate it with a real CloudFront distribution, AWS would reject that version during association. The lab's eligibility check gave me a way to check the restriction locally in Floci. [AWS Lambda@Edge restrictions](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/lambda-at-edge-function-restrictions.html)
