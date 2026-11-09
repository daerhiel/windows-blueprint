#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Validates the test answer file with Windows SIM and checks the created VM.
.DESCRIPTION
Creates a Windows SIM catalog for the exported Pro WIM if necessary. Validates
a production deployment answer, or the baseline answer with a synthetic password.
Writes validation.json under .local/vm-validation. Does not start the VM.
Runs Windows SIM in a separate Windows PowerShell worker when called from a
different runtime; the calling workflow keeps its current PowerShell host.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $WimPath,
    [ValidateSet('Baseline', 'Configured')] [string] $VMProfile = 'Baseline'
)
. (Join-Path $PSScriptRoot 'workflow-output.ps1')

function Invoke-TestVMValidationWorker {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Relays worker host records with their original colors without adding diagnostics to returned validation data.')]
    param([string] $WorkerPath, [string] $WimPath, [string] $VMProfile, [string] $OutputDirectory)
    $started = [DateTimeOffset]::UtcNow
    $reportPath = Join-Path $OutputDirectory 'validation.json'
    $logPath = Join-Path $OutputDirectory 'worker.log'
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-WorkflowMessage 'Running Windows SIM in an isolated compatibility worker. Log:' -Data $logPath
    # Only paths and a profile cross the process boundary; SIM objects stay in the worker.
    & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -Command {
        param($ScriptPath, $SourceWim, $VMProfile, $LogPath)
        $transcriptStarted = $false
        $global:LASTEXITCODE = 0
        try {
            Start-Transcript -LiteralPath $LogPath -Force | Out-Null
            $transcriptStarted = $true
            & $ScriptPath -WimPath $SourceWim -VMProfile $VMProfile 6>&1
        }
        catch {
            Write-Output ('VM validation worker failed: {0} ({1})' -f $_.Exception.Message, $_.FullyQualifiedErrorId)
            Write-Output $_.InvocationInfo.PositionMessage
            exit 1
        }
        finally { if ($transcriptStarted) { Stop-Transcript | Out-Null } }
        exit $LASTEXITCODE
    } -args $WorkerPath, $WimPath, $VMProfile, $logPath | ForEach-Object {
        if ($_.PSObject.TypeNames -contains 'Deserialized.System.Management.Automation.InformationRecord' -and $_.Tags -contains 'PSHOST') {
            $message = $_.MessageData
            Write-Host $message.Message -ForegroundColor $message.ForegroundColor -NoNewline:([bool]$message.NoNewLine)
        }
        else { $_ | Out-Host }
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw ('VM validation worker failed; exit {0}. Report: {1} Log: {2}' -f $exitCode, $reportPath, $logPath) }
    $report = Get-Content -LiteralPath $reportPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if (-not $report.completedAtUtc -or [DateTimeOffset]$report.startedAtUtc -lt $started -or [DateTimeOffset]$report.completedAtUtc -lt [DateTimeOffset]$report.startedAtUtc) { throw 'VM validation worker did not produce a fresh completed report.' }
    if ($report.status -cne 'Succeeded' -or $report.answer.status -cne 'Pass') { throw ('VM validation worker report did not pass. Report: ' + $reportPath) }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'VM setup validation requires Windows.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use a 64-bit PowerShell process.' }
