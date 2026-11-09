#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Packages the verified configured WIM with optional recovery compression to ESD.

.DESCRIPTION
Creates a bootable ISO with automatic disk preparation and native OOBE.
Recreates only its own .local/media output, checks every embedded file by hash,
and removes the staging tree after verification.

.PARAMETER IsoPath
Original Windows ISO used with the verified configured WIM to construct installation media.

.PARAMETER Compress
Exports the configured installation image as a recovery-compressed ESD when creating media.

.PARAMETER OutputDirectory
Owned media-build directory; defaults to .local/media/windows11-pro.

.OUTPUTS
None. Writes bootable installation media, manifests, logs, and an operation report.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $IsoPath,
    [switch] $Compress,
    [string] $OutputDirectory
)

. (Join-Path $PSScriptRoot 'workflow-output.ps1')

if (-not $PSBoundParameters.ContainsKey('OutputDirectory')) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\.local\media\windows11-pro'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Use native 64-bit Windows PowerShell 5.1.'
}

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$mediaRoot = Join-Path $root '.local\media'

if ([IO.Path]::GetDirectoryName($output) -ine $mediaRoot) {
    throw 'OutputDirectory must be directly under .local/media.'
}

foreach ($target in @($output, ($output + '.lock'))) {
    $ancestor = $target

    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Media output paths must not contain reparse points.'
        }

        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}

$sourceIso = (Resolve-Path -LiteralPath $IsoPath).ProviderPath

if ($sourceIso.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source ISO must be outside the media output.'
}

$buildDirectory = Join-Path $root '.local\build\windows11-pro'
$wimPath = Join-Path $buildDirectory 'install.wim'
$source = Get-Content -LiteralPath (Join-Path $root 'config\source-image.lock.json') -Raw | ConvertFrom-Json
$toolchain = Get-Content -LiteralPath (Join-Path $root 'config\toolchain.lock.json') -Raw | ConvertFrom-Json
$oscdimg = $toolchain.adk.oscdimg
$dismExe = Join-Path $toolchain.adk.dismDirectory 'dism.exe'
$iso = Join-Path $output 'windows11-pro.iso'
$tree = Join-Path $output 'files'
$lock = $null
$buildLock = $null
$sourceAttached = $false
$targetAttached = $false
$prepared = $false
$bootMounted = $false
$bootMount = Join-Path $output 'boot-mount'
$operationPath = Join-Path $output 'operation.json'
$operation = [ordered]@{
    schemaVersion       = 1
    status              = 'Running'
    stage               = 'Preflight'
    startedAtUtc        = [DateTime]::UtcNow.ToString('o')
    sourceIsoSha256     = $source.iso.sha256
    configurationSha256 = $null
    outputWimSha256     = $null
    imageIndex          = 1
    isoPath             = $iso
    isoSha256           = $null
    isoSizeBytes        = $null
    filesVerified       = 0
    error               = $null
    cleanupErrors       = @()
}

function Save-MediaOperation {
    <#
    .SYNOPSIS
    Saves the current installation-media operation report.

    .DESCRIPTION
    Serializes the operation and report path from the enclosing media-build invocation.

    .OUTPUTS
    None. Updates the media operation.json file.
    #>

    $operation | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $operationPath -Encoding UTF8
}

function Write-MediaStage {
    <#
    .SYNOPSIS
    Records and announces the current media-build stage.

    .DESCRIPTION
    Updates the enclosing operation, saves its report, and writes a console progress message.

    .PARAMETER Name
    Human-readable name of the stage about to run.

    .OUTPUTS
    None. Updates the report and writes a host message.
    #>

    param(
        [string] $Name
    )

    $operation.stage = $Name
    Save-MediaOperation
    Write-WorkflowMessage ('Media: ' + $Name)
}

function Get-MediaVolumeRoot {
    <#
    .SYNOPSIS
    Resolves the drive root of an attached installation ISO.

    .DESCRIPTION
    Requires exactly one mounted volume with a drive letter so subsequent media operations use an unambiguous source.

    .PARAMETER DiskImage
    Attached disk image object returned by the storage cmdlets.

    .OUTPUTS
    System.String. Mounted volume root path.
    #>

    param(
        $DiskImage
    )

    $volumes = @($DiskImage | Get-Volume | Where-Object {
            $_.DriveLetter
        })

    if ($volumes.Count -ne 1) {
        throw 'Expected one ISO volume with a drive letter.'
    }

    '{0}:\' -f $volumes[0].DriveLetter
}

