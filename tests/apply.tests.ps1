# Plain pwsh tests for apply/ (no framework). Runs on Linux:
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File tests/apply.tests.ps1
$ErrorActionPreference = 'Stop'
$applyDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'apply'
. (Join-Path $applyDir 'common.ps1')
. (Join-Path $applyDir 'startup.ps1') -NoRun

$script:failures = 0
function Assert {
    param([string]$Name, $Actual, $Expected)
    if ("$Actual" -ceq "$Expected") { Write-Host "ok   $Name" }
    else { Write-Host "FAIL $Name`n     expected: $Expected`n     actual:   $Actual"; $script:failures++ }
}

# --- PS 5.1 compatibility -------------------------------------------------------
foreach ($f in Get-ChildItem $applyDir -Filter *.ps1) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    Assert "parse $($f.Name)" $errs.Count 0
    $bad = @($tokens | Where-Object { $_.Kind -in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr' })
    $bad += @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] -or
                $n -is [System.Management.Automation.Language.PipelineChainAst] }, $true))
    $bad += @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and
                $n.ParameterName -eq 'Parallel' }, $true))
    Assert "no PS7-only syntax in $($f.Name)" $bad.Count 0
}

# --- Get-Platform ---------------------------------------------------------------
$virtio = @('PCI\VEN_1AF4&DEV_1041&SUBSYS_11001AF4', 'PCI\VEN_10DE&DEV_2684')
Assert 'platform: hypervisor + virtio -> vm' (Get-Platform -HypervisorPresent $true -PciIds $virtio) 'vm'
Assert 'platform: hypervisor only (VBS) -> metal' (Get-Platform -HypervisorPresent $true -PciIds @('PCI\VEN_10DE&DEV_2684')) 'metal'
Assert 'platform: virtio without hypervisor -> metal' (Get-Platform -HypervisorPresent $false -PciIds $virtio) 'metal'
Assert 'platform: none -> metal' (Get-Platform -HypervisorPresent $false -PciIds @()) 'metal'

# --- Test-ItemApplies -------------------------------------------------------------
$i = [pscustomobject]@{ id = 'a'; when = 'vm' }
Assert 'applies: when=vm on metal skipped' (Test-ItemApplies $i 'metal' 19045) 'when=vm, platform=metal'
Assert 'applies: when=vm on vm' ($null -eq (Test-ItemApplies $i 'vm' 19045)) $true
$i = [pscustomobject]@{ id = 'b'; when = 'any'; minBuild = 22000 }
Assert 'applies: minBuild 22000 on 19045' (Test-ItemApplies $i 'metal' 19045) 'needs build 22000, have 19045'
Assert 'applies: minBuild 22000 on 22631' ($null -eq (Test-ItemApplies $i 'metal' 22631)) $true
Assert 'applies: disabled' (Test-ItemApplies ([pscustomobject]@{ id = 'c'; enable = $false }) 'metal' 19045) 'disabled'
Assert 'applies: no fields -> applies' ($null -eq (Test-ItemApplies ([pscustomobject]@{ id = 'd' }) 'vm' 19045)) $true

# --- Compare-Version / Test-Installed ----------------------------------------------
Assert 'version: newer' (Compare-Version '2.1.0' '2.0.9') 1
Assert 'version: v-prefix equal' (Compare-Version 'v1.2' '1.2') 0
Assert 'version: older' (Compare-Version '1.9' '1.10') -1
Assert 'version: unparsable differ -> null' ($null -eq (Compare-Version 'beta' 'rc')) $true
$item = [pscustomobject]@{ id = 'kp'; version = '2.7.9'; detect = [pscustomobject]@{ displayName = '^KeePassXC' } }
Assert 'installed: newer counts' (Test-Installed $item @([pscustomobject]@{ DisplayName = 'KeePassXC'; DisplayVersion = '2.7.10' })) '2.7.10'
Assert 'installed: same counts' (Test-Installed $item @([pscustomobject]@{ DisplayName = 'KeePassXC'; DisplayVersion = '2.7.9' })) '2.7.9'
Assert 'installed: older does not' ($null -eq (Test-Installed $item @([pscustomobject]@{ DisplayName = 'KeePassXC'; DisplayVersion = '2.7.1' }))) $true
Assert 'installed: other name does not' ($null -eq (Test-Installed $item @([pscustomobject]@{ DisplayName = 'KeePass'; DisplayVersion = '9' }))) $true
$msi = [pscustomobject]@{ detect = [pscustomobject]@{ productCode = '{5417B253-1A6D-4638-BC94-743A6EC2E6F4}' } }
$msiEntry = [pscustomobject]@{ ProductCode = '{5417b253-1a6d-4638-bc94-743a6ec2e6f4}'; DisplayVersion = '7.6.9.0' }
Assert 'installed: product code case and braces insensitive' (Test-Installed $msi @($msiEntry)) '7.6.9.0'
Assert 'installed: other product code does not' ($null -eq (Test-Installed $msi @([pscustomobject]@{ ProductCode = '{00000000-0000-0000-0000-000000000000}' }))) $true
$tmpFile = New-TemporaryFile
Assert 'installed: path present' (Test-Installed ([pscustomobject]@{ detect = [pscustomobject]@{ path = $tmpFile.FullName } }) @()) 'present'
Assert 'installed: path absent' ($null -eq (Test-Installed ([pscustomobject]@{ detect = [pscustomobject]@{ path = "$($tmpFile.FullName).nope" } }) @())) $true
Assert 'installed: no detect' ($null -eq (Test-Installed ([pscustomobject]@{ id = 'x' }) @())) $true
Remove-Item $tmpFile

