# Operational automation map

This map groups operational scenarios into main scripts under `workflows/` and supporting utilities under `scripts/`. The [tool-preparation workflow](../workflows/prepare-tools.ps1), [source-preparation workflow](../workflows/prepare-source.ps1), [build workflow](../workflows/build.ps1), [VM workflow](../workflows/test-vm.ps1), and [report comparator](../scripts/compare-audits.ps1) provide the implemented entry points. The tables describe their command composition, execution boundaries, and the local helpers from which they were consolidated.

Keep coordinators responsible for sequencing and outcomes. Keep DISM servicing, ISO packaging, VM creation, native Setup, and installed-state collection in their existing implementations. Incident recovery, application-specific investigations, and discarded deployment approaches are excluded from the operational script set; their generated evidence remains under ignored local report directories.

## Entry points and consolidation decisions

| Entry point | Operations served by parameters | Supporting code and local sources | Why this grouping |
| --- | --- | --- | --- |
| `workflows/prepare-tools.ps1 -Tool Adk\|WinPE\|Lgpo\|All -Action Download\|Install\|Check\|Remove` | Acquire, install/extract, verify, or remove the selected pinned build tools and their download caches. | Tool-preparation commands in [build-plan.md](build-plan.md), plus `.local/prepare-winpe.ps1`. | The tools share lock-file input, fingerprint/signature checks, local downloads, and explicit installation. Removal pre-flights the selection, uses verified vendor uninstallers for registered host components, and cleans only selected local tool directories. Use tool-specific functions inside one coordinator; do not create a public script for each tool or rerun preparation as part of every build. |
| `workflows/prepare-source.ps1 -IsoPath <source-ISO>` | Prepare the original source WIM, component catalog, and commented selection template together from the locked image. | [export-image-catalog.ps1](../scripts/export-image-catalog.ps1). | Restores the local source artifacts needed by Windows SIM and catalog review from an empty `.local`, without reselecting an existing profile. Derive the shared output directory from the source lock and verify the worker outcome. |
| `workflows/build.ps1 -Stage Image\|Media\|All` | Build only the WIM, package a verified WIM, or run both stages. `-Compress` applies to media packaging. | [build-image.ps1](../scripts/build-image.ps1), [build-install-media.ps1](../scripts/build-install-media.ps1), and the build sequence in `.local/continue-current-profile.ps1`. | These are stages of one artifact flow. One entry point removes repeated command chains while retaining the independently usable servicing and packaging workers. |
| `workflows/test-vm.ps1 -Action Inspect\|Prepare\|Reinstall\|Capture\|Audit -VMProfile Baseline\|Configured` | Manage and verify the selected owned test VM. Audit variants use `-CompareTo` and explicit `-RestartBefore`; repeat capture can use `-ArchiveReason`. | [new-test-vm.ps1](../scripts/new-test-vm.ps1), [validate-vm-setup.ps1](../scripts/validate-vm-setup.ps1), the independent audit, and the shared comparator. The local implementation sources are mapped below. | Both profiles share ownership checks, credentials, guest transport, evidence preservation, and collection. One coordinator serves the installation and verification cycle. |
| `scripts/compare-audits.ps1 -Mode Repeatability\|Drift -Before <report> -After <report> -OutputDirectory <directory>` | Verify a stable repeated capture or describe changes after updates. | Shared report reading, provenance checks, and comparison implementation in [compare-audits.ps1](../scripts/compare-audits.ps1). | Both modes need the same report reader and identity rules, but have different success criteria. Keep one comparison implementation callable by the VM runner and independently on saved reports, without Hyper-V or elevation. |

`-Tool`, `-Stage`, `-Action`, and `-Mode` belong to different scripts. Do not combine them into a universal command dispatcher. Only parameters relevant to the selected operation should be accepted; for example, compression must be rejected for an image-only build, and a guest restart must be an explicit audit option.

## Elevation boundary

The operator runs a main script directly from an elevated 64-bit PowerShell terminal on Windows when its selected operation requires administrator rights. Alternatively, the operator can explicitly invoke that main script through [run-elevated.ps1](../scripts/run-elevated.ps1). The wrapper remains an optional outer launcher.

