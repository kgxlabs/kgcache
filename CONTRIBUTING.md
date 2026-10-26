# Contribute to kgcache

Help improve kgcache with a focused change, a reproducible bug report, or a
clearer guide. Start with the [documentation](docs/README.md) to learn the
supported behavior. Use the [contributor guides](docs/contribute/README.md)
when working on the server or its tools.

## Report a problem

Search [open and closed issues](https://github.com/kgxlabs/kgcache/issues)
first. A useful report includes:

- The version or commit, operating system, and CPU architecture.
- A small command sequence or program that reproduces the problem.
- The expected reply and the reply or error you received.
- Relevant settings and logs. For a client problem, include the library version
  and selected RESP mode.

Discuss a large feature or a change to command behavior in an issue before
writing it. Explain the workload and the proposed behavior. Small fixes and
documentation changes can go straight to a pull request.

## Set up a branch

Install Zig 0.16.0. Fork the repository if you do not have write access, then
create a branch from current main:

```sh
git fetch origin main
git switch -c fix/describe-the-change origin/main
zig build
zig build test
```

Target `main`. Keep each PR useful on its own, with the tests and docs needed
to understand it. Leave unrelated cleanup for another PR.

## Make and test the change

Follow nearby code. Explain decisions that a reader cannot infer from the
code itself. Keep comments and documentation direct and specific.

| Changed area | Checks to run |
| --- | --- |
| Zig | `zig fmt --check build.zig build.zig.zon src tests`, `zig build`, `zig build test`, `zig build test-integration` |
| Go client suite | `make test-go`, `make check-go` |
| Node client suite | `make deps-node`, `make test-node`, `make check-node` |
| Shell | `make fmt-shell`, `make check-shell` |
| Image or service | [Container checks](tests/container/README.md) |
| Release tooling | [Release checks](tests/release/README.md) |
| Documentation | Check affected links, syntax, and runnable examples |

Use `make fmt-go` and `make fmt-node` for client formatting. Client checks need
[their pinned tools](tests/integration/clients/README.md). Shell checks follow
[the shell conventions](tools/shell/README.md).

For a bug fix, add a regression test when practical. Show that the old behavior
fails and the fix passes. Follow [test organization](docs/contribute/testing.md)
when adding or moving Zig tests. `make test` runs the Zig and real-client test
groups. Separate format, shell, build, and container checks still apply.

For a performance claim, provide the workload, commands, build settings, OS,
CPU, and before/after results from the same machine. Explain memory or latency
tradeoffs. Compatibility tests alone do not establish performance.

## Write the commit and PR

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
for every introduced commit and the PR title:

```text
fix(resp): reject an invalid bulk string length
docs: explain snapshot recovery
feat(config)!: change a configuration default
```

The format is `<type>[optional scope][!]: <description>`. Prefer a lowercase
type and a short description. Use `fix` for a bug, `feat` for new behavior,
and `docs`, `test`, `refactor`, `style`, `perf`, `build`, `ci`, `chore`, or
`revert` when those describe the change better. Mark a breaking change with
`!` before the colon or a `BREAKING CHANGE:` footer.

Use the [PR template](.github/pull_request_template.md). Describe the problem,
the resulting behavior, the checks run, and compatibility impact. State which
relevant checks you could not run. Link the issue or discussion when useful.
Use a draft for unfinished work.

Compatibility includes replies, client handshakes, commands, config defaults,
CLI arguments, persistence formats, and deployment requirements. A bug fix can
still break users. Explain the impact and migration for such a change. Write
its summary so it can also serve as a release note.

CI checks **PR title** and **Commit messages**. Commitlint checks commits
introduced by the PR; it excludes older base commits and update merge commits.
The squash message must describe the final change, including compatibility and
backport references.

### Optional local commit check

Use Node.js 22.12.0 or newer. CI uses Node.js 22.14.0.

```sh
npm ci --prefix tools/commitlint --include=dev --ignore-scripts
git config --local core.hooksPath .githooks
```

The hook uses installed tools and never downloads them during a commit. If you
already use a hook manager, call [.githooks/commit-msg](.githooks/commit-msg)
from its `commit-msg` hook instead. To check the branch manually:

```sh
git fetch origin main
bash tools/commitlint/check.sh origin/main HEAD
```

## Review and merge

Keep the description current as the change develops. Address review comments
in the same PR. Explain disagreements with a concrete example or test.
Before merging, pass required checks, resolve review conversations, and obtain
an approving review from another maintainer with write access. New code after
approval needs another review.

Use **Squash and merge**. Review the final message before merging. Preserve
useful issue links, breaking-change notes, and cherry-pick references. Record
the resulting main commit when it will be backported.

Maintainers own release timing and scope. Ordinary PRs do not change package
versions, create release tags, or publish images. For assigned release work,
use the [release and backport guide](docs/contribute/release-workflow.md).
