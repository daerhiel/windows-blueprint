#Requires -Version 5.1
<#
.SYNOPSIS
Inventories installed Windows and checks explicitly configured requirements.
.DESCRIPTION
Run in a fresh 64-bit Windows PowerShell 5.1 process. Administrator privileges
are recommended, but unavailable areas are reported instead of silently skipped.
Writes only its own reports under .local/audit. Does not install dependencies,
download content, or change Windows configuration. Dot-sourcing defines functions
without collecting system data; the fixture tests use this entry point.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $ConfigurationPath
)

function New-AuditArea {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory report object without changing system state.')]
    param($Data = @(), [string] $Status = 'Complete', [string] $Scope = 'Machine', [string[]] $Errors = @())
    [ordered]@{ status = $Status; scope = $Scope; data = $Data; errors = @($Errors) }
}

function Get-AuditPackageFamily {
    param([string] $PackageName)
    if ($PackageName -notmatch '^([^_]+)_\d+\.\d+\.\d+\.\d+_[^_]+_[^_]*_([^_]+)$') {
        throw "Invalid full Appx package name: $PackageName"
    }
    $Matches[1] + '_' + $Matches[2]
}

function Read-AuditRegistryValue {
    param([string] $Path, [string] $Name)
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] {
        return @{ keyPresent = $false; valuePresent = $false; value = $null; kind = $null }
    }
    try {
        $present = @($key.GetValueNames()) -contains $Name
        $value = $null
        $kind = $null
        if ($present) {
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = [string]$key.GetValueKind($Name)
        }
        @{ keyPresent = $true; valuePresent = $present; value = $value; kind = $kind }
    }
    finally { $key.Dispose() }
}

