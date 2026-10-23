# Release proposals

`tools/release/propose.sh` inspects a committed source snapshot and proposes a
version. It writes one JSON record to stdout. It does not build, reserve a
version, change Git refs, publish an image, or create a GitHub release.

Requires Bash 3.2 or newer, Git, jq 1.6 or newer, sed, mktemp, and a SHA-256
tool. Run the reviewed tooling from the repository root. The selected repository
needs complete Git history and an up-to-date `refs/remotes/origin/main`.
The command reads local refs and performs no fetch.

## Preview a source and version

```sh
bash tools/release/propose.sh --source HEAD --version 0.2.0-rc.1+local.001
```

`--source` defaults to `HEAD`. It may name a branch, tag, or full commit SHA.
The command resolves it once and reads its development version directly from
that commit. Uncommitted source changes are outside that snapshot.

With no version or line input, the proposal uses that development default.
With a line, it proposes the next version from policy and supplied state:

```sh
bash tools/release/propose.sh --source HEAD --line 0.2 --state state.json
```

An unregistered preview line defaults to a regular first version. An explicit
version must belong to the selected line. Preview records always have
`mode: "preview"`, `source_eligible: false`, `publishable: false`, and no branch
request key. `eligibility_limits` explains missing registration or revoked policy.

`--repo DIR` selects another local Git repository. `--repository OWNER/REPO`
sets its expected lowercase identity, defaulting to `kgxlabs/kgcache`.
`--policy-sha SHA` asserts the exact pinned `origin/main` snapshot. A different
or stale SHA fails.

## Release-line policy

Policy comes from `.github/release-lines.json` at the pinned main commit.
The tool never uses the selected release branch's private policy copy.
The checked-in registry starts empty. Review registration changes on main
before creating a release branch.

This is the shape of one registered line. Replace the SHA placeholder with
the approved full main commit SHA:

```json
{
  "schema_version": 1,
  "repository": "kgxlabs/kgcache",
  "lines": [{
    "line": "0.2",
    "branch": "release/0.2",
    "cut_sha": "<full-cut-sha>",
    "status": "preparing",
    "channel": "regular",
    "prerelease_prefix": null,
    "target_version": null,
    "decision_ref": "review/line-registration",
    "notes_ref": "notes/0.2",
    "baseline": null,
    "activation": null,
    "blocked_versions": []
  }]
}
```

Line names use canonical `MAJOR.MINOR` numbers, without leading zeroes.
Statuses are `preparing`, `supported`, and `retired`. Preparing lines allow
candidate proposals and their first completed regular version. Later patches require
supported status and a completed regular baseline. Retired lines cannot start
a new branch release proposal.

For candidates, set `channel: "prerelease"`, a valid `prerelease_prefix` such
as `rc`, and `target_version`, such as `0.2.0`. The target must be the next
regular version. Counters include reserved candidates. Prefix changes must
advance SemVer precedence for that target.

`blocked_versions` holds full versions revoked by reviewed policy. An abandoned
tag needs a blocking record. `baseline`, when present, contains `version`,
`source_sha`, and `record_ref` for a completed fixed release. `activation`
contains `source_sha` and `decision_ref` for an imported branch baseline.
Imported lines need a new reviewed update after that baseline.

## Check a branch request

Pass a normalized event record from a trusted caller:

```sh
bash tools/release/propose.sh --event event.json --state state.json
```

The event fixes the source SHA. `--source` and `--version` cannot override it.
Both `refs/remotes/origin/main` and the registered remote release branch must
be available. A later release tip may prove ancestry but cannot replace the
event source.

A creation record has this shape:

```json
{
  "schema_version": 1,
  "repository": "kgxlabs/kgcache",
  "kind": "create",
  "branch": "release/0.2",
  "source_sha": "<full-cut-sha>",
  "before_sha": null,
  "forced": false,
  "deleted": false,
  "creation_id": "<original-creation-identity>",
  "creation_policy_sha": "<main-policy-sha-before-creation>",
  "review": null
}
```

