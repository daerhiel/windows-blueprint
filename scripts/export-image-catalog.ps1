#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Exports component catalogs from the pinned Windows image without servicing it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IsoPath,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [string] $SourceLockPath = (Join-Path $PSScriptRoot '..\config\source-image.lock.json'),
    [string] $ToolchainLockPath = (Join-Path $PSScriptRoot '..\config\toolchain.lock.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$sourceLock = Get-Content -LiteralPath $SourceLockPath -Raw | ConvertFrom-Json
$toolchainLock = Get-Content -LiteralPath $ToolchainLockPath -Raw | ConvertFrom-Json
if ($null -eq $sourceLock.selectedImage) {
    throw 'Select and pin a source image before exporting a catalog.'
}
$isoFullPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
$outputFullPath = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$catalogRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.local\catalog'))
if ([IO.Path]::GetDirectoryName($outputFullPath) -ine $catalogRoot) {
    throw 'OutputDirectory must be directly under the repository .local/catalog directory.'
}
foreach ($inputPath in @($isoFullPath, (Resolve-Path -LiteralPath $SourceLockPath).ProviderPath, (Resolve-Path -LiteralPath $ToolchainLockPath).ProviderPath)) {
    if ($inputPath.StartsWith($outputFullPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source files must be outside the output directory.' }
}
foreach ($checkedPath in @((Split-Path $catalogRoot -Parent), $catalogRoot, $outputFullPath, ($outputFullPath + '.lock'))) {
    if ((Test-Path -LiteralPath $checkedPath) -and ((Get-Item -LiteralPath $checkedPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Catalog paths must not contain reparse points.'
    }
}
[IO.Directory]::CreateDirectory($catalogRoot) | Out-Null
$directoryLock = $null
$outputPrepared = $false
$mountPath = Join-Path $outputFullPath 'mount'
$scratchPath = Join-Path $outputFullPath 'scratch'
$wimPath = Join-Path $outputFullPath 'pro.wim'
$dismLogPath = Join-Path $outputFullPath 'dism.log'
$operationPath = Join-Path $outputFullPath 'operation.json'
$createdIsoAttachment = $false
$createdWimMount = $false
$operation = [ordered]@{
    schemaVersion  = 1
    status         = 'Running'
    stage          = 'Preflight'
    startedAtUtc   = [DateTime]::UtcNow.ToString('o')
    detachedIso    = $false
    unmountedImage = $false
    error          = $null
    cleanupErrors  = @()
}

function Save-Operation {
    $operation | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $operationPath -Encoding UTF8
}

function Set-OperationStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Records required progress in the exporter-owned report; does not change the source image.')]
    param([string] $Name)
    $operation.stage = $Name
    Save-Operation
}

function Add-SelectionMap {
    param(
        [Collections.Generic.List[string]] $Lines,
        [string] $Name,
        [object[]] $Entries
    )
    $orderedEntries = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Entries) {
        $identifier = [string] $entry.Id
        if ([string]::IsNullOrWhiteSpace($identifier) -or $identifier -match '[\r\n]') { throw 'Invalid component identifier.' }
        if ($orderedEntries.ContainsKey($identifier)) { throw ('Duplicate component identifier: ' + $identifier) }
        $orderedEntries.Add($identifier, $entry)
    }
    $Lines.Add('    ' + $Name + ' = @{')
    foreach ($entry in $orderedEntries.Values) {
        $identifier = ([string] $entry.Id).Replace("'", "''")
        $Lines.Add("        # '" + $identifier + "' = '" + $entry.State + "' # " + $entry.Description)
    }
    $Lines.Add('    }')
}

try {
    try {
        $directoryLock = [IO.FileStream]::new(($outputFullPath + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    }
    catch { throw 'Another export is using this output directory.' }
    if ((Get-FileHash -LiteralPath $isoFullPath -Algorithm SHA256).Hash -ne $sourceLock.iso.sha256) {
        throw 'The ISO fingerprint does not match the source lock.'
    }

    $dismDirectory = $toolchainLock.adk.dismDirectory
    foreach ($toolFile in $toolchainLock.adk.files.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $dismDirectory $toolFile.Name) -Algorithm SHA256).Hash -ne $toolFile.Value) {
            throw ('Toolchain fingerprint mismatch: ' + $toolFile.Name)
        }
    }
    if (Get-Module Dism) {
        throw 'Run in a fresh Windows PowerShell process with -NoProfile.'
    }

    # Bind the cmdlets to the pinned ADK native API rather than the inbox DLL.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CatalogNativeLoader {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
}
'@
    $nativeHandle = [CatalogNativeLoader]::LoadLibraryEx((Join-Path $dismDirectory 'dismapi.dll'), [IntPtr]::Zero, 8)
    if ($nativeHandle -eq [IntPtr]::Zero) {
        throw ('Cannot load the ADK native API: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    Import-Module (Join-Path $dismDirectory 'dism.psd1')
    Import-Module Storage
    $loadedDismApi = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object { $_.ModuleName -ieq 'dismapi.dll' })
    if ($loadedDismApi.Count -ne 1 -or $loadedDismApi[0].FileName -ine (Join-Path $dismDirectory 'dismapi.dll')) {
        throw 'The process did not load the pinned ADK native API.'
    }

    $registeredMounts = @(Get-WindowsImage -Mounted)
    foreach ($registeredMount in $registeredMounts) {
        if ($registeredMount.Path -ieq $outputFullPath -or $registeredMount.Path.StartsWith($outputFullPath + '\', [StringComparison]::OrdinalIgnoreCase) -or $registeredMount.ImagePath.StartsWith($outputFullPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A Windows image in this output directory is still mounted.'
        }
    }
    if (Test-Path -LiteralPath $outputFullPath) {
        $resolvedOutputPath = (Resolve-Path -LiteralPath $outputFullPath).ProviderPath
        if ([IO.Path]::GetDirectoryName($resolvedOutputPath) -ine $catalogRoot) { throw 'Unsafe catalog cleanup path.' }
        if (@(Get-ChildItem -LiteralPath $resolvedOutputPath -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw 'Catalog contents must not contain reparse points.' }
        Remove-Item -LiteralPath $resolvedOutputPath -Recurse -Force
    }
    $outputDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($outputFullPath))
    if ($outputDrive.AvailableFreeSpace -lt 20GB) { throw 'At least 20 GiB of free space is required on the output drive.' }
    [IO.Directory]::CreateDirectory($outputFullPath) | Out-Null
    $outputPrepared = $true
    Save-Operation
    [IO.Directory]::CreateDirectory($mountPath) | Out-Null
    [IO.Directory]::CreateDirectory($scratchPath) | Out-Null
    Set-OperationStage 'Attach ISO'
    $diskImage = Get-DiskImage -ImagePath $isoFullPath
    if (-not $diskImage.Attached) {
        $diskImage = Mount-DiskImage -ImagePath $isoFullPath -StorageType ISO -Access ReadOnly -PassThru
        $createdIsoAttachment = $true
    }
    $sourceImages = @(
        foreach ($volume in @($diskImage | Get-Volume)) {
            if ($volume.DriveLetter) {
                $candidate = Join-Path ('{0}:\' -f $volume.DriveLetter) $sourceLock.selectedImage.path
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
            }
        }
    )
    if ($sourceImages.Count -ne 1) { throw 'Cannot locate the pinned installation image.' }
    $sourceImage = $sourceImages[0]
    $imageInfo = Get-WindowsImage -ImagePath $sourceImage -Index $sourceLock.selectedImage.index -LogPath $dismLogPath -ScratchDirectory $scratchPath
    $imageVersion = '{0}.{1}.{2}.{3}' -f $imageInfo.MajorVersion, $imageInfo.MinorVersion, $imageInfo.Build, $imageInfo.SPBuild
    if ($imageInfo.EditionId -ne $sourceLock.selectedImage.editionId -or $imageInfo.Architecture -ne 9 -or $imageVersion -ne $sourceLock.selectedImage.version -or $imageInfo.Languages[$imageInfo.DefaultLanguageIndex] -ne $sourceLock.selectedImage.defaultLanguage) {
        throw 'The selected image metadata does not match the source lock.'
    }

    Set-OperationStage 'Export Pro to working WIM'
    Export-WindowsImage -SourceImagePath $sourceImage -SourceIndex $sourceLock.selectedImage.index -DestinationImagePath $wimPath -CompressionType Fast -CheckIntegrity -LogPath $dismLogPath -ScratchDirectory $scratchPath | Out-Null
    Set-OperationStage 'Mount working WIM read-only'
    Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountPath -ReadOnly -CheckIntegrity -LogPath $dismLogPath -ScratchDirectory $scratchPath | Out-Null
    $createdWimMount = $true

    Set-OperationStage 'Read Optional Features'
    $features = @(Get-WindowsOptionalFeature -Path $mountPath -LogPath $dismLogPath -ScratchDirectory $scratchPath | Sort-Object FeatureName | ForEach-Object {
            [ordered]@{ name = $_.FeatureName; state = [string] $_.State }
        })
    Set-OperationStage 'Read Windows Capabilities'
    $capabilities = @(Get-WindowsCapability -Path $mountPath -LimitAccess -LogPath $dismLogPath -ScratchDirectory $scratchPath | Sort-Object Name | ForEach-Object {
            [ordered]@{ name = $_.Name; state = [string] $_.State }
        })
    Set-OperationStage 'Read provisioned Appx'
    $apps = @(Get-AppxProvisionedPackage -Path $mountPath -LogPath $dismLogPath -ScratchDirectory $scratchPath | Sort-Object PackageName | ForEach-Object {
            [ordered]@{ displayName = $_.DisplayName; packageName = $_.PackageName; version = [string] $_.Version; architecture = [string] $_.Architecture; dependencyReview = 'RequiredBeforeRemoval' }
        })

    Set-OperationStage 'Write catalog and selection template'
    $catalog = [ordered]@{
        schemaVersion    = 1
        sourceIsoSha256  = $sourceLock.iso.sha256
        sourceImage      = $sourceLock.selectedImage
        adkVersion       = $toolchainLock.adk.version
        optionalFeatures = $features
        capabilities     = $capabilities
        provisionedApps  = $apps
    }
    $catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputFullPath 'catalog.json') -Encoding UTF8
    $featureEntries = @($features | ForEach-Object {
            $state = switch ($_.state) {
                'Enabled' { 'Enabled' }
                'Disabled' { 'Disabled' }
                'DisabledWithPayloadRemoved' { 'Disabled' }
                default { throw ('Unsupported source feature state: ' + $_.state) }
            }
            [pscustomobject]@{ Id = $_.name; State = $state; Description = 'Source state: ' + $_.state }
        })
    $capabilityEntries = @($capabilities | ForEach-Object {
            $state = switch ($_.state) {
                'Installed' { 'Present' }
                'NotPresent' { 'Absent' }
                default { throw ('Unsupported source capability state: ' + $_.state) }
            }
            [pscustomobject]@{ Id = $_.name; State = $state; Description = 'Source state: ' + $_.state }
        })
    $appEntries = @($apps | ForEach-Object {
            [pscustomobject]@{ Id = $_.packageName; State = 'Present'; Description = 'Source: provisioned. Review dependencies before selecting Absent.' }
        })
    $selectionLines = [Collections.Generic.List[string]]::new()
    $selectionLines.Add('# Source: ' + $sourceLock.selectedImage.name + ' ' + $imageVersion + ', ' + $sourceLock.selectedImage.architecture + ', ' + $sourceLock.selectedImage.defaultLanguage + '; source index ' + $sourceLock.selectedImage.index + '.')
    $selectionLines.Add('# All rules are commented out. Each suggested value preserves the observed source state.')
    $selectionLines.Add('# Features: Enabled/Disabled. Capabilities and inbox apps: Present/Absent.')
    $selectionLines.Add('@{')
    $selectionLines.Add('    SchemaVersion = 1')
    Add-SelectionMap -Lines $selectionLines -Name 'OptionalFeatures' -Entries $featureEntries
    Add-SelectionMap -Lines $selectionLines -Name 'Capabilities' -Entries $capabilityEntries
    Add-SelectionMap -Lines $selectionLines -Name 'InboxApps' -Entries $appEntries
    $selectionLines.Add('}')
    $selectionPath = Join-Path $outputFullPath 'selections.psd1'
    [IO.File]::WriteAllLines($selectionPath, $selectionLines, [Text.UTF8Encoding]::new($false))
    Import-PowerShellDataFile -LiteralPath $selectionPath | Out-Null
    $operation['counts'] = @{ optionalFeatures = $features.Count; capabilities = $capabilities.Count; provisionedApps = $apps.Count }
    $operation.status = 'Succeeded'
}
catch {
    $operation.status = 'Failed'
    $operation.error = $_.Exception.Message
}
finally {
    if ($createdWimMount) {
        try {
            Dismount-WindowsImage -Path $mountPath -Discard -LogPath $dismLogPath -ScratchDirectory $scratchPath | Out-Null
            $operation.unmountedImage = $true
        }
        catch { $operation.cleanupErrors += $_.Exception.Message }
    }
    if ($createdIsoAttachment) {
        try {
            Dismount-DiskImage -ImagePath $isoFullPath | Out-Null
            $operation.detachedIso = $true
        }
        catch { $operation.cleanupErrors += $_.Exception.Message }
    }
    if ($operation.cleanupErrors.Count -gt 0) { $operation.status = 'Failed' }
    $operation['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    try { if ($outputPrepared) { Save-Operation } }
    finally { if ($null -ne $directoryLock) { $directoryLock.Dispose() } }
}
if ($operation.status -ne 'Succeeded') {
    Write-Error ((@($operation.error) + @($operation.cleanupErrors)) -join [Environment]::NewLine) -ErrorAction Continue
    exit 1
}