function Read-AuditRegistryPolicy {
    param([string] $Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::Unicode)
    try {
        if ($reader.ReadUInt32() -ne 0x67655250 -or $reader.ReadUInt32() -ne 1) { throw 'Invalid Registry.pol signature or version.' }
        while ($stream.Position -lt $stream.Length) {
            if ($reader.ReadUInt16() -ne 91) { throw 'Invalid Registry.pol record start.' }
            $strings = @()
            foreach ($field in @('key', 'name')) {
                $characters = [Collections.Generic.List[char]]::new()
                while (($character = $reader.ReadUInt16()) -ne 0) { $characters.Add([char]$character) }
                $strings += (-join $characters)
                if ($reader.ReadUInt16() -ne 59) { throw ('Invalid Registry.pol delimiter after ' + $field) }
            }
            $type = $reader.ReadUInt32()
            if ($reader.ReadUInt16() -ne 59) { throw 'Invalid Registry.pol type delimiter.' }
            $size = $reader.ReadUInt32()
            if ($reader.ReadUInt16() -ne 59 -or $size -gt ($stream.Length - $stream.Position - 2)) { throw 'Invalid Registry.pol data length.' }
            $bytes = $reader.ReadBytes([int]$size)
            if ($reader.ReadUInt16() -ne 93) { throw 'Invalid Registry.pol record end.' }
            $kind = [string]$type
            $value = $bytes
            if ($type -eq 4 -and $size -eq 4) { $kind = 'DWord'; $value = [BitConverter]::ToUInt32($bytes, 0) }
            [pscustomobject]@{ key = $strings[0]; name = $strings[1]; kind = $kind; value = $value }
        }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-AuditLocalGpo {
    param([string] $Path)
    $store = @{ Machine = @(); User = @(); Metadata = @{} }
    $ini = Join-Path $Path 'gpt.ini'
    if (Test-Path -LiteralPath $ini) {
        $general = $false
        foreach ($line in @(Get-Content -LiteralPath $ini)) {
            if ($line -match '^\s*\[([^\]]+)\]\s*$') { $general = $Matches[1] -ieq 'General'; continue }
            if ($general -and $line -match '^\s*(Version|gPCMachineExtensionNames|gPCUserExtensionNames)\s*=(.*?)\s*$') {
                if ($store.Metadata.ContainsKey($Matches[1])) { throw 'Duplicate local GPO metadata field.' }
                $store.Metadata[$Matches[1]] = $Matches[2]
            }
        }
    }
    foreach ($scope in @('Machine', 'User')) {
        $file = Join-Path $Path ($scope + '\Registry.pol')
        if (Test-Path -LiteralPath $file) { $store[$scope] = @(Read-AuditRegistryPolicy -Path $file) }
    }
    $store
}

function Get-AuditGpoObservation {
    param($Store, $Rule)
    $scope = 'Machine'
    if ($Rule.Path.StartsWith('HKCU:', [StringComparison]::OrdinalIgnoreCase)) { $scope = 'User' }
    $entries = @($Store[$scope] | Where-Object { $_.key -ieq $Rule.Path.Substring(6) -and $_.name -ieq $Rule.Name })
    if ($entries.Count -gt 1) { throw 'Ambiguous local GPO value.' }
    $version = [uint32]0
    $metadataValid = $Store.Metadata.ContainsKey('Version') -and [uint32]::TryParse($Store.Metadata.Version, [ref]$version)
    if ($scope -eq 'Machine') { $metadataValid = $metadataValid -and ($version -band 65535) -gt 0 }
    else { $metadataValid = $metadataValid -and ($version -shr 16) -gt 0 }
    $extension = 'gPC' + $scope + 'ExtensionNames'
    $guid = '\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}'
    $extensionList = '^(?:\[' + $guid + '(?:' + $guid + ')+\])+$'
    $metadataValid = $metadataValid -and $Store.Metadata.ContainsKey($extension) -and $Store.Metadata[$extension] -match $extensionList -and $Store.Metadata[$extension] -match '\[\{35378EAC-683F-11D2-A89A-00C04FBBCFA2\}'
    $kind = $null; $value = $null
    if ($entries.Count -eq 1) { $kind = $entries[0].kind; $value = $entries[0].value }
    [ordered]@{ scope = $scope; metadataValid = [bool]$metadataValid; valuePresent = ($entries.Count -eq 1); kind = $kind; value = $value }
}

function Read-AuditConfiguration {
    param([string] $Path)
    $config = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    $allowed = @('SchemaVersion', 'Edition', 'Architecture', 'Localization', 'OptionalFeatures', 'Capabilities', 'InboxApps', 'Policies')
    foreach ($key in $config.Keys) { if ($allowed -notcontains $key) { throw "Unsupported configuration field: $key" } }
    if ($config.SchemaVersion -ne 1 -or $config.Edition -cnotin @('Pro', 'Enterprise') -or $config.Architecture -cne 'x64') {
        throw 'Expected configuration schema 1, edition Pro or Enterprise, and architecture x64.'
    }
    if ($config.Localization -isnot [hashtable] -or $config.Localization.UiLanguage -isnot [string] -or -not $config.Localization.UiLanguage -or $config.Localization.InputLocales -isnot [array] -or @($config.Localization.InputLocales).Count -eq 0) {
        throw 'Localization requires UiLanguage and at least one InputLocales entry.'
    }
    foreach ($key in $config.Localization.Keys) { if ($key -notin @('UiLanguage', 'InputLocales')) { throw "Unsupported Localization field: $key" } }
    foreach ($locale in $config.Localization.InputLocales) { if ($locale -isnot [string] -or [string]::IsNullOrWhiteSpace($locale)) { throw 'InputLocales entries must be nonempty strings.' } }
    foreach ($section in @('OptionalFeatures', 'Capabilities', 'InboxApps')) {
        if ($config[$section] -isnot [hashtable]) { throw "$section must be a key/value map." }
        $states = @('Present', 'Absent')
        if ($section -eq 'OptionalFeatures') { $states = @('Enabled', 'Disabled') }
        foreach ($entry in $config[$section].GetEnumerator()) {
            if ([string]::IsNullOrWhiteSpace($entry.Key) -or $states -cnotcontains $entry.Value) { throw "Invalid rule in ${section}: $($entry.Key)" }
            if ($section -eq 'InboxApps') { Get-AuditPackageFamily $entry.Key | Out-Null }
        }
    }
    $families = @($config.InboxApps.Keys | ForEach-Object { Get-AuditPackageFamily $_ })
    if (@($families | Sort-Object -Unique).Count -ne $families.Count) { throw 'Multiple rules target the same Appx family.' }
    if (-not $config.ContainsKey('Policies')) { $config.Policies = @{} }
    if ($config.Policies -isnot [hashtable]) { throw 'Policies must be a key/value map.' }
    foreach ($id in $config.Policies.Keys) {
        $rule = $config.Policies[$id]
        if ($rule -isnot [hashtable] -or $rule.Path -notmatch '^HK(LM|CU):\\SOFTWARE\\Policies\\.+' -or -not $rule.Name -or -not $rule.ContainsKey('Value') -or $rule.Kind -notin @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary') -or @($rule.Editions).Count -eq 0) {
            throw "Invalid policy observation rule: $id"
        }
        if ($rule.ContainsKey('Verification') -and $rule.Verification -cne 'LocalGpo') { throw ('Unsupported policy verification: ' + $id) }
    }
    $config
}

function Get-AuditContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $sid = $identity.User.Value
    }
    finally { $identity.Dispose() }
    $commit = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try {
            $candidate = & git --no-optional-locks -C (Join-Path $PSScriptRoot '..') rev-parse --verify HEAD 2>$null
            if ($LASTEXITCODE -eq 0) { $commit = [string]$candidate }
        }
        catch { $commit = $null }
    }
    [ordered]@{ mode = 'Live'; powerShellVersion = [string]$PSVersionTable.PSVersion; isAdministrator = $admin; userSid = $sid; gitCommit = $commit }
}

