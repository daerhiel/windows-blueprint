# Design intent and open questions

This record preserves unresolved parts of the original installation and maintenance discussion, together with the current implementation boundaries. It supports decisions about project scope. Entries have no priority, implementation order, deadline, or commitment to deliver a feature. An entry can be resolved by implementing a capability, accepting a limitation, choosing another mechanism, or explicitly excluding it.

[Requirements](requirements.md) contains accepted decisions. [windows.psd1](../config/windows.psd1) and the lock files define selected configuration and inputs. The [build plan](build-plan.md) describes executable operations. This record explains questions that those documents do not yet settle.

## Source and interpretation

These entries summarize the initial Russian-language installation and maintenance discussion in English rather than quoting it verbatim. They preserve the intent and qualifications needed to assess the open questions without requiring the original conversation.

The user's initial goal was a transparent clean installation from an official Windows image, with known changes and an understanding of which unwanted components could return after updates. The later clarification asked for a reproducible installation path, automated through scripts and policy/settings files, with image composition maintained consistently over time. Configuration should remain recoverable from versioned rules when the source Windows version changes. These goals came from the opening request and later clarifications.

The assistant proposed several possible mechanisms, including a separate configuration operation, drift reconciliation, edition-specific policies, and offline update integration. Those proposals were not all explicit user requirements. Recording an absent mechanism here does not establish that it must be built or that it is supported for the selected Windows profile.

The source also contains product-release, policy-availability, licensing, and installation-hook claims. This record preserves the questions they raised without treating those claims as verified constraints. Check current authoritative documentation and the selected inputs before adopting a mechanism. Specific application lists, resource limits, versions, and fingerprints remain in configuration and locks.

## Applying configuration to an existing installation

**Source intent.** The discussion separated image creation, configuration application, and audit. It proposed an idempotent configuration operation that could be run repeatedly, checking actual state before applying changes. The installation-hook discussion was intended to avoid making configuration depend exclusively on a particular first-boot hook.

