# Applies the machine-config folder. Windows PowerShell 5.1 syntax only.
# Contract: windows-nix/README.md. Launched by apply.cmd (elevated).
[CmdletBinding()]
param(
    # Empty = this script's folder ($PSScriptRoot is unset in param defaults
    # under powershell.exe -File in 5.1).
    [string]$Root = '',
    [ValidateSet('', 'vm', 'metal')]
    [string]$Platform = '',
    # 0 = read from the registry; tests pass 19045/22000.
    [int]$Build = 0,
    # Log what each step would do; run no native command and change nothing.
    [switch]$DryRun,
    # Restart only after a successful run whose steps request a reboot.
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$TaskName = 'MachineConfigStartup'
$ShortcutName = 'Apply machine config.lnk'

function Get-LogPath {
    param([string]$Root)
    $name = 'apply-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)
    $dir = Join-Path $Root 'logs'
    try {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        $probe = Join-Path $dir '.write-test'
        Set-Content -LiteralPath $probe -Value '' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force
        return (Join-Path $dir $name)
    }
    catch {
        # Read-only root (the ISO): log next to the persistent copy instead.
        return (Join-Path (Join-Path $script:MachineConfigDir 'logs') $name)
    }
}

function Invoke-Effect {
    param([string]$What, [scriptblock]$Do)
    if ($DryRun) { Write-StepLog $ctx "  dry-run: $What"; return }
    & $Do
}

# Non-WHQL driver packages (e.g. Virtual Display Driver, signed via SignPath)
# fail installation with 0xE0000242 ("publisher not established as trusted")
# unless the catalog signer is in TrustedPublisher and its chain root is
# trusted. Import them from the package's own .cat before installing; this
# trusts only signers of packages the config explicitly installs.
function Trust-DriverSigner {
    param([string]$InfPath)
    if (Test-Path -LiteralPath $InfPath -PathType Container) {
        $infs = @(Get-ChildItem -LiteralPath $InfPath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
    } else {
        $infs = @(Get-Item -LiteralPath $InfPath)
    }
    foreach ($inf in $infs) {
        $cat = [IO.Path]::ChangeExtension($inf.FullName, '.cat')
        if (-not (Test-Path -LiteralPath $cat)) { continue }
        $leaf = (Get-AuthenticodeSignature -LiteralPath $cat).SignerCertificate
        if (-not $leaf) { continue }
        if (Test-Path -LiteralPath ("Cert:\LocalMachine\TrustedPublisher\" + $leaf.Thumbprint)) { continue }
        Invoke-Effect "trust driver signer $($leaf.Subject)" {
            $cer = Join-Path ([IO.Path]::GetTempPath()) ("machine-config-signer-" + $leaf.Thumbprint + ".cer")
            [IO.File]::WriteAllBytes($cer, $leaf.Export('Cer'))
            try {
                Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
                $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                $null = $chain.Build($leaf)
                $els = @($chain.ChainElements)
                if ($els.Count -gt 0) {
                    [IO.File]::WriteAllBytes($cer, $els[$els.Count - 1].Certificate.Export('Cer'))
                    Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
                    for ($j = 1; $j -lt $els.Count - 1; $j++) {
                        [IO.File]::WriteAllBytes($cer, $els[$j].Certificate.Export('Cer'))
                        Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\CA' | Out-Null
                    }
                }
            }
            finally { Remove-Item -LiteralPath $cer -Force -ErrorAction SilentlyContinue }
        }
    }
}

# devcon-equivalent install for root-enumerated drivers (VDD's Driver.Only
# zip has no installer; pnputil /install creates no device on its own).
# Create + register the devnode, then UpdateDriverForPlugAndPlayDevices —
# the same call devcon uses (DiInstallDevice rejects the fresh devinfo).
function Install-RootDevice {
    param([string]$InfPath, [string]$HardwareId, [string]$ItemId)
    $short = $HardwareId -replace '^Root\\', ''
    if (Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match [regex]::Escape($short) }) {
        Write-StepLog $ctx "  root device $HardwareId already present"
        return
    }
    $infFile = $InfPath
    if (Test-Path -LiteralPath $InfPath -PathType Container) {
        $infFile = (Get-ChildItem -LiteralPath $InfPath -Filter '*.inf' -Recurse | Select-Object -First 1).FullName
    }
    $m = Select-String -LiteralPath $infFile -Pattern 'ClassGUID\s*=\s*\{([0-9A-Fa-f-]+)\}' | Select-Object -First 1
    $classGuid = [Guid]$m.Matches[0].Groups[1].Value
    if (-not ('McSetupApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public struct McDevInfo {
    public int cbSize;
    public Guid ClassGuid;
    public int DevInst;
    public IntPtr Reserved;
}
public static class McSetupApi {
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SetupDiCreateDeviceInfo(IntPtr DeviceInfoSet, string DeviceName, ref Guid ClassGuid, string DeviceDescription, IntPtr hwndParent, int CreationFlags, ref McDevInfo DeviceInfoData);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SetupDiSetDeviceRegistryProperty(IntPtr DeviceInfoSet, ref McDevInfo DeviceInfoData, int Property, byte[] PropertyBuffer, int PropertyBufferSize);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SetupDiCallClassInstaller(int InstallFunction, IntPtr DeviceInfoSet, ref McDevInfo DeviceInfoData);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);
}
public static class McNewDev {
    [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwndParent, string HardwareId, string FullInfPath, uint InstallFlags, ref bool NeedReboot);
}
'@
    }
    Invoke-Effect "create root device $HardwareId" {
        $set = [McSetupApi]::SetupDiCreateDeviceInfoList([ref]$classGuid, [IntPtr]::Zero)
        if ($set -eq [IntPtr]::Zero -or $set -eq [IntPtr]::new(-1)) { throw 'SetupDiCreateDeviceInfoList failed' }
        try {
            $dev = New-Object McDevInfo
            $dev.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($dev)
            if (-not [McSetupApi]::SetupDiCreateDeviceInfo($set, $short, [ref]$classGuid, $null, [IntPtr]::Zero, 0x1, [ref]$dev)) {
                throw "SetupDiCreateDeviceInfo: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            $hwid = [Text.Encoding]::Unicode.GetBytes($HardwareId + "`0`0")
            if (-not [McSetupApi]::SetupDiSetDeviceRegistryProperty($set, [ref]$dev, 0x1, $hwid, $hwid.Length)) {
                throw "SetupDiSetDeviceRegistryProperty: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            if (-not [McSetupApi]::SetupDiCallClassInstaller(0x19, $set, [ref]$dev)) {
                throw "DIF_REGISTERDEVICE: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            $reboot = $false
            if (-not [McNewDev]::UpdateDriverForPlugAndPlayDevices([IntPtr]::Zero, $HardwareId, $infFile, 1, [ref]$reboot)) {
                throw "UpdateDriverForPlugAndPlayDevices: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        }
        finally { [McSetupApi]::SetupDiDestroyDeviceInfoList($set) | Out-Null }
    }
}

function Install-Item {
    param($Item, [string]$File)
    $kind = Get-ItemField $Item 'kind' 'installer'
    switch ($kind) {
        'installer' {
            $a = [string](Get-ItemField $Item 'silentArgs' '')
            Invoke-Effect "$File $a" { Invoke-Process $File $a }
        }
        'msi' {
            # msiexec is a GUI-subsystem exe: & would not wait for it.
            $a = '/i "{0}" /qn /norestart' -f $File
            Invoke-Effect "msiexec.exe $a" { Invoke-Process 'msiexec.exe' $a }
        }
        'zip' {
            $nested = Get-ItemField $Item 'nestedFile' $null
            if ($nested) {
                # Zipped installer: extract to temp, run the inner exe.
                $tmp = Join-Path ([IO.Path]::GetTempPath()) ("machine-config-" + $Item.id)
                $exe = Join-Path $tmp $nested
                $a = [string](Get-ItemField $Item 'silentArgs' '')
                Invoke-Effect "Expand-Archive $File -> $tmp; $exe $a" {
                    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
                    Expand-Archive -LiteralPath $File -DestinationPath $tmp -Force
                    try { Invoke-Process $exe $a }
                    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
                }
                break
            }
            $to = Get-ItemField $Item 'extractTo' $null
            if (-not $to) { throw "zip item $($Item.id) has neither extractTo nor nestedFile" }
            Invoke-Effect "Expand-Archive $File -> $to" {
                Expand-Archive -LiteralPath $File -DestinationPath $to -Force
            }
        }
        'msix' {
            Invoke-Effect "Add-AppxProvisionedPackage $File" {
                Add-AppxProvisionedPackage -Online -PackagePath $File -SkipLicense | Out-Null
            }
        }
        'driver' {
            $infPath = $File
            if ([IO.Path]::GetExtension($File) -ieq '.zip') {
                # Zipped driver package (e.g. VDD Driver.Only): extract, then
                # install from the folder (pnputil takes folder\*.inf /subdirs).
                $to = Get-ItemField $Item 'extractTo' $null
                if (-not $to) { throw "driver item $($Item.id) from a zip needs extractTo" }
                Invoke-Effect "Expand-Archive $File -> $to" {
                    Expand-Archive -LiteralPath $File -DestinationPath $to -Force
                }
                $infPath = $to
            }
            Trust-DriverSigner $infPath
            $rootDev = Get-ItemField $Item 'rootDevice' $null
            if ($rootDev) {
                Install-RootDevice -InfPath $infPath -HardwareId $rootDev -ItemId $Item.id
                break
            }
            $pa = @('/add-driver', $infPath, '/install')
            if ((Test-Path -LiteralPath $infPath -PathType Container)) {
                $pa = @('/add-driver', (Join-Path $infPath '*.inf'), '/subdirs', '/install')
            }
            # 259: nothing to add/install (already staged or no matching device).
            Invoke-Effect "pnputil $($pa -join ' ')" { Invoke-Native 'pnputil.exe' $pa -OkCodes @(0, 259) }
        }
        default { throw "unknown kind '$kind'" }
    }
}

function Register-StartupTask {
    param([string]$Script)
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Script
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        $a = @($existing.Actions)[0]
        $atStartup = @($existing.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count -gt 0
        # UserId is localised (СИСТЕМА on ru-RU), so compare the SID, not the name.
        $isSystem = ([Security.Principal.NTAccount]$existing.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-18'
        if ($a.Execute -eq 'powershell.exe' -and $a.Arguments -eq $argLine -and $atStartup -and $isSystem) {
            return (New-StepSkip 'already registered')
        }
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
}

function New-DesktopShortcut {
    param([string]$Target)
    $lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) $ShortcutName
    $shell = New-Object -ComObject WScript.Shell
    if ((Test-Path -LiteralPath $lnk) -and $shell.CreateShortcut($lnk).TargetPath -ieq $Target) {
        return (New-StepSkip 'already present')
    }
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = $Target
    $s.WorkingDirectory = Split-Path -Parent $Target
    $s.Save()
}

# tools\<Dir>\<ZipGlob> -> temp dir; returns the path of <File> found inside,
# or $null if the zip is absent. Temp, not system state, so -DryRun does it too.
function Expand-Tool {
    param([string]$Dir, [string]$ZipGlob, [string]$File)
    $zip = Get-ChildItem -Path (Join-Path (Join-Path $Root 'tools') $Dir) -Filter $ZipGlob -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $zip) { return $null }
    $dest = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'machine-config-tools') $Dir
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $dest -Force
    # The release zips nest a versioned top folder (Win11Debloat-<ver>\).
    $hit = Get-ChildItem -Path $dest -Filter $File -File -Recurse | Select-Object -First 1
    if ($null -eq $hit) { throw "$File not found in $($zip.Name)" }
    return $hit.FullName
}

# Marker under MachineConfigDir holding the fingerprint of a step's inputs, for
# steps whose effect can't be queried back.
function Test-Marker {
    param([string]$Name, [string]$Value)
    $p = Join-Path $script:MachineConfigDir $Name
    (Test-Path -LiteralPath $p) -and ((Get-Content -LiteralPath $p -Raw).Trim() -eq $Value)
}
function Set-Marker {
    param([string]$Name, [string]$Value)
    Invoke-Effect "write marker $Name" {
        New-Item -ItemType Directory -Path $script:MachineConfigDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:MachineConfigDir $Name) -Value $Value
    }
}

function Resolve-FileRoot {
    param([string]$Root)
    switch ($Root) {
        'LocalAppData' { [Environment]::GetFolderPath('LocalApplicationData') }
        'RoamingAppData' { [Environment]::GetFolderPath('ApplicationData') }
        'ProgramData' { [Environment]::GetFolderPath('CommonApplicationData') }
        'ProgramFiles' { [Environment]::GetFolderPath('ProgramFiles') }
        'ProgramFilesX86' { [Environment]::GetFolderPath('ProgramFilesX86') }
        'UserProfile' { [Environment]::GetFolderPath('UserProfile') }
        default { throw "unknown file root '$Root'" }
    }
}

# Starts $Exe as the interactive user, unelevated, in their session: apply runs
# elevated and often over ssh (session 0), where Start-Process would start the
# app invisibly or as admin. No one logged on: the app starts at next logon.
function Start-InUserSession {
    param([string]$Exe, [string]$Arguments)
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $user) { return (New-StepSkip 'no interactive user; starts at next logon') }
    $name = 'MachineConfigRestart-' + [guid]::NewGuid().ToString('N')
    $a = if ($Arguments) { New-ScheduledTaskAction -Execute $Exe -Argument $Arguments } else { New-ScheduledTaskAction -Execute $Exe }
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
    Register-ScheduledTask -TaskName $name -Action $a -Principal $p -Force | Out-Null
    try { Start-ScheduledTask -TaskName $name; Start-Sleep -Seconds 2 }
    finally { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
}

# Applies one machine.json file entry; stopped holders are queued in $restart.
function Set-DeclaredFile {
    param($Entry)
    foreach ($r in @($Entry.requires)) {
        if ($r -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($r)))) {
            return (New-StepSkip "requires $r")
        }
    }
    $path = Join-Path (Resolve-FileRoot $Entry.root) $Entry.path
    $current = $null
    if (Test-Path -LiteralPath $path) { $current = [IO.File]::ReadAllText($path) }
    $text = Get-FileUpdate $Entry $current
    if ($null -eq $text) { return (New-StepSkip 'unchanged') }
    $stopped = @()
    foreach ($h in @($Entry.holders)) {
        if (-not $h) { continue }
        foreach ($proc in @(Get-Process -Name $h.process -ErrorAction SilentlyContinue)) {
            $exe = if ($h.start) { [Environment]::ExpandEnvironmentVariables($h.start) } else { $proc.Path }
            Invoke-Effect "stop $($h.process) ($($proc.Id))" { Stop-Process -Id $proc.Id -Force; $proc.WaitForExit(10000) | Out-Null }
            $stopped += [pscustomobject]@{ Exe = $exe; Args = [string]$h.args }
        }
    }
    Invoke-Effect "write $path" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $text)
    }
    # Unique by exe+args: a holder of several files restarts once.
    foreach ($s in $stopped) {
        $k = "$($s.Exe)|$($s.Args)"
        if (-not $script:restart.Contains($k)) { $script:restart[$k] = $s }
    }
}

