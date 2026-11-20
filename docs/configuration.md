# Configuration reference

## Module entry point

Import the subflake's library and evaluate a host with `lib.evalModules`:

```nix
windows-nix.lib.windowsConfiguration {
  inherit pkgs;
  modules = [ ./hosts/laptop/windows ];
  specialArgs = { }; # optional extra module arguments
}
```

`pkgs` supplies fetchers and build tools. `specialArgs` is merged with the
provided `pkgs` and `wlib` arguments. `windowsModules.default` is the module
directory for consumers that need to compose the module list themselves.

Host policy belongs in host modules, not under `windows-nix/modules/`. A typical
host directory is:

```text
hosts/laptop/windows/
  default.nix       imports, packages, pins, and host-specific options
  packages.nix      common/bareOnly/vmOnly package sets
  pins.json         generated resolved downloads
  security.nix      optional focused modules
  apps.nix
```

All options merge across imported modules. Attrsets merge by key; lists
concatenate in module order. A conflicting scalar definition is an evaluation
error. `config.assertions` are checked when a build output is evaluated.

## Helpers (`wlib`)

- `wlib.dword n` returns `{ DWord = n; }`.
- `wlib.str s` returns `{ String = s; }`.
- `wlib.win11 value` wraps a registry or compatible value with
  `{ inherit value; minBuild = 22000; }`.
- `wlib.envString s` converts `%NAME%` segments to DSC `envvar()` expressions.
  Use it for startup commands and DSC strings that dsc.exe should resolve.
- `wlib.psdsc resource` adds
  `directives.requireAdapter = "Microsoft.Adapter/WindowsPowerShell"` for an
  adapted PowerShell DSC 1.1 resource.

## Packages

### The three sets

```nix
packages = {
  common = [ ];   # every platform
  bareOnly = [ ]; # physical/bare-metal Windows only
  vmOnly = [ ];   # detected QEMU/KVM virtio guests only
};
```

The renderer prepends the internal runtime selector `any`, `metal`, or `vm`.
Package IDs must be unique across all three lists, including disabled items.
The public item schema has no `when` field. `pins` is an attrset keyed by every
enabled package ID:

```nix
pins = lib.importJSON ./pins.json;
```

An enabled item without a pin fails evaluation. A disabled item may remain in
the configuration without a pin and is neither staged nor rendered as an
installer.

### Winget-only shorthand

Any set can contain only a winget package ID string:

```nix
packages.common = [
  "Microsoft.PowerShell"
  "KeePassXCTeam.KeePassXC"
];
```

Nix derives the ID by lowercasing the winget ID and replacing each
non-alphanumeric character with `-`; the examples become
`microsoft-powershell` and `keepassxcteam-keepassxc`. The original winget ID is
the display name. If two source IDs normalize to the same package ID, replace
one with an explicit attrset and choose a unique `id`.

`sync-pins` searches the newest manifests with a compatible x64/neutral/x86
installer. Automatic selection tries `installer`, `msi`, `msix`, then `zip` and
records the selected kind in the pin. A zip is automatic only when the manifest
provides a nested installer; a plain portable zip has no safe install location
to guess. Drivers and non-winget sources also require explicit `kind`.

When the manifest publishes `AppsAndFeaturesEntries.DisplayName`, the pin gets
an exact display-name detection regex. Otherwise MSI/WiX `ProductCode` and MSIX
`PackageFamilyName` provide native product-code and Appx detection fallbacks.
If neither the item nor pin provides `detect`, apply must run the installer on
every applicable run; add explicit detection for such packages.

Use an explicit attrset for a custom ID/name, driver, portable zip, extraction
path, explicit silent arguments, build gate, disable flag, or detection override.
An explicit winget attrset may also set `kind = "auto"`; this is the default when
`kind` is omitted. Automatic kind requires a winget source.

### Migrating flat package lists

Move each complete old item into the matching set, preserving all fields except
`when`:

- No `when`, or `when = "any"`: `packages.common`.
- `when = "metal"`: `packages.bareOnly`.
- `when = "vm"`: `packages.vmOnly`.

Runtime JSON and `-Platform` retain the existing `any`, `metal`, and `vm`
values. Standalone pin generation still accepts an old flat list during
migration.

### Package item fields

Required for an explicit attrset:

