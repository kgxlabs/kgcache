{
  schema_version: 2,
  version: $version,
  development_version: $development_version,
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
