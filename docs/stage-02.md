# Stage 2. Clean VM and integration checks

Status: baseline and configured Pro 10.0.26300.9711, en-US are installed offline. Setup/OOBE, first sign-in, GPT, administrator access, and Windows RE were verified. Both baseline and configured audit pairs matched on stable inventory fields, and their checkpoints are saved with installation media detached. Limited-user collection and configured image/media checks passed. The configured audit pair passed all 67 selected checks.

## Test profile

The initial VM configuration is stored in [test-vm.psd1](../config/test-vm.psd1). This is a test environment, not a physical-disk deployment profile. The source ISO remains unchanged; a separate data ISO carries the generated answer file.

| Setting | Value |
| --- | --- |
| Hypervisor / name | Hyper-V / `Windows11-Pro-Test` |
| Firmware | Generation 2, Microsoft Windows Secure Boot, local vTPM protector |
| CPU / memory | 4 virtual processors, 8 GiB static RAM; virtualization extensions exposed |
| Storage | One new dynamic 80 GiB VHDX under `.local/vm/windows11-pro` |
| Guest | Pinned Pro image, x64, en-US; computer name `WIN11-TEST`, timezone `UTC` |
| Account | Local administrator `vmadmin`, unique random password; no automatic sign-in |
| Network | Adapter disconnected; no downloads or updates before the baseline |
| Disk layout | Guest disk 0 only: 260 MiB EFI, 16 MiB MSR, Windows, then at least 2 GiB recovery; verify Windows RE after installation |
| Checkpoints | Automatic checkpoints disabled; create explicit checkpoints with the VM shut down |
| Desired component rules | Not applied during installation; baseline retains the source component choices |

The ISO was created through Media Creation Tool according to the user. The local fingerprint and this provenance statement are recorded separately in [source-image.lock.json](../config/source-image.lock.json); no independent published ISO checksum has been recorded. Oscdimg and the Windows SIM libraries used here are pinned in [toolchain.lock.json](../config/toolchain.lock.json).

## Reproduce preparation

From the repository root, check resources and tool/source fingerprints through the existing UAC launcher:

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; CheckOnly = $true } -LogDirectory '.local/launches/vm-preflight'
```

Create the VM and answer-file ISO:

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/vm-create'
```

The script creates a new VM and VHDX, sets Secure Boot/vTPM and nested virtualization, and attaches the official ISO plus `answer.iso`. It never starts the VM, reuses an existing VM or working directory, attaches a physical disk, or deletes an earlier installation. `-WhatIf` is available in an elevated direct invocation. A partial failure leaves artifacts for inspection; do not delete a VM directory while it remains registered or in use.

The [VM-only answer template](../setup/vm/autounattend.xml) selects the source image index from the lock and input locales from `windows.psd1`. It wipes only the new guest disk attached by this creation procedure. Do not copy it onto physical installation media. It does not inject drivers, remove apps, change services, or enable the desired component rules. The public Pro default installation key selects the edition; it is not a personal activation key and does not activate Windows.