- `id`: unique lowercase identifier matching `[a-z0-9-]+`; also its installer
  directory name.
- `name`: human-readable log name.
- `source`: one of:
  - `{ winget = "Publisher.Package"; }`: resolve a pinned winget manifest.
  - `{ github = { repo = "owner/project"; asset = "regular-expression"; }; }`:
    select a release asset.
  - `{ url = "https://..."; version = "..."; }`: resolve a fixed URL and version.

Optional:

- `kind`: `auto` (default), `installer`, `msi`, `zip`, `msix`, or `driver`.
  `auto` resolves only winget manifests.
- `detect`: installed-state check, default `null`:
  - `{ displayName = "regex"; }`: match uninstall-registry display names. An
    installed `DisplayVersion` equal to or newer than the pin is accepted.
  - `{ path = "C:\\...\\app.exe"; }`: presence check; `%VAR%` is expanded.
  - `{ productCode = "{GUID}"; }`: Windows Installer uninstall-key product code,
    compared case-insensitively and without regard to braces.
  - `{ appx = "Package.Name"; }`: Appx/MSIX presence check.
  - `null` uses derived pin detection when present. If neither has detection,
    the item is installed on every applicable run.
- `enable`: Boolean, default `true`.
- `minBuild`: minimum Windows build, default `0`.
- `silentArgs`: string or `null`; overrides the resolved manifest's silent
  switches.
- `extractTo`: destination for a plain zip or zipped driver, otherwise `null`.
- `nestedFile`: installer path inside a zip; run it instead of extracting the
  zip as an application.
- `rootDevice`: root-enumerated hardware ID such as `Root\MttVDD` for a driver
  that needs a device node created before binding.
- `tool`: stage under `tools/<tool>/` for the engine instead of listing the item
  in `items.json`. Engine tools normally live in `common`.

Kind behavior:

- `installer`: run the file with `silentArgs`.
- `msi`: run `msiexec /i ... /qn /norestart`.
- `zip`: run `nestedFile`, or extract to `extractTo`.
- `msix`: call `Add-AppxProvisionedPackage -SkipLicense`.
- `driver`: import catalog signers required by the selected package and run
  `pnputil`; `rootDevice` uses the root-device installation path.

### Pin generation

The packaged generator uses locked Python, Git, yq, and Nix dependencies:

```sh
nix run <windows-nix>#sync-pins -- --config /any/packages.nix --output /any/pins.json
nix run <windows-nix>#sync-pins -- --config ./packages.nix --output ./pins.json keepassxc dsc
```

Positional IDs selectively refresh those items and preserve all other pins,
including pins for removed items. Unknown IDs and duplicate package IDs fail.
With no IDs, the output is regenerated from the current package file. The
standalone parser accepts the new sets and the old flat list to ease migration.

Environment alternatives:

- `WINDOWS_CONFIG_DIR`: directory holding default `packages.nix` and `pins.json`.
- `WINDOWS_PACKAGES`: explicit package file.
- `WINDOWS_PINS`: explicit output file.
- `WINGET_PKGS`: winget-pkgs blobless clone cache, default `/tmp/wp`.
- `GITHUB_TOKEN` or `GH_TOKEN`: optional GitHub API authentication. Do not put
  either token in Nix files or pins.

CLI paths take precedence over environment defaults. `WINDOWS_HOST` belongs to
SSH deployment and is not interpreted as a pin directory.

A pin has this shape:

```json
{
  "id": {
    "version": "1.2.3",
    "url": "https://vendor/file.exe",
    "sha256": "lowercase-hex-or-SRI",
    "file": "file.exe",
    "silentArgs": "/quiet",
    "installerType": "inno",
    "nestedFile": null,
    "kind": "installer",
    "detect": { "displayName": "^Vendor Application$" }
  }
}
```

`kind` and `detect` are emitted when automatic winget resolution supplies them;
explicit kinds and detection take precedence. Other fields retain their existing
meanings.

Review URL, version, and hash changes. A rolling upstream URL can fail a later
build when its content changes; refresh its pin deliberately. Full builds fetch
fixed-output files into the Nix store. Thin builds keep URLs and hashes in
`items.json` so Windows can fetch only missing software.

## Registry and policy

