# Release workflow

Creating a remote `release/MAJOR.MINOR.PATCH-rc` branch requests the first
release candidate. For example, creating `release/0.1.0-rc` from reviewed main
requests `0.1.0-rc.1`. No preparation commit or PR is needed for that candidate.

Later, merge fixes into main first. Cherry-pick them into a working branch and
open a PR against the same RC branch. Squash merging that PR requests the next
candidate, such as `0.1.0-rc.2`.

Branch creation requests qualification. Publication happens only after the
source, image, transfer, and clean-pull checks pass. Local branch creation alone
has no effect until the branch is pushed to GitHub.

## Start an RC series

1. Merge the release automation into main before creating the RC branch.
2. Choose a target version, such as `0.1.0`, and a reviewed main commit.
3. Create `release/0.1.0-rc` from that commit and push it to GitHub. Creating the
   branch in GitHub's UI with main as its source works too.
4. Watch Request initial RC in Actions. It forwards the request to Release
   candidates on main. The publisher verifies the original branch creation,
   source review, actor access, and effective protections before reserving a number.
5. Watch Release candidates complete qualification and publication.

For example, from a clean checkout:

```sh
git fetch origin main
git switch --no-track -c release/0.1.0-rc origin/main
git push -u origin release/0.1.0-rc
```

The branch name is an intent to publish. Reserve `release/*-rc` names for real
candidate series. The source must be the original branch cut and a main commit
merged through an enforced PR. Initial notes link that source, its main PR, and
its documented compatibility limits. The publisher freezes those notes.

## Publish later candidates

1. Merge the fix into main.
2. Create a working branch from the latest `release/0.1.0-rc`.
3. Cherry-pick the main commit with `git cherry-pick -x`.
4. Open a PR into `release/0.1.0-rc`. Use its body for release notes. Retain the
   full cherry-pick reference in the PR body or squash message.
5. Wait for the required checks, then squash merge to request `0.1.0-rc.2`.

An initial request must be stored before later RC PRs are admitted. If GitHub
runs them out of order, retry the PR workflow after the initial request is stored.
Publication waits for earlier requests on the branch to finish, except for
untagged qualification failures.

Direct pushes, opened PRs, and closed unmerged PRs do not publish later candidates.
Ordinary main PRs do not publish. Branches for exact versions, such as
`release/0.1.0`, still publish that version through a merged PR.

Each version belongs to one stored request. RC numbering starts at one and
advances past all reserved numbers, including queued, failed, and exact-version
requests. Retrying a failed request keeps its number and notes. Another request
cannot replace an existing version. Existing unrelated tags stop publication.
A prerelease does not advance stable Docker line tags or `latest`.

Do not delete and recreate an RC branch to retry a release. Recreated and
force-updated branches fail the creation audit. Retry the original Release
candidates run instead. If forwarding failed, check for an existing publisher
run before rerunning Request initial RC.

## Recover an existing RC branch

A branch created before this automation was installed has no new creation event
to trigger it. Use the explicit initial-publication action once:

1. Open Actions, then Release candidates, and run the workflow from main.
2. Set `operation` to Publish RC.
3. Set `source_ref` to the existing RC branch, such as `release/0.1.0-rc`.
4. Set `source_sha` to its original branch creation commit. For a branch without
   backports, `git rev-parse origin/release/0.1.0-rc` gives that commit.
5. Provide `release_notes` and leave `version` empty.

This path verifies the same original creation and main review. It cannot
publish an arbitrary branch commit or override a reserved version. Retry the
original workflow run after a failure. A new dispatch for an already requested
source points back to its original request.

## Automatic publication

The workflow reads trusted automation settings from main. It verifies the
merged PR through GitHub, checks the exact source commit and merger access,
and audits effective main, release-branch, state, and version-tag protections.
The configured owner may bypass independent review. Other mergers need the
required maintainer approval. Unresolved maintainer change requests stop release.

On the first valid request, the publisher creates its protected `release-state`
branch automatically. It stores the version, source, notes, and request identity
before proceeding. No per-version registration or manual state-root pin is
needed.

Native Linux amd64 runners build and test the exact merged source and version,
save the image, and verify transfer on a fresh runner. The publisher then
reserves the annotated Git tag and uploads those retained image bytes. Another
native runner verifies a clean digest pull and repeats service/client checks.
The publisher finishes fixed image tags, GitHub assets, and eligible aliases.

PR notes are frozen with the request. Editing a PR after its release request
has been stored does not change a retry's notes. Publication uses no notes file
from the source tree. GitHub adds its normal source archives to the release.
The workflow uploads `build-info.json`, `release-info.json`, `qualification.json`,
and `SHA256SUMS` as release evidence.

