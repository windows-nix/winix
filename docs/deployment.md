# Deployment guide

## Delivery models

`windows-deploy` copies a built folder to Windows, verifies existing content by
SHA-256, and optionally invokes apply. It never builds the Nix configuration on
Windows. Choose a transport and an ownership mode independently:

- SSH: manage a remote Windows machine or a local Windows target through its
  OpenSSH server.
- WSL: manage the Windows host of the current WSL instance through
  `powershell.exe` and `tar.exe`; no SSH server is required.
- `merge`: preserve unmanaged files in the delivered folder (default).
- `enforce`: prune unmanaged payload files after a successful transfer.

Configuration CD and dual-boot copying remain alternatives for machines without
a network delivery path.

## Command reference

```text
windows-deploy [OPTIONS] <folder> [-- <apply arguments>]

-t, --transport auto|ssh|wsl
-H, --host DESTINATION
-d, --dir WINDOWS_PATH
-m, --mode merge|enforce
    --apply
-h, --help
```

Environment equivalents:

- `WINDOWS_TRANSPORT`: `auto`, `ssh`, or `wsl`.
- `WINDOWS_HOST`: SSH destination accepted by OpenSSH, including an SSH config
  alias or `user@host`.
- `WINDOWS_DIR`: target, default `C:\ProgramData\machine-config`.
- `WINDOWS_MODE`: `merge` or `enforce`.

`auto` chooses SSH if a host is set, then WSL if `WSL_INTEROP`,
`WSL_DISTRO_NAME`, or the kernel release identifies WSL. Otherwise it fails
before contacting a target and explains the required selection.

The source must be a complete `build.folder` or `build.folderThin` output. The
target must be a non-root absolute Windows path. Quotes, `%`, newlines, and
single quotes are rejected in target paths to keep command transport
unambiguous. The standard default needs no special configuration.

Synchronization is the default. `--apply` runs `apply.cmd` only after successful
delivery. Put apply arguments after `--`:

```sh
windows-deploy --host windows.example ./result --apply -- -DryRun -Build 22631
windows-deploy --transport wsl ./result --apply -- -Platform vm -Reboot
```

The legacy `<folder> --apply -DryRun` form remains accepted. Do not put secrets
in apply arguments; process command lines are visible to other administrative
tools.

## SSH transport

### Prepare Windows once

Run elevated Windows PowerShell. These commands change the OpenSSH service and
firewall; review local policy before running them:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd
Get-NetFirewallRule -Name '*ssh*' | Where-Object Enabled -eq 'True'
```

If your Windows edition does not create a firewall rule automatically, add one
through your normal firewall policy. Restrict its remote addresses to the
management network; do not expose OpenSSH to the public internet.

Use key authentication. For accounts in the Administrators group, stock Windows
OpenSSH normally reads `C:\ProgramData\ssh\administrators_authorized_keys`
instead of the user's `.ssh/authorized_keys`. Install the public key there and
set ACLs so only SYSTEM and Administrators can modify it. Consult the Microsoft
OpenSSH key-management documentation for your Windows version and localized
installation.

Confirm noninteractive authentication and elevation:

```sh
ssh -o BatchMode=yes windows.example powershell.exe -NoProfile -Command \
  '[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()'
ssh -o BatchMode=yes windows.example net session
```

The second command succeeds in an elevated administrator session. Some SSH
account, UAC, or domain configurations yield a filtered token; fix that before
using `--apply`. Delivery uses `BatchMode=yes`, so a password or host-key prompt
is a failed deployment rather than an interactive surprise.

### Deploy

```sh
windows-deploy --transport ssh --host windows.example \
  --dir 'C:\ProgramData\machine-config' --mode merge ./result --apply
