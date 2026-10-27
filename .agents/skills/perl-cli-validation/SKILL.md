---
name: perl-cli-validation
description: Review wifi-menu Perl prompt parsing, numeric selection, argument passing and fatal error handling without inventing tests.
---

# Perl CLI Validation

## Activation

Use this skill when a change touches `read_choice`, `choose_interface`,
`choose_network`, `choose_saved_or_new`, `die_tool`, `run`, `capture`,
prompt text, exit behavior or argument construction.

Use the domain skills for interface, hostname and secret semantics.

## Procedure

1. Read `wifi-menu.pl` and `README.md`. Confirm the current functions and
   prompts before editing.
2. Prompt parsing:
   - `read_choice` reads one line, trims leading and trailing whitespace
     and returns `''` at end of input;
   - an empty answer cancels or scans, according to the caller;
   - numeric choices must match `\A[1-9][0-9]*\z` and be within bounds;
   - reject zero, leading zeros, signs, decimals, trailing text and
     values greater than the list length.
3. External commands:
   - use list-form `system { $command[0] } @command` or
     `open my $fh, '-|', @command`;
   - never interpolate an SSID, passphrase or path into a single string
     passed to a shell;
   - check the exit status (`$?`) and report the failing operation;
   - `capture` returns both the close status and the full output; callers
     that need a specific state must inspect the output, as
     `apply_connection` does for `Bound`.
4. Failure behavior:
   - `die_tool` writes `[ERROR] ...` to standard error and exits 1;
   - check root before any filesystem or interface change;
   - a missing standard-input descriptor, non-terminal input or failed
     terminal attribute operation is fatal;
   - avoid printing untrusted SSIDs or saved labels directly; use
     `display_label` for terminal output.
5. Do not add interactive features, flags or test harnesses that the
   repository does not already have.

## Validations

- Static: `make test` runs `perl -c wifi-menu.pl` and checks syntax only.
  There is no functional test suite or lint target. GitHub Actions runs
  `make`-independent agent/skills synchronization checks on pull requests;
  those checks do not exercise Perl behavior or OpenBSD commands.
- Static: run `checkmake Makefile` when checkmake is installed. Keep recipes
  within its five-line target-body limit, preserving failure short-circuiting
  when joining commands.
- Static: review the regexes and bounds logic against the cases above;
  run `git diff --check` for whitespace.
- Real: interactive prompts and terminal echo require OpenBSD, root and a
  terminal. Do not run `wifi-menu`, `make install` or `make purge` in a
  documentation-only task.
- Linux can run the syntax check but cannot exercise `ifconfig`,
  `unveil` or the OpenBSD terminal behavior.

## Common problems

- Accepting `0`, `01`, `+1` or a number followed by text as a menu
  choice.
- Comparing a numeric string with `>` without validating its shape
  first.
- Using `system("ifconfig ... $ssid")` or a backtick command, which
  reintroduces shell interpretation.
- Checking `$!` instead of `$?` after a child process, or ignoring a
  `close` failure on a piped command.
- Treating `dhcpleasectl` exit 0 as proof of a lease.
- Printing a decoded SSID from a filename without escaping control bytes.
- Forgetting that an empty passphrase is a valid open-network choice,
  not an input error.
- Assuming a syntax check validates runtime behavior or OpenBSD
  permissions.

## References

- `README.md` for commands and limitations.
- `wifi-menu.pl`: `read_choice`, `choose_interface`, `choose_network`,
  `choose_saved_or_new`, `die_tool`, `run`, `capture`, `display_label`.
- `Makefile`: `test`, `help`, `install`, `uninstall`, `purge`, `clean`.
- Perl core documentation: `perlfunc` for `system`, `open` and `$?`;
  `POSIX` for `Termios`.
- Related skills: `openbsd-wifi-interface-discovery`,
  `wifi-secret-handling`.

## Maintenance & Continuous Learning

When this skill is used to modify the repository, review this skill after the implementation. Update it when the workflow, relevant project behavior, tools, configuration, paths, validation steps or assumptions have changed. Add reusable findings that would improve a future run, correct guidance that proved inaccurate, and keep examples and validation procedures current. Remove obsolete or conflicting instructions. Include only knowledge that applies to future use; do not add one-off details from the current execution. Review related skills and `AGENTS.md` for consistency, then run `make check-agent-knowledge` and the applicable checks documented above. Report the synchronization result and any check that could not be run.
