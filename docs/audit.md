# Installed-system audit

When `Deployment` is configured, the independent audit also checks the installed Windows disk's GPT partition order, sizes, types, drive letters, configured alignment, and NTFS defaults; the generated computer-name pattern; the local account/profile name correspondence and administrator membership; and Windows RE availability. Expected partition sizes are calculated independently of the installer. A manual Setup fallback may produce a layout outside this automatic profile and will be reported accordingly. BitLocker protection status is observed without reading recovery keys; cloud recovery-key backup cannot be established by this audit.

`scripts/audit.ps1` inventories installed Windows and compares explicit requirements from `config/windows.psd1`. It does not prepare or modify an image, apply configuration, install dependencies, download payloads, or change services and policies. The existing computer is not the project baseline. Live collection belongs in the Stage 2 VM.

## Invocation

Use a fresh 64-bit Windows PowerShell 5.1 process in the repository root. Online collection uses the installed Windows DISM module; it does not require the preparation ADK. PowerShell 7 can run fixture tests, but is not supported for live collection with the inbox Appx module. Full collection requires administrator privileges. A normal user run records unavailable areas and limits app registration visibility to the invoking user; it must not be interpreted as a full inventory.

In an elevated Windows PowerShell session inside the VM:

```powershell
.\scripts\audit.ps1 -ConfigurationPath '.\config\windows.psd1' -OutputDirectory '.local/audit/baseline'
$LASTEXITCODE
```

Or use the existing UAC launcher:

```powershell
.\scripts\run-elevated.ps1 -ScriptPath scripts/audit.ps1 -Parameters @{ OutputDirectory = 'D:\Repository\Projects\windows\.local\audit\baseline' } -LogDirectory '.local/launches/audit'
```

The launcher reports nonzero audit exits as a failed operation; inspect `audit.json` to distinguish expected baseline mismatches from collection failures. The audit output directory must be a new direct child of the repository's `.local/audit` directory, such as `baseline`, `baseline-repeat`, `configured`, or `after-update`. The script does not generate run suffixes, delete previous evidence, or overwrite reports. Choose labels explicitly. Reparse-point paths are rejected. The launcher may reuse its own transcript directory; that does not delete audit reports.

## Collections and comparisons

| Area | Evidence | Assessment |
| --- | --- | --- |
| Os | Edition ID, OS version/build/revision, architecture, system preferred UI language, invoking process UI language, current user's UI override, input language tags and method identifiers, default input method | Require Windows 11, selected edition/architecture, English UI observations, configured input entries, and selected default. Additional input entries are unmanaged. No exact source build is enforced, allowing updates. |
| OptionalFeatures | Full online feature names and states | Compare active rules only. `DisabledWithPayloadRemoved` satisfies `Disabled`; transitional states and unavailable identifiers are `NotVerified`. |
| Capabilities | Full capability identifiers and states, queried with `LimitAccess` | `Installed` satisfies `Present`, `NotPresent` satisfies `Absent`; unknown or pending states do not pass. |
| ProvisionedApps | Provisioned package names and families | Compare selected app families, allowing version, architecture, and resource-package changes. `Present` requires provisioning, not installation for every user. |
| RegisteredApps | Packages exposed by Appx, including main, framework, resource, bundle, and optional packages; per-user install states; dependency full names | An `Absent` app must also lack installed registrations across users. Observed installed registrations prove a mismatch even in a partial collection. Missing data in a partial collection cannot prove absence. Staged packages are recorded separately from installed registrations. |
| Services | Names, current state, startup mode, delayed automatic startup | Inventory only; no service configuration requirements are selected. A stopped service alone is not noncompliance. |
| Policies | Selected registry observations, edition applicability, and local GPO files/processing metadata | `LocalGpo` rules check the delivered GPO and actual registry state. Behavioral effectiveness is recorded separately and is not inferred from these matches. |
| Servicing | All DISM-reported package names, states, and release types | Inventory only; update state may legitimately change. This is not an update compliance or vulnerability scan. |
| Reboot | CBS `RebootPending`, Windows Update `RebootRequired`, nonempty `PendingFileRenameOperations` | Record indicators without exporting pending file paths. Their presence is informational; their absence does not rule out every reboot scenario. |

