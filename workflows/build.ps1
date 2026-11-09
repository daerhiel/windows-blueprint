#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Runs the configured image and installation-media build stages.
.DESCRIPTION
Uses the existing build workers in separate Windows PowerShell processes.
Run from an elevated 64-bit PowerShell Windows process.
Workers run in fresh native Windows PowerShell processes.
Does not install tools, change configuration, or manage test VMs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $IsoPath,
    [ValidateSet('Image', 'Media', 'All')] [string] $Stage = 'All',
    [switch] $Compress
)

. (Join-Path $PSScriptRoot '..\scripts\workflow-output.ps1')

function Invoke-ProjectBuild {
    [CmdletBinding()]
    param(
        [string] $RepositoryRoot,
        [string] $IsoPath,
        [ValidateSet('Image', 'Media', 'All')] [string] $Stage = 'All',
        [switch] $Compress
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Write-WorkflowMessage 'Checking build inputs and selected stages:' -Data $Stage
    if ($Stage -eq 'Image' -and $Compress) { throw '-Compress applies only to Media or All.' }
    $iso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) { throw 'IsoPath must identify a source ISO file.' }
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $output = Join-Path $root '.local\workflows\build'
    if ($iso.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The source ISO must be outside the workflow output.' }
    $resultPath = Join-Path $output 'operation.json'
    $phases = @(
        @{ name = 'Image'; script = 'build-image.ps1'; report = '.local\build\windows11-pro\operation.json'; artifact = '.local\build\windows11-pro\install.wim' }
        @{ name = 'Media'; script = 'build-install-media.ps1'; report = '.local\media\windows11-pro\operation.json'; artifact = '.local\media\windows11-pro\windows11-pro.iso' }
    ) | Where-Object { $Stage -eq 'All' -or $_.name -eq $Stage }
    foreach ($phase in $phases) {
        if (-not (Test-Path -LiteralPath (Join-Path $root ('scripts\' + $phase.script)) -PathType Leaf)) { throw ('Build worker is missing: ' + $phase.script) }
    }
    foreach ($target in @($output, ($output + '.lock'), $resultPath)) {
        $ancestor = $target
        while ($ancestor) {
            if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Workflow output paths must not contain reparse points.' }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
    }
    [IO.Directory]::CreateDirectory((Split-Path $output -Parent)) | Out-Null
    try {
        $lock = [IO.FileStream]::new(($output + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    }
    catch { throw 'Another build workflow is using this output directory.' }
    try {
        [IO.Directory]::CreateDirectory($output) | Out-Null
        $operation = [ordered]@{
            schemaVersion = 1; workflow = 'Build'; status = 'Running'
            stage = $Stage; compress = [bool]$Compress; isoPath = $iso
            startedAtUtc = [DateTime]::UtcNow.ToString('o'); completedAtUtc = $null
            phases = @(); error = $null
        }
        function Save-WorkflowOperation {
            $operation | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        }
        Save-WorkflowOperation
        $current = $null
        try {
            foreach ($phase in $phases) {
                $current = [ordered]@{
                    name = $phase.name; status = 'Running'; exitCode = $null
                    reportPath = Join-Path $root $phase.report
                    artifactPath = Join-Path $root $phase.artifact
                    startedAtUtc = [DateTime]::UtcNow.ToString('o'); completedAtUtc = $null; error = $null
                }
                $operation.phases += $current
                Save-WorkflowOperation
                if ($phase.name -eq 'Image') {
                    Write-WorkflowMessage 'Building the configured WIM in a separate Windows PowerShell process. DISM log:' -Data (Join-Path (Split-Path $current.reportPath -Parent) 'dism.log')
                }
                else {
                    Write-WorkflowMessage 'Packaging and verifying bootable installation media. DISM log:' -Data (Join-Path (Split-Path $current.reportPath -Parent) 'dism.log')
                    if ($Compress) { Write-WorkflowMessage 'Exporting recovery-compressed ESD was requested; compression may take a long time.' -Level Warning }
                }
                $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                # Serialize host messages as records so colors and transcript capture survive the worker boundary.
                & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -Command {
                    param($ScriptPath, $SourceIso, $UseCompression)
                    $global:LASTEXITCODE = 0
                    $parameters = @{ IsoPath = $SourceIso }
                    if ($UseCompression) { $parameters.Compress = $true }
                    try { & $ScriptPath @parameters 6>&1 }
                    catch {
                        # Relay exception text as output; serialized stderr can itself terminate the coordinator.
                        Write-Output ('Build worker exception: {0} ({1})' -f $_.Exception.Message, $_.FullyQualifiedErrorId)
                        Write-Output $_.InvocationInfo.PositionMessage
                        exit 1
                    }
                    exit $LASTEXITCODE
                } -args (Join-Path $root ('scripts\' + $phase.script)), $iso, ([bool]($phase.name -eq 'Media' -and $Compress)) | ForEach-Object {
                    if ($_.PSObject.TypeNames -contains 'Deserialized.System.Management.Automation.InformationRecord' -and $_.Tags -contains 'PSHOST') {
                        $message = $_.MessageData
                        Write-Host $message.Message -ForegroundColor $message.ForegroundColor -NoNewline:([bool]$message.NoNewLine)
                    }
                    else { $_ | Out-Host }
                }
                $current.exitCode = $LASTEXITCODE
                if ($current.exitCode -ne 0) {
                    $failureMessage = 'Build worker failed: {0}; exit {1}.' -f $phase.script, $current.exitCode
                    # Only use evidence from this invocation; a preflight failure can leave an older report.
                    if (Test-Path -LiteralPath $current.reportPath -PathType Leaf) {
                        try {
                            $failedReport = Get-Content -LiteralPath $current.reportPath -Raw | ConvertFrom-Json
                            if ($failedReport.completedAtUtc -and [DateTimeOffset]$failedReport.startedAtUtc -ge [DateTimeOffset]$current.startedAtUtc -and [DateTimeOffset]$failedReport.completedAtUtc -ge [DateTimeOffset]$failedReport.startedAtUtc) {
                                $current['workerStage'] = $failedReport.stage
                                $current['workerError'] = $failedReport.error
                                $current['cleanupErrors'] = @($failedReport.cleanupErrors)
                                if ($failedReport.PSObject.Properties['errorDetails']) { $current['workerErrorDetails'] = $failedReport.errorDetails }
                                $failureMessage += ' Stage: ' + $failedReport.stage + '.'
                                if (-not [string]::IsNullOrWhiteSpace($failedReport.error)) { $failureMessage += ' ' + $failedReport.error }
                                if (@($failedReport.cleanupErrors).Count) { $failureMessage += ' Cleanup: ' + ($failedReport.cleanupErrors -join '; ') }
                            }
                        }
                        catch { $failureMessage += ' Worker report could not be read: ' + $_.Exception.Message }
                    }
                    throw ($failureMessage + ' Report: ' + $current.reportPath)
                }
                Write-WorkflowMessage ($phase.name + ': checking the worker report, cleanup, and output artifact:') -Data $current.reportPath
                $report = Get-Content -LiteralPath $current.reportPath -Raw -ErrorAction Stop | ConvertFrom-Json
                if ([DateTimeOffset]$report.startedAtUtc -lt [DateTimeOffset]$current.startedAtUtc -or [DateTimeOffset]$report.completedAtUtc -lt [DateTimeOffset]$report.startedAtUtc) { throw ('Build worker did not produce a fresh completed report: ' + $phase.script) }
                if ($report.status -cne 'Succeeded' -or @($report.cleanupErrors).Count -ne 0) { throw ('Build worker report or cleanup failed: ' + $phase.script) }
                if (-not (Test-Path -LiteralPath $current.artifactPath -PathType Leaf)) { throw ('Build artifact is missing: ' + $current.artifactPath) }
                if ($phase.name -eq 'Image') {
                    if (-not $report.committed -or $report.outputImageIndex -ne 1 -or -not $report.outputWimSha256) { throw 'The image report does not describe a committed verified WIM.' }
                }
                else {
                    $compression = 'Unchanged'
                    if ($Compress) { $compression = 'Recovery' }
                    if ($report.imageIndex -ne 1 -or $report.filesVerified -lt 1 -or -not $report.isoSha256 -or $report.payloadCompression -cne $compression) { throw 'The media report does not describe verified media with the requested compression.' }
                }
                $current.status = 'Succeeded'
                $current.completedAtUtc = [DateTime]::UtcNow.ToString('o')
                Save-WorkflowOperation
                Write-WorkflowMessage ($phase.name + ': verified output:') -Data $current.artifactPath -Level Success
            }
            $operation.status = 'Succeeded'
        }
        catch {
            $operation.status = 'Failed'
            $operation['errorDetails'] = Get-WorkflowErrorDetails -Failure $_
            $operation.error = $operation.errorDetails.message
            if ($null -ne $current -and $current.status -eq 'Running') {
                $current.status = 'Failed'; $current.error = $operation.error; $current.completedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
            Write-WorkflowMessage 'Build workflow failed:' -Data $operation.error -Level Error
        }
        finally {
            $operation.completedAtUtc = [DateTime]::UtcNow.ToString('o')
            Save-WorkflowOperation
        }
        if ($operation.status -cne 'Succeeded') { throw $operation.error }
        Write-WorkflowMessage 'Build workflow completed. Report:' -Data $resultPath -Level Success
        [pscustomobject]$operation
    }
    finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -eq '.') { return }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Stage -eq 'Image' -and $Compress) { throw '-Compress applies only to Media or All.' }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'The build workflow requires Windows.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use a 64-bit PowerShell process.' }
Invoke-ProjectBuild -RepositoryRoot (Split-Path $PSScriptRoot -Parent) -IsoPath $IsoPath -Stage $Stage -Compress:$Compress | Out-Null
