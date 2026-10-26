# Preview a source and version

[Docs](../README.md) / [Contribute](README.md) / Release proposals

Use a proposal to resolve a committed source and version before building.
The local proposer is read-only: it does not build, reserve a number, change
refs, upload an image, or create a release.

## Create a preview

Run from the repository root:

```sh
bash tools/release/propose.sh --source HEAD --version 0.2.0-rc.1
```

`--source` accepts a branch, tag, or full SHA and defaults to HEAD. The tool
resolves it once. Working-tree changes are outside that source snapshot.
Omit `--version` to use the selected source's development default.

Use `--repo DIR` for another local repository and `--repository OWNER/REPO`
for its expected lowercase identity. The local repository needs complete Git
history and an up-to-date `refs/remotes/origin/main`. The command does not fetch.

A preview records mode `preview`, `source_eligible: false`, and
`publishable: false`, with no publication request key. A version-shaped input
does not turn it into a release request.

To build the selected proposal, continue with
[candidate qualification](release-candidates.md).

## Understand publication proposals

Real requests come from the [release workflow](release-workflow.md). Creating
an RC branch from reviewed main requests its first candidate. Later merged
backport PRs request subsequent candidates. The explicit Publish RC action
can recover a branch created before forwarding automation existed.

Those requests create mode `release` proposals with a fixed source, assigned
version, request reference, and frozen notes. Initial notes come from the
reviewed branch cut. Later notes come from the backport PR body.

The protected state reserves a number when storing the request. Queued and
failed requests keep that number, and retries recover the same proposal.
Another request cannot claim it. RC series branches provide the target version
and receive an increasing numeric suffix. Exact-version branches provide the
exact version.

Candidates remain non-publishing until native qualification, transfer, and
admission pass. The publisher tags the retained qualified image; it does not
commit a package version bump. Docker tags use the shared validated SemVer
mapping. Notes and version history live in GitHub and protected automation
state, rather than per-version source files.

The proposer retains an older event/state fixture interface for regression
tests. Use the workflow for operational release requests. There is no local
release-line registry to update.

## Check a change

```sh
bash tests/release/proposals.sh
```

The fixtures need no compiler, Docker, credentials, or published version.
They use isolated Git repositories. The implementation is
[propose.sh](../../tools/release/propose.sh) and its named jq policy files.
