include "release-pr";

def check($condition; $name):
  if $condition then . else error("failed release version check: " + $name) end;

def selected($branch; $requests):
  {branch: $branch} | release_request_version({requests: $requests});

check(selected("release/0.1.0"; {}) == "0.1.0"; "first stable patch")
| check(selected("release/0.1.0"; {old: {version: "0.1.0", status: "image"}}) == "0.1.1";
    "incomplete tagged patch keeps its number")
| check(selected("release/0.1.0"; {
    queued: {version: "0.1.4", status: "queued"},
    failed: {version: "0.1.6", status: "failed"},
    completed: {version: "0.1.2", status: "complete"},
    superseded: {version: "0.1.5", status: "superseded"},
    rc: {version: "0.1.99-rc.3"}, other: {version: "0.2.99"}}) == "0.1.7";
    "all reservations count and other release lines do not")
| check(selected("release/0.1.9"; {old: {version: "0.1.4"}}) == "0.1.9";
    "stable branch sets the first patch")
| check(selected("release/0.1.0"; {old: {version: "0.1.9007199254740992"}}) == "0.1.9007199254740993";
    "large patch numbers retain precision")
| check(selected("release/0.1.0-rc"; {}) == "0.1.0-rc.1"; "first RC")
| check(selected("release/0.1.0-rc.1"; {old: {version: "0.1.0-rc.1"}}) == "0.1.0-rc.2";
    "numbered RC branch advances")
| check(selected("release/0.1.0-rc.5"; {old: {version: "0.1.0-rc.2"}}) == "0.1.0-rc.5";
    "numbered RC branch sets the first counter")
| check(selected("release/0.1.0-rc"; {
    failed: {version: "0.1.0-rc.5", status: "failed"},
    queued: {version: "0.1.0-rc.8", status: "queued"},
    stable: {version: "0.1.0"}, other: {version: "0.2.0-rc.99"}}) == "0.1.0-rc.9";
    "RC reservations count across numbered and series branches")
| check(selected("release/0.1.0-beta.1"; {}) == "0.1.0-beta.1"; "other explicit prereleases stay exact")
| check(("release/0.1.0" | release_matches("0.1.2")) and
    ("release/0.1.2" | release_matches("0.1.1") | not) and
    ("release/0.1.0" | release_matches("0.2.0") | not) and
    ("release/0.1.0" | release_matches("0.1.1-rc.1") | not) and
    ("release/0.1.0" | release_matches("0.1.1+build") | not); "stable source validation")
| check(("release/0.1.0-rc.1" | release_matches("0.1.0-rc.2")) and
    ("release/0.1.0-rc.2" | release_matches("0.1.0-rc.1") | not) and
    ("release/0.1.0-rc.1" | release_matches("0.1.1-rc.2") | not) and
    ("release/0.1.0-rc.1" | release_matches("0.1.0") | not); "numbered RC source validation")
| {branch: "release/0.1.0", version: "0.1.1", event: {kind: "release"}} as $current
| ($current | .version = "0.1.0" | .tag_object_sha = ("a" * 40)) as $earlier
| check(($current | release_can_follow($earlier)) and
    ($current | release_can_follow($earlier | del(.tag_object_sha)) | not) and
    ($current | release_can_follow($earlier | .version = "0.1.1") | not) and
    ($current | release_can_follow($earlier | .branch = "release/0.1.1") | not) and
    ($current | .event.kind = "update" | release_can_follow($earlier) | not);
    "only newer numbered releases can pass an earlier reserved tag")
| true
