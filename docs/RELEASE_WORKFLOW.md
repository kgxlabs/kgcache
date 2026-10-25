# Release workflow

**Release candidate qualification** supports manual previews and automatic
publication from registered release branches. Publication starts disabled in
[release automation settings](../.github/release-automation.json).

Manual previews stay read-only even after publication is enabled. They build
and test a chosen source/version pair and retain its image. They never create
Git tags, GitHub releases, or registry uploads. The development version in
`build.zig.zon` does not change.

## Run a manual preview

1. Open **Actions**, then **Release candidate qualification**.
2. Select **Run workflow**. Choose the branch containing the workflow.
3. Set `source_ref` to a branch, tag, or full commit SHA.
4. Optionally set `release_line` or a complete SemVer `version`.
5. Check source qualification and saved-image transfer verification.

Confirm that both jobs ran and passed, and that **Verify release workflow
completion** passed. A skipped qualification or transfer makes that final check
fail. Publishing jobs stay skipped for manual previews. After workflow changes,
start a new manual run to use the merged workflow definition.

```sh
gh workflow run release.yml --ref main \
  -f source_ref=YOUR_WORKING_BRANCH \
  -f version=0.2.0-rc.1+local.001
```

This version labels test artifacts. It reserves no release number. Without a
line or explicit version, the preview uses the selected source's development
version. Repeated previews may reuse the same version.

The workflow reads trusted tooling from main. Qualification and client profiles
come from the exact selected source. That source must contain the candidate and
transfer tooling. Previews at existing tags remain previews.

## Verify an uploaded testing image

**Registry image verification** checks Docker Hub transport without creating a
release. First verify and upload the retained preview image to
`docker.io/kgxlabs/kgcachetesting:ci-RUN_ID`, using its original preview run ID.
Use the saved image, without rebuilding it or assigning a release-version tag.

Open **Actions**, then **Registry image verification**, and select **Run
workflow** on main. Set `candidate_run_id` to that successful main preview run.
Keep `credential_repository` set to `testing` while using the testing PAT.
Its selected source must belong to main history. The workflow downloads the
candidate and its independent transfer receipt. It checks their identity, then
pulls the testing image by digest into a fresh native Linux amd64 image store.
It verifies the image and runs the prepared-image service and client checks.

The image job has no publishing credentials or release environment. Its result
is marked non-publishing. Missing or expired evidence stops verification.

Manual runs on protected main also check the publisher App and Docker Hub
credentials through the `release` environment. The App must authenticate with
the configured permissions. Docker Hub must issue pull and push grants for the
chosen repository. No image upload or release operation is attempted.

After changing App permissions, approve the update for its installation. Merge
the matching workflow changes, then start a new manual run from main. Rerunning
an older run uses its original workflow permissions.

After replacing the Docker PAT, choose `production` to verify the replacement.
Leave `candidate_run_id` empty to check credentials alone. This is separate
from proving registry image transport. The final job rejects missing requested
checks. Both modes leave release versions and publication state unchanged.

For workflow changes before merge, push a working branch named
`ci/registry-check/RUN_ID`. This starts the same read-only verification for an
already uploaded test image. The branch suffix identifies a CI run, not a
release version. No `release/*` branch is needed.

## Configure publication

Complete setup through reviewed changes before enabling production writes.
Do not cut a production branch or create a GitHub version to test local changes.
The local fixtures below cover tags, registry writes, and release API recovery.

1. Install a dedicated GitHub App on this repository. Grant Contents write,
   Pull requests read, Administration write, and Actions read. Administration
   write is needed to inspect ruleset bypass lists. It also lets the App change
   protections, although the release tooling only reads these settings. Restrict
   its installation to this repository. Approve permission updates on the
   installation before running workflows that request them.
2. Create the `release` Actions environment. Store `RELEASE_APP_PRIVATE_KEY` and
   `DOCKERHUB_TOKEN` as secrets. Set `RELEASE_APP_ID` and `DOCKERHUB_USERNAME` as
   variables. Keep publisher credentials out of qualification jobs.
   Allow deployment branches `release/*` and `main`. Publication uses release
   branches. Only manual credential checks on protected main use the main rule.
