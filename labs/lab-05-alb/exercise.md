## Independent Lab Exercises

All commands run from the repository root with the course env files loaded:

```bash
cd ~/aws-floci-course
for f in configs/course.env configs/lab-0{1,2,3,4,5}.env; do source "$f"; done
export AWS_PAGER=""
```

---

### Exercise 1 - Basic: a second path through the same load balancer

**Part 1 - the results target group** (same type, protocol and port as `usms-enrolment-tg`; matcher `200-399`; deregistration delay 15 s)

```bash
VPC_ID=$(aws elbv2 describe-target-groups --names "$USMS_TG_NAME" \
  --query 'TargetGroups[0].VpcId' --output text)

RESULTS_TG_ARN=$(aws elbv2 create-target-group \
  --name usms-results-tg \
  --protocol HTTP --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP --health-check-path / --health-check-port traffic-port \
  --matcher HttpCode=200-399 \
  --tags Key=Name,Value=usms-results-tg Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "RESULTS_TG_ARN = $RESULTS_TG_ARN"

aws elbv2 modify-target-group-attributes --target-group-arn "$RESULTS_TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=15 \
  --query 'Attributes[?Key==`deregistration_delay.timeout_seconds`]' --output text

aws elbv2 describe-target-groups --target-group-arns "$RESULTS_TG_ARN" \
  --query 'TargetGroups[0].{Type:TargetType,Proto:Protocol,Port:Port,Path:HealthCheckPath,Matcher:Matcher.HttpCode}' \
  --output json
```

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-19-04.png>)


**Part 2 - conditions and actions as JSON documents**

```bash
cat > templates/lab-05-ex1-results-conditions.json << 'EOF'
[
  {
    "Field": "path-pattern",
    "PathPatternConfig": {
      "Values": ["/results", "/results/*"]
    }
  }
]
EOF

cat > templates/lab-05-ex1-results-actions.json << EOF
[
  {
    "Type": "forward",
    "TargetGroupArn": "$RESULTS_TG_ARN"
  }
]
EOF

for f in templates/lab-05-ex1-results-*.json; do python3 -m json.tool "$f" > /dev/null && echo "$f valid"; done
grep -c '[$]' templates/lab-05-ex1-results-*.json
```

The conditions heredoc is quoted (`'EOF'`) because it has nothing to substitute. The actions heredoc is unquoted because `$RESULTS_TG_ARN` must be written into it, and `grep -c` prints `0` for both.

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-19-54.png>)

**Part 3 - the priority-20 rule**

```bash
LISTENER_ARN="$USMS_ALB_LISTENER_ARN"

RESULTS_RULE_ARN=$(aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 20 \
  --conditions file://templates/lab-05-ex1-results-conditions.json \
  --actions file://templates/lab-05-ex1-results-actions.json \
  --tags Key=Name,Value=usms-results-rule Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results \
  --query 'Rules[0].RuleArn' --output text)
echo "RESULTS_RULE_ARN = $RESULTS_RULE_ARN"
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 22-20-22.png>)

**Verify - rules in evaluation order, an empty target group, tags**

`describe-rules` does not promise priority order, and `Priority` is a **string**: `"10"`, `"20"` and the literal `"default"`. JMESPath's `sort_by` on a string compares text, so `"100"` would sort before `"20"`. The ordering below is therefore done in python3, numerically, with `default` last:

```bash
aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,Default:IsDefault,Paths:join(`,`,Conditions[0].PathPatternConfig.Values||`[]`),Action:Actions[0].Type,TG:Actions[0].TargetGroupArn}' \
  --output table

aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --output json | python3 -c '
import json, sys
rules = json.load(sys.stdin)["Rules"]
rules.sort(key=lambda r: (r["Priority"] == "default", 0 if r["Priority"] == "default" else int(r["Priority"])))
for r in rules: print(r["Priority"], r["Actions"][0]["Type"])'

aws elbv2 describe-target-health --target-group-arn "$RESULTS_TG_ARN" \
  --query 'length(TargetHealthDescriptions)' --output text            # 0 - empty is correct
