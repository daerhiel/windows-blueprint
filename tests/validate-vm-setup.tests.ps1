#Requires -Version 5.1
<#
.SYNOPSIS
Checks the Windows SIM process boundary with synthetic workers and reports.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'scripts\workflow-output.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'scripts\validate-vm-setup.ps1'), [ref]$tokens, [ref]$errors)
if ($errors) { throw 'The VM validator contains syntax errors.' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-TestVMValidationWorker' }, $false)
. ([scriptblock]::Create($function.Extent.Text))
$fixture = Join-Path $repository ('.local\vm-validation-tests\' + [Guid]::NewGuid().ToString('N'))
$checks = 0
function Assert-ValidationTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:checks++
}
function Assert-ValidationFailure {
    param([scriptblock] $Action, [string] $Expected)
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert-ValidationTest ($message.Contains($Expected)) ('Expected ' + $Expected + '; actual: ' + $message)
}
$worker = @'
param([string] $WimPath, [string] $VMProfile)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'SIM requires the isolated native worker.' }
$behavior = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'behavior.json') -Raw | ConvertFrom-Json
if ($WimPath -cne $behavior.wimPath -or $VMProfile -cne $behavior.profile) { throw 'Worker inputs changed across the process boundary.' }
Write-Host 'Synthetic SIM stage' -ForegroundColor Cyan
if ($behavior.mode -eq 'Exit') { exit 7 }
if ($behavior.mode -eq 'Throw') { throw 'Synthetic SIM exception' }
if ($behavior.mode -eq 'Missing') { return }
$started = [DateTime]::UtcNow
if ($behavior.mode -eq 'Stale') { $started = $started.AddDays(-1) }
$report = @{ status = 'Succeeded'; startedAtUtc = $started.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o'); answer = @{ status = 'Pass' }; runtime = @{ powerShellEdition = $PSVersionTable.PSEdition } }
if ($behavior.mode -eq 'Failed') { $report.status = 'Failed' }
if ($behavior.mode -eq 'Warning') { $report.answer.status = 'Warning' }
if ($behavior.mode -eq 'Incomplete') { $report.completedAtUtc = $null }
$report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'validation.json') -Encoding UTF8
'@
function New-ValidationFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only synthetic files in a unique Git-ignored test fixture; no Windows SIM or VM operation is performed.')]
    param([string] $Mode, [string] $VMProfile = 'Configured')
    $directory = Join-Path $fixture ($Mode + ' ' + $VMProfile)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $wimPath = Join-Path $directory "source ' image.wim"
    Set-Content -LiteralPath $wimPath -Value 'synthetic WIM'
    Set-Content -LiteralPath (Join-Path $directory 'worker.ps1') -Value $worker -Encoding UTF8
    @{ mode = $Mode; profile = $VMProfile; wimPath = $wimPath } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'behavior.json') -Encoding UTF8
    @{ WorkerPath = Join-Path $directory 'worker.ps1'; WimPath = $wimPath; VMProfile = $VMProfile; OutputDirectory = $directory }
}
foreach ($VMProfile in @('Configured', 'Baseline')) {
    $parameters = New-ValidationFixture -Mode Success -VMProfile $VMProfile
    $result = @(Invoke-TestVMValidationWorker @parameters -InformationVariable messages)
    $report = Get-Content -LiteralPath (Join-Path $parameters.OutputDirectory 'validation.json') -Raw | ConvertFrom-Json
    Assert-ValidationTest ($report.runtime.powerShellEdition -eq 'Desktop' -and $result.Count -eq 0) 'Only a JSON report crosses back from the native worker; diagnostics do not leak as result objects.'
    Assert-ValidationTest (@($messages | Where-Object { $_.Tags -contains 'PSHOST' -and $_.MessageData.Message -ceq 'Synthetic SIM stage' -and $_.MessageData.ForegroundColor -eq 'Cyan' }).Count -eq 1) 'Relay worker stage messages with their original console color.'
    Assert-ValidationTest ((Get-Content -LiteralPath (Join-Path $parameters.OutputDirectory 'worker.log') -Raw).Contains('Synthetic SIM stage')) 'Retain worker stage messages in the transcript.'
}
foreach ($case in @(
    @{ mode = 'Exit'; expected = 'exit 7' }
    @{ mode = 'Throw'; expected = 'exit 1' }
    @{ mode = 'Missing'; expected = 'does not exist' }
    @{ mode = 'Stale'; expected = 'fresh completed report' }
    @{ mode = 'Incomplete'; expected = 'fresh completed report' }
    @{ mode = 'Failed'; expected = 'report did not pass' }
    @{ mode = 'Warning'; expected = 'report did not pass' }
)) {
    $parameters = New-ValidationFixture -Mode $case.mode
    Assert-ValidationFailure { Invoke-TestVMValidationWorker @parameters } $case.expected
}
Write-Output ('Passed ' + $checks + ' VM validation worker checks without Windows SIM or VM access.')
