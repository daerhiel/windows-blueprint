# Reproducible Windows 11 installation

This project aims to provide a reproducible clean installation of Windows 11 from an official Microsoft ISO, with configuration stored in Git and an independent audit of the resulting system state.

Pro is the base edition. Enterprise is considered as a separate profile for specific capabilities unavailable in Pro.

The initial deployment profile targets x64 machines and requires an x64 source image.

## Principles

- DISM and `autounattend.xml` handle image preparation and installation.
- LGPO and idempotent PowerShell configure the installed system.
- An independent audit checks actual state and detects changes after updates.
- System services and CBS packages are not manually stripped out.
- Reproducibility means the same verifiable state from the same inputs. Byte-for-byte ISO identity is not currently a requirement.
- Git stores configuration, code, and dependency metadata. Do not commit ISOs, tools, drivers, temporary files, reports containing machine data, or secrets.
- Keep the base image generic: do not inject additional drivers or vendor utilities, and do not migrate apps from the current installation.
- Keep the Windows display language in English; configure additional input layouts separately.

## Current stage

[Stage 1: requirements and initial inventory](docs/stage-01.md) is complete. Requirements and the desktop proposal are recorded, source inspection and catalog export have run successfully, and the installed-system audit has passed local fixture checks. Live collection and component verification are tracked in Stage 2.

[Stage 2: clean VM and integration checks](docs/stage-02.md) is in progress. Clean baseline and limited-user checks passed. The configured recovery-compressed ISO was installed in the separate offline VM; two installed-system audits each passed all 67 checks and matched on stable inventory fields. The `configured-audited` checkpoint is saved. Update verification remains pending.

[Requirements](docs/requirements.md) records accepted decisions and open questions.
The [configuration guide](config/README.md) describes the initial profile and the captured component selection catalog.

The [Pro component selection template](config/catalogs/pro-26300.9711/selections.psd1) contains the full exported list for the selected image: 138 Optional Features, 424 Windows Capabilities, and 47 provisioned Appx.

[Preparation scripts](scripts/README.md) describes source inspection and how to run the required elevated helper.

[Installed-system audit](docs/audit.md) describes collection scope, configuration checks, JSON/Markdown reports, exit codes, and the Stage 2 VM verification sequence.

[build operations log](docs/build-log.md) records preparation and build actions in execution order. The supplied ISO fingerprint and selected Pro image are pinned in [`config/source-image.lock.json`](config/source-image.lock.json); independent source verification is still pending.

After capturing the clean Pro baseline, [build a separate configured WIM](scripts/README.md#build-the-configured-image), perform a fresh VM installation, and verify it with the independent audit before and after updates. Deployment to a physical computer follows verification of this cycle.

## Documentation and agent instructions

Maintain project documentation and code comments in English, as specified in [AGENTS.md](AGENTS.md).

## Source material

The [previous conversation](docs/context.md) is preserved in its original language as historical reference material. Verify product versions and technical claims before using them; this file is not a project specification.