aws elbv2 describe-target-groups --target-group-arns "$RESULTS_TG_ARN" \
  --query 'length(TargetGroups[0].LoadBalancerArns)' --output text     # 1 - attached through the rule

for a in "$RESULTS_TG_ARN" "$RESULTS_RULE_ARN"; do
  aws elbv2 describe-tags --resource-arns "$a" --query 'TagDescriptions[0].Tags[].[Key,Value]' --output text | tr '\n' ' '; echo
done
```

Observed: three entries in evaluation order: `10 fixed-response` (`/alb-health`), `20 forward` (`/results` → `usms-results-tg`), `default forward` (→ `usms-enrolment-tg`). The results target group has **0** targets and is attached to **1** load balancer, and both objects carry `Project=USMS Tier=app Lab=05 Service=results`.

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-20-58.png>)

**A request to `/results` with no targets** would match rule 20 and be forwarded to a target group with no healthy targets. The ALB has nowhere to send it, so it answers **`503 Service Temporarily Unavailable`**, the `curl` entry in the Troubleshooting Log. On this Floci build the ALB's DNS name (`*.elb.floci`) does not resolve, so the 503 could not be observed with `curl`; it is reasoned from the configuration.

Neither object is recorded in `configs/lab-05.env`; Exercise 4 removes both.

---

### Exercise 2 - Intermediate: repair the verification script you broke

**The property the failing check asserted (one sentence):** *`usms-enrolment-sg` accepts inbound traffic only from a named security group, never from a CIDR range, and that group is the one caller the architecture intends to reach the enrolment tasks.* The original line expressed that property as "the source is `usms-app-sg`", which was the intended caller in Lab 04. Lab 05's Step 13 cutover changed the intended caller to the load balancer, so the expression became false while the property did not.

**The change** in [`scripts/utilities/verify-lab-04.sh`](../../scripts/utilities/verify-lab-04.sh) (and the copy of the script in the Lab 04 README):

- **`configs/lab-05.env` is now sourced** (`2>/dev/null || true`) and `USMS_ALB_SG` is read from it, never hard-coded.
- **A helper lists every inbound source** of `usms-enrolment-sg`: group IDs *and* CIDRs.
- **Check 1 (the original check, changed):** *"usms-enrolment-sg accepts traffic only from a named group, and that group is usms-alb-sg"*. The sources must be exactly `$USMS_ALB_SG` and nothing else, so a CIDR or any second group fails it.
- **Check 2 (new, immediately after):** *"usms-app-sg is no longer a source of usms-enrolment-sg"*. A check that only asked "is `usms-alb-sg` a source?" would still pass with both rules present (cutover never done, or the old rule re-added). This one names that regression, so a failure says what came back.
- **No `configs/lab-05.env` (Lab 04 done, Lab 05 not):** the original Lab 04 form of the check runs, so the script still works for that student.
- **`set -u`:** `: "${USMS_ALB_SG:=}"` keeps a missing variable from aborting the script. Check 1 then fails readably with `(USMS_ALB_SG MISSING from configs/lab-05.env)` in its name.
- **`${BASH_SOURCE[0]}` resolution** is unchanged, so the script runs from any directory.

```bash
bash -n scripts/utilities/verify-lab-04.sh && echo "syntax OK"
./scripts/utilities/verify-lab-04.sh | grep -E "usms-enrolment-sg|usms-app-sg|PASS="
(cd ~ && ~/aws-floci-course/scripts/utilities/verify-lab-04.sh | tail -1)
./scripts/utilities/verify-lab-05.sh | tail -1
```

Observed: `PASS=39 FAIL=0` from the repository root and from `~`, and `verify-lab-05.sh` `PASS=48 FAIL=0 SKIP=1` (the SKIP is the grace-period field Floci does not store; see the Lab 05 Troubleshooting Log).

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-21-52.png>)

**Edge cases tested** (each file restored afterwards):

```bash
# Lab 04 only: hide lab-05.env -> the original check runs, no crash
mv configs/lab-05.env /tmp/lab-05.env.bak && ./scripts/utilities/verify-lab-04.sh | grep -E "sourced|PASS="; mv /tmp/lab-05.env.bak configs/lab-05.env

