#Requires -Version 5.1

<#
.SYNOPSIS
Runs a repository script through UAC and preserves startup errors locally.

.DESCRIPTION
Starts a repository script in an elevated native Windows PowerShell process. Uses an owned launch directory for serialized arguments, a transcript, and process results; records failures before propagating them.

.PARAMETER ScriptPath
Repository-local PowerShell script to run in the elevated child process.

.PARAMETER Parameters
Named argument values serialized for the child invocation. Do not use this file transfer for secrets.

.PARAMETER LogDirectory
Owned launch directory directly under .local/launches.

.PARAMETER ElevatedChild
Internal recursion switch used by the elevated process; not an operator option.

.PARAMETER ParameterFile
Internal serialized argument file passed to the elevated child.

.OUTPUTS
System.Management.Automation.PSCustomObject. Recorded child-process result on successful completion.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ScriptPath,

    [hashtable] $Parameters = @{},
    [string] $LogDirectory = (Join-Path $PSScriptRoot '..\.local\launches\catalog'),
    [switch] $ElevatedChild,
    [string] $ParameterFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptFullPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

if (-not $scriptFullPath.StartsWith($repositoryRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($scriptFullPath) -ne '.ps1') {
    throw 'Only PowerShell scripts inside this repository can be launched.'
}

$logFullPath = [IO.Path]::GetFullPath($LogDirectory).TrimEnd('\')
$launchRoot = Join-Path $repositoryRoot '.local\launches'

if ([IO.Path]::GetDirectoryName($logFullPath) -ine $launchRoot) {
    throw 'LogDirectory must be directly under the repository .local/launches directory.'
}
if ($scriptFullPath.StartsWith($logFullPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The target script must be outside the log directory.'
}

foreach ($checkedPath in @((Join-Path $repositoryRoot '.local'), $launchRoot, $logFullPath, ($logFullPath + '.lock'))) {
    if ((Test-Path -LiteralPath $checkedPath) -and ((Get-Item -LiteralPath $checkedPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Launch paths must not contain reparse points.'
    }
}

if ($ElevatedChild) {
    $result = [ordered]@{
        script            = $scriptFullPath
        status            = 'Running'
        processId         = $PID
        processStartTicks = [string]([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
        error             = $null
        stack             = $null
        exitCode          = 1
    }
    $transcriptStarted = $false

    try {
        $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $logFullPath 'result.json') -Encoding UTF8
        Start-Transcript -LiteralPath (Join-Path $logFullPath 'process.log') | Out-Null
        $transcriptStarted = $true
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

        if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'The child process did not receive administrator privileges.'
        }

        $scriptParameters = Import-Clixml -LiteralPath $ParameterFile
        $global:LASTEXITCODE = 0
        & $scriptFullPath @scriptParameters
        $result.exitCode = $LASTEXITCODE

        if ($LASTEXITCODE -ne 0) {
            throw ('The script returned exit code ' + $LASTEXITCODE)
        }

        $result.status = 'Succeeded'
    }
    catch {
        $result.status = 'Failed'
        $result.error = $_.Exception.Message
        $result.stack = $_.ScriptStackTrace

        if ($result.exitCode -eq 0) {
            $result.exitCode = 1
        }
    }
    finally {
        if ($transcriptStarted) {
            Stop-Transcript | Out-Null
        }
    }

    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $logFullPath 'result.json') -Encoding UTF8
    exit $result.exitCode
}

[IO.Directory]::CreateDirectory($launchRoot) | Out-Null

try {
    $launchLock = [IO.FileStream]::new(($logFullPath + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
}
catch {
    throw 'Another launch is using this log directory.'
}

try {
    if (Test-Path -LiteralPath $logFullPath) {
        $resolvedLogPath = (Resolve-Path -LiteralPath $logFullPath).ProviderPath

        if ([IO.Path]::GetDirectoryName($resolvedLogPath) -ine $launchRoot) {
            throw 'Unsafe launch cleanup path.'
        }

        $previousResultPath = Join-Path $logFullPath 'result.json'

        if (Test-Path -LiteralPath $previousResultPath) {
            $previousResult = Get-Content -LiteralPath $previousResultPath -Raw | ConvertFrom-Json

            if ($previousResult.PSObject.Properties['processId']) {
                $previousProcess = Get-Process -Id $previousResult.processId -ErrorAction SilentlyContinue

                if ($null -ne $previousProcess -and [string]$previousProcess.StartTime.ToUniversalTime().Ticks -eq $previousResult.processStartTicks) {
                    throw 'The previous elevated process is still running.'
                }
            }
        }

        if (@(Get-ChildItem -LiteralPath $resolvedLogPath -Force -Recurse | Where-Object {
                    $_.Attributes -band [IO.FileAttributes]::ReparsePoint
                }).Count -gt 0) {
            throw 'Launch contents must not contain reparse points.'
        }

        Remove-Item -LiteralPath $resolvedLogPath -Recurse -Force
    }

    [IO.Directory]::CreateDirectory($logFullPath) | Out-Null
    $parameterFullPath = Join-Path $logFullPath 'parameters.clixml'
    $Parameters | Export-Clixml -LiteralPath $parameterFullPath
    $childArguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $PSCommandPath + '"'),
        '-ElevatedChild', '-ScriptPath', ('"' + $scriptFullPath + '"'),
        '-LogDirectory', ('"' + $logFullPath + '"'), '-ParameterFile', ('"' + $parameterFullPath + '"')
    )
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childProcess = Start-Process -FilePath $windowsPowerShell -Verb RunAs -WindowStyle Hidden -ArgumentList $childArguments -PassThru
    # Wait for the operation process, not an interactive console it may open.
    $childProcess.WaitForExit()
    $resultPath = Join-Path $logFullPath 'result.json'

    if (Test-Path -LiteralPath $resultPath) {
        $childResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $childResult

        if ($childResult.status -ne 'Succeeded') {
            throw ('Elevated script failed; see ' + $resultPath)
        }
    }
    else {
        throw ('The elevated process exited before recording its result. Exit code: ' + $childProcess.ExitCode)
    }
}
finally {
    $launchLock.Dispose()
}
