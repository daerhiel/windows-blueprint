# Preparation scripts

## Build the configured image

Selected `Policies` are compiled as part of the same offline build, using the pinned LGPO executable with file-generation options only. The image receives Machine/User `Registry.pol` files and `gpt.ini` processing metadata. LGPO and build-host files are not deployed. The existing pre-save and saved-WIM checks verify these files independently; installed-state verification uses the normal configured-VM audit. See [policies in the prepared image](../docs/stage-03.md).

[`build-image.ps1`](build-image.ps1) exports the pinned Pro source to a new `.local/build/windows11-pro/install.wim` at index 1 and applies the explicit Appx, Optional Feature, and Capability rules from `config/windows.psd1` offline. Run it in a fresh elevated Windows PowerShell 5.1 process through the existing launcher:

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/build-image.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/image-build'
```

Each invocation recreates its own output directory after checking for active builds, registered WIM mounts, and unsafe paths. Output directories must be directly under `.local/build`. The source ISO and pinned ADK files are hash-checked. The build copies its configuration into the output, reviews offline app manifests for declared reverse dependencies, rejects shared-framework removal, and applies only selected rules. It uses supported DISM servicing with `-Path`; it does not service the running host or change the baseline VM. Unselected provisioned apps must remain present. Feature enablement may enable required parents; `before.json` and `after.json` record the resulting inventory.

`operation.json` records progress, input fingerprints, completed operations, cleanup errors, and the final WIM hash. `plan.json`, `app-manifests.json`, and `verification.json` record the plan, dependency evidence, and checks. A successful build requires verification through a read-only mount of the saved WIM and completed cleanup. Failures discard uncommitted mount changes and are never reported as a ready image. Missing payloads fail the build; no payload downloads or external tools are installed. Preserve these local reports when investigating a failure before rerunning, because the next invocation cleans this build directory.

Offline feature states such as `EnablePending` require completion and independent verification after installation. Manifest checks do not prove application compatibility. The configured WIM still needs installation media, a fresh VM installation, and the independent audit. Configured installation media must select image index 1; the original ESD index 6 belongs to baseline source installation. Input layouts remain part of answer-file generation; selected local GPOs are already present in the image and Windows processes them at startup/sign-in.

Run planner/verification checks with `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/build-image.tests.ps1` or the same invocation using `pwsh.exe`. The suite uses synthetic inventories and the pinned LGPO compiler to generate policy files under ignored fixture directories. It independently reads those files, verifies both scopes and metadata, and confirms that existing policies are refused. It never mounts an image, calls DISM, or imports host policies. Prepare LGPO using the [build plan](../docs/build-plan.md) first. Microsoft documents [offline app provisioning removal](https://learn.microsoft.com/en-us/powershell/module/dism/remove-appxprovisionedpackage), [feature enablement and parent dependencies](https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature), and [capability removal](https://learn.microsoft.com/en-us/powershell/module/dism/remove-windowscapability).

## Package installation media

[`build-install-media.ps1`](build-install-media.ps1) packages the verified `.local/build/windows11-pro/install.wim` with the pinned Microsoft ISO's Setup files. Development builds copy the Fast-compressed WIM unchanged to `sources/install.wim`. The explicit `-Compress` option exports `sources/install.esd` with Recovery compression and matching image metadata for final packaging. Every packaged file is verified after mounting the ISO read-only.

The builder adds the pinned x64/en-US WinPE WMI, NetFX, Scripting, PowerShell, and StorageWMI packages to the Setup boot image and configures its startup through `winpeshl.ini`. The ISO contains `deployment/install.ps1`, the credential-free answer template, and `windows.psd1`. In UEFI WinPE, the installer selects the sole target disk, or unpartitioned disk 0 when multiple targets exist, calculates the configured sizes, generates an answer in the WinPE RAM drive, and starts Windows Setup. Otherwise, disk selection and partitioning stay in the standard Setup UI. Windows Setup performs the disk operations. The generated name uses the configured prefix and a fresh seven-character random suffix. No custom input screens or account-creation scripts are used.

OOBE skips the network screen with `HideWirelessSetupInOOBE` and uses `HideOnlineAccountScreens` for local account creation. Configure networking after the first sign-in. Username and password are entered only through native OOBE. No user credentials, AutoLogon, or first-logon commands are included. Setup Dynamic Update is disabled to use the pinned payload; normal Windows Update is tested afterward. Windows SIM validation checks the generated answer against the matching source catalog; a fresh installation must verify actual OOBE behavior. See Microsoft's [WinPE PowerShell prerequisites](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-adding-powershell-support-to-windows-pe), [startup configuration](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpeshlini-reference-launching-an-app-when-winpe-starts), [OOBE account setting](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oobe-hideonlineaccountscreens), and [network-screen setting](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oobe-hidewirelesssetupinoobe).

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/build-install-media.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/install-media'
```

