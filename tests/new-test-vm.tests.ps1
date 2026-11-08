#Requires -Version 5.1
<#
.SYNOPSIS
Validates VM answer rendering and local secret ACLs without creating a VM.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'scripts\new-test-vm.ps1') -IsoPath 'unused-fixture.iso'
$checks = 0
function Assert-VMTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
$settings = Get-TestVMConfiguration
$secret = [Security.SecureString]::new()
foreach ($character in 'Synthetic<&"password>9!'.ToCharArray()) { $secret.AppendChar($character) }
$credential = [pscredential]::new($settings.vm.AccountName, $secret)
$answer = Get-TestVMAnswer -Settings $settings -Credential $credential
$xml = [xml]$answer
$ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
$ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
$setup = "//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']"
Assert-VMTest ($answer -notmatch '__[A-Z_]+__') 'All template placeholders must be resolved.'
Assert-VMTest ($xml.SelectSingleNode('//u:LocalAccount/u:Password/u:Value', $ns).InnerText -ceq $credential.GetNetworkCredential().Password) 'XML escaping must preserve password characters without breaking the document.'
Assert-VMTest ($xml.SelectSingleNode('//u:LocalAccount/u:Name', $ns).InnerText -eq $settings.vm.AccountName) 'The local account must match configuration.'
Assert-VMTest ($null -eq $xml.SelectSingleNode('//u:AutoLogon', $ns)) 'The baseline must not use automatic sign-in.'
Assert-VMTest ($null -eq $xml.SelectSingleNode('//u:SkipMachineOOBE', $ns)) 'The template must not skip the OOBE engine.'
Assert-VMTest ($xml.SelectSingleNode($setup + '/u:DynamicUpdate/u:Enable', $ns).InnerText -eq 'false') 'Setup Dynamic Update must be disabled for the offline baseline.'
Assert-VMTest ($xml.SelectSingleNode($setup + '/u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData/u:Value', $ns).InnerText -eq [string]$settings.source.selectedImage.index) 'The image index must come from the source lock.'
$configured = Get-TestVMConfiguration -VMProfile Configured
$caught = $false
try { Get-TestVMAnswer -Settings $configured -Credential $credential | Out-Null } catch { $caught = $true }
Assert-VMTest $caught 'Configured installation must never generate private answer media.'
Assert-VMTest ($configured.vm.Name -cne $settings.vm.Name) 'Configured installation must target a different VM name.'
Assert-VMTest ($configured.directory -ine $settings.directory) 'Configured installation must use a different disk and secret directory.'
Assert-VMTest ($configured.vm.ProcessorCount -eq $settings.vm.ProcessorCount -and $configured.vm.MemoryBytes -eq $settings.vm.MemoryBytes -and $configured.vm.DiskBytes -eq 2TB -and $settings.vm.DiskBytes -eq 80GB) 'Configured VM exercises C/D sizing on a dynamic disk while baseline hardware stays unchanged.'
Assert-VMTest ($configured.imageIndex -eq 1) 'Configured media must select its single WIM image.'
Assert-VMTest ($configured.source.selectedImage.index -eq $settings.source.selectedImage.index -and $settings.imageIndex -eq $settings.source.selectedImage.index) 'Configured selection must leave the official source and baseline index unchanged.'
Assert-VMTest (-not $configured.vm.ContainsKey('AccountName') -and -not $configured.vm.ContainsKey('ComputerName') -and -not $configured.vm.ContainsKey('TimeZone')) 'Configured account comes from OOBE, host name from production setup, and time zone from Windows defaults.'
Assert-VMTest ($xml.SelectSingleNode($setup + '/u:ImageInstall/u:OSImage/u:InstallTo/u:DiskID', $ns).InnerText -eq '0') 'Installation must target the newly created VM disk.'
Assert-VMTest ($xml.SelectSingleNode($setup + '/u:ImageInstall/u:OSImage/u:InstallTo/u:PartitionID', $ns).InnerText -eq '3') 'Windows must target its GPT partition.'
$partitions = @($xml.SelectNodes($setup + '/u:DiskConfiguration/u:Disk/u:CreatePartitions/u:CreatePartition', $ns))
Assert-VMTest ($partitions.Count -eq 4 -and $partitions[0].Type -eq 'EFI' -and $partitions[1].Type -eq 'MSR' -and $partitions[3].Extend -eq 'true') 'GPT partitions must be EFI, MSR, Windows, then recovery.'
$fixedSize = [long]$partitions[0].Size + [long]$partitions[1].Size + [long]$partitions[2].Size
Assert-VMTest (($settings.vm.DiskBytes / 1MB) - $fixedSize -ge 2048) 'At least 2 GiB must remain for recovery and alignment.'
Assert-VMTest (@($xml.SelectNodes('//u:component[@processorArchitecture!="amd64"]', $ns)).Count -eq 0) 'Every component must target x64.'
Assert-VMTest (@($xml.SelectNodes('//u:RunSynchronous | //u:FirstLogonCommands | //u:Packages', $ns)).Count -eq 0) 'The baseline must not run component changes or install additional software.'
$settings.windows.Localization.InputLocales = @('en-US', 'ru-RU')
$localized = [xml](Get-TestVMAnswer -Settings $settings -Credential $credential)
$localizedNs = [Xml.XmlNamespaceManager]::new($localized.NameTable)
$localizedNs.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
Assert-VMTest (@($localized.SelectNodes('//u:InputLocale', $localizedNs) | Where-Object { $_.InnerText -ne 'en-US;ru-RU' }).Count -eq 0) 'Additional input locales must reach both installation passes.'
Assert-VMTest (@($localized.SelectNodes('//u:UILanguage', $localizedNs) | Where-Object { $_.InnerText -ne 'en-US' }).Count -eq 0) 'Adding a keyboard must leave the display language English.'

# Test ACL behavior only on newly created ignored fixtures, never an existing VM.
$fixture = Join-Path $repository ('.local\vm-tests\' + [Guid]::NewGuid().ToString('N'))
Set-TestVMPrivateDirectory -Path $fixture
$credentialPath = Join-Path $fixture 'credential.clixml'
$credential | Export-Clixml -LiteralPath $credentialPath
$reloaded = Import-Clixml -LiteralPath $credentialPath
Assert-VMTest ($reloaded.GetNetworkCredential().Password -ceq $credential.GetNetworkCredential().Password) 'Local DPAPI credential export must round-trip.'
$acl = Get-Acl -LiteralPath $fixture
Assert-VMTest $acl.AreAccessRulesProtected 'Secret directory permissions must not inherit broad access.'
$allowedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
$unexpected = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -notin $allowedSids })
Assert-VMTest ($unexpected.Count -eq 0) 'Only the owner, SYSTEM, and Administrators may access local credentials.'
& git --no-optional-locks -C $repository check-ignore --quiet -- $credentialPath
Assert-VMTest ($LASTEXITCODE -eq 0) 'Local credentials must be ignored by Git.'
Write-Output ("Passed $checks VM preparation checks without creating or starting a VM.")
