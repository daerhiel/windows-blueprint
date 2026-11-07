#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Validates the test answer file with Windows SIM and checks the created VM.
.DESCRIPTION
Creates a Windows SIM catalog for the exported Pro WIM if necessary. Validates
a rendered answer with a synthetic password, never the actual VM password.
Writes validation.json under .local/vm-validation. Does not start the VM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $WimPath,
    [ValidateSet('Baseline', 'Configured')] [string] $VMProfile = 'Baseline'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1.' }
. (Join-Path $PSScriptRoot 'new-test-vm.ps1') -IsoPath 'unused-validation.iso' -VMProfile $VMProfile
$settings = Get-TestVMConfiguration -VMProfile $VMProfile
$output = Join-Path $settings.root '.local\vm-validation'
if ($VMProfile -eq 'Configured') { $output = Join-Path $settings.root '.local\vm-configured-validation' }
$ancestor = $output
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Validation paths must not contain reparse points.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
foreach ($file in @('autounattend.xml', 'validation.json')) {
    $path = Join-Path $output $file
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Validation files must not be reparse points.' }
}
[IO.Directory]::CreateDirectory($output) | Out-Null
$record = [ordered]@{ status = 'Failed'; startedAtUtc = [DateTime]::UtcNow.ToString('o'); vm = $null; answer = $null; error = $null }
try {
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
    if ((Get-FileHash -LiteralPath $metadata.seedIsoPath -Algorithm SHA256).Hash -cne $metadata.seedIsoSha256) { throw 'Answer-file ISO changed after VM creation.' }
    $secretAcl = Get-Acl -LiteralPath (Join-Path $settings.directory 'secrets')
    $ownerSid = $secretAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $allowedSids = @($ownerSid, 'S-1-5-18', 'S-1-5-32-544')
    if (-not $secretAcl.AreAccessRulesProtected -or @($secretAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -notin $allowedSids }).Count -gt 0) { throw 'Credential directory permissions are broader than its owner, SYSTEM, and Administrators.' }
    $record.vm = @{ name = $vm.Name; state = [string]$vm.State; secureBoot = [string]$firmware.SecureBoot; tpmEnabled = $security.TpmEnabled; diskType = [string]$vhd.VhdType; network = 'Disconnected'; nestedVirtualization = $processor.ExposeVirtualizationExtensions }
    $toolchain = Get-Content -LiteralPath (Join-Path $settings.root 'config\toolchain.lock.json') -Raw | ConvertFrom-Json
    foreach ($file in $toolchain.adk.wsim.files.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $toolchain.adk.wsim.directory $file.Name) -Algorithm SHA256).Hash -cne $file.Value) { throw "Windows SIM binary does not match its lock: $($file.Name)" }
    }
    $secure = [Security.SecureString]::new()
    foreach ($character in 'Validation-only!9'.ToCharArray()) { $secure.AppendChar($character) }
    $credential = [pscredential]::new($settings.vm.AccountName, $secure)
    $answerPath = Join-Path $output 'autounattend.xml'
    [IO.File]::WriteAllText($answerPath, (Get-TestVMAnswer -Settings $settings -Credential $credential), [Text.UTF8Encoding]::new($false))
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
    if (-not (Test-Path -LiteralPath $imageInfo.CatalogPath)) { $imageInfo.CreateCatalog() | Out-Null }
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
    $record.answer = @{ status = [string]$result.CurrentStatus; succeeded = $result.Succeeded; messages = @($messages.ToArray()); catalogPath = $imageInfo.CatalogPath; templateSha256 = (Get-FileHash -LiteralPath (Join-Path $settings.root 'setup\vm\autounattend.xml') -Algorithm SHA256).Hash }
    if (-not $result.Succeeded -or [string]$result.CurrentStatus -cne 'Pass') { throw 'Windows SIM validation returned errors or warnings; review validation.json.' }
    $record.status = 'Succeeded'
}
catch { $record.error = $_.Exception.Message }
finally {
    $record['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'validation.json') -Encoding UTF8
}
if ($record.status -ne 'Succeeded') { throw $record.error }
Write-Output ('VM and Windows SIM validation succeeded. Report: ' + (Join-Path $output 'validation.json'))
