include "semver";
include "policy";

def release_version:
  require(type == "string" and startswith("release/"); "expected release/VERSION")
  | .[8:]
  | require(semver and (semver_parts | .metadata == null);
      "release branch must contain a complete SemVer without build metadata")
  | . as $version | docker_tag | $version;

def rc_series:
  semver and (semver_parts | .prerelease == ["rc"] and .metadata == null);

def release_matches($version):
  release_version as $target
  | if $target | rc_series then
      ($version | startswith($target + ".")) and
      ($version[($target | length) + 1:] | test("\\A[1-9][0-9]*\\z"))
    else $version == $target end;

def release_request_version($ledger):
  (.branch | release_version) as $target
  | if $target | rc_series then
      next_candidate($target[:-3]; "rc"; [$ledger.requests[] | select(.version != null)])
    else $target end
  | . as $version | docker_tag | $version;

def release_event($repository; $source):
  require(.action == "closed" and .pull_request.merged == true and
      (.repository.full_name | ascii_downcase) == $repository;
      "release requires a merged pull request")
  | .pull_request as $pr
  | require($pr.state == "closed" and $pr.merge_commit_sha == $source and
      ($pr.base.repo.full_name | ascii_downcase) == $repository and
      ($pr.head.repo.full_name | ascii_downcase) == $repository and
      ($pr.head.sha | sha) and ($pr.number | type == "number" and . > 0 and floor == .) and
      ($pr.merged_at | type == "string"); "release PR identity differs from workflow source")
  | ($pr.base.ref | release_version) as $version
  | {schema_version: 1, repository: $repository, kind: "release", branch: $pr.base.ref,
      source_sha: $source, version: $version, pr_number: $pr.number,
      head_sha: $pr.head.sha, merged_at: $pr.merged_at, title: $pr.title,
      notes: ($pr.body // ""), decision_ref: ("https://github.com/" + $repository + "/pull/" + ($pr.number | tostring))};

def release_proposal($event; $policy; $development; $key; $source_key):
  ($event.notes | gsub("(?s)<!--.*?-->"; "") | gsub("^\\s+|\\s+$"; "")) as $notes
  | {schema_version: 1, mode: "release", repository: $event.repository,
      publishable: false, proposal_only: true, qualification_required: true,
      source_sha: $event.source_sha, development_version: $development,
      policy_sha: $policy, original_policy_sha: $policy, reservation: null,
      line: ($event.version | version_line), branch: $event.branch, cut_sha: $event.source_sha,
      version: $event.version, intended_tag: ("v" + $event.version),
      channel: (if ($event.version | semver_parts | .prerelease) == null then "regular" else "prerelease" end),
      image: {version_tag: ($event.version | docker_tag), source_version_key: $source_key,
        source_tag: ("src-" + $source_key)},
      request_key: $key, event: $event, source_eligible: true, reused: false, supersedes: [],
      decision_ref: $event.decision_ref,
      release_notes: {pr_number: $event.pr_number,
        body: (if $notes == "" then $event.title + "\n\nRelease request: " + $event.decision_ref else $notes end)},
      state_request: {mode: "release", repository: $event.repository, branch: $event.branch,
        source_sha: $event.source_sha, policy_sha: $policy, request_key: $key,
        version: $event.version, status: "proposed"},
      eligibility_limits: ["Native source and image qualification must pass before publication."]};