# PSDSC 1.1 reaches its resources through local WinRM. Starts the service with
# listeners on loopback only; $winrmSaved holds what Restore-WinRM needs. Listeners
# are stored under the WSMAN registry key.
$WsmanListenerKey = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Listener'
function Start-LoopbackWinRM {
    $saved = [pscustomobject]@{
        StartType = (Get-Service WinRM).StartType
        Reg       = Join-Path ([IO.Path]::GetTempPath()) 'machine-config-wsman-listener.reg'
    }
    # 1: no listener key, nothing to restore.
    Invoke-Native 'reg.exe' @('export', $WsmanListenerKey, $saved.Reg, '/y') -OkCodes @(0, 1)
    # Recorded before any change, so a failure below still gets restored.
    $script:winrmSaved = $saved
    if ($saved.StartType -eq 'Disabled') { Set-Service WinRM -StartupType Manual }
    Start-Service WinRM
    Get-ChildItem WSMan:\localhost\Listener | Remove-Item -Recurse -Force
    foreach ($a in 'IP:127.0.0.1', 'IP:::1') {
        New-Item -Path WSMan:\localhost\Listener -Address $a -Transport HTTP -Force | Out-Null
    }
}
function Restore-WinRM {
    param($Saved)
    Stop-Service WinRM -Force
    Invoke-Native 'reg.exe' @('delete', $WsmanListenerKey, '/f') -OkCodes @(0, 1)
    if (Test-Path -LiteralPath $Saved.Reg) {
        Invoke-Native 'reg.exe' @('import', $Saved.Reg)
        Remove-Item -LiteralPath $Saved.Reg -Force
    }
    if ($Saved.StartType -eq 'Disabled') { Set-Service WinRM -StartupType Disabled }
}

