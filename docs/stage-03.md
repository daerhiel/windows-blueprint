# Stage 3. Policies in the prepared image

Status: the initial Pro policy delivery is verified through the saved WIM, packaged ISO, and a fresh installation. Repeated independent audits matched the selected component configuration, local GPO definitions and processing metadata, and installed registry values. Stable inventories matched, and the configured VM checkpoint was saved.

## Delivery

The `Policies` map in [windows.psd1](../config/windows.psd1) is an input to the existing [build-image.ps1](../scripts/build-image.ps1). During offline servicing, the pinned Microsoft LGPO tool compiles Machine and User `Registry.pol` files directly into `Windows\System32\GroupPolicy` in the mounted image. The builder writes the corresponding `gpt.ini` scope versions and registry-extension metadata. It refuses to replace pre-existing source policies.

The installed system receives ordinary local GPO files as part of Windows. Windows processes computer policy at startup and user policy at sign-in. There is no separate policy-installation step, runtime LGPO executable, repository copy, first-logon setup script, or VM-specific configuration mechanism in the image. Changing a selected policy requires rebuilding the image from the pinned inputs.

LGPO is a build-host dependency only. Its download URL, archive/executable fingerprints, and version are pinned in [toolchain.lock.json](../config/toolchain.lock.json); the downloaded files remain under ignored `.local/tools`. Build commands are in [build-plan step 21](build-plan.md).

## Initial Pro selections

| Policy | Scope | Purpose |
| --- | --- | --- |
| `DisableAdvertisingId` | Machine | Prevent advertising-ID use by apps |
| `DisableFeedbackNotifications` | Machine | Suppress Windows feedback questions |
| `DisableTailoredExperiences` | User | Prevent diagnostic personalization of offers |
| `DisableThirdPartySuggestions` | User | Suppress third-party Spotlight suggestions |

Each rule records its registry mapping, desired DWORD, reviewed editions, and `Verification = 'LocalGpo'`. Microsoft documents support for Pro and Enterprise: [advertising ID](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#disableadvertisingid), [feedback](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#donotshowfeedbacknotifications), [tailored experiences](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowtailoredexperienceswithdiagnosticdata), and [third-party suggestions](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowthirdpartysuggestionsinwindowsspotlight). Broader consumer-experience and Windows-tips policies are reserved for separately reviewed Enterprise selections. Interface preferences are deferred.

This profile does not claim removal of every Windows offer. In particular, disabling third-party suggestions and diagnostic personalization can leave Microsoft offers visible.

## Verification

The build verifies the compiled GPO entries and processing metadata before saving and again through the existing read-only mount of the saved WIM. The reader decodes the documented [Registry.pol format](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/registry-policy-file-format) independently of LGPO's compiler. The offline checks confirm delivery and still require installation verification.

The existing [audit.ps1](../scripts/audit.ps1) reads the installed Machine/User local GPO stores and the actual selected registry values. `LocalGpo` compliance means both the GPO definition/processing metadata and the applicable registry state match. It does not mean that every advertising surface was tested; `effectiveState` remains `NotVerified` in the collected evidence. An ordinary registry observation without `Verification = 'LocalGpo'` retains its existing effectiveness limitation.

The normal configured-VM installation and audit commands are unchanged. The host may collect reports, but it must not install or repair policies in the guest before auditing. Preserve the clean baseline; use a fresh configured installation to verify automatic delivery. Existing VM reports from an earlier image are not evidence for this integration.

## Remaining sequence

1. Complete the remaining configuration and physical deployment profile.
2. Run the final fresh-installation VM cycle, then repeat the independent audit after Windows Update and required restarts.

Windows Update verification is separate from image building and follows the completed configuration and deployment profile.
