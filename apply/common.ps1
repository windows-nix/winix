# Shared by apply.ps1 and startup.ps1. Windows PowerShell 5.1 syntax only.
# Pure functions take their inputs as parameters so tests run on Linux pwsh;
# functions that touch Windows are named Get-*/Invoke-* and stay thin.

$programData = $env:ProgramData
# Unset off Windows (Linux pwsh tests): keep state under temp.
if (-not $programData) { $programData = [IO.Path]::GetTempPath() }
$script:MachineConfigDir = Join-Path $programData 'machine-config'
$script:RebootExitCodes = @(3010, 1641)

function Get-Platform {
    param(
        [bool]$HypervisorPresent,
        [string[]]$PciIds
    )
    if (-not $PSBoundParameters.ContainsKey('HypervisorPresent')) {
        $HypervisorPresent = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    }
    if (-not $PSBoundParameters.ContainsKey('PciIds')) {
        $PciIds = @(Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'PCI\\%'" |
            ForEach-Object { $_.PNPDeviceID })
    }
    # Hyper-V/VBS on metal also sets the hypervisor bit; the virtio PCI vendor
    # (1AF4) is what tells QEMU/KVM apart. SMBIOS is copied from the host.
    $virtio = @($PciIds | Where-Object { $_ -match 'VEN_1AF4' }).Count -gt 0
    if ($HypervisorPresent -and $virtio) { return 'vm' }
    return 'metal'
}

function Get-WindowsBuild {
    [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
}

function Get-ItemField {
    param($Item, [string]$Name, $Default)
    $p = $Item.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# Returns $null when the item applies, else the reason it is skipped.
function Test-ItemApplies {
    param($Item, [string]$Platform, [int]$Build)
    if (-not (Get-ItemField $Item 'enable' $true)) { return 'disabled' }
    $when = Get-ItemField $Item 'when' 'any'
    if ($when -ne 'any' -and $when -ne $Platform) { return "when=$when, platform=$Platform" }
    $min = [int](Get-ItemField $Item 'minBuild' 0)
    if ($Build -lt $min) { return "needs build $min, have $Build" }
    return $null
}

# -1/0/1 when both parse as [version]; otherwise 0 if the strings are equal,
# $null if they differ (no ordering known).
function Compare-Version {
    param([string]$A, [string]$B)
    $a1 = "$A".Trim() -replace '^[vV]', ''
    $b1 = "$B".Trim() -replace '^[vV]', ''
    $va = $null; $vb = $null
    if ([version]::TryParse($a1, [ref]$va) -and [version]::TryParse($b1, [ref]$vb)) {
        return $va.CompareTo($vb)
    }
    if ($a1 -ieq $b1) { return 0 }
    return $null
}

function Get-UninstallEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $roots) {
        Get-ItemProperty $r -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
            ForEach-Object {
                $ver = ''
                if ($_.PSObject.Properties['DisplayVersion']) { $ver = [string]$_.DisplayVersion }
                [pscustomobject]@{
                    DisplayName = [string]$_.DisplayName
                    DisplayVersion = $ver
                    ProductCode = [string]$_.PSChildName
                }
            }
    }
}

# Returns the installed version string (or 'present') when the pin is
# satisfied, else $null. A newer installed version counts: self-updating apps
# must not be downgraded to the bootstrap pin.
function Test-Installed {
    param($Item, $Entries)
    $detect = Get-ItemField $Item 'detect' $null
    if ($null -eq $detect) { return $null }
    $path = Get-ItemField $detect 'path' $null
    if ($path) {
        $path = [Environment]::ExpandEnvironmentVariables($path)
        if (Test-Path -LiteralPath $path) { return 'present' }
        return $null
    }
    $productCode = Get-ItemField $detect 'productCode' $null
    if ($productCode) {
        foreach ($e in @($Entries)) {
            $installedCode = [string](Get-ItemField $e 'ProductCode' '')
            if ($installedCode -and $installedCode.Trim('{', '}') -ieq $productCode.Trim('{', '}')) {
                if ($e.DisplayVersion) { return $e.DisplayVersion }
                return 'present'
            }
        }
        return $null
    }
    $appx = Get-ItemField $detect 'appx' $null
    if ($appx) {
        # Appx packages are not in the uninstall registry.
        if (Get-AppxPackage -AllUsers -Name $appx -ErrorAction SilentlyContinue) { return 'present' }
        return $null
    }
    $regex = Get-ItemField $detect 'displayName' $null
    if (-not $regex) { return $null }
    $pin = [string](Get-ItemField $Item 'version' '')
    foreach ($e in @($Entries)) {
        if ($e.DisplayName -notmatch $regex) { continue }
        # No version on either side: presence is the only signal left.
        if (-not $pin -or -not $e.DisplayVersion) { return 'present' }
        $c = Compare-Version $e.DisplayVersion $pin
        if ($null -ne $c -and $c -ge 0) { return $e.DisplayVersion }
    }
    return $null
}

