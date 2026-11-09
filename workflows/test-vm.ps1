#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Prepares, reinstalls, inspects, audits, or removes the owned Hyper-V test VM.

.DESCRIPTION
Run from an elevated 64-bit PowerShell terminal on Windows. Configured guest access
requires an explicit PSCredential for the local administrator created in OOBE.
No action requests elevation or controls the desktop. Prepare and Reinstall stop
at the native Setup/OOBE handoff; console opening is explicitly optional.

.PARAMETER Action
Inspects, prepares, reinstalls, starts, captures, audits, collects a limited audit, or removes the selected VM.

.PARAMETER VMProfile
Selects the baseline or configured VM settings and their separate owned resources.

.PARAMETER IsoPath
Installation ISO for Prepare or Reinstall; the selected profile determines the required media evidence.

.PARAMETER WimPath
Path to the matching source WIM used for Windows SIM answer-file validation.

.PARAMETER ReportName
Directory name for the new audit report within the selected VM report root.

.PARAMETER WaitForGuestSeconds
Maximum time to wait for authenticated guest access and installation readiness.

.PARAMETER Credential
Explicit local guest administrator credential used for PowerShell Direct access.

.PARAMETER CompareTo
Earlier saved audit report used for drift comparison during Audit.

.PARAMETER RestartBefore
Restarts the guest before Audit and verifies that a new boot is available.

.PARAMETER ArchiveReason
Explicit diagnostics archive name required when preserving existing evidence for the action.

.PARAMETER DiscardCheckpoints
Explicitly permits discarding checkpoints belonging to the owned VM.

.PARAMETER NetworkMode
Temporarily isolates audit networking or preserves the existing adapter attachments.

.PARAMETER OpenConsole
Opens VMConnect after starting the VM.

.OUTPUTS
None. Writes console diagnostics and action-specific VM workflow reports.

.EXAMPLE
.\workflows\test-vm.ps1 -Action Prepare -VMProfile Configured -OpenConsole
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Inspect', 'Prepare', 'Reinstall', 'Start', 'Capture', 'Audit', 'Limited', 'Remove')] [string] $Action,
    [ValidateSet('Baseline', 'Configured')] [string] $VMProfile = 'Baseline',
    [string] $IsoPath,
    [string] $WimPath,
    [ValidatePattern('^[a-z][a-z0-9-]{0,39}$')] [string] $ReportName,
    [ValidateRange(0, 1800)] [int] $WaitForGuestSeconds = 300,
    [pscredential] $Credential,
    [string] $CompareTo,
    [switch] $RestartBefore,
    [ValidatePattern('^[a-z][a-z0-9-]{0,39}$')] [string] $ArchiveReason,
    [switch] $DiscardCheckpoints,
    [ValidateSet('Isolated', 'Preserve')] [string] $NetworkMode = 'Isolated',
    [switch] $OpenConsole
)

. (Join-Path $PSScriptRoot '..\scripts\workflow-output.ps1')

function Assert-TestVMActionParameters {
    <#
    .SYNOPSIS
    Checks that supplied workflow options apply to the selected VM action.

    .DESCRIPTION
    Rejects unsupported option combinations before the workflow changes VM resources.

    .PARAMETER Parameters
    Bound parameters from the public test-VM workflow invocation.

    .OUTPUTS
    None. Throws when an option is invalid for the selected action.
    #>

    param(
        [Collections.IDictionary] $Parameters
    )

    $action = $Parameters['Action']
    $allowed = @{
        IsoPath             = @('Prepare', 'Reinstall')
        WimPath             = @('Prepare', 'Reinstall')
        ReportName          = @('Audit', 'Limited')
        CompareTo           = @('Audit')
        RestartBefore       = @('Audit')
        ArchiveReason       = @('Capture', 'Reinstall')
        DiscardCheckpoints  = @('Reinstall', 'Remove')
        OpenConsole         = @('Start', 'Prepare', 'Reinstall')
        NetworkMode         = @('Audit', 'Capture')
        Credential          = @('Inspect', 'Capture', 'Audit', 'Limited')
        WaitForGuestSeconds = @('Capture', 'Audit', 'Limited')
    }

    foreach ($key in $allowed.Keys) {
        if ($Parameters.Keys -contains $key -and $action -notin $allowed[$key]) {
            throw ("-$key does not apply to -Action $action.")
        }
    }

    if ($action -eq 'Reinstall' -and $Parameters['VMProfile'] -ne 'Configured') {
        throw 'Reinstall supports only the Configured profile; preserve the clean baseline.'
    }
    if ($action -eq 'Remove' -and $Parameters.Keys -notcontains 'VMProfile') {
        throw 'Remove requires an explicit -VMProfile.'
    }
    if ($Parameters.Keys -contains 'NetworkMode' -and $Parameters['VMProfile'] -ne 'Configured' -and $Parameters['NetworkMode'] -ne 'Isolated') {
        throw 'The clean baseline must remain isolated.'
    }
}

function Assert-TestVMPath {
    <#
    .SYNOPSIS
    Checks that a VM resource path stays inside its owned root.

    .DESCRIPTION
    Rejects escaping paths and reparse points in existing ancestors, with an optional descendant check.

    .PARAMETER Path
    Owned VM resource path to check.

    .PARAMETER Root
    Root under which the resource must remain.

    .PARAMETER CheckContents
    Also checks existing descendants for reparse points.

    .OUTPUTS
    System.String. The checked absolute resource path.
    #>

    param(
        [string] $Path,
        [string] $Root,
        [switch] $CheckContents
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [IO.Path]::GetFullPath($Root).TrimEnd('\')

    if ($full -ine $parent -and -not $full.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Path escapes its owned directory: ' + $full)
    }

    $ancestor = $full

    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw ('Reparse point in operation path: ' + $ancestor)
        }

        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }

    if ($CheckContents -and (Test-Path -LiteralPath $full)) {
        if (@(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object {
                    $_.Attributes -band [IO.FileAttributes]::ReparsePoint
                }).Count) {
            throw ('Reparse point in operation contents: ' + $full)
        }
    }

    $full
}

function Get-TestVMDiskChain {
    <#
    .SYNOPSIS
    Validates the owned VM system disk and differencing-disk chain.

    .DESCRIPTION
    Follows VHDX and AVHDX parents, rejecting foreign paths and cycles. Missing owned disks are allowed only when explicitly requested for a disposable reset.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .PARAMETER Path
    Attached system disk or differencing disk from which to follow the chain.

    .PARAMETER AllowMissingDisks
    Allows missing owned disks when checking resources for a disposable system-disk reset.

    .OUTPUTS
    System.String. Validated disk-chain paths.
    #>

    param(
        $Settings,
        $Metadata,
        [string] $Path,
        [switch] $AllowMissingDisks
    )

    $base = Assert-TestVMPath -Path $Metadata.vhdPath -Root $Settings.directory

    if ($base -ine (Join-Path $Settings.directory 'system.vhdx')) {
        throw 'The recorded base disk is not the owned system.vhdx.'
    }

    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $chain = @()

    while ($true) {
        $current = Assert-TestVMPath -Path $Path -Root $Settings.directory

        if (-not $visited.Add($current)) {
            throw 'Cyclic VHD parent chain.'
        }

        $chain += $current

        if ($AllowMissingDisks -and -not (Test-Path -LiteralPath $current -PathType Leaf -ErrorAction Stop)) {
            if (Test-Path -LiteralPath $current -ErrorAction Stop) {
                throw 'A disk path exists but is not a file.'
            }
            if ($current -ieq $base) {
                break
            }
            if ([IO.Path]::GetFileName($current) -notmatch '^system_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.avhdx$') {
                throw 'A missing differencing disk is not an owned system disk path.'
            }

            # Reinstall discards this installation; a missing link cannot reveal its parent.
            # Still validate the recorded base when it remains available.
            $Path = $base
            continue
        }

        $vhd = Get-VHD -Path $current -ErrorAction Stop

        if ($current -ieq $base) {
            if ($vhd.ParentPath -or $vhd.VhdType -ne 'Dynamic' -or $vhd.Size -ne $Metadata.settings.DiskBytes) {
                throw 'The base disk differs from its recorded profile.'
            }

            break
        }

        if ($vhd.VhdType -ne 'Differencing' -or -not $vhd.ParentPath) {
            throw 'The disk does not descend from the recorded system disk.'
        }

        $Path = $vhd.ParentPath
    }

    $chain
}

function Get-TestVMValidationWim {
    <#
    .SYNOPSIS
    Resolves the source WIM used for VM answer-file validation.

    .DESCRIPTION
    Uses an explicit path or derives the prepared source catalog from the source lock and requires the WIM to exist.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Path
    Optional explicit source WIM path; omitted paths use the prepared catalog.

    .OUTPUTS
    System.String. Resolved source WIM path.
    #>

    param(
        $Settings,
        [string] $Path
    )

    if (-not $Path) {
        $version = [version]$Settings.source.selectedImage.version
        $Path = Join-Path $Settings.root ('.local\catalog\pro-' + $version.Build + '.' + $version.Revision + '\pro.wim')
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw 'The source WIM does not exist. Run workflows/prepare-source.ps1 -IsoPath <source-ISO> or supply -WimPath for a matching prepared source WIM.'
    }

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw 'WimPath must identify the exported source WIM for Windows SIM.'
    }

    $resolved
}

