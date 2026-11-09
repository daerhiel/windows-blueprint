#Requires -Version 5.1
<#
.SYNOPSIS
Checks audit comparison and VM ownership failure paths without controlling a VM.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Scope = 'Function', Target = '*', Justification = 'Cmdlet doubles retain production parameter signatures even when a fixture observes only selected arguments.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fixture helpers and cmdlet doubles change only isolated synthetic test data.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'Cmdlet doubles accept the production Confirm parameter without implementing interactive confirmation.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Scope = 'Function', Target = 'Import-Module', Justification = 'The test double prevents loading Hyper-V while exercising the workflow entry point.')]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
# Load definitions only; privileged entry points and production data are never executed.
foreach ($file in @('scripts\workflow-output.ps1', 'workflows\test-vm.ps1', 'scripts\compare-audits.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository $file), [ref]$tokens, [ref]$errors)
    if ($errors) { throw ('Syntax errors in ' + $file) }
    foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($function.Extent.Text)) }
}
$fixture = Join-Path $repository ('.local\workflow-tests\vm-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$checks = 0
function Assert-VMWorkflow {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:checks++
}
function Assert-VMWorkflowFailure {
    param([scriptblock] $Action, [string] $Expected)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-VMWorkflow ($message -like ('*' + $Expected + '*')) ('Expected ' + $Expected + '; actual: ' + $message)
}
function New-ComparisonFixture {
    param([string] $Name)
    $path = Join-Path $fixture $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $report = [ordered]@{
        schemaVersion = 1; exitCode = 0; summary = @{ nonCompliant = 0; incompleteAreas = 0; notVerified = 0 }
        context = @{ userSid = 'synthetic-user' }; configuration = @{ sha256 = 'config' }
        areas = [ordered]@{
            Os = @{ status = 'Complete'; scope = 'Machine'; data = @{ build = 'synthetic'; revision = 1 } }
            OptionalFeatures = @{ status = 'Complete'; scope = 'Machine'; data = @(@{ name = 'Feature'; state = 'Enabled' }) }
            RegisteredApps = @{ status = 'Complete'; scope = 'AllUsers'; data = @(@{ packageName = 'App_1'; users = @(@{ sid = 'user-a'; installState = 'Installed' }, @{ sid = 'user-b'; installState = 'Paused' }); dependencies = @('two', 'one') }) }
            Services = @{ status = 'Complete'; scope = 'Machine'; data = @(@{ name = 'Service_user-a'; state = 'Running'; startMode = 'Manual'; delayedAutoStart = $false }) }
            Policies = @{ status = 'Complete'; scope = 'ConfiguredRules'; data = @(@{ id = 'Policy'; observation = @{ value = 1 } }) }
            Reboot = @{ status = 'Complete'; scope = 'Machine'; data = @{ indicatorPresent = $false } }
            Deployment = @{ status = 'NotApplicable'; scope = 'DeploymentProfile'; data = $null }
        }
    }
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $path 'audit.json') -Encoding UTF8
    Join-Path $path 'audit.json'
}
function Save-ComparisonFixture { param($Report, [string] $Path) $Report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $Path -Encoding UTF8 }
$before = New-ComparisonFixture 'before'
$after = New-ComparisonFixture 'after'
$result = Get-AuditComparison -Mode Repeatability -Before $before -After $after
Assert-VMWorkflow ($result.stableAreasMatch -and $result.comparisonComplete) 'Standalone reports work without VM collection receipts.'
$changed = Get-Content -LiteralPath $after -Raw | ConvertFrom-Json
$changed.areas.Reboot.data.indicatorPresent = $true
$changed.areas.Services.data[0].state = 'Stopped'
$changed.areas.RegisteredApps.data[0].users = @($changed.areas.RegisteredApps.data[0].users | Sort-Object sid -Descending)
$changed.areas.RegisteredApps.data[0].dependencies = @('one', 'two')
Save-ComparisonFixture $changed $after
$result = Get-AuditComparison -Mode Repeatability -Before $before -After $after
Assert-VMWorkflow $result.stableAreasMatch 'Volatile service/reboot observations and collector enumeration order do not break repeatability.'
$result = Get-AuditComparison -Mode Drift -Before $before -After $after
Assert-VMWorkflow ($result.changes.Reboot.changed.Count -eq 1) 'Drift retains changed reboot observations.'
$changed.areas.OptionalFeatures.data[0].state = 'Disabled'
$changed.areas.RegisteredApps.data[0].users[0].installState = 'Installed'
$changed.areas.Services.data[0].startMode = 'Disabled'
$changed.areas.Policies.data[0].observation.value = 0
$changed.areas.Os.data.revision = 2
Save-ComparisonFixture $changed $after
$result = Get-AuditComparison -Mode Drift -Before $before -After $after
foreach ($name in @('OptionalFeatures', 'RegisteredApps', 'Services', 'Policies', 'Os')) { Assert-VMWorkflow ($result.changes[$name].changed.Count -eq 1) ('Drift includes ' + $name) }
$changed.areas.RegisteredApps.scope = 'CurrentUser'
$changed.areas.RegisteredApps.status = 'Partial'
Save-ComparisonFixture $changed $after
$result = Get-AuditComparison -Mode Drift -Before $before -After $after
Assert-VMWorkflow (-not $result.comparisonComplete -and -not $result.changes.RegisteredApps.comparable -and $result.changes.RegisteredApps.removed.Count -eq 0) 'Partial collection never proves app removal.'
$changed.areas.RegisteredApps.scope = 'AllUsers'; $changed.areas.RegisteredApps.status = 'Complete'
$changed.areas.Services.data += $changed.areas.Services.data[0]
Save-ComparisonFixture $changed $after
Assert-VMWorkflowFailure { Get-AuditComparison -Mode Drift -Before $before -After $after } 'duplicate identity'
$changed.areas.Services.data = @($changed.areas.Services.data[0])
$changed.configuration.sha256 = 'other'
Save-ComparisonFixture $changed $after
Assert-VMWorkflowFailure { Get-AuditComparison -Mode Drift -Before $before -After $after } 'configurations differ'
$changed.configuration.sha256 = 'config'; $changed.context.userSid = 'different-user'
Save-ComparisonFixture $changed $after
Assert-VMWorkflowFailure { Get-AuditComparison -Mode Drift -Before $before -After $after } 'user contexts differ'
$changed.context.userSid = 'synthetic-user'
Save-ComparisonFixture $changed $after
foreach ($path in @($before, $after)) { @{ vmId = 'owned'; configurationSha256 = 'config'; auditScriptSha256 = 'collector' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $path -Parent) 'collection.json') -Encoding UTF8 }
$receipt = Join-Path (Split-Path $after -Parent) 'collection.json'
@{ vmId = 'foreign'; configurationSha256 = 'config'; auditScriptSha256 = 'collector' } | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
Assert-VMWorkflowFailure { Get-AuditComparison -Mode Drift -Before $before -After $after } 'provenance differs'

