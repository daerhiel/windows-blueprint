# Windows configuration

`windows.psd1` records the desired component and policy configuration consumed by `build-image.ps1` and the independent installed-system audit. Read it with `Import-PowerShellDataFile` rather than executing it as a script.

## Local policies

The `Policies` map selects registry-backed local GPO settings. `Verification = 'LocalGpo'` requires the prepared Machine/User policy file and processing metadata, then matching installed registry state. The builder compiles the files directly into the WIM using the pinned LGPO tool; the installed system needs no project setup script or LGPO executable. Reviewed DWORD and expandable-string rules are supported for offline compilation. Existing source policies are refused rather than overwritten. See [Stage 3](../docs/stage-03.md) for scope and verification limits.

For a native policy that references a JSON file, `FileContent` stores that file's text alongside the policy rule. The builder writes it at the rule's configured path under the local Group Policy directory, and saved-image verification and the installed-system audit check its contents. Start layout settings follow Microsoft's [Configure Start Pins format](https://learn.microsoft.com/en-us/windows/configuration/start/layout). A layout configured for one-time application initializes the user's pins without resetting later user changes; the audit checks delivery of the initial configuration, not the user's current pin choices.

## Deployment

`Deployment` defines the computer-name prefix and disk sizing used by the installation media. C is the nearest configured power-of-two size to `WindowsFraction` of total disk capacity, with ties upward. `WindowsSizesGiB` bounds the result. D equals C when it fits after the service partitions; remaining capacity stays unallocated. Service partition sizes and alignment come from `Deployment.Disk`; Windows Setup uses NTFS defaults for C/D.

The WinPE installer uses the sole target disk, or unpartitioned disk 0 when several targets exist. Otherwise it leaves selection and partitioning to Windows Setup. It generates the answer file automatically and leaves account creation to OOBE; account credentials do not belong in this configuration. See the [deployment requirements](../docs/requirements.md#deployment-flow).

## Architecture

`Architecture` selects the deployment architecture. Validate the source image architecture against this value before generating the catalog or building installation media.

## Localization

`Localization.UiLanguage` sets the Windows display language. Add input locales in `Localization.InputLocales`; the first entry is the default. Additional layouts must not change the Windows display language or implicitly install display language packs.

Input locale values follow the Windows Setup [InputLocale format](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-international-core-inputlocale).

## Component selection

Use indexes to refer to the components in each category:

| Category | Desired states | Meaning |
| --- | --- | --- |
| Optional Features | `Enabled` / `Disabled` | Enable or disable a Windows feature |
| Windows Capabilities | `Present` / `Absent` | Require an installed or absent capability, using its complete identifier |
| Inbox Appx/MSIX | `Present` / `Absent` | Require an image-provided app to remain provisioned or be removed |

An active entry requests its explicit desired state. A commented or omitted entry is unmanaged; commenting out a rule does not undo an earlier change. Change the value on the existing key to select a different state. Reject duplicate identifiers and unsupported state values. Unselected inbox apps retain their image defaults. `Present` for an inbox app concerns the package from the selected image; it does not request external software installation.

When selecting virtualization features, check image support and hardware prerequisites before applying them. WSL runtime packaging and distribution provisioning are separate concerns from platform feature enablement.

The `Containers` selection enables the Windows container platform. It does not install a container runtime, management CLI, or container images, and it does not provide a Linux container environment by itself. Runtime provisioning remains a separate decision. Audit feature enablement separately from the ability to run an actual container. When runtime execution is tested inside the Stage 2 VM, verify the necessary nested virtualization support for Hyper-V isolation.

Microsoft documents the platform and runtime prerequisites in [Prepare Windows operating system containers](https://learn.microsoft.com/en-us/virtualization/windowscontainers/quick-start/set-up-environment).

## Complete image catalog

The complete [catalog](catalogs/pro-26300.9711/catalog.json) and [commented selection template](catalogs/pro-26300.9711/selections.psd1) are generated from the pinned source image. The catalog records image metadata and available identifiers; [windows.psd1](windows.psd1) selects the desired state.

[`export-image-catalog.ps1`](../scripts/export-image-catalog.ps1) captures the Optional Features, Windows Capabilities, and provisioned Appx exposed by the selected image, their source states, and image identity. The catalog describes what Windows reports; it does not guarantee that every payload is contained in the ISO or that every item can safely be removed. The provisioned app list is not a complete dependency graph or a list of every system app.

The exporter also generates an editable selection template with every discovered identifier commented out, grouped by the actions above. The template is a proposal, not a second active configuration. Copy selected entries into `windows.psd1`, preserving existing choices when refreshing a catalog. Framework packages and app dependencies must be identified before selecting removals.

The source ISO hash, image index, edition, build, architecture, and language are recorded alongside the catalog. Validate active selections against that catalog; do not silently substitute or ignore unavailable identifiers.

Official inventory interfaces:

- [Get-WindowsOptionalFeature](https://learn.microsoft.com/en-us/powershell/module/dism/get-windowsoptionalfeature)
- [Get-WindowsCapability](https://learn.microsoft.com/en-us/powershell/module/dism/get-windowscapability)

## Selection verification

The active selections live only in [windows.psd1](windows.psd1). Review app manifests and declared reverse dependencies before removing packages; do not remove shared frameworks required by retained apps. The catalog is an input inventory, not a dependency-safety guarantee.

The builder applies the selected rules through supported offline DISM servicing and preserves unmanaged provisioned apps. See Microsoft's [offline Appx servicing reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-app-package--appx-or-appxbundle--servicing-command-line-options). Payload availability and dependency checks must pass before saving the image.

Verification compares feature states, capabilities, provisioning, and user app registrations against the active configuration. Match selected apps by package family so Store version changes do not hide drift. Absence from provisioning alone does not prove absence for existing users. Record collection failures separately from noncompliance. Build and audit reports remain under `.local`; they carry the actual inventories and results.
