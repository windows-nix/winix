# Contributor guide

## Change workflow

Non-trivial features use the repository's OpenSpec workflow. The production
hardening design lives in
`openspec/changes/windows-production-delivery/` in the parent repository. Keep
proposal, capability specs, design, and tasks synchronized with implementation.

Flakes ignore untracked files. After creating a Nix module, sample, or other file
referenced by the flake, make it visible before evaluating:

```sh
git add -N path/to/new-file
```

Do not commit host-specific policy into `windows-nix/modules/` or the apply
engine. Consumer hosts import shared modules and provide their own package sets
and pins.

## Local checks

Run everything:

```sh
nix flake check path:./windows-nix
```

Run focused checks while iterating:

```sh
nix build path:./windows-nix#checks.x86_64-linux.apply-tests
nix build path:./windows-nix#checks.x86_64-linux.deploy-tests
nix build path:./windows-nix#checks.x86_64-linux.sync-pins-tests
nix build path:./windows-nix#checks.x86_64-linux.package-sets
nix build path:./windows-nix#checks.x86_64-linux.sample-security
```

Outside Nix, with the tools already available:

```sh
python3 tests/sync-pins.tests.py
python3 tests/deploy.tests.py
pwsh -NoProfile -File tests/apply.tests.ps1
bash -n deploy.sh
```

`deployFor` and the sync-pins package use `writeShellApplication`, so building
them also runs shellcheck:

```sh
nix build path:./windows-nix#packages.x86_64-linux.deploy
nix build path:./windows-nix#packages.x86_64-linux.sync-pins
```

## Test structure

### PowerShell

`tests/apply.tests.ps1` is a dependency-free pwsh suite. It checks:

- Parsing and rejection of PowerShell 7-only syntax in all engine scripts.
- Platform detection, item filtering, version comparison, and install detection.
- Step error isolation, summaries, logging, and reboot accounting.
- Cross-process mutex contention and pure reboot decisions.
- JSON/INI/text update semantics and idempotence.
- Startup plan generation, secedit, and auditpol helpers.
- Absence of application-specific names in the generic engine.
- End-to-end dry runs on both platform/build branches and failure continuation.

Keep Windows PowerShell 5.1 compatibility. Null coalescing, ternaries, pipeline
chain operators, `ForEach-Object -Parallel`, and other PS7-only constructs fail
the AST checks.

Pure functions belong in `common.ps1` where possible so Linux pwsh can test them.
Windows-touching wrappers should remain thin. Do not mock away the pure behavior
being added.

### Python

`sync-pins.tests.py` tests legacy list migration, three-set flattening, winget
string normalization, automatic kind/display-name resolution, MSI product-code
fallbacks, rejection of
ambiguous portable zips, unknown and duplicate IDs, selective pin preservation,
silent-argument overrides, and explicit external paths. Network resolution is
replaced with deterministic manifests and resolvers; real downloads are not part
of unit tests.

`deploy.tests.py` creates a complete temporary source folder and mock
`ssh`/`powershell.exe`/`tar.exe` endpoints. It records decoded PowerShell
payloads and writes real streamed tar input. The suite verifies incremental
selection, merge/enforce, protected names, WSL-without-SSH, apply argument and
exit propagation, no-op transfer, and validation/transfer failures.

When changing delivery, assert both what did happen and what must not happen
(for example, no apply after a failed archive and no SSH call in WSL mode).

### Nix rendering

`sample-packages.nix` proves the mapping to `any`/`metal`/`vm` without fetching
installers. `sample-security.nix` renders secedit, auditpol, an adapted PSDSC
resource, machine metadata, and a pinned module archive.

For migration work, compare old and new evaluated package IDs and every item
field. Moving an item between sets should change only its platform lowering,
not silently discard source, detection, driver, or installer fields.

## Working on package resolution

`sync-pins` resolves winget from a pinned `winget-pkgs` commit and GitHub/URL
sources live. It uses the Nix store as a prefetch cache. Preserve these
invariants:

- No credentials in package files or generated pins.
- No dependence on the parent repository or a host named mbox.
- Selective updates preserve unselected output byte content semantically.
- New sources produce a version, URL, file name, and SHA-256 suitable for both
  Nix fetchurl and Windows thin download.
- Installer architecture and silent switches are selected deterministically.

Use test doubles for network logic in unit tests. Perform real pin refreshes as
a separate reviewed operation; they can download large installers and update
many hashes.

## Adding or changing module options

1. Add the option with a precise type, default, description, and assertions.
2. Render into existing native formats before adding new engine concepts.
3. Keep host/application policy in host data.
4. Add or update a sample/check and the pure-engine tests that apply.
5. Update `docs/configuration.md`, `docs/architecture.md`, and operator behavior
  docs when semantics change.
6. Update the OpenSpec artifacts and tasks.

Prefer DSC native resources over custom PowerShell. Use `scripts` only with a
meaningful idempotence test. Do not make apply continue past preflight failures
such as an active writer or missing elevation.

## Real Windows validation matrix

Linux checks cannot execute Windows DSC, PnP, Appx, UAC, installer, service, or
restart APIs. Before a production release, use a disposable Windows VM or a
controlled host and record the results:

1. Build full and thin folders and inspect `items.json` for all three sets.
2. Deliver over SSH in merge mode; add a local payload and confirm it survives.
3. Deliver in enforce mode; confirm the payload is pruned and logs/markers stay.
4. Deliver over WSL with no SSH server and confirm UAC/elevation behavior.
5. Interrupt a transfer and confirm apply is not called; retry successfully.
6. Run `-DryRun`, then a real apply, then an unchanged second apply. The second
   run should report `changed: 0` except intentionally unmanaged drift.
7. Start two applies and confirm the second exits before changing state.
8. Exercise direct unelevated `apply.ps1` and confirm the actionable preflight.
9. Use an installer/test double that returns 3010. Confirm no restart without
   `-Reboot`, no restart after failures, and opt-in restart only on an isolated
   test VM.
10. Verify DSC drift correction, loopback WinRM restoration, holder restarts,
    driver installation, package detection, and boot actions relevant to the
    changed code.
11. Test thin download/hash failure and full-folder offline behavior.
12. Inspect logs and confirm deploy returns nonzero for an apply failure.

Do not test the VM unattend variant on a disk containing data; it wipes disk 0.

## Final review checklist

- `nix flake check` passes on the deliverable.
- Full, thin, and ISO outputs build for each affected in-repository host.
- Package migrations preserve every ID and item field.
- Documentation matches actual option names, defaults, protected paths, and
  exit/reboot behavior.
- No generated logs, test folders, tar archives, or result symlinks are left in
  the repository.
- Any real-Windows checks not run are stated explicitly rather than implied by
  Linux unit tests.
