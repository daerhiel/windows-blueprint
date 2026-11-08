# Installation requirements

Status: initial user decisions recorded. "Not defined" indicates an open decision, not a default value. The initial configuration is stored in [`config/windows.psd1`](../config/windows.psd1); its selection rules are described in the [configuration guide](../config/README.md).

## Accepted decisions

| Topic | Decision |
| --- | --- |
| OS source | Official Microsoft ISO |
| Base edition | Windows 11 Pro |
| Enterprise | Separate profile when specific supported policies are needed |
| Installation type | Clean installation |
| Configuration source | Git |
| Preparation and installation | DISM and `autounattend.xml` |
| Installed OS configuration | LGPO and idempotent PowerShell |
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
| Architecture | x64; use an x64 source ISO and validate that the selected image matches |
| Windows display language | English (United States), `en-US`; remains English when layouts are added |
| Input locales | `en-US` by default; additional layouts are editable in `Localization.InputLocales` |
| Required apps | No existing apps to migrate; retain unselected image apps, including basic desktop utilities, Store, security UI, and codecs |
| Unwanted apps | Initial desktop proposal selects 17 provisioned apps for removal, including Xbox and Game Bar; see [desktop selections](../config/README.md#desktop-selections); validate dependencies and behavior in the VM |
| WSL / virtualization | Enable WSL and virtualization platform features; use Hyper-V as the initial VM feature selection |
| WSL distribution and runtime | No distribution bundled; runtime provisioning and versioning remain to be decided |
| Native Windows containers | Enable the `Containers` Optional Feature alongside Hyper-V; validate support in the selected image |
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

Elevated read-only inspection selected Windows 11 Pro (`Professional`) at index 6 in `sources/install.esd`: version `10.0.26300.9711`, x64, default language `en-US`. The helper rechecked the ISO fingerprint and detached the ISO after reading metadata.

- Independent authentication of the ISO, if evidence beyond user-reported Media Creation Tool origin becomes available; keep the local fingerprint distinct from provenance evidence.
- Deployment Tools 10.1.26100.9457 and key binary hashes are pinned in [toolchain.lock.json](../config/toolchain.lock.json). Select and pin any additional tools, including a WinPE add-on if needed, before using them.
- Hyper-V VM settings, a generated local administrator account, and offline baseline timing are defined in [Stage 2](stage-02.md). Complete Windows SIM validation and verify the installed system before applying component rules.
- WSL runtime source and versioning if a runtime is provisioned in addition to enabling platform features; no Linux distribution is selected by default.
- Dependency and compatibility validation of the [initial desktop selections](../config/README.md#desktop-selections) in the baseline VM before applying them.
- Whether to test actual container execution in this iteration. If selected, define the runtime, compatible test image, sources, versions, and VM nested virtualization requirements separately from native feature enablement.

## Decisions required before physical installation

- The target disk and a verifiable method for selecting it in the installer.
- A data backup and verification that restoration is possible.
- Partitioning, encryption, and storage of recovery keys outside the repository.
- Post-install driver provisioning and hardware verification scenarios; keep additional drivers and vendor utilities outside the generic base image.

Disk partitioning and wiping are outside the scope of Stage 1.
