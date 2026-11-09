#Requires -Version 5.1

<#
.SYNOPSIS
Inventories installed Windows and checks explicitly configured requirements.

.DESCRIPTION
Run in a fresh 64-bit PowerShell Windows process. Administrator privileges
are recommended, but unavailable areas are reported instead of silently skipped.
Writes only its own reports under .local/audit. Does not install dependencies,
download content, or change Windows configuration. Dot-sourcing defines functions
without collecting system data; the fixture tests use this entry point.

.PARAMETER OutputDirectory
Required new report directory directly under .local/audit. Existing reports are never overwritten.

.PARAMETER ConfigurationPath
Windows requirements data file; defaults to config/windows.psd1.

.OUTPUTS
System.String. Completion message; writes audit.json and audit.md. The process exit code distinguishes mismatches, incomplete collection, and internal failure.

.EXAMPLE
.\scripts\audit.ps1 -OutputDirectory .\.local\audit\manual-check
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $ConfigurationPath
)

function New-AuditArea {
    <#
    .SYNOPSIS
    Creates an audit area with explicit collection status and scope.

    .DESCRIPTION
    Wraps collector observations and errors in the shared report shape. Incomplete observations remain distinguishable from confirmed absence.

    .PARAMETER Data
    Collected records for this area.

    .PARAMETER Status
    Collection or compliance status recorded in the result.

    .PARAMETER Scope
    Scope represented by the returned observation.

    .PARAMETER Errors
    Collection failures or limitations to retain in the report.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. Area status, scope, observations, and errors.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory report object without changing system state.')]
    param(
        $Data = @(),
        [string] $Status = 'Complete',
        [string] $Scope = 'Machine',
        [string[]] $Errors = @()
    )

    [ordered]@{
        status = $Status
        scope  = $Scope
        data   = $Data
        errors = @($Errors)
    }
}

function Get-AuditPackageFamily {
    <#
    .SYNOPSIS
    Extracts an Appx package family from a full package name.

    .DESCRIPTION
    Validates the versioned package-name structure and retains its package name and publisher identifier.

    .PARAMETER PackageName
    Full Appx package name including version, architecture, and publisher identifier.

    .OUTPUTS
    System.String. The package family name.
    #>

    param(
        [string] $PackageName
    )

    if ($PackageName -notmatch '^([^_]+)_\d+\.\d+\.\d+\.\d+_[^_]+_[^_]*_([^_]+)$') {
        throw "Invalid full Appx package name: $PackageName"
    }

    $Matches[1] + '_' + $Matches[2]
}

function Read-AuditRegistryValue {
    <#
    .SYNOPSIS
    Reads a registry value while preserving absence and value type.

    .DESCRIPTION
    Distinguishes a missing key from a missing value and reads expandable strings without expansion. Unexpected access or registry errors propagate to the collector.

    .PARAMETER Path
    Registry provider path of the key to inspect.

    .PARAMETER Name
    Registry value name; an empty name selects the default value.

    .OUTPUTS
    System.Collections.Hashtable. Key presence, value presence, value, and registry kind.
    #>

    param(
        [string] $Path,
        [string] $Name
    )

    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return @{
            keyPresent   = $false
            valuePresent = $false
            value        = $null
            kind         = $null
        }
    }

    try {
        $present = @($key.GetValueNames()) -contains $Name
        $value = $null
        $kind = $null

        if ($present) {
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = [string]$key.GetValueKind($Name)
        }

        @{
            keyPresent   = $true
            valuePresent = $present
            value        = $value
            kind         = $kind
        }
    }
    finally {
        $key.Dispose()
    }
}

