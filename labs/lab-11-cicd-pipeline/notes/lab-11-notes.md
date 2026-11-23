## Review Questions and Answers

**Q1. Source and Build both succeed but the deployed application is unchanged. Give two explanations (one involving `artifacts.base-directory`, one involving the source zip's layout) and how to distinguish them with one command each.**

*Explanation 1 - `base-directory`.* If `base-directory` is missing or wrong, the build "succeeds" but the output artifact either has everything nested under `dist/` or contains the unbuilt tree. The deploy step then looks for `imagedefinitions.json` or `index.html` at the artifact root, does not find the new file, and the service keeps what it had. *Distinguish with:* `unzip -l outputs/lab-11-buildoutput.zip` on the downloaded `BuildOutput` - paths starting with `dist/` (or `src/`) reveal it.

*Explanation 2 - source zip layout.* If the zip was built from the wrong directory - for example it contains the new files under `app/` while stale copies of `buildspec.yml` and `VERSION` sit at the root, or it was packed before the edit - CodeBuild happily builds the **root-level, old** content. Every stage is green; the build faithfully built the wrong source. *Distinguish with:* `unzip -l outputs/usms-enrolment-src.zip` (or on the `SourceOutput` object) - a nested `app/` prefix or an unchanged `VERSION` reveals it. The first problem is visible in the output artifact, the second already in the input artifact.

**Q2. Why does CodePipeline require versioning on an S3 source bucket? (In terms of what an execution needs to record about itself.)**

An execution must be able to say *exactly which bytes it started from* and must use those same bytes for every later stage and retry. In an unversioned bucket a key is just a mutable name: between the moment the Source action observed a change and the moment it (or a retried stage) reads the object, someone could overwrite it, and the execution would have no identifier for what it actually consumed. With versioning, the Source action records the object's **version ID** as the execution's source revision (`CODEBUILD_RESOLVED_SOURCE_VERSION` downstream), pins the `SourceOutput` to it, and change detection itself becomes "has the version ID changed?". Versioning turns "the file at this key" into "this immutable revision", which is what an execution history is made of.

**Q3. Explain `iam:PassRole` to someone who thinks it is redundant.**

Their objection is reasonable: if I may create the project, why a second permission for its role? Because *creating* a project and *choosing what authority it runs with* are different powers. A CodeBuild project runs arbitrary commands with its service role's permissions. If "create project" implied "use any role", then anyone allowed to create a harmless build project could name the account's administrator role (any role trusted by CodeBuild) and run `aws iam create-user …` inside the build - a privilege escalation from "can configure builds" to "is admin". `iam:PassRole` separates **configuration rights** from **delegation rights**: you may create the project, but you may only attach roles you have been explicitly allowed to hand over, and `iam:PassedToService` restricts which service may receive them. In this lab the pipeline may pass exactly one role (`usms-codebuild-role`) to exactly one service (CodeBuild).

**Q4. Argue for the two-role design, then give the strongest argument against it.**

*For:* the two principals have different jobs and different exposure. The build container executes code from the repository and its dependencies - the most likely thing in the system to be compromised - so it should hold the least: its own log group and the artifact bucket. The pipeline orchestrates: it starts builds, reads every artifact and passes roles, but runs no user code. With separate roles a compromised build cannot start other builds, pass roles or (in Lab 12) update ECS services; blast radii stay separate, policies stay readable and each can be audited against its own job.

*Against:* the separation is weaker than it looks. The build already writes the artifact that the pipeline will deploy, so an attacker who controls the build controls what gets deployed regardless of which role runs the deploy; the security boundary that really matters is who can change the source. Meanwhile two roles, two policies, a PassRole statement and two trust policies are twice the surface for drift and misconfiguration (as the missing results-build log group in Exercise 1 showed), and a single well-scoped role would be easier to reason about in a small system.

**Q5. For each heredoc form, what breaks if it were the other form, and why no error tells you?**

- **`<< 'BUILDSPEC'` (quoted) → if unquoted:** my shell expands `$USMS_RELEASE`, `$ARTIFACT_DIR`, `${CODEBUILD_BUILD_ID:-local}` at write time, and even runs `$(tr … < VERSION)` and `$(date …)` right then. The buildspec lands with empty variables and a frozen release/timestamp. It is still valid YAML and valid shell, the placeholders are replaced with empty strings (so the "placeholder replaced" tests even pass) - nothing errors; the build just stops meaning anything.
- **`<< META` (unquoted, inside) → if quoted:** `build-metadata.json` is written containing the literal text `"$USMS_RELEASE"`, `"${CODEBUILD_BUILD_ID:-local}"`. That is still valid JSON, so the smoke test "metadata is valid JSON" passes and no error appears - but the metadata no longer records anything, and Step 19's proof silently loses its evidence.
- **`<< EOF` in Step 21 (unquoted) → if quoted:** `configs/lab-11.env` contains the `$(aws …)` commands themselves. Sourcing it still works - it just re-runs AWS calls every time and records whatever is true *then*, not what was true when the lab finished; with Floci down it yields empty values. No syntax is wrong, so nothing complains.

In all three cases the shell is doing exactly what it was told; the mistake is in *when* expansion happens, and the result is well-formed text. **Quoted heredoc writes the text; unquoted heredoc writes the result.**

**Q6. When is the colleague right to remove `pre_build` validation, and when expensively wrong?**

*Right* when the deploy stage is cheap, fast, early and safe: it performs exactly the same check, fails before any change reaches running tasks (or rolls back automatically), produces a clear message, and there is only one deployment target - then the duplicate check only adds maintenance.

*Expensively wrong* when a failure at deploy time costs more than a failure at build time: when the image has already been built and pushed (minutes and registry clutter), when the deploy stage fails with a message that does not name the cause (Lab 12's container-name mismatch does not mention the container), when a half-applied deployment or rollback affects live users of the student-records system, when the same artifact feeds several targets (ECS and EKS), or when the deploy-time check is weaker or changes later. `pre_build` fails in ninety seconds with a precise message before anything is produced; the deploy stage fails after everything is.

**Q7. Evidence chain for an auditor that r4 was built from the repository source on a given date, and the weakest link.**

1. The **git commit** in the repository on that date containing `VERSION = r4` (`git log -p -- labs/lab-11-cicd/app/VERSION`).
2. The **S3 object version** of `source/usms-enrolment-src.zip` with its `LastModified` timestamp (`list-object-versions`) - the older version is still retrievable, so its contents can be unzipped and compared to the commit.
3. The **pipeline execution** that consumed that version: Source action summary records the S3 version ID (`get-pipeline-state` / `list-pipeline-executions`).
4. The **CodeBuild build** for that execution: build ID and `resolvedSourceVersion` in `batch-get-builds`, plus phases/logs.
5. The **build artifact** in `BuildOutput`, whose `build-metadata.json` records `release: r4`, `buildId`, `sourceVersion` matching step 2, and `builtAt`.

**Weakest link:** step 1 → step 2. The zip is packed **by hand from my working tree** with `usms-pack-source.sh` and uploaded manually; nothing records which git commit (or whether uncommitted edits) went into it. The chain from S3 version to artifact is machine-recorded; the chain from repository to S3 version rests on my say-so. (Fix: have the packer write `git rev-parse HEAD` and a clean-tree check into the zip and into `build-metadata.json`, or use a Git-based source.)