App matching uses package name plus publisher ID, rather than a version-pinned full name. A selected removal therefore still applies after a package version changes. Provisioned packages do not expose a full dependency graph through the inventory interface; dependency evidence is captured for packages returned by Appx. This does not replace reviewing provisioning manifests and reverse dependencies before removal. All-user visibility describes what Appx exposes, not offline profile hive inspection or proof about every possible user profile.

All-user registrations read the native `UserSecurityId.Sid` field. Missing SID evidence makes the collection partial while preserving observed installation states. The configured VM reports contain valid native SID strings; provisioning was compared with the baseline, and retained registrations were checked against the configured VM's own audited user SID.

System preferred UI language, a user override, and the PowerShell process UI language are separate observations. They do not establish the display language of every signed-in user. HKCU and input settings refer to the account running the audit; record and compare the same account in VM tests. WSL and Containers checks assess configured Windows features, not a runtime, distribution, or successful workload execution.

When there is no default input-method override, resolve the default from the user's language list, as described by [Get-WinDefaultInputMethodOverride](https://learn.microsoft.com/en-us/powershell/module/international/get-windefaultinputmethodoverride). Normalize single input-method strings and collections before indexing; otherwise a scalar TIP such as `0409:00000409` can be mistaken for its first character. The OS inventory retains `defaultInputMethodOverride` separately from the resolved method.

