# Supporting scripts

The main scenarios are [tool preparation](../workflows/prepare-tools.ps1), [source preparation](../workflows/prepare-source.ps1), [build](../workflows/build.ps1), and [test VM](../workflows/test-vm.ps1); this directory contains their supporting implementations and independent utilities. Invoke those workflows directly for normal operations, from a 64-bit PowerShell terminal on Windows with elevation when required. Initial discovery of a different source and standalone installed-system audits remain separate utilities.

## Build the configured image

Selected `Policies` are compiled as part of the same offline build, using the pinned LGPO executable with file-generation options only. The image receives Machine/User `Registry.pol` files, `gpt.ini` processing metadata, and any configured JSON files referenced by native policies. LGPO and build-host files are not deployed. The existing pre-save and saved-WIM checks verify these files independently; installed-state verification uses the normal configured-VM audit. See [policies in the prepared image](../docs/stage-03.md).

[`build-image.ps1`](build-image.ps1) exports the pinned Pro source to a new `.local/build/windows11-pro/install.wim` at index 1 and applies the explicit Appx, Optional Feature, and Capability rules from `config/windows.psd1` offline. The build workflow runs it in a fresh worker process on Windows x64. From an elevated terminal:

```powershell
.\workflows\build.ps1 -IsoPath 'D:\temp\windows.iso' -Stage Image
```

Each invocation recreates its own output directory after checking for active builds, registered WIM mounts, and unsafe paths. Output directories must be directly under `.local/build`. The source ISO and pinned ADK files are hash-checked. The build copies its configuration into the output, reviews offline app manifests for declared reverse dependencies, rejects shared-framework removal, and applies only selected rules. It uses supported DISM servicing with `-Path`; it does not service the running host or change the baseline VM. Unselected provisioned apps must remain present. Feature enablement may enable required parents; `before.json` and `after.json` record the resulting inventory.

`operation.json` records progress, input fingerprints, completed operations, cleanup errors, and the final WIM hash. `plan.json`, `app-manifests.json`, and `verification.json` record the plan, dependency evidence, and checks. A successful build requires verification through a read-only mount of the saved WIM and completed cleanup. Failures discard uncommitted mount changes and are never reported as a ready image. Missing payloads fail the build; no payload downloads or external tools are installed. Preserve these local reports when investigating a failure before rerunning, because the next invocation cleans this build directory.

LGPO compilation retains each scope's input and native output under `policy-source`, including `Machine.log` and `User.log` for the scopes compiled. Native stdout and stderr are captured separately; informational stderr does not fail a successful process. Nonzero exits report the command, exit code, diagnostics, and log path. Failed operation reports include `errorDetails` with the PowerShell error ID, source position, exception type, and script stack.

Offline feature states such as `EnablePending` require completion and independent verification after installation. Manifest checks do not prove application compatibility. The configured WIM still needs installation media, a fresh VM installation, and the independent audit. Configured media select the exported image; baseline media use the source index recorded in the lock. Input layouts remain part of answer-file generation; selected local GPOs are already present in the image and Windows processes them at startup/sign-in.

