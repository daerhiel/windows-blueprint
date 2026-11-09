#Requires -Version 5.1
<#
.SYNOPSIS
Checks build orchestration with isolated worker processes and synthetic artifacts.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'scripts\workflow-output.ps1')
$workflowPath = Join-Path $repository 'workflows\build.ps1'
# Load only the orchestration function; the executable entry point requires elevation.
$tokens = $null
$parseErrors = $null
$workflowAst = [Management.Automation.Language.Parser]::ParseFile($workflowPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'The build workflow contains syntax errors.' }
$buildFunction = @($workflowAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ProjectBuild' }, $false))
if ($buildFunction.Count -ne 1) { throw 'Expected one build orchestration function.' }
. ([scriptblock]::Create($buildFunction[0].Extent.Text))
$fixtureRoot = Join-Path $repository ('.local\workflow-tests\' + [Guid]::NewGuid().ToString('N'))
$checks = 0
function Assert-WorkflowTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:checks++
}
function Assert-WorkflowFailure {
    param([scriptblock] $Action, [string] $Expected)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-WorkflowTest ($message -like ('*' + $Expected + '*')) ('Expected failure: ' + $Expected + '; actual: ' + $message)
}
$worker = @'
param([string] $IsoPath, [switch] $Compress)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) { throw 'Build workers must run in 64-bit Windows PowerShell 5.1.' }
$root = Split-Path $PSScriptRoot -Parent
$phase = 'Media'
if ((Split-Path $PSCommandPath -Leaf) -eq 'build-image.ps1') { $phase = 'Image' }
Write-Host ('Synthetic ' + $phase + ' worker: ') -ForegroundColor White -NoNewline
Write-Host 'Running' -ForegroundColor Cyan
Write-Output ('Synthetic ' + $phase + ' native output')
$behavior = Get-Content -LiteralPath (Join-Path $root 'behavior.json') -Raw | ConvertFrom-Json
Add-Content -LiteralPath (Join-Path $root 'calls.txt') -Value ($phase + ':' + [bool]$Compress) -Encoding UTF8
if (-not (Test-Path -LiteralPath $IsoPath)) { exit 9 }
$applies = $behavior.phase -eq $phase
if ($applies -and $behavior.exitCode -and -not $behavior.reportBeforeExit) { exit $behavior.exitCode }
if ($applies -and $behavior.omitReport) { exit 0 }
$directory = Join-Path $root '.local\media\windows11-pro'
$artifact = 'windows11-pro.iso'
if ($phase -eq 'Image') { $directory = Join-Path $root '.local\build\windows11-pro'; $artifact = 'install.wim' }
[IO.Directory]::CreateDirectory($directory) | Out-Null
if ($applies -and $behavior.nativeDiagnostics) {
    . (Join-Path $PSScriptRoot 'workflow-output.ps1')
    $diagnosticCommand = "[Console]::Error.WriteLine(); [Console]::Error.WriteLine('Informational native banner'); [Console]::WriteLine('Native command succeeded'); exit 0"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($diagnosticCommand))
    Invoke-WorkflowNativeCommand -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -LogPath (Join-Path $directory 'native.log')
}
if (-not ($applies -and $behavior.omitArtifact)) { Set-Content -LiteralPath (Join-Path $directory $artifact) -Value 'synthetic artifact' }
$started = [DateTime]::UtcNow
if ($applies -and $behavior.staleReport) { $started = $started.AddDays(-1) }
$report = [ordered]@{
    status = 'Succeeded'; cleanupErrors = @(); startedAtUtc = $started.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o')
    committed = $true; outputImageIndex = 1; outputWimSha256 = 'synthetic WIM fingerprint'
    imageIndex = 1; filesVerified = 1; isoSha256 = 'synthetic ISO fingerprint'; payloadCompression = 'Unchanged'
    stage = 'Synthetic worker stage'; error = 'Synthetic compiler failure'; errorDetails = @{ fullyQualifiedErrorId = 'SyntheticErrorId' }
}
if ($Compress) { $report.payloadCompression = 'Recovery' }
if ($applies) { $report.status = $behavior.status; $report.cleanupErrors = @($behavior.cleanupErrors) }
$report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'operation.json') -Encoding UTF8
if ($applies -and $behavior.throwAfterReport) { throw 'Synthetic terminating worker exception' }
if ($applies -and $behavior.reportBeforeExit) { exit $behavior.exitCode }
exit 0
'@
function New-WorkflowFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only synthetic files in a unique Git-ignored test fixture; no image build or host servicing operation is performed.')]
    param([string] $Name, [hashtable] $Behavior = @{})
    $root = Join-Path $fixtureRoot $Name
    [IO.Directory]::CreateDirectory((Join-Path $root 'scripts')) | Out-Null
    foreach ($name in @('build-image.ps1', 'build-install-media.ps1')) { Set-Content -LiteralPath (Join-Path $root ('scripts\' + $name)) -Value $worker -Encoding UTF8 }
    Copy-Item -LiteralPath (Join-Path $repository 'scripts\workflow-output.ps1') -Destination (Join-Path $root 'scripts\workflow-output.ps1')
    $settings = @{ phase = 'Image'; status = 'Succeeded'; exitCode = 0; reportBeforeExit = $false; throwAfterReport = $false; nativeDiagnostics = $false; omitReport = $false; staleReport = $false; omitArtifact = $false; cleanupErrors = @() }
    foreach ($key in $Behavior.Keys) { $settings[$key] = $Behavior[$key] }
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'behavior.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'source image.iso') -Value 'synthetic source'
    $root
}
function Invoke-WorkflowFixture {
    param([string] $Root, [string] $Stage = 'All', [switch] $Compress)
    Invoke-ProjectBuild -RepositoryRoot $Root -IsoPath (Join-Path $Root 'source image.iso') -Stage $Stage -Compress:$Compress
}

$root = New-WorkflowFixture 'all stages'
$transcriptPath = Join-Path $root 'console.log'
Start-Transcript -LiteralPath $transcriptPath | Out-Null
try { $result = Invoke-ProjectBuild -RepositoryRoot $root -IsoPath (Join-Path $root 'source image.iso') -InformationVariable forwardedMessages }
finally { Stop-Transcript | Out-Null }
Assert-WorkflowTest ($result.status -eq 'Succeeded' -and ($result.phases.name -join ',') -eq 'Image,Media') 'Build both stages in order.'
Assert-WorkflowTest (@($result).Count -eq 1) 'Worker diagnostics do not leak into the returned workflow result.'
Assert-WorkflowTest (@($forwardedMessages | Where-Object { $_.Tags -contains 'PSHOST' -and $_.MessageData.Message -ceq 'Running' -and $_.MessageData.ForegroundColor -eq 'Cyan' }).Count -eq 2) 'Worker host messages retain their color when relayed through the coordinator.'
$transcriptText = Get-Content -LiteralPath $transcriptPath -Raw
$transcriptText = [regex]::Replace($transcriptText, '\s+', ' ')
Assert-WorkflowTest ($transcriptText.Contains('Synthetic Image worker: Running') -and $transcriptText.Contains('Synthetic Media worker: Running') -and $transcriptText.Contains('Synthetic Image native output')) 'Transcripts include all worker message segments and ordinary process output.'
Assert-WorkflowTest (((Get-Content (Join-Path $root 'calls.txt')) -join ',') -eq 'Image:False,Media:False') 'Development builds never request compression.'

$root = New-WorkflowFixture 'image only'
$result = Invoke-WorkflowFixture $root -Stage Image
Assert-WorkflowTest (@($result.phases).Count -eq 1 -and $result.phases[0].name -eq 'Image') 'Image selection must not invoke packaging.'

# Exercise public parameter binding and runtime guards without the privileged header.
$root = New-WorkflowFixture 'public entry point'
[IO.Directory]::CreateDirectory((Join-Path $root 'workflows')) | Out-Null
$workflowSource = Get-Content -LiteralPath $workflowPath -Raw
$entryGuard = @($workflowAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$MyInvocation.InvocationName -eq ''.'''
})
if ($entryGuard.Count -ne 1) {
    throw 'Expected one public entry-point guard.'
}
$entryOffset = $entryGuard[0].Extent.StartOffset
$entryPath = Join-Path $root 'workflows\build.ps1'
('[CmdletBinding()]' + [Environment]::NewLine + $workflowAst.ParamBlock.Extent.Text + [Environment]::NewLine + $workflowSource.Substring($entryOffset)) | Set-Content -LiteralPath $entryPath -Encoding UTF8
& $entryPath -IsoPath (Join-Path $root 'source image.iso') -Stage Image
$entryResult = Get-Content -LiteralPath (Join-Path $root '.local\workflows\build\operation.json') -Raw | ConvertFrom-Json
Assert-WorkflowTest ($entryResult.status -eq 'Succeeded' -and $entryResult.stage -eq 'Image' -and ((Get-Content -LiteralPath (Join-Path $root 'calls.txt')) -join ',') -eq 'Image:False') 'The public entry point accepts this Windows runtime and keeps the worker on 64-bit Windows PowerShell 5.1.'

$root = New-WorkflowFixture 'media only'
$result = Invoke-WorkflowFixture $root -Stage Media
Assert-WorkflowTest (((Get-Content (Join-Path $root 'calls.txt')) -join ',') -eq 'Media:False') 'Media selection must not invoke image servicing.'
$root = New-WorkflowFixture 'compressed media'
$result = Invoke-WorkflowFixture $root -Stage All -Compress
Assert-WorkflowTest (((Get-Content (Join-Path $root 'calls.txt')) -join ',') -eq 'Image:False,Media:True') 'Forward compression only to the media worker.'

$root = New-WorkflowFixture 'invalid compression'
Assert-WorkflowFailure { Invoke-WorkflowFixture $root -Stage Image -Compress } '-Compress applies only'
Assert-WorkflowTest (-not (Test-Path (Join-Path $root '.local'))) 'Reject invalid options before creating workflow output.'

$root = New-WorkflowFixture 'process failure' @{ exitCode = 7 }
Assert-WorkflowFailure { Invoke-WorkflowFixture $root } 'exit 7'
Assert-WorkflowTest (((Get-Content (Join-Path $root 'calls.txt')) -join ',') -eq 'Image:False') 'A worker process failure prevents the next stage.'
$failed = Get-Content (Join-Path $root '.local\workflows\build\operation.json') -Raw | ConvertFrom-Json
Assert-WorkflowTest ($failed.status -eq 'Failed' -and $failed.phases[0].exitCode -eq 7) 'Preserve the failed phase and exit code.'

$root = New-WorkflowFixture 'native informational stderr' @{ nativeDiagnostics = $true }
$result = Invoke-WorkflowFixture $root -Stage Image
$nativeLog = Get-Content -LiteralPath (Join-Path $root '.local\build\windows11-pro\native.log') -Raw
Assert-WorkflowTest ($result.status -eq 'Succeeded' -and $nativeLog.Contains('Informational native banner') -and $nativeLog.Contains('Exit code: 0')) 'Blank and informational native stderr must not terminate a serialized worker.'

$root = New-WorkflowFixture 'failed worker with report' @{ status = 'Failed'; exitCode = 7; reportBeforeExit = $true; cleanupErrors = @('Synthetic cleanup failure') }
Assert-WorkflowFailure { Invoke-WorkflowFixture $root } 'Synthetic compiler failure'
$failed = Get-Content (Join-Path $root '.local\workflows\build\operation.json') -Raw | ConvertFrom-Json
Assert-WorkflowTest ($failed.error.Contains('Synthetic worker stage') -and $failed.error.Contains('Synthetic cleanup failure') -and $failed.error.Contains($failed.phases[0].reportPath)) 'The final error includes worker stage, cleanup failure, and report path.'
Assert-WorkflowTest ($failed.phases[0].workerErrorDetails.fullyQualifiedErrorId -eq 'SyntheticErrorId') 'Preserve the original worker error details in the coordinator report.'

$root = New-WorkflowFixture 'worker exception with report' @{ status = 'Failed'; throwAfterReport = $true }
Assert-WorkflowFailure { Invoke-WorkflowFixture $root } 'Synthetic compiler failure'
$failed = Get-Content (Join-Path $root '.local\workflows\build\operation.json') -Raw | ConvertFrom-Json
Assert-WorkflowTest ($failed.phases[0].exitCode -eq 1 -and $failed.phases[0].workerErrorDetails.fullyQualifiedErrorId -eq 'SyntheticErrorId') 'A terminating worker exception must not prevent reading its fresh failure report.'

$root = New-WorkflowFixture 'failed worker with stale report' @{ status = 'Failed'; exitCode = 7; reportBeforeExit = $true; staleReport = $true }
Assert-WorkflowFailure { Invoke-WorkflowFixture $root } 'exit 7'
$failed = Get-Content (Join-Path $root '.local\workflows\build\operation.json') -Raw | ConvertFrom-Json
Assert-WorkflowTest (-not $failed.error.Contains('Synthetic compiler failure')) 'A failed worker must not attribute an older report to the current invocation.'

foreach ($case in @(
    @{ name = 'failed report'; behavior = @{ status = 'Failed' }; expected = 'report or cleanup failed' }
    @{ name = 'cleanup failure'; behavior = @{ cleanupErrors = @('synthetic cleanup failure') }; expected = 'report or cleanup failed' }
    @{ name = 'missing report'; behavior = @{ omitReport = $true }; expected = 'does not exist' }
    @{ name = 'stale report'; behavior = @{ staleReport = $true }; expected = 'fresh completed report' }
    @{ name = 'missing artifact'; behavior = @{ omitArtifact = $true }; expected = 'artifact is missing' }
)) {
    $root = New-WorkflowFixture $case.name $case.behavior
    Assert-WorkflowFailure { Invoke-WorkflowFixture $root } $case.expected
    Assert-WorkflowTest (((Get-Content (Join-Path $root 'calls.txt')) -join ',') -eq 'Image:False') 'Invalid worker evidence prevents packaging even with exit zero.'
}
$root = New-WorkflowFixture 'failed media' @{ phase = 'Media'; status = 'Failed' }
Assert-WorkflowFailure { Invoke-WorkflowFixture $root } 'report or cleanup failed'
$failed = Get-Content (Join-Path $root '.local\workflows\build\operation.json') -Raw | ConvertFrom-Json
Assert-WorkflowTest ($failed.phases[0].status -eq 'Succeeded' -and $failed.phases[1].status -eq 'Failed') 'Preserve a completed image phase when media verification fails.'

$root = New-WorkflowFixture 'locked workflow'
$output = Join-Path $root '.local\workflows\build'
[IO.Directory]::CreateDirectory($output) | Out-Null
Set-Content -LiteralPath (Join-Path $output 'operation.json') -Value 'existing evidence'
$held = [IO.FileStream]::new(($output + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
try { Assert-WorkflowFailure { Invoke-WorkflowFixture $root } 'Another build workflow' }
finally { $held.Dispose() }
Assert-WorkflowTest ((Get-Content (Join-Path $output 'operation.json') -Raw).Trim() -eq 'existing evidence') 'A concurrent invocation preserves existing workflow evidence.'
Assert-WorkflowTest (-not (Test-Path (Join-Path $root 'calls.txt'))) 'A blocked workflow starts no worker.'

$root = New-WorkflowFixture 'source inside workflow output'
$output = Join-Path $root '.local\workflows\build'
[IO.Directory]::CreateDirectory($output) | Out-Null
$inputPath = Join-Path $output 'operation.json'
Set-Content -LiteralPath $inputPath -Value 'source must be preserved'
Assert-WorkflowFailure { Invoke-ProjectBuild -RepositoryRoot $root -IsoPath $inputPath } 'source ISO must be outside'
Assert-WorkflowTest ((Get-Content -LiteralPath $inputPath -Raw).Trim() -eq 'source must be preserved') 'Reject an input in workflow output before overwriting it.'
Write-Output ('Build workflow checks passed: ' + $checks + '. Only synthetic worker processes and local fixture files were used.')
