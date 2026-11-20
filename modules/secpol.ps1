# Test/set helpers for `securityPolicy`, embedded verbatim into the generated
# DSC scripts by security.nix: DSC runs each script in a fresh Windows
# PowerShell 5.1 process, so nothing from the engine is loaded. The caller sets
# $Policy. Accounts are compared as SIDs because secedit exports some of them
# by localised name (Гость).

function ConvertTo-SidEntry {
    param([string]$Entry)
    $e = $Entry.Trim()
    if ($e.StartsWith('*')) { return $e.ToUpperInvariant() }
    if ($e -match '^S-1-') { return '*' + $e.ToUpperInvariant() }
    try { return '*' + ([Security.Principal.NTAccount]$e).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { return $e }
}

# Sorted, comma-joined SID set; $Value is a list or one "a,b" string.
function Get-SecRightSet {
    param($Value)
    $sids = @(@($Value) | ForEach-Object { "$_" -split ',' } | Where-Object { $_.Trim() } |
            ForEach-Object { ConvertTo-SidEntry $_ } | Sort-Object -Unique)
    $sids -join ','
}

# secedit INF lines -> @{ section = @{ key = raw value } }
function Read-SecInf {
    param([string[]]$Lines)
    $inf = @{}
    $section = ''
    foreach ($l in $Lines) {
        if ($l -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1]; $inf[$section] = @{}; continue }
        if ($section -and $l -match '^\s*([^=;]+?)\s*=\s*(.*?)\s*$') { $inf[$section][$Matches[1]] = $Matches[2] }
    }
    $inf
}

# Declared keys that differ from $Inf, as "Section/Key". Undeclared keys are ignored.
function Compare-SecPolicy {
    param($Policy, $Inf)
    $rights = $Inf['Privilege Rights']
    if ($null -eq $rights) { $rights = @{} }
    $access = $Inf['System Access']
    if ($null -eq $access) { $access = @{} }
    foreach ($p in @($Policy.userRights.PSObject.Properties)) {
        if ((Get-SecRightSet $p.Value) -ne (Get-SecRightSet $rights[$p.Name])) { "Privilege Rights/$($p.Name)" }
    }
    foreach ($p in @($Policy.account.PSObject.Properties)) {
        if ("$($p.Value)" -ne "$($access[$p.Name])".Trim('"')) { "System Access/$($p.Name)" }
    }
}

function New-SecInfLines {
    param($Policy)
    $l = @('[Unicode]', 'Unicode=yes')
    $acc = @($Policy.account.PSObject.Properties)
    if ($acc.Count -gt 0) {
        $l += '[System Access]'
        foreach ($p in $acc) {
            if ($p.Value -is [string]) { $l += ('{0} = "{1}"' -f $p.Name, $p.Value) } else { $l += ('{0} = {1}' -f $p.Name, $p.Value) }
        }
    }
    $ur = @($Policy.userRights.PSObject.Properties)
    if ($ur.Count -gt 0) {
        $l += '[Privilege Rights]'
        foreach ($p in $ur) { $l += ('{0} = {1}' -f $p.Name, (Get-SecRightSet $p.Value)) }
    }
    $l + @('[Version]', 'signature="$CHICAGO$"', 'Revision=1')
}

function Get-SecPolicyDrift {
    param($Policy)
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "machine-config-secpol-$PID.inf")
    try {
        secedit /export /areas SECURITYPOLICY USER_RIGHTS /cfg $tmp /quiet | Out-Null
        if ($LASTEXITCODE) { throw "secedit /export failed ($LASTEXITCODE)" }
        Compare-SecPolicy $Policy (Read-SecInf (Get-Content -LiteralPath $tmp -Encoding Unicode))
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Set-SecPolicy {
    param($Policy)
    $base = [IO.Path]::Combine([IO.Path]::GetTempPath(), "machine-config-secpol-$PID")
    $areas = @()
    if (@($Policy.account.PSObject.Properties).Count -gt 0) { $areas += 'SECURITYPOLICY' }
    if (@($Policy.userRights.PSObject.Properties).Count -gt 0) { $areas += 'USER_RIGHTS' }
    try {
        Set-Content -LiteralPath "$base.inf" -Value (New-SecInfLines $Policy) -Encoding Unicode
        # Fresh database: only the template's keys are applied, the rest stays.
        secedit /configure /db "$base.sdb" /cfg "$base.inf" /areas @areas /quiet | Out-Null
        if ($LASTEXITCODE) { throw "secedit /configure failed ($LASTEXITCODE); see %windir%\security\logs\scesrv.log" }
    }
    finally { Remove-Item -LiteralPath "$base.inf", "$base.sdb", "$base.jfm" -Force -ErrorAction SilentlyContinue }
}

function Get-AuditValue {
    param([string]$Name)
    @{ none = 0; success = 1; failure = 2; both = 3 }[$Name]
}

# auditpol /backup CSV -> @{ '{GUID}' = Setting Value (0 none, 1 success, 2 failure, 3 both) }.
# Column names stay English on localised Windows; subcategory names don't.
function Read-AuditCsv {
    param([string[]]$Lines)
    $m = @{}
    foreach ($r in @($Lines | Where-Object { $_ } | ConvertFrom-Csv)) {
        $g = $r.'Subcategory GUID'
        if ($g) { $m[$g.ToUpperInvariant()] = [int]$r.'Setting Value' }
    }
    $m
}

function Compare-AuditPolicy {
    param($Policy, $Current)
    foreach ($p in @($Policy.audit.PSObject.Properties)) {
        if ((Get-AuditValue $p.Value) -ne $Current[$p.Name.ToUpperInvariant()]) { $p.Name }
    }
}

function Get-AuditPolicyDrift {
    param($Policy)
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "machine-config-auditpol-$PID.csv")
    try {
        auditpol /backup "/file:$tmp" | Out-Null
        if ($LASTEXITCODE) { throw "auditpol /backup failed ($LASTEXITCODE)" }
        Compare-AuditPolicy $Policy (Read-AuditCsv (Get-Content -LiteralPath $tmp))
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Set-AuditPolicy {
    param($Policy)
    foreach ($g in @(Get-AuditPolicyDrift $Policy)) {
        $v = Get-AuditValue $Policy.audit.$g
        $s = if ($v -band 1) { 'enable' } else { 'disable' }
        $f = if ($v -band 2) { 'enable' } else { 'disable' }
        auditpol /set "/subcategory:$g" "/success:$s" "/failure:$f" | Out-Null
        if ($LASTEXITCODE) { throw "auditpol /set $g failed ($LASTEXITCODE)" }
    }
}
