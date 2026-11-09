#Requires -Version 5.1
<#
.SYNOPSIS
Compares saved audits for repeatability or drift without guest or Hyper-V access.
.DESCRIPTION
Writes comparison.json. Repeatability ignores reboot observations and service running
states; drift includes reboot observations. Partial areas never prove additions or
removals. Collection receipts are optional, but matching receipts are checked when present.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Repeatability', 'Drift')] [string] $Mode,
    [Parameter(Mandatory = $true)] [string] $Before,
    [Parameter(Mandatory = $true)] [string] $After,
    [Parameter(Mandatory = $true)] [string] $OutputDirectory
)

function ConvertTo-AuditCanonicalValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value.GetType().IsValueType) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) { $result[$key] = ConvertTo-AuditCanonicalValue $Value[$key] }
        return $result
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-AuditCanonicalValue $_ })
        # Collector arrays are sets; preserve records and identities while ignoring enumeration order.
        return ,@($items | Sort-Object { ConvertTo-Json -InputObject $_ -Depth 40 -Compress })
    }
    $result = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) { $result[$property.Name] = ConvertTo-AuditCanonicalValue $property.Value }
    $result
}

function Get-AuditComparison {
    param([ValidateSet('Repeatability', 'Drift')] [string] $Mode, [string] $Before, [string] $After)
    $paths = @((Resolve-Path -LiteralPath $Before).ProviderPath, (Resolve-Path -LiteralPath $After).ProviderPath)
    $reports = @($paths | ForEach-Object { Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json })
    foreach ($report in $reports) {
        if ($report.schemaVersion -ne 1 -or -not $report.areas -or @($report.areas.PSObject.Properties).Count -eq 0 -or -not $report.configuration.sha256) { throw 'Expected audit schema 1 with areas and a configuration fingerprint.' }
    }
    if ($reports[0].configuration.sha256 -cne $reports[1].configuration.sha256) { throw 'Audit configurations differ.' }
    if ($reports[0].context.userSid -cne $reports[1].context.userSid) { throw 'Audit user contexts differ.' }
    $receipts = @($paths | ForEach-Object {
        $path = Join-Path (Split-Path $_ -Parent) 'collection.json'
        if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } else { $null }
    })
    if ($null -ne $receipts[0] -and $null -ne $receipts[1]) {
        foreach ($key in @('vmId', 'configurationSha256', 'auditScriptSha256')) {
            if (-not $receipts[0].$key -or $receipts[0].$key -cne $receipts[1].$key) { throw ('Collection provenance differs: ' + $key) }
        }
        foreach ($index in @(0, 1)) {
            if ($receipts[$index].configurationSha256 -cne $reports[$index].configuration.sha256) { throw 'Collection receipt differs from its audit configuration.' }
        }
    }
    $identities = @{ OptionalFeatures = 'name'; Capabilities = 'name'; ProvisionedApps = 'family'; RegisteredApps = 'packageName'; Services = 'name'; Policies = 'id'; Servicing = 'name' }
    $changes = [ordered]@{}
    $complete = $true
    $match = $true
    $names = @(@($reports[0].areas.PSObject.Properties.Name) + @($reports[1].areas.PSObject.Properties.Name) | Sort-Object -Unique)
    foreach ($name in $names) {
        if ($Mode -eq 'Repeatability' -and $name -eq 'Reboot') { continue }
        $areas = @($reports | ForEach-Object {
            $property = $_.areas.PSObject.Properties[$name]
            if ($property) { $property.Value } else { $null }
        })
        $comparable = $null -ne $areas[0] -and $null -ne $areas[1] -and $areas[0].status -in @('Complete', 'NotApplicable') -and $areas[1].status -in @('Complete', 'NotApplicable') -and $areas[0].status -ceq $areas[1].status -and $areas[0].scope -ceq $areas[1].scope
        $entry = [ordered]@{ comparable = [bool]$comparable; before = $areas[0]; after = $areas[1]; added = @(); removed = @(); changed = @() }
        if (-not $comparable) { $complete = $false; $match = $false; $changes[$name] = $entry; continue }
        if ($areas[0].status -eq 'NotApplicable') { $changes[$name] = $entry; continue }
        if ($identities.ContainsKey($name)) {
            $maps = @()
            foreach ($area in $areas) {
                $map = @{}
                foreach ($record in @($area.data)) {
                    $key = [string]$record.($identities[$name])
                    if (-not $key -or $map.ContainsKey($key)) { throw ('Missing or duplicate identity in ' + $name) }
                    $value = $record
                    if ($name -eq 'Services') { $value = $record | Select-Object name, startMode, delayedAutoStart }
                    $map[$key] = ConvertTo-AuditCanonicalValue $value
                }
                $maps += ,$map
            }
            foreach ($key in @($maps[1].Keys | Sort-Object)) {
                if (-not $maps[0].ContainsKey($key)) { $entry.added += $maps[1][$key] }
                elseif ((ConvertTo-Json -InputObject $maps[0][$key] -Depth 40 -Compress) -cne (ConvertTo-Json -InputObject $maps[1][$key] -Depth 40 -Compress)) { $entry.changed += [ordered]@{ id = $key; before = $maps[0][$key]; after = $maps[1][$key] } }
            }
            foreach ($key in @($maps[0].Keys | Sort-Object)) { if (-not $maps[1].ContainsKey($key)) { $entry.removed += $maps[0][$key] } }
        }
        else {
            $old = ConvertTo-AuditCanonicalValue $areas[0].data
            $new = ConvertTo-AuditCanonicalValue $areas[1].data
            if ((ConvertTo-Json -InputObject $old -Depth 40 -Compress) -cne (ConvertTo-Json -InputObject $new -Depth 40 -Compress)) { $entry.changed += [ordered]@{ before = $old; after = $new } }
        }
        if ($entry.added.Count + $entry.removed.Count + $entry.changed.Count -gt 0) { $match = $false }
        $changes[$name] = $entry
    }
    $ignored = @('report timestamps', 'service running states')
    if ($Mode -eq 'Repeatability') { $ignored += 'reboot observations' }
    [pscustomobject][ordered]@{
        schemaVersion = 1; mode = $Mode; comparisonComplete = $complete; stableAreasMatch = $match
        beforeReport = $paths[0]; afterReport = $paths[1]
        beforeSha256 = (Get-FileHash -LiteralPath $paths[0] -Algorithm SHA256).Hash
        afterSha256 = (Get-FileHash -LiteralPath $paths[1] -Algorithm SHA256).Hash
        beforeReceipt = $receipts[0]; afterReceipt = $receipts[1]
        beforeExitCode = $reports[0].exitCode; afterExitCode = $reports[1].exitCode
        beforeSummary = $reports[0].summary; afterSummary = $reports[1].summary; changes = $changes
        ignoredVolatileFields = $ignored
        comparedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = Get-AuditComparison -Mode $Mode -Before $Before -After $After
$output = [IO.Path]::GetFullPath($OutputDirectory)
$path = Join-Path $output 'comparison.json'
foreach ($target in @($output, $path)) {
    while ($target) {
        if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Comparison output must not contain reparse points.' }
        $target = [IO.Path]::GetDirectoryName($target)
    }
}
if (Test-Path -LiteralPath $path) { throw 'Comparison output already exists; preserve it or choose a new output directory.' }
if ($path -iin @($result.beforeReport, $result.afterReport)) { throw 'Comparison output must not overwrite its inputs.' }
[IO.Directory]::CreateDirectory($output) | Out-Null
$file = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $writer = [IO.StreamWriter]::new($file, [Text.UTF8Encoding]::new($false))
    try { $writer.WriteLine(($result | ConvertTo-Json -Depth 50)) } finally { $writer.Dispose() }
}
finally { $file.Dispose() }
if (-not $result.comparisonComplete) { throw ('Audit comparison is incomplete; see ' + $path) }
if ($Mode -eq 'Repeatability' -and -not $result.stableAreasMatch) { throw ('Stable audit inventories differ; see ' + $path) }
Write-Output ('Audit comparison ready: ' + $path)
