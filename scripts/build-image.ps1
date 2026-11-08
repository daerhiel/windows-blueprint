#Requires -Version 5.1
<#
.SYNOPSIS
Builds a configured offline Pro WIM from the pinned Microsoft ISO.
.DESCRIPTION
Uses the pinned ADK, recreates its own output directory, and services only a newly
exported WIM. Configuration is read from config/windows.psd1. Source media, VM
disks, installed Windows, services, and individual CBS packages are not modified.
Dot-sourcing defines validation functions without performing a build.
#>
[CmdletBinding()]
param(
    [string] $IsoPath,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\.local\build\windows11-pro'),
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\windows.psd1')
)

function Get-ImageBuildPlan {
    param([hashtable] $Config, $Inventory, [object[]] $Manifests)
    $steps = @()
    foreach ($section in @('OptionalFeatures', 'Capabilities', 'InboxApps')) {
        foreach ($name in @($Config[$section].Keys | Sort-Object)) {
            $items = @($Inventory[$section] | Where-Object { $_.name -ceq $name })
            if ($items.Count -ne 1) { throw "Unknown or ambiguous ${section} selection: $name" }
            $state = $items[0].state
            $desired = $Config[$section][$name]
            $stateMatches = switch ($section) {
                OptionalFeatures {
                    if ($state -notin @('Enabled', 'Disabled', 'DisabledWithPayloadRemoved')) { throw "Unsettled source feature: $name ($state)" }
                    ($desired -eq 'Enabled' -and $state -eq 'Enabled') -or ($desired -eq 'Disabled' -and $state -in @('Disabled', 'DisabledWithPayloadRemoved'))
                }
                Capabilities {
                    if ($state -notin @('Installed', 'NotPresent')) { throw "Unsettled source capability: $name ($state)" }
                    ($desired -eq 'Present' -and $state -eq 'Installed') -or ($desired -eq 'Absent' -and $state -eq 'NotPresent')
                }
                InboxApps { $desired -eq 'Present' }
            }
            if (-not $stateMatches) { $steps += [pscustomobject]@{ section = $section; name = $name; desired = $desired; sourceState = $state } }
        }
    }
    $removed = @($steps | Where-Object { $_.section -eq 'InboxApps' } | ForEach-Object { ($_.name -split '_')[0] })
    $protected = @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI', 'Microsoft.Windows.SecHealthUI', 'MicrosoftWindows.Client.WebExperience')
    foreach ($name in $removed) {
        if ($name -in $protected) { throw "Protected app: $name" }
        $ownManifests = @($Manifests | Where-Object { $_.name -eq $name })
        if (@($ownManifests | Where-Object { -not $_.resource }).Count -eq 0 -or @($ownManifests | Where-Object { $_.framework }).Count -gt 0) { throw "Missing main app manifest or framework removal: $name" }
        $dependents = @($Manifests | Where-Object { $_.name -notin $removed -and ($_.dependencies -contains $name -or @($_.dependencyFamilies | Where-Object { ($_ -split '_')[0] -eq $name }).Count -gt 0) })
        if ($dependents.Count -gt 0) { throw "Retained app depends on ${name}: $(@($dependents | ForEach-Object { $_.name }) -join ', ')" }
    }
    $steps
}

function Get-ImagePolicyText {
    param([hashtable] $Rules, [ValidateSet('Machine', 'User')] [string] $Scope)
    $blocks = foreach ($id in @($Rules.Keys | Sort-Object)) {
        $rule = $Rules[$id]
        if (-not $rule.ContainsKey('Verification') -or $rule.Verification -cne 'LocalGpo' -or $rule.Kind -cne 'DWord' -or $rule.Value -isnot [int] -or $rule.Value -lt 0 -or $rule.Path -match '[\r\n]' -or $rule.Name -notmatch '^[A-Za-z0-9_.-]+$') { throw ('Unsupported offline local GPO rule: ' + $id) }
        $ruleScope = 'Machine'; $label = 'Computer'
        if ($rule.Path.StartsWith('HKCU:', [StringComparison]::OrdinalIgnoreCase)) { $ruleScope = 'User'; $label = 'User' }
        if ($ruleScope -eq $Scope) { @($label, $rule.Path.Substring(6), $rule.Name, ('DWORD:' + $rule.Value)) -join "`r`n" }
    }
    if (@($blocks).Count) { ($blocks -join "`r`n`r`n") + "`r`n" }
}