# USMS_ALB_SG missing under set -u -> a readable FAIL, not "unbound variable"
cp configs/lab-05.env /tmp/l5 && sed -i '/USMS_ALB_SG=/d' configs/lab-05.env
./scripts/utilities/verify-lab-04.sh 2>&1 | grep -E "named group|unbound|PASS="; cp /tmp/l5 configs/lab-05.env
```

- **No `lab-05.env`:** the original check runs. It reports FAIL *in this account* because the cutover has happened; for a student who has only done Lab 04 it passes.
- **No `USMS_ALB_SG`:** `FAIL usms-enrolment-sg accepts traffic only from a named group, and that group is usms-alb-sg (USMS_ALB_SG MISSING from configs/lab-05.env)`, with no unbound-variable abort.

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-28-05.png>)

**PASS count.** The script header now states: `PASS=39 FAIL=0` after Lab 05, `PASS=38 FAIL=0` after Lab 04 only. **An undocumented count is worse than none** because a bare `FAIL=0` is trusted at a glance. If a check is silently skipped, deleted or never reached, the script still says `FAIL=0`, and nobody notices that 38 checks ran instead of 39. A documented count turns "fewer checks than expected" into something a reader can spot.

**Commit** (only the two changed files were staged):

```bash
git add scripts/utilities/verify-lab-04.sh labs/lab-04-ecs/README.md
git commit
```

Commit `0d267f5`: *"verify-lab-04: assert the enrolment SG's caller property, not Lab 04's caller"*. The body explains that the property ("only a named group, never a CIDR, and the intended caller") still holds, and that Lab 05 changed which group is the intended caller.

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-29-29.png>)

**When updating a verification script is right, and when it hides a regression.** Updating it is right when the *architecture* changed on purpose and the check still tests the same property against the new intended state, as here, where the cutover was a planned, reviewed step and the new checks are at least as strict as the old one. It hides a regression when the check is loosened or rewritten just to make an unexpected failure go away, so that the script now agrees with whatever the system happens to be doing rather than with what it is supposed to do.

---

### Exercise 3 - Problem solving: a load balancer report tool

The script is [`scripts/utilities/usms-lb-report.sh`](../../scripts/utilities/usms-lb-report.sh). Design:

- **Four levels of calls in bash:**
  1. Load balancers, filtered with `starts_with(LoadBalancerName, 'usms-')`. The `usms-` prefix is the only name in the script.
  2. Listeners per load balancer.
  3. Rules per listener.
  4. Target health per distinct forward target group, with the healthy count from `length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])`.
- **Assembly and formatting:** results are assembled as JSON with `jq`, then **python3** formats them. Ordering rules and summarising several action types is clearer there.
- **Rule order:** `Priority` is a string, and the default rule's is the literal `"default"`. The sort key is `(1, 0)` for `"default"` and `(0, int(priority))` otherwise, so rules sort numerically and the default comes last. This is commented in the script.
- **Non-forward actions** print their own summary: `fixed-response <code>`, `redirect <code> to <proto>:<port>`, or the action type.
- **No blank rows:** a load balancer with no listeners prints `(no listeners)`, a listener with only the default rule prints `(no non-default rules)`, and an empty target group prints `(0 targets, 0 healthy)`. A target group that cannot be described prints `(unavailable)`.
- **`set -uo pipefail` without `-e`:** this is a report. One listener deleted mid-run must show as an explicit row, not abort the report for every other load balancer, so each call is checked instead.
- **Runs from any directory:** it resolves `configs/` from `${BASH_SOURCE[0]}`.
- **JSON copy:** it writes `outputs/lab-05-lb-report.json`.

```bash
chmod +x scripts/utilities/usms-lb-report.sh
bash -n scripts/utilities/usms-lb-report.sh && echo "syntax OK"