Main scripts and their workers must not call the elevation wrapper, request UAC, or relaunch themselves with `RunAs`. Check the privileges required by the selected operation before making changes; if they are missing, stop with a clear instruction to rerun from an elevated terminal. Operations that do not require administrator rights, including comparison of saved reports, remain usable without elevation. Child processes needed for isolation inherit the caller's privilege level.

Declare `#Requires -RunAsAdministrator` when every operation in a script requires elevation, as in the build workflow. Use operation-specific privilege checks only for entry points that also support nonprivileged operations. The directive enforces an existing elevated session; it does not request elevation.

## Source preparation: exact composition

`workflows/prepare-source.ps1` accepts the ISO path and passes the repository source and toolchain locks to the existing exporter in a fresh Windows PowerShell process. The exporter owns guarded output cleanup, ISO verification and attachment, source-image selection checks, the original WIM export, read-only component collection, template generation, and mount cleanup. Keep these outputs together; the original WIM is also the Windows SIM input used by VM preparation.

The coordinator resolves the same build/revision directory under `.local/catalog` that the VM workflow uses by default. It verifies the worker exit, fresh completed report, image cleanup, artifact existence, catalog identity, commented template, and unchanged lock inputs, then writes its own result under `.local/workflows/prepare-source`. It does not copy artifacts into Git, rewrite the desired profile or locks, install tools, or invoke a VM. Initial inspection of a different source remains separate from preparation of an already selected and pinned image.

## Build operations: exact composition

The build coordinator accepts the source ISO and uses the existing configuration and locks. It does not install tools, export a new selection catalog, change selections, stop a VM, or detach media from a VM.

| Operation | Command composition | Required outcome |
| --- | --- | --- |
| `workflows/build.ps1 -Stage Image` | Run `build-image.ps1`. | The saved WIM is verified, cleanup succeeded, and the build report identifies its inputs and output. |
| `workflows/build.ps1 -Stage Media` | Validate the existing build evidence, then run `build-install-media.ps1`. | The packaged ISO matches the verified WIM and current inputs. Reject stale or attached artifacts. |
| `workflows/build.ps1 -Stage All` | Run the image operation, check its result, then run the media operation. | Stop before packaging if image servicing or verification fails. |
| Media operation with `-Compress` | Pass `-Compress` to `build-install-media.ps1`. | Compression remains explicit; ordinary development packaging retains the working WIM. |

The current packager consumes the default build/configuration paths. Initially the coordinator should expose that supported profile flow. Alternative configuration/output paths require an explicit artifact contract across both workers before they can be public coordinator parameters.

## VM operations: exact composition

`workflows/test-vm.ps1` owns VM orchestration; it does not replace the audit collector, VM creator, or Windows SIM validator. Profile selection must resolve the target from configuration and owned metadata. No action controls the desktop or enters the configured user's OOBE credentials. Opening a console remains an explicitly requested convenience rather than a prerequisite or automatic action.

