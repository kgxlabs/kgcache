# Release and backport kgcache

[Docs](../README.md) / [Contribute](README.md) / Releases

Use this guide for assigned release work. A release branch is a request to
publish, not a place for ordinary development. Application changes land on
main first. The publisher qualifies and transfers one exact image before it
publishes that version.

For a local experiment, use a [read-only proposal](release-proposals.md) or
[local candidate](release-candidates.md).

## Backport a reviewed fix

A maintainer chooses the supported version and release scope. From a clean
checkout, create a temporary branch from that release target:

```sh
git fetch origin
git switch -c backport/0.2.1-describe-the-fix origin/release/0.2.1
git cherry-pick -x MAIN_SQUASH_COMMIT_SHA
```

Replace the placeholder with the full commit produced by squash merging the
fix into main. Open a PR against `release/0.2.1`. Include the original PR,
source SHA, conflict resolutions, validation, and the cherry-pick reference.
Test the target code: a clean cherry-pick does not establish compatibility.

Release branches accept compatible fixes and necessary maintenance. New
features and breaking changes belong on main for a future version. An exception
to main-first history requires a maintainer decision.

**Maintenance compatibility** checks the PR title, body, introduced commits,
and main references. It rejects declared features and breaking changes.
Reviewers still judge actual behavior. The release collector later checks the
squash commit, review, source history, and merger access.

Keep `(cherry picked from commit ...)` in the final squash message. GitHub may
use the PR body instead of the picked commit body, so copy that reference when
needed. The message and PR body also provide the release notes.

## Request a stable patch release

A stable release branch stays open for later patches. For example, the first
merged PR into `release/0.1.0` requests `0.1.0`. Later PR merges request `0.1.1`,
`0.1.2`, and so on. Creating the stable branch alone does not publish a release.
Merge each fix into main, then backport it through a PR against the same release
branch. A new branch is not needed for every patch.

The branch version is the first allowed patch in its major/minor line. The
publisher chooses the next number after all stored regular reservations in
that line, including queued and failed requests. It never gives an existing
number to a different source. Retrying a request keeps its original version
and notes.

Qualification uses the tools in the selected source commit. Backport required
release-tooling changes from main so the release branch can use them too.

## Start a release-candidate series

Creating remote `release/MAJOR.MINOR.PATCH-rc` requests candidate `.1` for that
target. For example, `release/0.1.0-rc` requests `0.1.0-rc.1`.

1. Choose a reviewed main commit and target version.
2. Create the RC branch from that commit and push it.
3. Watch **Request initial RC**, then **Release candidates**, in Actions.
4. Check qualification and publication evidence before distributing its image.

```sh
git fetch origin main
git switch --no-track -c release/0.1.0-rc origin/main
git push -u origin release/0.1.0-rc
```

These commands request a real release when pushed. No preparation commit or
PR is needed for the first candidate. The automation must already exist on
main. The source must be the original branch cut and a main commit admitted
through enforced PR review. Creating the branch in GitHub's UI also works.

The forwarding workflow and publisher verify original creation, source review,
actor access, and effective protections before reserving a number. Initial
notes link the source, main PR, and documented compatibility limits. Those
notes are then frozen with the request.

## Request the next candidate

Merge a fix into main, then follow the backport procedure with
`release/0.1.0-rc` as the target. Squash merging its PR requests the next number,
such as `0.1.0-rc.2`. Keep that PR's body suitable for release notes.

Direct pushes, opened PRs, and closed unmerged PRs do not request later
candidates. Ordinary main PRs do not publish. A numbered target such as
`release/0.1.0-rc.1` also accepts later RCs. Its first merged PR requests at least
`0.1.0-rc.1`; later merges advance the counter for the same target. Initial
publication on branch creation applies to the `release/0.1.0-rc` pattern.

The initial request must be stored before a later RC PR is admitted. If Actions
processes them out of order, retry the PR workflow after the initial request
exists. Earlier PR merges on the same branch must also have stored requests
before a later merge is admitted. Publication waits for earlier untagged
requests, except qualification failures. Once an earlier stable patch or RC is
tagged, a new merge can qualify and publish its next version even if the earlier
publication still needs recovery. The earlier request and tag stay unchanged.

Each version belongs to one stored request. Stable and RC numbering advance past
reserved numbers, including queued and failed requests. A retry retains
its version and notes. Another request cannot take that number. Unrelated
existing tags stop publication. Prereleases do not move stable Docker aliases.

## Follow the publication stages

```text
collect and freeze request
  -> build and qualify exact source/version on native Linux amd64
  -> save image and verify transfer on a fresh runner
  -> reserve annotated version tag and upload retained image
  -> verify a clean registry pull on another native runner
  -> finish fixed tags, evidence assets, and eligible aliases
```

Automation reads trusted settings from main. It verifies the merged PR,
source, merger access, and main/release/state/tag protections. The configured
review-bypass owner can satisfy its specific review exception. Other mergers
need the required maintainer approval. Unresolved maintainer change requests
stop admission.

