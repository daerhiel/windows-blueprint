# Stage 3. Policies in the prepared image

Status: the expanded Pro privacy profile and deployment flow are verified through a fresh installation from the Fast-WIM development ISO. Independent audits matched the selected components, local GPO definitions and processing metadata, installed registry values, and deployment requirements. Stable pre-update inventories matched, and `configured-audited` is preserved. Audits after Windows Update and a further restart passed the configured checks, with no remaining reboot indicators or policy drift. A paused deployment of a selected removed app remains visible in inventory and requires review; absence checks assess provisioning and installed registrations.

Subsequent configuration changes require an image rebuild and a fresh installation before they are covered by this verification. Policy delivery, registry state, and selected app absence are part of the existing audit; changed OOBE behavior also requires fresh-installation verification. Generated reports record the exact configuration tested.

## Delivery

The `Policies` map in [windows.psd1](../config/windows.psd1) is an input to the existing [build-image.ps1](../scripts/build-image.ps1). During offline servicing, the pinned Microsoft LGPO tool compiles Machine and User `Registry.pol` files directly into `Windows\System32\GroupPolicy` in the mounted image. The builder writes the corresponding `gpt.ini` scope versions and registry-extension metadata. It refuses to replace pre-existing source policies.

The installed system receives ordinary local GPO files as part of Windows. Windows processes computer policy at startup and user policy at sign-in. There is no separate policy-installation step, runtime LGPO executable, repository copy, first-logon setup script, or VM-specific configuration mechanism in the image. Changing a selected policy requires rebuilding the image from the pinned inputs.

LGPO is a build-host dependency only. Its download URL, archive/executable fingerprints, and version are pinned in [toolchain.lock.json](../config/toolchain.lock.json); the downloaded files remain under ignored `.local/tools`. Build commands are in [build-plan step 22](build-plan.md).

## Policy selection

The active policy rules and their official applicability references live in [windows.psd1](../config/windows.psd1). Each rule records its registry mapping, desired value and type, reviewed editions, and verification method. Review edition support before selecting a policy; a valid registry value alone does not establish that Windows supports its behavior.

## Verification

The build verifies the compiled GPO entries and processing metadata before saving and again through the existing read-only mount of the saved WIM. The reader decodes the documented [Registry.pol format](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/registry-policy-file-format) independently of LGPO's compiler. The offline checks confirm delivery and still require installation verification.

The existing [audit.ps1](../scripts/audit.ps1) reads the installed Machine/User local GPO stores and the actual selected registry values. `LocalGpo` compliance means both the GPO definition/processing metadata and the applicable registry state match. It does not mean that every advertising surface was tested; `effectiveState` remains `NotVerified` in the collected evidence. An ordinary registry observation without `Verification = 'LocalGpo'` retains its existing effectiveness limitation.

The configured VM installs directly from the deployment ISO, with automatic disk sizing and account creation through native OOBE. Host-side audit access uses the account created in OOBE. The host must not install or repair policies in the guest before auditing. The fresh-installation audits verified the expanded privacy profile, GPT partition sizes and alignment, NTFS defaults, computer-name format, local administrator profile, and enabled Windows RE. Reports, comparison results, and checkpoint metadata remain under ignored `.local/vm-configured`; the clean baseline is preserved.

## Remaining sequence

1. Review the paused app-deployment evidence and the intended scope of app-absence checks before physical deployment.
2. Rebuild and repeat fresh-installation and post-update verification if configuration or audit requirements change.

Windows Update verification is separate from image building and follows the completed configuration and deployment profile.
