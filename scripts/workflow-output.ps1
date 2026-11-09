#Requires -Version 5.1
<#
.SYNOPSIS
Defines console messages, native output capture, and workflow error details.
#>
function Write-WorkflowMessage {
    param(
        [string] $Message,
        [ValidateSet('Step', 'Success', 'Warning', 'Error')] [string] $Level = 'Step',
        [string] $Data
    )
    $color = 'Cyan'; $label = 'STEP'
    switch ($Level) {
        Success { $color = 'Green'; $label = 'OK' }
        Warning { $color = 'Yellow'; $label = 'WARN' }
        Error { $color = 'Red'; $label = 'FAIL' }
    }
    Write-Host ('[{0:HH:mm:ss}] ' -f (Get-Date)) -ForegroundColor White -NoNewline
    Write-Host ('[{0}] ' -f $label) -ForegroundColor $color -NoNewline
    if ($Data) {
        Write-Host ($Message + ' ') -ForegroundColor White -NoNewline
        Write-Host $Data -ForegroundColor $color
    }
    else { Write-Host $Message -ForegroundColor White }
}

function Get-WorkflowErrorDetails {
    param([Parameter(Mandatory = $true)] [Management.Automation.ErrorRecord] $Failure)
    $message = $Failure.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message) -and $Failure.ErrorDetails) { $message = $Failure.ErrorDetails.Message }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'PowerShell operation failed without an exception message. Error ID: ' + $Failure.FullyQualifiedErrorId
    }
    $position = $null
    if ($null -ne $Failure.InvocationInfo) { $position = $Failure.InvocationInfo.PositionMessage }
    [pscustomobject]@{
        message = $message
        fullyQualifiedErrorId = $Failure.FullyQualifiedErrorId
        exceptionType = $Failure.Exception.GetType().FullName
        position = $position
        scriptStackTrace = $Failure.ScriptStackTrace
        exceptionText = $Failure.Exception.ToString()
    }
}

function Invoke-WorkflowNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [Parameter(Mandatory = $true)] [string] $LogPath
    )
    # Quote Windows arguments as data, including embedded quotes and trailing backslashes.
    $quotedArguments = foreach ($argument in $Arguments) {
        $escaped = [regex]::Replace([string]$argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.WorkingDirectory = (Get-Location).ProviderPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw ('Could not start native command: ' + $FilePath) }
        # Drain both streams concurrently; stderr text alone is not a process failure.
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $outputTask.GetAwaiter().GetResult()
        $standardError = $errorTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally { $process.Dispose() }
    $record = @(
        ('[{0}] {1} {2}' -f [DateTime]::UtcNow.ToString('o'), $FilePath, $startInfo.Arguments)
        ('Exit code: ' + $exitCode), 'Standard output:', $standardOutput, 'Standard error:', $standardError, ''
    ) -join [Environment]::NewLine
    [IO.File]::AppendAllText($LogPath, $record, [Text.UTF8Encoding]::new($false))
    if ($exitCode -ne 0) {
        $detail = $standardError.Trim()
        if (-not $detail) { $detail = $standardOutput.Trim() }
        if (-not $detail) { $detail = 'The process produced no diagnostic output.' }
        throw ('Native command failed: {0}; exit {1}. {2} Log: {3}' -f $FilePath, $exitCode, $detail, $LogPath)
    }
    if ($standardOutput) { $standardOutput -split '\r?\n' }
}