The publisher creates protected `release-state` on the first valid request.
It stores source, version, notes, and request identity before qualification.
There is no per-version source registry or manually pinned state-root commit.

GitHub notes use the frozen request. Editing the PR after storage does not
change retry notes. The workflow uploads `build-info.json`, `release-info.json`,
`qualification.json`, and `SHA256SUMS`. GitHub adds normal source archives.
The publisher does not commit a version bump.

## Recover an older RC branch

An RC branch created before the forwarding workflow has no new creation event.
Run **Release candidates** from main with:

| Input | Value |
| --- | --- |
| `operation` | Publish RC |
| `source_ref` | The existing RC branch |
| `source_sha` | Its original branch-creation commit |
| `release_notes` | The intended candidate notes |
| `version` | Empty |

For a branch with no backports, `git rev-parse origin/release/0.1.0-rc` gives
the original source. The publisher still verifies creation and main review.
It cannot publish an arbitrary newer branch commit or replace a reservation.

To resume a tagged candidate with updated verification tooling, use the same
inputs and set `resume_run_id` to the original publication run. Recovery reuses
its image artifact, version, tag, and notes. It cannot change their bytes.

## Retry a failed publication

Rerun the original **Release candidates** run. Duplicate deliveries reuse the
stored request. A tagged version restores its retained candidate instead of
building a replacement. Intent records reconcile tag, registry, asset, and
alias operations after uncertain responses.

If forwarding failed, first check whether the publisher already received the
request. Do not delete and recreate the RC branch. Recreated or force-updated
branches fail the creation audit.

Artifacts are retained for 30 days. Missing or expired bytes require restoring
identical retained bytes or preparing a new version. Replacing a version tag or
rebuilding different image bytes is not retry recovery.

Aliases follow SemVer precedence. Prereleases leave stable aliases alone.
An older regular version cannot move `latest` backward. Conflicting fixed
references, changed protections, or unexplained tags stop publication.

## Run a preview or credential check

For a read-only build, run **Release candidates** from main with **Preview**,
`source_ref`, and an optional `version`. Omitted version uses the selected
source's development default. Preview reserves no number and creates no tag,
registry upload, release request, or GitHub Release, even when publication is
enabled.

For credentials, run **Registry image verification** on main. Leave
`candidate_run_id` empty. `credential_repository=testing` checks
`docker.io/kgxlabs/kgcachetesting`; `production` checks `docker.io/kgxlabs/kgcache`.
The job uses the stored credentials to verify App authentication, tag
protections, and pull/push grants without uploading.

To verify an uploaded testing image, supply its successful preview run ID.
The image job checks candidate and transfer evidence, pulls by digest into a
fresh native image store, and runs service/client checks without publisher
credentials. Every requested check must finish successfully.

## Configure release automation

The checked-in settings are in
[.github/release-automation.json](../../.github/release-automation.json).
Its `enabled` field controls production publication. Setup requires:

1. A dedicated publisher App with Contents write, Pull requests read,
   Administration write, and Actions read. Tooling reads protections;
   Administration write also permits modifying them.
2. The `release` environment secrets `RELEASE_APP_PRIVATE_KEY` and
   `DOCKERHUB_TOKEN`, plus variables `RELEASE_APP_ID` and `DOCKERHUB_USERNAME`.
   Its allowed refs include `release/*`, main, and `refs/pull/*/merge`.
3. Main and release PR rules with resolved threads, squash-only merges,
   deletion/force-push restrictions, and strict checks. Release targets add
   Maintenance compatibility. Exact names and integration IDs come from settings.
4. A base zero-approval PR rule without bypass actors, plus a separate
   one-approval ruleset whose only review bypass is the configured owner in
   **For pull requests only** mode. Classic review protection must permit the
   same owner. The exception does not waive CI.
5. Protected `release-state` creation, update, deletion, and force-push, with
   only the publisher App in **Always** bypass mode.
6. Protected `v*` tags with creation, update, and deletion restrictions and the
   same sole App bypass.
7. An owned Docker Hub destination with immutable full-version and `src-*`
   tags. Line aliases and `latest` stay mutable. Configure its destination,
   App ID, tag ruleset ID, required checks, and enforcement baseline.

Keep the separate **Require linear history** rule off. It can reject a new
release branch that inherits historical merge commits. Squash-only PRs keep
future changes linear, and the publisher requires one parent for a release
request commit.

Accept updated App permissions on its installation before running jobs that
need them. After merging workflow changes, start a new run: rerunning an older
run uses the older workflow definition. The optional `blocked_versions` array
is for exceptional revocation; a blocked version stops further publication.

## Validate a tooling change

```sh
bash tests/release/proposals.sh
bash tests/release/candidates.sh
bash tests/release/github.sh
bash tests/release/publication.sh --docker
make check-shell
```

These fixtures use temporary Git history, a fake GitHub API, and a local
registry. They do not publish a real version. See
[release checks](../../tests/release/README.md) for prerequisites and evidence.