(cd ~ && ~/aws-floci-course/scripts/utilities/usms-lb-report.sh) > /tmp/lb-home.txt
(cd ~/aws-floci-course/labs/lab-05-alb && ../../scripts/utilities/usms-lb-report.sh) > /tmp/lb-lab.txt
cat /tmp/lb-home.txt
diff /tmp/lb-home.txt /tmp/lb-lab.txt && echo "IDENTICAL"
```

Output after Exercise 1:

```
usms-enrolment-alb   internet-facing  application  active  AZs=2  SGs=1
  HTTP:80
    prio  10       path-pattern  /alb-health,/alb-health/*   -> fixed-response 200
    prio  20       path-pattern  /results,/results/*         -> usms-results-tg    (0 targets, 0 healthy)
    prio  default  -             -                           -> usms-enrolment-tg  (2 targets, 2 healthy)
```

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-29-47.png>)

**With the `/alb-health` rule temporarily deleted.** It was recreated afterwards at priority 10 from the same Step 15 templates, with its original tags:

```bash
HR=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --query "Rules[?Priority=='10'].RuleArn | [0]" --output text)
aws elbv2 delete-rule --rule-arn "$HR"
./scripts/utilities/usms-lb-report.sh
aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 10 \
  --conditions file://templates/lab-05-rule-conditions.json \
  --actions file://templates/lab-05-rule-actions.json \
  --tags Key=Name,Value=usms-enrolment-health-rule Key=Project,Value=USMS Key=Lab,Value=05 \
  --query 'Rules[0].RuleArn' --output text
```

```
usms-enrolment-alb   internet-facing  application  active  AZs=2  SGs=1
  HTTP:80
    prio  20       path-pattern  /results,/results/*         -> usms-results-tg    (0 targets, 0 healthy)
    prio  default  -             -                           -> usms-enrolment-tg  (2 targets, 2 healthy)
```

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-30-10.png>)

**A load balancer with no listeners.** I created a short-lived `usms-tmp-nolistener` (internal, no listener), ran the report, then deleted it:

```
usms-tmp-nolistener  internal         application  active  AZs=2  SGs=1
  (no listeners)
```

**After Exercise 4's tidy-up** (back to the Lab 05 state):

```
usms-enrolment-alb   internet-facing  application  active  AZs=2  SGs=1
  HTTP:80
    prio  10       path-pattern  /alb-health,/alb-health/*   -> fixed-response 200
    prio  default  -             -                           -> usms-enrolment-tg  (2 targets, 2 healthy)
```

---

### Exercise 4 - Challenge: the exposure review

*To: Information Security Officer. Re: the student enrolment API.*

#### 4.1 What changed

The enrolment API used to be reachable only from inside the VPC, by the web tier calling the tasks' private addresses directly. It is now published behind an internet-facing Application Load Balancer (`usms-enrolment-alb`) in the two public subnets, which accepts HTTP on port 80 from anywhere and forwards requests to the tasks, which are still in private subnets with no public addresses. On the security groups, `usms-alb-sg` now admits tcp/80 from `0.0.0.0/0`, and `usms-enrolment-sg` was changed to admit tcp/80 **only** from `usms-alb-sg`; the earlier rule admitting the web tier (`usms-app-sg`) was removed.

#### 4.2 Internal versus internet-facing

**The case for `--scheme internal`.** In Step 5's `create-load-balancer` command, only `--scheme internet-facing` changes to `--scheme internal`.
- **What changes:**
  - The DNS name gains an `internal-` prefix and resolves only to private IPs inside `usms-vpc`, so nothing on the internet can reach it.
  - The load balancer's nodes get no public IPv4 addresses, which saves $7.30 a month (4.4).
  - It could then sit in the private subnets.
  - `usms-alb-sg`'s ingress could be narrowed from `0.0.0.0/0` to the portal's security group.
- **What does not change:** the target group, the listener and its rules, the service's load-balancer wiring, `usms-enrolment-sg` (still sourced only from `usms-alb-sg`), the tasks, and the `app/...` ResourceLabel.
- **Recommendation: `internal`.** The portal is the only client, so exposing the API to the internet adds attack surface and cost and serves no user. Note that the scheme cannot be changed in place: an internal load balancer is a new resource, created alongside and then cut over to, the same "add → prove → remove" order as Step 13.

**The other side, in two sentences.** If students' browsers call the API directly, for example a single-page portal front end or a future mobile app, the API has to be reachable from the internet anyway, and an internet-facing ALB with HTTPS and a WAF is the controlled way to do that. An internal load balancer also only works if the portal itself runs inside (or is connected to) `usms-vpc`, which would need to be confirmed first.

#### 4.3 The exposure delta

| Reachability | Before (end of Lab 04) | After (Lab 05) |
|---|---|---|
| **Who can reach the load balancer** | No load balancer existed | Anyone on the internet, tcp/80 (`usms-alb-sg`: `0.0.0.0/0`), through `usms-public-rt` → `usms-igw` |
| **Who can reach the tasks** | Members of `usms-app-sg` (i.e. `usms-web-01`), tcp/80 | Only the load balancer's nodes (members of `usms-alb-sg`), tcp/80. So **anyone on the internet, indirectly**, as HTTP requests the ALB proxies |
| **Who can reach the tasks directly** (by their own IP) | `usms-web-01` only; nothing on the internet (private subnets, `assignPublicIp=DISABLED`, no IGW route) | **Nobody** except the ALB. `usms-web-01` **lost** direct access when its rule was removed; nothing on the internet gained direct access |

**Should you be worried?** The *tasks* are no more exposed at the network level than before: they still have no public address and accept only one named group. What is new is that their **application** is now reachable by anyone, over plaintext HTTP. That is the real risk, and it is addressed by 4.2 (go internal) or 4.5 (HTTPS).

#### 4.4 Monthly cost estimate

**Sources** (US East, N. Virginia):
- **ALB:** $0.0225 per ALB-hour and $0.008 per LCU-hour, billed on the largest of four LCU dimensions. The dimensions are 25 new connections/s, 3,000 active connections/min, 1 GB processed per hour (IP/container targets), and 1,000 rule evaluations/s with the first 10 rules free. Source: <https://aws.amazon.com/elasticloadbalancing/pricing/>
- **Public IPv4:** $0.005 per in-use public IPv4 address per hour; an internet-facing ALB has one per AZ. Source: <https://aws.amazon.com/vpc/pricing/>
- **Fargate:** $0.0404784 per vCPU-hour and $0.004446 per GB-hour. Source: <https://aws.amazon.com/fargate/pricing/>
- **Hours:** 730 per month (AWS's convention).

**Idle figure (no user traffic):**

| Item | Derivation | Monthly |
|---|---|---|
| ALB hours | 730 h × $0.0225 | $16.43 |
| Public IPv4 (2 AZs) | 2 × 730 h × $0.005 | $7.30 |
| LCUs | ≈ 0 (no client requests) | $0.00 |
| **ALB idle total** | | **$23.73** |

**Under load. Assumptions, stated so they can be replaced:**
- **Normal weeks:** 10 requests/s on average, during 8 business hours × 22 working days = **176 h**.
- **Enrolment peak:** 270,000 requests in one hour, from Lab 04 Exercise 4 (10,000 students × 30 requests, 90 % in the opening window).
- **Request size:** 22 KB average per request (2 KB request + 20 KB response).
- **Keep-alive:** 10 requests per connection, and connections stay open about 60 s.

| LCU dimension (normal hour, 10 req/s) | Usage | LCUs |
|---|---|---|
| New connections | 10 ÷ 10 = 1 /s ÷ 25 | 0.04 |
| Active connections | 1 /s × 60 s = 60 /min ÷ 3,000 | 0.02 |
| **Processed bytes** | 10 × 3,600 × 22 KB = 0.792 GB/h ÷ 1 GB | **0.792** |
| Rule evaluations | 1 non-default rule, within the 10 free | 0 |

**Processed bytes dominates**, not new connections or request count, which most people guess. With keep-alive, a low-traffic API opens very few connections, but every response's bytes are counted. The same holds at the peak: 270,000 × 22 KB = 5.94 GB in the hour = **5.94 LCU**, against 7.5 new connections/s = 0.3 LCU.

| Item | Derivation | Monthly |
|---|---|---|
| ALB idle total | from above | $23.73 |
| Normal-hours LCUs | 176 h × 0.792 LCU × $0.008 | $1.12 |
| Enrolment peak hour | 1 h × 5.94 LCU × $0.008 | $0.05 |
| **ALB under load** | | **$24.89** |
| *For comparison:* 2 Fargate tasks (0.25 vCPU, 1 GB) | 2 × 730 h × (0.25 × $0.0404784 + 1 × $0.004446) | *$21.27* |

So the load balancer **costs more than the two tasks it fronts**, and almost all of it is fixed: the hourly charge plus the public IPs. Traffic adds about $1.17 a month. Going `internal` (4.2) removes the $7.30 IPv4 charge.

#### 4.5 The HTTPS plan

Two separate things must be true. **The port must be open**, which is a security-group rule. **Something must listen on it**, which is a listener with a certificate. Opening 443 without a listener gives connection refused; a listener without the rule is unreachable.

| # | Object | What it does | Provided by | Cost |
|---|---|---|---|---|
| 1 | A domain name, e.g. `enrol.<university domain>` | ACM will not issue a certificate for the `*.elb.amazonaws.com` name | **Outside AWS:** the university's existing domain and DNS administrators (or Route 53, which charges for a hosted zone) | existing domain |
| 2 | An ACM **public certificate** for that name, requested with DNS validation | Proves the ALB is `enrol.<domain>` | AWS Certificate Manager | **Free.** "ACM issues certificates at no cost for use with services integrated with ACM", which includes ELB. Only *exportable* certificates are charged |
| 3 | The ACM **validation CNAME record**, added to the domain's DNS | Proves domain ownership. It must stay in place so ACM can renew automatically (certificates are valid 198 days and renew 45 days before expiry) | **Outside AWS:** the university DNS | free |
| 4 | **Port open:** an `usms-alb-sg` ingress rule for tcp/443 from `0.0.0.0/0` (or the portal's range if internal) | Allows TLS connections to reach the ALB nodes | AWS (EC2 security groups) | free |
| 5 | **Something listening:** an `HTTPS:443` listener on `usms-enrolment-alb` with the certificate ARN and a TLS 1.2+ security policy (e.g. `ELBSecurityPolicy-TLS13-1-2-2021-06`), default action forwarding to `usms-enrolment-tg`, and the `/alb-health` rule copied onto it | Terminates TLS and forwards to the tasks | AWS (ELBv2) | no extra hourly charge |
| 6 | A DNS **CNAME** `enrol.<domain>` → the ALB's DNS name | Lets the portal and browsers use the name on the certificate | **Outside AWS:** the university DNS | free |
| 7 | **The port-80 rule:** change the HTTP:80 listener's default action to type **`redirect`** (`Protocol=HTTPS, Port=443, StatusCode=HTTP_301`) | No login request is ever served in plaintext; old links are upgraded | AWS (ELBv2) | free |

In order: 1 → 2 → 3 (wait for `ISSUED`) → 4 → 5 → 6 → test → 7. The plaintext path is only switched to a redirect after HTTPS is proven to work, the same add → prove → remove order as Step 13.

**Surprising fact:** the certificate itself costs nothing. The only spending, and the only things outside AWS, are the domain and two DNS records.

Citations:
- [Request a public certificate](https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html)
- [ACM pricing](https://aws.amazon.com/certificate-manager/pricing/)
- [Create an HTTPS listener](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html)
- [Listener redirect actions](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-listeners.html)

#### 4.6 The tidy-up: the two Exercise 1 practice objects

Dependency order: the **rule** first, because it references the target group. A target group that a listener rule still forwards to cannot be deleted (`ResourceInUse`). Then the **target group**. The `/alb-health` rule (priority 10), `usms-enrolment-tg`, the listener and the load balancer are in the KEEP column and are not touched.

**Step 1 - identify exactly what will be deleted (read-only)**

```bash
RESULTS_RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --query "Rules[?Priority=='20'].RuleArn | [0]" --output text)
RESULTS_TG_ARN=$(aws elbv2 describe-target-groups --names usms-results-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "rule: $RESULTS_RULE_ARN"; echo "tg  : $RESULTS_TG_ARN"
aws elbv2 describe-rules --rule-arns "$RESULTS_RULE_ARN" \
  --query 'Rules[0].[Priority,Conditions[0].PathPatternConfig.Values[0],Actions[0].TargetGroupArn]' --output text
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 22-31-01.png>)

**Step 2 - delete the priority-20 rule**

> **DANGER - irreversible:** deletes listener rule priority **20** (`/results` → `usms-results-tg`); it can only be recreated.
> **Scope:** only this rule. The priority-**10** `/alb-health` rule is in the KEEP column and is asserted by `verify-lab-05.sh`. Do not delete it.
> **Check first:** Step 1 must print `20  /results  ...usms-results-tg...`. If it prints `10` or `/alb-health`, stop.
> **Impact:** requests to `/results` fall through to the default rule (`usms-enrolment-tg`) instead of returning 503.

```bash
aws elbv2 delete-rule --rule-arn "$RESULTS_RULE_ARN" && echo "rule deleted"
```

**Step 3 - delete the results target group**

> **DANGER - irreversible:** deletes target group `usms-results-tg`.
> **Scope:** only this empty practice target group. `usms-enrolment-tg` (the KEEP target group the service is registered in) must not be touched.
> **Order:** run only after Step 2. While rule 20 still forwards to it, this fails with `ResourceInUse`.
> **Check first:** `$RESULTS_TG_ARN` must contain `targetgroup/usms-results-tg/`.

```bash
aws elbv2 delete-target-group --target-group-arn "$RESULTS_TG_ARN" && echo "target group deleted"
```



**Confirm**

```bash
aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" --query 'Rules[].[Priority,Actions[0].Type]' --output text
aws elbv2 describe-target-groups --names usms-results-tg 2>&1 | tail -1
./scripts/utilities/usms-lb-report.sh
./scripts/utilities/verify-lab-05.sh
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 22-31-41.png>)

Observed:
- Rules: `10 fixed-response`, `default forward`.
- `describe-target-groups`: `TargetGroupNotFound` for `usms-results-tg`.
- The report is back to the Lab 05 table.
- `verify-lab-05.sh`: **`PASS=48 FAIL=0 SKIP=1`**, and `verify-lab-04.sh` still `PASS=39 FAIL=0`.

---

### Exercise 5 - Integration: the ResourceLabel hand-off to Lab 06

The script is [`scripts/utilities/usms-resource-label.sh`](../../scripts/utilities/usms-resource-label.sh):

- **Arguments:** it takes a load balancer name and a target group name, defaulting to `usms-enrolment-alb` and `usms-enrolment-tg`.
- **Lookups:** it looks both ARNs up by name every time. It never reads `configs/lab-05.env`, and it contains no access key.
- **Two cuts, two expansions:**
  - `"${LB_ARN#*:loadbalancer/}"` (shortest-prefix removal) drops everything up to and including `loadbalancer/`, because the label wants `app/<name>/<id>` *without* that word.
  - `"${TG_ARN##*:}"` (longest-prefix removal) keeps everything after the last `:`, because the label wants `targetgroup/<name>/<id>` *including* that word.

  Both are shell parameter expansion, from the same family as Lab 04's `"${TASK_ARN##*/}"`.
