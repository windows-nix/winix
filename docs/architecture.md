# Architecture

## Design boundary

`windows-nix` is a renderer plus a generic apply engine. Host policy is data:
Nix modules declare packages, native Windows resources, scripts, and files. The
build converts that data to formats Windows can consume. The engine contains no
host names or application-specific policy; tests enforce this boundary.

The subflake can be consumed from any repository. It does not import the parent
flake, discover mbox, read a fixed host path, or require NixOS on the build
machine. The consumer owns host modules, pins, and output wiring.

## Repository layout

```text
flake.nix          library, deploy/sync packages, and checks
lib.nix            windowsConfiguration and wlib helpers
modules/
  default.nix      module imports
  packages.nix     package sets, pins, and assertions
  dsc.nix          registry, startup, features, power, scripts, raw DSC
  security.nix     secedit/auditpol script generation
  secpol.ps1       pure/security helper functions
  files.nix        declared files, boot actions, manual steps
  build.nix        folder/thin/ISO/unattend rendering
apply/
  apply.cmd        self-elevating launcher
  apply.ps1        generic phased apply engine
  common.ps1       shared pure functions and Windows wrappers
  startup.ps1      per-boot action engine
deploy.sh          staged incremental SSH/WSL delivery
sync-pins          setup-independent pin resolver
unattend.nix       answer-file renderer
tests/             PowerShell, Python, and sample-host checks
docs/              operator and contributor documentation
```

## Evaluation and rendering

`lib.windowsConfiguration { pkgs; modules; specialArgs ? {}; }` calls
`lib.evalModules` over the generic modules and host modules. Options provide
types, defaults, assertions, and merge behavior. Build assertions are forced by
`build.folder`, `build.folderThin`, and `build.iso` so missing pins or invalid
configurations fail before delivery.

| Subsystem | Public option | Native/applied representation |
|---|---|---|
| Packages | `packages.{common,bareOnly,vmOnly}`, `pins` | `items.json`, fixed-output installers, `tools/` |
| Registry/ADMX effective values | `registry` | DSC `Microsoft.Windows/Registry` |
| Autostart | `startup` | Run-key registry resources |
| Optional features | `features` | DSC `Microsoft.Windows/OptionalFeatureList` |
| Power | `power` | DSC WindowsPowerShellScript using `powercfg` |
| Imperative invariants | `scripts` | DSC WindowsPowerShellScript test/set/get |
| Other native resources | `dsc.resources` | Verbatim DSC v3 resources |
| Gallery PSDSC | `dsc.modules`, `wlib.psdsc` | Pinned machine-wide modules and adapter directives |
| Account/user rights | `securityPolicy.{account,userRights}` | Generated secedit test/set scripts |
| Advanced audit | `securityPolicy.audit` | Generated auditpol scripts keyed by GUID |
| Application settings | `files` | `machine.json`; JSON/INI/text engine |
| Per-boot platform actions | `boot.actions` | `startup.json`; SYSTEM scheduled task |
| Debloat | `debloat.switches` | Pinned Win11Debloat and switch file |
| Virtio drivers | `drivers.virtio` | `drivers/vm`; `pnputil` |
| First boot | `unattend` | `autounattend.xml` and config ISO |

JSON is valid YAML for the generated DSC documents. The files use `.yaml` names
because dsc.exe accepts either representation.

## Package-set lowering

The three public lists are flattened in this order:

1. `common` receives `when = "any"`.
2. `bareOnly` receives `when = "metal"`.
3. `vmOnly` receives `when = "vm"`.

This lowering keeps the apply engine stable and makes rendered output easy to
inspect. Assertions operate on the flattened list, so an ID collision across
sets is caught. String entries are expanded to winget items before lowering;
the resolver records automatic kind and detection data in their pins, and the
renderer combines that data with any explicit overrides. Tools are split from
installers; tools are staged for the engine and omitted from `items.json`.

Full builds copy fixed-output blobs. Thin builds omit installer blobs but retain
pins in JSON. At apply time, `Test-ItemApplies` performs platform/build gating,
`Test-Installed` handles detection, and missing files are downloaded to partial
paths, verified, and renamed.

## Platform detection

`Get-Platform` returns `vm` only when both are true:

- `Win32_ComputerSystem.HypervisorPresent` is true.
- A PCI device has virtio vendor `VEN_1AF4`.

