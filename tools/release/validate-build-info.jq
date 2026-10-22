include "semver";

def require(condition; message):
  if condition then . else error(message) end;

def checksum:
  type == "string" and test("^[0-9a-f]{64}$");

require(type == "object"; "build record must be an object")
| require(.schema_version == 2; "schema_version must be 2")
| require(.version | semver; "version must be SemVer 2.0.0")
| require(.development_version | semver; "development_version must be SemVer 2.0.0")
| require(.source | type == "object"; "source must be an object")
| require(.source.revision | type == "string" and test("^[0-9a-f]{40}$"); "source.revision must be a Git commit")
| require(.source.dirty | type == "boolean"; "source.dirty must be a boolean")
| require(.target == $target; "platform and target do not agree")
| require(.cpu == $cpu; "cpu must be " + $cpu)
| require(.optimize == $optimize; "optimize must be " + $optimize)
| require(.persistence_test_controls == false; "persistence_test_controls must be false")
| require(.compiler | type == "object"; "compiler must be an object")
| require(.compiler.version == $compiler; "compiler.version must be " + $compiler)
| require(.compiler.archive_sha256 | checksum; "compiler.archive_sha256 must be a SHA-256 checksum")
| require(.runtime_base == $runtime; "runtime_base does not match the selected runtime")
| require(.binary | type == "object"; "binary must be an object")
| require(.binary.path == "bin/kgcache"; "binary.path must be bin/kgcache")
| require(.binary.sha256 | checksum; "binary.sha256 must be a SHA-256 checksum")