- **Validation before printing:** it splits the label on `/` and checks there are exactly six segments: `app`, the LB name, a non-empty LB ID, `targetgroup`, the TG name, and a non-empty TG ID. Otherwise it exits 1 with a reason.

```bash
chmod +x scripts/utilities/usms-resource-label.sh
(cd ~ && ~/aws-floci-course/scripts/utilities/usms-resource-label.sh)
(cd ~/aws-floci-course/labs && ../scripts/utilities/usms-resource-label.sh)
./scripts/utilities/usms-resource-label.sh nope-alb; echo "rc=$?"
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 22-41-31.png>)

Observed: `app/usms-enrolment-alb/a37770efd20c447f/targetgroup/usms-enrolment-tg/2e9834daa4844b6f` from both directories, and `load balancer 'nope-alb' not found` with `rc=1`.



**Append it to `configs/lab-05.env`, derived rather than typed**

```bash
LABEL=$(./scripts/utilities/usms-resource-label.sh) && \
  printf '\n# ALBRequestCountPerTarget ResourceLabel, derived by scripts/utilities/usms-resource-label.sh (Lab 05 Exercise 5)\nexport USMS_ALB_RESOURCE_LABEL=%s\n' "$LABEL" >> configs/lab-05.env

grep -n 'export .*=$\|None' configs/lab-05.env || echo "all values populated"
grep -c '^export' configs/lab-05.env
```
![alt text](<../../screenshots/Screenshot from 2026-10-17 22-32-08.png>)

Observed: `all values populated`, export count **16** (Step 18's 15 plus `USMS_ALB_RESOURCE_LABEL`). Lab 06 Step 9 picks this variable up automatically (`using the label Lab 05 Exercise 5 recorded`).



**The measurement** (timestamps from python3, not `date -d`/`date -v`)

```bash
ts() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))'; }
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

