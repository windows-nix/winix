# Operations, security, and recovery

## Running apply

Use the built folder's self-elevating launcher on Windows:

```powershell
.\apply.cmd
.\apply.cmd -DryRun
.\apply.cmd -Reboot
```

Or invoke the PowerShell engine from an already elevated noninteractive session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\apply.ps1
```

Parameters:

- `-Root <path>`: configuration folder; defaults to the script directory.
- `-Platform vm|metal`: override platform detection for testing or deliberate
  recovery. Empty detects the platform.
- `-Build <integer>`: override the detected Windows build; `0` detects it.
- `-DryRun`: log planned effects, run no native changing command, and do not
  write markers or persistent startup state. Some read-only parsing, logging, and temporary tool
  expansion still occur.
- `-Reboot`: opt in to a restart only if a step reports a reboot-required code
  and the run has no failures.

Normal interactive use should go through `apply.cmd`; it requests UAC elevation
and passes arguments to `apply.ps1`. Direct real runs without an elevated
administrator token exit with code 2 before configuration phases.

## Concurrency and exit status

A named `Global\MachineConfigApply` mutex serializes apply across interactive,
SSH, service, and scheduled-task sessions. A concurrent run exits before apply
steps with an actionable error. The mutex is released at normal completion and
by Windows when a process exits unexpectedly.

Exit codes:

- `0`: no failed step. Skipped and reboot-required steps can still be present.
- `1`: one or more steps failed.
- `2`: preflight failed, such as missing elevation or another active apply.

A step failure does not abort later independent phases. Read the summary and
log, fix the cause, and rerun. Deployment returns the remote apply status; its
own usage and validation errors normally return 2.

## Apply phases

After elevation and mutex preflight, apply:

1. Creates a log and reads `items.json` and `machine.json`.
2. Stages `drivers/vm` with `pnputil`, guarded by a content fingerprint.
3. Runs Win11Debloat when switches are declared, guarded by tool/switch
   fingerprints.
4. Unpacks pinned DSC and installs pinned PSDSC modules machine-wide.
5. If required, starts WinRM with loopback-only listeners, runs DSC documents,
   and restores the prior listener/service state. DSC uses `config test` first
   and `config set` only on drift.
6. Filters packages by runtime platform and `minBuild`, checks `detect`, obtains
   missing pinned installers, and installs them.
7. Writes changed declared files and restarts their holder processes in the
   interactive user session.
8. Copies the startup engine into persistent ProgramData, registers the SYSTEM
   `MachineConfigStartup` boot task, and maintains the desktop shortcut.
9. Prints manual steps, changed/failed/reboot summaries, and the log path.

The persistent startup task reads `startup.json` and applies per-platform boot
actions. It is not a second full apply.

## Idempotence and drift

A converged run should report `changed: 0`. DSC documents already in desired
state are skipped. Files compare parsed JSON or exact INI/text updates rather
than rewriting for formatting alone. Packages accept installed versions newer
than their pin when `displayName` detection provides comparable versions; this
avoids downgrading self-updating applications.

Some effects are fingerprint-based because Windows cannot query them back
completely: debloat and staged virtio drivers. Their markers live in the
persistent configuration directory. Keep markers when redeploying; deleting
one intentionally causes that phase to rerun.

Dry run is a planning aid, not a proof that every installer or DSC resource will
succeed. It cannot execute Windows-specific APIs on Linux and does not replace a
real-host validation.

## Logs and diagnosis

Logs are `logs\apply-<timestamp>.log` under the source folder when writable,
otherwise under `C:\ProgramData\machine-config\logs`. Boot actions write
`startup.log` in the persistent logs directory.

Each result is `ok`, `skipped`, or `failed`, with detail. Useful checks:

- `changed: N`: number of effective steps, excluding reads, DSC unpacking, and
  the WinRM bracket.
- `failed: ...`: exact failed phase names.
- `a reboot is required to finish`: an installer/native command returned 3010 or
  1641.
- `when=vm, platform=metal`: expected platform filtering, not an error.
- `needs build ...`: expected build gate.
- `requires ...`: declared file skipped because its app prerequisite is absent.

When DSC reports drift, the log lists resource names before set. For package
failures, check detection rules, silent arguments, target architecture, network
access for thin delivery, and the pinned installer hash.

## Reboot policy

Reboots are never implicit. Installer reboot codes are recorded and summarized.
Without `-Reboot`, Windows remains running. With `-Reboot`, apply restarts only
when a reboot is pending and no step failed. A failed run never automatically
restarts even when `-Reboot` was supplied.

For unattended deployment:

```sh
windows-deploy --host windows.example ./result --apply -- -Reboot
```

Expect the SSH/WSL connection and subsequent management actions to be disrupted
by a real restart. Wait for Windows and verify a second apply after boot. The
boot task handles per-boot actions; it does not replace post-reboot validation.

## Removals and rollback

Nix evaluation and folder pruning do not imply reversible Windows transactions.
Understand the three separate kinds of state:

1. **Source/build state**: Nix modules, pins, and store outputs. Rebuild an older
   revision to recover the old payload.
2. **Delivered folder state**: source files plus protected runtime state.
   `merge` preserves extras; `enforce` prunes unmanaged payload files.
3. **Windows machine state**: installed software, registry values, services,
   files, drivers, accounts, and policies. Only apply resources change this.

Removing a declaration means “stop managing this,” not “undo it.” Use explicit
operations when reversal is required:

- Registry value: keep the declaration with `exist = false`.
- Optional feature: set `NotPresent` or `Removed` as appropriate.
- Application file: add a tested script that deletes or restores the desired
  content, then remove that script only after convergence.
- Package: add a tested uninstall script or DSC resource with an explicit test.
  Do not assume every pinned installer supports silent uninstall.
- Startup entry: declare the corresponding Run registry value absent.
- Boot action: declare the desired opposite value; `null` means no action.

To roll back a bad configuration, stop further deployments, rebuild the last
known-good folder, deploy it, and add explicit compensating resources for any
new machine state that the old folder does not own. There is no snapshot-based
rollback. Use Windows restore points, VM snapshots, filesystem backups, or
application exports when the risk justifies them.

`enforce` can remove a manually added payload needed by a custom script. Keep a
backup of local additions or use merge mode. Protected logs and markers are not
backups of Windows state.

## Security model

### Supply chain

- Installer blobs and Gallery modules are fixed-output Nix fetches.
- Thin downloads verify SHA-256 before replacing a partial file.
- Winget manifests and GitHub releases are resolved at pin-refresh time, not
  selected dynamically by apply.
- Review pin diffs and upstream signatures. A hash guarantees consistency with
  the reviewed bytes, not that the publisher is trustworthy.
- Do not store GitHub tokens, SSH private keys, passwords, or application secrets
  in host modules, pins, ISO files, or logs.

### Elevation and remote access

Apply is administrative code. Limit who can modify the Nix source, built folder,
target ACLs, SSH keys, and WSL configuration. A user who can replace apply
scripts can run code as administrator/SYSTEM.

OpenSSH delivery keeps host-key checking and batch authentication enabled. WSL
uses the current Windows user's access token and UAC; it does not create an
unauthenticated local management service.

### Driver trust

Driver packages without an already-trusted catalog signer can require importing
the package's own Authenticode chain into TrustedPublisher and root/intermediate
stores. This is restricted to explicitly declared driver packages but is a
significant trust decision. Review driver sources and signatures before adding
them, especially non-WHQL packages.

### WinRM and DSC

PSDSC 1.1 adapters need local WinRM. Apply uses loopback-only listeners when it
had to start WinRM and restores saved listener configuration afterward. A
preexisting running WinRM service is not reconfigured by this bracket. Raw DSC
resources and scripts run with apply's administrative privileges.

### First boot

The answer file creates a one-time empty-password auto-logon and then requires a
password change. Protect installation media and the first-boot session. The VM
variant intentionally wipes disk 0. Config ISOs are not secret stores.

## Common failures

- **Second apply exits “already running”**: wait for the first process. If it was
  terminated, Windows releases the abandoned mutex; rerun. Do not delete random
  system mutex facilities.
- **Direct apply says elevation is required**: use `apply.cmd` or an elevated
  SSH/session token.
- **SSH works but UAC appears/fails**: the account is not receiving an elevated
  token. Correct OpenSSH/account policy rather than disabling UAC.
- **Thin package hash mismatch**: do not bypass verification. Refresh and review
  the pin if upstream intentionally replaced the file, or use the full folder.
- **Package reinstalls every run**: its `detect` does not match installed state,
  or the installed version cannot be compared. Inspect uninstall registry/Appx
  data and adjust the declaration.
- **Application overwrites a declared file**: declare its holder process so it
  stops before writes and restarts afterward.
- **Per-user file changed for the wrong account**: apply/HKCU targets the account
  running apply. Use that account or extend the module deliberately; implicit
  multi-user fan-out is not supported.
- **Win11 resources skipped**: detected build is below 22000. Check `-Build` was
  not accidentally supplied and verify the actual Windows build.
- **Deploy did not remove a manually installed app**: expected; enforce owns only
  the folder. Add an explicit uninstall resource.
- **Deployment interrupted during commit**: rerun the same folder. Hash
  comparison and staging make retries incremental, but no claim of atomic
  whole-directory replacement is made.
