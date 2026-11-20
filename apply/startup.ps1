# Runs at every boot as SYSTEM (task MachineConfigStartup, registered by
# apply.ps1 against the copy in C:\ProgramData\machine-config). Applies the
# per-platform actions declared in startup.json (option boot.actions).
# PowerShell 5.1 syntax.
[CmdletBinding()]
param(
    [ValidateSet('', 'vm', 'metal')]
    [string]$Platform = '',
    # Dot-source for tests: define the functions, change nothing.
    [switch]$NoRun
)

. (Join-Path $PSScriptRoot 'common.ps1')

# Pure: the ordered actions for a platform from startup.json entries
# ({kind,target,vm,metal}); a null value for the platform means no action.
function Get-StartupPlan {
    param($Actions, [string]$Platform)
    $plan = New-Object System.Collections.ArrayList
    foreach ($a in @($Actions)) {
        if (-not $a) { continue }
        $v = $a.PSObject.Properties[$Platform]
        if ($null -eq $v -or $null -eq $v.Value) { continue }
        [void]$plan.Add([pscustomobject]@{ Kind = $a.kind; Target = $a.target; Value = $v.Value })
    }
    return $plan
}

function Invoke-StartupAction {
    param($Action)
    switch ($Action.Kind) {
        'ServiceStartType' {
            if (-not (Get-Service -Name $Action.Target -ErrorAction SilentlyContinue)) {
                return (New-StepSkip "$($Action.Target) not installed")
            }
            # sc.exe, not Set-Service: 5.1's Set-Service has no 'system' start type.
            Invoke-Native 'sc.exe' @('config', $Action.Target, 'start=', $Action.Value)
        }
        'PnpDevice' {
            $devs = @(Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { @($_.HardwareID) -contains $Action.Target })
            if ($devs.Count -eq 0) { return (New-StepSkip "no '$($Action.Target)' device") }
            foreach ($d in $devs) {
                if ($Action.Value) { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false }
                else { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false }
            }
        }
        'Service' {
            $svc = Get-Service -DisplayName $Action.Target -ErrorAction SilentlyContinue
            if (-not $svc) { $svc = Get-Service -Name $Action.Target -ErrorAction SilentlyContinue }
            if (-not $svc) { return (New-StepSkip "$($Action.Target) not installed") }
            if ($Action.Value) {
                Set-Service -Name $svc.Name -StartupType Automatic
                Start-Service -Name $svc.Name
            }
            else {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc.Name -StartupType Disabled
            }
        }
        'MsiInterrupts' {
            $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -like "PCI\$($Action.Target)*" })
            if ($devs.Count -eq 0) { return (New-StepSkip "no $($Action.Target) PCI device") }
            foreach ($d in $devs) {
                $key = 'HKLM:\SYSTEM\CurrentControlSet\Enum\{0}\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties' -f $d.InstanceId
                if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
                New-ItemProperty -LiteralPath $key -Name 'MSISupported' -PropertyType DWord -Value 1 -Force | Out-Null
            }
        }
        default { throw "unknown action kind '$($Action.Kind)'" }
    }
}

if ($NoRun) { return }

$ErrorActionPreference = 'Stop'
$ctx = New-ApplyContext (Join-Path (Join-Path $script:MachineConfigDir 'logs') 'startup.log')
if (-not $Platform) { $Platform = Get-Platform }
Write-StepLog $ctx "startup: platform=$Platform"
$parsed = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'startup.json') -Raw | ConvertFrom-Json
foreach ($a in (Get-StartupPlan $parsed $Platform)) {
    Invoke-Step $ctx ("{0} {1} -> {2}" -f $a.Kind, $a.Target, $a.Value) { Invoke-StartupAction $a }
}
exit (Get-Summary $ctx).ExitCode