| Operation | Composition | Operation boundary |
| --- | --- | --- |
| `Inspect` | `.local/inspect-test-vms.ps1` plus the runner's VM identity, disk-chain, media, network, and checkpoint checks. | Show the recorded and actual state, including partial preparation. Installed-system inspection remains shared with `Audit` and `Capture`; unavailable guest access must be reported. |
| `Prepare -VMProfile Baseline` | `new-test-vm.ps1 -VMProfile Baseline` -> `validate-vm-setup.ps1 -VMProfile Baseline` -> the runner's fresh-install `Start` operation. | Create a missing baseline VM from the source ISO and stop at the Setup/OOBE handoff. Existing VMs are refused. Baseline-only answer media and credentials remain private. |
| `Prepare -VMProfile Configured` | The same command sequence with `VMProfile Configured`, using the verified deployment ISO. | Create a missing configured VM while preserving the clean baseline. Native OOBE creates the account. |
| `Reinstall -VMProfile Configured` | `.local/restart-configured-installation.ps1` disk-reset operation -> the existing validator -> the fresh-install `Start` operation. Reuse the evidence-preservation operation described below. | Keep the VM ID, initialized TPM/key protector, and firmware security settings. Replace only its owned system disk. Affected disposable checkpoints must be identified and their removal explicitly selected with `-DiscardCheckpoints`. Preserve the baseline. |
| `Remove -VMProfile Baseline` or `Configured` | Check recorded ownership and references -> unregister the powered-off VM -> delete its owned VM directory. | Require an explicit profile and checkpoint discard when applicable. Preserve reports, tools, external ISO inputs, and other VMs. Keep ownership metadata until file cleanup completes, allowing retry after partial removal. |
| `Capture -VMProfile Baseline` or `Configured` | Existing runner `Capture` -> `scripts/compare-audits.ps1 -Mode Repeatability` -> existing shutdown/media-detach/checkpoint operations. Use `.local/capture-deployment.ps1` for the configured credential-input requirement. | Preserve baseline-specific mismatch expectations. Configured capture requires compliant, complete audits and matching stable state before checkpoint creation. |
| `Capture` after an interrupted or unstable collection | The same capture operation with explicit `-ArchiveReason`, using the reusable parts of `.local/capture-stable-deployment.ps1`. | Preserve earlier host and guest reports before reusing their labels. A failed comparison is not silently retried until green. |
| `Audit -ReportName <label>` | Existing runner `Audit`, plus the network-condition handling in `.local/audit-after-update.ps1`. | Collect a separate report using explicitly supplied guest credentials. Preserve the original network attachments and existing checkpoints. Report collection and compliance outcomes separately. |
| `Audit -ReportName <label> -CompareTo <before-report>` | The same audit operation -> `scripts/compare-audits.ps1 -Mode Drift`. | This is the post-update scenario; it does not need a separate update-audit script. Show policy/component drift and contextual app/service changes. Windows Update installation remains outside this operation. |
| `Audit ... -RestartBefore` | Explicit guest restart/readiness verification from `.local/restart-after-update.ps1` -> the same audit operation and optional drift comparison. | This is the post-restart variant of the audit scenario. Restart only the selected guest, then collect once it is ready. Do not reboot as an implicit response to a reboot indicator. |

The runner's existing standalone `Start` and restricted-token `Limited` operations can remain explicit maintenance/test actions in the same VM entry point. They do not need new wrapper scripts. Neither action should be confused with reinstallation or a normal audit.

## Local implementation sources

The tool, VM, and build source helpers listed below are superseded by maintained entry points and remain local pending cleanup. Answer-validation source material remains until its useful variants are accounted for. None is a runtime dependency of a maintained workflow.

| Retained local file | Destination and operation | What to carry over |
| --- | --- | --- |
| `prepare-winpe.ps1` | `workflows/prepare-tools.ps1`, WinPE `Download`/`Install` operations | Pinned download/layout, signature checks, administrative extraction, and failure handling. Read values from the toolchain lock. |
| `continue-current-profile.ps1` | Split between `workflows/build.ps1 -Stage All` and `workflows/test-vm.ps1 -Action Prepare` | Command ordering and handoff between verified artifacts. Remove the combined build-and-VM assumption and automatic console opening. |
| `inspect-test-vms.ps1` | `workflows/test-vm.ps1 -Action Inspect` | Host-side state, disk/checkpoint references, and available resources; derive identities and locations from the selected profile and metadata. |
| `restart-configured-installation.ps1` | `workflows/test-vm.ps1 -Action Reinstall` | Same-VM system-disk reset, baseline protection, artifact checks, safe path ownership, and preservation of initialized VM security. Replace fixed VM/checkpoint identities with metadata. |
| `capture-deployment.ps1` | `workflows/test-vm.ps1 -Action Capture` credential input | Explicit `PSCredential` input. Drop the helper's internal UAC dispatch; elevation belongs to the operator's invocation. Configured-guest authentication is host-side test access. |
| `capture-stable-deployment.ps1` | Shared evidence-preservation function for `Capture` and `Reinstall` | Preserve old reports before reuse; handle host and guest ownership. `Reinstall` preserves host evidence before erasing the guest disk. Make the archive reason caller-supplied. |
| `audit-after-update.ps1` | `workflows/test-vm.ps1 -Action Audit`, with optional `-CompareTo` | Input-evidence checks, a new report label, and explicit network conditions with restoration on failure. |
| `restart-after-update.ps1` | `workflows/test-vm.ps1 -Action Audit -RestartBefore` | Normal guest restart, bounded readiness checks, and observed reboot completion. |
| `compare-update-audits.ps1` | `scripts/compare-audits.ps1 -Mode Drift` | Structured inventory differences and input provenance. Expand comparison to all collected areas and make VM receipts optional for standalone reports. |
| `validate-deployment-answer.ps1` | Existing `validate-vm-setup.ps1` validation function and maintained deployment tests | Generated-answer variants and Windows SIM checks; reuse the existing answer generator and validator rather than publishing another validation entry point. |