function Read-AuditRegistryPolicy {
    <#
    .SYNOPSIS
    Decodes a local Group Policy Registry.pol file.

    .DESCRIPTION
    Reads the binary policy format without applying it and rejects malformed records or unsupported encodings.

    .PARAMETER Path
    Path to the Registry.pol file to inspect.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Decoded registry policy records.
    #>

    param(
        [string] $Path
    )

    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::Unicode)

    try {
        if ($reader.ReadUInt32() -ne 0x67655250 -or $reader.ReadUInt32() -ne 1) {
            throw 'Invalid Registry.pol signature or version.'
        }

        while ($stream.Position -lt $stream.Length) {
            if ($reader.ReadUInt16() -ne 91) {
                throw 'Invalid Registry.pol record start.'
            }

            $strings = @()

            foreach ($field in @('key', 'name')) {
                $characters = [Collections.Generic.List[char]]::new()

                while (($character = $reader.ReadUInt16()) -ne 0) {
                    $characters.Add([char]$character)
                }

                $strings += (-join $characters)

                if ($reader.ReadUInt16() -ne 59) {
                    throw ('Invalid Registry.pol delimiter after ' + $field)
                }
            }

            $type = $reader.ReadUInt32()

            if ($reader.ReadUInt16() -ne 59) {
                throw 'Invalid Registry.pol type delimiter.'
            }

            $size = $reader.ReadUInt32()

            if ($reader.ReadUInt16() -ne 59 -or $size -gt ($stream.Length - $stream.Position - 2)) {
                throw 'Invalid Registry.pol data length.'
            }

            $bytes = $reader.ReadBytes([int]$size)

            if ($reader.ReadUInt16() -ne 93) {
                throw 'Invalid Registry.pol record end.'
            }

            $kind = [string]$type
            $value = $bytes

            if ($type -eq 4 -and $size -eq 4) {
                $kind = 'DWord'
                $value = [BitConverter]::ToUInt32($bytes, 0)
            }

            if ($type -eq 2) {
                if ($size -lt 2 -or $size % 2 -ne 0 -or $bytes[$size - 1] -ne 0 -or $bytes[$size - 2] -ne 0) {
                    throw 'Invalid Registry.pol expandable string.'
                }

                $kind = 'ExpandString'
                $value = [Text.UnicodeEncoding]::new($false, $false, $true).GetString($bytes, 0, $size - 2)
            }

            [PSCustomObject]@{
                key   = $strings[0]
                name  = $strings[1]
                kind  = $kind
                value = $value
            }
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-AuditLocalGpo {
    <#
    .SYNOPSIS
    Collects local Group Policy files and metadata.

    .DESCRIPTION
    Reads machine and user policy records, gpt.ini metadata, and referenced local JSON files without importing policy into the host.

    .PARAMETER Path
    GroupPolicy directory in the installed system or an offline image.

    .OUTPUTS
    System.Collections.Hashtable. Policy records, metadata, and referenced file observations.
    #>

    param(
        [string] $Path
    )

    $store = @{
        Machine  = @()
        User     = @()
        Metadata = @{}
        Files    = @{}
    }
    $ini = Join-Path $Path 'gpt.ini'

    if (Test-Path -LiteralPath $ini) {
        $general = $false

        foreach ($line in @(Get-Content -LiteralPath $ini)) {
            if ($line -match '^\s*\[([^\]]+)\]\s*$') {
                $general = $Matches[1] -ieq 'General'
                continue
            }

            if ($general -and $line -match '^\s*(Version|gPCMachineExtensionNames|gPCUserExtensionNames)\s*=(.*?)\s*$') {
                if ($store.Metadata.ContainsKey($Matches[1])) {
                    throw 'Duplicate local GPO metadata field.'
                }

                $store.Metadata[$Matches[1]] = $Matches[2]
            }
        }
    }

    foreach ($scope in @('Machine', 'User')) {
        $file = Join-Path $Path ($scope + '\Registry.pol')

        if (Test-Path -LiteralPath $file) {
            $store[$scope] = @(Read-AuditRegistryPolicy -Path $file)
        }
    }

    foreach ($entry in @($store.Machine) + @($store.User)) {
        if ($entry.kind -eq 'ExpandString' -and $entry.value -match '^%SystemRoot%\\System32\\GroupPolicy\\((?:Machine|User)\\[A-Za-z0-9_.-]+\.json)$') {
            $relative = $Matches[1]
            $file = Join-Path $Path $relative

            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $store.Files[$relative] = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
            }
        }
    }

    $store
}

function Get-AuditGpoObservation {
    <#
    .SYNOPSIS
    Resolves the observed delivery of one configured local policy.

    .DESCRIPTION
    Checks the configured scope, policy metadata, registry record, and optional JSON payload. Delivery evidence does not claim that the policy effect has been verified.

    .PARAMETER Store
    Local Group Policy inventory returned by Get-AuditLocalGpo.

    .PARAMETER Rule
    One validated local Group Policy rule.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. Observation for the selected policy rule.
    #>

    param(
        $Store,
        $Rule
    )

    $scope = 'Machine'

    if ($Rule.Path.StartsWith('HKCU:', [StringComparison]::OrdinalIgnoreCase)) {
        $scope = 'User'
    }

    $entries = @($Store[$scope] | Where-Object {
            $_.key -ieq $Rule.Path.Substring(6) -and $_.name -ieq $Rule.Name
        })

    if ($entries.Count -gt 1) {
        throw 'Ambiguous local GPO value.'
    }

    $version = [uint32]0
    $metadataValid = $Store.Metadata.ContainsKey('Version') -and [uint32]::TryParse($Store.Metadata.Version, [ref]$version)

    if ($scope -eq 'Machine') {
        $metadataValid = $metadataValid -and ($version -band 65535) -gt 0
    }
    else {
        $metadataValid = $metadataValid -and ($version -shr 16) -gt 0
    }

    $extension = 'gPC' + $scope + 'ExtensionNames'
    $guid = '\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}'
    $extensionList = '^(?:\[' + $guid + '(?:' + $guid + ')+\])+$'
    $metadataValid = $metadataValid -and $Store.Metadata.ContainsKey($extension) -and $Store.Metadata[$extension] -match $extensionList -and $Store.Metadata[$extension] -match '\[\{35378EAC-683F-11D2-A89A-00C04FBBCFA2\}'
    $kind = $null
    $value = $null

    if ($entries.Count -eq 1) {
        $kind = $entries[0].kind
        $value = $entries[0].value
    }

    $observation = [ordered]@{
        scope         = $scope
        metadataValid = [bool]$metadataValid
        valuePresent  = ($entries.Count -eq 1)
        kind          = $kind
        value         = $value
    }

    if ($Rule.ContainsKey('FileContent')) {
        $relative = $Rule.Value.Substring('%SystemRoot%\System32\GroupPolicy\'.Length)
        $present = $Store.ContainsKey('Files') -and $Store.Files.ContainsKey($relative)
        $observation['file'] = [ordered]@{ present = $present; matches = ($present -and $Store.Files[$relative] -ceq $Rule.FileContent) }
    }

    $observation
}

function Read-AuditConfiguration {
    <#
    .SYNOPSIS
    Imports and validates the Windows audit configuration.

    .DESCRIPTION
    Loads a PowerShell data file and checks supported schema, identifiers, selection values, and policy paths before collectors use them.

    .PARAMETER Path
    Path to the Windows configuration data file.

    .OUTPUTS
    System.Collections.Hashtable. Validated configuration data.
    #>

    param(
        [string] $Path
    )

    $config = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    $allowed = @('SchemaVersion', 'Edition', 'Architecture', 'Localization', 'OptionalFeatures', 'Capabilities', 'InboxApps', 'Policies', 'Deployment')

    foreach ($key in $config.Keys) {
        if ($allowed -notcontains $key) {
            throw "Unsupported configuration field: $key"
        }
    }

    if ($config.SchemaVersion -ne 1 -or $config.Edition -cnotin @('Pro', 'Enterprise') -or $config.Architecture -cne 'x64') {
        throw 'Expected configuration schema 1, edition Pro or Enterprise, and architecture x64.'
    }
    if ($config.Localization -isnot [hashtable] -or $config.Localization.UiLanguage -isnot [string] -or -not $config.Localization.UiLanguage -or $config.Localization.InputLocales -isnot [array] -or @($config.Localization.InputLocales).Count -eq 0) {
        throw 'Localization requires UiLanguage and at least one InputLocales entry.'
    }

    foreach ($key in $config.Localization.Keys) {
        if ($key -notin @('UiLanguage', 'InputLocales')) {
            throw "Unsupported Localization field: $key"
        }
    }

    foreach ($locale in $config.Localization.InputLocales) {
        if ($locale -isnot [string] -or [string]::IsNullOrWhiteSpace($locale)) {
            throw 'InputLocales entries must be nonempty strings.'
        }
    }

    if ($config.ContainsKey('Deployment')) {
        $deployment = $config.Deployment

        if ($deployment.ComputerNamePrefix -notmatch '^[A-Za-z][A-Za-z0-9-]{0,7}$' -or $deployment.Disk -isnot [hashtable]) {
            throw 'Deployment requires a computer name prefix and disk configuration.'
        }

        $disk = $deployment.Disk

        if ($disk.WindowsFraction -le 0 -or $disk.WindowsFraction -gt 1 -or @($disk.WindowsSizesGiB).Count -eq 0 -or @($disk.WindowsSizesGiB | Where-Object {
                    $_ -notin @(128, 256, 512, 1024)
                }).Count) {
            throw 'Invalid Windows partition sizing policy.'
        }

        foreach ($field in @('EfiMiB', 'MsrMiB', 'RecoveryMiB', 'AlignmentMiB')) {
            if ($disk[$field] -isnot [int] -or $disk[$field] -le 0) {
                throw ('Expected a positive MiB value: ' + $field)
            }
        }

        if ($disk.AlignmentMiB -ne 1) {
            throw 'Only the default 1 MiB Setup alignment is supported.'
        }
    }

    foreach ($section in @('OptionalFeatures', 'Capabilities', 'InboxApps')) {
        if ($config[$section] -isnot [hashtable]) {
            throw "$section must be a key/value map."
        }

        $states = @('Present', 'Absent')

        if ($section -eq 'OptionalFeatures') {
            $states = @('Enabled', 'Disabled')
        }

        foreach ($entry in $config[$section].GetEnumerator()) {
            if ([string]::IsNullOrWhiteSpace($entry.Key) -or $states -cnotcontains $entry.Value) {
                throw "Invalid rule in ${section}: $($entry.Key)"
            }
            if ($section -eq 'InboxApps') {
                Get-AuditPackageFamily $entry.Key | Out-Null
            }
        }
    }

    $families = @($config.InboxApps.Keys | ForEach-Object {
            Get-AuditPackageFamily $_
        })

    if (@($families | Sort-Object -Unique).Count -ne $families.Count) {
        throw 'Multiple rules target the same Appx family.'
    }
    if (-not $config.ContainsKey('Policies')) {
        $config.Policies = @{}
    }
    if ($config.Policies -isnot [hashtable]) {
        throw 'Policies must be a key/value map.'
    }

    foreach ($id in $config.Policies.Keys) {
        $rule = $config.Policies[$id]

        if ($rule -isnot [hashtable] -or $rule.Path -notmatch '^HK(LM|CU):\\SOFTWARE\\Policies\\.+' -or -not $rule.Name -or -not $rule.ContainsKey('Value') -or $rule.Kind -notin @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary') -or @($rule.Editions).Count -eq 0) {
            throw "Invalid policy observation rule: $id"
        }
        if ($rule.ContainsKey('Verification') -and $rule.Verification -cne 'LocalGpo') {
            throw ('Unsupported policy verification: ' + $id)
        }

        if ($rule.ContainsKey('FileContent')) {
            if ($rule.Kind -cne 'ExpandString' -or $rule.Verification -cne 'LocalGpo' -or $rule.Value -cnotmatch '^%SystemRoot%\\System32\\GroupPolicy\\(?:Machine|User)\\[A-Za-z0-9_.-]+\.json$' -or $rule.FileContent -isnot [string]) {
                throw ('Expected a local GPO JSON file policy: ' + $id)
            }

            $payload = $rule.FileContent | ConvertFrom-Json -ErrorAction Stop

            if ($null -eq $payload) {
                throw ('Expected JSON file content: ' + $id)
            }
        }
    }

    $config
}

function Get-AuditContext {
    <#
    .SYNOPSIS
    Collects the audit runtime and security context.

    .DESCRIPTION
    Records the live collection mode, runtime version, administrator status, user SID, and available repository revision.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. Audit context metadata.
    #>

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    try {
        $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $sid = $identity.User.Value
    }
    finally {
        $identity.Dispose()
    }

    $commit = $null

    if (Get-Command git -ErrorAction SilentlyContinue) {
        try {
            $candidate = & git --no-optional-locks -C (Join-Path $PSScriptRoot '..') rev-parse --verify HEAD 2>$null

            if ($LASTEXITCODE -eq 0) {
                $commit = [string]$candidate
            }
        }
        catch {
            $commit = $null
        }
    }

    [ordered]@{
        mode              = 'Live'
        powerShellVersion = [string]$PSVersionTable.PSVersion
        isAdministrator   = $admin
        userSid           = $sid
        gitCommit         = $commit
    }
}

function Import-AuditDism {
    <#
    .SYNOPSIS
    Loads the installed Windows DISM module for read-only collection.

    .DESCRIPTION
    Uses the system DISM module and rejects a conflicting module already loaded into the process. Does not prepare or install external tools.

    .OUTPUTS
    None. Imports the system module or throws on a conflicting runtime.
    #>

    # Online collection uses the installed OS module, not the image preparation ADK.
    $path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules\Dism\Dism.psd1'
    $loaded = Get-Module Dism

    if ($loaded -and [IO.Path]::GetDirectoryName($loaded.Path) -ine [IO.Path]::GetDirectoryName($path)) {
        throw 'Another DISM module is loaded. Use a fresh Windows PowerShell process.'
    }

    Import-Module $path -ErrorAction Stop
}

function Get-AuditCollectors {
    <#
    .SYNOPSIS
    Creates the installed-system audit collectors.

    .DESCRIPTION
    Returns scriptblocks accepting configuration, context, and an output directory. Each collector reports explicit completeness and scope without changing Windows configuration.

    .OUTPUTS
    System.Collections.IDictionary. Collector scriptblocks indexed by audit area.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Every collector accepts the same configuration, context, and output directory contract.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'status', Justification = 'The pipeline updates collection status, which is consumed after enumeration.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the map of collector scriptblocks, rather than an individual collector.')]
    param()

    @{
        Os               = {
            param(
                $config,
                $context,
                $directory
            )

            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $architectures = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -ExpandProperty Architecture -Unique)
            $architecture = 'Unknown'

            if ($architectures.Count -eq 1) {
                switch ([int]$architectures[0]) {
                    0 {
                        $architecture = 'x86'
                    }
                    9 {
                        $architecture = 'x64'
                    }
                    12 {
                        $architecture = 'arm64'
                    }
                }
            }

            $languages = @(Get-WinUserLanguageList -ErrorAction Stop)
            $defaultInput = Get-WinDefaultInputMethodOverride -ErrorAction Stop
            $tip = $null

            # A zero TIP means there is no override; Windows follows the user's language list.
            if ($defaultInput -and [string]$defaultInput.InputMethodTip -notin @('', '0')) {
                $tip = [string]$defaultInput.InputMethodTip
            }

            if (-not $tip -and $languages.Count -gt 0) {
                $tips = @($languages[0].InputMethodTips)

                if ($tips.Count -gt 0) {
                    $tip = [string]$tips[0]
                }
            }

            $defaultLocale = $null

            if ($tip -match '^([0-9a-fA-F]{4}):') {
                $defaultLocale = [Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($Matches[1], 16)).Name
            }

            $uiOverride = Get-WinUILanguageOverride -ErrorAction Stop
            New-AuditArea -Data ([ordered]@{
                    editionId                     = [string]$cv.EditionID
                    version                       = [string]$os.Version
                    build                         = [string]$os.BuildNumber
                    revision                      = [int]$cv.UBR
                    architecture                  = $architecture
                    systemPreferredUiLanguage     = [string](Get-SystemPreferredUILanguage -ErrorAction Stop)
                    currentProcessUiLanguage      = [Globalization.CultureInfo]::CurrentUICulture.Name
                    currentUserUiLanguageOverride = $(if ($uiOverride) {
                            $uiOverride.Name
                        }
                        else {
                            $null
                        })
                    inputLocales                  = @($languages | ForEach-Object {
                            $_.LanguageTag
                        })
                    inputMethodTips               = @($languages | ForEach-Object {
                            $_.InputMethodTips
                        } | Sort-Object -Unique)
                    defaultInputLocale            = $defaultLocale
                    defaultInputMethodTip         = $tip
                    defaultInputMethodOverride    = $(if ($defaultInput) {
                            [string]$defaultInput.InputMethodTip
                        }
                        else {
                            $null
                        })
                })
        }
        OptionalFeatures = {
            param(
                $config,
                $context,
                $directory
            )

            Import-AuditDism
            $items = @(Get-WindowsOptionalFeature -Online -LogPath (Join-Path $directory 'features-dism.log') -ErrorAction Stop | Sort-Object FeatureName | ForEach-Object {
                    [ordered]@{ name = [string]$_.FeatureName; state = [string]$_.State }
                })
            New-AuditArea -Data $items
        }
        Capabilities     = {
            param(
                $config,
                $context,
                $directory
            )

            Import-AuditDism
            $items = @(Get-WindowsCapability -Online -LimitAccess -LogPath (Join-Path $directory 'capabilities-dism.log') -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                    [ordered]@{ name = [string]$_.Name; state = [string]$_.State }
                })
            New-AuditArea -Data $items
        }
        ProvisionedApps  = {
            param(
                $config,
                $context,
                $directory
            )

            Import-AuditDism
            $items = @(Get-AppxProvisionedPackage -Online -LogPath (Join-Path $directory 'apps-dism.log') -ErrorAction Stop | Sort-Object PackageName | ForEach-Object {
                    [ordered]@{
                        name        = [string]$_.DisplayName
                        packageName = [string]$_.PackageName
                        family      = (Get-AuditPackageFamily $_.PackageName)
                    }
                })
            New-AuditArea -Data $items
        }
        RegisteredApps   = {
            param(
                $config,
                $context,
                $directory
            )

            $arguments = @{ PackageTypeFilter = @('Main', 'Framework', 'Resource', 'Bundle', 'Optional'); ErrorAction = 'Stop' }
            $status = 'Partial'
            $scope = 'CurrentUser'
            $errors = @('Administrator privileges are required for registrations across all users.')

            if ($context.isAdministrator) {
                $arguments.AllUsers = $true
                $status = 'Complete'
                $scope = 'AllUsers'
                $errors = @()
            }

            $items = @(Get-AppxPackage @arguments | Sort-Object PackageFullName | ForEach-Object {
                    $package = $_
                    $users = @()

                    if ($context.isAdministrator) {
                        $users = @($package.PackageUserInformation | Sort-Object {
                                $_.UserSecurityId.Sid
                            } | ForEach-Object {
                                $userSid = [string]$_.UserSecurityId.Sid

                                if ([string]::IsNullOrWhiteSpace($userSid)) {
                                    $status = 'Partial'
                                    $errors += "User SID unavailable for $($package.PackageFullName)."
                                    $userSid = $null
                                }

                                [ordered]@{ sid = $userSid; installState = [string]$_.InstallState }
                            })

                        if ($users.Count -eq 0) {
                            $status = 'Partial'
                            $errors += "User registration state unavailable for $($package.PackageFullName)."
                        }
                    }
                    else {
                        $users = @([ordered]@{ sid = $context.userSid; installState = 'Installed' })
                    }

                    [ordered]@{
                        name              = [string]$package.Name
                        packageName       = [string]$package.PackageFullName
                        family            = [string]$package.PackageFamilyName
                        isFramework       = [bool]$package.IsFramework
                        isResourcePackage = [bool]$package.IsResourcePackage
                        status            = [string]$package.Status
                        dependencies      = @($package.Dependencies | ForEach-Object {
                                [string]$_.PackageFullName
                            } | Sort-Object -Unique)
                        users             = $users
                    }
                })
            New-AuditArea -Data $items -Status $status -Scope $scope -Errors $errors
        }
        Services         = {
            param(
                $config,
                $context,
                $directory
            )

            $items = @(Get-CimInstance Win32_Service -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                    [ordered]@{
                        name             = [string]$_.Name
                        state            = [string]$_.State
                        startMode        = [string]$_.StartMode
                        delayedAutoStart = $_.DelayedAutoStart
                    }
                })
            New-AuditArea -Data $items
        }
        Policies         = {
            param(
                $config,
                $context,
                $directory
            )

            if ($config.Policies.Count -eq 0) {
                return (New-AuditArea -Status 'NotApplicable' -Scope 'ConfiguredRules')
            }

            $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
            $store = $null

            if (@($config.Policies.Values | Where-Object {
                        $_.ContainsKey('Verification') -and $_.Verification -eq 'LocalGpo' -and $edition -in @($_.Editions)
                    }).Count) {
                $store = Get-AuditLocalGpo -Path (Join-Path $env:WINDIR 'System32\GroupPolicy')
            }

            $items = @(foreach ($id in @($config.Policies.Keys | Sort-Object)) {
                    $rule = $config.Policies[$id]
                    $applicable = @($rule.Editions) -contains $edition
                    $observation = $null

                    if ($applicable) {
                        $observation = Read-AuditRegistryValue $rule.Path $rule.Name
                    }

                    $item = [ordered]@{
                        id             = $id
                        path           = $rule.Path
                        name           = $rule.Name
                        applicable     = $applicable
                        observation    = $observation
                        effectiveState = 'NotVerified'
                    }

                    if ($rule.ContainsKey('Verification') -and $rule.Verification -eq 'LocalGpo' -and $applicable) {
                        $item['localGpo'] = Get-AuditGpoObservation -Store $store -Rule $rule
                    }

                    $item
                })
            New-AuditArea -Data $items -Scope 'ConfiguredRegistryValues'
        }
        Deployment       = {
            param(
                $config,
                $context,
                $directory
            )

            $windows = Get-Partition -DriveLetter C -ErrorAction Stop
            $disk = Get-Disk -Number $windows.DiskNumber -ErrorAction Stop
            $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Sort-Object PartitionNumber | ForEach-Object {
                    $volume = @($_ | Get-Volume -ErrorAction Stop)
                    $fileSystem = $null
                    $clusterBytes = $null

                    if ($volume.Count -eq 1) {
                        $fileSystem = [string]$volume[0].FileSystem
                        $clusterBytes = $volume[0].AllocationUnitSize
                    }

                    [ordered]@{
                        number       = $_.PartitionNumber
                        sizeBytes    = $_.Size
                        offsetBytes  = $_.Offset
                        gptType      = [string]$_.GptType
                        letter       = [string]$_.DriveLetter
                        fileSystem   = $fileSystem
                        clusterBytes = $clusterBytes
                    }
                })
            $account = Get-LocalUser -SID $context.userSid -ErrorAction Stop
            $profilePath = (Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $context.userSid) -ErrorAction Stop).ProfileImagePath
            $administrators = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object {
                    $_.SID.Value
                })
            $recovery = @(& reagentc.exe /info 2>&1 | ForEach-Object {
                    [string]$_
                })

            if ($LASTEXITCODE -ne 0) {
                throw 'Cannot inspect Windows RE configuration.'
            }

            $encryption = @(foreach ($volume in @(Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop | Where-Object {
                            $_.DriveLetter -in @('C:', 'D:')
                        })) {
                    $state = Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop

                    if ($state.ReturnValue -ne 0) {
                        throw 'Cannot inspect BitLocker protection status.'
                    }

                    [ordered]@{ drive = $volume.DriveLetter; protectionStatus = $state.ProtectionStatus }
                })
            New-AuditArea -Data ([ordered]@{
                    computerName    = $env:COMPUTERNAME
                    accountName     = $account.Name
                    profilePath     = $profilePath
                    administrator   = ($context.userSid -in $administrators)
                    diskNumber      = $disk.Number
                    diskId          = $disk.UniqueId
                    diskModel       = $disk.FriendlyName
                    diskSerial      = $disk.SerialNumber
                    diskBytes       = $disk.Size
                    partitionStyle  = [string]$disk.PartitionStyle
                    partitions      = $partitions
                    recoveryEnabled = (($recovery -join ' ') -match 'Windows RE status:\s+Enabled')
                    encryption      = $encryption
                }) -Scope 'DeploymentProfile'
        }
        Servicing        = {
            param(
                $config,
                $context,
                $directory
            )

            Import-AuditDism
            $items = @(Get-WindowsPackage -Online -LogPath (Join-Path $directory 'packages-dism.log') -ErrorAction Stop | Sort-Object PackageName | ForEach-Object {
                    [ordered]@{
                        name        = [string]$_.PackageName
                        state       = [string]$_.PackageState
                        releaseType = [string]$_.ReleaseType
                    }
                })
            New-AuditArea -Data $items
        }
        Reboot           = {
            param(
                $config,
                $context,
                $directory
            )

            $cbs = Read-AuditRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' ''
            $wu = Read-AuditRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' ''
            $rename = Read-AuditRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
            $indicators = [ordered]@{
                cbsRebootPending            = $cbs.keyPresent
                windowsUpdateRebootRequired = $wu.keyPresent
                pendingFileRenameOperations = (@($rename.value | Where-Object {
                            $_
                        }).Count -gt 0)
            }
            New-AuditArea -Data ([ordered]@{ indicatorPresent = @($indicators.Values | Where-Object {
                            $_
                        }).Count -gt 0; indicators            = $indicators
                })
        }
    }
}

