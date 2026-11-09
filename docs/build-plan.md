# Build plan

Follow these instructions from the repository root. Use the configuration and lock files for the selected inputs and desired state. Run administrator actions directly from an elevated 64-bit PowerShell terminal on Windows. Main workflows do not request elevation internally. Build and audit reports are written under `.local`. Each command includes its own inputs and can be run in a new terminal.

The source fingerprint, selected image metadata, and toolchain pins live in Git. Removing `.local` requires preparing local tools and source artifacts again; it does not require choosing the inputs again. The input-selection steps below apply when deliberately changing those inputs. Source preparation and building recalculate the ISO hash and compare it with the recorded fingerprint before using the image.

Baseline VM steps verify the source and audit tooling separately. Configured preparation and reinstallation are independent of baseline VM state and reports.

1. Review the edition, architecture, language, and desired configuration in [windows.psd1](../config/windows.psd1).

2. Compute the ISO fingerprint and compare it with `iso.sha256` in [source-image.lock.json](../config/source-image.lock.json). When deliberately selecting a different ISO, record its reviewed fingerprint in that lock before source inspection. For the already pinned ISO, the workflows perform this comparison automatically; these commands expose both values for manual review:

   ```powershell
   Get-FileHash -LiteralPath 'D:\temp\windows.iso' -Algorithm SHA256
   (Get-Content -LiteralPath 'config/source-image.lock.json' -Raw | ConvertFrom-Json).iso.sha256
   ```

3. When selecting a different source image, inspect the ISO read-only using [inspect-source.ps1](../scripts/README.md#inspect-the-source-iso). The utility locates the installation image, verifies the recorded fingerprint, reads image metadata, and detaches only its own ISO attachment:

   ```powershell
   .\scripts\inspect-source.ps1 -IsoPath 'D:\temp\windows.iso' -OutputDirectory 'D:\Repository\Projects\windows\.local\source-inspection' -ExpectedSha256 (Get-Content -LiteralPath 'config/source-image.lock.json' -Raw | ConvertFrom-Json).iso.sha256
   ```

4. When selecting a different source, choose the image matching the configured edition, architecture, and language from the inspection output and record its index and metadata in the source lock. Keep an already selected image as recorded.

5. When changing the toolchain, select a compatible ADK using [Microsoft's compatibility list](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) and record the selected toolchain in [toolchain.lock.json](../config/toolchain.lock.json).

6. Download the pinned ADK offline layout using the [tool-preparation workflow](../workflows/prepare-tools.ps1):

   ```powershell
   .\workflows\prepare-tools.ps1 -Action Download -Tool Adk
   ```

7. Install the pinned ADK Deployment Tools:

   ```powershell
   .\workflows\prepare-tools.ps1 -Action Install -Tool Adk
   ```

8. Download and prepare the pinned Microsoft LGPO build tool:

   ```powershell
   .\workflows\prepare-tools.ps1 -Action Download -Tool Lgpo
   .\workflows\prepare-tools.ps1 -Action Install -Tool Lgpo
   ```

9. Download and prepare the pinned WinPE optional components, then verify the toolchain:

   ```powershell
   .\workflows\prepare-tools.ps1 -Action Download -Tool WinPE
   .\workflows\prepare-tools.ps1 -Action Install -Tool WinPE
   .\workflows\prepare-tools.ps1 -Action Check -Tool All
   ```

10. Prepare the original source WIM, component catalog, and commented key/value selection template together using the [source-preparation workflow](../workflows/prepare-source.ps1). The workflow verifies the ISO against the source lock and derives the working directory from the selected image. Run this step after deleting `.local`, even when the active configuration is already ready:

    ```powershell
    .\workflows\prepare-source.ps1 -IsoPath 'D:\temp\windows.iso'
    ```

11. When deliberately refreshing the reviewed catalog in Git, copy the generated catalog and selection template following the [configuration guide](../config/README.md#complete-image-catalog). Preserve existing template edits before replacing it. A ready profile does not require this copy after local source preparation.

12. When changing the desired profile, review the selection template and set the component and policy rules in [windows.psd1](../config/windows.psd1). Check configuration loading with `Import-PowerShellDataFile -LiteralPath 'config/windows.psd1'`.

13. When changing audit or deployment tooling, validate it using synthetic fixtures separately from the manual installation checks:

    ```powershell
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/deployment.tests.ps1
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
    ```

14. Check Hyper-V resources and pinned inputs, create a clean baseline VM, validate its hardware and answer file with Windows SIM, and start installation through the [VM workflow](../workflows/test-vm.ps1). Its source WIM comes from source preparation. Open the console explicitly and press a key at the DVD boot prompt:

    ```powershell
    .\workflows\test-vm.ps1 -Action Prepare -VMProfile Baseline -IsoPath 'D:\temp\windows.iso' -OpenConsole
    ```

15. Complete Setup/OOBE offline, sign in using the baseline account from [test-vm.psd1](../config/test-vm.psd1), and inspect the baseline installation:

    ```powershell
    .\workflows\test-vm.ps1 -Action Inspect -VMProfile Baseline
    ```

16. Capture and compare baseline audits, then save the baseline checkpoint using the VM workflow. Review the reports according to the [audit guide](audit.md):

    ```powershell
    .\workflows\test-vm.ps1 -Action Capture -VMProfile Baseline
    ```

17. Verify that the audit reports its collection limits when run without administrator privileges:

    ```powershell
    .\workflows\test-vm.ps1 -Action Limited -VMProfile Baseline
    ```

18. Build the configured Windows installation image from the pinned source ISO using [windows.psd1](../config/windows.psd1) through the [build workflow](../workflows/build.ps1):

    ```powershell
    .\workflows\build.ps1 -IsoPath 'D:\temp\windows.iso' -Stage Image
    ```

19. Create bootable installation media from the configured image through the build workflow. Keep the working WIM during development. Add `-Compress` only for an explicit final ESD export:

    ```powershell
    .\workflows\build.ps1 -IsoPath 'D:\temp\windows.iso' -Stage Media
    ```

20. Prepare a separate VM from the deployment ISO, using one dynamic test disk and no additional answer media. The VM workflow creates it, validates its hardware and answer file with Windows SIM, and starts installation. Preserve the baseline VM and its checkpoint. Press a key at the DVD boot prompt in the configured VM console:

    ```powershell
    .\workflows\test-vm.ps1 -Action Prepare -VMProfile Configured -OpenConsole
    ```

21. Let Setup prepare the single test disk automatically. Create a local administrator through the standard OOBE account page and sign in.

22. Audit the fresh installation using the local account created in OOBE, compare repeated inventories, and save the configured checkpoint. The command requests the credential for this operation directly; no credential variable from an earlier terminal is required. This authenticates host-side audit access to the test VM and is not part of image preparation. Review the reports and follow the [audit guide](audit.md#stage-2-vm-verification) for subsequent update verification:

    ```powershell
    .\workflows\test-vm.ps1 -Action Capture -VMProfile Configured -Credential (Get-Credential -Message 'Local administrator created in configured OOBE')
    ```