```nix
registry."HKLM\\SOFTWARE\\Policies\\Example".Enabled = wlib.dword 1;
registry."HKCU\\Software\\Example"."Value" = {
  value = wlib.str "configured";
  exist = true;
  minBuild = 0;
};
registry."HKCU\\Software\\Example".Obsolete = { exist = false; };
```

`registry` is `attrsOf (attrsOf regValue)`. Use `""` as the value name for a
key's default value. Direct value data supports:

- `String` and `ExpandString`: string.
- `MultiString`: list of strings.
- `Binary`: list of octets (`0..255`).
- `DWord`: unsigned 32-bit integer.
- `QWord`: unsigned integer.

The wrapped form accepts `value` (nullable), `exist` (default `true`), and
`minBuild` (default `0`). `exist = false` deletes the value. Registry policy
under `HKLM\SOFTWARE\Policies` has the effective policy behavior but does not
make `gpedit.msc` display a registry.pol origin.

## Startup entries

```nix
startup.Example = {
  command = "%LOCALAPPDATA%\\Example\\example.exe --minimized";
  scope = "user"; # or "machine"
};
```

Entries render as HKCU/HKLM `...\CurrentVersion\Run` registry resources. To
remove an entry, declare its registry value with `exist = false`; removing only
the `startup` attrset entry stops future management but does not delete the
existing Run value.

## Optional Windows features

```nix
features.Microsoft-Windows-Subsystem-Linux = "Installed";
features.VirtualMachinePlatform = "Installed";
features.SomeLegacyFeature = "NotPresent";
```

Values are `Installed`, `NotPresent`, or `Removed`, using DISM feature names.
They render to `Microsoft.Windows/OptionalFeatureList`.

## Power

```nix
power.scheme = {
  name = "Performance";
  guid = "11111111-1111-1111-1111-111111111111";
  template = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c";
};
power.standbyTimeout = { ac = 0; dc = 30; };
```

`power.scheme` and `power.standbyTimeout` default to `null`. A scheme duplicates
`template` under `guid` if needed and activates it. Standby values are minutes;
zero means never. Generated scripts match GUIDs and numeric powercfg output, not
localized labels.

## Imperative scripts

```nix
scripts."Example invariant" = {
  test = ''Test-Path -LiteralPath 'C:\ProgramData\Example\done' '';
  set = ''
    New-Item -ItemType Directory -Path 'C:\ProgramData\Example\done' -Force
  '';
  get = null;      # optional DSC getScript
  minBuild = 0;
};
```

Scripts are Windows PowerShell 5.1 `WindowsPowerShellScript` DSC resources.
`test` must return true only in the desired state. `set` must be safe to rerun
after drift. Keep host policy in these resources, not in `apply.ps1`.

## Raw DSC and PSDSC modules

```nix
dsc.resources = [
  {
    name = "Example service";
    type = "Microsoft.Windows/Service";
    properties = { Name = "example"; State = "Running"; StartupType = "Automatic"; };
    minBuild = 0;
    dependsOn = [ ];
  }
];

dsc.modules.AuditPolicyDsc = {
  version = "1.4.0.0";
  hash = "sha256-Z1SqayAyKtSrkPq6MQ5YO2oTKIlA3ZZZS3X8xxKhvLs=";
};
```

`dsc.resources` is passed through as a list of DSC v3 resource attrsets. Use
`wlib.psdsc` for Gallery/PSDSC resources that need the Windows PowerShell
adapter. `dsc.modules` pins `.nupkg` content by version and hash. Modules are
staged in `tools/psmodules` and installed machine-wide.

`dsc.winrm` defaults to true when a resource requires a Windows PowerShell
adapter. If WinRM was stopped, apply brackets the DSC phase with loopback-only
listeners and restores the prior service and listener state. It does not expose
a network listener for this phase.

## Security policy

```nix
securityPolicy.userRights.SeLockMemoryPrivilege = [ "S-1-5-32-544" ];
securityPolicy.account.MinimumPasswordLength = 12;
securityPolicy.account.LockoutBadCount = 5;
securityPolicy.audit."{0CCE9215-69AE-11D9-BED3-505054503030}" = "both";
```

- `userRights`: privilege constant to the exact list of SID holders. `[]` means
  nobody. Undeclared rights are untouched. Use SIDs, not localized names.