**Current boundary.** The builder applies selected component changes offline and compiles local GPOs into the image. Windows subsequently processes those GPOs. There is no project operation that applies the entire desired configuration to an already installed OS. Changing the prepared profile currently leads to a rebuild and fresh installation; see [policy delivery](stage-03.md#delivery).

**Open decision.** Determine whether in-place application is needed, which settings it should cover, and whether it is an installation convenience or a supported maintenance operation. A separate implementation must not become a second source of desired values.

**Nuances to retain.** Reapplying configuration cannot mean replaying every installation action. Disk preparation, account creation, generated identities, and one-time user initialization need different semantics from component and policy settings. Omitted configuration remains unmanaged, and supported user changes must be distinguished from settings the project intends to enforce. The original hook warnings motivate an execution-boundary question, not a requirement to introduce first-logon scripts or a general-purpose orchestrator.

## Restoring desired state after drift

**Source intent.** The proposed lifecycle included reconciliation after audit: detect an unwanted change after an update and restore the declared state without disabling Windows servicing.

**Current boundary.** The [audit](audit.md) reports mismatches and incomplete verification. The [comparison utility](../scripts/compare-audits.ps1) describes changes between saved reports. Neither repairs the installed system. VM reinstallation replaces a disposable test installation; it is not in-place reconciliation.

**Open decision.** Decide whether detection and operator review are sufficient, or whether an explicit repair operation is needed. If repair is selected, define the supported changes, invocation model, and handling of unsupported or indeterminate observations. The initial discussion does not require an unattended background repair agent.

**Nuances to retain.** Applying a newly selected configuration and repairing drift against an unchanged configuration are related but different cases. A raw audit difference is not automatically an instruction to reverse it: package updates, legitimate user changes, and incomplete collection require interpretation. The independent audit must remain read-only, and post-update evidence must be captured before any repair that would hide what the update changed.

## Preventing unwanted applications from returning

**Source intent.** The opening question concerned persistence across updates. The discussion explicitly distinguished removing an app from the installation image from preventing later acquisition, and suggested edition-dependent policy-based app removal as one possible mechanism.

**Current boundary.** The builder removes selected provisioned packages from the source image. The audit checks selected app families against provisioning and installed user registrations. It does not enforce an acquisition block or remove a returned app. [Stage 3](stage-03.md) records the distinction between source-image removal and later online acquisition.

**Open decision.** Decide whether the required outcome is initial absence, detection of a later return, prevention of acquisition, removal after return, or some combination. Establish supported mechanisms for the selected edition and OS version before promising prevention.

**Nuances to retain.** Provisioning, staging, installed registration, Store acquisition, system-initiated acquisition, and reappearance after an OS upgrade are different observations. The current absence checks do not treat every staged package as an installed app. Define which events matter and whether deliberate user reinstallation should be allowed. A policy suggested for another edition or a limited package set is not evidence of a universal block for Pro or for every application.

## Declaring and managing Windows service state

**Source intent.** The initial wording referred broadly to unwanted services. The discussion then distinguished apps, optional components, service startup configuration, and manual removal of services or CBS-owned files. It warned against treating those operations as interchangeable.

**Current boundary.** The audit inventories services and the comparator can report changes in startup configuration. There is no selected service-state configuration or service compliance/application operation. The accepted requirements exclude manual stripping of system services and CBS packages.

**Open decision.** Determine whether actual Windows service configuration belongs in scope, rather than only application and optional-component selection. If so, identify explicit desired states and supported ways to deliver them, with dependency and servicing behavior reviewed for each selection.

**Nuances to retain.** The original broad wording did not specify a service list or authorize blanket disabling. A stopped service is not necessarily disabled or unwanted; disabling an optional component is not equivalent to changing a service startup mode. Any service-management decision must preserve the accepted exclusion of arbitrary service/CBS stripping.

## Verifying the behavioral effect of policies

**Source intent.** The discussion emphasized that a registry or policy-file entry does not prove that Windows honors it, and called for checking the actual result.

**Current boundary.** The builder and audit check local GPO definitions, processing metadata, referenced policy files, and selected registry values. The policy collector retains `effectiveState = 'NotVerified'` for behavioral effects. Some deployment behavior is exercised through fresh Setup/OOBE verification, but there is no general behavioral check for every selected policy. See [verification limits](stage-03.md#verification).

**Open decision.** Decide which policies need behavioral evidence, what observation would establish the intended outcome, and whether each check can be automated or requires a documented manual observation.

**Nuances to retain.** Policy delivery, registry application, and observable behavior are separate claims. A check needs a defined user/session context and any relevant sign-in, restart, or policy-processing conditions. One-time initialization must not be evaluated as permanent enforcement of a user's later choices. A passing delivery check must not silently become a claim that every advertising surface or privacy-related behavior was tested.

## Checking policy applicability across Windows versions

**Source intent.** The user specifically questioned whether a policy would be honored on the relevant Windows version. The discussion also distinguished edition support from merely writing a setting.

**Current boundary.** Rules record reviewed editions and reference documentation; the collector determines applicability from the installed edition. Source locks identify the build used for preparation, while installed-system auditing allows OS updates. There is no per-policy OS-version/build applicability decision in the audit. See [policy observations](audit.md#optional-policy-observations).

**Open decision.** Decide how support knowledge should be represented and reviewed as Windows changes: for example, version-specific evidence, explicit compatibility limits, or a reviewed applicability matrix. Also decide how an unreviewed target should be reported.

**Nuances to retain.** A pinned source build and an edition match do not establish that a setting remains supported after a later upgrade. Applicability is distinct from successful delivery and behavioral effectiveness. Unknown support should remain distinguishable from a proven unsupported policy, a policy that failed to apply, and a verified compliant result.

## Integrating Windows updates into a reproducible image build

**Source intent.** The discussion proposed starting from a known original ISO and combining reviewed updates with configuration, rather than repeatedly patching an already modified working image. The purpose was a rebuild whose inputs remained understandable and reproducible.

**Current boundary.** Source and toolchain inputs are locked, and each image build starts from the original source. There is no declared set of Windows cumulative-update inputs or stage that applies them to the installation image. Adding WinPE dependencies during media preparation is a separate operation. Normal installed-system Windows Update remains an operator action followed by audit.

**Open decision.** Decide whether updates should be integrated offline, obtained through a newer reviewed source ISO, installed after deployment, or handled through a combination with explicit boundaries.

**Nuances to retain.** If offline updates are selected, their identities, sources, integrity evidence, applicability, dependencies, ordering, and resulting servicing state become build inputs and verification concerns. A successful build with those inputs would still not establish resilience to future updates. The original goal concerns reproducible and verifiable state; byte-for-byte image identity is not currently required.

## Verifying an upgrade to another Windows version

**Source intent.** The discussion distinguished cumulative servicing from an OS version upgrade, identifying the latter as a separate challenge for retained components and settings. It also wanted the ability to replace the source Windows version and rebuild from versioned rules.

**Current boundary.** The VM workflow supports audit and comparison after operator-installed updates and an explicit restart. It does not define a separate OS-version-upgrade verification procedure with its own input review, policy-support review, and acceptance boundary. Existing update observations apply to the inputs and transitions actually recorded, not every future release.

**Open decision.** Decide whether to support and verify an in-place upgrade of an existing configured installation, a fresh installation from a newer source, or both. Define what must be reviewed and what outcome would establish support for that transition.

**Nuances to retain.** A fresh installation from a new ISO and an upgrade of an existing configured OS exercise different paths. A successful cumulative-update check does not establish either one. Changes to configuration, component identifiers, or collection code can also affect whether before/after reports are directly comparable; their input identity must remain explicit.

## Providing an end-to-end Enterprise profile

**Source intent.** Pro was the available starting point. Enterprise was discussed as an option for specific capabilities, with edition choice and licensing raised separately. The closing recommendation was to choose it for an identified need, rather than for the edition name alone.

**Current boundary.** The configuration reader recognizes edition labels and policy rules have edition applicability, but source preparation, image-build checks, and VM preparation currently target the selected Pro profile. There is no complete reviewed Enterprise source/configuration/build/VM verification flow.

**Open decision.** Determine which required capability, if any, justifies another profile. If selected, review the source, desired rules, applicability, deployment behavior, audit expectations, and relevant licensing conditions as a coherent profile.

**Nuances to retain.** Shared configuration concepts do not make a different edition supported end to end. The source's mention of access to a key is not a profile-selection decision or a licensing review. Enterprise remains an option to evaluate; recording this question does not commit the project to changing editions or assuming capabilities unavailable in the selected Pro profile.

## Keeping this record useful

Keep each current boundary aligned with the implementation as it changes. When an open decision is resolved, record the chosen scope and rationale, update accepted requirements and relevant configuration, and retain enough context to explain what was deliberately excluded. Do not convert this record into an execution plan or infer priorities from the order of its sections.
