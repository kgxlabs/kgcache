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