Run planner/verification checks with `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/build-image.tests.ps1`. The suite uses synthetic inventories and the pinned LGPO compiler to generate policy files under ignored fixture directories. It independently reads those files, verifies both scopes and metadata, and confirms that existing policies are refused. It never mounts an image, calls DISM, or imports host policies. Prepare LGPO using the [build plan](../docs/build-plan.md) first. Microsoft documents [offline app provisioning removal](https://learn.microsoft.com/en-us/powershell/module/dism/remove-appxprovisionedpackage), [feature enablement and parent dependencies](https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature), and [capability removal](https://learn.microsoft.com/en-us/powershell/module/dism/remove-windowscapability).

## Package installation media

[`build-install-media.ps1`](build-install-media.ps1) packages the verified `.local/build/windows11-pro/install.wim` with the pinned Microsoft ISO's Setup files. Development builds copy the Fast-compressed WIM unchanged to `sources/install.wim`. The explicit `-Compress` option exports `sources/install.esd` with Recovery compression and matching image metadata for final packaging. Every packaged file is verified after mounting the ISO read-only.

The builder adds the WinPE dependencies pinned in [toolchain.lock.json](../config/toolchain.lock.json) to the Setup boot image and configures its startup through `winpeshl.ini`. The ISO contains `deployment/install.ps1`, the credential-free answer template, and `windows.psd1`. In UEFI WinPE, the installer selects the sole target disk, or unpartitioned disk 0 when multiple targets exist, calculates the configured sizes, generates an answer in the WinPE RAM drive, and starts Windows Setup. Otherwise, disk selection and partitioning stay in the standard Setup UI. Windows Setup performs the disk operations. The generated name uses the configured prefix and a random suffix. No custom input screens or account-creation scripts are used.

OOBE skips the network screen with `HideWirelessSetupInOOBE` and uses `HideOnlineAccountScreens` for local account creation. Configure networking after the first sign-in. Username and password are entered only through native OOBE. No user credentials, AutoLogon, or first-logon commands are included. Setup Dynamic Update is disabled to use the pinned payload; normal Windows Update is tested afterward. Windows SIM validation checks the generated answer against the matching source catalog; a fresh installation must verify actual OOBE behavior. See Microsoft's [WinPE PowerShell prerequisites](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-adding-powershell-support-to-windows-pe), [startup configuration](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpeshlini-reference-launching-an-app-when-winpe-starts), [OOBE account setting](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oobe-hideonlineaccountscreens), and [network-screen setting](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oobe-hidewirelesssetupinoobe).

```powershell
.\workflows\build.ps1 -IsoPath 'D:\temp\windows.iso' -Stage Media
```

The fixed output is `.local/media/windows11-pro/windows11-pro.iso`, with `operation.json`, `image.json`, a per-file hash manifest, and the boot order alongside it. The operation record includes the input WIM hash and the compressed payload's path, hash, size, and compression type. The script recreates its own output directory, refuses an attached ISO or media referenced by a VM, and locks the WIM build directory while packaging. Its free-space check budgets two copies of the payload/Setup files plus scratch space; the staging tree is removed after verification. Read the [DISM export options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14#export-image) and [Oscdimg options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options) for compression, boot entries, hidden files, and file ordering.

`native-commands.log` retains stdout, stderr, and exit codes from DISM and Oscdimg alongside DISM's own `dism.log`. Failed operation reports preserve structured PowerShell `errorDetails` as well as the readable error message.

## Prepare the test VM

The [VM workflow](../workflows/test-vm.ps1) coordinates [`new-test-vm.ps1`](new-test-vm.ps1), which checks resources and pinned inputs and creates the isolated VM and VHDX, and [`validate-vm-setup.ps1`](validate-vm-setup.ps1), which verifies the VM and validates its answer using Windows SIM. Run the [source-preparation workflow](../workflows/prepare-source.ps1) first to produce the original Pro WIM required for validation. `-Action Prepare` then creates, validates, and starts the missing VM, stopping at native Setup/OOBE. Only the baseline gets private answer-file media. See [Stage 2](../docs/stage-02.md) for baseline commands and credential handling.

`-VMProfile Configured` uses the deployment ISO and a separate VM working directory. VM settings come from [test-vm.psd1](../config/test-vm.psd1); `ConfiguredDiskBytes` exercises C/D sizing. No test account or answer ISO is generated: the installation follows the production setup and native OOBE. Supply the OOBE account as `-Credential` to `test-vm.ps1` for host-side audit access. Configured preparation and reinstallation are independent of baseline VM state and reports. Resource and free-space requirements are enforced by the preflight implementation in [new-test-vm.ps1](new-test-vm.ps1). Neither profile reuses an existing VM or disk. Windows SIM validates the production-generated answer for the configured profile using the matching cached source catalog.

Select `-VMProfile Configured` on the VM workflow; it passes the profile to its workers. Validation reports go to `.local/vm-configured-validation`; audit reports go to `.local/vm-configured`. Workflow and host-inspection records go under `.local/workflows/test-vm/<profile>`. `-Action Audit` defaults to the report label `configured`; `-Action Capture` collects `configured` and `configured-repeat` and saves `configured-audited`. The default `Baseline` profile retains its existing paths and source ESD index. See the [build plan](../docs/build-plan.md) for the exact invocations.

Windows SIM uses .NET Framework catalog serialization. The validator isolates that API in a built-in Windows PowerShell worker when the caller uses another runtime; the VM workflow keeps its calling PowerShell host. Only the WIM path and profile are passed to the worker. Stage messages retain console colors, `worker.log` records the worker transcript beside `validation.json`, and successful completion requires a fresh completed report with a passing answer-file result. The child inherits elevation without requesting UAC. Failed reports include the stage and structured error details.

If preparation fails during validation after creating the VM, repeat `validate-vm-setup.ps1` with the same `-WimPath` and `-VMProfile`, then use the VM workflow's `-Action Start`. Start checks the validation against the current VM, configuration, templates, empty disk, and installation media. Prepare continues to refuse existing VMs, and repeating validation does not recreate the VM or its disk.

Configured capture requires exit 0 from both audits before creating a checkpoint. The first capture requires a running desktop shell as evidence of first sign-in. Later collections can use the recorded checkpoint ID on the same VM as first-sign-in evidence, so a fresh GUI sign-in is not required after every boot. Setup completion, OS identity, privileges, GPT, WinRE, disk ancestry, and disconnected networking are still checked.

The initial capture requires the pinned source version. After the configured checkpoint is saved, `-Action Audit` accepts newer Windows versions on that same recorded VM for update verification. Install updates normally and restart as needed. The workflow temporarily isolates configured networking and restores original attachments; `-NetworkMode Preserve` explicitly retains current connections. Supply the OOBE account with `-Credential`; standalone `audit.ps1` does not depend on Hyper-V or disconnected networking. The [workflow guide](../workflows/README.md#test-vm) describes `Prepare`, `Reinstall`, explicit guest restart, evidence archives, and comparison options.

## Audit installed Windows

[`test-vm.ps1`](../workflows/test-vm.ps1) starts the prepared VM or uses PowerShell Direct to inspect and audit its installed system. `-Action Capture` performs repeated baseline collection, stable-state comparison, graceful shutdown, media detachment, and checkpoint capture in one elevated operation. It follows the recorded VHDX's checkpoint chain and refuses unrelated disks. See [Stage 2](../docs/stage-02.md) for the workflow.

`-Action Limited` verifies non-elevated collection using a restricted process under the same guest account. The helper checks for explicit scope/privilege limitations and expects the audit's incomplete-verification exit bit. It preserves the clean checkpoint and restores the VM's prior power state after starting an initially stopped VM.

[`audit.ps1`](audit.ps1) collects installed-system state without applying changes, compares explicit configuration rules, and writes JSON/Markdown reports under `.local/audit`. Use a fresh 64-bit `powershell.exe` process on Windows; full collection requires administrator privileges, and limited access is reported explicitly. See the [audit guide](../docs/audit.md) for invocations, exit codes, report schema, fixture tests, and VM checks. Live collection on the current computer is not a prerequisite.

## Run an elevated operation

`run-elevated.ps1` launches a repository script in a separate Windows PowerShell process through UAC. Script parameters are passed as data in a local CLIXML file. The launcher cleans its previous logs before starting and refuses to clean a directory used by an active launch or child process. Log directories must be directly under `.local/launches`; the default is `.local/launches/catalog`. Do not pass secrets as parameters or write them to the transcript.

## Export the component catalog

Prepare the Deployment Tools pinned in `config/toolchain.lock.json`, then invoke the [source-preparation workflow](../workflows/README.md#prepare-source). Its exporter verifies the recorded ISO and tool hashes, uses that ADK's DISM module and native API, and validates the selected source image before exporting it:

```powershell
.\workflows\prepare-source.ps1 -IsoPath 'D:\temp\windows.iso'
```

The workflow derives the output directory directly under `.local/catalog` from the source lock's image build and revision. The exporter refuses to clean an active export or registered WIM mount, removes the previous working directory, and checks available disk space. It creates `pro.wim`, mounts the exported image read-only, queries Optional Features, Windows Capabilities, and provisioned Appx, then discards its mount and detaches only its own ISO attachment. Working files remain locally until the next run cleans them.

The worker's `operation.json` records progress, errors, and cleanup. The coordinator verifies that report and the generated artifacts and writes `.local/workflows/prepare-source/operation.json` with their paths. Use the source WIM, `catalog.json`, and `selections.psd1` only after successful completion. The selection template contains one commented identifier-to-state pair for every discovered component. Features use `Enabled`/`Disabled`; capabilities and inbox apps use `Present`/`Absent`. It does not change the active configuration. App dependency review is still required before any removals; the provisioning catalog is not a complete dependency graph or a list of every system app.

The source image index is taken from `source-image.lock.json`; the working WIM contains only that image, at index 1. Raw DISM diagnostics and working files stay under `.local`; only reviewed catalog and configuration artifacts belong in Git.

## Inspect the source ISO

`inspect-source.ps1` reads all image indexes from `sources/install.wim` or `sources/install.esd` and records edition, architecture, version, and language. It does not mount or service the Windows installation image.

Use this discovery utility when deliberately selecting a different source, before the normal workflow sequence. Compute its local fingerprint with `Get-FileHash -LiteralPath <ISO-path> -Algorithm SHA256` and record that input in [source-image.lock.json](../config/source-image.lock.json) before inspection. Review the returned image metadata when updating the selected image and compatible toolchain pins. An already selected ISO with existing locks goes directly through [prepare-source.ps1](../workflows/prepare-source.ps1), whose exporter recalculates the ISO hash and compares it with the recorded value before exporting. Deleting `.local` removes working artifacts, not the fingerprint in Git; source preparation does not generate or replace that expected fingerprint.

Run it directly from an elevated native Windows PowerShell terminal. The inspection reuses `.local/source-inspection`, cleans previous results, and refuses a concurrent inspection. The source ISO must remain outside this working directory.

From the repository root:

```powershell
.\scripts\inspect-source.ps1 -IsoPath 'D:\temp\windows.iso' -OutputDirectory 'D:\Repository\Projects\windows\.local\source-inspection' -ExpectedSha256 (Get-Content -LiteralPath 'config/source-image.lock.json' -Raw | ConvertFrom-Json).iso.sha256
```

The script verifies the ISO against the recorded local fingerprint, temporarily attaches it read-only if needed, and detaches only attachments it created. This fingerprint check does not independently authenticate the download source.

Results are written to `inspection.json`; DISM diagnostics stay in the same output directory. Exit code 0 means inspection and required cleanup succeeded; exit code 1 indicates a failure. Review `status`, `error`, and `cleanupError` before using any image metadata. Startup errors such as missing administrator privileges can occur before a report is created.