# --- main ---------------------------------------------------------------------

if (-not $Root) { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $DryRun -and $onWindows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        [Console]::Error.WriteLine('machine-config: apply requires an elevated administrator token; run apply.cmd')
        exit 2
    }
}
try { $applyMutex = Enter-ApplyMutex }
catch {
    [Console]::Error.WriteLine("machine-config: cannot create the apply mutex: $($_.Exception.Message)")
    exit 2
}
if ($null -eq $applyMutex) {
    [Console]::Error.WriteLine('machine-config: another apply is already running; wait for it to finish')
    exit 2
}
$ctx = New-ApplyContext (Get-LogPath $Root)
if (-not $Platform) { $Platform = Get-Platform }
if ($Build -le 0) { $Build = Get-WindowsBuild }
$dryNote = ''
if ($DryRun) { $dryNote = ' (dry run)' }
Write-StepLog $ctx "machine-config apply: root=$Root platform=$Platform build=$Build$dryNote"

function Read-JsonFile {
    param([string]$Name)
    # Assign first: in 5.1 ConvertFrom-Json emits a JSON array as ONE object,
    # so @(... | ConvertFrom-Json) would nest it.
    $parsed = Get-Content -LiteralPath (Join-Path $Root $Name) -Raw | ConvertFrom-Json
    return $parsed
}
$items = @()
$machine = [pscustomobject]@{ files = @(); manualSteps = @() }
Invoke-Step $ctx 'read items.json, machine.json' {
    $script:items = @(Read-JsonFile 'items.json')
    $script:machine = Read-JsonFile 'machine.json'
}

