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

def dispatch_event($repository; $source; $run):
  require((.repository.full_name | ascii_downcase) == $repository and
      (.ref == "main" or .ref == "refs/heads/main") and .inputs.operation == "Publish RC";
      "RC publication requires an explicit Publish RC dispatch from main")
  | require((.inputs.source_sha | sha) and .inputs.source_sha == $source and
      (.inputs.version // "") == ""; "publication requires the exact source SHA and automatic version selection")
  | require(($run | type == "string" and test("\\A[1-9][0-9]*\\z")) and
      (.sender.login | reference) and (.sender.id | type == "number" and . > 0 and floor == .);
      "publication requires a dispatch run and actor identity")
  | (.inputs.source_ref | release_version) as $target
  | require($target | rc_series; "manual publication requires release/MAJOR.MINOR.PATCH-rc")
  | require(.inputs.release_notes | type == "string" and length <= 32768 and
      (gsub("(?s)<!--.*?-->"; "") | gsub("^\\s+|\\s+$"; "") | length > 0);
      "manual publication requires nonempty release notes")
  | {schema_version: 1, repository: $repository, kind: "release", trigger: "workflow_dispatch",
      branch: .inputs.source_ref, source_sha: $source, version: $target, pr_number: null,
      run_id: $run, actor: .sender, title: ("Publish " + $target), notes: .inputs.release_notes,
      decision_ref: ("https://github.com/" + $repository + "/actions/runs/" + $run)};

def creation_dispatch_event($repository; $source; $run):
  require(.action == "initial-rc" and (.repository.full_name | ascii_downcase) == $repository and
      .sender.login == "github-actions[bot]"; "expected an automatic initial RC request")
  | require((.client_payload.source_sha | sha) and .client_payload.source_sha == $source and
      (.client_payload.creation_run_id | type == "string" and test("\\A[1-9][0-9]*\\z")) and
      ($run | type == "string" and test("\\A[1-9][0-9]*\\z")); "invalid branch creation request identity")
  | (.client_payload.branch | release_version) as $target
  | require($target | rc_series; "automatic publication requires release/MAJOR.MINOR.PATCH-rc")
  | {schema_version:1,repository:$repository,kind:"release",trigger:"repository_dispatch",origin:"branch_creation",
      branch:.client_payload.branch,source_sha:$source,version:$target,pr_number:null,
      run_id:$run,creation_run_id:.client_payload.creation_run_id,actor:.sender,title:("Publish " + $target),notes:"",
      decision_ref:("https://github.com/" + $repository + "/actions/runs/" + $run)};

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