function New-AuditCheck {
    <#
    .SYNOPSIS
    Creates a compliance check record.

    .DESCRIPTION
    Keeps the configured requirement, observed value, result, and explanation together for JSON and Markdown reports.

    .PARAMETER Area
    Audit area to which the check belongs.

    .PARAMETER Id
    Stable identifier of the configured requirement.

    .PARAMETER Expected
    Configured value expected for this check.

    .PARAMETER Actual
    Observed value to compare with the configured requirement.

    .PARAMETER Status
    Collection or compliance status recorded in the result.

    .PARAMETER Reason
    Explanation recorded with the result.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. One compliance check.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory check result without changing system state.')]
    param(
        [string] $Area,
        [string] $Id,
        $Expected,
        $Actual,
        [string] $Status,
        [string] $Reason = ''
    )

    [ordered]@{
        area     = $Area
        id       = $Id
        expected = $Expected
        actual   = $Actual
        status   = $Status
        reason   = $Reason
    }
}

function Compare-AuditValue {
    <#
    .SYNOPSIS
    Compares an observed value with a configured requirement.

    .DESCRIPTION
    Returns a compliance check and uses NotVerified when collection cannot establish the actual value.

    .PARAMETER Area
    Audit area to which the check belongs.

    .PARAMETER Id
    Stable identifier of the configured requirement.

    .PARAMETER Expected
    Configured value expected for this check.

    .PARAMETER Actual
    Observed value to compare with the configured requirement.

    .PARAMETER Known
    Indicates that the actual value was collected completely enough to determine compliance.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. One comparison check.
    #>

    param(
        [string] $Area,
        [string] $Id,
        $Expected,
        $Actual,
        [bool] $Known
    )

    $status = 'NotVerified'

    if ($Known) {
        $status = 'NonCompliant'

        if ($Expected -ieq $Actual) {
            $status = 'Compliant'
        }
    }

    $reason = ''

    if (-not $Known) {
        $reason = 'Collection is incomplete, the identifier is unavailable, or the state is transitional; see collection evidence.'
    }

    New-AuditCheck -Area $Area -Id $Id -Expected $Expected -Actual $Actual -Status $status -Reason $reason
}

