# OpenBSD Wi-Fi Menu

`wifi-menu` is an interactive client-mode Wi-Fi configurator for OpenBSD.
It discovers interfaces in the `wlan` interface group, scans with
`ifconfig interface scan`, shows the discovered networks, creates a
protected `hostname.if(5)` file and asks `dhcpleased(8)` to obtain the
IPv4 lease.

It does not configure a Host AP, restart a local resolver, randomize the
MAC address or fabricate a default route. `dhcpleased` may install a
default route supplied by the DHCP server as part of the lease. Access
point operation, forwarding, a DHCP service and firewall policy are out
of scope.

## Requirements

- A current OpenBSD system with `ifconfig(8)`, `dhcpleased(8)` and
  `dhcpleasectl(8)` from the base system.
- Root privileges; the program exits before changing anything when it is
  not root.
- Perl from the base system. Password echo is controlled through its core
  `POSIX::Termios` interface, so no additional Perl module is required.
- An interactive terminal on standard input. Passphrase entry fails when
  standard input is a pipe or is otherwise not a terminal.

## Installation and use

```sh
$ doas make install
$ doas wifi-menu
```

`make` and `make all` are aliases for `make install`. The program:

1. obtains the members of the `wlan` interface group with
   `ifconfig wlan`;
2. brings the selected interface up and scans for access points;
3. clears the interface's existing wireless settings, then invokes
   `ifconfig` with an argument list, so an SSID or passphrase is never
   interpreted by a shell;
4. enables `inet autoconf`, installs the generated file as
   `/etc/hostname.interface` and waits up to ten seconds through
   `dhcpleasectl`; a connection is reported as successful only when the
   command output contains the `Bound` state;
5. after a successful connection, writes a mode-0600 saved file below
   `/etc/wifi_saved`.

An existing interface file is copied to
`/etc/hostname.interface.wifi-menu.old` immediately before replacement.
The backup is one generation only and is overwritten on the next run.
Saved entries and that backup contain the WPA passphrase in clear text
because that is the format consumed by `netstart(8)`. The directory is
mode 0700 and credential files are mode 0600; backups and access to them
must be treated as secrets. The passphrase is also visible in the
`ifconfig` argument vector while the join command runs.

Printable SSIDs, SSIDs with spaces and the hexadecimal representation
emitted by `ifconfig` are supported. `ifconfig` prints printable SSIDs
bare, wraps values containing spaces in double quotes without escaping
embedded quotes, and prints other bytes as `0x`-prefixed hexadecimal.
Hexadecimal values are passed back to `ifconfig` unchanged, which decodes
them. An SSID containing an embedded double quote is parsed from the
outermost quotes. An empty or hidden SSID (`nwid ""`) and a literal
two-quote SSID are both printed as `""`; they are skipped because the
output cannot distinguish them. Results are deduped by SSID, so multiple
BSSIDs for one SSID are shown once.

Values written to `hostname.if(5)` are enclosed in single quotes with
embedded single quotes encoded as `'\''`. Every backslash is doubled
because `netstart(8)` reads the file without `read -r` before evaluating
it. Line breaks, NUL bytes, tabs and repeated spaces are rejected because
that read and word-splitting pipeline cannot preserve them. WPA
passphrases must contain 8-63 bytes; a raw PSK may be written as `0x`
followed by 64 hexadecimal digits. An empty passphrase means an open
network.

A selected saved file is trusted only for its first `join` line. The
program re-renders the hostname file from the parsed SSID and passphrase,
so extra lines in a saved file are not installed. The parser accepts the
current single-quoted format and the older bare and double-quoted formats;
legacy values containing backslashes are ambiguous and may be
misinterpreted.

On OpenBSD, the Perl orchestration process locks an `unveil(2)` view after
choosing the interface. The launcher deliberately does not call
`pledge(2)` and does not set exec promises. The `unveil(2)` view
constrains pathname operations in the Perl process itself, but there is no
syscall ceiling. Because no exec promises are set, `execve(2)` clears the
view for each executed utility, so every child starts with a fresh
filesystem view and can apply its own security policy. Failure to install
or lock the view is fatal, and a missing `ifconfig` or `dhcpleasectl`
aborts before scanning.

## Removal

```sh
$ doas make uninstall
```

This removes only `/usr/local/bin/wifi-menu` at the default install
prefix; saved credentials are deliberately preserved. To remove the
saved directory, the `.wifi-menu.old` backups and leftover staging files:

```sh
$ doas make purge
```

This also removes the `.wifi-menu.old` recovery backup; copy it
elsewhere first if you may need it. Active `/etc/hostname.*` files are
preserved because they are the running configuration and may have been
created by the administrator. They can
still contain a `wpakey`; inspect and remove them manually if credential
removal must be complete. `make purge` refuses an empty, `.`, `..` or `/`
value of `WIFI_DIR`. The `WIFI_DIR` Makefile variable affects only
`install` and `purge`; the script itself always uses `/etc/wifi_saved`.

## Checks

```sh
$ make test
$ make check-agent-sync
```

`make test` runs `perl -c wifi-menu.pl` only. It is a syntax check, not a
functional test. `make check-agent-sync` checks the Git change set for a
substantive update to agent or skill instructions, validates instruction
structure and skill frontmatter, and checks local Markdown links. Pull
requests run this check in GitHub Actions. The checker enforces structural
conditions; reviewers must still confirm that the instruction update is
relevant and accurate. `make help` lists the targets, and `make -n install`
or `make -n purge` shows what a target would do without running it.

## Known limitations

- The backup is overwritten on every connection and there is no automatic
  rollback. A failed join or DHCP step may leave the live interface
  cleared and the new hostname file installed.
- Writes use `rename(2)` for an atomic namespace update, but there is no
  `fsync(2)`, so power loss can still lose or truncate a file.
- `SIGKILL` cannot be handled, and stopping the process with `SIGTSTP`
  can leave terminal echo disabled; use `stty sane` if that happens.
- `make purge` does not remove active `/etc/hostname.*` files.
- The scanner does not detect the security type of a network. Pressing
  Enter at the passphrase prompt configures an open join even for a WPA
  network.
- Interface discovery assumes names matching
  `[[:alpha:]]+[[:digit:]]+`.
- `make test` does not exercise OpenBSD, root-only paths, `ifconfig`,
  `dhcpleased` or wireless hardware.

## References

- [ifconfig(8)](https://man.openbsd.org/ifconfig.8)
- [hostname.if(5)](https://man.openbsd.org/hostname.if.5)
- [netstart(8)](https://man.openbsd.org/netstart.8)
- [dhcpleased(8)](https://man.openbsd.org/dhcpleased.8)
- [dhcpleasectl(8)](https://man.openbsd.org/dhcpleasectl.8)
- [unveil(2)](https://man.openbsd.org/unveil.2)
- [pledge(2)](https://man.openbsd.org/pledge.2)
- [OpenBSD::Unveil(3p)](https://man.openbsd.org/OpenBSD::Unveil)

## License

See [LICENSE](LICENSE).