# --- Invoke-Step / Get-Summary ----------------------------------------------------
$ctx = New-ApplyContext (Join-Path ([IO.Path]::GetTempPath()) "apply-test-$PID.log")
$ran = $false
Invoke-Step $ctx 'boom' { throw 'kaputt' } 6>$null
Invoke-Step $ctx 'after' { $script:ran = $true } 6>$null
Invoke-Step $ctx 'skip' { New-StepSkip 'nothing to do' } 6>$null
Invoke-Step $ctx 'reboot' { $global:LASTEXITCODE = 3010 } 6>$null
Invoke-Step $ctx 'badexit' { $global:LASTEXITCODE = 5 } 6>$null
$r = @{}; foreach ($x in $ctx.Results) { $r[$x.Step] = $x }
Assert 'step: throw -> failed' $r['boom'].Status 'failed'
Assert 'step: throw detail' $r['boom'].Detail 'kaputt'
Assert 'step: next step still runs' $ran $true
Assert 'step: after -> ok' $r['after'].Status 'ok'
Assert 'step: skip -> skipped' $r['skip'].Status 'skipped'
Assert 'step: skip reason' $r['skip'].Detail 'nothing to do'
Assert 'step: 3010 not failed' $r['reboot'].Status 'ok'
Assert 'step: nonzero exit failed' $r['badexit'].Status 'failed'
$s = Get-Summary $ctx
Assert 'summary: exit 1' $s.ExitCode 1
Assert 'summary: failed list' ($s.Failed -join ',') 'boom,badexit'
Assert 'summary: reboot' $s.Reboot $true
Assert 'step: logged to file' ((Get-Content $ctx.LogPath -Raw) -match '\[failed\] boom kaputt') $true
Remove-Item $ctx.LogPath
$ctx2 = New-ApplyContext (Join-Path ([IO.Path]::GetTempPath()) "apply-test2-$PID.log")
Invoke-Step $ctx2 'skip' { New-StepSkip 'x' } 6>$null
Assert 'summary: only skips -> exit 0' (Get-Summary $ctx2).ExitCode 0
Remove-Item $ctx2.LogPath

# --- apply mutex / reboot decision -----------------------------------------------
$mutexName = 'Local\MachineConfigTest-' + [guid]::NewGuid().ToString('N')
$mutex1 = Enter-ApplyMutex $mutexName
$job = Start-Job -ScriptBlock {
    param($Name)
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $acquired = $mutex.WaitOne(0)
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    return $acquired
} -ArgumentList $mutexName
$otherProcessAcquired = $job | Wait-Job | Receive-Job
Remove-Job $job
Assert 'mutex: first caller acquires' ($null -ne $mutex1) $true
Assert 'mutex: concurrent process rejected' $otherProcessAcquired $false
$mutex1.ReleaseMutex()
$mutex1.Dispose()
$rebootSummary = [pscustomobject]@{ Reboot = $true; Failed = @() }
Assert 'reboot: requested + required + successful' (Test-ShouldReboot $rebootSummary $true) $true
Assert 'reboot: no opt-in' (Test-ShouldReboot $rebootSummary $false) $false
$failedReboot = [pscustomobject]@{ Reboot = $true; Failed = @('install: broken') }
Assert 'reboot: failed run never restarts' (Test-ShouldReboot $failedReboot $true) $false
$noReboot = [pscustomobject]@{ Reboot = $false; Failed = @() }
Assert 'reboot: no pending requirement' (Test-ShouldReboot $noReboot $true) $false

