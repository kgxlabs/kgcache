# SemVer 2.0.0. Anchors cover the whole string, including trailing newlines.
# Keep identifiers as strings so large numeric fields do not lose precision.
def semver:
  type == "string" and test(
    "\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" +
    "(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?" +
    "(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?\\z");
