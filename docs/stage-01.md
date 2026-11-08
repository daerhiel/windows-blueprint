# Stage 1. Requirements and initial inventory

Plan recorded: 2026-11-07.

Status: complete for Stage 1 tool preparation. The pinned Pro image has been cataloged, the desktop proposal is recorded, and the installed-system audit is implemented and verified with synthetic data and stub Windows APIs. Live collection, dependency validation, and application/removal behavior are tracked as [Stage 2 VM integration checks](stage-02.md).

## Objective

Define a portable installation scenario, prepare a complete selection catalog
from the chosen official image, and implement an independent installed-system
audit. The audit will compare deployed Windows against explicit requirements
and detect drift after updates. The existing installation is not the baseline.

## Scope

This stage includes:

1. Documenting requirements, accepted decisions, and open questions.
2. Establishing a minimal project structure that separates configuration,
   policies, setup, scripts, and documentation as the respective files are added.
3. Implementing a catalog exporter for a mounted, unmodified source image, with
   complete commented selection templates for features, capabilities, and apps.
4. Implementing `scripts/audit.ps1` to inventory an installed Windows system.
5. Validating configuration loading, report formatting, and error handling
   without requiring an inventory of the current installation. Actual installed
   Windows collection tests are performed in the Stage 2 VM.

This stage excludes ISO/WIM modification, OS installation, disk partitioning,
policy application, app removal, service changes, and update installation.
The current computer is the first physical deployment target, but its apps,
settings, and drivers are not imported into the generic image. Collecting its
inventory is not required for this stage.

## Work sequence

### 1. Clarify requirements

Complete [requirements.md](requirements.md). Mark unknown values explicitly;
do not substitute the current computer's settings.

Define a verification scenario for each selected capability. For WSL, distinguish
enabling platform prerequisites from provisioning a runtime or distribution.
Use a temporary test distribution later if needed to verify execution; this
does not add a distribution to the deployment profile.

### 2. Export the image catalog

Choose and identify the official source image before generating a full catalog.
Query all Optional Features, Windows Capabilities, and provisioned Appx exposed
by that image. Record exact identifiers, source states, and image identity.
Do not use the current computer as a substitute for the image.

Generate commented selection templates and validate the active configuration
against the catalog. Commented entries are unmanaged; disabling or removing an
item requires an explicit selection. Preserve the distinction between a known
component and an available installation payload. See the
[configuration guide](../config/README.md).

### 3. Implement the audit

Each run must collect:

| Area | Data to capture |
| --- | --- |
| OS | Edition, version, build number, architecture, and language |
| Appx/MSIX | Provisioned packages and app registrations for users accessible to the audit, including dependencies |
| Components | Optional Features and Windows Capabilities with their states |
| Services | Name, state, and startup type; the current running state alone does not indicate noncompliance |
| Policies | Settings explicitly selected for the project, their values, scope, and known applicability |
| Servicing | Installed update packages and detected indicators of a pending reboot |

The initial audit produces an inventory. Compliance assessment applies only to
explicitly documented requirements; the machine's current state does not
automatically become the desired state. The presence of a policy value alone
does not prove that the policy is effective.

Behavior requirements:

- Do not change system configuration; write only the audit's own reports.
- Accept an explicit output directory and create separate results for each run.
- Record UTC time, Git commit when available, and execution context: PowerShell version and administrative privileges.
- Report collection completeness and errors separately for each area.
- Do not present incomplete data as a complete snapshot when privileges are
  insufficient.
- Distinguish "not applicable," "could not verify," and an actually missing value
  or object. Collection failures must also be reflected in the exit code.
- Do not collect passwords, activation keys, or BitLocker recovery keys.
- Do not install dependencies or download files during the audit.

### 4. Verify the result

Save JSON for automated comparison and a short Markdown report for human review.
The full report may contain machine and user information, so keep it out of Git.
The selected report directory must be ignored by Git.

Two consecutive runs without intentional changes must produce comparable
inventories. Timestamps, current service states, and other volatile fields are
not sufficient evidence of configuration changes on their own.

Stage 1 validates the tools without requiring access to the current machine's
inventory. Live collection, repeated-run comparison, and insufficient-privilege
behavior are integration checks for the Stage 2 VM. A clean Pro baseline is
captured there before configuration is applied, then compared with the configured
system and its state after updates. These checks must pass before physical
deployment.

## Deliverables

- Completed requirements with explicitly identified deferred decisions.
- Initial desired configuration and full image-derived component selection
  templates, with source identity recorded alongside the catalog.
- A catalog exporter and instructions for inspecting an unmodified source image.
- `scripts/audit.ps1` and instructions covering privileges and PowerShell
  requirements.
- A documented JSON schema and rules for interpreting errors.
- Tool validation results and instructions for the VM integration checks, without
  exposing machine data in Git.
- Rules for excluding local artifacts and secrets from Git.

## Acceptance criteria

- [x] The portable target scenario, x64 architecture, language, and initial component selections are defined.
- [x] A complete catalog and commented selection templates are generated from the identified source image.
- [x] No existing applications are migrated; inbox app selections are stored in configuration.
- [x] Open decisions are listed with the stage by which they must be resolved.
- [x] The audit implements collectors for all listed areas without configuration changes.
- [x] Configuration loading, JSON parsing, Markdown formatting, and error reporting are validated.
- [x] VM integration instructions cover live collection, insufficient privileges, and repeated-run comparison.
- [x] Local reports and secrets have been verified to stay out of Git.

Validation uses `tests/audit.tests.ps1` with synthetic Windows API responses and inventories. Fixture reports are Git-ignored; collectors do not query passwords, product keys, or recovery keys. See the [audit guide and VM verification sequence](audit.md), [report schema](audit-report.schema.json), and [configuration guide](../config/README.md).

Once these criteria are met, proceed to the stage for installing clean Pro in a VM.
Implementation checks do not count as evidence that live collection has passed;
record the Stage 2 integration results separately.
