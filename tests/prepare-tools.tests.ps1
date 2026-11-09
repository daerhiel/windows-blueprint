#Requires -Version 5.1
<#
.SYNOPSIS
Checks tool preparation with synthetic downloads, layouts, and installer processes.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fixture helpers and process doubles affect only isolated synthetic files.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Scope = 'Function', Target = 'Get-AuthenticodeSignature', Justification = 'Signature validation uses synthetic certificates, never host trust changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Scope = 'Function', Target = 'Invoke-WebRequest', Justification = 'The network double copies only local fixture files.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Scope = 'Function', Target = 'Start-Process', Justification = 'The process double verifies native exit handling without starting an installer.')]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'workflows\prepare-tools.ps1') -Action Check
$nativeProcess = (Get-Command Invoke-PreparationProcess).ScriptBlock
$fixture = Join-Path $repository ('.local\ops\tools-workflow-tests\' + [guid]::NewGuid().ToString('N'))
$checks = 0
function Assert-ToolsTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:checks++
}
function Assert-ToolsFailure {
    param([scriptblock] $Action, [string] $Expected)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-ToolsTest ($message -like ('*' + $Expected + '*')) ('Expected ' + $Expected + '; actual: ' + $message)
}
function Write-ToolsFixtureFile {
    param([string] $Path, [string] $Content)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
$root = Join-Path $fixture 'repository with spaces'
[IO.Directory]::CreateDirectory((Join-Path $root 'config')) | Out-Null
$adkSource = Join-Path $root 'sources\adksetup.exe'
$winpeSource = Join-Path $root 'sources\adkwinpesetup.exe'
$lgpoSource = Join-Path $root 'sources\LGPO.zip'
$adkHash = Write-ToolsFixtureFile $adkSource 'synthetic ADK bootstrapper'
$winpeHash = Write-ToolsFixtureFile $winpeSource 'synthetic WinPE bootstrapper'
$installed = [ordered]@{
    dism = Join-Path $root 'host\adk\DISM\dism.exe'
    wsim = Join-Path $root 'host\adk\WSIM\wsim.dll'
    oscdimg = Join-Path $root 'host\adk\Oscdimg\oscdimg.exe'
    cab = Join-Path $root '.local\tools\winpe\WinPE_OCs\WinPE-Test.cab'
    lgpo = Join-Path $root '.local\tools\lgpo\LGPO_30\LGPO.exe'
}
$fileHashes = @{}
foreach ($key in $installed.Keys) { $fileHashes[$key] = Write-ToolsFixtureFile $installed[$key] ('synthetic ' + $key) }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archiveSource = Join-Path $root 'sources\lgpo-archive'
Write-ToolsFixtureFile (Join-Path $archiveSource 'LGPO_30\LGPO.exe') 'synthetic lgpo' | Out-Null
[IO.Compression.ZipFile]::CreateFromDirectory($archiveSource, $lgpoSource)
$inputLock = [ordered]@{
    schemaVersion = 1
    adk = @{ version = '10.1.12345.678'; features = @('OptionId.DeploymentTools'); setupUrl = 'https://example.invalid/adk'; setupSha256 = $adkHash; dismDirectory = Split-Path $installed.dism -Parent; files = @{ 'dism.exe' = $fileHashes.dism }; wsim = @{ directory = Split-Path $installed.wsim -Parent; files = @{ 'wsim.dll' = $fileHashes.wsim } }; oscdimg = @{ path = $installed.oscdimg; sha256 = $fileHashes.oscdimg } }
    winpe = @{ version = '10.1.12345.678'; setupUrl = 'https://example.invalid/winpe'; setupSha256 = $winpeHash; packageDirectory = '.local/tools/winpe/WinPE_OCs'; packages = @(@{ path = 'WinPE-Test.cab'; sha256 = $fileHashes.cab }) }
    lgpo = @{ version = 'synthetic'; archiveUrl = 'https://example.invalid/lgpo'; archiveSha256 = (Get-FileHash $lgpoSource).Hash; path = '.local/tools/lgpo/LGPO_30/LGPO.exe'; sha256 = $fileHashes.lgpo }
}
$lockPath = Join-Path $root 'config\toolchain.lock.json'
$inputLock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $lockPath -Encoding UTF8
$sources = @{ 'https://example.invalid/adk' = $adkSource; 'https://example.invalid/winpe' = $winpeSource; 'https://example.invalid/lgpo' = $lgpoSource }
$administrator = $true
$validSignature = $true
$badDownload = $false
$badInstall = $false
$uninstallFails = $false
$uninstallLeavesProducts = $false
$hostProducts = @{ Adk = [Collections.Generic.List[object]]::new(); WinPE = [Collections.Generic.List[object]]::new(); Lgpo = [Collections.Generic.List[object]]::new() }
$processCalls = [Collections.Generic.List[object]]::new()
$downloadCalls = [Collections.Generic.List[string]]::new()
function Test-PreparationAdministrator { $administrator }
function Get-AuthenticodeSignature {
    param([string] $LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { throw 'Missing signature fixture input.' }
    $status = 'Valid'; if (-not $validSignature) { $status = 'NotTrusted' }
    [pscustomobject]@{ Status = $status; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Fixture, O=Microsoft Corporation, C=US' } }
}
function Invoke-WebRequest {
    param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing)
    if (-not $UseBasicParsing) { throw 'Expected basic parsing for installer downloads.' }
    $downloadCalls.Add($Uri)
    if ($badDownload) { Write-ToolsFixtureFile $OutFile 'wrong download' | Out-Null }
    else { Copy-Item -LiteralPath $sources[$Uri] -Destination $OutFile }
}
function Invoke-PreparationProcess {
    param([string] $Path, [string[]] $Arguments)
    $processCalls.Add([pscustomobject]@{ path = $Path; arguments = $Arguments })
    if ($Arguments -contains '/uninstall') {
        if ($uninstallFails) { throw 'Synthetic uninstall failure' }
        $toolName = 'Adk'
        if ((Split-Path $Path -Leaf) -eq 'adkwinpesetup.exe') { $toolName = 'WinPE' }
        if (-not $uninstallLeavesProducts) {
            for ($i = $hostProducts[$toolName].Count - 1; $i -ge 0; $i--) {
                if ($toolName -eq 'WinPE' -or $hostProducts[$toolName][$i].kind -eq 'Component') { $hostProducts[$toolName].RemoveAt($i) }
            }
        }
        if ($toolName -eq 'Adk') {
            foreach ($key in @('dism', 'wsim', 'oscdimg')) { Remove-Item -LiteralPath $installed[$key] -Force }
        }
    }
    elseif ($Arguments -contains '/layout') {
        if ($Arguments -contains '/features') { throw 'Feature selection is not accepted with layout.' }
        $layout = $Arguments[[array]::IndexOf($Arguments, '/layout') + 1].Trim('"')
        [IO.Directory]::CreateDirectory($layout) | Out-Null
        Copy-Item -LiteralPath $Path -Destination (Join-Path $layout (Split-Path $Path -Leaf))
        Write-ToolsFixtureFile (Join-Path $layout 'Installers\Windows PE Optional Packages (DesktopEditions)-x86_en-us.msi') 'synthetic MSI' | Out-Null
        Write-ToolsFixtureFile (Join-Path $layout 'Installers\payload.cab') 'synthetic cabinet' | Out-Null
    }
    elseif ($Arguments -contains '/a') {
        Write-ToolsFixtureFile $installed.cab 'synthetic cab' | Out-Null
        if ($badInstall) { Write-ToolsFixtureFile $installed.cab 'wrong extracted cabinet' | Out-Null }
    }
    else {
        foreach ($key in @('dism', 'wsim', 'oscdimg')) { Write-ToolsFixtureFile $installed[$key] ('synthetic ' + $key) | Out-Null }
    }
}
function Invoke-ToolsFixture { param([string] $Action, [string] $Tool = 'All') Invoke-ToolPreparation -RepositoryRoot $root -Action $Action -Tool $Tool }
$operationPath = Join-Path $root '.local\workflows\prepare-tools\operation.json'
$result = Invoke-ToolsFixture Check
Assert-ToolsTest ($result.status -eq 'Succeeded' -and $result.tools.Count -eq 3 -and $downloadCalls.Count -eq 0 -and $processCalls.Count -eq 0) 'Check verifies all installed pins without downloading or launching installers.'
Write-ToolsFixtureFile $installed.dism 'changed dism' | Out-Null
Assert-ToolsFailure { Invoke-ToolsFixture Check } 'verification failed'
$record = Get-Content -LiteralPath $operationPath -Raw | ConvertFrom-Json
Assert-ToolsTest ($record.tools.Count -eq 3 -and $record.tools[0].status -eq 'Failed' -and $record.tools[1].status -eq 'Succeeded') 'Check retains each tool result even when an earlier tool differs.'
Write-ToolsFixtureFile $installed.dism 'synthetic dism' | Out-Null
$administrator = $false
$before = (Get-FileHash $operationPath).Hash
Assert-ToolsFailure { Invoke-ToolsFixture Download Adk } 'elevated'
Assert-ToolsFailure { Invoke-ToolsFixture Install WinPE } 'elevated'
Assert-ToolsTest ((Get-FileHash $operationPath).Hash -ceq $before) 'Privilege refusal leaves the prior report untouched.'
$result = Invoke-ToolsFixture Download Lgpo
Assert-ToolsTest ($result.status -eq 'Succeeded' -and $processCalls.Count -eq 0) 'LGPO download does not require elevation or an installer.'
$result = Invoke-ToolsFixture Install Lgpo
Assert-ToolsTest ($result.tools[0].outcome -eq 'AlreadyPresent') 'Matching installations are reused without download prerequisites.'
$administrator = $true
$result = Invoke-ToolsFixture Download
Assert-ToolsTest ($result.status -eq 'Succeeded' -and $processCalls.Count -eq 2) 'Download prepares both vendor layouts and the LGPO archive.'
$downloads = $downloadCalls.Count
Invoke-ToolsFixture Download Lgpo | Out-Null
Assert-ToolsTest ($downloadCalls.Count -eq $downloads) 'A matching archive is reused without another network request.'
$jsonLock = Get-Content $lockPath -Raw | ConvertFrom-Json
$adk = Get-PreparationSpecification -Root $root -Lock $jsonLock -Tool Adk
$winpe = Get-PreparationSpecification -Root $root -Lock $jsonLock -Tool WinPE
$lgpo = Get-PreparationSpecification -Root $root -Lock $jsonLock -Tool Lgpo
Test-PreparationLayout -Specification $adk | Out-Null
Write-ToolsFixtureFile (Join-Path $adk.cache 'layout\Installers\payload.cab') 'tampered layout' | Out-Null
Assert-ToolsFailure { Test-PreparationLayout -Specification $adk } 'fingerprint mismatch'
Invoke-ToolsFixture Download Adk | Out-Null
Write-ToolsFixtureFile $installed.dism 'needs installation' | Out-Null
$result = Invoke-ToolsFixture Install Adk
Assert-ToolsTest ($result.tools[0].outcome -eq 'Installed' -and $result.tools[0].state.matches) 'ADK installation consumes the verified offline layout and checks installed outputs.'
$arguments = $processCalls[$processCalls.Count - 1].arguments
Assert-ToolsTest ($arguments -contains '/norestart' -and $arguments -contains 'OptionId.DeploymentTools' -and $arguments -notcontains '/layout') 'Install uses the selected features and suppresses automatic restarts.'
Write-ToolsFixtureFile $installed.cab 'needs extraction' | Out-Null
Write-ToolsFixtureFile (Join-Path $winpe.managed 'obsolete.txt') 'stale managed output' | Out-Null
$result = Invoke-ToolsFixture Install WinPE
Assert-ToolsTest ($result.tools[0].outcome -eq 'Installed' -and -not (Test-Path (Join-Path $winpe.managed 'obsolete.txt'))) 'WinPE replaces only its guarded managed extraction tree.'
Write-ToolsFixtureFile $installed.lgpo 'needs extraction' | Out-Null
$result = Invoke-ToolsFixture Install Lgpo
Assert-ToolsTest ($result.tools[0].state.matches -and (Test-Path $lgpo.download)) 'LGPO extraction preserves its separate download cache.'
$calls = $processCalls.Count
Invoke-ToolsFixture Install | Out-Null
Assert-ToolsTest ($processCalls.Count -eq $calls) 'Repeated Install skips every matching tool.'
$validSignature = $false
Assert-ToolsFailure { Invoke-ToolsFixture Check Lgpo } 'Microsoft signature'
$validSignature = $true
Write-ToolsFixtureFile $lgpo.download 'invalid archive cache' | Out-Null
$badDownload = $true
Assert-ToolsFailure { Invoke-ToolsFixture Download Lgpo } 'fingerprint mismatch'
Assert-ToolsTest (-not (Test-Path ($lgpo.download + '.part')) -and (Get-Content $lgpo.download -Raw) -eq 'invalid archive cache') 'A rejected download removes its partial file and preserves the previous cache file.'
$badDownload = $false
Invoke-ToolsFixture Download Lgpo | Out-Null
Write-ToolsFixtureFile $installed.cab 'needs extraction' | Out-Null
$badInstall = $true
Assert-ToolsFailure { Invoke-ToolsFixture Install WinPE } 'differ from the lock'
$badInstall = $false
Invoke-ToolsFixture Install WinPE | Out-Null
$lockFile = [IO.FileStream]::new((Split-Path $operationPath -Parent) + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Assert-ToolsFailure { Invoke-ToolsFixture Check } 'Another tool preparation' } finally { $lockFile.Dispose() }
Assert-ToolsFailure { Assert-PreparationPath -Path (Join-Path $root 'outside') -Root $lgpo.managed } 'escapes'
$junction = Join-Path $lgpo.managed 'redirect'
New-Item -ItemType Junction -Path $junction -Target (Join-Path $root 'sources') | Out-Null
Assert-ToolsFailure { Invoke-ToolsFixture Install Lgpo } 'reparse points'
$nativeExit = 3010
function Start-Process {
    param([string] $FilePath, [string[]] $ArgumentList, [string] $WindowStyle, [switch] $Wait, [switch] $PassThru)
    if ($FilePath -ne 'synthetic-installer.exe' -or $ArgumentList -notcontains '/norestart' -or $WindowStyle -ne 'Hidden' -or -not $Wait -or -not $PassThru) { throw 'Unexpected native process contract.' }
    [pscustomobject]@{ ExitCode = $nativeExit }
}
Assert-ToolsFailure { & $nativeProcess -Path 'synthetic-installer.exe' -Arguments @('/quiet', '/norestart') } 'host restart'
$nativeExit = 1603
Assert-ToolsFailure { & $nativeProcess -Path 'synthetic-installer.exe' -Arguments @('/quiet', '/norestart') } 'exit 1603'
$nativeExit = 0
& $nativeProcess -Path 'synthetic-installer.exe' -Arguments @('/quiet', '/norestart')
Assert-ToolsTest ($downloadCalls.Count -gt 0 -and $processCalls.Count -gt 0) 'All network and installer operations were intercepted by fixture doubles.'

# Remove uses synthetic product registrations; no installed host package is queried or changed.
function Get-PreparationHostProduct { param($Specification) $hostProducts[$Specification.name].ToArray() }
[IO.Directory]::Delete($junction, $false)
$hostProducts.Adk.Add([pscustomobject]@{ name = 'Windows Deployment Tools'; version = '10.1.12345.678'; kind = 'Component'; uninstaller = $null })
$hostProducts.Adk.Add([pscustomobject]@{ name = 'Windows Assessment and Deployment Kit'; version = '10.1.12345.678'; kind = 'Bundle'; uninstaller = $null })
$hostProducts.WinPE.Add([pscustomobject]@{ name = 'Windows PE Optional Packages'; version = '10.1.12345.678'; kind = 'Component'; uninstaller = $null })
$administrator = $false
Assert-ToolsFailure { Invoke-ToolsFixture Remove Adk } 'elevated'
$administrator = $true
$hostProducts.Adk[0].version = '10.1.99999.1'
$before = $processCalls.Count
Assert-ToolsFailure { Invoke-ToolsFixture Remove } 'version differs'
Assert-ToolsTest ($processCalls.Count -eq $before -and (Test-Path $winpe.managed) -and (Test-Path $winpe.cache)) 'All removal targets are preflighted before removing any selected tool.'
$hostProducts.Adk[0].version = '10.1.12345.678'
$missingInstaller = $adk.PSObject.Copy()
$missingInstaller.cache = Join-Path $root '.local\downloads\missing-adk'
$missingInstaller.download = Join-Path $missingInstaller.cache 'adksetup.exe'
Assert-ToolsFailure { Get-PreparationRemovalPlan -Specification $missingInstaller } 'run Download'
$validSignature = $false
Assert-ToolsFailure { Invoke-ToolsFixture Remove } 'pinned Microsoft uninstaller'
Assert-ToolsTest ($processCalls.Count -eq $before -and (Test-Path $winpe.cache) -and (Test-Path $winpe.managed)) 'Untrusted uninstallers are refused before any selected tool is changed.'
$validSignature = $true
$uninstallFails = $true
Assert-ToolsFailure { Invoke-ToolsFixture Remove WinPE } 'Synthetic uninstall failure'
Assert-ToolsTest ((Test-Path $winpe.cache) -and (Test-Path $winpe.managed)) 'Failed uninstall preserves its download cache and extracted components.'
$uninstallFails = $false
$uninstallLeavesProducts = $true
Assert-ToolsFailure { Invoke-ToolsFixture Remove WinPE } 'remain registered'
Assert-ToolsTest ((Test-Path $winpe.cache) -and (Test-Path $winpe.managed)) 'Incomplete uninstall does not silently erase preparation inputs.'
$uninstallLeavesProducts = $false
$before = $processCalls.Count
$result = Invoke-ToolsFixture Remove
Assert-ToolsTest ($result.status -eq 'Succeeded' -and ($result.tools.name -join ',') -eq 'WinPE,Adk,Lgpo') 'Remove All handles the WinPE add-on before ADK and removes LGPO last.'
$uninstalls = @($processCalls.ToArray() | Select-Object -Skip $before)
Assert-ToolsTest ($uninstalls.Count -eq 2 -and $uninstalls[0].arguments -contains '/uninstall' -and $uninstalls[1].arguments -contains 'OptionId.DeploymentTools' -and $uninstalls[1].arguments -contains '/norestart') 'Host removal uses verified native uninstallers and only locked ADK features.'
Assert-ToolsTest (-not (Test-Path $adk.cache) -and -not (Test-Path $winpe.cache) -and -not (Test-Path $lgpo.cache) -and -not (Test-Path $winpe.managed) -and -not (Test-Path $lgpo.managed)) 'Remove deletes only selected local installer and managed-tool directories.'
Assert-ToolsTest ((Test-Path $lockPath) -and (Test-Path $adkSource) -and (Test-Path $operationPath)) 'Tool removal preserves configuration, unrelated source files, and operation evidence.'
$before = $processCalls.Count
Invoke-ToolsFixture Remove | Out-Null
Assert-ToolsTest ($processCalls.Count -eq $before) 'Repeated removal of absent tools does not run an uninstaller.'
Assert-ToolsTest ($hostProducts.Adk.Count -eq 1 -and $hostProducts.Adk[0].kind -eq 'Bundle') 'An ADK bundle retained for other features does not trigger repeated uninstall.'
Write-ToolsFixtureFile $lgpo.download 'synthetic cached archive' | Out-Null
Write-ToolsFixtureFile $installed.lgpo 'synthetic extracted LGPO' | Out-Null
Write-ToolsFixtureFile $adk.download 'unrelated selected-tool cache' | Out-Null
$administrator = $false
Invoke-ToolsFixture Remove Lgpo | Out-Null
Assert-ToolsTest (-not (Test-Path $lgpo.cache) -and -not (Test-Path $lgpo.managed) -and (Test-Path $adk.download) -and $processCalls.Count -eq $before) 'LGPO removal needs no elevation and preserves other tools.'
Write-Output ("Passed $checks tool preparation checks without installing host tools or using the network.")
