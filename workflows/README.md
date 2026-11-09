# Operator workflows

Main operational scenarios live in this directory; supporting implementations remain in [scripts](../scripts/README.md). Workflows target Windows x64. Run them directly from a 64-bit PowerShell terminal and use an elevated terminal for privileged operations. Workflows never request elevation internally.

All workflows announce major operations before they start, including long waits and cleanup. Timestamped messages keep ordinary text white and highlight status tags and data such as paths and outcomes: cyan for stages, green for success, yellow for warnings, and red for failures. Text labels remain readable without color. The shared [console helper](../scripts/workflow-output.ps1) writes to the host information stream without adding messages to returned result objects. Direct invocation shows messages in the current terminal. Reports remain the detailed execution record.

For a checkout with configuration and locks already prepared, including after deleting `.local`, follow `prepare-tools` -> `prepare-source` -> `build` -> configured VM verification. Baseline VM verification is a separate source/audit test and is not a runtime prerequisite for the configured profile. The [build plan](../docs/build-plan.md) gives the commands and native Setup/OOBE handoffs. Generated source catalogs do not require reselecting a ready profile.

## Prepare tools

[prepare-tools.ps1](prepare-tools.ps1) manages ADK, WinPE optional components, and LGPO from [toolchain.lock.json](../config/toolchain.lock.json). Select `-Tool Adk`, `WinPE`, `Lgpo`, or `All`, and explicitly choose `-Action Download`, `Install`, `Check`, or `Remove`. The workflow never changes the lock or selects a newer release.

Tool preparation announces download verification, offline layout preparation and hashing, installation, extraction, and removal. Vendor installer stages show the diagnostic log path while the workflow waits for the process to finish.

| Action | Purpose |
| --- | --- |
| `Download` | Reuse matching cached bootstrapper/archive files or download replacements into verified temporary files. ADK and WinPE run the pinned vendor bootstrapper to prepare an offline layout, then record every layout file's hash. |
| `Install` | Reuse matching installed tools. Otherwise install the selected ADK features from its verified offline layout, administratively extract WinPE packages into the managed tool directory, or extract the pinned LGPO archive. Verify the resulting locked files. |
| `Check` | Verify installed ADK files, prepared WinPE CABs, and LGPO against their fingerprints. LGPO also requires a valid Microsoft signature. Check does not download or install tools. |
| `Remove` | Uninstall the locked ADK features and any registered matching WinPE add-on through verified Microsoft installers, then delete the selected tool's download cache and managed extraction directory. |

```powershell
.\workflows\prepare-tools.ps1 -Action Check -Tool All
.\workflows\prepare-tools.ps1 -Action Download -Tool All
.\workflows\prepare-tools.ps1 -Action Install -Tool All
```

Check and LGPO operations do not require elevation. ADK/WinPE Download, Install, and Remove require an elevated 64-bit PowerShell terminal on Windows because they may invoke the vendor installer or MSI infrastructure. This mixed entry point checks privileges for the chosen action before making changes; it does not self-elevate. The [Microsoft offline-install instructions](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-offline-install) describe vendor layouts and silent installation. Layout download does not combine `/layout` with `/features`; selected ADK features are applied during Install.

Downloads remain under `.local/downloads`. Layout receipts are generated beside their layouts and bind the file set to the pinned bootstrapper. Install validates those receipts before invoking cached installers. Missing, changed, or untrusted cache inputs require Download again; Install does not silently acquire them. A matching installation can be reused without a cached installer. Installer failures and restart-required results stop the operation; the workflow never restarts the host automatically.

WinPE is prepared as local optional-component CABs, not installed as a host WinPE add-on. LGPO and WinPE extraction replace only their guarded directories under `.local/tools` when the locked outputs differ. Download caches remain separate from those directories. Reparse points, unsafe archive paths, and concurrent preparation runs are refused. ADK installation stays under the Windows installer; project cleanup never recursively removes its system installation directory.

Remove checks every selected target before making changes and refuses registered versions that differ from the lock. Host removal requires a bootstrapper with the locked hash and a valid Microsoft signature, found in the download cache, offline layout, or registered bundle cache. If none is available, restore it with Download first. ADK removal passes the locked feature selection to the [vendor uninstaller](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-8.1-and-8/dn621910(v=win.10)); other ADK features can remain installed. All removes WinPE before ADK. A failed or incomplete uninstall retains that tool's local cache for diagnosis and retry; earlier completed removals are recorded and are not rolled back.