Assert-VMWorkflowFailure { Assert-TestVMActionParameters @{ Action = 'Audit'; IsoPath = 'source' } } 'does not apply'
Assert-VMWorkflowFailure { Assert-TestVMActionParameters @{ Action = 'Capture'; RestartBefore = $true } } 'does not apply'
Assert-VMWorkflowFailure { Assert-TestVMActionParameters @{ Action = 'Reinstall'; VMProfile = 'Baseline' } } 'only the Configured'
Assert-VMWorkflowFailure { Assert-TestVMActionParameters @{ Action = 'Audit'; VMProfile = 'Baseline'; NetworkMode = 'Preserve' } } 'remain isolated'
Assert-TestVMActionParameters @{ Action = 'Audit'; VMProfile = 'Configured'; NetworkMode = 'Preserve'; CompareTo = 'report'; RestartBefore = $true }

$owned = Join-Path $fixture 'owned'
[IO.Directory]::CreateDirectory($owned) | Out-Null
$settings = @{ root = $fixture; directory = $owned; profile = 'Configured'; vm = @{ Name = 'Owned'; DiskBytes = 80GB } }
$metadata = [PSCustomObject]@{ vmId = 'owned'; name = 'Owned'; directory = $owned; profile = 'Configured'; vhdPath = Join-Path $owned 'system.vhdx'; settings = @{ DiskBytes = 80GB } }
$diskMap = @{}
function Get-VHD { param([string] $Path) if (-not $diskMap.ContainsKey($Path)) { throw ('Unknown fixture disk: ' + $Path) }; $diskMap[$Path] }
$diskMap[$metadata.vhdPath] = [PSCustomObject]@{ VhdType = 'Dynamic'; ParentPath = $null; Size = 80GB; Attached = $false }
$child = Join-Path $owned 'child.avhdx'
$diskMap[$child] = [PSCustomObject]@{ VhdType = 'Differencing'; ParentPath = $metadata.vhdPath; Attached = $false }
Assert-VMWorkflow (@(Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $child).Count -eq 2) 'Accept the owned checkpoint disk chain.'
$diskMap[$child].ParentPath = Join-Path $fixture 'foreign.vhdx'
Assert-VMWorkflowFailure { Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $child } 'escapes'
$diskMap[$child].ParentPath = $child
Assert-VMWorkflowFailure { Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $child } 'Cyclic'
Assert-VMWorkflow (@(Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $metadata.vhdPath -AllowMissingDisks).Count -eq 1) 'Permit an absent owned base only for explicit disk replacement.'
$metadata.vhdPath = Join-Path $owned 'unrelated.vhdx'
Assert-VMWorkflowFailure { Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $metadata.vhdPath -AllowMissingDisks } 'not the owned'
$metadata.vhdPath = Join-Path $owned 'system.vhdx'

