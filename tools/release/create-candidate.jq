{
  schema_version: 1,
  kind: "release-candidate",
  mode: $proposal[0].mode,
  publishable: false,
  repository: $proposal[0].repository,
  source_sha: $proposal[0].source_sha,
  version: $proposal[0].version,
  development_version: $proposal[0].development_version,
  platform: "linux/amd64",
  proposal: $proposal[0],
  build: $build[0],
  image: {
    id: $image,
    version_tag: $proposal[0].image.version_tag,
    source_version_key: $proposal[0].image.source_version_key
  },
  archive: {
    path: "kgcache-linux-amd64.docker.tar.gz",
    format: "docker-archive+gzip",
    sha256: $archive_sha,
    bytes: $archive_bytes
  },
  tooling: {revision: $tooling_revision, dirty: $tooling_dirty, entrypoint_sha256: $tooling_sha},
  run: {id: $run_id, attempt: $attempt, workflow_ref: $workflow_ref, workflow_sha: $workflow_sha},
  qualification: {
    host: $host, engine: $engine,
    native_source: ($host == "linux/amd64"), native_image: ($engine == "linux/amd64"),
    qualified_amd64: ($host == "linux/amd64" and $engine == "linux/amd64")
  },
  checks: $checks,
  evidence: $evidence,
  client_coverage: {
    source_profiles: [$matrix[0].profiles[] | select(.ci == "required") | .id],
    source_binary: (if $host == "linux/amd64" then "image" else "host-build" end),
    image_profiles: $service[0].compose.clients
  }
}
