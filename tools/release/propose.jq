include "semver";
include "policy";

def greatest_version:
  reduce .[] as $version (null;
    if . == null or semver_compare($version; .) > 0 then $version else . end);

def next_regular($line; $releases):
  ($releases | map(.version | select((semver_parts | .prerelease) == null)) | greatest_version) as $last
  | if $last == null then $line + ".0"
    else ($last | semver_parts) | .major + "." + .minor + "." + (.patch | numeric_increment) end;

$policy[0] as $policy
| $state[0] as $state
| $event[0] as $event
| ($policy.lines | map(select(.line == $line)) | .[0] // null) as $registered
| ($registered // {line: $line, branch: (if $line == "" then null else "release/" + $line end),
     status: null, channel: "regular", prerelease_prefix: null, target_version: null,
     decision_ref: null, notes_ref: null, baseline: null, activation: null, blocked_versions: []}) as $selected
| ($state.releases | map(select(.branch == $selected.branch))) as $releases
| ($state.requests | map(select(.branch == $selected.branch))) as $requests
| ($tags[0] | map(
    require(.version | semver; "unexpected version tag: invalid SemVer")
    | select($line != "" and (.version | version_line) == $line))) as $tags
| $tags
| require(all(.[]; .type == "tag" and .peeled_type == "commit"); "version tags must be annotated and point directly to commits")
| require(all(.[]; . as $tag | any($releases[];
    .version == $tag.version and .tag_object_sha == $tag.object_sha and .source_sha == $tag.source_sha));
    "unexpected tag or missing/conflicting reserved release record")
| require(all($releases[]; . as $release | any($tags[];
    .version == $release.version and .object_sha == $release.tag_object_sha and .source_sha == $release.source_sha));
    "reserved release tag is missing or changed")
| require(all(range(0; $releases | length); . as $index |
    all(range($index + 1; $releases | length);
      semver_compare($releases[$index].version; $releases[.].version) != 0));
    "reserved releases have equal SemVer precedence")
| require(all($releases[]; .status != "abandoned" or
    (.version as $version | $selected.blocked_versions | index($version)) != null);
    "an abandoned tag requires an explicit blocked-version policy record")
