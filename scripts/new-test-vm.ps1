#Requires -Version 5.1

<#
.SYNOPSIS
Creates an isolated Hyper-V test VM; only the baseline needs answer media.

.DESCRIPTION
Run from an elevated 64-bit PowerShell terminal on Windows.
CheckOnly performs preflight without creating a VM.
The installation ISO is hash-checked and remains unchanged. Only a newly created
VHDX is attached as a hard disk. Existing VMs and working directories are refused.
Secrets remain in an ACL-restricted local directory, never in Git or parameters.

.PARAMETER IsoPath
Installation ISO to attach; the selected profile determines the required source or configured media.

.PARAMETER VMProfile
Selects the baseline or configured VM settings and their separate owned resources.

.PARAMETER CheckOnly
Returns preflight evidence without creating the VM, disk, or installation files.

.OUTPUTS
System.Collections.Specialized.OrderedDictionary for CheckOnly; otherwise a completion message and vm.json metadata.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [string] $IsoPath,
    [ValidateSet('Baseline', 'Configured')] [string] $VMProfile = 'Baseline',
    [switch] $CheckOnly
)

function Get-TestVMConfiguration {
    <#
    .SYNOPSIS
    Resolves the selected VM profile and its owned paths.

    .DESCRIPTION
    Combines the VM and Windows configuration with source identity. Baseline and configured profiles receive separate names, disks, outputs, and installation media settings.

    .PARAMETER VMProfile
    Selects the baseline or configured VM settings and their separate owned resources.

    .OUTPUTS
    System.Collections.Hashtable. Resolved VM settings.
    #>

    param(
        [ValidateSet('Baseline', 'Configured')] [string] $VMProfile = 'Baseline'
    )

    $root = Split-Path $PSScriptRoot -Parent
    $vm = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config\test-vm.psd1')
    $windows = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config\windows.psd1')
    $source = Get-Content -LiteralPath (Join-Path $root 'config\source-image.lock.json') -Raw | ConvertFrom-Json

    if ($windows.Edition -cne 'Pro' -or $windows.Architecture -cne 'x64' -or $windows.Localization.UiLanguage -cne 'en-US' -or $source.selectedImage.editionId -cne 'Professional' -or $source.selectedImage.architecture -cne 'x64' -or $source.selectedImage.defaultLanguage -cne 'en-US') {
        throw 'The test installer requires the pinned Pro/x64/en-US profile.'
    }
    if ($vm.Name -notmatch '^[A-Za-z0-9-]{1,40}$' -or $vm.ComputerName -notmatch '^[A-Za-z][A-Za-z0-9-]{0,14}$' -or $vm.AccountName -notmatch '^[A-Za-z][A-Za-z0-9-]{0,19}$') {
        throw 'Invalid VM, computer, or account name.'
    }
    if ($vm.ProcessorCount -lt 2 -or $vm.MemoryBytes -lt 4GB -or $vm.DiskBytes -lt 64GB -or $vm.DiskBytes % 1MB -ne 0) {
        throw 'The VM requires at least 2 processors, 4 GiB RAM, and a whole-MiB disk of at least 64 GiB.'
    }

    $directory = Join-Path $root '.local\vm\windows11-pro'
    $imageIndex = $source.selectedImage.index

    if ($VMProfile -eq 'Configured') {
        $vm.Name += '-Configured'
        $vm.DiskBytes = $vm.ConfiguredDiskBytes
        $vm.Remove('ComputerName')
        $vm.Remove('TimeZone')
        $vm.Remove('AccountName')
        $directory += '-configured'
        $imageIndex = 1
    }

    $vm.Remove('ConfiguredDiskBytes')
    @{
        root       = $root
        vm         = $vm
        windows    = $windows
        source     = $source
        directory  = $directory
        profile    = $VMProfile
        imageIndex = $imageIndex
    }
}