## Configure the publisher

1. Install the dedicated publisher App on this repository. Grant Contents write,
   Pull requests read, Administration write, and Actions read. Administration
   write is needed to inspect ruleset bypass lists and also permits changing
   protections. The release tooling reads those settings.
2. In the `release` Actions environment, store `RELEASE_APP_PRIVATE_KEY` and
   `DOCKERHUB_TOKEN`. Set `RELEASE_APP_ID` and `DOCKERHUB_USERNAME` as variables.
   Allow `release/*` branches and main. Main is used for manual credential checks.
3. Protect main and `release/*` with PRs, resolved review threads, squash-only
   merges, deletion and force-push restrictions, and strict CI checks.
   Use the exact check names and integration IDs in the automation settings.
   Release targets also require Maintenance compatibility.
   Leave the separate Require linear history rule off. GitHub can reject a new
   release branch because it inherits old merge commits from main. Required,
   squash-only PRs keep future updates linear. The publisher checks those rules
   and requires the release merge commit to have exactly one parent.
4. Keep a base PR rule with zero approvals and no bypass actors. A separate
   review ruleset requires one approval and permits only the account in
   `review_bypass` to bypass it, using For pull requests only. Classic review
   protection must allow the same account. This leaves CI checks required.
5. Protect `release-state` with creation, update, deletion, and force-push
   restrictions. Its sole bypass actor is the publisher App in Always mode.
6. Protect `v*` tags with creation, update, and deletion restrictions. The same
   publisher App is the sole bypass actor in Always mode.
7. Use an owned Docker Hub repository with immutable full-version and `src-*`
   tags. Keep line and latest aliases mutable. Configure the App ID, tag ruleset
   ID, required checks, registry destination, and enforcement baseline in
   `.github/release-automation.json`. `enabled` controls production publication.

Accept updated App permissions on the installation before running workflows
that request them. After merging workflow changes, start a new workflow run.
Rerunning an older run uses its original workflow definition.

The optional `blocked_versions` array in automation settings revokes specific
versions. It is for exceptional recovery decisions, not routine registration.
A blocked version stops further publication writes.

## Read-only previews

Open Actions, then Release candidates. Choose Preview and run it from main
with the chosen `source_ref` and an optional explicit `version`. Preview remains
read-only even when publication is enabled. It builds and qualifies the chosen
source/version pair, verifies saved-image transfer, and retains artifacts. It
creates no release request, Git tag, registry upload, or GitHub Release.

Without an explicit version, a preview uses the source's development default.
A preview does not reserve a release number. Versioned builds receive their
version as build input; the checked-in development version stays unchanged.

## Credential and testing-image checks

Open Registry image verification on main. Leave `candidate_run_id` empty for
credential checks alone. `credential_repository=testing` checks access to
`docker.io/kgxlabs/kgcachetesting`; `production` checks
`docker.io/kgxlabs/kgcache`. Both use the same stored Docker credentials. The
job authenticates the publisher App, verifies tag protections, and checks Docker
pull/push grants without uploading anything.

To verify an already uploaded testing image, provide its successful preview
run ID. The image job checks the retained candidate and transfer evidence, pulls
by digest into a fresh native Linux amd64 image store, and runs service/client
checks. That job has no publisher credentials. The final result requires every
requested check to finish successfully.

## Retry and recover

Rerun the original failed release workflow. Duplicate deliveries reuse its
stored request and exact version. A tagged version restores its original
retained candidate rather than building replacement bytes. Tag, registry, asset,
and alias operations reconcile their recorded intent after uncertain responses.

Artifacts are retained for 30 days. If required bytes are missing or expired,
restore the identical retained bytes or prepare a new version. Do not recreate
a release branch or replace a version tag to repair a failed publication.

Aliases advance by SemVer precedence. Prereleases leave stable aliases alone.
An older regular release cannot move latest backward. Fixed references with
different content, changed protection rules, and unexplained tags stop progress.

## Validate automation changes

Run the release proposal, candidate, GitHub, and publication fixtures. The
publication suite includes automatic initial requests, existing-branch recovery,
main-first backports, automatic state creation, frozen notes, exact version selection,
duplicate rejection, and retry recovery.

```sh
bash tests/release/proposals.sh
bash tests/release/candidates.sh
bash tests/release/github.sh
bash tests/release/publication.sh --docker
make check-shell
```

The fixtures use temporary Git repositories, a local registry, and a fake GitHub
API. They do not create real GitHub release versions or upload to Docker Hub.