function Compare-AuditConfiguration {
    <#
    .SYNOPSIS
    Evaluates configured requirements against collected audit areas.

    .DESCRIPTION
    Checks only selected requirements and preserves collection limitations and policy applicability. Does not change collected data or repair the system.

    .PARAMETER Config
    Validated Windows configuration containing the selected requirements.

    .PARAMETER Areas
    Collected audit areas with their status, scope, observations, and errors.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. One compliance check record per evaluated requirement.
    #>

    param(
        $Config,
        $Areas
    )

    $os = $Areas.Os
    $edition = @{ Pro = 'Professional'; Enterprise = 'Enterprise' }[$Config.Edition]

    foreach ($rule in @(
            @('Edition', $edition, 'editionId'), @('Architecture', $Config.Architecture, 'architecture'),
            @('UiLanguage.SystemPreferred', $Config.Localization.UiLanguage, 'systemPreferredUiLanguage'),
            @('UiLanguage.CurrentProcess', $Config.Localization.UiLanguage, 'currentProcessUiLanguage')
        )) {
        $actual = $null

        if ($os.status -eq 'Complete') {
            $actual = $os.data[$rule[2]]
        }

        Compare-AuditValue -Area 'Os' -Id $rule[0] -Expected $rule[1] -Actual $actual -Known ($os.status -eq 'Complete' -and -not [string]::IsNullOrEmpty($actual) -and $actual -ne 'Unknown')
    }

    $windows11 = $null

    if ($os.status -eq 'Complete') {
        $windows11 = ([version]$os.data.version -ge [version]'10.0.22000.0' -and ([version]$os.data.version).Major -eq 10)
    }

    Compare-AuditValue -Area 'Os' -Id 'Windows11' -Expected $true -Actual $windows11 -Known ($null -ne $windows11)

    if ($os.status -eq 'Complete' -and $os.data.currentUserUiLanguageOverride) {
        Compare-AuditValue -Area 'Os' -Id 'UiLanguage.CurrentUserOverride' -Expected $Config.Localization.UiLanguage -Actual $os.data.currentUserUiLanguageOverride -Known $true
    }

    foreach ($locale in @($Config.Localization.InputLocales)) {
        $present = $null

        if ($os.status -eq 'Complete') {
            $present = (@($os.data.inputLocales) -contains $locale -or @($os.data.inputMethodTips) -contains $locale)
        }

        Compare-AuditValue -Area 'Os' -Id ('InputLocale.' + $locale) -Expected $true -Actual $present -Known ($null -ne $present)
    }

    $defaultLocale = $null

    if ($os.status -eq 'Complete') {
        $defaultLocale = $os.data.defaultInputLocale

        if ($Config.Localization.InputLocales[0] -match ':') {
            $defaultLocale = $os.data.defaultInputMethodTip
        }
    }

    Compare-AuditValue -Area 'Os' -Id 'DefaultInputLocale' -Expected $Config.Localization.InputLocales[0] -Actual $defaultLocale -Known (-not [string]::IsNullOrEmpty($defaultLocale))

    foreach ($section in @('OptionalFeatures', 'Capabilities')) {
        $area = $Areas[$section]

        foreach ($name in @($Config[$section].Keys | Sort-Object)) {
            $found = @($area.data | Where-Object {
                    $_.name -ieq $name
                })
            $actual = $null
            $known = $area.status -eq 'Complete' -and $found.Count -eq 1

            if ($known) {
                $actual = [string]$found[0].state

                if ($section -eq 'OptionalFeatures' -and $actual -eq 'DisabledWithPayloadRemoved') {
                    $actual = 'Disabled'
                }
                elseif ($section -eq 'Capabilities' -and $actual -eq 'Installed') {
                    $actual = 'Present'
                }
                elseif ($section -eq 'Capabilities' -and $actual -eq 'NotPresent') {
                    $actual = 'Absent'
                }

                if ($actual -notin @('Enabled', 'Disabled', 'Present', 'Absent')) {
                    $known = $false
                }
            }

            Compare-AuditValue -Area $section -Id $name -Expected $Config[$section][$name] -Actual $actual -Known $known
        }
    }

    foreach ($name in @($Config.InboxApps.Keys | Sort-Object)) {
        $family = Get-AuditPackageFamily $name
        $desired = $Config.InboxApps[$name]
        $provisioned = $Areas.ProvisionedApps
        $found = @($provisioned.data | Where-Object {
                $_.family -ieq $family
            })
        $actual = 'Absent'

        if ($found.Count -gt 0) {
            $actual = 'Present'
        }
        elseif ($provisioned.status -ne 'Complete') {
            $actual = $null
        }

        Compare-AuditValue -Area 'ProvisionedApps' -Id $family -Expected $desired -Actual $actual -Known ($found.Count -gt 0 -or $provisioned.status -eq 'Complete')

        # Present requires provisioning, not registration for every existing user.
        if ($desired -eq 'Absent') {
            $registered = $Areas.RegisteredApps
            $found = @($registered.data | Where-Object {
                    $_.family -ieq $family -and @($_.users | Where-Object {
                            $_.installState -eq 'Installed'
                        }).Count -gt 0
                })
            $actual = 'Absent'

            if ($found.Count -gt 0) {
                $actual = 'Present'
            }
            elseif ($registered.status -ne 'Complete') {
                $actual = $null
            }

            Compare-AuditValue -Area 'RegisteredApps' -Id $family -Expected 'Absent' -Actual $actual -Known ($found.Count -gt 0 -or $registered.status -eq 'Complete')
        }
    }

    foreach ($id in @($Config.Policies.Keys | Sort-Object)) {
        $found = @($Areas.Policies.data | Where-Object {
                $_.id -eq $id
            })
        $status = 'NotVerified'
        $reason = 'A registry value alone does not establish effective policy.'
        $actual = $null

        if ($Areas.Policies.status -eq 'Complete' -and $found.Count -eq 1) {
            if (-not $found[0].applicable) {
                $status = 'NotApplicable'
                $reason = 'The observed edition is outside the documented rule applicability.'
            }
            else {
                $actual = $found[0].observation
                $rule = $Config.Policies[$id]

                if (-not $actual.valuePresent -or $actual.kind -ne $rule.Kind -or (ConvertTo-Json -InputObject $actual.value -Compress) -cne (ConvertTo-Json -InputObject $rule.Value -Compress)) {
                    $status = 'NonCompliant'
                    $reason = 'The configured registry observation does not match; policy effectiveness is not verified.'
                }
                elseif ($rule.ContainsKey('Verification') -and $rule.Verification -eq 'LocalGpo') {
                    $gpo = $found[0].localGpo
                    $actual = [ordered]@{ registry = $actual; localGpo = $gpo }
                    $status = 'NonCompliant'
                    $reason = 'The local GPO store or processing metadata differs from the configured policy.'

                    if ($gpo.metadataValid -and $gpo.valuePresent -and $gpo.kind -eq $rule.Kind -and (ConvertTo-Json -InputObject $gpo.value -Compress) -ceq (ConvertTo-Json -InputObject $rule.Value -Compress)) {
                        $status = 'Compliant'
                        $reason = 'Local GPO delivery and registry state match; user-facing behavior is not assessed.'

                        if ($rule.ContainsKey('FileContent') -and -not $gpo.file.matches) {
                            $status = 'NonCompliant'
                            $reason = 'The JSON file referenced by the local GPO is missing or differs from configuration.'
                        }
                    }
                }
            }
        }

        New-AuditCheck -Area 'Policies' -Id $id -Expected $Config.Policies[$id].Value -Actual $actual -Status $status -Reason $reason
    }

    if ($Config.ContainsKey('Deployment')) {
        $area = $Areas.Deployment

        if ($area.status -ne 'Complete') {
            Compare-AuditValue -Area Deployment -Id Configuration -Expected 'Configured deployment profile' -Actual $null -Known $false
        }
        else {
            $data = $area.data
            $policy = $Config.Deployment.Disk
            # Independently calculate expected sizes from observed disk capacity.
            $size = @($policy.WindowsSizesGiB | Sort-Object @{ Expression = {
                        [math]::Abs($_ * 1GB - $data.diskBytes * $policy.WindowsFraction)
                    }
                }, @{ Expression  = {
                        $_
                    }; Descending = $true
                })[0] * 1GB
            $available = [math]::Floor($data.diskBytes / 1MB) * 1MB - ($policy.EfiMiB + $policy.MsrMiB + $policy.RecoveryMiB + 4) * 1MB
            $expectedPartitions = @(
                @('C12A7328-F81F-11D2-BA4B-00A0C93EC93B', ($policy.EfiMiB * 1MB), '', 'FAT32'),
                @('E3C9E316-0B5C-4DB8-817D-F92DF00215AE', ($policy.MsrMiB * 1MB), '', ''),
                @('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7', $size, 'C', 'NTFS'),
                @('DE94BBA4-06D1-4D40-A16A-BFD50179D6AC', ($policy.RecoveryMiB * 1MB), '', 'NTFS')
            )

            if ($available -ge 2 * $size) {
                $expectedPartitions += , @('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7', $size, 'D', 'NTFS')
            }

            Compare-AuditValue -Area Deployment -Id PartitionStyle -Expected GPT -Actual $data.partitionStyle -Known $true
            Compare-AuditValue -Area Deployment -Id PartitionCount -Expected $expectedPartitions.Count -Actual @($data.partitions).Count -Known $true
            $layoutMatches = @($data.partitions).Count -eq $expectedPartitions.Count
            $alignmentMatches = $true
            $ntfsDefaults = $true

            for ($index = 0; $index -lt @($data.partitions).Count; $index++) {
                $partition = $data.partitions[$index]

                if ($index -lt $expectedPartitions.Count) {
                    $expected = $expectedPartitions[$index]
                    $layoutMatches = $layoutMatches -and $partition.gptType.Trim('{}') -ieq $expected[0] -and $partition.sizeBytes -eq $expected[1] -and $partition.letter.Trim([char]0) -ceq $expected[2] -and [string]$partition.fileSystem -ieq $expected[3]
                }

                $alignmentMatches = $alignmentMatches -and $partition.offsetBytes % ($policy.AlignmentMiB * 1MB) -eq 0

                if ($partition.fileSystem -eq 'NTFS' -and $partition.clusterBytes -ne 4096) {
                    $ntfsDefaults = $false
                }
            }

            Compare-AuditValue -Area Deployment -Id PartitionLayout -Expected $true -Actual $layoutMatches -Known $true
            Compare-AuditValue -Area Deployment -Id PartitionAlignment -Expected $true -Actual $alignmentMatches -Known $true
            Compare-AuditValue -Area Deployment -Id NtfsDefaults -Expected $true -Actual $ntfsDefaults -Known $true
            Compare-AuditValue -Area Deployment -Id ComputerName -Expected ($Config.Deployment.ComputerNamePrefix + '<7 uppercase letters/digits>') -Actual $data.computerName -Known $true | ForEach-Object {
                $_.status = 'NonCompliant'

                if ($data.computerName -cmatch ('^' + [regex]::Escape($Config.Deployment.ComputerNamePrefix) + '[A-Z0-9]{7}$')) {
                    $_.status = 'Compliant'
                }

                $_
            }
            Compare-AuditValue -Area Deployment -Id LocalProfileName -Expected $data.accountName -Actual (Split-Path $data.profilePath -Leaf) -Known $true | ForEach-Object {
                if ($_.expected -cne $_.actual) {
                    $_.status = 'NonCompliant'
                }

                $_
            }
            Compare-AuditValue -Area Deployment -Id Administrator -Expected $true -Actual $data.administrator -Known $true
            Compare-AuditValue -Area Deployment -Id WindowsRE -Expected $true -Actual $data.recoveryEnabled -Known $true
        }
    }
}