function Write-ImageLocalGpo {
    param([hashtable] $Rules, [string] $ImagePath, [string] $SourceDirectory, [string] $LgpoPath)
    $gpo = Join-Path $ImagePath 'Windows\System32\GroupPolicy'
    $existing = Get-AuditLocalGpo -Path $gpo
    if ($existing.Machine.Count -or $existing.User.Count) { throw 'The source already contains registry policies; refusing to replace unmanaged local GPOs.' }
    if ((Test-Path -LiteralPath $gpo) -and @(Get-ChildItem -LiteralPath $gpo -File -Recurse -Force | Where-Object { $_.Name -notin @('gpt.ini', 'Registry.pol') }).Count) { throw 'The source contains other local GPO settings; refusing to replace their metadata.' }
    [IO.Directory]::CreateDirectory($SourceDirectory) | Out-Null
    $version = 0
    $metadata = @('[General]')
    foreach ($scope in @('Machine', 'User')) {
        $text = Get-ImagePolicyText -Rules $Rules -Scope $scope
        if (-not $text) { continue }
        $directory = Join-Path $gpo $scope
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $inputFile = Join-Path $SourceDirectory ($scope + '.txt')
        [IO.File]::WriteAllText($inputFile, $text, [Text.UnicodeEncoding]::new($false, $true))
        # /r and /w only compile a file; no policy is imported into the build host.
        & $LgpoPath /r $inputFile /w (Join-Path $directory 'Registry.pol') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('LGPO compilation failed: ' + $scope) }
        $toolGuid = 'D02B1F72-3407-48AE-BA88-E8213C6761F1'
        if ($scope -eq 'Machine') { $version = $version -bor 1 }
        else { $version = $version -bor 65536; $toolGuid = 'D02B1F73-3407-48AE-BA88-E8213C6761F1' }
        $metadata += 'gPC' + $scope + 'ExtensionNames=[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{' + $toolGuid + '}]'
    }
    $metadata += 'Version=' + $version
    [IO.File]::WriteAllText((Join-Path $gpo 'gpt.ini'), (($metadata -join "`r`n") + "`r`n"), [Text.UnicodeEncoding]::new($false, $true))
}

function Get-ImageBuildVerification {
    param([hashtable] $Config, $Before, $After)
    $checks = @()
    foreach ($section in @('OptionalFeatures', 'Capabilities', 'InboxApps')) {
        foreach ($name in @($Config[$section].Keys | Sort-Object)) {
            $items = @($After[$section] | Where-Object { $_.name -ceq $name })
            $state = $null
            if ($items.Count -eq 1) { $state = $items[0].state }
            $desired = $Config[$section][$name]
            $pending = $false
            $pass = switch ($section) {
                OptionalFeatures {
                    $pending = $state -in @('EnablePending', 'DisablePending')
                    ($desired -eq 'Enabled' -and $state -in @('Enabled', 'EnablePending')) -or ($desired -eq 'Disabled' -and $state -in @('Disabled', 'DisabledWithPayloadRemoved', 'DisablePending'))
                }
                Capabilities { ($desired -eq 'Present' -and $state -eq 'Installed') -or ($desired -eq 'Absent' -and $state -eq 'NotPresent') }
                InboxApps { ($desired -eq 'Present' -and $items.Count -eq 1) -or ($desired -eq 'Absent' -and $items.Count -eq 0) }
            }
            $checks += [pscustomobject]@{ section = $section; name = $name; desired = $desired; actual = $state; passed = [bool]$pass; requiresFirstBoot = $pending }
        }
    }
    foreach ($app in @($Before.InboxApps | Where-Object { -not $Config.InboxApps.ContainsKey($_.name) })) {
        $checks += [pscustomobject]@{ section = 'RetainedInboxApps'; name = $app.name; desired = 'Present'; actual = $null; passed = ($app.name -in @($After.InboxApps | ForEach-Object { $_.name })); requiresFirstBoot = $false }
    }
    if ($Config.ContainsKey('Policies')) {
        foreach ($id in @($Config.Policies.Keys | Sort-Object)) {
            $rule = $Config.Policies[$id]
            $actual = Get-AuditGpoObservation -Store $After.LocalGpo -Rule $rule
            $pass = $actual.metadataValid -and $actual.valuePresent -and $actual.kind -eq $rule.Kind -and $actual.value -eq $rule.Value
            $checks += [pscustomobject]@{ section = 'Policies'; name = $id; desired = $rule.Value; actual = $actual; passed = [bool]$pass; requiresFirstBoot = $true }
        }
    }
    $checks
}

