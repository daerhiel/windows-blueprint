#Requires -Version 5.1
<#
.SYNOPSIS
Tests audit evaluation and reports using synthetic inventories only.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'scripts\audit.ps1')
$configuration = Join-Path $repository 'config\windows.psd1'
$catalog = Get-Content -LiteralPath (Join-Path $repository 'config\catalogs\pro-26300.9711\catalog.json') -Raw | ConvertFrom-Json
$prefix = 'fixture-' + [Guid]::NewGuid().ToString('N')
$context = [ordered]@{ mode = 'Fixture'; powerShellVersion = [string]$PSVersionTable.PSVersion; isAdministrator = $true; userSid = 'S-1-5-21-100-100-100-1000'; gitCommit = $null }
$passed = 0

function Assert-AuditTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

function Assert-AuditThrows {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the assertion that an action throws an exception.')]
    param([scriptblock] $Action, [string] $Message)
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true }
    Assert-AuditTest $caught $Message
}

function New-FixtureCollectors {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only in-memory synthetic collector results.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Creates a map of fixture collectors that implements the audit collector contract.')]
    param()
    $auditConfig = Read-AuditConfiguration $configuration
    $areas = @{}
    $areas.Os = New-AuditArea -Data (@{
            editionId = 'Professional'; architecture = 'x64'; version = '10.0.26300'; build = '26300'; revision = 9711
            systemPreferredUiLanguage = 'en-US'; currentProcessUiLanguage = 'en-US'; currentUserUiLanguageOverride = $null
            inputLocales = @('en-US'); inputMethodTips = @('0409:00000409'); defaultInputLocale = 'en-US'; defaultInputMethodTip = '0409:00000409'
        })
    $areas.OptionalFeatures = New-AuditArea -Data @(foreach ($item in $catalog.optionalFeatures) {
            $state = $item.state
            if ($auditConfig.OptionalFeatures.ContainsKey($item.name)) { $state = $auditConfig.OptionalFeatures[$item.name] }
            if ($item.name -eq 'WindowsMediaPlayer') { $state = 'DisabledWithPayloadRemoved' }
            @{ name = $item.name; state = $state }
        })
    $areas.Capabilities = New-AuditArea -Data @(foreach ($item in $catalog.capabilities) {
            $state = $item.state
            if ($auditConfig.Capabilities[$item.name] -eq 'Absent') { $state = 'NotPresent' }
            @{ name = $item.name; state = $state }
        })
    $areas.ProvisionedApps = New-AuditArea -Data @($catalog.provisionedApps | Where-Object { $auditConfig.InboxApps[$_.packageName] -ne 'Absent' } | ForEach-Object {
            @{ name = $_.displayName; packageName = $_.packageName; family = (Get-AuditPackageFamily $_.packageName) }
        })
    $areas.RegisteredApps = New-AuditArea -Data @() -Scope 'AllUsers'
    $areas.Services = New-AuditArea -Data @(@{ name = 'SyntheticService'; state = 'Stopped'; startMode = 'Manual'; delayedAutoStart = $false })
    $areas.Policies = New-AuditArea -Scope 'ConfiguredRegistryValues' -Data @(foreach ($id in $auditConfig.Policies.Keys) {
            $rule = $auditConfig.Policies[$id]
            @{ id = $id; applicable = $true; observation = @{ valuePresent = $true; kind = $rule.Kind; value = $rule.Value }; localGpo = @{ metadataValid = $true; valuePresent = $true; kind = $rule.Kind; value = $rule.Value }; effectiveState = 'NotVerified' }
        })
    $areas.Servicing = New-AuditArea -Data @(@{ name = 'SyntheticUpdate'; state = 'Installed'; releaseType = 'SecurityUpdate' })
    $areas.Reboot = New-AuditArea -Data @{ indicatorPresent = $true; indicators = @{ cbsRebootPending = $true } }
    $collectors = @{}
    foreach ($name in $areas.Keys) {
        $result = $areas[$name]
        $collectors[$name] = { $result }.GetNewClosure()
    }
    $collectors
}

