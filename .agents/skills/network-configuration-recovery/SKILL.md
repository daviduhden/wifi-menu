---
name: network-configuration-recovery
description: Diagnose and recover wifi-menu connection failures, including hostname backups, DHCP waits, partial state and saved-network selection.
---

# Network Configuration Recovery

## Activation

Use this skill when a change touches `clear_wireless_settings`,
`apply_connection`, `create_connection`, `saved_connections` or
`choose_saved_or_new`, or when a user reports a failed join, a DHCP
timeout, a lost network after reboot or a bad saved entry.

Quoting belongs to `hostname-if-safe-generation`; passphrase policy
belongs to `wifi-secret-handling`.

## Procedure

1. Read `wifi-menu.pl`, `README.md` and the current Makefile targets.
2. Trace the actual order in `apply_connection`:
   - clear BSSID, channel, `nwid`, `nwkey`, WPA, `wpakey` and the join
     list;
   - `ifconfig <if> join <ssid> [wpakey <pass>]`;
   - `ifconfig <if> inet autoconf`;
   - render and install `/etc/hostname.<if>`;
   - run `dhcpleasectl -w 10 <if>`.
3. Treat DHCP success as output containing `Bound`. `dhcpleasectl`
   returns 0 after a timeout, so never rely on its exit status alone.
4. Accept that there is no automatic rollback:
   - the live wireless settings are cleared before the new join;
   - the hostname file is installed before the DHCP wait;
   - a failed join or DHCP leaves a partially changed host;
   - a new saved entry is written only after `apply_connection` succeeds,
     so an existing saved entry is not overwritten by a failed join.
5. Recover from the one-generation backup:
   - inspect `/etc/hostname.<if>.wifi-menu.old` before using it; it may be
     the previous wifi-menu file, not the administrator's original;
   - restore it as root with mode 0600;
   - bring the interface down and up, then re-run `dhcpleasectl`;
   - remove the backup after recovery because it contains a passphrase.
6. Clean up crash residue manually if needed:
   - `/etc/.hostname.<if>.wifi-menu.<pid>`;
   - `/etc/.hostname.<if>.wifi-menu-backup.<pid>`;
   - a stale `/etc/hostname.<if>.wifi-menu.old`.
7. When selecting a saved network, re-render the hostname file from the
   parsed first line. Do not restore the saved file verbatim.
8. Note these boundaries:
   - `make purge` removes saved files and backups but leaves active
     `/etc/hostname.*` files;
   - `clear_wireless_settings` does not clear existing IPv4 or IPv6
     addresses; a previous static address can remain alongside
     `inet autoconf`;
   - renaming an interface orphans saved entries named for the old
     interface;
   - there is no `fsync`, so a crash can still lose a just-renamed file.

## Validations

- Static: trace every failure path and confirm whether it leaves the
  interface cleared, the hostname file replaced, the backup replaced or
  the saved entry written. `make test` is syntax only and does not cover
  this.
- Static: `make -n purge` and `make -n install` show the commands without
  running them; `git diff --check` checks whitespace.
- Real: requires OpenBSD, root and wireless hardware. Test a bad
  passphrase, a DHCP timeout and a restore from `.wifi-menu.old` on a
  disposable interface. Do not perform these checks during
  documentation-only work.
- Never run `make purge` or `wifi-menu` merely to observe recovery.

## Common problems

- Assuming `dhcpleasectl` exit status reports a lease; it does not.
- Assuming a failed join leaves the previous association intact; the
  settings were already cleared.
- Assuming `.wifi-menu.old` is the pre-wifi-menu original; the second run
  overwrites it with the first run's output.
- Forgetting that the new hostname file is installed before DHCP, so a
  DHCP failure is not a no-op.
- Leaving staging files behind after `SIGKILL` or power loss.
- Expecting `make purge` to remove the active hostname file.
- Expecting a saved file's extra lines to be honored; only the first
  `join` line is parsed and the hostname file is re-rendered.
- Treating a 10-second timeout as success because the command exited 0.

## References

- `README.md` for the documented flow and limitations.
- `wifi-menu.pl`: `clear_wireless_settings`, `apply_connection`,
  `create_connection`, `saved_connections`, `choose_saved_or_new`,
  `install_hostname_file`.
- [dhcpleased(8)](https://man.openbsd.org/dhcpleased.8)
- [dhcpleasectl(8)](https://man.openbsd.org/dhcpleasectl.8)
- OpenBSD `dhcpleasectl.c`:
  <https://github.com/openbsd/src/blob/master/usr.sbin/dhcpleasectl/dhcpleasectl.c>
- [hostname.if(5)](https://man.openbsd.org/hostname.if.5)
- Related skills: `hostname-if-safe-generation`,
  `wifi-secret-handling`.