function ConvertTo-AuditMarkdown {
    <#
    .SYNOPSIS
    Renders the audit report as readable Markdown.

    .DESCRIPTION
    Summarizes collection completeness, requirement checks, and observations from the same report used for JSON output.

    .PARAMETER Report
    Completed audit report containing context, areas, checks, and summary.

    .OUTPUTS
    System.String. Markdown report text.
    #>

    param(
        $Report
    )

    $lines = @('# Windows audit', '', ('Mode: {0}. UTC: {1}. Exit code: {2}.' -f $Report.context.mode, $Report.startedAtUtc, $Report.exitCode), '',
        ('Checks: {0} compliant, {1} noncompliant, {2} not verified, {3} not applicable.' -f $Report.summary.compliant, $Report.summary.nonCompliant, $Report.summary.notVerified, $Report.summary.notApplicable), '',
        '| Collection | Status | Scope |', '| --- | --- | --- |')

    foreach ($name in $Report.areas.Keys) {
        $lines += '| {0} | {1} | {2} |' -f $name, $Report.areas[$name].status, $Report.areas[$name].scope
    }

    $lines += @('', '## Findings', '')

    foreach ($check in @($Report.checks | Where-Object {
                $_.status -ne 'Compliant'
            })) {
        $text = '{0}: {1} / {2}; expected {3}; observed {4}. {5}' -f $check.status, $check.area, $check.id, (ConvertTo-Json -InputObject $check.expected -Compress -Depth 6), (ConvertTo-Json -InputObject $check.actual -Compress -Depth 6), $check.reason
        # Keep identifiers and error text from creating Markdown structure or HTML.
        $text = [Net.WebUtility]::HtmlEncode(($text -replace '[\r\n]+', ' ')).Replace('|', '&#124;').Replace('`', '&#96;')
        $lines += '- ' + $text
    }

    if ($Report.summary.nonCompliant -eq 0 -and $Report.summary.notVerified -eq 0) {
        $lines += 'No unresolved configuration checks.'
    }

    foreach ($name in $Report.areas.Keys) {
        foreach ($message in $Report.areas[$name].errors) {
            $lines += '- Collection error ({0}): {1}' -f $name, [Net.WebUtility]::HtmlEncode(($message -replace '[\r\n]+', ' ')).Replace('`', '&#96;')
        }
    }

    $lines += @('', 'Reboot indicators and service running states are observations, not compliance rules. See audit.json for inventory, scope, dependencies, and evidence. System preferred and process UI language checks do not prove the language of every desktop session.', '')
    $lines -join [Environment]::NewLine
}