3. Protect main and `release/*` with active rulesets. Require PRs, dismissal of
   stale approvals, resolved review threads, and squash merging.
   Require linear history, block deletion and force pushes, and set
   strict required checks. Use the exact contexts and integration IDs in the
   settings file. Release branches need the main checks plus **Maintenance
   compatibility**. No actor may bypass these merge rules.
   Keep the base PR rule at zero approvals. Add a separate review ruleset with
   one required approval. Only the account in `review_bypass` may bypass that
   ruleset, using **For pull requests only**. Classic protection must also require
   one approval and allow only that account to bypass reviews.
   The review collector checks this account's administration access before
   accepting a merge without approval. Other mergers need an independent maintainer approval.
   Unresolved maintainer change requests still stop admission.
   To restore review for everyone, remove `review_bypass` and its GitHub bypass
   entries, then require one approval in the base PR rule.
4. Protect `release-state` with creation, update, deletion, and force-push
   restrictions. Its only bypass actor must be the publisher App, with mode
   **Always**. Contributors and the normal Actions token must not update it.
5. Protect `v*` tags with creation, update, and deletion restrictions. Its only
   bypass actor must be the same App. Record this tag ruleset's ID in settings.
   The automation never replaces or deletes a version tag.
6. Choose an owned, public Docker Hub repository. Scope its automation token to
   that destination where supported. Use selected-tag immutability for full
   version and `src-*` tags. Keep line and `latest` aliases mutable. Do not use
   an all-tags-immutable policy with moving aliases.
7. Set the repository slug, App ID, tag ruleset ID, owned registry, and UTC
   `enforcement_since` in settings. This time is the reviewed baseline after
   the protections became active. Existing branches from before that baseline
   need a reviewed migration. They cannot enter automatically.
8. Enable publication only after local checks and native CI pass. The first
   intended branch operation initializes `release-state` if absent, reports its
   root SHA, and stops. Review that root, pin `state_root_sha` through a main PR,
   and rerun the original workflow. This is a one-time trust setup. It creates
   no version tag or release.

The configured rehearsal image destination is `docker.io/kgxlabs/kgcachetesting`.
It grants no permission to create test GitHub tags or releases. Routine tests
use a temporary local registry and a loopback API instead.

The collector verifies effective main/release rules, covering ruleset bypass
lists, state restrictions, and version-tag restrictions. A changed enforcement
fingerprint stops admission. Review the change before reconciling its baseline.
Missing state, an unpinned root, and retired or blocked versions stop writes.