function Enter-ApplyMutex {
    param([string]$Name = 'Global\MachineConfigApply')
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    }
    catch {
        $mutex.Dispose()
        throw
    }
    if (-not $acquired) { $mutex.Dispose(); return $null }
    return $mutex
}

function Test-ShouldReboot {
    param($Summary, [bool]$Requested)
    return $Requested -and $Summary.Reboot -and @($Summary.Failed).Count -eq 0
}

function New-ApplyContext {
    param([string]$LogPath)
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [pscustomobject]@{
        LogPath = $LogPath
        Results = New-Object System.Collections.ArrayList
    }
}

function Write-StepLog {
    param($Context, [string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Write-Host $line
    Add-Content -LiteralPath $Context.LogPath -Value $line
}

# A step's script block returns this to report "skipped" instead of "ok".
function New-StepSkip {
    param([string]$Reason)
    [pscustomobject]@{ PSTypeName = 'MachineConfig.StepSkip'; Reason = $Reason }
}

# Runs one native command; exit codes in -OkCodes are normalised to 0, reboot
# codes are kept so Invoke-Step can report them, anything else throws.
function Invoke-Native {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [int[]]$OkCodes = @(0))
    $out = & $FilePath @ArgumentList 2>&1
    $code = $LASTEXITCODE
    if ($null -ne $out) { $out | ForEach-Object { Write-Verbose "$_" } }
    if ($OkCodes -contains $code) { $global:LASTEXITCODE = 0; return }
    $global:LASTEXITCODE = $code
    if ($script:RebootExitCodes -notcontains $code) {
        throw "$FilePath exited with $code`: $(($out | Select-Object -Last 5) -join ' | ')"
    }
}

# Start-Process variant for installers: silentArgs is one string that must
# reach the exe verbatim (PS 5.1 re-quotes array elements containing spaces).
function Invoke-Process {
    param([string]$FilePath, [string]$Arguments, [int[]]$OkCodes = @(0))
    $sp = @{ FilePath = $FilePath; PassThru = $true }
    if ($Arguments) { $sp.ArgumentList = $Arguments }
    # Not -Wait: in PS 5.1 it also waits for every descendant, so an installer
    # that launches its app (System Informer, Apollo) hangs apply forever.
    $p = Start-Process @sp
    $null = $p.Handle # cache the handle, or ExitCode is null after exit
    $p.WaitForExit()
    $code = $p.ExitCode
    if ($OkCodes -contains $code) { $global:LASTEXITCODE = 0; return }
    $global:LASTEXITCODE = $code
    if ($script:RebootExitCodes -notcontains $code) { throw "$FilePath exited with $code" }
}

function Invoke-Step {
    param($Context, [string]$Name, [scriptblock]$Script)
    $status = 'ok'
    $detail = ''
    $global:LASTEXITCODE = 0
    try {
        $out = & $Script
        $code = $global:LASTEXITCODE
        $skip = @($out | Where-Object { $_ -and $_.PSObject.TypeNames -contains 'MachineConfig.StepSkip' })
        if ($script:RebootExitCodes -contains $code) {
            $detail = "reboot required ($code)"
        }
        elseif ($code -ne 0 -and $null -ne $code) {
            $status = 'failed'
            $detail = "exit code $code"
        }
        elseif ($skip.Count -gt 0) {
            $status = 'skipped'
            $detail = $skip[0].Reason
        }
    }
    catch {
        $status = 'failed'
        $detail = $_.Exception.Message
    }
    $global:LASTEXITCODE = 0
    [void]$Context.Results.Add([pscustomobject]@{ Step = $Name; Status = $status; Detail = $detail })
    Write-StepLog $Context ("[{0}] {1} {2}" -f $status, $Name, $detail)
}

function Get-Summary {
    param($Context)
    $failed = @($Context.Results | Where-Object { $_.Status -eq 'failed' } | ForEach-Object { $_.Step })
    $exitCode = 0
    if ($failed.Count -gt 0) { $exitCode = 1 }
    [pscustomobject]@{
        Table    = ($Context.Results | Format-Table Step, Status, Detail -AutoSize | Out-String -Width 200)
        Failed   = $failed
        Reboot   = @($Context.Results | Where-Object { $_.Detail -like 'reboot required*' }).Count -gt 0
        ExitCode = $exitCode
    }
}

# Sets key=value in [section] of INI text, adding the section or key if absent.
function Set-IniValue {
    param([string]$Text, [string]$Section, [string]$Key, [string]$Value)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Text) { $lines.AddRange([string[]]($Text -split "\r?\n")) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $header = "[$Section]"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq $header) { $start = $i; break } }
    if ($start -lt 0) {
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add($header); $lines.Add("$Key=$Value")
        return ($lines -join "`r`n") + "`r`n"
    }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { $end = $i; break } }
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $lines[$i] = "$Key=$Value"
            return ($lines -join "`r`n") + "`r`n"
        }
    }
    $lines.Insert($end, "$Key=$Value")
    return ($lines -join "`r`n") + "`r`n"
}

