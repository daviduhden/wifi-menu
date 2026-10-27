---
name: wifi-secret-handling
description: Protect WPA passphrases and saved credentials in wifi-menu, including terminal input, file modes, backups, logging and purge behavior.
---

# Wi-Fi Secret Handling

## Activation

Use this skill when a change touches `read_password`, any `chmod`,
`umask`, saved-file mode, backup handling, password validation, logging of
SSIDs or passphrases, or credential removal.

Use `hostname-if-safe-generation` for the encoding itself and
`network-configuration-recovery` for restoring a backup.

## Procedure

1. Require root before touching `/etc`.
2. Read the passphrase from standard input only when it is a terminal:
   - `POSIX::Termios` obtains the current terminal attributes;
   - clear `ECHO` with `TCSANOW`;
   - read the line;
   - restore the original attributes in an `eval` even after `INT`,
     `TERM`, `HUP` or `QUIT`;
   - print a newline after the hidden input.
3. Validate the value after `chomp`:
   - empty means an open network and produces no `wpakey`;
   - otherwise accept 8-63 bytes or a raw PSK written as `0x` plus 64
     hexadecimal digits;
   - reject CR, LF, NUL, tabs and repeated spaces because the
     `hostname.if` pipeline cannot preserve them.
4. Protect the data at rest:
   - `/etc/wifi_saved` is mode 0700;
   - saved entries, `/etc/hostname.<if>` and
     `/etc/hostname.<if>.wifi-menu.old` are mode 0600;
   - `umask 077` is set before creating files;
   - the hostname staging file is opened with
     `O_WRONLY|O_CREAT|O_EXCL` and mode 0600.
5. Avoid leaking the value:
   - never log or print a passphrase;
   - use `display_label` for SSIDs before terminal output;
   - remember that the passphrase is visible in the `ifconfig` argument
     vector during the join, because `ifconfig` has no separate secret
     input path.
6. Treat backups as secrets. The `.wifi-menu.old` file is one generation,
   contains the previous passphrase and is overwritten on the next run.
7. Understand purge scope:
   - `make uninstall` preserves credentials;
   - `make purge` removes `/etc/wifi_saved`, `.wifi-menu.old` backups and
     staging files;
   - active `/etc/hostname.*` files are deliberately preserved and may
     still contain `wpakey`. Inspect and remove them manually if complete
     removal is required.
8. Never add a mode that makes a credential world-readable, even briefly.
   Do not rely on a later `chmod` to hide a file created with the default
   umask.

## Validations

- Static: inspect every `chmod`, `sysopen`, `tempfile` and `umask` call.
  `make test` is syntax only and does not verify modes.
- Static: `make -n purge` shows the destructive commands without running
  them. Do not run `make purge` on a real host as a test.
- Real: on OpenBSD, verify `stat -f '%Sp %N'` on the directory, one saved
  file and one backup; verify that `ps` shows the passphrase during a
  join. Use a disposable passphrase.
- Never use a real credential in a fixture, log, commit or transcript.
- Runtime checks require OpenBSD, root and a terminal; Linux cannot
  verify `POSIX::Termios` echo behavior or the real file modes.

## Common problems

- `SIGKILL` cannot be caught, and `SIGTSTP` is not handled, so a stopped
  process can leave echo disabled. `stty sane` restores the terminal.
- Restoring terminal attributes only on the normal path leaves echo off
  after a signal.
- A passphrase in `ifconfig` argv is visible to local users for the
  duration of the call.
- `make purge` is not a complete secret-removal operation while an active
  `hostname.if` contains `wpakey`.
- A saved label decoded from a filename can contain control bytes;
  escape it before printing.
- Rejecting tabs and repeated spaces is intentional: accepting them would
  silently change the value after reboot.
- A 64-character WPA passphrase without the `0x` prefix is not a raw PSK;
  `ifconfig` treats it as an over-long passphrase.

## References

- `README.md` for user-visible secret handling and limitations.
- `wifi-menu.pl`: `read_password`, `validate_saved_value`,
  `display_label`, `config_content`, `write_config`,
  `install_hostname_file`, `main`.
- [ifconfig(8)](https://man.openbsd.org/ifconfig.8), especially `join`
  and `wpakey`.
- [hostname.if(5)](https://man.openbsd.org/hostname.if.5)
- Related skills: `hostname-if-safe-generation`,
  `network-configuration-recovery`.

## Maintenance & Continuous Learning

When this skill is used to modify the repository, review this skill after the implementation. Update it when the workflow, relevant project behavior, tools, configuration, paths, validation steps or assumptions have changed. Add reusable findings that would improve a future run, correct guidance that proved inaccurate, and keep examples and validation procedures current. Remove obsolete or conflicting instructions. Include only knowledge that applies to future use; do not add one-off details from the current execution. Review related skills and `AGENTS.md` for consistency, then run `make check-agent-knowledge` and the applicable checks documented above. Report the synchronization result and any check that could not be run.