Validate the actual VM and the answer settings against the exported Pro WIM using Windows SIM:

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/validate-vm-setup.ps1 -Parameters @{ WimPath = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711\pro.wim' } -LogDirectory '.local/launches/vm-validation'
```

The validator creates the Windows SIM `.clg` catalog next to the working WIM if needed. It renders the current template with a synthetic password and validates it using the installed Windows SIM API, without opening the real credential file. It also verifies that the created VM is off, has the configured resources, one matching dynamic VHDX, disconnected networking, Secure Boot, and vTPM. Review `.local/vm-validation/validation.json` for validation messages. XML fixture tests alone do not validate component applicability to an image.

## Local secrets

The generated answer XML and `answer.iso` contain the VM password in plaintext because Windows Setup needs it. They stay in the ACL-restricted, Git-ignored VM directory. The `secrets` subdirectory separately permits only the creating user, SYSTEM, and Administrators; `secrets/credential.clixml` uses Windows DPAPI for that user on that host. The VM identity has access to its media but not to this credential directory. Do not print credentials into transcripts or pass a password through the UAC launcher.

For later PowerShell Direct access, import the credential in a normal or elevated Windows PowerShell session of the same creating user: `$credential = Import-Clixml -LiteralPath '.local/vm/windows11-pro/secrets/credential.clixml'`. Do not pipe the credential's plaintext password to output. The sandbox cannot use the host user's DPAPI profile; run the credential round-trip checks in the normal user context outside it.

Preparation checks, without creating or starting a VM:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/new-test-vm.tests.ps1
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/new-test-vm.tests.ps1
```

The suite checks XML escaping, image/partition selection, optional keyboard handling, absence of automatic sign-in and component-change commands, recovery space, restricted ACLs, local credential round-trip, and Git exclusion. Use an ordinary user session with the Windows profile loaded; DPAPI failure is a failed check, not a reason to fall back to plaintext credential storage.

Preparation verification passed 25 checks in Windows PowerShell 5.1 and 25 in PowerShell 7, including profile isolation and configured answer selection at image index 1. The VM preparation scripts and their test suite have no PSScriptAnalyzer findings. Actual Hyper-V inspection confirmed the powered-off baseline VM's security, disk, and network settings; Windows SIM returned `Pass`. Baseline integration results are recorded below.

## Next integration actions

[`run-vm-baseline.ps1`](../scripts/run-vm-baseline.ps1) targets the recorded VM ID and single VHDX, requires disconnected networking, and imports the local credential only for PowerShell Direct. `-Action Start -OpenConsole` starts only a fresh powered-off test disk and opens VMConnect; `-Action Inspect -WaitForGuestSeconds 900` waits for the guest heartbeat and writes `.local/vm-baseline/inspection.json`. A heartbeat is not proof that OOBE has finished or that PowerShell Direct authentication is ready.

After inspection succeeds, `-Action Audit -ReportName baseline` copies only the audit script and desired configuration into the guest's marked `C:\WindowsProject` working directory, runs the audit in a fresh Windows PowerShell process, and copies reports back to `.local/vm-baseline/baseline`. Use `baseline-repeat` for the second run. Existing report directories are refused. Baseline exit 1 is expected when source defaults differ from the desired profile; exits 2/3 indicate incomplete verification and must be investigated. The helper does not apply the desired rules.

`-Action Capture` performs both audit runs in one elevated operation, verifies identical code/configuration hashes and stable inventory fields, shuts the VM down gracefully, detaches installation media, selects its system disk for boot, and saves the `baseline-audited` checkpoint. It ignores timestamps, current service running states, and reboot indicators in the repeatability comparison. Report directories and existing checkpoints are never replaced. All VHD checkpoint parents must remain within the VM directory and lead to its recorded original VHDX; existing snapshots are preserved. `collection.json` records hashes from the actual copied guest inputs, `comparison.json` records the repeatability result, and `checkpoint.json` records the snapshot identity.

The verified baseline reports each contain 27 compliant checks, 41 expected mismatches, zero incomplete areas, and zero unresolved checks. The mismatches are six Optional Features, one Windows Capability, and the same 17 selected apps observed both in provisioning and user registrations. Both audits return exit 1 because desired component changes have not been applied. Local results are in `.local/vm-baseline/baseline`, `.local/vm-baseline/baseline-repeat`, `comparison.json`, and `checkpoint.json`; machine inventories remain excluded from Git. Earlier diagnostic reports are retained separately under `.local/diagnostics`.

Run the limited-user integration check through the same host launcher:

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Limited' } -LogDirectory '.local/launches/vm-limited'
```

This action requires the recorded baseline checkpoint and detached installation media. It starts the VM if it was off, uses PowerShell Direct for orchestration, and runs the audit under the existing `vmadmin` identity with a restricted process token using Windows `runas /trustlevel:0x20000`. It creates no accounts, changes no group memberships or policies, and leaves the checkpoint intact. The VM is shut down afterward if the helper started it. The result represents a process without elevation under the same user profile, rather than a separate standard-user account. The [Windows runas reference](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc771525(v=ws.11)) describes the trust-level option.

The live `limited-user` report passed JSON Schema validation and recorded `isAdministrator: false` with `FullLanguage` in `launch.json`. Optional Features, Capabilities, ProvisionedApps, and Servicing failed with explicit collection errors; RegisteredApps was `Partial` with `CurrentUser` scope. Seven OS checks passed, 17 observed user app registrations proved mismatches, and 44 checks remained `NotVerified`. Exit 3 correctly combined proven mismatches with incomplete verification. Unobserved provisioned app state remained `actual: null`. Reports and launch evidence are stored under `.local/vm-baseline/limited-user` and excluded from Git; the audit code hash matches the full baseline run.

After successful Windows SIM validation, start the VM and complete Setup from its attached media. The official DVD may require a key press in the VM console. Unconfigured OOBE screens may still appear; record any choices rather than introducing undocumented bypass commands. Keep networking disconnected until the baseline and baseline-repeat audits have completed. Verify the installed edition/build/language, GPT layout, and `reagentc /info`; retain setup diagnostics locally on failure.

Follow the [audit VM verification sequence](audit.md#stage-2-vm-verification) for full and limited-user collection, repeatability, and checkpoint capture. Prepare the selected component changes in a separate offline WIM using [build-image.ps1](../scripts/build-image.ps1), then create installation media and perform a fresh configured installation while preserving the clean baseline and its checkpoint. Verify the configured system with the independent audit. After that passes, connect networking explicitly, install updates, and repeat the audit. WSL runtime/distribution provisioning and real container execution remain separate deferred decisions; enabling Windows features is the initial test scope.

The configured `.local/build/windows11-pro/install.wim` at index 1 passed all 73 offline checks through a read-only mount after saving. Seventeen provisioned apps were removed and the other 30 retained. The legacy Media Player capability is `NotPresent`; its Optional Feature identifier disappears with capability removal and has no duplicate rule. Containers, Hyper-V, WSL, and Virtual Machine Platform are enabled along with their supporting features, Work Folders is disabled, and all other capability states match the source. Manifest review covered 153 manifests with no declared dependency from a retained app to a removed app. Build cleanup completed successfully; input fingerprints, the configuration snapshot, and the output WIM hash are stored in the ignored build directory. Synthetic build checks passed 16 assertions in both PowerShell versions. The source ISO and baseline VM were not changed; these checks do not replace the installed-system audit.

Package the configured WIM with [build-install-media.ps1](../scripts/build-install-media.ps1); use `-Compress` to export recovery-compressed `sources/install.esd`, or omit it to copy `sources/install.wim` unchanged. The working WIM is retained. The generic ISO keeps the original Setup/boot files and contains no answer file or credentials. Use `-VMProfile Configured` with the existing VM preparation, validation, and inspection helpers for the fresh installation. It creates `Windows11-Pro-Test-Configured` with the same virtual hardware and a new VHDX/private answer ISO; the baseline remains off with its checkpoint intact. Configured Setup selects image index 1. Validation reuses the cached source-version Windows SIM catalog for unchanged answer components. See the [script guide](../scripts/README.md#package-installation-media) for paths/resource requirements and the [build log](build-log.md) for the ordered commands.

The packaged ISO passed hash verification for all 982 files, including the recovery-compressed ESD. Its single-image metadata matches the verified WIM; the ISO is 6220.6 MiB. Its staging tree and owned ISO attachments were cleaned successfully. A fresh installation from this compressed ISO completed in the configured VM, which has isolated disk/credentials and passed Windows SIM validation with status `Pass`. Setup/OOBE and first sign-in are complete. The baseline VM remains powered off with its recorded checkpoint intact.

The compressed installation's `configured` and `configured-repeat` audits each returned exit 0: 67 compliant checks, zero mismatches, zero unresolved checks, and zero incomplete areas. Both reports passed JSON Schema validation and their stable inventories matched. All 17 selected families are absent from provisioning and installed user registrations. The 31 retained provisioned families match the installed baseline minus those removals and are registered for the audited `vmadmin` SID. The extra family compared with the offline WIM's 30 is `Microsoft.MicrosoftEdge.Stable`, which appears during installation of the baseline as well. No pending reboot indicators were observed. Reports and comparison/checkpoint records are under `.local/vm-configured`; `configured-audited` was saved powered off with media detached.

Microsoft references: [Windows 11 VM requirements](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements), [nested virtualization](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/enable-nested-virtualization), [answer-file discovery](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview), [OOBE automation](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/automate-oobe), [edition selection and activation](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/work-with-product-keys-and-activation-auth-phases), and [Windows SIM validation](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wsim/validate-an-answer-file).
