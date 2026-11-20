# VM host module (`nixosModules.windows-vm`)

Generic, hardware-independent NixOS module that runs a Windows install as a
KVM guest with GPU passthrough (VFIO/iommufd, hugepages, CPU pinning, kvmfr
for Looking Glass, evdev input passthrough, on-demand GPU handover). Exported
from this flake:

```nix
# host flake.nix
inputs.windows-nix.url = "path:../windows-nix"; # or github:...

# hosts/<host>/default.nix
imports = [
  inputs.windows-nix.nixosModules.windows-vm
  inputs.windows-nix.nixosModules.win-sync   # optional: deliver the config folder
];
```

`nixosModules.default` imports both.

## What the host must supply

The module has no machine-specific defaults:

- `windows-vm.user` — **required** (kvm group, polkit rule, user units).
- `windows-vm.guestGpu` — PCI functions to pass, or leave null to auto-detect
  the NVIDIA card in the facter report (auto-detect asserts that the report
  lists ≥ 2 GPUs).
- `windows-vm.gpuSystemUnits` / `gpuUserUnits` — units that hold the GPU and
  are stopped while the VM runs (default `[]`).
- `windows-vm.ivrsOverride` + `ivrsDump` — for boards whose firmware ships
  IVMD exclusion ranges (kernel 7 then refuses VFIO for the affected buses).
  The dump is board-specific and stays in the consuming repo:
  `sudo cp /sys/firmware/acpi/tables/IVRS ivrs-orig`.
- `windows-vm.amdIommu` / `gpuFlrWorkaround` — add `amd_iommu=on` /
  `vfio_pci.disable_idle_d3=1` (RTX 5090 FLR defect). Both default off.

Other options: `passAudio`, `evdevDevices`, `evdevGrabToggle` (qemu combos or
an evsieve-translated chord), `maxResolution` (sizes kvmfr), `lgSpiceInput`,
`virtualConsole`, `gpuHandover`, `viewerPackage` (Looking Glass client
package used by `win-vm viewer` — override with a desktop-specific wrapper).

`services.win-sync` (win-sync module) copies a built Windows config folder
(`windowsConfigurations.<host>.config.build.folder`) to
`ProgramData\machine-config` on the Windows partition (`sudo win-sync`).

## Desktop integration

Everything assuming a particular desktop (Looking Glass client config, GNOME
shell helpers, tiler float entries, home-manager wiring) is deliberately NOT
in this module. The nixos repo carries a companion overlay
(`nixos/windows-vm-desktop.nix`) for GNOME Wayland; other hosts bring their
own or run headless with `virtualConsole` / SPICE.

## Firmware prerequisites (not settable from Nix)

Integrated graphics enabled and primary, SVM/IOMMU + Above-4G decoding on,
Resizable BAR on (if the guest shows Code 43/12, turn ReBAR off). Host monitor
on the iGPU output.

## Checks

`checks.x86_64-linux.win-vm` (unit tests for the launcher) and
`.win-sync` (NixOS VM test for the shared disk rules). Run with
`nix build .#checks.x86_64-linux.win-sync -L`.
