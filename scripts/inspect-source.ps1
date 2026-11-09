#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Reads image metadata from an ISO without servicing its contents.

.DESCRIPTION
Run in an elevated Windows PowerShell session. Verifies the ISO fingerprint,
temporarily attaches the ISO read-only, and writes inspection.json and DISM logs.
Only attachments created by this invocation are detached on exit.

.PARAMETER IsoPath
Original ISO whose hash and image metadata should be inspected.

.PARAMETER OutputDirectory
Owned output directory for inspection.json and DISM logs.

.PARAMETER ExpectedSha256
Expected SHA-256 hash of the source ISO.

.OUTPUTS
None. Writes inspection.json and DISM logs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IsoPath,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string] $ExpectedSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$resolvedIsoPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$inspectionRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.local\source-inspection'))

if ($resolvedOutputDirectory -ine $inspectionRoot) {
    throw 'OutputDirectory must be the repository .local/source-inspection directory.'
}
if ($resolvedIsoPath.StartsWith($inspectionRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The source ISO must be outside the inspection directory.'
}

foreach ($checkedPath in @((Split-Path $inspectionRoot -Parent), $inspectionRoot, ($inspectionRoot + '.lock'))) {
    if ((Test-Path -LiteralPath $checkedPath) -and ((Get-Item -LiteralPath $checkedPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Inspection paths must not contain reparse points.'
    }
}

[IO.Directory]::CreateDirectory((Split-Path $inspectionRoot -Parent)) | Out-Null
$inspectionLock = $null
$outputPrepared = $false
$resultPath = Join-Path $resolvedOutputDirectory 'inspection.json'

$inspectionResult = [ordered]@{
    schemaVersion             = 1
    status                    = 'Failed'
    startedAtUtc              = [DateTime]::UtcNow.ToString('o')
    isoPath                   = $resolvedIsoPath
    isoSha256                 = $null
    installationImagePath     = $null
    images                    = @()
    createdAttachment         = $false
    detachedCreatedAttachment = $false
    error                     = $null
    cleanupError              = $null
}
$createdAttachment = $false

try {
    try {
        $inspectionLock = [IO.FileStream]::new(($inspectionRoot + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    }
    catch {
        throw 'Another inspection is using this output directory.'
    }

    $actualHash = (Get-FileHash -LiteralPath $resolvedIsoPath -Algorithm SHA256).Hash
    $inspectionResult.isoSha256 = $actualHash

    if ($actualHash -ne $ExpectedSha256) {
        throw 'The ISO fingerprint does not match the recorded source.'
    }

    if (Test-Path -LiteralPath $resolvedOutputDirectory) {
        $cleanupPath = (Resolve-Path -LiteralPath $resolvedOutputDirectory).ProviderPath

        if ($cleanupPath -ine $inspectionRoot) {
            throw 'Unsafe inspection cleanup path.'
        }

        if (@(Get-ChildItem -LiteralPath $cleanupPath -Force -Recurse | Where-Object {
                    $_.Attributes -band [IO.FileAttributes]::ReparsePoint
                }).Count -gt 0) {
            throw 'Inspection contents must not contain reparse points.'
        }

        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
    }

    [IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
    $outputPrepared = $true

    Import-Module Storage
    Import-Module Dism
    $diskImage = Get-DiskImage -ImagePath $resolvedIsoPath

    if (-not $diskImage.Attached) {
        $diskImage = Mount-DiskImage -ImagePath $resolvedIsoPath -StorageType ISO -Access ReadOnly -PassThru
        $createdAttachment = $true
        $inspectionResult.createdAttachment = $true
    }

    $imageCandidates = @(
        foreach ($volume in @($diskImage | Get-Volume)) {
            if ($volume.DriveLetter) {
                foreach ($fileName in @('install.wim', 'install.esd')) {
                    $candidatePath = Join-Path ('{0}:\sources' -f $volume.DriveLetter) $fileName

                    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                        $candidatePath
                    }
                }
            }
        }
    )

    if ($imageCandidates.Count -ne 1) {
        throw 'Expected exactly one sources/install.wim or sources/install.esd.'
    }

    $imagePath = $imageCandidates[0]
    $inspectionResult.installationImagePath = 'sources/' + [IO.Path]::GetFileName($imagePath)
    $dismLogPath = Join-Path $resolvedOutputDirectory 'dism.log'
    $imageSummaries = @(Get-WindowsImage -ImagePath $imagePath -LogPath $dismLogPath)

    if ($imageSummaries.Count -eq 0) {
        throw 'The installation image contains no image indexes.'
    }

    $inspectionResult.images = @(
        foreach ($summary in $imageSummaries) {
            $image = Get-WindowsImage -ImagePath $imagePath -Index $summary.ImageIndex -LogPath $dismLogPath
            $languages = @($image.Languages | ForEach-Object {
                    [string] $_
                })

            if ($image.DefaultLanguageIndex -ge $languages.Count) {
                throw 'The default language index is outside the image language list.'
            }

            [ordered]@{
                index           = $image.ImageIndex
                name            = $image.ImageName
                editionId       = $image.EditionId
                architecture    = $image.Architecture
                version         = '{0}.{1}.{2}.{3}' -f $image.MajorVersion, $image.MinorVersion, $image.Build, $image.SPBuild
                languages       = $languages
                defaultLanguage = $languages[$image.DefaultLanguageIndex]
            }
        }
    )
    $inspectionResult.status = 'Succeeded'
}
catch {
    $inspectionResult.error = $_.Exception.Message
}
finally {
    if ($createdAttachment) {
        try {
            Dismount-DiskImage -ImagePath $resolvedIsoPath | Out-Null
            $inspectionResult.detachedCreatedAttachment = $true
        }
        catch {
            $inspectionResult.status = 'Failed'
            $inspectionResult.cleanupError = $_.Exception.Message
        }
    }

    $inspectionResult['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')

    try {
        if ($outputPrepared) {
            $inspectionResult | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        }
    }
    finally {
        if ($null -ne $inspectionLock) {
            $inspectionLock.Dispose()
        }
    }
}

if ($inspectionResult.status -ne 'Succeeded') {
    Write-Error ((@($inspectionResult.error) + @($inspectionResult.cleanupError)) -join [Environment]::NewLine) -ErrorAction Continue
    exit 1
}
