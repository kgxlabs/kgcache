# Shell checks

Use Bash 3.2 or later on macOS or Linux, with Git, Docker, and GNU `timeout`.
Run from the repository root:

```sh
make check-shell
make fmt-shell
```

`check-shell` runs ShellCheck 0.11.0 and checks formatting with shfmt 3.12.0.
`fmt-shell` applies the formatter. The tool images are pinned by version and
digest in `check.sh`. Docker selects the image for its engine architecture.
No tools are installed on the host.

The checks include tracked scripts and new scripts that Git does not ignore.
They skip ignored dependencies and generated output. File names are passed as
separate arguments, including names that contain spaces. Checks mount the
repository read-only; formatting mounts it writable and uses the caller's UID
and GID. Each Docker phase has a deadline and owned containers are removed on
exit.

`.editorconfig` defines four-space indentation and case indentation.
`.shellcheckrc` enables source following and the optional checks for masked
command failures and suppressed `errexit`. Exceptions must be local and explain
why the flagged behavior is intentional.

Follow the [Google Shell Style Guide's formatting rules](https://google.github.io/styleguide/shellguide.html#s5-formatting),
with the repository's four-space indentation:

- Put one blank line between logical steps, such as setup, execution, and checks.
  Keep related assignments and their checks together.
- Separate local declarations from the function's commands with one blank line.
- Put `if` bodies and closing `fi` statements on separate lines. Keep short case
  alternatives on one line only when they are easy to read.
- Aim for 80 columns. Wrap long commands at argument boundaries. Use one option
  and its value per line for long option lists. Keep literal strings, URLs, and
  digests intact when splitting them would make them harder to read or change
  their value.
- Split long pipelines at pipe boundaries. Use the repository's shfmt layout,
  with `|`, `&&`, and `||` at the end of the continued line.

Add logical blank lines and command wrapping when writing or reviewing scripts.
shfmt preserves that grouping. It does not choose logical groups or wrap commands
to a line-length limit. Run `make fmt-shell`, then `make check-shell`.
