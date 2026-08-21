# Lab 01 — IAM Prediction

## Prediction

Before running the simulator, the predicted decisions for `usms-audit-01` are:

| Action | Predicted decision | Reason |
|---|---|---|
| `ec2:CreateVpc` | Deny | Creating a VPC is a write/change operation and is not expected to be granted to the audit user. |
| `ec2:DescribeVpcs` | Allow | Describing VPCs is a read-only EC2 operation and is expected to be granted to the audit user. |

The prediction will be checked against the available simulator.

## Floci simulator support

Floci supports EC2, so the EC2 operations can be checked through Floci. If the required simulator operation itself is unavailable, the policy JSON will be used to justify the prediction.

