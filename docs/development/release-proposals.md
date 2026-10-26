# Release proposals

[Developer documentation](README.md)

`tools/release/propose.sh` makes read-only source/version previews. It does not
build, reserve a version, change Git refs, upload an image, or create a release.

For an initial candidate, create a remote `release/MAJOR.MINOR.PATCH-rc` branch
from reviewed main. Later backport PRs into that branch request the next number.
The protected state freezes each source, version, and notes before qualification.
The explicit Publish RC action can recover branches created before automation
was installed. See the [release workflow](release-workflow.md).
There is no checked-in release-line registry to maintain.

## Preview a committed source

```sh
bash tools/release/propose.sh --source HEAD --version 0.1.0-rc.1
```

The source defaults to HEAD and can be a branch, tag, or full commit SHA. The
command resolves it once. Uncommitted changes are outside that source snapshot.
Without an explicit version, it uses the source's development default.

Use `--repo DIR` for another local repository and `--repository OWNER/REPO` for
its expected lowercase identity. Complete Git history and an up-to-date
`refs/remotes/origin/main` are required. The tool performs no fetch.

Preview records have mode `preview`, `source_eligible: false`,
`publishable: false`, and no publication request key. A preview is not a release
request, even if its version looks like an intended public release.

## Automatic request proposals

An initial branch request or merged release PR produces a mode `release`
proposal with its exact source commit, assigned version, request reference, and
frozen notes. Initial notes are generated from the reviewed cut. Later notes
come from the backport PR body. The protected state
reserves the next number for RC series branches when it records the request.
Queued and failed requests retain their numbers. A retry recovers that same
proposal. A second PR cannot claim the same version.

Every candidate remains non-publishing until native qualification, transfer,
and publication admission checks have passed. The publisher creates the tag
only for the retained qualified image. It does not commit a source version bump.

Version syntax follows SemVer. An RC series branch such as `release/0.1.0-rc`
supplies the target version and receives an automatic numeric suffix. Other
release branches supply the exact version. Docker tags use the shared validated
mapping. Release notes and version history live in GitHub and the automation's
protected state, rather than per-version source files.

The local proposer also retains its older event/state fixture interface for
regression coverage. That interface is not the operational release procedure.
