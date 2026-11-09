# Reproducible Windows 11 installation

This project aims to provide a reproducible clean installation of Windows 11 from an official Microsoft ISO, with configuration stored in Git and an independent audit of the resulting system state.

Pro is the base edition. Enterprise is considered as a separate profile for specific capabilities unavailable in Pro.

The source image must match the deployment architecture selected in [windows.psd1](config/windows.psd1).

## Principles

- DISM and `autounattend.xml` handle image preparation and installation.
- Selected local GPOs are compiled into the image; Windows applies them after installation.
- An independent audit checks actual state and detects changes after updates.
- System services and CBS packages are not manually stripped out.
- Reproducibility means the same verifiable state from the same inputs. Byte-for-byte ISO identity is not currently a requirement.
- Git stores configuration, code, and dependency metadata. Do not commit ISOs, tools, drivers, temporary files, reports containing machine data, or secrets.
- Keep the base image generic: do not inject additional drivers or vendor utilities, and do not migrate apps from the current installation.
- Keep the Windows display language in English; configure additional input layouts separately.

## Current stage

[Stage 1: requirements and initial inventory](docs/stage-01.md) is complete. Requirements and the desktop proposal are recorded, source inspection and catalog export have run successfully, and the installed-system audit has passed local fixture checks. Live collection and component verification are tracked in Stage 2.

[Stage 2: clean VM and integration checks](docs/stage-02.md) established the component-only image and installation/audit cycle. Clean baseline and limited-user checks passed; repeated configured audits matched, with `configured-audited` saved.

[Stage 3: policies in the prepared image](docs/stage-03.md) integrates local GPO compilation into the existing WIM build and verification. The initial Pro rules address advertising and suggestions. A fresh installation passed repeated independent audits of component state, local GPO delivery, and registry values. Windows Update verification follows the complete configuration and deployment profile.

The [deployment flow](docs/requirements.md#deployment-flow) adds automatic disk sizing through Windows Setup and local-user creation through native OOBE. Development media use the Fast-compressed WIM. A fresh installation passed matching independent audits of the selected components, expanded privacy policies, and deployment profile; the pre-update `configured-audited` checkpoint is preserved. Post-update audits passed the configured checks, including after a further restart, with no remaining reboot indicators.

The current [windows.psd1](config/windows.psd1) passed fresh-installation and post-update audits, including verification of referenced policy files. Generated reports identify the exact configuration verified. The observed paused deployment of a selected removed app was traced to a separate system-initiated acquisition request. Removing source-image provisioning does not block later online acquisition; the audit's absence checks continue to assess provisioning and installed registrations.

[Requirements](docs/requirements.md) records accepted decisions and open questions. The [design questions](docs/design-questions.md) preserve the original intent, unresolved maintenance questions, and current implementation boundaries without defining an implementation roadmap. The [configuration guide](config/README.md) describes the initial profile and the captured component selection catalog.

The [component selection template](config/catalogs/pro-26300.9711/selections.psd1) contains the full exported component list for the selected image.

[Supporting scripts](scripts/README.md) describes initial source inspection, worker implementations, and the optional elevation launcher.

[Operator workflows](workflows/README.md) provides the tool-preparation, source-preparation, build, and test-VM entry points and the standalone saved-audit comparison utility. Source preparation keeps the original WIM, component catalog, and commented selection template together, including when starting with an empty `.local`. The [operational automation map](docs/automation-review.md) records their composition and cleanup boundaries.

[Installed-system audit](docs/audit.md) describes collection scope, configuration checks, JSON/Markdown reports, exit codes, and the Stage 2 VM verification sequence.

The [build plan](docs/build-plan.md) provides sequential preparation, build, and VM verification instructions. The supplied ISO fingerprint and selected Pro image are pinned in [`config/source-image.lock.json`](config/source-image.lock.json); independent source verification is still pending.

[Build a separate configured WIM and installation ISO](workflows/README.md#build), perform a fresh VM installation, and verify it with the independent audit before and after updates. Deployment to a physical computer follows verification of this cycle.

## Documentation and agent instructions

Maintain project documentation and code comments in English, as specified in [AGENTS.md](AGENTS.md).

## Source material

The [previous conversation](docs/context.md) is preserved in its original language as historical reference material. Verify product versions and technical claims before using them; this file is not a project specification.