function Import-AuditDism {
    # Online collection uses the installed OS module, not the image preparation ADK.
    $path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules\Dism\Dism.psd1'
    $loaded = Get-Module Dism
    if ($loaded -and [IO.Path]::GetDirectoryName($loaded.Path) -ine [IO.Path]::GetDirectoryName($path)) {
        throw 'Another DISM module is loaded. Use a fresh Windows PowerShell process.'
    }
    Import-Module $path -ErrorAction Stop
}

function Get-AuditCollectors {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Every collector accepts the same configuration, context, and output directory contract.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'status', Justification = 'The pipeline updates collection status, which is consumed after enumeration.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the map of collector scriptblocks, rather than an individual collector.')]
    param()
    @{
        Os               = {
            param($config, $context, $directory)
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $architectures = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -ExpandProperty Architecture -Unique)
            $architecture = 'Unknown'
            if ($architectures.Count -eq 1) {
                switch ([int]$architectures[0]) { 0 { $architecture = 'x86' }; 9 { $architecture = 'x64' }; 12 { $architecture = 'arm64' } }
            }
            $languages = @(Get-WinUserLanguageList -ErrorAction Stop)
            $defaultInput = Get-WinDefaultInputMethodOverride -ErrorAction Stop
            $tip = $null
            # A zero TIP means there is no override; Windows follows the user's language list.
            if ($defaultInput -and [string]$defaultInput.InputMethodTip -notin @('', '0')) { $tip = [string]$defaultInput.InputMethodTip }
            if (-not $tip -and $languages.Count -gt 0) {
                $tips = @($languages[0].InputMethodTips)
                if ($tips.Count -gt 0) { $tip = [string]$tips[0] }
            }
            $defaultLocale = $null
            if ($tip -match '^([0-9a-fA-F]{4}):') { $defaultLocale = [Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($Matches[1], 16)).Name }
            $uiOverride = Get-WinUILanguageOverride -ErrorAction Stop
            New-AuditArea -Data ([ordered]@{
                    editionId = [string]$cv.EditionID; version = [string]$os.Version; build = [string]$os.BuildNumber; revision = [int]$cv.UBR
                    architecture = $architecture; systemPreferredUiLanguage = [string](Get-SystemPreferredUILanguage -ErrorAction Stop)
                    currentProcessUiLanguage = [Globalization.CultureInfo]::CurrentUICulture.Name
                    currentUserUiLanguageOverride = $(if ($uiOverride) { $uiOverride.Name } else { $null })
                    inputLocales = @($languages | ForEach-Object { $_.LanguageTag })
                    inputMethodTips = @($languages | ForEach-Object { $_.InputMethodTips } | Sort-Object -Unique)
                    defaultInputLocale = $defaultLocale; defaultInputMethodTip = $tip
                    defaultInputMethodOverride = $(if ($defaultInput) { [string]$defaultInput.InputMethodTip } else { $null })
                })
        }
        OptionalFeatures = {
            param($config, $context, $directory)
            Import-AuditDism
            $items = @(Get-WindowsOptionalFeature -Online -LogPath (Join-Path $directory 'features-dism.log') -ErrorAction Stop | Sort-Object FeatureName | ForEach-Object {
                    [ordered]@{ name = [string]$_.FeatureName; state = [string]$_.State }
                })
            New-AuditArea -Data $items
        }
        Capabilities     = {
            param($config, $context, $directory)
            Import-AuditDism
            $items = @(Get-WindowsCapability -Online -LimitAccess -LogPath (Join-Path $directory 'capabilities-dism.log') -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                    [ordered]@{ name = [string]$_.Name; state = [string]$_.State }
                })
            New-AuditArea -Data $items
        }
        ProvisionedApps  = {
            param($config, $context, $directory)
            Import-AuditDism
            $items = @(Get-AppxProvisionedPackage -Online -LogPath (Join-Path $directory 'apps-dism.log') -ErrorAction Stop | Sort-Object PackageName | ForEach-Object {
                    [ordered]@{ name = [string]$_.DisplayName; packageName = [string]$_.PackageName; family = (Get-AuditPackageFamily $_.PackageName) }
                })
            New-AuditArea -Data $items
        }
        RegisteredApps   = {
            param($config, $context, $directory)
            $arguments = @{ PackageTypeFilter = @('Main', 'Framework', 'Resource', 'Bundle', 'Optional'); ErrorAction = 'Stop' }
            $status = 'Partial'
            $scope = 'CurrentUser'
            $errors = @('Administrator privileges are required for registrations across all users.')
            if ($context.isAdministrator) { $arguments.AllUsers = $true; $status = 'Complete'; $scope = 'AllUsers'; $errors = @() }
            $items = @(Get-AppxPackage @arguments | Sort-Object PackageFullName | ForEach-Object {
                    $package = $_
                    $users = @()
                    if ($context.isAdministrator) {
                        $users = @($package.PackageUserInformation | Sort-Object { $_.UserSecurityId.Sid } | ForEach-Object {
                                $userSid = [string]$_.UserSecurityId.Sid
                                if ([string]::IsNullOrWhiteSpace($userSid)) { $status = 'Partial'; $errors += "User SID unavailable for $($package.PackageFullName)."; $userSid = $null }
                                [ordered]@{ sid = $userSid; installState = [string]$_.InstallState }
                            })
                        if ($users.Count -eq 0) { $status = 'Partial'; $errors += "User registration state unavailable for $($package.PackageFullName)." }
                    }
                    else { $users = @([ordered]@{ sid = $context.userSid; installState = 'Installed' }) }
                    [ordered]@{
                        name = [string]$package.Name; packageName = [string]$package.PackageFullName
                        family = [string]$package.PackageFamilyName; isFramework = [bool]$package.IsFramework
                        isResourcePackage = [bool]$package.IsResourcePackage; status = [string]$package.Status
                        dependencies = @($package.Dependencies | ForEach-Object { [string]$_.PackageFullName } | Sort-Object -Unique)
                        users = $users
                    }
                })
            New-AuditArea -Data $items -Status $status -Scope $scope -Errors $errors
        }
        Services         = {
            param($config, $context, $directory)
            $items = @(Get-CimInstance Win32_Service -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                    [ordered]@{ name = [string]$_.Name; state = [string]$_.State; startMode = [string]$_.StartMode; delayedAutoStart = $_.DelayedAutoStart }
                })
            New-AuditArea -Data $items
        }
        Policies         = {
            param($config, $context, $directory)
            if ($config.Policies.Count -eq 0) { return (New-AuditArea -Status 'NotApplicable' -Scope 'ConfiguredRules') }
            $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
            $store = $null
            if (@($config.Policies.Values | Where-Object { $_.ContainsKey('Verification') -and $_.Verification -eq 'LocalGpo' -and $edition -in @($_.Editions) }).Count) { $store = Get-AuditLocalGpo -Path (Join-Path $env:WINDIR 'System32\GroupPolicy') }
            $items = @(foreach ($id in @($config.Policies.Keys | Sort-Object)) {
                    $rule = $config.Policies[$id]
                    $applicable = @($rule.Editions) -contains $edition
                    $observation = $null
                    if ($applicable) { $observation = Read-AuditRegistryValue $rule.Path $rule.Name }
                    $item = [ordered]@{ id = $id; path = $rule.Path; name = $rule.Name; applicable = $applicable; observation = $observation; effectiveState = 'NotVerified' }
                    if ($rule.ContainsKey('Verification') -and $rule.Verification -eq 'LocalGpo' -and $applicable) { $item['localGpo'] = Get-AuditGpoObservation -Store $store -Rule $rule }
                    $item
                })
            New-AuditArea -Data $items -Scope 'ConfiguredRegistryValues'
        }
        Servicing        = {
            param($config, $context, $directory)
            Import-AuditDism
            $items = @(Get-WindowsPackage -Online -LogPath (Join-Path $directory 'packages-dism.log') -ErrorAction Stop | Sort-Object PackageName | ForEach-Object {
                    [ordered]@{ name = [string]$_.PackageName; state = [string]$_.PackageState; releaseType = [string]$_.ReleaseType }
                })
            New-AuditArea -Data $items
        }
        Reboot           = {
            param($config, $context, $directory)
            $cbs = Read-AuditRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' ''
            $wu = Read-AuditRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' ''
            $rename = Read-AuditRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
            $indicators = [ordered]@{ cbsRebootPending = $cbs.keyPresent; windowsUpdateRebootRequired = $wu.keyPresent; pendingFileRenameOperations = (@($rename.value | Where-Object { $_ }).Count -gt 0) }
            New-AuditArea -Data ([ordered]@{ indicatorPresent = @($indicators.Values | Where-Object { $_ }).Count -gt 0; indicators = $indicators })
        }
    }
}