if ($MyInvocation.InvocationName -eq '.') { return }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'Use a fresh native 64-bit Windows PowerShell 5.1 process.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator access is required.' }
}
finally { $identity.Dispose() }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildOutputDirectory = $OutputDirectory
. (Join-Path $PSScriptRoot 'audit.ps1') -OutputDirectory '' -ConfigurationPath ''
$configFullPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$config = Read-AuditConfiguration $configFullPath
$sourcePath = Join-Path $root 'config\source-image.lock.json'
$toolPath = Join-Path $root 'config\toolchain.lock.json'
$source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
$tools = Get-Content -LiteralPath $toolPath -Raw | ConvertFrom-Json
if ($config.Edition -cne 'Pro' -or $source.selectedImage.editionId -cne 'Professional' -or $source.selectedImage.architecture -cne $config.Architecture -or $source.selectedImage.defaultLanguage -cne $config.Localization.UiLanguage) { throw 'Configuration must match the pinned Pro/x64/en-US source.' }
$iso = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
$output = [IO.Path]::GetFullPath($buildOutputDirectory).TrimEnd('\')
$buildRoot = Join-Path $root '.local\build'
if ([IO.Path]::GetDirectoryName($output) -ine $buildRoot) { throw 'OutputDirectory must be directly under .local/build.' }
foreach ($inputPath in @($iso, $configFullPath, $sourcePath, $toolPath)) {
    if ($inputPath.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Build inputs must be outside the output directory.' }
}
$ancestor = $output + '.lock'
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build paths must not contain reparse points.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
# The output directory is checked separately from its sibling lock path.
if ((Test-Path -LiteralPath $output) -and ((Get-Item -LiteralPath $output -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build output must not be a reparse point.' }
[IO.Directory]::CreateDirectory($buildRoot) | Out-Null
$lock = $null
$prepared = $false
$mounted = $false
$attached = $false
$mount = Join-Path $output 'mount'
$wim = Join-Path $output 'install.wim'
$operationPath = Join-Path $output 'operation.json'
$operation = [ordered]@{ schemaVersion = 1; status = 'Running'; stage = 'Preflight'; startedAtUtc = [DateTime]::UtcNow.ToString('o'); sourceIsoSha256 = $source.iso.sha256; configurationSha256 = (Get-FileHash -LiteralPath $configFullPath -Algorithm SHA256).Hash; sourceLockSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash; toolchainLockSha256 = (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash; buildScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash; completed = @(); error = $null; cleanupErrors = @(); committed = $false }
function Save-BuildOperation {
    $operation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $operationPath -Encoding UTF8
}
function Write-BuildStage {
    param([string] $Name)
    $operation.stage = $Name
    Save-BuildOperation
    Write-Output $Name
}
function Get-BuildInventory {
    @{
        OptionalFeatures = @(Get-WindowsOptionalFeature @servicing | Sort-Object FeatureName | ForEach-Object { [pscustomobject]@{ name = $_.FeatureName; state = [string]$_.State } })
        Capabilities     = @(Get-WindowsCapability @servicing -LimitAccess | Sort-Object Name | ForEach-Object { [pscustomobject]@{ name = $_.Name; state = [string]$_.State } })
        InboxApps        = @(Get-AppxProvisionedPackage @servicing | Sort-Object PackageName | ForEach-Object { [pscustomobject]@{ name = $_.PackageName; state = 'Present' } })
        LocalGpo         = Get-AuditLocalGpo -Path (Join-Path $mount 'Windows\System32\GroupPolicy')
    }
}
try {
    try { $lock = [IO.FileStream]::new(($output + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose) }
    catch { throw 'Another build is using this output directory.' }
    if ((Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash -cne $source.iso.sha256) { throw 'ISO fingerprint differs from the source lock.' }
    $lgpo = $null
    if ($config.Policies.Count) {
        foreach ($scope in @('Machine', 'User')) { Get-ImagePolicyText -Rules $config.Policies -Scope $scope | Out-Null }
        $targets = @($config.Policies.Values | ForEach-Object { $_.Path + '\' + $_.Name } | Sort-Object -Unique)
        if ($targets.Count -ne $config.Policies.Count -or @($config.Policies.Values | Where-Object { $source.selectedImage.editionId -cnotin @($_.Editions) }).Count) { throw 'Offline policies contain duplicate targets or unsupported edition rules.' }
        $lgpo = Join-Path $root $tools.lgpo.path
        if ((Get-FileHash -LiteralPath $lgpo -Algorithm SHA256).Hash -cne $tools.lgpo.sha256) { throw 'LGPO fingerprint differs from the toolchain lock.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $lgpo
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'LGPO must have a valid Microsoft signature.' }
        $operation['lgpoSha256'] = $tools.lgpo.sha256
    }
    foreach ($file in $tools.adk.files.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $tools.adk.dismDirectory $file.Name) -Algorithm SHA256).Hash -cne $file.Value) { throw ('ADK fingerprint mismatch: ' + $file.Name) }
    }
    if (Get-Module Dism) { throw 'Use a fresh Windows PowerShell process without a loaded DISM module.' }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BuildNativeLoader {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
}
'@
    $api = Join-Path $tools.adk.dismDirectory 'dismapi.dll'
    if ([BuildNativeLoader]::LoadLibraryEx($api, [IntPtr]::Zero, 8) -eq [IntPtr]::Zero) { throw 'Cannot load the pinned DISM native API.' }
    Import-Module (Join-Path $tools.adk.dismDirectory 'dism.psd1')
    Import-Module Storage
    $loaded = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object { $_.ModuleName -ieq 'dismapi.dll' })
    if ($loaded.Count -ne 1 -or $loaded[0].FileName -ine $api) { throw 'The pinned DISM native API was not loaded.' }
    foreach ($registered in @(Get-WindowsImage -Mounted)) {
        if ($registered.Path -ieq $output -or $registered.Path.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase) -or $registered.ImagePath.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'An image in the build directory is still mounted; cleanup is refused.' }
    }
    if (Test-Path -LiteralPath $output) {
        $resolved = (Resolve-Path -LiteralPath $output).ProviderPath
        if ([IO.Path]::GetDirectoryName($resolved) -ine $buildRoot) { throw 'Unsafe build cleanup path.' }
        if (@(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw 'Build contents must not contain reparse points.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($output)).AvailableFreeSpace -lt 25GB) { throw 'At least 25 GiB free space is required.' }
    [IO.Directory]::CreateDirectory($output) | Out-Null
    [IO.Directory]::CreateDirectory($mount) | Out-Null
    $scratch = Join-Path $output 'scratch'
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $prepared = $true
    $dism = @{ LogPath = (Join-Path $output 'dism.log'); ScratchDirectory = $scratch; ErrorAction = 'Stop' }
    $servicing = @{ Path = $mount; LogPath = $dism.LogPath; ScratchDirectory = $scratch; ErrorAction = 'Stop' }
    Copy-Item -LiteralPath $configFullPath -Destination (Join-Path $output 'windows.psd1')
    if ((Get-FileHash -LiteralPath (Join-Path $output 'windows.psd1') -Algorithm SHA256).Hash -cne $operation.configurationSha256) { throw 'Configuration changed during build preflight.' }
    $config = Read-AuditConfiguration (Join-Path $output 'windows.psd1')
    Write-BuildStage 'Attach source ISO read-only'
    $diskImage = Get-DiskImage -ImagePath $iso
    if (-not $diskImage.Attached) { $diskImage = Mount-DiskImage -ImagePath $iso -StorageType ISO -Access ReadOnly -PassThru; $attached = $true }
    $images = @(foreach ($volume in @($diskImage | Get-Volume)) {
            if ($volume.DriveLetter) {
                $candidate = Join-Path ('{0}:\' -f $volume.DriveLetter) $source.selectedImage.path
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
            }
        })
    if ($images.Count -ne 1) { throw 'Cannot locate the selected installation image.' }
    $info = Get-WindowsImage -ImagePath $images[0] -Index $source.selectedImage.index @dism
    $version = '{0}.{1}.{2}.{3}' -f $info.MajorVersion, $info.MinorVersion, $info.Build, $info.SPBuild
    if ($info.EditionId -cne $source.selectedImage.editionId -or $info.Architecture -ne 9 -or $version -cne $source.selectedImage.version -or $info.Languages[$info.DefaultLanguageIndex] -cne $source.selectedImage.defaultLanguage) { throw 'Source image metadata differs from the lock.' }
    Write-BuildStage 'Export Pro to a clean working WIM'
    Export-WindowsImage -SourceImagePath $images[0] -SourceIndex $source.selectedImage.index -DestinationImagePath $wim -CompressionType Fast -CheckIntegrity @dism | Out-Null
    Write-BuildStage 'Mount working WIM for offline servicing'
    Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount -CheckIntegrity @dism | Out-Null
    $mounted = $true
    $before = Get-BuildInventory
    $before | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'before.json') -Encoding UTF8
    Write-BuildStage 'Review offline app manifests and selected rules'
    $manifests = @(foreach ($relative in @('Program Files\WindowsApps', 'Windows\SystemApps')) {
            $parent = Join-Path $mount $relative
            foreach ($directory in @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop)) {
                $path = Join-Path $directory.FullName 'AppxManifest.xml'
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $xml = [xml](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
                $identityNode = $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
                if ($null -eq $identityNode) { throw "Invalid app manifest: $path" }
                $dependencies = @($xml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*'))
                [pscustomobject]@{
                    name = $identityNode.GetAttribute('Name'); publisher = $identityNode.GetAttribute('Publisher')
                    path = $path.Substring($mount.Length + 1); sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                    framework = ($null -ne $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Properties"]/*[local-name()="Framework" and text()="true"]'))
                    resource = ($null -ne $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Properties"]/*[local-name()="ResourcePackage" and text()="true"]'))
                    dependencies = @($dependencies | ForEach-Object { $_.GetAttribute('Name') } | Where-Object { $_ } | Sort-Object -Unique)
                    dependencyFamilies = @($dependencies | ForEach-Object { $_.GetAttribute('PackageFamilyName') } | Where-Object { $_ } | Sort-Object -Unique)
                }
            }
        })
    $manifests | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'app-manifests.json') -Encoding UTF8
    $plan = @(Get-ImageBuildPlan -Config $config -Inventory $before -Manifests $manifests)
    ConvertTo-Json -InputObject $plan -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'plan.json') -Encoding UTF8
    # Capability removal may also change an overlapping Optional Feature.
    foreach ($section in @('Capabilities', 'OptionalFeatures', 'InboxApps')) {
        foreach ($step in @($plan | Where-Object { $_.section -eq $section })) {
            Write-BuildStage ($section + ': ' + $step.name + ' -> ' + $step.desired)
            switch ($section) {
                Capabilities {
                    if ($step.desired -eq 'Absent') { Remove-WindowsCapability -Name $step.name @servicing | Out-Null }
                    else { Add-WindowsCapability -Name $step.name -LimitAccess @servicing | Out-Null }
                }
                OptionalFeatures {
                    $current = [string](Get-WindowsOptionalFeature -FeatureName $step.name @servicing).State
                    if ($step.desired -eq 'Enabled' -and $current -notin @('Enabled', 'EnablePending')) { Enable-WindowsOptionalFeature -FeatureName $step.name -All -LimitAccess -NoRestart @servicing | Out-Null }
                    elseif ($step.desired -eq 'Disabled' -and $current -notin @('Disabled', 'DisabledWithPayloadRemoved', 'DisablePending')) { Disable-WindowsOptionalFeature -FeatureName $step.name -NoRestart @servicing | Out-Null }
                }
                InboxApps { Remove-AppxProvisionedPackage -PackageName $step.name @servicing | Out-Null }
            }
            $operation.completed += $step
            Save-BuildOperation
        }
    }
    if ($config.Policies.Count) {
        Write-BuildStage 'Compile selected local GPOs into the offline image'
        Write-ImageLocalGpo -Rules $config.Policies -ImagePath $mount -SourceDirectory (Join-Path $output 'policy-source') -LgpoPath $lgpo
    }
    Write-BuildStage 'Verify offline selections, retained apps, and local GPOs'
    $after = Get-BuildInventory
    $after | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'after.json') -Encoding UTF8
    $checks = @(Get-ImageBuildVerification -Config $config -Before $before -After $after)
    ConvertTo-Json -InputObject $checks -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'verification.json') -Encoding UTF8
    if (@($checks | Where-Object { -not $_.passed }).Count -gt 0) { throw 'Offline verification failed; see verification.json. Changes will be discarded.' }
    Write-BuildStage 'Commit the configured working WIM'
    Dismount-WindowsImage -Path $mount -Save -CheckIntegrity @dism | Out-Null
    $mounted = $false
    $operation.committed = $true
    Write-BuildStage 'Verify the saved WIM through a read-only mount'
    Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount -ReadOnly -CheckIntegrity @dism | Out-Null
    $mounted = $true
    $saved = Get-BuildInventory
    $checks = @(Get-ImageBuildVerification -Config $config -Before $before -After $saved)
    ConvertTo-Json -InputObject $checks -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'verification.json') -Encoding UTF8
    if (@($checks | Where-Object { -not $_.passed }).Count -gt 0) { throw 'Saved WIM verification failed.' }
    Dismount-WindowsImage -Path $mount -Discard @dism | Out-Null
    $mounted = $false
    $operation['outputImageIndex'] = 1
    $operation['outputWimSha256'] = (Get-FileHash -LiteralPath $wim -Algorithm SHA256).Hash
    $operation['requiresFirstBootVerification'] = $true
    $operation.status = 'Succeeded'
    $operation.stage = 'Complete'
}
catch {
    $operation.status = 'Failed'
    $operation.error = $_.Exception.Message
    if ($prepared) { Save-BuildOperation }
}
finally {
    if ($mounted) {
        try { Dismount-WindowsImage -Path $mount -Discard @dism | Out-Null }
        catch { $operation.cleanupErrors += $_.Exception.Message }
    }
    if ($attached) {
        try { Dismount-DiskImage -ImagePath $iso | Out-Null }
        catch { $operation.cleanupErrors += $_.Exception.Message }
    }
    if ($operation.cleanupErrors.Count -gt 0) { $operation.status = 'Failed' }
    $operation['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    try { if ($prepared) { Save-BuildOperation } }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}
if ($operation.status -ne 'Succeeded') { throw ((@($operation.error) + @($operation.cleanupErrors)) -join [Environment]::NewLine) }
Write-Output ('Configured WIM ready: ' + $wim + ' (index 1). Installation and independent audit are still required.')