function Invoke-FixtureAudit {
    param([string] $Label, [hashtable] $Collectors, [string] $ConfigurationFile = $configuration)
    $directory = Join-Path $repository ('.local\audit\' + $prefix + '-' + $Label)
    Invoke-WindowsAudit -ConfigurationPath $ConfigurationFile -OutputDirectory $directory -Collectors $Collectors -Context $context
}

$good = Invoke-FixtureAudit 'compliant' (New-FixtureCollectors)
Assert-AuditTest ($good.exitCode -eq 0) 'A complete matching inventory must pass, even with a reboot indicator and stopped manual services.'
Assert-AuditTest ($good.summary.nonCompliant -eq 0 -and $good.summary.notVerified -eq 0) 'All configured requirements must be resolved.'
$goodPath = Join-Path $repository ('.local\audit\' + $prefix + '-compliant')
$json = Get-Content -LiteralPath (Join-Path $goodPath 'audit.json') -Raw | ConvertFrom-Json
Assert-AuditTest ($json.context.mode -eq 'Fixture' -and $json.schemaVersion -eq 1) 'Fixture evidence must be clearly labeled and JSON must round-trip.'
Assert-AuditTest (@($json.areas.Capabilities.data).Count -eq 424 -and @($json.areas.ProvisionedApps.data).Count -eq 30) 'Inventory arrays must retain all fixture entries.'
$second = Invoke-FixtureAudit 'repeat' (New-FixtureCollectors)
Assert-AuditTest ((ConvertTo-Json -InputObject $good.areas -Depth 20 -Compress) -ceq (ConvertTo-Json -InputObject $second.areas -Depth 20 -Compress)) 'Identical collections must be comparable independently of run timestamps.'

$collectors = New-FixtureCollectors
$collectors.RegisteredApps = {
    New-AuditArea -Scope 'AllUsers' -Data @(@{
            packageName  = 'Microsoft.XboxGamingOverlay_999.0.0.0_x64__8wekyb3d8bbwe'
            family       = 'Microsoft.XboxGamingOverlay_8wekyb3d8bbwe'
            users        = @(@{ sid = 'S-1-5-21-100-100-100-1000'; installState = 'Installed' })
            dependencies = @('Synthetic.Framework_1.0.0.0_x64__123456789abcd')
        })
}
$drift = Invoke-FixtureAudit 'updated-app' $collectors
Assert-AuditTest ($drift.exitCode -eq 1 -and $drift.summary.nonCompliant -eq 1) 'A removed app returning under a new version must be detected in registrations.'
Assert-AuditTest (@($drift.checks | Where-Object { $_.area -eq 'ProvisionedApps' -and $_.status -ne 'Compliant' }).Count -eq 0) 'Provisioning and registrations must be checked independently.'
$driftJson = Get-Content -LiteralPath (Join-Path $repository ('.local\audit\' + $prefix + '-updated-app\audit.json')) -Raw | ConvertFrom-Json
Assert-AuditTest ($driftJson.areas.RegisteredApps.data[0].dependencies[0] -eq 'Synthetic.Framework_1.0.0.0_x64__123456789abcd') 'Dependency evidence must survive serialization.'

$collectors.RegisteredApps = { New-AuditArea -Status 'Partial' -Scope 'CurrentUser' -Data @() -Errors @('All-user access denied.') }
$partial = Invoke-FixtureAudit 'partial' $collectors
Assert-AuditTest ($partial.exitCode -eq 2 -and $partial.summary.notVerified -eq 17) 'Missing all-user visibility must not prove app absence.'
Assert-AuditTest (@($partial.checks | Where-Object { $_.area -eq 'RegisteredApps' -and $null -ne $_.actual }).Count -eq 0) 'Unknown absence must not be reported as observed absence.'

$collectors = New-FixtureCollectors
$collectors.OptionalFeatures = { throw 'Synthetic access denied <script>|` payload' }
$failure = Invoke-FixtureAudit 'failed-collector' $collectors
Assert-AuditTest ($failure.exitCode -eq 2 -and $failure.areas.OptionalFeatures.status -eq 'Failed') 'Collector failures must produce an incomplete report and nonzero exit.'
Assert-AuditTest ($failure.areas.Servicing.status -eq 'Complete') 'A failed collector must not prevent later collections.'
$markdown = Get-Content -LiteralPath (Join-Path $repository ('.local\audit\' + $prefix + '-failed-collector\audit.md')) -Raw
Assert-AuditTest ($markdown -notmatch '<script>' -and $markdown -match '&lt;script&gt;') 'Error text must not become executable HTML in Markdown.'
$collectors.RegisteredApps = { New-AuditArea -Scope 'AllUsers' -Data @(@{ family = 'Microsoft.XboxGamingOverlay_8wekyb3d8bbwe'; users = @(@{ installState = 'Installed' }) }) }
$both = Invoke-FixtureAudit 'drift-and-failure' $collectors
Assert-AuditTest ($both.exitCode -eq 3) 'Simultaneous drift and incomplete collection must remain distinguishable.'

$collectors = New-FixtureCollectors
$collectors.OptionalFeatures = { New-AuditArea -Data @(@{ name = 'Containers'; state = 'EnablePending' }) }
$pending = Invoke-FixtureAudit 'pending-feature' $collectors
Assert-AuditTest (@($pending.checks | Where-Object { $_.id -eq 'Containers' -and $_.status -eq 'NotVerified' -and $_.actual -eq 'EnablePending' }).Count -eq 1) 'Pending feature changes are not completed enablement.'
Assert-AuditTest (@($pending.checks | Where-Object { $_.area -eq 'OptionalFeatures' -and $_.status -eq 'Compliant' }).Count -eq 0) 'Unavailable feature identifiers must not silently pass.'

$fixtureFiles = Join-Path $repository ('.local\audit-test-data\' + $prefix)
[IO.Directory]::CreateDirectory($fixtureFiles) | Out-Null
$invalidPath = Join-Path $fixtureFiles 'invalid.psd1'
$invalidText = (Get-Content -LiteralPath $configuration -Raw) -replace '(?m)^([ \t]*OptionalFeatures[ \t]*=[ \t]*@\{)', ('${1}' + "`n        'SyntheticInvalidFeature' = 'Bogus'")
[IO.File]::WriteAllText($invalidPath, $invalidText)
Assert-AuditThrows { Read-AuditConfiguration $invalidPath } 'Invalid desired states must be rejected before collection.'
[IO.File]::WriteAllText($invalidPath, "@{ SchemaVersion = 1; Edition = 'Pro'; Architecture = 'x64'; SchemaVersion = 1 }")
Assert-AuditThrows { Read-AuditConfiguration $invalidPath } 'Duplicate data-file keys must be rejected.'
[IO.File]::WriteAllText($invalidPath, "@{ SchemaVersion = (Get-Date) }")
Assert-AuditThrows { Read-AuditConfiguration $invalidPath } 'Configuration must be imported as restricted data, never executed.'

$presentPath = Join-Path $fixtureFiles 'present.psd1'
$text = (Get-Content -LiteralPath $configuration -Raw) -replace '(?m)^([ \t]*InboxApps[ \t]*=[ \t]*@\{)', ('${1}' + "`n        'Microsoft.WindowsStore_1.0.0.0_neutral_~_8wekyb3d8bbwe' = 'Present'")
[IO.File]::WriteAllText($presentPath, $text)
$present = Invoke-FixtureAudit -Label 'present-updated' -Collectors (New-FixtureCollectors) -ConfigurationFile $presentPath
Assert-AuditTest ($present.exitCode -eq 0) 'A Present app rule must match the updated provisioned family, without requiring registration for every user.'
$duplicateText = $text -replace '(?m)^([ \t]*InboxApps[ \t]*=[ \t]*@\{)', ('${1}' + "`n        'Microsoft.WindowsStore_2.0.0.0_x64__8wekyb3d8bbwe' = 'Absent'")
[IO.File]::WriteAllText($invalidPath, $duplicateText)
Assert-AuditThrows { Read-AuditConfiguration $invalidPath } 'Conflicting rules for two versions of one app family must be rejected.'

$policyPath = Join-Path $fixtureFiles 'policy.psd1'
$policyText = @'
@{
    SchemaVersion = 1; Edition = 'Pro'; Architecture = 'x64'
    Localization = @{ UiLanguage = 'en-US'; InputLocales = @('en-US') }
    OptionalFeatures = @{}; Capabilities = @{}; InboxApps = @{}
    Policies = @{
        Synthetic = @{ Path = 'HKLM:\SOFTWARE\Policies\Synthetic'; Name = 'Setting'; Kind = 'DWord'; Value = 1; Editions = @('Professional') }
    }
}
'@
[IO.File]::WriteAllText($policyPath, $policyText)
$collectors = New-FixtureCollectors
$collectors.Policies = { New-AuditArea -Data @(@{ id = 'Synthetic'; applicable = $true; observation = @{ valuePresent = $true; kind = 'DWord'; value = 1 }; effectiveState = 'NotVerified' }) }
$policy = Invoke-FixtureAudit -Label 'policy-match' -Collectors $collectors -ConfigurationFile $policyPath
Assert-AuditTest ($policy.exitCode -eq 2 -and $policy.summary.notVerified -eq 1) 'A matching registry value must not prove policy effectiveness.'
$collectors.Policies = { New-AuditArea -Data @(@{ id = 'Synthetic'; applicable = $false; observation = $null; effectiveState = 'NotVerified' }) }
$notApplicable = Invoke-FixtureAudit -Label 'policy-not-applicable' -Collectors $collectors -ConfigurationFile $policyPath
Assert-AuditTest ($notApplicable.exitCode -eq 0 -and $notApplicable.summary.notApplicable -eq 1) 'Known policy inapplicability must remain distinct from failed verification.'

$collectors = New-FixtureCollectors
$collectors.Policies = {
    param($config)
    New-AuditArea -Data @(foreach ($id in $config.Policies.Keys) {
            $rule = $config.Policies[$id]
            @{ id = $id; applicable = $true; observation = @{ valuePresent = $true; kind = $rule.Kind; value = $rule.Value }; localGpo = @{ metadataValid = $false; valuePresent = $true; kind = $rule.Kind; value = $rule.Value }; effectiveState = 'NotVerified' }
        })
}
$managedPolicyPath = Join-Path $fixtureFiles 'managed-policy.psd1'
[IO.File]::WriteAllText($managedPolicyPath, $policyText.Replace("Editions = @('Professional')", "Editions = @('Professional'); Verification = 'LocalGpo'"))
$missingMetadata = Invoke-FixtureAudit -Label 'policy-metadata-missing' -Collectors $collectors -ConfigurationFile $managedPolicyPath
Assert-AuditTest ($missingMetadata.summary.nonCompliant -eq 1 -and $missingMetadata.exitCode -eq 1) 'Matching registry values without valid local GPO processing metadata must fail delivery verification.'

$polPath = Join-Path $fixtureFiles 'Registry.pol'
$stream = [IO.File]::Create($polPath)
$writer = [IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint32]0x67655250); $writer.Write([uint32]1); $writer.Write([uint16]91)
    $writer.Write([Text.Encoding]::Unicode.GetBytes("SOFTWARE\Policies\Synthetic`0")); $writer.Write([uint16]59)
    $writer.Write([Text.Encoding]::Unicode.GetBytes("Setting`0")); $writer.Write([uint16]59)
    $writer.Write([uint32]4); $writer.Write([uint16]59); $writer.Write([uint32]4); $writer.Write([uint16]59)
    $writer.Write([uint32]1); $writer.Write([uint16]93)
}
finally { $writer.Dispose(); $stream.Dispose() }
$entries = @(Read-AuditRegistryPolicy -Path $polPath)
Assert-AuditTest ($entries.Count -eq 1 -and $entries[0].kind -ceq 'DWord' -and $entries[0].value -eq 1 -and $entries[0].key -ceq 'SOFTWARE\Policies\Synthetic') 'Registry.pol must be decoded independently of the compiler.'
$bytes = [IO.File]::ReadAllBytes($polPath)
[IO.File]::WriteAllBytes($polPath, $bytes[0..($bytes.Length - 2)])
Assert-AuditThrows { Read-AuditRegistryPolicy -Path $polPath } 'A truncated policy record must not prove configured state.'
$bytes[0] = 0
[IO.File]::WriteAllBytes($polPath, $bytes)
Assert-AuditThrows { Read-AuditRegistryPolicy -Path $polPath } 'An invalid Registry.pol signature must fail collection.'
$gpoPath = Join-Path $fixtureFiles 'GroupPolicy'
[IO.Directory]::CreateDirectory((Join-Path $gpoPath 'Machine')) | Out-Null
$bytes[0] = 0x50
[IO.File]::WriteAllBytes((Join-Path $gpoPath 'Machine\Registry.pol'), $bytes)
$ini = Join-Path $gpoPath 'gpt.ini'
$registryExtension = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
$rule = @{Path = 'HKLM:\SOFTWARE\Policies\Synthetic'; Name = 'Setting' }
[IO.File]::WriteAllText($ini, "[Other]`r`nVersion=1`r`ngPCMachineExtensionNames=$registryExtension`r`n")
Assert-AuditTest (-not (Get-AuditGpoObservation -Store (Get-AuditLocalGpo $gpoPath) -Rule $rule).metadataValid) 'GPO metadata outside the General section must not prove delivery.'
[IO.File]::WriteAllText($ini, "[General]`r`nVersion=1`r`ngPCMachineExtensionNames=[{D02B1F72-3407-48AE-BA88-E8213C6761F1}{35378EAC-683F-11D2-A89A-00C04FBBCFA2}]`r`n")
Assert-AuditTest (-not (Get-AuditGpoObservation -Store (Get-AuditLocalGpo $gpoPath) -Rule $rule).metadataValid) 'The registry extension must be a client extension, not merely a tool GUID.'
[IO.File]::WriteAllText($ini, "[General]`r`nVersion=1`r`ngPCMachineExtensionNames=$registryExtension`r`n")
Assert-AuditTest ((Get-AuditGpoObservation -Store (Get-AuditLocalGpo $gpoPath) -Rule $rule).metadataValid) 'Valid General metadata and registry client-extension pairs must be recognized.'

$before = (Get-FileHash -LiteralPath (Join-Path $goodPath 'audit.json') -Algorithm SHA256).Hash
Assert-AuditThrows { Invoke-WindowsAudit -ConfigurationPath $configuration -OutputDirectory $goodPath -Collectors (New-FixtureCollectors) -Context $context } 'Existing reports must never be overwritten.'
Assert-AuditTest ($before -eq (Get-FileHash -LiteralPath (Join-Path $goodPath 'audit.json') -Algorithm SHA256).Hash) 'Refusing a repeated output path must preserve existing evidence.'
Assert-AuditThrows { Invoke-WindowsAudit -ConfigurationPath $configuration -OutputDirectory (Join-Path $repository '.local\outside-audit') -Collectors (New-FixtureCollectors) -Context $context } 'Report paths outside the audit root must be rejected.'
$incompleteCollectors = New-FixtureCollectors
$incompleteCollectors.Remove('Os')
Assert-AuditThrows { Invoke-FixtureAudit 'missing-collector' $incompleteCollectors } 'Injected fixture collectors must never fall back to live collection.'

& git --no-optional-locks -C $repository check-ignore --quiet -- (Join-Path $goodPath 'audit.json')
Assert-AuditTest ($LASTEXITCODE -eq 0) 'Generated reports must remain ignored by Git.'

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $schemaPath = Join-Path $repository 'docs\audit-report.schema.json'
    foreach ($directory in @(Get-ChildItem -LiteralPath (Join-Path $repository '.local\audit') -Directory | Where-Object { $_.Name.StartsWith($prefix + '-') })) {
        $reportPath = Join-Path $directory.FullName 'audit.json'
        Assert-AuditTest (Test-Json -Json (Get-Content -LiteralPath $reportPath -Raw) -SchemaFile $schemaPath -ErrorAction Stop) ('Report must match the schema: ' + $directory.Name)
    }
    $json.PSObject.Properties.Remove('areas')
    Assert-AuditTest (-not (Test-Json -Json ($json | ConvertTo-Json -Depth 30) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'Schema validation must reject a missing collection envelope.'
}

# Exercise the real collector projections with stubbed Windows APIs, not this host.
$script:gpoReads = 0
function Get-AuditLocalGpo {
    param([string] $Path)
    if (-not $Path) { throw 'Expected an explicit local GPO path.' }
    $script:gpoReads++
    @{ Machine = @(); User = @(); Metadata = @{} }
}
function Get-CimInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Test double prevents live CIM collection in this isolated test process.')]
    [CmdletBinding()]
    param([string] $ClassName)
    switch ($ClassName) {
        'Win32_OperatingSystem' { [pscustomobject]@{ Version = '10.0.26300'; BuildNumber = '26300' } }
        'Win32_Processor' { [pscustomobject]@{ Architecture = 9 } }
        'Win32_Service' { [pscustomobject]@{ Name = 'Synthetic'; State = 'Stopped'; StartMode = 'Auto'; DelayedAutoStart = $true } }
        default { throw 'Unexpected CIM query.' }
    }
}
function Get-ItemProperty {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Test double prevents live registry collection in this isolated test process.')]
    [CmdletBinding()]
    param([string] $LiteralPath)
    if ($LiteralPath -ne 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion') { throw 'Unexpected registry query.' }
    [pscustomobject]@{ EditionID = 'Professional'; UBR = 9711 }
}
function Get-WinUserLanguageList { [CmdletBinding()] param(); [pscustomobject]@{ LanguageTag = 'en-US'; InputMethodTips = @('0409:00000409') } }
function Get-WinDefaultInputMethodOverride { [CmdletBinding()] param(); [pscustomobject]@{ InputMethodTip = '0419:00000419' } }
function Get-WinUILanguageOverride { [CmdletBinding()] param(); $null }
function Get-SystemPreferredUILanguage { [CmdletBinding()] [OutputType([string])] param(); 'en-US' }
function Import-AuditDism { }
function Get-WindowsOptionalFeature {
    [CmdletBinding()] param([switch] $Online, [string] $LogPath)
    if (-not $Online -or -not $LogPath.StartsWith($goodPath)) { throw 'Unexpected feature collection parameters.' }
    [pscustomobject]@{ FeatureName = 'SyntheticFeature'; State = 'Enabled' }
}
function Get-WindowsCapability {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test double preserves the Windows API parameter contract.')]
    [CmdletBinding()] param([switch] $Online, [switch] $LimitAccess, [string] $LogPath)
    if (-not $Online -or -not $LimitAccess) { throw 'Capability collection must restrict source access.' }
    [pscustomobject]@{ Name = 'Synthetic~~~~0.0.1.0'; State = 'Installed' }
}
function Get-AppxProvisionedPackage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test double preserves the Windows API parameter contract.')]
    [CmdletBinding()] param([switch] $Online, [string] $LogPath)
    [pscustomobject]@{ DisplayName = 'Synthetic.App'; PackageName = 'Synthetic.App_1.0.0.0_neutral_~_123456789abcd' }
}
function Get-WindowsPackage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test double preserves the Windows API parameter contract.')]
    [CmdletBinding()] param([switch] $Online, [string] $LogPath)
    [pscustomobject]@{ PackageName = 'SyntheticUpdate'; PackageState = 'InstallPending'; ReleaseType = 'SecurityUpdate' }
}
$script:appHasUsers = $true
$script:appHasSid = $true
function Get-AppxPackage {
    [CmdletBinding()] param([switch] $AllUsers, [string[]] $PackageTypeFilter)
    if ($PackageTypeFilter -notcontains 'Optional' -or $PackageTypeFilter -notcontains 'Resource') { throw 'Package filters are incomplete.' }
    $users = @()
    if ($AllUsers -and $script:appHasUsers) {
        $fixtureSid = $null
        if ($script:appHasSid) { $fixtureSid = 'S-1-5-21-100-100-100-1000' }
        $users = @([pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Sid = $fixtureSid; Username = 'fixture' }; InstallState = 'Installed' })
    }
    [pscustomobject]@{
        Name = 'Synthetic.App'; PackageFullName = 'Synthetic.App_1.0.0.0_x64__123456789abcd'; PackageFamilyName = 'Synthetic.App_123456789abcd'
        PackageUserInformation = $users; IsFramework = $false; IsResourcePackage = $false; Status = 'Ok'
        Dependencies = @([pscustomobject]@{ PackageFullName = 'Synthetic.Framework_1.0.0.0_x64__123456789abcd' })
    }
}
function Read-AuditRegistryValue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test double accepts registry locations without reading this host.')]
    param([string] $Path, [string] $Name)
    @{ keyPresent = $false; valuePresent = $false; kind = $null; value = $null }
}
$rawCollectors = Get-AuditCollectors
$auditConfig = Read-AuditConfiguration $configuration
$rawOs = & $rawCollectors.Os $auditConfig $context $goodPath
Assert-AuditTest ($rawOs.data.defaultInputLocale -eq 'ru-RU' -and $rawOs.data.defaultInputMethodTip -eq '0419:00000419') 'Default input method override must take precedence over the first language-list entry.'
Assert-AuditTest ($rawOs.data.editionId -eq 'Professional' -and $rawOs.data.architecture -eq 'x64') 'OS projection must read the documented edition and native processor architecture.'
function Get-WinDefaultInputMethodOverride { [CmdletBinding()] param(); [pscustomobject]@{ InputMethodTip = '0' } }
$rawOs = & $rawCollectors.Os $auditConfig $context $goodPath
Assert-AuditTest ($rawOs.data.defaultInputLocale -eq 'en-US' -and $rawOs.data.defaultInputMethodTip -eq '0409:00000409' -and $rawOs.data.defaultInputMethodOverride -eq '0') 'A zero override must use the language-list default while preserving raw evidence.'
function Get-WinDefaultInputMethodOverride { [CmdletBinding()] param(); $null }
$rawOs = & $rawCollectors.Os $auditConfig $context $goodPath
Assert-AuditTest ($rawOs.data.defaultInputLocale -eq 'en-US' -and $null -eq $rawOs.data.defaultInputMethodOverride) 'A missing override must use the language-list default.'
function Get-WinUserLanguageList { [CmdletBinding()] param(); [pscustomobject]@{ LanguageTag = 'en-US'; InputMethodTips = '0409:00000409' } }
$rawOs = & $rawCollectors.Os $auditConfig $context $goodPath
Assert-AuditTest ($rawOs.data.defaultInputLocale -eq 'en-US' -and $rawOs.data.defaultInputMethodTip -eq '0409:00000409') 'A scalar input-method string must not be indexed as individual characters.'
$rawApps = & $rawCollectors.RegisteredApps $auditConfig $context $goodPath
Assert-AuditTest ($rawApps.status -eq 'Complete' -and $rawApps.data[0].dependencies.Count -eq 1 -and $rawApps.data[0].users[0].installState -eq 'Installed') 'Appx projection must retain dependencies and user installation states.'
Assert-AuditTest ($rawApps.data[0].users[0].sid -ceq 'S-1-5-21-100-100-100-1000') 'All-user Appx projection must read the native wrapper SID field.'
$script:appHasSid = $false
$rawApps = & $rawCollectors.RegisteredApps $auditConfig $context $goodPath
Assert-AuditTest ($rawApps.status -eq 'Partial' -and $null -eq $rawApps.data[0].users[0].sid -and $rawApps.errors.Count -gt 0) 'Missing native SID evidence must be explicit and incomplete.'
$script:appHasSid = $true
$script:appHasUsers = $false
$rawApps = & $rawCollectors.RegisteredApps $auditConfig $context $goodPath
Assert-AuditTest ($rawApps.status -eq 'Partial' -and $rawApps.errors.Count -gt 0) 'Missing user installation-state evidence must make the actual collector partial.'
$limitedContext = @{ isAdministrator = $false; userSid = 'S-1-5-21-100-100-100-1000' }
$rawApps = & $rawCollectors.RegisteredApps $auditConfig $limitedContext $goodPath
Assert-AuditTest ($rawApps.status -eq 'Partial' -and $rawApps.scope -eq 'CurrentUser' -and $rawApps.data[0].users[0].sid -eq $limitedContext.userSid) 'Non-admin Appx projection must explicitly limit scope and preserve the invoking user.'
foreach ($name in @('OptionalFeatures', 'Capabilities', 'ProvisionedApps', 'Services', 'Servicing', 'Reboot', 'Policies')) {
    $area = & $rawCollectors[$name] $auditConfig $context $goodPath
    Assert-AuditTest ($area.status -in @('Complete', 'NotApplicable')) ('Collector must project stub API evidence: ' + $name)
}
$editionOnly = Read-AuditConfiguration $configuration
$editionOnly.Policies = @{ EnterpriseOnly = @{Path='HKLM:\SOFTWARE\Policies\Synthetic'; Name='Setting'; Kind='DWord'; Value=1; Editions=@('Enterprise'); Verification='LocalGpo'} }
$readsBefore = $script:gpoReads
$area = & $rawCollectors.Policies $editionOnly $context $goodPath
Assert-AuditTest ($script:gpoReads -eq $readsBefore -and -not $area.data[0].applicable) 'Inapplicable policies must not require access to local GPO files.'

Write-Output ("Passed $passed assertions using synthetic inventories only. Fixture reports: .local/audit/$prefix-*")
