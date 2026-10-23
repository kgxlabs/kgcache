include "semver";

.schema_version == 2 and (.development_version | semver) and
.binary.sha256 == $sha and .persistence_test_controls == false and
.target == "x86_64-linux-gnu.2.36" and .cpu == "baseline" and
.optimize == "ReleaseSafe" and
.source.revision == $image[0][0].Config.Labels["org.opencontainers.image.revision"] and
(.source.dirty | type == "boolean") and
((.source.revision | test("^[0-9a-f]{40}$")) or
  (.source.revision == "unknown" and .source.dirty)) and
(.version | semver) and $version == ("kgcache " + .version) and
(.version == $image[0][0].Config.Labels["org.opencontainers.image.version"] or
  (.source.dirty and .version == .development_version and
    $image[0][0].Config.Labels["org.opencontainers.image.version"] == ""))
