# Contributing to kgcache

Keep each pull request focused on one change that can be reviewed, tested,
and backported on its own. Start with the [README](README.md) for setup and
current compatibility. Docs, tests, bug reports, and feedback from real clients
are useful contributions too.

## Report a bug

Search [existing issues](https://github.com/kgxlabs/kgcache/issues), including
closed issues, before opening a report. Include:

- The kgcache version or commit SHA, OS, and CPU architecture.
- The smallest command sequence or script that shows the problem.
- Expected behavior and what happened instead.
- Relevant config and log output. For client issues, include the library version
  and whether it used RESP2 or RESP3.

A report with a clear reproduction is useful even without a proposed fix.

## Start a change

- Discuss large features or behavior changes in an issue first. Explain the use
  case and proposed behavior. Small fixes and docs can go straight to a PR.
- Create a working branch from current `main`. If you do not have write access,
  fork the repository first. Use a name such as `fix/describe-the-fix`,
  `feat/describe-the-feature`, or `docs/describe-the-docs`.
- Target `main` for ordinary changes. Link related issues or earlier discussions.
- Keep unrelated cleanup out of the PR. Include any docs needed to use the change.

## Follow the code style

Follow nearby code and keep formatting changes limited to the files you touch.
Use `zig fmt` for Zig, `make fmt-go` for Go client code, and `make fmt-node`
for Node client code. Follow the [shell conventions](tools/shell/README.md)
and use `make fmt-shell` for shell scripts. Client formatters need the setup
described in [client test setup](tests/integration/clients/README.md).

Explain non-obvious decisions in comments. Make sure you understand and can
explain the code you submit.

## Write clear commit messages and PR titles

Use [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
for commits and PR titles. The PR title becomes the subject of the squash commit.

```text
<type>[optional scope][!]: <description>
```

Include a type, a colon and space, and a short description. A scope in parentheses
can name the area, such as `fix(resp): reject an invalid length`. An optional `!`
before the colon marks a breaking change. Prefer lowercase for consistency;
the check accepts other casing too.

Use `fix` for bug fixes and `feat` for new features. Other types are allowed.
These are common choices:

| Type | Use for |
| --- | --- |
| `fix` | A bug fix |
| `feat` | New behavior or a new capability |
| `docs` | Documentation |
| `test` | Tests and fixtures |
| `refactor` | Code changes that preserve behavior |
| `style` | Formatting changes that preserve behavior |
| `perf` | Performance improvements |
| `build` | Build tools or dependencies |
| `ci` | CI workflows |
| `chore` | Other maintenance |
| `revert` | Reverting an earlier change |

Examples:

```text
chore: add contribution guide and pr template
fix(resp): reject an invalid bulk string length
feat(config): add a configuration option
feat(config)!: change a configuration default
docs: clarify the Compose setup
```

Individual commits in a PR must follow this format too. The **Commit messages**
CI check uses [commitlint](https://commitlint.js.org/) to check commits introduced
by the PR. Older commits already on the target branch and merge commits used
to update a working branch are excluded. Before merging, maintainers check that
the final title and commit body describe the complete change. The **PR title**
CI check uses
[action-semantic-pull-request](https://github.com/amannn/action-semantic-pull-request)
to validate the Conventional Commit header. It reruns when the title changes.
Reviewers still check that the type and compatibility notes describe the change.

## Enable local commit checks

The optional Git `commit-msg` hook checks messages before creating a commit.
Use Node.js 22.12.0 or newer. CI uses Node.js 22.14.0, the same version as the
client tests. From the repository root, run:

```sh
npm ci --prefix tools/commitlint --include=dev --ignore-scripts
git config --local core.hooksPath .githooks
```

This Git setting applies to this repository. If you already use a hook manager,
call [.githooks/commit-msg](.githooks/commit-msg) from its `commit-msg` hook instead.
The hook does not download dependencies when committing. CI checks messages
even when the local hook is not enabled or is bypassed.

To check a branch before pushing:

```sh
git fetch origin
bash tools/commitlint/check.sh origin/main HEAD
```

## Describe compatibility and release impact

State whether the PR is a compatible fix, a new feature, a breaking change,
or has no user-visible effect. Write the summary so it can serve as a short
release note for users. Explain the previous and new behavior when useful.

Consider Redis client behavior, protocol replies and errors, commands,
configuration defaults, CLI options, persistence formats, and deployment
requirements. A change can break users even when it fixes a bug.

For a breaking change, explain the impact and migration steps in the PR. Mark it
with `!` before the title's colon, such as
`feat(config)!: change a configuration default`, or include a `BREAKING CHANGE:`
footer in the final squash commit body. Both markers can be used together.

Commit types describe intent. Reviewers still judge compatibility and release
eligibility. A `fix:` title alone does not prove that a change is safe for a
patch release.

## Run the relevant checks

Use Zig 0.16.0 to match CI. Run commands from the repository root.

| Change | Local checks |
| --- | --- |
| Zig code | `zig build`, `zig build test`, and `zig build test-integration` |
| Go client tests | `make test-go` and `make check-go` |
| Node client tests | `make deps-node`, `make test-node`, and `make check-node` |
| Shell scripts | `make check-shell` |
| Container or service behavior | Follow the [container checks](tests/container/README.md) |
| Release build tools | Follow the [release build checks](tests/release/README.md) |
| Documentation | Check changed links and examples |

Client tests need the pinned runtimes and dependencies described in
[client test setup](tests/integration/clients/README.md). Shell and container
checks need Docker and the prerequisites in their guides.

Use `make test` to run the Zig and real-client test groups. It does not replace
the separate formatting, shell, build, and container checks.

For a bug fix, add a regression test when practical. Confirm it fails on the old
code and passes with the fix. Add coverage for new behavior and explain any
intentional changes to existing tests. Follow [test organization](docs/TESTING.md)
when adding or moving Zig tests.

For a performance claim, include a repeatable benchmark command, workload,
build settings, and before/after results on the same machine. State the OS
and CPU. Mention any tradeoffs in latency, throughput, or memory use.

List checks run and their results in the PR. Explain relevant checks you could
not run. For a docs-only change, check the affected docs and examples.

## Open and update a PR

Use the [PR template](.github/pull_request_template.md): a short summary, testing
results, and compatibility impact. A few sentences can be enough for a small
change. Use a draft PR when you want early feedback on unfinished work.

Address review comments in the same PR and keep the description current.
Explain technical disagreements with a concrete example or test.

CI runs source tests, the client matrix, shell checks, and build/container
validation on PRs. If a check fails, read its logs and investigate the cause.
Before merging, obtain at least one approving review from another maintainer
with write access and pass all required checks, including **PR title** and
**Commit messages**. New code changes after approval need another review.
Resolve review conversations before merging.

## Merge with squash

Use **Squash and merge**. One focused PR becomes one commit on the target branch.
Review the final commit message before confirming the merge. Keep the useful
explanation, issue references, breaking-change footer, and backport source
reference. Remove unused template fields.

Record the resulting commit SHA when it is needed for a backport. This is the
commit on `main`, not one of the original working commits from the PR branch.
Squashing gives the change one commit to copy. A backport still needs review
and tests because older code can have different behavior or dependencies.

## Backport a compatible fix

Fix and merge the issue on `main` first. A maintainer decides which supported
versions need the fix. A branch such as `release/0.2.1` prepares that exact
version. Its first merged preparation or backport PR requests publication as
`v0.2.1`. Use a new version branch for another release.

For an approved backport, create a temporary branch from the target release
branch and cherry-pick the resulting `main` commit with `-x`:

```sh
git fetch origin
git switch -c backport/0.2.1-describe-the-fix origin/release/0.2.1
git cherry-pick -x MAIN_SQUASH_COMMIT_SHA
```

Replace `MAIN_SQUASH_COMMIT_SHA` with the full commit SHA. The `-x` option records
where the change came from. Open a PR against `release/0.2.1` and include the
original PR, full source SHA, and any conflict resolutions or extra changes.
Run the relevant checks on the target code.

The **Maintenance compatibility** check validates the PR title, body, introduced
commit messages, and main source references. It rejects declared features and
breaking changes. Reviewers still judge compatibility. After merging, the
[release workflow](docs/RELEASE_WORKFLOW.md) checks the actual squash commit,
maintainer approval, and main-first history before qualification.

Keep the original commit reference in the final squash commit body. GitHub does
not automatically preserve a picked commit's body when it uses the PR description
as the squash message. Copy the `(cherry picked from commit ...)` line into that
message when needed.

Release branches accept compatible fixes and necessary maintenance approved by
a maintainer. New features and breaking changes belong on `main` for a future
version. An exception to fixing `main` first needs a maintainer's review.

## Release ownership

Maintainers choose release scope and timing. Ordinary feature and bug-fix PRs
should not change the package version, create release tags, or publish images.
Include those operations only when a maintainer has explicitly assigned release
preparation work. Passing build and image checks does not itself publish a release.