function Get-TestVMAnswer {
    <#
    .SYNOPSIS
    Renders the baseline unattended installation answer file.

    .DESCRIPTION
    Uses the baseline template and explicit guest credential. Rejects the configured profile, which uses the native Setup and OOBE handoff.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Credential
    Explicit local guest administrator credential used for PowerShell Direct access.

    .OUTPUTS
    System.String. Rendered unattended answer XML containing credential material.
    #>

    [OutputType([string])]
    param(
        $Settings,
        [pscredential] $Credential
    )

    if ($Settings.profile -eq 'Configured') {
        throw 'Configured installation uses the deployment answer embedded in its ISO and creates its user in OOBE.'
    }

    $xml = [xml](Get-Content -LiteralPath (Join-Path $Settings.root 'setup\vm\autounattend.xml') -Raw)
    $values = @{
        '__INPUT_LOCALES__'   = (@($Settings.windows.Localization.InputLocales) -join ';')
        '__WINDOWS_SIZE_MB__' = [string]([long]($Settings.vm.DiskBytes / 1MB) - 260 - 16 - 2048 - 4)
        '__IMAGE_INDEX__'     = [string]$Settings.imageIndex
        '__COMPUTER_NAME__'   = $Settings.vm.ComputerName
        '__TIME_ZONE__'       = $Settings.vm.TimeZone
        '__ACCOUNT_NAME__'    = $Settings.vm.AccountName
        # Setup requires the actual password; this XML is written only to private media.
        '__PASSWORD__'        = $Credential.GetNetworkCredential().Password
    }

    foreach ($node in @($xml.SelectNodes('//*[not(*)]'))) {
        if ($values.ContainsKey($node.InnerText)) {
            $node.InnerText = $values[$node.InnerText]
        }
    }

    if ($xml.OuterXml -match '__[A-Z_]+__') {
        throw 'Unresolved answer-file placeholder.'
    }

    $xml.OuterXml
}

