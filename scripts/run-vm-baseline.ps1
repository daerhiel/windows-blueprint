#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Starts the prepared test VM or inspects/audits it through PowerShell Direct.
.DESCRIPTION
Targets only the VM ID and VHDX recorded by new-test-vm.ps1. Networking must remain
disconnected. Imports the local DPAPI credential without printing it. Audit runs
copy only the audit script and configuration to an owned guest working directory.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Start', 'Inspect', 'Audit', 'Capture', 'Limited')] [string] $Action,
    [ValidatePattern('^[a-z][a-z0-9-]{0,39}$')] [string] $ReportName = 'baseline',
    [ValidateRange(0, 1800)] [int] $WaitForGuestSeconds = 0,
    [ValidateSet('Baseline', 'Configured')] [string] $VMProfile = 'Baseline',
    [switch] $OpenConsole
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1.' }
$reportNameWasSpecified = $PSBoundParameters.ContainsKey('ReportName')
. (Join-Path $PSScriptRoot 'new-test-vm.ps1') -IsoPath 'unused-baseline.iso' -VMProfile $VMProfile
$settings = Get-TestVMConfiguration -VMProfile $VMProfile
if ($VMProfile -eq 'Configured' -and -not $reportNameWasSpecified) { $ReportName = 'configured' }
$metadata = Get-Content -LiteralPath (Join-Path $settings.directory 'vm.json') -Raw | ConvertFrom-Json
Import-Module Hyper-V
$vm = Get-VM -Id $metadata.vmId
$disks = @(Get-VMHardDiskDrive -VM $vm)
if ($vm.Name -cne $settings.vm.Name -or $disks.Count -ne 1) {
    throw ('VM identity or disk attachment differs from the recorded test VM. Expected name: {0}; actual: {1}; expected disk: {2}; actual disks: {3}' -f $settings.vm.Name, $vm.Name, $metadata.vhdPath, (@($disks | ForEach-Object { $_.Path }) -join ', '))
}
# Checkpoints replace the attached path; every parent must remain inside this VM's directory.
$diskPath = [IO.Path]::GetFullPath($disks[0].Path)
$visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
while ($diskPath -ine $metadata.vhdPath) {
    if (-not $diskPath.StartsWith($settings.directory + '\', [StringComparison]::OrdinalIgnoreCase) -or -not $visited.Add($diskPath)) { throw 'Unrelated or cyclic VHD parent chain.' }
    $disk = Get-VHD -Path $diskPath
    if ($disk.VhdType -ne 'Differencing' -or -not $disk.ParentPath) { throw 'The attached disk does not descend from the recorded test VHDX.' }
    $diskPath = [IO.Path]::GetFullPath($disk.ParentPath)
}
if (@(Get-VMNetworkAdapter -VM $vm | Where-Object { $_.SwitchName }).Count -gt 0) { throw 'The baseline VM must remain disconnected from all virtual switches.' }
$output = Join-Path $settings.root '.local\vm-baseline'
if ($VMProfile -eq 'Configured') { $output = Join-Path $settings.root '.local\vm-configured' }
$ancestor = $output
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Baseline output paths must not contain reparse points.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
if (-not $PSCmdlet.ShouldProcess($vm.Name, $Action)) { return }
[IO.Directory]::CreateDirectory($output) | Out-Null
if ($Action -eq 'Start') {
    $validationDirectory = Join-Path $settings.root '.local\vm-validation'
    if ($VMProfile -eq 'Configured') { $validationDirectory = Join-Path $settings.root '.local\vm-configured-validation' }
    $validation = Get-Content -LiteralPath (Join-Path $validationDirectory 'validation.json') -Raw | ConvertFrom-Json
    if ($validation.status -cne 'Succeeded' -or $validation.answer.status -cne 'Pass') { throw 'A clean Windows SIM/VM validation is required before starting installation.' }
    if ($validation.vm.name -cne $vm.Name) { throw 'Validation belongs to another VM.' }
    if ($vm.State -ne 'Off' -or $disks[0].Path -ine $metadata.vhdPath -or (Get-Item -LiteralPath $metadata.vhdPath).Length -gt 64MB) { throw 'Start is only for the powered-off fresh test disk without checkpoints, not an existing installation.' }
    if ((Get-FileHash -LiteralPath $metadata.seedIsoPath -Algorithm SHA256).Hash -cne $metadata.seedIsoSha256) { throw 'Answer media changed after VM preparation.' }
    $dvds = @(Get-VMDvdDrive -VM $vm | Where-Object { $_.Path -and $_.Path -ine $metadata.seedIsoPath })
    if ($dvds.Count -ne 1 -or (Get-FileHash -LiteralPath $dvds[0].Path -Algorithm SHA256).Hash -cne $metadata.isoSha256) { throw 'The attached source ISO differs from the recorded input.' }
    Start-VM -VM $vm
    if ($OpenConsole) {
        # This is an interactive console the user may need for the DVD prompt and OOBE.
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\vmconnect.exe') -ArgumentList @('localhost', $vm.Name) -WindowStyle Normal | Out-Null
    }
    Write-Output ('Started ' + $vm.Name + ' with disconnected networking.')
    return
}
$startedForLimited = $false
if ($Action -eq 'Limited') {
    if (-not $reportNameWasSpecified) { $ReportName = 'limited-user' }
    $checkpointRecord = Get-Content -LiteralPath (Join-Path $output 'checkpoint.json') -Raw | ConvertFrom-Json
    if ($checkpointRecord.vmId -cne $metadata.vmId -or @(Get-VMSnapshot -VM $vm | Where-Object { [string]$_.Id -ceq $checkpointRecord.id }).Count -ne 1) { throw 'The recorded clean baseline checkpoint must exist before limited-user testing.' }
    if (@(Get-VMDvdDrive -VM $vm | Where-Object { $_.Path }).Count -gt 0) { throw 'Installation media must remain detached.' }
    if ($vm.State -eq 'Off') {
        Start-VM -VM $vm
        $startedForLimited = $true
        $vm = Get-VM -Id $metadata.vmId
    }
    if ($WaitForGuestSeconds -eq 0) { $WaitForGuestSeconds = 300 }
}
if ($vm.State -ne 'Running') { throw 'The test VM is not running.' }
if ($Action -eq 'Capture') {
    $reportLabels = @('baseline', 'baseline-repeat')
    if ($VMProfile -eq 'Configured') { $reportLabels = @('configured', 'configured-repeat') }
    foreach ($name in $reportLabels) {
        & $PSCommandPath -Action Audit -ReportName $name -VMProfile $VMProfile
    }
    $first = Get-Content -LiteralPath (Join-Path $output ($reportLabels[0] + '\audit.json')) -Raw | ConvertFrom-Json
    $second = Get-Content -LiteralPath (Join-Path $output ($reportLabels[1] + '\audit.json')) -Raw | ConvertFrom-Json
    $firstReceipt = Get-Content -LiteralPath (Join-Path $output ($reportLabels[0] + '\collection.json')) -Raw | ConvertFrom-Json
    $secondReceipt = Get-Content -LiteralPath (Join-Path $output ($reportLabels[1] + '\collection.json')) -Raw | ConvertFrom-Json
    if ($VMProfile -eq 'Configured' -and ($first.exitCode -ne 0 -or $second.exitCode -ne 0)) { throw 'Both configured audits must pass before saving a checkpoint; inspect their reports.' }
    if ($firstReceipt.auditScriptSha256 -cne $secondReceipt.auditScriptSha256 -or $firstReceipt.configurationSha256 -cne $secondReceipt.configurationSha256) { throw 'Audit code or configuration changed between baseline runs.' }
    function Get-StableBaseline {
        param($Report)
        $projection = [ordered]@{}
        foreach ($area in $Report.areas.PSObject.Properties) {
            if ($area.Value.status -notin @('Complete', 'NotApplicable')) { throw ('Incomplete collection: ' + $area.Name) }
            if ($area.Name -eq 'Reboot') { continue }
            $data = $area.Value.data
            if ($area.Name -eq 'Services') { $data = @($data | Select-Object name, startMode, delayedAutoStart) }
            $projection[$area.Name] = $data
        }
        ConvertTo-Json -InputObject $projection -Depth 30 -Compress
    }
    $match = (Get-StableBaseline $first) -ceq (Get-StableBaseline $second)
    [ordered]@{
        schemaVersion = 1; stableAreasMatch = $match
        ignoredVolatileFields = @('timestamps', 'service running states', 'reboot indicators')
        firstExitCode = $first.exitCode; secondExitCode = $second.exitCode
        comparedAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'comparison.json') -Encoding UTF8
    if (-not $match) { throw 'Stable baseline inventories differ; review the two reports before creating a checkpoint.' }
    $checkpointName = 'baseline-audited'
    if ($VMProfile -eq 'Configured') { $checkpointName = 'configured-audited' }
    if (@(Get-VMSnapshot -VM $vm | Where-Object { $_.Name -eq $checkpointName }).Count -gt 0) { throw 'The baseline checkpoint name already exists; existing checkpoints are never replaced.' }
    # A powered-off checkpoint avoids capturing transient guest memory and open file state.
    Stop-VM -VM $vm -Confirm:$false
    $vm = Get-VM -Id $metadata.vmId
    if ($vm.State -ne 'Off') { throw 'The VM did not shut down cleanly; no checkpoint was created.' }
    foreach ($dvd in @(Get-VMDvdDrive -VM $vm | Where-Object { $_.Path })) {
        Set-VMDvdDrive -VMDvdDrive $dvd -Path $null
    }
    Set-VMFirmware -VM $vm -FirstBootDevice (Get-VMHardDiskDrive -VM $vm)
    Checkpoint-VM -VM $vm -SnapshotName $checkpointName
    $checkpoint = Get-VMSnapshot -VM $vm | Where-Object { $_.Name -eq $checkpointName }
    [ordered]@{
        schemaVersion = 1; vmId = [string]$vm.Id; name = $checkpointName; id = [string]$checkpoint.Id
        state = 'Off'; installMediaDetached = $true; createdAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'checkpoint.json') -Encoding UTF8
    Write-Output ('Stable baseline captured; VM powered off; checkpoint: ' + $checkpointName)
    return
}
try {
    if ($WaitForGuestSeconds -gt 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds($WaitForGuestSeconds)
        while ([string]$vm.Heartbeat -notlike 'Ok*') {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the guest Windows heartbeat; inspect Setup in the VM console.' }
            Start-Sleep -Seconds 5
            $vm = Get-VM -Id $metadata.vmId
            if ($vm.State -ne 'Running') { throw 'The VM stopped while waiting for Windows.' }
        }
    }
    $credential = Import-Clixml -LiteralPath (Join-Path $settings.directory 'secrets\credential.clixml')
    $session = New-PSSession -VMId $vm.Id -Credential $credential -ErrorAction Stop
    try {
        $inspection = Invoke-Command -Session $session -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup'
            $imageState = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
            finally { $identity.Dispose() }
            $recovery = @(& reagentc.exe /info 2>&1 | ForEach-Object { [string]$_ })
            $recoveryExit = $LASTEXITCODE
            [pscustomobject]@{
                editionId = $cv.EditionID; build = $cv.CurrentBuildNumber; revision = $cv.UBR
                computerName = $env:COMPUTERNAME; systemPreferredUiLanguage = [string](Get-SystemPreferredUILanguage)
                imageState = $imageState; systemSetupInProgress = $setup.SystemSetupInProgress; oobeInProgress = $setup.OOBEInProgress
                desktopShellRunning = (@(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count -gt 0)
                isAdministrator = $admin; partitionStyle = [string](Get-Disk -Number 0).PartitionStyle
                partitions = @(Get-Partition -DiskNumber 0 | Sort-Object PartitionNumber | Select-Object PartitionNumber, Type, GptType, Size)
                recoveryExitCode = $recoveryExit; recovery = $recovery
            }
        }
        $inspectionPath = Join-Path $output 'inspection.json'
        if ((Test-Path -LiteralPath $inspectionPath) -and ((Get-Item -LiteralPath $inspectionPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Inspection report must not be a reparse point.' }
        $inspection | Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inspectionPath -Encoding UTF8
        if ($Action -eq 'Inspect') {
            $inspection | Select-Object editionId, build, revision, imageState, systemSetupInProgress, oobeInProgress, desktopShellRunning, isAdministrator, partitionStyle
            return
        }
        $installedVersion = '10.0.' + $inspection.build + '.' + $inspection.revision
        $firstSignInConfirmed = $inspection.desktopShellRunning
        $checkpointPath = Join-Path $output 'checkpoint.json'
        if (-not $firstSignInConfirmed -and (Test-Path -LiteralPath $checkpointPath)) {
            $previousCapture = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            $firstSignInConfirmed = $previousCapture.vmId -ceq $metadata.vmId -and @(Get-VMSnapshot -VM $vm | Where-Object { [string]$_.Id -ceq $previousCapture.id }).Count -eq 1
        }
        if ($inspection.imageState -ne 'IMAGE_STATE_COMPLETE' -or $inspection.systemSetupInProgress -ne 0 -or $inspection.oobeInProgress -ne 0 -or ($Action -ne 'Limited' -and -not $firstSignInConfirmed) -or -not $inspection.isAdministrator -or $inspection.editionId -cne 'Professional' -or $inspection.systemPreferredUiLanguage -cne 'en-US' -or $installedVersion -cne $settings.source.selectedImage.version -or $inspection.partitionStyle -ne 'GPT' -or $inspection.recoveryExitCode -ne 0 -or ($inspection.recovery -join ' ') -notmatch 'Windows RE status:\s+Enabled') { throw 'Complete source-matching Pro setup, confirmed first sign-in, administrator access, GPT, and enabled Windows RE are required before baseline collection.' }
        $destination = Join-Path $output $ReportName
        if (Test-Path -LiteralPath $destination) { throw 'Host report directory already exists; previous audit evidence is never overwritten.' }
        $guestRoot = 'C:\WindowsProject'
        Invoke-Command -Session $session -ScriptBlock {
            $root = $using:guestRoot
            $ErrorActionPreference = 'Stop'
            $marker = Join-Path $Root '.baseline-project'
            if ((Test-Path -LiteralPath $Root) -and (-not (Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw) -cne 'Windows ADK baseline project')) { throw 'Guest working directory already exists without the project marker.' }
            New-Item -ItemType Directory -Path (Join-Path $Root 'scripts'), (Join-Path $Root 'config') -Force | Out-Null
            [IO.File]::WriteAllText($marker, 'Windows ADK baseline project')
        }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'audit.ps1') -Destination ($guestRoot + '\scripts\audit.ps1') -ToSession $session
        Copy-Item -LiteralPath (Join-Path $settings.root 'config\windows.psd1') -Destination ($guestRoot + '\config\windows.psd1') -ToSession $session
        $limited = $Action -eq 'Limited'
        $audit = Invoke-Command -Session $session -ScriptBlock {
            $root = $using:guestRoot
            $name = $using:ReportName
            $ErrorActionPreference = 'Stop'
            Set-Location -LiteralPath $Root
            $directory = Join-Path $Root ('.local\audit\' + $Name)
            if (Test-Path -LiteralPath $directory) { throw 'Guest report directory already exists.' }
            $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if ($using:limited) {
                $completion = Join-Path $Root ('.local\' + $Name + '.completed.json')
                if (Test-Path -LiteralPath $completion) { throw 'A previous limited-user completion record already exists.' }
                $bootstrap = @'
$ErrorActionPreference = 'Stop'
$projectRoot = '__ROOT__'
$reportLabel = '__NAME__'
$completionPath = Join-Path $projectRoot ('.local\' + $reportLabel + '.completed.json')
try {
    . (Join-Path $projectRoot 'scripts\audit.ps1')
    $result = Invoke-WindowsAudit -ConfigurationPath (Join-Path $projectRoot 'config\windows.psd1') -OutputDirectory (Join-Path $projectRoot ('.local\audit\' + $reportLabel))
    [ordered]@{ status = 'Completed'; exitCode = $result.exitCode; isAdministrator = $result.context.isAdministrator; languageMode = [string]$ExecutionContext.SessionState.LanguageMode } | ConvertTo-Json | Set-Content -LiteralPath $completionPath -Encoding UTF8
    exit $result.exitCode
}
catch {
    [ordered]@{ status = 'Failed'; exitCode = 4; error = $_.Exception.Message; languageMode = [string]$ExecutionContext.SessionState.LanguageMode } | ConvertTo-Json | Set-Content -LiteralPath $completionPath -Encoding UTF8
    exit 4
}
'@
                $bootstrap = $bootstrap.Replace('__ROOT__', $Root).Replace('__NAME__', $Name)
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
                $command = $powershell + ' -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -EncodedCommand ' + $encoded
                $launch = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\runas.exe') -ArgumentList @('/trustlevel:0x20000', ('"' + $command + '"')) -WindowStyle Hidden -PassThru -Wait
                if ($launch.ExitCode -ne 0) { throw ('Limited-user launcher failed with exit ' + $launch.ExitCode) }
                $deadline = [DateTime]::UtcNow.AddMinutes(3)
                while (-not (Test-Path -LiteralPath $completion)) {
                    if ([DateTime]::UtcNow -ge $deadline) { throw 'Limited-user process did not record completion.' }
                    Start-Sleep -Seconds 1
                }
                $completed = Get-Content -LiteralPath $completion -Raw | ConvertFrom-Json
                if ($completed.status -cne 'Completed') { throw ('Limited-user process failed: ' + $completed.error) }
                if ($completed.isAdministrator) { throw 'The audit process retained administrator privileges.' }
                $processExit = $completed.exitCode
            }
            else {
                & $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $Root 'scripts\audit.ps1') -ConfigurationPath (Join-Path $Root 'config\windows.psd1') -OutputDirectory $directory | Out-Null
                $processExit = $LASTEXITCODE
            }
            [pscustomobject]@{
                exitCode = $processExit; directory = $directory
                auditScriptSha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'scripts\audit.ps1') -Algorithm SHA256).Hash
                configurationSha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'config\windows.psd1') -Algorithm SHA256).Hash
            }
        }
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        Copy-Item -Path ($audit.directory + '\*') -Destination $destination -FromSession $session -Recurse
        if ($limited) {
            Copy-Item -LiteralPath ($guestRoot + '\.local\' + $ReportName + '.completed.json') -Destination (Join-Path $destination 'launch.json') -FromSession $session
        }
        [ordered]@{
            vmId = [string]$vm.Id; sourceImageVersion = $settings.source.selectedImage.version
            auditScriptSha256 = $audit.auditScriptSha256
            configurationSha256 = $audit.configurationSha256
            collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'collection.json') -Encoding UTF8
        $report = Get-Content -LiteralPath (Join-Path $destination 'audit.json') -Raw | ConvertFrom-Json
        if ($report.exitCode -ne $audit.exitCode) { throw 'Guest process exit code differs from its audit report.' }
        Write-Output ('Copied {0}: exit {1}; {2} mismatches; {3} incomplete areas; {4} unresolved checks.' -f $ReportName, $audit.exitCode, $report.summary.nonCompliant, $report.summary.incompleteAreas, $report.summary.notVerified)
        if ($limited) {
            if ($report.context.isAdministrator -or ($report.exitCode -band 2) -ne 2 -or $report.summary.incompleteAreas -eq 0 -or $report.areas.RegisteredApps.status -cne 'Partial' -or $report.areas.RegisteredApps.scope -cne 'CurrentUser') { throw 'The limited-user audit did not expose the expected privilege and scope limitations.' }
            Write-Output 'Limited-user behavior verified: restricted process, incomplete collection, and current-user registration scope.'
        }
        elseif ($audit.exitCode -notin @(0, 1)) { throw 'Baseline audit is incomplete; inspect its reports.' }
    }
    finally { Remove-PSSession -Session $session }
}
finally {
    if ($startedForLimited -and (Get-VM -Id $metadata.vmId).State -eq 'Running') { Stop-VM -VM (Get-VM -Id $metadata.vmId) -Confirm:$false }
}
