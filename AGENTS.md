# Agent Instructions

## Project

`wifi-menu` is an OpenBSD-only, root-run, interactive client-mode Wi-Fi
configurator. It is a single Perl script (`wifi-menu.pl`) installed by a
small Makefile. There is no CPAN dependency, no test suite, no CI and no
linter configuration. The license is ISC; see `LICENSE`.

The program never configures a Host AP, forwarding, a DHCP service, a
resolver or MAC randomization. It may cause `dhcpleased` to install a
lease-provided default route.

## Architecture

Main flow:

1. `main` checks root, sets `umask 077`, creates or protects
   `/etc/wifi_saved`, then selects an interface.
2. `select_interface` parses `ifconfig wlan`, asks the user to choose when
   needed and brings the interface up.
3. `setup_sandbox` locks an `unveil(2)` view after the interface is known.
4. `choose_saved_or_new` offers saved files for the selected interface or
   scans with `ifconfig <if> scan`.
5. `apply_connection` clears wireless settings, runs
   `ifconfig <if> join ... [wpakey ...]`, enables `inet autoconf`,
   installs a generated hostname file and waits with
   `dhcpleasectl -w 10 <if>`.
6. A new connection is saved only after that succeeds; selecting an
   existing saved network re-renders the hostname file from parsed
   values.

Key paths and data:

- `/etc/wifi_saved` is mode 0700; entries are mode 0600 and contain
  clear-text WPA secrets.
- `/etc/hostname.<if>` is mode 0600 and is the active boot configuration.
- `/etc/hostname.<if>.wifi-menu.old` is a one-generation backup, also
  mode 0600, and is also a secret.
- Saved filenames encode the SSID bytes as hexadecimal plus the interface
  name.

Function ownership is described in the skills below rather than repeated
here.

## Invariants

- Check root before creating, deleting or changing anything.
- Pass SSIDs and passphrases to `ifconfig` and `dhcpleasectl` as list-form
  argv. Never introduce a shell for those calls.
- Values written to `hostname.if(5)` use POSIX single-quote encoding;
  embedded `'` becomes `'\''`, and every backslash is doubled because
  `netstart(8)` reads the file without `read -r` before `eval`.
- Reject CR, LF, NUL, tabs and repeated spaces in values that must survive
  `netstart`. Do not weaken this to make an exotic value fit.
- Install canonical hostname content generated from parsed values. Never
  copy an arbitrary saved file verbatim into `/etc/hostname.<if>`.
- Keep `/etc/wifi_saved` at 0700 and all credential, backup and staging
  files at 0600.
- The Perl process deliberately does not call `pledge(2)` and does not set
  exec promises. `unveil(2)` constrains pathname operations in that
  process only; `execve(2)` clears the view for children, which then apply
  their own policy. Do not describe the children as durably confined.
- Treat a DHCP result as successful only when `dhcpleasectl` output
  contains `Bound`; its exit status is 0 even on timeout.

## Conventions

- Perl 5 core only; `use strict` and `use warnings`.
- Four-space indentation; two-space continuation indent; full-sentence
  comments above functions and subtle blocks; no POD.
- ASCII-only tracked files. Use plain hyphens, not typographic dashes.
- LF line endings, final newline, no trailing whitespace.
- Makefile recipes use tabs and `@`; path variables use `?=`; `.PHONY`
  stays last.
- Preserve the ISC copyright and license notices.
- Do not impose a historical 72-column limit. There is no enforced line
  length; current Perl lines stay under 80 columns.

## Commands

```sh
make test                 # perl -c wifi-menu.pl; syntax only
make help                 # list targets
make -n install           # dry run
make -n uninstall         # dry run
make -n purge             # dry run; purge is destructive
git status --short
git diff --check
git diff
```

`make`, `make all` and `make install` install to
`/usr/local/bin/wifi-menu` and create/protect `/etc/wifi_saved` when run
as root. `make uninstall` removes only the installed script.
`make purge` also removes `/etc/wifi_saved`, `.wifi-menu.old` backups and
staging files; it deliberately leaves active `/etc/hostname.*` files.
`WIFI_DIR` affects only the Makefile, not the hard-coded script path.
`make clean` removes only `*~` editor backups.

## Security and testing policy

- Do not run `wifi-menu`, `make install`, `make uninstall` or `make purge`
  while working on documentation. They change host network state and
  files under `/etc`.
- Static verification is available on any platform: read the code, check
  encodings and regexes, run `make test` for syntax only, and use
  `git diff --check`.
- Runtime verification requires OpenBSD, root and wireless hardware. It
  cannot be replaced by Linux tests, and `make test` does not exercise
  `ifconfig`, `dhcpleasectl`, `unveil` or permissions.
- Use dummy SSIDs and passphrases in examples. Never print, commit or log
  a real passphrase, backup or saved file.
- Do not invent a test framework, CI workflow or linter target. None
  exists in this repository.

## Preexisting changes and Git

Check `git status --short` before editing and preserve unrelated work.
Do not commit, push, rewrite history or change the host configuration as
part of documentation work. The repository is marked shallow even though
reachable history goes back to the root commit; do not attempt to repair
or rewrite it.

## Skills

Load only the skill that matches the change:

- [openbsd-wifi-interface-discovery](.agents/skills/openbsd-wifi-interface-discovery/SKILL.md)
- [hostname-if-safe-generation](.agents/skills/hostname-if-safe-generation/SKILL.md)
- [wifi-secret-handling](.agents/skills/wifi-secret-handling/SKILL.md)
- [network-configuration-recovery](.agents/skills/network-configuration-recovery/SKILL.md)
- [perl-cli-validation](.agents/skills/perl-cli-validation/SKILL.md)
