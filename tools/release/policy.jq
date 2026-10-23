include "semver";

def require($condition; $message):
  if $condition then . else error($message) end;

def sha: type == "string" and test("\\A[0-9a-f]{40}\\z");
def checksum: type == "string" and test("\\A[0-9a-f]{64}\\z");
def reference: type == "string" and test("\\A[^[:space:]]+\\z");
def line_name: type == "string" and test("\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\z");
def version_line: semver_parts | .major + "." + .minor;
def regular: semver and (semver_parts | .prerelease == null);
def unique_by_field($field): length == (map(.[$field]) | unique | length);
def only_keys($allowed): (keys - $allowed | length) == 0;

def validate_line:
  require(type == "object"; "release line must be an object")
  | require(only_keys(["line", "branch", "cut_sha", "status", "channel", "prerelease_prefix",
      "target_version", "decision_ref", "notes_ref", "baseline", "activation", "blocked_versions"]);
      "unknown release-line field")
  | require(.line | line_name; "line must be canonical MAJOR.MINOR")
  | require(.branch == "release/" + .line; "branch must match release/<line>")
  | require(.cut_sha | sha; "cut_sha must be a full commit SHA")
  | require(.status == "preparing" or .status == "supported" or .status == "retired"; "invalid line status")
  | require(.channel == "regular" or .channel == "prerelease"; "invalid release channel")
  | require(.decision_ref | reference; "decision_ref is required")
  | require(.notes_ref | reference; "notes_ref is required")
  | . as $line
  | require(.blocked_versions | type == "array" and all(.[]; semver and (version_line == $line.line));
      "blocked_versions must contain full versions from this line")
  | require((.blocked_versions | unique | length) == (.blocked_versions | length); "duplicate blocked version")
  | if .channel == "prerelease" then
      require(.prerelease_prefix | type == "string" and length > 0; "prerelease_prefix is required")
      | require(("0.0.0-" + .prerelease_prefix + ".1") | semver; "invalid prerelease_prefix")
      | require(("0.0.0-" + .prerelease_prefix + ".1" | semver_parts | .metadata) == null;
          "prerelease_prefix must not contain build metadata")
      | require(.target_version | regular and (semver_parts | .metadata == null);
          "target_version must be a regular SemVer without metadata")
      | require((.target_version | version_line) == .line; "target_version belongs to another line")
    else require(.prerelease_prefix == null and .target_version == null;
      "regular channel must not set a candidate prefix or target") end
  | require(.baseline == null or (.baseline | type == "object" and
      (.version | regular) and (.source_sha | sha) and (.record_ref | reference)); "invalid baseline")
  | require(.baseline == null or (.baseline.version | version_line) == .line; "baseline belongs to another line")
  | require(.activation == null or (.activation | type == "object" and
      (.source_sha | sha) and (.decision_ref | reference)); "invalid activation");

def validate_policy($repository):
  require(type == "object" and .schema_version == 1; "release policy schema_version must be 1")
  | require(only_keys(["schema_version", "repository", "lines"]); "unknown release-policy field")
  | require(.repository == $repository; "release policy repository mismatch")
  | require(.lines | type == "array"; "policy lines must be an array")
  | .lines |= map(validate_line)
  | require(.lines | unique_by_field("line"); "duplicate release line");

def validate_review:
  require(type == "object" and (.before_sha | sha) and (.source_sha | sha); "invalid reviewed update identity")
  | require(.decision_ref | reference; "review decision_ref is required")
  | require(.kind == "fix" or .kind == "maintenance"; "review kind must be fix or maintenance")
  | require(.main_commits | type == "array" and all(.[]; sha); "main_commits must contain full SHAs")
  | require(.kind != "fix" or (.main_commits | length) > 0; "fix backports require main_commits");

def validate_state($repository):
  require(type == "object" and .schema_version == 1; "release state schema_version must be 1")
  | require(only_keys(["schema_version", "repository", "creation", "updates", "requests", "releases"]);
      "unknown release-state field")
  | require(.repository == $repository; "release state repository mismatch")
  | require(.creation == null or (.creation | type == "object" and
      (.branch | type == "string") and (.source_sha | sha) and (.policy_sha | sha) and
      (.creation_id | reference)); "invalid original branch creation")
  | require(.updates | type == "array"; "updates must be an array")
  | .updates |= map(validate_review)
  | require(.updates | unique_by_field("source_sha"); "duplicate reviewed source")
  | require(.requests | type == "array"; "requests must be an array")
  | .requests |= map(
      require(.mode == "branch" and .repository == $repository and
        (.branch | type == "string") and (.source_sha | sha) and
        (.policy_sha | sha) and (.request_key | checksum) and (.version | semver); "invalid prior branch request")
      | require(.status == "proposed" or .status == "failed" or .status == "superseded"; "invalid request status"))
  | require(all(.requests[]; .branch == "release/" + (.version | version_line)); "prior request line/version mismatch")
  | require(.requests | unique_by_field("request_key"); "duplicate prior request")
  | require(.releases | type == "array"; "releases must be an array")
  | .releases |= map(
      require((.version | semver) and (.source_sha | sha) and (.policy_sha | sha) and
        (.tag_object_sha | sha) and (.request_key | checksum) and (.branch | type == "string");
        "invalid reserved release identity")
      | require(.status == "complete" or .status == "incomplete" or .status == "abandoned";
          "invalid reserved release status"))
  | require(all(.releases[]; .branch == "release/" + (.version | version_line)); "reserved release line/version mismatch")
  | require(.releases | unique_by_field("version"); "duplicate reserved version")
  | require(.releases | unique_by_field("request_key"); "one branch request cannot reserve multiple versions");

def validate_event($repository):
  require(type == "object" and .schema_version == 1; "branch event schema_version must be 1")
  | require(.repository == $repository; "branch event repository mismatch")
  | require(.kind == "create" or .kind == "update"; "event must create or update a branch")
  | require(.branch | type == "string" and startswith("release/"); "event must target a release branch")
  | require(.branch[8:] | line_name; "event branch must be canonical release/MAJOR.MINOR")
  | require(.source_sha | sha; "event source must be a full commit SHA")
  | require(.forced == false and .deleted == false; "forced or deleted branches cannot request a release")
  | require(.creation_id | reference; "original creation_id is required")
  | if .kind == "create" then
      require(.creation_policy_sha | sha; "creation_policy_sha must pin the policy before branch creation")
      |
      require(.before_sha == null and .review == null; "creation must not contain an update review or before SHA")
    else require(.before_sha | sha; "update before_sha must be a full commit SHA")
      | require(.review.before_sha == .before_sha and .review.source_sha == .source_sha;
          "review and event source identities differ")
      | .review |= validate_review end;