function New-AuditCheck {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory check result without changing system state.')]
    param([string] $Area, [string] $Id, $Expected, $Actual, [string] $Status, [string] $Reason = '')
    [ordered]@{ area = $Area; id = $Id; expected = $Expected; actual = $Actual; status = $Status; reason = $Reason }
}

function Compare-AuditValue {
    param([string] $Area, [string] $Id, $Expected, $Actual, [bool] $Known)
    $status = 'NotVerified'
    if ($Known) {
        $status = 'NonCompliant'
        if ($Expected -ieq $Actual) { $status = 'Compliant' }
    }
    $reason = ''
    if (-not $Known) { $reason = 'Collection is incomplete, the identifier is unavailable, or the state is transitional; see collection evidence.' }
    New-AuditCheck -Area $Area -Id $Id -Expected $Expected -Actual $Actual -Status $status -Reason $reason
}

function Compare-AuditConfiguration {
    param($Config, $Areas)
    $os = $Areas.Os
    $edition = @{ Pro = 'Professional'; Enterprise = 'Enterprise' }[$Config.Edition]
    foreach ($rule in @(
            @('Edition', $edition, 'editionId'), @('Architecture', $Config.Architecture, 'architecture'),
            @('UiLanguage.SystemPreferred', $Config.Localization.UiLanguage, 'systemPreferredUiLanguage'),
            @('UiLanguage.CurrentProcess', $Config.Localization.UiLanguage, 'currentProcessUiLanguage')
        )) {
        $actual = $null
        if ($os.status -eq 'Complete') { $actual = $os.data[$rule[2]] }
        Compare-AuditValue -Area 'Os' -Id $rule[0] -Expected $rule[1] -Actual $actual -Known ($os.status -eq 'Complete' -and -not [string]::IsNullOrEmpty($actual) -and $actual -ne 'Unknown')
    }
    $windows11 = $null
    if ($os.status -eq 'Complete') { $windows11 = ([version]$os.data.version -ge [version]'10.0.22000.0' -and ([version]$os.data.version).Major -eq 10) }
    Compare-AuditValue -Area 'Os' -Id 'Windows11' -Expected $true -Actual $windows11 -Known ($null -ne $windows11)
    if ($os.status -eq 'Complete' -and $os.data.currentUserUiLanguageOverride) {
        Compare-AuditValue -Area 'Os' -Id 'UiLanguage.CurrentUserOverride' -Expected $Config.Localization.UiLanguage -Actual $os.data.currentUserUiLanguageOverride -Known $true
    }
    foreach ($locale in @($Config.Localization.InputLocales)) {
        $present = $null
        if ($os.status -eq 'Complete') { $present = (@($os.data.inputLocales) -contains $locale -or @($os.data.inputMethodTips) -contains $locale) }
        Compare-AuditValue -Area 'Os' -Id ('InputLocale.' + $locale) -Expected $true -Actual $present -Known ($null -ne $present)
    }
    $defaultLocale = $null
    if ($os.status -eq 'Complete') {
        $defaultLocale = $os.data.defaultInputLocale
        if ($Config.Localization.InputLocales[0] -match ':') { $defaultLocale = $os.data.defaultInputMethodTip }
    }
    Compare-AuditValue -Area 'Os' -Id 'DefaultInputLocale' -Expected $Config.Localization.InputLocales[0] -Actual $defaultLocale -Known (-not [string]::IsNullOrEmpty($defaultLocale))
    foreach ($section in @('OptionalFeatures', 'Capabilities')) {
        $area = $Areas[$section]
        foreach ($name in @($Config[$section].Keys | Sort-Object)) {
            $found = @($area.data | Where-Object { $_.name -ieq $name })
            $actual = $null
            $known = $area.status -eq 'Complete' -and $found.Count -eq 1
            if ($known) {
                $actual = [string]$found[0].state
                if ($section -eq 'OptionalFeatures' -and $actual -eq 'DisabledWithPayloadRemoved') { $actual = 'Disabled' }
                elseif ($section -eq 'Capabilities' -and $actual -eq 'Installed') { $actual = 'Present' }
                elseif ($section -eq 'Capabilities' -and $actual -eq 'NotPresent') { $actual = 'Absent' }
                if ($actual -notin @('Enabled', 'Disabled', 'Present', 'Absent')) { $known = $false }
            }
            Compare-AuditValue -Area $section -Id $name -Expected $Config[$section][$name] -Actual $actual -Known $known
        }
    }
    foreach ($name in @($Config.InboxApps.Keys | Sort-Object)) {
        $family = Get-AuditPackageFamily $name
        $desired = $Config.InboxApps[$name]
        $provisioned = $Areas.ProvisionedApps
        $found = @($provisioned.data | Where-Object { $_.family -ieq $family })
        $actual = 'Absent'
        if ($found.Count -gt 0) { $actual = 'Present' }
        elseif ($provisioned.status -ne 'Complete') { $actual = $null }
        Compare-AuditValue -Area 'ProvisionedApps' -Id $family -Expected $desired -Actual $actual -Known ($found.Count -gt 0 -or $provisioned.status -eq 'Complete')
        # Present requires provisioning, not registration for every existing user.
        if ($desired -eq 'Absent') {
            $registered = $Areas.RegisteredApps
            $found = @($registered.data | Where-Object { $_.family -ieq $family -and @($_.users | Where-Object { $_.installState -eq 'Installed' }).Count -gt 0 })
            $actual = 'Absent'
            if ($found.Count -gt 0) { $actual = 'Present' }
            elseif ($registered.status -ne 'Complete') { $actual = $null }
            Compare-AuditValue -Area 'RegisteredApps' -Id $family -Expected 'Absent' -Actual $actual -Known ($found.Count -gt 0 -or $registered.status -eq 'Complete')
        }
    }
    foreach ($id in @($Config.Policies.Keys | Sort-Object)) {
        $found = @($Areas.Policies.data | Where-Object { $_.id -eq $id })
        $status = 'NotVerified'
        $reason = 'A registry value alone does not establish effective policy.'
        $actual = $null
        if ($Areas.Policies.status -eq 'Complete' -and $found.Count -eq 1) {
            if (-not $found[0].applicable) { $status = 'NotApplicable'; $reason = 'The observed edition is outside the documented rule applicability.' }
            else {
                $actual = $found[0].observation
                $rule = $Config.Policies[$id]
                if (-not $actual.valuePresent -or $actual.kind -ne $rule.Kind -or (ConvertTo-Json -InputObject $actual.value -Compress) -cne (ConvertTo-Json -InputObject $rule.Value -Compress)) {
                    $status = 'NonCompliant'; $reason = 'The configured registry observation does not match; policy effectiveness is not verified.'
                }
                elseif ($rule.ContainsKey('Verification') -and $rule.Verification -eq 'LocalGpo') {
                    $gpo = $found[0].localGpo
                    $actual = [ordered]@{ registry = $actual; localGpo = $gpo }
                    $status = 'NonCompliant'; $reason = 'The local GPO store or processing metadata differs from the configured policy.'
                    if ($gpo.metadataValid -and $gpo.valuePresent -and $gpo.kind -eq $rule.Kind -and (ConvertTo-Json -InputObject $gpo.value -Compress) -ceq (ConvertTo-Json -InputObject $rule.Value -Compress)) {
                        $status = 'Compliant'; $reason = 'Local GPO delivery and registry state match; advertising behavior is not assessed.'
                    }
                }
            }
        }
        New-AuditCheck -Area 'Policies' -Id $id -Expected $Config.Policies[$id].Value -Actual $actual -Status $status -Reason $reason
    }
}

