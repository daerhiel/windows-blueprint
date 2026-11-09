#Requires -Version 5.1
<#
.SYNOPSIS
Calculates an unattended disk layout in WinPE and starts Windows Setup.
.DESCRIPTION
Uses the only target disk, or unpartitioned disk 0 when multiple targets exist.
Otherwise leaves selection and partitioning to the standard Windows Setup UI.
Creates no accounts and never prompts for credentials or disk selection.
#>
[CmdletBinding()]
param([string] $MediaRoot = (Split-Path $PSScriptRoot -Parent))

function Get-DeploymentDisk {
    param([object[]] $Disks)
    if ($Disks.Count -eq 0) { throw 'No target disks were found.' }
    $selected = $null
    if ($Disks.Count -eq 1) { $selected = $Disks[0] }
    else {
        $first = @($Disks | Where-Object { $_.Number -eq 0 })
        if ($first.Count -eq 1) {
            if ($null -eq $first[0].NumberOfPartitions) { throw 'Cannot determine whether disk 0 is unpartitioned.' }
            if ($first[0].NumberOfPartitions -eq 0) { $selected = $first[0] }
        }
    }
    if ($null -ne $selected -and ($selected.IsOffline -or $selected.IsReadOnly)) { throw 'The automatically selected disk is offline or read-only.' }
    $selected
}

function Get-DeploymentLayout {
    param([long] $DiskBytes, [hashtable] $Configuration)
    $policy = $Configuration.Deployment.Disk
    $target = $DiskBytes * $policy.WindowsFraction
    $sizes = @($policy.WindowsSizesGiB | Sort-Object)
    $size = $sizes[0]
    foreach ($candidate in $sizes) {
        if ([math]::Abs($candidate * 1GB - $target) -le [math]::Abs($size * 1GB - $target)) { $size = $candidate }
    }
    $windowsMiB = [long]$size * 1024
    # Reserve GPT metadata and alignment space at both ends of the disk.
    $availableMiB = [long][math]::Floor($DiskBytes / 1MB) - $policy.EfiMiB - $policy.MsrMiB - $policy.RecoveryMiB - 4
    if ($availableMiB -lt $windowsMiB) { throw 'The disk cannot fit the minimum Windows partition and service partitions.' }
    $dataMiB = 0L
    if ($availableMiB - $windowsMiB -ge $windowsMiB) { $dataMiB = $windowsMiB }
    [PSCustomObject]@{ WindowsMiB = $windowsMiB; DataMiB = $dataMiB; UnallocatedMiB = $availableMiB - $windowsMiB - $dataMiB }
}

