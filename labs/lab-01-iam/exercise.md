## Independent Lab Exercises

### Exercise 1 - The QA identity

> **Screenshot:** `aws iam get-group --group-name usms-qa` + `aws iam list-attached-group-policies --group-name usms-qa` + `aws iam list-attached-user-policies --user-name usms-qa-01` (empty)
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-37-14.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-37-29.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-37-49.png>)

### Exercise 2 - The read-only reporting policy

> **Screenshot:** `aws iam list-policies --scope Local --query "Policies[?PolicyName=='USMSReportingReadOnly']"`
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-42-10.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-42-26.png>)

### Exercise 3 - The third-party analytics role

> **Screenshot:** `aws iam get-role --role-name usms-analytics-partner-role` (MaxSessionDuration `1800`) + `assume-role` `Expiration` ~30 min ahead
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-45-38.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-45-53.png>)

### Exercise 4 - Least-privilege backup operator policy

> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-49-27.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-49-49.png>)

### Exercise 5 - Preparing the identity for Lab 2

> **Screenshot:** `aws iam list-policy-versions --output table` showing v3 as default, v1/v2 retained
>
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-53-03.png>)
> ![alt text](<../../screenshots/Screenshot from 2026-08-21 20-53-17.png>)

---