# Stage 2. Clean VM and integration checks

Status: baseline and configured installations completed offline. Setup/OOBE, first sign-in, GPT, administrator access, and Windows RE were verified. Baseline and configured audit pairs matched on stable inventory fields, and their checkpoints were saved with installation media detached. Limited-user collection and configured image/media checks passed. Generated reports record the exact source, configuration, and results for each run.

## Test profile

The initial VM configuration is stored in [test-vm.psd1](../config/test-vm.psd1). This is a test environment, not a physical-disk deployment profile. The source ISO remains unchanged; a separate data ISO carries the generated answer file.

VM identity, resources, and baseline account settings live in [test-vm.psd1](../config/test-vm.psd1); baseline partitioning lives in the [VM answer template](../setup/vm/autounattend.xml). The validator checks the actual VM against these inputs. Keep baseline networking disconnected and retain source component defaults. Create explicit checkpoints with the VM shut down.

The ISO was created through Media Creation Tool according to the user. The local fingerprint and this provenance statement are recorded separately in [source-image.lock.json](../config/source-image.lock.json); no independent published ISO checksum has been recorded. Oscdimg and the Windows SIM libraries used here are pinned in [toolchain.lock.json](../config/toolchain.lock.json).

## Reproduce preparation

Prepare the pinned tools through the [tool-preparation workflow](../workflows/README.md#prepare-tools), following the [build plan](build-plan.md). From an elevated 64-bit PowerShell terminal on Windows at the repository root, prepare the original source WIM, component catalog, and commented selection template together, then create, validate, and start the baseline VM:

```powershell
.\workflows\prepare-source.ps1 -IsoPath 'D:\temp\windows.iso'
.\workflows\test-vm.ps1 -Action Prepare -VMProfile Baseline -IsoPath 'D:\temp\windows.iso' -OpenConsole
```

Source preparation derives the catalog working directory from the source lock and exports `pro.wim` for Windows SIM. Run it when rebuilding from an empty `.local`, even if the desired configuration and reviewed catalog already exist in Git. It does not require reselecting the active profile or copying generated catalog files into Git.

The VM workflow checks host resources and pinned inputs, creates a new isolated VM and VHDX, configures Secure Boot/vTPM and nested virtualization, and attaches the official ISO plus private answer media. It then validates the actual VM and generated answer through Windows SIM and starts installation. Existing VMs and working directories are refused. `-WhatIf` previews the workflow action without creating resources. A partial failure leaves evidence for inspection; do not delete a VM directory while it remains registered or in use.

The [VM-only answer template](../setup/vm/autounattend.xml) selects the source image index from the lock and input locales from `windows.psd1`. It wipes only the new guest disk attached by this creation procedure. Do not copy it onto physical installation media. It does not inject drivers, remove apps, change services, or enable the desired component rules. The public Pro default installation key selects the edition; it is not a personal activation key and does not activate Windows.

The validator creates the Windows SIM `.clg` catalog next to the source WIM if needed. It renders the current template with a synthetic password and validates it using the installed Windows SIM API, without opening the real credential file. It also verifies that the created VM is off, has the configured resources, one matching dynamic VHDX, disconnected networking, Secure Boot, and vTPM before installation starts. Review `.local/vm-validation/validation.json` and `.local/workflows/test-vm/baseline/operation.json`. XML fixture tests alone do not validate component applicability to an image.

## Local secrets

The generated answer XML and `answer.iso` contain the VM password in plaintext because Windows Setup needs it. They stay in the ACL-restricted, Git-ignored VM directory. The `secrets` subdirectory separately permits only the creating user, SYSTEM, and Administrators; `secrets/credential.clixml` uses Windows DPAPI for that user on that host. The VM identity has access to its media but not to this credential directory. Do not print credentials into transcripts or pass a password through the UAC launcher.

For later PowerShell Direct access, import the credential in a normal or elevated 64-bit PowerShell session on Windows as the same creating user: `$credential = Import-Clixml -LiteralPath '.local/vm/windows11-pro/secrets/credential.clixml'`. Do not pipe the credential's plaintext password to output. The sandbox cannot use the host user's DPAPI profile; run the credential round-trip checks in the normal user context outside it.

Preparation checks, without creating or starting a VM:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/new-test-vm.tests.ps1
```

The suite checks XML escaping, image/partition selection, optional keyboard handling, absence of automatic sign-in and component-change commands, recovery space, restricted ACLs, local credential round-trip, and Git exclusion. Use an ordinary user session with the Windows profile loaded; DPAPI failure is a failed check, not a reason to fall back to plaintext credential storage.

Preparation verification covered profile isolation and answer selection. Hyper-V inspection confirmed the powered-off baseline VM's security, disk, and network settings; Windows SIM returned `Pass`. Detailed validation results remain in generated reports.

## Next integration actions

[`test-vm.ps1`](../workflows/test-vm.ps1) targets the recorded VM ID and single VHDX. Baseline collection requires disconnected networking and imports its private credential only for PowerShell Direct. `-Action Start -OpenConsole` starts only a fresh powered-off test disk and opens VMConnect. `-Action Inspect` records host state under `.local/workflows/test-vm/<profile>/inspection.json`; it uses the private baseline credential for a running owned guest, or an explicit `-Credential` for configured guest inspection. Use `-WaitForGuestSeconds` for bounded collection-readiness polling. A heartbeat is not proof that OOBE has finished or that PowerShell Direct authentication is ready. The [workflow guide](../workflows/README.md#test-vm) describes preparation, same-VM reinstallation, network restoration, and saved-report comparison.

After inspection succeeds, `-Action Audit -ReportName baseline` copies only the audit script and desired configuration into the guest's marked `C:\WindowsProject` working directory, runs the audit in a fresh Windows PowerShell process, and copies reports back to `.local/vm-baseline/baseline`. Use `baseline-repeat` for the second run. Existing report directories are refused. Baseline exit 1 is expected when source defaults differ from the desired profile; exits 2/3 indicate incomplete verification and must be investigated. The helper does not apply the desired rules.

`-Action Capture` performs both audit runs in one elevated operation, verifies identical code/configuration hashes and stable inventory fields, shuts the VM down gracefully, detaches installation media, selects its system disk for boot, and saves the `baseline-audited` checkpoint. It ignores timestamps, current service running states, and reboot indicators in the repeatability comparison. Report directories and existing checkpoints are never replaced. All VHD checkpoint parents must remain within the VM directory and lead to its recorded original VHDX; existing snapshots are preserved. `collection.json` records hashes from the actual copied guest inputs, `comparison.json` records the repeatability result, and `checkpoint.json` records the snapshot identity.

The baseline reports distinguish expected source-default mismatches from collection failures. Local results are in `.local/vm-baseline/baseline`, `.local/vm-baseline/baseline-repeat`, `comparison.json`, and `checkpoint.json`; machine inventories remain excluded from Git. Earlier diagnostic reports are retained separately under `.local/diagnostics`.

Run the limited-user integration check through the VM workflow from the elevated terminal:

```powershell
.\workflows\test-vm.ps1 -Action Limited -VMProfile Baseline
```

This action requires the recorded baseline checkpoint and detached installation media. It starts the VM if it was off, uses PowerShell Direct for orchestration, and runs the audit under the existing baseline account with a restricted process token using Windows `runas /trustlevel:0x20000`. It creates no accounts, changes no group memberships or policies, and leaves the checkpoint intact. The VM is shut down afterward if the helper started it. The result represents a process without elevation under the same user profile, rather than a separate standard-user account. The [Windows runas reference](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc771525(v=ws.11)) describes the trust-level option.

The live limited-user check demonstrated explicit collection errors, current-user registration scope, and unresolved unavailable states. Unobserved provisioned app state remained unknown. Reports and launch evidence are stored under `.local/vm-baseline/limited-user` and excluded from Git.

After the preparation workflow starts the VM, complete Setup from its attached media. The official DVD may require a key press in the VM console. Unconfigured OOBE screens may still appear; record any choices rather than introducing undocumented bypass commands. Keep networking disconnected until the baseline and baseline-repeat audits have completed. Verify the installed edition/build/language, GPT layout, and `reagentc /info`; retain setup diagnostics locally on failure.

Follow the [audit VM verification sequence](audit.md#stage-2-vm-verification) for full and limited-user collection, repeatability, and checkpoint capture. Prepare selected components, [local GPOs](stage-03.md), and installation media through the [build workflow](../workflows/README.md#build), then perform a fresh configured installation while preserving the clean baseline and its checkpoint. Verify the installed system with the independent audit, without applying policies from the host. Windows Update verification follows the complete configuration and deployment profile. WSL runtime/distribution provisioning and real container execution remain separate deferred decisions.

Offline build reports record the input fingerprints, configuration snapshot, dependency evidence, saved-WIM verification, and cleanup outcome. These checks do not replace the installed-system audit; the source ISO and baseline VM remain unchanged.

Use `workflows/build.ps1 -Stage All` without `-Compress` for development media that retain the Fast-compressed WIM. The ISO includes automatic disk preparation and the native OOBE configuration. Use `workflows/test-vm.ps1 -Action Prepare -VMProfile Configured -OpenConsole` to create, validate, and start the separate configured VM with a single deployment ISO. Account creation uses standard OOBE, and subsequent audit access uses that account. See the [workflow guide](../workflows/README.md) and [build plan](build-plan.md).

Configured reports, repeatability evidence, and checkpoint metadata remain under `.local/vm-configured`. [Stage 3](stage-03.md) describes verification of local GPO delivery. Existing checkpoints establish results only for the configuration recorded by their reports.

Microsoft references: [Windows 11 VM requirements](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements), [nested virtualization](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/enable-nested-virtualization), [answer-file discovery](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview), [OOBE automation](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/automate-oobe), [edition selection and activation](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/work-with-product-keys-and-activation-auth-phases), and [Windows SIM validation](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wsim/validate-an-answer-file).