function ConvertTo-AuditMarkdown {
    param($Report)
    $lines = @('# Windows audit', '', ('Mode: {0}. UTC: {1}. Exit code: {2}.' -f $Report.context.mode, $Report.startedAtUtc, $Report.exitCode), '',
        ('Checks: {0} compliant, {1} noncompliant, {2} not verified, {3} not applicable.' -f $Report.summary.compliant, $Report.summary.nonCompliant, $Report.summary.notVerified, $Report.summary.notApplicable), '',
        '| Collection | Status | Scope |', '| --- | --- | --- |')
    foreach ($name in $Report.areas.Keys) { $lines += '| {0} | {1} | {2} |' -f $name, $Report.areas[$name].status, $Report.areas[$name].scope }
    $lines += @('', '## Findings', '')
    foreach ($check in @($Report.checks | Where-Object { $_.status -ne 'Compliant' })) {
        $text = '{0}: {1} / {2}; expected {3}; observed {4}. {5}' -f $check.status, $check.area, $check.id, (ConvertTo-Json -InputObject $check.expected -Compress -Depth 6), (ConvertTo-Json -InputObject $check.actual -Compress -Depth 6), $check.reason
        # Keep identifiers and error text from creating Markdown structure or HTML.
        $text = [Net.WebUtility]::HtmlEncode(($text -replace '[\r\n]+', ' ')).Replace('|', '&#124;').Replace('`', '&#96;')
        $lines += '- ' + $text
    }
    if ($Report.summary.nonCompliant -eq 0 -and $Report.summary.notVerified -eq 0) { $lines += 'No unresolved configuration checks.' }
    foreach ($name in $Report.areas.Keys) {
        foreach ($message in $Report.areas[$name].errors) {
            $lines += '- Collection error ({0}): {1}' -f $name, [Net.WebUtility]::HtmlEncode(($message -replace '[\r\n]+', ' ')).Replace('`', '&#96;')
        }
    }
    $lines += @('', 'Reboot indicators and service running states are observations, not compliance rules. See audit.json for inventory, scope, dependencies, and evidence. System preferred and process UI language checks do not prove the language of every desktop session.', '')
    $lines -join [Environment]::NewLine
}