T0=$(ts)
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --force-new-deployment \
  --query 'service.deployments[].{S:status,R:runningCount}' --output json
prev=""; stable=0
for i in $(seq 1 60); do
  deps=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" --query 'length(services[0].deployments)' --output text)
  run=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" --query 'services[0].runningCount' --output text)
  tg=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query "TargetHealthDescriptions[].join(':',[Target.Id,TargetHealth.State])" --output text | tr '\t' ' ')
  echo "poll $i: deployments=$deps running=$run targets=[$tg]"
  if [ "$deps" = 1 ] && [ "$tg" = "$prev" ] && [ "$run" = 2 ]; then stable=$((stable+1)); else stable=0; fi
  prev="$tg"; [ $stable -ge 1 ] && break; sleep 2
done
T1=$(ts)
python3 -c "import datetime,sys;f=lambda s:datetime.datetime.strptime(s,'%Y-%m-%dT%H:%M:%S.%fZ');print(round((f(sys.argv[2])-f(sys.argv[1])).total_seconds(),1))" "$T0" "$T1"
```

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-32-43.png>)

Observed: **4.9 s**. **This measurement is meaningless on this build.** `--force-new-deployment` returned a single PRIMARY deployment, and the same two task IPs (`172.19.0.3`, `172.19.0.4`) stayed `healthy` in every poll, so Floci replaced no tasks. The 4.9 s is just API round-trip time.

The **documented figure** is used instead, and AWS publishes no single number for it:
- The ECS task recommendations page says `awsvpc` mode adds launch latency for the network interface attachment.
- AWS re:Invent 2023 (CON307) says downloading and extracting the image has the largest effect on Fargate launch time.
- AWS re:Post gives **30–45 s or longer** as normal for a new Fargate task.

Adding 2 healthy checks × 30 s, a full capacity replacement is **about 90–105 s**. That is the figure Lab 06's 60 s scale-out and 300 s scale-in cooldowns are sized against.

**The readiness file** `outputs/lab-05-lab04c-readiness.txt` has one labelled line each for:
- the resource label
- the target group ARN
- the load balancer ARN
- `service/usms-ecs-cluster/usms-enrolment-svc`
- `ecs:service:DesiredCount`
- the current desired count (2)
- the recommended metric (**`ALBRequestCountPerTarget`**: it measures student demand directly and early, scales linearly, and is not distorted by an I/O-bound API idling on CPU)
- the measured time, with the "meaningless on this build" note
- the documented Fargate figure, with its sources

```bash
cat outputs/lab-05-lab04c-readiness.txt
```

![alt text](<../../screenshots/Screenshot from 2026-10-17 22-42-16.png>)

**Verifying the label without a scaling policy:** it contains both names, it has exactly six `/`-separated segments, and the first is the literal `app` (all checked by the script before it prints). **`app` is there because** the load balancer ARN's path encodes the load balancer *type*: `loadbalancer/app/...` for an Application Load Balancer. For a Network Load Balancer it would be `net` (and `gwy` for a Gateway Load Balancer), although `ALBRequestCountPerTarget` only applies to ALBs.

> **Note on committing:** `outputs/` is in `.gitignore`, and `verify-lab-05.sh` fails if any `outputs/` file is tracked, so the readiness file is recorded here rather than committed. The two scripts (`usms-lb-report.sh`, `usms-resource-label.sh`) and `configs/lab-05.env` are the files to commit.