# --- Set-IniValue / Set-JsonProperty -------------------------------------------------
$once = Set-IniValue "[General]`r`nA=1`r`n" 'Browser' 'Enabled' 'true'
Assert 'ini: adds section' $once "[General]`r`nA=1`r`n`r`n[Browser]`r`nEnabled=true`r`n"
Assert 'ini: idempotent' (Set-IniValue $once 'Browser' 'Enabled' 'true') $once
Assert 'ini: replaces value' (Set-IniValue "[Browser]`r`nEnabled=false`r`n[X]`r`nEnabled=0" 'Browser' 'Enabled' 'true') "[Browser]`r`nEnabled=true`r`n[X]`r`nEnabled=0`r`n"
Assert 'ini: empty text' (Set-IniValue '' 'S' 'K' 'V') "[S]`r`nK=V`r`n"
$o = '{"enabled":{"Awake":true}}' | ConvertFrom-Json
Set-JsonProperty $o @('enabled', 'PowerToys Run') $false
Assert 'json: nested set keeps siblings' ($o | ConvertTo-Json -Compress) '{"enabled":{"Awake":true,"PowerToys Run":false}}'
$o = '{"x":{"a":1,"b":2,"c":3}}' | ConvertFrom-Json
Set-JsonProperty $o @('x', 'a') 9
Set-JsonProperty $o @('x', 'b') 8
Assert 'json: overwrite keeps key order' ($o | ConvertTo-Json -Compress) '{"x":{"a":9,"b":8,"c":3}}'
Set-JsonProperty $o @('a', 'b') 1
Assert 'json: creates intermediates' ($o.a | ConvertTo-Json -Compress) '{"b":1}'

# --- Get-FileUpdate ------------------------------------------------------------------
$env:MC_TEST_DIR = 'C:\Apps'
$e = [pscustomobject]@{ format = 'json'; data = ('{"Hotkey":"Alt + Space","nested":{"b":"%MC_TEST_DIR%\\x"}}' | ConvertFrom-Json) }
$new = Get-FileUpdate $e '{"Hotkey":"Ctrl + Alt + Win + Space","Theme":"Dark","nested":{"a":1}}'
$o = $new | ConvertFrom-Json
Assert 'file json: sets key' $o.Hotkey 'Alt + Space'
Assert 'file json: keeps app keys' $o.Theme 'Dark'
Assert 'file json: nested merge keeps siblings' ($o.nested | ConvertTo-Json -Compress) '{"a":1,"b":"C:\\Apps\\x"}'
Assert 'file json: idempotent' ($null -eq (Get-FileUpdate $e $new)) $true
Assert 'file json: formatting is not drift' ($null -eq (Get-FileUpdate $e ($o | ConvertTo-Json -Compress))) $true
Assert 'file json: missing file written' ((Get-FileUpdate $e $null | ConvertFrom-Json).Hotkey) 'Alt + Space'
$e = [pscustomobject]@{ format = 'json'; data = ('{"enabled":{"PowerToys Run":false}}' | ConvertFrom-Json) }
Assert 'file json: bool leaf' ((Get-FileUpdate $e '{"enabled":{"Awake":true}}' | ConvertFrom-Json).enabled | ConvertTo-Json -Compress) '{"Awake":true,"PowerToys Run":false}'
$e = [pscustomobject]@{ format = 'json'; data = ('{"l":["%MC_TEST_DIR%"]}' | ConvertFrom-Json) }
Assert 'file json: list expanded' ((Get-FileUpdate $e '{}' | ConvertFrom-Json).l -join ',') 'C:\Apps'
$e = [pscustomobject]@{ format = 'ini'; data = ('{"Browser":{"Enabled":"true"}}' | ConvertFrom-Json) }
$ini = Get-FileUpdate $e "[General]`r`nA=1`r`n"
Assert 'file ini: adds key' $ini "[General]`r`nA=1`r`n`r`n[Browser]`r`nEnabled=true`r`n"
Assert 'file ini: idempotent' ($null -eq (Get-FileUpdate $e $ini)) $true
$e = [pscustomobject]@{ format = 'text'; data = "x`r`n" }
Assert 'file text: write' (Get-FileUpdate $e 'y') "x`r`n"
Assert 'file text: idempotent' ($null -eq (Get-FileUpdate $e "x`r`n")) $true