function Get-MediaImageInfo {
    <#
    .SYNOPSIS
    Reads image metadata through the verified native DISM executable.

    .DESCRIPTION
    Checks that the supplied WIM or ESD contains one image and collects the metadata used to verify installation media.

    .PARAMETER ImagePath
    Path to the single-image WIM or ESD to inspect.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. Image metadata parsed from DISM output.
    #>

    param(
        [string] $ImagePath
    )

    $arguments = @('/Get-ImageInfo', ('/ImageFile:' + $ImagePath), '/English', ('/LogPath:' + $dismLog), ('/ScratchDir:' + $scratch))
    $listing = @(Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments $arguments -LogPath $nativeLog)

    if (@($listing | Where-Object {
                $_ -match '^\s*Index\s*:'
            }).Count -ne 1) {
        throw 'Expected one readable installation image.'
    }

    $details = @(Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments ($arguments + '/Index:1') -LogPath $nativeLog)
    $fields = @{}

    foreach ($line in $details) {
        $fieldMatch = [regex]::Match($line, '^\s*([^:]+?)\s*:\s*(.*?)\s*$')

        if ($fieldMatch.Success) {
            $fields[$fieldMatch.Groups[1].Value] = $fieldMatch.Groups[2].Value
        }
    }

    foreach ($key in @('Name', 'Architecture', 'Version', 'ServicePack Build', 'Edition')) {
        if (-not $fields.ContainsKey($key)) {
            throw ('Missing image metadata field: ' + $key)
        }
    }

    if (($details -join "`n") -notmatch ([regex]::Escape($source.selectedImage.defaultLanguage) + '\s+\(Default\)')) {
        throw 'Image default language differs from the source lock.'
    }

    [ordered]@{
        name            = $fields.Name
        architecture    = $fields.Architecture
        edition         = $fields.Edition
        version         = $fields.Version + '.' + $fields['ServicePack Build']
        defaultLanguage = $source.selectedImage.defaultLanguage
    }
}

[IO.Directory]::CreateDirectory($mediaRoot) | Out-Null