Local cleanup covers only the selected tool directories under `.local/downloads` and `.local/tools`. Source Windows ISOs, generated WIM/ISO images, VMs, configuration, and reports remain available. Removal does not disable Windows features or change the host OS component selection. Installer logs remain under `.local/workflows/prepare-tools/logs`. An already absent tool can be removed again without running its uninstaller.

```powershell
.\workflows\prepare-tools.ps1 -Action Remove -Tool All -WhatIf
.\workflows\prepare-tools.ps1 -Action Remove -Tool All
```

The result is `.local/workflows/prepare-tools/operation.json`. It records the lock fingerprint, selected action, per-tool outcome, and checked files. `AlreadyPresent` means verification succeeded without reinstalling. Tool preparation precedes builds and VM scenarios; the build workflow does not invoke installers implicitly. `-WhatIf` previews the chosen action without writing a result.

## Prepare source

[prepare-source.ps1](prepare-source.ps1) accepts `-IsoPath` and prepares the source artifacts from [source-image.lock.json](../config/source-image.lock.json) using the already prepared ADK in [toolchain.lock.json](../config/toolchain.lock.json). Run it from an elevated 64-bit PowerShell terminal on Windows:

```powershell
.\workflows\prepare-source.ps1 -IsoPath 'D:\temp\windows.iso'
```

The workflow runs [export-image-catalog.ps1](../scripts/export-image-catalog.ps1) in a fresh process. That worker verifies the ISO fingerprint and locked ADK binaries, checks the selected source image, exports `pro.wim`, mounts it read-only, and generates `catalog.json` and the fully commented `selections.psd1` together. The working directory under `.local/catalog` is derived from the selected image's build and revision. The VM workflow resolves the same `pro.wim` for Windows SIM validation; it does not recreate the source artifacts implicitly.

