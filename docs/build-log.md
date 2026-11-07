# Build log

Commands are shown relative to the repository root. Administrator actions run in a separate process through Windows UAC.

1. **Done** — Set Pro/x64/en-US and the initial component selections in [windows.psd1](../config/windows.psd1).

2. **Done** — Fingerprint the ISO and save the result in [source-image.lock.json](../config/source-image.lock.json). Command: `Get-FileHash -LiteralPath 'D:\temp\windows.iso' -Algorithm SHA256`.

3. **Done** — Inspect the ISO read-only; find `sources/install.esd`; detach it afterward. Commands: `Mount-DiskImage -ImagePath 'D:\temp\windows.iso' -StorageType ISO -Access ReadOnly -PassThru`, then `Dismount-DiskImage -ImagePath 'D:\temp\windows.iso'`.

4. **Done** — Run [inspect-source.ps1](../scripts/inspect-source.ps1) through [run-elevated.ps1](../scripts/run-elevated.ps1); recheck the ISO fingerprint and enumerate all image indexes. The script reuses `.local/source-inspection` and cleans its previous results automatically:

   ```powershell
   .\scripts\run-elevated.ps1 -ScriptPath scripts/inspect-source.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\source-inspection'; ExpectedSha256 = 'AFC1E62C432B335E23D9D88E5C7971AE3B5D7DD651F306A2D5B485F60D43C2BF' } -LogDirectory '.local/launches/inspection'
   ```

5. **Done** — Select Pro index 6, version 10.0.26300.9711, x64, en-US from that result; record it in the source lock.