Invoke-Step $ctx 'drivers: stage drivers\vm' {
    $dir = Join-Path $Root 'drivers\vm'
    if (-not (Test-Path -LiteralPath $dir)) { return (New-StepSkip 'drivers\vm missing') }
    $fp = Get-Fingerprint $dir (Get-ChildItem -LiteralPath $dir -Recurse -File)
    # The marker doubles as win-vm's "virtio drivers staged" check.
    if (Test-Marker 'virtio-staged' $fp) { return (New-StepSkip 'already staged') }
    $pa = @('/add-driver', (Join-Path $dir '*.inf'), '/subdirs', '/install')
    Invoke-Effect "pnputil $($pa -join ' ')" { Invoke-Native 'pnputil.exe' $pa -OkCodes @(0, 259) }
    Set-Marker 'virtio-staged' $fp
}

Invoke-Step $ctx 'debloat: Win11Debloat' {
    $toolDir = Join-Path (Join-Path $Root 'tools') 'Win11Debloat'
    $list = Join-Path $toolDir 'switches.txt'
    if (-not (Test-Path -LiteralPath $list)) { return (New-StepSkip 'no switches declared') }
    # Re-run only when the release or the switch list changes.
    $fp = Get-Fingerprint $toolDir (Get-ChildItem -LiteralPath $toolDir -File)
    if (Test-Marker 'debloat-applied' $fp) { return (New-StepSkip 'already applied') }
    $ps1 = Expand-Tool 'Win11Debloat' 'Win11Debloat*.zip' 'Win11Debloat.ps1'
    if ($null -eq $ps1) { return (New-StepSkip 'tools\Win11Debloat\*.zip missing') }
    $switches = @(Get-Content -LiteralPath $list | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    # Windows PowerShell 5.1 child, not pwsh (Win11Debloat exits 1 under Core),
    # and a child at all because it may call exit.
    $pa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1, '-Silent') + $switches
    Invoke-Effect "powershell $($pa -join ' ')" { Invoke-Native 'powershell.exe' $pa }
    Set-Marker 'debloat-applied' $fp
}

