#Requires -Version 5.1

<#
.SYNOPSIS
Generates a commented key/value component template from an existing catalog.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $CatalogPath,
    [Parameter(Mandatory = $true)]
    [string] $OutputPath,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$catalogFullPath = (Resolve-Path -LiteralPath $CatalogPath).ProviderPath
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if ($catalogFullPath -ieq $outputFullPath) { throw 'The output must not overwrite the input catalog.' }
if ((Test-Path -LiteralPath $outputFullPath) -and -not $Force) { throw 'The output exists; use -Force to regenerate it.' }
$catalog = Get-Content -LiteralPath $catalogFullPath -Raw | ConvertFrom-Json
if ($catalog.schemaVersion -ne 1) { throw 'Unsupported catalog schema version.' }
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Source: ' + $catalog.sourceImage.name + ' ' + $catalog.sourceImage.version + ', ' + $catalog.sourceImage.architecture + ', ' + $catalog.sourceImage.defaultLanguage + '; source index ' + $catalog.sourceImage.index + '.')
$lines.Add('# All rules are commented out. Each suggested value preserves the observed source state.')
$lines.Add('# Features: Enabled/Disabled. Capabilities and inbox apps: Present/Absent.')
$lines.Add('@{')
$lines.Add('    SchemaVersion = 2')

function Add-ComponentRule([string] $Identifier, [string] $State, [string] $Description) {
    if ([string]::IsNullOrWhiteSpace($Identifier) -or $Identifier -match '[\r\n]') { throw 'Invalid component identifier.' }
    $escapedIdentifier = $Identifier.Replace("'", "''")
    $lines.Add("        # '" + $escapedIdentifier + "' = '" + $State + "' # " + $Description)
}

function Get-OrderedComponents([object[]] $Items, [string] $IdentityProperty) {
    # Use ordinal ordering so Windows PowerShell and PowerShell 7 render identically.
    $orderedItems = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) {
        $identifier = [string] $item.$IdentityProperty
        if ([string]::IsNullOrWhiteSpace($identifier)) { throw 'Invalid component identifier.' }
        if ($orderedItems.ContainsKey($identifier)) { throw ('Duplicate component identifier: ' + $identifier) }
        $orderedItems.Add($identifier, $item)
    }
    return $orderedItems.Values
}

$lines.Add('    OptionalFeatures = @{')
foreach ($feature in @(Get-OrderedComponents $catalog.optionalFeatures 'name')) {
    $state = switch ($feature.state) {
        'Enabled' { 'Enabled' }
        'Disabled' { 'Disabled' }
        'DisabledWithPayloadRemoved' { 'Disabled' }
        default { throw ('Unsupported source feature state: ' + $feature.state) }
    }
    Add-ComponentRule $feature.name $state ('Source state: ' + $feature.state)
}
$lines.Add('    }')

$lines.Add('    Capabilities = @{')
foreach ($capability in @(Get-OrderedComponents $catalog.capabilities 'name')) {
    $state = switch ($capability.state) {
        'Installed' { 'Present' }
        'NotPresent' { 'Absent' }
        default { throw ('Unsupported source capability state: ' + $capability.state) }
    }
    Add-ComponentRule $capability.name $state ('Source state: ' + $capability.state)
}
$lines.Add('    }')

$lines.Add('    InboxApps = @{')
foreach ($app in @(Get-OrderedComponents $catalog.provisionedApps 'packageName')) {
    Add-ComponentRule $app.packageName 'Present' 'Source: provisioned. Review dependencies before selecting Absent.'
}
$lines.Add('    }')
$lines.Add('}')

[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputFullPath)) | Out-Null
[IO.File]::WriteAllLines($outputFullPath, $lines, [Text.UTF8Encoding]::new($false))
Import-PowerShellDataFile -LiteralPath $outputFullPath | Out-Null