Each invocation recreates the exporter's guarded working directory. Active exports, registered image mounts, unsafe paths, and source files inside output or lock paths are refused. Only the worker's own ISO attachment and WIM mount are detached or unmounted; an ISO already attached by the operator remains attached. WIM, catalog, template, and raw DISM diagnostics stay local. Follow the [configuration guide](../config/README.md#complete-image-catalog) when deliberately refreshing reviewed catalog files in Git.

The coordinator requires a successful worker exit, a fresh completed report, successful image cleanup, all source artifacts, matching catalog identity, and a loadable commented template. Its result is `.local/workflows/prepare-source/operation.json`, which identifies the artifact paths and worker report. Input lock changes during preparation fail verification. Concurrent source-preparation workflows are refused. The workflow does not select a new image, rewrite locks, copy generated files into tracked configuration, install tools, build configured media, or create a VM.

Run `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/prepare-source.tests.ps1` to check orchestration with synthetic exporters and artifacts, without DISM or host image changes. This checks workflow code separately from the manual build/install verification sequence.

## Build

[build.ps1](build.ps1) runs the existing WIM and ISO builders in fresh worker processes on Windows x64. Every stage requires administrator privileges, declared with `#Requires -RunAsAdministrator`. It requires prepared tools and the selected source ISO; configuration and fingerprints come from the existing configuration and locks. It does not prepare tools or manage VMs.

From the repository root, using the source location recorded in the [build plan](../docs/build-plan.md):

```powershell
.\workflows\build.ps1 -IsoPath 'D:\temp\windows.iso' -Stage All
```

Select `-Stage Image` to build only the configured WIM, or `-Stage Media` to package an already verified WIM. Media packaging retains the WIM by default. Add `-Compress` only for an explicit final ESD export; it is rejected for an image-only build.

Each worker retains its existing guarded output cleanup, input checks, artifact verification, and reports. The workflow stops on a failed worker process, a failed or stale worker report, incomplete cleanup, or a missing artifact. Its own result references those reports in `.local/workflows/build/operation.json`; concurrent invocations are refused. It does not replace independent installation and update verification.

The coordinator relays build-worker host messages to preserve both console colors and transcript capture. Messages distinguish image servicing, media packaging, output verification, and cleanup; the coordinator prints the relevant DISM log and verified artifact paths.

When a failed worker produces a fresh completed report, the workflow includes its stage, original error, cleanup errors, and report path in the final failure message. The workflow report also preserves the worker's structured error details when available. An older report is never used as the cause of a new process failure. See the [worker diagnostics](../scripts/README.md#build-the-configured-image) for native compiler and packaging logs.

## Test VM

[test-vm.ps1](test-vm.ps1) coordinates the existing VM creator, Windows SIM validator, and independent audit. Run it from an elevated 64-bit PowerShell terminal on Windows. Every action requires administrator privileges, declared with `#Requires -RunAsAdministrator`. VM settings come from [test-vm.psd1](../config/test-vm.psd1), and existing machines are addressed by their recorded ownership metadata. The baseline uses private test answer media; the configured profile uses only the integrated deployment ISO and native OOBE.

| Action | Purpose |
| --- | --- |
| `Inspect` | Read metadata and actual disk, media, network, security, resource, and checkpoint state, including partial preparation. Guest inspection uses the private baseline credential or an explicit configured `-Credential`; unavailable access is recorded. |
| `Prepare` | Create a missing VM, validate its answer and hardware, then start native Setup. Supply `-IsoPath` for the baseline source. The configured profile defaults to the built ISO. `-WimPath` can select the matching source catalog WIM for Windows SIM. |
| `Reinstall` | Replace the powered-off configured VM's owned system disk, validate, and start Setup. Preserve the VM ID, initialized TPM, and firmware security settings. Accept missing base, Hyper-V system-delta files, or an absent disk attachment only for the recorded VM and owned paths; existing checkpoints still require explicit discard. |
| `Start` | Start an already prepared and freshly validated installation with an empty disk. |
| `Capture` | Collect repeated complete audits, verify repeatability, shut down gracefully, detach installation media, and create the audited checkpoint. Configured audits must also pass compliance. |
| `Audit` | Collect a separate installed-system report. `-CompareTo` adds drift comparison against an earlier report from the same VM and inputs. `-RestartBefore` explicitly requests a normal guest restart and verifies a later boot before collection. |
| `Limited` | Run the existing restricted-token audit check while preserving the recorded checkpoint. The generated guest launcher is a readable script file. |
| `Remove` | Unregister the powered-off owned VM and delete only its profile's VM working directory, including disks and private baseline answer media. Select `-VMProfile` explicitly; existing checkpoints require `-DiscardCheckpoints`. |

For example, from an elevated terminal at the repository root:

```powershell
.\workflows\test-vm.ps1 -Action Inspect -VMProfile Configured
.\workflows\test-vm.ps1 -Action Prepare -VMProfile Configured
```

Prepare refuses existing VMs or working directories. To repeat installation in the existing configured VM, first inspect its checkpoints and power it off. Reinstall isolates its network before Setup; original connections are recorded and restored if the operation fails. Successful installation handoff remains disconnected. Use an explicit archive label to preserve existing host reports. Supply `-DiscardCheckpoints` only when intentionally discarding the listed configured checkpoints; the script refuses checkpoint removal without it. Reinstallation archives existing host evidence before replacing the disk and can resume after that evidence was already archived by an interrupted attempt. Neither disk reset nor inspection reapplies a key protector or Secure Boot template.

Missing files do not prove a healthy disk chain. Only Reinstall permits the recorded base path or missing Hyper-V `system_<GUID>.avhdx` paths within the VM directory, as a destructive reset of the disposable installation. Readable parent chains must still resolve inside that directory, and other VM and checkpoint references are checked before replacement. A missing active disk is detached before deleting its checkpoints, so the discarded installation does not require merging the missing delta. Checkpoint metadata is removed through Hyper-V; the script does not synthesize missing delta contents or edit VM configuration files directly. If checkpoint deletion fails after detachment, the same command can resume with no attached disk. Other checkpoint-deletion failures stop the operation with evidence recorded.

The Windows SIM source WIM is resolved and checked before preparation or disk reset. Run [prepare-source.ps1](prepare-source.ps1) first, including when `.local` has been deleted. Its default catalog directory uses the build and revision from the source lock. `-WimPath` explicitly selects another matching exported source WIM.

The [SIM validator](../scripts/validate-vm-setup.ps1) runs its .NET Framework API in an isolated built-in Windows PowerShell worker as needed; the workflow keeps the caller's PowerShell runtime. Paths and the profile are passed as data, and a fresh passing JSON report is required. Worker messages are relayed to the console, with a transcript in `worker.log` beside the validation report. If preparation stops during validation after VM creation, repeat the validator for that VM and source WIM, then use `-Action Start` to continue without replacing its disk.

```powershell
.\workflows\test-vm.ps1 -Action Reinstall -VMProfile Configured -ArchiveReason before-next-install -DiscardCheckpoints
```

Console opening requires explicit `-OpenConsole` for Prepare, Reinstall, or Start. The operator handles the DVD boot prompt, OOBE, and sign-in. Configured guest credentials are supplied explicitly and are never read from previous launch parameters:

```powershell
.\workflows\test-vm.ps1 -Action Capture -VMProfile Configured -Credential (Get-Credential -Message 'Local administrator created in configured OOBE')
.\workflows\test-vm.ps1 -Action Audit -VMProfile Configured -Credential (Get-Credential -Message 'Local administrator created in configured OOBE') -ReportName after-update -CompareTo .local/vm-configured/configured-repeat/audit.json
.\workflows\test-vm.ps1 -Action Audit -VMProfile Configured -Credential (Get-Credential -Message 'Local administrator created in configured OOBE') -ReportName after-update-reboot -RestartBefore -CompareTo .local/vm-configured/configured-repeat/audit.json
```

Audit and Capture isolate configured networking by default, recording original attachments before disconnecting and restoring every attachment in `finally`. `-NetworkMode Preserve` explicitly keeps current connections. Baseline collection remains disconnected. Updates are installed normally by the operator, outside the workflow. `-WaitForGuestSeconds` bounds guest-readiness and restart polling; a heartbeat alone does not prove completed OOBE or successful authentication.

Audit labels and checkpoints are never silently replaced. Capture can use `-ArchiveReason <label>` to preserve prior host and owned guest reports before reusing its labels. Archive labels are stable caller-supplied names; collisions are refused. Archives remain under `.local/diagnostics`, and guest archives stay inside the marked project working directory. Existing audited checkpoints require a separate Audit or explicit configured reinstallation.

Operation and host-inspection records are written under `.local/workflows/test-vm/<profile>`. Audit reports remain under `.local/vm-baseline` or `.local/vm-configured`, with collection receipts, comparison evidence, and checkpoint identity. The operation distinguishes failed collection from completed but noncompliant Audit results; either produces a failing command. A baseline Capture may retain expected source-default mismatches. Concurrent workflow actions for the same profile are refused.

VM messages distinguish ownership checks, preparation, Windows SIM validation, Setup/OOBE handoff, guest readiness and restart waits, audit execution, report copying and comparison, checkpoint creation, and network restoration. A successful Setup handoff means the VM has started; the operator still completes native Setup and OOBE in its console. Completion messages identify the operation report, including actions that return immediately after inspection, removal, or installation handoff.

To remove a test VM, select its profile explicitly and power it off first. Use `-WhatIf` to preview the action; `-Confirm` requests standard PowerShell confirmation. Remove refuses an unexpected VM identity, disks outside the owned profile, mounted virtual disks, reparse points, and resources referenced by another VM or its checkpoints. Existing audit reports, validation reports, diagnostic archives, tools, and external installation media remain available. Baseline private answer media and credentials inside the deleted VM directory are removed with it.

```powershell
.\workflows\test-vm.ps1 -Action Remove -VMProfile Configured -DiscardCheckpoints -WhatIf
.\workflows\test-vm.ps1 -Action Remove -VMProfile Configured -DiscardCheckpoints -Confirm
```

The workflow records the removal target and ownership metadata before unregistering the VM with [Remove-VM](https://learn.microsoft.com/en-us/powershell/module/hyper-v/remove-vm). It then removes the owned files, retaining `vm.json` until the remaining contents are gone so interrupted cleanup can be retried. The same command accepts an already unregistered owned directory or an already absent profile; it never infers ownership from the VM name alone. An existing directory without ownership metadata is refused. Retained audit labels still require explicit evidence preservation before reuse by a later Capture.

## Saved audit comparison

[compare-audits.ps1](../scripts/compare-audits.ps1) runs without elevation or Hyper-V. Both modes compare all collected areas, preserve user-registration and service-instance identities, and verify matching collection receipts when available. Repeatability ignores reboot observations and service running states. Drift includes reboot observations and describes changes without treating every change as a compliance failure. Partial, missing, or differently scoped areas are marked incomparable and never prove removal. Existing comparison files are preserved.

```powershell
.\scripts\compare-audits.ps1 -Mode Drift -Before .local/vm-configured/configured-repeat/audit.json -After .local/vm-configured/after-update/audit.json -OutputDirectory .local/comparisons/update-review
```

The [automation review](../docs/automation-review.md) maps the maintained entry points and cleanup boundaries. Obsolete supporting scripts are removed after their useful operations and callers have been migrated.
