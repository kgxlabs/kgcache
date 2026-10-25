include "semver";
include "policy";

def publication_statuses:
  ["queued", "admitted", "failed", "superseded", "qualified", "tagged", "image", "release", "complete"];

def review_bypass:
  (if has("review_bypass") then .review_bypass else null end)
  | require(. == null or (type == "object" and (.login | reference) and
      (.id | type == "number" and . > 0 and floor == .)); "invalid review bypass");

def validate_automation($repository):
  require(.schema_version == 1 and .repository == $repository and
    (.enabled | type == "boolean") and .state_ref == "refs/heads/release-state";
    "invalid release automation settings")
  | require(review_bypass | . == null or type == "object"; "invalid review bypass")
  | require((if has("blocked_versions") then .blocked_versions else [] end) |
      type == "array" and all(.[]; semver) and length == (unique | length);
      "invalid blocked versions")
  | require(.enabled == false or
    ((.publisher_app_id | type == "number" and . > 0 and floor == .) and
     (.tag_ruleset_id | type == "number" and . > 0 and floor == .) and
     (.enforcement_since | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and
     (.registry_repository | type == "string" and test("^docker.io/[a-z0-9_-]+/[a-z0-9_-]+$")));
    "activation needs a publisher app, enforcement baseline, and owned registry")
  | require(all(.required_checks.main[], .required_checks.release[];
      (.context | type == "string" and length > 0) and
      (.integration_id | type == "number" and . > 0)); "invalid required check identity");

def validate_state_rules($app):
  . as $proof
  | require(.effective | type == "array"; "missing state branch protections")
  | require(any(.effective[]; .type == "creation") and
      any(.effective[]; .type == "update") and
      any(.effective[]; .type == "deletion") and
      any(.effective[]; .type == "non_fast_forward"); "state branch must restrict updates and history")
  | require(all(.effective[]; .ruleset_id as $id |
      any($proof.rulesets[]; .id == $id and .enforcement == "active" and .target == "branch" and
        .bypass_actors == [{actor_id: $app, actor_type: "Integration", bypass_mode: "always"}]));
      "only the publisher app may bypass state restrictions")
  | true;

def validate_tag_rules($app):
  . as $ruleset
  | require(.target == "tag" and .enforcement == "active" and
    .conditions.ref_name.include == ["refs/tags/v*"] and .conditions.ref_name.exclude == [] and
    .bypass_actors == [{actor_id: $app, actor_type: "Integration", bypass_mode: "always"}] and
    all(["creation", "update", "deletion"][]; . as $kind | any($ruleset.rules[]; .type == $kind));
    "invalid tag rules");

def validate_ledger($repository):
  require(type == "object" and .schema_version == 1 and .repository == $repository;
    "invalid durable release ledger")
  | require(only_keys(["schema_version", "repository", "lines", "requests", "aliases"]);
    "unknown ledger field")
  | require((.lines | type == "object") and (.requests | type == "object") and
      (.aliases | type == "object"); "invalid ledger collections")
  | .lines |= with_entries(.value |= (
      require((.branch | type == "string") and (.cut_sha | sha) and
          (.last_source_sha | sha) and (.enforcement_sha256 | checksum) and
          (.creation | type == "object") and (.creation.source_sha == .cut_sha) and
          (.creation.creation_id | reference) and (.creation.policy_sha | sha) and
          (.updates | type == "array"); "invalid durable line identity")
      | .updates |= map(validate_review)))
  | require(all(.lines | to_entries[]; (.key | line_name) and .value.branch == "release/" + .key);
      "durable line key mismatch")
  | .requests |= with_entries(.value |= (
      require((.request_key | checksum) and (.source_sha | sha) and (.policy_sha | sha) and
          (.branch | type == "string") and (.event | type == "object") and
          (.event.source_sha == .source_sha and .event.branch == .branch);
          "invalid durable request identity")
      | require(.status as $s | publication_statuses | index($s) != null;
          "invalid durable request status")
      | require(.status == "queued" or (.version | semver); "allocated request lacks a version")
      | require(.status == "queued" or (.proposal.source_sha == .source_sha and
          .proposal.version == .version and .proposal.request_key == .request_key);
          "allocated request/proposal mismatch")
      | require((.status | IN("queued", "admitted", "failed", "superseded")) or
          ((.candidate_sha256 | checksum) and (.candidate.image_id | type == "string"));
          "qualified request lacks retained candidate identity")
      | require((.status | IN("queued", "admitted", "failed", "superseded", "qualified")) or
          (.tag_object_sha | sha); "tagged request lacks tag proof")))
  | require(all(.requests | to_entries[]; .key == .value.request_key); "request key mismatch")
  | require([.requests[] | select(.status != "queued" and .status != "superseded") |
      .branch + ":" + .version] | length == (unique | length); "duplicate allocated version");

# API responses must come from the trusted collector. Ruleset detail is needed
# because effective branch rules alone do not expose bypass permissions.
def validate_merge_rules($required; $bypass):
  . as $proof
  | require(.effective | type == "array"; "missing effective branch rules")
  | require(.rulesets | type == "array" and length > 0; "missing ruleset detail")
  | require(all(.rulesets[]; . as $ruleset |
      .enforcement == "active" and .target == "branch" and has("bypass_actors") and
      (.bypass_actors == [] or ($bypass != null and .bypass_actors ==
        [{actor_id: $bypass.id, actor_type: "User", bypass_mode: "pull_request"}] and
        ([$proof.effective[] | select(.ruleset_id == $ruleset.id)] |
          length == 1 and all(.[]; .type == "pull_request")))));
      "inactive or bypassable merge rules")
  | require(all(.effective[]; .ruleset_id as $id | any($proof.rulesets[]; .id == $id));
      "effective rule has no verified ruleset detail")
  | require(any(.effective[]; .type == "deletion") and
      any(.effective[]; .type == "non_fast_forward") and
      any(.effective[]; .type == "required_linear_history"); "missing branch history protections")
  | require(any(.effective[]; .ruleset_id as $id |
      .type == "pull_request" and
      (.parameters.required_approving_review_count | type == "number") and
      .parameters.required_approving_review_count >= (if $bypass == null then 1 else 0 end) and
      any($proof.rulesets[]; .id == $id and .bypass_actors == []) and
      .parameters.dismiss_stale_reviews_on_push == true and
      .parameters.required_review_thread_resolution == true and
      .parameters.allowed_merge_methods == ["squash"]); "missing required PR review protections")
  | require(any(.effective[]; .type == "pull_request" and
      .parameters.required_approving_review_count >= 1); "missing required PR review protections")
  | require(any(.effective[]; .type == "required_status_checks" and
      .parameters.strict_required_status_checks_policy == true and
      all($required[]; . as $required |
        any($proof.effective[] | select(.type == "required_status_checks") |
          .parameters.required_status_checks[];
          .context == $required.context and .integration_id == $required.integration_id)));
      "missing required status checks")
  | true;

def validate_merge_rules($required): validate_merge_rules($required; null);

def proposer_state($ledger; $line):
  ($ledger.lines[$line] // null) as $stored
  | {schema_version: 1, repository: $ledger.repository,
      creation: $stored.creation, updates: ($stored.updates // []),
      requests: [$ledger.requests[] | select(.branch == "release/" + $line) |
        select(.status | IN("admitted", "qualified", "failed", "superseded")) |
        {mode: "branch", repository: $ledger.repository, branch, source_sha,
          policy_sha: .proposal.original_policy_sha, request_key, version,
          status: (if .status == "failed" then "failed"
            elif .status == "superseded" then "superseded" else "proposed" end)}],
      releases: [$ledger.requests[] | select(.branch == "release/" + $line) |
        select(.tag_object_sha != null) |
        {branch, source_sha, version, request_key, tag_object_sha,
          policy_sha: .proposal.original_policy_sha,
          status: (if .status == "complete" then "complete" else "incomplete" end)}]};

# Freeze each operation's intent and its read-back result separately.
def checkpoint($key; $phase; $value):
  .requests[$key] as $request
  | ({registry_intent: ["registry", "intent"], uploaded: ["registry", "uploaded"],
      verified: ["registry", "verified"], fixed: ["registry", "fixed"],
      github_intent: ["github", "intent"], draft: ["github", "draft"],
      published: ["github", "published"], alias_intent: ["alias", "intent"],
      alias_line: ["alias", "line"], alias_latest: ["alias", "latest"],
      complete: ["alias", "complete"]}[$phase]) as $path
  | require($path != null; "unknown publication checkpoint")
  | require($request.tag_object_sha | sha; "publication requires the reserved tag")
  | require($value | type == "object"; "checkpoint must be an object")
  | require(($request | getpath($path)) == null or ($request | getpath($path)) == $value;
      "checkpoint differs from recorded operation; reconcile original identity")
  | require($phase != "uploaded" or $request.registry.intent != null; "missing upload intent")
  | require($phase != "verified" or
      ($request.registry.uploaded.digest == $value.digest and $value.passed == true and
       $value.image_id == $request.candidate.image_id and
       $value.candidate_sha256 == $request.candidate_sha256 and
       $value.engine_id != $request.registry.intent.engine_id); "invalid clean-pull verification")
  | require($phase != "fixed" or
      ($request.registry.verified.passed == true and $value.digest == $request.registry.uploaded.digest);
      "fixed references require verified uploaded content")
  | require($phase != "github_intent" or $request.registry.fixed != null; "image is not fixed")
  | require($phase != "draft" or $request.github.intent != null; "missing GitHub publication intent")
  | require($phase != "published" or
      ($request.github.draft.id == $value.id and $value.verified == true); "release publication lacks verified draft")
  | require(($phase | startswith("alias_") | not) or $request.github.published.verified == true;
      "aliases require a verified public release")
  | require($phase != "alias_line" or
      ($value == $request.alias.intent.line.target and
       (.aliases[$request.alias.intent.line.key] == $request.alias.intent.line.previous or
        .aliases[$request.alias.intent.line.key] == $value)); "line alias checkpoint conflicts")
  | require($phase != "alias_latest" or
      ($value == $request.alias.intent.latest.target and
       (.aliases.latest == $request.alias.intent.latest.previous or .aliases.latest == $value));
      "latest alias checkpoint conflicts")
  | require($phase != "complete" or
      ($request.github.published.verified == true and $value.verified == true and
       $request.alias.intent != null and
       ($request.alias.intent.line == null or $request.alias.line == $request.alias.intent.line.target) and
       ($request.alias.intent.latest == null or $request.alias.latest == $request.alias.intent.latest.target));
      "release lacks final alias verification")
  | .requests[$key] |= setpath($path; $value)
  | if $phase == "alias_line" then .aliases[$request.alias.intent.line.key] = $value
    elif $phase == "alias_latest" then .aliases.latest = $value else . end
  | if $phase == "fixed" and .requests[$key].status == "tagged" then .requests[$key].status = "image"
    elif $phase == "published" and .requests[$key].status != "complete" then .requests[$key].status = "release"
    elif $phase == "complete" then .requests[$key].status = "complete"
    else . end;

def alias_decision($previous; $target; $key; $tag):
  (if $previous == null then 1 else semver_compare($target.version; $previous.version) end) as $order
  | {key: $key, tag: $tag, previous: $previous,
      advance: ($order > 0), target: (if $order > 0 then $target else $previous end),
      reason: (if $order > 0 then "higher precedence"
        elif $order < 0 then "newer release is already selected"
        elif $target.digest == $previous.digest then "same content and precedence"
        else "equal precedence with different content" end)};

def alias_plan($key):
  . as $ledger | .requests[$key] as $r
  | if ($r.version | semver_parts | .prerelease) != null then {line: null, latest: null}
    else {version: $r.version, digest: $r.registry.fixed.digest, request_key: $key,
      repository: $r.registry.intent.repository, release_id: $r.github.published.id} as $target
    | ($r.version | version_line) as $line
    | {line: alias_decision($ledger.aliases["line/" + $line]; $target; "line/" + $line; $line),
        latest: alias_decision($ledger.aliases.latest; $target; "latest"; "latest")} end;
