# Check build targets and versions

[Contributor guide](../../docs/contribute/testing.md) / Build checks

Run this suite after changing `build.zig`, version input, or target handling.
Use macOS or Linux with Bash 3.2 or newer, Zig 0.16.0, and `file`.

## Run

From the repository root:

```sh
bash tests/build/run.sh
zig build test
zig build test-integration
```

Set `ZIG=/absolute/path/to/zig` to select a compiler. The script checks native
output, cross-compilation, SemVer fixtures, versioned server/test-tool builds,
and early rejection of foreign `run`, `test`, and `test-integration` steps.

## Build without execution

```sh
zig build -Dtarget=x86_64-linux-gnu.2.36 -Doptimize=ReleaseSafe \
  --prefix zig-out/linux-amd64
```

The normal build target is native. Execution steps require a target that the
build host can run natively. Test runtime behavior on that platform separately;
a successful cross-compile proves only that the artifact builds.

See [build versions](../../docs/contribute/building.md) for SemVer rules and
[release checks](../release/README.md) for Linux artifact qualification.
