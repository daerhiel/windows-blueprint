# Installation requirements

Status: initial user decisions recorded. "Not defined" indicates an open decision, not a default value. The initial configuration is stored in [`config/windows.psd1`](../config/windows.psd1); its selection rules are described in the [configuration guide](../config/README.md).

[Design intent and open questions](design-questions.md) preserves unresolved ideas from the original discussion, current implementation boundaries, and decisions still needed about ongoing maintenance. Those entries are not additional accepted requirements or a delivery roadmap.

## Accepted decisions

| Topic | Decision |
| --- | --- |
| OS source | Official Microsoft ISO |
| Base edition | Windows 11 Pro |
| Enterprise | Separate profile when specific supported policies are needed |
| Installation type | Clean installation |
| Configuration source | Git |
| Preparation and installation | DISM and `autounattend.xml` |
| Policy delivery | Local GPOs compiled into the prepared image and processed by Windows after installation |
| Result verification | Independent audit, including verification after updates |
| System services and CBS packages | Manual stripping is excluded |
| Portability | Use a generic base image; the first physical target is the current computer |
| Drivers and vendor utilities | Do not inject additional drivers or vendor utilities into the base image |
| Existing apps and settings | Do not migrate them from the current installation |
| Application scope | Only image-provided apps are in scope; external app installation is excluded for now |

## Stage 1 decisions

| Topic | Value |
| --- | --- |
| Target computer | Current computer first; deployment must also support other compatible machines |
| Architecture and localization | Selected in `windows.psd1`; validate source compatibility and keep input layouts separate from the display language |
| Application and component selection | Selected in `windows.psd1` against the source catalog; retain unmanaged image defaults and validate dependencies in the VM |
| WSL distribution and runtime | No distribution bundled; runtime provisioning and versioning remain to be decided |
| Container runtime | Runtime, CLI, and container images are not selected or bundled; external software remains outside the current app scope |
| Other Windows features and capabilities | Select from complete catalogs of the chosen image rather than a short questionnaire |
| Hardware-specific customization | No hardware-specific additions to the base image |
| Current installation inventory | Not required as a baseline; do not derive desired state from this machine |

Document a verification method for each selected capability. An unanswered
question or commented-out entry does not mean the capability should be disabled.

## Catalog and audit purposes

- The source image catalog lists Optional Features, Windows Capabilities, and provisioned apps available for selection. Generate editable, commented templates from the chosen image, not from the current installation.
- The installed-system audit checks whether the deployed system matches the configuration and detects drift after updates. Capture its first clean baseline in the Stage 2 VM.
- Inspecting the current installation is optional troubleshooting, not a prerequisite or a source of application migration requirements.
- Distinguish image-reported component availability from payload availability. Additional matching sources may be required to install selected capabilities.
- Enabling WSL prerequisites does not by itself prove that a usable WSL runtime or Linux distribution has been installed. Verify those separately if selected.
- Enabling `Containers` does not prove that a runtime can execute containers. Audit the Windows platform feature separately from any later runtime tests.

## Decisions required before VM installation

The user-supplied ISO is currently located at `D:\temp\windows.iso`. Its computed size, SHA-256, selected image metadata, and user-reported origin through Media Creation Tool are recorded in [`config/source-image.lock.json`](../config/source-image.lock.json). No independent published ISO checksum has been recorded. See the [build plan](build-plan.md) for the action sequence.

The source lock records the selected image's path, index, edition, architecture, version, and language. Read-only inspection verifies the ISO fingerprint and detaches its attachment after reading metadata.

- Independent authentication of the ISO, if evidence beyond user-reported Media Creation Tool origin becomes available; keep the local fingerprint distinct from provenance evidence.
- Deployment Tools, WinPE dependencies, and binary fingerprints are pinned in [toolchain.lock.json](../config/toolchain.lock.json). Select and pin additional tools before using them.
- Hyper-V VM settings, a generated local administrator account, and offline baseline timing are defined in [Stage 2](stage-02.md). Complete Windows SIM validation and verify the installed system before applying component rules.
- WSL runtime source and versioning if a runtime is provisioned in addition to enabling platform features; no Linux distribution is selected by default.
- Dependency and compatibility validation of the [selected component rules](../config/windows.psd1) before applying them.
- Whether to test actual container execution in this iteration. If selected, define the runtime, compatible test image, sources, versions, and VM nested virtualization requirements separately from native feature enablement.

## Deployment flow

Installation uses Windows Setup and a generated unattended answer file without custom interactive prompts. Create the local user through the standard OOBE account page; do not embed a user name, password, or AutoLogon configuration in the image.

Automatic disk preparation targets a single disk. If only one target disk is present, use it. If multiple target disks are present, use disk 0 only when it has no partitions. Otherwise, leave disk selection and partitioning to the standard Windows Setup UI, without automatic wiping or the project's C/D sizing. Exclude the installation medium from target disks. Failure to inspect partitions is not evidence that a disk is unpartitioned.

For automatic preparation, calculate the configured partition sizes in WinPE and pass the resulting disk configuration to Windows Setup through the answer file. Windows Setup creates and formats the partitions.

Use UEFI/GPT with EFI, MSR, C, Windows RE, optional D, and the remaining space unallocated. Calculate C from the disk-capacity fraction and allowed sizes in `Deployment.Disk`, rounding to the nearest allowed size with ties upward. D equals C when it fits after the service partitions; otherwise omit it. C and D use NTFS defaults. Service partition sizes and alignment also come from `Deployment.Disk`.

Generate a fresh computer name using the configured prefix and a random suffix for each installation. Apply the configured localization and keep the user account page available. OOBE behavior is defined by the [deployment answer template](../setup/deployment/autounattend.xml), and selected policies are defined in [windows.psd1](../config/windows.psd1). Normal Windows Update follows installation; activation is handled separately.

The first user is a local administrator created in OOBE. Microsoft account linking is allowed afterward. Retain standard BitLocker/device-encryption behavior; recovery-key backup to the Microsoft account requires the authenticated post-installation flow. Neither the builder nor audit collects recovery keys.

Deliver selected account policies through the image's local GPO and verify them with the independent audit. Verify their effect on account-creation screens during a fresh OOBE run; account creation remains native OOBE.

Development media retain the Fast-compressed installation WIM. Do not export an ESD during development; final compression is a separate, explicit option.

## Decisions required before physical installation

- Verify that the target disk satisfies the automatic selection rule, or select and partition it through Windows Setup.
- A data backup and verification that restoration is possible.
- Partitioning, encryption, and storage of recovery keys outside the repository.
- Post-install driver provisioning and hardware verification scenarios; keep additional drivers and vendor utilities outside the generic base image.

Disk partitioning and wiping are outside the scope of Stage 1.