function Get-TestVMOwnedMachine {
    <#
    .SYNOPSIS
    Resolves the VM and verifies its recorded identity and owned disks.

    .DESCRIPTION
    Checks metadata against Hyper-V identity, generation, disk attachment, and owned paths before returning the VM object.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .PARAMETER AllowMissingDisks
    Allows missing owned disks when checking resources for a disposable system-disk reset.

    .OUTPUTS
    Microsoft.HyperV.PowerShell.VirtualMachine. The verified owned VM.
    #>

    param(
        $Settings,
        $Metadata,
        [switch] $AllowMissingDisks
    )

    if (-not $Metadata.vmId -or $Metadata.name -cne $Settings.vm.Name -or $Metadata.profile -cne $Settings.profile -or [IO.Path]::GetFullPath($Metadata.directory).TrimEnd('\') -ine $Settings.directory) {
        throw 'VM ownership metadata differs from the selected profile.'
    }

    $vm = Get-VM -Id $Metadata.vmId -ErrorAction Stop
    $drives = @(Get-VMHardDiskDrive -VM $vm)
    $missingAttachment = $AllowMissingDisks -and $Settings.profile -eq 'Configured' -and $drives.Count -eq 0

    if ($vm.Name -cne $Settings.vm.Name -or $vm.Generation -ne 2 -or (-not $missingAttachment -and ($drives.Count -ne 1 -or [string]$drives[0].ControllerType -ne 'SCSI' -or $drives[0].ControllerNumber -ne 0 -or $drives[0].ControllerLocation -ne 0))) {
        throw 'VM identity or system disk attachment differs from the owned profile.'
    }

    $path = $Metadata.vhdPath

    if ($drives.Count -eq 1) {
        $path = $drives[0].Path
    }

    Get-TestVMDiskChain -Settings $Settings -Metadata $Metadata -Path $path -AllowMissingDisks:$AllowMissingDisks | Out-Null
    $vm
}

function Remove-TestVMResources {
    <#
    .SYNOPSIS
    Checks or removes resources belonging to the recorded test VM.

    .DESCRIPTION
    Requires the VM to be powered off and validates ownership, checkpoints, disk references, and paths before removing anything. Keeps metadata until resource removal completes.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .PARAMETER DiscardCheckpoints
    Explicitly permits discarding checkpoints belonging to the owned VM.

    .PARAMETER CheckOnly
    Returns the validated operation plan without creating, replacing, or removing VM resources.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Resource removal plan or result.
    #>

    param(
        $Settings,
        $Metadata,
        [switch] $DiscardCheckpoints,
        [switch] $CheckOnly
    )

    Write-WorkflowMessage 'Checking VM ownership, disk references, and checkpoints before removal:' -Data $Settings.vm.Name
    $vmRoot = Join-Path $Settings.root '.local\vm'
    $expected = Join-Path $vmRoot 'windows11-pro'

    if ($Settings.profile -eq 'Configured') {
        $expected += '-configured'
    }

    $directory = Assert-TestVMPath -Path $Settings.directory -Root $vmRoot -CheckContents

    if ($directory -ine [IO.Path]::GetFullPath($expected)) {
        throw 'Removal directory differs from the selected VM profile.'
    }

    $machines = @(Get-VM -ErrorAction Stop)
    $named = @($machines | Where-Object {
            $_.Name -ceq $Settings.vm.Name
        })

    if (-not $Metadata) {
        if ($named.Count -or (Test-Path -LiteralPath $directory -ErrorAction Stop)) {
            throw 'Removal requires ownership metadata for existing resources.'
        }

        return [PSCustomObject]@{
            vmId          = $null
            directory     = $directory
            metadata      = $null
            checkpoints   = @()
            alreadyAbsent = $true
        }
    }

    if ($Metadata.schemaVersion -ne 1 -or $Metadata.name -cne $Settings.vm.Name -or [IO.Path]::GetFullPath($Metadata.directory).TrimEnd('\') -ine $directory -or [IO.Path]::GetFullPath($Metadata.vhdPath) -ine (Join-Path $directory 'system.vhdx')) {
        throw 'Removal ownership metadata differs from the selected profile.'
    }

    $vm = $null

    if ($Metadata.vmId) {
        $id = [guid]::Empty

        if (-not [guid]::TryParse($Metadata.vmId, [ref]$id)) {
            throw 'Invalid VM ownership ID.'
        }

        $vm = @($machines | Where-Object {
                [string]$_.Id -ieq $Metadata.vmId
            }) | Select-Object -First 1
    }
    elseif ($Metadata.status -notin @('Preparing', 'Failed')) {
        throw 'Removal requires a recorded VM ID or partial preparation record.'
    }

    if (@($named | Where-Object {
                -not $vm -or [string]$_.Id -ine [string]$vm.Id
            }).Count) {
        throw 'A VM with this name is not owned by the removal metadata.'
    }

    $snapshots = @()

    if ($vm) {
        if ($vm.Name -cne $Settings.vm.Name -or $vm.Generation -ne 2 -or $vm.State -ne 'Off') {
            throw 'Removal requires the powered-off owned test VM.'
        }

        Assert-TestVMPath -Path $vm.Path -Root $directory | Out-Null
        $snapshots = @(Get-VMSnapshot -VM $vm)

        if ($snapshots.Count -and -not $DiscardCheckpoints) {
            throw 'Removal would discard checkpoints; explicitly supply -DiscardCheckpoints.'
        }

        $attachments = , @(Get-VMHardDiskDrive -VM $vm)

        foreach ($snapshot in $snapshots) {
            $attachments += , @(Get-VMHardDiskDrive -VMSnapshot $snapshot)
        }

        foreach ($drives in $attachments) {
            if (@($drives).Count -gt 1) {
                throw 'Removal found unexpected additional disks.'
            }

            foreach ($drive in @($drives)) {
                if ([string]$drive.ControllerType -ne 'SCSI' -or $drive.ControllerNumber -ne 0 -or $drive.ControllerLocation -ne 0) {
                    throw 'Removal found an unexpected disk controller.'
                }

                Get-TestVMDiskChain -Settings $Settings -Metadata $Metadata -Path $drive.Path -AllowMissingDisks | Out-Null
            }
        }
    }

    $sourcePath = $Metadata.PSObject.Properties['isoPath']

    if ($sourcePath -and $sourcePath.Value -and [IO.Path]::GetFullPath($sourcePath.Value).StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installation source media must remain outside the removal directory.'
    }

    foreach ($other in @($machines | Where-Object {
                -not $vm -or [string]$_.Id -ine [string]$vm.Id
            })) {
        foreach ($property in @('Path', 'SnapshotFileLocation', 'SmartPagingFilePath')) {
            $location = $other.PSObject.Properties[$property]

            if ($location -and $location.Value) {
                $path = [IO.Path]::GetFullPath([string]$location.Value).TrimEnd('\')

                if ($path -ieq $directory -or $path.StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Another VM stores configuration inside the removal directory.'
                }
            }
        }

        $references = @(Get-VMHardDiskDrive -VM $other)
        $media = @(Get-VMDvdDrive -VM $other)

        foreach ($snapshot in @(Get-VMSnapshot -VM $other)) {
            $references += @(Get-VMHardDiskDrive -VMSnapshot $snapshot)
            $media += @(Get-VMDvdDrive -VMSnapshot $snapshot)
        }

        foreach ($dvd in $media) {
            if ($dvd.Path -and [IO.Path]::GetFullPath($dvd.Path).StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Another VM references media in the removal directory.'
            }
        }

        foreach ($reference in $references) {
            $path = [IO.Path]::GetFullPath($reference.Path)
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

            while ($path) {
                if ($path.StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Another VM references a disk in the removal directory.'
                }
                if (-not $seen.Add($path)) {
                    throw 'Cannot verify a cyclic foreign disk chain.'
                }
                if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
                    break
                }

                $path = (Get-VHD -Path $path -ErrorAction Stop).ParentPath
            }
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force -ErrorAction Stop | Where-Object Extension -in @('.vhd', '.vhdx', '.avhd', '.avhdx'))) {
        if ((Get-VHD -Path $file.FullName -ErrorAction Stop).Attached) {
            throw 'Removal found a mounted virtual disk; leave it intact.'
        }
    }

    $plan = [PSCustomObject]@{
        vmId          = $Metadata.vmId
        directory     = $directory
        metadata      = $Metadata
        checkpoints   = @($snapshots | Select-Object Name, Id)
        alreadyAbsent = $false
    }

    if ($CheckOnly) {
        return $plan
    }
    if ($vm) {
        Write-WorkflowMessage 'Unregistering the owned VM and its selected checkpoints:' -Data $Settings.vm.Name -Level Warning
        Remove-VM -VM $vm -Force -Confirm:$false -ErrorAction Stop
    }

    if (@(Get-VM -ErrorAction Stop | Where-Object {
                [string]$_.Id -ieq $Metadata.vmId -or $_.Name -ceq $Settings.vm.Name
            }).Count) {
        throw 'The VM is still registered; directory cleanup is refused.'
    }

    Assert-TestVMPath -Path $directory -Root $vmRoot -CheckContents | Out-Null
    Write-WorkflowMessage 'Deleting the owned VM working directory and disks:' -Data $directory -Level Warning

    # Keep ownership metadata until all other files have been removed, allowing cleanup retry.
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Where-Object Name -ine 'vm.json')) {
        $path = Assert-TestVMPath -Path $item.FullName -Root $directory -CheckContents

        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
    }

    if (@(Get-ChildItem -LiteralPath $directory -Force | Where-Object Name -ine 'vm.json').Count) {
        throw 'The removal directory changed during cleanup; ownership metadata was retained.'
    }

    Remove-Item -LiteralPath (Join-Path $directory 'vm.json') -Force -ErrorAction Stop
    [IO.Directory]::Delete($directory, $false)
    $plan
}