function Set-TestVMPrivateDirectory {
    <#
    .SYNOPSIS
    Creates a private directory for VM installation secrets.

    .DESCRIPTION
    Restricts the directory ACL to the current owner, SYSTEM, and administrators before sensitive baseline files are written.

    .PARAMETER Path
    New owned directory in which private VM files will be stored.

    .OUTPUTS
    None. Creates the directory and sets its access rules.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Protects the newly created local secret directory before any secret is written; the caller confirms the complete creation operation.')]
    param(
        [string] $Path
    )

    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    try {
        $owner = $identity.User
    }
    finally {
        $identity.Dispose()
    }

    $acl.SetOwner($owner)

    foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-TestVMPreflight {
    <#
    .SYNOPSIS
    Checks host resources, tools, and installation evidence for a VM.

    .DESCRIPTION
    Verifies Hyper-V prerequisites, selected media, pinned tools, and configured build evidence before VM creation or reinstallation.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER IsoPath
    Path to the source or installation ISO required by the selected operation.

    .PARAMETER ForReinstall
    Allows the existing owned VM while checking inputs for system-disk replacement.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. Preflight evidence.
    #>

    param(
        $Settings,
        [string] $IsoPath,
        [switch] $ForReinstall
    )

    Import-Module Hyper-V -ErrorAction Stop
    Get-VMHost -ErrorAction Stop | Out-Null
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    $existing = @(Get-VM -ErrorAction Stop | Where-Object {
            $_.Name -eq $Settings.vm.Name
        })

    if (-not $ForReinstall -and ($existing.Count -gt 0 -or (Test-Path -LiteralPath $Settings.directory))) {
        throw 'The named VM or its working directory already exists; no existing installation will be replaced.'
    }

    if (-not $system.HypervisorPresent -or @($cpu | Where-Object {
                $_.Architecture -ne 9
            }).Count -gt 0) {
        throw 'An active Hyper-V hypervisor on an x64 host is required.'
    }

    if ([long]$system.TotalPhysicalMemory -lt ($Settings.vm.MemoryBytes + 4GB) -or ([long]$os.FreePhysicalMemory * 1KB) -lt ($Settings.vm.MemoryBytes + 2GB)) {
        throw 'Insufficient host memory for the configured VM and host reserve.'
    }
    if ($system.NumberOfLogicalProcessors -lt $Settings.vm.ProcessorCount) {
        throw 'Insufficient host logical processors.'
    }

    if ($Settings.vm.ExposeVirtualizationExtensions -and @($cpu | Where-Object {
                $_.Manufacturer -notin @('GenuineIntel', 'AuthenticAMD')
            }).Count -gt 0) {
        throw 'Nested virtualization requires a reviewed Intel or AMD host.'
    }

    if ($Settings.vm.ExposeVirtualizationExtensions -and @($cpu | Where-Object {
                $_.Manufacturer -eq 'AuthenticAMD'
            }).Count -gt 0 -and [int]$os.BuildNumber -lt 22000) {
        throw 'Nested virtualization on AMD requires Windows 11 or a separately reviewed server host.'
    }

    # Configured media already exists; reserve room for the fresh guest and updates.
    $requiredFreeSpace = 60GB

    if ($Settings.profile -eq 'Configured') {
        $requiredFreeSpace = 40GB
    }

    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Settings.directory))

    if ($drive.DriveFormat -notin @('NTFS', 'ReFS') -or $drive.AvailableFreeSpace -lt $requiredFreeSpace) {
        throw ('The VM volume must use NTFS/ReFS and have at least {0} GiB free.' -f ($requiredFreeSpace / 1GB))
    }

    $iso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).ProviderPath

    if ($iso.StartsWith($Settings.directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The source ISO must remain outside the VM directory.'
    }

    $expectedIsoHash = $Settings.source.iso.sha256
    $expectedIsoSize = $Settings.source.iso.sizeBytes

    if ($Settings.profile -eq 'Configured') {
        $media = Get-Content -LiteralPath (Join-Path $Settings.root '.local\media\windows11-pro\operation.json') -Raw | ConvertFrom-Json

        if (-not $media.deployment) {
            throw 'Configured VM requires the integrated deployment ISO.'
        }

        $build = Get-Content -LiteralPath (Join-Path $Settings.root '.local\build\windows11-pro\operation.json') -Raw | ConvertFrom-Json

        if ($media.status -cne 'Succeeded' -or @($media.cleanupErrors).Count -ne 0 -or $media.imageIndex -ne 1 -or $media.filesVerified -lt 1 -or $media.sourceIsoSha256 -cne $Settings.source.iso.sha256 -or $build.status -cne 'Succeeded' -or $media.outputWimSha256 -cne $build.outputWimSha256 -or (Get-FileHash -LiteralPath (Join-Path $Settings.root 'config\windows.psd1') -Algorithm SHA256).Hash -cne $media.configurationSha256) {
            throw 'Configured media is unverified or stale; rebuild it before VM creation.'
        }

        $expectedIsoHash = $media.isoSha256
        $expectedIsoSize = $media.isoSizeBytes
    }

    if ((Get-Item -LiteralPath $iso).Length -ne $expectedIsoSize -or (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash -cne $expectedIsoHash) {
        throw 'Installation ISO does not match the selected profile evidence.'
    }

    $toolchain = Get-Content -LiteralPath (Join-Path $Settings.root 'config\toolchain.lock.json') -Raw | ConvertFrom-Json
    $oscdimg = $toolchain.adk.oscdimg

    if ((Get-FileHash -LiteralPath $oscdimg.path -Algorithm SHA256).Hash -cne $oscdimg.sha256) {
        throw 'Oscdimg does not match its lock file.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $oscdimg.path

    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'Oscdimg must have a valid Microsoft signature.'
    }

    [ordered]@{
        name                   = $Settings.vm.Name
        generation             = 2
        processors             = $Settings.vm.ProcessorCount
        memoryGiB              = $Settings.vm.MemoryBytes / 1GB
        diskGiB                = $Settings.vm.DiskBytes / 1GB
        hostMemoryGiB          = [math]::Round($system.TotalPhysicalMemory / 1GB, 1)
        hostAvailableMemoryGiB = [math]::Round(([long]$os.FreePhysicalMemory * 1KB) / 1GB, 1)
        hostLogicalProcessors  = $system.NumberOfLogicalProcessors
        hostFreeDiskGiB        = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        isoPath                = $iso
        isoSha256              = $expectedIsoHash
        oscdimgPath            = $oscdimg.path
        profile                = $Settings.profile
        imageIndex             = $Settings.imageIndex
        requiredFreeDiskGiB    = $requiredFreeSpace / 1GB
        nestedVirtualization   = $Settings.vm.ExposeVirtualizationExtensions
        network                = 'Disconnected'
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Test-VM creation requires Windows.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Use a 64-bit PowerShell process.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

try {
    $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
finally {
    $identity.Dispose()
}

if (-not $admin) {
    throw 'Administrator privileges are required; run from an elevated terminal.'
}

$settings = Get-TestVMConfiguration -VMProfile $VMProfile
$ancestor = $settings.directory

while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'VM paths must not contain reparse points.'
    }

    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}

$preflight = Get-TestVMPreflight -Settings $settings -IsoPath $IsoPath

if ($CheckOnly) {
    $preflight

    return
}
if (-not $PSCmdlet.ShouldProcess($settings.directory, 'Create isolated Hyper-V VM and new VHDX for the selected installation profile')) {
    return
}

$parent = Split-Path $settings.directory -Parent
[IO.Directory]::CreateDirectory($parent) | Out-Null
$lockPath = $settings.directory + '.lock'

if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'VM lock must not be a reparse point.'
}

$lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
$record = $null

try {
    if (Test-Path -LiteralPath $settings.directory) {
        throw 'The VM directory was created concurrently; refusing to reuse it.'
    }

    Set-TestVMPrivateDirectory -Path $settings.directory
    $vhdPath = Join-Path $settings.directory 'system.vhdx'
    $metadataPath = Join-Path $settings.directory 'vm.json'
    $record = [ordered]@{
        schemaVersion = 1
        status        = 'Preparing'
        vmId          = $null
        name          = $settings.vm.Name
        state         = 'Off'
        directory     = $settings.directory
        vhdPath       = $vhdPath
        seedIsoPath   = $null
        isoPath       = $preflight.isoPath
        isoSha256     = $preflight.isoSha256
        seedIsoSha256 = $null
        settings      = $settings.vm
        createdAtUtc  = [DateTime]::UtcNow.ToString('o')
        profile       = $settings.profile
        imageIndex    = $settings.imageIndex
        error         = $null
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    $seedIso = $null
    $seedHash = $null

    if ($VMProfile -eq 'Baseline') {
        $secretDirectory = Join-Path $settings.directory 'secrets'
        Set-TestVMPrivateDirectory -Path $secretDirectory
        $mediaDirectory = Join-Path $settings.directory 'media'
        [IO.Directory]::CreateDirectory($mediaDirectory) | Out-Null
        $bytes = [byte[]]::new(24)
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()

        try {
            $rng.GetBytes($bytes)
        }
        finally {
            $rng.Dispose()
        }

        $securePassword = [Security.SecureString]::new()

        foreach ($character in ('Vm!9' + [Convert]::ToBase64String($bytes)).ToCharArray()) {
            $securePassword.AppendChar($character)
        }

        $securePassword.MakeReadOnly()
        $credential = [pscredential]::new($settings.vm.AccountName, $securePassword)
        $credential | Export-Clixml -LiteralPath (Join-Path $secretDirectory 'credential.clixml')
        $answer = Get-TestVMAnswer -Settings $settings -Credential $credential
        [IO.File]::WriteAllText((Join-Path $mediaDirectory 'autounattend.xml'), $answer, [Text.UTF8Encoding]::new($false))
        $answer = $null
        $seedIso = Join-Path $settings.directory 'answer.iso'
        & $preflight.oscdimgPath -u2 -udfver102 -lWIN11ANSWER $mediaDirectory $seedIso | Out-Null

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $seedIso)) {
            throw 'Answer-file ISO creation failed.'
        }

        $seedHash = (Get-FileHash -LiteralPath $seedIso -Algorithm SHA256).Hash
    }

    $vm = New-VM -Name $settings.vm.Name -Generation 2 -MemoryStartupBytes $settings.vm.MemoryBytes -NewVHDPath $vhdPath -NewVHDSizeBytes $settings.vm.DiskBytes -Path $settings.directory
    # Persist ownership before later Hyper-V configuration can fail.
    $record.vmId = [string]$vm.Id
    $record.seedIsoPath = $seedIso
    $record.seedIsoSha256 = $seedHash
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
    Set-VMProcessor -VM $vm -Count $settings.vm.ProcessorCount -ExposeVirtualizationExtensions $settings.vm.ExposeVirtualizationExtensions
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
    Enable-VMTPM -VM $vm
    $vmAccount = [Security.Principal.NTAccount]::new('NT VIRTUAL MACHINE', $vm.Id.ToString())
    $vmSid = $vmAccount.Translate([Security.Principal.SecurityIdentifier])
    $acl = Get-Acl -LiteralPath $settings.directory
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($vmSid, 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $settings.directory -AclObject $acl
    $installationDvd = Add-VMDvdDrive -VM $vm -Path $preflight.isoPath -Passthru

    if ($seedIso) {
        Add-VMDvdDrive -VM $vm -Path $seedIso | Out-Null
    }

    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $installationDvd

    if (@(Get-VMHardDiskDrive -VM $vm).Count -ne 1 -or (Get-VMHardDiskDrive -VM $vm).Path -ine $vhdPath -or @(Get-VMNetworkAdapter -VM $vm | Where-Object {
                $_.SwitchName
            }).Count -ne 0) {
        throw 'Unexpected disk or network attachment; do not start this VM.'
    }

    $record.status = 'Created'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $settings.directory 'vm.json') -Encoding UTF8
    Write-Output ('Created {0}, powered off, with one new VHDX and disconnected networking. Metadata: {1}' -f $vm.Name, (Join-Path $settings.directory 'vm.json'))
}
catch {
    if ($null -ne $record) {
        $record.status = 'Failed'
        $record.error = $_.Exception.Message
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    }

    throw
}
finally {
    $lock.Dispose()
}