$vm = [PSCustomObject]@{ Id = 'owned'; Name = 'Owned'; Generation = 2; State = 'Off' }
$drives = @([PSCustomObject]@{ Path = $metadata.vhdPath; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 })
$snapshots = @([PSCustomObject]@{ Id = 'checkpoint'; Name = 'saved' })
$mutations = @()
function Get-VM { param($Id) $vm }
function Get-VMHardDiskDrive { param($VM, $VMSnapshot) $drives }
function Get-VMFirmware { param($VM) [PSCustomObject]@{ SecureBoot = 'On'; SecureBootTemplate = 'MicrosoftWindows' } }
function Get-VMSecurity { param($VM) [PSCustomObject]@{ TpmEnabled = $true } }
function Get-VMNetworkAdapter { param($VM) @() }
function Get-VMSnapshot { param($VM) $snapshots }
function Remove-VMSnapshot { param($VMSnapshot, $Confirm) $script:mutations += 'checkpoint' }
Assert-VMWorkflowFailure { Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' } 'explicitly supply'
Assert-VMWorkflow ($mutations.Count -eq 0) 'Checkpoint refusal precedes any destructive call.'
$vm.State = 'Running'
$fixtureVM = $vm
function Get-VM { param($Id) $fixtureVM }
Assert-VMWorkflowFailure { Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' -DiscardCheckpoints } 'powered-off'
$vm.State = 'Off'
$vm.Name = 'Foreign'
Assert-VMWorkflowFailure { Get-TestVMOwnedMachine -Settings $settings -Metadata $metadata -AllowMissingDisks } 'identity'
$vm.Name = 'Owned'

$restored = @()
function Get-VMNetworkAdapter { param($VM) @([PSCustomObject]@{ Id = 'one' }, [PSCustomObject]@{ Id = 'two' }) }
function Get-VMSwitch { param($Id) if ($Id -eq 'missing') { throw 'Missing switch' }; [PSCustomObject]@{ Name = $Id } }
function Connect-VMNetworkAdapter { param($VMNetworkAdapter, $SwitchName) $script:restored += $VMNetworkAdapter.Id }
Assert-VMWorkflowFailure { Restore-TestVMNetwork -VM $vm -Connections @(@{ Id = 'one'; SwitchId = 'missing' }, @{ Id = 'two'; SwitchId = 'present' }) } 'restoration failed'
Assert-VMWorkflow ($restored -contains 'two') 'One restoration failure must not skip the remaining adapters.'

$reports = Join-Path $fixture '.local\vm-configured'
[IO.Directory]::CreateDirectory($reports) | Out-Null
Set-Content -LiteralPath (Join-Path $reports 'evidence.txt') -Value 'preserve'
$archive = Move-TestVMReports -Settings $settings -Metadata $metadata -Output $reports -Reason 'before-reset'
Assert-VMWorkflow ((Test-Path (Join-Path $archive 'evidence.txt')) -and -not (Test-Path $reports)) 'Archive report evidence before reusing its paths.'
Assert-VMWorkflowFailure { Get-TestVMArchivePath -Settings $settings -Reason 'before-reset' } 'already exists'
Assert-VMWorkflowFailure { Assert-TestVMPath -Path (Join-Path $fixture 'foreign') -Root $owned } 'escapes'
$junction = Join-Path $fixture 'redirect'
New-Item -ItemType Junction -Path $junction -Target $owned | Out-Null
Assert-VMWorkflowFailure { Assert-TestVMPath -Path (Join-Path $junction 'data') -Root $fixture } 'Reparse point'

# Exercise the real entry-point sequencing with synthetic workers and mocked VM APIs.
# Remove only the privileged script header from this fixture; all host operations are mocks.
$entryRoot = Join-Path $repository ('.local\ops\vm-workflow-tests\' + [Guid]::NewGuid().ToString('N'))
foreach ($directory in @('workflows', 'scripts', '.local\vm\owned')) { [IO.Directory]::CreateDirectory((Join-Path $entryRoot $directory)) | Out-Null }
$entryPath = Join-Path $entryRoot 'workflows\test-vm.ps1'
$tokens = $null; $errors = $null
$workflowAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'workflows\test-vm.ps1'), [ref]$tokens, [ref]$errors)
$source = Get-Content -LiteralPath (Join-Path $repository 'workflows\test-vm.ps1') -Raw
$entryGuard = @($workflowAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$MyInvocation.InvocationName -eq ''.'''
})
if ($entryGuard.Count -ne 1) {
    throw 'Expected one public entry-point guard.'
}
$offset = $entryGuard[0].Extent.StartOffset
('[CmdletBinding(SupportsShouldProcess = $true)]' + [Environment]::NewLine + $workflowAst.ParamBlock.Extent.Text.Substring($workflowAst.ParamBlock.Extent.Text.IndexOf('param(')) + [Environment]::NewLine + $source.Substring($offset)) | Set-Content -LiteralPath $entryPath -Encoding UTF8
@'
param([string] $IsoPath, [string] $VMProfile)
function Get-TestVMConfiguration { param($VMProfile) $entrySettings }
'@ | Set-Content -LiteralPath (Join-Path $entryRoot 'scripts\new-test-vm.ps1') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $repository 'scripts\compare-audits.ps1') -Destination (Join-Path $entryRoot 'scripts\compare-audits.ps1')
$entrySettings = @{ root = $entryRoot; directory = Join-Path $entryRoot '.local\vm\owned'; profile = 'Configured'; vm = @{ Name = 'Owned'; DiskBytes = 80GB } }
$entryMetadata = [PSCustomObject]@{ vmId = 'owned'; name = 'Owned'; directory = $entrySettings.directory; profile = 'Configured'; vhdPath = Join-Path $entrySettings.directory 'system.vhdx'; settings = @{ DiskBytes = 80GB } }
$entryMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $entrySettings.directory 'vm.json') -Encoding UTF8
$diskMap[$entryMetadata.vhdPath] = [PSCustomObject]@{ VhdType = 'Dynamic'; ParentPath = $null; Size = 80GB; Attached = $false }
$drives = @([PSCustomObject]@{ Path = $entryMetadata.vhdPath; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 })
$snapshots = @()
$vm.State = 'Running'
$credential = [pscredential]::new('synthetic', [securestring]::new())
$entryMode = 'Fail'
$entryCalls = [Collections.Generic.List[string]]::new()
function Import-Module { param($Name) if ($Name -ne 'Hyper-V') { throw 'Unexpected fixture module import.' } }
function Get-VMNetworkAdapter { param($VM) @([PSCustomObject]@{ Id = 'one'; SwitchId = 'switch'; SwitchName = 'switch' }) }
function Disconnect-VMNetworkAdapter { param($VMNetworkAdapter) $entryCalls.Add('disconnect') }
function Connect-VMNetworkAdapter { param($VMNetworkAdapter, $SwitchName) $entryCalls.Add('restore') }
function Stop-VM { param($VM, $Confirm) $entryCalls.Add('shutdown') }
function Checkpoint-VM { param($VM, $SnapshotName) $entryCalls.Add('checkpoint') }
function Invoke-TestVMCollection {
    param($Settings, $Metadata, $VM, $Output, $ReportName, [pscredential] $Credential, $WaitForGuestSeconds, $Limited)
    if (-not (Test-Path -LiteralPath $Output -PathType Container)) { throw 'The collection output directory was not prepared.' }
    $entryCalls.Add('collect')
    if ($entryMode -eq 'Fail') { throw 'Synthetic collection failure' }
    $path = New-ComparisonFixture $ReportName
    $destination = Join-Path $Output $ReportName
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($entryMode -eq 'NonCompliant') { $report.exitCode = 1; $report.summary.nonCompliant = 1 }
    if ($entryMode -eq 'Mismatch' -and $ReportName -like '*-repeat') { $report.areas.OptionalFeatures.data[0].state = 'Disabled' }
    $path = Join-Path $destination 'audit.json'
    Save-ComparisonFixture $report $path
    [PSCustomObject]@{ reportPath = $path; exitCode = $report.exitCode; summary = $report.summary }
}
$operationPath = Join-Path $entryRoot '.local\workflows\test-vm\configured\operation.json'
Assert-VMWorkflowFailure { & $entryPath -Action Audit -VMProfile Configured -Credential $credential -ReportName failure } 'Synthetic collection failure'
Assert-VMWorkflow (($entryCalls -join ',') -eq 'disconnect,collect,restore') 'The entry point restores networking after failed collection.'
$operation = Get-Content -LiteralPath $operationPath -Raw | ConvertFrom-Json
Assert-VMWorkflow ($operation.status -eq 'Failed') 'A failed collection produces a failed operation record.'
$entryMode = 'NonCompliant'; $entryCalls = [Collections.Generic.List[string]]::new()
Assert-VMWorkflowFailure { & $entryPath -Action Audit -VMProfile Configured -Credential $credential -ReportName mismatch } 'configuration mismatches'
$operation = Get-Content -LiteralPath $operationPath -Raw | ConvertFrom-Json
Assert-VMWorkflow ($operation.status -eq 'NonCompliant' -and $operation.reports[0].exitCode -eq 1) 'Collection success remains distinct from compliance.'
$entryMode = 'Mismatch'; $entryCalls = [Collections.Generic.List[string]]::new()
Assert-VMWorkflowFailure { & $entryPath -Action Capture -VMProfile Configured -Credential $credential } 'inventories differ'
Assert-VMWorkflow (-not ($entryCalls -contains 'shutdown') -and -not ($entryCalls -contains 'checkpoint') -and $entryCalls[-1] -eq 'restore') 'Unstable capture preserves guest state and creates no checkpoint.'

Move-TestVMReports -Settings $entrySettings -Metadata $entryMetadata -Output (Join-Path $entryRoot '.local\vm-configured') -Reason 'before-stable-fixture' | Out-Null
$entryMode = 'Match'; $entryCalls = [Collections.Generic.List[string]]::new()
$fixtureSnapshots = [Collections.Generic.List[object]]::new()
$fixtureDVD = [PSCustomObject]@{ Path = 'synthetic.iso' }
function Get-VMSnapshot { param($VM) $fixtureSnapshots.ToArray() }
function Get-VMDvdDrive { param($VM) $fixtureDVD }
function Set-VMDvdDrive { param($VMDvdDrive, $Path) $VMDvdDrive.Path = $Path }
function Set-VMFirmware { param($VM, $FirstBootDevice) if ($args.Count) { throw 'Unexpected firmware security change.' } }
function Set-VMKeyProtector { throw 'An initialized key protector must never be changed.' }
function Enable-VMTPM { throw 'An initialized TPM must never be reconfigured.' }
function Stop-VM { param($VM, $Confirm) $VM.State = 'Off'; $entryCalls.Add('shutdown') }
function Checkpoint-VM { param($VM, $SnapshotName) $fixtureSnapshots.Add([PSCustomObject]@{ Id = 'audited'; Name = $SnapshotName }); $entryCalls.Add('checkpoint') }
& $entryPath -Action Capture -VMProfile Configured -Credential $credential | Out-Null
$operation = Get-Content -LiteralPath $operationPath -Raw | ConvertFrom-Json
Assert-VMWorkflow ($operation.status -eq 'Succeeded' -and $fixtureVM.State -eq 'Off' -and $null -eq $fixtureDVD.Path) 'Stable capture finishes with detached media and a powered-off guest.'
Assert-VMWorkflow (($entryCalls -join ',') -eq 'disconnect,collect,collect,shutdown,checkpoint,restore') 'Stable capture checks both reports before shutdown and checkpoint creation, then restores networking.'

# Successful disk replacement touches only the owned fixture file and mocked VM APIs.
$vm.State = 'Off'; $fixtureDVD.Path = 'source.iso'
$fixtureSnapshots.Clear()
function Get-VMNetworkAdapter { param($VM) @() }
$replacementCalls = [Collections.Generic.List[string]]::new()
function Remove-VMHardDiskDrive { param($VMHardDiskDrive, $Confirm) $replacementCalls.Add('detach') }
function New-VHD { param($Path, $SizeBytes, [switch]$Dynamic) Set-Content -LiteralPath $Path -Value 'new synthetic disk'; $replacementCalls.Add('create') }
function Add-VMHardDiskDrive { param($VM, $ControllerType, $ControllerNumber, $ControllerLocation, $Path) $replacementCalls.Add('attach') }
$fixtureDVD.Path = 'source.iso'
Set-Content -LiteralPath $metadata.vhdPath -Value 'old synthetic disk'
$drives = @([PSCustomObject]@{ Path = $metadata.vhdPath; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 })
Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso'
Assert-VMWorkflow (($replacementCalls -join ',') -eq 'detach,create,attach' -and (Get-Content -LiteralPath $metadata.vhdPath -Raw) -like 'new synthetic disk*') 'Reinstall replaces the owned base file while preserving initialized VM security.'
$beforeDisk = Get-Content -LiteralPath $metadata.vhdPath -Raw
$replacementCalls.Clear()
Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' -CheckOnly
Assert-VMWorkflow ($replacementCalls.Count -eq 0 -and (Get-Content -LiteralPath $metadata.vhdPath -Raw) -ceq $beforeDisk) 'Reinstall preflight does not change the system disk.'

function Get-VMProcessor { param($VM) [PSCustomObject]@{ Count = 2; ExposeVirtualizationExtensions = $true } }
function Get-VMMemory { param($VM) [PSCustomObject]@{ Startup = 4GB; DynamicMemoryEnabled = $false } }
$drives = @([PSCustomObject]@{ Path = $entryMetadata.vhdPath; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 })
$diskMap.Remove($entryMetadata.vhdPath)
& $entryPath -Action Inspect -VMProfile Configured | Out-Null
$inspection = Get-Content -LiteralPath (Join-Path $entryRoot '.local\workflows\test-vm\configured\inspection.json') -Raw | ConvertFrom-Json
Assert-VMWorkflow ($inspection.issues.Count -gt 0 -and $inspection.guestAccess -eq 'NotRequested' -and $inspection.actual.id -eq 'owned') 'Inspect reports a missing or unreadable disk while retaining actual VM identity.'
$beforeWhatIf = (Get-FileHash -LiteralPath $operationPath).Hash
& $entryPath -Action Prepare -VMProfile Configured -WhatIf | Out-Null
Assert-VMWorkflow ((Get-FileHash -LiteralPath $operationPath).Hash -ceq $beforeWhatIf) 'WhatIf preserves the previous operation record and performs no worker action.'

# A missing Hyper-V system delta remains owned by its recorded controller and VM directory.
$missingDelta = Join-Path $owned 'system_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.avhdx'
$resetAttachments = [Collections.Generic.List[object]]::new()
$resetAttachments.Add([PSCustomObject]@{ Path = $missingDelta; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 })
$snapshotDrive = [PSCustomObject]@{ Path = $metadata.vhdPath; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 }
function Get-VMHardDiskDrive { param($VM, $VMSnapshot) if ($VMSnapshot) { $snapshotDrive } else { $resetAttachments.ToArray() } }
function Remove-VMHardDiskDrive { param($VMHardDiskDrive, $Confirm) $resetAttachments.Clear(); $replacementCalls.Add('detach') }
function Add-VMHardDiskDrive { param($VM, $ControllerType, $ControllerNumber, $ControllerLocation, $Path) $resetAttachments.Add([PSCustomObject]@{ Path = $Path; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 }); $replacementCalls.Add('attach') }
$fixtureSnapshots.Add([PSCustomObject]@{ Id = 'broken'; Name = 'broken-checkpoint' })
$replacementCalls.Clear()
$checkpointDeletes = [Collections.Generic.List[string]]::new()
function Remove-VMSnapshot {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $VMSnapshot, [switch] $Confirm)
    process {
        if ($resetAttachments.Count) { throw 'The missing active disk must be detached before checkpoint deletion.' }
        $checkpointDeletes.Add([string]$VMSnapshot.Id); $fixtureSnapshots.Clear()
    }
}
Assert-VMWorkflowFailure { Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $missingDelta } 'Unknown fixture disk'
Assert-VMWorkflow (@(Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $missingDelta -AllowMissingDisks).Count -eq 2) 'Only reinstall may accept a missing owned system delta and still validate its base.'
Assert-VMWorkflowFailure { Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' } 'explicitly supply'
Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' -DiscardCheckpoints -CheckOnly
Assert-VMWorkflow ($checkpointDeletes.Count -eq 0 -and $replacementCalls.Count -eq 0) 'Broken-chain preflight leaves checkpoints and disk files intact.'
Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' -DiscardCheckpoints
Assert-VMWorkflow ($checkpointDeletes.Count -eq 1 -and ($replacementCalls -join ',') -eq 'detach,create,attach' -and -not (Test-Path -LiteralPath $missingDelta)) 'Reinstall discards the stale checkpoint and replaces the base without inventing missing deltas.'
Assert-VMWorkflowFailure { Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path (Join-Path $owned 'unrelated.avhdx') -AllowMissingDisks } 'not an owned system'
Assert-VMWorkflowFailure { Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path (Join-Path $fixture 'system_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.avhdx') -AllowMissingDisks } 'escapes'
$diskMap[$metadata.vhdPath].ParentPath = Join-Path $fixture 'foreign.vhdx'
Assert-VMWorkflowFailure { Get-TestVMDiskChain -Settings $settings -Metadata $metadata -Path $missingDelta -AllowMissingDisks } 'base disk differs'
$diskMap[$metadata.vhdPath].ParentPath = $null

$validationSettings = @{ root = $fixture; source = @{ selectedImage = @{ version = '10.0.12345.678' } } }
$validationWim = Join-Path $fixture '.local\catalog\pro-12345.678\pro.wim'
[IO.Directory]::CreateDirectory((Split-Path $validationWim -Parent)) | Out-Null
Set-Content -LiteralPath $validationWim -Value 'synthetic source WIM'
Assert-VMWorkflow ((Get-TestVMValidationWim -Settings $validationSettings) -ieq $validationWim) 'Resolve the default catalog by build and revision, without the OS version prefix.'
Assert-VMWorkflowFailure { Get-TestVMValidationWim -Settings $validationSettings -Path (Join-Path $fixture 'missing.wim') } 'does not exist*prepare-source.ps1'

$resetAttachments.Clear()
$resetAttachments.Add([PSCustomObject]@{ Path = $missingDelta; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 })
$fixtureSnapshots.Add([PSCustomObject]@{ Id = 'interrupted'; Name = 'interrupted-checkpoint' })
function Remove-VMSnapshot {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $VMSnapshot, [switch] $Confirm)
    process { throw 'Synthetic checkpoint removal failure' }
}
$beforeFailure = (Get-FileHash -LiteralPath $metadata.vhdPath).Hash
Assert-VMWorkflowFailure { Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' -DiscardCheckpoints } 'Synthetic checkpoint removal failure'
Assert-VMWorkflow ($resetAttachments.Count -eq 0 -and (Get-FileHash -LiteralPath $metadata.vhdPath).Hash -ceq $beforeFailure) 'A failed checkpoint discard leaves the base file intact and the missing attachment detached.'
Assert-VMWorkflowFailure { Get-TestVMOwnedMachine -Settings $settings -Metadata $metadata } 'attachment differs'
Get-TestVMOwnedMachine -Settings $settings -Metadata $metadata -AllowMissingDisks | Out-Null
function Remove-VMSnapshot {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $VMSnapshot, [switch] $Confirm)
    process { $fixtureSnapshots.Clear() }
}
Reset-TestVMSystemDisk -Settings $settings -Metadata $metadata -VM $vm -IsoPath 'source.iso' -DiscardCheckpoints
Assert-VMWorkflow ($resetAttachments.Count -eq 1 -and $resetAttachments[0].Path -ieq $metadata.vhdPath -and $fixtureSnapshots.Count -eq 0) 'Reinstall resumes after disk detachment without recreating the VM or fabricating missing delta files.'
# Removal fixtures use a separate owned tree and synthetic Hyper-V identities.
$removalRoot = Join-Path $repository ('.local\ops\vm-removal-tests\' + [guid]::NewGuid().ToString('N'))
$removalDirectory = Join-Path $removalRoot '.local\vm\windows11-pro-configured'
$retainedDirectory = Join-Path $removalRoot '.local\vm\windows11-pro'
foreach ($path in @($removalDirectory, $retainedDirectory, (Join-Path $removalRoot 'workflows'), (Join-Path $removalRoot 'scripts'), (Join-Path $removalRoot '.local\vm-configured'))) { [IO.Directory]::CreateDirectory($path) | Out-Null }
$removalId = [guid]::NewGuid()
$retainedId = [guid]::NewGuid()
$removalMachines = [Collections.Generic.List[object]]::new()
$removalVM = [PSCustomObject]@{ Id = $removalId; Name = 'Synthetic-Configured'; Generation = 2; State = 'Off'; Path = $removalDirectory }
$retainedVM = [PSCustomObject]@{ Id = $retainedId; Name = 'Synthetic-Baseline'; Generation = 2; State = 'Off'; Path = $retainedDirectory }
$removalMachines.Add($removalVM); $removalMachines.Add($retainedVM)
$removalMetadata = [PSCustomObject]@{ schemaVersion = 1; vmId = [string]$removalId; name = $removalVM.Name; directory = $removalDirectory; profile = 'Configured'; status = 'Created'; vhdPath = Join-Path $removalDirectory 'system.vhdx'; settings = @{ DiskBytes = 80GB }; isoPath = Join-Path $removalRoot 'source.iso' }
$removalSettings = @{ root = $removalRoot; directory = $removalDirectory; profile = 'Configured'; vm = @{ Name = $removalVM.Name } }
$removalMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $removalDirectory 'vm.json') -Encoding UTF8
Set-Content -LiteralPath $removalMetadata.vhdPath -Value 'synthetic disk'
Set-Content -LiteralPath (Join-Path $retainedDirectory 'retain.txt') -Value 'baseline evidence'
Set-Content -LiteralPath $removalMetadata.isoPath -Value 'source media'
$retainedReport = Join-Path $removalRoot '.local\vm-configured\evidence.json'
Set-Content -LiteralPath $retainedReport -Value 'audit evidence'
$seed = Join-Path $removalDirectory 'answer.iso'
Set-Content -LiteralPath $seed -Value 'synthetic answer media'
$removalDrive = [PSCustomObject]@{ Path = $removalMetadata.vhdPath; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 }
$removalSnapshots = [Collections.Generic.List[object]]::new()
$removalSnapshots.Add([PSCustomObject]@{ Id = [guid]::NewGuid(); Name = 'synthetic-checkpoint' })
$extraRemovalDrives = @(); $foreignRemovalDrives = @(); $foreignRemovalMedia = @()
$removeVMCalls = [Collections.Generic.List[string]]::new()
$failUnregister = $false
$removalDisks = @{ }
$removalDisks[$removalMetadata.vhdPath] = [PSCustomObject]@{ VhdType = 'Dynamic'; ParentPath = $null; Size = 80GB; Attached = $false }
function Get-VM { [CmdletBinding()] param($Id) if ($Id) { $removalMachines.ToArray() | Where-Object { $_.Id -eq $Id } } else { $removalMachines.ToArray() } }
function Get-VMSnapshot { param($VM) if ($VM.Id -eq $removalId) { $removalSnapshots.ToArray() } }
function Get-VMHardDiskDrive { param($VM, $VMSnapshot) if ($VMSnapshot -or $VM.Id -eq $removalId) { @($removalDrive) + $extraRemovalDrives } else { $foreignRemovalDrives } }
function Get-VMDvdDrive { param($VM, $VMSnapshot) if ($VM -and $VM.Id -eq $retainedId) { $foreignRemovalMedia } }
function Get-VHD { [CmdletBinding()] param([string] $Path) if (-not $removalDisks.ContainsKey($Path)) { throw 'Unexpected removal fixture disk.' }; $removalDisks[$Path] }
function Remove-VM { param($VM, [switch]$Force, $Confirm, $ErrorAction) $removeVMCalls.Add([string]$VM.Id); if ($failUnregister) { throw 'Synthetic unregister failure' }; [void]$removalMachines.Remove($VM) }
Assert-VMWorkflowFailure { Assert-TestVMActionParameters @{ Action = 'Remove' } } 'explicit -VMProfile'
Assert-VMWorkflowFailure { Assert-TestVMActionParameters @{ Action = 'Remove'; VMProfile = 'Configured'; Credential = $credential } } 'does not apply'
Assert-TestVMActionParameters @{ Action = 'Remove'; VMProfile = 'Configured'; DiscardCheckpoints = $true }
$removalVM.State = 'Running'
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'powered-off'
$removalVM.State = 'Off'
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata } 'explicitly supply'
$removalMetadata.vmId = [string][guid]::NewGuid()
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'not owned'
$removalMetadata.vmId = [string]$removalId
$extraRemovalDrives = @([PSCustomObject]@{ Path = $removalMetadata.vhdPath; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 1 })
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'additional disks'
$extraRemovalDrives = @()
$foreignRemovalDrives = @($removalDrive)
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'Another VM references a disk'
$foreignDisk = Join-Path $removalRoot 'foreign.vhdx'
Set-Content -LiteralPath $foreignDisk -Value 'synthetic foreign child'
$removalDisks[$foreignDisk] = [PSCustomObject]@{ ParentPath = $removalMetadata.vhdPath }
$foreignRemovalDrives = @([PSCustomObject]@{ Path = $foreignDisk })
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'Another VM references a disk'
$foreignRemovalDrives = @()
$foreignRemovalMedia = @([PSCustomObject]@{ Path = $seed })
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'Another VM references media'
$foreignRemovalMedia = @()
$removalDisks[$removalMetadata.vhdPath].Attached = $true
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'mounted virtual disk'
$removalDisks[$removalMetadata.vhdPath].Attached = $false
$removalJunction = Join-Path $removalDirectory 'redirect'
New-Item -ItemType Junction -Path $removalJunction -Target $retainedDirectory | Out-Null
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'Reparse point'
[IO.Directory]::Delete($removalJunction, $false)
Assert-VMWorkflow ((Test-Path (Join-Path $retainedDirectory 'retain.txt')) -and $removeVMCalls.Count -eq 0) 'Reparse refusal preserves the registration and the junction target.'
$plan = Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints -CheckOnly
Assert-VMWorkflow ($plan.checkpoints.Count -eq 1 -and $removeVMCalls.Count -eq 0 -and (Test-Path $seed)) 'Removal preflight preserves VM registration, checkpoint metadata, and files.'
$failUnregister = $true
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $removalMetadata -DiscardCheckpoints } 'Synthetic unregister failure'
Assert-VMWorkflow ((Test-Path $removalMetadata.vhdPath) -and (Test-Path (Join-Path $removalDirectory 'vm.json'))) 'Failed unregister never deletes storage or ownership metadata.'
$failUnregister = $false

# Exercise the public Remove action with the same isolated entry-point fixture.
Copy-Item -LiteralPath $entryPath -Destination (Join-Path $removalRoot 'workflows\test-vm.ps1')
Copy-Item -LiteralPath (Join-Path $entryRoot 'scripts\new-test-vm.ps1'), (Join-Path $entryRoot 'scripts\compare-audits.ps1') -Destination (Join-Path $removalRoot 'scripts')
$entrySettings = $removalSettings
$removalEntry = Join-Path $removalRoot 'workflows\test-vm.ps1'
$callsBeforeWhatIf = $removeVMCalls.Count
& $removalEntry -Action Remove -VMProfile Configured -DiscardCheckpoints -WhatIf | Out-Null
Assert-VMWorkflow ($removeVMCalls.Count -eq $callsBeforeWhatIf -and (Test-Path $removalDirectory)) 'WhatIf performs no unregister or storage deletion.'
& $removalEntry -Action Remove -VMProfile Configured -DiscardCheckpoints | Out-Null
$removedOperation = Get-Content -LiteralPath (Join-Path $removalRoot '.local\workflows\test-vm\configured\operation.json') -Raw | ConvertFrom-Json
Assert-VMWorkflow ($removedOperation.status -eq 'Succeeded' -and $removedOperation.vmId -eq [string]$removalId -and -not (Test-Path $removalDirectory)) 'Remove records the owned VM ID and deletes its working directory.'
Assert-VMWorkflow ((Test-Path $retainedReport) -and (Test-Path $removalMetadata.isoPath) -and (Test-Path (Join-Path $retainedDirectory 'retain.txt')) -and $removalMachines.Count -eq 1) 'Remove preserves audit evidence, source media, and the other VM.'
$callsBeforeRepeat = $removeVMCalls.Count
& $removalEntry -Action Remove -VMProfile Configured | Out-Null
Assert-VMWorkflow ($removeVMCalls.Count -eq $callsBeforeRepeat -and -not (Test-Path $removalDirectory)) 'Removing an already absent profile is a safe no-op.'
[IO.Directory]::CreateDirectory($removalDirectory) | Out-Null
$removalMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $removalDirectory 'vm.json') -Encoding UTF8
Set-Content -LiteralPath $seed -Value 'remaining owned answer media'
& $removalEntry -Action Remove -VMProfile Configured | Out-Null
Assert-VMWorkflow (-not (Test-Path $removalDirectory) -and $removeVMCalls.Count -eq $callsBeforeRepeat) 'A retry cleans an already unregistered owned directory without touching another VM.'
[IO.Directory]::CreateDirectory($removalDirectory) | Out-Null
Set-Content -LiteralPath $seed -Value 'unowned data'
Assert-VMWorkflowFailure { Remove-TestVMResources -Settings $removalSettings -Metadata $null } 'ownership metadata'
Assert-VMWorkflow (Test-Path $seed) 'An unowned leftover directory is never deleted.'

$baselineMetadata = [PSCustomObject]@{ schemaVersion = 1; vmId = [string]$retainedId; name = $retainedVM.Name; directory = $retainedDirectory; status = 'Created'; vhdPath = Join-Path $retainedDirectory 'system.vhdx'; settings = @{ DiskBytes = 80GB } }
$baselineSettings = @{ root = $removalRoot; directory = $retainedDirectory; profile = 'Baseline'; vm = @{ Name = $retainedVM.Name } }
$baselineMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $retainedDirectory 'vm.json') -Encoding UTF8
Remove-TestVMResources -Settings $baselineSettings -Metadata $baselineMetadata | Out-Null
Assert-VMWorkflow (-not (Test-Path $retainedDirectory) -and $removalMachines.Count -eq 0 -and (Test-Path $retainedReport)) 'Baseline removal proves ownership from ID, name, and paths without requiring a redundant profile field.'
Write-Output ("Passed $checks VM workflow checks without changing a real VM.")
