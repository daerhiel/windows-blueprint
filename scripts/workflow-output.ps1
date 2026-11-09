#Requires -Version 5.1

<#
.SYNOPSIS
Defines console messages, native output capture, and workflow error details.

.DESCRIPTION
Dot-source this file to define the shared console, native-process, and diagnostic helpers. Loading it does not run an operation.

.OUTPUTS
None. Defines shared helper functions.
#>


function Write-WorkflowMessage {
    <#
    .SYNOPSIS
    Writes a timestamped console message with a colored status tag.

    .DESCRIPTION
    Keeps ordinary text white and highlights the status tag and optional data. Messages use the host information stream and do not become pipeline results.

    .PARAMETER Message
    Human-readable description of the current stage or result.

    .PARAMETER Level
    Status used to choose the tag and highlight color.

    .PARAMETER Data
    Optional path, identifier, or result highlighted after the message.

    .OUTPUTS
    None. Writes a host message.
    #>

    param(
        [string] $Message,
        [ValidateSet('Step', 'Success', 'Warning', 'Error')] [string] $Level = 'Step',
        [string] $Data
    )

    $color = 'Cyan'
    $label = 'STEP'

    switch ($Level) {
        Success {
            $color = 'Green'
            $label = 'OK'
        }
        Warning {
            $color = 'Yellow'
            $label = 'WARN'
        }
        Error {
            $color = 'Red'
            $label = 'FAIL'
        }
    }

    Write-Host ('[{0:HH:mm:ss}] ' -f (Get-Date)) -ForegroundColor White -NoNewline
    Write-Host ('[{0}] ' -f $label) -ForegroundColor $color -NoNewline

    if ($Data) {
        Write-Host ($Message + ' ') -ForegroundColor White -NoNewline
        Write-Host $Data -ForegroundColor $color
    }
    else {
        Write-Host $Message -ForegroundColor White
    }
}

function Get-WorkflowErrorDetails {
    <#
    .SYNOPSIS
    Creates serializable diagnostics from a PowerShell error record.

    .DESCRIPTION
    Preserves the exception type, error ID, source position, and stack trace. Supplies a fallback message when the exception text is empty.

    .PARAMETER Failure
    Error record captured by the failing operation.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Diagnostic fields suitable for an operation report.
    #>

    param(
        [Parameter(Mandatory = $true)] [Management.Automation.ErrorRecord] $Failure
    )

    $message = $Failure.Exception.Message

    if ([string]::IsNullOrWhiteSpace($message) -and $Failure.ErrorDetails) {
        $message = $Failure.ErrorDetails.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'PowerShell operation failed without an exception message. Error ID: ' + $Failure.FullyQualifiedErrorId
    }

    $position = $null

    if ($null -ne $Failure.InvocationInfo) {
        $position = $Failure.InvocationInfo.PositionMessage
    }

    [PSCustomObject]@{
        message               = $message
        fullyQualifiedErrorId = $Failure.FullyQualifiedErrorId
        exceptionType         = $Failure.Exception.GetType().FullName
        position              = $position
        scriptStackTrace      = $Failure.ScriptStackTrace
        exceptionText         = $Failure.Exception.ToString()
    }
}

function Invoke-WorkflowNativeCommand {
    <#
    .SYNOPSIS
    Runs a native Windows command and records both output streams.

    .DESCRIPTION
    Quotes arguments as data, drains stdout and stderr concurrently, and appends a diagnostic record. Throws on a nonzero exit code; stderr text alone does not indicate failure.

    .PARAMETER FilePath
    Path to the executable to start without a command shell.

    .PARAMETER Arguments
    Individual argument values passed to the executable.

    .PARAMETER LogPath
    File to append command details and output to; its parent directory must already exist.

    .OUTPUTS
    System.String. Lines from the successful command standard output.
    #>

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
        if (-not $process.Start()) {
            throw ('Could not start native command: ' + $FilePath)
        }

        # Drain both streams concurrently; stderr text alone is not a process failure.
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $outputTask.GetAwaiter().GetResult()
        $standardError = $errorTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    $record = @(
        ('[{0}] {1} {2}' -f [DateTime]::UtcNow.ToString('o'), $FilePath, $startInfo.Arguments)
        ('Exit code: ' + $exitCode), 'Standard output:', $standardOutput, 'Standard error:', $standardError, ''
    ) -join [Environment]::NewLine
    [IO.File]::AppendAllText($LogPath, $record, [Text.UTF8Encoding]::new($false))

    if ($exitCode -ne 0) {
        $detail = $standardError.Trim()

        if (-not $detail) {
            $detail = $standardOutput.Trim()
        }
        if (-not $detail) {
            $detail = 'The process produced no diagnostic output.'
        }

        throw ('Native command failed: {0}; exit {1}. {2} Log: {3}' -f $FilePath, $exitCode, $detail, $LogPath)
    }

    if ($standardOutput) {
        $standardOutput -split '\r?\n'
    }
}
