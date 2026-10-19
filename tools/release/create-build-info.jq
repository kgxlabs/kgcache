{
  schema_version: 1,
  version: $version,
  source: {revision: $revision, dirty: $dirty},
  platform: $platform,
  target: $target,
  cpu: $cpu,
  optimize: $optimize,
  persistence_test_controls: false,
  compiler: {version: $compiler, archive_sha256: $archive_sha},
  runtime_base: $runtime,
  binary: {path: "bin/kgcache", sha256: $sha}
}
