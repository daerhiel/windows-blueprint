# Build plan

Follow these instructions from the repository root. Use the configuration and lock files for the selected inputs and desired state. Administrator actions run in a separate process through Windows UAC; run the ADK installer from an elevated PowerShell session. Build and audit reports are written under `.local`.

1. Set the edition, architecture, language, and desired configuration in [windows.psd1](../config/windows.psd1).

2. Fingerprint the ISO and save the result in [source-image.lock.json](../config/source-image.lock.json). Command: `Get-FileHash -LiteralPath 'D:\temp\windows.iso' -Algorithm SHA256`.

3. Inspect the ISO read-only to locate the installation image, then detach it. Commands: `Mount-DiskImage -ImagePath 'D:\temp\windows.iso' -StorageType ISO -Access ReadOnly -PassThru`, then `Dismount-DiskImage -ImagePath 'D:\temp\windows.iso'`.

4. Inspect the source image and verify its fingerprint using [inspect-source.ps1](../scripts/inspect-source.ps1):

   ```powershell
   .\scripts\run-elevated.ps1 -ScriptPath scripts/inspect-source.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\source-inspection'; ExpectedSha256 = 'AFC1E62C432B335E23D9D88E5C7971AE3B5D7DD651F306A2D5B485F60D43C2BF' } -LogDirectory '.local/launches/inspection'
   ```

5. Select the image matching the configured edition, architecture, and language from the inspection output; record its index and metadata in the source lock.

6. Select a compatible ADK using [Microsoft's compatibility list](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) and record the selected toolchain in [toolchain.lock.json](../config/toolchain.lock.json).

7. Download the ADK installer, verify its Microsoft signature, and pin its version and hashes in the toolchain lock:

   ```powershell
   New-Item -ItemType Directory -Path .local/downloads/adk-26100 -Force | Out-Null
   Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2289980' -OutFile '.local/downloads/adk-26100/adksetup.exe'
   Get-AuthenticodeSignature -LiteralPath '.local/downloads/adk-26100/adksetup.exe'
   ```

8. Install the pinned ADK Deployment Tools:

   ```powershell
   & '.local/downloads/adk-26100/adksetup.exe' /quiet /norestart /features OptionId.DeploymentTools /log 'D:\Repository\Projects\windows\.local\downloads\adk-26100\install.log'
   ```

9. Download and verify the pinned Microsoft LGPO build tool using [toolchain.lock.json](../config/toolchain.lock.json):

   ```powershell
   $lgpo = (Get-Content config/toolchain.lock.json -Raw | ConvertFrom-Json).lgpo
   New-Item -ItemType Directory -Path .local/tools/lgpo -Force | Out-Null
   Invoke-WebRequest -Uri $lgpo.archiveUrl -OutFile .local/tools/lgpo/LGPO.zip -UseBasicParsing
   if ((Get-FileHash .local/tools/lgpo/LGPO.zip).Hash -cne $lgpo.archiveSha256) { throw 'LGPO archive fingerprint mismatch.' }
   Expand-Archive -LiteralPath .local/tools/lgpo/LGPO.zip -DestinationPath .local/tools/lgpo -Force
   ```

10. Export the source image's component catalog and commented key/value selection template using [export-image-catalog.ps1](../scripts/export-image-catalog.ps1):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/export-image-catalog.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711' } -LogDirectory '.local/launches/catalog'
    ```

11. Copy the exported [catalog and selection template](../config/catalogs/pro-26300.9711/) into the configuration directory. Preserve any existing selections before replacing the template:

    ```powershell
    New-Item -ItemType Directory -Path config/catalogs/pro-26300.9711 -Force | Out-Null
    Copy-Item -LiteralPath '.local/catalog/pro-26300.9711/catalog.json', '.local/catalog/pro-26300.9711/selections.psd1' -Destination 'config/catalogs/pro-26300.9711'
    ```

12. Review [selections.psd1](../config/catalogs/pro-26300.9711/selections.psd1) and set the desired component and policy rules in [windows.psd1](../config/windows.psd1). See the [configuration guide](../config/README.md). Check configuration loading with `Import-PowerShellDataFile -LiteralPath 'config/windows.psd1'`.

13. Validate the audit tooling using the [fixture suite](../tests/audit.tests.ps1):

    ```powershell
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
    pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
    ```

14. Check Hyper-V resources and pinned source/tool fingerprints for the [test profile](../config/test-vm.psd1):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; CheckOnly = $true } -LogDirectory '.local/launches/vm-preflight'
    ```

15. Prepare a clean baseline VM from the source ISO using the [test profile](../config/test-vm.psd1). Keep generated credentials under `.local/vm/windows11-pro/secrets`:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/vm-create'
    ```

16. Validate the baseline VM and its answer file with Windows SIM before starting installation:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/validate-vm-setup.ps1 -Parameters @{ WimPath = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711\pro.wim' } -LogDirectory '.local/launches/vm-validation'
    ```

17. Start the baseline VM and open its console. Press a key at the DVD boot prompt to start Windows Setup:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Start'; OpenConsole = $true } -LogDirectory '.local/launches/vm-start'
    ```

18. Complete Setup/OOBE offline, sign in as `vmadmin`, and inspect the baseline installation:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Inspect'; WaitForGuestSeconds = 900 } -LogDirectory '.local/launches/vm-inspection'
    ```

19. Capture and compare baseline audits, then save the baseline checkpoint using the [baseline helper](../scripts/run-vm-baseline.ps1). Review the reports according to the [audit guide](audit.md):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Capture' } -LogDirectory '.local/launches/vm-capture'
    ```

20. Verify that the audit reports its collection limits when run without administrator privileges:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Limited' } -LogDirectory '.local/launches/vm-limited'
    ```

21. Build the configured Windows installation image from the pinned source ISO using [windows.psd1](../config/windows.psd1):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/build-image.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/image-build'
    ```

22. Create bootable installation media from the configured image using [build-install-media.ps1](../scripts/build-install-media.ps1). Use `Compress` to produce compressed installation media; omit it to retain the WIM:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/build-install-media.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; Compress = $true } -LogDirectory '.local/launches/install-media'
    ```

23. Prepare a separate VM for a fresh installation from the configured ISO, preserving the baseline VM and its checkpoint:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\Repository\Projects\windows\.local\media\windows11-pro\windows11-pro.iso'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-create'
    ```

24. Validate the configured VM and its answer file with Windows SIM before starting installation:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/validate-vm-setup.ps1 -Parameters @{ WimPath = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711\pro.wim'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-validation'
    ```

25. Start the configured VM and open its console. Press a key at the DVD boot prompt to start Windows Setup from the configured ISO:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Start'; VMProfile = 'Configured'; OpenConsole = $true } -LogDirectory '.local/launches/vm-configured-start'
    ```

26. Complete Setup/OOBE offline and sign in as `vmadmin` using the configured VM's own credential under `.local/vm/windows11-pro-configured/secrets`.

27. Audit the fresh installation against the selected configuration, compare repeated inventories, and save the configured checkpoint. Review the reports according to the [audit guide](audit.md):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Capture'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-capture'
    ```
