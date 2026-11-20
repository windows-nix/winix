# windows-nix

Declarative Windows configuration with Nix. Host modules render to DSC v3,
pinned installers, configuration files, and a PowerShell 5.1 apply engine.
Delivery works over SSH or directly from WSL on the same Windows host.

## Requirements

- Nix with flakes on `x86_64-linux`; NixOS is not required.
- Windows 10/11 x64 with Windows PowerShell 5.1.
- SSH delivery: OpenSSH Server and an elevated administrator account.
- WSL delivery: `powershell.exe` and `tar.exe` available through WSL interop.

## Configure

Add `windows-nix` as a flake input, then evaluate a host:

```nix
let
  windows = windows-nix.lib.windowsConfiguration {
    inherit pkgs;
    modules = [ ./hosts/laptop/windows ];
  };
in {
  packages.x86_64-linux = {
    windows-config = windows.config.build.folder;
    windows-config-thin = windows.config.build.folderThin;
    windows-config-iso = windows.config.build.iso;
    windows-deploy = windows-nix.lib.deployFor pkgs;
  };
}
```

A host imports its package sets and generated pins:

```nix
# hosts/laptop/windows/default.nix
{ lib, wlib, ... }:
{
  packages = import ./packages.nix;
  pins = lib.importJSON ./pins.json;

  features.Microsoft-Windows-Subsystem-Linux = "Installed";
  registry."HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".AppsUseLightTheme = wlib.dword 0;
}
```

Packages have three platform lists. A winget ID is sufficient for standard
installers; attrsets provide explicit overrides:

```nix
# hosts/laptop/windows/packages.nix
{
  common = [
    "Microsoft.PowerShell"
    {
      id = "keepassxc";
      name = "KeePassXC";
      kind = "msi";
      source.winget = "KeePassXCTeam.KeePassXC";
      detect.displayName = "^KeePassXC";
    }
  ];
  bareOnly = [ ];
  vmOnly = [ ];
}
```

Resolve installer versions and hashes, then build:

```sh
nix run path:../windows-nix#sync-pins -- \
  --config hosts/laptop/windows/packages.nix \
  --output hosts/laptop/windows/pins.json
nix build .#windows-config
```

Build outputs:

- `build.folder`: full folder with pinned installers.
- `build.folderThin`: metadata and tools; Windows downloads missing installers.
- `build.iso`: non-bootable configuration CD.
- `build.unattend`: generated answer file.

## Deploy

```sh
# Remote Windows
windows-deploy --host windows.example ./result --apply

# Windows host of the current WSL instance
windows-deploy --transport wsl ./result --apply

# Inspect the apply plan
windows-deploy --transport wsl ./result --apply -- -DryRun
```

`--mode merge` is the default and preserves unmanaged target files.
`--mode enforce` removes payload files absent from the build. Runtime logs and
state are preserved in both modes. Removing something from Nix does not
uninstall it or undo its Windows settings; see the operations guide for explicit
removal and rollback procedures.

## Documentation

- [Configuration reference](docs/configuration.md)
- [SSH, WSL, ISO, and deployment modes](docs/deployment.md)
- [Operations, security, recovery, and troubleshooting](docs/operations.md)
- [Architecture](docs/architecture.md)
- [Development and real-host validation](docs/development.md)

Run the Linux-side test suite with:

```sh
nix flake check path:./windows-nix
```