| ($requests | map(select(.request_key == $request_key)) | .[0] // null) as $prior
| ($releases | map(select(.request_key == $request_key)) | .[0] // null) as $reserved
| require($prior == null or $reserved == null or $prior.version == $reserved.version;
    "saved request and reserved release disagree")
| require($prior == null or $reserved == null or $prior.policy_sha == $reserved.policy_sha;
    "saved request and reserved release policy disagree")
| require($prior == null or $prior.status != "superseded"; "request was superseded")
| ($reserved.policy_sha // $prior.policy_sha // $policy_sha) as $original_policy
| (next_regular($line; $releases)) as $regular
| (if ($mode == "preview" and ($explicit_version != "" or $line == "")) or $reserved != null then null
   elif $selected.channel == "prerelease" then
     require($selected.target_version == $regular; "candidate target must be the next regular version")
     | next_candidate($selected.target_version; $selected.prerelease_prefix; $releases)
   else $regular end) as $fresh
| (if $mode == "preview" and $explicit_version != "" then $explicit_version
   elif $mode == "preview" and $line == "" then $development_version
   else $reserved.version // $prior.version // $fresh end) as $version
| require($version | semver; "proposal version must be SemVer 2.0.0")
| require($line == "" or ($version | version_line) == $line; "version belongs to another release line")
| ($version | docker_tag) as $image_tag
| ($mode == "branch" and ($prior != null or $reserved != null)) as $reused
| if $mode == "branch" then
    require($registered != null; "unregistered release line")
    | require($selected.status != "retired"; "release line is retired")
    | require(($selected.blocked_versions | index($version)) == null; "version is blocked by main policy")
    | require($reserved.status == "complete" or $selected.status != "preparing" or
        (all($releases[]; .status != "complete" or (.version | semver_parts | .prerelease) != null));
        "a completed regular release requires supported line status")
    | require($selected.status != "supported" or
        any($releases[]; .status == "complete" and (.version | semver_parts | .prerelease) == null);
        "supported line requires a completed regular baseline")
    | require($reserved.status == "complete" or all($releases[]; .request_key == $request_key or .status == "complete" or
        (.version as $v | $selected.blocked_versions | index($v)) != null);
        "an earlier tagged request is unresolved")
    | require($reserved.status == "complete" or all($requests[]; .request_key == $request_key or .status != "proposed" or
        (.request_key as $key | any($releases[]; .request_key == $key)));
        "an earlier untagged request is still pending")
    | require(all($releases[]; .version != $version or .request_key == $request_key);
        "proposed version is reserved by another request")
    | require($reserved != null or $prior == null or $prior.version == $fresh;
        "untagged prior proposal is stale; reconcile request order")
    | if $reserved == null or $reserved.status != "complete" then
        require(($version | semver_parts | .metadata) == null; "automatic versions must not contain build metadata")
        | require((($version | semver_parts | .prerelease) != null) == ($selected.channel == "prerelease");
            "channel changed while the request was unresolved")
        | if $selected.channel == "prerelease" then
            require(($version | semver_parts | .major + "." + .minor + "." + .patch) == $selected.target_version;
                "candidate target changed while the request was unresolved")
            | require(($version | semver_parts | .prerelease[:-1] | join(".")) == $selected.prerelease_prefix;
                "candidate prefix changed while the request was unresolved")
          else . end
      else . end
    | require($reused or $selected.channel != "prerelease" or all($releases[];
        (.version | semver_parts) as $parts
        | if $parts.prerelease != null and
            ($parts.major + "." + $parts.minor + "." + $parts.patch) == $selected.target_version
          then semver_compare($version; .version) > 0 else true end);
        "candidate prefix change would not advance SemVer precedence")
  else . end
| require($selected.baseline == null or any($releases[];
    .version == $selected.baseline.version and .source_sha == $selected.baseline.source_sha and .status == "complete");
    "reviewed baseline lacks its completed fixed release record")
| {
    schema_version: 1, mode: $mode, publishable: false, proposal_only: true,
    repository: $repository, source_sha: $source, development_version: $development_version,
    policy_sha: $policy_sha,
    original_policy_sha: (if $mode == "branch" then $original_policy else null end),
    reservation: $reserved, line: (if $line == "" then null else $line end),
    branch: $selected.branch, cut_sha: ($registered.cut_sha // null),
    version: $version, intended_tag: ("v" + $version),
    channel: (if ($version | semver_parts | .prerelease) == null then "regular" else "prerelease" end),
    policy_channel: $selected.channel, reused: $reused,
    image: {version_tag: $image_tag},
    request_key: (if $mode == "branch" then $request_key else null end),
    event: $event, creation: $creation[0],
    decision_ref: $selected.decision_ref, notes_ref: $selected.notes_ref,
    baseline: $selected.baseline, activation: $selected.activation,
    source_eligible: ($mode == "branch"), qualification_required: true,
    eligibility_limits: (if $mode == "branch" then
       ["Review/event/state authenticity is the caller's responsibility.", "Source/image qualification has not run."]
      else ["A manual preview is not a branch release request.", "Source/image qualification has not run."] +
       (if $registered == null then ["No registered release line was selected."] else [] end) +
       (if $selected.status == "retired" then ["The selected release line is retired."] else [] end) +
       (if ($selected.blocked_versions | index($version)) != null then ["The selected version is blocked."] else [] end) end),
    supersedes: (if $mode == "branch" and ($reused | not) then
       [$requests[] | select(.status == "failed" and .request_key != $request_key)
        | select(.request_key as $key | all($releases[]; .request_key != $key)) | .request_key] else [] end),
    state_request: (if $mode == "branch" then {
       mode: "branch", repository: $repository, branch: $selected.branch, source_sha: $source,
       request_key: $request_key, version: $version, policy_sha: $original_policy, status: "proposed"
     } else null end)
  }
