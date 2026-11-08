# Windows configuration

`windows.psd1` records the desired component and policy configuration consumed by `build-image.ps1` and the independent installed-system audit. Read it with `Import-PowerShellDataFile` rather than executing it as a script.

## Local policies

The `Policies` map selects registry-backed local GPO settings. `Verification = 'LocalGpo'` requires the prepared Machine/User policy file and processing metadata, then matching installed registry state. The builder compiles the files directly into the WIM using the pinned LGPO tool; the installed system needs no project setup script or LGPO executable. Only reviewed DWORD rules are currently supported for offline compilation. Existing source policies are refused rather than overwritten. See [Stage 3](../docs/stage-03.md) for scope and verification limits.

## Deployment

`Deployment` defines the computer-name prefix and disk sizing used by the installation media. C is the nearest configured power-of-two size to `WindowsFraction` of total disk capacity, with ties upward. `WindowsSizesGiB` bounds the result. D equals C when it fits after EFI, MSR, C, and Windows RE; remaining capacity stays unallocated. `EfiMiB`, `MsrMiB`, and `RecoveryMiB` set the service partition sizes. Setup uses its default 1 MiB alignment and NTFS settings for C/D.

The WinPE installer uses the sole target disk, or unpartitioned disk 0 when several targets exist. Otherwise it leaves selection and partitioning to Windows Setup. It generates the answer file automatically and leaves account creation to OOBE; account credentials do not belong in this configuration. See the [deployment requirements](../docs/requirements.md#deployment-flow).

## Architecture

The deployment architecture is set separately in `Architecture`: the initial profile uses `x64`. Validate the source image architecture against this value before generating the catalog or building installation media.

## Localization

Keep `Localization.UiLanguage` set to `en-US`. Add input locales in `Localization.InputLocales`; the first entry is the default. A commented Russian layout is included as an example. Additional layouts must not change the Windows display language or implicitly install display language packs.

Input locale values follow the Windows Setup [InputLocale format](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-international-core-inputlocale).

## Component selection

Use indexes to refer to the components in each category:

| Category | Desired states | Meaning |
| --- | --- | --- |
| Optional Features | `Enabled` / `Disabled` | Enable or disable a Windows feature |
| Windows Capabilities | `Present` / `Absent` | Require an installed or absent capability, using its complete identifier |
| Inbox Appx/MSIX | `Present` / `Absent` | Require an image-provided app to remain provisioned or be removed |

An active entry requests its explicit desired state. A commented or omitted entry is unmanaged; commenting out a rule does not undo an earlier change. Change the value on the existing key to select a different state. Reject duplicate identifiers and unsupported state values. Unselected inbox apps retain their image defaults. `Present` for an inbox app concerns the package from the selected image; it does not request external software installation.

WSL, Hyper-V, and the native `Containers` platform feature are selected initially. Check image support and hardware prerequisites before applying them. WSL runtime packaging and updates are separate concerns; no Linux distribution is selected or bundled.

The `Containers` selection enables the Windows container platform. It does not install a container runtime, management CLI, or container images, and it does not provide a Linux container environment by itself. Runtime provisioning remains a separate decision. Audit feature enablement separately from the ability to run an actual container. When runtime execution is tested inside the Stage 2 VM, verify the necessary nested virtualization support for Hyper-V isolation.

Microsoft documents the platform and runtime prerequisites in [Prepare Windows operating system containers](https://learn.microsoft.com/en-us/virtualization/windowscontainers/quick-start/set-up-environment).

## Complete image catalog

The complete [catalog](catalogs/pro-26300.9711/catalog.json) and [commented selection template](catalogs/pro-26300.9711/selections.psd1) were generated from the pinned Windows 11 Pro image, version 10.0.26300.9711, x64, en-US, ESD index 6. They contain 138 Optional Features, 424 Windows Capabilities, and 47 provisioned Appx packages. Active identifiers and desired state values in `windows.psd1` are checked against this catalog.

[`export-image-catalog.ps1`](../scripts/export-image-catalog.ps1) captures the Optional Features, Windows Capabilities, and provisioned Appx exposed by the selected image, their source states, and image identity. The catalog describes what Windows reports; it does not guarantee that every payload is contained in the ISO or that every item can safely be removed. The provisioned app list is not a complete dependency graph or a list of every system app.

The exporter also generates an editable selection template with every discovered identifier commented out, grouped by the actions above. The template is a proposal, not a second active configuration. Copy selected entries into `windows.psd1`, preserving existing choices when refreshing a catalog. Framework packages and app dependencies must be identified before selecting removals.

The source ISO hash, image index, edition, build, architecture, and language are recorded alongside the catalog. Validate active selections against that catalog; do not silently substitute or ignore unavailable identifiers.

Official inventory interfaces:

- [Get-WindowsOptionalFeature](https://learn.microsoft.com/en-us/powershell/module/dism/get-windowsoptionalfeature)
- [Get-WindowsCapability](https://learn.microsoft.com/en-us/powershell/module/dism/get-windowscapability)

## Desktop selections

`windows.psd1` defines the desktop profile applied to a separate working image by [build-image.ps1](../scripts/build-image.ps1). These are project defaults, not a claim that these apps are unnecessary for every desktop.

| Selection | Reason and effect |
| --- | --- |
| Keep WSL, VirtualMachinePlatform, Hyper-V, and Containers enabled | Preserve the agreed virtualization and native container platform. |
| Disable Work Folders | No corporate Work Folders server is part of this profile. |
| Remove the Windows Media Player Legacy capability | Use the retained modern Media Player (`Microsoft.ZuneMusic`); leave `MediaPlayback` and the image's codecs unchanged. Capability removal also removes the `WindowsMediaPlayer` Optional Feature identifier in this image, so it has no separate feature rule. Legacy-player integrations need a separate compatibility check. |
| Keep IIS, WAS, MSMQ, AD LDS, and NFS disabled | No local web, FTP, message queue, directory server, or NFS scenario is selected. These features are already disabled in the source. |
| Keep SMB1, Simple TCP/IP services, Telnet, TFTP, LPD/LPR, XPS printing, DirectPlay, and Recall disabled | These scenarios are outside the initial desktop profile and already disabled in the source. Standard file sharing, printing, and Print to PDF retain their defaults. |
| Remove Clipchamp, News, Weather, Office Hub, Outlook, Power Automate, To Do, Dev Home, Feedback Hub, Phone Link, and Teams | Exclude additional content, account-connected apps, automation, and phone integration from the base installation. These can be selected individually later. |
| Remove Solitaire, Xbox app, Game Bar, Xbox TCUI, Xbox Identity Provider, and Xbox Speech to Text Overlay | Gaming components are explicitly excluded by the user. Xbox sign-in, Game Bar capture, and its accessibility overlay will be unavailable unless restored. |

The 424 capabilities include 337 language/font entries, 30 inbox network driver entries, and 57 other entries. Uninstalled language packs and administration tools are left unmanaged rather than described as removals. Keep English OCR, speech, handwriting, text-to-speech, Windows Hello, network drivers, DirectX configuration, system Notepad, PowerShell ISE, OneSync, OpenSSH Client, print management, VBScript, and security capabilities at their source defaults. Microsoft's [Features on Demand guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod) recommends retaining many preinstalled capabilities; a component's age or name alone is insufficient grounds for removal.

The remaining 30 provisioned apps keep their defaults, including Store, Store Purchase App, App Installer, Windows Security, Terminal, Notepad, Calculator, Paint, Photos, Snipping Tool, modern Media Player, codecs, Clock, Camera, Sound Recorder, Sticky Notes, Get Help, and Quick Assist. Bing Search, Windows Web Experience, Cross Device, and Application Compatibility Enhancements are retained pending a separately justified change; removing Phone Link does not imply removing every related system component. Shared framework dependencies are not selected for removal.

Microsoft documents the legacy player as an [optional Windows component](https://support.microsoft.com/en-us/windows/apps/windowsmediaplayer/troubleshoot-windows-media-player-errors). Its [inbox app removal list](https://learn.microsoft.com/en-us/windows/configuration/policy-based-inbox-app-removal/policy-based-inbox-app-removal) includes several of the selected consumer apps. That removal policy requires Enterprise or Education; the Pro implementation uses offline [DISM provisioning operations](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-app-package--appx-or-appxbundle--servicing-command-line-options). These interfaces do not prove dependency safety for this image. [build-image.ps1](../scripts/build-image.ps1) reviews app manifests and declared reverse dependencies before servicing a working WIM and preserves unselected provisioned apps. A fresh VM installation and independent audit must validate the resulting system.

Verification must compare feature states, installed capabilities, and provisioning against every active rule. After first sign-in and again after an update, also check selected apps by package identity across user registrations, allowing for Store version changes; absence from provisioning alone does not prove absence for existing users. Record collection failures separately from noncompliance. Offline servicing checks are recorded in the build output; installed-system validation uses the independent audit in the configured VM.
