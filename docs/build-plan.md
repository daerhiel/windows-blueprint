# Build plan

Follow these instructions from the repository root. Use the configuration and lock files for the selected inputs and desired state. Administrator actions run in a separate process through Windows UAC; run the ADK installer from an elevated PowerShell session. Build and audit reports are written under `.local`.

1. Set the edition, architecture, language, and desired configuration in [windows.psd1](../config/windows.psd1).

2. Fingerprint the ISO and save the result in [source-image.lock.json](../config/source-image.lock.json). Command: `Get-FileHash -LiteralPath 'D:\temp\windows.iso' -Algorithm SHA256`.

3. Inspect the ISO read-only to locate the installation image, then detach it. Commands: `Mount-DiskImage -ImagePath 'D:\temp\windows.iso' -StorageType ISO -Access ReadOnly -PassThru`, then `Dismount-DiskImage -ImagePath 'D:\temp\windows.iso'`.

4. Inspect the source image and verify its fingerprint using [inspect-source.ps1](../scripts/inspect-source.ps1):

   ```powershell
   .\scripts\run-elevated.ps1 -ScriptPath scripts/inspect-source.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\source-inspection'; ExpectedSha256 = (Get-Content config/source-image.lock.json -Raw | ConvertFrom-Json).iso.sha256 } -LogDirectory '.local/launches/inspection'
   ```

5. Select the image matching the configured edition, architecture, and language from the inspection output; record its index and metadata in the source lock.

6. Select a compatible ADK using [Microsoft's compatibility list](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) and record the selected toolchain in [toolchain.lock.json](../config/toolchain.lock.json).

7. Download the ADK installer, verify its Microsoft signature, and pin its version and hashes in the toolchain lock:

   ```powershell
   New-Item -ItemType Directory -Path .local/downloads/adk-26100 -Force | Out-Null
   Invoke-WebRequest -Uri (Get-Content config/toolchain.lock.json -Raw | ConvertFrom-Json).adk.setupUrl -OutFile '.local/downloads/adk-26100/adksetup.exe'
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

10. Prepare the pinned WinPE optional components needed for automatic disk configuration, using [toolchain.lock.json](../config/toolchain.lock.json). Run the MSI administrative extraction from an elevated PowerShell session:

    ```powershell
    $winpe = (Get-Content config/toolchain.lock.json -Raw | ConvertFrom-Json).winpe
    New-Item -ItemType Directory -Path .local/downloads/adk-winpe -Force | Out-Null
    Invoke-WebRequest -Uri $winpe.setupUrl -OutFile .local/downloads/adk-winpe/adkwinpesetup.exe -UseBasicParsing
    if ((Get-FileHash .local/downloads/adk-winpe/adkwinpesetup.exe).Hash -cne $winpe.setupSha256) { throw 'WinPE installer fingerprint mismatch.' }
    $signature = Get-AuthenticodeSignature .local/downloads/adk-winpe/adkwinpesetup.exe
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'A valid Microsoft signature is required.' }
    $layout = Join-Path $PWD '.local/downloads/adk-winpe/layout'
    $process = Start-Process .local/downloads/adk-winpe/adkwinpesetup.exe -ArgumentList @('/quiet', '/layout', ('"' + $layout + '"')) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'WinPE package download failed.' }
    $package = Join-Path $layout 'Installers/Windows PE Optional Packages (DesktopEditions)-x86_en-us.msi'
    $signature = Get-AuthenticodeSignature -LiteralPath $package
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'A valid Microsoft MSI signature is required.' }
    $destination = Join-Path $PWD '.local/tools/winpe'
    $process = Start-Process msiexec.exe -ArgumentList @('/a', ('"' + $package + '"'), '/qn', ('TARGETDIR="' + $destination + '"')) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'WinPE package extraction failed.' }
    foreach ($package in $winpe.packages) {
        if ((Get-FileHash -LiteralPath (Join-Path $winpe.packageDirectory $package.path)).Hash -cne $package.sha256) { throw ('WinPE package fingerprint mismatch: ' + $package.path) }
    }
    ```
11. Export the source image's component catalog and commented key/value selection template using [export-image-catalog.ps1](../scripts/export-image-catalog.ps1):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/export-image-catalog.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; OutputDirectory = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711' } -LogDirectory '.local/launches/catalog'
    ```