## Existing scripts that should stay separate

| Existing script | Decision |
| --- | --- |
| `inspect-source.ps1` | Keep as an initial discovery utility before deliberately selecting and pinning a different image. Ordinary preparation with existing locks uses the source workflow. |
| `export-image-catalog.ps1` | Keep as the source-preparation worker. It prepares the original WIM, catalog, and commented template together; the source coordinator verifies its result and exposes their paths. |
| `build-image.ps1`, `build-install-media.ps1` | Keep as workers under the parameterized build coordinator. Servicing a WIM and packaging an ISO have distinct artifacts, guards, cleanup, and reports; merging their implementations would not remove the need for those boundaries. |
| `new-test-vm.ps1`, `validate-vm-setup.ps1` | Keep as VM creation and validation workers. Correct early ownership recording in the creator and reuse the validator during both preparation and reinstallation. |
| `audit.ps1` | Keep independent of VM lifecycle, networking, reboots, policy application, and report history. |
| `run-elevated.ps1` | Keep as an optional operator-facing launcher for a main script. Main scripts and workers never invoke it internally. |
| `setup/deployment/install.ps1` | Keep image deployment in native Setup. Operational VM automation must not introduce production account-creation or first-logon scripts. |

## What is excluded from the script set

Incident-specific VMMS/process recovery, fixed-ID partial-VM completion, boot/start-menu/app investigations, obsolete full-VM replacement chains, discarded guest policy installation, and duplicate capture wrappers have been removed from the top-level local script set. Their diagnostic reports remain local. They are not relocated into a maintained `recovery` or `diagnostics` command collection.

The one-off cleanup probes are also excluded from operations. Their still-useful lock, mount, path, and evidence-preservation cases belong in the maintained tests when that behavior changes. Optional diagnostic bundles can be reconsidered if repeated use demonstrates a need; they are not an additional required build/test phase.

## Implementation constraints

- The VM creator must record owned resources before later preparation can fail. Existing initialized VM security must survive inspection and disk reset. Reject foreign VHD/checkpoint references and unsafe paths before destructive work.
- Keep elevation outside scenario implementations. Validate the selected operation's required privileges before changes; the operator supplies the elevated terminal.
- A launcher success is an execution outcome. Read the audit/build/media results before declaring a scenario successful; preserve audit mismatch and incomplete-collection semantics.
- Accept configured-guest credentials explicitly. Do not import secrets from a previous launch's `parameters.clixml`; any intentional private cache needs a VM-bound lifecycle independent of transcript cleanup.
- The report comparator must share its reader/identity rules across both modes, handle incomplete and unavailable areas, and keep service-instance and user-registration context visible. Keep the accepted app-absence rules unchanged.
- Use stable work paths, explicit report/archive labels, readable commands, and bounded waits. The limited-user action uses a readable generated script. Do not add run-number suffixes, automatic repair fallbacks, or a generic pipeline engine.
- Keep executable build-plan instructions aligned with the maintained entry points. When workflow behavior changes, add focused failure, ownership, and cleanup checks, then update its callers and retire superseded local helpers.

Tool and source preparation, build and VM coordination, and the shared report comparator are implemented. These operations satisfy the recurring-scenario prerequisite for [Stage 3](stage-03.md). Retiring remaining local source helpers is maintenance work and does not block final media packaging or invalidate recorded installation verification. Remove unused or superseded repository scripts only after their useful operations and callers have been accounted for. Consolidation does not change the image profile.
