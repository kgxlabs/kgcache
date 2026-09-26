# Test organization

This is the repository convention for placing Zig tests. Use it when adding tests and when moving tests for [issue #73](https://github.com/kgxlabs/kgcache/issues/73).

## Test entry point

Run the project suite with `zig build test`. `build.zig` uses `src/tests.zig` as its test root. That file imports the source and test files whose tests must run. When adding a separate test file, add it to `src/tests.zig`. Keep a source file imported there while it still has inline tests. If a new test file imports a source file with no inline tests, a second direct import of that source file is unnecessary.

`zig test src/example.zig` only covers tests reached from that file. It does not replace the project suite when tests live in a separate file.

## Where tests go

| Situation | Place tests |
| --- | --- |
| A small, focused test close to a function or type | In the source file |
| A test that needs a private declaration in the source file | In the source file |
| A group of tests or fixtures that makes the source hard to read | In a nearby file named `*_tests.zig` |
| A test of behavior across several components | Near the component boundary it exercises, in a separate test file when substantial |

For example, tests for `src/store/mem_store.zig` can live in `src/store/mem_store_tests.zig`. The test file imports the source file. Register the test file in `src/tests.zig` so `zig build test` discovers it.

Choose the location test by test. A module can have both inline and separate tests. There is no line count or test count that requires a move.

## Boundaries and fixtures

- Test behavior through public functions, interfaces, replies, state changes, and errors where practical. Do not make a production declaration `pub` only to move its test to another file.
- Keep test-only imports and fixtures in the test file when all their callers are there. If an inline test still uses a fixture, keep it accessible to that test.
- Put a helper in `src/tests/helpers.zig` only when multiple areas use the same behavior. Keep helpers that belong to one component beside that component's tests.
- Preserve test names, assertions, setup, and cleanup when moving existing tests. Do not combine a test move with a behavior change unless the change is independently needed.
- Split production code when it has a clear responsibility boundary and a useful interface. Test volume alone is not a reason to split it.

## Checking a test move

Before a larger move, record the current test result and the tests being moved. After each small extraction, run `zig build test`, `zig build`, and `git diff --check`. Confirm that `src/tests.zig` still discovers every moved and inline test. Explain any intentional change in test coverage.
