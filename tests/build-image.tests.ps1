#Requires -Version 5.1
<#
.SYNOPSIS
Checks offline build planning and verification using synthetic data only.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\build-image.ps1')
$checks = 0
function Assert-BuildTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
function Assert-BuildException {
    param([scriptblock] $Action, [string] $Message)
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-BuildTest $thrown $Message
}
$remove = 'Example.Remove_1.0.0.0_neutral_~_8wekyb3d8bbwe'
$keep = 'Example.Keep_1.0.0.0_neutral_~_8wekyb3d8bbwe'
$config = @{ OptionalFeatures = @{ Virtualization = 'Enabled'; Legacy = 'Disabled' }; Capabilities = @{ 'Legacy~~~~0.0.1.0' = 'Absent' }; InboxApps = @{ $remove = 'Absent' } }
$before = @{
    OptionalFeatures = @([pscustomobject]@{ name = 'Virtualization'; state = 'Disabled' }, [pscustomobject]@{ name = 'Legacy'; state = 'Enabled' })
    Capabilities     = @([pscustomobject]@{ name = 'Legacy~~~~0.0.1.0'; state = 'Installed' })
    InboxApps        = @([pscustomobject]@{ name = $remove; state = 'Present' }, [pscustomobject]@{ name = $keep; state = 'Present' })
}
$manifests = @(
    [pscustomobject]@{ name = 'Example.Remove'; framework = $false; resource = $false; dependencies = @(); dependencyFamilies = @() },
    [pscustomobject]@{ name = 'Example.Keep'; framework = $false; resource = $false; dependencies = @(); dependencyFamilies = @() }
)
$plan = @(Get-ImageBuildPlan $config $before $manifests)
Assert-BuildTest ($plan.Count -eq 4) 'Plan the feature changes, capability removal, and selected app only.'
Assert-BuildTest (@($plan | Where-Object { $_.name -eq $keep }).Count -eq 0) 'Unselected apps must be retained.'
$appResource = [pscustomobject]@{ name = 'Example.Remove'; framework = $false; resource = $true; dependencies = @(); dependencyFamilies = @() }
Assert-BuildTest (@(Get-ImageBuildPlan $config $before @($manifests + $appResource)).Count -eq 4) 'App-owned resources must be serviced with their parent app.'
Assert-BuildException { Get-ImageBuildPlan $config $before @($manifests[1], $appResource) } 'Resources alone must not substitute for a main app manifest.'
$config.OptionalFeatures['Missing'] = 'Disabled'
Assert-BuildException { Get-ImageBuildPlan $config $before $manifests } 'Unknown component identifiers must fail before servicing.'
$config.OptionalFeatures.Remove('Missing')
$before.OptionalFeatures[0].state = 'EnablePending'
Assert-BuildException { Get-ImageBuildPlan $config $before $manifests } 'Unsettled source states must fail.'
$before.OptionalFeatures[0].state = 'Disabled'
$manifests[1].dependencies = @('Example.Remove')
Assert-BuildException { Get-ImageBuildPlan $config $before $manifests } 'Retained manifest dependencies must block removal.'
$manifests[1].dependencies = @()
$manifests[1].dependencyFamilies = @('Example.Remove_8wekyb3d8bbwe')
Assert-BuildException { Get-ImageBuildPlan $config $before $manifests } 'Retained package-family dependencies must block removal.'
$manifests[1].dependencyFamilies = @()
$manifests[0].framework = $true
Assert-BuildException { Get-ImageBuildPlan $config $before $manifests } 'Shared frameworks must not be removed.'
$manifests[0].framework = $false
Assert-BuildException { Get-ImageBuildPlan $config $before @($manifests[1]) } 'Missing selected app manifests must block removal.'
$store = 'Microsoft.WindowsStore_1.0.0.0_neutral_~_8wekyb3d8bbwe'
$config.InboxApps[$store] = 'Absent'
$before.InboxApps += [pscustomobject]@{ name = $store; state = 'Present' }
Assert-BuildException { Get-ImageBuildPlan $config $before $manifests } 'Store must be protected even with an explicit removal rule.'
$config.InboxApps.Remove($store)
$before.InboxApps = @($before.InboxApps | Where-Object { $_.name -ne $store })
$after = @{
    OptionalFeatures = @([pscustomobject]@{ name = 'Virtualization'; state = 'EnablePending' }, [pscustomobject]@{ name = 'Legacy'; state = 'DisabledWithPayloadRemoved' })
    Capabilities     = @([pscustomobject]@{ name = 'Legacy~~~~0.0.1.0'; state = 'NotPresent' })
    InboxApps        = @([pscustomobject]@{ name = $keep; state = 'Present' })
}
$verification = @(Get-ImageBuildVerification $config $before $after)
Assert-BuildTest (@($verification | Where-Object { -not $_.passed }).Count -eq 0) 'Configured offline states and retained apps must pass.'
Assert-BuildTest (@($verification | Where-Object { $_.requiresFirstBoot }).Count -eq 1) 'Pending feature completion must require first-boot verification.'
$after.InboxApps = @()
Assert-BuildTest (@(Get-ImageBuildVerification $config $before $after | Where-Object { -not $_.passed -and $_.section -eq 'RetainedInboxApps' }).Count -eq 1) 'Unexpected removal of an unselected app must fail verification.'
$after.InboxApps = @([pscustomobject]@{ name = $keep; state = 'Present' }, [pscustomobject]@{ name = $remove; state = 'Present' })
Assert-BuildTest (@(Get-ImageBuildVerification $config $before $after | Where-Object { -not $_.passed -and $_.name -eq $remove }).Count -eq 1) 'Remaining selected apps must fail verification.'
$after.OptionalFeatures = @()
Assert-BuildTest (@(Get-ImageBuildVerification $config $before $after | Where-Object { -not $_.passed -and $_.section -eq 'OptionalFeatures' }).Count -eq 2) 'Missing selected features must not be reported as disabled.'
Write-Output ("Passed $checks offline build checks.")