try {
    $lock = [IO.FileStream]::new(($output + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    $buildLock = [IO.FileStream]::new(($buildDirectory + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    $build = Get-Content -LiteralPath (Join-Path $buildDirectory 'operation.json') -Raw | ConvertFrom-Json
    $checks = @(Get-Content -LiteralPath (Join-Path $buildDirectory 'verification.json') -Raw | ConvertFrom-Json)

    if ($build.status -cne 'Succeeded' -or -not $build.committed -or $build.outputImageIndex -ne 1 -or @($build.cleanupErrors).Count -ne 0 -or $checks.Count -eq 0 -or @($checks | Where-Object {
                -not $_.passed
            }).Count -gt 0) {
        throw 'A successfully saved, verified, and unmounted configured WIM is required.'
    }

    if ($build.sourceIsoSha256 -cne $source.iso.sha256 -or (Get-FileHash -LiteralPath $sourceIso -Algorithm SHA256).Hash -cne $source.iso.sha256) {
        throw 'Source ISO does not match the configured build and source lock.'
    }
    if ((Get-FileHash -LiteralPath (Join-Path $root 'config\windows.psd1') -Algorithm SHA256).Hash -cne $build.configurationSha256) {
        throw 'Configuration changed since the WIM build.'
    }
    if ((Get-FileHash -LiteralPath $wimPath -Algorithm SHA256).Hash -cne $build.outputWimSha256) {
        throw 'Configured WIM changed after verification.'
    }

    foreach ($toolFile in $toolchain.adk.files.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $toolchain.adk.dismDirectory $toolFile.Name) -Algorithm SHA256).Hash -cne $toolFile.Value) {
            throw ('DISM toolchain fingerprint mismatch: ' + $toolFile.Name)
        }
    }

    if ((Get-FileHash -LiteralPath $oscdimg.path -Algorithm SHA256).Hash -cne $oscdimg.sha256) {
        throw 'Oscdimg differs from the toolchain lock.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $oscdimg.path

    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'Oscdimg must have a valid Microsoft signature.'
    }

    Import-Module (Join-Path $toolchain.adk.dismDirectory 'Dism.psd1')

    if (@(Get-WindowsImage -Mounted | Where-Object {
                $_.Path -ieq $bootMount -or $_.Path.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)
            }).Count) {
        throw 'The media output contains a mounted image; cleanup is refused.'
    }

    $packageRoot = Join-Path $root $toolchain.winpe.packageDirectory

    foreach ($package in $toolchain.winpe.packages) {
        if ((Get-FileHash -LiteralPath (Join-Path $packageRoot $package.path)).Hash -cne $package.sha256) {
            throw ('WinPE package fingerprint mismatch: ' + $package.path)
        }
    }

    Import-Module Storage

    if ((Test-Path -LiteralPath $iso) -and (Get-DiskImage -ImagePath $iso).Attached) {
        throw 'The previous output ISO is attached; cleanup is refused.'
    }

    if (Test-Path -LiteralPath $output) {
        if (Get-Module -ListAvailable Hyper-V) {
            Import-Module Hyper-V

            foreach ($vm in @(Get-VM)) {
                if (@(Get-VMDvdDrive -VM $vm | Where-Object {
                            $_.Path -and $_.Path.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)
                        }).Count -gt 0) {
                    throw 'A VM references media in the output directory; detach it before rebuilding.'
                }
            }
        }

        $resolvedOutput = (Resolve-Path -LiteralPath $output).ProviderPath

        if ([IO.Path]::GetDirectoryName($resolvedOutput) -ine $mediaRoot) {
            throw 'Unsafe media cleanup path.'
        }

        if (@(Get-ChildItem -LiteralPath $resolvedOutput -Force -Recurse | Where-Object {
                    $_.Attributes -band [IO.FileAttributes]::ReparsePoint
                }).Count -gt 0) {
            throw 'Media contents must not contain reparse points.'
        }

        Remove-Item -LiteralPath $resolvedOutput -Recurse -Force
    }

    # Budget two payload/setup copies plus scratch space; compression normally reduces this.
    $requiredSpace = 2 * ((Get-Item -LiteralPath $wimPath).Length + $source.iso.sizeBytes - $source.observedMedia.installationImageSizeBytes) + 2GB

    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($output)).AvailableFreeSpace -lt $requiredSpace) {
        throw ('At least {0:N1} GiB free space is required to stage and package media.' -f ($requiredSpace / 1GB))
    }

    [IO.Directory]::CreateDirectory($tree) | Out-Null
    $prepared = $true
    $operation.configurationSha256 = $build.configurationSha256
    $operation.outputWimSha256 = $build.outputWimSha256
    $operation['oscdimgSha256'] = $oscdimg.sha256
    $operation['dismSha256'] = $toolchain.adk.files.'dism.exe'
    $scratch = Join-Path $output 'scratch'
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $dismLog = Join-Path $output 'dism.log'
    $nativeLog = Join-Path $output 'native-commands.log'
    Write-MediaStage 'Attach original Microsoft ISO read-only'
    $sourceDisk = Get-DiskImage -ImagePath $sourceIso

    if (-not $sourceDisk.Attached) {
        $sourceDisk = Mount-DiskImage -ImagePath $sourceIso -StorageType ISO -Access ReadOnly -PassThru
        $sourceAttached = $true
    }

    $sourceRoot = Get-MediaVolumeRoot $sourceDisk
    Write-MediaStage 'Copy original Setup files'
    $manifest = @(foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($sourceRoot.Length)

            if ($relative.Replace('\', '/') -ieq $source.selectedImage.path.Replace('\', '/')) {
                continue
            }

            $destination = Join-Path $tree $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
            [PSCustomObject]@{
                path   = $relative
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                origin = 'MicrosoftISO'
            }
        })
    Write-MediaStage 'Prepare Windows Setup with automatic disk configuration'
    $bootWim = Join-Path $output 'setup.wim'
    $originalBoot = Join-Path $tree 'sources\boot.wim'
    $bootInfo = Get-WindowsImage -ImagePath $originalBoot -Index 2

    if (([version]$bootInfo.Version).Build -ne $toolchain.winpe.imageBuild) {
        throw 'WinPE optional components must match the Setup image build.'
    }

    Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @('/Export-Image', ('/SourceImageFile:' + $originalBoot), '/SourceIndex:2', ('/DestinationImageFile:' + $bootWim), '/Compress:max', '/Bootable', '/CheckIntegrity', '/English', ('/LogPath:' + $dismLog), ('/ScratchDir:' + $scratch)) -LogPath $nativeLog | Out-Null
    [IO.Directory]::CreateDirectory($bootMount) | Out-Null
    Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @('/Mount-Image', ('/ImageFile:' + $bootWim), '/Index:1', ('/MountDir:' + $bootMount), '/CheckIntegrity', '/English', ('/LogPath:' + $dismLog), ('/ScratchDir:' + $scratch)) -LogPath $nativeLog | Out-Null
    $bootMounted = $true

    foreach ($package in $toolchain.winpe.packages) {
        Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @(('/Image:' + $bootMount), '/Add-Package', ('/PackagePath:' + (Join-Path $packageRoot $package.path)), '/English', ('/LogPath:' + $dismLog), ('/ScratchDir:' + $scratch)) -LogPath $nativeLog | Out-Null
    }

    $startup = @'
