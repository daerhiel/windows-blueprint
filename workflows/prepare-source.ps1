#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Prepares the pinned source WIM, component catalog, and commented selection template.

.DESCRIPTION
Accepts the source ISO path and runs the existing exporter in a fresh Windows
PowerShell process. Configuration and toolchain inputs come from the repository
locks. Keeps all source artifacts together under .local/catalog and verifies the
worker's completed report and catalog identity. Run from an elevated terminal.
The coordinator supports 64-bit Windows PowerShell.

.PARAMETER IsoPath
Original Windows ISO matching the source lock.

.OUTPUTS
None. Writes the prepared source WIM, catalog, selection template, and workflow report.

.EXAMPLE
.\workflows\prepare-source.ps1 -IsoPath D:\temp\windows.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $IsoPath
)

. (Join-Path $PSScriptRoot '..\scripts\workflow-output.ps1')

function Invoke-SourcePreparation {
    <#
    .SYNOPSIS
    Exports and verifies the locked source catalog and selection template.

    .DESCRIPTION
    Runs the catalog worker in an isolated native process. Checks its fresh report, source identity, cleanup, generated files, and unchanged lock files before marking the workflow successful.

    .PARAMETER RepositoryRoot
    Absolute path to the repository whose configuration, workers, and local outputs are used.

    .PARAMETER IsoPath
    Path to the original Windows ISO matching the source lock.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Completed source-preparation operation.
    #>

    [CmdletBinding()]
    param(
        [string] $RepositoryRoot,
        [string] $IsoPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Write-WorkflowMessage 'Checking pinned source-preparation inputs:' -Data $IsoPath
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $iso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).ProviderPath

    if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) {
        throw 'IsoPath must identify a source ISO file.'
    }

    $sourcePath = Join-Path $root 'config\source-image.lock.json'
    $toolchainPath = Join-Path $root 'config\toolchain.lock.json'
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $toolchainHash = (Get-FileHash -LiteralPath $toolchainPath -Algorithm SHA256).Hash
    $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
    $toolchain = Get-Content -LiteralPath $toolchainPath -Raw | ConvertFrom-Json

    if ($source.schemaVersion -ne 1 -or $toolchain.schemaVersion -ne 1 -or -not $source.selectedImage -or $source.iso.sha256 -notmatch '^[a-f0-9]{64}$') {
        throw 'Source preparation requires valid locks and a selected source image.'
    }

    $version = [version]$source.selectedImage.version

    if ($version.Build -lt 0 -or $version.Revision -lt 0) {
        throw 'The selected image must have a complete build and revision.'
    }

    $output = Join-Path $root '.local\workflows\prepare-source'
    $catalogDirectory = Join-Path $root ('.local\catalog\pro-' + $version.Build + '.' + $version.Revision)
    $workerPath = Join-Path $root 'scripts\export-image-catalog.ps1'
    $workerReportPath = Join-Path $catalogDirectory 'operation.json'
    $resultPath = Join-Path $output 'operation.json'

    foreach ($directory in @($output, $catalogDirectory)) {
        if ($iso -ieq $directory -or $iso -ieq ($directory + '.lock') -or $iso.StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The source ISO must be outside the source-preparation output directories and lock files.'
        }
    }

    if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
        throw 'The source exporter is missing.'
    }

    foreach ($target in @($output, ($output + '.lock'), $resultPath, $catalogDirectory, ($catalogDirectory + '.lock'))) {
        $ancestor = $target

        while ($ancestor) {
            if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Source-preparation output paths must not contain reparse points.'
            }

            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
    }

    [IO.Directory]::CreateDirectory((Split-Path $output -Parent)) | Out-Null

    try {
        $lock = [IO.FileStream]::new(($output + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    }
    catch {
        throw 'Another prepare-source workflow is using this output directory.'
    }

    try {
        [IO.Directory]::CreateDirectory($output) | Out-Null
        $operation = [ordered]@{
            schemaVersion       = 1
            workflow            = 'PrepareSource'
            status              = 'Running'
            isoPath             = $iso
            sourceLockSha256    = $sourceHash
            toolchainLockSha256 = $toolchainHash
            startedAtUtc        = [DateTime]::UtcNow.ToString('o')
            completedAtUtc      = $null
            outputDirectory     = $catalogDirectory
            workerReportPath    = $workerReportPath
            exitCode            = $null
            wimPath             = Join-Path $catalogDirectory 'pro.wim'
            catalogPath         = Join-Path $catalogDirectory 'catalog.json'
            selectionsPath      = Join-Path $catalogDirectory 'selections.psd1'
            error               = $null
        }

        function Save-SourceWorkflowOperation {
            <#
            .SYNOPSIS
            Saves the current source-preparation workflow report.

            .DESCRIPTION
            Serializes the operation and result path from the enclosing source-preparation invocation.

            .OUTPUTS
            None. Updates the enclosing workflow operation.json file.
            #>

            $operation | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        }

        Save-SourceWorkflowOperation

        try {
            Write-WorkflowMessage 'Exporting the source WIM, component catalog, and selection template together. DISM log:' -Data (Join-Path $catalogDirectory 'dism.log')
            $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -Command {
                param(
                    $ScriptPath,
                    $SourceIso,
                    $Output,
                    $SourceLock,
                    $ToolchainLock
                )

                $global:LASTEXITCODE = 0

                try {
                    & $ScriptPath -IsoPath $SourceIso -OutputDirectory $Output -SourceLockPath $SourceLock -ToolchainLockPath $ToolchainLock 6>&1
                }
                catch {
                    Write-Error -ErrorRecord $_ -ErrorAction Continue
                    exit 1
                }

                exit $LASTEXITCODE
            } -args $workerPath, $iso, $catalogDirectory, $sourcePath, $toolchainPath | ForEach-Object {
                if ($_.PSObject.TypeNames -contains 'Deserialized.System.Management.Automation.InformationRecord' -and $_.Tags -contains 'PSHOST') {
                    $message = $_.MessageData
                    Write-Host $message.Message -ForegroundColor $message.ForegroundColor -NoNewline:([bool]$message.NoNewLine)
                }
                else {
                    $_ | Out-Host
                }
            }
            $operation.exitCode = $LASTEXITCODE

            if ($operation.exitCode -ne 0) {
                throw ('Source exporter failed with exit ' + $operation.exitCode + '. Report: ' + $workerReportPath)
            }

            Write-WorkflowMessage 'Checking the source exporter report and completed cleanup:' -Data $workerReportPath
            $report = Get-Content -LiteralPath $workerReportPath -Raw | ConvertFrom-Json

            if ([DateTimeOffset]$report.startedAtUtc -lt [DateTimeOffset]$operation.startedAtUtc -or -not $report.completedAtUtc -or [DateTimeOffset]$report.completedAtUtc -lt [DateTimeOffset]$report.startedAtUtc) {
                throw 'The source exporter did not produce a fresh completed report.'
            }
            if ($report.schemaVersion -ne 1 -or $report.status -cne 'Succeeded' -or @($report.cleanupErrors).Count -ne 0 -or -not $report.unmountedImage) {
                throw 'The source exporter report or image cleanup failed.'
            }

            foreach ($artifact in @($operation.wimPath, $operation.catalogPath, $operation.selectionsPath)) {
                if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or (Get-Item -LiteralPath $artifact -Force).Length -eq 0 -or ((Get-Item -LiteralPath $artifact -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw ('A source artifact is missing, empty, or unsafe: ' + $artifact)
                }
            }

            Write-WorkflowMessage 'Verifying the generated catalog identity and commented selection template.'
            $catalog = Get-Content -LiteralPath $operation.catalogPath -Raw | ConvertFrom-Json

            if ($catalog.schemaVersion -ne 1 -or $catalog.sourceIsoSha256 -ine $source.iso.sha256 -or $catalog.adkVersion -cne $toolchain.adk.version) {
                throw 'The source catalog differs from the pinned inputs.'
            }

            foreach ($field in @('path', 'index', 'name', 'editionId', 'architecture', 'version', 'defaultLanguage')) {
                if ([string]$catalog.sourceImage.$field -cne [string]$source.selectedImage.$field) {
                    throw ('The source catalog image differs from the lock: ' + $field)
                }
            }

            $selections = Import-PowerShellDataFile -LiteralPath $operation.selectionsPath

            if ($selections.SchemaVersion -ne 1) {
                throw 'Unsupported source selection-template schema.'
            }

            foreach ($section in @('OptionalFeatures', 'Capabilities', 'InboxApps')) {
                if ($selections[$section] -isnot [hashtable] -or $selections[$section].Count -ne 0) {
                    throw 'The source selection template must contain only commented component rules.'
                }
            }

            if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -cne $sourceHash -or (Get-FileHash -LiteralPath $toolchainPath -Algorithm SHA256).Hash -cne $toolchainHash) {
                throw 'A source-preparation lock changed during export.'
            }

            $operation.status = 'Succeeded'
        }
        catch {
            $operation.status = 'Failed'
            $operation.error = $_.Exception.Message
            Write-WorkflowMessage 'Source preparation failed:' -Data $operation.error -Level Error
        }
        finally {
            $operation.completedAtUtc = [DateTime]::UtcNow.ToString('o')
            Save-SourceWorkflowOperation
        }

        if ($operation.status -cne 'Succeeded') {
            throw $operation.error
        }

        Write-WorkflowMessage 'Source WIM ready for Windows SIM:' -Data $operation.wimPath -Level Success
        Write-WorkflowMessage 'Component catalog ready:' -Data $operation.catalogPath -Level Success
        Write-WorkflowMessage 'Commented selection template ready:' -Data $operation.selectionsPath -Level Success
        Write-WorkflowMessage 'Source preparation completed. Report:' -Data $resultPath -Level Success
        [PSCustomObject]$operation
    }
    finally {
        $lock.Dispose()
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Source preparation requires Windows.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Use a 64-bit PowerShell process.'
}

Invoke-SourcePreparation -RepositoryRoot (Split-Path $PSScriptRoot -Parent) -IsoPath $IsoPath | Out-Null