See [GitHub branch rules](https://docs.github.com/en/rest/repos/rules) and
[Docker immutable tags](https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/).

## Request a release

1. Choose a stable main commit. Review scope, compatibility, upgrade steps,
   known limits, and release notes.
2. Register the line in [release-lines.json](../.github/release-lines.json)
   through a reviewed main PR. Record the exact cut SHA and canonical branch
   name, such as `release/0.2`. Set `decision_ref` to that PR's full URL.
3. Set `notes_ref` to a reviewed repository file path. Its content at the pinned
   main policy commit becomes release notes. It must be nonempty. Use it to
   explain compatibility and migration needs.
4. Merge registration before creating the branch at its exact cut SHA.
5. Inspect the resulting workflow. With publication disabled, it only qualifies.
   With complete activation, the branch operation requests publication.

`release/0.2` is a branch for one maintenance line. `v0.2.0` is an immutable tag
for one release. The first automatic regular version for this line is `0.2.0`.
A `release/0.0` line starts at `0.0.0`. Choose the intended starting line and
channel in reviewed policy. Manual preview versions do not affect this choice.

The coordinator stores requests by repository, branch, and exact source SHA.
Duplicate create/push deliveries and reruns recover that identity. GitHub
activity proves initial creation and prior registration once. Later updates
use stored progression and current enforced PR rules, without replaying all
historical approvals.

## Merge a patch or prepare a breaking change

Follow the [backport guide](../CONTRIBUTING.md#backport-a-compatible-fix).
Merge the fix on main first. Cherry-pick its squash commit with `-x` into a
working branch based on the supported release line. Review and squash its PR
into that line. Preserve the full cherry-pick reference in the final message.

CI checks the merged PR, source order, declared compatibility, and main-first
references. A later branch tip cannot replace the event commit. Once `0.2.0`
is complete and policy marks the line supported, the next accepted update
receives `0.2.1`. Necessary compatible maintenance may have no main fix reference.

New features and breaking changes stay on main for a new release line. Before
1.0, review compatibility and choose the next minor line explicitly. From 1.0,
breaking changes require a new major line. Conventional Commit markers help
reject declared breaking backports. Reviewers still judge actual compatibility.

A prerelease line uses policy's target version and prefix, such as
`0.3.0-rc.1`. Each accepted request advances its counter. Graduation to a regular
release needs a reviewed channel change. Prereleases never update normal aliases.

## Follow the publication stages

| Stage | Responsibility |
| --- | --- |
| Registration, branch cut, or backport merge | Maintainer review requests release. |
| Durable admission and allocation | CI verifies current policy and rules, then stores one ordered request/version. |
| Qualification and transfer | Read-only native runners build, run the pinned client profiles, save the image, and verify its transfer. |
| Tag and transport upload | Publisher stores qualification and tag intent, atomically reserves the annotated tag, and uploads the saved image. |
| Registry verification | A separate native runner pulls the digest into a fresh image store and runs prepared-image service/client checks. It has no publishing credential. |
| Fixed publication | Publisher verifies the receipt, assigns full-version and source/version image tags, then creates a draft and checks every downloaded asset. |
| Release and aliases | CI publishes with `make_latest: false`, then advances eligible Docker line/latest and GitHub latest pointers. |

The actual registry digest must describe the retained image configuration.
Only Linux amd64 is published. Fixed tags with other content are conflicts.
Release assets are `build-info.json`, `release-info.json`, `qualification.json`,
and `SHA256SUMS`. GitHub notes retain full SemVer. Docker tags map `+` to `_`.

Docker aliases advance by SemVer precedence. Build metadata does not change
precedence. Older maintenance releases may advance their line alias while
leaving global latest on a newer line. Equal precedence with different content
keeps the current alias. There are no moving Git tags or major-only image aliases.

## Inspect and recover

Artifacts are retained for 30 days. Candidate names include mode, version,
source SHA, run ID, and attempt. Request selection, admission evidence, image
transfer, registry verification, and final publication use separate artifacts.
Durable checkpoints remain in the protected state branch.

Read the failed job and retained evidence. Rerun the original workflow. Do not
push a replacement tag, recreate a release branch, or enter a new version to
repair an interrupted publication. The workflow restores the original candidate
and resumes its checkpoints without rebuilding a tagged version.

An untagged failed qualification may be retried. A reviewed descendant may
supersede it and reuse its unused version. A tagged version stays reserved.
If required candidate bytes expire or are lost, stop. Restore byte-identical,
authenticated evidence or prepare a new version through review.

Source gaps, full queues, unexplained tags, conflicting assets, and changed
fixed digests stop progression. Retry the missing original request or review
the conflict. Do not bypass the check. Alias recovery finishes partial writes
and never moves a newer pointer backward.

Workflows share a publication concurrency group with `queue: max`. GitHub keeps
up to 100 pending runs. Waiting order can differ from source order, so the
ledger checks progression separately. See [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

## Check automation changes

```sh
bash tests/release/proposals.sh
bash tests/release/candidates.sh
bash tests/release/github.sh
bash tests/release/publication.sh
bash tests/release/publication.sh --docker
make check-shell
```

The publication fixtures use temporary local Git histories and a stateful fake
GitHub API. The Docker option adds a disposable registry and needs Node.js.
Synthetic receipts are marked as fixtures and cannot authorize production.
No test changes project refs, creates a GitHub version, or uploads to Docker Hub.
Native clean-pull qualification and hosted artifact handoff need CI verification.