# --- startup plan from data ----------------------------------------------------------
$actions = '[{"kind":"ServiceStartType","target":"vgk","metal":"system","vm":"disabled"},{"kind":"PnpDevice","target":"Root\\MttVDD","metal":false,"vm":true},{"kind":"MsiInterrupts","target":"VEN_10DE","metal":null,"vm":true}]' | ConvertFrom-Json
function Format-Plan { param($p) ($p | ForEach-Object { "$($_.Kind):$($_.Target)=$($_.Value)" }) -join ';' }
Assert 'startup plan vm' (Format-Plan (Get-StartupPlan $actions 'vm')) 'ServiceStartType:vgk=disabled;PnpDevice:Root\MttVDD=True;MsiInterrupts:VEN_10DE=True'
Assert 'startup plan metal (null = no action)' (Format-Plan (Get-StartupPlan $actions 'metal')) 'ServiceStartType:vgk=system;PnpDevice:Root\MttVDD=False'

# --- securityPolicy helpers (modules/secpol.ps1) ---------------------------------------
. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules') 'secpol.ps1')
$inf = Read-SecInf @('[Unicode]', 'Unicode=yes', '[System Access]', 'MinimumPasswordLength = 0', 'LockoutBadCount = 10',
    'NewGuestName = "Гость"', '[Privilege Rights]', 'SeBackupPrivilege = *S-1-5-32-551,*S-1-5-32-544', 'SeLockMemoryPrivilege = ')
Assert 'secinf: section parsed' $inf['System Access']['LockoutBadCount'] '10'
Assert 'secinf: empty right parsed' $inf['Privilege Rights']['SeLockMemoryPrivilege'] ''
$pol = '{"userRights":{"SeBackupPrivilege":["S-1-5-32-544","S-1-5-32-551"],"SeLockMemoryPrivilege":["S-1-5-32-544"],"SeDebugPrivilege":[]},"account":{"MinimumPasswordLength":0,"LockoutBadCount":0,"NewGuestName":"Гость"}}' | ConvertFrom-Json
Assert 'secpol: drift = declared keys that differ (order-insensitive SIDs, missing = empty)' ((Compare-SecPolicy $pol $inf) -join ';') 'Privilege Rights/SeLockMemoryPrivilege;System Access/LockoutBadCount'
$lines = New-SecInfLines $pol
Assert 'secpol: inf rights as *SIDs' ($lines -contains 'SeBackupPrivilege = *S-1-5-32-544,*S-1-5-32-551') $true
Assert 'secpol: inf empty right' ($lines -contains 'SeDebugPrivilege = ') $true
Assert 'secpol: inf string quoted, int bare' (($lines -contains 'NewGuestName = "Гость"') -and ($lines -contains 'LockoutBadCount = 0')) $true
Assert 'secpol: inf round-trips to no drift' @(Compare-SecPolicy $pol (Read-SecInf $lines)).Count 0
$csv = Read-AuditCsv @('Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value',
    'PC,System,Расширение системы безопасности,{0cce9211-69ae-11d9-bed3-505054503030},No Auditing,,0',
    'PC,System,Вход в систему,{0CCE9215-69AE-11D9-BED3-505054503030},Success,,1')
$apol = '{"audit":{"{0CCE9211-69AE-11D9-BED3-505054503030}":"none","{0CCE9215-69AE-11D9-BED3-505054503030}":"both"}}' | ConvertFrom-Json
Assert 'auditpol: drift by GUID, case-insensitive' ((Compare-AuditPolicy $apol $csv) -join ';') '{0CCE9215-69AE-11D9-BED3-505054503030}'

# --- engine has no app-specific logic -------------------------------------------------
foreach ($f in 'apply.ps1', 'startup.ps1', 'common.ps1') {
    $hits = @(Select-String -Path (Join-Path $applyDir $f) -Pattern 'Flow|PowerToys|KeePass|CmdPal|Command Palette|Keyboard Manager|Vanguard|vgk|MttVDD|Looking Glass')
    Assert "no app names in $f" $hits.Count 0
}