. (Join-Path $PSScriptRoot 'new-test-vm.ps1') -IsoPath 'unused-validation.iso' -VMProfile $VMProfile
$settings = Get-TestVMConfiguration -VMProfile $VMProfile
$output = Join-Path $settings.root '.local\vm-validation'
if ($VMProfile -eq 'Configured') { $output = Join-Path $settings.root '.local\vm-configured-validation' }
$ancestor = $output
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Validation paths must not contain reparse points.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
foreach ($file in @('autounattend.xml', 'validation.json', 'worker.log')) {
    $path = Join-Path $output $file
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Validation files must not be reparse points.' }
}
[IO.Directory]::CreateDirectory($output) | Out-Null
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Invoke-TestVMValidationWorker -WorkerPath $PSCommandPath -WimPath (Resolve-Path -LiteralPath $WimPath -ErrorAction Stop).ProviderPath -VMProfile $VMProfile -OutputDirectory $output
    return
}
$record = [ordered]@{ status = 'Failed'; stage = 'Check VM hardware'; startedAtUtc = [DateTime]::UtcNow.ToString('o'); vm = $null; answer = $null; error = $null; runtime = @{ powerShellVersion = [string]$PSVersionTable.PSVersion; powerShellEdition = $PSVersionTable.PSEdition; clrVersion = [string][Environment]::Version } }
function Write-ValidationStage {
    param([string] $Name)
    $record.stage = $Name
    Write-WorkflowMessage ('SIM: ' + $Name)
}
try {
    Write-ValidationStage 'Check VM hardware and installation-media attachments'
    $metadata = Get-Content -LiteralPath (Join-Path $settings.directory 'vm.json') -Raw | ConvertFrom-Json
    Import-Module Hyper-V
    $vm = Get-VM -Id $metadata.vmId
    $processor = Get-VMProcessor -VM $vm
    $memory = Get-VMMemory -VM $vm
    $firmware = Get-VMFirmware -VM $vm
    $security = Get-VMSecurity -VM $vm
    $disks = @(Get-VMHardDiskDrive -VM $vm)
    if ($vm.Name -cne $settings.vm.Name -or $vm.State -ne 'Off' -or $vm.Generation -ne 2 -or $processor.Count -ne $settings.vm.ProcessorCount -or $processor.ExposeVirtualizationExtensions -ne $settings.vm.ExposeVirtualizationExtensions -or $memory.Startup -ne $settings.vm.MemoryBytes -or $memory.DynamicMemoryEnabled -or [string]$firmware.SecureBoot -ne 'On' -or -not $security.TpmEnabled -or $disks.Count -ne 1 -or $disks[0].Path -ine $metadata.vhdPath) { throw 'The actual VM does not match the powered-off test profile.' }
    $vhd = Get-VHD -Path $disks[0].Path
    if ($vhd.VhdType -ne 'Dynamic' -or $vhd.Size -ne $settings.vm.DiskBytes -or @(Get-VMNetworkAdapter -VM $vm | Where-Object { $_.SwitchName }).Count -gt 0) { throw 'Unexpected VHD or network configuration.' }
    if ($VMProfile -eq 'Baseline') {
        if ((Get-FileHash -LiteralPath $metadata.seedIsoPath -Algorithm SHA256).Hash -cne $metadata.seedIsoSha256) { throw 'Answer-file ISO changed after VM creation.' }
        $secretAcl = Get-Acl -LiteralPath (Join-Path $settings.directory 'secrets')
        $ownerSid = $secretAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $allowedSids = @($ownerSid, 'S-1-5-18', 'S-1-5-32-544')
        if (-not $secretAcl.AreAccessRulesProtected -or @($secretAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -notin $allowedSids }).Count -gt 0) { throw 'Credential directory permissions are broader than its owner, SYSTEM, and Administrators.' }
    }
    elseif ($metadata.seedIsoPath -or @(Get-VMDvdDrive -VM $vm | Where-Object { $_.Path }).Count -ne 1) { throw 'The configured VM must use only the deployment ISO, without answer media.' }
    $record.vm = @{ id = [string]$vm.Id; name = $vm.Name; metadataSha256 = (Get-FileHash -LiteralPath (Join-Path $settings.directory 'vm.json') -Algorithm SHA256).Hash; state = [string]$vm.State; secureBoot = [string]$firmware.SecureBoot; tpmEnabled = $security.TpmEnabled; diskType = [string]$vhd.VhdType; network = 'Disconnected'; nestedVirtualization = $processor.ExposeVirtualizationExtensions }
    $record['configurationSha256'] = (Get-FileHash -LiteralPath (Join-Path $settings.root 'config\windows.psd1') -Algorithm SHA256).Hash
    $toolchain = Get-Content -LiteralPath (Join-Path $settings.root 'config\toolchain.lock.json') -Raw | ConvertFrom-Json
    Write-ValidationStage 'Verify the pinned Windows SIM libraries'
    foreach ($file in $toolchain.adk.wsim.files.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $toolchain.adk.wsim.directory $file.Name) -Algorithm SHA256).Hash -cne $file.Value) { throw "Windows SIM binary does not match its lock: $($file.Name)" }
    }
    $answerPath = Join-Path $output 'autounattend.xml'
    Write-ValidationStage 'Render the answer file for the selected VM profile'
    $templatePath = Join-Path $settings.root 'setup\vm\autounattend.xml'
    if ($VMProfile -eq 'Baseline') {
        $secure = [Security.SecureString]::new()
        foreach ($character in 'Validation-only!9'.ToCharArray()) { $secure.AppendChar($character) }
        $credential = [pscredential]::new($settings.vm.AccountName, $secure)
        [IO.File]::WriteAllText($answerPath, (Get-TestVMAnswer -Settings $settings -Credential $credential), [Text.UTF8Encoding]::new($false))
    }
    else {
        . (Join-Path $settings.root 'setup\deployment\install.ps1')
        $templatePath = Join-Path $settings.root 'setup\deployment\autounattend.xml'
        $layout = Get-DeploymentLayout -DiskBytes $settings.vm.DiskBytes -Configuration $settings.windows
        $template = [xml](Get-Content -LiteralPath $templatePath -Raw)
        $answer = New-DeploymentAnswer -Template $template -Configuration $settings.windows -DiskNumber 0 -Layout $layout -MachineName 'DT-WSIM123'
        $answer.Save($answerPath)
    }
    $rendered = [xml](Get-Content -LiteralPath $answerPath -Raw)
    $imageSelection = $rendered.SelectSingleNode('//*[local-name()="MetaData"]/*[local-name()="Value"]')
    if ($null -eq $imageSelection -or $imageSelection.InnerText -cne [string]$settings.imageIndex) { throw 'The answer file does not select the profile image index.' }
    # Cached catalogs contain implementation types; load both pinned assemblies before reading them.
    foreach ($assembly in @('microsoft.componentstudio.componentplatforminterface.dll', 'microsoft.componentstudio.ComponentPlatformImplementation.dll')) {
        [Reflection.Assembly]::LoadFrom((Join-Path $toolchain.adk.wsim.directory $assembly)) | Out-Null
    }
    $cpi = [Microsoft.ComponentStudio.ComponentPlatformInterface.Cpi]::Instance
    $wim = $cpi.OpenWim((Resolve-Path -LiteralPath $WimPath).ProviderPath)
    if ($wim.Images.Count -ne 1 -or $wim.Images[0].ImageName -cne $settings.source.selectedImage.name) { throw 'Use the single-image Pro WIM exported by the project.' }
    $imageInfo = $wim.Images[0]
    $record['catalogPath'] = $imageInfo.CatalogPath
    if (-not (Test-Path -LiteralPath $imageInfo.CatalogPath)) {
        Write-ValidationStage 'Create the source WIM catalog; this can take several minutes'
        try { $imageInfo.CreateCatalog() | Out-Null }
        catch {
            # Remove only an incomplete catalog created by this invocation.
            $catalogFailure = $_
            try { if (Test-Path -LiteralPath $imageInfo.CatalogPath -PathType Leaf) { Remove-Item -LiteralPath $imageInfo.CatalogPath -Force } }
            catch { Write-WorkflowMessage 'Could not remove the incomplete catalog:' -Data $_.Exception.Message -Level Warning }
            throw $catalogFailure
        }
    }
    Write-ValidationStage 'Open the source WIM catalog and validate the answer file'
    # Catalog creation opens the image as a side effect; cached catalogs need this explicitly.
    $cpi.OpenOfflineImage($imageInfo) | Out-Null
    $answerFile = $cpi.OpenAnswerFile($answerPath, $imageInfo)
    if ($null -eq $answerFile.OfflineImage) { throw 'Windows SIM did not associate the answer file with the selected image.' }
    $result = $answerFile.Validate()
    $messages = [Collections.Generic.List[string]]::new()
    function Add-ValidationMessage {
        param($Result)
        if ($Result.Message) { $messages.Add(([string]$Result.CurrentStatus + ': ' + $Result.Message)) }
        foreach ($inner in $Result.InnerResults) { Add-ValidationMessage $inner }
    }
    Add-ValidationMessage $result
    $record.answer = @{ status = [string]$result.CurrentStatus; succeeded = $result.Succeeded; messages = @($messages.ToArray()); catalogPath = $imageInfo.CatalogPath; templateSha256 = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash }
    if (-not $result.Succeeded -or [string]$result.CurrentStatus -cne 'Pass') { throw 'Windows SIM validation returned errors or warnings; review validation.json.' }
    $record.stage = 'Complete'
    $record.status = 'Succeeded'
}
catch {
    $record['errorDetails'] = Get-WorkflowErrorDetails -Failure $_
    $record.error = $record.errorDetails.message
}
finally {
    $record['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'validation.json') -Encoding UTF8
}
if ($record.status -ne 'Succeeded') { throw $record.error }
Write-Output ('VM and Windows SIM validation succeeded. Report: ' + (Join-Path $output 'validation.json'))
