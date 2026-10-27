---
name: openbsd-wifi-interface-discovery
description: Inspect or change Wi-Fi interface discovery and scan parsing in wifi-menu.pl while preserving OpenBSD ifconfig output semantics.
---

# OpenBSD Wi-Fi Interface Discovery

## Activation

Use this skill when a change touches `list_wifi_interfaces`,
`choose_interface`, `select_interface`, `scan_networks` or
`choose_network`, or when debugging empty interface lists, missing
networks, quoted SSIDs, hexadecimal SSIDs or duplicate scan results.

Do not use it for hostname file quoting or secret handling; those belong
to `hostname-if-safe-generation` and `wifi-secret-handling`.

## Procedure

1. Read `wifi-menu.pl`, `README.md` and the relevant Makefile targets.
   Confirm the current function names before editing; line numbers move.
2. Interface discovery:
   - `ifconfig wlan` treats `wlan` as a built-in interface group and
     prints a full status block for every member. Each block starts at
     column 0 with `<name>: flags=...`.
   - `list_wifi_interfaces` extracts names matching
     `^([[:alpha:]]+[[:digit:]]+):`, removes duplicates and preserves
     kernel group order. Do not assume sorting.
   - A failed `ifconfig wlan` is a fatal error, not an empty group. An
     empty member list is reported separately by `choose_interface`.
   - With one interface, selection is automatic. With several, the
     prompt accepts only `\A[1-9][0-9]*\z` within bounds; an empty line
     cancels.
   - `select_interface` runs `ifconfig <if> up` and treats failure as
     fatal.
3. Network discovery:
   - `scan_networks` runs `ifconfig <if> scan` with list-form `open`.
     Scan lines are indented `nwid <ssid> chan <n> ...`; the interface
     status line is `ieee80211:` and must not match.
   - `ifconfig` prints printable SSIDs bare, wraps values containing
     spaces in double quotes without escaping embedded quotes, and prints
     other bytes as lowercase `0x`-prefixed hexadecimal. Empty SSIDs are
     printed as `""`.
   - The parser matches the quoted form greedily so an SSID containing
     ` chan ` is not split. It strips the outer double quotes only when
     the printed value contains whitespace, so a bare SSID that itself
     starts and ends with `"` survives. Hexadecimal text is passed back
     to `ifconfig`, which decodes it.
   - `""` is skipped. It cannot be distinguished from a literal
     two-quote SSID, so hidden or empty SSIDs have no manual-entry path.
   - Results are deduped by SSID, hiding duplicate BSSIDs and different
     security modes.
4. Keep every `ifconfig` call in list form. Never introduce a shell or
   interpolate a value into a command string.
5. If you change a regex, reason through at least these cases: printable
   bare SSID, `"Cafe Wifi"`, `"Foo"Bar baz"`, `"quoted"`, `0x...`,
   `""`, an SSID containing ` chan ` and duplicate BSSIDs.

## Validations

- Static: `make test` is only `perl -c wifi-menu.pl`; it does not validate
  scan parsing. Also run `git diff --check`.
- Static review: compare the regex against the documented `ifconfig`
  output and the cases above. Do not claim runtime coverage from a syntax
  check.
- Real check: requires OpenBSD, root and a wireless interface. Run
  `ifconfig wlan` and `ifconfig <if> scan` manually, then test one quoted
  SSID and one hexadecimal SSID. Never do this while only documenting.
- Linux cannot exercise `ifconfig` or the `wlan` group. Do not substitute
  mocked output for an OpenBSD check when claiming a fix works.

## Common problems

- Treating an `ifconfig wlan` failure as "no interfaces" hides the real
  error.
- `ifconfig scan` can print an error and still exit 0, so an empty result
  is not proof that no access point exists.
- A regex such as `"[^"]*"` breaks on SSIDs containing an embedded
  double quote and a space.
- Unconditionally stripping outer quotes corrupts a bare SSID that really
  contains quote characters.
- Interface names outside `[A-Za-z]+[0-9]+` are not discovered.
- Deduping by SSID loses per-BSSID signal and security information.

## References

- `README.md` for user-visible behavior and limitations.
- `wifi-menu.pl`: `list_wifi_interfaces`, `choose_interface`,
  `select_interface`, `scan_networks`, `choose_network`.
- [ifconfig(8)](https://man.openbsd.org/ifconfig.8)
- OpenBSD `ifconfig.c` source, especially `print_string`,
  `ieee80211_listnodes` and `ieee80211_printnode`:
  <https://github.com/openbsd/src/blob/master/sbin/ifconfig/ifconfig.c>
- Related skills: `perl-cli-validation` for menu parsing;
  `hostname-if-safe-generation` for the selected SSID.

## Maintenance & Continuous Learning

When this skill is used to modify the repository, review this skill after the implementation. Update it when the workflow, relevant project behavior, tools, configuration, paths, validation steps or assumptions have changed. Add reusable findings that would improve a future run, correct guidance that proved inaccurate, and keep examples and validation procedures current. Remove obsolete or conflicting instructions. Include only knowledge that applies to future use; do not add one-off details from the current execution. Review related skills and `AGENTS.md` for consistency, then run `make check-agent-sync` and the applicable checks documented above. Report the synchronization result and any check that could not be run.
