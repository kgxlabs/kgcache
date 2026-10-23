include "policy";

# Keep event values as data. Branch creation and push delivery can describe
# the same request, so the source key never includes a workflow run ID.
def workflow_event($name; $repository; $source):
  require((.repository.full_name | ascii_downcase) == $repository; "event repository mismatch")
  | if $name == "push" then
      require(.created | type == "boolean"; "missing push creation flag")
      |
      require(.deleted == false and .forced == false; "forced or deleted branch event")
      | require(.after == $source; "push source differs from workflow SHA")
      | require(.ref | startswith("refs/heads/release/"); "expected a release branch")
      | {kind: (if .created then "create" else "update" end),
          branch: .ref[11:], source_sha: .after,
          before_sha: (if .created then null else .before end)}
    elif $name == "create" then
      require(.ref_type == "branch"; "only branch creation is supported")
      | {kind: "create", branch: .ref, source_sha: $source, before_sha: null}
    else error("unsupported branch event") end
  | require(.branch[8:] | line_name; "expected canonical release/MAJOR.MINOR")
  | require(.source_sha | sha; "invalid event source")
  | require(.kind == "create" or (.before_sha | sha); "invalid event before SHA");

def merged_pr($repository; $branch; $source):
  require(.merged == true and .state == "closed" and (.base.repo.full_name | ascii_downcase) == $repository and
      .base.ref == $branch and .merge_commit_sha == $source and
      (.head.sha | sha) and (.merged_at | type == "string") and
      (.number | type == "number" and . > 0 and floor == .) and
      (.user.login | reference) and (.merged_by.login | reference);
      "expected a merged PR for this exact source and base branch");

# Comments do not revoke an approval. A later change request or dismissal does.
# Require approval of the final PR head before the merge, from another user.
def review_decisions($pr):
  map(select(.submitted_at != null and .submitted_at <= $pr.merged_at and
    (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")))
  | group_by(.user.login) | map(sort_by(.submitted_at, .id) | last)
  | map(select(.user.login != $pr.user.login))
  | {approvals: map(select(.state == "APPROVED" and .commit_id == $pr.head.sha)),
      changes: map(select(.state == "CHANGES_REQUESTED"))};