# Sets $Object.<path...> = $Value, creating intermediate objects.
function Set-JsonProperty {
    param($Object, [string[]]$Path, $Value)
    $cur = $Object
    for ($i = 0; $i -lt $Path.Count - 1; $i++) {
        $p = $cur.PSObject.Properties[$Path[$i]]
        if ($null -eq $p -or $null -eq $p.Value) {
            $cur | Add-Member -NotePropertyName $Path[$i] -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $cur = $cur.PSObject.Properties[$Path[$i]].Value
    }
    # Add-Member -Force on an existing property moves it to the end, so two steps
    # editing sibling keys would reorder the file on every run.
    $leaf = $cur.PSObject.Properties[$Path[-1]]
    if ($null -ne $leaf) { $leaf.Value = $Value }
    else { $cur | Add-Member -NotePropertyName $Path[-1] -NotePropertyValue $Value }
}

function Test-JsonObject { param($V) $V -is [System.Management.Automation.PSCustomObject] }

# Copy of parsed JSON data with %VAR% expanded in every string.
function Expand-EnvData {
    param($Data)
    if ($Data -is [string]) { return [Environment]::ExpandEnvironmentVariables($Data) }
    if (Test-JsonObject $Data) {
        $o = [pscustomobject]@{}
        foreach ($p in $Data.PSObject.Properties) {
            $o | Add-Member -NotePropertyName $p.Name -NotePropertyValue (Expand-EnvData $p.Value)
        }
        return $o
    }
    if ($Data -is [System.Collections.IList]) { return , @(foreach ($x in $Data) { Expand-EnvData $x }) }
    return $Data
}

# Merges $Data into $Target key by key; objects recurse, anything else replaces.
function Merge-JsonData {
    param($Target, $Data)
    foreach ($p in $Data.PSObject.Properties) {
        $cur = $Target.PSObject.Properties[$p.Name]
        if ((Test-JsonObject $p.Value) -and $null -ne $cur -and (Test-JsonObject $cur.Value)) {
            Merge-JsonData $cur.Value $p.Value
        }
        else { Set-JsonProperty $Target @($p.Name) $p.Value }
    }
}

# New text for a machine.json file entry, or $null when $Current (the file's
# text, $null if missing) already holds the declared state. JSON compares
# parsed values, so the app's own formatting never counts as drift.
function Get-FileUpdate {
    param($Entry, $Current)
    switch ($Entry.format) {
        'json' {
            $raw = $Current
            if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
            $obj = $raw | ConvertFrom-Json
            $before = $obj | ConvertTo-Json -Depth 32 -Compress
            Merge-JsonData $obj (Expand-EnvData $Entry.data)
            if ($null -ne $Current -and ($obj | ConvertTo-Json -Depth 32 -Compress) -ceq $before) { return $null }
            return ($obj | ConvertTo-Json -Depth 32)
        }
        'ini' {
            $text = [string]$Current
            foreach ($s in $Entry.data.PSObject.Properties) {
                foreach ($k in $s.Value.PSObject.Properties) {
                    $text = Set-IniValue $text $s.Name $k.Name ([Environment]::ExpandEnvironmentVariables($k.Value))
                }
            }
            if ($text -ceq $Current) { return $null }
            return $text
        }
        'text' {
            if ($Entry.data -ceq $Current) { return $null }
            return [string]$Entry.data
        }
        default { throw "unknown file format '$($Entry.format)'" }
    }
}

# SHA-256 over relative paths and contents: the input of a step whose effect
# can't be queried back (debloat, driver staging), recorded as a marker.
function Get-Fingerprint {
    param([string]$Base, $Files)
    $lines = @(@($Files) | Where-Object { $_ } | ForEach-Object {
            '{0} {1}' -f $_.FullName.Substring($Base.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        } | Sort-Object)
    $sha = [Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines -join "`n")))) -replace '-', ''
}