The collection APIs and their limits are documented by Microsoft: [Get-AppxPackage](https://learn.microsoft.com/en-us/powershell/module/appx/get-appxpackage), [Get-WindowsCapability](https://learn.microsoft.com/en-us/powershell/module/dism/get-windowscapability), [Get-WindowsPackage](https://learn.microsoft.com/en-us/powershell/module/dism/get-windowspackage), [Win32_Service](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-service), and [Get-SystemPreferredUILanguage](https://learn.microsoft.com/en-us/powershell/module/languagepackmanagement/get-systempreferreduilanguage).

## Report contract

`audit.json` follows [audit-report.schema.json](audit-report.schema.json), a JSON Schema draft 7 document. The schema validates the report envelope and check structure; the area-specific inventory fields are described above. `audit.md` contains collection scope/status, check counts, unresolved findings, and collection errors. Raw DISM logs are stored alongside the reports. All outputs stay under Git-ignored `.local`; they contain user SIDs and installed package/service information. Do not commit them or include secrets in selected policy observations.

| JSON field | Contract |
| --- | --- |
| `schemaVersion` | Integer `1`. |
| `startedAtUtc`, `completedAtUtc` | UTC ISO 8601 timestamps; exclude from stable inventory comparisons. |
| `context` | `mode` (`Live` or `Fixture`), PowerShell version, administrator status, invoking user SID, and Git commit if available. Commit alone does not identify uncommitted script changes. |
| `configuration` | SHA-256 of the imported data file and the desired configuration snapshot, with an empty `Policies` map when omitted. |
| `areas` | Named collections defined by the report schema. Each has `status`, `scope`, `data`, and `errors`. `Complete` means the API query completed for its stated scope; `Partial` indicates known gaps; `Failed` indicates a failed query; `NotApplicable` is used when there are no selected policy rules. |
| `checks` | One result per requirement/observation: `area`, `id`, `expected`, `actual`, `status`, and `reason`. Status is `Compliant`, `NonCompliant`, `NotVerified`, or `NotApplicable`. Unknown absence is represented by `actual: null`, not an empty inventory presented as success. |
| `summary` | Counts of each check status and incomplete areas. |
| `exitCode` | Bit 1 indicates mismatches, bit 2 indicates incomplete collection or unresolved verification. See the exit table. |

| Exit | Meaning |
| --- | --- |
| 0 | All collections completed or are inapplicable, and all applicable configured checks passed. |
| 1 | Observed configuration mismatches; no unresolved checks or collection failures. Expected for an unconfigured baseline. |
| 2 | Incomplete collection or unresolved verification, without proven mismatches. |
| 3 | Both proven mismatches and incomplete collection/unresolved verification. |
| 4 | Startup, configuration, output, or internal processing failure. A complete report is not guaranteed; never consume leftover files as a completed run. |

## Optional policy observations

The `Policies` map describes reviewed requirements using `Path`, `Name`, `Kind`, `Value`, and `Editions`. Paths are restricted to `HKLM:\SOFTWARE\Policies\...` or `HKCU:\SOFTWARE\Policies\...`; editions use actual `EditionID` values such as `Professional` and `Enterprise`. Verify support and applicability from official documentation before adding a rule.

A missing key/value or type/value mismatch is `NonCompliant`. For `Verification = 'LocalGpo'`, compliance additionally requires a matching entry in the installed Machine/User `Registry.pol`, a nonzero version for that scope, and registry-extension metadata in `gpt.ini`. The audit decodes those files without LGPO and does not change them. This verifies delivery and registry state; `effectiveState` remains `NotVerified` for behavioral effects. HKCU covers the invoking account. An ordinary observation without `LocalGpo` verification retains `NotVerified` and exit bit 2 even when its registry value matches. An edition outside reviewed applicability is `NotApplicable`.

When a rule includes `FileContent`, the referenced JSON file must also be present and match its configured text. The audit reads only JSON paths referenced within the local Group Policy directory. A missing or changed file is noncompliant even when registry values match. This verifies native policy delivery; it does not enforce current user choices after a one-time Start layout has been applied.

## Local verification

Run the fixture suite without elevation:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
```

The tests inject synthetic collectors and execution context; they never fall back to live Windows collection. Temporary fixture report labels contain a random identifier to isolate test invocations. Reports are marked `mode: Fixture` and remain ignored by Git. Tests cover matching state, updated app identities, separate provisioning/registration findings, dependency serialization, insufficient visibility, failed collectors, pending/unavailable features, policy applicability/effectiveness limits, malformed configuration, duplicate app families, report preservation, path restrictions, and repeatability. PowerShell 7 additionally validates reports against the JSON schema when running the tests. These checks do not prove that live collection works.

## Stage 2 VM verification

1. Resolve the pre-installation decisions in [requirements.md](requirements.md): VM platform/settings, account creation, baseline network/update timing, and input source verification. Use the unchanged pinned Pro image and an isolated test disk; no physical disk operations are required.
2. Install clean Pro. Run the elevated audit into `baseline` before applying configuration. Review the report for complete collections, correct OS identity, app dependencies, and expected differences from the desired profile. A baseline exit of 1 is acceptable only when every mismatch is understood; collection failures are not acceptable.
3. Run it again into `baseline-repeat` with the same account, privileges, configuration, and network conditions, without intentional changes. Compare `areas` by stable identifiers: feature/capability names, app families and package names, service names/start modes, policy IDs, and servicing package names. Treat service running state, reboot indicators, Store/Windows Update activity, and user SIDs as contextual evidence rather than automatic configuration drift. Explain unexpected differences before continuing. No automatic historical report comparator is implemented yet.
4. From a non-elevated shell, run into `limited-user`. Confirm that unavailable areas are `Failed`/`Partial`, registration scope is `CurrentUser`, missing all-user apps are `NotVerified`, and the exit includes bit 2. Confirm that no system settings changed.
5. Preserve the baseline VM snapshot. Use [build-image.ps1](../scripts/build-image.ps1) to review offline app manifests and reverse dependencies and apply the selected component rules to a fresh working WIM. Create installation media and perform a fresh configured VM installation while retaining the baseline. Audit into `configured`; investigate every mismatch and collection failure. Runtime/distribution tests require separately defined inputs.
6. Complete the configuration and deployment profile before the final update cycle. Install updates, restart as required, then audit into `after-update`. Check for returned apps by family and changed feature/capability/policy states. Retain reports locally and record the reviewed outcome. Restore the snapshot to reproduce unexpected behavior. Physical installation remains deferred until this complete cycle passes.

No live inventory, VM installation, dependency validation, component removal, or post-update integration checks have been performed during fixture verification.

The automated [limited-user VM check](stage-02.md) uses `run-vm-baseline.ps1 -Action Limited` to launch a restricted process under the existing test account. Host orchestration is elevated, while the collector's own context must report `isAdministrator: false`. Its live report demonstrated explicit DISM collection failures, current-user-only app scope, unresolved unavailable states, and exit 3. This does not replace testing permissions and profiles of additional deployment users if those become part of the project requirements.