function Get-TestVMHostInspection {
    <#
    .SYNOPSIS
    Collects host-side state and ownership issues for the recorded VM.

    .DESCRIPTION
    Reads current hardware, disk, network, security, and checkpoint state without changing the VM.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Host inspection observations and issues.
    #>

    param(
        $Settings,
        $Metadata
    )

    Write-WorkflowMessage 'Inspecting VM identity, disks, media, networking, security, and checkpoints:' -Data $Settings.vm.Name
    $vm = $null
    $issues = @()

    if ($Metadata -and $Metadata.vmId) {
        $vm = Get-VM -Id $Metadata.vmId -ErrorAction SilentlyContinue
    }

    $named = @(Get-VM | Where-Object {
            $_.Name -ceq $Settings.vm.Name
        })

    if (-not $vm) {
        $issues += 'The recorded VM is absent or preparation has not recorded its ID.'
    }

    if ($named.Count -and (-not $vm -or @($named | Where-Object {
                    [string]$_.Id -cne [string]$vm.Id
                }).Count)) {
        $issues += 'A VM with the configured name is not owned by this metadata.'
    }

    $actual = $null

    if ($vm) {
        try {
            Get-TestVMOwnedMachine -Settings $Settings -Metadata $Metadata | Out-Null
        }
        catch {
            $issues += $_.Exception.Message
        }

        $actual = [ordered]@{
            id          = [string]$vm.Id
            name        = $vm.Name
            state       = [string]$vm.State
            disks       = @(Get-VMHardDiskDrive -VM $vm | Select-Object Path, ControllerType, ControllerNumber, ControllerLocation)
            media       = @(Get-VMDvdDrive -VM $vm | Select-Object Path, ControllerNumber, ControllerLocation)
            network     = @(Get-VMNetworkAdapter -VM $vm | Select-Object Id, Name, SwitchId, SwitchName)
            checkpoints = @(Get-VMSnapshot -VM $vm | Select-Object Name, Id)
            tpmEnabled  = (Get-VMSecurity -VM $vm).TpmEnabled
            firmware    = Get-VMFirmware -VM $vm | Select-Object SecureBoot, SecureBootTemplate
            processor   = Get-VMProcessor -VM $vm | Select-Object Count, ExposeVirtualizationExtensions
            memory      = Get-VMMemory -VM $vm | Select-Object Startup, DynamicMemoryEnabled
        }
    }

    [PSCustomObject]@{
        metadata      = $Metadata
        actual        = $actual
        namedMachines = @($named | Select-Object Name, Id, State)
        issues        = $issues
        guest         = $null
        guestAccess   = 'NotRequested'
        freeDiskBytes = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Settings.directory)).AvailableFreeSpace
    }
}

function Get-TestVMArchivePath {
    <#
    .SYNOPSIS
    Resolves a new diagnostics archive path for a VM operation.

    .DESCRIPTION
    Uses the explicit reason and selected VM profile, rejecting an existing destination instead of overwriting evidence.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Reason
    Explicit archive name describing why the evidence is being preserved.

    .OUTPUTS
    System.String. Unused owned diagnostics archive path.
    #>

    param(
        $Settings,
        [string] $Reason
    )

    $root = Join-Path $Settings.root '.local\diagnostics'
    $path = Assert-TestVMPath -Path (Join-Path $root ('vm-' + $Settings.profile.ToLowerInvariant() + '-' + $Reason)) -Root $root

    if (Test-Path -LiteralPath $path) {
        throw 'The requested evidence archive already exists; choose another explicit reason label.'
    }

    $path
}

function Move-TestVMReports {
    <#
    .SYNOPSIS
    Archives host reports and available guest evidence before VM changes.

    .DESCRIPTION
    Preserves evidence under the explicit archive reason and records the archive operation in an owned working directory.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .PARAMETER Output
    Workflow output directory containing host-side operation reports.

    .PARAMETER Reason
    Explicit archive name describing why the evidence is being preserved.

    .PARAMETER Session
    Optional authenticated guest session from which to preserve additional evidence.

    .OUTPUTS
    System.String. Path to the completed evidence archive.
    #>

    param(
        $Settings,
        $Metadata,
        [string] $Output,
        [string] $Reason,
        $Session
    )

    $archive = Get-TestVMArchivePath -Settings $Settings -Reason $Reason
    Assert-TestVMPath -Path $Output -Root (Join-Path $Settings.root '.local') -CheckContents | Out-Null

    foreach ($name in @('vm.json', 'archive.json')) {
        if (Test-Path -LiteralPath (Join-Path $Output $name)) {
            throw 'Report evidence conflicts with archive metadata; preserve it separately.'
        }
    }

    Write-WorkflowMessage 'Archiving previous audit evidence:' -Data $archive

    if ($Session) {
        Write-WorkflowMessage 'Archiving owned guest audit reports before reusing report labels.'
        Invoke-Command -Session $Session -ScriptBlock {
            param(
                $Label
            )

            $ErrorActionPreference = 'Stop'
            $root = 'C:\WindowsProject'

            if (-not (Test-Path -LiteralPath $root)) {
                return
            }
            if ((Get-Content -LiteralPath (Join-Path $root '.baseline-project') -Raw) -cne 'Windows ADK baseline project') {
                throw 'Guest report ownership marker differs.'
            }

            foreach ($item in @(Get-Item -LiteralPath $root -Force) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw 'Guest evidence contains a reparse point.'
                }
            }

            $source = Join-Path $root '.local\audit'
            $destination = Join-Path $root ('.local\archives\' + $Label)

            if (Test-Path -LiteralPath $destination) {
                throw 'The guest evidence archive already exists.'
            }
            if (Test-Path -LiteralPath $source) {
                [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
                Move-Item -LiteralPath $source -Destination $destination
            }
        } -ArgumentList $Reason
    }

    [IO.Directory]::CreateDirectory((Split-Path $archive -Parent)) | Out-Null

    if (Test-Path -LiteralPath $Output) {
        Move-Item -LiteralPath $Output -Destination $archive
    }
    else {
        [IO.Directory]::CreateDirectory($archive) | Out-Null
    }

    $Metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $archive 'vm.json') -Encoding UTF8
    [ordered]@{
        reason        = $Reason
        vmId          = $Metadata.vmId
        archivedAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $archive 'archive.json') -Encoding UTF8
    $archive
}

function Restore-TestVMNetwork {
    <#
    .SYNOPSIS
    Restores the VM network adapters to their recorded attachments.

    .DESCRIPTION
    Matches adapters by identity and restores their original switch or disconnected state after temporary isolation.

    .PARAMETER VM
    Hyper-V VM object whose identity and owned resources have already been checked.

    .PARAMETER Connections
    Adapter identity and switch attachment records captured before isolation.

    .OUTPUTS
    None. Restores Hyper-V adapter connections.
    #>

    param(
        $VM,
        [object[]] $Connections
    )

    if ($Connections.Count) {
        Write-WorkflowMessage 'Restoring the original VM network attachments.'
    }

    $errors = @()

    foreach ($connection in $Connections) {
        try {
            $adapter = @(Get-VMNetworkAdapter -VM $VM | Where-Object {
                    [string]$_.Id -ceq [string]$connection.Id
                })
            $switch = Get-VMSwitch -Id $connection.SwitchId -ErrorAction Stop

            if ($adapter.Count -ne 1) {
                throw 'The original network adapter is missing.'
            }

            Write-WorkflowMessage 'Reconnecting the VM adapter to its original switch:' -Data $switch.Name
            Connect-VMNetworkAdapter -VMNetworkAdapter $adapter[0] -SwitchName $switch.Name -ErrorAction Stop
        }
        catch {
            $errors += $_.Exception.Message
        }
    }

    if ($errors.Count) {
        throw ('Network restoration failed: ' + ($errors -join '; '))
    }
}