function Invoke-WindowsAudit {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param([string] $ConfigurationPath, [string] $OutputDirectory, [hashtable] $Collectors, $Context)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $configurationHash = (Get-FileHash -LiteralPath $ConfigurationPath -Algorithm SHA256).Hash
    $config = Read-AuditConfiguration $ConfigurationPath
    if ($configurationHash -ne (Get-FileHash -LiteralPath $ConfigurationPath -Algorithm SHA256).Hash) { throw 'Configuration changed while it was being imported.' }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'Specify a new OutputDirectory under .local/audit.' }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.local\audit')).TrimEnd('\')
    $output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($output) -ine $root) { throw 'OutputDirectory must be directly under the repository .local/audit directory.' }
    $ancestor = $output
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Audit paths must not contain reparse points.' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $order = @('Os', 'OptionalFeatures', 'Capabilities', 'ProvisionedApps', 'RegisteredApps', 'Services', 'Policies', 'Servicing', 'Reboot')
    if ($null -eq $Collectors) { $Collectors = Get-AuditCollectors }
    foreach ($name in $order) { if (-not $Collectors.ContainsKey($name)) { throw "Collector missing: $name" } }
    if ($null -eq $Context) { $Context = Get-AuditContext }
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $lockPath = $output + '.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Audit locks must not be reparse points.' }
    $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    try {
        if (Test-Path -LiteralPath $output) { throw 'OutputDirectory already exists; choose a new run directory. Previous audit reports are never deleted.' }
        [IO.Directory]::CreateDirectory($output) | Out-Null
        $report = [ordered]@{
            schemaVersion = 1; startedAtUtc = [DateTime]::UtcNow.ToString('o'); completedAtUtc = $null; context = $Context
            configuration = [ordered]@{ sha256 = $configurationHash; desired = $config }
            areas = [ordered]@{}; checks = @(); summary = $null; exitCode = 4
        }
        foreach ($name in $order) {
            try {
                $area = & $Collectors[$name] $config $Context $output
                if ($area -isnot [System.Collections.IDictionary] -or $area.status -notin @('Complete', 'Partial', 'Failed', 'NotApplicable') -or -not $area.Contains('data') -or -not $area.Contains('errors') -or -not $area.Contains('scope')) {
                    throw "Invalid result from collector $name."
                }
                $report.areas[$name] = $area
            }
            catch {
                $scope = 'Machine'
                if ($name -eq 'RegisteredApps') {
                    $scope = 'CurrentUser'
                    if ($Context.isAdministrator) { $scope = 'AllUsers' }
                }
                elseif ($name -eq 'Policies') { $scope = 'ConfiguredRules' }
                $report.areas[$name] = New-AuditArea -Status 'Failed' -Scope $scope -Errors @($_.Exception.Message)
            }
        }
        $report.checks = @(Compare-AuditConfiguration $config $report.areas)
        $report.summary = [ordered]@{
            compliant       = @($report.checks | Where-Object { $_.status -eq 'Compliant' }).Count
            nonCompliant    = @($report.checks | Where-Object { $_.status -eq 'NonCompliant' }).Count
            notVerified     = @($report.checks | Where-Object { $_.status -eq 'NotVerified' }).Count
            notApplicable   = @($report.checks | Where-Object { $_.status -eq 'NotApplicable' }).Count
            incompleteAreas = @($report.areas.Values | Where-Object { $_.status -in @('Failed', 'Partial') }).Count
        }
        $report.exitCode = 0
        if ($report.summary.nonCompliant -gt 0) { $report.exitCode = 1 }
        if ($report.summary.incompleteAreas -gt 0 -or $report.summary.notVerified -gt 0) { $report.exitCode = $report.exitCode -bor 2 }
        $report.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        $encoding = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $output 'audit.json'), (ConvertTo-Json -InputObject $report -Depth 30), $encoding)
        [IO.File]::WriteAllText((Join-Path $output 'audit.md'), (ConvertTo-AuditMarkdown $report), $encoding)
        $report
    }
    finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'Use a fresh 64-bit Windows PowerShell 5.1 process.' }
    if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) { $ConfigurationPath = Join-Path $PSScriptRoot '..\config\windows.psd1' }
    $result = Invoke-WindowsAudit -ConfigurationPath $ConfigurationPath -OutputDirectory $OutputDirectory
    Write-Output ('Audit completed. Exit code: {0}. Reports: {1}' -f $result.exitCode, $OutputDirectory)
    exit $result.exitCode
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 4
}
