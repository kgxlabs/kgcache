# Contributing to kgcache

Keep each pull request focused on one change that can be reviewed, tested,
and backported on its own. Start with the [README](README.md) for setup and
current compatibility.

## Start a change

- Create a working branch from current `main`. Use a name such as
  `fix/describe-the-fix`, `feat/describe-the-feature`, or `docs/describe-the-docs`.
- Target `main` for ordinary changes. Discuss large changes before starting.
- Explain the bug or intended behavior. Include a small reproduction when useful.
- Keep unrelated cleanup out of the PR. Include any docs needed to use the change.

## Write a clear PR title

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
for PR titles. The title becomes the subject of the squash commit.

```text
type(scope): describe the change
```

The scope is optional. Use a short area name such as `resp`, `config`,
`persistence`, or `container`.

| Type | Use for |
| --- | --- |
| `fix` | A bug fix |
| `feat` | New behavior or a new capability |
| `docs` | Documentation |
| `test` | Tests and fixtures |
| `refactor` | Code changes that preserve behavior |
| `perf` | Performance improvements |
| `build` | Build tools or dependencies |
| `ci` | CI workflows |
| `chore` | Other maintenance |
| `revert` | Reverting an earlier change |

Examples:

```text
fix(resp): reject an invalid bulk string length
feat(config): add a configuration option
docs: clarify the Compose setup
```

Working commits inside a PR do not need this format. Before merging,
maintainers check that the final title and commit body describe the complete
change. These conventions are reviewed by people; there is no PR title
validator in CI yet.

## Describe compatibility and release impact

State whether the PR is a compatible fix, a new feature, a breaking change,
or has no user-visible effect. Include a short release note for user-visible
changes. Explain the previous and new behavior when that helps a reviewer.

Consider Redis client behavior, protocol replies and errors, commands,
configuration defaults, CLI options, persistence formats, and deployment
requirements. A change can break users even when it fixes a bug.

For a breaking change, add `!` before the title's colon, such as
`feat(config)!: change a configuration default`. Explain the impact and migration
steps in the PR. Put a `BREAKING CHANGE: ...` footer at the end of the final
squash commit body. Describe the actual change in place of `...`.

Commit types describe intent. Reviewers still judge compatibility and release
eligibility. A `fix:` title alone does not prove that a change is safe for a
patch release.

## Run the relevant checks

Use Zig 0.16.0 to match CI. Run commands from the repository root.
Format changed Zig files with `zig fmt`.

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

Add a regression test for a bug fix when practical. Follow
[test organization](docs/TESTING.md) when adding or moving Zig tests.
In the PR, list the commands run and their results. Explain any relevant checks
you could not run. For a docs-only change, check the affected docs and examples.

CI runs source tests, the client matrix, shell checks, and build/container
validation on PRs. Wait for applicable CI checks to pass and address review
comments before merging.

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
release lines need the fix. A branch such as `release/0.2` holds maintenance
work for that line. A tag such as `v0.2.1` identifies one exact released commit.

For an approved backport, create a temporary branch from the target release
branch and cherry-pick the resulting `main` commit with `-x`:

```sh
git fetch origin
git switch -c backport/0.2-describe-the-fix origin/release/0.2
git cherry-pick -x MAIN_SQUASH_COMMIT_SHA
```

Replace `MAIN_SQUASH_COMMIT_SHA` with the full commit SHA. The `-x` option records
where the change came from. Open a PR against `release/0.2` and include the
original PR, full source SHA, and any conflict resolutions or extra changes.
Run the relevant checks on the target code.

Keep the original commit reference in the final squash commit body. GitHub does
not automatically preserve a picked commit's body when it uses the PR description
as the squash message. Copy the `(cherry picked from commit ...)` line into that
message when needed.

Release branches accept compatible fixes and necessary maintenance approved by
a maintainer. New features and breaking changes belong on `main` for a future
release line. An exception to fixing `main` first needs a maintainer's review.

## Release ownership

Maintainers choose release scope and timing. Ordinary feature and bug-fix PRs
should not change the package version, create release tags, or publish images.
Include those operations only when a maintainer has explicitly assigned release
preparation work. Passing build and image checks does not itself publish a release.
