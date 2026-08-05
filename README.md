# OpenBSD Wi-Fi Menu

`wifi-menu` is an interactive client-mode Wi-Fi configurator for OpenBSD. It discovers interfaces in the `wlan` interface group, shows the result of `ifconfig interface scan`, creates a protected `hostname.if(5)` file and asks `dhcpleased(8)` to obtain the IPv4 lease.

It does not configure a Host AP, restart a local resolver, invent a default route or randomize the MAC address. Those operations require separate policy and, in the case of an access point, address assignment, forwarding, DHCP and firewall configuration.

## Requirements

- A current OpenBSD system with `ifconfig(8)`, `dhcpleased(8)` and `dhcpleasectl(8)` from the base system.
- Root privileges; the program exits before changing anything when it is not root.
- Perl from the base system. Password echo is controlled through its core `POSIX::Termios` interface, so no additional Perl module is required.

## Installation and use

```sh
$ doas make install
$ doas wifi-menu
```

The program:

1. obtains the members of the `wlan` interface group with `ifconfig wlan`;
2. brings the selected interface up and scans for access points;
3. invokes `ifconfig` with an argument list, so an SSID or passphrase is never interpreted by a shell;
4. writes a mode-0600 saved file below `/etc/wifi_saved` and atomically installs it as `/etc/hostname.interface`;
5. enables `inet autoconf`, which is the flag monitored by `dhcpleased`, then waits up to ten seconds through `dhcpleasectl`.

An existing interface file is copied to `/etc/hostname.interface.wifi-menu.old` immediately before replacement. Saved entries and that backup contain the WPA passphrase in clear text because that is the format consumed by `netstart(8)`. The directory is mode 0700 and credential files are mode 0600; backups and access to them must be treated as secrets.

Printable SSIDs, SSIDs with spaces and the hexadecimal representation emitted by `ifconfig` are supported. For an unambiguous `hostname.if` file, line breaks, double quotes, backslashes and `#` are rejected in saved SSIDs/passphrases. WPA passphrases must contain 8–63 characters.

On OpenBSD, the Perl orchestration process locks an `unveil(2)` view and applies `pledge(2)` after choosing the interface. The Perl binding does not set `execpromises`, so each executed base-system utility starts with its own pledge state while retaining the narrowed unveil view; `ifconfig` and `dhcpleasectl` can then apply their native security policy. Failure to install either launcher restriction is fatal.

## Removal

```sh
$ doas make uninstall
```

This removes only `/usr/local/bin/wifi-menu`; saved credentials are deliberately preserved. To remove them explicitly:

```sh
$ doas make purge
```

## References

- [ifconfig(8)](https://man.openbsd.org/ifconfig.8)
- [hostname.if(5)](https://man.openbsd.org/hostname.if.5)
- [dhcpleased(8)](https://man.openbsd.org/dhcpleased.8)
- [dhcpleasectl(8)](https://man.openbsd.org/dhcpleasectl.8)
- [OpenBSD::Pledge(3p)](https://man.openbsd.org/OpenBSD::Pledge)
- [OpenBSD::Unveil(3p)](https://man.openbsd.org/OpenBSD::Unveil)

## License

See [LICENSE](LICENSE).
