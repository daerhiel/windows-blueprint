#Requires -Version 5.1
<#
.SYNOPSIS
Checks native process diagnostics and argument handling without servicing images.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\workflow-output.ps1')
$fixture = Join-Path (Split-Path $PSScriptRoot -Parent) ('.local\workflow-output-tests\' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$checks = 0
function Assert-OutputTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:checks++
}
# Inspect the process arguments independently of script parameter binding.
$probe = Join-Path $fixture 'native probe.ps1'
@'
[Console]::Error.WriteLine('')
[Console]::Error.WriteLine('Informational native banner')
$commandLine = [Environment]::GetCommandLineArgs()
$scriptIndex = [Array]::IndexOf($commandLine, $PSCommandPath)
for ($i = $scriptIndex + 1; $i -lt $commandLine.Length; $i++) { [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandLine[$i]))) }
[Console]::WriteLine([Environment]::CurrentDirectory)
exit 0
'@ | Set-Content -LiteralPath $probe -Encoding ASCII
$shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @('plain', 'path with spaces\', 'embedded"quote', 'slash\\"quote', 'symbols $() & ;', '')
$log = Join-Path $fixture 'native.log'
Push-Location -LiteralPath $fixture
try { $output = @(Invoke-WorkflowNativeCommand -FilePath $shell -Arguments (@('-NoProfile', '-NonInteractive', '-File', $probe) + $arguments) -LogPath $log) }
finally { Pop-Location }
for ($i = 0; $i -lt $arguments.Count; $i++) {
    $expected = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($arguments[$i]))
    Assert-OutputTest ($output[$i] -ceq $expected) ('Preserve native argument ' + $i)
}
Assert-OutputTest ($output[$arguments.Count] -ieq $fixture) 'Use the PowerShell working directory for relative native paths.'
$logText = Get-Content -LiteralPath $log -Raw
Assert-OutputTest ($logText.Contains('Informational native banner') -and $logText.Contains('Exit code: 0')) 'Capture stderr without treating informational output as failure.'

$failureCommand = "[Console]::Error.WriteLine('Synthetic native failure'); exit 7"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($failureCommand))
$failure = ''
try { Invoke-WorkflowNativeCommand -FilePath $shell -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -LogPath $log | Out-Null }
catch { $failure = $_.Exception.Message }
Assert-OutputTest ($failure.Contains('exit 7') -and $failure.Contains('Synthetic native failure') -and $failure.Contains($log)) 'A nonzero exit reports the exit code, native diagnostics, and log path.'

# Enough concurrent output to fill both OS pipes if either is drained synchronously.
$largeCommand = "1..256 | ForEach-Object { [Console]::Out.WriteLine(('o' * 1024)); [Console]::Error.WriteLine(('e' * 1024)) }; exit 0"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($largeCommand))
$largeLog = Join-Path $fixture 'large.log'
Invoke-WorkflowNativeCommand -FilePath $shell -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -LogPath $largeLog | Out-Null
Assert-OutputTest ((Get-Item -LiteralPath $largeLog).Length -gt 512KB) 'Drain and retain both large native output streams.'

$emptyFailure = [Management.Automation.ErrorRecord]::new([Exception]::new(''), 'SyntheticEmptyMessage', [Management.Automation.ErrorCategory]::NotSpecified, $null)
$details = Get-WorkflowErrorDetails -Failure $emptyFailure
Assert-OutputTest (-not [string]::IsNullOrWhiteSpace($details.message) -and $details.message.Contains('SyntheticEmptyMessage')) 'An empty exception message still identifies the PowerShell error.'
Write-Output ('Native diagnostic checks passed: ' + $checks + '.')
