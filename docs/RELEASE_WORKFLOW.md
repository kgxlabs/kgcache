# Release candidate workflow

**Release candidate qualification** runs the
[candidate tools](RELEASE_CANDIDATES.md) in GitHub Actions. It selects a source
and version, qualifies them on native Linux amd64, and verifies the saved image
on a fresh runner. Every event is read-only. No version is reserved, tagged,
uploaded to a registry, or published as a GitHub Release.

## Run a manual preview

The workflow must exist on the repository's default branch before GitHub shows
**Run workflow**. See [GitHub's manual workflow instructions](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).

1. Open **Actions**, then **Release candidate qualification**.
2. Select **Run workflow**. Choose the branch containing the workflow code.
3. Set `source_ref` to the source branch, tag, or full commit SHA to test.
4. Optionally set `release_line` or a complete `version`.
5. Run the workflow. Check all three jobs and the summary.

The workflow branch and `source_ref` are separate inputs. The source ref is
resolved once to a full SHA. Qualification, client profiles, dependency locks,
and the import verifier all come from that selected commit. It must contain
the candidate tooling and its request-evidence support.

With [GitHub CLI](https://cli.github.com/manual/gh_workflow_run):

```sh
gh workflow run release.yml --ref main \
  -f source_ref=YOUR_WORKING_BRANCH \
  -f version=0.2.0-rc.1+local.001
gh run list --workflow release.yml
gh run view RUN_ID
```

Use `--ref YOUR_WORKFLOW_BRANCH` to test workflow changes after pushing them.
The workflow still needs to exist on the default branch for manual dispatch.
Use a full source SHA to repeat exactly the same source/version pair.

`source_ref` defaults to `main`. Without a line or version, the preview uses
the source's development default. `release_line` proposes an unreserved version
from that line. An explicit version must belong to the supplied line. Ambiguous
branch/tag names require `refs/heads/NAME` or `refs/tags/NAME`.

Previews at tags remain previews. There is no publication input, environment,
secret, registry login, or write-permission job.

## Prepare a release branch

Only cut a production release branch for an intentional release decision.
Use previews and local fixtures to test automation changes.

1. Choose a stable main commit containing the required automation. Review its
   scope, compatibility, and notes.
2. Open a registration PR on main for
   [`.github/release-lines.json`](../.github/release-lines.json). Record the exact
   cut SHA, canonical `release/MAJOR.MINOR` branch, lifecycle, channel, and notes.
3. Set `decision_ref` to that registration PR's full GitHub URL before merging.
   Obtain a maintainer approval of the final PR head, then merge it on main.
4. Confirm the registration has merged before creating the branch at its exact
   recorded cut. The cut may predate the registry commit because policy is read
   from protected main.
5. Inspect the resulting qualification run and candidate. Publication is not
   implemented by this workflow.

Git branch creation and the GitHub branch UI are both covered. Matching create
and push deliveries have the same branch/source request key. The workflow uses
`create` for the initial cut and skips the accompanying creation push. Genuine
redelivery or a rerun can create another evidence run without consuming a version.

The collector uses GitHub's
[repository activity API](https://docs.github.com/en/rest/repos/repos#list-repository-activities)
to identify the branch's original creation and the main policy already present
at that time. It uses server activity times, not Git commit dates. Registration
must be in a reviewed main PR. Same-second chronology that cannot be proved
stops selection.

## Merge a compatible backport

Follow the [backport guide](../CONTRIBUTING.md#backport-a-compatible-fix).
Merge the fix on main, then cherry-pick its squash commit with `-x` into a
working branch based on the target release line. Open and review a PR against
that line. Preserve the full `(cherry picked from commit ...)` reference in the
final squash message.

The **Maintenance compatibility** PR check rejects declared features and
breaking changes in the title, body, and introduced commit messages. Fix PRs
need a full main source reference. Reviewers still judge compatibility and
conflict resolutions. Add this check to the required checks for active release
branches. Keep the existing title, commit, source, client, shell, and build
checks required. Branch qualification jobs run after merging and should not
be required PR checks.

After merging, the collector checks the actual event SHA and its one-parent
squash progression. It finds the merged PR, a maintainer approval of its final
head, and main-first source references. It checks all earlier maintenance
commits after the registered cut too. A later branch tip cannot replace the
event commit. Necessary maintenance may have no main fix reference.

## Inspect results and artifacts

| Job | Result |
| --- | --- |
| Select candidate source and version | Pinned source and main policy, advisory version, original creation, review history, and checksummed API evidence. |
| Qualify selected source on native Linux amd64 | Full qualification of the selected source/version and the saved tested image. |
| Verify saved image on a fresh native Linux amd64 runner | Download by artifact ID, verify the expected manifest checksum, load, and inspect without rebuilding. |

Artifacts are retained for 30 days. Names contain the run ID and attempt.
Candidate names also contain mode, version, and full source SHA. Completed
bundles, selection evidence, transfer results, and failed attempts have separate
names. The candidate binds the selection evidence to its exact proposal through
`evidence/request.json` and the bundle's checksum inventory.

Download the complete candidate artifact for a local check:

```sh
gh run download RUN_ID --name CANDIDATE_ARTIFACT_NAME --dir ./candidate
bash tools/release/import-candidate.sh --candidate ./candidate \
  --expected-sha256 EXPECTED_MANIFEST_SHA256
```

Use the manifest checksum reported by the qualification job. On a development
machine, add `--allow-emulation`. This does not change the native qualification
record made by CI. See [candidate verification](RELEASE_CANDIDATES.md#verify-a-transfer).

## Stop and retry

Read the failed job and its retained evidence. Fix the cause and rerun the
original workflow, or run another explicit preview of the same source/version.
Reruns recheck current policy. Use an explicit preview when the same proposed
version is needed after a policy change. No production number has been consumed.
Missing or delayed API evidence can
require a later rerun. Do not recreate a release branch to repair its history.

The collector reads at most one year of activity, 20 pages per list, 100
maintenance commits, and 500 API responses. Raw responses are capped at
16 MiB and retained selection files at 32 MiB. Missing original creation,
missing policy/review history, force updates, observed recreation, or ambiguous
history stops branch selection. Use a manual preview while maintainers resolve
the missing evidence.

This read-only collector does not supply durable creation or request state.
It checks the available activity window. It cannot establish branch history
outside that window. Existing production tags require matching durable release
records; it refuses unexplained tags instead of inventing their state.

Automatic patch progression, durable deduplication, retained-candidate recovery,
Git tags, image publication, and GitHub Releases belong to the publication
coordinator. Until that exists, separate branch updates may propose the same
unused version. Passing qualification does not authorize publication.

## Check changes locally

```sh
bash tests/release/github.sh
bash tests/release/proposals.sh
bash tests/release/candidates.sh
make check-shell
```

The GitHub fixtures use temporary Git history and a local GET-only API stub.
They make no external API calls or changes to project refs. The **Shell lint**
workflow also runs pinned actionlint to validate workflow syntax and embedded
shell commands. Hosted event delivery and artifact transfer still need an
actual Actions run.