- `account`: secedit `[System Access]` keys to integer or string values.
- `audit`: advanced audit subcategory GUID, including braces, to `none`,
  `success`, `failure`, or `both`. GUID validation happens at evaluation.

The generated scripts compare only declared keys through `secedit` and
`auditpol`; undeclared security settings remain unmanaged.

## Declared application files

```nix
files.example = {
  root = "RoamingAppData";
  path = "Example\\settings.json";
  format = "json";
  json = { theme = "dark"; nested.value = "%LOCALAPPDATA%\\Example"; };
  requires = [ "%LOCALAPPDATA%\\Example\\example.exe" ];
  holders = [
    { process = "example"; start = null; args = "--minimized"; }
  ];
  minBuild = 0;
};
```

Roots are `LocalAppData`, `RoamingAppData`, `ProgramData`, `ProgramFiles`, and
`UserProfile`. Per-user roots and HKCU refer to the account running apply.

Formats:

- `json`: `json` attrset merged recursively into existing JSON. Other keys and
  array values not explicitly replaced remain app-owned. Parsed values are
  compared, so formatting alone is not drift.
- `ini`: `ini` is `section -> key -> string`; only declared keys change.
- `text`: `text` owns the entire file content.

Exactly the data field matching `format` must be nonempty. `requires` paths are
expanded and skip the file when absent. `%VAR%` in JSON/INI strings expands at
apply time. `holders` stop before a changed write and restart afterward in the
interactive user's session; `start = null` reuses the stopped executable path.
Unchanged files do not stop holders.

Removing a `files` declaration does not delete the app file. Use an explicit
removal script when deletion is desired.

## Per-boot platform actions

```nix
boot.actions = [
  { kind = "ServiceStartType"; target = "example"; metal = "disabled"; vm = "auto"; }
];
```

The actual fields are `metal` and `vm`, both nullable and accepting Boolean or
string values. `null` means no action on that platform. Kinds:

- `ServiceStartType`: sc.exe start value (`boot`, `system`, `auto`, `demand`, or
  `disabled`).
- `Service`: service/display name; true means automatic and started, false means
  stopped and disabled.
- `PnpDevice`: hardware ID; true enables and false disables matching devices.
- `MsiInterrupts`: PCI vendor prefix such as `VEN_10DE`; true sets MSI support.

Actions render to `startup.json` and run as SYSTEM at every boot. The package
sets use the friendlier `bareOnly` name while this existing runtime API retains
`metal`.

## Debloat, drivers, manual steps, and unattend

- `debloat.switches`: list of Win11Debloat switch names without the leading
  dash. Empty skips debloat. Input fingerprints prevent unnecessary reruns.
- `drivers.virtio`: list of virtio-win driver directory names staged from the
  nixpkgs `w10/amd64` layout into `drivers/vm` and installed with `pnputil`.
- `manualSteps`: list of `{ text; belowBuild ? null; }`. Text is printed in the
  summary; `belowBuild` limits it to older Windows builds.
- `unattend.variant`: `vm` (default) or `metal` answer-file variant.
- `unattend.user`: local administrator name, default `user`.
- `build.applyDir`: engine source directory, default the subflake's `apply/`.

**Warning:** the VM answer file wipes disk 0 and creates EFI/MSR/C/D partitions.
The metal variant leaves partitioning to the operator. Neither variant is a
general-purpose installer for arbitrary machines; review `unattend.nix` before
using the ISO.

## Read-only build outputs

- `build.folder`: complete configuration folder, including fixed-output
  installers, tools, drivers, DSC modules, scripts, JSON, and YAML.
- `build.folderThin`: the same metadata and scripts without installer blobs.
  Missing applicable installers are downloaded at apply time and hash-checked.
- `build.iso`: non-bootable ISO 9660/Joliet image, volume label `MCONFIG`.
- `build.unattend`: answer file used by the ISO.
- `build.applyDir` is configurable rather than read-only.

`items.json`, `machine.json`, `startup.json`, and DSC document derivations are
also exposed internally through build passthru for checks.

## Windows build gates

Resources with `minBuild > 19045` render into `config.win11.dsc.yaml`; other
resources use `config.dsc.yaml`. Apply skips the Win11 document below build
22000. Packages and declared files carry their own `minBuild` and compare it to
the detected or overridden build. Use `-Build` only for testing or a deliberate
override; it does not change Windows.