$ErrorActionPreference = 'Stop'
try {
    $media = @(Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
        $path = [string]$_.DriveLetter + ':\'
        if ((Test-Path -LiteralPath ($path + 'deployment\install.ps1') -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath ($path + 'sources\boot.wim') -ErrorAction SilentlyContinue)) { $path }
    })
    if ($media.Count -ne 1) { throw 'Expected one project installation medium.' }
    & ($media[0] + 'deployment\install.ps1') -MediaRoot $media[0]
}
catch {
    Write-Error $_ -ErrorAction Continue
    Start-Sleep -Seconds 30
    & wpeutil.exe Shutdown
}
'@
    $system32 = Join-Path $bootMount 'Windows\System32'
    [IO.File]::WriteAllText((Join-Path $system32 'start-deployment.ps1'), $startup, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines((Join-Path $system32 'winpeshl.ini'), @(
            '[LaunchApps]', '%SYSTEMROOT%\System32\wpeinit.exe',
            '%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe, -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File X:\Windows\System32\start-deployment.ps1'
        ), [Text.Encoding]::ASCII)

    if (-not (Test-Path -LiteralPath (Join-Path $system32 'WindowsPowerShell\v1.0\powershell.exe'))) {
        throw 'WinPE PowerShell is missing.'
    }

    $startupHashes = @{}

    foreach ($name in @('winpeshl.ini', 'start-deployment.ps1')) {
        $startupHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $system32 $name)).Hash
    }

    Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @('/Unmount-Image', ('/MountDir:' + $bootMount), '/Commit', '/CheckIntegrity', '/English', ('/LogPath:' + $dismLog), ('/ScratchDir:' + $scratch)) -LogPath $nativeLog | Out-Null
    $bootMounted = $false
    Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @('/Mount-Image', ('/ImageFile:' + $bootWim), '/Index:1', ('/MountDir:' + $bootMount), '/ReadOnly', '/CheckIntegrity', '/English', ('/LogPath:' + $dismLog), ('/ScratchDir:' + $scratch)) -LogPath $nativeLog | Out-Null
    $bootMounted = $true

    foreach ($name in $startupHashes.Keys) {
        if ((Get-FileHash -LiteralPath (Join-Path $system32 $name)).Hash -cne $startupHashes[$name]) {
            throw ('Saved Setup startup file differs: ' + $name)
        }
    }

    Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @('/Unmount-Image', ('/MountDir:' + $bootMount), '/Discard', '/English', ('/LogPath:' + $dismLog)) -LogPath $nativeLog | Out-Null
    $bootMounted = $false
    Copy-Item -LiteralPath $bootWim -Destination $originalBoot -Force
    $manifest = @($manifest | Where-Object {
            $_.path -ine 'sources\boot.wim'
        })
    $manifest += [PSCustomObject]@{
        path   = 'sources\boot.wim'
        sha256 = (Get-FileHash -LiteralPath $originalBoot).Hash
        origin = 'ConfiguredWinPE'
    }
    [IO.Directory]::CreateDirectory((Join-Path $tree 'deployment')) | Out-Null

    foreach ($name in @('autounattend.xml', 'install.ps1', 'windows.psd1')) {
        $inputPath = Join-Path $root ('setup\deployment\' + $name)

        if ($name -eq 'windows.psd1') {
            $inputPath = Join-Path $root 'config\windows.psd1'
        }

        $relative = 'deployment\' + $name
        Copy-Item -LiteralPath $inputPath -Destination (Join-Path $tree $relative)
        $manifest += [PSCustomObject]@{
            path   = $relative
            sha256 = (Get-FileHash -LiteralPath $inputPath).Hash
            origin = 'Deployment'
        }
    }

    $operation['deployment'] = $true
    $inputMetadata = Get-MediaImageInfo -ImagePath $wimPath
    $payloadName = 'install.wim'
    $outputMetadata = $inputMetadata
    $origin = 'ConfiguredWIM'

    if ($Compress) {
        $payloadName = 'install.esd'
        $origin = 'ConfiguredESD'
    }

    $payloadPath = Join-Path $tree ('sources\' + $payloadName)

    if ($Compress) {
        Write-MediaStage 'Export the configured WIM to recovery-compressed ESD'
        Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @('/Export-Image', ('/SourceImageFile:' + $wimPath), '/SourceIndex:1', ('/DestinationImageFile:' + $payloadPath), '/Compress:recovery', '/CheckIntegrity', '/English', ('/LogPath:' + $dismLog), ('/ScratchDir:' + $scratch)) -LogPath $nativeLog | Out-Null

        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
            throw 'Recovery-compressed ESD export failed.'
        }

        Write-MediaStage 'Verify the compressed image metadata'
        $outputMetadata = Get-MediaImageInfo -ImagePath $payloadPath

        if (($inputMetadata | ConvertTo-Json -Compress) -cne ($outputMetadata | ConvertTo-Json -Compress)) {
            throw 'Compressed image metadata differs from the verified WIM.'
        }
    }
    else {
        Write-MediaStage 'Copy the verified configured WIM without recompression'
        Copy-Item -LiteralPath $wimPath -Destination $payloadPath
    }

    $operation['payloadPath'] = 'sources/' + $payloadName
    $operation['payloadCompression'] = 'Unchanged'

    if ($Compress) {
        $operation.payloadCompression = 'Recovery'
    }

    $operation['payloadSha256'] = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash

    if (-not $Compress -and $operation.payloadSha256 -cne $build.outputWimSha256) {
        throw 'Copied WIM differs from the verified build.'
    }

    $operation['payloadSizeBytes'] = (Get-Item -LiteralPath $payloadPath).Length
    $operation['payloadImage'] = $outputMetadata
    $outputMetadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'image.json') -Encoding UTF8
    $manifest += [PSCustomObject]@{
        path   = 'sources\' + $payloadName
        sha256 = $operation.payloadSha256
        origin = $origin
    }
    $payloads = @(Get-ChildItem -LiteralPath (Join-Path $tree 'sources') -File | Where-Object {
            $_.Name -match '^install\.(wim|esd)$|^install.*\.swm$'
        })

    if ($payloads.Count -ne 1 -or $payloads[0].Name -ine $payloadName -or (Test-Path -LiteralPath (Join-Path $tree 'autounattend.xml'))) {
        throw 'Media must contain only the configured installation image and no root answer file.'
    }

    foreach ($required in @('boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin', 'sources\boot.wim', 'setup.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $tree $required) -PathType Leaf)) {
            throw ('Missing original Setup file: ' + $required)
        }
    }

    Write-MediaStage 'Create bootable installation ISO'
    $bootOrder = @($manifest | Where-Object {
            $_.path -match '^(boot\\|efi\\|bootmgr(\.efi)?$)'
        } | ForEach-Object {
            $_.path
        } | Sort-Object)
    $bootOrder += 'sources\boot.wim'
    [IO.File]::WriteAllLines((Join-Path $output 'boot-order.txt'), $bootOrder, [Text.Encoding]::ASCII)
    # Relative boot paths avoid spaces in Oscdimg's multi-boot option.
    Push-Location -LiteralPath $tree

    try {
        Invoke-WorkflowNativeCommand -FilePath $oscdimg.path -Arguments @('-m', '-o', '-h', '-u2', '-udfver102', '-lWIN11PRO', '-yo..\boot-order.txt', '-bootdata:2#p0,e,bboot\etfsboot.com#pEF,e,befi\microsoft\boot\efisys.bin', $tree, $iso) -LogPath $nativeLog | Out-Null

        if (-not (Test-Path -LiteralPath $iso)) {
            throw 'Oscdimg failed to create installation media.'
        }
    }
    finally {
        Pop-Location
    }

    Write-MediaStage 'Verify every file in the packaged ISO'
    $targetDisk = Mount-DiskImage -ImagePath $iso -StorageType ISO -Access ReadOnly -PassThru
    $targetAttached = $true
    $targetRoot = Get-MediaVolumeRoot $targetDisk

    foreach ($entry in $manifest) {
        if ((Get-FileHash -LiteralPath (Join-Path $targetRoot $entry.path) -Algorithm SHA256).Hash -cne $entry.sha256) {
            throw ('Packaged file hash mismatch: ' + $entry.path)
        }
    }

    if (@(Get-ChildItem -LiteralPath $targetRoot -Recurse -File -Force).Count -ne $manifest.Count) {
        throw 'Packaged ISO contains an unexpected file count.'
    }

    $operation.filesVerified = $manifest.Count
    ConvertTo-Json -InputObject $manifest -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'files.json') -Encoding UTF8
    Dismount-DiskImage -ImagePath $iso | Out-Null
    $targetAttached = $false

    # This exact staging path was created under the checked output directory.
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($tree)) -ine $output) {
        throw 'Unsafe staging cleanup path.'
    }

    Remove-Item -LiteralPath $tree -Recurse -Force
    $operation.isoSha256 = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    $operation.isoSizeBytes = (Get-Item -LiteralPath $iso).Length
    $operation.stage = 'Complete'
    $operation.status = 'Succeeded'
}
catch {
    $operation.status = 'Failed'
    $operation['errorDetails'] = Get-WorkflowErrorDetails -Failure $_
    $operation.error = $operation.errorDetails.message
    Write-WorkflowMessage 'Media packaging failed:' -Data $operation.error -Level Error

    if ($prepared) {
        Save-MediaOperation
    }
}
finally {
    if ($bootMounted) {
        Write-WorkflowMessage 'Discarding the remaining Setup boot-image mount during cleanup.' -Level Warning

        try {
            Invoke-WorkflowNativeCommand -FilePath $dismExe -Arguments @('/Unmount-Image', ('/MountDir:' + $bootMount), '/Discard', '/English', ('/LogPath:' + $dismLog)) -LogPath $nativeLog | Out-Null
        }
        catch {
            $operation.cleanupErrors += $_.Exception.Message
        }
    }

    if ($targetAttached) {
        Write-WorkflowMessage 'Detaching the generated ISO during media cleanup.'

        try {
            Dismount-DiskImage -ImagePath $iso | Out-Null
        }
        catch {
            $operation.cleanupErrors += $_.Exception.Message
        }
    }

    if ($sourceAttached) {
        Write-WorkflowMessage 'Detaching the source ISO during media cleanup.'

        try {
            Dismount-DiskImage -ImagePath $sourceIso | Out-Null
        }
        catch {
            $operation.cleanupErrors += $_.Exception.Message
        }
    }

    if ($operation.cleanupErrors.Count -gt 0) {
        $operation.status = 'Failed'
    }

    $operation['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')

    try {
        if ($prepared) {
            Save-MediaOperation
        }
    }
    finally {
        if ($null -ne $buildLock) {
            $buildLock.Dispose()
        }
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}

if ($operation.status -cne 'Succeeded') {
    throw ((@($operation.error) + @($operation.cleanupErrors)) -join [Environment]::NewLine)
}

Write-WorkflowMessage 'Verified installation media with automatic disk preparation and native OOBE:' -Data $iso -Level Success