12. Copy the exported [catalog and selection template](../config/catalogs/pro-26300.9711/) into the configuration directory. Preserve any existing selections before replacing the template:

    ```powershell
    New-Item -ItemType Directory -Path config/catalogs/pro-26300.9711 -Force | Out-Null
    Copy-Item -LiteralPath '.local/catalog/pro-26300.9711/catalog.json', '.local/catalog/pro-26300.9711/selections.psd1' -Destination 'config/catalogs/pro-26300.9711'
    ```

13. Review [selections.psd1](../config/catalogs/pro-26300.9711/selections.psd1) and set the desired component and policy rules in [windows.psd1](../config/windows.psd1). See the [configuration guide](../config/README.md). Check configuration loading with `Import-PowerShellDataFile -LiteralPath 'config/windows.psd1'`.

14. Validate the audit and unattended deployment tooling using synthetic fixtures:

    ```powershell
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/deployment.tests.ps1
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
    pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/audit.tests.ps1
    ```

15. Check Hyper-V resources and pinned source/tool fingerprints for the [test profile](../config/test-vm.psd1):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso'; CheckOnly = $true } -LogDirectory '.local/launches/vm-preflight'
    ```

16. Prepare a clean baseline VM from the source ISO using the [test profile](../config/test-vm.psd1). Keep generated credentials under `.local/vm/windows11-pro/secrets`:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/vm-create'
    ```

17. Validate the baseline VM and its answer file with Windows SIM before starting installation:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/validate-vm-setup.ps1 -Parameters @{ WimPath = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711\pro.wim' } -LogDirectory '.local/launches/vm-validation'
    ```

18. Start the baseline VM and open its console. Press a key at the DVD boot prompt to start Windows Setup:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Start'; OpenConsole = $true } -LogDirectory '.local/launches/vm-start'
    ```

19. Complete Setup/OOBE offline, sign in using the baseline account from [test-vm.psd1](../config/test-vm.psd1), and inspect the baseline installation:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Inspect' } -LogDirectory '.local/launches/vm-inspection'
    ```

20. Capture and compare baseline audits, then save the baseline checkpoint using the [baseline helper](../scripts/run-vm-baseline.ps1). Review the reports according to the [audit guide](audit.md):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Capture' } -LogDirectory '.local/launches/vm-capture'
    ```

21. Verify that the audit reports its collection limits when run without administrator privileges:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Limited' } -LogDirectory '.local/launches/vm-limited'
    ```

22. Build the configured Windows installation image from the pinned source ISO using [windows.psd1](../config/windows.psd1):

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/build-image.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/image-build'
    ```

23. Create bootable installation media from the configured image using [build-install-media.ps1](../scripts/build-install-media.ps1). Keep the Fast-compressed WIM during development. Add `Compress` only for an explicit final ESD export:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/build-install-media.ps1 -Parameters @{ IsoPath = 'D:\temp\windows.iso' } -LogDirectory '.local/launches/install-media'
    ```

24. Prepare a separate VM from the deployment ISO, using one dynamic test disk and no additional answer media. Preserve the baseline VM and its checkpoint:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/new-test-vm.ps1 -Parameters @{ IsoPath = 'D:\Repository\Projects\windows\.local\media\windows11-pro\windows11-pro.iso'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-create'
    ```

25. Validate the configured VM and its answer file with Windows SIM before starting installation:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/validate-vm-setup.ps1 -Parameters @{ WimPath = 'D:\Repository\Projects\windows\.local\catalog\pro-26300.9711\pro.wim'; VMProfile = 'Configured' } -LogDirectory '.local/launches/vm-configured-validation'
    ```

26. Start the configured VM and open its console. Press a key at the DVD boot prompt to start Windows Setup from the configured ISO:

    ```powershell
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Start'; VMProfile = 'Configured'; OpenConsole = $true } -LogDirectory '.local/launches/vm-configured-start'
    ```

27. Let Setup prepare the single test disk automatically. Create a local administrator through the standard OOBE account page and sign in.

28. Audit the fresh installation using the local account created in OOBE, compare repeated inventories, and save the configured checkpoint. The credential prompt authenticates host-side audit access to this test VM; it is not part of image preparation. Review the reports according to the [audit guide](audit.md):

    ```powershell
    $credential = Get-Credential -Message 'Local administrator created in the configured VM OOBE'
    .\scripts\run-elevated.ps1 -ScriptPath scripts/run-vm-baseline.ps1 -Parameters @{ Action = 'Capture'; VMProfile = 'Configured'; Credential = $credential } -LogDirectory '.local/launches/vm-configured-capture'
    ```