6. **Done** — Select ADK 10.1.26100.9457 for Windows 11 26H2 using [Microsoft's compatibility list](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
7. **Done** — Download the ADK installer and verify its Microsoft signature; pin versions and hashes in [toolchain.lock.json](../config/toolchain.lock.json).

   ```powershell
   Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2289980' -OutFile '.local/downloads/adk-26100/adksetup.exe'
   Get-AuthenticodeSignature -LiteralPath '.local/downloads/adk-26100/adksetup.exe'
   ```

8. **Done** — Install Deployment Tools through UAC; installer exit code 0. Executed installer arguments:

   ```powershell
   & '.local/downloads/adk-26100/adksetup.exe' /quiet /norestart /features OptionId.DeploymentTools /log 'D:\Repository\Projects\windows\.local\downloads\adk-26100\install.log'
   ```

9. **Done** — Run the [catalog exporter](../scripts/export-image-catalog.ps1) through [run-elevated.ps1](../scripts/run-elevated.ps1): extract Pro to a working WIM, mount it read-only, collect 138 Features, 424 Capabilities, and 47 Appx, and generate the commented key/value selection template with one entry per component.

   ```powershell
   .\scripts\run-elevated.ps1 -ScriptPath scripts/export-image-catalog.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711' } -LogDirectory '.local/launches/catalog'
   ```

10. **Done** — Copy the validated [catalog and selection template](../config/catalogs/pro-26300.9711/) into the configuration directory. Command: `Copy-Item -LiteralPath '.local/catalog/pro-26300.9711/catalog.json', '.local/catalog/pro-26300.9711/selections.psd1' -Destination 'config/catalogs/pro-26300.9711'`.

11. **Done** — Review [selections.psd1](../config/catalogs/pro-26300.9711/selections.psd1) and set the desktop rules in [windows.psd1](../config/windows.psd1): retain virtualization, disable Work Folders and the legacy media player, keep unused roles disabled, and select 17 provisioned apps for removal, including Xbox and Game Bar. See [selection rationale and VM checks](../config/README.md#desktop-selections). Load the configuration with `Import-PowerShellDataFile -LiteralPath 'config/windows.psd1'`; nothing is applied at this step.

12. **Done** — Implement [audit.ps1](../scripts/audit.ps1) and validate it with synthetic data only; no installed-system inventory was collected. Run the [fixture suite](../tests/audit.tests.ps1):

    ```powershell
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
    pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
    ```

13. **Done** — Check Hyper-V resources and pinned source/tool fingerprints for the [test profile](../config/test-vm.psd1):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; CheckOnly = $true } -LogDirectory '.local/launches/vm-preflight'
    ```

14. **Done** — Create the powered-off `Windows11-Pro-Test` VM with one new dynamic VHDX, disconnected networking, Secure Boot, vTPM, nested virtualization, and separate local answer-file media. Keep generated credentials under `.local/vm/windows11-pro/secrets`:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/vm-create'
    ```

15. **Done** — Validate the actual VM and rendered answer file with Windows SIM; result `Pass`. The first invocation creates its image catalog; subsequent checks reuse it:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/validate-vm-setup.ps1 -Parameters @{ WimPath = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711\pro.wim' } -LogDirectory '.local/launches/vm-validation'
    ```

16. **Done** — Start the prepared VM and open its console; press a key at the DVD boot prompt. Windows Setup uses the separate answer-file ISO and the unchanged Microsoft installation ISO:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Start'; OpenConsole = $true } -LogDirectory '.local/launches/vm-start'
    ```

17. **Done** — Complete Setup/OOBE offline and sign in as `vmadmin`. Inspection confirmed Pro 10.0.26300.9711, en-US, GPT, and Windows RE enabled on partition 4:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Inspect'; WaitForGuestSeconds = 900 } -LogDirectory '.local/launches/vm-inspection'
    ```

18. **Done** — Capture both baseline audits and confirm matching stable inventories, understood desired-state mismatches, zero incomplete collections, and zero unresolved checks. Shut the VM down gracefully, detach installation media, and save the `baseline-audited` checkpoint:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Capture' } -LogDirectory '.local/launches/vm-capture'
    ```

19. **Done** — Run the audit in a restricted process under `vmadmin`: `isAdministrator = false`, current-user app scope, five incomplete areas, unavailable states reported as unresolved, and expected exit 3. Preserve the baseline checkpoint and return the VM to its prior power state:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Limited' } -LogDirectory '.local/launches/vm-limited'
    ```

20. **Done** — Build a fresh working Pro WIM from the pinned ISO and apply the selected rules offline: remove 17 provisioned Appx and the legacy Media Player capability, enable the selected virtualization/container features, and disable Work Folders. App manifest review passed; the saved `.local/build/windows11-pro/install.wim` at index 1 passed 73 checks, including preservation of 30 provisioned apps. Cleanup completed:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/build-image.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/image-build'
    ```

21. **Done** — Export the verified working WIM to `sources/install.esd` with DISM recovery compression, verify image metadata, and package it with the original Microsoft Setup/boot files. All 982 files in `.local/media/windows11-pro/windows11-pro.iso` passed hash verification; the ISO is 6220.6 MiB. Keep VM credentials and disk configuration on separate answer media:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/build-install-media.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; Compress = $true } -LogDirectory '.local/launches/install-media'
    ```

22. **Done** — Create the powered-off `Windows11-Pro-Test-Configured` VM with a new disk, disconnected networking, and new private answer media. Preserve the powered-off baseline and its checkpoint:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\Repository\Projects\windows\.local\media\windows11-pro\windows11-pro.iso'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-create'
    ```

23. **Done** — Validate the configured VM and its answer settings with Windows SIM using the cached source-version catalog; result `Pass`. Secure Boot, vTPM, nested virtualization, a new dynamic disk, and disconnected networking match the test profile:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/validate-vm-setup.ps1 -Parameters @{ WimPath = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711\pro.wim'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-validation'
    ```

24. **Done** — Start the configured VM and open its console. Press a key at the DVD boot prompt; Windows Setup started from the configured ISO:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Start'; VMProfile = 'Configured'; OpenConsole = $true } -LogDirectory '.local/launches/vm-configured-start'
    ```

25. **Done** — Complete Setup/OOBE offline and sign in as `vmadmin` using the configured VM's own credential under `.local/vm/windows11-pro-configured/secrets`.

26. **Done** — Inspect the installation from the compressed ISO and collect two independent audits: 67 compliant checks in each, zero mismatches, zero incomplete areas, and zero unresolved checks. Confirm matching stable inventories, preservation of the 31 installed-system provisioned apps expected from the baseline, and absence of all 17 selected app families. Shut down, detach installation media, and save `configured-audited`:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Capture'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-capture'
    ```
