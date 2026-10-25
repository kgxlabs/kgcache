# Release workflow

A merged PR into `release/VERSION` requests that exact version. For example,
merging a preparation PR into `release/0.1.0-rc.1` requests `0.1.0-rc.1`.
Main remains the development branch. Release branches are not merged into main
as the release trigger.

The version comes from the target branch name. Release notes come from the PR
body captured at merge time. There is no release-line registry or release-note
file to update for each version.

## Prepare a release

1. Choose a complete SemVer, such as `0.1.0-rc.1` or `0.1.0`.
2. Create `release/VERSION` from the intended tested source. The first release
   branch must include the current release tooling from main.
3. Create a working branch from that release branch. Put final preparation or
   compatible backports there. Fixes land on main first and retain the full
   cherry-pick reference.
4. Open a PR with `release/VERSION` as its base. Use its body for release notes.
   An empty body falls back to the PR title and link.
5. Wait for the required server, client, build, shell, and maintenance checks.
6. Squash merge the PR into `release/VERSION` to request publication.

Branch creation, direct pushes, opened PRs, and closed unmerged PRs do not
publish. Ordinary PRs into main do not publish. Release requests use branches
within this repository.

The target branch needs a complete version without a leading `v` or build
metadata. `release/0.1` is not a versioned release request. The tag gets the
leading `v` automatically. A prerelease version becomes a GitHub prerelease and
does not advance stable Docker line or `latest` aliases.

Each version belongs to one merged PR. For the next candidate, create a new
branch such as `release/0.1.0-rc.2`. Another PR cannot replace the content of an
already requested or published version. A failed request is retried from its
original workflow run.

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
3. Protect main and `release/*` with PRs, resolved review threads, squash merges,
   linear history, deletion and force-push restrictions, and strict CI checks.
   Use the exact check names and integration IDs in the automation settings.
   Release targets also require Maintenance compatibility.
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

Open Actions, then Release candidate qualification. Run it from main with the
chosen `source_ref` and an optional explicit `version`. Manual dispatch remains
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
publication suite includes merged versioned PRs, automatic state creation,
frozen notes, exact version selection, duplicate rejection, and retry recovery.

```sh
bash tests/release/proposals.sh
bash tests/release/candidates.sh
bash tests/release/github.sh
bash tests/release/publication.sh --docker
make check-shell
```

The fixtures use temporary Git repositories, a local registry, and a fake GitHub
API. They do not create real GitHub release versions or upload to Docker Hub.