$dscExe = $null
Invoke-Step $ctx 'dsc: unpack' {
    $script:dscExe = Expand-Tool 'dsc' 'DSC-*-x86_64-pc-windows-msvc.zip' 'dsc.exe'
    if ($null -eq $script:dscExe) { throw 'tools\dsc\DSC-*-x86_64-pc-windows-msvc.zip missing' }
}
# tools\psmodules\<Name>\<Version>.zip: PSDSC 1.1 only finds machine-scope modules.
foreach ($zip in @(Get-ChildItem -Path (Join-Path (Join-Path $Root 'tools') 'psmodules') -Filter *.zip -File -Recurse -ErrorAction SilentlyContinue)) {
    $modName = $zip.Directory.Name
    $modVersion = $zip.BaseName
    Invoke-Step $ctx "psmodule: $modName $modVersion" {
        $dest = [IO.Path]::Combine([Environment]::GetFolderPath('ProgramFiles'), "WindowsPowerShell\Modules\$modName\$modVersion")
        if (Test-Path -LiteralPath (Join-Path $dest "$modName.psd1")) { return (New-StepSkip 'already installed') }
        Invoke-Effect "Expand-Archive $($zip.FullName) -> $dest" {
            Expand-Archive -LiteralPath $zip.FullName -DestinationPath $dest -Force
            # NuGet packaging, not module content.
            foreach ($n in '_rels', 'package', '[Content_Types].xml', "$modName.nuspec") {
                Remove-Item -LiteralPath (Join-Path $dest $n) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
$winrmSaved = $null
if (Get-ItemField $machine 'dscWinRM' $false) {
    Invoke-Step $ctx 'dsc: winrm up' {
        if (-not $DryRun -and (Get-Service WinRM).Status -eq 'Running') { return (New-StepSkip 'already running') }
        Invoke-Effect 'start WinRM with loopback-only listeners' { Start-LoopbackWinRM }
    }
}
foreach ($cfgName in 'config.dsc.yaml', 'config.win11.dsc.yaml') {
    Invoke-Step $ctx "dsc: $cfgName" {
        if ($cfgName -eq 'config.win11.dsc.yaml' -and $Build -lt 22000) {
            return (New-StepSkip "needs build 22000, have $Build")
        }
        $cfg = Join-Path $Root $cfgName
        if (-not (Test-Path -LiteralPath $cfg)) { return (New-StepSkip "$cfgName missing") }
        if ($null -eq $dscExe) { throw 'dsc.exe unavailable' }
        # test first, so a converged machine reports skipped instead of ok.
        if (-not $DryRun) {
            $out = & $dscExe -l error config test -o json --file $cfg 2>$null
            if ($LASTEXITCODE -eq 0) {
                $res = @((($out | Out-String) | ConvertFrom-Json).results)
                $drift = @($res | Where-Object { -not $_.result.inDesiredState } | ForEach-Object { $_.name })
                if ($drift.Count -eq 0) { return (New-StepSkip "in desired state ($($res.Count) resources)") }
                Write-StepLog $ctx ("  drift: " + ($drift -join '; '))
            }
            $global:LASTEXITCODE = 0
        }
        $pa = @('config', 'set', '--file', $cfg)
        Invoke-Effect "dsc $($pa -join ' ')" { Invoke-Native $dscExe $pa }
    }
}
if ($winrmSaved) {
    Invoke-Step $ctx 'dsc: winrm restore' { Restore-WinRM $winrmSaved }
}

$entries = @(Get-UninstallEntries)
foreach ($item in $items) {
    Invoke-Step $ctx "install: $($item.id)" {
        $reason = Test-ItemApplies $item $Platform $Build
        if ($reason) { return (New-StepSkip $reason) }
        $have = Test-Installed $item $entries
        if ($have) { return (New-StepSkip "already $have") }
        $file = Join-Path $Root ([string](Get-ItemField $item 'file' ''))
        if (-not (Test-Path -LiteralPath $file)) {
            # Thin deploy: the folder carries no installer blobs; fetch only
            # the items that are actually missing, at their pinned url+hash.
            $url = Get-ItemField $item 'url' $null
            $pinHash = Get-ItemField $item 'sha256' $null
            if (-not $url -or -not $pinHash) { throw "missing $file (no pinned url in items.json)" }
            Write-StepLog $ctx "  download: $url"
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
                $tmpFile = "$file.partial"
                try {
                    Invoke-WebRequest -Uri $url -OutFile $tmpFile -UseBasicParsing
                    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($tmpFile))
                    $hex = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
                    $sri = 'sha256-' + [Convert]::ToBase64String($bytes)
                    if ($pinHash -ine $hex -and $pinHash -ine $sri) {
                        throw "hash mismatch for $($item.id): got $hex, want $pinHash"
                    }
                    Move-Item $tmpFile $file -Force
                }
                finally { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        }
        Install-Item $item $file
    }
}

# Per-user files are those of the account running apply (one local admin).
$restart = [ordered]@{}
foreach ($f in @($machine.files)) {
    if (-not $f) { continue }
    Invoke-Step $ctx "file: $($f.name)" {
        $min = [int](Get-ItemField $f 'minBuild' 0)
        if ($Build -lt $min) { return (New-StepSkip "needs build $min, have $Build") }
        Set-DeclaredFile $f
    }
}
foreach ($s in $restart.Values) {
    $stepName = ("restart: {0} {1}" -f (Split-Path -Leaf $s.Exe), $s.Args).TrimEnd()
    Invoke-Step $ctx $stepName {
        Invoke-Effect "start $($s.Exe) $($s.Args) in the user session" { Start-InUserSession $s.Exe $s.Args }
    }
}

# engine: the boot task runs from a persistent copy so it outlives the ISO/folder.
$startupCopy = Join-Path $script:MachineConfigDir 'startup.ps1'
Invoke-Step $ctx 'engine: copy startup.ps1, common.ps1, startup.json' {
    $changed = 0
    foreach ($f in 'startup.ps1', 'common.ps1', 'startup.json') {
        $src = Join-Path $Root $f
        $dst = Join-Path $script:MachineConfigDir $f
        if ($src -ieq $dst) { continue }
        if ((Test-Path -LiteralPath $dst) -and
            (Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash) { continue }
        $changed++
        Invoke-Effect "copy $f -> $dst" {
            New-Item -ItemType Directory -Path $script:MachineConfigDir -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    if ($changed -eq 0) { return (New-StepSkip 'unchanged') }
}
Invoke-Step $ctx "engine: scheduled task $TaskName" {
    Invoke-Effect "register $TaskName (SYSTEM, at startup) -> $startupCopy" { Register-StartupTask $startupCopy }
}
Invoke-Step $ctx 'engine: desktop shortcut' {
    $target = Join-Path $Root 'apply.cmd'
    Invoke-Effect "shortcut '$ShortcutName' -> $target" { New-DesktopShortcut $target }
}

# summary
$summary = Get-Summary $ctx
Write-StepLog $ctx ("summary:`r`n" + $summary.Table.TrimEnd())
$manual = @(foreach ($m in @($machine.manualSteps)) {
        if (-not $m) { continue }
        $below = Get-ItemField $m 'belowBuild' $null
        if ($null -eq $below -or $Build -lt [int]$below) { $m.text }
    })
if ($manual.Count -gt 0) {
    Write-StepLog $ctx ("manual steps:`r`n" + (($manual | ForEach-Object { "  - $_" }) -join "`r`n"))
}
# 'read ...', 'dsc: unpack' and the WinRM bracket leave the machine as it was.
$changedSteps = @($ctx.Results | Where-Object { $_.Status -eq 'ok' -and $_.Step -notlike 'read *' -and $_.Step -ne 'dsc: unpack' -and $_.Step -notlike 'dsc: winrm *' }).Count
Write-StepLog $ctx "changed: $changedSteps"
if ($summary.Reboot) { Write-StepLog $ctx 'a reboot is required to finish' }
if ($summary.Failed.Count -gt 0) { Write-StepLog $ctx ('failed: ' + ($summary.Failed -join ', ')) }
$restart = Test-ShouldReboot $summary ([bool]$Reboot)
if ($restart) { Write-StepLog $ctx 'reboot requested: restarting after releasing the apply lock' }
elseif ($Reboot -and $summary.Reboot -and $summary.Failed.Count -gt 0) { Write-StepLog $ctx 'not rebooting because the run failed' }
Write-StepLog $ctx "log: $($ctx.LogPath)"
$applyMutex.ReleaseMutex()
$applyMutex.Dispose()
if ($restart -and -not $DryRun) { Restart-Computer -Force }
exit $summary.ExitCode