The fixed output is `.local/media/windows11-pro/windows11-pro.iso`, with `operation.json`, `image.json`, a per-file hash manifest, and the boot order alongside it. The operation record includes the input WIM hash and the compressed payload's path, hash, size, and compression type. The script recreates its own output directory, refuses an attached ISO or media referenced by a VM, and locks the WIM build directory while packaging. Its free-space check budgets two copies of the payload/Setup files plus scratch space; the staging tree is removed after verification. Read the [DISM export options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14#export-image) and [Oscdimg options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options) for compression, boot entries, hidden files, and file ordering.

## Prepare the test VM

[`new-test-vm.ps1`](new-test-vm.ps1) checks host resources and pinned inputs, then creates the isolated Hyper-V VM and a new VHDX. Only the baseline gets private answer-file media. `-CheckOnly` performs preflight; creation leaves the VM powered off and refuses existing installations. [`validate-vm-setup.ps1`](validate-vm-setup.ps1) checks the VM and validates its applicable answer against the exported Pro WIM using Windows SIM. See [Stage 2](../docs/stage-02.md) for baseline commands and credential handling.

`-VMProfile Configured` uses the deployment ISO at image index 1 and creates `Windows11-Pro-Test-Configured` under `.local/vm/windows11-pro-configured`. Its dynamic disk uses `ConfiguredDiskBytes` to exercise C/D sizing. No test account or answer ISO is generated: the installation follows the production setup and native OOBE. Supply the OOBE account as `-Credential` to `run-vm-baseline.ps1` for host-side audit access. The baseline retains its existing private answer media and credentials. Configured creation requires the baseline VM to remain off with its recorded checkpoint intact and 40 GiB free after packaging; baseline creation retains its 60 GiB reserve. Neither profile reuses an existing VM or disk. Windows SIM validates the production-generated answer for the configured profile using the matching cached source catalog.

Pass the same `-VMProfile Configured` to `validate-vm-setup.ps1` and `run-vm-baseline.ps1`. Validation reports go to `.local/vm-configured-validation`; inspection and audit reports go to `.local/vm-configured`. `-Action Audit` defaults to the report label `configured`; `-Action Capture` collects `configured` and `configured-repeat` and saves `configured-audited`. The default `Baseline` profile retains its existing paths and source ESD index. See the [build plan](../docs/build-plan.md) for the exact invocations.

Configured capture requires exit 0 from both audits before creating a checkpoint. The first capture requires a running desktop shell as evidence of first sign-in. Later collections can use the recorded checkpoint ID on the same VM as first-sign-in evidence, so a fresh GUI sign-in is not required after every boot. Setup completion, OS identity, privileges, GPT, WinRE, disk ancestry, and disconnected networking are still checked.

The initial capture requires the pinned source version. After the configured checkpoint is saved, `-Action Audit` accepts newer Windows versions on that same recorded VM for update verification. Install updates normally and restart as needed, then disconnect the test network before using the host-side helper. Supply the OOBE account with `-Credential`; standalone `audit.ps1` does not depend on Hyper-V or disconnected networking.

## Audit installed Windows

