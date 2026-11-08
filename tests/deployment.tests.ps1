#Requires -Version 5.1
<#
.SYNOPSIS
Tests destructive disk-selection boundaries and generated Setup XML without disk access.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'setup\deployment\install.ps1')
$configuration = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config\windows.psd1')
$template = [xml](Get-Content -LiteralPath (Join-Path $root 'setup\deployment\autounattend.xml') -Raw)
$checks = 0
function Assert-Deployment {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:checks++
}
function New-FixtureDisk {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory synthetic object without disk access.')]
    param([int] $Number, $Partitions = 0, [bool] $ReadOnly = $false, [bool] $Offline = $false)
    [pscustomobject]@{ Number = $Number; NumberOfPartitions = $Partitions; IsReadOnly = $ReadOnly; IsOffline = $Offline }
}
$only = New-FixtureDisk 3 4
Assert-Deployment ((Get-DeploymentDisk @($only)).Number -eq 3) 'Use the actual number of the sole disk, including a previously partitioned disk.'
Assert-Deployment ((Get-DeploymentDisk @((New-FixtureDisk 1 3), (New-FixtureDisk 0 0))).Number -eq 0) 'Multiple disks permit only unpartitioned disk 0.'
Assert-Deployment ($null -eq (Get-DeploymentDisk @((New-FixtureDisk 0 1), (New-FixtureDisk 1 0)))) 'Never choose another empty disk when disk 0 has partitions.'
Assert-Deployment ($null -eq (Get-DeploymentDisk @((New-FixtureDisk 2 0), (New-FixtureDisk 4 0)))) 'Missing disk 0 must fall back to Windows Setup.'
foreach ($disks in @(
    @{ Items = @() },
    @{ Items = @((New-FixtureDisk 0 0 $true)) },
    @{ Items = @((New-FixtureDisk 0 0 $false $true)) },
    @{ Items = @((New-FixtureDisk 0 $null), (New-FixtureDisk 1 0)) }
)) {
    $caught = $false
    try { Get-DeploymentDisk $disks.Items | Out-Null } catch { $caught = $true }
    Assert-Deployment $caught 'Missing disks, inaccessible disks, and unknown partition counts must not authorize wiping.'
}
foreach ($case in @(
    @(200GB, 128, 0), @(1TB, 128, 128), @(2TB, 256, 256), @((3TB - 8), 256, 256),
    @(3TB, 512, 512), @(4TB, 512, 512), @(6TB, 1024, 1024), @(8TB, 1024, 1024), @(16TB, 1024, 1024)
)) {
    $layout = Get-DeploymentLayout -DiskBytes $case[0] -Configuration $configuration
    Assert-Deployment ($layout.WindowsMiB -eq $case[1] * 1024 -and $layout.DataMiB -eq $case[2] * 1024) ('Capacity boundary ' + $case[0])
    Assert-Deployment ($layout.UnallocatedMiB -ge 0) 'Never overcommit disk capacity.'
}
$caught = $false
try { Get-DeploymentLayout -DiskBytes 80GB -Configuration $configuration | Out-Null } catch { $caught = $true }
Assert-Deployment $caught 'An undersized disk must fail before Setup can wipe it.'
$serviceMiB = 512 + 16 + 2048 + 4
foreach ($delta in @(-1, 0)) {
    $layout = Get-DeploymentLayout -DiskBytes ((2 * 128 * 1024 + $serviceMiB + $delta) * 1MB) -Configuration $configuration
    Assert-Deployment (($layout.DataMiB -gt 0) -eq ($delta -eq 0)) 'D is present exactly when an equal-sized partition fits.'
}
foreach ($capacity in @(200GB, 2TB)) {
    $layout = Get-DeploymentLayout -DiskBytes $capacity -Configuration $configuration
    $answer = New-DeploymentAnswer -Template $template -Configuration $configuration -DiskNumber 3 -Layout $layout -MachineName 'DT-TEST123'
    $ns = [Xml.XmlNamespaceManager]::new($answer.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    Assert-Deployment ($answer.SelectSingleNode('//u:Disk/u:DiskID', $ns).InnerText -ceq '3') 'Render the selected disk number.'
    Assert-Deployment ($answer.SelectSingleNode('//u:WillWipeDisk', $ns).InnerText -ceq 'true') 'The selected automatic target is fully wiped.'
    Assert-Deployment ($answer.SelectSingleNode('//u:InstallTo/u:PartitionID', $ns).InnerText -ceq '3') 'Install Windows into the C partition.'
    Assert-Deployment (@($answer.SelectNodes('//u:CreatePartition', $ns)).Count -eq $(if ($capacity -eq 200GB) { 4 } else { 5 })) 'Create D only when it fits.'
    $modifications = @($answer.SelectNodes('//u:ModifyPartition', $ns))
    Assert-Deployment ((@($modifications | ForEach-Object { [int]$_.Order }) -join ',') -ceq ((1..$modifications.Count) -join ',')) 'Modification order must remain consecutive when the MSR partition is skipped.'
    Assert-Deployment (@($answer.SelectNodes('//u:Extend | //u:UserAccounts | //u:Password | //u:AutoLogon | //u:FirstLogonCommands | //u:SkipMachineOOBE', $ns)).Count -eq 0) 'Keep fixed sizes, native account creation, and no credentials or custom sign-in.'
    Assert-Deployment ($answer.SelectSingleNode('//u:HideWirelessSetupInOOBE', $ns).InnerText -ceq 'true') 'Skip network setup during OOBE so account creation can proceed offline.'
}
$fallback = New-DeploymentAnswer -Template $template -Configuration $configuration -DiskNumber $null -MachineName 'DT-TEST123'
Assert-Deployment ($fallback.OuterXml -notmatch 'WillWipeDisk|InstallTo|CreatePartition') 'Manual fallback must contain no disk-changing or automatic target settings.'
Assert-Deployment ($fallback.OuterXml -match '<WillShowUI>Always</WillShowUI>') 'Manual fallback uses the standard Setup UI.'
Assert-Deployment ($template.OuterXml -notmatch 'WillWipeDisk|UserAccounts|Password|AutoLogon|ComputerName') 'The embedded template has no destructive target or credentials.'
$configuration.Localization.InputLocales = @('en-US', 'ru-RU')
$localized = New-DeploymentAnswer -Template $template -Configuration $configuration -DiskNumber $null -MachineName 'DT-TEST123'
Assert-Deployment ($localized.OuterXml -match 'en-US;ru-RU' -and $localized.OuterXml -notmatch '<UILanguage>ru-RU') 'Keyboard additions preserve the English system language.'
Write-Output ("Passed $checks deployment checks without accessing disks.")