function Invoke-WindowsAudit {
    <#
    .SYNOPSIS
    Collects and checks installed Windows in a new owned report directory.

    .DESCRIPTION
    Locks a new output directory under .local/audit, collects each area, and writes JSON and Markdown reports. Test fixtures may supply collectors and context instead of live inspection.

    .PARAMETER ConfigurationPath
    Path to the PowerShell data file describing the installed-system requirements to audit.

    .PARAMETER OutputDirectory
    New report directory directly under the repository .local/audit directory.

    .PARAMETER Collectors
    Optional collector map for fixture or controlled collection; defaults to the live collectors.

    .PARAMETER Context
    Optional collection context paired with injected collectors; defaults to the live runtime context.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. Completed audit report.
    #>

    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [string] $ConfigurationPath,
        [string] $OutputDirectory,
        [hashtable] $Collectors,
        $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $configurationHash = (Get-FileHash -LiteralPath $ConfigurationPath -Algorithm SHA256).Hash
    $config = Read-AuditConfiguration $ConfigurationPath

    if ($configurationHash -ne (Get-FileHash -LiteralPath $ConfigurationPath -Algorithm SHA256).Hash) {
        throw 'Configuration changed while it was being imported.'
    }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        throw 'Specify a new OutputDirectory under .local/audit.'
    }

    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.local\audit')).TrimEnd('\')
    $output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')

    if ([IO.Path]::GetDirectoryName($output) -ine $root) {
        throw 'OutputDirectory must be directly under the repository .local/audit directory.'
    }

    $ancestor = $output

    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Audit paths must not contain reparse points.'
        }

        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }

    $order = @('Os', 'OptionalFeatures', 'Capabilities', 'ProvisionedApps', 'RegisteredApps', 'Services', 'Policies', 'Servicing', 'Reboot')

    if ($config.ContainsKey('Deployment')) {
        $order += 'Deployment'
    }
    if ($null -eq $Collectors) {
        $Collectors = Get-AuditCollectors
    }

    foreach ($name in $order) {
        if (-not $Collectors.ContainsKey($name)) {
            throw "Collector missing: $name"
        }
    }

    if ($null -eq $Context) {
        $Context = Get-AuditContext
    }

    [IO.Directory]::CreateDirectory($root) | Out-Null
    $lockPath = $output + '.lock'

    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Audit locks must not be reparse points.'
    }

    $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)

    try {
        if (Test-Path -LiteralPath $output) {
            throw 'OutputDirectory already exists; choose a new run directory. Previous audit reports are never deleted.'
        }

        [IO.Directory]::CreateDirectory($output) | Out-Null
        $report = [ordered]@{
            schemaVersion  = 1
            startedAtUtc   = [DateTime]::UtcNow.ToString('o')
            completedAtUtc = $null
            context        = $Context
            configuration  = [ordered]@{ sha256 = $configurationHash; desired = $config }
            areas          = [ordered]@{}
            checks         = @()
            summary        = $null
            exitCode       = 4
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

                    if ($Context.isAdministrator) {
                        $scope = 'AllUsers'
                    }
                }
                elseif ($name -eq 'Policies') {
                    $scope = 'ConfiguredRules'
                }

                $report.areas[$name] = New-AuditArea -Status 'Failed' -Scope $scope -Errors @($_.Exception.Message)
            }
        }

        $report.checks = @(Compare-AuditConfiguration $config $report.areas)
        $report.summary = [ordered]@{
            compliant       = @($report.checks | Where-Object {
                    $_.status -eq 'Compliant'
                }).Count
            nonCompliant    = @($report.checks | Where-Object {
                    $_.status -eq 'NonCompliant'
                }).Count
            notVerified     = @($report.checks | Where-Object {
                    $_.status -eq 'NotVerified'
                }).Count
            notApplicable   = @($report.checks | Where-Object {
                    $_.status -eq 'NotApplicable'
                }).Count
            incompleteAreas = @($report.areas.Values | Where-Object {
                    $_.status -in @('Failed', 'Partial')
                }).Count
        }
        $report.exitCode = 0

        if ($report.summary.nonCompliant -gt 0) {
            $report.exitCode = 1
        }
        if ($report.summary.incompleteAreas -gt 0 -or $report.summary.notVerified -gt 0) {
            $report.exitCode = $report.exitCode -bor 2
        }

        $report.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        $encoding = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $output 'audit.json'), (ConvertTo-Json -InputObject $report -Depth 30), $encoding)
        [IO.File]::WriteAllText((Join-Path $output 'audit.md'), (ConvertTo-AuditMarkdown $report), $encoding)
        $report
    }
    finally {
        $lock.Dispose()
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
        throw 'Use a fresh 64-bit Windows PowerShell 5.1 process.'
    }
    if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
        $ConfigurationPath = Join-Path $PSScriptRoot '..\config\windows.psd1'
    }

    $result = Invoke-WindowsAudit -ConfigurationPath $ConfigurationPath -OutputDirectory $OutputDirectory
    Write-Output ('Audit completed. Exit code: {0}. Reports: {1}' -f $result.exitCode, $OutputDirectory)
    exit $result.exitCode
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 4
}