Otherwise it returns `metal`. Hyper-V/VBS on physical Windows can set the
hypervisor bit, so the bit alone is insufficient. SMBIOS copying is not used as
the discriminator. The detector targets the existing QEMU/KVM virtio use case;
other hypervisors need a deliberate detector extension or `-Platform` override.

`bareOnly` means the detector's `metal` result. The existing boot-action fields
and apply CLI continue to use `metal` for compatibility.

## DSC selection and WinRM

Resources with `minBuild > 19045` go to `config.win11.dsc.yaml`; the rest go to
`config.dsc.yaml`. Apply skips the Win11 document below build 22000.

Each DSC document is tested before set. This makes no-op runs visible and limits
set operations to drift. Raw resource attrsets can include directives and
`dependsOn` fields accepted by DSC.

PSDSC 1.1 resources run through the Windows PowerShell adapter. When their
configuration requires it and WinRM was not running, apply:

1. Exports listener registry state and records service start type.
2. Starts WinRM with only IPv4/IPv6 loopback listeners.
3. Runs the DSC documents.
4. Restores listener state and prior disabled/stopped behavior.

The adapter constraint is why securityPolicy uses secedit/auditpol directly
instead: its typed security resources do not require WinRM.

## Generic file updates

`Get-FileUpdate` computes desired content without writing:

- JSON: parse, recursively merge declared objects, replace declared scalar/array
  leaves, preserve undeclared keys, and compare parsed values.
- INI: replace/add only declared section keys and preserve other text.
- Text: own the whole content.

Environment expansion happens on declared values. If content is unchanged, no
write or holder stop occurs. Otherwise holders are stopped, the file is written,
and unique holders are restarted after all file updates through a one-shot
interactive-session scheduled task. If no user is logged on, restart is skipped
and normal logon startup can start the app.

## Native process and reboot handling

Native exit codes 3010 and 1641 are reboot-required results, not immediate
failures. Other unexpected nonzero codes fail the step. Installer processes are
waited for without waiting for every descendant, avoiding installers that launch
long-running apps.

A summary records failed steps and reboot requirements. Reboot is a separate
opt-in decision after all phases and lock release. No failed run reboots.

## Delivery pipeline

Both transports execute the same encoded PowerShell operations:

1. Validate local folder, target path, transport, and mode.
2. Read a remote SHA-256 manifest, excluding protected runtime state.
3. Compare local hashes and build a changed-file list.
4. Stream a dereferencing tar archive into a target staging directory.
5. After successful extraction, copy staged files to the live folder.
6. In enforce mode, remove manifest entries absent from the source and prune
   empty unprotected directories.
7. Remove staging state and optionally invoke `apply.cmd`.

SSH wraps PowerShell and tar in noninteractive OpenSSH calls. WSL invokes
`powershell.exe` and `tar.exe` directly. This keeps policy identical while using
no network service for same-host WSL.

The pipeline is incremental and staged, not a whole-directory atomic rename.
The target can contain runtime logs and markers, so renaming the entire folder
would introduce more state-management risk than it solves.

## Deliberately not used

- **LGPO/registry.pol**: effective ADMX policy registry values are directly
  testable by DSC. They do not show a configured origin in gpedit.
- **SecurityPolicyDsc/AuditPolicyDsc for typed security policy**: secedit and
  auditpol avoid WinRM. Gallery modules remain available through raw PSDSC.
- **Provisioning packages**: require a Windows GUI authoring tool and do not
  provide drift correction.
- **Start layout/default association XML**: commonly limited to first sign-in or
  new profiles and can trigger app-default resets.
- **winget configure as the package source of truth**: dynamic resolution would
  weaken fixed pins and offline behavior.

## Not covered by typed options yet

AppLocker/WDAC, BitLocker, certificate stores, local users/groups, third-party
ADMX ingestion, arbitrary scheduled tasks beyond engine plumbing, and default
file associations have no dedicated typed module. Use native `dsc.resources`,
pinned Gallery modules, or tested `scripts` until a reusable option earns its
place. The generic delivery and apply safety behavior already applies to those
resources.

Multi-user fan-out is also not implicit: per-user files and HKCU target the
account running apply. Adding it requires an explicit profile/user model rather
than guessing every profile on a machine.