function Restart-TestVMGuest {
    <#
    .SYNOPSIS
    Restarts the guest and waits for a new authenticated boot.

    .DESCRIPTION
    Records the current boot, requests a restart through PowerShell Direct, and checks that a different boot becomes available within the deadline.

    .PARAMETER VM
    Hyper-V VM object whose identity and owned resources have already been checked.

    .PARAMETER Credential
    Explicit local guest administrator credential used for PowerShell Direct access.

    .PARAMETER TimeoutSeconds
    Maximum time to wait for the restarted guest and authenticated access.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Before and after restart evidence.
    #>

    param(
        $VM,
        [pscredential] $Credential,
        [int] $TimeoutSeconds
    )

    Write-WorkflowMessage 'Requesting a normal guest restart before audit collection.'
    $session = New-PSSession -VMId $VM.Id -Credential $Credential -ErrorAction Stop

    try {
        $before = Invoke-Command -Session $session -ScriptBlock {
            (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        }
        Invoke-Command -Session $session -ScriptBlock {
            & shutdown.exe /r /t 0

            if ($LASTEXITCODE -ne 0) {
                throw ('Guest restart request failed: ' + $LASTEXITCODE)
            }
        }
    }
    finally {
        Remove-PSSession -Session $session
    }

    Write-WorkflowMessage 'Waiting for PowerShell Direct to reconnect and confirm a later guest boot. Timeout in seconds:' -Data ([string]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds([math]::Max(1, $TimeoutSeconds))

    do {
        Start-Sleep -Seconds 5
        $probe = $null

        try {
            $probe = New-PSSession -VMId $VM.Id -Credential $Credential -ErrorAction Stop
            $after = Invoke-Command -Session $probe -ScriptBlock {
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            }

            if ([DateTimeOffset]$after -gt [DateTimeOffset]$before) {
                Write-WorkflowMessage 'Guest restart confirmed. New boot time in UTC:' -Data $after -Level Success

                return [PSCustomObject]@{ beforeBootUtc = $before; afterBootUtc = $after }
            }
        }
        catch {
            Write-Verbose 'Waiting for the restarted guest PowerShell Direct endpoint.'
        }
        finally {
            if ($probe) {
                Remove-PSSession -Session $probe
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw 'The guest did not report a later boot before the restart timeout.'
}

function Reset-TestVMSystemDisk {
    <#
    .SYNOPSIS
    Checks or replaces the configured VM owned system disk.

    .DESCRIPTION
    Requires a powered-off owned VM and validates disk references and checkpoint disposal. Preserves the VM identity and security settings while resetting its disposable installation disk.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .PARAMETER VM
    Hyper-V VM object whose identity and owned resources have already been checked.

    .PARAMETER IsoPath
    Path to the source or installation ISO required by the selected operation.

    .PARAMETER DiscardCheckpoints
    Explicitly permits discarding checkpoints belonging to the owned VM.

    .PARAMETER CheckOnly
    Performs all reset ownership checks without changing checkpoints, disks, or attachments.

    .OUTPUTS
    None. Validates the reset or replaces the owned disk and installation-media attachment.
    #>

    param(
        $Settings,
        $Metadata,
        $VM,
        [string] $IsoPath,
        [switch] $DiscardCheckpoints,
        [switch] $CheckOnly
    )

    Write-WorkflowMessage 'Checking ownership, firmware, and disk chains before replacing the configured VM system disk.'

    if ($Settings.profile -cne 'Configured' -or $VM.State -ne 'Off') {
        throw 'Reinstall requires the powered-off configured VM.'
    }

    Get-TestVMOwnedMachine -Settings $Settings -Metadata $Metadata -AllowMissingDisks | Out-Null
    $firmware = Get-VMFirmware -VM $VM

    if (-not (Get-VMSecurity -VM $VM).TpmEnabled -or [string]$firmware.SecureBoot -cne 'On' -or $firmware.SecureBootTemplate -cne 'MicrosoftWindows') {
        throw 'The initialized TPM and Microsoft Windows Secure Boot configuration must remain intact.'
    }

    $snapshots = @(Get-VMSnapshot -VM $VM)

    if ($snapshots.Count -and -not $DiscardCheckpoints) {
        throw 'Reinstall would discard checkpoints; inspect them and explicitly supply -DiscardCheckpoints.'
    }

    foreach ($snapshot in $snapshots) {
        $drives = @(Get-VMHardDiskDrive -VMSnapshot $snapshot)

        if ($drives.Count -ne 1) {
            throw 'A checkpoint references unexpected disks.'
        }

        Get-TestVMDiskChain -Settings $Settings -Metadata $Metadata -Path $drives[0].Path -AllowMissingDisks | Out-Null
    }

    foreach ($other in @(Get-VM | Where-Object {
                [string]$_.Id -cne [string]$VM.Id
            })) {
        $references = @(Get-VMHardDiskDrive -VM $other)

        foreach ($snapshot in @(Get-VMSnapshot -VM $other)) {
            $references += @(Get-VMHardDiskDrive -VMSnapshot $snapshot)
        }

        foreach ($reference in $references) {
            $candidate = [IO.Path]::GetFullPath($reference.Path)
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

            while ($candidate) {
                if ($candidate.StartsWith($Settings.directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Another VM references this VM disk directory.'
                }
                if (-not $seen.Add($candidate)) {
                    throw 'A foreign VM has a cyclic disk chain; cannot verify exclusive ownership.'
                }
                if (-not (Test-Path -LiteralPath $candidate -ErrorAction Stop)) {
                    break
                }

                $candidate = (Get-VHD -Path $candidate -ErrorAction Stop).ParentPath
            }
        }
    }

    $dvds = @(Get-VMDvdDrive -VM $VM)

    if ($dvds.Count -ne 1 -or ($dvds[0].Path -and $dvds[0].Path -ine $IsoPath)) {
        throw 'Unexpected DVD attachment; inspect and detach foreign media before reinstallation.'
    }

    $currentDrives = @(Get-VMHardDiskDrive -VM $VM)
    $currentPath = $Metadata.vhdPath

    if ($currentDrives.Count -eq 1) {
        $currentPath = $currentDrives[0].Path
    }

    $chain = @(Get-TestVMDiskChain -Settings $Settings -Metadata $Metadata -Path $currentPath -AllowMissingDisks)
    $missingDisks = @($chain | Where-Object {
            -not (Test-Path -LiteralPath $_ -ErrorAction Stop)
        })

    foreach ($path in $chain) {
        if ((Test-Path -LiteralPath $path) -and (Get-VHD -Path $path).Attached) {
            throw 'A system disk is mounted; leave the disk intact.'
        }
    }

    # All ownership checks precede checkpoint removal and disk replacement.
    if ($CheckOnly) {
        return
    }
    # Discarding a broken installation does not require merging its missing active delta.
    # Detach that storage reference through Hyper-V before deleting its checkpoints.
    # A later retry accepts the same owned VM with no disk attachment.
    if ($missingDisks.Count -and $currentDrives.Count -eq 1 -and $snapshots.Count) {
        Write-WorkflowMessage 'Detaching the missing active disk before discarding its checkpoints.' -Level Warning
        Remove-VMHardDiskDrive -VMHardDiskDrive $currentDrives[0] -Confirm:$false
    }

    if ($snapshots.Count) {
        Write-WorkflowMessage 'Discarding configured checkpoints:' -Data (($snapshots | ForEach-Object {
                    $_.Name + ' [' + $_.Id + ']'
                }) -join ', ') -Level Warning
        $snapshots | Remove-VMSnapshot -Confirm:$false -ErrorAction Stop
        Write-WorkflowMessage 'Waiting for checkpoint removal and disk-chain consolidation to finish.'
        $deadline = [DateTime]::UtcNow.AddMinutes(3)

        do {
            $drives = @(Get-VMHardDiskDrive -VM $VM)

            if (@(Get-VMSnapshot -VM $VM).Count -eq 0 -and ($drives.Count -eq 0 -or ($drives.Count -eq 1 -and ($drives[0].Path -ieq $Metadata.vhdPath -or ($missingDisks.Count -and $drives[0].Path -iin $chain))))) {
                break
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Checkpoint merge did not finish; leave the disks intact.'
            }

            Start-Sleep -Seconds 2
        } while ($true)
    }

    $drives = @(Get-VMHardDiskDrive -VM $VM)

    if ($drives.Count -gt 1 -or ($drives.Count -eq 1 -and $drives[0].Path -ine $Metadata.vhdPath -and -not ($missingDisks.Count -and $drives[0].Path -iin $chain))) {
        throw 'The system disk did not return to an owned replacement path.'
    }

    $path = Assert-TestVMPath -Path $Metadata.vhdPath -Root $Settings.directory

    if (Test-Path -LiteralPath $path) {
        $disk = Get-VHD -Path $path

        if ($disk.ParentPath -or $disk.Attached) {
            throw 'The base disk is still mounted or has an unexpected parent.'
        }
    }

    if ($drives.Count -eq 1) {
        Remove-VMHardDiskDrive -VMHardDiskDrive $drives[0] -Confirm:$false
    }

    Write-WorkflowMessage 'Replacing the disposable VM system disk:' -Data $path -Level Warning

    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }

    New-VHD -Path $path -SizeBytes $Settings.vm.DiskBytes -Dynamic | Out-Null
    Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $path
    Write-WorkflowMessage 'Attaching installation media and selecting DVD boot:' -Data $IsoPath
    Set-VMDvdDrive -VMDvdDrive $dvds[0] -Path $IsoPath
    Set-VMFirmware -VM $VM -FirstBootDevice (Get-VMDvdDrive -VM $VM)
}

function Get-TestVMGuestInspection {
    <#
    .SYNOPSIS
    Collects guest installation, partition, and recovery observations.

    .DESCRIPTION
    Reads Windows identity, Setup readiness, first-sign-in state, GPT layout, and WinRE state through the supplied session without repairing the guest.

    .PARAMETER Session
    Authenticated PowerShell Direct session to the owned guest.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Guest inspection evidence.
    #>

    param(
        $Session
    )

    Invoke-Command -Session $session -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup'
        $imageState = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

        try {
            $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        finally {
            $identity.Dispose()
        }

        $recovery = @(& reagentc.exe /info 2>&1 | ForEach-Object {
                [string]$_
            })
        $recoveryExit = $LASTEXITCODE
        [PSCustomObject]@{
            editionId                 = $cv.EditionID
            build                     = $cv.CurrentBuildNumber
            revision                  = $cv.UBR
            computerName              = $env:COMPUTERNAME
            systemPreferredUiLanguage = [string](Get-SystemPreferredUILanguage)
            imageState                = $imageState
            systemSetupInProgress     = $setup.SystemSetupInProgress
            oobeInProgress            = $setup.OOBEInProgress
            desktopShellRunning       = (@(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count -gt 0)
            isAdministrator           = $admin
            partitionStyle            = [string](Get-Disk -Number 0).PartitionStyle
            partitions                = @(Get-Partition -DiskNumber 0 | Sort-Object PartitionNumber | Select-Object PartitionNumber, Type, GptType, Size)
            recoveryExitCode          = $recoveryExit
            recovery                  = $recovery
        }
    }
}

function Write-TestVMAuditSummary {
    <#
    .SYNOPSIS
    Displays a collected guest audit summary and unresolved findings.

    .DESCRIPTION
    Writes colored console messages from the verified, copied JSON report before collection-completeness checks can fail. Keeps report data off the success output stream and identifies the saved readable and detailed reports.

    .PARAMETER Report
    Parsed audit.json report with check counts, compliance checks, and collection areas.

    .PARAMETER ReportName
    Label identifying this audit, including separate labels for consecutive Capture audits.

    .PARAMETER ReportPath
    Host path to the copied audit.json report; audit.md is stored alongside it.

    .OUTPUTS
    None. Writes host messages through Write-WorkflowMessage.
    #>

    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)] [string] $ReportName,
        [Parameter(Mandatory = $true)] [string] $ReportPath
    )

    $summaryLevel = 'Success'

    if ($Report.summary.nonCompliant -gt 0) {
        $summaryLevel = 'Error'
    }
    elseif ($Report.summary.notVerified -gt 0 -or $Report.summary.incompleteAreas -gt 0) {
        $summaryLevel = 'Warning'
    }

    Write-WorkflowMessage ($ReportName + ': audit summary') -Level $summaryLevel
    $counters = @(
        @{
            key   = 'compliant'
            label = 'Compliant checks:'
            level = 'Success'
        }
        @{
            key   = 'nonCompliant'
            label = 'Noncompliant checks:'
            level = 'Error'
        }
        @{
            key   = 'notVerified'
            label = 'Not verified checks:'
            level = 'Warning'
        }
        @{
            key   = 'notApplicable'
            label = 'Not applicable checks:'
            level = 'Step'
        }
        @{
            key   = 'incompleteAreas'
            label = 'Incomplete collection areas:'
            level = 'Warning'
        }
    )

    foreach ($counter in $counters) {
        $key = $counter.key
        $count = $Report.summary.$key
        $level = 'Success'

        if ($count -gt 0) {
            $level = $counter.level
        }

        Write-WorkflowMessage $counter.label -Data ([string]$count) -Level $level
    }

    foreach ($check in $Report.checks) {
        if ($check.status -in @('NonCompliant', 'NotVerified')) {
            $level = 'Warning'

            if ($check.status -eq 'NonCompliant') {
                $level = 'Error'
            }

            Write-WorkflowMessage ('{0}/{1}: {2}' -f $check.area, $check.id, $check.reason) -Level $level
        }
    }

    foreach ($property in $Report.areas.PSObject.Properties) {
        $area = $property.Value

        if ($area.status -in @('Failed', 'Partial')) {
            Write-WorkflowMessage ('{0}: collection {1}. {2}' -f $property.Name, $area.status, ($area.errors -join '; ')) -Level Warning
        }
    }

    Write-WorkflowMessage 'Readable audit report:' -Data ([IO.Path]::ChangeExtension($ReportPath, '.md'))
    Write-WorkflowMessage 'Detailed audit report:' -Data $ReportPath
}

function Invoke-TestVMCollection {
    <#
    .SYNOPSIS
    Collects a guest audit and verifies its copied evidence.

    .DESCRIPTION
    Waits for guest readiness, verifies ownership and provenance, transfers the audit inputs, and copies hash-checked reports back to the host. Does not repair guest state.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .PARAMETER VM
    Hyper-V VM object whose identity and owned resources have already been checked.

    .PARAMETER Output
    Owned host directory receiving the collection report.

    .PARAMETER ReportName
    Directory name for the new audit report within the selected VM report root.

    .PARAMETER Credential
    Explicit local guest administrator credential used for PowerShell Direct access.

    .PARAMETER WaitForGuestSeconds
    Maximum time to wait for authenticated guest access and installation readiness.

    .PARAMETER Limited
    Runs collection with a restricted token for the same guest user.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Audit report path, exit code, and collection summary.
    #>

    param(
        $Settings,
        $Metadata,
        $VM,
        [string] $Output,
        [string] $ReportName,
        [pscredential] $Credential,
        [int] $WaitForGuestSeconds,
        [switch] $Limited
    )

    Write-WorkflowMessage 'Preparing guest audit collection:' -Data $ReportName
    $VMProfile = $Settings.profile
    $Action = 'Audit'

    if ($Limited) {
        $Action = 'Limited'
    }

    if ($WaitForGuestSeconds -gt 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds($WaitForGuestSeconds)

        if ([string]$vm.Heartbeat -notlike 'Ok*') {
            Write-WorkflowMessage 'Waiting for the guest Windows heartbeat. Timeout in seconds:' -Data ([string]$WaitForGuestSeconds)
        }

        while ([string]$vm.Heartbeat -notlike 'Ok*') {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Timed out waiting for the guest Windows heartbeat; inspect Setup in the VM console.'
            }

            Start-Sleep -Seconds 5
            $vm = Get-VM -Id $metadata.vmId

            if ($vm.State -ne 'Running') {
                throw 'The VM stopped while waiting for Windows.'
            }
        }
    }

    if ($null -eq $Credential) {
        if ($VMProfile -eq 'Configured') {
            throw 'Provide -Credential for the local administrator created through OOBE; the configured image contains no test credentials.'
        }

        $Credential = Import-Clixml -LiteralPath (Join-Path $settings.directory 'secrets\credential.clixml')
    }

    Write-WorkflowMessage 'Connecting to the guest through PowerShell Direct.'
    $session = New-PSSession -VMId $vm.Id -Credential $credential -ErrorAction Stop

    try {
        Write-WorkflowMessage 'Checking guest Setup/OOBE completion, OS identity, administrator access, and recovery state.'
        $inspection = Get-TestVMGuestInspection -Session $session
        $inspectionPath = Join-Path $output 'inspection.json'

        if ((Test-Path -LiteralPath $inspectionPath) -and ((Get-Item -LiteralPath $inspectionPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Inspection report must not be a reparse point.'
        }

        $inspection | Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inspectionPath -Encoding UTF8
        $installedVersion = '10.0.' + $inspection.build + '.' + $inspection.revision
        $firstSignInConfirmed = $inspection.desktopShellRunning
        $checkpointVerified = $false
        $checkpointPath = Join-Path $output 'checkpoint.json'

        if (Test-Path -LiteralPath $checkpointPath) {
            $previousCapture = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            $checkpointVerified = $previousCapture.vmId -ceq $metadata.vmId -and @(Get-VMSnapshot -VM $vm | Where-Object {
                    [string]$_.Id -ceq $previousCapture.id
                }).Count -eq 1
            $firstSignInConfirmed = $firstSignInConfirmed -or $checkpointVerified
        }

        $versionMatches = $installedVersion -ceq $settings.source.selectedImage.version

        if ($VMProfile -eq 'Configured' -and $Action -eq 'Audit' -and $checkpointVerified) {
            $versionMatches = [version]$installedVersion -ge [version]$settings.source.selectedImage.version
        }
        if ($inspection.imageState -ne 'IMAGE_STATE_COMPLETE' -or $inspection.systemSetupInProgress -ne 0 -or $inspection.oobeInProgress -ne 0 -or ($Action -ne 'Limited' -and -not $firstSignInConfirmed) -or -not $inspection.isAdministrator -or $inspection.editionId -cne 'Professional' -or $inspection.systemPreferredUiLanguage -cne 'en-US' -or -not $versionMatches -or $inspection.partitionStyle -ne 'GPT' -or $inspection.recoveryExitCode -ne 0 -or ($inspection.recovery -join ' ') -notmatch 'Windows RE status:\s+Enabled') {
            throw 'Complete Pro setup, confirmed first sign-in, administrator access, GPT, enabled Windows RE, and the expected OS version are required before collection.'
        }

        $destination = Join-Path $output $ReportName

        if (Test-Path -LiteralPath $destination) {
            throw 'Host report directory already exists; previous audit evidence is never overwritten.'
        }

        $guestRoot = 'C:\WindowsProject'
        Write-WorkflowMessage 'Preparing the owned guest working directory and copying audit inputs:' -Data $guestRoot
        Invoke-Command -Session $session -ScriptBlock {
            $root = $using:guestRoot
            $ErrorActionPreference = 'Stop'
            $marker = Join-Path $Root '.baseline-project'

            if ((Test-Path -LiteralPath $Root) -and (-not (Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw) -cne 'Windows ADK baseline project')) {
                throw 'Guest working directory already exists without the project marker.'
            }

            $ancestor = $Root

            while ($ancestor) {
                if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Guest working paths contain a reparse point.'
                }

                $ancestor = [IO.Path]::GetDirectoryName($ancestor)
            }

            if (Test-Path -LiteralPath $Root) {
                if (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object {
                            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
                        }).Count) {
                    throw 'Guest working contents contain a reparse point.'
                }
            }

            New-Item -ItemType Directory -Path (Join-Path $Root 'scripts'), (Join-Path $Root 'config') -Force | Out-Null
            [IO.File]::WriteAllText($marker, 'Windows ADK baseline project')
        }
        $expectedAuditHash = (Get-FileHash -LiteralPath (Join-Path $settings.root 'scripts\audit.ps1') -Algorithm SHA256).Hash
        $expectedConfigHash = (Get-FileHash -LiteralPath (Join-Path $settings.root 'config\windows.psd1') -Algorithm SHA256).Hash
        Copy-Item -LiteralPath (Join-Path $settings.root 'scripts\audit.ps1') -Destination ($guestRoot + '\scripts\audit.ps1') -ToSession $session
        Copy-Item -LiteralPath (Join-Path $settings.root 'config\windows.psd1') -Destination ($guestRoot + '\config\windows.psd1') -ToSession $session
        $limited = $Action -eq 'Limited'

        if ($limited) {
            Write-WorkflowMessage 'Running the guest audit with a restricted token; waiting for completion:' -Data $ReportName
        }
        else {
            Write-WorkflowMessage 'Running the independent guest audit; waiting for completion:' -Data $ReportName
        }

        $audit = Invoke-Command -Session $session -ScriptBlock {
            $root = $using:guestRoot
            $name = $using:ReportName
            $ErrorActionPreference = 'Stop'
            Set-Location -LiteralPath $Root
            $directory = Join-Path $Root ('.local\audit\' + $Name)

            if (Test-Path -LiteralPath $directory) {
                throw 'Guest report directory already exists.'
            }

            $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

            if ($using:limited) {
                $completion = Join-Path $Root ('.local\' + $Name + '.completed.json')

                if (Test-Path -LiteralPath $completion) {
                    throw 'A previous limited-user completion record already exists.'
                }

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
                $bootstrapPath = Join-Path $Root ('.local\' + $Name + '.launch.ps1')
                [IO.File]::WriteAllText($bootstrapPath, $bootstrap, [Text.UTF8Encoding]::new($false))
                $command = $powershell + ' -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ' + $bootstrapPath
                $launch = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\runas.exe') -ArgumentList @('/trustlevel:0x20000', ('"' + $command + '"')) -WindowStyle Hidden -PassThru -Wait

                if ($launch.ExitCode -ne 0) {
                    throw ('Limited-user launcher failed with exit ' + $launch.ExitCode)
                }

                $deadline = [DateTime]::UtcNow.AddMinutes(3)

                while (-not (Test-Path -LiteralPath $completion)) {
                    if ([DateTime]::UtcNow -ge $deadline) {
                        throw 'Limited-user process did not record completion.'
                    }

                    Start-Sleep -Seconds 1
                }

                $completed = Get-Content -LiteralPath $completion -Raw | ConvertFrom-Json

                if ($completed.status -cne 'Completed') {
                    throw ('Limited-user process failed: ' + $completed.error)
                }
                if ($completed.isAdministrator) {
                    throw 'The audit process retained administrator privileges.'
                }

                $processExit = $completed.exitCode
            }
            else {
                & $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $Root 'scripts\audit.ps1') -ConfigurationPath (Join-Path $Root 'config\windows.psd1') -OutputDirectory $directory | Out-Null
                $processExit = $LASTEXITCODE
            }

            [PSCustomObject]@{
                exitCode            = $processExit
                directory           = $directory
                auditScriptSha256   = (Get-FileHash -LiteralPath (Join-Path $Root 'scripts\audit.ps1') -Algorithm SHA256).Hash
                configurationSha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'config\windows.psd1') -Algorithm SHA256).Hash
            }
        }
        Write-WorkflowMessage 'Copying guest audit reports to the host:' -Data $destination
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        Copy-Item -Path ($audit.directory + '\*') -Destination $destination -FromSession $session -Recurse

        if ($limited) {
            Copy-Item -LiteralPath ($guestRoot + '\.local\' + $ReportName + '.completed.json') -Destination (Join-Path $destination 'launch.json') -FromSession $session
        }

        [ordered]@{
            vmId                = [string]$vm.Id
            sourceImageVersion  = $settings.source.selectedImage.version
            auditScriptSha256   = $audit.auditScriptSha256
            configurationSha256 = $audit.configurationSha256
            collectedAtUtc      = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'collection.json') -Encoding UTF8
        Write-WorkflowMessage 'Verifying audit input hashes, process exit code, and collection completeness.'
        $report = Get-Content -LiteralPath (Join-Path $destination 'audit.json') -Raw | ConvertFrom-Json

        if ($audit.auditScriptSha256 -cne $expectedAuditHash -or $audit.configurationSha256 -cne $expectedConfigHash -or $report.configuration.sha256 -cne $expectedConfigHash) {
            throw 'Audit inputs changed during collection.'
        }
        if ($report.exitCode -ne $audit.exitCode) {
            throw 'Guest process exit code differs from its audit report.'
        }

        Write-TestVMAuditSummary -Report $report -ReportName $ReportName -ReportPath (Join-Path $destination 'audit.json')

        if ($limited) {
            if ($report.context.isAdministrator -or ($report.exitCode -band 2) -ne 2 -or $report.summary.incompleteAreas -eq 0 -or $report.areas.RegisteredApps.status -cne 'Partial' -or $report.areas.RegisteredApps.scope -cne 'CurrentUser') {
                throw 'The limited-user audit did not expose the expected privilege and scope limitations.'
            }

            Write-WorkflowMessage 'Limited-user collection limits verified.' -Level Success
        }
        elseif ($audit.exitCode -notin @(0, 1)) {
            throw 'Guest audit is incomplete; inspect its reports.'
        }

        $collectionLevel = 'Success'

        if (-not $limited -and $audit.exitCode -ne 0) {
            $collectionLevel = 'Warning'
        }

        Write-WorkflowMessage ($ReportName + ': reports copied and verified. Audit exit code:') -Data ([string]$audit.exitCode) -Level $collectionLevel
        [PSCustomObject]@{
            reportPath = Join-Path $destination 'audit.json'
            exitCode   = $report.exitCode
            summary    = $report.summary
        }
    }
    finally {
        Remove-PSSession -Session $session
    }
}

function Start-TestVMInstallation {
    <#
    .SYNOPSIS
    Starts the owned VM after validating the prepared installation.

    .DESCRIPTION
    Requires current passing validation, an empty powered-off system disk, no checkpoints, and matching installation inputs. Optionally opens the console for the native Setup and OOBE handoff.

    .PARAMETER Settings
    Resolved VM configuration returned by Get-TestVMConfiguration.

    .PARAMETER Metadata
    Recorded VM identity, owned paths, and installation provenance from vm.json.

    .PARAMETER VM
    Hyper-V VM object whose identity and owned resources have already been checked.

    .PARAMETER OpenConsole
    Opens VMConnect after starting the VM.

    .OUTPUTS
    None. Starts the VM and optionally VMConnect.
    #>

    param(
        $Settings,
        $Metadata,
        $VM,
        [switch] $OpenConsole
    )

    Write-WorkflowMessage 'Verifying fresh VM validation, the empty system disk, and installation-media hashes before boot.'
    $validationDirectory = Join-Path $Settings.root '.local\vm-validation'

    if ($Settings.profile -eq 'Configured') {
        $validationDirectory = Join-Path $Settings.root '.local\vm-configured-validation'
    }

    $validation = Get-Content -LiteralPath (Join-Path $validationDirectory 'validation.json') -Raw | ConvertFrom-Json

    if ($validation.status -cne 'Succeeded' -or $validation.answer.status -cne 'Pass' -or $validation.vm.id -cne [string]$VM.Id -or $validation.vm.metadataSha256 -cne (Get-FileHash -LiteralPath (Join-Path $Settings.directory 'vm.json') -Algorithm SHA256).Hash) {
        throw 'Fresh validation of this VM and its current ownership metadata is required before Start.'
    }

    $templatePath = Join-Path $Settings.root 'setup\vm\autounattend.xml'

    if ($Settings.profile -eq 'Configured') {
        $templatePath = Join-Path $Settings.root 'setup\deployment\autounattend.xml'
    }
    if ($validation.answer.templateSha256 -cne (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash -or $validation.configurationSha256 -cne (Get-FileHash -LiteralPath (Join-Path $Settings.root 'config\windows.psd1') -Algorithm SHA256).Hash) {
        throw 'Setup inputs changed since VM validation.'
    }

    $disks = @(Get-VMHardDiskDrive -VM $VM)

    if ($VM.State -ne 'Off' -or @(Get-VMSnapshot -VM $VM).Count -or $disks.Count -ne 1 -or $disks[0].Path -ine $Metadata.vhdPath -or (Get-Item -LiteralPath $Metadata.vhdPath).Length -gt 64MB) {
        throw 'Start requires the powered-off fresh test disk without checkpoints.'
    }
    if (@(Get-VMNetworkAdapter -VM $VM | Where-Object SwitchName).Count) {
        throw 'Disconnect the installation VM from virtual switches.'
    }

    if ($Settings.profile -eq 'Baseline') {
        if ((Get-FileHash -LiteralPath $Metadata.seedIsoPath -Algorithm SHA256).Hash -cne $Metadata.seedIsoSha256) {
            throw 'Answer media changed after VM preparation.'
        }
    }
    elseif ($Metadata.seedIsoPath -or @(Get-VMDvdDrive -VM $VM | Where-Object Path).Count -ne 1) {
        throw 'Configured installation must use only the integrated deployment ISO.'
    }

    $dvds = @(Get-VMDvdDrive -VM $VM | Where-Object {
            $_.Path -and $_.Path -ine $Metadata.seedIsoPath
        })

    if ($dvds.Count -ne 1 -or (Get-FileHash -LiteralPath $dvds[0].Path -Algorithm SHA256).Hash -cne $Metadata.isoSha256) {
        throw 'The installation ISO differs from the recorded input.'
    }

    Write-WorkflowMessage 'Starting the VM from its installation media:' -Data $VM.Name
    Start-VM -VM $VM | Out-Null

    if ($OpenConsole) {
        Write-WorkflowMessage 'Opening the Hyper-V console:' -Data $VM.Name
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\vmconnect.exe') -ArgumentList @('localhost', $VM.Name) -WindowStyle Normal | Out-Null
    }

    Write-WorkflowMessage 'VM started:' -Data $VM.Name -Level Success
    Write-WorkflowMessage 'Complete the DVD boot prompt, native Windows Setup, and OOBE in the VM console.' -Level Warning
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The test-VM workflow requires Windows.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Use a 64-bit PowerShell process.'
}

Write-WorkflowMessage 'Checking test-VM workflow parameters and configuration:' -Data ($Action + ' / ' + $VMProfile)
Assert-TestVMActionParameters -Parameters $PSBoundParameters
$root = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $root 'scripts'
$requestedIsoPath = $IsoPath
. (Join-Path $scripts 'new-test-vm.ps1') -IsoPath 'unused-workflow.iso' -VMProfile $VMProfile
. (Join-Path $scripts 'compare-audits.ps1') -Mode Drift -Before 'unused' -After 'unused' -OutputDirectory 'unused'
$settings = Get-TestVMConfiguration -VMProfile $VMProfile
$IsoPath = $requestedIsoPath
$metadataPath = Assert-TestVMPath -Path (Join-Path $settings.directory 'vm.json') -Root $settings.directory
$output = Join-Path $root '.local\vm-baseline'

if ($VMProfile -eq 'Configured') {
    $output = Join-Path $root '.local\vm-configured'
}

Assert-TestVMPath -Path $output -Root (Join-Path $root '.local') -CheckContents | Out-Null
$operationRoot = Join-Path $root ('.local\workflows\test-vm\' + $VMProfile.ToLowerInvariant())

foreach ($path in @($operationRoot, ($operationRoot + '.lock'), (Join-Path $operationRoot 'operation.json'))) {
    Assert-TestVMPath -Path $path -Root (Join-Path $root '.local') | Out-Null
}

Write-WorkflowMessage 'Loading the Hyper-V management module.'
Import-Module Hyper-V -ErrorAction Stop

if (-not $PSCmdlet.ShouldProcess($settings.vm.Name, $Action)) {
    return
}

[IO.Directory]::CreateDirectory((Split-Path $operationRoot -Parent)) | Out-Null

try {
    $lock = [IO.FileStream]::new(($operationRoot + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
}
catch {
    throw 'Another test-vm workflow is using this profile.'
}

$operation = [ordered]@{
    schemaVersion     = 1
    action            = $Action
    profile           = $VMProfile
    status            = 'Running'
    startedAtUtc      = [DateTime]::UtcNow.ToString('o')
    completedAtUtc    = $null
    vmId              = $null
    reports           = @()
    comparisonPath    = $null
    archivePath       = $null
    inspectionPath    = $null
    outputDirectory   = $output
    networkMode       = $NetworkMode
    networkBefore     = @()
    restorationErrors = @()
    restart           = $null
    reinstallBefore   = $null
    removal           = $null
    error             = $null
}
$connections = @()
$vm = $null
$startedForLimited = $false

try {
    [IO.Directory]::CreateDirectory($operationRoot) | Out-Null
    $operation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $operationRoot 'operation.json') -Encoding UTF8
    $metadata = $null

    if (Test-Path -LiteralPath $metadataPath) {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    }

    if ($Action -eq 'Inspect') {
        $inspection = Get-TestVMHostInspection -Settings $settings -Metadata $metadata

        if (-not $Credential -and $VMProfile -eq 'Baseline' -and $inspection.actual -and $inspection.actual.state -eq 'Running' -and $inspection.issues.Count -eq 0) {
            try {
                $Credential = Import-Clixml -LiteralPath (Join-Path $settings.directory 'secrets\credential.clixml')
            }
            catch {
                $inspection.guestAccess = 'Unavailable: ' + $_.Exception.Message
            }
        }

        if ($Credential -and $inspection.actual -and $inspection.actual.state -eq 'Running' -and $inspection.issues.Count -eq 0) {
            Write-WorkflowMessage 'Inspecting the running guest through PowerShell Direct.'
            $session = $null

            try {
                $session = New-PSSession -VMId $inspection.actual.id -Credential $Credential -ErrorAction Stop
                $inspection.guest = Get-TestVMGuestInspection -Session $session | Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName
                $inspection.guestAccess = 'Succeeded'
            }
            catch {
                $inspection.guestAccess = $_.Exception.Message
            }
            finally {
                if ($session) {
                    Remove-PSSession -Session $session
                }
            }
        }
        elseif ($Credential) {
            $inspection.guestAccess = 'Unavailable: VM is absent, stopped, or ownership checks failed.'
        }

        if ($inspection.actual) {
            $operation.vmId = $inspection.actual.id
        }

        $operation.inspectionPath = Join-Path $operationRoot 'inspection.json'
        $inspection | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $operation.inspectionPath -Encoding UTF8

        foreach ($issue in $inspection.issues) {
            Write-WorkflowMessage 'VM inspection finding:' -Data $issue -Level Warning
        }

        if ($inspection.guestAccess -ne 'NotRequested' -and $inspection.guestAccess -ne 'Succeeded') {
            Write-WorkflowMessage 'Guest inspection was unavailable:' -Data $inspection.guestAccess -Level Warning
        }

        $inspection | ConvertTo-Json -Depth 12 | Out-Host
        $operation.status = 'Succeeded'

        return
    }

    if ($Action -eq 'Remove') {
        $operation.removal = Remove-TestVMResources -Settings $settings -Metadata $metadata -DiscardCheckpoints:$DiscardCheckpoints -CheckOnly
        $operation.vmId = $operation.removal.vmId
        $operation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $operationRoot 'operation.json') -Encoding UTF8
        Remove-TestVMResources -Settings $settings -Metadata $metadata -DiscardCheckpoints:$DiscardCheckpoints | Out-Null
        $operation.status = 'Succeeded'

        return
    }

    if ($Action -in @('Prepare', 'Reinstall')) {
        Write-WorkflowMessage 'Resolving the matching source WIM for Windows SIM validation.'
        $WimPath = Get-TestVMValidationWim -Settings $settings -Path $WimPath
    }

    if ($Action -eq 'Prepare') {
        if (-not $IsoPath) {
            if ($VMProfile -eq 'Baseline') {
                throw 'Prepare -VMProfile Baseline requires -IsoPath for the official source ISO.'
            }

            $IsoPath = Join-Path $root '.local\media\windows11-pro\windows11-pro.iso'
        }

        Write-WorkflowMessage 'Creating the isolated test VM, system disk, and installation-media attachments:' -Data $settings.vm.Name
        & (Join-Path $scripts 'new-test-vm.ps1') -IsoPath $IsoPath -VMProfile $VMProfile -Confirm:$false | Out-Host
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    }

    if (-not $metadata) {
        throw 'Owned VM metadata is missing; use Prepare for a missing VM.'
    }

    Write-WorkflowMessage 'Verifying the recorded VM identity and owned system disk.'
    $vm = Get-TestVMOwnedMachine -Settings $settings -Metadata $metadata -AllowMissingDisks:($Action -eq 'Reinstall')
    $operation.vmId = [string]$vm.Id

    if ($Action -eq 'Reinstall') {
        if (-not $IsoPath) {
            $IsoPath = Join-Path $root '.local\media\windows11-pro\windows11-pro.iso'
        }

        Write-WorkflowMessage 'Checking reinstallation inputs and available host resources.'
        $preflight = Get-TestVMPreflight -Settings $settings -IsoPath $IsoPath -ForReinstall

        if (@(Get-VMSnapshot -VM $vm).Count -and -not $DiscardCheckpoints) {
            throw 'Inspect existing checkpoints and explicitly supply -DiscardCheckpoints before reinstallation.'
        }

        Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath $preflight.isoPath -DiscardCheckpoints:$DiscardCheckpoints -CheckOnly

        if ((Test-Path -LiteralPath $output) -and -not $ArchiveReason) {
            throw 'Previous reports exist; supply -ArchiveReason to preserve them before reinstallation.'
        }
        if ($ArchiveReason -and (Test-Path -LiteralPath $output)) {
            $operation.archivePath = Move-TestVMReports -Settings $settings -Metadata $metadata -Output $output -Reason $ArchiveReason
        }

        $operation.reinstallBefore = Get-TestVMHostInspection -Settings $settings -Metadata $metadata
        $adapters = @(Get-VMNetworkAdapter -VM $vm | Where-Object SwitchName)
        $connections = @($adapters | Select-Object Id, SwitchId, SwitchName)
        $operation.networkBefore = $connections
        $operation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $operationRoot 'operation.json') -Encoding UTF8
        Write-WorkflowMessage 'Isolating VM networking before reinstallation.'

        foreach ($adapter in $adapters) {
            Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter -ErrorAction Stop
        }

        Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath $preflight.isoPath -DiscardCheckpoints:$DiscardCheckpoints
        $metadata.isoSha256 = $preflight.isoSha256
        $metadata | Add-Member -NotePropertyName isoPath -NotePropertyValue $preflight.isoPath -Force
        $metadata.status = 'Created'
        $metadata.settings = $settings.vm
        $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    }

    if ($Action -in @('Prepare', 'Reinstall', 'Start')) {
        if ($Action -ne 'Start') {
            Write-WorkflowMessage 'Validating the answer file with Windows SIM and checking VM hardware. Source WIM:' -Data $WimPath
            & (Join-Path $scripts 'validate-vm-setup.ps1') -WimPath $WimPath -VMProfile $VMProfile | Out-Host
        }

        Start-TestVMInstallation -Settings $settings -Metadata $metadata -VM $vm -OpenConsole:$OpenConsole

        # Fresh installation remains isolated; restore prior connections only on failure.
        if ($Action -eq 'Reinstall') {
            $connections = @()
        }

        $operation.status = 'Succeeded'

        return
    }

    if (-not $Credential) {
        if ($VMProfile -eq 'Configured') {
            throw 'Supply -Credential for the local administrator created in configured OOBE.'
        }

        $Credential = Import-Clixml -LiteralPath (Join-Path $settings.directory 'secrets\credential.clixml')
    }

    if (-not $ReportName) {
        $ReportName = $VMProfile.ToLowerInvariant()

        if ($Action -eq 'Limited') {
            $ReportName = 'limited-user'
        }
    }

    if ($Action -eq 'Limited') {
        $checkpoint = Get-Content -LiteralPath (Join-Path $output 'checkpoint.json') -Raw | ConvertFrom-Json

        if ($checkpoint.vmId -cne [string]$vm.Id -or @(Get-VMSnapshot -VM $vm | Where-Object {
                    [string]$_.Id -ceq $checkpoint.id
                }).Count -ne 1 -or @(Get-VMDvdDrive -VM $vm | Where-Object Path).Count) {
            throw 'Limited requires the recorded clean checkpoint with detached installation media.'
        }

        if ($vm.State -eq 'Off') {
            Write-WorkflowMessage 'Starting the checkpointed guest for the limited-user audit.'
            Start-VM -VM $vm | Out-Null
            $startedForLimited = $true
            $vm = Get-VM -Id $metadata.vmId
        }
    }

    if ($vm.State -ne 'Running') {
        throw 'Start the installed guest and complete its first sign-in before collection.'
    }

    $checkpointName = $VMProfile.ToLowerInvariant() + '-audited'
    $labels = @($ReportName)

    if ($Action -eq 'Capture') {
        if (@(Get-VMSnapshot -VM $vm | Where-Object Name -eq $checkpointName).Count) {
            throw 'The audited checkpoint already exists; use Audit for subsequent checks.'
        }

        $labels = @($VMProfile.ToLowerInvariant(), ($VMProfile.ToLowerInvariant() + '-repeat'))

        if ($ArchiveReason) {
            $session = New-PSSession -VMId $vm.Id -Credential $Credential -ErrorAction Stop

            try {
                $operation.archivePath = Move-TestVMReports -Settings $settings -Metadata $metadata -Output $output -Reason $ArchiveReason -Session $session
            }
            finally {
                Remove-PSSession -Session $session
            }
        }
    }

    foreach ($label in $labels) {
        if (Test-Path -LiteralPath (Join-Path $output $label)) {
            throw 'Report labels already exist; preserve earlier evidence before repeating collection.'
        }
    }

    $beforeReport = $null

    if ($CompareTo) {
        Write-WorkflowMessage 'Verifying the previous audit and its collection receipt before comparison:' -Data $CompareTo
        $beforeReport = (Resolve-Path -LiteralPath $CompareTo).ProviderPath
        $receipt = Get-Content -LiteralPath (Join-Path (Split-Path $beforeReport -Parent) 'collection.json') -Raw | ConvertFrom-Json

        if ($receipt.vmId -cne [string]$vm.Id -or $receipt.configurationSha256 -cne (Get-FileHash -LiteralPath (Join-Path $root 'config\windows.psd1') -Algorithm SHA256).Hash -or $receipt.auditScriptSha256 -cne (Get-FileHash -LiteralPath (Join-Path $scripts 'audit.ps1') -Algorithm SHA256).Hash) {
            throw 'CompareTo must describe the same VM, configuration, and audit implementation.'
        }
    }

    $attachedAdapters = @(Get-VMNetworkAdapter -VM $vm | Where-Object SwitchName)
    $operation.networkBefore = @($attachedAdapters | Select-Object Id, SwitchId, SwitchName)

    if ($Action -eq 'Limited' -and $attachedAdapters.Count) {
        throw 'Limited requires disconnected networking.'
    }

    if ($NetworkMode -eq 'Isolated') {
        if ($VMProfile -eq 'Baseline' -and $attachedAdapters.Count) {
            throw 'The clean baseline must remain disconnected.'
        }

        $connections = @($attachedAdapters | Select-Object Id, SwitchId, SwitchName)
        $operation.networkBefore = $connections
        # Record every original attachment before the first disconnect.
        $operation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $operationRoot 'operation.json') -Encoding UTF8
        Write-WorkflowMessage 'Isolating VM networking during audit collection; original attachments will be restored afterward.'

        foreach ($adapter in $attachedAdapters) {
            Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter -ErrorAction Stop
        }
    }
    else {
        Write-WorkflowMessage 'Keeping current VM network connections as explicitly requested.' -Level Warning
    }

    if ($RestartBefore) {
        $operation.restart = Restart-TestVMGuest -VM $vm -Credential $Credential -TimeoutSeconds $WaitForGuestSeconds
    }

    [IO.Directory]::CreateDirectory($output) | Out-Null

    foreach ($label in $labels) {
        $collected = Invoke-TestVMCollection -Settings $settings -Metadata $metadata -VM $vm -Output $output -ReportName $label -Credential $Credential -WaitForGuestSeconds $WaitForGuestSeconds -Limited:($Action -eq 'Limited')
        $operation.reports += $collected
    }

    if ($Action -eq 'Capture') {
        if ($VMProfile -eq 'Configured' -and @($operation.reports | Where-Object {
                    $_.exitCode -ne 0 -or $_.summary.notVerified -gt 0
                }).Count) {
            throw 'Both configured audits must pass before checkpoint creation; inspect the reports.'
        }

        $operation.comparisonPath = Join-Path $output 'comparison.json'
        Write-WorkflowMessage 'Comparing consecutive audits for repeatability before checkpoint creation.'
        & (Join-Path $scripts 'compare-audits.ps1') -Mode Repeatability -Before $operation.reports[0].reportPath -After $operation.reports[1].reportPath -OutputDirectory $output | Out-Host
        Write-WorkflowMessage 'Shutting down the audited guest cleanly; waiting for shutdown to finish.'
        Stop-VM -VM $vm -Confirm:$false
        $vm = Get-VM -Id $metadata.vmId

        if ($vm.State -ne 'Off') {
            throw 'The guest did not shut down cleanly; no checkpoint was created.'
        }

        Write-WorkflowMessage 'Detaching installation media and selecting the system disk for boot.'

        foreach ($dvd in @(Get-VMDvdDrive -VM $vm | Where-Object Path)) {
            Set-VMDvdDrive -VMDvdDrive $dvd -Path $null
        }

        Set-VMFirmware -VM $vm -FirstBootDevice (Get-VMHardDiskDrive -VM $vm)
        Write-WorkflowMessage 'Creating the audited checkpoint; waiting for Hyper-V to finish:' -Data $checkpointName
        Checkpoint-VM -VM $vm -SnapshotName $checkpointName
        $checkpoint = Get-VMSnapshot -VM $vm | Where-Object Name -eq $checkpointName
        [ordered]@{
            schemaVersion        = 1
            vmId                 = [string]$vm.Id
            name                 = $checkpointName
            id                   = [string]$checkpoint.Id
            state                = 'Off'
            installMediaDetached = $true
            createdAtUtc         = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'checkpoint.json') -Encoding UTF8
        Write-WorkflowMessage 'Audited checkpoint created:' -Data $checkpointName -Level Success
    }
    elseif ($CompareTo) {
        $comparisonDirectory = Split-Path $operation.reports[0].reportPath -Parent
        $operation.comparisonPath = Join-Path $comparisonDirectory 'comparison.json'
        Write-WorkflowMessage 'Comparing the collected audit with the previous report for drift.'
        & (Join-Path $scripts 'compare-audits.ps1') -Mode Drift -Before $beforeReport -After $operation.reports[0].reportPath -OutputDirectory $comparisonDirectory | Out-Host
    }

    $operation.status = 'Succeeded'

    if ($Action -eq 'Audit' -and $operation.reports[0].exitCode -ne 0) {
        $operation.status = 'NonCompliant'
        $operation.error = 'Collection completed, but the audit found configuration mismatches.'
        Write-WorkflowMessage 'Audit result:' -Data $operation.error -Level Warning
    }
}
catch {
    $operation.status = 'Failed'
    $operation.error = $_.Exception.Message
    Write-WorkflowMessage 'Test VM operation failed:' -Data $operation.error -Level Error
}
finally {
    try {
        if ($connections.Count) {
            Restore-TestVMNetwork -VM $vm -Connections $connections
        }
    }
    catch {
        $operation.restorationErrors += $_.Exception.Message
        $operation.status = 'Failed'
        Write-WorkflowMessage 'VM network restoration failed:' -Data $_.Exception.Message -Level Error
    }

    try {
        if ($startedForLimited -and (Get-VM -Id $metadata.vmId).State -eq 'Running') {
            Write-WorkflowMessage 'Shutting down the guest started for the limited-user audit.'
            Stop-VM -VM (Get-VM -Id $metadata.vmId) -Confirm:$false
        }
    }
    catch {
        $operation.restorationErrors += $_.Exception.Message
        $operation.status = 'Failed'
        Write-WorkflowMessage 'Limited-user audit cleanup failed:' -Data $_.Exception.Message -Level Error
    }

    $operation.completedAtUtc = [DateTime]::UtcNow.ToString('o')

    try {
        $operation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $operationRoot 'operation.json') -Encoding UTF8
    }
    finally {
        $lock.Dispose()
    }

    $completionLevel = 'Success'

    if ($operation.status -eq 'Failed') {
        $completionLevel = 'Error'
    }
    elseif ($operation.status -ne 'Succeeded') {
        $completionLevel = 'Warning'
    }

    Write-WorkflowMessage 'Test VM operation result:' -Data $operation.status -Level $completionLevel
    Write-WorkflowMessage 'Operation report:' -Data (Join-Path $operationRoot 'operation.json') -Level $completionLevel
}

if ($operation.status -cne 'Succeeded') {
    throw ((@($operation.error) + @($operation.restorationErrors)) -join '; ')
}
