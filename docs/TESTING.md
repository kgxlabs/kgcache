# Test organization

This is the repository convention for placing Zig tests. Use it when adding or moving tests.

## Test entry point

Run the project suite with `zig build test`. `build.zig` uses `src/tests.zig` as its test root. That file imports the source and test files whose tests must run. Add each new test file to `src/tests.zig` once. Keep a source file imported there when it has inline tests. A separate test file imports the source it covers, so the test root does not need a second direct source import when all its tests have moved.

`zig test src/example.zig` only covers tests reached from that file. It does not replace the project suite when tests live in a separate file.

## Where tests go

| Situation | Place tests |
| --- | --- |
| A small, focused test close to a function or type | In the source file |
| A test that needs a private declaration in the source file | In the source file |
| A group of tests or fixtures that makes the source hard to read | In a nearby file named `*_tests.zig` |
| A test of behavior across several components | Near the component boundary it exercises, in a separate test file when substantial |

For example, `src/store/mem_store_tests.zig` holds the `MemoryStore` tests and imports `src/store/mem_store.zig`. `src/persistence/aof.zig` has both inline tests that need private declarations and public journal tests in `src/persistence/aof_tests.zig`. Both AOF files are imported by `src/tests.zig`. The private scheduler tests remain in `src/cron.zig`.

Choose the location test by test. A module can have both inline and separate tests. There is no line count or test count that requires a move.

## Boundaries and fixtures

- Test behavior through public functions, interfaces, replies, state changes, and errors where practical. Do not make a production declaration `pub` only to move its test to another file.
- Keep test-only imports and fixtures in the test file when all their callers are there. If an inline test still uses a fixture, keep it accessible to that test.
- Keep a fixture beside its tests when one component owns it. If inline and separate tests for that component share a fixture, use a nearby test helper file, as `src/persistence/aof_test_helpers.zig` does. Use `src/tests/helpers.zig` for fixtures shared across components, as the command and connection tests do.
- Preserve test names, assertions, setup, and cleanup when moving existing tests. Do not combine a test move with a behavior change unless the change is independently needed.
- Split production code when it has a clear responsibility boundary and a useful interface. Test volume alone is not a reason to split it.

## Checking a test move

Before a larger move, record the current test result and the tests being moved. After each small extraction, run `zig build test`, `zig build`, and `git diff --check`. Check Zig formatting on edited files. Confirm that `src/tests.zig` still discovers every moved and inline test. Explain any intentional change in test coverage.
