#Requires -Version 5.1
<#
.SYNOPSIS
Checks source preparation with isolated synthetic exporter processes and artifacts.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'scripts\workflow-output.ps1')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'workflows\prepare-source.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'Source preparation contains syntax errors.' }
$functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SourcePreparation' }, $false))
if ($functions.Count -ne 1) { throw 'Expected one source-preparation coordinator.' }
. ([scriptblock]::Create($functions[0].Extent.Text))
$fixtureRoot = Join-Path $repository ('.local\ops\source-workflow-tests\' + [guid]::NewGuid().ToString('N'))
$checks = 0
function Assert-SourceTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:checks++
}
function Assert-SourceFailure {
    param([scriptblock] $Action, [string] $Expected)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-SourceTest ($message -like ('*' + $Expected + '*')) ('Expected ' + $Expected + '; actual: ' + $message)
}
$worker = @'
param([string] $IsoPath, [string] $OutputDirectory, [string] $SourceLockPath, [string] $ToolchainLockPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$behavior = Get-Content -LiteralPath (Join-Path $root 'behavior.json') -Raw | ConvertFrom-Json
$source = Get-Content -LiteralPath $SourceLockPath -Raw | ConvertFrom-Json
$toolchain = Get-Content -LiteralPath $ToolchainLockPath -Raw | ConvertFrom-Json
Set-Content -LiteralPath (Join-Path $root 'called.txt') -Value $OutputDirectory
Write-Host 'Synthetic exporter: reading source' -ForegroundColor Cyan
if ((Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash -ine $source.iso.sha256) { exit 9 }
if ($behavior.exitCode) { exit $behavior.exitCode }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
if (-not $behavior.omitWim) { Set-Content -LiteralPath (Join-Path $OutputDirectory 'pro.wim') -Value 'synthetic source WIM' }
$catalog = @{ schemaVersion = 1; sourceIsoSha256 = $source.iso.sha256; sourceImage = $source.selectedImage; adkVersion = $toolchain.adk.version }
if ($behavior.wrongIso) { $catalog.sourceIsoSha256 = '0' * 64 }
if ($behavior.wrongImage) { $catalog.sourceImage.index++ }
if ($behavior.wrongAdk) { $catalog.adkVersion = 'different' }
if (-not $behavior.omitCatalog) { $catalog | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'catalog.json') -Encoding UTF8 }
$template = '@{ SchemaVersion = 1; OptionalFeatures = @{}; Capabilities = @{}; InboxApps = @{} }'
if ($behavior.activeSelection) { $template = '@{ SchemaVersion = 1; OptionalFeatures = @{ Example = "Enabled" }; Capabilities = @{}; InboxApps = @{} }' }
if (-not $behavior.omitSelections) { Set-Content -LiteralPath (Join-Path $OutputDirectory 'selections.psd1') -Value $template -Encoding UTF8 }
$started = [DateTime]::UtcNow
if ($behavior.staleReport) { $started = $started.AddDays(-1) }
$report = @{ schemaVersion = 1; status = $behavior.status; startedAtUtc = $started.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o'); unmountedImage = $behavior.unmountedImage; detachedIso = $false; cleanupErrors = @($behavior.cleanupErrors) }
if (-not $behavior.omitReport) { $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'operation.json') -Encoding UTF8 }
if ($behavior.changeLock) { Add-Content -LiteralPath $ToolchainLockPath -Value ' ' }
exit 0
'@
function New-SourceFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only synthetic files in a unique Git-ignored test fixture; no source image is mounted or exported.')]
    param([string] $Name, [hashtable] $Behavior = @{})
    $root = Join-Path $fixtureRoot ($Name + ' with spaces')
    foreach ($directory in @('config', 'scripts')) { [IO.Directory]::CreateDirectory((Join-Path $root $directory)) | Out-Null }
    $iso = Join-Path $root 'source [test] & image.iso'
    Set-Content -LiteralPath $iso -Value 'synthetic ISO'
    Set-Content -LiteralPath (Join-Path $root 'scripts\export-image-catalog.ps1') -Value $worker -Encoding UTF8
    $source = @{ schemaVersion = 1; iso = @{ sha256 = (Get-FileHash -LiteralPath $iso).Hash }; selectedImage = @{ path = 'sources/install.esd'; index = 6; name = 'Windows 11 Pro'; editionId = 'Professional'; architecture = 'x64'; version = '10.0.34567.890'; defaultLanguage = 'en-US' } }
    $source | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'config\source-image.lock.json') -Encoding UTF8
    @{ schemaVersion = 1; adk = @{ version = '10.1.23456.789' } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config\toolchain.lock.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'config\windows.psd1') -Value '@{ ExistingProfile = $true }'
    $settings = @{ exitCode = 0; status = 'Succeeded'; omitReport = $false; staleReport = $false; cleanupErrors = @(); unmountedImage = $true; omitWim = $false; omitCatalog = $false; omitSelections = $false; wrongIso = $false; wrongImage = $false; wrongAdk = $false; activeSelection = $false; changeLock = $false }
    foreach ($key in $Behavior.Keys) { $settings[$key] = $Behavior[$key] }
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'behavior.json') -Encoding UTF8
    $root
}
function Invoke-SourceFixture {
    param([string] $Root)
    Invoke-SourcePreparation -RepositoryRoot $Root -IsoPath (Join-Path $Root 'source [test] & image.iso')
}
$root = New-SourceFixture 'success'
$inputHashes = @{}
foreach ($file in @('windows.psd1', 'source-image.lock.json', 'toolchain.lock.json')) { $inputHashes[$file] = (Get-FileHash -LiteralPath (Join-Path $root ('config\' + $file))).Hash }
$result = Invoke-SourceFixture $root
Assert-SourceTest ($result.status -eq 'Succeeded' -and @($result).Count -eq 1) 'A fresh checkout produces one successful result without diagnostic output in the success stream.'
$expectedDirectory = Join-Path $root '.local\catalog\pro-34567.890'
Assert-SourceTest ($result.outputDirectory -ceq $expectedDirectory -and (Split-Path $result.wimPath -Parent) -ceq $expectedDirectory -and (Split-Path $result.catalogPath -Parent) -ceq $expectedDirectory -and (Split-Path $result.selectionsPath -Parent) -ceq $expectedDirectory) 'WIM, catalog, and selection template share the version-derived directory expected by VM validation.'
foreach ($file in $inputHashes.Keys) { Assert-SourceTest ((Get-FileHash -LiteralPath (Join-Path $root ('config\' + $file))).Hash -ceq $inputHashes[$file]) ('Source preparation preserves ' + $file) }
Assert-SourceTest (-not (Test-Path -LiteralPath (Join-Path $root 'config\catalogs'))) 'Generated catalogs are not copied into maintained configuration automatically.'
Assert-SourceTest ((Get-Content -LiteralPath (Join-Path $root '.local\workflows\prepare-source\operation.json') -Raw | ConvertFrom-Json).status -eq 'Succeeded') 'The coordinator records the verified outcome.'

# Exercise the public parameter binding and runtime guards without its privileged header.
$root = New-SourceFixture 'entry point'
[IO.Directory]::CreateDirectory((Join-Path $root 'workflows')) | Out-Null
$workflowSource = Get-Content -LiteralPath (Join-Path $repository 'workflows\prepare-source.ps1') -Raw
$offset = $workflowSource.IndexOf("if (`$MyInvocation.InvocationName -eq '.') { return }")
$entryPath = Join-Path $root 'workflows\prepare-source.ps1'
('[CmdletBinding()]' + [Environment]::NewLine + $ast.ParamBlock.Extent.Text + [Environment]::NewLine + $workflowSource.Substring($offset)) | Set-Content -LiteralPath $entryPath -Encoding UTF8
& $entryPath -IsoPath (Join-Path $root 'source [test] & image.iso')
Assert-SourceTest ((Get-Content -LiteralPath (Join-Path $root '.local\workflows\prepare-source\operation.json') -Raw | ConvertFrom-Json).status -eq 'Succeeded') 'The public entry point accepts this Windows PowerShell runtime and prepares source artifacts through the worker.'

foreach ($case in @(
    @{ name = 'process failure'; behavior = @{ exitCode = 7 }; expected = 'exit 7' }
    @{ name = 'failed report'; behavior = @{ status = 'Failed' }; expected = 'report or image cleanup failed' }
    @{ name = 'stale report'; behavior = @{ staleReport = $true }; expected = 'fresh completed report' }
    @{ name = 'missing report'; behavior = @{ omitReport = $true }; expected = 'does not exist' }
    @{ name = 'cleanup failure'; behavior = @{ cleanupErrors = @('synthetic cleanup failure') }; expected = 'report or image cleanup failed' }
    @{ name = 'mounted image'; behavior = @{ unmountedImage = $false }; expected = 'report or image cleanup failed' }
    @{ name = 'missing WIM'; behavior = @{ omitWim = $true }; expected = 'source artifact is missing' }
    @{ name = 'missing catalog'; behavior = @{ omitCatalog = $true }; expected = 'source artifact is missing' }
    @{ name = 'missing selections'; behavior = @{ omitSelections = $true }; expected = 'source artifact is missing' }
    @{ name = 'wrong ISO'; behavior = @{ wrongIso = $true }; expected = 'catalog differs from the pinned inputs' }
    @{ name = 'wrong image'; behavior = @{ wrongImage = $true }; expected = 'catalog image differs from the lock' }
    @{ name = 'wrong ADK'; behavior = @{ wrongAdk = $true }; expected = 'catalog differs from the pinned inputs' }
    @{ name = 'active template'; behavior = @{ activeSelection = $true }; expected = 'only commented component rules' }
    @{ name = 'changed lock'; behavior = @{ changeLock = $true }; expected = 'lock changed during export' }
)) {
    $root = New-SourceFixture $case.name $case.behavior
    Assert-SourceFailure { Invoke-SourceFixture $root } $case.expected
    $record = Get-Content -LiteralPath (Join-Path $root '.local\workflows\prepare-source\operation.json') -Raw | ConvertFrom-Json
    Assert-SourceTest ($record.status -eq 'Failed' -and $record.error) 'Invalid exporter results are retained as failed workflow evidence.'
}
$root = New-SourceFixture 'ISO mismatch'
Set-Content -LiteralPath (Join-Path $root 'source [test] & image.iso') -Value 'changed ISO'
Assert-SourceFailure { Invoke-SourceFixture $root } 'exit 9'
$root = New-SourceFixture 'concurrent'
$output = Join-Path $root '.local\workflows\prepare-source'
[IO.Directory]::CreateDirectory($output) | Out-Null
Set-Content -LiteralPath (Join-Path $output 'operation.json') -Value 'previous evidence'
$heldLock = [IO.FileStream]::new(($output + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
try { Assert-SourceFailure { Invoke-SourceFixture $root } 'Another prepare-source workflow' }
finally { $heldLock.Dispose() }
Assert-SourceTest ((Get-Content -LiteralPath (Join-Path $output 'operation.json') -Raw).Trim() -ceq 'previous evidence' -and -not (Test-Path -LiteralPath (Join-Path $root 'called.txt'))) 'Concurrent preparation preserves prior evidence and dispatches no worker.'
foreach ($relativePath in @('.local\workflows\prepare-source\input.iso', '.local\workflows\prepare-source.lock', '.local\catalog\pro-34567.890\input.iso', '.local\catalog\pro-34567.890.lock', '.local\catalog\pro-34567.890')) {
    $root = New-SourceFixture ([guid]::NewGuid().ToString('N'))
    $inputPath = Join-Path $root $relativePath
    [IO.Directory]::CreateDirectory((Split-Path $inputPath -Parent)) | Out-Null
    Set-Content -LiteralPath $inputPath -Value 'source must remain intact'
    Assert-SourceFailure { Invoke-SourcePreparation -RepositoryRoot $root -IsoPath $inputPath } 'outside the source-preparation output'
    Assert-SourceTest ((Get-Content -LiteralPath $inputPath -Raw).Trim() -ceq 'source must remain intact' -and -not (Test-Path -LiteralPath (Join-Path $root 'called.txt'))) 'Inputs cannot be cleaned or used as output lock files.'
}
$root = New-SourceFixture 'junction'
$target = Join-Path $root 'retained-source'
[IO.Directory]::CreateDirectory($target) | Out-Null
Set-Content -LiteralPath (Join-Path $target 'sentinel.txt') -Value 'retain'
[IO.Directory]::CreateDirectory((Join-Path $root '.local\catalog')) | Out-Null
New-Item -ItemType Junction -Path (Join-Path $root '.local\catalog\pro-34567.890') -Target $target | Out-Null
Assert-SourceFailure { Invoke-SourceFixture $root } 'reparse points'
Assert-SourceTest ((Test-Path -LiteralPath (Join-Path $target 'sentinel.txt')) -and -not (Test-Path -LiteralPath (Join-Path $root 'called.txt'))) 'Unsafe output paths never reach exporter cleanup.'
Write-Output ('Passed ' + $checks + ' source-preparation checks using synthetic exporters without DISM or host image changes.')