```

SSH options such as identity files, ports, proxy commands, and host-key aliases
belong in the local OpenSSH client configuration. The deployer does not disable
host-key checking or accept unknown host keys automatically.

## Same-host WSL transport

WSL interoperability is normally enabled. Verify:

```sh
command -v powershell.exe
command -v tar.exe
powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion'
```

If interop is disabled, enable `[interop] enabled=true` and
`appendWindowsPath=true` in `/etc/wsl.conf` using your normal NixOS/WSL
configuration, then restart WSL through your usual workflow. Restarting WSL can
terminate processes in every running distribution; schedule it accordingly.

```sh
windows-deploy --transport wsl --mode merge ./result --apply
```

The copy stays on the same Windows host: PowerShell hashes and commits files,
and `tar.exe` extracts the streamed archive. No network socket, SSH service, or
Windows credential is needed by the deployer.

`apply.cmd` is self-elevating. A non-elevated WSL invocation therefore presents
the normal Windows UAC prompt and waits for the elevated process. The elevated
console can own apply output; inspect the apply log afterward. A cancelled UAC
prompt or failed apply returns nonzero.

WSL interoperability does not bypass Windows access control. The Windows user
associated with `powershell.exe` must be able to write the target and elevate.

## Ownership modes in detail

Both modes hash source and target files and transfer only differences. Changed
files first go to `.deploy-incoming-<pid>` under the target. The archive must
finish successfully before files are copied into the live folder. Store symlinks
are dereferenced by tar.

### `merge`

- Creates target directories as needed.
- Copies new and changed source files.
- Leaves other target files and directories untouched.
- Suitable when Nix supplies a default configuration folder and an operator adds
  local payloads later.

### `enforce`

- Performs the same successful staged update.
- Compares the pre-transfer remote manifest with the complete source manifest.
- Deletes remote payload files absent from the source.
- Removes resulting empty, unprotected directories.
- Suitable when the built folder is authoritative and stray payloads should not
  survive.

Protected in both modes:

- `logs/` and its contents.
- `virtio-staged` and `debloat-applied` markers.
- `.apply.lock` if present.
- `.deploy-*` staging paths.

`enforce` is not a transaction or a machine-wide enforcement engine. A failure
during the final per-file commit can leave a partially updated folder; rerun the
same deployment to converge it. Apply is never invoked after a failed archive
transfer.

Most importantly, folder ownership does not determine Windows state ownership:

- Removing a package from Nix does not uninstall it.
- Removing a `files` declaration does not delete the application file.
- Removing registry/DSC declarations does not restore previous values.
- Manual application configuration remains unless a declaration or script owns
  it.

Use explicit removal resources as described in the operations guide.

## Full, thin, and offline delivery

### Full folder

`build.folder` includes every enabled installer and tool. Build it on a connected
Nix host, then deliver without target downloads:

```sh
nix build .#windows-config
windows-deploy --host windows.example ./result --apply
```

This is the preferred path for restricted networks and predictable offline
application. The target still needs network access only for resources or scripts
that explicitly use it.

### Thin folder

`build.folderThin` omits installer blobs. Its `items.json` contains each pinned
URL and SHA-256. Apply checks `detect` first and downloads only applicable,
missing installations; unrelated already-installed packages are not fetched.

```sh
nix build .#windows-config-thin
windows-deploy --host windows.example ./result --apply
```

A failed download or hash mismatch fails that package step. Other steps continue
and the final apply exit code is nonzero. Keep the full-folder path available
for isolated machines.

### Incremental sync and manual files

A no-change run transfers no archive, but `--apply` still runs so Windows drift
can be corrected. In merge mode, manually added payload files neither affect the
hash comparison nor get deleted. In enforce mode, expect them to be pruned.

## Config CD and first boot

`build.iso` is a non-bootable ISO 9660 + Joliet image labeled `MCONFIG`. Attach it
next to a Windows installation ISO. It contains the full folder and
`autounattend.xml`.

- VM variant: wipes disk 0, creates EFI/MSR/C/D, and loads virtio storage drivers
  from the config CD. Review disk numbering and data destruction before boot.
- Metal variant: selects the edition but leaves disk selection/partitioning to
  the operator.
- Setup creates the declared local administrator with an empty password and
  requires a password change at first logon.
- First logon copies the CD to `C:\ProgramData\machine-config` and runs
  `apply.cmd`.
- The generic Pro installation key selects an edition; it does not activate
  Windows and is not a private secret.

For an existing dual-boot system, a NixOS-specific sync service may mount the
Windows partition and copy the folder. That integration belongs to the consumer
repository, not the generic engine.

## Delivery troubleshooting

- `cannot auto-select a transport`: set `--host`, or run inside WSL with
  `--transport wsl`.
- `SSH transport needs --host`: set `WINDOWS_HOST` or `-H`.
- `powershell.exe is not on PATH`: repair WSL interop/Windows PATH.
- `source is not a complete build.folder`: pass the store output, not the host
  module directory.
- Permission denied during hashing/copy: check target ACLs and the elevated
  account.
- Apply fails only over SSH: verify `net session` and the unfiltered admin token.
- WSL apply does nothing until a Windows prompt is answered: check for UAC on
  the Windows desktop.
- A stale file survives enforce: verify it is not protected runtime state and
  rerun with the same target path.
- A transfer failed: fix connectivity/disk space and rerun. Apply was not called;
  unchanged hashes make the retry incremental.

See the operations guide for apply logs and phase-specific failures.
