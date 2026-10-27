---
name: hostname-if-safe-generation
description: Generate, parse and install OpenBSD hostname.if files safely, including netstart quoting, canonical content and atomic replacement.
---

# Safe `hostname.if` Generation

## Activation

Use this skill when a change touches `hostname_arg`, `unquote_hn_field`,
`config_content`, `config_path`, `write_config`, `parse_saved_config` or
`install_hostname_file`, or when a saved SSID or passphrase does not
survive a reboot.

Secret policy and password entry belong to `wifi-secret-handling`.
Backup lifecycle and rollback belong to
`network-configuration-recovery`.

## Procedure

1. Read `wifi-menu.pl`, `README.md` and
   `references/netstart-quoting.md` in this skill directory.
2. Validate every value before encoding it:
   - reject CR, LF and NUL;
   - reject tabs and repeated spaces;
   - allow a single space and a single quote;
   - allow a raw PSK in the form `0x` plus 64 hexadecimal digits.
3. Render canonical content with `config_content`:
   `join <quoted-ssid>` plus optional ` wpakey <quoted-passphrase>`,
   followed by `inet autoconf` and a final newline.
4. Encode each field with `hostname_arg`:
   - build a POSIX single-quoted word;
   - encode an embedded `'` as `'\''`;
   - double every backslash so ksh `read` without `-r` leaves the word
     intact for `eval`.
5. Parse an existing saved file with `parse_saved_config`:
   - read and validate only the first line;
   - accept the current doubled-backslash format and the older bare or
     double-quoted formats;
   - reject malformed or empty SSIDs and values that cannot round-trip;
   - never install the saved file verbatim. Pass the parsed values to
     `config_content` and install that result.
6. Install atomically:
   - `write_config` uses `File::Temp` inside `/etc/wifi_saved`, chmods
     0600, then `rename`s.
   - `install_hostname_file` first stages a 0600 backup of the existing
     `/etc/hostname.<if>` as `/etc/hostname.<if>.wifi-menu.old`.
   - It then creates the new file with `sysopen` and
     `O_WRONLY|O_CREAT|O_EXCL`, mode 0600, and `rename`s it into place.
   - Rename gives an atomic namespace update, not crash durability. Do
     not claim `fsync` guarantees that are not implemented.
7. Keep `umask 077`, the 0700 directory and every 0600 file. A backup is
   a secret and is overwritten on the next connection.

## Validations

- Static: `make test` is syntax only; `git diff --check` catches
  whitespace. Inspect the generated encoding by hand for the examples in
  `references/netstart-quoting.md`.
- Static: confirm that a saved file with a valid first line and an extra
  `!command` line is not installed verbatim.
- Real: an OpenBSD system with root and a disposable SSID can verify that
  the value survives `netstart`. Do not run `wifi-menu`, `make install`
  or `netstart` in a documentation-only task.
- Never use a real passphrase in a fixture or log.

## Common problems

- Using only `'\''` without doubling the backslash produces invalid shell
  quoting after `netstart` reads the file.
- Copying a saved file into `/etc/hostname.<if>` lets extra lines run at
  boot.
- Unconditionally stripping quotes from a scan result corrupts a bare SSID
  that contains quote characters.
- Parsing `$1` and `$2` after calling a helper that uses regexes clobbers
  the captures; copy both captures before decoding either field.
- A backup is one generation only; the second run overwrites the
  administrator's original file.
- `make purge` removes saved files and backups but leaves the active
  `/etc/hostname.*` file, which can still contain a `wpakey`.
- No `fsync` is performed, so a crash can lose the new file even though
  the rename was atomic.

## References

- `README.md` for the user-visible format and limitations.
- `wifi-menu.pl`: `validate_saved_value`, `hostname_arg`,
  `unquote_hn_field`, `config_content`, `write_config`,
  `parse_saved_config`, `install_hostname_file`.
- `references/netstart-quoting.md` in this skill.
- [hostname.if(5)](https://man.openbsd.org/hostname.if.5)
- [netstart(8)](https://man.openbsd.org/netstart.8)
- OpenBSD `netstart` source:
  <https://github.com/openbsd/src/blob/master/etc/netstart>
- Related skills: `wifi-secret-handling`,
  `network-configuration-recovery`.

## Maintenance & Continuous Learning

When this skill is used to modify the repository, review this skill after the implementation. Update it when the workflow, relevant project behavior, tools, configuration, paths, validation steps or assumptions have changed. Add reusable findings that would improve a future run, correct guidance that proved inaccurate, and keep examples and validation procedures current. Remove obsolete or conflicting instructions. Include only knowledge that applies to future use; do not add one-off details from the current execution. Review related skills and `AGENTS.md` for consistency, then run `make check-agent-sync` and the applicable checks documented above. Report the synchronization result and any check that could not be run.
