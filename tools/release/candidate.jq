include "semver";

def candidate_require($condition; $message):
  if $condition then . else error($message) end;
def candidate_sha: type == "string" and test("\\A[0-9a-f]{64}\\z");
def candidate_commit: type == "string" and test("\\A[0-9a-f]{40}\\z");
def candidate_image_id: type == "string" and test("\\Asha256:[0-9a-f]{64}\\z");
def candidate_path:
  type == "string" and startswith("evidence/") and
  test("\\A[A-Za-z0-9_./-]+\\z") and
  (split("/") | all(.[]; . != "" and . != "." and . != ".."));

def validate_candidate_proposal:
  candidate_require(type == "object" and .schema_version == 1; "proposal schema_version must be 1")
  | candidate_require(.mode == "preview" or .mode == "branch" or .mode == "release"; "invalid proposal mode")
  | candidate_require(.publishable == false and .proposal_only == true and .qualification_required == true;
      "qualification requires a non-publishing proposal")
  | candidate_require(.repository | type == "string" and test("\\A[a-z0-9_.-]+/[a-z0-9_.-]+\\z");
      "invalid proposal repository")
  | candidate_require((.source_sha | candidate_commit) and (.policy_sha | candidate_commit);
      "proposal must pin source and policy commits")
  | candidate_require((.version | semver) and (.development_version | semver); "invalid proposal versions")
  | candidate_require(.intended_tag == "v" + .version and .image.version_tag == (.version | docker_tag);
      "proposal tag/version mapping differs")
  | candidate_require(.image.source_version_key | candidate_sha; "invalid source/version key")
  | candidate_require(.image.source_tag == "src-" + .image.source_version_key; "invalid source/version reference")
  | candidate_require(.reservation == null; "reserved requests require retained-candidate recovery, not a rebuild")
  | if .mode == "preview" then
      candidate_require(.request_key == null and .state_request == null and .source_eligible == false;
        "preview must not claim branch eligibility")
    else
      candidate_require(.source_eligible == true and (.request_key | candidate_sha) and
        (.original_policy_sha | candidate_commit) and (.cut_sha | candidate_commit);
        "branch proposal is missing source eligibility")
      | candidate_require((if .mode == "release" then .branch == "release/" + .version
          else .branch == "release/" + .line end) and
          (.version | semver_parts | .major + "." + .minor) == .line;
          "branch proposal line/version mismatch")
      | candidate_require(.event.source_sha == .source_sha and .event.branch == .branch and
          .state_request.source_sha == .source_sha and .state_request.version == .version and
          .state_request.request_key == .request_key and .state_request.policy_sha == .original_policy_sha;
          "branch proposal identities disagree")
      | if .mode == "release" then
          candidate_require(.event.kind == "release" and .event.version == .version and
            .release_notes.pr_number == .event.pr_number and
            (.release_notes.body | type == "string" and length > 0) and
            (.release_notes.sha256 | candidate_sha); "release proposal lacks frozen PR notes")
        else . end
    end;

def candidate_phases:
  ["source-unit", "source-process", "source-build", "source-arm64", "source-proposals", "source-failures",
   "source-shell", "client-prepare", "client-quality", "image-build", "image-artifact",
   "image-runtime", "image-service", "client-go", "client-node"];

def validate_candidate:
  candidate_require(type == "object" and .schema_version == 1 and .kind == "release-candidate";
      "candidate schema_version must be 1")
  | candidate_require(.publishable == false; "candidate must be non-publishing")
  | .proposal |= validate_candidate_proposal
  | candidate_require(.mode == .proposal.mode and .repository == .proposal.repository and
      .source_sha == .proposal.source_sha and .version == .proposal.version and
      .development_version == .proposal.development_version; "candidate/proposal identity mismatch")
  | candidate_require(.build.source.revision == .source_sha and .build.source.dirty == false and
      .build.version == .version and .build.development_version == .development_version;
      "candidate/build identity mismatch")
  | candidate_require(.platform == "linux/amd64" and .build.platform == .platform; "unsupported candidate platform")
  | candidate_require(.image.id | candidate_image_id; "invalid candidate image ID")
  | candidate_require(.image.source_version_key == .proposal.image.source_version_key and
      .image.version_tag == .proposal.image.version_tag; "candidate image/version mapping mismatch")
  | candidate_require(.archive.path == "kgcache-linux-amd64.docker.tar.gz" and
      .archive.format == "docker-archive+gzip" and (.archive.sha256 | candidate_sha) and
      (.archive.bytes | type == "number" and . > 0 and . <= 536870912 and . == floor);
      "invalid candidate archive descriptor")
  | candidate_require(.run.id | type == "string" and test("\\A[A-Za-z0-9_.-]+\\z"); "invalid candidate run ID")
  | candidate_require(.run.attempt | type == "string" and test("\\A[1-9][0-9]*\\z"); "invalid run attempt")
  | candidate_require((.run.workflow_sha | candidate_commit) and
      (.run.workflow_ref | type == "string" and length > 0); "invalid workflow identity")
  | candidate_require((.tooling.revision | candidate_commit) and (.tooling.dirty | type == "boolean") and
      (.tooling.entrypoint_sha256 | candidate_sha); "invalid tooling identity")
  | candidate_require(.checks | type == "array" and all(.[]; .passed == true and (.log | candidate_path));
      "candidate checks did not pass")
  | candidate_require((.checks | map(.name) | unique | length) == (.checks | length); "duplicate check name")
  | candidate_require((candidate_phases - [.checks[].name] | length) == 0; "candidate is missing required checks")
  | candidate_require(.evidence | type == "array" and length > 0 and length <= 512 and all(.[];
      (.path | candidate_path) and (.sha256 | candidate_sha) and
      (.bytes | type == "number" and . >= 0 and . <= 1048576 and . == floor)); "invalid evidence inventory")
  | candidate_require((.evidence | map(.path) | unique | length) == (.evidence | length);
      "duplicate evidence path")
  | candidate_require((.evidence | map(.bytes) | add) <= 33554432; "candidate evidence exceeds 32 MiB")
  | candidate_require((["evidence/reports/runtime.json", "evidence/reports/service.json",
      "evidence/client-matrix.json", "evidence/image.json", "evidence/tooling.json"] - [.evidence[].path] | length) == 0;
      "candidate qualification reports are missing")
  | . as $candidate
  | candidate_require(all(.checks[]; .log as $log | any($candidate.evidence[]; .path == $log));
      "check log is missing from evidence")
  | candidate_require(.qualification.native_source | type == "boolean"; "missing source platform proof")
  | candidate_require(.qualification.native_image | type == "boolean"; "missing image platform proof")
  | candidate_require(.qualification.qualified_amd64 ==
      (.qualification.native_source and .qualification.native_image); "qualification/platform flags disagree")
  | candidate_require(.qualification.native_source == (.qualification.host == "linux/amd64") and
      .qualification.native_image == (.qualification.engine == "linux/amd64"); "native platform claims disagree")
  | candidate_require(.client_coverage.source_profiles | type == "array" and length > 0;
      "missing required source-client profiles")
  | candidate_require(.client_coverage.source_binary ==
      (if .qualification.native_source then "image" else "host-build" end);
      "source-client executable provenance differs");