function New-DeploymentAnswer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory XML document only.')]
    param([xml] $Template, [hashtable] $Configuration, [Nullable[int]] $DiskNumber, $Layout, [string] $MachineName)
    $answer = [xml]$Template.OuterXml
    $ns = [Xml.XmlNamespaceManager]::new($answer.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $namespace = $ns.LookupNamespace('u')
    function Add-AnswerElement {
        param([Xml.XmlNode] $Parent, [string] $Name, [string] $Value)
        $element = $answer.CreateElement($Name, $namespace)
        if ($PSBoundParameters.ContainsKey('Value')) { $element.InnerText = $Value }
        $Parent.AppendChild($element)
    }
    foreach ($node in $answer.SelectNodes('//u:InputLocale', $ns)) { $node.InnerText = @($Configuration.Localization.InputLocales) -join ';' }
    $shell = $answer.SelectSingleNode("//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Shell-Setup']", $ns)
    Add-AnswerElement $shell 'ComputerName' $MachineName | Out-Null
    $setup = $answer.SelectSingleNode("//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']", $ns)
    $diskConfiguration = Add-AnswerElement $setup 'DiskConfiguration'
    $image = $setup.SelectSingleNode('u:ImageInstall/u:OSImage', $ns)
    if ($null -eq $DiskNumber) {
        Add-AnswerElement $diskConfiguration 'WillShowUI' 'Always' | Out-Null
        Add-AnswerElement $image 'WillShowUI' 'Always' | Out-Null
        return ,$answer
    }
    $disk = Add-AnswerElement $diskConfiguration 'Disk'
    $disk.SetAttribute('action', 'http://schemas.microsoft.com/WMIConfig/2002/State', 'add') | Out-Null
    Add-AnswerElement $disk 'DiskID' ([string]$DiskNumber) | Out-Null
    Add-AnswerElement $disk 'WillWipeDisk' 'true' | Out-Null
    $create = Add-AnswerElement $disk 'CreatePartitions'
    $modify = Add-AnswerElement $disk 'ModifyPartitions'
    $policy = $Configuration.Deployment.Disk
    $partitions = @(
        @{ Type = 'EFI'; Size = $policy.EfiMiB; Format = 'FAT32'; Label = 'System' }
        @{ Type = 'MSR'; Size = $policy.MsrMiB }
        @{ Type = 'Primary'; Size = $Layout.WindowsMiB; Format = 'NTFS'; Label = 'Windows'; Letter = 'C' }
        @{ Type = 'Primary'; Size = $policy.RecoveryMiB; Format = 'NTFS'; Label = 'Recovery'; TypeID = 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC' }
    )
    if ($Layout.DataMiB -gt 0) { $partitions += @{ Type = 'Primary'; Size = $Layout.DataMiB; Format = 'NTFS'; Label = 'Data'; Letter = 'D' } }
    $modificationOrder = 0
    for ($index = 0; $index -lt $partitions.Count; $index++) {
        $definition = $partitions[$index]
        $partition = Add-AnswerElement $create 'CreatePartition'
        $partition.SetAttribute('action', 'http://schemas.microsoft.com/WMIConfig/2002/State', 'add') | Out-Null
        Add-AnswerElement $partition 'Order' ([string]($index + 1)) | Out-Null
        Add-AnswerElement $partition 'Type' $definition.Type | Out-Null
        Add-AnswerElement $partition 'Size' ([string]$definition.Size) | Out-Null
        if ($definition.Type -eq 'MSR') { continue }
        $modificationOrder++
        $partition = Add-AnswerElement $modify 'ModifyPartition'
        $partition.SetAttribute('action', 'http://schemas.microsoft.com/WMIConfig/2002/State', 'add') | Out-Null
        Add-AnswerElement $partition 'Order' ([string]$modificationOrder) | Out-Null
        Add-AnswerElement $partition 'PartitionID' ([string]($index + 1)) | Out-Null
        foreach ($field in @('Format', 'Label', 'Letter', 'TypeID')) {
            if ($definition.ContainsKey($field)) { Add-AnswerElement $partition $field $definition[$field] | Out-Null }
        }
    }
    Add-AnswerElement $diskConfiguration 'WillShowUI' 'OnError' | Out-Null
    $installTo = Add-AnswerElement $image 'InstallTo'
    Add-AnswerElement $installTo 'DiskID' ([string]$DiskNumber) | Out-Null
    Add-AnswerElement $installTo 'PartitionID' '3' | Out-Null
    return ,$answer
}

if ($MyInvocation.InvocationName -eq '.') { return }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')) { throw 'This installer must run in Windows PE.' }
& wpeutil.exe UpdateBootInfo
if ($LASTEXITCODE -ne 0 -or (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control').PEFirmwareType -ne 2) { throw 'UEFI boot is required.' }
$configuration = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'windows.psd1')
$template = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'autounattend.xml') -Raw)
$mediaDisk = @(Get-Partition -DriveLetter $MediaRoot.Substring(0, 1) -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DiskNumber)
$disks = @(Get-Disk -ErrorAction Stop | Where-Object { $_.Number -notin $mediaDisk })
$selected = Get-DeploymentDisk -Disks $disks
$diskNumber = $null
$layout = $null
if ($null -ne $selected) {
    $diskNumber = [int]$selected.Number
    $layout = Get-DeploymentLayout -DiskBytes $selected.Size -Configuration $configuration
    $current = Get-Disk -Number $diskNumber -ErrorAction Stop
    if ($current.UniqueId -cne $selected.UniqueId -or $current.Size -ne $selected.Size -or $current.NumberOfPartitions -ne $selected.NumberOfPartitions) { throw 'The target disk changed during preparation.' }
}
$machineName = $configuration.Deployment.ComputerNamePrefix + ([IO.Path]::GetRandomFileName().Replace('.', '').Substring(0, 7).ToUpperInvariant())
$answer = New-DeploymentAnswer -Template $template -Configuration $configuration -DiskNumber $diskNumber -Layout $layout -MachineName $machineName
$answerPath = Join-Path $env:SystemDrive 'deployment-unattend.xml'
$answer.Save($answerPath)
$process = Start-Process -FilePath (Join-Path $MediaRoot 'setup.exe') -ArgumentList ('/unattend:"' + $answerPath + '"') -Wait -PassThru
if ($process.ExitCode -ne 0) { throw ('Windows Setup failed: ' + $process.ExitCode) }
