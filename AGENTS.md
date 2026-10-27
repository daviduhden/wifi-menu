# Agent Instructions

## Project

`wifi-menu` is an OpenBSD-only, root-run, interactive client-mode Wi-Fi
configurator. It is a single Perl script (`wifi-menu.pl`) installed by a
small Makefile. There is no CPAN dependency, functional test suite or
linter configuration. GitHub Actions runs the agent/skills maintenance
check on pull requests. The license is ISC; see `LICENSE`.

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
  stays last. Keep target bodies within checkmake's five-line default, and
  preserve command order and failure short-circuiting when joining recipes.
- Preserve the ISC copyright and license notices.
- Do not impose a historical 72-column limit. There is no enforced line
  length; current Perl lines stay under 80 columns.

## Commands

```sh
make test                 # perl -c wifi-menu.pl; syntax only
make check-agent-sync     # enforce instruction maintenance and structure
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
- Do not invent a functional test framework or linter target. The
  GitHub Actions workflow only enforces agent/skills synchronization;
  it does not exercise the OpenBSD program.

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

## Continuous Agent & Skills Maintenance

Agent instructions and skills are living repository artifacts.

Every repository modification MUST include an agent/skills synchronization step.

Before completing any task, inspect the applicable AGENTS.md and SKILL.md files, update the affected instructions, and validate their consistency with the implementation.

A code change without the corresponding agent knowledge maintenance is considered incomplete.

Never claim completion when the synchronization step has been skipped or has failed.

This review is required after every repository change, including code, configuration, dependencies, features, bug fixes, refactors, tests, workflows, documentation and repository structure changes. Before editing, inventory applicable `AGENTS.md`, `.github/agents/*.agent.md`, `.agents/skills/**/SKILL.md`, `.github/skills/**/SKILL.md`, `.claude/skills/**/SKILL.md`, and other tool instruction files. Then identify skills by their activation scope and the functions, files, tools or invariants touched by the change.

Review the root instructions and each relevant specialized instruction after implementation. Update existing instructions when behavior, procedures, assumptions, tools, commands, paths or reusable lessons changed. Create a skill only when the repository has a reusable, distinct workflow that no existing skill covers; do not create duplicate or task-specific skills. Keep specialized agents synchronized with their related skills and the actual repository workflow. Remove obsolete or contradictory guidance and verify every local path and cross-reference.

Every task that changes repository files must include a substantive, relevant change to at least one agent instruction or skill. The automated check rejects missing, empty and obviously trivial instruction edits; it cannot judge semantic relevance, which still requires review. If a useful synchronization change cannot be made, document why and report the task as incomplete. Do not add timestamps or cosmetic edits to satisfy the check.

Run `make check-agent-sync` before completion. It checks Git changes, instruction structure, skill frontmatter, required maintenance sections, substantive instruction changes and local Markdown links. For a pull request, CI runs the same checker against the PR base. Also run `git diff --check` and the implementation-specific checks applicable to the task. These structural checks do not establish semantic correctness.

### Definition of Done

- [ ] Repository changes implemented.
- [ ] Relevant agent instructions reviewed.
- [ ] Relevant skills reviewed.
- [ ] Affected AGENTS.md / SKILL.md files updated.
- [ ] Obsolete knowledge removed.
- [ ] New reusable knowledge incorporated.
- [ ] Agent and skill references validated.
- [ ] Automated maintenance checks passed.
- [ ] Final synchronization status reported.

If any item fails, correct it or explicitly report the limitation and leave the task incomplete. Final reports must include an **Agent & Skills Synchronization** section listing agents reviewed, skills reviewed, instruction files updated, knowledge incorporated or corrected, validations actually run, and a final `PASS` or `FAIL` status. Never claim a validation passed unless it ran successfully.
