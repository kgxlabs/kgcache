# Build checks

Run these checks from a macOS or Linux development host with Bash, Zig 0.16.0,
`file`, and ripgrep:

```sh
bash tests/build/run.sh
zig build test
zig build test-integration
```

The build check verifies native output, cross-compilation to a different Linux
target, and early rejection of foreign `run`, `test`, and `test-integration`
requests. Set `ZIG=/absolute/path/to/zig` to select a compiler.

Ordinary builds use the native target. Select a target for a build without
executing it:

```sh
zig build -Dtarget=x86_64-linux-gnu.2.36 -Doptimize=ReleaseSafe --prefix zig-out/linux-amd64
```

Executable run steps require a target that the build host can run natively.
Run process tests on the selected platform. Cross-compilation by itself does not
establish runtime compatibility.