# --- apply.ps1 -DryRun end to end ------------------------------------------------------
$root = Join-Path ([IO.Path]::GetTempPath()) "machine-config-test-$PID"
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    foreach ($f in 'apply.ps1', 'common.ps1', 'startup.ps1', 'apply.cmd') { Copy-Item (Join-Path $applyDir $f) $root }
    $items = @(
        @{ id = 'steam'; name = 'Steam'; kind = 'installer'; when = 'any'; minBuild = 0; file = 'installers/steam/SteamSetup.exe'; version = '1'; silentArgs = '/S' },
        @{ id = 'w11only'; name = 'Win11 only'; kind = 'msix'; when = 'any'; minBuild = 22000; file = 'installers/w11only/x.msix'; version = '1' },
        @{ id = 'lg-host'; name = 'LG host'; kind = 'installer'; when = 'vm'; minBuild = 0; file = 'installers/lg-host/lg.exe'; version = 'B7' },
        @{ id = 'zapret'; name = 'zapret'; kind = 'zip'; when = 'any'; minBuild = 0; file = 'installers/zapret/z.zip'; version = '1'; extractTo = 'C:\Tools\zapret' },
        @{ id = 'vdd'; name = 'VDD'; kind = 'zip'; when = 'any'; minBuild = 0; file = 'installers/vdd/vdd.zip'; version = '1'; nestedFile = 'VDD-Setup.exe'; silentArgs = '/S' }
    )
    $items | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'items.json')
    @{
        files       = @(
            @{ name = 'app'; root = 'UserProfile'; path = 'app\settings.json'; format = 'json'; data = @{ Hotkey = 'Alt + Space' }; holders = @(@{ process = 'no-such-proc'; start = $null; args = '' }); requires = @(); minBuild = 0 },
            @{ name = 'w11file'; root = 'UserProfile'; path = 'w11.ini'; format = 'ini'; data = @{ S = @{ K = 'V' } }; holders = @(); requires = @(); minBuild = 22000 },
            @{ name = 'needsapp'; root = 'UserProfile'; path = 'n.json'; format = 'json'; data = @{ a = 1 }; holders = @(); requires = @('%MC_TEST_DIR%\nope.exe'); minBuild = 0 }
        )
        manualSteps = @(@{ text = 'Enrol in consumer ESU.'; belowBuild = 22000 }, @{ text = 'Install Valorant by hand, on C:.'; belowBuild = $null })
        dscWinRM    = $true
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'machine.json')
    '[]' | Set-Content (Join-Path $root 'startup.json')
    foreach ($it in $items) {
        New-Item -ItemType Directory -Path (Join-Path $root (Split-Path -Parent $it.file)) -Force | Out-Null
        Set-Content (Join-Path $root $it.file) 'x'
    }
    Set-Content (Join-Path $root 'config.dsc.yaml') 'x'
    Set-Content (Join-Path $root 'config.win11.dsc.yaml') 'x'
    New-Item -ItemType Directory -Path (Join-Path $root 'drivers/vm/viostor') -Force | Out-Null
    Set-Content (Join-Path $root 'drivers/vm/viostor/viostor.inf') 'x'
    $stage = Join-Path $root 'stage'
    New-Item -ItemType Directory -Path (Join-Path $stage 'Win11Debloat-2026.10.30'), (Join-Path $stage 'dsc') -Force | Out-Null
    Set-Content (Join-Path $stage 'Win11Debloat-2026.10.30/Win11Debloat.ps1') 'x'
    Set-Content (Join-Path $stage 'dsc/dsc.exe') 'x'
    New-Item -ItemType Directory -Path (Join-Path $root 'tools/Win11Debloat'), (Join-Path $root 'tools/dsc') -Force | Out-Null
    Compress-Archive -Path (Join-Path $stage 'Win11Debloat-2026.10.30') -DestinationPath (Join-Path $root 'tools/Win11Debloat/Win11Debloat.zip')
    Compress-Archive -Path (Join-Path $stage 'dsc/dsc.exe') -DestinationPath (Join-Path $root 'tools/dsc/DSC-3.1.0-x86_64-pc-windows-msvc.zip')
    "-DisableTelemetry`n# comment`n`n-DisableBing" | Set-Content (Join-Path $root 'tools/Win11Debloat/switches.txt')
    Remove-Item $stage -Recurse
    New-Item -ItemType Directory -Path (Join-Path $root 'tools/psmodules/SomeDsc') -Force | Out-Null
    Set-Content (Join-Path $root 'tools/psmodules/SomeDsc/1.2.3.zip') 'x'

    $out = & pwsh -NoProfile -File (Join-Path $root 'apply.ps1') -Platform metal -Build 19045 -DryRun 2>&1
    $code = $LASTEXITCODE
    Assert 'dryrun: exit 0' $code 0
    $log = @(Get-ChildItem (Join-Path $root 'logs') -Filter 'apply-*.log')
    Assert 'dryrun: log file exists' $log.Count 1
    $text = ''
    if ($log.Count -gt 0) { $text = Get-Content $log[0].FullName -Raw }
    function Assert-Log { param([string]$Name, [string]$Pattern) Assert "dryrun: $Name" ($text -match $Pattern) $true }
    Assert-Log 'Win11-only item skipped' '\[skipped\] install: w11only needs build 22000, have 19045'
    Assert-Log 'vm item skipped on metal' '\[skipped\] install: lg-host when=vm, platform=metal'
    Assert-Log 'win11 dsc skipped' '\[skipped\] dsc: config\.win11\.dsc\.yaml needs build 22000'
    Assert-Log 'dsc config set' 'dry-run: dsc config set --file \S+config\.dsc\.yaml'
    Assert-Log 'debloat switches' 'dry-run: powershell .*Win11Debloat\.ps1 -Silent -DisableTelemetry -DisableBing'
    Assert-Log 'pnputil' 'dry-run: pnputil /add-driver \S+\*\.inf /subdirs /install'
    Assert-Log 'installer' 'dry-run: \S+SteamSetup\.exe /S'
    Assert-Log 'zip extract' 'dry-run: Expand-Archive \S+z\.zip -> C:\\Tools\\zapret'
    Assert-Log 'nested zip installer' 'dry-run: Expand-Archive \S+vdd\.zip -> \S+machine-config-vdd; \S+VDD-Setup\.exe /S'
    Assert-Log 'scheduled task' 'dry-run: register MachineConfigStartup'
    Assert-Log 'shortcut' "dry-run: shortcut 'Apply machine config.lnk'"
    Assert-Log 'declared json file' 'dry-run: write \S*app[/\\]settings\.json'
    Assert-Log 'file below minBuild skipped' '\[skipped\] file: w11file needs build 22000'
    Assert-Log 'file requires missing app' '\[skipped\] file: needsapp requires'
    Assert-Log 'ESU manual step' 'consumer ESU'
    Assert-Log 'Valorant manual step' 'Valorant by hand, on C:'
    Assert-Log 'psmodule installed machine-wide' 'dry-run: Expand-Archive \S+1\.2\.3\.zip -> .*WindowsPowerShell[/\\]Modules[/\\]SomeDsc[/\\]1\.2\.3'
    Assert-Log 'winrm brought up for PSDSC' 'dry-run: start WinRM with loopback-only listeners'
    Assert 'dryrun: no winrm restore without a saved state' ($text -match 'winrm restore') $false
    Assert 'dryrun: no failed steps' ($text -match '\[failed\]') $false
    if ($code -ne 0 -or $text -match '\[failed\]') { Write-Host ($out | Out-String) }
    Assert 'dryrun: no marker written' (Test-Path (Join-Path $script:MachineConfigDir 'virtio-staged')) $false

    # A failing item must not stop the run, and makes the exit code 1.
    Remove-Item (Join-Path $root 'installers/steam/SteamSetup.exe')
    Remove-Item (Join-Path $root 'logs') -Recurse
    $null = & pwsh -NoProfile -File (Join-Path $root 'apply.ps1') -Platform vm -Build 22631 -DryRun 2>&1
    Assert 'dryrun fail: exit 1' $LASTEXITCODE 1
    $text = Get-Content (Get-ChildItem (Join-Path $root 'logs') -Filter 'apply-*.log')[0].FullName -Raw
    Assert-Log 'missing installer failed' '\[failed\] install: steam missing'
    Assert-Log 'later item still ran' 'dry-run: \S+lg\.exe'
    Assert-Log 'win11 dsc runs on 22631' 'dry-run: dsc config set --file \S+config\.win11\.dsc\.yaml'
    Assert-Log 'summary names failure' 'failed: install: steam'
    Assert 'dryrun fail: no ESU on Win11' ($text -match 'consumer ESU') $false
    Assert-Log 'win11 file runs on 22631' 'dry-run: write \S*w11\.ini'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -gt 0) { Write-Host "$script:failures test(s) failed"; exit 1 }
Write-Host 'all tests passed'
exit 0
