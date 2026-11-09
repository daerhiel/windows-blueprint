#Requires -Version 5.1
<#
.SYNOPSIS
Downloads, installs, checks, or removes the build tools pinned in the toolchain lock.
.DESCRIPTION
Runs in a 64-bit PowerShell Windows process.
Check and LGPO operations need no elevation. ADK/WinPE preparation and removal
require an elevated PowerShell terminal. Elevation is never requested
internally. Download prepares verified offline layouts; Install consumes that cache.
Remove uninstalls selected host components and deletes their local tool caches.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Download', 'Install', 'Check', 'Remove')] [string] $Action,
    [ValidateSet('Adk', 'WinPE', 'Lgpo', 'All')] [string] $Tool = 'All'
)

. (Join-Path $PSScriptRoot '..\scripts\workflow-output.ps1')

function Assert-PreparationPath {
    param([string] $Path, [string] $Root, [switch] $Contents)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $boundary = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full -ine $boundary -and -not $full.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)) { throw ('Path escapes the tool preparation directory: ' + $full) }
    $ancestor = $full
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw ('Reparse point in tool preparation path: ' + $ancestor) }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    if ($Contents -and (Test-Path -LiteralPath $full)) {
        if (@(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Tool preparation contents contain reparse points.' }
    }
    $full
}

function Assert-PreparationFile {
    param([string] $Path, [string] $Sha256)
    if ($Sha256 -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Sha256) { throw ('Tool fingerprint mismatch: ' + $Path) }
}

function Assert-PreparationSignature {
    param([string] $Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') { throw ('A valid Microsoft signature is required: ' + $Path) }
}

function Get-PreparationSpecification {
    param([string] $Root, $Lock, [ValidateSet('Adk', 'WinPE', 'Lgpo')] [string] $Tool)
    $pins = @()
    $managed = $null
    $signaturePath = $null
    switch ($Tool) {
        Adk {
            $entry = $Lock.adk
            $cache = Join-Path $Root ('.local\downloads\adk-' + ([version]$entry.version).Build)
            foreach ($file in $entry.files.PSObject.Properties) { $pins += [pscustomobject]@{ path = Join-Path $entry.dismDirectory $file.Name; sha256 = $file.Value } }
            foreach ($file in $entry.wsim.files.PSObject.Properties) { $pins += [pscustomobject]@{ path = Join-Path $entry.wsim.directory $file.Name; sha256 = $file.Value } }
            $pins += [pscustomobject]@{ path = $entry.oscdimg.path; sha256 = $entry.oscdimg.sha256 }
            if (-not @($entry.features).Count -or @($entry.features | Where-Object { $_ -notmatch '^OptionId\.[A-Za-z0-9]+$' }).Count) { throw 'Invalid ADK feature selection in the toolchain lock.' }
            $name = 'adksetup.exe'
        }
        WinPE {
            $entry = $Lock.winpe
            $cache = Join-Path $Root '.local\downloads\adk-winpe'
            $managed = Join-Path $Root '.local\tools\winpe'
            $packages = Assert-PreparationPath -Path (Join-Path $Root $entry.packageDirectory) -Root $managed
            foreach ($file in $entry.packages) {
                $pins += [pscustomobject]@{ path = Assert-PreparationPath -Path (Join-Path $packages $file.path) -Root $packages; sha256 = $file.sha256 }
            }
            $name = 'adkwinpesetup.exe'
        }
        Lgpo {
            $entry = $Lock.lgpo
            $cache = Join-Path $Root '.local\downloads\lgpo'
            $managed = Join-Path $Root '.local\tools\lgpo'
            $signaturePath = Assert-PreparationPath -Path (Join-Path $Root $entry.path) -Root $managed
            $pins += [pscustomobject]@{ path = $signaturePath; sha256 = $entry.sha256 }
            $name = 'LGPO.zip'
        }
    }
    if (-not $pins.Count) { throw ('The toolchain lock contains no file pins for ' + $Tool) }
    foreach ($pin in $pins) { if ($pin.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid toolchain file fingerprint.' } }
    Assert-PreparationPath -Path $cache -Root (Join-Path $Root '.local\downloads') -Contents | Out-Null
    if ($managed) { Assert-PreparationPath -Path $managed -Root (Join-Path $Root '.local\tools') -Contents | Out-Null }
    if ($Tool -eq 'Lgpo') { $url = $entry.archiveUrl; $hash = $entry.archiveSha256 }
    else { $url = $entry.setupUrl; $hash = $entry.setupSha256 }
    if ($url -notmatch '^https://' -or $hash -notmatch '^[a-f0-9]{64}$') { throw 'Tool downloads require an HTTPS URL and pinned SHA-256.' }
    [pscustomobject]@{ name = $Tool; entry = $entry; cache = $cache; download = Join-Path $cache $name; downloadName = $name; url = $url; sha256 = $hash; managed = $managed; pins = $pins; signaturePath = $signaturePath }
}

function Get-PreparationState {
    param($Specification)
    Write-WorkflowMessage ($Specification.name + ': verifying prepared files against the toolchain lock.')
    $files = @(foreach ($pin in $Specification.pins) {
        $actual = $null
        $status = 'Missing'
        if (Test-Path -LiteralPath $pin.path -PathType Leaf) {
            $actual = (Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash
            $status = 'Mismatch'
            if ($actual -ieq $pin.sha256) { $status = 'Match' }
        }
        [pscustomobject]@{ path = $pin.path; expectedSha256 = $pin.sha256; observedSha256 = $actual; status = $status }
    })
    $matched = @($files | Where-Object status -ne 'Match').Count -eq 0
    if ($matched -and $Specification.signaturePath) { Assert-PreparationSignature -Path $Specification.signaturePath }
    [pscustomobject]@{ matches = $matched; files = $files }
}

function Invoke-PreparationProcess {
    param([string] $Path, [string[]] $Arguments)
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -eq 1618) {
        throw ('Another installation or kit setup is already running (exit 1618). Wait for it to finish or close its setup window, then repeat this command. Installer: ' + $Path)
    }
    if ($process.ExitCode -eq 3010) {
        Write-WorkflowMessage 'The installer requires a host restart. Restart normally before repeating the operation.' -Level Warning
        throw 'Tool preparation requires a host restart. Restart normally and repeat the operation; no automatic restart was requested.'
    }
    if ($process.ExitCode -ne 0) { throw ('Tool preparation process failed with exit {0}: {1}' -f $process.ExitCode, $Path) }
}

function Save-PreparationLayout {
    param($Specification)
    Write-WorkflowMessage ($Specification.name + ': computing offline layout file hashes and saving the receipt.')
    $layout = Join-Path $Specification.cache 'layout'
    Assert-PreparationPath -Path $layout -Root $Specification.cache -Contents | Out-Null
    $files = @(Get-ChildItem -LiteralPath $layout -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($layout.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    if (-not $files.Count) { throw 'The installer did not produce an offline layout.' }
    Assert-PreparationFile -Path (Join-Path $layout $Specification.downloadName) -Sha256 $Specification.sha256
    [ordered]@{ schemaVersion = 1; setupSha256 = $Specification.sha256; createdAtUtc = [DateTime]::UtcNow.ToString('o'); files = $files } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Specification.cache 'layout.json') -Encoding UTF8
}

function Test-PreparationLayout {
    param($Specification)
    Write-WorkflowMessage ($Specification.name + ': verifying the cached offline layout and all file hashes.')
    $layout = Join-Path $Specification.cache 'layout'
    Assert-PreparationPath -Path $layout -Root $Specification.cache -Contents | Out-Null
    $receiptPath = Join-Path $Specification.cache 'layout.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.schemaVersion -ne 1 -or $receipt.setupSha256 -ine $Specification.sha256 -or -not @($receipt.files).Count) { throw 'Offline layout receipt differs from the pinned installer; run Download.' }
    if (@(Get-ChildItem -LiteralPath $layout -Recurse -File -Force).Count -ne @($receipt.files).Count) { throw 'Offline layout file set changed; run Download.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $receipt.files) {
        $path = Assert-PreparationPath -Path (Join-Path $layout $file.path) -Root $layout
        if (-not $seen.Add($path)) { throw 'Duplicate offline layout file identity.' }
        Assert-PreparationFile -Path $path -Sha256 $file.sha256
    }
    Assert-PreparationFile -Path (Join-Path $layout $Specification.downloadName) -Sha256 $Specification.sha256
    $layout
}

function Invoke-PreparationDownload {
    param($Specification)
    [IO.Directory]::CreateDirectory($Specification.cache) | Out-Null
    Write-WorkflowMessage ($Specification.name + ': checking the cached download:') -Data $Specification.download
    $valid = (Test-Path -LiteralPath $Specification.download -PathType Leaf) -and (Get-FileHash -LiteralPath $Specification.download -Algorithm SHA256).Hash -ieq $Specification.sha256
    if (-not $valid) {
        if (Test-Path -LiteralPath $Specification.download) {
            Write-WorkflowMessage ($Specification.name + ': the cached download differs from the lock; downloading a verified replacement.') -Level Warning
        }
        $temporary = Assert-PreparationPath -Path ($Specification.download + '.part') -Root $Specification.cache
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        try {
            Write-WorkflowMessage ($Specification.name + ': downloading ' + $Specification.downloadName + ' to') -Data $temporary
            Invoke-WebRequest -Uri $Specification.url -OutFile $temporary -UseBasicParsing | Out-Null
            Write-WorkflowMessage ($Specification.name + ': verifying the downloaded file hash.')
            Assert-PreparationFile -Path $temporary -Sha256 $Specification.sha256
            if ($Specification.name -ne 'Lgpo') {
                Write-WorkflowMessage ($Specification.name + ': verifying the Microsoft signature on the downloaded installer.')
                Assert-PreparationSignature -Path $temporary
            }
            Move-Item -LiteralPath $temporary -Destination $Specification.download -Force
        }
        finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    }
    else { Write-WorkflowMessage ($Specification.name + ': reusing the cached download; its hash matches the lock.') -Level Success }
    Assert-PreparationFile -Path $Specification.download -Sha256 $Specification.sha256
    if ($Specification.name -ne 'Lgpo') {
        Assert-PreparationSignature -Path $Specification.download
        $layout = Join-Path $Specification.cache 'layout'
        $log = Join-Path $Specification.cache 'layout.log'
        Write-WorkflowMessage ($Specification.name + ': preparing the offline layout with the vendor installer; waiting for it to finish. Log:') -Data $log
        Invoke-PreparationProcess -Path $Specification.download -Arguments @('/quiet', '/norestart', '/layout', ('"' + $layout + '"'), '/log', ('"' + $log + '"'))
        Save-PreparationLayout -Specification $Specification
    }
}

function Invoke-PreparationInstall {
    param($Specification)
    $before = Get-PreparationState -Specification $Specification
    if ($before.matches) {
        Write-WorkflowMessage ($Specification.name + ': prepared files already match; skipping installation.') -Level Success
        return [pscustomobject]@{ outcome = 'AlreadyPresent'; state = $before }
    }
    if ($Specification.name -eq 'Adk') {
        $layout = Test-PreparationLayout -Specification $Specification
        $installer = Join-Path $layout $Specification.downloadName
        Assert-PreparationSignature -Path $installer
        $arguments = @('/quiet', '/norestart', '/features') + @($Specification.entry.features) + @('/log', ('"' + (Join-Path $Specification.cache 'install.log') + '"'))
        Write-WorkflowMessage 'Adk: installing the selected Deployment Tools; waiting for the vendor installer to finish. Log:' -Data (Join-Path $Specification.cache 'install.log')
        Invoke-PreparationProcess -Path $installer -Arguments $arguments
    }
    else {
        if ($Specification.name -eq 'WinPE') {
            $layout = Test-PreparationLayout -Specification $Specification
            $package = Join-Path $layout 'Installers\Windows PE Optional Packages (DesktopEditions)-x86_en-us.msi'
            Assert-PreparationSignature -Path $package
        }
        else {
            Write-WorkflowMessage 'Lgpo: verifying the cached archive hash and extraction paths.'
            Assert-PreparationFile -Path $Specification.download -Sha256 $Specification.sha256
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($Specification.download)
            try {
                foreach ($entry in $archive.Entries) {
                    Assert-PreparationPath -Path (Join-Path $Specification.managed $entry.FullName) -Root $Specification.managed | Out-Null
                    if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'LGPO archive contains a symbolic link.' }
                }
            }
            finally { $archive.Dispose() }
        }
        $target = Assert-PreparationPath -Path $Specification.managed -Root (Split-Path $Specification.managed -Parent) -Contents
        if (Test-Path -LiteralPath $target) {
            Write-WorkflowMessage ($Specification.name + ': replacing the managed extraction directory:') -Data $target -Level Warning
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        [IO.Directory]::CreateDirectory($target) | Out-Null
        if ($Specification.name -eq 'WinPE') {
            Write-WorkflowMessage 'WinPE: extracting optional-component packages with Windows Installer; waiting for extraction to finish. Log:' -Data (Join-Path $Specification.cache 'extract.log')
            Invoke-PreparationProcess -Path (Join-Path $env:WINDIR 'System32\msiexec.exe') -Arguments @('/a', ('"' + $package + '"'), '/qn', '/norestart', ('TARGETDIR="' + $target + '"'), '/l*v', ('"' + (Join-Path $Specification.cache 'extract.log') + '"'))
        }
        else {
            Write-WorkflowMessage 'Lgpo: extracting the verified archive to' -Data $target
            Expand-Archive -LiteralPath $Specification.download -DestinationPath $target
        }
    }
    $after = Get-PreparationState -Specification $Specification
    if (-not $after.matches) { throw ('Prepared tool files differ from the lock: ' + $Specification.name) }
    [pscustomobject]@{ outcome = 'Installed'; state = $after }
}

function Get-PreparationHostProduct {
    param($Specification)
    if ($Specification.name -eq 'Lgpo') { return }
    $bundle = '^Windows Assessment and Deployment Kit(?: - Windows (?:10|11))?$'
    $components = '^Windows Deployment Tools(?: Environment)?$'
    if ($Specification.name -eq 'WinPE') {
        $bundle = '^Windows Assessment and Deployment Kit Windows Preinstallation Environment Add-ons(?: - Windows (?:10|11))?$'
        $components = '^Windows PE(?: |$)'
    }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction Stop) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $displayName = $properties.PSObject.Properties['DisplayName']
            if (-not $displayName -or ($displayName.Value -notmatch $bundle -and $displayName.Value -notmatch $components)) { continue }
            $version = $properties.PSObject.Properties['DisplayVersion']
            $publisher = $properties.PSObject.Properties['Publisher']
            if (-not $version -or -not $publisher -or $publisher.Value -notin @('Microsoft', 'Microsoft Corporation')) { throw 'Installed tool registration has an unexpected publisher or version.' }
            $kind = 'Component'; $uninstaller = $null
            if ($displayName.Value -match $bundle) {
                $kind = 'Bundle'
                $command = $properties.PSObject.Properties['UninstallString']
                if ($command -and $command.Value -match '^"([^"\r\n]+\.exe)"\s+/uninstall(?:\s|$)') { $uninstaller = $Matches[1] }
            }
            [pscustomobject]@{ name = $displayName.Value; version = [string]$version.Value; kind = $kind; uninstaller = $uninstaller }
        }
    }
}

function Get-PreparationRemovalPlan {
    param($Specification)
    Write-WorkflowMessage ($Specification.name + ': inspecting installed product registrations and verifying removal inputs.')
    $products = @(Get-PreparationHostProduct -Specification $Specification)
    if (@($products | Where-Object { $_.version -cne $Specification.entry.version }).Count) { throw ('Installed ' + $Specification.name + ' version differs from the toolchain lock; removal is refused.') }
    $uninstall = $products.Count -gt 0
    if ($Specification.name -eq 'Adk') {
        # A bundle can remain for unrelated ADK features after Deployment Tools removal.
        $uninstall = @($products | Where-Object kind -eq 'Component').Count -gt 0 -or @($Specification.pins | Where-Object { Test-Path -LiteralPath $_.path }).Count -gt 0
    }
    $installer = $null
    if ($uninstall) {
        $candidates = @($Specification.download, (Join-Path $Specification.cache ('layout\' + $Specification.downloadName))) + @($products | Where-Object uninstaller | ForEach-Object uninstaller)
        foreach ($path in @($candidates | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                Assert-PreparationFile -Path $path -Sha256 $Specification.sha256
                Assert-PreparationSignature -Path $path
                $installer = $path
                break
            }
            catch { Write-Verbose ('Rejected uninstaller candidate: ' + $path) }
        }
        if (-not $installer) { throw ('A pinned Microsoft uninstaller is required for ' + $Specification.name + '; run Download to restore it. No cleanup was performed.') }
    }
    [pscustomobject]@{ uninstallRequired = $uninstall; installer = $installer; products = $products; cache = $Specification.cache; managed = $Specification.managed }
}

function Invoke-PreparationRemove {
    param($Specification, $Plan, [string] $LogDirectory)
    if ($Plan.uninstallRequired) {
        # Verify immediately before execution; registration command strings are never executed.
        Assert-PreparationFile -Path $Plan.installer -Sha256 $Specification.sha256
        Assert-PreparationSignature -Path $Plan.installer
        Assert-PreparationPath -Path $LogDirectory -Root (Split-Path $LogDirectory -Parent) -Contents | Out-Null
        [IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
        $arguments = @('/uninstall', '/quiet', '/norestart')
        if ($Specification.name -eq 'Adk') { $arguments += @('/features') + @($Specification.entry.features) }
        $arguments += @('/log', ('"' + (Join-Path $LogDirectory ($Specification.name.ToLowerInvariant() + '-remove.log')) + '"'))
        Write-WorkflowMessage ($Specification.name + ': uninstalling the selected host components; waiting for the vendor uninstaller to finish. Logs:') -Data $LogDirectory -Level Warning
        Invoke-PreparationProcess -Path $Plan.installer -Arguments $arguments
        Write-WorkflowMessage ($Specification.name + ': checking that the selected host components were removed.')
        $remaining = @(Get-PreparationHostProduct -Specification $Specification)
        if ($Specification.name -eq 'Adk') {
            if (@($Specification.pins | Where-Object { Test-Path -LiteralPath $_.path }).Count -or @($remaining | Where-Object kind -eq 'Component').Count) { throw 'ADK deployment components remain after uninstall; download cache was retained.' }
        }
        elseif ($remaining.Count) { throw 'WinPE components remain registered after uninstall; download cache was retained.' }
    }
    else { Write-WorkflowMessage ($Specification.name + ': no selected host components require uninstalling.') }
    foreach ($path in @($Specification.managed, $Specification.cache)) {
        if (-not $path) { continue }
        $target = Assert-PreparationPath -Path $path -Root (Split-Path $path -Parent) -Contents
        if (Test-Path -LiteralPath $target) {
            Write-WorkflowMessage ($Specification.name + ': deleting the owned tool directory:') -Data $target -Level Warning
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        }
    }
    [pscustomobject]@{ outcome = 'Removed'; state = [pscustomobject]@{ hostProducts = @(Get-PreparationHostProduct -Specification $Specification); cachePresent = Test-Path -LiteralPath $Specification.cache; managedPresent = ($Specification.managed -and (Test-Path -LiteralPath $Specification.managed)) } }
}

function Test-PreparationAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}

function Invoke-ToolPreparation {
    param([string] $RepositoryRoot, [ValidateSet('Download', 'Install', 'Check', 'Remove')] [string] $Action, [ValidateSet('Adk', 'WinPE', 'Lgpo', 'All')] [string] $Tool)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $lockPath = Join-Path $root 'config\toolchain.lock.json'
    Write-WorkflowMessage 'Loading configuration and checking tool preparation prerequisites:' -Data ($Action + ' / ' + $Tool)
    $inputHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
    $inputLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ($inputLock.schemaVersion -ne 1) { throw 'Expected toolchain lock schema 1.' }
    $order = @('Adk', 'WinPE', 'Lgpo')
    if ($Action -eq 'Remove') { $order = @('WinPE', 'Adk', 'Lgpo') }
    $names = $order | Where-Object { $Tool -eq 'All' -or $_ -eq $Tool }
    if ($Action -ne 'Check' -and @($names | Where-Object { $_ -in @('Adk', 'WinPE') }).Count -and -not (Test-PreparationAdministrator)) { throw 'ADK/WinPE preparation and removal require an elevated PowerShell terminal.' }
    $specifications = @($names | ForEach-Object { Get-PreparationSpecification -Root $root -Lock $inputLock -Tool $_ })
    $output = Join-Path $root '.local\workflows\prepare-tools'
    foreach ($path in @($output, ($output + '.lock'), (Join-Path $output 'operation.json'))) { Assert-PreparationPath -Path $path -Root (Join-Path $root '.local') | Out-Null }
    [IO.Directory]::CreateDirectory((Split-Path $output -Parent)) | Out-Null
    try { $lock = [IO.FileStream]::new(($output + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose) }
    catch { throw 'Another tool preparation operation is running.' }
    $operation = [ordered]@{ schemaVersion = 1; action = $Action; tool = $Tool; status = 'Running'; toolchainLockSha256 = $inputHash; startedAtUtc = [DateTime]::UtcNow.ToString('o'); completedAtUtc = $null; tools = @(); error = $null }
    try {
        [IO.Directory]::CreateDirectory($output) | Out-Null
        if ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash -cne $inputHash) { throw 'The toolchain lock changed during preparation preflight.' }
        $removalPlans = @{}
        if ($Action -eq 'Remove') {
            # Preflight the entire selection before uninstalling or deleting any selected tool.
            Write-WorkflowMessage 'Checking removal prerequisites for all selected tools before making changes.'
            foreach ($specification in $specifications) { $removalPlans[$specification.name] = Get-PreparationRemovalPlan -Specification $specification }
        }
        foreach ($specification in $specifications) {
            $current = [ordered]@{ name = $specification.name; status = 'Running'; outcome = $null; state = $null; removal = $null; error = $null }
            if ($Action -eq 'Remove') { $current.removal = $removalPlans[$specification.name] }
            $operation.tools += $current
            $operation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'operation.json') -Encoding UTF8
            Write-WorkflowMessage ($specification.name + ': starting') -Data $Action
            switch ($Action) {
                Check {
                    $current.state = Get-PreparationState -Specification $specification
                    if (-not $current.state.matches) { $current.status = 'Failed'; $current.error = 'Pinned tool files are missing or differ from the lock.' }
                    else { $current.outcome = 'Verified' }
                }
                Download { Invoke-PreparationDownload -Specification $specification; $current.outcome = 'Downloaded' }
                Install {
                    $result = Invoke-PreparationInstall -Specification $specification
                    $current.state = $result.state; $current.outcome = $result.outcome
                }
                Remove {
                    $result = Invoke-PreparationRemove -Specification $specification -Plan $removalPlans[$specification.name] -LogDirectory (Join-Path $output 'logs')
                    $current.state = $result.state; $current.outcome = $result.outcome
                }
            }
            if ($current.status -eq 'Failed') {
                Write-WorkflowMessage ($specification.name + ':') -Data $current.error -Level Error
                continue
            }
            $current.status = 'Succeeded'
            Write-WorkflowMessage ($specification.name + ':') -Data $current.outcome -Level Success
        }
        if (@($operation.tools | Where-Object status -ne 'Succeeded').Count) { throw 'Tool verification failed; see the preparation report.' }
        if ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash -cne $operation.toolchainLockSha256) { throw 'The toolchain lock changed during preparation.' }
        $operation.status = 'Succeeded'
    }
    catch {
        $operation.status = 'Failed'; $operation.error = $_.Exception.Message
        if ($operation.tools.Count -and $operation.tools[-1].status -eq 'Running') { $operation.tools[-1].status = 'Failed'; $operation.tools[-1].error = $operation.error }
        Write-WorkflowMessage 'Tool preparation failed:' -Data $operation.error -Level Error
    }
    finally {
        $operation.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        try { $operation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'operation.json') -Encoding UTF8 }
        finally { $lock.Dispose() }
    }
    if ($operation.status -ne 'Succeeded') { throw $operation.error }
    Write-WorkflowMessage 'Tool preparation completed. Report:' -Data (Join-Path $output 'operation.json') -Level Success
    [pscustomobject]$operation
}

if ($MyInvocation.InvocationName -eq '.') { return }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Tool preparation requires Windows.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use a 64-bit PowerShell process.' }
if ($PSCmdlet.ShouldProcess(('Pinned build tools: ' + $Tool), $Action)) { Invoke-ToolPreparation -RepositoryRoot (Split-Path $PSScriptRoot -Parent) -Action $Action -Tool $Tool | Out-Null }