[`run-vm-baseline.ps1`](run-vm-baseline.ps1) starts the prepared VM or uses PowerShell Direct to inspect and audit its installed system. `-Action Capture` performs repeated baseline collection, stable-state comparison, graceful shutdown, media detachment, and checkpoint capture in one elevated operation. It follows the recorded VHDX's checkpoint chain and refuses unrelated disks. See [Stage 2](../docs/stage-02.md) for the workflow.

`-Action Limited` verifies non-elevated collection using a restricted process under the same guest account. The helper checks for explicit scope/privilege limitations and expects the audit's incomplete-verification exit bit. It preserves the clean checkpoint and restores the VM's prior power state after starting an initially stopped VM.

[`audit.ps1`](audit.ps1) collects installed-system state without applying changes, compares explicit configuration rules, and writes JSON/Markdown reports under `.local/audit`. Use a fresh 64-bit Windows PowerShell 5.1 process; full collection requires administrator privileges, and limited access is reported explicitly. See the [audit guide](../docs/audit.md) for invocations, exit codes, report schema, fixture tests, and VM checks. Live collection on the current computer is not a prerequisite.

## Run an elevated operation

`run-elevated.ps1` launches a repository script in a separate Windows PowerShell process through UAC. Script parameters are passed as data in a local CLIXML file. The launcher cleans its previous logs before starting and refuses to clean a directory used by an active launch or child process. Log directories must be directly under `.local/launches`; the default is `.local/launches/catalog`. Do not pass secrets as parameters or write them to the transcript.

## Export the component catalog

Install the Deployment Tools version pinned in `config/toolchain.lock.json`. The exporter verifies the recorded ISO and tool hashes, uses that ADK's DISM module and native API, and validates the selected source image before exporting it.

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/export-image-catalog.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711' } -LogDirectory '.local/launches/catalog'
```

Output directories must be directly under `.local/catalog`. The exporter refuses to clean an active export or registered WIM mount, removes the previous working directory, then requires at least 20 GiB free. It creates `pro.wim`, mounts index 1 read-only, queries Optional Features, Windows Capabilities, and provisioned Appx, then discards the mount and detaches its ISO attachment. Working files remain locally until the next run cleans them.

`operation.json` records progress, errors, and cleanup. Use `catalog.json` and `selections.psd1` only after the operation status is `Succeeded` and cleanup has completed. The selection template contains one commented identifier-to-state pair for every discovered component. Features use `Enabled`/`Disabled`; capabilities and inbox apps use `Present`/`Absent`. It does not change the active configuration. App dependency review is still required before any removals; the provisioning catalog is not a complete dependency graph or a list of every system app.

The source image index is taken from `source-image.lock.json`; the working WIM contains only that image, at index 1. Raw DISM diagnostics and working files stay under `.local`; only reviewed catalog and configuration artifacts belong in Git.

## Inspect the source ISO

`inspect-source.ps1` reads all image indexes from `sources/install.wim` or `sources/install.esd` and records edition, architecture, version, and language. It does not mount or service the Windows installation image.

Run it through `run-elevated.ps1` and approve the Windows UAC prompt. The inspection reuses `.local/source-inspection`, cleans previous results, and refuses a concurrent inspection. The source ISO must remain outside this working directory.

From the repository root:

```powershell
$sourceLock = Get-Content -LiteralPath config/source-image.lock.json -Raw | ConvertFrom-Json
.\scripts\run-elevated.ps1 -ScriptPath scripts/inspect-source.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\source-inspection'; ExpectedSha256 = $sourceLock.iso.sha256 } -LogDirectory '.local/launches/inspection'
```

The script verifies the ISO against the recorded local fingerprint, temporarily attaches it read-only if needed, and detaches only attachments it created. This fingerprint check does not independently authenticate the download source.

Results are written to `inspection.json`; DISM diagnostics stay in the same output directory. Exit code 0 means inspection and required cleanup succeeded; exit code 1 indicates a failure. Review `status`, `error`, and `cleanupError` before using any image metadata. Startup errors such as missing administrator privileges can occur before a report is created.
