# Check and format shell scripts

[Contributor guide](../../docs/contribute/testing.md) / Shell tooling

Use the same ShellCheck and shfmt checks locally and in CI. The scripts run
pinned tool images through Docker, without installing host copies.

## Run

Use macOS or Linux with Bash 3.2 or newer, Git, Docker, and GNU `timeout`.
From the repository root:

```sh
make check-shell
```

Apply formatting, then check again:

```sh
make fmt-shell
make check-shell
```

[check.sh](check.sh) pins ShellCheck 0.11.0 and shfmt 3.12.0 by version and
digest. Docker selects its engine architecture. Each phase has a deadline and
removes its owned containers on exit.

The file inventory includes tracked scripts and new, non-ignored scripts.
Deleted files, ignored dependencies, and generated output are excluded. Names
are passed as separate arguments, including paths with spaces. Checks mount
the repository read-only. Formatting mounts it writable as the caller's UID/GID.

## Write code the tools can check

[.editorconfig](../../.editorconfig) defines four-space and case indentation.
[.shellcheckrc](../../.shellcheckrc) follows sourced files and enables checks
for masked failures and suppressed `errexit`. Keep an exception local and
explain why the flagged behavior is needed.

Follow the [Google shell formatting guide](https://google.github.io/styleguide/shellguide.html#s5-formatting)
with this repository's indentation:

- Separate setup, execution, and checking with logical blank lines.
- Keep related assignments and assertions together. Leave one blank line
  between local declarations and the function's commands.
- Put an `if` body and its `fi` on separate lines. Keep short case alternatives
  on one line only when that is easy to read.
- Aim for 80 columns. Break long commands at argument boundaries, keeping an
  option beside its value. Do not split a literal, URL, or digest if that changes
  its value or makes it harder to read.
- Follow shfmt's pipeline layout, with `|`, `&&`, or `||` at the continued
  line's end.

shfmt preserves logical grouping. It does not choose the groups or enforce a
line-length limit, so review both after applying the formatter.