The source must equal the registered cut. The creation policy must already
register that cut and remain reachable from current main. Repeated deliveries
use the same `creation_id`. A recreated branch uses a different identity.
Git does not store branch lifetimes, so the caller supplies this evidence.

For an update, use `kind: "update"`, the actual `before_sha`, and the resulting
full `source_sha`. Keep the original creation identity. Supply a review object:

```json
{
  "before_sha": "<full-before-sha>",
  "source_sha": "<full-resulting-squash-sha>",
  "decision_ref": "review/backport-pr",
  "kind": "fix",
  "main_commits": ["<full-main-fix-sha>"]
}
```

An update must add one squash commit after its before SHA. Each earlier commit
after the cut needs a matching saved review. Fix backports require source
commits reachable from pinned main. Necessary maintenance uses
`kind: "maintenance"` and may have no main source commits.

The caller supplies authentic event, review, and release records. The tool
checks their structure, identity, Git history, and policy consistency.
`source_eligible: true` describes those checks. Source/image qualification and
publication approval are separate requirements. Every result remains
`proposal_only: true` and `publishable: false`.

## State and retries

State is input only. The command does not change or reserve it. An empty state
has this shape:

```json
{
  "schema_version": 1,
  "repository": "kgxlabs/kgcache",
  "creation": null,
  "updates": [],
  "requests": [],
  "releases": []
}
```

| Field | Contents |
| --- | --- |
| `creation` | Original `branch`, `source_sha`, `policy_sha`, and `creation_id`. Copy the verified creation record from the proposal. Required for updates and existing reserved lines. |
| `updates` | Accepted review records for earlier squash commits after the cut. |
| `requests` | Prior `state_request` records. Status is `proposed`, `failed`, or `superseded`. Preview records cannot enter this list. |
| `releases` | Fixed version records with `version`, `branch`, `source_sha`, `policy_sha`, `request_key`, `tag_object_sha`, and status `complete`, `incomplete`, or `abandoned`. |

Every version tag on the selected line must have a matching release record.
It must be annotated and point directly to the recorded commit. Missing,
changed, or unexplained tags fail. Metadata-only versions with equal SemVer
precedence are rejected as conflicting reserved state.

The first regular proposal is patch `0`. Later proposals increment the greatest
reserved regular patch, including blocked or abandoned tags. A tagged attempt
blocks later requests until complete or explicitly blocked. An untagged pending
request also blocks later requests. A reviewed descendant may supersede a
failed untagged attempt and reuse its unreserved number.

A matching prior request or fixed release returns its original version with
`reused: true`. Stale, superseded, conflicting, or revoked identities fail.
No version number is reserved by this command.

`policy_sha` records current validation policy. `original_policy_sha` retains
the branch request's original policy on retries. `reservation` contains the
matching fixed release record when a version tag already exists, otherwise null.

## Identity and version format

Versions follow [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html), including
large numeric identifiers. Numeric ordering and increments preserve their
decimal strings. Build metadata does not change precedence.

The Docker version tag replaces `+` with `_`. The full SemVer value stays in
the record. Mapped tags must fit the
[128-character Docker tag grammar](https://github.com/distribution/reference/blob/main/regexp.go).
They are never truncated.

Identity keys use SHA-256 of compact UTF-8 JSON arrays, with no trailing newline:

- Branch request: `[1,"request",repository,branch,source_sha]`.
- Source/version: `[1,"source-version",source_sha,version]`.

`request_key` stays the same across duplicate deliveries or policy snapshots.
The source/version key produces the proposed `src-<key>` image reference.
These names are output data only.

## Maintenance compatibility

Check a complete PR title/body or commit message from stdin:

```sh
bash tools/release/compatibility.sh < message.txt
```

The check rejects `feat`, a Conventional Commit `!`, and `BREAKING CHANGE` or
`BREAKING-CHANGE` footers. Branch proposals apply it to reviewed release commits
and their declared main source commits. Review still determines whether an
unmarked change preserves compatibility.

Run the local checks with `bash tests/release/proposals.sh`. All test commits,
branches, and version tags live in temporary repositories. They do not alter
project refs or create real releases.
